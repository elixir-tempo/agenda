defmodule Agenda.SeriesLifecycleTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Ledger
  alias Agenda.Session

  # A weekly stand-up over four weeks, in a room open every weekday
  # morning of March.
  setup do
    {:ok, room} =
      Agenda.resource("Huddle", seats: 6)
      |> Agenda.open("R28/2027-03-01T09:00:00/P1D")

    standup =
      Agenda.session("Stand-up", duration: ~o"PT15M")
      |> Session.needs(:room, seats: 6)

    {:ok, occurrences} = Agenda.every(standup, "R4/2027-03-01T09:00:00/P1W")

    %{room: room, occurrences: occurrences}
  end

  defp book_all(occurrences, room) do
    Enum.reduce(occurrences, Agenda.ledger(), fn occurrence, ledger ->
      {:ok, [first | _]} = Agenda.plan(occurrence, [room], busy: Agenda.busy(ledger))
      {:ok, ledger} = Agenda.allocate(ledger, first)
      ledger
    end)
  end

  describe "expansion" do
    test "yields one session per repetition", context do
      assert length(context.occurrences) == 4
    end

    test "each occurrence is named and carries the series", context do
      assert Enum.map(context.occurrences, & &1.name) ==
               ["Stand-up 1", "Stand-up 2", "Stand-up 3", "Stand-up 4"]

      assert Enum.all?(context.occurrences, &(&1.series == "Stand-up"))
    end

    test "occurrences keep the original's requirements and length", context do
      assert Enum.all?(context.occurrences, &(&1.duration == ~o"PT15M"))
      assert Enum.all?(context.occurrences, &(length(&1.requirements) == 1))
    end

    test "each occurrence has its own window, a week apart", context do
      starts = Enum.map(context.occurrences, & &1.window.from)

      assert Enum.uniq(starts) == starts
      assert hd(starts) == ~o"2027Y3M1DT9H0M0S"
    end

    test "an unreadable pattern is an error, not a crash" do
      session = Agenda.session("X", duration: ~o"PT1H")

      assert Agenda.every(session, "not a recurrence") == {:error, :unreadable_pattern}
    end
  end

  describe "booking the run" do
    test "every occurrence gets its own allocation", context do
      ledger = book_all(context.occurrences, context.room)

      assert Ledger.count(ledger) == 4
    end

    test "the allocations all carry the series name", context do
      ledger = book_all(context.occurrences, context.room)

      assert ledger |> Ledger.to_list() |> Enum.map(& &1.series) |> Enum.uniq() == ["Stand-up"]
    end

    test "occurrences are booked at distinct times", context do
      ledger = book_all(context.occurrences, context.room)

      starts = ledger |> Ledger.to_list() |> Enum.map(& &1.interval.from)

      assert length(Enum.uniq(starts)) == 4
    end
  end

  describe "release_series/3" do
    test "cancels the whole run in one call", context do
      ledger = book_all(context.occurrences, context.room)

      {:ok, ledger} = Ledger.release_series(ledger, "Stand-up")

      assert Ledger.count(ledger) == 0
    end

    test "leaves other sessions alone", context do
      ledger = book_all(context.occurrences, context.room)

      one_off =
        Agenda.session("Retro", duration: ~o"PT1H", between: "2027-03-02/2027-03-03")
        |> Session.needs(:room, seats: 6)

      {:ok, [first | _]} = Agenda.plan(one_off, [context.room], busy: Agenda.busy(ledger))
      {:ok, ledger} = Agenda.allocate(ledger, first)

      {:ok, ledger} = Ledger.release_series(ledger, "Stand-up")

      assert Ledger.count(ledger) == 1
      assert ledger |> Ledger.to_list() |> hd() |> Map.get(:session) == "Retro"
    end

    test "an unknown series changes nothing", context do
      ledger = book_all(context.occurrences, context.room)

      assert {:ok, ^ledger} = Ledger.release_series(ledger, "Nonexistent")
    end

    test ":from cancels the rest of the run and keeps the past", context do
      ledger = book_all(context.occurrences, context.room)

      # Occurrences fall on 1, 8, 15 and 22 March; cancel from the 10th.
      {:ok, ledger} = Ledger.release_series(ledger, "Stand-up", from: "2027-03-10")

      remaining = ledger |> Ledger.to_list() |> Enum.map(& &1.session) |> Enum.sort()

      assert remaining == ["Stand-up 1", "Stand-up 2"]
    end

    test ":from before the run cancels all of it", context do
      ledger = book_all(context.occurrences, context.room)

      {:ok, ledger} = Ledger.release_series(ledger, "Stand-up", from: "2027-01-01")

      assert Ledger.count(ledger) == 0
    end

    test ":from after the run cancels none of it", context do
      ledger = book_all(context.occurrences, context.room)

      {:ok, ledger} = Ledger.release_series(ledger, "Stand-up", from: "2027-12-01")

      assert Ledger.count(ledger) == 4
    end

    test "releasing frees the exact slots the run had taken", context do
      ledger = book_all(context.occurrences, context.room)
      [_, second | _] = context.occurrences

      booked = ledger |> Ledger.for_session("Stand-up 2") |> hd() |> Map.get(:interval)

      # While held, that precise slot is not on offer.
      {:ok, held} =
        Agenda.plan(second, [context.room], busy: Agenda.busy(ledger), limit: 500)

      refute Enum.any?(held, &Tempo.equal?(&1.interval, booked))

      {:ok, ledger} = Ledger.release_series(ledger, "Stand-up")

      {:ok, freed} =
        Agenda.plan(second, [context.room], busy: Agenda.busy(ledger), limit: 500)

      assert Enum.any?(freed, &Tempo.equal?(&1.interval, booked))
    end
  end
end
