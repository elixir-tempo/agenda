# `ash_scheduling_timetable` — a discussion document

**Audience:** Kip Cole and team Alembic. This is a proposal to talk about, not a design to sign off. Everything below that is Alembic's decision is marked as a question rather than answered.

**Note on circulation:** this document describes internals of `team-alembic/ash_scheduling`, which is a private repository. It should stay internal until Alembic are happy for it to travel — in particular it should not ship in a public release of `timetable`.

**Basis:** `ash_scheduling` at `main` as of 2026-08-03 (last commit 2026-07-03), read directly: `lib/ash_scheduling/schedule_engine.ex`, the DSL docs, ADR-002, and `internal_docs/architecture/2026-02-09-implementation-requirements.md`. `timetable` at `336ce4e`.

## Why an adapter at all

The two libraries solve adjacent halves of the same problem and barely overlap.

`ash_scheduling` owns everything to do with **being an Ash application**: resources, relationships, queries, transactions, policies, status lifecycle, persistence. Its `ScheduleEngine` resolves availability over that data — expanding RRULEs per schedule or availability timezone, subtracting block-outs and claims, intersecting across schedules for the all-free case. None of that can live in a library that does not know Ash, and `timetable` does not.

`timetable` owns everything to do with **what resources are and which one to choose**: typed attributes, requirement matching with explanations, a place tree that derives travel time, capacity depth, turnaround buffers, and a backtracking arranger for laying out many sessions at once. It is a pure value library — no processes, no database, no clock — sitting on Tempo's calendar-, timezone-, and DST-correct interval algebra.

The seam is narrow and the vocabularies already agree, which is the strongest evidence the fit is real:

| AshScheduling | Timetable |
| --- | --- |
| `Schedule` (polymorphic handle on a consumer entity) | `Resource` |
| `Availability` | `Resource.open` |
| `BlockOut`, `Claim` | busy time passed to `free/2` |
| `Claim` row | `Allocation` |
| `Booking` `reserve` / `release` / `reschedule` | `allocate/2` / `release/2` / `rearrange/3` |
| `Pool` + `Strategy` | requirement matching + `plan/3` |
| `[)` half-open ranges | `[)` half-open intervals |

Both enforce half-open bounds. Had they disagreed, none of this would compose.

## What is actually built, on both sides

Worth stating plainly because the roadmap is out of date and it changes what the adapter is for.

**`ash_scheduling`.** `ScheduleEngine.resolve/3` and `diagnose/3` are implemented — the ROADMAP still lists P2 as "Not started", but the engine exists and is tested. Of ADR-002's four behaviours, only `Strategy` exists in code (`lib/ash_scheduling/strategy.ex`, with a `Fifo` default); `Matcher`, `Selector`, `CostFn` and `Optimizer` are described in the ADR but have no modules yet.

Four capabilities that the implementation-requirements document specifies for the engine do not appear in it: **capacity**, **buffers**, **`min_duration`** and **`explain`** each occur zero times in `schedule_engine.ex`. Output is always UTC, which the moduledoc records as a TODO.

**`timetable`.** All four of those are implemented and tested, along with attribute matching, the place tree, series expansion, and whole-programme arrangement. It has no notion of persistence, concurrency control, or a clock.

That is the shape of the opportunity: the adapter is **not a replacement for the engine**. It is a way to fill in the parts of the engine's own specification that are not built yet, plus the domain logic ADR-002 always intended to come from the consumer.

## Three integration depths

This is the main thing to decide, and it is Alembic's call. They are increasingly invasive; each is a superset of the one before.

### Option A — behaviours only

The adapter implements `AshScheduling.Strategy` (and `Matcher`, `Selector`, `CostFn` if and when those modules land), backed by Timetable's matching, ranking, and place-tree travel. `ScheduleEngine` is untouched.

