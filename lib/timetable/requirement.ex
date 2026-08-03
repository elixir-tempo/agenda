defmodule Timetable.Requirement do
  @moduledoc """
  A requirement — what a session demands of the resources allocated to
  it.

  A requirement is named, so that an arrangement can say *which* role a
  resource was chosen for, and comes in two shapes:

  * **by attribute** — "a room seating at least eight with video
    conferencing"; any resource satisfying the predicates will do.

  * **by roster** — "Alice, Bob and Carol"; these named resources
    specifically.

  Both shapes are the same struct, so a session can hold a list of
  requirements without the caller sorting them into kinds.

  """

  alias Timetable.Predicate
  alias Timetable.Resource

  @typedoc "What a session demands, under a role name."
  @type t :: %__MODULE__{
          name: atom(),
          attributes: %{optional(atom()) => Predicate.t()},
          roster: [Resource.t()]
        }

  defstruct name: nil, attributes: %{}, roster: []

  @doc """
  Build a requirement from attribute predicates.

  Bare values are coerced to `Timetable.Predicate.exactly/1`, so
  `video_conferencing: true` and `seats: at_least(8)` may be mixed
  freely.

  ### Arguments

  * `name` is the role name, such as `:room`.

  * `predicates` is a keyword list of attribute predicates.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> import Timetable.Predicate
      iex> requirement = Timetable.Requirement.new(:room, seats: at_least(8))
      iex> requirement.attributes[:seats].op
      :at_least

  """
  @spec new(atom(), keyword()) :: t()
  def new(name, predicates \\ []) when is_atom(name) do
    attributes = Map.new(predicates, fn {key, value} -> {key, Predicate.coerce(value)} end)
    %__MODULE__{name: name, attributes: attributes}
  end

  @doc """
  Build a requirement naming specific resources.

  ### Arguments

  * `name` is the role name, such as `:attendees`.

  * `resources` is the list of required `t:Timetable.Resource.t/0`.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> alice = Timetable.Resource.new("Alice")
      iex> requirement = Timetable.Requirement.roster(:attendees, [alice])
      iex> Enum.map(requirement.roster, & &1.name)
      ["Alice"]

  """
  @spec roster(atom(), [Resource.t()]) :: t()
  def roster(name, resources) when is_atom(name) and is_list(resources) do
    %__MODULE__{name: name, roster: resources}
  end

  @doc """
  Fold the requirements induced by `resources` into `requirement`.

  This is what makes `requires:` on a person bind the room: allocating
  Alice, who requires step-free access, tightens the room requirement
  so that an inaccessible room stops being eligible.

  ### Arguments

  * `requirement` is the `t:t/0` to tighten.

  * `resources` is a list of `t:Timetable.Resource.t/0` whose
    `requires` should be folded in.

  ### Returns

  * a `t:t/0` carrying the additional predicates.

  ### Examples

      iex> alice = Timetable.Resource.new("Alice", requires: [step_free_access: true])
      iex> room = Timetable.Requirement.new(:room, seats: 8)
      iex> tightened = Timetable.Requirement.induce(room, [alice])
      iex> Map.keys(tightened.attributes) |> Enum.sort()
      [:seats, :step_free_access]

  """
  @spec induce(t(), [Resource.t()]) :: t()
  def induce(%__MODULE__{} = requirement, resources) when is_list(resources) do
    induced =
      resources
      |> Enum.flat_map(&Map.to_list(&1.requires))
      |> Map.new(fn {key, value} -> {key, Predicate.coerce(value)} end)

    %{requirement | attributes: Map.merge(requirement.attributes, induced)}
  end

  @doc """
  Every way `resource` fails `requirement`, as readable phrases.

  An empty list means the resource is eligible — so `eligible?/2` is
  `unmet/2` returning nothing, and the explanation is never computed
  separately from the decision.

  ### Arguments

  * `requirement` is a `t:t/0`.

  * `resource` is a `t:Timetable.Resource.t/0`.

  ### Returns

  * a list of phrases, one per unsatisfied attribute, empty when the
    resource qualifies.

  ### Examples

      iex> import Timetable.Predicate
      iex> small = Timetable.Resource.new("Meeting room 2", seats: 4)
      iex> requirement = Timetable.Requirement.new(:room, seats: at_least(8))
      iex> Timetable.Requirement.unmet(requirement, small)
      ["seats is 4 — needs at least 8"]

  """
  @spec unmet(t(), Resource.t()) :: [String.t()]
  def unmet(%__MODULE__{} = requirement, %Resource{} = resource) do
    requirement.attributes
    |> Enum.sort_by(fn {name, _predicate} -> name end)
    |> Enum.reject(fn {name, predicate} ->
      Predicate.satisfied?(predicate, Resource.attribute(resource, name))
    end)
    |> Enum.map(fn {name, predicate} -> phrase(name, predicate, resource) end)
  end

  defp phrase(name, predicate, resource) do
    case Resource.attribute(resource, name) do
      nil -> "no #{name} — needs #{Predicate.describe(predicate)}"
      value -> "#{name} is #{inspect(value)} — needs #{Predicate.describe(predicate)}"
    end
  end

  @doc """
  `true` when `resource` satisfies every attribute of `requirement`.

  ### Arguments

  * `requirement` is a `t:t/0`.

  * `resource` is a `t:Timetable.Resource.t/0`.

  ### Returns

  * `true` or `false`.

  ### Examples

      iex> import Timetable.Predicate
      iex> boardroom = Timetable.Resource.new("Boardroom", seats: 8)
      iex> requirement = Timetable.Requirement.new(:room, seats: at_least(8))
      iex> Timetable.Requirement.eligible?(requirement, boardroom)
      true

  """
  @spec eligible?(t(), Resource.t()) :: boolean()
  def eligible?(%__MODULE__{} = requirement, %Resource{} = resource) do
    unmet(requirement, resource) == []
  end

  @doc """
  The resources from `candidates` that satisfy `requirement`.

  ### Arguments

  * `requirement` is a `t:t/0`.

  * `candidates` is a list of `t:Timetable.Resource.t/0`.

  ### Returns

  * the eligible resources, in the order given.

  ### Examples

      iex> import Timetable.Predicate
      iex> big = Timetable.Resource.new("Boardroom", seats: 8)
      iex> small = Timetable.Resource.new("Meeting room 2", seats: 4)
      iex> requirement = Timetable.Requirement.new(:room, seats: at_least(8))
      iex> Timetable.Requirement.eligible(requirement, [big, small]) |> Enum.map(& &1.name)
      ["Boardroom"]

  """
  @spec eligible(t(), [Resource.t()]) :: [Resource.t()]
  def eligible(%__MODULE__{} = requirement, candidates) when is_list(candidates) do
    Enum.filter(candidates, &eligible?(requirement, &1))
  end
end
