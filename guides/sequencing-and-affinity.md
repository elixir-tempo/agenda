# Sequencing, tracks and affinity

Most of what a scheduler is asked for is not "is this room free". It is *this after that*, *these three may not collide*, and *keep them together if you can*. This guide is those three, in that order, because each one is a different kind of constraint and the differences matter more than the syntax.

Ordering is **hard** and pairwise. A track is **hard** and intrinsic. Affinity is **soft** — it never makes a layout invalid, only worse. Reaching for the wrong one is the usual way a programme comes out either over-constrained or ignored.

The venue for all of it: two rooms on one level, one a floor above, so that moving between them costs something the library can measure.

```elixir
venue = Agenda.place("Venue")
level_1 = Agenda.place("Level 1", within: venue)
level_2 = Agenda.place("Level 2", within: venue)

day = ~o"2027-03-01T09:00:00/2027-03-01T13:00:00"

room_a = Agenda.resource("Room A", within: level_1, seats: 100) |> Agenda.open!(day)
room_b = Agenda.resource("Room B", within: level_1, seats: 100) |> Agenda.open!(day)
room_c = Agenda.resource("Room C", within: level_2, seats: 100) |> Agenda.open!(day)

rooms = [room_a, room_b, room_c]

talk = fn name ->
  Agenda.session(name, duration: ~o"PT1H", window: day)
  |> Agenda.Session.needs(:room, seats: at_least(10))
end
```

Nobody stated a distance. It comes out of the place tree:

```elixir
{Agenda.travel_time(room_a, room_b), Agenda.travel_time(room_a, room_c)}
#=> {{:ok, ~o"PT0M"}, {:ok, ~o"PT5M"}}
```

Same level is free; a level away is five minutes. Every constraint below that mentions distance reads those numbers rather than a rule you wrote.

## One thing after another

`precede/4` says one session must finish before another starts. It relates exactly two sessions by name, and the names are the ones you gave them:

```elixir
ordered =
  Agenda.programme("Day", across: day)
  |> Agenda.Programme.add_session(
    Agenda.session("Setup", duration: ~o"PT1H", window: ~o"2027-03-01T09:00:00/2027-03-01T10:00:00")
    |> Agenda.Session.needs(:room, seats: at_least(10)))
  |> Agenda.Programme.add_session(
    Agenda.session("Briefing", duration: ~o"PT1H", window: ~o"2027-03-01T11:00:00/2027-03-01T12:00:00")
    |> Agenda.Session.needs(:room, seats: at_least(10)))

{:ok, after_setup} = Agenda.precede(ordered, "Setup", "Briefing")
{:ok, [_ | _]} = Agenda.arrange(after_setup, rooms)
```

That is the weak form, and it is usually the one you want: *after*, with nothing said about how long after. Two options sharpen it, and they pull in opposite directions.

**`:gap` is a floor.** "No sooner than" — half an hour to write up the survey before quoting for it.

**`:within` is a ceiling.** "No later than" — measured from the end of the predecessor, so it does not shrink if the predecessor runs long.

Setting them against a fixed pair of windows shows each one biting. Setup can only run at 09:00 and the briefing only at 11:00, so the two are always exactly an hour apart, and the question is only whether that hour is acceptable:

```elixir
outcome = fn programme ->
  case Agenda.arrange(programme, rooms) do
    {:ok, _arrangements} -> :held
    {:error, _reason} -> :refused
  end
end

{:ok, immediately} = Agenda.precede(ordered, "Setup", "Briefing", within: "PT0S")
{:ok, within_30} = Agenda.precede(ordered, "Setup", "Briefing", within: "PT30M")
{:ok, within_2h} = Agenda.precede(ordered, "Setup", "Briefing", within: "PT2H")
{:ok, after_2h} = Agenda.precede(ordered, "Setup", "Briefing", gap: "PT2H")

{outcome.(immediately), outcome.(within_30), outcome.(within_2h), outcome.(after_2h)}
#=> {:refused, :refused, :held, :refused}
```

Read that row by row. `within: "PT0S"` is **immediately after** — the successor starts the instant the predecessor ends — and an hour's daylight between them refuses it. `within: "PT30M"` refuses for the same reason with more room. `within: "PT2H"` holds, because an hour is inside two. And `gap: "PT2H"` refuses from the other side: it demands *at least* two hours and only one is available.

So "immediately after" is `within: "PT0S"`, and "after, whenever" is no option at all. Everything else is a window between the two.

A refusal says which constraint did the refusing, and names the session on the other side of it:

```elixir
{:error, reason} = Agenda.arrange(immediately, rooms)

Agenda.explain(reason)
#=> "Day cannot be held: Briefing cannot be placed anywhere its ordering with Setup allows"
```

