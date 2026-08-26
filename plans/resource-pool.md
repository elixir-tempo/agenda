# Plan — a resource pool abstraction

**Status: deferred, deliberately.** `Agenda.Resource.fetch/2` and `fetch_all/2` landed 2026-08-27 to close the identity-lookup gap. The structure itself is not built, because measurement says it is not yet paying for itself. This records what was measured, so the next person does not re-derive it — or reach for ETS on instinct, which the numbers below say is the wrong instinct.

## The problem

A pool is a bare `[Agenda.Resource.t()]` — 16 specs, 6 `is_list(pool)` guards, built by hand as `rooms ++ speakers`. Three things happen to it constantly, and all three are linear:

* **Identity lookup** — "the resource named `Ann`". Callers were writing `Enum.find/2` or building their own `Map.new(pool, &{&1.name, &1})`. `Ledger.arrangements/3` still builds exactly that map privately.

* **Eligibility filtering** — `Requirement.eligible/2` is `Enum.filter(candidates, &eligible?(requirement, &1))`, run once per requirement per session. This is the one that actually grows.

* **Traversal** — candidate enumeration walks the pool per session.

## What was measured

Machine: MacBook Pro, Elixir 1.20.0-rc.5 / OTP 29. Numbers are per-call unless stated.

### Pool size against end-to-end `arrange/3`

Padding the pool with resources that cannot satisfy any requirement, so only scan cost varies:

| pool | `arrange/3` |
| --- | --- |
| 8 | 80 ms |
| 206 | 60 ms |
| 1,006 | 92 ms |
| 3,006 | 176 ms |

375× the resources costs ~2× the time, and 206 was inside the noise of 8. **Search dominates; scanning does not.** That is the whole reason this is deferred.

### Identity lookup, 3,000 resources, worst-case position

| | per lookup |
| --- | --- |
| `Enum.find/2` | 133.3 µs |
| `Map.fetch/2` | 0.123 µs |
| `:ets.lookup/2` | 0.194 µs |

A plain map wins — ETS copies the term out of the table on every read, a map does not. ETS only becomes the better answer when the pool must be read by many processes without copying the whole list into each.

### Attribute filtering — ETS does not help

Full-table `:ets.select/2` against `Enum.filter/2`, 3,000 resources, varying selectivity:

| matches | `Enum.filter` | `:ets.select` |
| --- | --- | --- |
| 2,990 | 182 µs | 265 µs |
| 500 | 156 µs | 178 µs |
| 100 | 151 µs | 164 µs |
| 10 | 151 µs | 159 µs |

**ETS is slower at every selectivity tested**, including 10 matches out of 3,000. A select still traverses every row and then copies the matches out; the list is already on the process heap. An `ordered_set` keyed by `{attribute_value, name}` did not change this — a guard on the key does *not* make ETS bound the traversal. Bounding needs a match *pattern* that binds a key prefix, or explicit `:ets.next/2` walking from a start key.

### What match specs can and cannot express

Verified by execution, not from memory:

* `{:map_get, :seats, :"$2"}` **works** in a match-spec guard, and a row whose map lacks the key is silently skipped rather than erroring the select — which is exactly the semantics `at_least/1` wants.

* `is_map_key/2` works. `:==`, `:>=`, `:"=<"`, `:orelse`, `:andalso` work, so `exactly/1`, `at_least/1`, `at_most/1` and `any_of/1` over scalar attributes are all expressible.

* `{:member, …}` is **rejected** — `not a valid match specification`. There is no list-membership guard BIF, so `all_of/1` and `none_of/1` over list-valued attributes can never be pushed into a select. Those always need a post-filter, so any index is partial by construction.

## When to revisit

Two triggers, either one sufficient:

* **A pool in the thousands with a search that is not the bottleneck.** The table above says scanning starts to matter somewhere past ~1,000 resources. If a profile ever shows `Requirement.eligible/2` above the search, that is the signal.

* **A pool that must be shared across processes.** `arrange/3` already enumerates candidates under `Task.async_stream`; today each task gets the pool by copy. A shared table changes that calculus, and is the one argument for ETS the numbers actually support.

## What to build, when it is time

Not ETS-first. In order of increasing cost:

1. **`Agenda.Pool` as a value** — a struct holding the resources *and* a name index, accepted anywhere a list is accepted today, so `is_list(pool)` guards become a normalising clause and `rooms ++ speakers` keeps working. `Ledger.arrangements/3` drops its private map. Non-breaking, and settles identity lookup permanently at 0.12 µs.

2. **Attribute indexes inside that struct** — `%{attribute => %{value => [name]}}` built once at construction, narrowing candidates before `eligible?/2` runs. Pays only for selective requirements; `all_of`/`none_of` fall through to a scan per the match-spec finding above. Needs invalidation discipline, since `Agenda.open/2` and `Agenda.resource/2` return new resources.

3. **An ETS-backed pool** — only for the cross-process case, and only if measurement says the copy is the cost. The price is that a pool stops being a value: it acquires an owner process, a lifecycle, and a table that must outlive every task reading it. `arrange/3`'s determinism guarantee depends on the pool not shifting underneath it, and a mutable table makes that a property to defend rather than one you get for free.

## Done so far

`Agenda.Resource.fetch/2` and `fetch_all/2` — identity lookup over a list, returning `{:error, {:unknown_resource, name}}` and `{:error, {:unknown_resources, names}}`. `fetch_all/2` is all-or-nothing and reports *every* unknown name, because the failure being prevented is a roster that quietly loses a member: the session still runs, without the person it named. Still O(n) per lookup — deliberately, per the measurement above.
