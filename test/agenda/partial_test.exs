defmodule Agenda.PartialTest do
  use ExUnit.Case, async: true

  alias Agenda.Arranger
  alias Agenda.Infeasible
  alias Agenda.Layout
  alias Agenda.Programme
  alias Agenda.Session
  alias Agenda.Track

  doctest Agenda.Layout

  setup do
    venue = Agenda.place("Convention Centre")

    open = fn resource, span ->
      {:ok, resource} = Agenda.open(resource, span)
      resource
    end

    %{
      # Three hours of room.
      hall:
        open.(
          Agenda.resource("Hall", within: venue, seats: 100),
          "2026-09-15T09:00:00/2026-09-15T12:00:00"
        ),
      studio:
        open.(
          Agenda.resource("Studio", within: venue, seats: 100),
          "2026-09-15T09:00:00/2026-09-15T12:00:00"
        )
    }
  end

  defp talk(name) do
    name
    |> Agenda.session(duration: "PT1H")
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

  describe "unplaced: :error is the default" do
    test "an overconstrained programme still fails whole", context do
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:error, reason} = Arranger.arrange(programme, [context.hall])
      assert Agenda.explain(reason) =~ "Conf cannot be held"
    end

    test "passing :error explicitly is the same", context do
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:error, _reason} = Arranger.arrange(programme, [context.hall], unplaced: :error)
    end
  end

  describe "unplaced: :allow" do
    test "a programme that fits is still {:ok, arrangements}", context do
      programme = conf([talk("Keynote"), talk("Deep dive")])

      assert {:ok, arrangements} = Arranger.arrange(programme, [context.hall], unplaced: :allow)
      assert length(arrangements) == 2
    end

    test "leaves out the fewest sessions it can", context do
      # Three hours of room, four one-hour talks: three fit.
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:partial, layout} = Arranger.arrange(programme, [context.hall], unplaced: :allow)

      assert length(layout.placed) == 3
      assert length(layout.unplaced) == 1
    end

    test "the placements it does return are genuinely compatible", context do
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:partial, layout} = Arranger.arrange(programme, [context.hall], unplaced: :allow)

      for a <- layout.placed, b <- layout.placed, a.session != b.session do
        assert Tempo.disjoint?(a.interval, b.interval),
               "#{a.session} and #{b.session} both hold the Hall"
      end
    end

    test "a track that cannot fit gives up only its surplus", context do
      # A track cannot clash with itself, so six one-hour talks across
      # three hours of room can only ever place three.
      track = Agenda.track("T", of: Enum.map(1..6, &talk("S#{&1}")))

      assert {:partial, layout} =
               Arranger.arrange(conf([track]), [context.hall], unplaced: :allow)

      assert length(layout.placed) == 3
      assert length(layout.unplaced) == 3
    end

    test "two rooms place more than one", context do
      programme = conf(Enum.map(1..8, &talk("S#{&1}")))

      assert {:partial, layout} =
               Arranger.arrange(programme, [context.hall, context.studio], unplaced: :allow)

      # Two rooms, three hours each: six placements available.
      assert length(layout.placed) == 6
      assert length(layout.unplaced) == 2
    end

    test "a session nothing can satisfy is left out, not fatal", context do
      # The lecture needs 500 seats; nothing in the pool has them. On
      # the default that fails the programme outright.
      lecture =
        Agenda.session("Lecture", duration: "PT1H")
        |> Session.needs(:room, seats: 500)

      programme = conf([talk("Keynote"), lecture])

      assert {:error, _fatal} = Arranger.arrange(programme, [context.hall])

      assert {:partial, layout} = Arranger.arrange(programme, [context.hall], unplaced: :allow)
      assert Enum.map(layout.placed, & &1.session) == ["Keynote"]
      assert Layout.unplaced_sessions(layout) == ["Lecture"]
    end

    test "every session being impossible is a layout with nothing placed", context do
      lecture = fn name ->
        Agenda.session(name, duration: "PT1H") |> Session.needs(:room, seats: 500)
      end

      programme = conf([lecture.("One"), lecture.("Two")])

      assert {:partial, layout} = Arranger.arrange(programme, [context.hall], unplaced: :allow)
      assert layout.placed == []
      assert Layout.unplaced_sessions(layout) == ["One", "Two"]
    end
  end

  describe "branch and bound, not iterative deepening" do
    # Deepening searched for "all placed", then "all but one", then
    # "all but two" — finding *nothing* until it reached the right
    # round, and redoing every earlier round's work on each pass. A
    # badly overbooked programme exhausted the node cap and returned an
    # error where it could have returned most of a conference.

    defp overbooked(count, context) do
      conf(Enum.map(1..count, &talk("S#{&1}")))
      |> then(&{&1, [context.hall, context.studio]})
    end

    test "a heavily overbooked programme still answers within the default cap", context do
      # Two rooms across three hours hold six; twelve are offered.
      {programme, pool} = overbooked(12, context)

      assert {:partial, layout} = Arranger.arrange(programme, pool, unplaced: :allow)
      assert length(layout.placed) == 6
      assert length(layout.unplaced) == 6
    end

    test "and knows the answer is the best one", context do
      {programme, pool} = overbooked(12, context)

      assert {:partial, layout} = Arranger.arrange(programme, pool, unplaced: :allow)
      assert layout.minimal?
    end

    test "the capacity bound stops the search rather than proving the point", context do
      # Adding sessions past capacity must not cost more — the bound is
      # reached sooner, so the search stops sooner. Deepening got
      # steadily slower here until it gave up entirely.
      {small, pool} = overbooked(8, context)
      {large, ^pool} = overbooked(20, context)

      assert {:partial, from_small} = Arranger.arrange(small, pool, unplaced: :allow)
      assert {:partial, from_large} = Arranger.arrange(large, pool, unplaced: :allow)

      assert length(from_small.placed) == 6
      assert length(from_large.placed) == 6
      assert from_small.minimal? and from_large.minimal?
    end

    test "a feasible programme is unaffected", context do
      programme = conf([talk("Keynote"), talk("Deep dive")])

      assert {:ok, arrangements} = Arranger.arrange(programme, [context.hall], unplaced: :allow)
      assert length(arrangements) == 2
    end
  end

  describe "minimal? separates proved from best-so-far" do
    test "a completed search is minimal", context do
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:partial, layout} = Arranger.arrange(programme, [context.hall], unplaced: :allow)
      assert layout.minimal?
    end

    test "explain/1 stays quiet when the answer is proved", context do
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:partial, layout} = Arranger.arrange(programme, [context.hall], unplaced: :allow)
      refute Agenda.explain(layout) =~ "node limit"
    end

    test "explain/1 says so when it is only the best found" do
      layout = Layout.new("Conf", [], [Infeasible.new("X", ["nope"])], false)

      assert Agenda.explain(layout) =~ "node limit"
      assert Agenda.explain(layout) =~ "raise :nodes"
      refute layout.minimal?
    end

    test "a cap hit with nothing placed is still an error, not an empty layout", context do
      # Anytime means "return what was found", not "invent a result".
      programme = conf(Enum.map(["A", "B", "C"], &talk/1))

      assert {:error, reason} = Arranger.arrange(programme, [context.hall], nodes: 1)
      assert Agenda.explain(reason) =~ "node limit"
    end
  end

  describe "the layout says why" do
    test "an unplaceable session keeps the planner's reason", context do
      lecture =
        Agenda.session("Lecture", duration: "PT1H")
        |> Session.needs(:room, seats: 500)

      programme = conf([lecture])

      assert {:partial, layout} = Arranger.arrange(programme, [context.hall], unplaced: :allow)

      [reason] = layout.unplaced
      assert reason.session == "Lecture"
      assert Agenda.explain(reason) =~ "seats"
    end

    test "a session squeezed out by another says so", context do
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:partial, layout} = Arranger.arrange(programme, [context.hall], unplaced: :allow)

      [reason] = layout.unplaced
      assert Agenda.explain(reason) =~ "clashing with something already placed"
    end

    test "explain/1 counts what was placed", context do
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))

      assert {:partial, layout} = Arranger.arrange(programme, [context.hall], unplaced: :allow)

      assert Agenda.explain(layout) =~ "Conf: 3 of 4 sessions placed."
    end
  end

  describe "arrangements come back in programme order" do
    test "regardless of how constrained each session was", context do
      # The search orders by fewest candidates first; the caller should
      # not have to know that.
      wide = talk("Wide")

      narrow =
        Agenda.session("Narrow",
          duration: "PT1H",
          window: "2026-09-15T09:00:00/2026-09-15T10:00:00"
        )
        |> Session.needs(:room, seats: 100)

      programme = conf([wide, narrow])

      assert {:ok, arrangements} = Arranger.arrange(programme, [context.hall])
      assert Enum.map(arrangements, & &1.session) == ["Wide", "Narrow"]
    end
  end
end
