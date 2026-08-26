defmodule Agenda.PlannerTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils
  import Agenda.Predicate

  alias Agenda.Arrangement
  alias Agenda.Planner
  alias Agenda.Session
  alias Tempo.Interval

  doctest Agenda.Planner

  setup do
    sydney = Agenda.place("Sydney")
    level_2 = Agenda.place("Level 2", within: sydney)
    level_3 = Agenda.place("Level 3", within: sydney)
    darling = Agenda.place("Darling Harbour")

    open = fn resource ->
      {:ok, resource} = Agenda.open(resource, "2026-06-15T09:00:00/2026-06-15T17:00:00")
      resource
    end

    %{
      sydney: sydney,
      boardroom:
        open.(
          Agenda.resource("Boardroom",
            within: level_2,
            seats: 8,
            video_conferencing: true,
            step_free_access: true
          )
        ),
      annexe: open.(Agenda.resource("Annexe", within: level_3, seats: 12)),
      attic: open.(Agenda.resource("Attic", within: darling, seats: 12)),
      small: open.(Agenda.resource("Meeting room 2", within: level_2, seats: 4)),
      alice: open.(Agenda.resource("Alice", requires: [step_free_access: true])),
      bob: open.(Agenda.resource("Bob"))
    }
  end

  defp review(context, extra \\ []) do
    "Review"
    |> Agenda.session(duration: "PT1H", window: "2026-06-15/2026-06-16")
    |> Session.needs(:room, Keyword.get(extra, :room, seats: at_least(8)))
    |> Session.roster(:attendees, Keyword.get(extra, :attendees, [context.alice, context.bob]))
  end

  defp rooms(arrangements) do
    arrangements
    |> Enum.map(&(&1.allocations.room |> hd() |> Map.get(:name)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  describe "plan/3 — the happy path" do
    test "returns one arrangement per fitting slot", context do
      {:ok, arrangements} = Planner.plan(review(context), [context.boardroom])

      assert length(arrangements) == 8
    end

    test "every arrangement allocates a resource to each role", context do
      {:ok, [first | _]} = Planner.plan(review(context), [context.boardroom])

      assert %{room: [room]} = first.allocations
      assert room.name == "Boardroom"
      assert first.session == "Review"
    end

    test "consecutive arrangements meet — back-to-back, no gap, no overlap", context do
      {:ok, arrangements} = Planner.plan(review(context), [context.boardroom])

      assert arrangements
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> Tempo.meets?(a.interval, b.interval) end)
    end

    test "the earliest slot comes first — ordering is chronological, not lexicographic",
         context do
      {:ok, arrangements} = Planner.plan(review(context), [context.boardroom])

      # Sorted as ISO strings, "10:00" would precede "9:00".
      assert List.first(arrangements).interval.from == ~o"2026Y6M15DT9H0M0S"
      assert List.last(arrangements).interval.from == ~o"2026Y6M15DT16H0M0S"
    end

    test "every arrangement lasts exactly the session's duration", context do
      {:ok, arrangements} = Planner.plan(review(context), [context.boardroom])

      assert Enum.all?(arrangements, &Tempo.exactly?(&1.interval, ~o"PT1H"))
    end

    test "every arrangement falls within the session's window", context do
      window = ~o"2026-06-15/2026-06-16"

      {:ok, arrangements} = Planner.plan(review(context), [context.boardroom])

      assert Enum.all?(arrangements, &Tempo.within?(&1.interval, window))
    end
  end

  describe "plan/3 — provenance rides on the interval" do
    test "each arrangement names every resource whose free time produced it", context do
      {:ok, [first | _]} = Planner.plan(review(context), [context.boardroom])

      assert %{free: contributors} = Interval.metadata(first.interval)
      assert Enum.sort(contributors) == ["Alice", "Boardroom", "Bob"]
    end

    test "a session with no roster still names the chosen room", context do
      session =
        "Solo"
        |> Agenda.session(duration: "PT1H", window: "2026-06-15/2026-06-16")
        |> Session.needs(:room, seats: at_least(8))

      {:ok, [first | _]} = Planner.plan(session, [context.boardroom])

      assert Interval.metadata(first.interval) == %{free: ["Boardroom"]}
    end
  end

  describe "plan/3 — named resources are allocated, not merely matched" do
    test "the arrangement records roster members alongside the chosen room", context do
      {:ok, [first | _]} = Planner.plan(review(context), [context.boardroom])

      assert Map.keys(first.allocations) |> Enum.sort() == [:attendees, :room]

      assert first.allocations.attendees |> Enum.map(& &1.name) |> Enum.sort() ==
               ["Alice", "Bob"]
    end

    test "a session with only named resources still allocates them", context do
      session =
        "Standup"
        |> Agenda.session(duration: "PT1H", window: "2026-06-15/2026-06-16")
        |> Session.roster(:attendees, [context.bob])

      {:ok, [first | _]} = Planner.plan(session, [])

      assert first.allocations.attendees |> Enum.map(& &1.name) == ["Bob"]
    end

    test "roster members appear once, not twice, in the provenance", context do
      {:ok, [first | _]} = Planner.plan(review(context), [context.boardroom])

      %{free: contributors} = Interval.metadata(first.interval)

      assert length(contributors) == length(Enum.uniq(contributors))
    end
  end

  describe "plan/3 — busy time is subtracted" do
    test "a busy room loses the overlapping slots", context do
      busy = %{"Boardroom" => "2026-06-15T09:00:00/2026-06-15T12:00:00"}

      {:ok, arrangements} = Planner.plan(review(context), [context.boardroom], busy: busy)

      assert length(arrangements) == 5
      assert List.first(arrangements).interval.from == ~o"2026Y6M15DT12H0M0S"
    end

    test "a busy attendee removes the slot even when the room is free", context do
      busy = %{"Alice" => "2026-06-15T09:00:00/2026-06-15T16:00:00"}

      {:ok, arrangements} = Planner.plan(review(context), [context.boardroom], busy: busy)

      assert length(arrangements) == 1
      assert List.first(arrangements).interval.from == ~o"2026Y6M15DT16H0M0S"
    end

    test "no arrangement overlaps the busy period", context do
      busy_span = ~o"2026-06-15T09:00:00/2026-06-15T12:00:00"

      {:ok, arrangements} =
        Planner.plan(review(context), [context.boardroom], busy: %{"Boardroom" => busy_span})

      refute Enum.any?(arrangements, &Tempo.overlaps?(&1.interval, busy_span))
    end

    test "everyone busy is infeasible, with a reason", context do
      busy = %{"Alice" => "2026-06-15/2026-06-16"}

      assert {:error, reason} = Planner.plan(review(context), [context.boardroom], busy: busy)
      assert Agenda.explain(reason) =~ "Review cannot be held"
    end
  end

  describe "plan/3 — eligibility and induced requirements" do
    test "a room that is too small is never offered", context do
      {:ok, arrangements} = Planner.plan(review(context), [context.small, context.boardroom])

      assert rooms(arrangements) == ["Boardroom"]
    end

    test "no eligible room is infeasible and names the nearest misses", context do
      assert {:error, reason} = Planner.plan(review(context), [context.small])

      message = Agenda.explain(reason)
      assert message =~ "nothing satisfies room"
      assert message =~ "Meeting room 2"
      assert message =~ "seats is 4"
    end

    test "an attendee's own requirement rules out a room", context do
      # The annexe is big enough but has no step-free access; Alice needs it.
      assert {:error, reason} =
               Planner.plan(review(context, attendees: [context.alice]), [context.annexe])

      assert Agenda.explain(reason) =~ "step_free_access"
    end

    test "the same room is fine for an attendee who does not need access", context do
      assert {:ok, arrangements} =
               Planner.plan(review(context, attendees: [context.bob]), [context.annexe])

      assert length(arrangements) == 8
    end
  end

  describe "plan/3 — preferences rank but never exclude" do
    # Bob induces no requirements, so both rooms stay eligible and the
    # ranking is what is actually under test. With Alice in the room the
    # Attic would be excluded by her step-free access need, and these
    # would pass without exercising preferences at all.
    setup context do
      session =
        context
        |> review(attendees: [context.bob])
        |> Session.prefers(within: context.sydney)

      %{session: session, pool: [context.attic, context.boardroom]}
    end

    test "both rooms are genuinely eligible", context do
      {:ok, arrangements} = Planner.plan(review(context, attendees: [context.bob]), context.pool)

      assert rooms(arrangements) == ["Attic", "Boardroom"]
    end

    test "a preferred room sorts above an equally free one", context do
      {:ok, [%Arrangement{} = best | _]} = Planner.plan(context.session, context.pool)

      assert best.allocations.room |> hd() |> Map.get(:name) == "Boardroom"
      assert best.score > 0
    end

    test "the unpreferred room is still offered", context do
      {:ok, arrangements} = Planner.plan(context.session, context.pool)

      assert rooms(arrangements) == ["Attic", "Boardroom"]
    end

    test "every preferred arrangement outranks every unpreferred one", context do
      {:ok, arrangements} = Planner.plan(context.session, context.pool)

      {preferred, rest} = Enum.split_while(arrangements, &(&1.score > 0))

      assert length(preferred) == 8
      assert Enum.all?(preferred, &(hd(&1.allocations.room).name == "Boardroom"))
      assert Enum.all?(rest, &(hd(&1.allocations.room).name == "Attic"))
    end
  end

  describe "plan/3 — limits" do
    test "truncates to :limit", context do
      {:ok, arrangements} = Planner.plan(review(context), [context.boardroom], limit: 3)

      assert length(arrangements) == 3
    end
  end
end
