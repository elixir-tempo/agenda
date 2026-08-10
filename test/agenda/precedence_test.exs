defmodule Agenda.PrecedenceTest do
  use ExUnit.Case, async: true

  alias Agenda.Arrangement
  alias Agenda.Fixpoint
  alias Agenda.Precedence
  alias Agenda.Programme
  alias Agenda.Session
  alias Tempo.Compare
  alias Tempo.Duration

  doctest Agenda.Precedence

  setup do
    {:ok, van} =
      Agenda.resource("Van", seats: 1)
      |> Agenda.open("2027-04-05T08:00:00/2027-04-05T17:00:00")

    {:ok, second_van} =
      Agenda.resource("Second van", seats: 1)
      |> Agenda.open("2027-04-05T08:00:00/2027-04-05T17:00:00")

    %{van: van, second_van: second_van}
  end

  defp task(name, duration \\ "PT1H") do
    name
    |> Agenda.session(lasting: duration)
    |> Session.needs(:van, seats: 1)
  end

  defp job(sessions) do
    Enum.reduce(
      sessions,
      Agenda.programme("Job", across: "2027-04-05/2027-04-06"),
      &Programme.add_session(&2, &1)
    )
  end

  defp starts(arrangements, name) do
    arrangements |> Enum.find(&(&1.session == name)) |> Map.get(:interval) |> Map.get(:from)
  end

  defp ends(arrangements, name) do
    arrangements |> Enum.find(&(&1.session == name)) |> Map.get(:interval) |> Map.get(:to)
  end

  defp at_or_after?(later, earlier) do
    Compare.compare_endpoints(later, earlier) in [:later, :same]
  end

  describe "declaring an order" do
    test "both sessions must be in the programme" do
      programme = job([task("Survey")])

      assert {:error, {:unknown_sessions, ["Quote"]}} =
               Agenda.precede(programme, "Survey", "Quote")
    end

    test "a naming mistake is an error, not a constraint that quietly does nothing" do
      assert {:error, {:unknown_sessions, ["Survey", "Quote"]}} =
               Agenda.precede(Agenda.programme("Job"), "Survey", "Quote")
    end

    test "an unreadable gap is reported when arranging", context do
      {:ok, programme} =
        Agenda.precede(job([task("Survey"), task("Quote")]), "Survey", "Quote",
          gap: "half an hour"
        )

      assert {:error, reason} = Agenda.arrange(programme, [context.van])
      assert Agenda.explain(reason) =~ "which is not a duration"
    end
  end

  describe "the order is enforced" do
    test "the successor never starts before the predecessor ends", context do
      {:ok, programme} =
        Agenda.precede(job([task("Survey"), task("Quote")]), "Survey", "Quote")

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.van])
      assert at_or_after?(starts(arrangements, "Quote"), ends(arrangements, "Survey"))
    end

    test "even when the programme lists them the other way round", context do
      # Declaration order must not decide scheduling order.
      {:ok, programme} =
        Agenda.precede(job([task("Quote"), task("Survey")]), "Survey", "Quote")

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.van])
      assert at_or_after?(starts(arrangements, "Quote"), ends(arrangements, "Survey"))
    end

    test "even when two vans would let them run at once", context do
      # Without the precedence these would both take the first slot.
      {:ok, programme} =
        Agenda.precede(job([task("Survey"), task("Quote")]), "Survey", "Quote")

      assert {:ok, arrangements} =
               Agenda.arrange(programme, [context.van, context.second_van])

      assert at_or_after?(starts(arrangements, "Quote"), ends(arrangements, "Survey"))
    end

    test "a chain of three is two precedences, and holds end to end", context do
      programme = job([task("Survey"), task("Quote"), task("Install")])
      {:ok, programme} = Agenda.precede(programme, "Survey", "Quote")
      {:ok, programme} = Agenda.precede(programme, "Quote", "Install")

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.van])

      assert at_or_after?(starts(arrangements, "Quote"), ends(arrangements, "Survey"))
      assert at_or_after?(starts(arrangements, "Install"), ends(arrangements, "Quote"))
    end
  end

  describe "the gap" do
    test "a minimum gap is respected", context do
      {:ok, programme} =
        Agenda.precede(job([task("Survey"), task("Quote")]), "Survey", "Quote", gap: "PT2H")

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.van])

      earliest = Tempo.shift(ends(arrangements, "Survey"), Duration.new!(hour: 2))
      assert at_or_after?(starts(arrangements, "Quote"), earliest)
    end

    test "a maximum gap is respected", context do
      {:ok, programme} =
        Agenda.precede(job([task("Survey"), task("Quote")]), "Survey", "Quote", within: "PT1H")

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.van])

      latest = Tempo.shift(ends(arrangements, "Survey"), Duration.new!(hour: 1))
      assert Compare.compare_endpoints(starts(arrangements, "Quote"), latest) in [:earlier, :same]
    end

    test "a gap wider than the day makes the job impossible", context do
      {:ok, programme} =
        Agenda.precede(job([task("Survey"), task("Quote")]), "Survey", "Quote", gap: "P7D")

      assert {:error, _reason} = Agenda.arrange(programme, [context.van])
    end

    test "gap and within together pin the follow-up to a window", context do
      # An interview loop: the panel follows screening, not sooner than
      # an hour after and not later than three.
      {:ok, programme} =
        Agenda.precede(job([task("Screening"), task("Panel")]), "Screening", "Panel",
          gap: "PT1H",
          within: "PT3H"
        )

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.van])

      finished = ends(arrangements, "Screening")
      started = starts(arrangements, "Panel")

      assert at_or_after?(started, Tempo.shift(finished, Duration.new!(hour: 1)))

      assert Compare.compare_endpoints(
               started,
               Tempo.shift(finished, Duration.new!(hour: 3))
             ) in [
               :earlier,
               :same
             ]
    end
  end

  describe "precedence and the rest of the library" do
    test "the fixpoint bridge enforces it too", context do
      # `conflict?/4` is the shared predicate, so both solvers get it.
      {:ok, programme} =
        Agenda.precede(job([task("Survey"), task("Quote")]), "Survey", "Quote")

      assert {:ok, arrangements} = Fixpoint.solve(programme, [context.van])
      assert at_or_after?(starts(arrangements, "Quote"), ends(arrangements, "Survey"))
    end

    test "conflict/3 names an impossible ordering", context do
      {:ok, programme} =
        Agenda.precede(job([task("Survey"), task("Quote")]), "Survey", "Quote", gap: "P7D")

      assert {:ok, names} = Agenda.conflict(programme, [context.van])
      assert Enum.sort(names) == ["Quote", "Survey"]
    end

    test "restricting a programme drops precedences that lost an end" do
      programme = job([task("Survey"), task("Quote")])
      {:ok, programme} = Agenda.precede(programme, "Survey", "Quote")

      restricted = Programme.restrict_to(programme, ["Survey"])

      assert restricted.precedences == []
    end

    test "an ordered pair still respects resource exclusion", context do
      {:ok, programme} =
        Agenda.precede(job([task("Survey"), task("Quote")]), "Survey", "Quote")

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.van])

      for a <- arrangements, b <- arrangements, a.session != b.session do
        assert Tempo.disjoint?(a.interval, b.interval)
      end
    end

    test "sessions with no precedence between them are unordered", context do
      programme = job([task("Survey"), task("Quote"), task("Unrelated")])
      {:ok, programme} = Agenda.precede(programme, "Survey", "Quote")

      assert {:ok, arrangements} = Agenda.arrange(programme, [context.van])
      assert length(arrangements) == 3
      assert %Arrangement{} = Enum.find(arrangements, &(&1.session == "Unrelated"))
    end

    test "between/3 finds the pair either way round" do
      precedences = [Precedence.new("Survey", "Quote")]

      assert {_p, :in_order} = Precedence.between(precedences, "Survey", "Quote")
      assert {_p, :reversed} = Precedence.between(precedences, "Quote", "Survey")
      assert Precedence.between(precedences, "Survey", "Other") == nil
    end
  end
end
