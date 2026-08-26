# Plan — `agenda`: resources, requirements, and programmes

Tempo answers *when is this free?* It cannot answer *what should I book, and where?* This plan adds named resources, the attributes that describe them, the places that contain them, the requirements a session places on them, and the allocation ledger that keeps the answer true as sessions move. The temporal core stays where it is; the resource vocabulary goes into a companion library, `agenda`; an adapter makes it drop into AshScheduling's declared extension points.

## Problem

A scheduling request in the real world is not "find a free hour". At the small end it is:

> *"Book the quarterly review — an hour some time next week, eight people, a room that seats them all with video conferencing, and Alice needs step-free access."*

At the large end it is the same sentence repeated sixty times with interference between the repetitions:

> *"Lay out a four-day conference over two venues and eight rooms: no track may collide with itself, popular talks go in the big rooms, and a delegate must be able to walk between consecutive talks in the ten-minute break."*

Tempo can express the *when* of both exactly and can already compute the free windows. It has no vocabulary for the *what*, the *who*, or the *where*: no named resource, no attribute on a resource, no containment between places, no requirement a session places on a resource, no record of what is allocated to whom, and so no way to free a room when the session holding it moves or is cancelled.

Everything above the temporal line is currently the caller's problem, and every caller solves it the same way — a map of resources, hand-rolled filters over its keys, a hard-coded travel matrix, ad-hoc bookkeeping to release what was held. That is the undifferentiated heavy lifting this plan removes.

## What already exists — an audit, not an assumption

The premise that `IntervalSet` metadata is "already the base platform" is half right, and the half that fails is the half a booking engine leans on hardest. Measured on `f7f29b3`:

* **`difference/2` preserves the left operand's metadata across every emitted fragment.** Subtracting a resource's busy time from its availability keeps each free fragment tagged with the resource it belongs to. This is the single most important behaviour for resource scheduling and it already works.

* **`union/2` preserves per-member metadata** — members stay distinct, each keeping its own tag. Pooling several resources' free time into one set retains which fragment came from which.

* **`filter/2` sees metadata**, so "the members belonging to Bob" is already expressible.

* **`intersection/2` keeps only the *left* operand's metadata and silently drops the right's.** Intersecting Alice's free time with Bob's yields fragments tagged `alice` only. This is documented (`lib/operations.ex:727`) and deliberate, but it means the central multi-resource question — *"who and what is free in this window?"* — loses its answer at the moment it is computed. There is no option to merge.

* **`slots/3` drops metadata entirely** — every cut slot comes back with `%{}`. The function that turns free regions into the windows a booking UI offers is exactly where resource identity matters most, and it is where identity is lost. This is undocumented: the `slots/3` docs never mention metadata, so this is a gap rather than a design decision.

Two further pieces of prior art matter more than the metadata question:

* **Tempo's set operations are already a sweep-line** (`sweep_intersection`, `sweep_members` in `lib/operations.ex`), which is precisely the algorithm AshScheduling's ADR-003 selects for its unbuilt availability engine — and Tempo's is calendar-correct, zone-aware, and non-Gregorian-capable, which a hand-rolled one would not be. `Tempo.IntervalSet.Backend.Tree` additionally provides the interval tree ADR-003 lists as the structure to reach for "if the engine gains a long-lived, frequently-queried dataset".

* **`Tempo.Network` is a Simple Temporal Problem solver** and `Tempo.Schedule` is critical-path scheduling on top of it. ADR-003 considers temporal CSP, rejects it *for the enumeration engine*, and says it "belong[s] in that layer" if an optimiser is ever added. That layer is what this plan builds, and its solver is already written.

The summary: Tempo has the temporal engine AshScheduling has not yet built, plus the constraint solver AshScheduling explicitly defers to its consumer. What is missing from both is the resource vocabulary in between.

## Architectural boundary — core, companion, adapter

The line follows the precedent set in Tempo's own `plans/uncertainty-roadmap.md` (sibling repo): work that reads or produces *intervals* is core; work that introduces a *new value type* is companion.

