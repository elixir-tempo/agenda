defmodule Agenda.Limit do
  @moduledoc """
  How much of a resource may — or must — be claimed over a period.

  A limit is a budget on a stretch of calendar. It is not concurrency:
  concurrency asks how many claims may overlap at one instant, a limit
  asks how much falls inside a day, a week or a month, however far
  apart the claims sit.

  ## Two measures

  A limit counts either **claims** or **time**, and the difference is
  the difference between a roster and a timesheet:

      Agenda.resource("Dana", limits: [day: 3, week: 12])
      Agenda.resource("Dana", limits: [day: ~o"PT7H36M", week: ~o"PT38H"])

  The first says *"at most three engagements a day"*. The second says
  *"at most seven hours thirty-six minutes a day"* — the same period
  vocabulary and the same ledger, measured in duration rather than
  cardinality. Eight open hours is not eight jobs, and neither is it
  eight hours of billable work.

  ## Ceilings and floors

  An integer or a duration on its own is a **ceiling**. A floor is
  written explicitly, and both ends may be given at once:

      limits: [week: [at_least: ~o"PT38H", at_most: ~o"PT45H"]]

  > *"At least a full week, and no more than forty-five hours."*

  **Only ceilings constrain the search**, and this is a real asymmetry
  rather than an omission. A ceiling prunes: a candidate that would
  breach it can be rejected the moment it is considered, because
  nothing added later can bring the total back down. A floor cannot be
  used that way — a partial layout is *supposed* to be under the floor,
  and rejecting it would reject every layout before the last placement.

  So a floor is a **completion** condition, not a placement condition.
  `Agenda.arrange/3` and `Agenda.plan/3` enforce ceilings and ignore
  floors; `Agenda.reconcile/3` checks both, because it is the function
  that looks at a finished period and asks whether it adds up.

  """

  alias Agenda.Allocation
  alias Tempo.Duration
  alias Tempo.Interval

  @periods [:day, :week, :month]

  @typedoc """
  What a limit counts — claims, or time.
  """
  @type measure :: {:count, pos_integer()} | {:duration, Tempo.Duration.t()}

  @typedoc """
  A budget over one period.

  `at_most` is a ceiling and constrains the search. `at_least` is a
  floor and is checked only by `Agenda.reconcile/3`. Either may be
  `nil`, but not both.
  """
  @type t :: %__MODULE__{
          period: :day | :week | :month,
          at_most: measure() | nil,
          at_least: measure() | nil
        }

  defstruct [:period, :at_most, :at_least]

  @doc """
  Read a resource's `:limits` keyword list into limits.

  ### Arguments

  * `limits` is a keyword list keyed by period — `:day`, `:week` or
    `:month`. Each value is a count, a duration, or a keyword list
    carrying `:at_most` and/or `:at_least`.

  ### Returns

  * `{:ok, limits}` in the order given; or

  * `{:error, reason}` naming the period that could not be read.

  ### Examples

      iex> {:ok, [limit]} = Agenda.Limit.parse(week: 5)
      iex> {limit.period, limit.at_most, limit.at_least}
      {:week, {:count, 5}, nil}

      iex> import Tempo.Sigils
      iex> {:ok, [limit]} = Agenda.Limit.parse(day: ~o"PT7H36M")
      iex> limit.at_most
      {:duration, ~o"PT7H36M"}

      iex> import Tempo.Sigils
      iex> {:ok, [limit]} = Agenda.Limit.parse(week: [at_least: ~o"PT38H", at_most: ~o"PT45H"])
      iex> {limit.at_least, limit.at_most}
      {{:duration, ~o"PT38H"}, {:duration, ~o"PT45H"}}

      iex> Agenda.Limit.parse(fortnight: 5)
      {:error, "unknown limit period :fortnight — expected :day, :week or :month"}

  """
  @spec parse(keyword()) :: {:ok, [t()]} | {:error, term()}
  def parse(limits) when is_list(limits) do
    Enum.reduce_while(limits, {:ok, []}, fn {period, spec}, {:ok, acc} ->
      case one(period, spec) do
        {:ok, limit} -> {:cont, {:ok, [limit | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Read a resource's `:limits`, raising on anything malformed.

  `Agenda.Resource.new/2` returns a resource rather than a tuple, so a
  limit it cannot read has nowhere to go but an exception. That is the
  right outcome: a limit silently dropped is a contract silently not
  enforced.

  ### Arguments

  * `limits` is as for `parse/1`.

  ### Returns

  * the limits; or raises `ArgumentError`.

  ### Examples

      iex> [limit] = Agenda.Limit.parse!(day: 1)
      iex> limit.at_most
      {:count, 1}

  """
  @spec parse!(keyword()) :: [t()]
  def parse!(limits) when is_list(limits) do
    case parse(limits) do
      {:ok, parsed} -> parsed
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  defp one(period, _spec) when period not in @periods do
    {:error, "unknown limit period #{inspect(period)} — expected :day, :week or :month"}
  end

  defp one(period, spec) when is_list(spec) do
    with {:ok, at_most} <- bound(period, :at_most, Keyword.get(spec, :at_most)),
         {:ok, at_least} <- bound(period, :at_least, Keyword.get(spec, :at_least)) do
      if is_nil(at_most) and is_nil(at_least) do
        {:error, "limit for #{inspect(period)} gives neither :at_most nor :at_least"}
      else
        {:ok, %__MODULE__{period: period, at_most: at_most, at_least: at_least}}
      end
    end
  end

  defp one(period, spec) do
    with {:ok, at_most} <- bound(period, :at_most, spec) do
      {:ok, %__MODULE__{period: period, at_most: at_most}}
    end
  end

  defp bound(_period, _which, nil), do: {:ok, nil}

  defp bound(_period, _which, value) when is_integer(value) and value > 0 do
    {:ok, {:count, value}}
  end

  defp bound(period, which, value) when is_binary(value) do
    case Tempo.from_iso8601(value) do
      {:ok, parsed} -> bound(period, which, parsed)
      {:error, _reason} -> unreadable(period, which, value)
    end
  end

  defp bound(period, which, %Duration{} = value) do
    case Duration.to_unit(value, :second) do
      {:ok, _seconds} -> {:ok, {:duration, value}}
      {:error, _reason} -> unreadable(period, which, value)
    end
  end

  defp bound(period, which, value), do: unreadable(period, which, value)

  defp unreadable(period, which, value) do
    {:error,
     "#{inspect(which)} for #{inspect(period)} is #{inspect(value)} — " <>
       "expected a positive count or a duration"}
  end

  @doc """
  What a set of allocations amounts to, as a count and a duration.

  Both measures are computed together because a limit may be expressed
  either way and the caller does not know which until it looks.

  ### Arguments

  * `allocations` is a list of `t:Agenda.Allocation.t/0`.

  ### Returns

  * `{count, duration}`, where `duration` is a `t:Tempo.Duration.t/0`
    summing every allocation's interval. An allocation whose interval
    has no measurable length contributes nothing to the duration and
    still contributes one to the count.

  ### Examples

      iex> import Tempo.Sigils
      iex> allocations = [
      ...>   %Agenda.Allocation{interval: ~o"2026-06-16T09:00:00/2026-06-16T12:00:00"},
      ...>   %Agenda.Allocation{interval: ~o"2026-06-16T13:00:00/2026-06-16T17:00:00"}
      ...> ]
      iex> {count, duration} = Agenda.Limit.amount(allocations)
      iex> {count, Tempo.Duration.to_unit(duration, :hour)}
      {2, {:ok, 7.0}}

  """
  @spec amount([Allocation.t()]) :: {non_neg_integer(), Tempo.Duration.t()}
  def amount(allocations) when is_list(allocations) do
    allocations |> Enum.map(& &1.interval) |> total()
  end

  @doc """
  What a set of intervals amounts to, as a count and a duration.

  The primitive under `amount/1`, for callers holding intervals rather
  than allocations — the arranger weighs a candidate placement before
  any allocation exists.

  ### Arguments

  * `intervals` is a list of `t:Tempo.Interval.t/0`.

  ### Returns

  * `{count, duration}`. An interval with no measurable length —
    unbounded, or a recurrence — contributes nothing to the duration
    and still contributes one to the count.

  ### Examples

      iex> import Tempo.Sigils
      iex> {count, duration} = Agenda.Limit.total([~o"2026-06-16T09:00:00/2026-06-16T12:00:00"])
      iex> {count, Tempo.Duration.to_unit(duration, :hour)}
      {1, {:ok, 3.0}}

  """
  @spec total([Tempo.Interval.t()]) :: {non_neg_integer(), Tempo.Duration.t()}
  def total(intervals) when is_list(intervals) do
    {length(intervals), intervals |> Enum.flat_map(&measurable/1) |> Duration.sum()}
  end

  defp measurable(%Interval{} = interval) do
    case Interval.duration(interval) do
      %Duration{} = duration -> [duration]
      _infinite_or_unreadable -> []
    end
  end

  defp measurable(_other), do: []

  @doc """
  Which day, week or month a moment falls in.

  A week is bucketed by the date its Monday falls on, so the boundary
  is the calendar's rather than an arbitrary seven-day window measured
  from the first claim.

  ### Arguments

  * `moment` is a `t:Tempo.t/0`.

  * `period` is `:day`, `:week` or `:month`.

  ### Returns

  * an opaque bucket key, equal for two moments in the same period; or

  * `:undated` when the moment does not carry a full date, or the
    period is not one this module knows. Everything undated shares one
    bucket, which keeps a limit conservative rather than unenforced.

  ### Examples

      iex> import Tempo.Sigils
      iex> Agenda.Limit.bucket(~o"2026-06-16T10:00:00", :day)
      {2026, 6, 16}

      iex> import Tempo.Sigils
      iex> Agenda.Limit.bucket(~o"2026-06-16T10:00:00", :month)
      {2026, 6}

      iex> import Tempo.Sigils
      iex> # Tuesday and Thursday of one week share its Monday.
      iex> Agenda.Limit.bucket(~o"2026-06-16T10:00:00", :week) ==
      ...>   Agenda.Limit.bucket(~o"2026-06-18T10:00:00", :week)
      true

  """
  @spec bucket(Tempo.t() | term(), atom()) :: tuple() | :undated
  def bucket(%Tempo{} = moment, period) do
    with year when is_integer(year) <- moment.time[:year],
         month when is_integer(month) <- moment.time[:month],
         day when is_integer(day) <- moment.time[:day] do
      calendar_bucket(year, month, day, period)
    else
      _no_date -> :undated
    end
  end

  def bucket(_other, _period), do: :undated

  defp calendar_bucket(year, month, day, :day), do: {year, month, day}
  defp calendar_bucket(year, month, _day, :month), do: {year, month}

  defp calendar_bucket(year, month, day, :week) do
    case Date.new(year, month, day) do
      {:ok, date} -> date |> Date.beginning_of_week() |> Date.to_erl()
      {:error, _reason} -> :undated
    end
  end

  defp calendar_bucket(_year, _month, _day, _unknown_period), do: :undated

  @doc """
  `true` when `count` claims totalling `duration` sit within the
  limit's ceiling.

  A limit with no ceiling always permits, which is what makes a
  floor-only limit invisible to the search.

  ### Arguments

  * `limit` is a `t:t/0`.

  * `count` is how many claims fall in the period.

  * `duration` is what they total, as a `t:Tempo.Duration.t/0`.

  ### Returns

  * `true` or `false`.

  ### Examples

      iex> import Tempo.Sigils
      iex> [limit] = Agenda.Limit.parse!(day: ~o"PT8H")
      iex> {Agenda.Limit.permits?(limit, 1, ~o"PT7H"), Agenda.Limit.permits?(limit, 1, ~o"PT9H")}
      {true, false}

      iex> import Tempo.Sigils
      iex> [limit] = Agenda.Limit.parse!(week: [at_least: ~o"PT38H"])
      iex> Agenda.Limit.permits?(limit, 99, ~o"PT99H")
      true

  """
  @spec permits?(t(), non_neg_integer(), Tempo.Duration.t()) :: boolean()
  def permits?(%__MODULE__{at_most: nil}, _count, _duration), do: true

  def permits?(%__MODULE__{at_most: {:count, most}}, count, _duration), do: count <= most

  def permits?(%__MODULE__{at_most: {:duration, most}}, _count, duration) do
    compare(duration, most) in [:lt, :eq]
  end

  @doc """
  How a period's claims breach a limit, or `nil` when they do not.

  Both ends are checked, so this is the function that sees a floor.

  ### Arguments

  * `limit` is a `t:t/0`.

  * `count` is how many claims fall in the period.

  * `duration` is what they total, as a `t:Tempo.Duration.t/0`.

  ### Returns

  * `nil` when the claims satisfy the limit; or

  * `{:over, measure}` naming the ceiling that was exceeded; or

  * `{:under, measure}` naming the floor that was not reached.

  ### Examples

      iex> import Tempo.Sigils
      iex> [limit] = Agenda.Limit.parse!(week: [at_least: ~o"PT38H"])
      iex> Agenda.Limit.breach(limit, 5, ~o"PT30H")
      {:under, {:duration, ~o"PT38H"}}

      iex> import Tempo.Sigils
      iex> [limit] = Agenda.Limit.parse!(week: [at_least: ~o"PT38H"])
      iex> Agenda.Limit.breach(limit, 5, ~o"PT38H")
      nil

  """
  @spec breach(t(), non_neg_integer(), Tempo.Duration.t()) ::
          {:over, measure()} | {:under, measure()} | nil
  def breach(%__MODULE__{} = limit, count, duration) do
    cond do
      not permits?(limit, count, duration) -> {:over, limit.at_most}
      short?(limit.at_least, count, duration) -> {:under, limit.at_least}
      true -> nil
    end
  end

  defp short?(nil, _count, _duration), do: false
  defp short?({:count, least}, count, _duration), do: count < least
  defp short?({:duration, least}, _count, duration), do: compare(duration, least) == :lt

  # Durations are compared in seconds rather than by their components,
  # because `PT90M` and `PT1H30M` are the same budget written two ways
  # and a component-wise comparison would call them different.
  defp compare(a, b) do
    with {:ok, left} <- Duration.to_unit(a, :second),
         {:ok, right} <- Duration.to_unit(b, :second) do
      cond do
        left < right -> :lt
        left > right -> :gt
        true -> :eq
      end
    else
      _unreadable -> :eq
    end
  end
end
