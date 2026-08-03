defmodule Timetable.Arranger do
  @moduledoc """
  Laying out a whole programme — a placement for every session, with
  nothing clashing.

  This is a **search**, not an enumeration, and that is the difference
  between it and `Timetable.Planner.plan/3`. Planning lists the ways
  one session could be held; arranging must choose one placement per
  session such that every choice is still compatible with every other.
  A room taken by the keynote is gone for the workshop.

  Three constraints hold a programme together:

  * **No resource is in two places at once.** Two placements sharing a
    resource must not overlap.

  * **A track cannot clash with itself.** Sessions sharing an audience
    must not overlap, which is what makes a track a track.

  * **Consecutive track sessions must be reachable.** The gap between
    them must be at least the journey between their rooms — derived
    from the place tree, not configured.

  ### Scale, and where this stops

  The search is depth-first with backtracking, ordered most-constrained
  first, and bounded by an explicit node cap. A conference of a few
  dozen sessions across a handful of rooms is comfortable. A university
  timetable of thousands of classes is not — that wants a real
  constraint solver, and the way to use one here is to write its output
  back through `Timetable.Ledger.allocate/2`, which stays authoritative
  either way.

  When the cap is reached the result says so rather than returning a
  partial layout as though it were complete: a partial programme
  presented as finished is worse than an admitted failure.

  """

  import Tempo.Sigils

  alias Tempo.Compare
  alias Tempo.Interval
  alias Timetable.Arrangement
  alias Timetable.Infeasible
  alias Timetable.Planner
  alias Timetable.Programme
  alias Timetable.Resource
  alias Timetable.Track

  @default_nodes 10_000
  @default_candidates 40

  @doc """
  Find a placement for every session in `programme`.

  ### Arguments

  * `programme` is a `t:Timetable.Programme.t/0`.

  * `pool` is the list of `t:Timetable.Resource.t/0` to choose from.

  ### Options

  * `:busy` is a map of resource name to what already claims it, as
    `Timetable.Ledger.busy/2` returns. The default is `%{}`.

  * `:candidates` caps how many placements are considered per session.
    The default is `40`.

  * `:nodes` caps how many search steps are taken before giving up.
    The default is `10_000`.

  * `:travel` is passed to `Timetable.travel_time/3` for the
    reachability check — use it to supply per-pair overrides.

  ### Returns

  * `{:ok, arrangements}` — one per session, mutually consistent; or

  * `{:error, t:Timetable.Infeasible.t/0}` naming the session that
    could not be placed, or reporting that the cap was hit.

  ### Examples

      iex> room = Timetable.resource("Hall", seats: 100)
      iex> {:ok, room} = Timetable.open(room, "2026-09-15T09:00:00/2026-09-15T12:00:00")
      iex> talk = fn name ->
      ...>   Timetable.session(name, lasting: "PT1H", between: "2026-09-15/2026-09-16")
      ...>   |> Timetable.Session.needs(:room, seats: 100)
      ...> end
      iex> programme =
      ...>   Timetable.programme("Conf")
      ...>   |> Timetable.Programme.add_track(
      ...>        Timetable.track("Elixir", of: [talk.("Keynote"), talk.("Deep dive")]))
      iex> {:ok, arrangements} = Timetable.Arranger.arrange(programme, [room])
      iex> length(arrangements)
      2

  """
  @spec arrange(Programme.t(), [Resource.t()], keyword()) ::
          {:ok, [Arrangement.t()]} | {:error, Infeasible.t()}
  def arrange(%Programme{} = programme, pool, options \\ []) when is_list(pool) do
    with {:ok, candidates} <- candidates_per_session(programme, pool, options) do
      candidates
      |> Enum.sort_by(fn {_session, _symmetry, placements} -> length(placements) end)
      |> search(programme, [], budget(options), options)
      |> to_result(programme)
    end
  end

  defp budget(options), do: Keyword.get(options, :nodes, @default_nodes)

  # --- candidate placements, one session at a time ----------------

  defp candidates_per_session(programme, pool, options) do
    limit = Keyword.get(options, :candidates, @default_candidates)

    programme
    |> Programme.all_sessions()
    |> Enum.reduce_while({:ok, []}, fn session, {:ok, acc} ->
      case placements_for(session, programme, pool, options, limit) do
        {:ok, placements} ->
          {:cont, {:ok, acc ++ [{session, symmetry_of(session, programme), placements}]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # Two sessions are interchangeable when nothing distinguishes them
  # but their name: same track, same length, same window, same
  # requirements. Anything that makes them different — a different
  # room requirement, a different day — gives them different keys and
  # exempts them from the ordering rule below.
  defp symmetry_of(session, programme) do
    track = Programme.track_of(programme, session.name)

    {track && track.name, session.duration, session.window, session.requirements}
  end

  defp placements_for(session, programme, pool, options, limit) do
    session = bounded_by(session, programme)

    plan_options =
      options
      |> Keyword.take([:busy])
      |> Keyword.put(:limit, limit)

    Planner.plan(session, pool, plan_options)
  end

  # A session inherits the programme's window unless it states its own.
  defp bounded_by(%{window: nil} = session, %Programme{window: window}),
    do: %{session | window: window}

  defp bounded_by(session, _programme), do: session

  # --- depth-first search with backtracking -----------------------

  # `placed` holds `{arrangement, symmetry}` pairs — the symmetry key
  # is search bookkeeping and never reaches the caller.
  defp search([], _programme, placed, budget, _options),
    do: {:found, placed |> Enum.reverse() |> Enum.map(&elem(&1, 0)), budget}

  defp search(_remaining, _programme, _placed, budget, _options) when budget <= 0,
    do: {:exhausted, :nodes}

  defp search([{session, symmetry, candidates} | rest], programme, placed, budget, options) do
    try_candidates(candidates, session, symmetry, rest, programme, placed, budget, options)
  end

  defp try_candidates([], session, _symmetry, _rest, _programme, _placed, _budget, _options),
    do: {:stuck, session}

  defp try_candidates(
         [candidate | others],
         session,
         symmetry,
         rest,
         programme,
         placed,
         budget,
         options
       ) do
    if worth_trying?(candidate, symmetry, programme, placed, options) do
      case search(rest, programme, [{candidate, symmetry} | placed], budget - 1, options) do
        {:found, _arrangements, _left} = found ->
          found

        {:exhausted, _why} = exhausted ->
          exhausted

        {:stuck, _deeper} ->
          try_candidates(others, session, symmetry, rest, programme, placed, budget - 1, options)
      end
    else
      try_candidates(others, session, symmetry, rest, programme, placed, budget - 1, options)
    end
  end

  # Symmetry breaking, and the reason the search is tractable at all.
  #
  # Interchangeable sessions — same length, same window, same
  # requirements, same track — produce identical subproblems under any
  # permutation. Without a canonical order the search explores all of
  # them, so proving a tight programme infeasible costs a factorial in
  # the number of look-alike sessions. Requiring each to start no
  # earlier than its predecessor in the same group collapses those
  # permutations to one, and loses no solution: any arrangement can be
  # relabelled into this order because the sessions are identical.
  defp worth_trying?(candidate, symmetry, programme, placed, options) do
    in_symmetry_order?(candidate, symmetry, placed) and
      compatible?(candidate, placed, programme, options)
  end

  # The most recently placed session of the same shape is the head of
  # `placed`'s matching entries, so this candidate must not start
  # before it.
  defp in_symmetry_order?(candidate, symmetry, placed) do
    case Enum.find(placed, fn {_arrangement, key} -> key == symmetry end) do
      nil ->
        true

      {earlier, _key} ->
        Compare.compare_endpoints(earlier.interval.from, candidate.interval.from) != :later
    end
  end

  defp to_result({:found, arrangements, _budget}, _programme), do: {:ok, arrangements}

  defp to_result({:exhausted, :nodes}, programme) do
    {:error,
     Infeasible.new(programme.name, [
       "the search reached its node limit before placing every session — " <>
         "raise :nodes, or narrow the programme"
     ])}
  end

  defp to_result({:stuck, session}, programme) do
    {:error,
     Infeasible.new(programme.name, [
       "#{session.name} cannot be placed without clashing with something already placed"
     ])}
  end

  # --- the three constraints --------------------------------------

  defp compatible?(candidate, placed, programme, options) do
    within_capacity?(candidate, placed) and
      Enum.all?(placed, fn {arrangement, _symmetry} ->
        track_ok?(candidate, arrangement, programme, options)
      end)
  end

  # Capacity is a question about the whole set of placements, not about
  # any pair: a resource with concurrency 3 tolerates two overlapping
  # holders and refuses the third. Asking pairwise could only ever
  # answer "is it free at all", which is the concurrency-1 special case.
  defp within_capacity?(candidate, placed) do
    Enum.all?(Arrangement.resources(candidate), fn resource ->
      holders = Enum.count(placed, &holds_at?(&1, resource.name, candidate.interval))

      holders + 1 <= resource.concurrency
    end)
  end

  defp holds_at?({arrangement, _symmetry}, name, interval) do
    Tempo.overlaps?(arrangement.interval, interval) and
      Enum.any?(Arrangement.resources(arrangement), &(&1.name == name))
  end

  defp track_ok?(a, b, programme, options) do
    case {Programme.track_of(programme, a.session), Programme.track_of(programme, b.session)} do
      {%Track{} = track, %Track{name: same}} when track.name == same ->
        same_track_ok?(a, b, track, options)

      _different_or_none ->
        true
    end
  end

  # A track cannot clash with itself, and a delegate must be able to
  # walk between consecutive sessions in the gap between them.
  defp same_track_ok?(a, b, %Track{} = track, options) do
    Tempo.disjoint?(a.interval, b.interval) and reachable?(a, b, track, options)
  end

  defp reachable?(_a, _b, %Track{reachable_within: nil}, _options), do: true

  defp reachable?(a, b, %Track{reachable_within: within}, options) do
    {earlier, later} = in_time_order(a, b)

    case longest_journey(earlier, later, options) do
      :unknown -> false
      journey -> fits_the_gap?(earlier, later, journey) and no_longer_than?(journey, within)
    end
  end

  defp in_time_order(a, b) do
    if Tempo.before?(a.interval, b.interval) or Tempo.meets?(a.interval, b.interval) do
      {a, b}
    else
      {b, a}
    end
  end

  # The journey has to happen in the space between the two sessions.
  # Sessions that meet leave no space at all, so only a journey of no
  # distance fits.
  defp fits_the_gap?(earlier, later, journey) do
    case Interval.new(from: earlier.interval.to, to: later.interval.from) do
      {:ok, gap} -> Tempo.at_least?(gap, journey)
      {:error, _no_gap} -> no_longer_than?(journey, ~o"PT0S")
    end
  end

  # Comparing two durations means giving them a position: shift a
  # common origin by each and compare where they land. Comparing the
  # structs directly would be Erlang term order, and comparing their
  # ISO strings would be worse. Points rather than spans, because a
  # zero-length duration has no valid interval under the half-open
  # convention — and a zero journey is the ordinary case for two rooms
  # in the same place.
  @origin ~o"2000-01-01T00:00:00"

  defp no_longer_than?(duration, limit) do
    Compare.compare_endpoints(
      Tempo.shift(@origin, duration),
      Tempo.shift(@origin, limit)
    ) in [:earlier, :same]
  end

  # The slowest journey between any *located* resource of one session
  # and any of the other — if a single delegate cannot make it, the
  # pair fails. One unknown journey makes the whole pair unknown: an
  # unmeasured route is not a short one.
  #
  # Only located resources count. A person or a piece of equipment has
  # no place of its own — it travels with the session — so including
  # them would make every journey unknown. Travel is between places,
  # and only things that sit somewhere have one.
  defp longest_journey(earlier, later, options) do
    travel = Keyword.get(options, :travel, [])

    pairs =
      for from <- located(earlier),
          to <- located(later),
          do: {from, to}

    Enum.reduce_while(pairs, ~o"PT0S", fn {from, to}, longest ->
      case Timetable.travel_time(from, to, travel) do
        {:error, :unknown} -> {:halt, :unknown}
        {:ok, journey} -> {:cont, longer_of(longest, journey)}
      end
    end)
  end

  defp longer_of(longest, journey) do
    if no_longer_than?(journey, longest), do: longest, else: journey
  end

  defp located(%Arrangement{} = arrangement) do
    arrangement |> Arrangement.resources() |> Enum.reject(&is_nil(&1.within))
  end
end