* **Metadata provenance → Tempo core.** Making `intersection/3` able to merge metadata and `slots/3` able to carry it produces intervals, changes no types, and fixes a gap that anyone attaching meaning to an interval hits. It belongs beside the operations it corrects, and it is worth doing whether or not the rest of this plan proceeds.

* **Resources, places, requirements, allocations → companion library.** A `Resource` is not an interval and never becomes one. Attribute matching is set logic over maps; containment is a tree walk. Neither touches the time line. Putting them in core would double Tempo's surface area with a domain vocabulary that most of Tempo's users — the ISO 8601, calendar, and recurrence users — would never touch, and would bind a focused 1.0 temporal library to the release cadence of a scheduling product.

* **Ash resources, persistence, transactions → adapter.** The companion library must not know what a database is. Ash already owns identity, persistence, transactions, and policy; the adapter's whole job is to translate between Ash's rows and the companion's values.

## The lexicon

Scheduling is a field where the obvious word is almost always already taken by something else, so the vocabulary is a design decision rather than a naming afterthought. Three collisions are hard constraints:

* **`Stream` is unusable.** Elixir's stdlib owns it, and a conference "stream" would shadow it in every `alias`. The concept is a **track**.

* **`Schedule` is triple-booked** — `Tempo.Schedule` is critical-path project scheduling, `AshScheduling.Schedule` is *the bookable resource*, and colloquially "the conference schedule" is the finished output. The library never uses the bare word as a module name.

* **`Event` is already taken inside Tempo** — `Tempo.Event.Easter` exists — and it collides with event-sourcing besides. The thing being scheduled is a **session**.

The settled vocabulary, with what each term displaces:

| Concept | Term | Not, because |
| --- | --- | --- |
| A bookable thing — room, person, projector | **Resource** | `Asset` implies ownership; `Schedule` is AshScheduling's word for this exact thing |
| A fact about a resource | **Attribute** | `Property` collides with property-based testing |
| A resource that contains others | **Place** | `Venue` is event-only — a hospital is not a venue; `Location` is a coordinate, not a container |
| The containment relation | **`within`** | `parent`/`child` says nothing about what the relation means |
| A thing needing resources for a span | **Session** | `Meeting` too narrow; `Event` taken; `Booking` is AshScheduling's, and means the *request* there |
| Sessions that must not self-overlap | **Track** | `Stream` fatal; `Series` implies recurrence |
| The whole collection being laid out | **Programme** | `Schedule` overloaded; `Plan` is the verb |
| What a session demands of a resource | **Requirement** | `Constraint` leaks solver internals into the API |
| One resource bound to one session | **Allocation** | `Claim` and `Reservation` are AshScheduling's |
| The set of allocations | **Ledger** | — |
| One candidate solution | **Arrangement** | `Solution` implies uniqueness; `Option` is too weak for a whole programme |

The test that this vocabulary works: *"the programme allocates a resource to each session in a track, subject to its requirements, and the ledger records what is committed."* That sentence is true of a conference, a court list, a school timetable, and a dentist.

## The model

Every noun below is a value — no processes, no database, no global state.

### Resources and attributes

People and rooms are the same kind of thing; only their attributes differ.

```elixir
boardroom = Agenda.resource("Boardroom",
              within: level_2, seats: 8, video_conferencing: true,
              whiteboards: 2, step_free_access: true)

alice = Agenda.resource("Alice", requires: [step_free_access: true])
```

A resource carries its own availability — the recurring pattern of when it is open at all, as a Tempo value:

```elixir
boardroom = Agenda.open(boardroom, ~o"R/2026-01-05T08/PT10H/P1W", on: Tempo.workdays())
```

> *"The boardroom is open for ten hours from 8am every workday."*

### Places are a tree, and travel is derived from it

A place contains resources and other places. Depth is arbitrary — campus, building, floor, wing — and the library never interprets the levels, only their nesting.

```elixir
sydney   = Agenda.place("Sydney Convention Centre")
level_2  = Agenda.place("Level 2", within: sydney)
darling  = Agenda.place("Darling Harbour Theatre")

Agenda.travel_time(boardroom, annexe)      # both within level_2
# => ~o"PT3M"

Agenda.travel_time(boardroom, main_stage)  # different venues
# => ~o"PT25M"
```

