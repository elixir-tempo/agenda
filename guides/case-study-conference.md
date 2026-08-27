# Case study: ElixirConf 2027

Two days, a keynote each morning, then parallel tracks running until the close. This is where planning stops being enough and becomes a search — a room taken by one talk is gone for another, and a track that collides with itself has no audience.

## Planning versus arranging

Everything in the other case studies uses `plan/3`, which *enumerates*: it lists the ways one session could be held. A conference needs something different. Each choice forecloses others, so the question is not "when could this talk run?" but *"is there a placement for every talk such that nothing clashes?"* That is `arrange/3`, and it searches.

Three constraints hold a programme together:

* **No resource is in two places at once.** Two placements sharing a room must not overlap.

* **A track cannot clash with itself.** That is what makes it a track rather than a list.

* **Consecutive track sessions must be reachable.** A delegate following the track has to physically get between them.

## The venue

```elixir
venue       = Agenda.place("Convention Centre")
main_level  = Agenda.place("Plenary Level", within: venue)
break_level = Agenda.place("Breakout Level", within: venue)

conf_days =
  Tempo.IntervalSet.new!([
    ~o"2027-05-13T09:00:00/2027-05-13T17:00:00",
    ~o"2027-05-14T09:00:00/2027-05-14T17:00:00"
  ])

hall   = Agenda.resource("Main Hall", within: main_level, seats: 800) |> Agenda.open!(conf_days)
room_a = Agenda.resource("Room A", within: break_level, seats: 200) |> Agenda.open!(conf_days)
room_b = Agenda.resource("Room B", within: break_level, seats: 200) |> Agenda.open!(conf_days)
```

Open hours are a Tempo value, so "nine to five on two specific days" is just a two-member interval set. It could equally be an ISO 8601 recurrence or an RFC 5545 `RRULE` — `open/2` takes all three, and ISO 8601 is the preferred spelling because it is what Tempo stores and renders back.

## Keynotes and talks differ only in what they demand

```elixir
keynote = fn name, window ->
  Agenda.session(name, duration: ~o"PT1H", window: window)
  |> Agenda.Session.needs(:room, seats: at_least(500))
end

talk = fn name, window ->
  Agenda.session(name, duration: ~o"PT1H", window: window)
  |> Agenda.Session.needs(:room, seats: at_least(150))
end
```

A keynote needs 500 seats, which only the main hall has; a talk needs 150, which any room satisfies. Nothing marks one as "a keynote" — the demand does the work.

**Keeping the keynote unopposed is a matter of windows, not a special constraint.** Give the keynote the morning and the tracks the rest of the day, and nothing can be scheduled against it:

```elixir
day1_morning = ~o"2027-05-13T09:00:00/2027-05-13T10:30:00"
day1_rest    = ~o"2027-05-13T10:30:00/2027-05-13T17:00:00"

day2_morning = ~o"2027-05-14T09:00:00/2027-05-14T10:30:00"
day2_rest    = ~o"2027-05-14T10:30:00/2027-05-14T17:00:00"
```

This is worth stating plainly because the alternative — a genuine "nothing else may run" constraint — does not exist in the library, and the window approach is how the requirement is actually met.

## Tracks

```elixir
{:ok, core} =
  Agenda.track("Core", of: [talk.("OTP internals", day1_rest), talk.("Ecto at scale", day2_rest)])
  |> Agenda.Track.reachable(within: ~o"PT15M")

{:ok, web} =
  Agenda.track("Web", of: [talk.("LiveView patterns", day1_rest), talk.("Phoenix 2.0", day2_rest)])
  |> Agenda.Track.reachable(within: ~o"PT15M")
```

> *"No two Core talks may overlap, and a delegate following Core must be able to walk between consecutive ones inside fifteen minutes."*

Not overlapping is intrinsic — a set of sessions that may collide with each other is just a list, so there is no `no_overlap` option to remember. `reachable/2` is the only choice, and it reads the place tree: Room A and Room B are on the same level, so moving between them costs nothing; the main hall is a level away.

The word is deliberately **track** and not "stream". Elixir's `Stream` owns that name, and a conference stream would shadow it at every call site.

## Arranging the whole thing

```elixir
programme =
  Agenda.programme("ElixirConf 2027", across: ~o"2027-05-13/2027-05-15")
  |> Agenda.Programme.add_session(keynote.("Day 1 keynote", day1_morning))
  |> Agenda.Programme.add_session(keynote.("Day 2 keynote", day2_morning))
  |> Agenda.Programme.add_track(core)
  |> Agenda.Programme.add_track(web)

{:ok, arrangements} = Agenda.arrange(programme, [hall, room_a, room_b])
length(arrangements)
#=> 6
```

Sorted by time, that is the programme:

```
Day 1 keynote:      2027-05-13 09:00–10:00 — Main Hall
OTP internals:      2027-05-13 10:30–11:30 — Main Hall
LiveView patterns:  2027-05-13 10:30–11:30 — Room A
Day 2 keynote:      2027-05-14 09:00–10:00 — Main Hall
Ecto at scale:      2027-05-14 10:30–11:30 — Main Hall
Phoenix 2.0:        2027-05-14 10:30–11:30 — Room A
```

