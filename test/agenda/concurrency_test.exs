defmodule Agenda.ConcurrencyTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils
  import Agenda.Predicate

  alias Agenda.Arranger
  alias Agenda.Availability
  alias Agenda.Programme
  alias Agenda.Session
  alias Tempo.Compare
  alias Tempo.IntervalSet

  @morning "2027-03-02T09:00:00/2027-03-02T12:00:00"
  @window "2027-03-02/2027-03-03"

  defp resource(name, concurrency) do
    {:ok, resource} =
      Agenda.resource(name, seats: 1, concurrency: concurrency)
      |> Agenda.open(@morning)

    resource
  end

  defp claims(count, from, to) do
    List.duplicate("2027-03-02T#{from}:00:00/2027-03-02T#{to}:00:00", count)
  end

  defp free_hours(resource, busy) do
    {:ok, free} = Availability.free(resource, within: @window, busy: busy)

    free
    |> IntervalSet.to_list()
    |> Enum.map(fn i ->
      Compare.to_utc_seconds(i.to) - Compare.to_utc_seconds(i.from)
    end)
    |> Enum.sum()
    |> div(3600)
  end

  describe "free/2 honours concurrency" do
    test "the default of one is unavailable as soon as it is claimed" do
      assert free_hours(resource("Room", 1), claims(1, "09", "10")) == 2
    end

    test "a resource with room to spare stays free while under-subscribed" do
      lockers = resource("Lockers", 20)

      assert free_hours(lockers, claims(1, "09", "10")) == 3
      assert free_hours(lockers, claims(19, "09", "10")) == 3
    end

    test "it becomes unavailable exactly when claims reach concurrency" do
      lockers = resource("Lockers", 20)

      assert free_hours(lockers, claims(20, "09", "10")) == 2
    end

    test "over-subscription does not make it more unavailable" do
      lockers = resource("Lockers", 20)

      assert free_hours(lockers, claims(25, "09", "10")) == 2
    end

    test "saturation is measured per instant, not per day" do
      # Twenty claims at nine and one at eleven: only the nine o'clock
      # hour is used up.
      lockers = resource("Lockers", 20)
      busy = claims(20, "09", "10") ++ claims(1, "11", "12")

      assert free_hours(lockers, busy) == 2
    end

    test "claims that merely meet never accumulate" do
      # Three back-to-back claims on a concurrency-3 desk are one holder
      # at a time, so the desk is never used up and every hour stays
      # available. Under the old behaviour all three hours were lost.
      desk = resource("Hot desk", 3)
      busy = claims(1, "09", "10") ++ claims(1, "10", "11") ++ claims(1, "11", "12")

      assert free_hours(desk, busy) == 3
    end

    test "the same desk at concurrency one loses all three hours" do
      desk = resource("Hot desk", 1)
      busy = claims(1, "09", "10") ++ claims(1, "10", "11") ++ claims(1, "11", "12")

      assert free_hours(desk, busy) == 0
    end
  end

  describe "plan/3 honours concurrency" do
    defp hire(pool, busy) do
      session =
        Agenda.session("Locker hire", duration: ~o"PT1H", window: ~o"2027-03-02/2027-03-03")
        |> Session.needs(:room, seats: at_least(1))

      {:ok, options} = Agenda.plan(session, pool, busy: busy)
      options
    end

    test "a slot is still offered while the resource has room" do
      lockers = resource("Lockers", 3)

      assert length(hire([lockers], %{"Lockers" => claims(2, "09", "10")})) == 3
    end

    test "a saturated slot is withdrawn" do
      lockers = resource("Lockers", 3)

      options = hire([lockers], %{"Lockers" => claims(3, "09", "10")})

      assert length(options) == 2
      refute Enum.any?(options, &(&1.interval.from == ~o"2027Y3M2DT9H0M0S"))
    end
  end

  describe "arrange/3 honours concurrency" do
    defp booking(name) do
      Agenda.session(name, duration: ~o"PT1H")
      |> Session.needs(:desk, seats: at_least(1))
    end

    defp programme_of(names) do
      Enum.reduce(names, Agenda.programme("P", across: @window), fn name, acc ->
        Programme.add_session(acc, booking(name))
      end)
    end

    test "sessions may share a resource up to its concurrency" do
      # Three bookings, one three-person desk, only one hour available.
      {:ok, desk} =
        Agenda.resource("Desk", seats: 1, concurrency: 3)
        |> Agenda.open("2027-03-02T09:00:00/2027-03-02T10:00:00")

      assert {:ok, arrangements} = Arranger.arrange(programme_of(["A", "B", "C"]), [desk])
      assert length(arrangements) == 3

      # All three at the same time — that is the point of concurrency.
      assert arrangements |> Enum.map(& &1.interval.from) |> Enum.uniq() |> length() == 1
    end

    test "one more than the concurrency does not fit" do
      {:ok, desk} =
        Agenda.resource("Desk", seats: 1, concurrency: 3)
        |> Agenda.open("2027-03-02T09:00:00/2027-03-02T10:00:00")

      assert {:error, _reason} = Arranger.arrange(programme_of(["A", "B", "C", "D"]), [desk])
    end

    test "a concurrency-1 resource still serialises" do
      {:ok, desk} =
        Agenda.resource("Desk", seats: 1)
        |> Agenda.open("2027-03-02T09:00:00/2027-03-02T11:00:00")

      assert {:ok, [a, b]} = Arranger.arrange(programme_of(["A", "B"]), [desk])
      assert Tempo.disjoint?(a.interval, b.interval)
    end
  end
end