> *"Two rooms on the same level are three minutes apart; two rooms in different venues are twenty-five."*

Travel time is a function of the **lowest common ancestor** of the two resources in the place tree — a default per-depth table, overridable for any specific pair when the real building disagrees with the geometry. This is what makes the containment tree earn its place: a flat `location: :sydney` attribute can answer *"is this room in Sydney?"* but not *"can a delegate get from here to there in the break?"*, and the second question is the one that decides whether a programme is workable at all. It is also precisely what AshScheduling's `CostFn.transition_cost/3` exists to answer.

### Sessions and requirements read as the sentence a person would say

```elixir
review =
  Agenda.session("Quarterly review", duration: ~o"PT1H")
  |> Agenda.needs(:room, seats: at_least(8), video_conferencing: true)
  |> Agenda.needs(:attendees, all_of([alice, bob, carol]))
  |> Agenda.between(~o"2026-06-15/2026-06-20")
  |> Agenda.prefers(within: sydney)
```

> *"The quarterly review needs a room seating **at least** eight with video conferencing, and Alice, Bob and Carol; it runs for **an hour** somewhere **between** the 15th and the 20th, **preferably** in Sydney."*

The attribute predicates — `at_least/1`, `at_most/1`, `exactly/1`, `any_of/1`, `all_of/1`, `none_of/1` — deliberately mirror the duration predicates Tempo already has (`at_least?/2`, `at_most?/2`, `exactly?/2`). One vocabulary, applied on one side to durations and on the other to attributes, is one thing to learn.

### Tracks constrain sessions against each other

A track is the first construct that is not about a resource at all. It is a family of sessions with relationships among themselves.

```elixir
elixir_track =
  Agenda.track("Elixir", of: [keynote, otp_internals, ecto_at_scale])
  |> Agenda.no_overlap()
  |> Agenda.reachable(within: ~o"PT10M")
```

> *"No two talks in the Elixir track may overlap, and a delegate must be able to walk between consecutive ones inside the ten-minute break."*

`reachable/2` reads the place tree — it is the payoff for modelling containment rather than labelling location. `no_overlap/1` is the constraint that makes a track a track.

These two differ in kind, and the difference decides which solver handles them. If a track is pinned to one room and runs sequentially, `no_overlap` reduces to precedence between time points, which is exactly the Simple Temporal Problem `Tempo.Network` already solves. If the room is free to vary per session, it is mutual exclusion with a choice — disjunctive, outside STP, and therefore handled by the search in stage 4 rather than by the network.

### Programmes lay out the whole thing at once

```elixir
programme =
  Agenda.programme("ElixirConf AU 2026")
  |> Agenda.across(~o"2026-09-15/2026-09-18")
  |> Agenda.in_places([sydney, darling])
  |> Agenda.add_track(elixir_track)
  |> Agenda.add_track(phoenix_track)

{:ok, arrangement} = Agenda.arrange(programme, against: ledger)
```

> *"Lay the conference out across four days and two venues so that no track collides with itself and every delegate can get between consecutive talks."*

Two verbs, two scopes, deliberately distinct: `plan/2` returns ranked arrangements for **one** session; `arrange/2` solves a **whole programme** at once. A caller who only ever books meeting rooms never meets `arrange/2`.

### Five distinctions that decide whether the model survives contact

**Seats are not concurrency.** `seats: 8` is an attribute matched against demand. *How many sessions may hold this resource at once* is a separate property, and conflating them is the trap that makes a 200-seat lecture hall accept two simultaneous lectures. They are orthogonal: the lecture hall is `seats: 200, concurrency: 1`; a bank of twenty identical lockers is `seats: 1, concurrency: 20`. AshScheduling's `Schedule.capacity` is the *concurrency* one, which is why the word "capacity" is avoided in this library entirely.

**A place is a tree, not a label.** Covered above; the consequence for the API is that `within:` takes a place, never a string, and travel is computed rather than configured.

**A person's attribute is often a requirement on something else.** `step_free_access: true` on Alice is not a fact about Alice's availability — it is a constraint she imposes on whatever room she is allocated. The model makes this explicit with `requires:`, and requirements compose upward: allocating Alice to a session adds her requirements to that session's room requirement.

