defmodule Agenda.LimitsTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Arrangement
  alias Agenda.Limit
  alias Agenda.Programme
  alias Agenda.Session
  alias Tempo.Duration
  alias Tempo.IntervalSet

  # A fortnight of mornings, so a week boundary falls inside the window.
  @fortnight "2027-04-05/2027-04-19"

  defp nurse(name, limits) do
    {:ok, nurse} =
      Agenda.resource(name, qualified: true, limits: limits, concurrency: 1)
      |> Agenda.open(
        IntervalSet.new!(
          for day <- 5..16 do
            Tempo.from_iso8601!(
              "2027-04-#{String.pad_leading("#{day}", 2, "0")}T09:00:00" <>
                "/2027-04-#{String.pad_leading("#{day}", 2, "0")}T17:00:00"
            )
          end
        )
      )

    nurse
  end

  defp shift(name) do
    name
    |> Agenda.session(lasting: "PT8H", between: @fortnight)
    |> Session.needs(:staff, qualified: true)
  end

  defp roster(count) do
    Enum.reduce(
      1..count,
      Agenda.programme("Roster", across: @fortnight),
      &Programme.add_session(&2, shift("Shift #{&1}"))
    )
  end

  defp days(arrangements) do
    arrangements
    |> Enum.map(& &1.interval.from.time[:day])
    |> Enum.sort()
  end

  describe "a limit may measure time rather than claims" do
    test "a duration ceiling caps hours, not shifts" do
      # Eight-hour shifts against a sixteen-hour week: two fit, a third
      # does not, and nothing said "two".
      ann = nurse("Ann", week: ~o"PT16H")

      assert {:partial, layout} = Agenda.arrange(roster(10), [ann], unplaced: :allow)

      {_count, worked} = Limit.sum(Enum.map(layout.placed, & &1.interval))
      assert {:ok, hours} = Duration.to_unit(worked, :hour)
      assert hours <= 32.0
    end

    test "a ceiling too small for one shift places nothing" do
      ann = nurse("Ann", day: ~o"PT4H")

      assert {:partial, layout} = Agenda.arrange(roster(3), [ann], unplaced: :allow)
      assert layout.placed == []
    end

    test "a ceiling that exactly fits one shift admits it" do
      # An eight-hour ceiling and an eight-hour shift: inclusive, so
      # one a day fits and all three place.
      ann = nurse("Ann", day: ~o"PT8H")

      assert {:ok, arrangements} = Agenda.arrange(roster(3), [ann], unplaced: :allow)
      assert length(arrangements) == 3
      assert days(arrangements) == Enum.uniq(days(arrangements))
    end

    test "a floor never prunes the search" do
      # A floor no layout could reach must still cost nothing, because
      # a partial layout is supposed to be under its floor. Compare
      # against the same roster with no limit at all.
      ann = nurse("Ann", week: [at_least: ~o"PT500H"])
      unlimited = nurse("Bea", [])

      assert {:ok, floored} = Agenda.arrange(roster(3), [ann], unplaced: :allow)
      assert {:ok, baseline} = Agenda.arrange(roster(3), [unlimited], unplaced: :allow)
      assert length(floored) == length(baseline)
    end
  end

  describe "a limit is not concurrency" do
    test "one a day still allows many across the fortnight" do
      # Concurrency 1 already stops two at once. The limit is what
      # stops two on the same day at different hours.
      ann = nurse("Ann", day: 1)

      assert {:partial, layout} =
               Agenda.arrange(roster(20), [ann], unplaced: :allow)

      assert days(layout.placed) == Enum.uniq(days(layout.placed))
    end

    test "and the shifts land on distinct days" do
      ann = nurse("Ann", day: 1)

      assert {:partial, layout} = Agenda.arrange(roster(20), [ann], unplaced: :allow)

      assert length(layout.placed) == length(Enum.uniq(days(layout.placed)))
    end
  end

  describe "a weekly limit" do
    test "caps how many shifts fall in one calendar week" do
      # Twelve open days spanning two weeks; three a week means at
      # most six placed.
      ann = nurse("Ann", day: 1, week: 3)

      assert {:partial, layout} = Agenda.arrange(roster(20), [ann], unplaced: :allow)

      assert length(layout.placed) == 6
    end

    test "the boundary is the calendar's, not seven days from the first shift" do
      # 2027-04-05 is a Monday, so 5–11 and 12–18 are the two weeks.
      ann = nurse("Ann", day: 1, week: 3)

      {:partial, layout} = Agenda.arrange(roster(20), [ann], unplaced: :allow)

      {first_week, second_week} = Enum.split_with(days(layout.placed), &(&1 <= 11))

      assert length(first_week) == 3
      assert length(second_week) == 3
    end
  end

  describe "limits count what is already booked" do
    test "a nurse who has worked already has less left" do
      # No availability calculation can express "at most three this
      # week", so the ledger has to be consulted by the limit itself.
      ann = nurse("Ann", week: 3)

      busy = %{
        "Ann" => [
          Tempo.from_iso8601!("2027-04-05T09:00:00/2027-04-05T17:00:00"),
          Tempo.from_iso8601!("2027-04-06T09:00:00/2027-04-06T17:00:00")
        ]
      }

      assert {:partial, layout} =
               Agenda.arrange(roster(20), [ann], unplaced: :allow, busy: busy)

      # Two of the first week's three are gone, so only one more there.
      first_week = layout.placed |> days() |> Enum.filter(&(&1 <= 11))
      assert length(first_week) == 1
    end
  end

  describe "no limits changes nothing" do
    test "an unlimited resource fills every open day" do
      ann = nurse("Ann", [])

      assert {:partial, layout} = Agenda.arrange(roster(20), [ann], unplaced: :allow)

      assert length(layout.placed) == 12
    end

    test "and the search still proves minimality" do
      ann = nurse("Ann", [])

      {:partial, layout} = Agenda.arrange(roster(20), [ann], unplaced: :allow)

      assert layout.minimal?
    end
  end

  describe "limits and the rest of the library" do
    test "two nurses share the load when one is capped" do
      ann = nurse("Ann", week: 1)
      raj = nurse("Raj", [])

      assert {:partial, layout} = Agenda.arrange(roster(20), [ann, raj], unplaced: :allow)

      held =
        layout.placed
        |> Enum.flat_map(&Arrangement.resources/1)
        |> Enum.frequencies_by(& &1.name)

      assert held["Ann"] == 2
      assert held["Raj"] > held["Ann"]
    end

    test "an over-capped roster is still reported as partial, not fatal" do
      ann = nurse("Ann", week: 1)

      assert {:partial, layout} = Agenda.arrange(roster(20), [ann], unplaced: :allow)
      refute layout.unplaced == []
      assert Agenda.explain(layout) =~ "sessions placed"
    end
  end
end