> *"Each morning opens with a keynote in the main hall; the two tracks then run in parallel, Core in the hall and Web in Room A."*

Both tracks got the same slot — that is correct and is the whole point of parallel tracks. What the search guaranteed is that *Core* does not collide with *Core*, and that no room hosts two things at once.

## When it cannot be done, it says why

```elixir
impossible =
  Agenda.session("Impossible keynote", duration: ~o"PT1H", window: day1_morning)
  |> Agenda.Session.needs(:room, seats: at_least(5000))

programme_with_it = Agenda.Programme.add_session(programme, impossible)

{:error, reason} = Agenda.arrange(programme_with_it, [hall, room_a, room_b])

Agenda.explain(reason)
#=> "Impossible keynote cannot be held: nothing satisfies room: Main Hall (seats is 800 —
#=>  needs at least 5000), Room A (seats is 200 — needs at least 5000), Room B (seats is
#=>  200 — needs at least 5000)"
```

Not "no solution found" — the session that failed, and every room with the reason it did not qualify. That is the difference between a programme committee arguing and a programme committee booking a bigger venue.

## When the programme does not fit

A committee accepts more talks than the venue holds. That is not a bug in the schedule, it is the ordinary state of a call for papers, and failing the whole programme over it is useless. `unplaced: :allow` asks for the **fewest** sessions left out instead:

```elixir
lightning_slot = ~o"2027-05-13T14:00:00/2027-05-13T16:00:00"

crowded =
  Enum.reduce(1..8, programme, fn n, acc ->
    Agenda.Programme.add_session(acc, talk.("Lightning #{n}", lightning_slot))
  end)

{:partial, layout} = Agenda.arrange(crowded, [hall, room_a, room_b], unplaced: :allow)

length(layout.placed)
#=> 12
Agenda.Layout.unplaced_sessions(layout)
#=> ["Lightning 7", "Lightning 8"]
```

Three rooms across a two-hour slot hold six lightning talks; eight were offered, so two are left out and the other six join the six-session programme.

The result is **never** `{:ok, …}` when something was dropped — the tag is `{:partial, layout}`, so a caller who has not thought about incompleteness cannot mistake one for a finished programme. Each entry in `layout.unplaced` is an ordinary infeasible result, so it still says why:

```elixir
Agenda.explain(layout)
#=> "ElixirConf 2027: 12 of 14 sessions placed. Lightning 7 cannot be held: cannot be
#=>  placed without clashing with something already placed Lightning 8 cannot be held:
#=>  cannot be placed without clashing with something already placed"
```

"Fewest" is meant literally, and `layout.minimal?` says whether it was proved:

```elixir
layout.minimal?
#=> true
```

The search is branch-and-bound. It keeps the best complete layout found so far and cuts any branch that already leaves out as many, so a greedy near-miss is never passed off as the best available. Two consequences are worth knowing:

* **It answers early and improves.** The first descent already yields a usable layout, so hitting the `:nodes` cap returns the best found rather than an error. That is what `minimal?: false` means — a good answer whose optimality was not proved. Raise `:nodes` and ask again.

* **Being more overbooked is not more expensive.** A relaxation bound — how many placements the rooms could possibly hold, ignoring every other constraint — lets the search stop the moment it matches it, instead of exhaustively proving the point. Twenty lightning talks into six slots is *faster* than eight, because the bound is reached sooner.

## Holding the announced sessions still

Once the programme is published, re-running it must not move the keynote somebody already booked a flight for. `:pinned` fixes chosen placements and searches around them:

```elixir
{:ok, arrangements} = Agenda.arrange(programme, [hall, room_a, room_b])
announced = Enum.filter(arrangements, &String.contains?(&1.session, "keynote"))

{:ok, revised} = Agenda.arrange(programme, [hall, room_a, room_b], pinned: announced)
length(revised)
#=> 6
```

A pin is not a hint. Every constraint still applies to it — a pinned session occupies its room, clashes with its track, and counts against reachability — and a pin that cannot be honoured is an error naming it, not something quietly dropped. Pinning what is already booked is a one-liner via `Agenda.arrangements/3`, which rebuilds ledger allocations into pinnable arrangements.

## Which sessions are actually fighting

When a programme genuinely cannot be laid out, `arrange/3` names *a* session that failed. That is often not the one to move. `conflict/3` returns a **minimal** set — remove any single member and the rest fit:

```elixir
tight =
  Agenda.programme("Overbooked", across: ~o"2027-05-13/2027-05-14")
  |> Agenda.Programme.add_session(keynote.("Keynote A", day1_morning))
  |> Agenda.Programme.add_session(keynote.("Keynote B", day1_morning))

Agenda.conflict(tight, [hall, room_a, room_b])
#=> {:ok, ["Keynote A", "Keynote B"]}
```

> *"Both keynotes need the only 500-seat room in the same 90 minutes. One of them has to move."*