```elixir
Agenda.explain(review, meeting_room_2)
# => "Meeting room 2 seats 4 — the review needs at least 8.
#     No step-free access — Alice requires it."
```

> *"Meeting room 2 is out on two counts: too small, and Alice cannot get into it."*

Without this, accessibility degrades into a filter the caller has to remember to apply, which is exactly the bug class the library exists to remove.

**Some attributes aggregate across resources, most do not.** Two rooms seating four do not make a room seating eight, but eight chairs plus four chairs make twelve. An attribute is therefore declared `:exclusive` (default — matched against a single resource) or `:additive` (summed across the allocated set). Getting this wrong in either direction produces a programme that is silently impossible.

**Hard requirements filter; soft preferences rank.** `needs` removes candidates; `prefers` orders the survivors. An arrangement satisfying every `needs` and no `prefers` is still valid — it is just worse. Keeping these in separate functions rather than one weighted score means an empty result always has a reason expressible as a sentence.

### Planning produces ranked, explained arrangements — not one answer

```elixir
{:ok, arrangements} = Agenda.plan(review, against: ledger)

Enum.map(arrangements, &Agenda.explain/1)
# => ["Tue 16 Jun 10:00–11:00 — Boardroom, all three attendees free. Sydney (preferred).",
#     "Thu 18 Jun 14:00–15:00 — Boardroom, all three attendees free. Sydney (preferred).",
#     "Wed 17 Jun 09:00–10:00 — Annexe, all three attendees free. Darling Harbour."]
```

> *"There are three ways to hold this session; the first two are in the preferred venue."*

When there is no answer, the failure is a sentence and not an empty list:

```elixir
{:error, %Agenda.Infeasible{} = reason} = Agenda.plan(unstaffable, against: ledger)

Agenda.explain(reason)
# => "No room seats 8 with video conferencing between 15 and 20 June.
#     The Boardroom qualifies but is allocated to Board meeting on all five days."
```

> *"You cannot hold this session, and the thing standing in the way is the board."*

At programme scale the same discipline applies to a partial failure — an infeasible programme names the track and the session that could not be placed, not merely that placement failed. This is the capability AshScheduling's `explain: true` mode reaches for and can only supply at the temporal level; attribute- and place-level reasons are only expressible once attributes and places exist.

## How an arrangement is solved

The pipeline is ordered cheapest-first, and every stage but one is set algebra Tempo already performs.

1. **Eligibility — attribute matching, no time involved.** Requirements filter resources by attributes alone. This is a map comparison over a few hundred resources at worst, it needs no calendar, and it typically removes most of the search space before any interval is touched. Induced requirements (`requires:`) are folded in here.

2. **Availability — one `difference/2` per surviving resource.** `free = open − allocated`. Metadata already survives `difference/2`, so every free fragment stays tagged with its resource.

3. **Co-availability — `intersection/2` across a candidate combination.** The windows where a room *and* every attendee are simultaneously free.

   *Revised after building Phase 2:* this stage was expected to need the Phase 0 metadata-merge fix, and does not. The planner drives each intersection itself, one resource at a time, so provenance is already in the call structure — it never has to be recovered from interval metadata. That makes Phase 0 genuinely independent of this library rather than a prerequisite for it, and it is the better design regardless: relying on a carrier with documented lossy semantics would have been fragile. Phase 0 remains worth doing for Tempo's own users.

4. **Selection — matching, with travel and track feasibility.** Given the windows, choose an actual allocation: one room from the eligible rooms, the named attendees, additive attributes summed. Two feasibility checks join the match here — `reachable/2` rejects a pair of consecutive track sessions whose rooms are further apart than the gap between them, and `no_overlap/1` rejects a track colliding with itself. For the overwhelmingly common shape (one room, N named people, no track) this collapses to a direct lookup.

5. **Ranking — soft preferences.** Score survivors, order, return.

