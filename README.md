# Timetable

Resource-constrained scheduling for [Tempo](https://github.com/elixir-tempo/tempo).

Tempo answers *when is this free?* Timetable answers *what should I book, and where?* It adds the named resources, the attributes describing them, the places containing them, and the requirements a session places on them — so that a scheduling question can be asked the way a person would ask it.

```elixir
import Timetable.Predicate

boardroom = Timetable.resource("Boardroom", within: level_2, seats: 8, video_conferencing: true)
alice     = Timetable.resource("Alice", requires: [step_free_access: true])

needs_a_room = Timetable.needs(:room, seats: at_least(8), video_conferencing: true)

Timetable.eligible(needs_a_room, rooms)
```

> *"Which rooms seat at least eight and have video conferencing?"*

## Why

Every scheduling system rebuilds the same three things above the calendar: a map of resources, hand-rolled filters over its keys, and a hard-coded travel matrix. None of it is what makes the product interesting, and getting it wrong produces meetings nobody can attend.

Two ideas do most of the work.

**A failed match is a sentence, not a `false`.** Eligibility and its explanation are computed together, so the reason a room does not qualify is always available:

```elixir
Timetable.explain(needs_a_room, meeting_room_2)
#=> "Meeting room 2: seats is 4 — needs at least 8"
```

**A person's needs bind the room.** `step_free_access: true` on Alice is not a fact about her availability — it is a constraint she places on wherever she is booked. Folding her requirements into the room requirement means accessibility cannot be forgotten at the call site:

```elixir
needs_a_room
|> Timetable.Requirement.induce([alice])
|> Timetable.explain(attic)
#=> "Attic: no step_free_access — needs true"
```

> *"The attic is out because Alice cannot get into it."*

## Places are a tree, so travel is derived

A place contains resources and other places, to whatever depth suits — campus, building, floor, wing. The library never interprets what a level means, only how the levels nest. Travel time then falls out of the structure rather than being configured:

```elixir
Timetable.travel_time(boardroom, upstairs)
#=> {:ok, ~o"PT5M"}

Timetable.travel_time(boardroom, main_stage)
#=> {:error, :unknown}
```

> *"Getting upstairs takes five minutes; nothing can be said about getting to the other venue until someone measures it."*

Unrelated places return `{:error, :unknown}` rather than a guess, and any specific pair can be overridden where the building disagrees with the geometry:

```elixir
Timetable.travel_time(boardroom, main_stage, between: [{{"Boardroom", "Main Stage"}, ~o"PT25M"}])
#=> {:ok, ~o"PT25M"}
```

This is what a flat `location: :sydney` attribute cannot do. It can answer *"is this room in Sydney?"*, but not *"can a delegate get from here to there in the ten-minute break?"* — and only the second question decides whether a programme is workable.

## Guides

New to Tempo or to this library? Start with **[Getting started](https://hexdocs.pm/timetable/getting-started.html)** — the one Tempo idea you need, the five nouns, and the whole describe-plan-allocate-release loop in five minutes.

Then three worked problems, each end to end with executed output:

* [Consultants on customer sites](https://hexdocs.pm/timetable/case-study-consultants.html) — an IT services business. Skills matching, customer sites as resources, travel between jobs, and why a consultant's day is a track.

* [Meeting rooms and AV equipment](https://hexdocs.pm/timetable/case-study-meeting-rooms.html) — a larger business. Room attributes, booking a room *and* a projector together, accessibility that cannot be forgotten, and moving a meeting without losing the room.

* [ElixirConf 2027](https://hexdocs.pm/timetable/case-study-conference.html) — two days, keynotes, and parallel tracks. Where planning becomes searching, and where the search stops.

## When not everything fits

Three things separate a scheduler you can ship from one that only works on the happy path, and all three are about failure.

**Place what you can.** By default an unplaceable session fails the whole programme, which is right when the programme is a unit and wrong when it is a wish list. `unplaced: :allow` leaves out as few sessions as the search can manage — and says so, under a tag that cannot be mistaken for success:

```elixir
case Timetable.arrange(programme, rooms, unplaced: :allow) do
  {:ok, arrangements} -> publish(arrangements)
  {:partial, layout}  -> review(layout.placed, layout.unplaced)
  {:error, reason}    -> abandon(reason)
end
```

**Hold the announced sessions still.** A published programme gets edited, and the keynote must not move. `:pinned` fixes chosen placements and searches around them, with every constraint still applying to the pins:

```elixir
Timetable.arrange(programme, rooms, pinned: already_announced)
```

**Say which sessions are actually in tension.** "No arrangement found" is a dead end. `conflict/3` returns a *minimal* set — remove any one member and the rest fit:

```elixir
Timetable.conflict(programme, rooms)
#=> {:ok, ["Keynote", "Workshop", "Panel"]}
```

> *"Any two of these three fit. Choose which one moves."*

It works on a single session too, naming the demands that are impossible *together* — including the ones a person induced rather than the session asking for them:

```elixir
Timetable.conflict(session, rooms)
#=> {:ok, [needs: {:room, :video_conferencing}, requires: {"Alice", :step_free_access}]}
```

## Holding a room while someone finds their card

A booking page needs to take a room *tentatively*. A hold occupies the resource exactly as a booking does — which is why it lives in the ledger rather than in a persistence layer: availability is derived on every call, so a hold nobody can see is a hold nobody subtracts.

```elixir
{:ok, ledger} = Timetable.hold(ledger, arrangement, until: "2026-06-15T10:15:00")
{:ok, ledger} = Timetable.confirm(ledger, "Review")
```

**Nothing expires on its own.** `expire/2` takes the moment as an argument rather than reading a clock:

```elixir
{:ok, ledger} = Timetable.expire(ledger, now)
```

That is deliberate. `busy/2` is called inside `plan/3` and `arrange/3`; if it consulted the system clock, arranging the same programme twice would give different answers as holds lapsed underneath it. Refusing to guess the time is the same discipline as refusing to guess an unmeasured journey.

The rest of the claim lifecycle — completed, cancelled, no-show — is deliberately *not* here. A hold changes what is available; a no-show does not. That line is what separates the engine's business from the adapter's.

## Preferring one workable layout over another

Every constraint above is hard. A preference is soft: it never makes a layout invalid, only worse.

```elixir
{:ok, programme} = Timetable.prefer(programme, :room_changes, weight: 10)
{:ok, programme} = Timetable.prefer(programme, :room_spread, weight: 3)

Timetable.explain_score(arrangements, programme)
#=> ["room_changes: 0 × 10 = 0", "room_spread: 0 × 3 = 0"]
```

Preferences count *violations*, so zero is ideal — a number that means something on its own, where a reward total only means something next to another reward total.

Optimisation is **lexicographic and two-pass**, and that is the whole design. The first pass ignores preferences and *proves* how many sessions can be placed. The second takes that number as a hard ceiling and looks only for a better-scoring layout placing exactly as many. So a preference can never cost you a session, `minimal?` still means proven, and the new `score_proven?` says whether the scoring pass finished or ran out of its own budget.

What is not promised is soft *optimality*. Proving a weighted optimum needs a bound on remaining cost that this search has no cheap way to compute — and a programme that genuinely needs one wants a solver, which is the next section.

## Handing it to a solver

Past a few dozen sessions the exact search runs out of road. The answer has always been "use a solver, then write the result back through `allocate/2`" — and with the optional [fixpoint](https://hex.pm/packages/fixpoint) dependency that sentence is executable:

```elixir
{:ok, arrangements} = Timetable.Fixpoint.solve(programme, rooms)
```

Nothing about the model changes. Each session already has a finite list of candidate placements that satisfy its requirements, so the solver's variable is *which candidate* — eligibility, induced requirements, availability and the place tree all stay on this side of the boundary, where they are explained. The solver never learns what a room is. Conflicts come from `Timetable.Arranger.conflict?/4`, the same predicate the built-in search uses, so the two cannot disagree about what a clash is.

It answers the all-or-nothing question only, for exclusive resources. Concurrency above one is refused rather than mis-solved: capacity is not a pairwise property, and fixpoint has no cumulative constraint to express it.

## Open hours from a calendar

Availability usually already exists somewhere. `from_ical/1` reads [RFC 7953](https://www.rfc-editor.org/rfc/rfc7953.html) `VAVAILABILITY` — what a CalDAV server hands you when asked when someone is free:

```elixir
{:ok, hours} = Timetable.from_ical(vavailability)
{:ok, clinic} = Timetable.open(Timetable.resource("Clinic"), hours)
```

`PRIORITY` across overlapping components and each `AVAILABLE` recurrence resolve against the window you actually ask about, not at import time. `VEVENT`s in the same document are ignored — those are time *taken*, and belong in `free/2`'s `:busy`.

Requires the optional `ical` dependency.

## Status

**Early development, but no longer only a model.** Implemented: resources, attributes, the place tree and derived travel, requirements and the predicate vocabulary, induced requirements, explanations, availability, single-session planning, the allocation ledger, holds, recurring series, tracks, whole-programme arrangement, partial arrangement, pinning, soft constraints, minimal conflict sets, RFC 7953 import, and the fixpoint solver bridge.

Still open: the rest of the claim lifecycle — completed, cancelled, no-show — which belongs with the persistence adapter, since none of those states changes what is available. The full design is in [the plan](https://github.com/elixir-tempo/timetable/blob/main/plans/tempo-timetable.md).

### Optional dependencies

* [`ical`](https://hex.pm/packages/ical) for RFC 7953 `VAVAILABILITY` import.

* [`fixpoint`](https://hex.pm/packages/fixpoint) for the solver bridge. It describes itself as a proof of concept, so treat that path accordingly.

## Installation

Not yet published to Hex. Until the first release:

```elixir
def deps do
  [
    {:timetable, github: "elixir-tempo/timetable"}
  ]
end
```

### Configure a timezone database

Elixir ships a UTC-only timezone database, and with it every zone resolves to UTC and daylight-saving arithmetic is **silently wrong** rather than failing — a London window across the spring-forward boundary measures an hour longer than it is. Any application doing zoned scheduling should configure a real IANA database:

```elixir
config :elixir, :time_zone_database, Tz.TimeZoneDatabase
```

with `{:tz, "~> 0.28"}` in your dependencies. Timetable does not choose one for you.

## License

Apache-2.0. See [LICENSE.md](LICENSE.md).
