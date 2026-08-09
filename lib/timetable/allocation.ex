defmodule Timetable.Allocation do
  @moduledoc """
  One resource, bound to one session, over one interval.

  An allocation is **keyed by the session that holds it**. That single
  decision is what makes releasing a resource a consequence rather than
  a workflow: cancelling a session drops its key, and every resource it
  held is free again because nothing else was holding them. There is no
  release step to forget.

  An allocation is the persisted grain of a
  `t:Timetable.Arrangement.t/0` — the arrangement proposes a room and a
  roster for a time, and allocating it records one of these per
  resource.

  """

  alias Timetable.Arrangement

  @typedoc """
  One resource held by one session for one interval.

  `held_until` marks a **tentative** claim — a hold, not a booking. It
  occupies the resource exactly as a firm allocation does, which is why
  it lives here rather than in a persistence layer: availability is
  derived on every call, so a hold nobody can see is a hold nobody
  subtracts. `nil` means the claim is firm.
  """
  @type t :: %__MODULE__{
          session: String.t(),
          role: atom(),
          resource: String.t(),
          interval: Tempo.Interval.t(),
          series: String.t() | nil,
          held_until: Tempo.t() | nil
        }

  defstruct [:session, :role, :resource, :interval, :series, :held_until]

  @doc """
  The allocations an arrangement implies — one per resource, across
  every role.

  ### Arguments

  * `arrangement` is a `t:Timetable.Arrangement.t/0`.

  ### Returns

  * the allocations, ordered by role then resource name so that two
    equal arrangements always yield an equal list.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> [allocation] = Timetable.Allocation.from_arrangement(arrangement)
      iex> {allocation.session, allocation.role, allocation.resource}
      {"Review", :room, "Boardroom"}

  """
  @spec from_arrangement(Arrangement.t()) :: [t()]
  def from_arrangement(%Arrangement{} = arrangement) do
    arrangement.allocations
    |> Enum.flat_map(fn {role, resources} ->
      Enum.map(resources, fn resource ->
        %__MODULE__{
          session: arrangement.session,
          role: role,
          resource: resource.name,
          interval: arrangement.interval,
          series: arrangement.series
        }
      end)
    end)
    |> Enum.sort_by(&{&1.role, &1.resource})
  end

  @doc """
  `true` when two allocations bind the same resource, in the same
  role, over the same span.

  This is the identity a changeset compares on — it deliberately
  ignores which session holds it, because `rearrange/3` asks "is this
  same binding still wanted?" within one session.

  ### Arguments

  * `a` and `b` are each a `t:t/0`.

  ### Returns

  * `true` or `false`.

  ### Examples

      iex> import Tempo.Sigils
      iex> hour = ~o"2026-06-16T10:00:00/2026-06-16T11:00:00"
      iex> a = %Timetable.Allocation{role: :room, resource: "Boardroom", interval: hour}
      iex> b = %Timetable.Allocation{role: :room, resource: "Boardroom", interval: hour}
      iex> Timetable.Allocation.same?(a, b)
      true

  """
  @spec same?(t(), t()) :: boolean()
  def same?(%__MODULE__{} = a, %__MODULE__{} = b) do
    a.role == b.role and a.resource == b.resource and
      Tempo.equal?(a.interval, b.interval)
  end
end