6. **Linked sessions — hand the skeleton to `Tempo.Network`.** A panel of three back-to-back interviews, or a track pinned to one room, is a conjunctive precedence problem over time points — exactly the Simple Temporal Problem `Tempo.Network` and `Tempo.Schedule` already solve. Resource choice is made in stages 1–5; the temporal shape is tightened by the existing solver.

Stages 1–3 and 6 are existing machinery. Stage 4 is the genuinely new algorithm, and its single-session case is small.

### What this deliberately is not

This is a **search over enumerated candidates**, not a general constraint optimiser. Single-session planning against a few hundred resources is exact and fast. A conference of a few dozen sessions across a handful of rooms is tractable by search with the track and travel constraints pruning hard. A university timetable of thousands of classes, or a month's roster for two hundred staff minimising overtime, is not — that is CP-SAT's job, and ADR-002 already routes it to the `Optimizer` behaviour with the consumer bringing their own solver.

The line is worth stating plainly rather than letting it be discovered in production. Where the two meet is that an external optimiser's output is written back through the same allocation API, so the ledger stays authoritative either way.

**Since written, that hand-off is implemented rather than merely described.** `Agenda.Fixpoint.solve/3` hands a programme to a CP solver and takes ordinary arrangements back. It does not move the line — it makes crossing it a function call. The model handed over is *which candidate placement* per session, so eligibility, induced requirements, availability and the place tree stay on this side where they are explained, and the solver never learns what a room is.

Two further qualifications the original text did not anticipate. Soft constraints were added, but only lexicographically: the count is proven first and the score improved second, so this is still not a general optimiser and does not pretend to prove a weighted optimum. And the fixpoint bridge models exclusive resources only, because capacity above one is not a pairwise property and that solver has no cumulative constraint.

## Persistent state — the ledger, and why freeing is not a workflow

The requirement is that a resource is released when the session holding it changes or is cancelled. The design decision that makes this trivial rather than error-prone: **an allocation is keyed by the session that holds it, and free time is derived, never stored.**

```elixir
ledger = Agenda.Ledger.new()
{:ok, ledger} = Agenda.allocate(ledger, arrangement)

Agenda.free(ledger, boardroom, during: ~o"2026-06-16")
# => the boardroom's open hours minus everything allocated to it that day
```

> *"The boardroom's free time is what it is open minus what is already allocated."*

Because free time is a `difference/2` computed on demand rather than a stored flag, there is no such thing as a stale free/busy record and no release step that can be forgotten. Cancelling is dropping a key:

```elixir
{:ok, ledger} = Agenda.release(ledger, "Quarterly review")
```

> *"Releasing the review frees the room and all three attendees, because nothing was holding them but the review."*

### Moving a session produces a changeset, not a rewrite

Rescheduling is the operation that gets bungled in every hand-rolled system, because the naive implementation releases everything and re-acquires it — which loses the room to a competing booking in the gap, and churns rows that did not need to change. The library instead computes the difference between what is allocated and what is now wanted:

```elixir
{:ok, changes} = Agenda.rearrange(ledger, "Quarterly review", new_arrangement)

changes
# => [keep:     {alice,     ~o"2026-06-18T14/PT1H"},
#     keep:     {bob,       ~o"2026-06-18T14/PT1H"},
#     release:  {boardroom, ~o"2026-06-16T10/PT1H"},
#     allocate: {annexe,    ~o"2026-06-18T14/PT1H"}]
```

> *"Moving the review keeps Alice and Bob, gives back the boardroom, and takes the annexe instead."*

The changeset is an ordinary value. The library never applies it — it has no database — so the adapter applies it inside whatever transaction its data layer provides, and the minimal-diff property means the write touches only what genuinely moved. At programme scale this matters more, not less: republishing a conference programme after one speaker cancels should move one session, not sixty.

### Concurrency is the adapter's problem, and the library must not pretend otherwise

A ledger is an immutable value, so two processes can plan against the same snapshot and both succeed. Nothing in a pure library can prevent that. What the library owes the adapter is enough information to detect it: every allocation carries the session key and interval needed for a uniqueness or exclusion constraint to reject the loser, and `allocate/2` is idempotent on an unchanged changeset so a retry after losing a race is safe. AshScheduling's roadmap already assigns this to its P3 orchestration phase (exclusion constraints for concurrency 1, advisory locks above it); the adapter should use that machinery rather than duplicate it.

