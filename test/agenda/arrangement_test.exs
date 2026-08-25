defmodule Agenda.ArrangementTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Arrangement

  doctest Agenda.Arrangement

  defp at(interval), do: %Arrangement{interval: interval}

  describe "compare/2" do
    test "orders by start" do
      early = at(~o"2026-06-16T09:00:00/2026-06-16T10:00:00")
      late = at(~o"2026-06-16T12:00:00/2026-06-16T13:00:00")

      assert Arrangement.compare(early, late) == :lt
      assert Arrangement.compare(late, early) == :gt
    end

    test "then by end, so the shorter of two simultaneous sessions comes first" do
      short = at(~o"2026-06-16T09:00:00/2026-06-16T09:20:00")
      long = at(~o"2026-06-16T09:00:00/2026-06-16T10:00:00")

      assert Arrangement.compare(short, long) == :lt
    end

    test "equal intervals compare equal" do
      one = at(~o"2026-06-16T09:00:00/2026-06-16T10:00:00")
      other = at(~o"2026-06-16T09:00:00/2026-06-16T10:00:00")

      assert Arrangement.compare(one, other) == :eq
    end

    test "the session name does not affect the order" do
      a = %Arrangement{session: "Zulu", interval: ~o"2026-06-16T09:00:00/2026-06-16T10:00:00"}
      b = %Arrangement{session: "Alpha", interval: ~o"2026-06-16T12:00:00/2026-06-16T13:00:00"}

      assert Arrangement.compare(a, b) == :lt
    end
  end

  describe "sorting a layout" do
    test "Enum.sort/2 takes the module, as it does for Date and Tempo" do
      first = at(~o"2026-06-16T09:00:00/2026-06-16T10:00:00")
      second = at(~o"2026-06-16T11:00:00/2026-06-16T12:00:00")
      third = at(~o"2026-06-16T14:00:00/2026-06-16T15:00:00")

      assert Enum.sort([third, first, second], Arrangement) == [first, second, third]
    end

    test "and it agrees with sorting by the interval through Tempo" do
      layout =
        Enum.map(
          [
            ~o"2026-06-16T14:00:00/2026-06-16T15:00:00",
            ~o"2026-06-16T09:00:00/2026-06-16T10:00:00",
            ~o"2026-06-16T11:00:00/2026-06-16T12:00:00"
          ],
          &at/1
        )

      assert Enum.sort(layout, Arrangement) == Enum.sort_by(layout, & &1.interval, Tempo)
    end

    test "an empty layout sorts to itself" do
      assert Enum.sort([], Arrangement) == []
    end
  end
end
