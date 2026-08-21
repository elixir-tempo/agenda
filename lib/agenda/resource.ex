defmodule Agenda.Resource do
  @moduledoc """
  A resource — a named thing that can be allocated to a session.

  People and rooms are the same kind of thing here; only their
  attributes differ. A room has `seats` and `video_conferencing`, a
  person has skills and access needs, and both sit somewhere in the
  `Agenda.Place` tree.

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

  * **`limits`** — how often it may be claimed over a *period*, as
    `[day: 1, week: 5]`. Concurrency asks how many claims may overlap
    at an instant; a limit asks how many may fall inside a stretch of
    calendar, however far apart. A nurse who may work one shift a day
    and five a week is `concurrency: 1, limits: [day: 1, week: 5]` —
    the concurrency stops two at once, the limits make it a contract.

  """

  alias Agenda.Place

  @typedoc "A named, allocatable thing."
  @type t :: %__MODULE__{
          name: String.t(),
          attributes: %{optional(atom()) => term()},
          within: Place.t() | nil,
          requires: %{optional(atom()) => term()},
          concurrency: pos_integer(),
          limits: keyword(),
          avoids: term(),
          prefers: term(),
          open: Tempo.Interval.t() | Tempo.IntervalSet.t() | nil,
          buffer_before: Tempo.Duration.t() | nil,
          buffer_after: Tempo.Duration.t() | nil
        }

  defstruct name: nil,
            attributes: %{},
            within: nil,
            requires: %{},
            concurrency: 1,
            limits: [],
            avoids: nil,
            prefers: nil,
            open: nil,
            buffer_before: nil,
            buffer_after: nil

  @reserved [
    :within,
    :requires,
    :concurrency,
    :limits,
    :avoids,
    :prefers,
    :open,
    :buffer_before,
    :buffer_after
  ]

  @doc """
  Build a resource.

  Any option that is not reserved becomes an attribute, so attributes
  read as themselves at the call site rather than being nested inside
  an `attributes:` keyword.

  ### Arguments

  * `name` is the resource's name.

  ### Options

  * `:within` is the enclosing `t:Agenda.Place.t/0`. The
    default is `nil`.

  * `:requires` is a keyword list of attributes this resource demands
    of resources allocated alongside it. The default is `[]`.

  * `:concurrency` is how many sessions may hold this resource
    simultaneously. The default is `1`.

  * `:limits` caps how often the resource may be claimed *over a
    period*, as `[day: 1, week: 5]` — at most one shift a day and five
    a week. Recognised periods are `:day`, `:week` and `:month`. This
    is not concurrency: concurrency is how many claims may overlap at
    one instant, a limit is how many may fall inside a stretch of
    calendar however far apart they are. The default is none.

  * `:avoids` is when the resource would *rather not* be used — a
    Tempo value, an ISO 8601 string, or a recurrence. Unlike `:open`
    this is a wish, not a rule: it makes a placement worse rather than
    invalid, and only counts when the programme declares the
    `:resource_wishes` preference. The default is none.

  * `:prefers` is the mirror — when the resource would *rather* be
    used. A placement outside it is a violation. The default is none.

  * `:open` is when the resource is available at all — see
    `Agenda.open/2`, which validates it. The default is `nil`,
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

      iex> boardroom = Agenda.Resource.new("Boardroom", seats: 8, video_conferencing: true)
      iex> boardroom.attributes
      %{seats: 8, video_conferencing: true}

      iex> alice = Agenda.Resource.new("Alice", requires: [step_free_access: true])
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
      limits: Keyword.get(reserved, :limits, []),
      avoids: Keyword.get(reserved, :avoids),
      prefers: Keyword.get(reserved, :prefers),
      open: Keyword.get(reserved, :open),
      buffer_before: duration(Keyword.get(reserved, :buffer_before)),
      buffer_after: duration(Keyword.get(reserved, :buffer_after))
    }
  end

  # A buffer is written the way every other duration in this library is
  # written — `"PT10M"` or `~o"PT10M"` — but it is the only one that is
  # not used until something is already booked. Left as a string it
  # reaches `Tempo.shift/2` the first time a claim has to be widened,
  # which is a crash a long way from the line that caused it, and only
  # on resources that turned out to be busy. Parsing it here means the
  # value is either usable or unchanged from the moment it is given.
  defp duration(nil), do: nil

  defp duration(value) when is_binary(value) do
    case Tempo.from_iso8601(value) do
      {:ok, parsed} -> parsed
      {:error, _reason} -> value
    end
  end

  defp duration(value), do: value

  @doc """
  The value of `name` on `resource`, or `nil` when the resource does
  not carry that attribute.

  ### Arguments

  * `resource` is a `t:t/0`.

  * `name` is the attribute name.

  ### Returns

  * the attribute value, or `nil`.

  ### Examples

      iex> boardroom = Agenda.Resource.new("Boardroom", seats: 8)
      iex> {Agenda.Resource.attribute(boardroom, :seats),
      ...>  Agenda.Resource.attribute(boardroom, :projector)}
      {8, nil}

  """
  @spec attribute(t(), atom()) :: term()
  def attribute(%__MODULE__{attributes: attributes}, name), do: Map.get(attributes, name)

  @doc """
  `true` when `resource` sits inside `place`, at any depth.

  A resource with no place is inside nothing.

  ### Arguments

  * `resource` is a `t:t/0`.

  * `place` is a `t:Agenda.Place.t/0`.

  ### Returns

  * `true` or `false`.

  ### Examples

      iex> sydney = Agenda.Place.new("Sydney Convention Centre")
      iex> level_2 = Agenda.Place.new("Level 2", within: sydney)
      iex> boardroom = Agenda.Resource.new("Boardroom", within: level_2)
      iex> Agenda.Resource.within?(boardroom, sydney)
      true

      iex> sydney = Agenda.Place.new("Sydney Convention Centre")
      iex> nowhere = Agenda.Resource.new("Nowhere")
      iex> Agenda.Resource.within?(nowhere, sydney)
      false

  """
  @spec within?(t(), Place.t()) :: boolean()
  def within?(%__MODULE__{within: nil}, %Place{}), do: false
  def within?(%__MODULE__{within: within}, %Place{} = place), do: Place.contains?(place, within)

  @doc """
  How far apart two resources are in the place tree, in levels.

  Delegates to `Agenda.Place.separation/2`; a resource with no
  place is `:disjoint` from everything, itself included, because
  nothing can be said about the journey.

  ### Arguments

  * `a` and `b` are each a `t:t/0`.

  ### Returns

  * `0`, a positive integer, or `:disjoint` — see
    `Agenda.Place.separation/2`.

  ### Examples

      iex> sydney = Agenda.Place.new("Sydney Convention Centre")
      iex> level_2 = Agenda.Place.new("Level 2", within: sydney)
      iex> level_3 = Agenda.Place.new("Level 3", within: sydney)
      iex> boardroom = Agenda.Resource.new("Boardroom", within: level_2)
      iex> annexe = Agenda.Resource.new("Annexe", within: level_3)
      iex> Agenda.Resource.separation(boardroom, annexe)
      1

  """
  @spec separation(t(), t()) :: Place.separation()
  def separation(%__MODULE__{within: nil}, %__MODULE__{}), do: :disjoint
  def separation(%__MODULE__{}, %__MODULE__{within: nil}), do: :disjoint

  def separation(%__MODULE__{within: a}, %__MODULE__{within: b}), do: Place.separation(a, b)
end
