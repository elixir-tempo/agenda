defmodule Agenda.PinningTest do
  use ExUnit.Case, async: true

  alias Agenda.Arranger
  alias Agenda.Ledger
  alias Agenda.Programme
  alias Agenda.Session
  alias Agenda.Track
  alias Tempo.Compare

  setup do
    venue = Agenda.place("Convention Centre")
    level_2 = Agenda.place("Level 2", within: venue)
    across_town = Agenda.place("Annexe Building")

    open = fn resource ->
      {:ok, resource} = Agenda.open(resource, "2026-09-15T09:00:00/2026-09-15T12:00:00")
      resource
    end

    %{
      hall: open.(Agenda.resource("Hall", within: level_2, seats: 100)),
      studio: open.(Agenda.resource("Studio", within: level_2, seats: 100)),
      far: open.(Agenda.resource("Far Room", within: across_town, seats: 100))
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

  defp starting_at(arrangements, session) do
    arrangements |> Enum.find(&(&1.session == session)) |> Map.get(:interval) |> Map.get(:from)
  end

  defp same_moment?(a, b), do: Compare.compare_endpoints(a, b) == :same

  # A placement for `session` at the `nth` slot the search would offer.
  defp placement(programme, pool, session, nth) do
    {:ok, arrangements} = Agenda.plan(pick(programme, session), pool, limit: 10)

    arrangements |> Enum.at(nth) |> Map.put(:session, session)
  end

  defp pick(programme, name) do
    programme
    |> Programme.all_sessions()
    |> Enum.find(&(&1.name == name))
    |> Map.put(:window, programme.window)
  end

  describe "a pin is honoured" do
    test "the pinned session keeps exactly its placement", context do
      programme = conf([talk("Keynote"), talk("Deep dive")])
      pin = placement(programme, [context.hall], "Keynote", 2)

      assert {:ok, arrangements} = Arranger.arrange(programme, [context.hall], pinned: [pin])

      assert same_moment?(starting_at(arrangements, "Keynote"), pin.interval.from)
    end

    test "the pinned session is returned alongside the searched ones", context do
      programme = conf([talk("Keynote"), talk("Deep dive"), talk("Panel")])
      pin = placement(programme, [context.hall], "Keynote", 0)

      assert {:ok, arrangements} = Arranger.arrange(programme, [context.hall], pinned: [pin])

      assert Enum.map(arrangements, & &1.session) == ["Keynote", "Deep dive", "Panel"]
    end

    test "other sessions move out of the pin's way", context do
      # One room, three hours, three talks. Pinning the keynote to the
      # last hour leaves the other two the first two.
      programme = conf([talk("Keynote"), talk("Deep dive"), talk("Panel")])
      pin = placement(programme, [context.hall], "Keynote", 2)

      assert {:ok, arrangements} = Arranger.arrange(programme, [context.hall], pinned: [pin])

      for a <- arrangements, b <- arrangements, a.session != b.session do
        assert Tempo.disjoint?(a.interval, b.interval)
      end
    end

    test "a pin can make an otherwise feasible programme infeasible", context do
      # Two talks, one room open 09:00-12:00, but the studio pin takes
      # the hall's only remaining slot away.
      programme = conf([talk("A"), talk("B"), talk("C")])
      pin = placement(programme, [context.hall], "A", 0)

      # Fine with three hours for three talks.
      assert {:ok, _all} = Arranger.arrange(programme, [context.hall], pinned: [pin])

      # Not fine once a fourth talk is added.
      four = conf([talk("A"), talk("B"), talk("C"), talk("D")])
      assert {:error, _reason} = Arranger.arrange(four, [context.hall], pinned: [pin])
    end
  end

  describe "pins are constrained like anything else" do
    test "a pin occupies its room for the sessions that move", context do
      programme = conf([talk("Keynote"), talk("Deep dive")])
      pin = placement(programme, [context.hall], "Keynote", 0)

      assert {:ok, arrangements} = Arranger.arrange(programme, [context.hall], pinned: [pin])

      moved = starting_at(arrangements, "Deep dive")
      refute same_moment?(moved, pin.interval.from)
    end

    test "a pin counts against a track's reachability", context do
      # The annexe is open for the first hour only, so pinning "First"
      # there forces "Second" into the convention centre. The journey
      # between the two is unmeasured, and an unmeasured route is not a
      # short one — so the track cannot be walked and the programme
      # fails.
      {:ok, annexe} =
        Agenda.resource("Far Room", within: Agenda.place("Annexe Building"), seats: 100)
        |> Agenda.open("2026-09-15T09:00:00/2026-09-15T10:00:00")

      track =
        Agenda.track("T", of: [talk("First"), talk("Second")])
        |> Track.reachable(within: "PT5M")

      programme = conf([track])
      pin = placement(programme, [annexe], "First", 0)

      assert {:error, reason} =
               Arranger.arrange(programme, [context.hall, annexe], pinned: [pin])

      assert Agenda.explain(reason) =~ "cannot be placed"
    end

    test "a pinned session still respects concurrency" do
      {:ok, bank} =
        Agenda.resource("Lockers", seats: 100, concurrency: 2)
        |> Agenda.open("2026-09-15T09:00:00/2026-09-15T10:00:00")

      # One hour, concurrency 2, three talks: the third has nowhere.
      programme = conf([talk("A"), talk("B"), talk("C")])
      pin = placement(programme, [bank], "A", 0)

      assert {:partial, layout} =
               Arranger.arrange(programme, [bank], pinned: [pin], unplaced: :allow)

      assert length(layout.placed) == 2
      assert length(layout.unplaced) == 1
    end
  end

  describe "a pin that cannot be honoured is an error" do
    test "naming a session the programme does not have", context do
      programme = conf([talk("Keynote")])
      pin = %{placement(programme, [context.hall], "Keynote", 0) | session: "Ghost"}

      assert {:error, reason} = Arranger.arrange(programme, [context.hall], pinned: [pin])
      assert Agenda.explain(reason) =~ "Ghost is pinned but is not in the programme"
    end

    test "pinning the same session twice", context do
      programme = conf([talk("Keynote"), talk("Deep dive")])
      first = placement(programme, [context.hall], "Keynote", 0)
      second = placement(programme, [context.hall], "Keynote", 1)

      assert {:error, reason} =
               Arranger.arrange(programme, [context.hall], pinned: [first, second])

      assert Agenda.explain(reason) =~ "pinned 2 times"
    end

    test "two pins that hold the same room at the same time", context do
      programme = conf([talk("Keynote"), talk("Deep dive")])
      slot = placement(programme, [context.hall], "Keynote", 0)
      clash = %{slot | session: "Deep dive"}

      assert {:error, reason} =
               Arranger.arrange(programme, [context.hall], pinned: [slot, clash])

      assert Agenda.explain(reason) =~ "clashes with another pin"
    end
  end

  describe "pinning what is already booked" do
    test "a ledger round-trips into pins", context do
      programme = conf([talk("Keynote"), talk("Deep dive")])
      pool = [context.hall, context.studio]

      {:ok, [first | _rest]} = Arranger.arrange(programme, pool)
      {:ok, ledger} = Agenda.allocate(Agenda.ledger(), first)

      assert {:ok, [pin]} = Ledger.arrangements(ledger, pool)
      assert pin.session == first.session
      assert same_moment?(pin.interval.from, first.interval.from)

      assert {:ok, arrangements} =
               Arranger.arrange(programme, pool,
                 pinned: [pin],
                 busy: Ledger.busy(ledger, except: [pin.session])
               )

      assert same_moment?(starting_at(arrangements, pin.session), first.interval.from)
    end

    test "a resource the pool no longer has is reported, not guessed at", context do
      programme = conf([talk("Keynote")])
      {:ok, [only]} = Arranger.arrange(programme, [context.hall])
      {:ok, ledger} = Agenda.allocate(Agenda.ledger(), only)

      assert {:error, reason} = Ledger.arrangements(ledger, [context.studio])
      assert Agenda.explain(reason) =~ "Hall is allocated but is not in the pool"
    end

    test ":only narrows which sessions come back", context do
      programme = conf([talk("Keynote"), talk("Deep dive")])
      pool = [context.hall, context.studio]

      {:ok, arrangements} = Arranger.arrange(programme, pool)

      ledger =
        Enum.reduce(arrangements, Agenda.ledger(), fn arrangement, ledger ->
          {:ok, ledger} = Agenda.allocate(ledger, arrangement)
          ledger
        end)

      assert {:ok, [one]} = Ledger.arrangements(ledger, pool, only: "Keynote")
      assert one.session == "Keynote"
    end
  end

  describe "busy and pins together" do
    test "a pin does not double-count against its own concurrency" do
      {:ok, bank} =
        Agenda.resource("Lockers", seats: 100, concurrency: 3)
        |> Agenda.open("2026-09-15T09:00:00/2026-09-15T10:00:00")

      # Concurrency 3 over one hour: three talks fit together, and
      # pinning one of them must not consume two of the three.
      programme = conf([talk("A"), talk("B"), talk("C")])
      pin = placement(programme, [bank], "A", 0)

      assert {:ok, arrangements} = Arranger.arrange(programme, [bank], pinned: [pin])
      assert length(arrangements) == 3
    end
  end
end
