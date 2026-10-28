defmodule Agenda.Written do
  @moduledoc false

  # A span written into a sentence: an explanation, a refusal, the name of
  # a hold. ISO 8601 text names a calendar only by its IXDTF name, so a span
  # of a calendar with none (a fiscal calendar's) cannot be written in it;
  # such a span is written in the Gregorian calendar, the one a sentence
  # names its times in. Decided as Tempo's decision 69.

  alias Tempo.Iso8601EncodeError

  @spec span(Tempo.t()) :: String.t()
  def span(%Tempo{} = span) do
    span
    |> Tempo.to_iso8601()
    |> written(span)
  end

  defp written({:ok, text}, _span) do
    text
  end

  defp written({:error, %Iso8601EncodeError{reason: {:calendar, _calendar}}}, span) do
    span
    |> Tempo.to_calendar!(Calendar.ISO)
    |> Tempo.to_iso8601!()
  end

  defp written({:error, exception}, _span) do
    raise(exception)
  end
end