* **For:** zero disruption. Nothing in `ash_scheduling` changes. Ships today against `Strategy` alone. Exactly the extension model ADR-002 describes.
* **Against:** the engine's missing capacity, buffers, `min_duration` and `explain` stay missing, or get built twice. Consumers get better *selection* but not better *availability*.
* **Effort:** small.

### Option B — behaviours, plus availability refinement

As A, and additionally the adapter post-processes `ScheduleEngine.resolve/3` output through Timetable to add capacity depth, buffers, and `min_duration` filtering.

* **For:** the four unbuilt engine capabilities arrive without `ash_scheduling` implementing them. The engine keeps ownership of Ash data loading, RRULE expansion, and status filtering — the parts Timetable genuinely cannot do.
* **Against:** two interval representations in one pipeline (`TimeRange` and `Tempo.Interval`), so conversion happens twice per query. Responsibility for "what is available" becomes shared, which needs a clear story about which library owns which rule.
* **Effort:** moderate. This is the option we think is worth the most discussion.

### Option C — engine substitution

Timetable's availability computation replaces the resolution core of `ScheduleEngine`, with `ash_scheduling` keeping data loading, the DSL, and the write path.

* **For:** one interval implementation. Calendar correctness beyond Gregorian, ISO 8601-2 semantics, and DST handling that is regression-tested in both hemispheres. Resolves the UTC-output TODO, because Tempo values keep their zone.
* **Against:** the largest change to a library Alembic own and are building toward 1.0, and it makes `ash_scheduling` depend on Tempo. Hard to justify unless the calendar correctness is worth something to their users.
* **Effort:** large, and not ours to choose.

**Our suggestion, offered lightly:** start at A because it can ship immediately, and treat B as the real conversation. C is worth naming only so nobody thinks it is being smuggled in.

## What the adapter must implement, whichever depth

### 1. Projecting Ash resources into Timetable resources

The one piece with no counterpart today. `AshScheduling.Schedule` has nowhere to record that a room seats eight — `PoolMember.metadata` is an untyped map every strategy parses for itself.

The adapter should **not** add an attributes column. ADR-002's "your domain stays yours" is right, so the consumer implements a small behaviour projecting *their own* resource into a Timetable resource:

```elixir
defmodule MyApp.Rooms.Projection do
  @behaviour AshSchedulingTimetable.Projection

  @impl true
  def to_resource(%MyApp.Room{} = room) do
    Timetable.resource(room.name,
      within: place_for(room.floor),
      seats: room.capacity,
      video_conferencing: room.has_vc,
      step_free_access: room.accessible,
      concurrency: room.schedule.capacity,
      buffer_after: room.turnaround
    )
  end
end
```

Everything downstream — matching, explanations, travel, arrangement — follows from this one function.

### 2. Value conversion

`TimeRange` ⟷ `Tempo.Interval`, in both directions. Tempo has `from_date_time/1`, `to_date_time/1`, `from_naive_date_time/1` and `to_date/1`, so the mechanics are straightforward.

**One caveat worth stating up front:** a `tstzrange` cannot express a Tempo *resolution*. `~o"2027-06"` is a month-long interval, not a timestamp, and round-tripping flattens it to explicit bounds. The adapter must therefore treat persisted intervals as explicit spans and never rely on implicit-span semantics surviving the database. This is not a defect in either library; it is what the two representations mean.

### 3. Behaviour implementations

**A working `Strategy` exists as a proof of concept**, in the sibling project `ash_scheduling_timetable_poc`. It compiles against the real `AshScheduling.Strategy` with `@behaviour` and `@impl`, so the compiler checks the callback signature, and it reproduces the `DoctorAndRoom` example from your own moduledoc with declarative requirements instead of hand-filtering. Eleven tests pass. Two notes from building it are in that project's README, one of which is a packaging issue on your side (`ash_postgres` is declared optional but a dependent cannot compile without it).


