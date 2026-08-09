defmodule Timetable.Conflict do
  @moduledoc """
  Which constraints are *jointly* to blame.

  "No arrangement found" is a dead end. "These three sessions cannot
  all be held — any two of them can" is a decision: drop one, move one,
  or find another room. The difference is a **minimal conflict set** —
  a set of constraints that cannot hold together, from which removing
  any single member makes the rest satisfiable.

  Minimality is what makes it useful. Every failing programme is
  trivially its own conflict set; naming the two sessions that actually
  collide out of forty is the answer someone can act on.

  This is QuickXplain (Junker, 2004), and it is deliberately generic:
  it knows nothing about sessions or resources, only how to bisect a
  list and ask an oracle. `Timetable.Arranger.conflict/3` supplies the
  programme oracle and `Timetable.Planner.conflict/3` the requirement
  one.

  ### What the oracle must promise

  `satisfiable?` must be **monotone**: if a set of constraints cannot
  be satisfied, no superset of it can be either. Every constraint in
  this library narrows — a further session to place, a further
  attribute to match — so this holds naturally. An oracle that gives up
  early (`Timetable.Arranger.arrange/3` hitting its `:nodes` cap, say)
  breaks the promise, and the conflict set it produces is a plausible
  guess rather than a proof.

  ### Cost

  Bisection, not enumeration: `O(k log(n/k))` oracle calls for a
  conflict of `k` constraints out of `n`. Twenty sessions with a
  two-session conflict costs on the order of ten arrangements, not a
  million subsets.

  """

  @typedoc "Decides whether a set of constraints can hold together."
  @type oracle :: ([term()] -> boolean())

  @doc """
  The smallest subset of `constraints` that still cannot be satisfied.

  ### Arguments

  * `constraints` is the list of constraints to search, each an opaque
    term the oracle understands.

  * `background` is the constraints that are never dropped — they are
    given to the oracle every time but can never appear in the result.
    Defaults to `[]`.

  * `satisfiable?` is the oracle: a function taking a list of
    constraints and returning `true` when they can hold together. It
    must be monotone, as described above.

  ### Returns

  * `:none` when everything holds together and there is nothing to
    explain; or

  * `{:ok, conflict}` where `conflict` is a minimal subset of
    `constraints`, in their original order. An empty list means
    `background` alone is unsatisfiable and nothing in `constraints` is
    to blame.

  ### Examples

      iex> # A set holds together while its members sum to ten or less.
      iex> room_for = fn chosen -> Enum.sum(chosen) <= 10 end
      iex> Timetable.Conflict.minimal([6, 7, 1], room_for)
      {:ok, [6, 7]}

      iex> room_for = fn chosen -> Enum.sum(chosen) <= 10 end
      iex> Timetable.Conflict.minimal([2, 3], room_for)
      :none

      iex> room_for = fn chosen -> Enum.sum(chosen) <= 10 end
      iex> Timetable.Conflict.minimal([1], [20], room_for)
      {:ok, []}

  """
  @spec minimal([term()], [term()], oracle()) :: {:ok, [term()]} | :none
  def minimal(constraints, background \\ [], satisfiable?)

  def minimal(constraints, background, satisfiable?)
      when is_list(constraints) and is_list(background) and is_function(satisfiable?, 1) do
    cond do
      satisfiable?.(background ++ constraints) -> :none
      not satisfiable?.(background) -> {:ok, []}
      true -> {:ok, narrow(background, false, constraints, satisfiable?)}
    end
  end

  # QuickXplain proper, entered only once the background is known to be
  # satisfiable on its own.
  #
  # Splitting in half and asking about each half finds a conflict in a
  # logarithmic number of oracle calls, where testing constraints one
  # at a time would take a linear number and enumerating subsets an
  # exponential one.
  #
  # `grew?` records whether `background` gained anything since the last
  # time it was tested. Without it every branch would re-ask a question
  # whose answer cannot have changed.
  defp narrow(background, grew?, constraints, satisfiable?) do
    cond do
      grew? and not satisfiable?.(background) ->
        []

      match?([_only], constraints) ->
        constraints

      true ->
        {first, second} = Enum.split(constraints, div(length(constraints), 2))

        from_second = narrow(background ++ first, first != [], second, satisfiable?)
        from_first = narrow(background ++ from_second, from_second != [], first, satisfiable?)

        from_first ++ from_second
    end
  end
end
