defmodule Timetable.Place do
  @moduledoc """
  A place — a named location that contains resources and other places.

  Places form a tree of arbitrary depth. A campus contains buildings,
  a building contains floors, a floor contains rooms; the library never
  interprets what a level *means*, only how the levels nest.

  The tree exists so that travel between two resources can be
  **derived** rather than configured. A flat `location: :sydney`
  attribute can answer *"is this room in Sydney?"*, but not *"can
  someone get from here to there in the ten-minute break?"* — and only
  the second question decides whether a programme is workable.
  `separation/2` is the primitive that answers it.

  """

  @typedoc "A place in the containment tree."
  @type t :: %__MODULE__{name: String.t(), within: t() | nil}

  @typedoc """
  How far apart two places are: `0` when they are the same place, `n`
  when the deeper of the two is `n` levels below their nearest common
  ancestor, and `:disjoint` when they share no ancestor at all.
  """
  @type separation :: non_neg_integer() | :disjoint

  defstruct [:name, :within]

  @doc """
  Build a place, optionally inside another.

  ### Arguments

  * `name` is the place's name.

  ### Options

  * `:within` is the enclosing `t:t/0`. The default is `nil`, making
    this place a root.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> level_2 = Timetable.Place.new("Level 2", within: sydney)
      iex> level_2.within.name
      "Sydney Convention Centre"

  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, options \\ []) when is_binary(name) do
    %__MODULE__{name: name, within: Keyword.get(options, :within)}
  end

  @doc """
  The chain of places from the root down to `place`, inclusive.

  ### Arguments

  * `place` is a `t:t/0`.

  ### Returns

  * a list of `t:t/0` ordered outermost first.

  ### Examples

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> level_2 = Timetable.Place.new("Level 2", within: sydney)
      iex> Enum.map(Timetable.Place.path(level_2), & &1.name)
      ["Sydney Convention Centre", "Level 2"]

  """
  @spec path(t()) :: [t()]
  def path(%__MODULE__{} = place), do: climb(place, [])

  # Climbing towards the root while prepending yields the chain
  # outermost-first, which is the order `common_ancestor/2` zips on.
  defp climb(nil, acc), do: acc
  defp climb(%__MODULE__{within: within} = place, acc), do: climb(within, [place | acc])

  @doc """
  The outermost place enclosing `place`, or `place` itself when it is
  already a root.

  ### Arguments

  * `place` is a `t:t/0`.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> level_2 = Timetable.Place.new("Level 2", within: sydney)
      iex> Timetable.Place.root(level_2).name
      "Sydney Convention Centre"

  """
  @spec root(t()) :: t()
  def root(%__MODULE__{within: nil} = place), do: place
  def root(%__MODULE__{within: within}), do: root(within)

  @doc """
  `true` when `outer` encloses `inner`, at any depth. A place contains
  itself.

  ### Arguments

  * `outer` is the enclosing `t:t/0`.

  * `inner` is the enclosed `t:t/0`.

  ### Returns

  * `true` or `false`.

  ### Examples

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> level_2 = Timetable.Place.new("Level 2", within: sydney)
      iex> Timetable.Place.contains?(sydney, level_2)
      true

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> level_2 = Timetable.Place.new("Level 2", within: sydney)
      iex> Timetable.Place.contains?(level_2, sydney)
      false

  """
  @spec contains?(t(), t()) :: boolean()
  def contains?(%__MODULE__{} = outer, %__MODULE__{} = inner) do
    Enum.any?(path(inner), &same?(&1, outer))
  end

  @doc """
  The nearest place enclosing both `a` and `b`, or `nil` when they
  share no ancestor.

  ### Arguments

  * `a` and `b` are each a `t:t/0`.

  ### Returns

  * the innermost common `t:t/0`; or

  * `nil` when the two are in unrelated trees.

  ### Examples

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> level_2 = Timetable.Place.new("Level 2", within: sydney)
      iex> level_3 = Timetable.Place.new("Level 3", within: sydney)
      iex> Timetable.Place.common_ancestor(level_2, level_3).name
      "Sydney Convention Centre"

  """
  @spec common_ancestor(t(), t()) :: t() | nil
  def common_ancestor(%__MODULE__{} = a, %__MODULE__{} = b) do
    a
    |> path()
    |> Enum.zip(path(b))
    |> Enum.take_while(fn {x, y} -> same?(x, y) end)
    |> List.last()
    |> case do
      nil -> nil
      {shared, _} -> shared
    end
  end

  @doc """
  How far apart two places are, measured in levels of the containment
  tree.

  This is the primitive travel time is derived from: the further up the
  tree you must climb to get from one place to the other, the longer
  the journey.

  ### Arguments

  * `a` and `b` are each a `t:t/0`.

  ### Returns

  * `0` when `a` and `b` are the same place;

  * a positive integer — the number of levels from the deeper place up
    to the nearest common ancestor; or

  * `:disjoint` when the two share no ancestor.

  ### Examples

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> level_2 = Timetable.Place.new("Level 2", within: sydney)
      iex> level_3 = Timetable.Place.new("Level 3", within: sydney)
      iex> {Timetable.Place.separation(level_2, level_2),
      ...>  Timetable.Place.separation(level_2, level_3)}
      {0, 1}

      iex> sydney = Timetable.Place.new("Sydney Convention Centre")
      iex> darling = Timetable.Place.new("Darling Harbour Theatre")
      iex> Timetable.Place.separation(sydney, darling)
      :disjoint

  """
  @spec separation(t(), t()) :: separation()
  def separation(%__MODULE__{} = a, %__MODULE__{} = b) do
    case common_ancestor(a, b) do
      nil -> :disjoint
      shared -> max(depth_below(a, shared), depth_below(b, shared))
    end
  end

  # How many levels `place` sits below `ancestor`.
  defp depth_below(place, ancestor) do
    length(path(place)) - length(path(ancestor))
  end

  # Places are compared by identity of name and enclosing chain rather
  # than by struct equality, so two independently-built values naming
  # the same place are the same place.
  defp same?(%__MODULE__{name: name, within: nil}, %__MODULE__{name: name, within: nil}), do: true

  defp same?(%__MODULE__{name: name, within: a}, %__MODULE__{name: name, within: b})
       when not is_nil(a) and not is_nil(b),
       do: same?(a, b)

  defp same?(%__MODULE__{}, %__MODULE__{}), do: false
end
