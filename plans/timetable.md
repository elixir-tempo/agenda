# Plan — `timetable`: period grids, cohorts, and curriculum demand

## Problem

A school or university timetable is not a large scheduling problem. It is a different problem that happens to share vocabulary.

The question a scheduler answers is *when can this happen, and where?* — one session at a time, or a programme at a time, against a calendar of concrete dates. The question a timetabler answers is *what is the shape of a typical week?* — every lesson at once, against a repeating grid of periods, where the hard constraints are usually easy to satisfy and the entire craft is in the soft ones.

`agenda` answers the first question well. This library answers the second. The two share a lexicon and several primitives, and almost no algorithm.

## Why a sibling, and not an extension of `agenda`

Three things break structurally if timetabling is pushed into `agenda`, and each is load-bearing rather than a matter of taste.

**The grid is the unit of solving, not something to expand before solving.** `agenda` models time as bounded intervals on a concrete calendar, and `Agenda.Series` expands a repeating session into ordinary dated sessions — one per occurrence — so that everything downstream works unchanged. That is the right decision for a fortnightly clinic and the wrong one here. A fifteen-week semester of a thousand lessons expands to fifteen thousand sessions, when the problem actually being solved is a thousand lessons over a forty-slot grid. The repetition *is* the answer; expanding it first destroys the structure that makes the problem tractable.

**A lesson is not a session.** `Agenda.Session` is one contiguous block with one duration. A curriculum demand is *"Maths, five periods a week, at most two on any day, at least one of them a double"* — a quantity of time that fragments into sub-events with a shape, where the fragmentation is part of what the solver decides. There is no way to say that in terms of a session, and adding it would distort the session concept for every existing user.

**The objective is the job, not the garnish.** In meeting scheduling, feasibility is hard and preferences break ties; `agenda`'s two-phase lexicographic design encodes exactly that priority, proving the placement count first and only then improving score. In timetabling, feasibility is usually easy — a valid timetable is often reachable greedily — and the whole difficulty is minimising student idle gaps, teacher compactness, and subject spread. A violation counter with three built-ins and no proven soft optimality is the wrong end of the telescope. Worse, `agenda`'s guarantee that *a preference can never cost you a session* is precisely the guarantee a timetabler does not want, because they will trade a lesson's preferred slot for a cohort's whole-week compactness without hesitating.

Add to that the scale: roughly a thousand lessons against a search whose honest working range is a few hundred sessions. That gap is not closed by tuning.

## What transfers, and should not be rebuilt

More than the above suggests. The dependency runs one way — `timetable` depends on `agenda` — and these are the reasons:

* **`Agenda.Track` is a student cohort.** It is already the one constraint in `agenda` that relates sessions to *each other* rather than to a resource: these share an audience, so no two may run at once, and a delegate must be able to walk between consecutive ones. That is the cohort clash constraint exactly, including the part most timetabling systems get wrong.

* **`Agenda.Place` answers the travel question.** *"Can a student get from the science block to the sports hall between period 3 and period 4?"* is a real hard constraint in a split-campus school, and a place tree with derived travel already answers it. A flat room attribute cannot.

* **`Agenda.Requirement` and the predicate vocabulary** describe room types and teacher qualifications without inventing a second language for it — a lab needs `fume_hood: true`, a teacher needs `all_of([:physics, :senior])`.

* **`Agenda.Conflict` — minimal conflict sets.** Timetablers ask *"why is this impossible?"* more than any other question, and the tools they have answer it badly. QuickXplain over curriculum demands would be a genuinely distinguishing feature, and it is already written.

* **`Agenda.Ledger`** stays authoritative for anything that becomes a real booking, so a published timetable and an ad-hoc room request cannot double-book.

## The model

### The grid is explicit and finite

A `Timetable.Grid` is days × periods, with each period carrying a real duration and start time so the result can be projected back onto the calendar through `agenda`. Solving happens on slot indices; dates are a rendering concern.

```elixir
grid = Timetable.grid(days: ~w(mon tue wed thu fri), periods: 8, period: ~o"PT45M", first: ~o"08:30")
```

The projection back to concrete dates — *"this grid, every week of term, minus the public holidays"* — is `agenda`'s and Tempo's business, and is the last step rather than the first.

### Demand, not sessions

