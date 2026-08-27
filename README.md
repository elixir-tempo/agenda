# Agenda

Resource-constrained scheduling for [Tempo](https://github.com/elixir-tempo/tempo).

Tempo answers *when is this free?* Agenda answers *what should I book, and where?* It adds the named resources, the attributes describing them, the places containing them, and the requirements a session places on them — so that a scheduling question can be asked the way a person would ask it.

```elixir
import Agenda.Predicate

boardroom = Agenda.resource("Boardroom", within: level_2, seats: 8, video_conferencing: true)
alice     = Agenda.resource("Alice", requires: [step_free_access: true])

needs_a_room = Agenda.needs(:room, seats: at_least(8), video_conferencing: true)

Agenda.eligible(needs_a_room, rooms)
```

> *"Which rooms seat at least eight and have video conferencing?"*

## Why

Every scheduling system rebuilds the same three things above the calendar: a map of resources, hand-rolled filters over its keys, and a hard-coded travel matrix. None of it is what makes the product interesting, and getting it wrong produces meetings nobody can attend.

Two ideas do most of the work.

**A failed match is a sentence, not a `false`.** Eligibility and its explanation are computed together, so the reason a room does not qualify is always available:

```elixir
Agenda.explain(needs_a_room, meeting_room_2)
#=> "Meeting room 2: seats is 4 — needs at least 8"
```

**A person's needs bind the room.** `step_free_access: true` on Alice is not a fact about her availability — it is a constraint she places on wherever she is booked. Folding her requirements into the room requirement means accessibility cannot be forgotten at the call site:

```elixir
needs_a_room
|> Agenda.Requirement.induce([alice])
|> Agenda.explain(attic)
#=> "Attic: no step_free_access — needs true"
```

> *"The attic is out because Alice cannot get into it."*

## Places are a tree, so travel is derived

A place contains resources and other places, to whatever depth suits — campus, building, floor, wing. The library never interprets what a level means, only how the levels nest. Travel time then falls out of the structure rather than being configured:

```elixir
Agenda.travel_time(boardroom, upstairs)
#=> {:ok, ~o"PT5M"}

Agenda.travel_time(boardroom, main_stage)
#=> {:error, :unknown}
```

> *"Getting upstairs takes five minutes; nothing can be said about getting to the other venue until someone measures it."*

Unrelated places return `{:error, :unknown}` rather than a guess, and any specific pair can be overridden where the building disagrees with the geometry:

```elixir
Agenda.travel_time(boardroom, main_stage, between: [{{"Boardroom", "Main Stage"}, ~o"PT25M"}])
#=> {:ok, ~o"PT25M"}
```

This is what a flat `location: :sydney` attribute cannot do. It can answer *"is this room in Sydney?"*, but not *"can a delegate get from here to there in the ten-minute break?"* — and only the second question decides whether a programme is workable.

## Livebooks

Interactive and runnable — every cell executes live in [Livebook](https://livebook.dev):

* [![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Felixir-tempo%2Fagenda%2Fmain%2Flivebook%2Felixir_melbourne_september_2026.livemd) **Scheduling ElixirConf** — the real ElixirConf US 2025 programme laid out from scratch: 42 talks, three rooms, two days, and the constraint invented data misses.

* [![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fraw.githubusercontent.com%2Felixir-tempo%2Fagenda%2Fmain%2Flivebook%2Ftimesheets_and_leave.livemd) **Timesheets and leave** — recording work and absence against one ledger, and reconciling a period against the hours that were owed.

## Guides

New to Tempo or to this library? Start with **[Getting started](https://hexdocs.pm/agenda/getting-started.html)** — the one Tempo idea you need, the five nouns, and the whole describe-plan-allocate-release loop in five minutes.

Then three worked problems, each end to end with executed output:

* [Consultants on customer sites](https://hexdocs.pm/agenda/case-study-consultants.html) — an IT services business. Skills matching, customer sites as resources, travel between jobs, and why a consultant's day is a track.

* [Meeting rooms and AV equipment](https://hexdocs.pm/agenda/case-study-meeting-rooms.html) — a larger business. Room attributes, booking a room *and* a projector together, accessibility that cannot be forgotten, and moving a meeting without losing the room.

* [ElixirConf US 2025](https://hexdocs.pm/agenda/case-study-elixirconf.html) — the real programme: 42 talks, three rooms, two days, and the constraint invented data misses. Why a speaker is a resource, not a label.

* [ElixirConf 2027](https://hexdocs.pm/agenda/case-study-conference.html) — two days, keynotes, and parallel tracks. Where planning becomes searching, and where the search stops.

## When not everything fits

Three things separate a scheduler you can ship from one that only works on the happy path, and all three are about failure.

**Place what you can.** By default an unplaceable session fails the whole programme, which is right when the programme is a unit and wrong when it is a wish list. `unplaced: :allow` leaves out as few sessions as the search can manage — and says so, under a tag that cannot be mistaken for success:

```elixir
case Agenda.arrange(programme, rooms, unplaced: :allow) do
  {:ok, arrangements} -> publish(arrangements)
  {:partial, layout}  -> review(layout.placed, layout.unplaced)
  {:error, reason}    -> abandon(reason)
end
```

**Hold the announced sessions still.** A published programme gets edited, and the keynote must not move. `:pinned` fixes chosen placements and searches around them, with every constraint still applying to the pins:

```elixir
Agenda.arrange(programme, rooms, pinned: already_announced)
```

**Say which sessions are actually in tension.** "No arrangement found" is a dead end. `conflict/3` returns a *minimal* set — remove any one member and the rest fit:

```elixir
Agenda.conflict(programme, rooms)
#=> {:ok, ["Keynote", "Workshop", "Panel"]}
```

> *"Any two of these three fit. Choose which one moves."*

It works on a single session too, naming the demands that are impossible *together* — including the ones a person induced rather than the session asking for them:

```elixir
Agenda.conflict(session, rooms)
#=> {:ok, [needs: {:room, :video_conferencing}, requires: {"Alice", :step_free_access}]}
```

## Order, contracts, and what people would rather

Three constraints that turn meeting scheduling into task and shift scheduling. Each answers a different question, and reaching for the wrong one is the commonest modelling mistake.

**Order.** An installation cannot precede its survey. That is not a clash and not a track:

```elixir
{:ok, programme} = Agenda.precede(programme, "Survey", "Installation", gap: "PT1H")
```

`:within` caps the other end — `gap: "PT15M", within: "PT2H"` is what makes an interview loop a loop rather than two appointments a fortnight apart. Both are measured from the predecessor's *end*, so overrunning pushes the successor rather than eating its allowance. Because it relates exactly two sessions it is a pairwise constraint, so the solver bridge enforces it too.

**Contracts.** Eight open hours is not eight jobs:

```elixir
Agenda.resource("Dana", limits: [day: 3, week: 12])
Agenda.resource("Dana", limits: [day: ~o"PT7H36M", week: [at_least: ~o"PT38H"]])
```

This is **not** concurrency. Concurrency is how many claims may overlap at one instant; a limit is how many fall inside a stretch of calendar, however far apart. And limits count what the ledger already holds — availability can be derived, but no availability calculation can express *"at most twelve this week"*.

A limit measures either claims or *time*, and may set a floor as well as a ceiling. Only ceilings constrain the search, and the asymmetry is real rather than an omission: a ceiling prunes, because nothing placed later brings a total back down, while a partial layout is *supposed* to be under its floor. A floor is a completion condition, so it is [`reconcile/3`](https://hexdocs.pm/agenda/Agenda.html#reconcile/3) that checks it.

**Wishes.** What someone would rather, as against what is possible:

```elixir
Agenda.resource("Priya", avoids: friday_afternoons)
{:ok, programme} = Agenda.prefer(programme, :resource_wishes, weight: 5)
```

`avoids` makes a placement worse; `open/2` makes it impossible. Spelling a preference as unavailability takes the option away from everyone and fails the week rather than booking reluctantly when there is no alternative.

## Does the week add up?

A schedule is the ledger read as *intent*; a timesheet is the same ledger read as *record*. `reconcile/3` compares the two over a period:

```elixir
{:ok, report} = Agenda.reconcile(ledger, dana, within: quarter, excluding: holidays)

Agenda.Reconciliation.explain(report)
#=> ["Dana: 5 hours unaccounted — 2026Y6M16DT12H0M0S/T17H0M0S"]
```

**The answer is a set, not a total.** Summing hours and comparing to a number passes on data that is wrong: a consultant who misses a Tuesday and works the following Saturday totals exactly the same as one who did neither. `unaccounted` and `overclaimed` are interval sets, so they say *which* time is missing — which is what a person can act on.

Work and leave are the same structure, separated by a tag on the claim:

```elixir
{:ok, ledger} = Agenda.allocate(ledger, arrangement, tag: {:project, "ACME-2026-01"})
{:ok, ledger} = Agenda.allocate(ledger, arrangement, tag: {:leave, :annual})
```

One ledger means a day cannot be two things — billing a client while on leave is the overlap the ledger already refuses, not a rule somebody has to remember to write.

**Holidays are not this library's business.** They vary by jurisdiction down to the local government area — Queensland appoints show holidays per district — and accurate data for that is a maintenance problem with a far wider audience than scheduling. So they arrive as an ordinary interval set through `:excluding`, from a feed via `from_ical/1` or from wherever you resolve them. The subtraction order does one useful thing for free: holidays leave the expectation *before* claims are compared against it, so **a public holiday inside a period of leave cannot consume that leave**.

## Holding a room while someone finds their card

A booking page needs to take a room *tentatively*. A hold occupies the resource exactly as a booking does — which is why it lives in the ledger rather than in a persistence layer: availability is derived on every call, so a hold nobody can see is a hold nobody subtracts.

```elixir
{:ok, ledger} = Agenda.hold(ledger, arrangement, until: "2026-06-15T10:15:00")
{:ok, ledger} = Agenda.confirm(ledger, "Review")
```

**Nothing expires on its own.** `expire/2` takes the moment as an argument rather than reading a clock:

```elixir
{:ok, ledger} = Agenda.expire(ledger, now)
```

That is deliberate. `busy/2` is called inside `plan/3` and `arrange/3`; if it consulted the system clock, arranging the same programme twice would give different answers as holds lapsed underneath it. Refusing to guess the time is the same discipline as refusing to guess an unmeasured journey.

The rest of the claim lifecycle — completed, cancelled, no-show — is deliberately *not* here. A hold changes what is available; a no-show does not. That line is what separates the engine's business from the adapter's.

## Preferring one workable layout over another

Every constraint above is hard. A preference is soft: it never makes a layout invalid, only worse.

```elixir
{:ok, programme} = Agenda.prefer(programme, :room_changes, weight: 10)
{:ok, programme} = Agenda.prefer(programme, :room_spread, weight: 3)

Agenda.explain_score(arrangements, programme)
#=> ["room_changes: 0 × 10 = 0", "room_spread: 0 × 3 = 0"]
```

Preferences count *violations*, so zero is ideal — a number that means something on its own, where a reward total only means something next to another reward total.

Optimisation is **lexicographic and two-pass**, and that is the whole design. The first pass ignores preferences and *proves* how many sessions can be placed. The second takes that number as a hard ceiling and looks only for a better-scoring layout placing exactly as many. So a preference can never cost you a session, `minimal?` still means proven, and the new `score_proven?` says whether the scoring pass finished or ran out of its own budget.

What is not promised is soft *optimality*. Proving a weighted optimum needs a bound on remaining cost that this search has no cheap way to compute — and a programme that genuinely needs one wants a solver, which is the next section.

## Handing it to a solver

How far the exact search reaches depends on the shape of a programme rather than its size — sessions that cannot interact are solved separately and concurrently, so 1,200 spread across twenty days lay out in about a second, while 500 all competing for a single day exhaust the default `:nodes` budget. Density is the variable rather than the total: 200 in one day take about 220 ms and 450 about 1.5 s, and when the budget does run out the first remedy is to raise it — those same 500 place in 2 s given `nodes: 200_000`.

A real constraint solver is a different tool rather than a bigger one. With the optional [fixpoint](https://hex.pm/packages/fixpoint) dependency the same programme becomes an ordinary CP model in one call:

```elixir
{:ok, arrangements} = Agenda.Fixpoint.solve(programme, rooms)
```

Nothing about the model changes. Each session already has a finite list of candidate placements that satisfy its requirements, so the solver's variable is *which candidate* — eligibility, induced requirements, availability and the place tree all stay on this side of the boundary, where they are explained. The solver never learns what a room is. Conflicts come from `Agenda.Arranger.conflict?/4`, the same predicate the built-in search uses, so the two cannot disagree about what a clash is.

It answers the all-or-nothing question only, for exclusive resources. Concurrency above one is refused rather than mis-solved: capacity is not a pairwise property, and fixpoint has no cumulative constraint to express it.

Reach for it when you need a constraint this library cannot express and intend to write it in fixpoint yourself — not because a programme got large. Measured head to head the built-in search is faster at every size, and on a day filled to the hour the bridge stops returning inside twenty seconds from about two dozen sessions, long before `arrange/3` reaches its own limits.

## Open hours from a calendar

Availability usually already exists somewhere. `from_ical/1` reads [RFC 7953](https://www.rfc-editor.org/rfc/rfc7953.html) `VAVAILABILITY` — what a CalDAV server hands you when asked when someone is free:

```elixir
{:ok, hours} = Agenda.from_ical(vavailability)
{:ok, clinic} = Agenda.open(Agenda.resource("Clinic"), hours)
```

`PRIORITY` across overlapping components and each `AVAILABLE` recurrence resolve against the window you actually ask about, not at import time. `VEVENT`s in the same document are ignored — those are time *taken*, and belong in `free/2`'s `:busy`.

Requires the optional `ical` dependency.

## Status

**Early development, but no longer only a model.** Implemented: resources, attributes, the place tree and derived travel, requirements and the predicate vocabulary, induced requirements, explanations, availability, single-session planning, the allocation ledger, tagged claims, holds, recurring series, tracks, whole-programme arrangement, partial arrangement, pinning, precedence, load limits measured in claims or in time with floors and ceilings, reconciliation over a period, soft constraints including per-resource wishes, minimal conflict sets, RFC 7953 import, and the fixpoint solver bridge.

Meeting and conference scheduling is the focus. Task and shift scheduling are expressible — precedence makes a task graph, limits make a contract, wishes make a roster people will accept — and exact at small scale, or handed to a solver at large.

Still open: the rest of the claim lifecycle — completed, cancelled, no-show — which belongs with the persistence adapter, since none of those states changes what is available. The full design is in [the plan](https://github.com/elixir-tempo/agenda/blob/main/plans/agenda.md).

### Optional dependencies

* [`ical`](https://hex.pm/packages/ical) `~> 3.2` for RFC 7953 `VAVAILABILITY` import — 3.2 is the first release carrying it.

* [`fixpoint`](https://hex.pm/packages/fixpoint) for the solver bridge. It describes itself as a proof of concept, so treat that path accordingly.

## Installation

```elixir
def deps do
  [
    {:agenda, "~> 0.1"}
  ]
end
```

### Configure a timezone database

Elixir ships a UTC-only timezone database, and with it every zone resolves to UTC and daylight-saving arithmetic is **silently wrong** rather than failing — a London window across the spring-forward boundary measures an hour longer than it is. Any application doing zoned scheduling should configure a real IANA database:

```elixir
config :elixir, :time_zone_database, Tz.TimeZoneDatabase
```

with `{:tz, "~> 0.28"}` in your dependencies. Agenda does not choose one for you.

## License

Apache-2.0. See [LICENSE.md](LICENSE.md).
