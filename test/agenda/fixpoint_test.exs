defmodule Agenda.FixpointTest do
  # Deliberately not async. Every test here is bounded by a wall clock:
  # the solver runs concurrently and returns whatever it has when the
  # timeout fires, so its result depends on how much CPU it actually
  # got. Sharing the machine with nineteen other cases turns that into
  # a coin toss — one of these was observed taking 4.3 s on one run and
  # 7.1 s on the next, on an idle machine, against the same budget.
  #
  # Running them alone does not make the solver deterministic, but it
  # removes the variance this suite controls. The generous timeouts
  # below cover the rest, and cost nothing on the tests that return as
  # soon as the solver finishes.
  use ExUnit.Case, async: false

  # Above every solver budget below, so the solver's own timeout is
  # always the binding constraint. Left at ExUnit's 60 s default, a
  # test given a 60 s budget would be killed by the framework first and
  # report "test timed out" instead of the assertion that actually
  # failed.
  @moduletag timeout: 180_000

  import Tempo.Sigils

  alias Agenda.Arrangement
  alias Agenda.Fixpoint
  alias Agenda.Limit
  alias Agenda.Programme
  alias Agenda.Session
  alias Agenda.Track
  alias Tempo.IntervalSet

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
    |> Agenda.session(duration: "PT1H", between: "2026-09-15/2026-09-16")
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

  # `{:error, :timeout}` says the search ran out of clock. The bridge is
  # explicit that this is a *different fact* from "no layout exists", and
  # a test that asserts a definite answer is asking about the programme,
  # not about how much CPU this machine happened to spare. On a loaded
  # runner any of these can hit the budget, so give the solver more time
  # rather than failing a build over scheduling noise. Still unsettled at
  # four times the budget is a real failure, and reports as one.
  defp settled(programme, pool, options) do
    case Fixpoint.solve(programme, pool, options) do
      {:error, :timeout} ->
        Fixpoint.solve(programme, pool, Keyword.update!(options, :timeout, &(&1 * 4)))

      settled ->
        settled
    end
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
        Agenda.session(name, duration: "PT1H", between: hour)
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
        Agenda.session("Lecture", duration: "PT1H", between: "2026-09-15/2026-09-16")
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

      assert {:ok, arrangements} = settled(programme, pool, timeout: 10_000)
      assert length(arrangements) == 9
    end
  end

  describe "scale" do
    test "a dense infeasible programme is abandoned, not proved", context do
      # Ten one-hour talks into nine room-hours: genuinely impossible.
      # The solver does not discover that — it neither finds a layout nor
      # proves there is none, at 5 s, 20 s or 60 s. This is the case a
      # caller must not misread: `{:error, :timeout}` says nobody
      # finished looking, and reading it as "impossible" would be wrong
      # even here, where impossible happens to be the truth.
      #
      # Pinned deliberately. If a future fixpoint proves this instance,
      # this test fails and the claim above needs rewriting.
      programme = conf(Enum.map(1..10, &talk("S#{&1}")))
      pool = [context.hall, context.studio, context.far]

      assert {:error, :timeout} = Fixpoint.solve(programme, pool, timeout: 5_000)
    end

    test "a nine-session exact packing is found", context do
      # Three rooms, three hours, nine one-hour talks: exactly full.
      programme = conf(Enum.map(1..9, &talk("S#{&1}")))
      pool = [context.hall, context.studio, context.far]

      assert {:ok, arrangements} = settled(programme, pool, timeout: 10_000)
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

  describe "load limits" do
    # Three days of three one-hour slots, one person. Small enough that
    # the whole candidate list fits in the model, so a proof means the
    # programme rather than the truncation.
    defp days(limits) do
      hours =
        IntervalSet.new!(
          for day <- 5..7 do
            Tempo.from_iso8601!("2027-04-0#{day}T09:00:00/2027-04-0#{day}T11:00:00")
          end
        )

      {:ok, ann} = Agenda.open(Agenda.resource("Ann", qualified: true, limits: limits), hours)
      ann
    end

    defp shifts(count) do
      Enum.reduce(
        1..count,
        Agenda.programme("Roster", across: "2027-04-05/2027-04-08"),
        fn index, programme ->
          session =
            "S#{index}"
            |> Agenda.session(duration: "PT1H", between: "2027-04-05/2027-04-08")
            |> Session.needs(:staff, qualified: true)

          Programme.add_session(programme, session)
        end
      )
    end

    defp respects?(arrangements, resource) do
      Enum.all?(resource.limits, fn limit ->
        arrangements
        |> Enum.group_by(&Limit.bucket(&1.interval.from, limit.period))
        |> Enum.all?(fn {_bucket, held} ->
          {count, duration} = Limit.sum(held)
          Limit.permits?(limit, count, duration)
        end)
      end)
    end

    test "a count limit is enforced rather than ignored" do
      ann = days(day: 1)

      assert {:ok, arrangements} =
               settled(shifts(3), [ann], candidates: 6, timeout: 60_000)

      assert length(arrangements) == 3
      assert respects?(arrangements, ann)

      # One a day, so one on each of the three days.
      assert arrangements |> Enum.map(& &1.interval.from.time[:day]) |> Enum.sort() == [5, 6, 7]
    end

    test "a duration limit is enforced rather than ignored" do
      ann = days(day: ~o"PT1H")

      assert {:ok, arrangements} =
               settled(shifts(3), [ann], candidates: 6, timeout: 60_000)

      assert length(arrangements) == 3
      assert respects?(arrangements, ann)

      # One hour a day and one-hour shifts, so one on each day.
      assert arrangements |> Enum.map(& &1.interval.from.time[:day]) |> Enum.sort() == [5, 6, 7]
    end

    test "a programme that cannot fit inside the limit is proved impossible" do
      # Four one-hour shifts, one a day, three days.
      ann = days(day: 1)

      assert {:error, %Agenda.Infeasible{}} =
               settled(shifts(4), [ann], candidates: 6, timeout: 60_000)
    end

    test "the same programme fits once the limit allows it" do
      assert {:ok, arrangements} =
               settled(shifts(4), [days(day: 2)], candidates: 6, timeout: 60_000)

      assert length(arrangements) == 4
    end

    test "a duration limit and the count limit it is equivalent to agree" do
      # One hour a day and one one-hour shift a day are the same
      # contract written two ways, so they must decide alike — on the
      # programme that fits, and on the one that cannot.
      assert {:ok, counted} =
               settled(shifts(3), [days(day: 1)], candidates: 6, timeout: 60_000)

      assert {:ok, timed} =
               settled(shifts(3), [days(day: ~o"PT1H")], candidates: 6, timeout: 60_000)

      assert length(counted) == length(timed)

      assert {:error, %Agenda.Infeasible{}} =
               settled(shifts(4), [days(day: ~o"PT1H")], candidates: 6, timeout: 60_000)
    end

    test "a floor is ignored, exactly as the built-in search ignores it" do
      # A floor no layout could reach must not cost a placement.
      ann = days(week: [at_least: ~o"PT500H"])

      assert {:ok, arrangements} =
               settled(shifts(3), [ann], candidates: 6, timeout: 60_000)

      assert length(arrangements) == 3
    end

    test "claims already in the ledger come off the budget" do
      ann = days(day: 1)

      # Ann already has the 5th. One more shift must go elsewhere.
      busy = %{"Ann" => [Tempo.from_iso8601!("2027-04-05T09:00:00/2027-04-05T10:00:00")]}

      assert {:ok, arrangements} =
               settled(shifts(2), [ann], candidates: 6, busy: busy, timeout: 60_000)

      days_used = arrangements |> Enum.map(& &1.interval.from.time[:day]) |> Enum.sort()
      refute 5 in days_used
    end
  end
end
