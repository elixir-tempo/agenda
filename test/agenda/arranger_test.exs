defmodule Agenda.ArrangerTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Arranger
  alias Agenda.Programme
  alias Agenda.Session
  alias Agenda.Track
  alias Tempo.Compare

  doctest Agenda.Arranger
  doctest Agenda.Track
  doctest Agenda.Programme

  setup do
    venue = Agenda.place("Convention Centre")
    level_2 = Agenda.place("Level 2", within: venue)
    level_3 = Agenda.place("Level 3", within: venue)
    across_town = Agenda.place("Annexe Building")

    open = fn resource ->
      {:ok, resource} = Agenda.open(resource, "2026-09-15T09:00:00/2026-09-15T12:00:00")
      resource
    end

    %{
      hall: open.(Agenda.resource("Hall", within: level_2, seats: 100)),
      studio: open.(Agenda.resource("Studio", within: level_2, seats: 100)),
      upstairs: open.(Agenda.resource("Upstairs", within: level_3, seats: 100)),
      far: open.(Agenda.resource("Far Room", within: across_town, seats: 100))
    }
  end

  defp talk(name) do
    name
    |> Agenda.session(lasting: "PT1H")
    |> Session.needs(:room, seats: 100)
  end

  defp conf(tracks_or_sessions) do
    Enum.reduce(
      tracks_or_sessions,
      Agenda.programme("Conf", across: "2026-09-15/2026-09-16"),
      fn
        %Track{} = track, programme -> Programme.add_track(programme, track)
        session, programme -> Programme.add_session(programme, session)
      end
    )
  end

  defp starts(arrangements) do
    arrangements
    |> Enum.map(& &1.interval.from)
    |> Enum.sort(&(Compare.compare_endpoints(&1, &2) in [:earlier, :same]))
  end

  describe "arrange/3 — a placement for every session" do
    test "places every session in the programme", context do
      programme = conf([talk("Keynote"), talk("Deep dive"), talk("Panel")])

      {:ok, arrangements} = Arranger.arrange(programme, [context.hall])

      assert length(arrangements) == 3

      assert Enum.map(arrangements, & &1.session) |> Enum.sort() ==
               ["Deep dive", "Keynote", "Panel"]
    end

    test "one room cannot hold two sessions at once", context do
      programme = conf([talk("Keynote"), talk("Deep dive")])

      {:ok, arrangements} = Arranger.arrange(programme, [context.hall])

      [a, b] = arrangements
      assert Tempo.disjoint?(a.interval, b.interval)
    end

    test "more sessions than slots is infeasible, and says which one", context do
      # Three hours of room, four one-hour talks.
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:error, reason} = Arranger.arrange(programme, [context.hall])
      assert Agenda.explain(reason) =~ "Conf cannot be held"
      assert Agenda.explain(reason) =~ "cannot be placed"
    end

    test "two rooms let two sessions run in parallel", context do
      programme = conf([talk("Keynote"), talk("Workshop")])

      {:ok, arrangements} = Arranger.arrange(programme, [context.hall, context.studio])

      # With two rooms the earliest slot can serve both.
      assert length(arrangements) == 2
    end

    test "sessions inherit the programme's window when they state none", context do
      session = talk("Keynote")
      assert is_nil(session.window)

      {:ok, [only]} = Arranger.arrange(conf([session]), [context.hall])

      assert Tempo.within?(only.interval, ~o"2026-09-15/2026-09-16")
    end
  end

  describe "arrange/3 — a track cannot clash with itself" do
    test "two sessions in one track never overlap", context do
      track = Agenda.track("Elixir", of: [talk("Keynote"), talk("Deep dive")])

      {:ok, arrangements} = Arranger.arrange(conf([track]), [context.hall, context.studio])

      [a, b] = arrangements
      assert Tempo.disjoint?(a.interval, b.interval)
    end

    test "sessions in different tracks may run at the same time", context do
      elixir = Agenda.track("Elixir", of: [talk("Keynote")])
      erlang = Agenda.track("Erlang", of: [talk("BEAM internals")])

      {:ok, arrangements} =
        Arranger.arrange(conf([elixir, erlang]), [context.hall, context.studio])

      assert [start, start] = starts(arrangements)
    end
  end

  describe "arrange/3 — reachability between consecutive track sessions" do
    test "a same-level journey fits a back-to-back-plus-gap track", context do
      # Hall and Studio are on the same level: no travel time at all.
      track =
        "Elixir"
        |> Agenda.track(of: [talk("Keynote"), talk("Deep dive")])
        |> Track.reachable(within: ~o"PT10M")

      assert {:ok, arrangements} =
               Arranger.arrange(conf([track]), [context.hall, context.studio])

      assert length(arrangements) == 2
    end

    # Each room below is open for exactly one slot, so the two talks
    # cannot share a room and the cross-room journey is unavoidable.
    # Without that, the arranger rightly puts both in one room and no
    # journey is ever made — the constraint would go untested.
    defp only_at(name, place, window) do
      {:ok, room} = Agenda.open(Agenda.resource(name, within: place, seats: 100), window)
      room
    end

    test "an unmeasured journey is never assumed short" do
      venue = Agenda.place("Convention Centre")
      elsewhere = Agenda.place("Annexe Building")

      first = only_at("Hall", venue, "2026-09-15T09:00:00/2026-09-15T10:00:00")
      second = only_at("Far Room", elsewhere, "2026-09-15T10:30:00/2026-09-15T11:30:00")

      track =
        "Elixir"
        |> Agenda.track(of: [talk("Keynote"), talk("Deep dive")])
        |> Track.reachable(within: ~o"PT10M")

      assert {:error, reason} = Arranger.arrange(conf([track]), [first, second])
      assert Agenda.explain(reason) =~ "cannot be placed"
    end

    test "a journey longer than the track allows is rejected" do
      venue = Agenda.place("Convention Centre")
      level_2 = Agenda.place("Level 2", within: venue)
      level_3 = Agenda.place("Level 3", within: venue)

      first = only_at("Hall", level_2, "2026-09-15T09:00:00/2026-09-15T10:00:00")
      second = only_at("Upstairs", level_3, "2026-09-15T10:30:00/2026-09-15T11:30:00")

      # Hall to Upstairs is a 5-minute walk by the default table.
      too_tight =
        "Elixir"
        |> Agenda.track(of: [talk("Keynote"), talk("Deep dive")])
        |> Track.reachable(within: ~o"PT1M")

      assert {:error, _reason} = Arranger.arrange(conf([too_tight]), [first, second])

      generous = Track.reachable(too_tight, within: ~o"PT30M")

      assert {:ok, arrangements} = Arranger.arrange(conf([generous]), [first, second])
      assert length(arrangements) == 2
    end

    test "the same journey is fine when the track allows enough time", context do
      track =
        "Elixir"
        |> Agenda.track(of: [talk("Keynote"), talk("Deep dive")])
        |> Track.reachable(within: ~o"PT30M")

      assert {:ok, arrangements} =
               Arranger.arrange(conf([track]), [context.hall, context.upstairs])

      assert length(arrangements) == 2
    end

    test "a per-pair override rescues an otherwise unreachable pair", context do
      track =
        "Elixir"
        |> Agenda.track(of: [talk("Keynote"), talk("Deep dive")])
        |> Track.reachable(within: ~o"PT10M")

      options = [travel: [between: [{{"Hall", "Far Room"}, ~o"PT0S"}]]]

      assert {:ok, arrangements} =
               Arranger.arrange(conf([track]), [context.hall, context.far], options)

      assert length(arrangements) == 2
    end

    test "a placeless resource does not make every journey unknown" do
      # People travel with the session; they have no place of their own.
      # Counting them as a leg would make every journey unmeasurable and
      # every reachable track infeasible.
      venue = Agenda.place("Convention Centre")
      level_2 = Agenda.place("Level 2", within: venue)
      level_3 = Agenda.place("Level 3", within: venue)

      first = only_at("Hall", level_2, "2026-09-15T09:00:00/2026-09-15T10:00:00")
      second = only_at("Upstairs", level_3, "2026-09-15T10:30:00/2026-09-15T11:30:00")
      speaker = Agenda.resource("Speaker")
      {:ok, speaker} = Agenda.open(speaker, "2026-09-15T09:00:00/2026-09-15T12:00:00")

      with_speaker = fn name ->
        name |> talk() |> Session.roster(:speaker, [speaker])
      end

      track =
        "Elixir"
        |> Agenda.track(of: [with_speaker.("Keynote"), with_speaker.("Deep dive")])
        |> Track.reachable(within: ~o"PT30M")

      assert {:ok, arrangements} = Arranger.arrange(conf([track]), [first, second, speaker])
      assert length(arrangements) == 2
    end

    test "reachability is not applied to untracked sessions", context do
      # Two standalone sessions may use unrelated rooms freely.
      programme = conf([talk("Keynote"), talk("Deep dive")])

      assert {:ok, arrangements} = Arranger.arrange(programme, [context.hall, context.far])
      assert length(arrangements) == 2
    end
  end

  describe "arrange/3 — interchangeable sessions are placed once, not permuted" do
    # Look-alike sessions produce identical subproblems under any
    # ordering, so the search fixes a canonical one. These tests guard
    # the two ways that can go wrong: losing a valid arrangement, and
    # constraining sessions that were never interchangeable.

    defp packed(count, hours) do
      venue = Agenda.place("Venue")

      {:ok, room} =
        Agenda.resource("Room", within: venue, seats: 100)
        |> Agenda.open("2026-09-15T09:00:00/2026-09-15T#{9 + hours}:00:00")

      programme =
        conf([Agenda.track("T", of: Enum.map(1..count, &talk("S#{&1}")))])

      {programme, room}
    end

    test "an exact packing is still found" do
      {programme, room} = packed(6, 6)

      assert {:ok, arrangements} = Arranger.arrange(programme, [room])
      assert length(arrangements) == 6

      # Every hour used exactly once.
      assert arrangements |> Enum.map(& &1.interval.from) |> Enum.uniq() |> length() == 6
    end

    test "an impossible packing is proven impossible, not merely given up on" do
      # Before symmetry breaking this exhausted the node budget instead
      # of concluding anything, because it walked every permutation.
      {programme, room} = packed(9, 8)

      assert {:error, reason} = Arranger.arrange(programme, [room], nodes: 5_000)

      message = Agenda.explain(reason)
      assert message =~ "cannot be placed"
      refute message =~ "node limit"
    end

    test "sessions of different lengths are not treated as interchangeable" do
      venue = Agenda.place("Venue")

      {:ok, room} =
        Agenda.resource("Room", within: venue, seats: 100)
        |> Agenda.open("2026-09-15T09:00:00/2026-09-15T12:00:00")

      long =
        Agenda.session("Long", lasting: "PT2H")
        |> Session.needs(:room, seats: 100)

      short =
        Agenda.session("Short", lasting: "PT1H")
        |> Session.needs(:room, seats: 100)

      programme = conf([Agenda.track("T", of: [long, short])])

      assert {:ok, arrangements} = Arranger.arrange(programme, [room])
      assert length(arrangements) == 2

      assert Enum.all?(arrangements, &Tempo.within?(&1.interval, ~o"2026-09-15/2026-09-16"))
    end

    test "look-alike sessions in different tracks are independent" do
      venue = Agenda.place("Venue")

      rooms =
        for name <- ["A", "B"] do
          {:ok, room} =
            Agenda.resource(name, within: venue, seats: 100)
            |> Agenda.open("2026-09-15T09:00:00/2026-09-15T10:00:00")

          room
        end

      # One hour, two rooms, one identical talk in each of two tracks:
      # only possible if the tracks are not symmetry-linked.
      programme =
        conf([
          Agenda.track("One", of: [talk("X")]),
          Agenda.track("Two", of: [talk("Y")])
        ])

      assert {:ok, arrangements} = Arranger.arrange(programme, rooms)
      assert length(arrangements) == 2
    end
  end

  describe "arrange/3 — the caps are reported, never silent" do
    test "hitting the node cap is an error naming the limit", context do
      programme = conf(Enum.map(["A", "B", "C"], &talk/1))

      assert {:error, reason} = Arranger.arrange(programme, [context.hall], nodes: 1)

      message = Agenda.explain(reason)
      assert message =~ "node limit"
      assert message =~ ":nodes"
    end

    test "a truncated candidate list is not passed off as complete", context do
      # One candidate per session, and three sessions needing distinct
      # slots, cannot succeed — the cap must surface rather than return
      # a partial programme.
      programme = conf(Enum.map(["A", "B", "C"], &talk/1))

      assert {:error, _reason} = Arranger.arrange(programme, [context.hall], candidates: 1)
    end

    test "a generous cap solves what a tight one cannot", context do
      programme = conf(Enum.map(["A", "B", "C"], &talk/1))

      assert {:error, _} = Arranger.arrange(programme, [context.hall], candidates: 1)
      assert {:ok, _} = Arranger.arrange(programme, [context.hall], candidates: 40)
    end
  end

  describe "arrange/3 — a track's reachability is any availability pattern" do
    test "a duration written as a string is read, not crashed on", context do
      # `Track.reachable/2` accepts anything `Agenda.open/2` does,
      # so the arranger must parse it rather than assume a struct.
      track =
        Agenda.track("T", of: [talk("First"), talk("Second")])
        |> Track.reachable(within: "PT10M")

      assert {:ok, arrangements} = Arranger.arrange(conf([track]), [context.hall])
      assert length(arrangements) == 2
    end

    test "a string and a sigil agree", context do
      as_string = Track.reachable(Agenda.track("T", of: [talk("A")]), within: "PT10M")
      as_sigil = Track.reachable(Agenda.track("T", of: [talk("A")]), within: ~o"PT10M")

      assert Arranger.arrange(conf([as_string]), [context.hall]) ==
               Arranger.arrange(conf([as_sigil]), [context.hall])
    end

    test "something that is not a duration is an error, not a crash", context do
      track =
        Agenda.track("T", of: [talk("First"), talk("Second")])
        |> Track.reachable(within: "not a duration")

      assert {:error, reason} = Arranger.arrange(conf([track]), [context.hall])
      assert Agenda.explain(reason) =~ "which is not a duration"
    end

    test "an interval is not a duration either", context do
      track =
        Agenda.track("T", of: [talk("First")])
        |> Track.reachable(within: "2026-09-15/2026-09-16")

      assert {:error, reason} = Arranger.arrange(conf([track]), [context.hall])
      assert Agenda.explain(reason) =~ "which is not a duration"
    end
  end
end
