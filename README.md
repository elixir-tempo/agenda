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

## Status

**Early development.** Phase 1 — the model and matching, with no time involved — is implemented: resources, attributes, the place tree, travel time, requirements, the predicate vocabulary, induced requirements, and explanations.

Availability and planning, the allocation ledger, tracks and programmes follow in later phases. The full design is in [the plan](https://github.com/elixir-tempo/timetable/blob/main/plans/tempo-timetable.md).

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
