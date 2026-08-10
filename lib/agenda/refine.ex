defmodule Agenda.Refine do
  @moduledoc """
  Narrowing free time — the verbs that turn *"when is this open?"* into
  *"when is this actually bookable?"*

  Each function takes free time and gives back less of it, and each is
  a single Tempo set operation wearing a domain name. That is the whole
  design: Tempo already knows how to intersect, union, and filter
  intervals correctly across calendars, zones, and daylight saving, so
  a scheduling vocabulary is naming those operations rather than
  reimplementing them.

  ### They compose in a pipeline

  Every function accepts either an interval set or the `{:ok, set}` a
  previous step returned, and an `{:error, reason}` passes straight
  through untouched. So a refinement reads as one sentence and still
  short-circuits on failure:

      iex> {:ok, boardroom} =
      ...>   Agenda.resource("Boardroom")
      ...>   |> Agenda.open("2027-03-02T09:00:00/2027-03-02T17:00:00")
      iex> {:ok, bookable} =
      ...>   boardroom
      ...>   |> Agenda.free(within: "2027-03-02/2027-03-03", busy: "2027-03-02T12:00:00/2027-03-02T13:00:00")
      ...>   |> Agenda.only_during("2027-03-02T10:00:00/2027-03-02T16:00:00")
      ...>   |> Agenda.lasting_at_least("PT2H")
      iex> bookable |> Tempo.IntervalSet.to_list() |> Enum.map(&Tempo.to_iso8601/1)
      ["2027Y3M2DT10H0M0S/2027Y3M2DT12H0M0S", "2027Y3M2DT13H0M0S/2027Y3M2DT16H0M0S"]

  > *"The boardroom's free time, only between ten and four, in windows
  > lasting at least two hours."*

  The lunch hour splits the day in two and the ten-to-four bound trims
  both ends; what survives is a two-hour morning and a three-hour
  afternoon.

  """

  alias Agenda.Availability
  alias Tempo.IntervalSet

  @typedoc "Free time, or the result of the step that produced it."
  @type refinable :: IntervalSet.t() | {:ok, IntervalSet.t()} | {:error, term()}

  @doc """
  Keep only the free time that falls inside `constraint`.

  This is how a resource is made subject to something else's hours — a
  consulting room bookable only during clinic hours, a court only while
  the building is open. The constraint is ordinary free time itself, so
  constraints compose by applying them in turn.

  ### Arguments

  * `free` is an interval set, or the `{:ok, set}` from a previous
    step.

  * `constraint` is a Tempo value or ISO 8601 string bounding it.

  ### Returns

  * `{:ok, interval_set}`; or

  * `{:error, reason}`, including any error passed in.

  ### Examples

      iex> {:ok, room} =
      ...>   Agenda.resource("Room")
      ...>   |> Agenda.open("2027-03-02T09:00:00/2027-03-02T17:00:00")
      iex> {:ok, clinic}  =
      ...>   room
      ...>   |> Agenda.free(within: "2027-03-02/2027-03-03")
      ...>   |> Agenda.only_during("2027-03-02T13:00:00/2027-03-02T16:00:00")
      iex> clinic |> Tempo.IntervalSet.to_list() |> Enum.map(&Tempo.to_iso8601/1)
      ["2027Y3M2DT13H0M0S/2027Y3M2DT16H0M0S"]

  """
  @spec only_during(refinable(), Availability.pattern()) ::
          {:ok, IntervalSet.t()} | {:error, term()}
  def only_during(free, constraint) do
    with {:ok, set} <- unwrap(free),
         {:ok, bound} <- Availability.normalise(constraint) do
      Tempo.intersection(set, bound)
    end
  end

  @doc """
  Keep only the free time falling inside *any* of `constraints`.

  Where `only_during/2` is a single condition every window must meet,
  this is the grouped alternative — bookable while **any** of these
  venues is open, or while **any** of a roster is on duty. An empty
  list constrains nothing, matching the identity of Tempo's own n-ary
  set operations.

  ### Arguments

  * `free` is an interval set, or the `{:ok, set}` from a previous
    step.

  * `constraints` is a list of Tempo values or ISO 8601 strings.

  ### Returns

  * `{:ok, interval_set}`; or

  * `{:error, reason}`.

  ### Examples

      iex> {:ok, room} =
      ...>   Agenda.resource("Room")
      ...>   |> Agenda.open("2027-03-02T09:00:00/2027-03-02T17:00:00")
      iex> {:ok, staffed} =
      ...>   room
      ...>   |> Agenda.free(within: "2027-03-02/2027-03-03")
      ...>   |> Agenda.during_any([
      ...>        "2027-03-02T09:00:00/2027-03-02T10:00:00",
      ...>        "2027-03-02T15:00:00/2027-03-02T17:00:00"
      ...>      ])
      iex> staffed |> Tempo.IntervalSet.to_list() |> Enum.map(&Tempo.to_iso8601/1)
      ["2027Y3M2DT9H0M0S/2027Y3M2DT10H0M0S", "2027Y3M2DT15H0M0S/2027Y3M2DT17H0M0S"]

  """
  @spec during_any(refinable(), [Availability.pattern()]) ::
          {:ok, IntervalSet.t()} | {:error, term()}
  def during_any(free, []), do: unwrap(free)

  def during_any(free, [first | rest]) do
    with {:ok, set} <- unwrap(free),
         {:ok, head} <- Availability.normalise(first),
         {:ok, tail} <- normalise_all(rest),
         {:ok, either} <- Tempo.union(head, tail) do
      Tempo.intersection(set, either)
    end
  end

  @doc """
  Keep only the windows long enough to be worth offering.

  A three-minute gap between two meetings is free time nobody can use.

  ### Arguments

  * `free` is an interval set, or the `{:ok, set}` from a previous
    step.

  * `duration` is the shortest useful window, a `t:Tempo.Duration.t/0`
    or ISO 8601 string.

  ### Returns

  * `{:ok, interval_set}`; or

  * `{:error, reason}`.

  ### Examples

      iex> {:ok, room} =
      ...>   Agenda.resource("Room")
      ...>   |> Agenda.open("2027-03-02T09:00:00/2027-03-02T12:00:00")
      iex> {:ok, usable} =
      ...>   room
      ...>   |> Agenda.free(within: "2027-03-02/2027-03-03",
      ...>        busy: ["2027-03-02T09:20:00/2027-03-02T09:30:00",
      ...>               "2027-03-02T10:00:00/2027-03-02T10:30:00"])
      ...>   |> Agenda.lasting_at_least("PT1H")
      iex> usable |> Tempo.IntervalSet.to_list() |> Enum.map(&Tempo.to_iso8601/1)
      ["2027Y3M2DT10H30M0S/2027Y3M2DT12H0M0S"]

  """
  @spec lasting_at_least(refinable(), Availability.pattern()) ::
          {:ok, IntervalSet.t()} | {:error, term()}
  def lasting_at_least(free, duration) do
    with {:ok, set} <- unwrap(free),
         {:ok, least} <- Availability.normalise(duration) do
      {:ok, IntervalSet.filter(set, &Tempo.at_least?(&1, least))}
    end
  end

  # Accepting both a bare set and a previous step's result is what lets
  # these read as one sentence; an error simply falls through.
  defp unwrap(%IntervalSet{} = set), do: {:ok, set}
  defp unwrap({:ok, %IntervalSet{} = set}), do: {:ok, set}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp normalise_all(patterns) do
    Enum.reduce_while(patterns, {:ok, []}, fn pattern, {:ok, acc} ->
      case Availability.normalise(pattern) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