Only a constraint that refuses *every* candidate placement is named. A reason that accounts for some of them accounts for nothing, so where no single constraint explains the whole refusal the message falls back to saying the session could not be placed at all. The other three read the same way — a room already taken is a clash, two sessions in one track are a collision, and a resource worked past its `:limits` is a load limit — so the first line of a failure tells you which part of the programme to look at.

A chain is just two precedences, and the search enforces each independently rather than reasoning about the chain as a whole:

```elixir
three =
  ["Setup", "Talk", "Teardown"]
  |> Enum.reduce(Agenda.programme("Chain", across: day), fn name, acc ->
    Agenda.Programme.add_session(acc, talk.(name))
  end)

{:ok, chained} = Agenda.precede(three, "Setup", "Talk")
{:ok, chained} = Agenda.precede(chained, "Talk", "Teardown")

{:ok, arrangements} = Agenda.arrange(chained, rooms)

arrangements
|> Enum.sort_by(& &1.interval.from, Tempo)
|> Enum.map(& &1.session)
#=> ["Setup", "Talk", "Teardown"]
```

## A track is a set that cannot overlap itself

Three sessions that know nothing about each other are free to run at once, and with three rooms open that is exactly what happens:

```elixir
loose =
  ["T1", "T2", "T3"]
  |> Enum.reduce(Agenda.programme("Loose", across: day), fn name, acc ->
    Agenda.Programme.add_session(acc, talk.(name))
  end)

{:ok, parallel} = Agenda.arrange(loose, rooms)

parallel |> Enum.map(& &1.interval.from) |> Enum.uniq() |> length()
#=> 1
```

One distinct start time between them: all three at nine o'clock, one per room. Putting the same three in a track is what says *a delegate should be able to follow all of these*:

```elixir
{:ok, core} =
  Agenda.track("Core", of: Enum.map(["T1", "T2", "T3"], talk))
  |> Agenda.Track.reachable(within: ~o"PT15M")

tracked = Agenda.Programme.add_track(Agenda.programme("Tracked", across: day), core)

{:ok, sequence} = Agenda.arrange(tracked, rooms)

sequence |> Enum.map(& &1.interval.from) |> Enum.uniq() |> length()
#=> 3
```

Three distinct start times — nine, ten and eleven, and all three in Room A.

**Not overlapping is intrinsic to a track, not an option on one.** There is no `no_overlap: true` to remember, because a set of sessions that may collide with each other is already expressible: it is a list. `reachable/2` is the only choice a track offers, and it is about travel rather than collision.

## Keeping a track together

Non-overlap says nothing about *where*. A track can satisfy it perfectly while bouncing a delegate between rooms all morning, and the way to see that is to take a room away for an hour:

```elixir
patchy =
  Tempo.IntervalSet.new!([
    ~o"2027-03-01T09:00:00/2027-03-01T10:00:00",
    ~o"2027-03-01T11:00:00/2027-03-01T13:00:00"
  ])

closes_at_ten = Agenda.resource("Room A", within: level_1, seats: 100) |> Agenda.open!(patchy)
open_all_day = Agenda.resource("Room B", within: level_1, seats: 100) |> Agenda.open!(day)

pair = [closes_at_ten, open_all_day]

{:ok, bouncing} = Agenda.arrange(tracked, pair)

bouncing
|> Enum.sort_by(& &1.interval.from, Tempo)
|> Enum.map(fn arrangement ->
  arrangement |> Agenda.Arrangement.resource(:room) |> Map.get(:name)
end)
#=> ["Room A", "Room B", "Room A"]
```

Room A, Room B, Room A — out and back, because Room A is shut at ten and the search has no reason to care. Saying that you care is one line:

```elixir
{:ok, prefer_same_room} = Agenda.prefer(tracked, :room_changes, weight: 10)

{:ok, stays_put} = Agenda.arrange(prefer_same_room, pair)

stays_put
|> Enum.sort_by(& &1.interval.from, Tempo)
|> Enum.map(fn arrangement ->
  {arrangement.interval.from, arrangement |> Agenda.Arrangement.resource(:room) |> Map.get(:name)}
end)
#=> [{~o"2027Y3M1DT9H0M0S", "Room A"},
#=>  {~o"2027Y3M1DT11H0M0S", "Room A"},
#=>  {~o"2027Y3M1DT12H0M0S", "Room A"}]
```

It waited. Rather than step next door for the ten o'clock hour, the track sits out the closure and resumes at eleven in the same room — finishing an hour later than it needed to. That is what a soft constraint does: it spends something you did not explicitly protect. If finishing early mattered more, that is another preference, and their weights decide.

The two layouts are the same programme scored differently:

```elixir
{Agenda.explain_score(bouncing, prefer_same_room), Agenda.explain_score(stays_put, prefer_same_room)}
#=> {["room_changes: 2 × 10 = 20"], ["room_changes: 0 × 10 = 0"]}
```

