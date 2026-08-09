defmodule Timetable.FixpointTest do
  use ExUnit.Case, async: true

  alias Timetable.Arrangement
  alias Timetable.Fixpoint
  alias Timetable.Programme
  alias Timetable.Session
  alias Timetable.Track

  doctest Timetable.Fixpoint

  setup do
    venue = Timetable.place("Venue")
    level = Timetable.place("Level 2", within: venue)
    annexe = Timetable.place("Annexe")

    open = fn resource ->
      {:ok, resource} = Timetable.open(resource, "2026-09-15T09:00:00/2026-09-15T12:00:00")
      resource
    end

    %{
      hall: open.(Timetable.resource("Hall", within: level, seats: 100)),
      studio: open.(Timetable.resource("Studio", within: level, seats: 100)),
      far: open.(Timetable.resource("Far Room", within: annexe, seats: 100))
    }
  end

  defp talk(name) do
    name
    |> Timetable.session(lasting: "PT1H", between: "2026-09-15/2026-09-16")
    |> Session.needs(:room, seats: 100)
  end

  defp conf(items) do
    Enum.reduce(items, Timetable.programme("Conf", across: "2026-09-15/2026-09-16"), fn
      %Track{} = track, programme -> Programme.add_track(programme, track)
      session, programme -> Programme.add_session(programme, session)
    end)
  end

  defp disjoint?(arrangements) do
    for a <- arrangements, b <- arrangements, a.session != b.session do
      Tempo.disjoint?(a.interval, b.interval)
    end
    |> Enum.all?()
  end

  describe "solving" do
    test "it places every session", context do
      programme = conf(Enum.map(["A", "B", "C"], &talk/1))

      assert {:ok, arrangements} = Fixpoint.solve(programme, [context.hall])
      assert length(arrangements) == 3
    end

    test "and the layout is genuinely valid", context do
      programme = conf(Enum.map(["A", "B", "C"], &talk/1))

      assert {:ok, arrangements} = Fixpoint.solve(programme, [context.hall])
      assert disjoint?(arrangements)
    end

    test "the answer is ordinary arrangements the ledger accepts", context do
      programme = conf([talk("Keynote")])

      assert {:ok, [%Arrangement{} = arrangement]} = Fixpoint.solve(programme, [context.hall])
      assert {:ok, ledger} = Timetable.allocate(Timetable.ledger(), arrangement)
      assert Timetable.count(ledger) == 1
    end

    test "two rooms let two sessions run at once", context do
      programme = conf([talk("A"), talk("B")])

      assert {:ok, arrangements} = Fixpoint.solve(programme, [context.hall, context.studio])
      assert length(arrangements) == 2
    end

    test "it agrees with arrange/3 on what is feasible", context do
      # Both are exact for the all-or-nothing question, so they must
      # never disagree about whether a programme can be laid out.
      programme = conf(Enum.map(["A", "B", "C"], &talk/1))

      assert {:ok, from_search} = Timetable.arrange(programme, [context.hall])
      assert {:ok, from_solver} = Fixpoint.solve(programme, [context.hall])

      assert length(from_search) == length(from_solver)
      assert disjoint?(from_solver)
    end
  end

  describe "the constraints carry across" do
    test "a track cannot clash with itself", context do
      track = Timetable.track("Core", of: [talk("First"), talk("Second")])

      assert {:ok, arrangements} = Fixpoint.solve(conf([track]), [context.hall, context.studio])
      assert disjoint?(arrangements)
    end

    test "reachability is enforced, not merely modelled", context do
      # The annexe is unmeasured from the venue, so a delegate cannot be
      # asked to cross between them in five minutes. Both rooms are
      # offered; the solver must keep the track on one side.
      track =
        Timetable.track("Core", of: [talk("First"), talk("Second")])
        |> Track.reachable(within: "PT5M")

      assert {:ok, arrangements} = Fixpoint.solve(conf([track]), [context.hall, context.far])

      places =
        arrangements
        |> Enum.flat_map(&Arrangement.resources/1)
        |> Enum.map(& &1.within.name)
        |> Enum.uniq()

      assert length(places) == 1
    end

    test "and a track split across an unmeasured gap has no layout", context do
      # Two sessions that must be simultaneous cannot share a room, so
      # the only layout would straddle the unmeasured gap — and there
      # is none.
      hour = "2026-09-15T09:00:00/2026-09-15T10:00:00"

      pinned_talk = fn name ->
        Timetable.session(name, lasting: "PT1H", between: hour)
        |> Session.needs(:room, seats: 100)
      end

      track =
        Timetable.track("Core", of: [pinned_talk.("First"), pinned_talk.("Second")])
        |> Track.reachable(within: "PT5M")

      assert {:error, reason} = Fixpoint.solve(conf([track]), [context.hall, context.far])
      assert Timetable.explain(reason) =~ "no arrangement places every session"
    end

    test "a session nothing satisfies is reported before the solver runs", context do
      lecture =
        Timetable.session("Lecture", lasting: "PT1H", between: "2026-09-15/2026-09-16")
        |> Session.needs(:room, seats: 500)

      assert {:error, reason} = Fixpoint.solve(conf([lecture]), [context.hall])
      assert Timetable.explain(reason) =~ "seats"
    end
  end

  describe "what it refuses" do
    test "concurrency above one is refused, not mis-solved", context do
      # Capacity is not a pairwise property, and there is no cumulative
      # constraint to express it with — so this is an error rather than
      # a layout this library would reject.
      {:ok, lockers} =
        Timetable.resource("Lockers", seats: 100, concurrency: 3)
        |> Timetable.open("2026-09-15T09:00:00/2026-09-15T12:00:00")

      assert {:error, reason} = Fixpoint.solve(conf([talk("A")]), [context.hall, lockers])

      message = Timetable.explain(reason)
      assert message =~ "concurrency 3"
      assert message =~ "Timetable.arrange/3"
    end

    test "an infeasible programme is proven infeasible", context do
      # Four one-hour talks, three hours of room.
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:error, reason} = Fixpoint.solve(programme, [context.hall])
      assert Timetable.explain(reason) =~ "no arrangement places every session"
    end

    test "and the diagnosis still points at conflict/3", context do
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:error, reason} = Fixpoint.solve(programme, [context.hall])
      assert Timetable.explain(reason) =~ "Timetable.conflict/3"
    end
  end

  describe "scale" do
    test "it handles a programme the built-in search gives up on", context do
      # Twelve sessions across three rooms and three hours: nine slots,
      # so this is infeasible, but the point is that the solver reaches
      # a verdict rather than exhausting a node budget.
      programme = conf(Enum.map(1..10, &talk("S#{&1}")))
      pool = [context.hall, context.studio, context.far]

      assert {:error, _proven} = Fixpoint.solve(programme, pool, timeout: 5_000)
    end

    test "a nine-session exact packing is found", context do
      # Three rooms, three hours, nine one-hour talks: exactly full.
      programme = conf(Enum.map(1..9, &talk("S#{&1}")))
      pool = [context.hall, context.studio, context.far]

      assert {:ok, arrangements} = Fixpoint.solve(programme, pool, timeout: 10_000)
      assert length(arrangements) == 9

      # Every room-hour used exactly once.
      slots =
        Enum.map(arrangements, fn arrangement ->
          room = arrangement |> Arrangement.resources() |> hd() |> Map.get(:name)
          {room, arrangement.interval.from.time[:hour]}
        end)

      assert length(Enum.uniq(slots)) == 9
    end
  end
end
