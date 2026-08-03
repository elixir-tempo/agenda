defmodule Timetable.Resource do
  @moduledoc """
  A resource — a named thing that can be allocated to a session.

  People and rooms are the same kind of thing here; only their
  attributes differ. A room has `seats` and `video_conferencing`, a
  person has skills and access needs, and both sit somewhere in the
  `Timetable.Place` tree.

  Two fields carry more weight than they appear to:

  * **`requires`** — attributes this resource demands of whatever it is
    allocated alongside. `step_free_access: true` on a person is not a
    fact about their availability; it is a constraint they impose on
    the room. Modelling it here means accessibility cannot be forgotten
    at the call site.

  * **`concurrency`** — how many sessions may hold this resource at
    once. This is *not* `seats`. A 200-seat lecture hall is
    `seats: 200, concurrency: 1`; a bank of twenty identical lockers is
    `seats: 1, concurrency: 20`. Conflating the two is what lets a hall
    accept two simultaneous lectures.

  """

  alias Timetable.Place

  @typedoc "A named, allocatable thing."
  @type t :: %__MODULE__{
          name: String.t(),
          attributes: %{optional(atom()) => term()},
          within: Place.t() | nil,
          requires: %{optional(atom()) => term()},
          concurrency: pos_integer(),
          open: Tempo.Interval.t() | Tempo.IntervalSet.t() | nil,
          buffer_before: Tempo.Duration.t() | nil,
          buffer_after: Tempo.Duration.t() | nil
        }

  defstruct name: nil,
            attributes: %{},
            within: nil,
            requires: %{},
            concurrency: 1,
            open: nil,
            buffer_before: nil,
            buffer_after: nil

  @reserved [:within, :requires, :concurrency, :open, :buffer_before, :buffer_after]

  @doc """
  Build a resource.

  Any option that is not reserved becomes an attribute, so attributes
  read as themselves at the call site rather than being nested inside
  an `attributes:` keyword.

  ### Arguments

  * `name` is the resource's name.

  ### Options

  * `:within` is the enclosing `t:Timetable.Place.t/0`. The
    default is `nil`.

  * `:requires` is a keyword list of attributes this resource demands
    of resources allocated alongside it. The default is `[]`.

  * `:concurrency` is how many sessions may hold this resource
    simultaneously. The default is `1`.

  * `:open` is when the resource is available at all — see
    `Timetable.open/2`, which validates it. The default is `nil`,
    meaning the resource is never open.

  * `:buffer_before` is turnaround needed before each claim — set-up,
    travel in, a room being unlocked. A `t:Tempo.Duration.t/0`; the
    default is none.

  * `:buffer_after` is turnaround needed after each claim — cleaning,
    resetting the room, a machine cooling down. A
    `t:Tempo.Duration.t/0`; the default is none.

  * every other option is taken as an attribute.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> boardroom = Timetable.Resource.new("Boardroom", seats: 8, video_conferencing: true)
      iex> boardroom.attributes
      %{seats: 8, video_conferencing: true}

      iex> alice = Timetable.Resource.new("Alice", requires: [step_free_access: true])
      iex> alice.requires
      %{step_free_access: true}

  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, options \\ []) when is_binary(name) do
    {reserved, attributes} = Keyword.split(options, @reserved)

    %__MODULE__{
      name: name,
      attributes: Map.new(attributes),
      within: Keyword.get(reserved, :within),
      requires: reserved |> Keyword.get(:requires, []) |> Map.new(),
      concurrency: Keyword.get(reserved, :concurrency, 1),
      open: Keyword.get(reserved, :open),
      buffer_before: Keyword.get(reserved, :buffer_before),
      buffer_after: Keyword.get(reserved, :buffer_after)
    }
  end

  @doc """
  The value of `name` on `resource`, or `nil` when the resource does
  not carry that attribute.

  ### Arguments

  * `resource` is a `t:t/0`.

  * `name` is the attribute name.

  ### Returns

  * the attribute value, or `nil`.

  ### Examples

      iex> boardroom = Timetable.Resource.new("Boardroom", seats: 8)
      iex> {Timetable.Resource.attribute(boardroom, :seats),
      ...>  Timetable.Resource.attribute(boardroom, :projector)}
      {8, nil}

  """
  @spec attribute(t(), atom()) :: term()
  def attribute(%__MODULE__{attributes: attributes}, name), do: Map.get(attributes, name)

  @doc """
  `true` when `resource` sits inside `place`, at any depth.

  A resource with no place is inside nothing.

  ### Arguments

  * `resource` is a `t:t/0`.

  * `place` is a `t:Timetable.Place.t/0`.

  ### Returns

  * `true` or `false`.

  ### Examples

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> level_2 = Timetable.Place.new("Level 2", within: sydney)
      iex> boardroom = Timetable.Resource.new("Boardroom", within: level_2)
      iex> Timetable.Resource.within?(boardroom, sydney)
      true

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> nowhere = Timetable.Resource.new("Nowhere")
      iex> Timetable.Resource.within?(nowhere, sydney)
      false

  """
  @spec within?(t(), Place.t()) :: boolean()
  def within?(%__MODULE__{within: nil}, %Place{}), do: false
  def within?(%__MODULE__{within: within}, %Place{} = place), do: Place.contains?(place, within)

  @doc """
  How far apart two resources are in the place tree, in levels.

  Delegates to `Timetable.Place.separation/2`; a resource with no
  place is `:disjoint` from everything, itself included, because
  nothing can be said about the journey.

  ### Arguments

  * `a` and `b` are each a `t:t/0`.

  ### Returns

  * `0`, a positive integer, or `:disjoint` — see
    `Timetable.Place.separation/2`.

  ### Examples

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> level_2 = Timetable.Place.new("Level 2", within: sydney)
      iex> level_3 = Timetable.Place.new("Level 3", within: sydney)
      iex> boardroom = Timetable.Resource.new("Boardroom", within: level_2)
      iex> annexe = Timetable.Resource.new("Annexe", within: level_3)
      iex> Timetable.Resource.separation(boardroom, annexe)
      1

  """
  @spec separation(t(), t()) :: Place.separation()
  def separation(%__MODULE__{within: nil}, %__MODULE__{}), do: :disjoint
  def separation(%__MODULE__{}, %__MODULE__{within: nil}), do: :disjoint

  def separation(%__MODULE__{within: a}, %__MODULE__{within: b}), do: Place.separation(a, b)
end