A `Timetable.Demand` is what a cohort must be taught, by whom, in what kind of room, and in what shape:

```elixir
Timetable.demand("10A Maths",
  cohort: "10A",
  teacher: needs(:teacher, all_of([:maths, :senior])),
  room: needs(:room, seats: at_least(30)),
  periods: 5,
  shape: [max_per_day: 2, doubles: 1, spread: :even])
```

The solver decides how the five periods split and where each lands. `shape:` is where the domain lives, and it is the part with no `agenda` equivalent.

### Soft constraints are first-class and weighted

Not a tie-breaker. The built-in vocabulary is the one the literature and the practitioners share: student idle gaps, teacher idle gaps, teacher days-in-attendance, subject spread across the week, room stability for a cohort, avoidance of last period for hard subjects. Each is a weighted violation count, and the weights are the user's — a school that will not tolerate a single student gap and one that cares only about teacher days want different timetables from identical input.

## The engine

**Local search, not exact search.** Late-acceptance hill climbing or simulated annealing over a complete-but-invalid assignment, with neighbourhood moves that swap two lessons, move one lesson to a free slot, or swap a whole day between two cohorts. This is the algorithm class that wins the international competitions, and it is a different shape from anything in `Agenda.Arranger`: no branch-and-bound, no relaxation bound, no proven minimality.

That is a real trade and should be stated plainly rather than discovered: **this library will not prove anything.** It returns the best timetable it found in the time it was given, with its score and its violations itemised. `agenda`'s `minimal?` flag has no analogue here, and pretending otherwise would be dishonest. What it offers instead is *anytime* behaviour — a usable answer at ten seconds, a better one at ten minutes — and a violation report that says exactly what it could not satisfy and by how much.

A hybrid is worth trying later: `agenda`'s exact search or the `fixpoint` bridge to establish a feasible starting assignment, then local search to improve it. Worth trying, not worth assuming.

## Interoperability — XHSTT

The anchor is [XHSTT](https://www.utwente.nl/en/eemcs/dmmp/hstt/), the XML format for high school timetabling used by the international timetabling competitions. It is the RFC-equivalent for this domain: a published schema, a set of real-world instances from a dozen countries, and — critically — published best-known solutions.

This matters more than the usual interop argument. It converts *"the engine seems to work on my example"* into a measurable claim against instances other people have also attacked. It is the same discipline this family already applied twice, with RFC 7953 and RFC 8984, and it is the only honest way to say whether the engine is any good.

Read first, write second: importing an XHSTT instance and scoring a solution against its own objective is a smaller job than emitting one, and it is what makes the benchmark usable.

## Staging

1. **Grid, demand, cohort, and a validity checker.** No solver. Given an assignment, say whether it is valid and what it scores. This is the foundation the engine is tested against, and it is independently useful for checking a timetable someone produced by hand.

2. **XHSTT import, and the benchmark harness.** Read the competition instances, score the published solutions, confirm the scorer agrees with the published numbers. Until the scorer is right, no engine result means anything.

3. **A greedy constructor.** Most instances admit a feasible timetable greedily. This establishes the baseline that local search must beat, and it is what the anytime behaviour starts from.

4. **Local search.** Late-acceptance hill climbing first — it has one parameter and is hard to misconfigure — with the neighbourhood moves above. Measure against the benchmark at every step.

5. **Explanations.** Violation reports as sentences, and `Agenda.Conflict` applied to demands so that an infeasible instance names the demands in tension rather than shrugging.

6. **Projection onto the calendar,** through `agenda` and Tempo: term dates, holidays, and the ledger.

## What this deliberately is not

* **Not exact, and not proving anything.** See above. If a caller needs a proof, they have a small problem and should use `Agenda.arrange/3`.

* **Not a room booking system.** A timetable is a repeating pattern; a booking is a claim on a specific date. The second is `agenda`'s, and the boundary is the projection step.

* **Not a student enrolment or curriculum planner.** Demands arrive already decided. Which students are in which cohort, and which subjects a cohort takes, is upstream.

* **Not employee rostering.** Shift work has a different constraint vocabulary — rest periods between shifts, night/day rotation, contractual hours over a rolling window. `agenda`'s load limits already reach some of it, and the rest is a third problem, not this one.
