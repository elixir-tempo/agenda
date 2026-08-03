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
venue       = Timetable.place("Convention Centre")
main_level  = Timetable.place("Plenary Level", within: venue)
break_level = Timetable.place("Breakout Level", within: venue)

conf_days =
  Tempo.IntervalSet.new!([
    ~o"2027-05-13T09:00:00/2027-05-13T17:00:00",
    ~o"2027-05-14T09:00:00/2027-05-14T17:00:00"
  ])

{:ok, hall}   = Timetable.resource("Main Hall", within: main_level, seats: 800) |> Timetable.open(conf_days)
{:ok, room_a} = Timetable.resource("Room A", within: break_level, seats: 200) |> Timetable.open(conf_days)
{:ok, room_b} = Timetable.resource("Room B", within: break_level, seats: 200) |> Timetable.open(conf_days)
```

Open hours are a Tempo value, so "nine to five on two specific days" is just a two-member interval set. It could equally be an ISO 8601 recurrence or an RFC 5545 `RRULE` — `open/2` takes all three, and ISO 8601 is the preferred spelling because it is what Tempo stores and renders back.

## Keynotes and talks differ only in what they demand

```elixir
keynote = fn name, window ->
  Timetable.session(name, lasting: ~o"PT1H", between: window)
  |> Timetable.Session.needs(:room, seats: at_least(500))
end

talk = fn name, window ->
  Timetable.session(name, lasting: ~o"PT1H", between: window)
  |> Timetable.Session.needs(:room, seats: at_least(150))
end
```

A keynote needs 500 seats, which only the main hall has; a talk needs 150, which any room satisfies. Nothing marks one as "a keynote" — the demand does the work.

**Keeping the keynote unopposed is a matter of windows, not a special constraint.** Give the keynote the morning and the tracks the rest of the day, and nothing can be scheduled against it:

```elixir
day1_morning = ~o"2027-05-13T09:00:00/2027-05-13T10:30:00"
day1_rest    = ~o"2027-05-13T10:30:00/2027-05-13T17:00:00"
```

This is worth stating plainly because the alternative — a genuine "nothing else may run" constraint — does not exist in the library, and the window approach is how the requirement is actually met.

## Tracks

```elixir
core =
  Timetable.track("Core", of: [talk.("OTP internals", day1_rest), talk.("Ecto at scale", day2_rest)])
  |> Timetable.Track.reachable(within: ~o"PT15M")

web =
  Timetable.track("Web", of: [talk.("LiveView patterns", day1_rest), talk.("Phoenix 2.0", day2_rest)])
  |> Timetable.Track.reachable(within: ~o"PT15M")
```

> *"No two Core talks may overlap, and a delegate following Core must be able to walk between consecutive ones inside fifteen minutes."*

Not overlapping is intrinsic — a set of sessions that may collide with each other is just a list, so there is no `no_overlap` option to remember. `reachable/2` is the only choice, and it reads the place tree: Room A and Room B are on the same level, so moving between them costs nothing; the main hall is a level away.

The word is deliberately **track** and not "stream". Elixir's `Stream` owns that name, and a conference stream would shadow it at every call site.

## Arranging the whole thing

```elixir
programme =
  Timetable.programme("ElixirConf 2027", across: ~o"2027-05-13/2027-05-15")
  |> Timetable.Programme.add_session(keynote.("Day 1 keynote", day1_morning))
  |> Timetable.Programme.add_session(keynote.("Day 2 keynote", day2_morning))
  |> Timetable.Programme.add_track(core)
  |> Timetable.Programme.add_track(web)

{:ok, arrangements} = Timetable.arrange(programme, [hall, room_a, room_b])
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
  Timetable.session("Impossible keynote", lasting: ~o"PT1H", between: day1_morning)
  |> Timetable.Session.needs(:room, seats: at_least(5000))

Timetable.arrange(programme_with_it, [hall, room_a, room_b])
#=> {:error, reason}

Timetable.explain(reason)
#=> "Impossible keynote cannot be held: nothing satisfies room: Main Hall (seats is 800 —
#=>  needs at least 5000), Room A (seats is 200 — needs at least 5000), Room B (seats is
#=>  200 — needs at least 5000)"
```

Not "no solution found" — the session that failed, and every room with the reason it did not qualify. That is the difference between a programme committee arguing and a programme committee booking a bigger venue.

## Scale, honestly

The search is depth-first with backtracking, ordered most-constrained-first, and bounded by two explicit caps:

* `:candidates` — how many placements are considered per session (default 40).

* `:nodes` — how many search steps before giving up (default 10,000).

**Both caps report when they are hit.** A partial programme presented as finished is worse than an admitted failure, so hitting the node limit is an error naming the limit, not a short list of arrangements:

```elixir
Timetable.arrange(programme, rooms, nodes: 1) |> elem(1) |> Timetable.explain()
#=> "... the search reached its node limit before placing every session — raise :nodes,
#=>  or narrow the programme"
```

A conference of a few dozen sessions across a handful of rooms is comfortable. A university timetable of thousands of classes is not — that wants a purpose-built constraint solver. The way to use one here is to write its output back through `Timetable.allocate/2`, which stays authoritative either way; the ledger does not care who computed the answer.

## What to take away

* **`plan/3` enumerates, `arrange/3` searches.** One session's options versus a consistent layout for all of them.

* **Demand does the classifying.** A keynote is a session that needs 500 seats; no type marks it as special.

* **Use windows to sequence.** Unopposed keynotes come from giving the keynote the morning, not from a constraint.

* **Not overlapping is intrinsic to a track.** Only reachability is optional.

* **Read the caps.** If a programme fails, check whether it was genuinely infeasible or merely hit `:nodes`.
