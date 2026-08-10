defmodule Agenda.Series do
  @moduledoc """
  A session that repeats — a weekly stand-up, a fortnightly clinic, a
  daily hand-over.

  A series is not a new kind of thing. Expanding one gives back
  ordinary sessions, each windowed to one occurrence, so everything
  that works on a session works on every occurrence: planning,
  arranging, allocating, explaining. What they share is a `:series`
  name, which is what lets the whole run be released together — or
  released from a date forward, leaving the past alone.

  The recurrence itself is Tempo's, so ISO 8601 (`R10/2027-03-02T09:00:00/P1W`)
  and RFC 5545 (`FREQ=WEEKLY;COUNT=10`) both work, and both expand
  correctly across daylight saving.

  ### Example

      iex> standup = Agenda.session("Stand-up", lasting: "PT15M")
      iex> {:ok, occurrences} = Agenda.every(standup, "R3/2027-03-02T09:00:00/P1W")
      iex> Enum.map(occurrences, & &1.name)
      ["Stand-up 1", "Stand-up 2", "Stand-up 3"]

      iex> standup = Agenda.session("Stand-up", lasting: "PT15M")
      iex> {:ok, [first | _]} = Agenda.every(standup, "R3/2027-03-02T09:00:00/P1W")
      iex> {first.series, Tempo.to_iso8601(first.window)}
      {"Stand-up", "2027Y3M2DT9H0M0S/2027Y3M9DT9H0M0S"}

  > *"The stand-up repeats weekly three times; the first occurrence may
  > fall anywhere in the week beginning the 2nd of March."*

  """

  alias Agenda.Availability
  alias Agenda.Session
  alias Tempo.IntervalSet

  @doc """
  Expand `session` over `pattern`, one occurrence per repetition.

  Each occurrence is a full session whose window is that repetition's
  span, so an occurrence can be planned, moved, or refused on its own.

  ### Arguments

  * `session` is the `t:Agenda.Session.t/0` to repeat. Its own
    window, if any, is replaced by each occurrence's.

  * `pattern` is a recurrence — an ISO 8601 repeating interval
    (preferred) or an RFC 5545 `RRULE`.

  ### Options

  * `:bound` bounds an otherwise unbounded recurrence. Required when
    `pattern` does not state its own count or end.

  ### Returns

  * `{:ok, sessions}`, one per occurrence, in time order; or

  * `{:error, reason}` when the pattern cannot be read or is unbounded
    and unbounded by `:bound`.

  ### Examples

      iex> clinic = Agenda.session("Clinic", lasting: "PT4H")
      iex> {:ok, occurrences} = Agenda.Series.expand(clinic, "R2/2027-03-02/P1D")
      iex> length(occurrences)
      2

      iex> clinic = Agenda.session("Clinic", lasting: "PT4H")
      iex> Agenda.Series.expand(clinic, "not a recurrence")
      {:error, :unreadable_pattern}

  """
  @spec expand(Session.t(), Availability.pattern(), keyword()) ::
          {:ok, [Session.t()]} | {:error, term()}
  def expand(%Session{} = session, pattern, options \\ []) do
    with {:ok, recurrence} <- Availability.normalise(pattern),
         {:ok, occurrences} <- materialise(recurrence, options) do
      {:ok,
       occurrences
       |> IntervalSet.to_list()
       |> Enum.with_index(1)
       |> Enum.map(&occurrence(session, &1))}
    end
  end

  defp materialise(recurrence, options) do
    case Keyword.fetch(options, :bound) do
      {:ok, bound} -> Tempo.to_interval(recurrence, bound: bound)
      :error -> Tempo.to_interval(recurrence)
    end
    |> as_set()
  end

  defp as_set({:ok, %IntervalSet{} = set}), do: {:ok, set}
  defp as_set({:ok, interval}), do: {:ok, IntervalSet.new!([interval])}
  defp as_set({:error, reason}), do: {:error, reason}

  # Each occurrence keeps the original's requirements and length, and
  # takes the repetition's span as its window. The series name is what
  # they hold in common.
  defp occurrence(%Session{} = session, {window, index}) do
    %{session | name: "#{session.name} #{index}", window: window, series: session.name}
  end
end
