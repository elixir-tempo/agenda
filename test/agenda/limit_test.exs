defmodule Agenda.LimitTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Limit
  alias Tempo.Duration

  doctest Agenda.Limit

  describe "parse/1" do
    test "a bare integer is a count ceiling" do
      assert {:ok, [%Limit{period: :day, at_most: {:count, 3}, at_least: nil}]} =
               Limit.parse(day: 3)
    end

    test "a bare duration is a duration ceiling" do
      assert {:ok, [%Limit{at_most: {:duration, duration}}]} = Limit.parse(day: ~o"PT7H36M")
      assert Duration.to_unit(duration, :second) == {:ok, 27_360.0}
    end

    test "a duration may be given as an ISO 8601 string" do
      assert {:ok, [%Limit{at_most: {:duration, _}}]} = Limit.parse(day: "PT8H")
    end

    test "both ends at once" do
      assert {:ok, [%Limit{at_least: {:duration, _}, at_most: {:duration, _}}]} =
               Limit.parse(week: [at_least: ~o"PT38H", at_most: ~o"PT45H"])
    end

    test "a floor alone is legal" do
      assert {:ok, [%Limit{at_most: nil, at_least: {:duration, _}}]} =
               Limit.parse(week: [at_least: ~o"PT38H"])
    end

    test "an unknown period is named in the error" do
      assert {:error, message} = Limit.parse(fortnight: 5)
      assert message =~ ":fortnight"
    end

    test "a limit giving neither end is refused" do
      assert {:error, message} = Limit.parse(week: [])
      assert message =~ "neither"
    end

    test "a negative or zero count is refused" do
      assert {:error, _} = Limit.parse(day: 0)
      assert {:error, _} = Limit.parse(day: -1)
    end

    test "an unreadable value is refused rather than ignored" do
      assert {:error, message} = Limit.parse(day: "not a duration")
      assert message =~ "expected a positive count or a duration"
    end

    test "order is preserved" do
      assert {:ok, [%Limit{period: :day}, %Limit{period: :week}]} = Limit.parse(day: 1, week: 5)
    end
  end

  describe "parse!/1" do
    test "raises rather than silently dropping a malformed limit" do
      assert_raise ArgumentError, ~r/:fortnight/, fn -> Limit.parse!(fortnight: 5) end
    end
  end

  describe "total/1" do
    test "sums measurable intervals" do
      {count, duration} =
        Limit.total([
          ~o"2026-06-16T09:00:00/2026-06-16T12:00:00",
          ~o"2026-06-16T13:00:00/2026-06-16T17:00:00"
        ])

      assert count == 2
      assert Duration.to_unit(duration, :hour) == {:ok, 7.0}
    end

    test "an empty list totals nothing" do
      assert {0, duration} = Limit.total([])
      assert Duration.to_unit(duration, :second) == {:ok, 0.0}
    end
  end

  describe "permits?/3 — ceilings" do
    test "a count ceiling compares the count" do
      [limit] = Limit.parse!(day: 2)

      assert Limit.permits?(limit, 2, ~o"PT100H")
      refute Limit.permits?(limit, 3, ~o"PT0S")
    end

    test "a duration ceiling compares the duration, not the count" do
      [limit] = Limit.parse!(day: ~o"PT8H")

      assert Limit.permits?(limit, 20, ~o"PT8H")
      refute Limit.permits?(limit, 1, ~o"PT8H1S")
    end

    test "the ceiling is inclusive" do
      [limit] = Limit.parse!(day: ~o"PT8H")

      assert Limit.permits?(limit, 1, ~o"PT8H")
    end

    test "durations written differently compare equal" do
      [limit] = Limit.parse!(day: ~o"PT1H30M")

      assert Limit.permits?(limit, 1, ~o"PT90M")
    end
  end

  describe "permits?/3 — floors are invisible to the search" do
    test "a floor-only limit permits anything" do
      [limit] = Limit.parse!(week: [at_least: ~o"PT38H"])

      assert Limit.permits?(limit, 0, ~o"PT0S")
      assert Limit.permits?(limit, 99, ~o"PT99H")
    end

    test "a limit with both ends still only prunes on the ceiling" do
      [limit] = Limit.parse!(week: [at_least: ~o"PT38H", at_most: ~o"PT45H"])

      assert Limit.permits?(limit, 1, ~o"PT1H")
      refute Limit.permits?(limit, 1, ~o"PT46H")
    end
  end

  describe "breach/3" do
    test "nothing when the claims satisfy the limit" do
      [limit] = Limit.parse!(week: [at_least: ~o"PT38H", at_most: ~o"PT45H"])

      assert Limit.breach(limit, 5, ~o"PT40H") == nil
    end

    test "over names the ceiling" do
      [limit] = Limit.parse!(week: ~o"PT45H")

      assert {:over, {:duration, _}} = Limit.breach(limit, 5, ~o"PT46H")
    end

    test "under names the floor" do
      [limit] = Limit.parse!(week: [at_least: ~o"PT38H"])

      assert {:under, {:duration, _}} = Limit.breach(limit, 5, ~o"PT30H")
    end

    test "a floor met exactly is not a breach" do
      [limit] = Limit.parse!(week: [at_least: ~o"PT38H"])

      assert Limit.breach(limit, 5, ~o"PT38H") == nil
    end

    test "count floors work too" do
      [limit] = Limit.parse!(week: [at_least: 5])

      assert {:under, {:count, 5}} = Limit.breach(limit, 4, ~o"PT0S")
      assert Limit.breach(limit, 5, ~o"PT0S") == nil
    end

    test "a ceiling breach is reported ahead of a floor breach" do
      [limit] = Limit.parse!(week: [at_least: ~o"PT38H", at_most: ~o"PT10H"])

      assert {:over, _} = Limit.breach(limit, 1, ~o"PT20H")
    end
  end

  describe "Resource integration" do
    test "limits are parsed on construction" do
      resource = Agenda.resource("Dana", limits: [day: ~o"PT7H36M"])

      assert [%Limit{period: :day, at_most: {:duration, _}}] = resource.limits
    end

    test "a malformed limit raises at the resource, not later" do
      assert_raise ArgumentError, fn -> Agenda.resource("Dana", limits: [year: 5]) end
    end

    test "no limits is an empty list" do
      assert Agenda.resource("Dana").limits == []
    end
  end
end