## Fitting AshScheduling

AshScheduling's architecture was designed with exactly this seam in mind. ADR-002 defines four behaviours as the places domain logic plugs in, and states that the library "does not implement constraint solvers", "does not implement skill/preference matching logic", "does not model geography, locations, or spatial relationships", and carries a free-form `context` map on every callback for whatever the consumer needs. `agenda` is a consumer that fills all four.

| AshScheduling extension point | `agenda` supplies | Status upstream |
| --- | --- | --- |
| `Matcher.eligible?/3` | Stage 1 — attribute matching with `explain` | Behaviour defined, no implementation |
| `Selector.select/3`, `Strategy.select/3` | Stages 4–5 — matching and ranking | `Fifo` only |
| `CostFn.transition_cost/3` | `travel_time/2` over the place tree | Default fixed buffers only |
| `Optimizer.optimize/3` | Programme-scale `arrange/2`; passes through to an external solver above that | No implementation |
| `ScheduleEngine.resolve/3` (P2) | Tempo's sweep-line set algebra, calendar- and zone-correct | **Not started** |
| P5 Constraints | Requirements and tracks | **Not started** |
| P6 Cycles (rotating day patterns) | Tempo recurrence and RRULE | **Not started** |
| P7 Pools and assignment | Stages 1–5 behind `Strategy` | **Not started** |

The mapping of nouns is close to one-to-one, which is the strongest evidence the two models agree:

* A `Agenda.Resource` is an `AshScheduling.Schedule` — both are polymorphic handles onto a consumer entity. Attributes are the missing half: AshScheduling has nowhere to put `seats: 8` except `PoolMember.metadata`, an untyped map every strategy must parse for itself. The adapter should not add an attribute column; it should define a small behaviour the consumer implements to project *their own* `Room` resource into attributes and its place, which keeps ADR-002's "your domain stays yours" promise intact.

* A `Agenda.Ledger` is the set of `Claim` rows; `allocate`/`release`/`rearrange` are `Booking`'s `reserve`/`release`/`reschedule` actions. The `rearrange` changeset maps directly onto the `supersedes` / `superseded_by` chain those actions already maintain.

* `Agenda.plan/2` is what `Booking.available_slots` and `Pool.process` want to call.

* **Places have no counterpart, by their design not by oversight.** ADR-002 lists geography as a non-goal that "must never be prevented", supported via `context`. The place tree is exactly the thing a consumer is expected to bring, and `travel_time/2` is exactly the `CostFn` they left open.

Two frictions are real and should be stated rather than discovered:

* **Value conversion at every boundary.** AshScheduling stores `tstzrange` and `DateTime`; this library works in `Tempo` and `Tempo.Interval`. Tempo has `from_date_time/1`, `to_date_time/1`, `from_naive_date_time/1` and `to_date/1`, so the conversion is mechanical — but a `tstzrange` cannot represent a Tempo *resolution* (`~o"2026-06"` is a month-long interval, not a timestamp), so round-tripping flattens resolution to explicit bounds. Persisted intervals must therefore be treated as explicit spans, never relying on implicit-span semantics surviving a database round trip.

* **Half-open agreement is a precondition, and it holds.** Both libraries enforce `[)` — Tempo as a stated architectural invariant, AshScheduling in `TimeRange`/`Tstzrange` canonicalisation (their R-08). Had they disagreed, none of this would compose.

## Rejected alternatives

* **Put it all in Tempo core.** Rejected: doubles the surface area of a focused 1.0 temporal library with a domain vocabulary most of its users will never touch, and couples Tempo's release cadence to a scheduling product's. The metadata provenance work is the only part that passes the core test.

* **Build it inside AshScheduling directly.** Rejected: it would be unusable outside Ash, and ADR-002 is explicit that this logic belongs in the consumer. A pure library with a thin adapter serves both the Ash user and the plain-Elixir user; the reverse does not.

* **`location` as a flat attribute instead of a place tree.** Rejected: it answers "is this room in Sydney?" but not "can a delegate get between these two rooms in ten minutes?", and only the second question decides whether a programme is workable. A flat label also forces every caller to maintain their own travel matrix — the thing the tree derives.

