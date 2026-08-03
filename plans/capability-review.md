# Capability review against AshScheduling

A gap assessment, not adapter design. The question is whether `timetable` can *express* the capabilities AshScheduling's implementation requirements state a scheduling system needs — regardless of who eventually wires the two together.

Source: `internal_docs/architecture/2026-02-09-implementation-requirements.md` in `team-alembic/ash_scheduling` (private), plus its ROADMAP and ADR-002. Reviewed 2026-08-03 against `timetable` at the tip of `main`.

Every "yes" below was executed, not assumed. Two were assumed on the first pass and turned out to be wrong; both are recorded as defects rather than quietly fixed and forgotten.

## Status

**Reviewed 2026-08-03. Revised after the gap-closing work of the same day.** Four of the five items the first pass raised are now closed; the fifth (holds and an injectable clock) is deliberately deferred to the adapter. The tables below record the current state; the closing notes record what changed and why.

## Verdict

Of the capabilities AshScheduling enumerates, `timetable` now covers the availability engine, matching, orchestration-as-values, and recurrence. What remains open is the claim lifecycle — specifically `:held` and the clock it needs — which is entangled with how claims are persisted and belongs with the adapter rather than ahead of it.

## The engine (their Phase 2)

| Requirement | Status |
| --- | --- |
| Pure resolution, no database | **Yes.** Every module is a value transform; the ledger is a struct. |
| Availability rules expanded within a query window | **Yes** — `open/2` accepts a Tempo value, ISO 8601, or RFC 5545 `RRULE`. |
| Existing claims excluded | **Yes** — `free/2` is `open − busy`. |
| Block-out overlapping availability is excluded | **Yes**, functionally. Block-outs are just busy time; there is no separate concept carrying a `reason`. |
| Block-out always beats availability | **Yes** — subtraction is unconditional. |
| DST-safe expansion, both directions | **Yes**, and now regression-tested in both hemispheres. A timezone database must be configured — see the closing note. |
| Capacity 1 — any overlap makes it unavailable | **Yes.** |
| Capacity > 1 — sum quantities against capacity | **Yes.** `concurrency` on a resource; a window is unavailable only where overlapping claims reach it. A claim of quantity *n* is *n* claims. |
| `buffer_before` / `buffer_after` | **Yes.** Durations on the resource, widening each claim before availability is computed. |
| `min_duration` filtering | **Yes** — `lasting_at_least/2`. |
| `explain: true` on unavailable windows | **Partial.** We explain *eligibility* richly ("seats is 4 — needs at least 8") but cannot say *why a particular window* is unavailable. |
| `transition_fn` for context-dependent gaps | **Yes, and richer** — `travel_time/3` derives the gap from the place tree with per-pair overrides, rather than a callback the consumer must supply. |
| `now` / injectable clock | **No.** Nothing in the library reads a clock; it only matters once holds exist. |
| Sweep-line, O(n log n) | **Yes**, inherited from Tempo's set operations. |
| Commutativity — evaluation order does not change results | **Yes, verified.** Three orderings of the same busy set give identical output. |
| Monotonicity — adding a block-out never increases availability | **Yes, verified.** |
| Bookable — every returned window can actually be taken | **Yes, verified.** No returned window overlaps any busy interval. |

## Orchestration, state, constraints, cycles (their Phases 3–6)

