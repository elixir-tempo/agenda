# Getting started

Timetable answers *what should I book, and where?* It is built on [Tempo](https://hexdocs.pm/ex_tempo), which answers *when is this free?* This guide assumes you know neither.

## Installation

```elixir
def deps do
  [
    {:timetable, "~> 0.1"}
  ]
end
```

## The one Tempo idea you need

Tempo treats **every date and time as a bounded interval, never an instant.** A day is not a point; it is the span from one midnight to the next:

```elixir
Tempo.to_interval!(~o"2027-03-02")
#=> from 2027-03-02, to 2027-03-03

Tempo.to_interval!(~o"2027-03")
#=> from 2027-03, to 2027-04
```

A value's span is one unit of its finest *stated* field, so `~o"2027-03"` is the whole of March. Two consequences matter here:

* **Every interval is half-open** — `[from, to)`, including the start and excluding the end. Adjacent bookings therefore join cleanly with no overlap and no gap: `[9am, 10am)` followed by `[10am, 11am)` is exactly `[9am, 11am)`.

* **Free time is set algebra.** Free is open minus busy; mutual free time is the intersection of everyone's. Timetable does not reimplement any of that — it delegates to Tempo, which is calendar-, timezone-, and DST-correct in ways nothing hand-rolled will be.

The `~o` sigil parses ISO 8601 at compile time. For strings that arrive at runtime, `Tempo.from_iso8601/1` returns `{:ok, value}` or a precise error. Timetable's own functions accept either, plus RFC 5545 `RRULE` strings, so you rarely need to convert anything yourself.

## Five nouns

* **Resource** — a named thing that can be allocated. A room, a person, a projector, a customer site. People and rooms are the same kind of thing; only their attributes differ.

* **Place** — a container of resources and other places, forming a tree. Travel between resources is *derived* from the tree rather than configured.

* **Session** — the thing being scheduled: how long it runs, the window it must fall inside, and what it requires.

* **Arrangement** — one candidate way to hold a session: a time, and a resource for every role.

* **Allocation** — one resource bound to one session over one interval. The **ledger** is the set of them.

## Five minutes, end to end

Describe a room by what it has:

```elixir
{:ok, room} =
  Timetable.resource("Room 1", seats: 6, video_conferencing: true)
  |> Timetable.open("2027-03-02T09:00:00/2027-03-02T12:00:00")
```

Attributes are whatever your world actually has — `seats` and `video_conferencing` are just names, and nothing needs registering.

Describe what you want:

```elixir
import Timetable.Predicate

review =
  Timetable.session("Sprint review", lasting: ~o"PT1H", between: ~o"2027-03-02/2027-03-03")
  |> Timetable.Session.needs(:room, seats: at_least(4), video_conferencing: true)
```

> *"The sprint review runs for an hour on the 2nd, and needs a room seating at least four with video conferencing."*

Ask:

```elixir
{:ok, options} = Timetable.plan(review, [room])

length(options)
#=> 3

Timetable.explain(hd(options))
#=> "2027Y3M2DT9H0M0S/2027Y3M2DT10H0M0S — room: Room 1"
```

Three one-hour windows in a three-hour morning. Commit one:

```elixir
{:ok, ledger} = Timetable.allocate(Timetable.ledger(), hd(options))
Timetable.count(ledger)
#=> 1
```

And the next plan sees it:

```elixir
{:ok, remaining} = Timetable.plan(review, [room], busy: Timetable.busy(ledger))
length(remaining)
#=> 2
```

Cancelling puts it back, with no bookkeeping:

```elixir
{:ok, ledger} = Timetable.release(ledger, "Sprint review")
{:ok, restored} = Timetable.plan(review, [room], busy: Timetable.busy(ledger))
length(restored)
#=> 3
```

That is the whole loop: **describe, plan, allocate, release.** Free time is derived on every call rather than stored, so there is no free/busy record to go stale and no release step that can be forgotten.

## Failures are sentences

The feature that saves the most time in practice. A resource that does not qualify says why:

```elixir
booth = Timetable.resource("Phone booth", seats: 1)

Timetable.explain(Timetable.needs(:room, seats: at_least(4), video_conferencing: true), booth)
#=> "Phone booth: seats is 1 — needs at least 4; no video_conferencing — needs true"
```

Both reasons, not the first. And when nothing works at all:

```elixir
{:error, reason} = Timetable.plan(review, [booth])

Timetable.explain(reason)
#=> "Sprint review cannot be held: nothing satisfies room: Phone booth (seats is 1 —
#=>  needs at least 4, no video_conferencing — needs true)"
```

Not "no availability" — the room, and what was wrong with it. Eligibility and its explanation are computed together, so the reason can never drift out of step with the answer.

## Free time directly

You do not have to go through `plan/3`. When you just want the gaps:

```elixir
{:ok, free} =
  Timetable.free(room,
    within: "2027-03-02/2027-03-03",
    busy: "2027-03-02T10:00:00/2027-03-02T11:00:00")

free |> Tempo.IntervalSet.to_list() |> Enum.map(&Tempo.to_iso8601/1)
#=> ["2027Y3M2DT9H0M0S/2027Y3M2DT10H0M0S", "2027Y3M2DT11H0M0S/2027Y3M2DT12H0M0S"]
```

> *"The room is open nine to twelve and busy from ten to eleven, so it is free either side."*

## The predicate vocabulary

Requirements are written with these, and they deliberately mirror Tempo's own duration predicates so there is one set of words rather than two:

| Predicate | Means |
| --- | --- |
| `at_least(8)` | the attribute is 8 or more |
| `at_most(4)` | 4 or fewer |
| `exactly(:sydney)` | equal to this — a bare value is sugar for it |
| `any_of([:a, :b])` | one of these |
| `all_of([:a, :b])` | the attribute is a list containing all of these |
| `none_of([:x])` | none of these |

Two habits worth forming early:

* **`needs/3` describes, `roster/3` names.** Use `needs` when any qualifying resource will do and let the planner choose; use `roster` when the choice is already made — these three people, that customer's office.

* **Put a person's access needs on the person.** `Timetable.resource("Priya", requires: [step_free_access: true])` turns "somebody must remember" into "the room is not eligible". The requirement travels with them into every session they join.

## Two words that are not what you expect

* **`seats` is not concurrency.** `seats` is an ordinary attribute you invented; `concurrency` is how many sessions may hold the resource at once, and it defaults to `1`. A twenty-seat training room still holds one meeting at a time. Conflating them is what lets a lecture theatre accept two simultaneous lectures.

* **A place is a tree, not a label.** `within:` takes a place, and travel time is computed from how far apart two resources sit in it. A flat `location: :sydney` attribute can answer *"is this room in Sydney?"* but not *"can someone get from here to there in the break?"* — and only the second question decides whether a schedule is workable.

## Where to go next

Three worked case studies, each end to end, with every value in them executed rather than illustrated:

* **[Consultants on customer sites](case-study-consultants.md)** — an IT services business. Skills matching with `all_of`, customer sites modelled as resources, travel between jobs, and why a consultant's day is a track. Read this one if your resources move.

* **[Meeting rooms and AV equipment](case-study-meeting-rooms.md)** — a larger business. Booking a room *and* a projector as one unit, accessibility that cannot be forgotten, and moving a meeting without losing the room. Read this one first if you are scheduling a building.

* **[ElixirConf 2027](case-study-conference.md)** — two days, keynotes, parallel tracks. Where planning becomes searching, and where the search stops. Read this one if you are laying out many sessions at once rather than booking them one at a time.

## Knowing when to stop

`plan/3` enumerates the ways one session could be held. `arrange/3` searches for a consistent layout across many. Both are exact, and both are bounded by caps that *report* when they are hit rather than returning a partial answer as though it were complete.

A conference of a few dozen sessions across a handful of rooms is comfortable. A university timetable of thousands of classes, or a month's roster for hundreds of staff minimising overtime, is not — that wants a purpose-built constraint solver. The way to use one here is to write its output back through `Timetable.allocate/2`: the ledger does not care who computed the answer, and everything downstream keeps working.