* **Attributes as an untyped map matched by a consumer-supplied function.** Rejected: it is what `PoolMember.metadata` already offers and it is why nothing can explain a failure. Without a declared predicate vocabulary there is no way to say *"needs at least 8, this seats 4"* — only `false`.

* **A full CP-SAT solver in the library.** Rejected: enormous, and the wrong shape for the incremental path that dominates. The staged pipeline handles single sessions exactly and modest programmes well; the `Optimizer` behaviour is the documented door for the rest.

* **Store free/busy rather than derive it.** Rejected: every stale-cache and forgotten-release bug in scheduling comes from here. Deriving costs one `difference/2`.

## Phases

**Phase 0 — Tempo core: metadata provenance.** Add a `:metadata` option to `intersection/3` (`:left` default — non-breaking — plus `:merge` and `{:merge, fun}`), and carry the source member's metadata onto each slot in `slots/3`. The `slots/3` change is a behaviour change but a defect fix: the docs never claimed metadata was dropped. CHANGELOG under `Fixed` and `Added`. Independently useful; ships with or without the rest.

**Phase 1 — model and matching, no time.** `Resource`, attributes, the `Place` tree and `travel_time/2`, `Requirement`, the predicate vocabulary, induced requirements, `:exclusive`/`:additive`, and `explain` for eligibility. Entirely testable without a calendar, which makes it the right first slice.

**Phase 2 — availability and single-session planning.** `open/2`, `free/2`, stages 2–5 for one session, ranked arrangements with `explain`, `Infeasible` with reasons. This is where Tempo does the work. **Done.** Phase 0 turned out not to be a prerequisite — see stage 3 above.

**Phase 3 — ledger and changesets.** `allocate`, `release`, `rearrange`, the minimal diff, idempotency. **Done.** The two invariants the Risks section names are covered by tests: an unchanged arrangement diffs to `:keep` only, and `allocate` then `release` returns the original ledger. `busy/2` closes the loop back into `plan/3`, with `:except` so a session re-planning does not collide with the copy of itself it is about to replace.

**Phase 4 — tracks and programmes.** `track/2`, `reachable/2`, `programme/1`, `arrange/3`. **Done**, with two deviations from this plan, both deliberate:

* **`no_overlap/1` was not built.** The lexicon defines a track as "sessions that must not self-overlap", so making that opt-in would contradict the definition. Not overlapping is intrinsic; `reachable/2` is the only option.

* **`Tempo.Network` is not used.** The plan expected pinned tracks to delegate to the STP solver. In practice every track shape — pinned or varying-room — is handled by the same backtracking search, because the search must run anyway for resource exclusion and reachability, and routing a subset of cases through a second solver would add a seam for no gain. The STP remains the right tool if precedence constraints between sessions are ever added (*"the panel must follow the keynote"*), which this phase does not model.

**Phase 4d — calendar interchange.** Not in the original plan. `from_ical/1` reads RFC 7953 `VAVAILABILITY` into open hours. The parsing sits upstream — `VAVAILABILITY` support was contributed to the `ical` library and the interval work to `Tempo.ICal` — because the missing piece was *format*, not *domain*, which is the same test that sent `IntervalSet.overlapping/2` and `Duration.negate/1` upstream. RFC 8984 JSCalendar landed the same way, as a standalone `jscalendar` package with a `Tempo.JSCalendar` bridge. **Done.**

**Phase 4a — answering when it does not fit.** Not in the original plan, and added once the search was exercised in anger. `unplaced: :allow` returns a `Layout` under a `{:partial, …}` tag with the fewest sessions left out; `:pinned` fixes chosen placements and searches around them; `Conflict.minimal/3` (QuickXplain) names the smallest set of sessions or requirements that cannot hold together. **Done.**

The search itself was rewritten twice in the process, both times because measurement contradicted the design. Iterative deepening on the number left out was replaced by branch and bound, because deepening finds *nothing* until it reaches the correct round and so returned an error where it could have returned most of a conference. A relaxation bound — the largest set of non-overlapping candidates each resource could hold — then let it stop as soon as a layout matches, which made being *further* overbooked cheaper rather than dearer.

