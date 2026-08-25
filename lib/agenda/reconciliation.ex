defmodule Agenda.Reconciliation do
  @moduledoc """
  Whether a resource's claims account for the time it owed.

  A schedule is the ledger read as *intent* — who should be where. A
  timesheet is the same ledger read as *record* — who was. This module
  compares the two readings over a period and reports the difference.

  ## Why a difference and not a sum

  The obvious check is to total the claims and compare against a
  number. That check passes on data that is wrong. A consultant who
  misses a Tuesday and works the following Saturday totals exactly the
  same as one who did neither, and a day billed against an office that
  was shut totals the same as a day billed against one that was open. A
  total that balances is not evidence the period is correct — it is
  evidence that two errors were the same size.

  So `unaccounted` and `overclaimed` are **interval sets, not
  quantities**. They say *"Tuesday afternoon"*, which is something a
  person can act on, where *"11.4 hours short"* is not.

  ## What counts as expected

  Expected time is the resource's open hours inside the window, less
  anything the caller says removes the obligation:

      Agenda.reconcile(ledger, dana, within: quarter, excluding: holidays)

  `agenda` does not know what a public holiday is, and does not resolve
  one. Holidays arrive as an ordinary `t:Tempo.IntervalSet.t/0` from
  wherever the caller keeps them — a jurisdiction library, a CalDAV
  feed through `Agenda.from_ical/1`, or a hand-written list.

  The order matters and is deliberate. Holidays leave the expectation
  *before* claims are compared against it, so **a holiday falling
  inside a period of leave cannot consume that leave**: the day was
  never owed, so no claim is needed to account for it. That is the
  perennial payroll bug, and here it is unrepresentable rather than
  guarded against.

  ## Leave is a claim, not a gap

  Work and leave are both claims on the resource, distinguished by
  `Agenda.Allocation`'s tag. Both account for expected time — a day of
  annual leave is not missing time — and `by_tag` reports how the
  period divided between them.

  """

  alias Agenda.Allocation
  alias Agenda.Availability
  alias Agenda.Ledger
  alias Agenda.Limit
  alias Agenda.Resource
  alias Tempo.Duration
  alias Tempo.Interval
  alias Tempo.IntervalSet

  @typedoc """
  A limit that a period's claims did not satisfy.

  `bucket` is the specific day, week or month at fault, as returned by
  `Agenda.Limit.bucket/2`.
  """
  @type breach :: %{
          period: atom(),
          bucket: tuple() | :undated,
          breach: {:over, Limit.measure()} | {:under, Limit.measure()}
        }

  @typedoc """
  What a resource owed over a window, and what it claimed.
  """
  @type t :: %__MODULE__{
          resource: String.t(),
          within: Tempo.Interval.t(),
          expected: IntervalSet.t(),
          claimed: IntervalSet.t(),
          unaccounted: IntervalSet.t(),
          overclaimed: IntervalSet.t(),
          by_tag: %{optional(Allocation.tag() | nil) => Tempo.Duration.t()},
          breaches: [breach()]
        }

  defstruct [
    :resource,
    :within,
    :expected,
    :claimed,
    :unaccounted,
    :overclaimed,
    by_tag: %{},
    breaches: []
  ]

  @doc """
  Compare what `resource` claimed in the ledger against what it owed.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `resource` is a `t:Agenda.Resource.t/0`.

  ### Options

  * `:within` is the window to reconcile — a Tempo value or an ISO 8601
    string. Required, because open hours may be an unbounded recurrence
    and have no materialisation without one.

  * `:excluding` is time the resource did not owe — public holidays, a
    shutdown — as an `t:Tempo.IntervalSet.t/0`, a Tempo value, or a
    string. Subtracted from the expectation before any claim is
    compared against it. The default is none.

  * `:expected` states the owed time outright, as an
    `t:Tempo.IntervalSet.t/0`, instead of deriving it from the
    resource's open hours. `:excluding` still applies to it.

  ### Returns

  * `{:ok, reconciliation}`; or

  * `{:error, reason}` when the window or a set cannot be read.

  ### Examples

      iex> import Tempo.Sigils
      iex> {:ok, dana} =
      ...>   Agenda.open(Agenda.resource("Dana"), ~o"2026-06-16T09:00:00/2026-06-16T17:00:00")
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Acme",
      ...>   interval: ~o"2026-06-16T09:00:00/2026-06-16T12:00:00",
      ...>   allocations: %{consultant: [dana]}
      ...> }
      iex> {:ok, ledger} = Agenda.allocate(Agenda.ledger(), arrangement, tag: {:project, "ACME"})
      iex> {:ok, report} = Agenda.reconcile(ledger, dana, within: ~o"2026-06-16/2026-06-17")
      iex> report.unaccounted |> Tempo.IntervalSet.to_list() |> Enum.map(&Tempo.to_iso8601/1)
      ["2026Y6M16DT12H0M0S/2026Y6M16DT17H0M0S"]

  > *"Three of the eight hours are accounted for; the afternoon is not."*

  """
  @spec reconcile(Ledger.t(), Resource.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def reconcile(%Ledger{} = ledger, %Resource{} = resource, options) do
    with {:ok, window} <- Availability.normalise(Keyword.fetch!(options, :within)),
         {:ok, owed} <- owed(resource, window, options),
         {:ok, excluding} <- set(Keyword.get(options, :excluding), window),
         {:ok, expected} <- Tempo.difference(owed, excluding),
         allocations = allocations(ledger, resource, window),
         {:ok, claimed} <- claimed(allocations, window),
         {:ok, unaccounted} <- Tempo.difference(expected, claimed),
         {:ok, overclaimed} <- Tempo.difference(claimed, expected) do
      {:ok,
       %__MODULE__{
         resource: resource.name,
         within: window,
         expected: expected,
         claimed: claimed,
         unaccounted: unaccounted,
         overclaimed: overclaimed,
         by_tag: by_tag(allocations),
         breaches: breaches(resource, allocations)
       }}
    end
  end

  defp owed(resource, window, options) do
    case Keyword.get(options, :expected) do
      nil -> Availability.free(resource, within: window)
      given -> set(given, window)
    end
  end

  # Everything reaching the set algebra is clipped to the window first,
  # so a holiday set spanning a decade costs nothing to pass in and a
  # claim straddling the boundary contributes only its part inside.
  defp set(nil, _window), do: {:ok, IntervalSet.new!([])}

  defp set(%IntervalSet{} = given, window), do: clip(given, window)

  defp set(given, window) do
    with {:ok, normalised} <- Availability.normalise(given) do
      normalised
      |> List.wrap()
      |> IntervalSet.new()
      |> then(&with({:ok, s} <- &1, do: clip(s, window)))
    end
  end

  defp clip(%IntervalSet{} = set, window) do
    with {:ok, bounds} <- IntervalSet.new([window]) do
      Tempo.intersection(set, bounds)
    end
  end

  defp allocations(ledger, resource, window) do
    ledger
    |> Ledger.to_list()
    |> Enum.filter(&(&1.resource == resource.name and overlaps?(&1.interval, window)))
  end

  defp overlaps?(%Interval{} = interval, window) do
    Tempo.overlaps?(interval, window) == true
  end

  defp overlaps?(_other, _window), do: false

  defp claimed(allocations, window) do
    with {:ok, set} <- allocations |> Enum.map(& &1.interval) |> IntervalSet.new() do
      clip(set, window)
    end
  end

  defp by_tag(allocations) do
    allocations
    |> Enum.group_by(& &1.tag)
    |> Map.new(fn {tag, held} ->
      {_count, duration} = Limit.amount(held)
      {tag, duration}
    end)
  end

  # A floor is checked here and nowhere else. The search cannot enforce
  # one — a partial layout is supposed to be under it — so the question
  # only becomes answerable once a period is finished, which is exactly
  # what this function is looking at.
  defp breaches(resource, allocations) do
    Enum.flat_map(resource.limits, &breached_buckets(&1, allocations))
  end

  defp breached_buckets(%Limit{} = limit, allocations) do
    allocations
    |> Enum.group_by(&Limit.bucket(&1.interval.from, limit.period))
    |> Enum.sort_by(fn {bucket, _held} -> bucket end)
    |> Enum.flat_map(&breached_bucket(limit, &1))
  end

  defp breached_bucket(%Limit{} = limit, {bucket, held}) do
    {count, duration} = Limit.amount(held)

    case Limit.breach(limit, count, duration) do
      nil -> []
      breach -> [%{period: limit.period, bucket: bucket, breach: breach}]
    end
  end

  @doc """
  `true` when nothing is unaccounted, nothing is overclaimed, and no
  limit was breached.

  ### Arguments

  * `reconciliation` is a `t:t/0`.

  ### Returns

  * `true` or `false`.

  ### Examples

      iex> import Tempo.Sigils
      iex> day = ~o"2026-06-16T09:00:00/2026-06-16T17:00:00"
      iex> {:ok, dana} = Agenda.open(Agenda.resource("Dana"), day)
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Acme",
      ...>   interval: day,
      ...>   allocations: %{consultant: [dana]}
      ...> }
      iex> {:ok, ledger} = Agenda.allocate(Agenda.ledger(), arrangement, tag: {:project, "ACME"})
      iex> {:ok, report} = Agenda.reconcile(ledger, dana, within: ~o"2026-06-16/2026-06-17")
      iex> Agenda.Reconciliation.balanced?(report)
      true

  """
  @spec balanced?(t()) :: boolean()
  def balanced?(%__MODULE__{} = reconciliation) do
    IntervalSet.empty?(reconciliation.unaccounted) and
      IntervalSet.empty?(reconciliation.overclaimed) and
      reconciliation.breaches == []
  end

  @doc """
  What did not add up, as sentences.

  Eligibility in this library is always explained rather than merely
  decided, and a reconciliation is the same: the point of the report is
  the sentence a person is sent, not the boolean.

  ### Arguments

  * `reconciliation` is a `t:t/0`.

  ### Returns

  * a list of sentences, empty when the period balances.

  ### Examples

      iex> import Tempo.Sigils
      iex> {:ok, dana} =
      ...>   Agenda.open(Agenda.resource("Dana"), ~o"2026-06-16T09:00:00/2026-06-16T17:00:00")
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Acme",
      ...>   interval: ~o"2026-06-16T09:00:00/2026-06-16T12:00:00",
      ...>   allocations: %{consultant: [dana]}
      ...> }
      iex> {:ok, ledger} = Agenda.allocate(Agenda.ledger(), arrangement, tag: {:project, "ACME"})
      iex> {:ok, report} = Agenda.reconcile(ledger, dana, within: ~o"2026-06-16/2026-06-17")
      iex> Agenda.Reconciliation.explain(report)
      ["Dana: 5 hours unaccounted — 2026Y6M16DT12H0M0S/2026Y6M16DT17H0M0S"]

  """
  @spec explain(t()) :: [String.t()]
  def explain(%__MODULE__{} = reconciliation) do
    gaps(reconciliation, reconciliation.unaccounted, "unaccounted") ++
      gaps(reconciliation, reconciliation.overclaimed, "claimed beyond the expected hours") ++
      Enum.map(reconciliation.breaches, &breach_sentence(reconciliation.resource, &1))
  end

  defp gaps(_reconciliation, set, _what) when set == nil, do: []

  defp gaps(reconciliation, set, what) do
    case IntervalSet.to_list(set) do
      [] ->
        []

      intervals ->
        {_count, duration} = Limit.total(intervals)
        spans = Enum.map_join(intervals, ", ", &Tempo.to_iso8601/1)
        ["#{reconciliation.resource}: #{hours(duration)} #{what} — #{spans}"]
    end
  end

  defp breach_sentence(resource, %{period: period, bucket: bucket, breach: breach}) do
    "#{resource}: #{describe(breach)} in the #{period} of #{label(bucket)}"
  end

  defp describe({:over, {:count, most}}), do: "more than #{most} claims"
  defp describe({:under, {:count, least}}), do: "fewer than #{least} claims"
  defp describe({:over, {:duration, most}}), do: "more than #{hours(most)}"
  defp describe({:under, {:duration, least}}), do: "less than #{hours(least)}"

  defp label({year, month, day}), do: "#{year}-#{pad(month)}-#{pad(day)}"
  defp label({year, month}), do: "#{year}-#{pad(month)}"
  defp label(other), do: inspect(other)

  defp pad(number), do: String.pad_leading("#{number}", 2, "0")

  defp hours(duration) do
    case Duration.to_unit(duration, :hour) do
      {:ok, hours} -> "#{trim(hours)} hours"
      {:error, _reason} -> "an unmeasurable span"
    end
  end

  defp trim(hours) do
    rounded = Float.round(hours, 2)

    if rounded == Float.round(rounded, 0) do
      "#{trunc(rounded)}"
    else
      "#{rounded}"
    end
  end
end
