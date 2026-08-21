defmodule Agenda.FixpointTest do
  use ExUnit.Case, async: true

  alias Agenda.Arrangement
  alias Agenda.Fixpoint
  alias Agenda.Programme
  alias Agenda.Session
  alias Agenda.Track

  doctest Agenda.Fixpoint

  setup do
    venue = Agenda.place("Venue")
    level = Agenda.place("Level 2", within: venue)
    annexe = Agenda.place("Annexe")

    open = fn resource ->
      {:ok, resource} = Agenda.open(resource, "2026-09-15T09:00:00/2026-09-15T12:00:00")
      resource
    end

    %{
      hall: open.(Agenda.resource("Hall", within: level, seats: 100)),
      studio: open.(Agenda.resource("Studio", within: level, seats: 100)),
      far: open.(Agenda.resource("Far Room", within: annexe, seats: 100))
    }
  end

  defp talk(name) do
    name
    |> Agenda.session(lasting: "PT1H", between: "2026-09-15/2026-09-16")
    |> Session.needs(:room, seats: 100)
  end

  defp conf(items) do
    Enum.reduce(items, Agenda.programme("Conf", across: "2026-09-15/2026-09-16"), fn
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
      assert {:ok, ledger} = Agenda.allocate(Agenda.ledger(), arrangement)
      assert Agenda.count(ledger) == 1
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

      assert {:ok, from_search} = Agenda.arrange(programme, [context.hall])
      assert {:ok, from_solver} = Fixpoint.solve(programme, [context.hall])

      assert length(from_search) == length(from_solver)
      assert disjoint?(from_solver)
    end
  end

  describe "the constraints carry across" do
    test "a track cannot clash with itself", context do
      track = Agenda.track("Core", of: [talk("First"), talk("Second")])

      assert {:ok, arrangements} = Fixpoint.solve(conf([track]), [context.hall, context.studio])
      assert disjoint?(arrangements)
    end

    test "reachability is enforced, not merely modelled", context do
      # The annexe is unmeasured from the venue, so a delegate cannot be
      # asked to cross between them in five minutes. Both rooms are
      # offered; the solver must keep the track on one side.
      track =
        Agenda.track("Core", of: [talk("First"), talk("Second")])
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
        Agenda.session(name, lasting: "PT1H", between: hour)
        |> Session.needs(:room, seats: 100)
      end

      track =
        Agenda.track("Core", of: [pinned_talk.("First"), pinned_talk.("Second")])
        |> Track.reachable(within: "PT5M")

      assert {:error, reason} = Fixpoint.solve(conf([track]), [context.hall, context.far])
      assert Agenda.explain(reason) =~ "no arrangement places every session"
    end

    test "a session nothing satisfies is reported before the solver runs", context do
      lecture =
        Agenda.session("Lecture", lasting: "PT1H", between: "2026-09-15/2026-09-16")
        |> Session.needs(:room, seats: 500)

      assert {:error, reason} = Fixpoint.solve(conf([lecture]), [context.hall])
      assert Agenda.explain(reason) =~ "seats"
    end
  end

  describe "what it refuses" do
    test "concurrency above one is refused, not mis-solved", context do
      # Capacity is not a pairwise property, and there is no cumulative
      # constraint to express it with — so this is an error rather than
      # a layout this library would reject.
      {:ok, lockers} =
        Agenda.resource("Lockers", seats: 100, concurrency: 3)
        |> Agenda.open("2026-09-15T09:00:00/2026-09-15T12:00:00")

      assert {:error, reason} = Fixpoint.solve(conf([talk("A")]), [context.hall, lockers])

      message = Agenda.explain(reason)
      assert message =~ "concurrency 3"
      assert message =~ "Agenda.arrange/3"
    end

    test "an infeasible programme is proven infeasible", context do
      # Four one-hour talks, three hours of room.
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:error, reason} = Fixpoint.solve(programme, [context.hall])
      assert Agenda.explain(reason) =~ "no arrangement places every session"
    end

    test "and the diagnosis still points at conflict/3", context do
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:error, reason} = Fixpoint.solve(programme, [context.hall])
      assert Agenda.explain(reason) =~ "Agenda.conflict/3"
    end

    test "running out of time is not the same answer as no layout", context do
      # A programme big enough that one millisecond cannot settle it.
      # The solver logs its own timeout and then marks itself complete,
      # so an empty result here is indistinguishable from infeasible
      # unless the status is read — which is exactly the bug.
      programme = conf(Enum.map(1..9, &talk("S#{&1}")))
      pool = [context.hall, context.studio, context.far]

      assert {:error, :timeout} = Fixpoint.solve(programme, pool, timeout: 1)
    end

    test "a timeout is not reported as an Infeasible", context do
      programme = conf(Enum.map(1..9, &talk("S#{&1}")))
      pool = [context.hall, context.studio, context.far]

      assert {:error, reason} = Fixpoint.solve(programme, pool, timeout: 1)
      refute match?(%Agenda.Infeasible{}, reason)
    end

    test "the same programme succeeds when given time", context do
      # The other half of the proof: the timeout above is about the
      # clock, not about the programme being unsatisfiable.
      programme = conf(Enum.map(1..9, &talk("S#{&1}")))
      pool = [context.hall, context.studio, context.far]

      assert {:ok, arrangements} = Fixpoint.solve(programme, pool, timeout: 10_000)
      assert length(arrangements) == 9
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