Two changes at weight ten, against none. Penalties rather than rewards, so the layout you want scores zero.

## Same room is not the same as close by

`:room_changes` counts *changes*, not distance. Stepping next door and climbing a floor are both one change, and for the layout above that is the wrong reading: Room A and Room B are on the same level, so the delegate who "moved" did not actually walk anywhere.

Preferences are open, so the fix is to count what you actually mind. A preference is a name, a weight, and a function from the placements to a violation count, handed the programme and pool as context:

```elixir
far_apart = fn arrangements, %{programme: programme} ->
  Enum.reduce(programme.tracks, 0, fn track, total ->
    names = MapSet.new(Agenda.Track.session_names(track))

    journeys =
      arrangements
      |> Enum.filter(&MapSet.member?(names, &1.session))
      |> Enum.sort_by(& &1.interval.from, Tempo)
      |> Enum.map(&Agenda.Arrangement.resource(&1, :room))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [from, to] ->
        case Agenda.travel_time(from, to) do
          {:ok, journey} -> Tempo.Duration.compare(journey, ~o"PT0M") == :gt
          {:error, :unknown} -> false
        end
      end)

    total + journeys
  end)
end

{:ok, prefer_nearby} = Agenda.prefer(tracked, {:far_apart, far_apart}, weight: 10)
```

Scoring the very same out-and-back layout under each preference is the whole distinction in two numbers:

```elixir
{Agenda.explain_score(bouncing, prefer_same_room), Agenda.explain_score(bouncing, prefer_nearby)}
#=> {["room_changes: 2 × 10 = 20"], ["far_apart: 0 × 10 = 0"]}
```

Two room changes, no journeys. Neither number is wrong — they answer different questions, and which one you want depends on whether you are protecting a delegate's walk or a habit of staying put.

## Proximity as a hard rule

When the walk genuinely has to be possible rather than merely preferred, it belongs on the track. `reachable/2` reads the same place tree and asks whether consecutive sessions can actually be got between:

```elixir
morning_only = Agenda.resource("Room A", within: level_1, seats: 100)
  |> Agenda.open!(~o"2027-03-01T09:00:00/2027-03-01T10:00:00")
upstairs = Agenda.resource("Room C", within: level_2, seats: 100) |> Agenda.open!(day)

held = fn within ->
  {:ok, track} =
    Agenda.track("Pair", of: Enum.map(["T1", "T2"], talk))
    |> Agenda.Track.reachable(within: within)

  {:ok, arrangements} =
    Agenda.programme("Conf", across: day)
    |> Agenda.Programme.add_track(track)
    |> Agenda.arrange([morning_only, upstairs])

  arrangements
  |> Enum.sort_by(& &1.interval.from, Tempo)
  |> Enum.map(fn a -> {a.interval.from, a |> Agenda.Arrangement.resource(:room) |> Map.get(:name)} end)
end

{held.(~o"PT15M"), held.(~o"PT1M")}
#=> {[{~o"2027Y3M1DT9H0M0S", "Room A"}, {~o"2027Y3M1DT11H0M0S", "Room C"}],
#=>  [{~o"2027Y3M1DT9H0M0S", "Room C"}, {~o"2027Y3M1DT10H0M0S", "Room C"}]}
```

Tightening the rule changed *which rooms were used*, which is worth dwelling on. Given fifteen minutes, the track accepts the climb to Room C — and the ten o'clock slot goes unused, because the two talks are an hour apart rather than back to back. Given one minute, no journey between levels is possible at all, so the search abandons Room A, puts the whole track upstairs, and runs it back to back.

That hour is the part people trip over. **Reachability needs time, not just proximity.** Two sessions running back to back in different rooms are unreachable no matter how close the rooms are, because there is no interval in which to make the journey. A track of hourly talks with no gaps can only ever sit in one room, and tightening `:within` does not squeeze the timetable — it removes rooms from consideration.

## What to take away

* **`precede/4` is the pair, `:gap` and `:within` are the window.** `:gap` is a floor and `:within` a ceiling; "immediately after" is `within: "PT0S"`, and "after, eventually" is neither option.

* **A chain is just precedences.** Three sessions in order are two constraints, enforced independently.

* **Not overlapping is intrinsic to a track.** There is no option for it, because a set of sessions that may collide is already a list.

* **`reachable/2` is hard and needs time.** It reads travel from the place tree, and back-to-back sessions in different rooms fail it however close they are.

* **Preferences never make a layout invalid.** They make it worse, and a layout that satisfies every one of them scores zero.

* **Count what you actually mind.** `:room_changes` counts changes, not distance; if a step next door is fine and a floor is not, that is a dozen lines of your own preference over `travel_time/3`.