* `Strategy.select/3` — filter pool members through Timetable requirement matching, rank by preference, return the chosen member(s). The multi-role case (one doctor *and* one room) is what `plan/3` already does.
* `Matcher.eligible?/3`, `Selector.select/3`, `CostFn.transition_cost/3` — when those modules exist. `CostFn` maps directly onto `travel_time/3` over the place tree, which is the geography ADR-002 lists as a non-goal that must stay possible.

### 4. Ledger reconciliation

Timetable's `rearrange/3` produces a minimal `:keep` / `:release` / `:allocate` changeset. The adapter turns that into `Claim` writes inside the caller's transaction, mapping `:release`/`:allocate` pairs onto the existing `supersedes` / `superseded_by` chain. Timetable never writes anything, which keeps atomicity and conflict prevention exactly where they belong — with Ash and Postgres.

## Open questions for Alembic

These are the decisions we should not make unilaterally.

1. **Which integration depth?** A, B, or C above. This determines everything else.

2. **Packaging.** A separate `ash_scheduling_timetable` package, or an optional dependency contributed into `ash_scheduling` itself? A separate package keeps your dependency graph clean and lets it version independently; contributing upstream makes it discoverable. We have no strong preference and it affects your release process more than ours.

3. **Are `Matcher`, `Selector` and `CostFn` still the intended shape?** ADR-002 defines them but they have no modules. If the design has moved, we would rather build against where you are going than against the ADR.

4. **Capacity representation.** Your `Claim` carries a `quantity`; Timetable counts overlapping claims and treats a quantity of *n* as *n* claims. Is that encoding acceptable at the boundary, or should Timetable take weights directly? The latter is a small change and we would rather match your model.

5. **Buffers.** Yours are integer minutes on `Schedule`; ours are `Tempo.Duration` on the resource. Converting is trivial in either direction — is there a reason to prefer one at the seam?

6. **Holds, and the clock.** This is the one capability Timetable deliberately does not have. A `:held` claim consumes availability until it expires, so an engine has to know about it, and that needs an injectable clock. We did not build one because **how a hold is represented depends on how claims are persisted, which is your decision.** You already have `AshScheduling.Clock`. Should Timetable grow a compatible clock abstraction, or should holds stay entirely on your side of the seam and simply arrive as busy time?

7. **Timezone database.** Elixir's default is UTC-only, and without a real IANA database daylight-saving arithmetic is silently wrong rather than failing — we shipped that bug ourselves and caught it only by testing a spring-forward day. You already depend on `tz`. Should the adapter assert a non-UTC-only database at boot rather than let a misconfiguration produce plausible wrong answers?

## Sequencing

1. Agree the integration depth and packaging (questions 1–2).
2. Build the projection behaviour and value conversion — needed at every depth, and independently testable.
3. Implement `Strategy` against it. This is a shippable increment on its own.
4. If Option B: add capacity, buffer and `min_duration` refinement over `resolve/3` output.
5. Revisit holds once 6 is settled.

Steps 2 and 3 do not depend on anything unbuilt in `ash_scheduling`, so they can start whenever.

## Explicitly out of scope

So nobody has to guess what we think we are proposing:

* **We are not proposing to replace conflict prevention.** Exclusion constraints for capacity-1 and advisory locks above it are Postgres's job and yours. A pure library cannot arbitrate races.
* **We are not proposing to own the status lifecycle.** Confirmed, completed, cancelled, no-show are persistence concerns. Only `:held` touches availability, which is why it is question 6 rather than an assumption.
* **We are not proposing a general constraint solver.** `arrange/3` handles a conference of a few dozen sessions and reports when its caps are hit; a university timetable of thousands wants CP-SAT. If someone brings one, its output writes back through the same allocation API.

## Risks

* **`ash_scheduling` is pre-1.0 and moving.** The ROADMAP is already out of date relative to the code. Anything the adapter builds against should be confirmed with you rather than read from documentation.
* **Two interval representations** in Option B means conversion in the hot path. Worth measuring before committing; we have not.
* **A shared responsibility for availability** is the real risk in Option B — if both libraries can affect what is available, the rule for who owns which behaviour has to be written down before the code is, not after.
