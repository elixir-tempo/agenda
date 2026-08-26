defmodule Agenda.LedgerTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Arrangement
  alias Agenda.Ledger
  alias Agenda.Session

  doctest Agenda.Ledger
  doctest Agenda.Allocation

  setup do
    %{
      boardroom: Agenda.resource("Boardroom"),
      annexe: Agenda.resource("Annexe"),
      alice: Agenda.resource("Alice"),
      bob: Agenda.resource("Bob"),
      tuesday: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      thursday: ~o"2026-06-18T14:00:00/2026-06-18T15:00:00"
    }
  end

  defp review(context, options \\ []) do
    %Arrangement{
      session: Keyword.get(options, :session, "Review"),
      interval: Keyword.get(options, :interval, context.tuesday),
      allocations:
        Keyword.get(options, :allocations, %{
          room: [context.boardroom],
          attendees: [context.alice, context.bob]
        })
    }
  end

  defp labels(changes), do: changes |> Enum.map(&elem(&1, 0)) |> Enum.frequencies()

  defp named(changes, label) do
    changes
    |> Enum.filter(&(elem(&1, 0) == label))
    |> Enum.map(&elem(&1, 1).resource)
    |> Enum.sort()
  end

  describe "allocate/2 and release/2" do
    test "allocating records one allocation per resource", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      assert Ledger.count(ledger) == 3
    end

    test "allocating is idempotent — the same arrangement twice is one holding", context do
      {:ok, once} = Ledger.allocate(Ledger.new(), review(context))
      {:ok, twice} = Ledger.allocate(once, review(context))

      assert twice == once
    end

    test "allocate then release returns the original ledger", context do
      original = Ledger.new()

      {:ok, ledger} = Ledger.allocate(original, review(context))
      {:ok, ledger} = Ledger.release(ledger, "Review")

      assert ledger == original
    end

    test "releasing frees every resource the session held, not just one", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))
      {:ok, ledger} = Ledger.release(ledger, "Review")

      assert Ledger.busy(ledger) == %{}
    end

    test "releasing a session that holds nothing is a no-op", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))
      {:ok, once} = Ledger.release(ledger, "Review")
      {:ok, twice} = Ledger.release(once, "Review")

      assert twice == once
    end

    test "sessions are independent — releasing one leaves the other", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      {:ok, ledger} =
        Ledger.allocate(
          ledger,
          review(context,
            session: "Standup",
            interval: context.thursday,
            allocations: %{room: [context.annexe]}
          )
        )

      {:ok, ledger} = Ledger.release(ledger, "Review")

      assert Ledger.busy(ledger) |> Map.keys() == ["Annexe"]
    end
  end

  describe "busy/2 — the loop back into planning" do
    test "reports each resource's claimed intervals", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      assert Ledger.busy(ledger) |> Map.keys() |> Enum.sort() ==
               ["Alice", "Boardroom", "Bob"]
    end

    test ":except hides a session from itself", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      assert Ledger.busy(ledger, except: "Review") == %{}
    end

    test ":except hides only the named session", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      {:ok, ledger} =
        Ledger.allocate(
          ledger,
          review(context, session: "Standup", allocations: %{room: [context.annexe]})
        )

      assert Ledger.busy(ledger, except: "Review") |> Map.keys() == ["Annexe"]
    end
  end

  describe "diff/3 — the changeset is minimal" do
    test "an unchanged arrangement yields only :keep", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      changes = Ledger.diff(ledger, "Review", review(context))

      assert labels(changes) == %{keep: 3}
    end

    test "moving the time releases and re-allocates everything", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      changes = Ledger.diff(ledger, "Review", review(context, interval: context.thursday))

      assert labels(changes) == %{release: 3, allocate: 3}
    end

    test "swapping one resource keeps the rest", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      moved =
        review(context,
          allocations: %{room: [context.annexe], attendees: [context.alice, context.bob]}
        )

      changes = Ledger.diff(ledger, "Review", moved)

      assert labels(changes) == %{keep: 2, release: 1, allocate: 1}
      assert named(changes, :keep) == ["Alice", "Bob"]
      assert named(changes, :release) == ["Boardroom"]
      assert named(changes, :allocate) == ["Annexe"]
    end

    test "a resource kept is never released and re-allocated", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      moved = review(context, allocations: %{room: [context.annexe], attendees: [context.alice]})
      changes = Ledger.diff(ledger, "Review", moved)

      kept = named(changes, :keep)
      churned = named(changes, :release) ++ named(changes, :allocate)

      assert "Alice" in kept
      refute "Alice" in churned
    end

    test "a session holding nothing yields only :allocate", context do
      changes = Ledger.diff(Ledger.new(), "Review", review(context))

      assert labels(changes) == %{allocate: 3}
    end

    test "the same resource in a different role is not the same binding", context do
      {:ok, ledger} =
        Ledger.allocate(Ledger.new(), review(context, allocations: %{room: [context.boardroom]}))

      recast = review(context, allocations: %{overflow: [context.boardroom]})
      changes = Ledger.diff(ledger, "Review", recast)

      assert labels(changes) == %{release: 1, allocate: 1}
    end

    test "diff does not mutate the ledger", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      _changes = Ledger.diff(ledger, "Review", review(context, interval: context.thursday))

      assert Ledger.count(ledger) == 3

      assert ledger |> Ledger.for_session("Review") |> hd() |> Map.get(:interval) ==
               context.tuesday
    end
  end

  describe "diff/3 — order independence" do
    test "resource order within a role does not change the changeset", context do
      {:ok, ledger} = Ledger.allocate(Ledger.new(), review(context))

      reordered =
        review(context,
          allocations: %{
            room: [context.boardroom],
            attendees: [context.bob, context.alice]
          }
        )

      assert labels(Ledger.diff(ledger, "Review", reordered)) == %{keep: 3}
    end

    test "allocation order does not change the resulting ledger", context do
      one = review(context, allocations: %{room: [context.boardroom]})
      two = review(context, session: "Standup", allocations: %{room: [context.annexe]})

      {:ok, forwards} = Ledger.allocate(Ledger.new(), one)
      {:ok, forwards} = Ledger.allocate(forwards, two)

      {:ok, backwards} = Ledger.allocate(Ledger.new(), two)
      {:ok, backwards} = Ledger.allocate(backwards, one)

      assert forwards == backwards
    end
  end

  describe "the whole loop — plan, allocate, re-plan" do
    setup do
      boardroom = Agenda.resource("Boardroom", seats: 8)
      {:ok, boardroom} = Agenda.open(boardroom, "2026-06-15T09:00:00/2026-06-15T12:00:00")

      session =
        "Review"
        |> Agenda.session(duration: "PT1H", window: "2026-06-15/2026-06-16")
        |> Session.needs(:room, seats: 8)

      %{room: boardroom, session: session}
    end

    test "an allocated slot is not offered again", context do
      {:ok, arrangements} = Agenda.plan(context.session, [context.room])
      assert length(arrangements) == 3

      {:ok, ledger} = Ledger.allocate(Ledger.new(), hd(arrangements))

      {:ok, remaining} =
        Agenda.plan(context.session, [context.room], busy: Ledger.busy(ledger))

      assert length(remaining) == 2
    end

    test "releasing puts the slot back", context do
      {:ok, [first | _]} = Agenda.plan(context.session, [context.room])
      {:ok, ledger} = Ledger.allocate(Ledger.new(), first)
      {:ok, ledger} = Ledger.release(ledger, "Review")

      {:ok, restored} =
        Agenda.plan(context.session, [context.room], busy: Ledger.busy(ledger))

      assert length(restored) == 3
    end

    test "re-planning a session sees past its own allocation", context do
      {:ok, [first | _]} = Agenda.plan(context.session, [context.room])
      {:ok, ledger} = Ledger.allocate(Ledger.new(), first)

      {:ok, options} =
        Agenda.plan(context.session, [context.room], busy: Ledger.busy(ledger, except: "Review"))

      # All three slots are available again, including the one it holds.
      assert length(options) == 3
    end
  end
end