**Phase 4b — holds.** `hold/3`, `confirm/2`, `expire/2`. **Done**, and contrary to the capability review, which had deferred this to the adapter. Availability is derived from the ledger on every call, so a hold the ledger cannot see is a hold nobody subtracts. `expire/2` takes the moment as an argument rather than the library reading a clock — see the review's post-mortem.

**Phase 4c — soft constraints and the solver hand-off.** `Preference` with `:room_changes`, `:room_spread` and custom counters, optimised lexicographically in two passes so a preference can never cost a placement. `Agenda.Fixpoint.solve/3` makes the "bring your own solver" line below executable against [fixpoint](https://hex.pm/packages/fixpoint). **Done.**

**Phase 5 — adapter.** `Matcher`, `Selector`/`Strategy`, `CostFn` over the place tree, then the attribute-and-place projection behaviour. Whether this lands as a separate `ash_scheduling_agenda` package or as an optional dependency contributed into `ash_scheduling` is Alembic's call and worth asking before building — the technical content is identical either way.

## Risks

* **The additive/exclusive distinction is easy to get wrong and silent when wrong.** An arrangement that sums seats across two rooms is not obviously broken until someone walks into the meeting. Property test: for any arrangement, every `:exclusive` requirement is satisfied by a single resource.

* **Default travel times will be wrong for real buildings.** A per-depth table is a guess, and a venue where two adjacent rooms are separated by a locked fire door will defeat it. The per-pair override must be a first-class part of the API from Phase 1, not an afterthought, and `travel_time/2` must be inspectable so a wrong answer is diagnosable.

* **Ledger diffs must be provably minimal and order-independent.** `rearrange` producing a spurious `release`+`allocate` for an unchanged resource loses it to a competing booking. Property test: `rearrange(ledger, session, same_arrangement)` yields only `:keep`, and `allocate` then `release` returns the original ledger.

* **Programme-scale search can blow up.** Tracks and travel prune hard, but a programme with many interchangeable rooms and a wide window can still explode. Needs an explicit candidate cap that *reports truncation* rather than silently returning the first N — a partial arrangement presented as complete is worse than a failure.

* **Explain quality decays silently.** Reasons are the feature; they are also the thing no test asserts unless one is written to. Every `Infeasible` constructor should be required to carry a reason, enforced by the type rather than by discipline.

* **Upstream coupling.** AshScheduling is pre-1.0, private, and its README already lags its own tree (Reservation → Claim). Phase 5 should not start until its P2/P3 land, and per the standing rule, gaps found in it get reported upstream rather than worked around here.

## Definition of done

Phase 0 meets Tempo's six gates on the mise-current toolchain and is the only phase that touches this repository. Phases 1–5 are the `agenda` repository with the same six gates plus one addition specific to this library: **every example in the README, guides, and moduledocs must pass the read-aloud test** — the prose translation is written first and the code made to match it, per this project's documentation standard. An example that cannot be said in a sentence a product manager would recognise means a predicate is missing, and the predicate gets added before the example ships.

## Open questions

* **Packaging of the adapter** — separate package, or contributed upstream into `ash_scheduling` as an optional dependency? Worth asking Alembic before Phase 5.

* ~~**The default travel table**~~ — **settled.** Zero for the same place, five and ten minutes for one and two levels apart, twenty for anything deeper, and `{:error, :unknown}` for unrelated roots. The safer half of the original suggestion won: unrelated places are never guessed at, and any specific pair can be overridden with `:between`.

* ~~**Whether resource availability belongs here at all**~~ — **settled, and the argument for keeping it got stronger.** `open/2` takes a Tempo value, an ISO 8601 string, an RFC 5545 `RRULE`, or — via `from_ical/1` — an RFC 7953 `VAVAILABILITY` document, which is what a CalDAV server returns when asked when someone is free. Had a resource merely carried a caller-supplied value, every consumer would have rebuilt that import. The import stays unmaterialised until a query window is known, so `PRIORITY` and each recurrence resolve against the dates actually asked about.
