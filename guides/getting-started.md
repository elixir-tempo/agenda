# Getting started

Agenda answers *what should I book, and where?* It is built on [Tempo](https://hexdocs.pm/ex_tempo), which answers *when is this free?* This guide assumes you know neither.

## Installation

<!-- guide-test: skip -->
```elixir
def deps do
  [
    {:agenda, "~> 0.1"}
  ]
end
```

## The one Tempo idea you need

Tempo treats **every date and time as a bounded interval, never an instant.** A day is not a point; it is the span from one midnight to the next:

```elixir
Tempo.to_interval!(~o"2027-03-02") |> Tempo.to_iso8601()
#=> "2027Y3M2D/3D"

Tempo.to_interval!(~o"2027-03") |> Tempo.to_iso8601()
#=> "2027Y3M/4M"
```

> *"The second of March is the span from the second to the third; March is the span from March to April."* An interval end drops whatever it shares with its start, so `/3D` is the third of the same month.

A value's span is one unit of its finest *stated* field, so `~o"2027-03"` is the whole of March. Two consequences matter here:

* **Every interval is half-open** — `[from, to)`, including the start and excluding the end. Adjacent bookings therefore join cleanly with no overlap and no gap: `[9am, 10am)` followed by `[10am, 11am)` is exactly `[9am, 11am)`.

* **Free time is set algebra.** Free is open minus busy; mutual free time is the intersection of everyone's. Agenda does not reimplement any of that — it delegates to Tempo, which is calendar-, timezone-, and DST-correct in ways nothing hand-rolled will be.

The `~o` sigil parses ISO 8601 at compile time. For strings that arrive at runtime, `Tempo.from_iso8601/1` returns `{:ok, value}` or a precise error. Agenda's own functions accept either, plus RFC 5545 `RRULE` strings, so you rarely need to convert anything yourself.

## Five nouns

* **Resource** — a named thing that can be allocated. A room, a person, a projector, a customer site. People and rooms are the same kind of thing; only their attributes differ.

* **Place** — a container of resources and other places, forming a tree. Travel between resources is *derived* from the tree rather than configured.

* **Session** — the thing being scheduled: how long it runs, the window it must fall inside, and what it requires. A meeting, a talk, a shift, a task.

* **Arrangement** — one candidate way to hold a session: a time, and a resource for every role.

* **Allocation** — one resource bound to one session over one interval. The **ledger** is the set of them.

## Five minutes, end to end

Describe a room by what it has:

```elixir
{:ok, room} =
  Agenda.resource("Room 1", seats: 6, video_conferencing: true)
  |> Agenda.open("2027-03-02T09:00:00/2027-03-02T12:00:00")
```

Attributes are whatever your world actually has — `seats` and `video_conferencing` are just names, and nothing needs registering.

Describe what you want:

```elixir
import Agenda.Predicate

review =
  Agenda.session("Sprint review", duration: ~o"PT1H", window: ~o"2027-03-02/2027-03-03")
  |> Agenda.Session.needs(:room, seats: at_least(4), video_conferencing: true)
```

> *"The sprint review runs for an hour on the 2nd, and needs a room seating at least four with video conferencing."*

Ask:

```elixir
{:ok, options} = Agenda.plan(review, [room])

length(options)
#=> 3

Agenda.explain(hd(options))
#=> "2027Y3M2DT9H0M0S/T10H0M0S — room: Room 1"
```

Three one-hour windows in a three-hour morning. Commit one:

```elixir
{:ok, ledger} = Agenda.allocate(Agenda.ledger(), hd(options))
Agenda.count(ledger)
#=> 1
```

And the next plan sees it:

```elixir
{:ok, remaining} = Agenda.plan(review, [room], busy: Agenda.busy(ledger))
length(remaining)
#=> 2
```

Cancelling puts it back, with no bookkeeping:

```elixir
{:ok, ledger} = Agenda.release(ledger, "Sprint review")
{:ok, restored} = Agenda.plan(review, [room], busy: Agenda.busy(ledger))
length(restored)
#=> 3
```

That is the whole loop: **describe, plan, allocate, release.** Free time is derived on every call rather than stored, so there is no free/busy record to go stale and no release step that can be forgotten.

## Failures are sentences

The feature that saves the most time in practice. A resource that does not qualify says why:

```elixir
booth = Agenda.resource("Phone booth", seats: 1)

Agenda.explain(Agenda.needs(:room, seats: at_least(4), video_conferencing: true), booth)
#=> "Phone booth: seats is 1 — needs at least 4; no video_conferencing — needs true"
```

Both reasons, not the first. And when nothing works at all:

```elixir
{:error, reason} = Agenda.plan(review, [booth])

Agenda.explain(reason)
#=> "Sprint review cannot be held: nothing satisfies room: Phone booth (seats is 1 —
#=>  needs at least 4, no video_conferencing — needs true)"
```

Not "no availability" — the room, and what was wrong with it. Eligibility and its explanation are computed together, so the reason can never drift out of step with the answer.

## Free time directly

You do not have to go through `plan/3`. When you just want the gaps:

```elixir
{:ok, free} =
  Agenda.free(room,
    within: "2027-03-02/2027-03-03",
    busy: "2027-03-02T10:00:00/2027-03-02T11:00:00")

Tempo.IntervalSet.members(free)
#=> [~o"2027Y3M2DT9H0M0S/T10H0M0S", ~o"2027Y3M2DT11H0M0S/T12H0M0S"]
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

* **`needs/3` describes, `roster/3` names.** Use `needs` when any qualifying resource will do and let the planner choose; use `roster` when the choice is already made — these three people, that customer's office. When the names arrive as strings, `Agenda.Resource.fetch_all/2` turns them into resources all-or-nothing, so a typo fails the call instead of quietly handing `roster` a shorter list.

* **Put a person's access needs on the person.** `Agenda.resource("Priya", requires: [step_free_access: true])` turns "somebody must remember" into "the room is not eligible". The requirement travels with them into every session they join.

## Two words that are not what you expect

* **`seats` is not concurrency.** `seats` is an ordinary attribute you invented; `concurrency` is how many sessions may hold the resource at once, and it defaults to `1`. A twenty-seat training room still holds one meeting at a time. Conflating them is what lets a lecture theatre accept two simultaneous lectures.

* **A place is a tree, not a label.** `within:` takes a place, and travel time is computed from how far apart two resources sit in it. A flat `location: :sydney` attribute can answer *"is this room in Sydney?"* but not *"can someone get from here to there in the break?"* — and only the second question decides whether a schedule is workable.

## Where to go next

Three worked case studies, each end to end, with every value in them executed rather than illustrated:

* **[Consultants on customer sites](case-study-consultants.md)** — an IT services business. Skills matching with `all_of`, customer sites modelled as resources, travel between jobs, and why a consultant's day is a track. Read this one if your resources move.

* **[Meeting rooms and AV equipment](case-study-meeting-rooms.md)** — a larger business. Booking a room *and* a projector as one unit, accessibility that cannot be forgotten, and moving a meeting without losing the room. Read this one first if you are scheduling a building.

* **[ElixirConf US 2025](case-study-elixirconf.md)** — a real conference programme, laid out from scratch. Speakers as resources, announced keynotes as pins, and what happens when one person is booked against themselves. Read this one if your sessions involve people who appear more than once.

* **[ElixirConf 2027](case-study-conference.md)** — two days, keynotes, parallel tracks. Where planning becomes searching, and where the search stops. Read this one if you are laying out many sessions at once rather than booking them one at a time.

## Open hours you already have

Availability usually exists somewhere before it exists in your code. `from_ical/1` reads an RFC 7953 `VAVAILABILITY` — what a CalDAV server returns when asked when someone is free — into a pattern `open/2` accepts:

```elixir
vavailability = """
BEGIN:VCALENDAR
BEGIN:VAVAILABILITY
UID:clinic
DTSTAMP:20260601T000000Z
BEGIN:AVAILABLE
UID:clinic-available
DTSTAMP:20260601T000000Z
DTSTART:20260601T090000Z
DTEND:20260601T170000Z
RRULE:FREQ=DAILY;COUNT=5
END:AVAILABLE
END:VAVAILABILITY
END:VCALENDAR
"""

{:ok, hours} = Agenda.from_ical(vavailability)
clinic = Agenda.open!(Agenda.resource("Clinic"), hours)

{:ok, week} = Agenda.free(clinic, within: ~o"2026-06-01/2026-06-08")
length(Tempo.IntervalSet.members(week))
#=> 5
```

It stays unmaterialised until you ask about a window, so a recurring `AVAILABLE` and `PRIORITY` across overlapping components resolve against the dates you actually query. `VEVENT`s in the same document are ignored — those are time *taken*, and belong in `free/2`'s `:busy`. Needs the optional `ical` dependency.

## Three constraints beyond "does it fit"

The examples from here on need a second room and a small programme, so
that each runs as it stands:

```elixir
room_2 =
  Agenda.resource("Room 2", seats: 6, video_conferencing: true)
  |> Agenda.open!(~o"2027-03-02T09:00:00/2027-03-02T12:00:00")

rooms = [room, room_2]

survey = Agenda.session("Survey", duration: ~o"PT1H", window: ~o"2027-03-02/2027-03-03")
installation = Agenda.session("Installation", duration: ~o"PT1H", window: ~o"2027-03-02/2027-03-03")

programme =
  Agenda.programme("Field work")
  |> Agenda.Programme.add_session(survey)
  |> Agenda.Programme.add_session(installation)

friday_afternoons = ~o"2027-03-05T13:00:00/2027-03-05T17:00:00"
```

Each answers a different question, and picking the wrong one is the commonest modelling mistake:

```elixir
# Order — the installation follows the survey, an hour later at least.
{:ok, programme} = Agenda.precede(programme, "Survey", "Installation", gap: "PT1H")

# A contract — at most three jobs a day, twelve a week.
Agenda.resource("Dana", limits: [day: 3, week: 12])

# A wish — Priya would rather not, but could.
Agenda.resource("Priya", avoids: friday_afternoons)
```

A **limit is not concurrency**: concurrency is how many claims may overlap at one instant, a limit is how many fall inside a stretch of calendar however far apart. And a **wish is not an absence**: `avoids` makes a placement worse, `open/2` makes it impossible — writing a preference as unavailability takes the option away from everyone.

## Holding something before you book it

A booking page needs to take a room tentatively while somebody decides. A hold occupies the resource exactly as a booking does:

```elixir
{:ok, [arrangement | _rest]} = Agenda.plan(review, [room])

{:ok, ledger} = Agenda.hold(Agenda.ledger(), arrangement, until: "2027-03-01T09:05:00")
{:ok, ledger} = Agenda.confirm(ledger, "Sprint review")
```

Nothing expires on its own — `Agenda.expire(ledger, now)` takes the moment as an argument rather than reading a clock, so planning the same session twice always gives the same answer. That matters more than the convenience it costs: `busy/2` runs inside `plan/3` and `arrange/3`, and a ledger that shifts underneath them is one you cannot test.

## Preferring one workable answer to another

Everything above is hard — a layout is valid or it is not. Several are usually valid, and a preference chooses among them without ever making one invalid:

```elixir
{:ok, programme} = Agenda.prefer(programme, :room_changes, weight: 10)
```

`:room_changes` and `:room_spread` are built in; your own is a name and a function. Preferences count violations, so zero is ideal. Crucially **a preference can never cost you a session** — the number placed is settled and proven first, and only then is a better-scoring layout preferred among those placing just as many.

## When the answer is "no"

Three separate questions hide inside a failed schedule, and each has its own verb:

* **"Book what fits."** `arrange/3` with `unplaced: :allow` leaves out as few sessions as it can and returns `{:partial, layout}` — never `{:ok, …}`, so an incomplete programme cannot be mistaken for a finished one.

* **"Do not move what is announced."** `:pinned` fixes chosen placements and searches around them, with every constraint still applying to the pins.

* **"Which of these is actually fighting?"** `conflict/3` returns a *minimal* set — remove any one member and the rest fit. It works on a programme (which sessions cannot co-exist) and on a single session (which demands are impossible together, including those a rostered person induced).

The conference case study works all three end to end.

## Knowing when to stop

`plan/3` enumerates the ways one session could be held. `arrange/3` searches for a consistent layout across many. Both are exact, and both are bounded by caps that *report* when they are hit rather than returning a partial answer as though it were complete.

Scale depends on the shape of the programme more than its size, because sessions that cannot interact are solved separately and at the same time: 1,200 sessions across twenty days lay out in under three seconds, while 200 all competing for a single day take about five. A university timetable of thousands of classes, or a month's roster for hundreds of staff minimising overtime, is not — that wants a purpose-built constraint solver. The way to use one here is to write its output back through `Agenda.allocate/2`: the ledger does not care who computed the answer, and everything downstream keeps working.

With the optional [fixpoint](https://hex.pm/packages/fixpoint) dependency that hand-off is already written:

```elixir
{:ok, arrangements} = Agenda.Fixpoint.solve(programme, rooms)
```

The solver is only asked to *choose*. Eligibility, induced requirements, availability and the place tree all stay here, where they are explained — the model handed over is which of each session's candidate placements to take, and the answer comes back as ordinary arrangements the ledger accepts. It covers the all-or-nothing question for exclusive resources; partial layouts, preferences and concurrency above one stay with `arrange/3`.
