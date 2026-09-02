defmodule Agenda.Arrangement do
  @moduledoc """
  One way a session could be held — a time, and a resource for every
  role.

  Planning returns arrangements ranked best-first rather than a single
  answer, because "best" depends on preferences the caller may want to
  overrule. An arrangement is inert: nothing is committed until it is
  allocated.

  """

  alias Agenda.Resource

  @typedoc "A candidate placement of a session."
  @type t :: %__MODULE__{
          session: String.t(),
          interval: Tempo.Interval.t(),
          allocations: %{optional(atom()) => [Resource.t()]},
          attending: %{optional(atom()) => [Resource.t()]},
          score: number(),
          series: String.t() | nil
        }

  defstruct session: nil,
            interval: nil,
            allocations: %{},
            attending: %{},
            score: 0,
            series: nil

  @doc """
  Every resource allocated, across all roles.

  ### Arguments

  * `arrangement` is a `t:t/0`.

  ### Returns

  * the allocated resources, role order preserved.

  ### Examples

      iex> boardroom = Agenda.Resource.new("Boardroom")
      iex> arrangement = %Agenda.Arrangement{allocations: %{room: [boardroom]}}
      iex> Enum.map(Agenda.Arrangement.resources(arrangement), & &1.name)
      ["Boardroom"]

  """
  @spec resources(t()) :: [Resource.t()]
  def resources(%__MODULE__{allocations: allocations}) do
    allocations
    |> Enum.sort_by(fn {role, _resources} -> role end)
    |> Enum.flat_map(fn {_role, resources} -> resources end)
  end

  @doc """
  A one-line description of the arrangement.

  ### Arguments

  * `arrangement` is a `t:t/0`.

  ### Returns

  * a sentence naming the time and the resources.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Agenda.Resource.new("Boardroom")
      iex> arrangement = %Agenda.Arrangement{
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> Agenda.Arrangement.explain(arrangement)
      "2026Y6M16DT10H0M0S/T11H0M0S — room: Boardroom"

  """
  @spec explain(t()) :: String.t()
  def explain(%__MODULE__{} = arrangement) do
    roles =
      arrangement.allocations
      |> Enum.sort_by(fn {role, _resources} -> role end)
      |> Enum.map_join(", ", fn {role, resources} ->
        "#{role}: #{Enum.map_join(resources, ", ", & &1.name)}"
      end)

    "#{Tempo.to_iso8601(arrangement.interval)} — #{roles}"
  end

  @doc """
  The resources filling one role.

  `resources/1` answers *"who and what is booked"*; this answers *"what
  is in the room slot"*. Without it a caller reaches into
  `arrangement.allocations` — or worse, hunts through every resource
  for one carrying a `:seats` attribute, which guesses at something a
  role already states.

  ### Arguments

  * `arrangement` is a `t:t/0`.

  * `role` is the role to read, as given to `Agenda.needs/2` or
    `Agenda.Session.roster/3`.

  ### Returns

  * the resources filling `role`, or `[]` when the arrangement has
    none. An absent role is not an error: a session that never asked
    for a projector simply has no projector.

  ### Examples

      iex> boardroom = Agenda.Resource.new("Boardroom")
      iex> alice = Agenda.Resource.new("Alice")
      iex> arrangement = %Agenda.Arrangement{allocations: %{room: [boardroom], speaker: [alice]}}
      iex> Enum.map(Agenda.Arrangement.resources(arrangement, :room), & &1.name)
      ["Boardroom"]

      iex> arrangement = %Agenda.Arrangement{allocations: %{room: []}}
      iex> Agenda.Arrangement.resources(arrangement, :projector)
      []

  """
  @spec resources(t(), atom()) :: [Resource.t()]
  def resources(%__MODULE__{allocations: allocations}, role) when is_atom(role) do
    Map.get(allocations, role, [])
  end

  @doc """
  The single resource filling one role, or `nil`.

  The common case, because most roles take exactly one: a session has
  one room even when it has four speakers. Where a role holds several,
  this is the first and `resources/2` is the question to ask.

  ### Arguments

  * `arrangement` is a `t:t/0`.

  * `role` is the role to read.

  ### Returns

  * the resource filling `role`, or `nil` when nothing does.

  ### Examples

      iex> boardroom = Agenda.Resource.new("Boardroom")
      iex> arrangement = %Agenda.Arrangement{allocations: %{room: [boardroom]}}
      iex> Agenda.Arrangement.resource(arrangement, :room).name
      "Boardroom"

      iex> arrangement = %Agenda.Arrangement{allocations: %{room: []}}
      iex> Agenda.Arrangement.resource(arrangement, :room)
      nil

  """
  @spec resource(t(), atom()) :: Resource.t() | nil
  def resource(%__MODULE__{} = arrangement, role) when is_atom(role) do
    arrangement |> resources(role) |> List.first()
  end

  @doc """
  Compare two arrangements chronologically.

  Present so that `Enum.sort/2` and `Enum.sort_by/3` accept this module
  the way they accept `Date`, `Time` and `Tempo`:

      Enum.sort(arrangements, Agenda.Arrangement)

  Sorting a programme by time is the commonest thing anyone does with a
  layout, and without this the call site has to reach inside — first for
  the interval, then often for its start — which is three levels of
  structure to say *"in the order they happen"*.

  Ordering is `Tempo.compare/2` on the intervals, so it is by start and
  then by end: two sessions beginning together put the shorter first.
  That is a total order, deliberately, where `Tempo.relation/2` gives
  the thirteen interval relations. Sorting needs the former; reasoning
  about overlap needs the latter.

  ### Arguments

  * `a` and `b` are each a `t:t/0`.

  ### Returns

  * `:lt`, `:eq` or `:gt`.

  ### Examples

      iex> import Tempo.Sigils
      iex> morning = %Agenda.Arrangement{interval: ~o"2026-06-16T09:00:00/2026-06-16T10:00:00"}
      iex> midday = %Agenda.Arrangement{interval: ~o"2026-06-16T12:00:00/2026-06-16T13:00:00"}
      iex> Agenda.Arrangement.compare(morning, midday)
      :lt

      iex> import Tempo.Sigils
      iex> morning = %Agenda.Arrangement{interval: ~o"2026-06-16T09:00:00/2026-06-16T10:00:00"}
      iex> midday = %Agenda.Arrangement{interval: ~o"2026-06-16T12:00:00/2026-06-16T13:00:00"}
      iex> [midday, morning] |> Enum.sort(Agenda.Arrangement) |> Enum.map(& &1.interval)
      [~o"2026Y6M16DT9H0M0S/T10H0M0S",
       ~o"2026Y6M16DT12H0M0S/T13H0M0S"]

  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = a, %__MODULE__{} = b) do
    Tempo.compare(a.interval, b.interval)
  end
end