| Requirement | Status |
| --- | --- |
| Atomic multi-resource reserve, all-or-nothing | **Yes, as a value.** An arrangement allocates every role together; applying it atomically is the persistence layer's job, which is the correct split. |
| Dry-run check | **Yes** — `plan/3` is the dry run; nothing is committed until `allocate/2`. |
| Release by booking id | **Yes** — `release/2`, keyed by session. |
| Reschedule with supersedes chain | **Yes** — `rearrange/3` returns a minimal `:keep` / `:release` / `:allocate` changeset that maps onto the chain. |
| Idempotency key | **Partial.** `allocate/2` is idempotent by construction (a session's allocations are replaced wholesale), so retrying is safe. There is no key to deduplicate two *different* calls meaning the same thing. |
| Recurring series with a shared id, cancel-from-date | **Yes** — `every/3` expands a session over a recurrence; `release_series/3` cancels the run, or the rest of it with `:from`. |
| Conflict prevention under concurrency | **Correctly out of scope.** A pure library cannot arbitrate races; the ledger carries what an exclusion constraint or advisory lock needs. |
| Claim lifecycle: held → confirmed → completed / cancelled / no-show | **No** — deferred to the adapter. See the open item below. |
| Hold expiry excluded from conflict checks | **No** — follows from having no holds. |
| Constraint schedules: bookable only during a constraining schedule's hours | **Yes** — `only_during/2`. |
| Grouped OR constraints (any of three venues open) | **Yes** — `during_any/2`. |
| Constraint cycle detection | **Not applicable** — no constraint graph to make cyclic. |
| Cycles: rotating day patterns, working-days mode, exclusions | **Partial.** Tempo's recurrence and `Tempo.add_working_days/3` cover the arithmetic; we surface nothing named. |

## What the review found, and what was done

**1. `concurrency` was declared and enforced nowhere. Closed.** `Timetable.Resource` accepted `concurrency: 20`, the moduledoc explained it, and the getting-started guide taught it — while the value appeared in no other module. A twenty-locker bank went fully unavailable after one booking. This was worse than an absent feature, because the API promised something it did not do and the documentation taught the promise.

Closing it needed a primitive Tempo did not have: *the regions where at least N intervals overlap*. That is general interval algebra, not scheduling, so it went upstream as `Tempo.IntervalSet.overlapping/2`. Availability then reads as the sentence it always meant:

```elixir
busy
|> with_turnaround(resource)
|> IntervalSet.overlapping(at_least: resource.concurrency)
|> then(&Tempo.difference(open, &1))
```

> *"Take what claims the resource, widen each claim by its turnaround, find where those claims use it up, and subtract that from its open hours."*

Concurrency 1 falls out as the special case — a resource is used up wherever it is claimed at all.

**2. No timezone database was configured, so DST was silently wrong. Closed.** A London window from midnight to 6am on a spring-forward day measured six hours instead of five, and nothing raised: without `config :elixir, :time_zone_database`, Elixir resolves every zone as UTC and the arithmetic is quietly plausible. Tempo was correct throughout — the gap was ours. `tz` is now a dev/test dependency, configured in `config/config.exs`, with `test/timetable/timezone_test.exs` asserting both transition directions in both hemispheres and that the database is not the UTC-only default. **A consuming application must configure its own**, which the README now says.

**3. Buffers. Closed.** `buffer_before` and `buffer_after` are durations on the resource, and each claim is widened by them before availability is computed. AshScheduling's own worked case is a test: a 30-minute claim with a 15-minute after-buffer blocks 45 minutes.

This also needed a Tempo primitive. Shifting *backwards* by a duration decided at runtime had no clean expression — every consumer would hand-roll keyword negation — so `Tempo.Duration.negate/1` went upstream, with property tests that negation is an involution and that shifting by a duration then its negation returns the origin. The buffer code is then obvious:

```elixir
defp earlier_by(point, duration), do: Tempo.shift(point, Duration.negate(duration))
```

**4. Recurring sessions. Closed.** `every/3` expands a session over an ISO 8601 recurrence or an RFC 5545 `RRULE` into one session per occurrence, each windowed to its repetition and sharing a `:series` name. `release_series/3` cancels the run, or with `:from` only the part that has not happened yet. No new temporal machinery was needed — the recurrence is Tempo's.

**5. Naming what was already expressible. Closed.** Constraint composition, grouped-OR constraints, and minimum durations all worked through raw Tempo set algebra, but a caller had to know to reach for `Tempo.intersection/3`. They are now `only_during/2`, `during_any/2`, and `lasting_at_least/2`, and they compose:

```elixir
boardroom
|> Timetable.free(within: march, busy: taken)
|> Timetable.only_during(clinic_hours)
|> Timetable.lasting_at_least("PT2H")
```

> *"The boardroom's free time, only during clinic hours, in windows lasting at least two hours."*

Each verb accepts either a set or the `{:ok, set}` from the previous step, and an error falls straight through — so the pipeline reads as one sentence and still short-circuits. Each is one Tempo call underneath, which is the point: **a domain vocabulary on Tempo is naming operations, not reimplementing them.**

## Still open

**Claim lifecycle, and the clock it needs.** Most of the status graph — confirmed, completed, cancelled, no-show — is persistence's business and rightly outside a pure library. `:held` is not: a hold *consumes availability until it expires*, so the engine has to know about it, and that requires an injectable clock the library currently has no notion of.

This is deliberately deferred rather than merely unfinished. How a hold is represented depends on how claims are persisted, which is the adapter's decision; building it first would mean guessing at that shape. Everything a hold needs is already in place — allocations carry their interval, and `free/2` derives availability on every call — so adding one is additive when the adapter settles the representation.

**Two smaller partials** noted above and not closed: `explain: true` cannot yet say why a *particular window* is unavailable (only why a resource is ineligible), and cycles are expressible through Tempo's recurrence and working-day arithmetic without a named surface.

## Where we are ahead

Worth recording, because it shapes what an adapter should delegate rather than reimplement:

* **Attribute matching with explanations.** AshScheduling defines `Matcher` as a behaviour and ships no implementation; their `PoolMember.metadata` is an untyped map every strategy parses itself. We have a typed predicate vocabulary and a failure that is a sentence.

* **Induced requirements.** A person's `requires:` tightening the room requirement has no counterpart in their model, and it is the mechanism that makes accessibility impossible to forget.

* **Places as a tree.** ADR-002 lists geography as a non-goal that must stay possible, supported via the `context` map. We derive travel from containment, which is the thing they left open.

* **Whole-programme arrangement.** Their `Optimizer` behaviour is unimplemented and explicitly delegated to the consumer ("consumer brings CP-SAT, OR-Tools"). `arrange/3` fills it for the small-to-medium case, with caps that report truncation.

* **Calendar correctness beyond Gregorian.** Inherited from Tempo: non-Gregorian calendars, uncertain dates, and ISO 8601-2 semantics that a hand-rolled engine would not attempt.

## What this says about building on Tempo

Two of the five items needed something added to Tempo, and both additions were general rather than scheduling-specific: overlap depth (`IntervalSet.overlapping/2`) and duration negation (`Duration.negate/1`). Neither is about rooms or bookings; both are interval algebra any consumer would eventually want.

That is the pattern worth recording. When a domain library finds itself hand-rolling temporal logic, the question is whether the missing piece is *domain* or *temporal*. Overlap depth and negation were temporal, so they went upstream and the domain code collapsed to a readable pipeline. The place tree, requirement matching, and the allocation ledger are domain, and stay here.

## Recommendation

All five items the first pass raised are resolved or deliberately deferred. The next substantive work is the adapter, which is also where holds should be designed — their representation depends on how claims are persisted, and that is the adapter's decision to make rather than one to guess at now.
