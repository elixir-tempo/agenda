defmodule Agenda.Hours do
  @moduledoc false

  alias Tempo.Interval

  # A span of whole hours on one day, built from its parts. Tests that
  # vary a day or an hour build the span rather than write its text,
  # as Tempo asks of every program that holds the parts.

  @spec on({Calendar.year(), Calendar.month(), Calendar.day()}, Calendar.hour(), Calendar.hour()) ::
          Tempo.t()
  def on({year, month, day}, from_hour, to_hour) do
    Interval.new!(
      from: at(year, month, day, from_hour),
      to: at(year, month, day, to_hour)
    )
  end

  defp at(year, month, day, hour) do
    Tempo.new!(year: year, month: month, day: day, hour: hour, minute: 0, second: 0)
  end
end
