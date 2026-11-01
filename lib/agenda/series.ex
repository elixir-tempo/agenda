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

      iex> standup = Agenda.session("Stand-up", duration: "PT15M")
      iex> {:ok, occurrences} = Agenda.every(standup, "R3/2027-03-02T09:00:00/P1W")
      iex> Enum.map(occurrences, & &1.name)
      ["Stand-up 1", "Stand-up 2", "Stand-up 3"]

      iex> import Tempo.Sigils
      iex> standup = Agenda.session("Stand-up", duration: "PT15M")
      iex> {:ok, [first | _]} = Agenda.every(standup, "R3/2027-03-02T09:00:00/P1W")
      iex> {first.series, first.window}
      {"Stand-up", ~o"2027Y3M2DT9H0M0S/9DT9H0M0S"}

  > *"The stand-up repeats weekly three times; the first occurrence may
  > fall anywhere in the week beginning the 2nd of March."*

  ### Identity

  An occurrence carries two identities, and every arrangement planned
  for it and every allocation it holds carries them too:

  * **`series`** is the original session's name: the whole run, as
    iCalendar's master event is. `Agenda.release_series/3` frees by it.

  * **`recurrence_id`** is the start of the repetition the occurrence
    was expanded for: which occurrence it is, as iCalendar's
    `RECURRENCE-ID` is the original start of an instance. It stays the
    same wherever in its window the occurrence is planned, and however
    often it is re-planned.

  An occurrence's name (`"Stand-up 3"`) counts its place in one
  expansion, so it changes when the run starts later; its
  `recurrence_id` does not. An adapter writes the run as one iCalendar
  event, the instances keyed by `recurrence_id`, rather than as many
  unrelated ones.

  `expand/3` expands a session over a pattern, one occurrence per
  repetition.

  """

  alias Agenda.Availability
  alias Agenda.Session
  alias Tempo.Interval
  alias Tempo.IntervalSet

  @doc """
  Expand `session` over `pattern`, one occurrence per repetition.

  Each occurrence is a full session whose window is that repetition's
  span, so an occurrence can be planned, moved, or refused on its own.
  Its `series` is `session`'s name and its `recurrence_id` the
  repetition's start.

  ### Arguments

  * `session` is the `t:Agenda.Session.t/0` to repeat. Its own
    window, if any, is replaced by each occurrence's.

  * `pattern` is a recurrence — an ISO 8601 repeating interval
    (preferred) or an RFC 5545 `RRULE`.

  * `options` is a keyword list of options.

  ### Options

  * `:bound` bounds an otherwise unbounded recurrence: the occurrences
    that overlap it are expanded. Required when `pattern` does not state
    its own count or end.

  ### Returns

  * `{:ok, sessions}`, one per occurrence, in time order, or

  * `{:error, reason}` when the pattern cannot be read or is unbounded
    and unbounded by `:bound`.

  ### Examples

      iex> clinic = Agenda.session("Clinic", duration: "PT4H")
      iex> {:ok, occurrences} = Agenda.Series.expand(clinic, "R2/2027-03-02/P1D")
      iex> length(occurrences)
      2

      iex> import Tempo.Sigils
      iex> clinic = Agenda.session("Clinic", duration: "PT4H")
      iex> {:ok, occurrences} = Agenda.Series.expand(clinic, "R2/2027-03-02/P1D")
      iex> Enum.map(occurrences, & &1.recurrence_id)
      [~o"2027Y3M2D", ~o"2027Y3M3D"]

      iex> clinic = Agenda.session("Clinic", duration: "PT4H")
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
       |> IntervalSet.members()
       |> Enum.with_index(1)
       |> Enum.map(&occurrence(session, &1))}
    end
  end

  defp materialise(recurrence, options) do
    case Keyword.fetch(options, :bound) do
      {:ok, bound} -> Tempo.to_interval(recurrence, within: bound)
      :error -> Tempo.to_interval(recurrence)
    end
  end

  # Each occurrence keeps the original's requirements and length, and
  # takes the repetition's span as its window. The series name is what
  # they hold in common, and the repetition's start is which one it is.
  defp occurrence(%Session{} = session, {window, index}) do
    %{
      session
      | name: "#{session.name} #{index}",
        window: window,
        series: session.name,
        recurrence_id: Interval.from(window)
    }
  end
end
