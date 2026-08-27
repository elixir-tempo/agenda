# Case study: ElixirConf US 2025

The other case studies invent their data. This one does not: it is the real programme of [ElixirConf US 2025](https://elixirconf.com/archives/elixirconf_2025/index.html) — 42 talks, three rooms, two days at the Renaissance Orlando at SeaWorld — handed to `arrange/3` to lay out from scratch.

The point is not to reproduce the published grid. It is that a real programme has a constraint an invented one usually misses, and it only shows up when you use real people.

The excerpts below show the shape rather than all forty-two talks. The complete programme, runnable cell by cell, is the [Melbourne livebook](https://github.com/elixir-tempo/agenda/blob/main/livebook/elixir_melbourne_september_2026.livemd).

## What the conference actually was

Thursday 28 and Friday 29 August 2025. Three parallel rooms — **Peninsula 4-7**, **Canaveral** and **Biscayne** — with Peninsula 1-3 used for registration, coffee, lunch and the reception rather than for talks. Sessions ran 20 or 40 minutes. Each day opened with a keynote in Peninsula 4-7 and closed there too.

Talks did not run continuously. Thursday's ran 10:45–12:45, then 13:45–15:05 after lunch, then 15:35–16:05 after the afternoon coffee break. That shape is the *first* thing to model, and it is a set rather than a range:

```elixir
talk_hours =
  Tempo.IntervalSet.new!([
    ~o"2025-08-28T10:45:00/2025-08-28T12:45:00",
    ~o"2025-08-28T13:45:00/2025-08-28T15:05:00",
    ~o"2025-08-28T15:35:00/2025-08-28T16:05:00",
    ~o"2025-08-29T10:40:00/2025-08-29T12:40:00",
    ~o"2025-08-29T13:40:00/2025-08-29T15:20:00",
    ~o"2025-08-29T15:50:00/2025-08-29T16:20:00"
  ])
```

The breaks are not constraints to be enforced. They are simply time the rooms are not open, and everything downstream inherits that for free.

Peninsula 4-7 is also the plenary room, so it opens earlier and closes later than the other two:

```elixir
plenary_hours =
  Tempo.IntervalSet.new!([
    ~o"2025-08-28T09:00/T10:15",
    ~o"2025-08-28T10:45/T12:45",
    ~o"2025-08-28T13:45/T15:05",
    ~o"2025-08-28T15:35/T17:50",
    ~o"2025-08-29T09:00/T10:10",
    ~o"2025-08-29T10:40/T12:40",
    ~o"2025-08-29T13:40/T15:20",
    ~o"2025-08-29T15:50/T17:30"
  ])
```

```elixir
venue = Agenda.place("Renaissance Orlando at SeaWorld")

peninsula = Agenda.resource("Peninsula 4-7", within: venue, seats: 700) |> Agenda.open!(plenary_hours)
canaveral = Agenda.resource("Canaveral", within: venue, seats: 250) |> Agenda.open!(talk_hours)
biscayne  = Agenda.resource("Biscayne", within: venue, seats: 250) |> Agenda.open!(talk_hours)
```

## The constraint invented data misses

**Speakers are resources.** Not attributes of a talk, not metadata — resources, exactly like rooms, with the same default concurrency of one.

```elixir
speaker = fn name ->
  Agenda.resource(name, role: :speaker) |> Agenda.open!(plenary_hours)
end

allison = speaker.("Allison Randal")
anna = speaker.("Anna Sherman")
savannah = speaker.("Savannah Manning")
lorena = speaker.("Lorena Mireles")
```

That single decision is what makes the rest work, and the reason is visible in the real programme. Allison Randal gave Thursday's opening keynote, *Open Source Resilience*, at 09:15 — and also appeared on the *Building Careers, Balancing Life* panel later that morning. Anna Sherman was on that same panel on Thursday and gave *From Bulbasaur to Venusaur* on Friday. Four people shared the panel between them.

A scheduler that treats a speaker as a label on a talk cannot see any of this. A scheduler that treats them as a resource cannot miss it, because a resource in two places at once is the constraint it already enforces.

A talk therefore names its room by description and its speakers by name:

```elixir
Agenda.session("Building Careers, Balancing Life", duration: "PT40M", window: "2025-08-28/2025-08-29")
|> Agenda.Session.needs(:room, seats: at_least(250))
|> Agenda.Session.roster(:speaker, [savannah, anna, allison, lorena])
```

`needs/3` describes — any room seating 250 will do, and the planner chooses. `roster/3` names — these four people, no substitutes. Both kinds of requirement bind the same way once the search starts.

> **One roster call per role.** `roster(:speaker, [a, b, c])` binds all three. Calling `roster(:speaker, [a])` three times does *not* accumulate — the last call wins and the earlier speakers are silently dropped, which is a mistake that costs you exactly the constraint this case study is about.

## The keynotes are already announced

Keynotes are published months ahead. They are not decisions left to the scheduler, they are fixed points it has to work around — and a pin is an ordinary arrangement, so the way to build one is to plan the session against the slot it was announced for and keep the answer:

```elixir
session =
  Agenda.session("Keynote: Open Source Resilience",
    duration: "PT60M",
    window: "2025-08-28T09:15:00/2025-08-28T10:15:00")
  |> Agenda.Session.roster(:room, [peninsula])
  |> Agenda.Session.roster(:speaker, [allison])

{:ok, [pin | _rest]} = Agenda.plan(session, rooms ++ speakers)
```

A pinned session must still be **in** the programme. Pinning fixes where a session goes; it does not smuggle one in from outside, and passing a pin for a session the programme does not contain is refused rather than quietly accepted:

```elixir
#=> {:error, %Agenda.Infeasible{reasons: ["Keynote: Open Source Resilience is pinned but is not in the programme"]}}
```

## Laying it out

```elixir
{:ok, arrangements} = Agenda.arrange(programme, rooms ++ speakers, pinned: pinned)

length(arrangements)
#=> 46
```

Forty-two talks and four plenaries, against three rooms and forty-five speakers, in about **175 ms** — five consecutive runs measured 171, 172, 174, 175 and 180. Thursday morning comes out as:

```
9H15M0S    Peninsula 4-7  Keynote: Open Source Resilience
10H45M0S   Peninsula 4-7  The Architecture Behind Deploying Livebook Apps with Livebook Teams
10H45M0S   Canaveral      From Complexity to Clarity: Managing Distributed Recorder Workers
10H45M0S   Biscayne       Building Careers, Balancing Life
11H25M0S   Peninsula 4-7  Extending Elixir with WebAssembly Components
11H25M0S   Canaveral      Starting a business on Phoenix LiveView and Event Sourcing in 2025
11H25M0S   Biscayne       Engineering Network Protocol Clients
```

And the constraint that mattered held:

```
Allison Randal — 2 sessions, none overlapping:
  2025Y8M28DT9H15M0S   Peninsula 4-7  Keynote: Open Source Resilience
  2025Y8M28DT10H45M0S  Biscayne       Building Careers, Balancing Life

Anna Sherman — 2 sessions, none overlapping:
  2025Y8M28DT10H45M0S  Biscayne       Building Careers, Balancing Life
  2025Y8M29DT14H40M0S  Biscayne       From Bulbasaur to Venusaur
```

Nobody wrote a rule saying Allison Randal cannot be on the panel during her own keynote. It follows from her being a resource with a concurrency of one, and it would have followed just as automatically for a room, a projector or a customer site.

## What happens when it cannot hold

Force the panel into the keynote slot and the programme stops being satisfiable:

```elixir
Agenda.session("Building Careers, Balancing Life",
  duration: "PT40M",
  window: "2025-08-28T09:15:00/2025-08-28T09:55:00")
```

```elixir
{:error, reason} = Agenda.arrange(forced, pool, pinned: pinned)

Agenda.explain(reason)
#=> "Building Careers, Balancing Life cannot be held: no window is long enough with everyone free"
```

*Everyone free* is the operative phrase. The room is free at 09:15 — Canaveral and Biscayne are both empty — and the session still cannot be held, because one of the four people it names is on stage in Peninsula 4-7. When several sessions are in tension rather than one, `conflict/3` names the minimal set.

## Two honest notes

**The layout is denser than the real one.** Agenda placed talks at 10:45, 11:25 and 12:05; the published programme used 10:45, 11:35 and 12:25. The extra ten minutes is changeover — one speaker unplugging while the next sets up — and Agenda does not invent it, because nothing here asked for it.

Saying so is `buffer_after` on the room:

```elixir
Agenda.resource("Canaveral", within: venue, seats: 250, buffer_after: "PT10M")
```

That is turnaround the room genuinely needs, so it holds against every other claim — a session already booked, or another talk in the same programme — and candidate start times shift to match: four 40-minute talks in a room wanting ten minutes fall at 9:00, 9:50, 10:40 and 11:30 rather than being packed end to end.

It is deliberately *not* used above, and the reason is worth knowing. The window this case study models — 10:45 to 12:45 — was taken from the published grid, which already spends those ten minutes: 40 + 10, 40 + 10, 20 fills it exactly. Declaring the turnaround as well asks for it twice, and the programme stops fitting. Model the changeover **or** carve it out of the hours, not both.

**Two days is not two problems.** Sessions that cannot constrain each other are solved separately and concurrently, and at first glance a two-day conference should split cleanly down the middle. This one does not, and the reason is Anna Sherman: she speaks on Thursday *and* Friday, so she links the days into a single component. That is worth knowing before assuming a long conference will decompose — one shared speaker, one shared room, or one precedence is enough to join two halves that otherwise have nothing to do with each other.

## Where this leaves you

The whole programme is about sixty lines of description: an interval set for the hours, three rooms, forty-five speakers, forty-two talks naming what they need, and four pins. Nothing in it is scheduling logic. The clash rules, the availability arithmetic across breaks, and the search that reconciles them are the library's, and the part you write is the part only you know — which talk needs whom.
