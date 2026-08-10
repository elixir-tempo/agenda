defmodule Agenda.PreferenceTest do
  use ExUnit.Case, async: true

  alias Agenda.Arrangement
  alias Agenda.Programme
  alias Agenda.Session
  alias Agenda.Track

  doctest Agenda.Preference

  setup do
    venue = Agenda.place("Venue")
    level = Agenda.place("Level 2", within: venue)

    open = fn resource ->
      {:ok, resource} = Agenda.open(resource, "2026-09-15T09:00:00/2026-09-15T13:00:00")
      resource
    end

    %{
      hall: open.(Agenda.resource("Hall", within: level, seats: 100)),
      studio: open.(Agenda.resource("Studio", within: level, seats: 100))
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

  defp rooms(arrangements) do
    Enum.map(arrangements, fn arrangement ->
      arrangement |> Arrangement.resources() |> Enum.map(& &1.name)
    end)
  end

  describe "declaring preferences" do
    test "a built-in is recognised" do
      assert {:ok, programme} = Agenda.prefer(Agenda.programme("Conf"), :room_changes)
      assert [%Agenda.Preference{name: :room_changes, weight: 1}] = programme.preferences
    end

    test "a weight is carried" do
      assert {:ok, programme} =
               Agenda.prefer(Agenda.programme("Conf"), :room_spread, weight: 7)

      assert [%{weight: 7}] = programme.preferences
    end

    test "an unknown name is an error, not silently ignored" do
      assert {:error, {:unknown_preference, :teleportation}} =
               Agenda.prefer(Agenda.programme("Conf"), :teleportation)
    end

    test "a custom preference is a name and a function" do
      counter = fn arrangements, _context -> length(arrangements) end

      assert {:ok, programme} =
               Agenda.prefer(Agenda.programme("Conf"), {:count_them, counter}, weight: 2)

      assert [%{name: :count_them, weight: 2}] = programme.preferences
    end
  end

  describe "room_changes" do
    test "a track that stays put beats one that moves", context do
      # Two talks in one track, two rooms free at both times. Without a
      # preference either layout is workable; with one, staying wins.
      track = Agenda.track("Core", of: [talk("First"), talk("Second")])
      {:ok, programme} = Agenda.prefer(conf([track]), :room_changes, weight: 10)

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.hall, context.studio])

      assert [first, second] = rooms(arrangements)
      assert first == second
    end

    test "the score is zero when nothing moves", context do
      track = Agenda.track("Core", of: [talk("First"), talk("Second")])
      {:ok, programme} = Agenda.prefer(conf([track]), :room_changes, weight: 10)

      {:ok, arrangements} = Agenda.arrange(programme, [context.hall, context.studio])

      assert Agenda.score(arrangements, programme) == 0
    end

    test "untracked sessions are not counted — they share no audience", context do
      {:ok, programme} =
        Agenda.prefer(conf([talk("One"), talk("Two")]), :room_changes, weight: 10)

      {:ok, arrangements} = Agenda.arrange(programme, [context.hall, context.studio])

      assert Agenda.score(arrangements, programme) == 0
    end
  end

  describe "room_spread" do
    test "it prefers using both rooms over piling into one", context do
      # Two simultaneous-capable talks; spreading scores better.
      {:ok, programme} =
        Agenda.prefer(conf([talk("One"), talk("Two")]), :room_spread, weight: 10)

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.hall, context.studio])

      used = arrangements |> rooms() |> List.flatten() |> Enum.uniq()
      assert length(used) == 2
    end

    test "one room in use is not an imbalance", context do
      {:ok, programme} = Agenda.prefer(conf([talk("Only")]), :room_spread, weight: 10)

      {:ok, arrangements} = Agenda.arrange(programme, [context.hall])

      assert Agenda.score(arrangements, programme) == 0
    end
  end

  describe "the lexicographic guarantee" do
    test "a preference never costs a placement", context do
      # Four one-hour talks, four hours of one room: all four fit, and
      # a preference must not trade one away for a prettier layout.
      programme = conf(Enum.map(["A", "B", "C", "D"], &talk/1))
      {:ok, preferred} = Agenda.prefer(programme, :room_spread, weight: 100)

      assert {:ok, plain} = Agenda.arrange(programme, [context.hall])
      assert {:ok, scored} = Agenda.arrange(preferred, [context.hall])

      assert length(plain) == length(scored)
      assert length(scored) == 4
    end

    test "and never costs one in a partial layout either", context do
      # Six talks, four hours, one room: four fit either way.
      programme = conf(Enum.map(1..6, &talk("S#{&1}")))
      {:ok, preferred} = Agenda.prefer(programme, :room_spread, weight: 100)

      assert {:partial, plain} =
               Agenda.arrange(programme, [context.hall], unplaced: :allow)

      assert {:partial, scored} =
               Agenda.arrange(preferred, [context.hall], unplaced: :allow)

      assert length(plain.placed) == length(scored.placed)
      assert scored.minimal?
    end
  end

  describe "score_proven?" do
    test "a completed search proves its score", context do
      # Six talks into four hours of one room: genuinely partial, so
      # there is a layout to carry the flag.
      {:ok, programme} = Agenda.prefer(conf(Enum.map(1..6, &talk("S#{&1}"))), :room_changes)

      assert {:partial, layout} =
               Agenda.arrange(programme, [context.hall], unplaced: :allow)

      assert layout.score_proven?
      assert layout.minimal?
    end

    test "hitting the node cap leaves the score unproven", context do
      {:ok, programme} = Agenda.prefer(conf(Enum.map(1..6, &talk("S#{&1}"))), :room_spread)

      case Agenda.arrange(programme, [context.hall], unplaced: :allow, nodes: 12) do
        {:partial, layout} -> refute layout.score_proven?
        {:error, _cap} -> :ok
      end
    end

    test "a layout carries its score", context do
      {:ok, programme} = Agenda.prefer(conf(Enum.map(1..6, &talk("S#{&1}"))), :room_spread)

      assert {:partial, layout} =
               Agenda.arrange(programme, [context.hall], unplaced: :allow)

      assert is_number(layout.score)
    end
  end

  describe "explaining a score" do
    test "each preference says what it contributed", context do
      track = Agenda.track("Core", of: [talk("First"), talk("Second")])

      {:ok, programme} = Agenda.prefer(conf([track]), :room_changes, weight: 10)
      {:ok, programme} = Agenda.prefer(programme, :room_spread, weight: 3)

      {:ok, arrangements} = Agenda.arrange(programme, [context.hall, context.studio])

      assert [changes, spread] = Agenda.explain_score(arrangements, programme)
      assert changes =~ "room_changes:"
      assert changes =~ "× 10"
      assert spread =~ "room_spread:"
      assert spread =~ "× 3"
    end

    test "a layout can be explained directly", context do
      {:ok, programme} = Agenda.prefer(conf(Enum.map(1..6, &talk("S#{&1}"))), :room_spread)

      {:partial, layout} = Agenda.arrange(programme, [context.hall], unplaced: :allow)

      assert [sentence] = Agenda.explain_score(layout, programme)
      assert sentence =~ "room_spread:"
    end
  end

  describe "no preferences costs nothing" do
    test "behaviour is identical to before", context do
      programme = conf(Enum.map(["A", "B", "C"], &talk/1))

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.hall])
      assert length(arrangements) == 3
      assert Agenda.score(arrangements, programme) == 0
    end

    test "and the search still stops at the capacity bound", context do
      # Without preferences the search may return as soon as it matches
      # the bound; with them it must keep looking. This guards the
      # first half of that.
      programme = conf(Enum.map(1..12, &talk("S#{&1}")))

      assert {:partial, layout} =
               Agenda.arrange(programme, [context.hall], unplaced: :allow)

      assert layout.minimal?
      assert length(layout.placed) == 4
    end
  end
end
