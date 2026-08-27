defmodule Agenda.Availability do
  @moduledoc """
  When a resource is open, and what of that is still free.

  Two ideas carry the whole module:

  * **Open hours are a Tempo value**, so a resource is open for a single
    interval, a recurring pattern, or any set algebra over them — and
    the calendar, timezone, and DST correctness comes from Tempo rather
    than from anything written here.

  * **Free time is derived, never stored.** `free/2` is
    `open − busy`, computed on demand. There is no free/busy record to
    go stale, and no release step that can be forgotten: a resource
    stops being busy the moment nothing claims it.

  ### Stating open hours

  ISO 8601 is the preferred spelling — it is what Tempo stores and what
  `inspect/1` returns — but `open/2` accepts an RFC 5545 `RRULE` too,
  since that is what most calendar systems emit:

      iex> boardroom = Agenda.Resource.new("Boardroom")
      iex> {:ok, boardroom} = Agenda.Availability.open(boardroom, "R5/2026-06-15/P1D")
      iex> {:ok, free} = Agenda.Availability.free(boardroom, within: "2026-06-15/2026-06-17")
      iex> Tempo.IntervalSet.count(free)
      2

  > *"The boardroom is open for five days from the 15th; across the
  > 15th and 16th that leaves two free days."*

  """

  alias Agenda.Resource
  alias Tempo.Duration
  alias Tempo.Interval
  alias Tempo.IntervalSet
  alias Tempo.RRule

  @typedoc "A Tempo value that already denotes a span."
  @type span :: Tempo.t() | Tempo.Interval.t() | Tempo.Duration.t() | IntervalSet.t()

  @typedoc """
  Availability imported from an RFC 7953 `VAVAILABILITY`, held
  unmaterialised until a query window is known — exactly as a
  recurrence is.
  """
  @type imported :: {:vavailability, term()}

  @typedoc """
  Anything that can be read as a span: a Tempo value, a string in
  ISO 8601 (preferred) or RFC 5545 `RRULE` form, or the result of
  `from_ical/1`.
  """
  @type pattern :: span() | String.t() | imported()

  @doc """
  Set when `resource` is open.

  ### Arguments

  * `resource` is a `t:Agenda.Resource.t/0`.

  * `pattern` is a Tempo value, an ISO 8601 string (preferred), or an
    RFC 5545 `RRULE` string.

  ### Returns

  * `{:ok, resource}` with its open hours set; or

  * `{:error, reason}` when `pattern` cannot be read as a span.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Agenda.Resource.new("Boardroom")
      iex> {:ok, boardroom} = Agenda.Availability.open(boardroom, "2026-06-15T09:00:00/2026-06-15T17:00:00")
      iex> boardroom.open
      ~o"2026Y6M15DT9H0M0S/T17H0M0S"

      iex> boardroom = Agenda.Resource.new("Boardroom")
      iex> Agenda.Availability.open(boardroom, "not a time")
      {:error, :unreadable_pattern}

  """
  @spec open(Resource.t(), pattern()) :: {:ok, Resource.t()} | {:error, term()}
  def open(%Resource{} = resource, pattern) do
    case normalise(pattern) do
      {:ok, value} -> {:ok, %{resource | open: value}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Open hours on a resource, raising on a pattern it cannot read.

  The `!` companion to `open/2`, for the case where the pattern is a
  literal in the source rather than data: a guide, a notebook, or a
  fixture. There the tuple is pure ceremony — an unreadable literal is
  a typo, not a condition to handle — and unwrapping it at every setup
  line buries what the example is actually about.

  Reach for `open/2` wherever the pattern comes from outside the
  program, which is most of an application.

  ### Arguments

  * `resource` is a `t:Agenda.Resource.t/0`.

  * `pattern` is as for `open/2`.

  ### Returns

  * the resource with its open hours set; or raises `ArgumentError`.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Agenda.Availability.open!(Agenda.resource("Boardroom"), "2026-06-15T09:00:00/2026-06-15T17:00:00")
      iex> boardroom.open
      ~o"2026Y6M15DT9H0M0S/2026Y6M15DT17H0M0S"

      iex> Agenda.Availability.open!(Agenda.resource("Boardroom"), "not a pattern")
      ** (ArgumentError) Boardroom: cannot read :unreadable_pattern as open hours

  """
  @spec open!(Resource.t(), pattern()) :: Resource.t()
  def open!(%Resource{} = resource, pattern) do
    case open(resource, pattern) do
      {:ok, opened} ->
        opened

      {:error, reason} ->
        raise ArgumentError, "#{resource.name}: cannot read #{inspect(reason)} as open hours"
    end
  end

  @doc """
  Read `pattern` as a Tempo value.

  Tempo values pass through untouched. Strings are tried as ISO 8601
  first — the preferred spelling — and then as an RFC 5545 `RRULE`, so
  a calendar system's own recurrence rule is accepted at the interface
  without the caller translating it.

  ### Arguments

  * `pattern` is a Tempo value or a string.

  ### Returns

  * `{:ok, value}`; or

  * `{:error, :unreadable_pattern}` when it is neither.

  ### Examples

      iex> {:ok, value} = Agenda.Availability.normalise("R5/2026-06-15/P1D")
      iex> value.recurrence
      5

      iex> {:ok, value} = Agenda.Availability.normalise("FREQ=DAILY;COUNT=3")
      iex> value.recurrence
      3

  """
  @spec normalise(term()) :: {:ok, span() | imported()} | {:error, :unreadable_pattern}
  def normalise({:vavailability, _calendar} = imported), do: {:ok, imported}
  def normalise(%IntervalSet{} = value), do: {:ok, value}
  def normalise(%Interval{} = value), do: {:ok, value}
  def normalise(%Duration{} = value), do: {:ok, value}
  def normalise(%Tempo{} = value), do: {:ok, value}

  def normalise(pattern) when is_binary(pattern) do
    with {:error, _iso} <- Tempo.from_iso8601(pattern),
         {:error, _rrule} <- RRule.parse(pattern, []) do
      {:error, :unreadable_pattern}
    end
  end

  def normalise(_pattern), do: {:error, :unreadable_pattern}

  @doc """
  Read a resource's open hours from an RFC 7953 `VAVAILABILITY`.

  This is how a calendar system states availability, and it is what a
  CalDAV server will hand you. The result is a pattern for `open/2`,
  held unmaterialised until a query window is known — a
  `VAVAILABILITY` whose `AVAILABLE` subcomponents recur has no extent
  of its own, exactly as an ISO 8601 recurrence has none.

  `VEVENT`s in the same document are ignored. They are what is
  *taken*, not what is *offered*, and belong in `free/2`'s `:busy`
  rather than in a resource's open hours.

  Requires the optional `ical` dependency.

  ### Arguments

  * `ics` is iCalendar data as a string.

  ### Returns

  * `{:ok, pattern}` to hand to `open/2`; or

  * `{:error, reason}` when the data cannot be read, or when `ical`
    is not available.

  ### Examples

      iex> ics = \"\"\"
      ...> BEGIN:VCALENDAR
      ...> VERSION:2.0
      ...> BEGIN:VAVAILABILITY
      ...> UID:clinic
      ...> DTSTAMP:20260601T000000Z
      ...> BEGIN:AVAILABLE
      ...> UID:weekday-clinic
      ...> DTSTAMP:20260601T000000Z
      ...> DTSTART:20260601T090000Z
      ...> DTEND:20260601T170000Z
      ...> RRULE:FREQ=DAILY;COUNT=5
      ...> END:AVAILABLE
      ...> END:VAVAILABILITY
      ...> END:VCALENDAR
      ...> \"\"\"
      iex> {:ok, hours} = Agenda.Availability.from_ical(ics)
      iex> {:ok, clinic} = Agenda.open(Agenda.resource("Clinic"), hours)
      iex> {:ok, free} = Agenda.free(clinic, within: "2026-06-01/2026-06-08")
      iex> Tempo.IntervalSet.count(free)
      5

  """
  @spec from_ical(String.t()) :: {:ok, imported()} | {:error, :ical_not_available | String.t()}
  def from_ical(ics) when is_binary(ics) do
    if Code.ensure_loaded?(Tempo.ICal) do
      # `apply/3` rather than a direct call: `ical` is an optional
      # dependency, so `ICal` may not exist at compile time and a
      # direct call would warn in every project that does not import
      # calendar data.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      {:ok, {:vavailability, apply(ICal, :from_ics, [ics])}}
    else
      {:error, :ical_not_available}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc """
  The time `resource` is open and not already taken.

  `free = open − busy`, clipped to the query window. Computed on
  demand, so it cannot go stale.

  ### Arguments

  * `resource` is a `t:Agenda.Resource.t/0`.

  ### Options

  * `:within` is the query window — a Tempo value or ISO 8601 string.
    Required: an unbounded recurrence has no materialisation without
    one.

  * `:busy` is what already claims the resource — a Tempo value, a
    string, an `t:Tempo.IntervalSet.t/0`, or a list of them. The
    default is `[]`.

  ### Returns

  * `{:ok, interval_set}` of the free spans; or

  * `{:error, reason}` when the window or a pattern cannot be read.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Agenda.Resource.new("Boardroom")
      iex> {:ok, boardroom} = Agenda.Availability.open(boardroom, "2026-06-15T09:00:00/2026-06-15T17:00:00")
      iex> {:ok, free} = Agenda.Availability.free(boardroom,
      ...>   within: "2026-06-15/2026-06-16",
      ...>   busy: "2026-06-15T12:00:00/2026-06-15T13:00:00")
      iex> Tempo.IntervalSet.members(free)
      [~o"2026Y6M15DT9H0M0S/T12H0M0S",
       ~o"2026Y6M15DT13H0M0S/T17H0M0S"]

  A resource with no open hours is never free:

      iex> Agenda.Resource.new("Boardroom")
      ...> |> Agenda.Availability.free(within: "2026-06-15/2026-06-16")
      ...> |> then(fn {:ok, free} -> Tempo.IntervalSet.empty?(free) end)
      true

  """
  @spec free(Resource.t(), keyword()) :: {:ok, IntervalSet.t()} | {:error, term()}
  def free(%Resource{open: nil}, _options), do: {:ok, IntervalSet.new!([])}

  def free(%Resource{} = resource, options) do
    with :ok <- usable_buffers(resource),
         {:ok, within} <- required(options, :within),
         {:ok, window} <- normalise(within),
         {:ok, open} <- within(resource.open, window),
         {:ok, busy} <- busy_set(Keyword.get(options, :busy, []), window) do
      busy
      |> with_turnaround(resource)
      |> saturated(resource.concurrency)
      |> then(&Tempo.difference(open, &1))
    end
  end

  # `Agenda.Resource.new/2` parses a buffer written as a string, so
  # anything still unparsed here was never a duration. Saying so is the
  # difference between an error the caller can act on and a
  # `FunctionClauseError` raised several frames inside `Tempo.shift/2`,
  # on some later call where the resource happened to be busy.
  # A required option. Absent, it is an error tuple like any other bad
  # input rather than a `KeyError` raised several frames from the call.
  defp required(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, name}}
    end
  end

  defp usable_buffers(%Resource{} = resource) do
    [before: resource.buffer_before, after: resource.buffer_after]
    |> Enum.reject(fn {_which, value} -> value == nil or is_struct(value, Tempo.Duration) end)
    |> case do
      [] -> :ok
      [{which, value} | _rest] -> {:error, {:invalid_buffer, resource.name, which, value}}
    end
  end

  # A claim costs more than the time it books: the room has to be set
  # up before and reset afterwards. Widening each claim by the
  # resource's turnaround makes that time genuinely unavailable rather
  # than something the caller has to remember to leave free.
  defp with_turnaround(busy, %Resource{buffer_before: nil, buffer_after: nil}), do: busy

  defp with_turnaround(busy, %Resource{} = resource) do
    IntervalSet.map(busy, &widen(&1, resource))
    |> IntervalSet.new!()
  end

  defp widen(%Interval{} = claim, %Resource{} = resource) do
    %{
      claim
      | from: earlier_by(claim.from, resource.buffer_before),
        to: later_by(claim.to, resource.buffer_after)
    }
  end

  defp earlier_by(point, nil), do: point
  defp earlier_by(point, duration), do: Tempo.shift(point, Duration.negate(duration))

  defp later_by(point, nil), do: point
  defp later_by(point, duration), do: Tempo.shift(point, duration)

  # A resource is only unavailable where enough claims overlap to use
  # it up. At the default concurrency of one that is anywhere it is
  # claimed at all; a bank of twenty lockers stays free until the
  # twenty-first person wants one.
  defp saturated(busy, concurrency) do
    IntervalSet.overlapping(busy, at_least: concurrency)
  end

  # An imported `VAVAILABILITY` states availability directly, so
  # materialising it *is* asking what it offers over the window —
  # `Tempo.ICal.available/2` already clips to that window, resolves
  # PRIORITY across overlapping components, and expands each
  # `AVAILABLE` recurrence.
  defp within({:vavailability, calendar}, window) do
    # See `from_ical/1` for why this is `apply/3`.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(Tempo.ICal, :available, [calendar, [within: window]])
  end

  # Materialise the open pattern against the window, then clip to it.
  # An unbounded recurrence needs the window as its bound; a plain
  # interval needs no materialisation at all.
  defp within(open, window) do
    case Tempo.to_interval(open, bound: window) do
      {:ok, materialised} -> Tempo.intersection(materialised, window)
      {:error, _reason} -> Tempo.intersection(open, window)
    end
  end

  # Everything claiming the resource, collapsed into a *single*
  # interval set. Handing `Tempo.difference/3` a list would fold one
  # sweep per member — a resource with a year of bookings behind it
  # would pay hundreds of passes over its own open hours. One set is
  # one sweep, and the cost stops tracking the size of the ledger.
  defp busy_set(busy, window) when is_list(busy) do
    busy
    |> Enum.reduce_while({:ok, []}, fn one, {:ok, acc} ->
      case claimed_intervals(one, window) do
        {:ok, intervals} -> {:cont, {:ok, acc ++ intervals}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, intervals} -> IntervalSet.new(intervals)
      {:error, reason} -> {:error, reason}
    end
  end

  defp busy_set(busy, window), do: busy_set([busy], window)

  defp claimed_intervals(one, window) do
    with {:ok, value} <- normalise(one),
         {:ok, materialised} <- within(value, window) do
      {:ok, IntervalSet.to_list(materialised)}
    end
  end
end
