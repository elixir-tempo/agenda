defmodule Timetable.Preference do
  @moduledoc """
  What makes one workable layout better than another.

  Every constraint elsewhere in this library is **hard**: a room is
  eligible or it is not, two sessions clash or they do not. A
  preference is soft. It never makes a layout invalid, it only makes
  it worse — and a programme with none is exactly as correct as one
  with several, just less opinionated about which of the workable
  answers you get.

  ### Penalties, not rewards

  A preference counts *violations*, and lower is better. Counting what
  is wrong rather than what is right means the ideal layout scores
  zero, which is a number that means something on its own — where a
  reward total only means something next to another reward total.

  ### What is and is not promised

  `Timetable.Arranger.arrange/3` optimises **lexicographically**: it
  first places as many sessions as it can, provably, and only then
  prefers a better score among the layouts it reaches. The count is
  proven; the score is not, and `Timetable.Layout`'s `score_proven?`
  says which you have. This is a deliberate limit — proving soft
  optimality means bounding a weighted cost, and no bound that cheap
  exists here. A programme that genuinely needs it wants a solver.

  ### Writing your own

  A preference is a name, a weight, and a function from the placements
  to a violation count:

      Timetable.Programme.prefer(programme, {:no_friday_afternoons, &count_friday_afternoons/2},
        weight: 3)

  The function receives the arrangements and a context carrying
  `:programme` and `:pool`, so it can consult the tracks and the
  resources as well as the placements.

  """

  alias Tempo.Compare
  alias Timetable.Arrangement
  alias Timetable.Programme
  alias Timetable.Track

  @typedoc "The information a preference may consult beyond the placements."
  @type context :: %{programme: Programme.t(), pool: list()}

  @typedoc "A named, weighted soft constraint."
  @type t :: %__MODULE__{
          name: atom(),
          weight: number(),
          count: (list(), context() -> non_neg_integer())
        }

  defstruct [:name, :weight, :count]

  @builtin [:room_changes, :room_spread]

  @doc """
  Build a preference.

  ### Arguments

  * `preference` is a built-in name — `:room_changes` or
    `:room_spread` — or a `{name, function}` pair for one of your own.

  ### Options

  * `:weight` is how much each violation costs. The default is `1`.

  ### Returns

  * `{:ok, t:t/0}`; or

  * `{:error, reason}` when the name is neither a built-in nor paired
    with a function.

  ### Examples

      iex> {:ok, preference} = Timetable.Preference.new(:room_changes, weight: 10)
      iex> {preference.name, preference.weight}
      {:room_changes, 10}

      iex> Timetable.Preference.new(:teleportation)
      {:error, {:unknown_preference, :teleportation}}

  """
  @spec new(atom() | {atom(), function()}, keyword()) :: {:ok, t()} | {:error, term()}
  def new(preference, options \\ [])

  def new(name, options) when name in @builtin do
    {:ok, %__MODULE__{name: name, weight: weight(options), count: counter(name)}}
  end

  def new({name, counter}, options) when is_atom(name) and is_function(counter, 2) do
    {:ok, %__MODULE__{name: name, weight: weight(options), count: counter}}
  end

  def new(name, _options) when is_atom(name), do: {:error, {:unknown_preference, name}}
  def new(other, _options), do: {:error, {:unknown_preference, other}}

  defp weight(options), do: Keyword.get(options, :weight, 1)

  @doc """
  What a layout costs against `preferences`.

  ### Arguments

  * `preferences` is a list of `t:t/0`.

  * `arrangements` is the placements to score.

  * `context` is a `t:context/0`.

  ### Returns

  * the total penalty, where `0` is ideal.

  ### Examples

      iex> Timetable.Preference.score([], [], %{programme: Timetable.programme("C"), pool: []})
      0

  """
  @spec score([t()], [Arrangement.t()], context()) :: number()
  def score(preferences, arrangements, context) do
    Enum.reduce(preferences, 0, fn preference, total ->
      total + preference.weight * preference.count.(arrangements, context)
    end)
  end

  @doc """
  What each preference contributed, as sentences.

  A single number says a layout is worse without saying how, which is
  the same failure `explain/2` exists to avoid for eligibility.

  ### Arguments

  * `preferences` is a list of `t:t/0`.

  * `arrangements` is the placements to score.

  * `context` is a `t:context/0`.

  ### Returns

  * one sentence per preference, in the order they were declared.

  ### Examples

      iex> {:ok, preference} = Timetable.Preference.new(:room_changes, weight: 10)
      iex> context = %{programme: Timetable.programme("Conf"), pool: []}
      iex> Timetable.Preference.explain([preference], [], context)
      ["room_changes: 0 × 10 = 0"]

  """
  @spec explain([t()], [Arrangement.t()], context()) :: [String.t()]
  def explain(preferences, arrangements, context) do
    Enum.map(preferences, fn preference ->
      violations = preference.count.(arrangements, context)

      "#{preference.name}: #{violations} × #{preference.weight} = " <>
        "#{violations * preference.weight}"
    end)
  end

  ## --- the built-ins ---------------------------------------------

  defp counter(:room_changes), do: &room_changes/2
  defp counter(:room_spread), do: &room_spread/2

  # A delegate following a track would rather stay put. Counts the
  # consecutive pairs within each track that sit in different rooms —
  # not the rooms used, so a track that moves once and stays scores
  # better than one that alternates.
  defp room_changes(arrangements, %{programme: programme}) do
    programme.tracks
    |> Enum.map(&changes_within(&1, arrangements))
    |> Enum.sum()
  end

  defp changes_within(%Track{} = track, arrangements) do
    names = MapSet.new(Track.session_names(track))

    arrangements
    |> Enum.filter(&MapSet.member?(names, &1.session))
    |> Enum.sort_by(& &1.interval.from, &earlier_or_same/2)
    |> Enum.map(&rooms_of/1)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [before, after_it] -> before != after_it end)
  end

  # Piling every session into one room while another stands empty is
  # workable and disliked. The penalty is the gap between the busiest
  # and least-busy room *in use* — comparing against unused rooms
  # would punish merely having a large pool.
  defp room_spread(arrangements, _context) do
    arrangements
    |> Enum.flat_map(&MapSet.to_list(rooms_of(&1)))
    |> Enum.frequencies()
    |> Map.values()
    |> case do
      [] -> 0
      [_only] -> 0
      uses -> Enum.max(uses) - Enum.min(uses)
    end
  end

  # Only located resources count as "rooms" — a person or a projector
  # travels with the session and moving between them is not a walk.
  defp rooms_of(%Arrangement{} = arrangement) do
    arrangement
    |> Arrangement.resources()
    |> Enum.reject(&is_nil(&1.within))
    |> MapSet.new(& &1.name)
  end

  defp earlier_or_same(a, b) do
    Compare.compare_endpoints(a, b) in [:earlier, :same]
  end
end
