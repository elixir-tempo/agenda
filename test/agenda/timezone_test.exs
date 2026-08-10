defmodule Agenda.TimezoneTest do
  use ExUnit.Case, async: true

  alias Agenda.Availability
  alias Tempo.Compare
  alias Tempo.IntervalSet

  # Without a real IANA database Elixir resolves every zone as UTC and
  # DST arithmetic is silently wrong — a spring-forward day looks a full
  # hour longer than it is, and nothing raises. These tests fail if the
  # `:time_zone_database` configuration is ever lost.

  defp hours(set) do
    set
    |> IntervalSet.to_list()
    |> Enum.map(fn i -> Compare.to_utc_seconds(i.to) - Compare.to_utc_seconds(i.from) end)
    |> Enum.sum()
    |> div(3600)
  end

  defp open_for(iso) do
    {:ok, value} = Tempo.from_iso8601(iso)
    {:ok, resource} = Agenda.open(Agenda.resource("R"), value)
    {:ok, free} = Availability.free(resource, within: value)
    hours(free)
  end

  describe "a real timezone database is configured" do
    test "the configured database is not the UTC-only default" do
      refute Calendar.get_time_zone_database() == Calendar.UTCOnlyTimeZoneDatabase
    end
  end

  describe "daylight saving" do
    test "an ordinary day is the length it looks" do
      assert open_for("2027-03-27T00:00:00[Europe/London]/2027-03-27T06:00:00[Europe/London]") ==
               6
    end

    test "a spring-forward day loses the skipped hour" do
      # London goes 01:00 GMT -> 02:00 BST on 2027-03-28, so midnight to
      # six in the morning is five hours of real time, not six.
      assert open_for("2027-03-28T00:00:00[Europe/London]/2027-03-28T06:00:00[Europe/London]") ==
               5
    end

    test "an autumn-fallback day gains the repeated hour" do
      # London goes 02:00 BST -> 01:00 GMT on 2027-10-31.
      assert open_for("2027-10-31T00:00:00[Europe/London]/2027-10-31T06:00:00[Europe/London]") ==
               7
    end

    test "the southern hemisphere transitions the other way" do
      # Sydney goes 03:00 AEDT -> 02:00 AEST on 2027-04-04.
      assert open_for(
               "2027-04-04T00:00:00[Australia/Sydney]/2027-04-04T06:00:00[Australia/Sydney]"
             ) == 7
    end
  end
end
