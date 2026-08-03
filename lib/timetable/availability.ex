defmodule Timetable.Availability do
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

      iex> boardroom = Timetable.Resource.new("Boardroom")
      iex> {:ok, boardroom} = Timetable.Availability.open(boardroom, "R5/2026-06-15/P1D")
      iex> {:ok, free} = Timetable.Availability.free(boardroom, within: "2026-06-15/2026-06-17")
      iex> Tempo.IntervalSet.count(free)
      2

  > *"The boardroom is open for five days from the 15th; across the
  > 15th and 16th that leaves two free days."*

  """

  alias Tempo.Duration
  alias Tempo.Interval
  alias Tempo.IntervalSet
  alias Tempo.RRule
  alias Timetable.Resource

  @typedoc "A Tempo value that already denotes a span."
  @type span :: Tempo.t() | Tempo.Interval.t() | Tempo.Duration.t() | IntervalSet.t()

  @typedoc """
  Anything that can be read as a span: a Tempo value, or a string in
  ISO 8601 (preferred) or RFC 5545 `RRULE` form.
  """
  @type pattern :: span() | String.t()

  @doc """
  Set when `resource` is open.

  ### Arguments

  * `resource` is a `t:Timetable.Resource.t/0`.

  * `pattern` is a Tempo value, an ISO 8601 string (preferred), or an
    RFC 5545 `RRULE` string.

  ### Returns

  * `{:ok, resource}` with its open hours set; or

  * `{:error, reason}` when `pattern` cannot be read as a span.

  ### Examples

      iex> boardroom = Timetable.Resource.new("Boardroom")
      iex> {:ok, boardroom} = Timetable.Availability.open(boardroom, "2026-06-15T09:00:00/2026-06-15T17:00:00")
      iex> Tempo.to_iso8601(boardroom.open)
      "2026Y6M15DT9H0M0S/2026Y6M15DT17H0M0S"

      iex> boardroom = Timetable.Resource.new("Boardroom")
      iex> Timetable.Availability.open(boardroom, "not a time")
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

      iex> {:ok, value} = Timetable.Availability.normalise("R5/2026-06-15/P1D")
      iex> value.recurrence
      5

      iex> {:ok, value} = Timetable.Availability.normalise("FREQ=DAILY;COUNT=3")
      iex> value.recurrence
      3

  """
  @spec normalise(term()) :: {:ok, span()} | {:error, :unreadable_pattern}
  def normalise(%IntervalSet{} = value), do: {:ok, value}
  def normalise(%Interval{} = value), do: {:ok, value}
  def normalise(%Duration{} = value), do: {:ok, value}
  def normalise(%Tempo{} = value), do: {:ok, value}

  def normalise(pattern) when is_binary(pattern) do
    with {:error, _iso} <- Tempo.from_iso8601(pattern),
         {:error, _rrule} <- rrule(pattern) do
      {:error, :unreadable_pattern}
    end
  end

  def normalise(_pattern), do: {:error, :unreadable_pattern}

  # `Tempo.RRule.parse/2` raises rather than returning an error tuple on
  # some malformed input, and a library function must not crash on a
  # value that merely turned out not to be an RRULE.
  defp rrule(pattern) do
    RRule.parse(pattern, [])
  rescue
    _error -> {:error, :not_an_rrule}
  end

  @doc """
  The time `resource` is open and not already taken.

  `free = open − busy`, clipped to the query window. Computed on
  demand, so it cannot go stale.

  ### Arguments

  * `resource` is a `t:Timetable.Resource.t/0`.

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

      iex> boardroom = Timetable.Resource.new("Boardroom")
      iex> {:ok, boardroom} = Timetable.Availability.open(boardroom, "2026-06-15T09:00:00/2026-06-15T17:00:00")
      iex> {:ok, free} = Timetable.Availability.free(boardroom,
      ...>   within: "2026-06-15/2026-06-16",
      ...>   busy: "2026-06-15T12:00:00/2026-06-15T13:00:00")
      iex> free |> Tempo.IntervalSet.to_list() |> Enum.map(&Tempo.to_iso8601/1)
      ["2026Y6M15DT9H0M0S/2026Y6M15DT12H0M0S", "2026Y6M15DT13H0M0S/2026Y6M15DT17H0M0S"]

  A resource with no open hours is never free:

      iex> Timetable.Resource.new("Boardroom")
      ...> |> Timetable.Availability.free(within: "2026-06-15/2026-06-16")
      ...> |> then(fn {:ok, free} -> Tempo.IntervalSet.empty?(free) end)
      true

  """
  @spec free(Resource.t(), keyword()) :: {:ok, IntervalSet.t()} | {:error, term()}
  def free(%Resource{open: nil}, _options), do: {:ok, IntervalSet.new!([])}

  def free(%Resource{} = resource, options) do
    with {:ok, window} <- normalise(Keyword.fetch!(options, :within)),
         {:ok, open} <- within(resource.open, window),
         {:ok, busy} <- busy_set(Keyword.get(options, :busy, []), window) do
      busy
      |> with_turnaround(resource)
      |> saturated(resource.concurrency)
      |> then(&Tempo.difference(open, &1))
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
