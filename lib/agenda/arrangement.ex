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
          score: number(),
          series: String.t() | nil
        }

  defstruct session: nil, interval: nil, allocations: %{}, score: 0, series: nil

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
      "2026Y6M16DT10H0M0S/2026Y6M16DT11H0M0S — room: Boardroom"

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
end
