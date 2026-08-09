defmodule Timetable.HoldsTest do
  use ExUnit.Case, async: true

  alias Tempo.IntervalSet
  alias Timetable.Ledger
  alias Timetable.Session

  setup do
    {:ok, boardroom} =
      Timetable.resource("Boardroom", seats: 8)
      |> Timetable.open("2026-06-15T09:00:00/2026-06-15T17:00:00")

    session =
      Timetable.session("Review", lasting: "PT1H", between: "2026-06-15/2026-06-16")
      |> Session.needs(:room, seats: 8)

    {:ok, [first | _rest]} = Timetable.plan(session, [boardroom])

    %{room: boardroom, session: session, arrangement: first}
  end

  defp held(ledger, arrangement, until) do
    {:ok, ledger} = Timetable.hold(ledger, arrangement, until: until)
    ledger
  end

  describe "a hold occupies the resource" do
    test "it is subtracted from free time exactly as an allocation is", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      {:ok, free} =
        Timetable.free(context.room,
          within: "2026-06-15/2026-06-16",
          busy: Map.get(Timetable.busy(ledger), "Boardroom", [])
        )

      refute Enum.any?(IntervalSet.to_list(free), fn window ->
               Tempo.overlaps?(window, context.arrangement.interval)
             end)
    end

    test "and planning will not offer the same slot twice", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      {:ok, options} =
        Timetable.plan(context.session, [context.room], busy: Timetable.busy(ledger))

      refute Enum.any?(options, fn option ->
               Tempo.equal?(option.interval, context.arrangement.interval)
             end)
    end

    test "a hold is visible as a hold, not as a booking", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      assert [allocation] = Timetable.holds(ledger)
      assert allocation.session == "Review"
      assert allocation.held_until != nil
    end

    test "a firm allocation is not a hold", context do
      {:ok, ledger} = Timetable.allocate(Timetable.ledger(), context.arrangement)

      assert Timetable.holds(ledger) == []
      assert Timetable.count(ledger) == 1
    end
  end

  describe "expiry" do
    test "nothing lapses until time is advanced", context do
      # The ledger reads no clock. A hold taken an hour ago is still a
      # hold until someone says what time it is.
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      assert Timetable.count(ledger) == 1
      assert length(Timetable.holds(ledger)) == 1
    end

    test "a hold survives a moment before its expiry", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      assert {:ok, ledger} = Timetable.expire(ledger, "2026-06-15T10:14:59")
      assert Timetable.count(ledger) == 1
    end

    test "a hold lapses at its expiry, not after it", context do
      # Good *until* ten past means gone at ten past.
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      assert {:ok, ledger} = Timetable.expire(ledger, "2026-06-15T10:15:00")
      assert Timetable.count(ledger) == 0
    end

    test "expiring frees the time again", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")
      {:ok, ledger} = Timetable.expire(ledger, "2026-06-15T11:00:00")

      {:ok, free} =
        Timetable.free(context.room,
          within: "2026-06-15/2026-06-16",
          busy: Map.get(Timetable.busy(ledger), "Boardroom", [])
        )

      assert Enum.any?(IntervalSet.to_list(free), fn window ->
               Tempo.overlaps?(window, context.arrangement.interval)
             end)
    end

    test "a firm allocation never lapses", context do
      {:ok, ledger} = Timetable.allocate(Timetable.ledger(), context.arrangement)

      assert {:ok, ledger} = Timetable.expire(ledger, "2099-01-01T00:00:00")
      assert Timetable.count(ledger) == 1
    end

    test "expiring is idempotent", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      {:ok, once} = Timetable.expire(ledger, "2026-06-15T11:00:00")
      {:ok, twice} = Timetable.expire(once, "2026-06-15T11:00:00")

      assert once == twice
    end

    test "an unreadable moment is an error, not a crash", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      assert {:error, _reason} = Timetable.expire(ledger, "half past forever")
    end
  end

  describe "confirming" do
    test "a confirmed hold becomes firm and stops lapsing", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      assert {:ok, ledger} = Timetable.confirm(ledger, "Review")
      assert Timetable.holds(ledger) == []

      assert {:ok, ledger} = Timetable.expire(ledger, "2099-01-01T00:00:00")
      assert Timetable.count(ledger) == 1
    end

    test "confirming keeps the same interval and resources", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")
      {:ok, ledger} = Timetable.confirm(ledger, "Review")

      assert [allocation] = Ledger.for_session(ledger, "Review")
      assert allocation.resource == "Boardroom"
      assert Tempo.equal?(allocation.interval, context.arrangement.interval)
    end

    test "confirming a session that holds nothing is a no-op" do
      assert {:ok, ledger} = Timetable.confirm(Timetable.ledger(), "Nothing")
      assert Timetable.count(ledger) == 0
    end

    test "confirming twice is a no-op", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      {:ok, once} = Timetable.confirm(ledger, "Review")
      {:ok, twice} = Timetable.confirm(once, "Review")

      assert once == twice
    end
  end

  describe "holds and the rest of the ledger" do
    test "a hold replaces whatever the session held before", context do
      # Same key, same wholesale replacement as allocate/2.
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")
      ledger = held(ledger, context.arrangement, "2026-06-15T11:00:00")

      assert Timetable.count(ledger) == 1
    end

    test "releasing drops a hold as readily as a booking", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      assert {:ok, ledger} = Timetable.release(ledger, "Review")
      assert Timetable.count(ledger) == 0
    end

    test "allocating over a hold makes it firm", context do
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      assert {:ok, ledger} = Timetable.allocate(ledger, context.arrangement)
      assert Timetable.holds(ledger) == []
    end

    test "the ledger reads no clock, so arranging twice gives one answer", context do
      # The property that makes expire/2 take its moment as an
      # argument: without it, the same ledger would answer differently
      # as holds lapsed underneath a caller.
      ledger = held(Timetable.ledger(), context.arrangement, "2026-06-15T10:15:00")

      first = Timetable.busy(ledger)
      second = Timetable.busy(ledger)

      assert first == second
    end
  end
end
