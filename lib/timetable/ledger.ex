defmodule Timetable.Ledger do
  @moduledoc """
  What is currently allocated, and to whom.

  The ledger is an ordinary immutable value holding
  `t:Timetable.Allocation.t/0` records **keyed by session**. Two
  consequences follow from that key, and they are the whole point of
  the module:

  * **Releasing is dropping a key.** Cancelling a session frees every
    resource it held, because nothing else was holding them. There is
    no release step to forget and no free/busy record to go stale —
    free time is derived by `Timetable.Availability.free/2`, never
    stored.

  * **Moving a session is a changeset, not a rewrite.** `diff/3`
    reports only what genuinely changed. The naive alternative —
    release everything, re-acquire it — loses the room to a competing
    booking in the gap and churns rows that did not move.

  The ledger never writes anything. `diff/3` returns a plain value for
  a persistence layer to apply inside its own transaction.

  ### The loop

      iex> boardroom = Timetable.resource("Boardroom", seats: 8)
      iex> {:ok, boardroom} = Timetable.open(boardroom, "2026-06-15T09:00:00/2026-06-15T11:00:00")
      iex> session =
      ...>   Timetable.session("Review", lasting: "PT1H", between: "2026-06-15/2026-06-16")
      ...>   |> Timetable.Session.needs(:room, seats: 8)
      iex> ledger = Timetable.Ledger.new()
      iex> {:ok, [best | _]} = Timetable.plan(session, [boardroom], busy: Timetable.busy(ledger))
      iex> {:ok, ledger} = Timetable.Ledger.allocate(ledger, best)
      iex> Timetable.Ledger.count(ledger)
      1

  > *"Plan against what is already allocated, then allocate the best
  > option."*

  """

  alias Tempo.Compare
  alias Timetable.Allocation
  alias Timetable.Arrangement
  alias Timetable.Availability
  alias Timetable.Infeasible
  alias Timetable.Resource

  @typedoc "Allocations held against the sessions that hold them."
  @type t :: %__MODULE__{sessions: %{optional(String.t()) => [Allocation.t()]}}

  @typedoc """
  One line of a changeset: keep a binding untouched, give one back, or
  take a new one.
  """
  @type change :: {:keep | :release | :allocate, Allocation.t()}

  defstruct sessions: %{}

  @doc """
  An empty ledger.

  ### Returns

  * an empty `t:t/0`.

  ### Examples

      iex> Timetable.Ledger.count(Timetable.Ledger.new())
      0

  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Record an arrangement, replacing whatever that session held before.

  Allocating is idempotent: allocating the same arrangement twice
  leaves the ledger identical, because a session's allocations are
  replaced wholesale rather than appended.

  ### Arguments

  * `ledger` is a `t:t/0`.

  * `arrangement` is a `t:Timetable.Arrangement.t/0`.

  ### Returns

  * `{:ok, ledger}`.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.Ledger.allocate(Timetable.Ledger.new(), arrangement)
      iex> Timetable.Ledger.count(ledger)
      1

  """
  @spec allocate(t(), Arrangement.t()) :: {:ok, t()}
  def allocate(%__MODULE__{} = ledger, %Arrangement{} = arrangement) do
    allocations = Allocation.from_arrangement(arrangement)
    {:ok, %{ledger | sessions: Map.put(ledger.sessions, arrangement.session, allocations)}}
  end

  @doc """
  Claim resources *tentatively*, until `until`.

  A hold is what a booking page takes while someone finds their card.
  It occupies the resource exactly as an allocation does — that is the
  point, and it is why holds live in the ledger rather than in a
  persistence layer. Availability is derived on every call from what
  the ledger holds, so a hold the ledger cannot see is a hold nobody
  subtracts, and two people book the same room.

  Nothing expires on its own. `expire/2` is what advances time, and
  until it is called a hold is simply a claim. That keeps the ledger a
  value: arranging the same programme twice gives the same answer,
  because no function here reads a clock.

  ### Arguments

  * `ledger` is a `t:t/0`.

  * `arrangement` is a `t:Timetable.Arrangement.t/0`.

  ### Options

  * `:until` is when the hold lapses — a Tempo value or an ISO 8601
    string. Required.

  ### Returns

  * `{:ok, ledger}`; or

  * `{:error, reason}` when `:until` cannot be read as a moment.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.Ledger.hold(Timetable.Ledger.new(), arrangement,
      ...>                   until: "2026-06-15T10:15:00")
      iex> Timetable.Ledger.holds(ledger) |> Enum.map(& &1.session)
      ["Review"]

  """
  @spec hold(t(), Arrangement.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def hold(%__MODULE__{} = ledger, %Arrangement{} = arrangement, options) do
    with {:ok, until} <- Availability.normalise(Keyword.fetch!(options, :until)) do
      allocations =
        arrangement
        |> Allocation.from_arrangement()
        |> Enum.map(&%{&1 | held_until: until})

      {:ok, %{ledger | sessions: Map.put(ledger.sessions, arrangement.session, allocations)}}
    end
  end

  @doc """
  Turn a session's hold into a firm allocation.

  ### Arguments

  * `ledger` is a `t:t/0`.

  * `session` is the session's name.

  ### Returns

  * `{:ok, ledger}`. Confirming a session that holds nothing, or one
    already firm, is a no-op.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.Ledger.hold(Timetable.Ledger.new(), arrangement,
      ...>                   until: "2026-06-15T10:15:00")
      iex> {:ok, ledger} = Timetable.Ledger.confirm(ledger, "Review")
      iex> Timetable.Ledger.holds(ledger)
      []

  """
  @spec confirm(t(), String.t()) :: {:ok, t()}
  def confirm(%__MODULE__{} = ledger, session) when is_binary(session) do
    case Map.fetch(ledger.sessions, session) do
      {:ok, allocations} ->
        firm = Enum.map(allocations, &%{&1 | held_until: nil})
        {:ok, %{ledger | sessions: Map.put(ledger.sessions, session, firm)}}

      :error ->
        {:ok, ledger}
    end
  end

  @doc """
  Drop every hold that has lapsed by `now`.

  This is the only function here that has anything to do with the
  passing of time, and it takes the moment as an argument rather than
  reading a clock. That is deliberate. `busy/2` is called inside
  `Timetable.plan/3` and `Timetable.arrange/3`; if it consulted the
  system clock, arranging the same programme twice would give
  different answers as holds lapsed underneath it, and the ledger
  would stop being a value you can reason about. Refusing to guess the
  time is the same discipline as refusing to guess an unmeasured
  journey.

  A hold lapses when `now` has reached its expiry — a hold good
  *until* ten past is gone at ten past.

  ### Arguments

  * `ledger` is a `t:t/0`.

  * `now` is the current moment — a Tempo value or an ISO 8601 string.

  ### Returns

  * `{:ok, ledger}` with lapsed holds removed; or

  * `{:error, reason}` when `now` cannot be read as a moment.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.Ledger.hold(Timetable.Ledger.new(), arrangement,
      ...>                   until: "2026-06-15T10:15:00")
      iex> {:ok, still_held} = Timetable.Ledger.expire(ledger, "2026-06-15T10:10:00")
      iex> Timetable.Ledger.count(still_held)
      1
      iex> {:ok, lapsed} = Timetable.Ledger.expire(ledger, "2026-06-15T10:15:00")
      iex> Timetable.Ledger.count(lapsed)
      0

  """
  @spec expire(t(), Availability.pattern()) :: {:ok, t()} | {:error, term()}
  def expire(%__MODULE__{} = ledger, now) do
    with {:ok, moment} <- Availability.normalise(now) do
      kept =
        ledger.sessions
        |> Enum.reject(fn {_session, allocations} -> lapsed?(allocations, moment) end)
        |> Map.new()

      {:ok, %{ledger | sessions: kept}}
    end
  end

  # A session's allocations share one expiry, so the head decides.
  defp lapsed?([%Allocation{held_until: nil} | _rest], _now), do: false
  defp lapsed?([], _now), do: false

  defp lapsed?([%Allocation{held_until: until} | _rest], now) do
    Compare.compare_endpoints(until, now) in [:earlier, :same]
  end

  @doc """
  Every allocation that is still only a hold.

  ### Arguments

  * `ledger` is a `t:t/0`.

  ### Returns

  * the held allocations, ordered as `to_list/1` orders them.

  ### Examples

      iex> Timetable.Ledger.holds(Timetable.Ledger.new())
      []

  """
  @spec holds(t()) :: [Allocation.t()]
  def holds(%__MODULE__{} = ledger) do
    ledger |> to_list() |> Enum.filter(&(&1.held_until != nil))
  end

  @doc """
  Free everything a session was holding.

  ### Arguments

  * `ledger` is a `t:t/0`.

  * `session` is the session's name.

  ### Returns

  * `{:ok, ledger}`. Releasing a session that holds nothing is a no-op,
    so this is safe to call twice.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.Ledger.allocate(Timetable.Ledger.new(), arrangement)
      iex> {:ok, ledger} = Timetable.Ledger.release(ledger, "Review")
      iex> Timetable.Ledger.count(ledger)
      0

  """
  @spec release(t(), String.t()) :: {:ok, t()}
  def release(%__MODULE__{} = ledger, session) when is_binary(session) do
    {:ok, %{ledger | sessions: Map.delete(ledger.sessions, session)}}
  end

  @doc """
  Free everything held by a whole series.

  The occurrences of a repeating session are separate sessions sharing
  a series name, so cancelling the run is one call rather than a loop
  the caller has to get right.

  ### Arguments

  * `ledger` is a `t:t/0`.

  * `series` is the series name — the original session's name, before
    it was expanded.

  ### Options

  * `:from` releases only the occurrences starting at or after this
    point, a Tempo value or ISO 8601 string. Cancelling the rest of a
    term should not unpick the sessions already held.

  ### Returns

  * `{:ok, ledger}`; or

  * `{:error, reason}` when `:from` cannot be read.

  ### Examples

      iex> Timetable.Ledger.release_series(Timetable.Ledger.new(), "Stand-up")
      {:ok, Timetable.Ledger.new()}

  """
  @spec release_series(t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def release_series(%__MODULE__{} = ledger, series, options \\ []) do
    with {:ok, cutoff} <- cutoff(Keyword.get(options, :from)) do
      doomed =
        ledger.sessions
        |> Enum.filter(fn {_name, allocations} -> in_series?(allocations, series, cutoff) end)
        |> Enum.map(fn {name, _allocations} -> name end)

      {:ok, %{ledger | sessions: Map.drop(ledger.sessions, doomed)}}
    end
  end

  defp cutoff(nil), do: {:ok, nil}
  defp cutoff(from), do: Availability.normalise(from)

  defp in_series?(allocations, series, cutoff) do
    Enum.any?(allocations, fn allocation ->
      allocation.series == series and at_or_after?(allocation, cutoff)
    end)
  end

  defp at_or_after?(_allocation, nil), do: true

  defp at_or_after?(allocation, cutoff) do
    Compare.compare_endpoints(allocation.interval.from, start_of(cutoff)) != :earlier
  end

  defp start_of(%Tempo.Interval{from: from}), do: from
  defp start_of(point), do: point

  @doc """
  What `session` currently holds.

  ### Arguments

  * `ledger` is a `t:t/0`.

  * `session` is the session's name.

  ### Returns

  * the session's allocations, or `[]` when it holds nothing.

  ### Examples

      iex> Timetable.Ledger.for_session(Timetable.Ledger.new(), "Review")
      []

  """
  @spec for_session(t(), String.t()) :: [Allocation.t()]
  def for_session(%__MODULE__{sessions: sessions}, session) do
    Map.get(sessions, session, [])
  end

  @doc """
  Every allocation in the ledger, whoever holds it.

  ### Arguments

  * `ledger` is a `t:t/0`.

  ### Returns

  * the allocations, ordered by session then role then resource so the
    listing is stable.

  ### Examples

      iex> Timetable.Ledger.to_list(Timetable.Ledger.new())
      []

  """
  @spec to_list(t()) :: [Allocation.t()]
  def to_list(%__MODULE__{sessions: sessions}) do
    sessions
    |> Enum.sort_by(fn {session, _allocations} -> session end)
    |> Enum.flat_map(fn {_session, allocations} -> allocations end)
  end

  @doc """
  Rebuild what is allocated as arrangements, ready to pin.

  This is the inverse of `allocate/2`, and it exists so that
  re-arranging a programme can hold its published sessions still:
  `Timetable.arrange/3` takes `t:Timetable.Arrangement.t/0` values as
  `:pinned`, and these are the ones already booked.

  An allocation records a resource by *name*, so the pool it came from
  is needed to restore it. A name the pool does not have is an error
  rather than a stand-in resource: a substitute would default to
  concurrency 1 and no place, and would then quietly answer capacity
  and travel questions wrongly.

  ### Arguments

  * `ledger` is a `t:t/0`.

  * `pool` is the list of `t:Timetable.Resource.t/0` the allocations
    were made from.

  ### Options

  * `:only` is a session name, or a list of them, to rebuild. The
    default is every session in the ledger.

  ### Returns

  * `{:ok, arrangements}` — one per session, ordered by session name;
    or

  * `{:error, t:Timetable.Infeasible.t/0}` naming the resources the
    pool does not have.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.Ledger.allocate(Timetable.Ledger.new(), arrangement)
      iex> {:ok, [rebuilt]} = Timetable.Ledger.arrangements(ledger, [boardroom])
      iex> {rebuilt.session, Map.keys(rebuilt.allocations)}
      {"Review", [:room]}

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.Ledger.allocate(Timetable.Ledger.new(), arrangement)
      iex> {:error, reason} = Timetable.Ledger.arrangements(ledger, [])
      iex> Timetable.Infeasible.message(reason)
      "Review cannot be held: Boardroom is allocated but is not in the pool"

  """
  @spec arrangements(t(), [Resource.t()], keyword()) ::
          {:ok, [Arrangement.t()]} | {:error, Infeasible.t()}
  def arrangements(%__MODULE__{} = ledger, pool, options \\ []) when is_list(pool) do
    known = Map.new(pool, &{&1.name, &1})

    ledger
    |> to_list()
    |> only(Keyword.get(options, :only))
    |> Enum.group_by(& &1.session)
    |> Enum.sort_by(fn {session, _allocations} -> session end)
    |> Enum.reduce_while({:ok, []}, fn {session, allocations}, {:ok, acc} ->
      case rebuild(session, allocations, known) do
        {:ok, arrangement} -> {:cont, {:ok, acc ++ [arrangement]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp only(allocations, nil), do: allocations

  defp only(allocations, sessions) do
    wanted = sessions |> List.wrap() |> MapSet.new()

    Enum.filter(allocations, &MapSet.member?(wanted, &1.session))
  end

  defp rebuild(session, allocations, known) do
    case Enum.reject(allocations, &Map.has_key?(known, &1.resource)) do
      [] ->
        {:ok,
         %Arrangement{
           session: session,
           interval: hd(allocations).interval,
           allocations:
             allocations
             |> Enum.group_by(& &1.role)
             |> Map.new(fn {role, held} ->
               {role, Enum.map(held, &Map.fetch!(known, &1.resource))}
             end),
           series: hd(allocations).series
         }}

      strangers ->
        {:error,
         Infeasible.new(
           session,
           Enum.map(strangers, &"#{&1.resource} is allocated but is not in the pool")
         )}
    end
  end

  @doc """
  How many allocations the ledger holds.

  ### Arguments

  * `ledger` is a `t:t/0`.

  ### Returns

  * the count.

  ### Examples

      iex> Timetable.Ledger.count(Timetable.Ledger.new())
      0

  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{} = ledger), do: ledger |> to_list() |> length()

  @doc """
  What each resource is already claimed for, shaped for
  `Timetable.Planner.plan/3`'s `:busy` option.

  This is what closes the loop: plan against the ledger, allocate the
  result, and the next plan sees it.

  ### Arguments

  * `ledger` is a `t:t/0`.

  ### Options

  * `:except` is a session name, or a list of them, whose allocations
    are ignored — use it when re-planning a session so it does not
    collide with the copy of itself it is about to replace, or when
    pinning sessions in `Timetable.arrange/3`, which claims what its
    pins hold and so must not be told about them twice.

  ### Returns

  * a map of resource name to the intervals claiming it.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.Ledger.allocate(Timetable.Ledger.new(), arrangement)
      iex> Timetable.Ledger.busy(ledger) |> Map.keys()
      ["Boardroom"]

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.Ledger.allocate(Timetable.Ledger.new(), arrangement)
      iex> Timetable.Ledger.busy(ledger, except: "Review")
      %{}

  """
  @spec busy(t(), keyword()) :: %{optional(String.t()) => [Tempo.Interval.t()]}
  def busy(%__MODULE__{} = ledger, options \\ []) do
    except = options |> Keyword.get(:except, []) |> List.wrap() |> MapSet.new()

    ledger
    |> to_list()
    |> Enum.reject(&MapSet.member?(except, &1.session))
    |> Enum.group_by(& &1.resource, & &1.interval)
  end

  @doc """
  What would change if `session` moved to `arrangement`.

  Only genuine movement is reported. A binding the new arrangement
  still wants is `:keep`, never a `:release` followed by an
  `:allocate` — that pair would hand the resource to a competing
  booking in the gap between them, and churn rows that never moved.

  ### Arguments

  * `ledger` is a `t:t/0`.

  * `session` is the session's name.

  * `arrangement` is the `t:Timetable.Arrangement.t/0` it should move
    to.

  ### Returns

  * a list of `t:change/0`, ordered `:keep`, then `:release`, then
    `:allocate`.

  ### Examples

  Re-planning a session to exactly where it already is changes
  nothing:

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.Ledger.allocate(Timetable.Ledger.new(), arrangement)
      iex> Timetable.Ledger.diff(ledger, "Review", arrangement) |> Enum.map(&elem(&1, 0))
      [:keep]

  """
  @spec diff(t(), String.t(), Arrangement.t()) :: [change()]
  def diff(%__MODULE__{} = ledger, session, %Arrangement{} = arrangement) do
    held = for_session(ledger, session)
    wanted = Allocation.from_arrangement(arrangement)

    keep = Enum.filter(held, fn one -> Enum.any?(wanted, &Allocation.same?(one, &1)) end)
    release = Enum.reject(held, fn one -> Enum.any?(wanted, &Allocation.same?(one, &1)) end)
    fresh = Enum.reject(wanted, fn one -> Enum.any?(held, &Allocation.same?(one, &1)) end)

    tag(keep, :keep) ++ tag(release, :release) ++ tag(fresh, :allocate)
  end

  defp tag(allocations, label), do: Enum.map(allocations, &{label, &1})
end
