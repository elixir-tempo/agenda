defmodule Agenda.Planner do
  @moduledoc """
  Working out when and where a session could be held.

  The pipeline is ordered cheapest-first, and every stage but one is
  set algebra Tempo already performs:

  1. **Eligibility** — attribute matching, no calendar involved. This
     removes most of the search space before any interval is touched,
     and it is where a resource's own `requires` are folded in.

  2. **Availability** — one `Tempo.difference/2` per surviving
     resource: what it is open for, minus what already claims it.

  3. **Co-availability** — `Tempo.intersection/2` across a candidate
     combination: when the room *and* everyone needed are all free.

  4. **Slotting** — cut those windows into placements of the session's
     length with `Tempo.IntervalSet.slots/3`.

  5. **Ranking** — score against the session's soft preferences and
     return best-first.

  Provenance rides on the intervals themselves. Each resource's free
  time is tagged with its own name, and `Tempo.intersection/3`'s
  `{:merge, fun}` resolver accumulates those tags as the sets are
  intersected — so a surviving window states which resources produced
  it, and `Tempo.IntervalSet.slots/3` carries that through to every
  placement. Nothing has to be reconstructed afterwards.

  """

  alias Agenda.Arrangement
  alias Agenda.Availability
  alias Agenda.Conflict
  alias Agenda.Infeasible
  alias Agenda.Limit
  alias Agenda.Place
  alias Agenda.Requirement
  alias Agenda.Resource
  alias Agenda.Session
  alias Tempo.Compare
  alias Tempo.Duration
  alias Tempo.IntervalSet

  @default_limit 20

  @doc """
  Rank the ways `session` could be held against `pool`.

  ### Arguments

  * `session` is a `t:Agenda.Session.t/0` with a duration and a
    window.

  * `pool` is the list of `t:Agenda.Resource.t/0` available to
    choose from.

  ### Options

  * `:busy` is a map of resource name to what already claims it — any
    value `Agenda.Availability.free/2` accepts. The default is
    `%{}`.

  * `:limit` is the most arrangements to return. The default is `20`.
    Truncation is reported rather than silent — see `:truncated?` on
    the result.

  * `:spread` chooses *how* the list is truncated. `false`, the
    default, keeps the best `:limit` placements, which is what a caller
    picking one time wants. `true` samples start moments evenly across
    the window instead and round-robins between them, trading depth at
    the front of the window for coverage of all of it — which is what
    `Agenda.Arranger.arrange/3` needs, since sessions handed identical
    placements collide. The coverage is what makes a cap safe to set:
    with `:spread`, `limit: 4` over two days offers both days rather
    than four times on the first.

  ### Returns

  * `{:ok, arrangements}` ranked best-first; or

  * `{:error, t:Agenda.Infeasible.t/0}` carrying the reasons.

  ### Examples

      iex> boardroom = Agenda.Resource.new("Boardroom", seats: 8)
      iex> {:ok, boardroom} = Agenda.open(boardroom, "2026-06-15T09:00:00/2026-06-15T12:00:00")
      iex> session =
      ...>   Agenda.session("Review", duration: "PT1H", window: "2026-06-15/2026-06-16")
      ...>   |> Agenda.Session.needs(:room, seats: 8)
      iex> {:ok, arrangements} = Agenda.Planner.plan(session, [boardroom])
      iex> length(arrangements)
      3

  """
  @spec plan(Session.t(), [Resource.t()], keyword()) ::
          {:ok, [Arrangement.t()]} | {:error, Infeasible.t()}
  def plan(%Session{} = session, pool, options \\ []) when is_list(pool) do
    named = Session.named_resources(session)
    roles = induced_roles(session, named)

    with {:ok, candidates} <- eligible_by_role(session, roles, pool),
         {:ok, window} <- Availability.normalise(session.window),
         {:ok, duration} <- Availability.normalise(session.duration),
         {:ok, roster_free} <- co_free(named, window, window, options) do
      with {:ok, placements} <-
             arrangements(session, candidates, roster_free, window, duration, options) do
        placements
        |> within_limits(options)
        |> ranked(session, options)
      end
    end
  end

  @doc """
  The smallest set of demands that rules out every way of holding
  `session`.

  Where `plan/3`'s failure says *that* nothing fits, this says *which
  demands together* make it so — the requirement-level counterpart of
  `Agenda.Arranger.conflict/3`. Two attributes that are each
  satisfiable alone but impossible together are the common case, and
  neither `Agenda.explain/2` nor a list of near misses will show it.

  Both kinds of demand are searched, which matters because the second
  is invisible at the call site:

  * `{:needs, role, attribute}` — an attribute the session asked for,
    as in `Agenda.Session.needs(session, :room, seats: at_least(8))`.

  * `{:requires, resource, attribute}` — an attribute a rostered
    resource *induces*, as in a person whose `requires:` tightens
    whatever room they are booked into.

  ### Arguments

  * `session` is a `t:Agenda.Session.t/0`.

  * `pool` is the list of `t:Agenda.Resource.t/0` to choose from.

  ### Options

  Takes the same options as `plan/3`.

  ### Returns

  * `:none` when the session can be held and there is nothing to
    explain; or

  * `{:ok, demands}` — a minimal set of demands that cannot all be met.
    An empty list means no demand is to blame: the session fails on
    time alone, with every attribute demand dropped.

  ### Examples

      iex> import Agenda.Predicate
      iex> small = Agenda.resource("Snug", seats: 4, video_conferencing: true)
      iex> {:ok, small} = Agenda.open(small, "2026-06-15T09:00:00/2026-06-15T12:00:00")
      iex> big = Agenda.resource("Barn", seats: 40, video_conferencing: false)
      iex> {:ok, big} = Agenda.open(big, "2026-06-15T09:00:00/2026-06-15T12:00:00")
      iex> session =
      ...>   Agenda.session("Review", duration: "PT1H", window: "2026-06-15/2026-06-16")
      ...>   |> Agenda.Session.needs(:room, seats: at_least(8), video_conferencing: true)
      iex> Agenda.Planner.conflict(session, [small, big])
      {:ok, [needs: {:room, :seats}, needs: {:room, :video_conferencing}]}

  """
  @spec conflict(Session.t(), [Resource.t()], keyword()) ::
          {:ok, [{:needs | :requires, {atom() | String.t(), atom()}}]} | :none
  def conflict(%Session{} = session, pool, options \\ []) when is_list(pool) do
    Conflict.minimal(demands(session), fn kept ->
      match?({:ok, _arrangements}, plan(relaxed(session, kept), pool, options))
    end)
  end

  defp demands(%Session{} = session) do
    asked =
      for requirement <- session.requirements,
          {attribute, _predicate} <- requirement.attributes,
          do: {:needs, {requirement.name, attribute}}

    induced =
      for requirement <- session.requirements,
          resource <- requirement.roster,
          {attribute, _value} <- resource.requires,
          do: {:requires, {resource.name, attribute}}

    asked ++ Enum.uniq(induced)
  end

  # The session as it would be if only `kept` were demanded of it.
  # Induced demands are dropped at their source — the rostered
  # resource's own `requires` — because that is where the induction
  # happens, and suppressing it anywhere later would leave `plan/3`
  # folding it straight back in.
  defp relaxed(%Session{} = session, kept) do
    keeping = MapSet.new(kept)

    requirements =
      Enum.map(session.requirements, fn requirement ->
        %{
          requirement
          | attributes:
              Map.filter(requirement.attributes, fn {attribute, _predicate} ->
                MapSet.member?(keeping, {:needs, {requirement.name, attribute}})
              end),
            roster: Enum.map(requirement.roster, &without_induced(&1, keeping))
        }
      end)

    %{session | requirements: requirements}
  end

  defp without_induced(%Resource{} = resource, keeping) do
    %{
      resource
      | requires:
          Map.filter(resource.requires, fn {attribute, _value} ->
            MapSet.member?(keeping, {:requires, {resource.name, attribute}})
          end)
    }
  end

  # --- stage 1: eligibility --------------------------------------

  # A named resource's own `requires` tighten every open role: booking
  # Alice, who needs step-free access, rules out inaccessible rooms.
  defp induced_roles(%Session{} = session, named) do
    session
    |> Session.open_roles()
    |> Enum.map(&Requirement.induce(&1, named))
  end

  defp eligible_by_role(session, roles, pool) do
    roles
    |> Enum.map(&{&1, Requirement.eligible(&1, pool)})
    |> Enum.split_with(fn {_role, eligible} -> eligible != [] end)
    |> case do
      {filled, []} -> {:ok, filled}
      {_filled, empty} -> {:error, no_candidates(session, empty, pool)}
    end
  end

  defp no_candidates(session, empty, pool) do
    reasons =
      Enum.map(empty, fn {role, _none} ->
        "nothing satisfies #{role.name}: " <> nearest_misses(role, pool)
      end)

    Infeasible.new(session.name, reasons)
  end

  defp nearest_misses(_role, []), do: "the pool is empty"

  defp nearest_misses(role, pool) do
    pool
    |> Enum.map(fn resource -> "#{resource.name} (#{miss(role, resource)})" end)
    |> Enum.take(3)
    |> Enum.join(", ")
  end

  defp miss(role, resource) do
    role |> Requirement.unmet(resource) |> Enum.join(", ")
  end

  # --- stages 2 and 3: availability and co-availability -----------

  # Everyone involved must be free simultaneously, so their free sets
  # intersect. Each resource's free time is tagged with its own name
  # and the intersection accumulates those tags, so a surviving window
  # states which resources produced it — `Tempo.IntervalSet.slots/3`
  # then carries that through to every placement. An empty list
  # imposes no constraint, which is `base` unchanged.
  defp co_free(resources, base, window, options) do
    with {:ok, sets} <- tagged_free(resources, window, options) do
      Tempo.intersection(base, sets, metadata: {:merge, &accumulate/2})
    end
  end

  defp accumulate(a, b), do: Map.merge(a, b, fn _key, x, y -> x ++ y end)

  defp tagged_free(resources, window, options) do
    Enum.reduce_while(resources, {:ok, []}, fn resource, {:ok, acc} ->
      case free_within(resource, window, options) do
        {:ok, free} -> {:cont, {:ok, acc ++ [tag(free, resource)]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp tag(free, resource) do
    free
    |> IntervalSet.to_list()
    |> Enum.map(&%{&1 | metadata: %{free: [resource.name]}})
    |> IntervalSet.new!()
  end

  defp free_within(resource, window, options) do
    busy =
      options
      |> Keyword.get(:busy, %{})
      |> Map.get(resource.name, [])

    Availability.free(resource, within: window, busy: busy)
  end

  # --- stage 4: slotting ------------------------------------------

  # An empty result and a failure are different answers. A combination
  # with nowhere to go contributes no placements, and the session may
  # still be held some other way; a resource whose *configuration* will
  # not compute — an unparseable buffer, a malformed `:busy` value —
  # is a defect, and every combination will hit it. Reporting the
  # second as though it were the first is what turns a typo into "no
  # window is long enough with everyone free", which sends the caller
  # looking at their calendar instead of at their code.
  defp arrangements(session, candidates, roster_free, window, duration, options) do
    candidates
    |> combinations()
    |> Enum.reduce_while({:ok, []}, fn combination, {:ok, acc} ->
      case placements(session, combination, roster_free, window, duration, options) do
        {:ok, placements} -> {:cont, {:ok, acc ++ placements}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # One resource per open role: the cartesian product across roles.
  # With the usual single role this is just the candidate list.
  defp combinations([]), do: [%{}]

  defp combinations([{role, eligible} | rest]) do
    for choice <- eligible, tail <- combinations(rest), do: Map.put(tail, role.name, [choice])
  end

  defp rosters_of(%Session{} = session) do
    session
    |> Session.rosters()
    |> Map.new(fn requirement -> {requirement.name, requirement.roster} end)
  end

  # The chosen resources must be free too, on top of the roster's
  # mutual free time — the same co-availability question, so the same
  # function answers it.
  defp placements(session, allocation, roster_free, window, duration, options) do
    chosen = allocation |> Map.values() |> List.flatten()

    case co_free(chosen, roster_free, window, options) do
      {:ok, free} -> {:ok, slots(session, allocation, free, duration, options)}
      {:error, _reason} = error -> error
    end
  end

  # The arrangement records the named resources alongside the chosen
  # ones. A roster member is as allocated as a chosen room — it occupies
  # that person, that site — so omitting them would let the ledger
  # double-book someone the session had explicitly reserved. Their
  # availability is already folded into `free` via the roster
  # intersection, which is why they are merged only here.
  defp slots(session, allocation, free, duration, options) do
    allocations = Map.merge(allocation, rosters_of(session))

    free
    |> IntervalSet.slots(duration, every: step(duration, allocations, options))
    |> IntervalSet.to_list()
    |> Enum.map(fn interval ->
      %Arrangement{
        session: session.name,
        interval: interval,
        allocations: allocations,
        score: 0,
        series: session.series
      }
    end)
  end

  # Candidate start times step by the session's own length, which packs
  # a free stretch end to end. That is right until a resource needs
  # turnaround between uses: a forty-minute talk in a room wanting ten
  # minutes to reset cannot start every forty minutes, and offering
  # only those starts leaves the search choosing between a clash and
  # skipping a whole slot.
  #
  # Stepping by length *plus* turnaround offers the starts that
  # actually work — 9:00, 9:50, 10:40 rather than 9:00, 9:40, 10:20.
  # Only `Agenda.Arranger.arrange/3` asks for this: a caller planning
  # one session needs no gap from itself, and narrowing their options
  # would be an answer to a question they did not ask.
  defp step(duration, allocations, options) do
    if Keyword.get(options, :turnaround, false) do
      widen(duration, longest_turnaround(allocations))
    else
      duration
    end
  end

  defp longest_turnaround(allocations) do
    allocations
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(fn %Resource{} = resource ->
      Enum.reject([resource.buffer_before, resource.buffer_after], &is_nil/1)
    end)
    |> case do
      [] -> nil
      buffers -> Enum.max(buffers, Duration)
    end
  end

  defp widen(duration, nil), do: duration

  defp widen(duration, turnaround), do: Duration.add(duration, turnaround)

  # --- stage 4b: load limits --------------------------------------

  # A placement that would take a resource past one of its `:limits` is
  # not a placement, and leaving it in the list is how an incremental
  # caller books a twelfth meeting for somebody capped at eight.
  #
  # Unlike every other check here, a limit cannot be answered from the
  # placement alone: it is measured over a period rather than an
  # instant, so it needs to know what the resource is *already* doing.
  # That is what `:busy` carries, and without it there is nothing to
  # count and every placement stands — which is why `Agenda.Arranger`
  # still has to check limits itself as it places.
  defp within_limits(placements, options) do
    case Keyword.get(options, :busy, %{}) do
      busy when is_map(busy) and map_size(busy) > 0 ->
        Enum.filter(placements, &permitted?(&1, busy))

      _nothing_claimed ->
        placements
    end
  end

  defp permitted?(%Arrangement{} = arrangement, busy) do
    Enum.all?(Arrangement.resources(arrangement), fn resource ->
      Enum.all?(resource.limits, &fits?(&1, arrangement, claimed(busy, resource.name)))
    end)
  end

  defp fits?(%Limit{} = limit, %Arrangement{} = arrangement, held) do
    bucket = Limit.bucket(arrangement.interval.from, limit.period)

    same_period =
      Enum.filter(held, fn claim ->
        case moment(claim) do
          nil -> false
          from -> Limit.bucket(from, limit.period) == bucket
        end
      end)

    {count, duration} = Limit.sum([arrangement.interval | same_period])
    Limit.permits?(limit, count, duration)
  end

  defp claimed(busy, name) do
    case Map.get(busy, name) do
      nil -> []
      %IntervalSet{} = set -> IntervalSet.to_list(set)
      claims when is_list(claims) -> claims
      one -> [one]
    end
  end

  # An allocation carries its interval; an interval is its own.
  defp moment(%{interval: %{from: from}}), do: from
  defp moment(%{from: from}), do: from
  defp moment(_unreadable), do: nil

  # --- stage 5: ranking -------------------------------------------

  defp ranked([], session, _options) do
    {:error, Infeasible.new(session.name, ["no window is long enough with everyone free"])}
  end

  defp ranked(arrangements, session, options) do
    limit = Keyword.get(options, :limit, @default_limit)
    invited = attendance(session, options)

    scored =
      arrangements
      |> Enum.map(&attended(&1, invited))
      |> Enum.map(&%{&1 | score: &1.score + score(&1, session.preferences)})
      |> Enum.sort(&better?/2)
      |> take(limit, Keyword.get(options, :spread, false))

    {:ok, scored}
  end

  # --- optional participants ---------------------------------------

  # `Agenda.Session.invite/3` names people who may come but need not.
  # They are scored, never required: a time more of them can make is a
  # better time, and a time none of them can make is still a time.
  #
  # Their free sets are computed once for the whole window rather than
  # per candidate, because a session with forty candidate placements
  # and six invitees would otherwise ask the same question 240 times.
  defp attendance(%Session{invitees: []}, _options), do: %{}

  defp attendance(%Session{} = session, options) do
    case Availability.normalise(session.window) do
      {:ok, window} ->
        Map.new(session.invitees, fn {role, resources} ->
          {role, Enum.map(resources, &{&1, free_or_nothing(&1, window, options)})}
        end)

      {:error, _unreadable} ->
        %{}
    end
  end

  defp free_or_nothing(resource, window, options) do
    case free_within(resource, window, options) do
      {:ok, free} -> free
      {:error, _reason} -> IntervalSet.new!([])
    end
  end

  defp attended(%Arrangement{} = arrangement, invited) when map_size(invited) == 0 do
    arrangement
  end

  defp attended(%Arrangement{} = arrangement, invited) do
    available =
      Map.new(invited, fn {role, pairs} ->
        free_now =
          for {resource, free} <- pairs,
              free_throughout?(free, arrangement.interval),
              do: resource

        {role, free_now}
      end)

    count = available |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

    %{arrangement | attending: available, score: arrangement.score + count}
  end

  # Free for the *whole* interval. Somebody who can make half a meeting
  # cannot make the meeting, so a partial overlap counts for nothing.
  defp free_throughout?(free, interval) do
    case Tempo.difference(interval, free) do
      {:ok, remainder} -> IntervalSet.count(remainder) == 0
      {:error, _reason} -> false
    end
  end

  # Truncating a ranked list takes a *prefix*, and for a session with no
  # preferences the ranking is chronological — so the best twenty
  # placements across ten rooms are twenty of the earliest two hours,
  # and the rest of the day is never offered. That is the right answer
  # when a person is choosing one meeting time and the wrong one when a
  # search needs many sessions to go in different slots: they are all
  # handed the same narrow window and fight over it.
  #
  # Spreading takes the same number of placements but round-robins them
  # across distinct start moments, so the cap buys coverage of the whole
  # window instead of depth at the front of it. The result is sorted
  # back into rank order, because the search should still try the better
  # placements first.
  defp take(scored, limit, false), do: Enum.take(scored, limit)

  defp take(scored, limit, true) when length(scored) <= limit, do: scored

  defp take(scored, limit, true) do
    scored
    |> Enum.group_by(&Compare.to_utc_seconds(&1.interval.from))
    |> Enum.sort_by(fn {moment, _group} -> moment end)
    |> Enum.map(fn {_moment, group} -> group end)
    |> across(limit)
    |> round_robin([])
    |> Enum.take(limit)
    |> Enum.sort(&better?/2)
  end

  # Which *moments* to offer when there are more of them than the cap
  # allows. Taking the first `limit` of them would cover the front of
  # the window, which is the depth-over-coverage trade `:spread` exists
  # to avoid — on a two-day show it offers the whole of day one and
  # nothing of day two, and a resource limited per day is then held to
  # a single day's worth of placements.
  #
  # Striding instead gives an even sample of the window. `div(index *
  # limit, count)` walks 0..limit-1 in contiguous runs as `index` walks
  # the moments, so keeping the first of each run keeps exactly `limit`
  # moments, evenly spaced, in order.
  defp across(buckets, limit) when length(buckets) <= limit, do: buckets

  defp across(buckets, limit) do
    count = length(buckets)

    buckets
    |> Enum.with_index()
    |> Enum.uniq_by(fn {_bucket, index} -> div(index * limit, count) end)
    |> Enum.map(fn {bucket, _index} -> bucket end)
  end

  # One from each bucket in turn, until every bucket is empty. Each
  # round is *appended* to what came before: rounds are complete passes
  # across the window, so putting a later round first would hand a
  # truncated caller the tail of the window instead of a spread of it.
  defp round_robin([], taken), do: Enum.reverse(taken)

  defp round_robin(buckets, taken) do
    {heads, rest} =
      Enum.reduce(buckets, {[], []}, fn
        [head | tail], {heads, rest} ->
          {[head | heads], (tail == [] && rest) || [tail | rest]}
      end)

    round_robin(Enum.reverse(rest), heads ++ taken)
  end

  # Best score first, then earliest. Times must be compared
  # chronologically, never as their ISO strings — lexicographically
  # "10:00" sorts before "9:00".
  defp better?(%Arrangement{score: same} = a, %Arrangement{score: same} = b) do
    Compare.compare_endpoints(a.interval.from, b.interval.from) in [:earlier, :same]
  end

  defp better?(%Arrangement{} = a, %Arrangement{} = b), do: a.score > b.score

  defp score(%Arrangement{} = arrangement, preferences) do
    resources = Arrangement.resources(arrangement)

    Enum.count(
      for preference <- preferences, resource <- resources, prefers?(resource, preference) do
        :match
      end
    )
  end

  defp prefers?(%Resource{} = resource, {:within, %Place{} = place}) do
    Resource.within?(resource, place)
  end

  defp prefers?(%Resource{} = resource, {key, value}) do
    Resource.attribute(resource, key) == value
  end
end