This is QuickXplain, and it costs a number of trial arrangements logarithmic in the size of the programme rather than one per session — so run it **on failure**, not on every call. Pinned sessions form the background and are never named, because they are not free to move.

## Preferring one layout over another

Everything so far is hard: a layout is valid or it is not. But several layouts are usually valid, and `arrange/3` has been picking among them arbitrarily. A delegate following the Core track would rather not be marched between floors every hour, and that is a *preference* — it never makes a layout invalid, only worse.

```elixir
{:ok, programme} = Agenda.prefer(programme, :room_changes, weight: 10)

{:ok, arrangements} = Agenda.arrange(programme, [hall, room_a, room_b])
Agenda.explain_score(arrangements, programme)
#=> ["room_changes: 0 × 10 = 0"]
```

Zero because both Core talks now sit in the same room. Preferences count *violations*, so the ideal layout scores zero — a number that means something on its own, where a reward total only means something next to another reward total.

`:room_spread` is the other built-in, and it discourages piling everything into one room while another stands empty. Your own is a name and a function:

```elixir
count_late_keynotes = fn arrangements, _programme ->
  Enum.count(arrangements, fn arrangement ->
    String.contains?(arrangement.session, "Keynote") and
      Tempo.compare(arrangement.interval.from, ~o"2027-05-13T12:00") == :gt
  end)
end

{:ok, fussy} =
  Agenda.prefer(programme, {:no_late_keynotes, count_late_keynotes}, weight: 5)
```

**A preference can never cost you a session.** Optimisation is lexicographic and runs in two passes: the first ignores preferences entirely and proves how many sessions can be placed, the second takes that number as a hard ceiling and looks only for a better-scoring layout placing exactly as many. So `minimal?` still means what it meant, and a separate `score_proven?` says whether the scoring pass finished:

```elixir
{layout.minimal?, layout.score_proven?}
#=> {true, true}
```

The first is *provably the fewest left out*; the second says the scoring pass finished too.

The two are independent, and usually the first is proven while the second is merely good — the count is cheap to prove and the score is not. Declaring a preference does cost time: the search can no longer stop at the first layout that places everything, since a later one may score better. It gets its own `:score_nodes` budget so it can never spend the one that proves the count.

## When even that is not enough

Past a few dozen sessions this search runs out of road, and the guide has said so from the start: use a real solver and write its output back through `allocate/2`. With the optional [fixpoint](https://hex.pm/packages/fixpoint) dependency, that is one call:

<!-- guide-test: skip (13.5s against the solver's 30s default budget — too close to run in CI) -->
```elixir
{:ok, arrangements} = Agenda.Fixpoint.solve(programme, [hall, room_a, room_b])
```

The programme does not change shape to suit the solver. Each session already has a finite list of candidate placements that satisfy its requirements, so the variable handed over is *which candidate* — and eligibility, induced requirements, availability and the place tree all stay here, where they are explained. The solver never learns what a room is. Conflicts come from the same predicate `arrange/3` uses, so the two cannot disagree about what a clash is.

Two limits. It answers the all-or-nothing question only — `unplaced: :allow`, `minimal?` and preferences all stay with `arrange/3`. And it models exclusive resources only: capacity above one is not a pairwise property, so a pool containing a resource with `concurrency > 1` is refused rather than quietly mis-solved.

## Scale, honestly

The search is depth-first with backtracking, ordered most-constrained-first, and bounded by two explicit caps:

* `:candidates` — how many placements are considered per session (default 40).

* `:nodes` — how many search steps before giving up (default 10,000).

**Both caps report when they are hit.** A partial programme presented as finished is worse than an admitted failure, so hitting the node limit is an error naming the limit, not a short list of arrangements:

```elixir
Agenda.arrange(programme, [hall, room_a, room_b], nodes: 1) |> elem(1) |> Agenda.explain()
#=> "ElixirConf 2027 cannot be held: the search reached its node limit before placing
#=>  every session — raise :nodes, or narrow the programme"
```

A few hundred sessions is comfortable. A university timetable of thousands of classes is not — that wants a purpose-built constraint solver. The way to use one here is to write its output back through `Agenda.allocate/2`, which stays authoritative either way; the ledger does not care who computed the answer.

## What to take away

* **`plan/3` enumerates, `arrange/3` searches.** One session's options versus a consistent layout for all of them.

* **Demand does the classifying.** A keynote is a session that needs 500 seats; no type marks it as special.

* **Use windows to sequence.** Unopposed keynotes come from giving the keynote the morning, not from a constraint.

* **Not overlapping is intrinsic to a track.** Only reachability is optional.

* **Read the caps.** If a programme fails, check whether it was genuinely infeasible or merely hit `:nodes`.

* **Failure has three shapes, not one.** `unplaced: :allow` for "book what fits", `:pinned` for "do not move what is announced", and `conflict/3` for "which of these is actually fighting".

* **Hard constraints decide validity, preferences decide taste.** And a preference can never cost a placement, because the count is settled before the score is considered.
