defmodule Agenda.Arranger do
  @moduledoc """
  Laying out a whole programme — a placement for every session, with
  nothing clashing.

  This is a **search**, not an enumeration, and that is the difference
  between it and `Agenda.Planner.plan/3`. Planning lists the ways
  one session could be held; arranging must choose one placement per
  session such that every choice is still compatible with every other.
  A room taken by the keynote is gone for the workshop.

  Three constraints hold a programme together:

  * **No resource is in two places at once.** Two placements sharing a
    resource must not overlap — and must be separated by that
    resource's `buffer_before`/`buffer_after` turnaround, if it needs
    any, whether the neighbour is another session in this programme or
    a booking that already existed.

  * **A track cannot clash with itself.** Sessions sharing an audience
    must not overlap, which is what makes a track a track.

  * **Consecutive track sessions must be reachable.** The gap between
    them must be at least the journey between their rooms — derived
    from the place tree, not configured.

  ### Placing what fits, when not everything does

  By default one unplaceable session fails the programme, which is the
  right answer when the programme is a unit. When it is a wish list,
  `unplaced: :allow` asks instead for the **fewest** sessions left out:

      {:partial, layout} = arrange(programme, pool, unplaced: :allow)

  The result is a `t:Agenda.Layout.t/0` under a `:partial` tag,
  never `{:ok, …}` — a partial programme presented as finished is worse
  than an admitted failure, but a partial programme *labelled* as
  partial is better than no answer at all.

  That search is branch-and-bound, which makes it **anytime**: the
  first complete layout is found immediately and later ones only
  improve on it, so exhausting the node cap returns the best layout so
  far rather than nothing. `Agenda.Layout`'s `minimal?` says which
  you have. A relaxation bound — what the resources could hold at
  best — lets the search stop as soon as it matches, so a badly
  overbooked programme is cheaper to answer than a marginal one.

  ### Preferring one workable layout over another

  Every constraint above is hard. A `Agenda.Preference` is soft: it
  never makes a layout invalid, only worse. Declaring one changes what
  `arrange/3` returns among the answers that were always allowed.

      {:ok, programme} = Agenda.prefer(programme, :room_changes, weight: 10)

  Optimisation is **lexicographic and two-pass**. The first pass
  ignores preferences and proves how many sessions can be placed. The
  second takes that number as a hard ceiling and looks only for a
  better-scoring layout that places exactly as many — so a preference
  can never cost a placement, and `Agenda.Layout`'s `minimal?`
  means what it always meant.

  What is *not* promised is soft optimality: the scoring pass has its
  own `:score_nodes` budget and stops when it runs out, which
  `score_proven?` reports. Proving a weighted optimum needs a bound on
  remaining cost that this search has no cheap way to compute, and a
  programme that genuinely needs one wants a solver.

  ### Holding placements still

  A published programme gets edited, and the edit must not move the
  keynote that has already been announced. `:pinned` fixes chosen
  placements and searches around them; every constraint still applies
  to a pin, so the sessions that move must work with the ones that
  cannot.

  ### Scale, and where this stops

  The search is depth-first with backtracking, ordered most-constrained
  first, and bounded by an explicit node cap. Two things decide how far
  it reaches.

  **Sessions that cannot constrain each other are solved apart.** A
  shared resource, a shared track or a precedence is what carries a
  constraint between two sessions; without one of those they are
  independent, and searching them together costs the product of their
  choices where it should cost the sum. A conference whose days share
  no room splits into one subproblem per day. This is exact — the
  components are disjoint, so no layout is lost and `minimal?` still
  means proven.

  **The caps scale with the programme.** Interchangeable sessions
  receive the same ranked candidates, so a `:candidates` cap below the
  session count makes a satisfiable programme unsatisfiable, and the
  work per session grows with the programme, so a fixed `:nodes` cap
  does the same. Both now grow with the session count, and the
  placements offered are spread across the window rather than taken
  from the front of it. A fixed cap of either kind does not narrow the
  search — it reports a workable programme as impossible.

  **Independent work is done at the same time.** Enumerating one
  session's placements cannot affect another's, and neither can
  searching two disjoint components, so both are spread across
  `:concurrency` processes. Order is preserved, so the answer does not
  depend on which scheduler finished first.

  What that adds up to on defaults: 1,200 sessions across twenty days
  lay out in under three seconds, 240 across six days in about four
  hundred milliseconds, and 200 competing for a *single* day — one
  component, so nothing to divide — in about five seconds. The shape of
  the programme matters more than its size: sessions that cannot
  interact are nearly free, and sessions that all compete for the same
  rooms are the real cost. Saying "no" stays fast either way, since an
  impossible programme is cut off by the relaxation bound long before
  any cap. Past that, or for a university timetable of thousands of
  classes, the answer is still a real constraint solver, and the way to
  use one here is to write its output back through
  `Agenda.Ledger.allocate/2`, which stays authoritative either way.

  When a cap is reached the result says so rather than returning a
  partial layout as though it were complete, and says *which* cap —
  running out of nodes and running out of placements need opposite
  responses from the caller.

  """

  import Tempo.Sigils

  alias Agenda.Arrangement
  alias Agenda.Availability
  alias Agenda.Conflict
  alias Agenda.Infeasible
  alias Agenda.Layout
  alias Agenda.Limit
  alias Agenda.Planner
  alias Agenda.Precedence
  alias Agenda.Preference
  alias Agenda.Programme
  alias Agenda.Resource
  alias Agenda.Session
  alias Agenda.Track
  alias Tempo.Compare
  alias Tempo.Duration
  alias Tempo.Interval

  @default_nodes 10_000

  # How much the node cap grows per session once a programme is large
  # enough to need more than the floor. Measured rather than guessed:
  # the search needs roughly 33 nodes per session at sixty sessions and
  # 156 at a hundred and sixty, so the requirement grows with the
  # programme and a fixed cap turns into a false "impossible" exactly
  # as the fixed candidate cap did. This leaves about double the
  # measured need.
  #
  # A larger cap costs nothing on a programme that succeeds — the
  # search stops when it finds a layout, and the cap only bounds how
  # long it will look before admitting defeat. What it does buy is a
  # slower answer on a genuinely impossible programme, which is the
  # right way round: being told "no" late is better than being told
  # "no" wrongly.
  @nodes_per_session 250

  # No component is searched with less than this, however small its
  # share works out. A floor costs little — a small component that
  # succeeds stops long before spending it.
  @minimum_component_nodes 2_000

  # Below this many items, spawning costs more than it saves — but
  # "worth it" depends on the item. Enumerating one session's
  # placements is milliseconds, so a handful of them is not worth
  # distributing; searching one component is a substantial fraction of
  # the whole call, so even two are.
  @parallel_enumeration 8
  @parallel_components 2

  # The floor, not the answer. Interchangeable sessions are offered the
  # *same* ranked candidate list, so a programme of N such sessions
  # needs at least N distinct placements between them or it is
  # unsatisfiable however long the search runs — the enumeration, not
  # the programme, is what has no solution. Scaling the cap with the
  # session count is what keeps that failure from being reachable by
  # accident; `@candidate_headroom` leaves room for the placements lost
  # to sessions that are *not* interchangeable.
  @default_candidates 40
  @candidate_headroom 10

  # The scoring pass is capped far lower than the counting pass. It is
  # looking for a nicer answer, not a correct one, and every node it
  # spends is latency a caller pays for cosmetics. Raise it with
  # `:score_nodes` when the layout matters more than the wait.
  @default_score_nodes 2_000

  @typedoc "The outcome of arranging a programme."
  @type result ::
          {:ok, [Arrangement.t()]}
          | {:partial, Layout.t()}
          | {:error, Infeasible.t()}

  @doc """
  Find a placement for every session in `programme`.

  ### Arguments

  * `programme` is a `t:Agenda.Programme.t/0`.

  * `pool` is the list of `t:Agenda.Resource.t/0` to choose from.

  ### Options

  * `:busy` is a map of resource name to what already claims it, as
    `Agenda.Ledger.busy/2` returns. The default is `%{}`. It must
    not include the claims of `:pinned` sessions — those are added for
    you, so pass `Agenda.Ledger.busy/2` the pinned session names as
    `:except`.

  * `:pinned` is a list of `t:Agenda.Arrangement.t/0` whose
    placements are fixed. Those sessions are not searched for, every
    constraint still applies to them, and they are returned alongside
    the sessions that were placed. The default is `[]`.

  * `:unplaced` decides what happens when a session cannot be held —
    `:error` (the default) fails the whole programme, `:allow` leaves
    out as few sessions as the search can manage and returns
    `{:partial, layout}`.

  * `:candidates` caps how many placements are considered per session.
    The default scales with the programme — `40`, or ten more than the
    number of sessions, whichever is larger. Interchangeable sessions
    are offered the same ranked placements, so a cap below the session
    count makes a satisfiable programme unsatisfiable.

  * `:nodes` caps how many search steps are taken across the whole
    call, including every round of the `unplaced: :allow` search and
    every independent subproblem the programme splits into. The default
    scales with the programme — `10_000`, or 250 per session, whichever
    is larger — because the work per session grows with the programme
    and a fixed cap reports a satisfiable one as impossible.

  * `:concurrency` is how many processes may work at once, defaulting
    to `System.schedulers_online/0`. Candidate enumeration and
    independent subproblems are both spread across them. Pass `1` to
    stay on the calling process — what you want when the caller already
    runs this inside a pool of its own. The answer does not depend on
    it: results are collected in order, so the same programme arranges
    the same way at any setting.

  * `:travel` is passed to `Agenda.travel_time/3` for the
    reachability check — use it to supply per-pair overrides.

  ### Returns

  * `{:ok, arrangements}` — one per session, mutually consistent, in
    programme order; or

  * `{:partial, t:Agenda.Layout.t/0}` under `unplaced: :allow`, when
    some sessions could not be held; or

  * `{:error, t:Agenda.Infeasible.t/0}` naming the session that
    could not be placed, reporting a bad pin, or reporting that the cap
    was hit.

  ### Examples

      iex> room = Agenda.resource("Hall", seats: 100)
      iex> {:ok, room} = Agenda.open(room, "2026-09-15T09:00:00/2026-09-15T12:00:00")
      iex> talk = fn name ->
      ...>   Agenda.session(name, duration: "PT1H", window: "2026-09-15/2026-09-16")
      ...>   |> Agenda.Session.needs(:room, seats: 100)
      ...> end
      iex> programme =
      ...>   Agenda.programme("Conf")
      ...>   |> Agenda.Programme.add_track(
      ...>        Agenda.track("Elixir", of: [talk.("Keynote"), talk.("Deep dive")]))
      iex> {:ok, arrangements} = Agenda.Arranger.arrange(programme, [room])
      iex> Enum.map(arrangements, & &1.session)
      ["Keynote", "Deep dive"]

  """
  @spec arrange(Programme.t(), [Resource.t()], keyword()) :: result()
  def arrange(%Programme{} = programme, pool, options \\ []) when is_list(pool) do
    with {:ok, programme} <- with_readable_tracks(programme),
         {:ok, pinned} <- pins(programme, options) do
      options = Keyword.put(options, :busy, busy_including(pinned, options))
      {candidates, unplaceable} = candidates_per_session(programme, pool, pinned, options)

      candidates
      |> Enum.sort_by(&search_order(&1, programme))
      |> decompose(programme, pinned, unplaceable, options)
    end
  end

  @doc """
  The smallest set of sessions in `programme` that cannot all be held.

  This is the diagnostic to reach for when `arrange/3` fails. A failure
  names *a* session that could not be placed; this names the group that
  is actually in tension, so that the answer is "any two of these three
  fit — choose which one moves" rather than "no arrangement found".

  It works by arranging smaller and smaller parts of the programme, so
  it costs a number of arrangements logarithmic in the programme's
  size. Run it on failure, not on every call.

  Pinned sessions form the background: they are never named as part of
  a conflict, because they are not free to move. If the pins alone
  cannot be arranged the result is `{:ok, []}`, which says exactly
  that.

  ### Arguments

  * `programme` is a `t:Agenda.Programme.t/0`.

  * `pool` is the list of `t:Agenda.Resource.t/0` to choose from.

  ### Options

  Takes the same options as `arrange/3`. `:unplaced` is ignored — a
  conflict is only meaningful against the all-or-nothing question.

  ### Returns

  * `:none` when the whole programme can be arranged and there is
    nothing to explain; or

  * `{:ok, session_names}` — a minimal set of sessions that cannot all
    be held. Removing any one of them leaves a set that can.

  ### Examples

      iex> room = Agenda.resource("Hall", seats: 100)
      iex> {:ok, room} = Agenda.open(room, "2026-09-15T09:00:00/2026-09-15T10:00:00")
      iex> talk = fn name ->
      ...>   Agenda.session(name, duration: "PT1H", window: "2026-09-15/2026-09-16")
      ...>   |> Agenda.Session.needs(:room, seats: 100)
      ...> end
      iex> programme =
      ...>   Agenda.programme("Conf")
      ...>   |> Agenda.Programme.add_session(talk.("Keynote"))
      ...>   |> Agenda.Programme.add_session(talk.("Deep dive"))
      iex> Agenda.Arranger.conflict(programme, [room])
      {:ok, ["Keynote", "Deep dive"]}

  """
  @spec conflict(Programme.t(), [Resource.t()], keyword()) :: {:ok, [String.t()]} | :none
  def conflict(%Programme{} = programme, pool, options \\ []) when is_list(pool) do
    options = Keyword.put(options, :unplaced, :error)
    fixed = options |> Keyword.get(:pinned, []) |> Enum.map(& &1.session)
    free = programme |> Programme.all_sessions() |> Enum.map(& &1.name) |> Kernel.--(fixed)

    Conflict.minimal(free, fixed, fn names ->
      match?({:ok, _placed}, arrange(Programme.restrict_to(programme, names), pool, options))
    end)
  end

  # --- reachability durations -------------------------------------

  # `Agenda.Track.reachable/2` takes any availability pattern, so a
  # track can carry `"PT5M"` as readily as `~o"PT5M"`. The search
  # compares it by shifting a point, which needs the parsed duration —
  # so it is resolved once here, and an unreadable one is an error
  # tuple rather than a crash six frames into the search.
  @doc """
  Resolve a programme's track reachability durations once.

  `Agenda.Track.reachable/2` accepts a duration written as a string,
  and the search compares durations thousands of times, so the pattern
  is read once here rather than re-parsed per comparison. `arrange/3`
  does this for itself; another solver building on
  `conflict?/4` must do it too, or a string will reach the comparison
  as a `FunctionClauseError` several frames down.

  ### Arguments

  * `programme` is a `t:Agenda.Programme.t/0`.

  ### Returns

  * `{:ok, programme}` with every track's reach resolved; or

  * `{:error, t:Agenda.Infeasible.t/0}` when one is not a duration.

  ### Examples

      iex> {:ok, programme} = Agenda.Arranger.readable(Agenda.programme("Conf"))
      iex> programme.tracks
      []

  """
  @spec readable(Programme.t()) :: {:ok, Programme.t()} | {:error, Infeasible.t()}
  def readable(%Programme{} = programme), do: with_readable_tracks(programme)

  defp with_readable_tracks(%Programme{} = programme) do
    with {:ok, programme} <- with_readable_precedences(programme) do
      readable_reaches(programme)
    end
  end

  # Precedence gaps go the same way as track reach, and for the same
  # reason: the search compares them thousands of times, so a string
  # is read once here rather than reaching `Tempo.shift/2` as a
  # `FunctionClauseError` several frames down.
  defp with_readable_precedences(%Programme{} = programme) do
    programme.precedences
    |> Enum.reduce_while({:ok, []}, fn precedence, {:ok, acc} ->
      case readable_spans(precedence) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:error, reason} -> {:halt, {:error, Infeasible.new(programme.name, [reason])}}
      end
    end)
    |> case do
      {:ok, precedences} -> {:ok, %{programme | precedences: precedences}}
      {:error, _reason} = error -> error
    end
  end

  defp readable_spans(%Precedence{} = precedence) do
    with {:ok, gap} <- readable_span(precedence.gap, precedence, "gap"),
         {:ok, within} <- readable_span(precedence.within, precedence, "within") do
      {:ok, %{precedence | gap: gap, within: within}}
    end
  end

  defp readable_span(nil, _precedence, _label), do: {:ok, nil}

  defp readable_span(pattern, %Precedence{} = precedence, label) do
    case Availability.normalise(pattern) do
      {:ok, %Duration{} = duration} ->
        {:ok, duration}

      _not_a_duration ->
        {:error,
         "#{precedence.first} precedes #{precedence.then} with a #{label} of " <>
           "#{inspect(pattern)}, which is not a duration"}
    end
  end

  defp readable_reaches(%Programme{} = programme) do
    programme.tracks
    |> Enum.reduce_while({:ok, []}, fn track, {:ok, acc} ->
      case readable_reach(track) do
        {:ok, track} -> {:cont, {:ok, acc ++ [track]}}
        {:error, reason} -> {:halt, {:error, Infeasible.new(programme.name, [reason])}}
      end
    end)
    |> case do
      {:ok, tracks} -> {:ok, %{programme | tracks: tracks}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp readable_reach(%Track{reachable_within: nil} = track), do: {:ok, track}

  defp readable_reach(%Track{reachable_within: within} = track) do
    case Availability.normalise(within) do
      {:ok, %Duration{} = duration} ->
        {:ok, %{track | reachable_within: duration}}

      _not_a_duration ->
        {:error,
         "the #{track.name} track is reachable within #{inspect(within)}, which is not a duration"}
    end
  end

  # --- pins --------------------------------------------------------

  # A pin is only useful if it is honoured, so a pin that cannot be is
  # an error rather than something quietly dropped. Three ways it can
  # be wrong: it names a session the programme does not have, it is one
  # of two pins for the same session, or it clashes with another pin.
  defp pins(programme, options) do
    pinned = Keyword.get(options, :pinned, [])
    known = programme |> Programme.all_sessions() |> MapSet.new(& &1.name)

    with :ok <- all_known(pinned, known, programme),
         :ok <- one_per_session(pinned, programme) do
      pins_agree(pinned, programme, options)
    end
  end

  defp all_known(pinned, known, programme) do
    case Enum.reject(pinned, &MapSet.member?(known, &1.session)) do
      [] ->
        :ok

      strangers ->
        {:error,
         Infeasible.new(
           programme.name,
           Enum.map(strangers, &"#{&1.session} is pinned but is not in the programme")
         )}
    end
  end

  defp one_per_session(pinned, programme) do
    pinned
    |> Enum.frequencies_by(& &1.session)
    |> Enum.filter(fn {_session, count} -> count > 1 end)
    |> case do
      [] ->
        :ok

      repeated ->
        {:error,
         Infeasible.new(
           programme.name,
           Enum.map(repeated, fn {session, count} ->
             "#{session} is pinned #{count} times — a session can hold only one placement"
           end)
         )}
    end
  end

  # Pins are checked against each other with the same rules the search
  # applies, so an impossible set is reported before any work is done.
  defp pins_agree(pinned, programme, options) do
    Enum.reduce_while(pinned, {:ok, []}, fn pin, {:ok, settled} ->
      if compatible?(pin, settled, programme, options) do
        {:cont, {:ok, [{pin, exempt(pin)} | settled]}}
      else
        {:halt,
         {:error,
          Infeasible.new(programme.name, [
            "#{pin.session} is pinned to a placement that clashes with another pin"
          ])}}
      end
    end)
    |> case do
      {:ok, settled} -> {:ok, settled |> Enum.reverse() |> Enum.map(&elem(&1, 0))}
      {:error, reason} -> {:error, reason}
    end
  end

  # A pinned placement occupies its resources for everyone else, so it
  # belongs in `:busy` before candidates are generated. Without this the
  # `:candidates` cap could fill with placements that all clash with a
  # pin, and a perfectly placeable session would look impossible.
  defp busy_including(pinned, options) do
    Enum.reduce(pinned, Keyword.get(options, :busy, %{}), fn arrangement, busy ->
      arrangement
      |> Arrangement.resources()
      |> Enum.reduce(busy, fn resource, acc ->
        Map.update(acc, resource.name, [arrangement.interval], &(&1 ++ [arrangement.interval]))
      end)
    end)
  end

  # Most-constrained-first, by domain size — a session with three
  # placements is settled before one with three hundred, because
  # discovering it cannot fit is cheaper near the root.
  #
  # Domain size alone is not the whole story once a precedence is
  # involved. A precedence says nothing until *both* its sessions are
  # placed: whichever comes first is unconstrained, so the search fixes
  # it anywhere, and only on reaching the partner — perhaps forty
  # sessions later — discovers the pair cannot work and unwinds the
  # whole subtree. Placing both ends early, and next to each other,
  # makes the constraint bite at the top of the tree where it prunes
  # instead of at the bottom where it only rejects.
  defp search_order({session, _symmetry, placements}, %Programme{} = programme) do
    {(ordered?(session, programme) && 0) || 1, length(placements)}
  end

  # --- candidate placements, one session at a time ----------------

  defp candidates_per_session(programme, pool, pinned, options) do
    fixed = MapSet.new(pinned, & &1.session)

    free =
      programme
      |> Programme.all_sessions()
      |> Enum.reject(&MapSet.member?(fixed, &1.name))

    limit = candidate_limit(length(free), options)

    # Enumerating one session's placements cannot affect another's —
    # each is a fresh question about the same unchanging pool — so this
    # is the one part of the call that parallelises without any
    # argument about correctness. It is worth doing: enumeration is
    # about a quarter of a large `arrange/3`, and it is the quarter
    # that a single component cannot otherwise share out.
    free
    |> in_parallel(
      fn session ->
        {session, placements_for(session, programme, pool, options, limit)}
      end,
      options,
      @parallel_enumeration
    )
    |> Enum.reduce({[], []}, fn
      {session, {:ok, placements}}, {candidates, unplaceable} ->
        {candidates ++ [{session, symmetry_of(session, programme), placements}], unplaceable}

      {_session, {:error, reason}}, {candidates, unplaceable} ->
        {candidates, unplaceable ++ [reason]}
    end)
  end

  # `ordered: true` is not incidental. The results feed a search whose
  # answer depends on the order it considers things, so arranging the
  # same programme twice must give the same layout — a scheduler that
  # returned a different-but-equally-valid answer on every call would
  # be untestable and unnerving to use.
  #
  # Below the threshold the spawn costs more than the work saved, and
  # `concurrency: 1` opts out entirely, which a caller already running
  # this inside a pool of their own will want.
  defp in_parallel(items, fun, options, threshold) do
    concurrency = concurrency(options)

    if concurrency > 1 and length(items) >= threshold do
      items
      |> Task.async_stream(fun,
        max_concurrency: concurrency,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)
    else
      Enum.map(items, fun)
    end
  end

  # Per call first, then application config, then one process per
  # scheduler. The middle rung is what lets an application that runs
  # this inside its own pool set the policy once rather than at every
  # call site.
  defp concurrency(options) do
    Keyword.get(options, :concurrency) ||
      Application.get_env(:agenda, :concurrency) ||
      System.schedulers_online()
  end

  # An explicit `:candidates` is taken at face value — a caller who
  # names a number has a reason, and second-guessing it would make the
  # option useless for narrowing a search deliberately.
  defp candidate_limit(session_count, options) do
    Keyword.get(options, :candidates) ||
      max(@default_candidates, session_count + @candidate_headroom)
  end

  # Two sessions are interchangeable when nothing distinguishes them
  # but their name: same track, same length, same window, same
  # requirements. Anything that makes them different — a different
  # room requirement, a different day — gives them different keys and
  # exempts them from the ordering rule below.
  defp symmetry_of(session, programme) do
    if ordered?(session, programme) do
      # A session in a precedence is interchangeable with nothing. The
      # symmetry rules impose a canonical chronological order on
      # look-alike sessions, which is sound only while relabelling them
      # loses no solution — and an ordering says exactly which of the
      # two comes first. Left in the same group, "A must finish before
      # B" and "the later-declared must not start earlier" contradict
      # each other and a perfectly feasible job is reported impossible.
      {:ordered, session.name}
    else
      track = Programme.track_of(programme, session.name)

      {track && track.name, session.duration, session.window, session.requirements}
    end
  end

  defp ordered?(_session, %Programme{precedences: []}), do: false

  defp ordered?(session, %Programme{precedences: precedences}) do
    Enum.any?(precedences, &(&1.first == session.name or &1.then == session.name))
  end

  # A pinned placement is interchangeable with nothing: its time is
  # fixed, so it cannot be relabelled and must sit outside every
  # symmetry rule.
  defp exempt(%Arrangement{session: session}), do: {:pinned, session}

  defp placements_for(session, programme, pool, options, limit) do
    session = bounded_by(session, programme)

    plan_options =
      options
      |> Keyword.take([:busy])
      |> Keyword.put(:limit, limit)
      |> Keyword.put(:spread, true)
      |> Keyword.put(:turnaround, true)

    Planner.plan(session, pool, plan_options)
  end

  # A session inherits the programme's window unless it states its own.
  defp bounded_by(%{window: nil} = session, %Programme{window: window}),
    do: %{session | window: window}

  defp bounded_by(session, _programme), do: session

  # --- how many sessions may be left out --------------------------

  # --- independent subproblems ------------------------------------

  # Two sessions constrain each other only if something can carry a
  # constraint between them: a shared resource, a shared track, or a
  # precedence. Sessions with none of those cannot affect each other's
  # placement at all, so solving them together only means searching
  # their choices as one combined space — the cost is the product of
  # the parts where it should be the sum. A two-day conference whose
  # days share no room splits in two for free.
  #
  # This is exact. Nothing is approximated and no layout is lost; the
  # components are genuinely disjoint, so the minimum for the whole is
  # the sum of the minima and `minimal?` survives.
  #
  # Preferences are the exception, and the reason for the guard below:
  # `:room_spread` and friends score a layout as a whole, so a
  # component that scores well alone may not be part of the best
  # scoring layout overall. Where preferences are declared the
  # programme is solved in one piece, as before.
  defp decompose(candidates, programme, pinned, unplaceable, options) do
    options = Keyword.put(options, :nodes, node_budget(length(candidates), options))

    candidates
    |> components(programme, unplaceable)
    |> solve_components(candidates, programme, pinned, unplaceable, options)
  end

  # Three cases keep the whole programme together, and each is about
  # correctness rather than cost:
  #
  #   * **Preferences** score a layout as a whole, so a component that
  #     scores well alone need not belong to the best layout overall.
  #
  #   * **An unplaceable session** never reaches `candidates` at all —
  #     it is already known to have nowhere to go. Whether that makes
  #     the programme fail or merely makes the layout partial is a
  #     question about the programme, not about any one component, and
  #     splitting would answer it per part.
  #
  #   * **Fewer than two sessions** has nothing to split.
  defp components(candidates, _programme, [_first | _rest] = _unplaceable), do: [candidates]

  defp components(candidates, _programme, _unplaceable) when length(candidates) < 2,
    do: [candidates]

  defp components(candidates, %Programme{preferences: [_first | _rest]}, _unplaceable),
    do: [candidates]

  defp components(candidates, programme, _unplaceable),
    do: connected_components(candidates, programme)

  defp solve_components([_only], candidates, programme, pinned, unplaceable, options) do
    resolve(candidates, programme, pinned, unplaceable, options, starvation(candidates))
  end

  defp solve_components(components, candidates, programme, pinned, unplaceable, options) do
    shares = budget_shares(components, length(candidates), options)

    # The components are disjoint by construction and each already has
    # its own slice of the node budget, so searching them at the same
    # time changes nothing about the answer — only how long it takes to
    # get. Order is preserved, so the layout does not depend on which
    # scheduler finished first.
    #
    # Every component sees the pins: a pin outside this component still
    # occupies its resources, and dropping it would let the search
    # place a session on top of one.
    components
    |> Enum.zip(shares)
    |> in_parallel(
      fn {component, share} ->
        resolve(
          component,
          programme,
          pinned,
          unplaceable,
          Keyword.put(options, :nodes, share),
          starvation(component)
        )
      end,
      options,
      @parallel_components
    )
    |> Enum.reduce_while({:ok, [], [], true}, fn
      {:ok, arrangements}, {:ok, placed, skipped, minimal?} ->
        {:cont, {:ok, placed ++ own(arrangements, pinned), skipped, minimal?}}

      {:partial, layout}, {:ok, placed, skipped, minimal?} ->
        {:cont,
         {:ok, placed ++ own(layout.placed, pinned), skipped ++ layout.unplaced,
          minimal? and layout.minimal?}}

      {:error, _reason} = error, {:ok, _placed, _skipped, _minimal?} ->
        {:halt, error}
    end)
    |> case do
      {:ok, placed, [], _minimal?} ->
        {:ok, pinned ++ placed}

      {:ok, placed, skipped, minimal?} ->
        {:partial, Layout.new(programme.name, pinned ++ placed, skipped, minimal?)}

      {:error, _reason} = error ->
        error
    end
  end

  # `:nodes` caps the whole call, so splitting the programme must not
  # multiply the budget by the number of parts. Each component gets a
  # share in proportion to its size, with a floor so that a component
  # of two sessions is not handed a budget too small to search it.
  defp budget_shares(components, total_sessions, options) do
    total = budget(options, [])

    Enum.map(components, fn component ->
      share = div(total * length(component), max(total_sessions, 1))

      max(share, @minimum_component_nodes)
    end)
  end

  # Each component's result carries the pins back with it, so they are
  # stripped before the parts are concatenated and added once.
  defp own(arrangements, pinned) do
    fixed = MapSet.new(pinned, & &1.session)

    Enum.reject(arrangements, &MapSet.member?(fixed, &1.session))
  end

  # Building this by comparing every pair costs a quadratic number of
  # comparisons, each of which has to know which resources two sessions
  # could use — and rebuilding those sets per comparison made finding
  # the components cost more than the search they were meant to speed
  # up. Inverting it is both faster and simpler to state: walk each
  # session's placements once, note which resources it could use, and
  # let every resource join the sessions that named it. Tracks and
  # precedences join their members the same way.
  #
  # The cost is then proportional to the number of placements rather
  # than to the square of the number of sessions.
  defp connected_components(candidates, programme) do
    indexed = Enum.with_index(candidates)

    edges =
      %{}
      |> join(groups_by_resource(indexed))
      |> join(groups_by_track(indexed, programme))
      |> join(groups_by_precedence(indexed, programme))

    indexed
    |> Enum.map(fn {_candidate, i} -> i end)
    |> group_components(edges, %{}, [])
    |> Enum.map(fn members -> Enum.map(members, &Enum.at(candidates, &1)) end)
  end

  defp groups_by_resource(indexed) do
    indexed
    |> Enum.reduce(%{}, fn {{_session, _symmetry, placements}, i}, acc ->
      placements
      |> resource_names()
      |> Enum.reduce(acc, fn name, inner ->
        Map.update(inner, name, [i], &[i | &1])
      end)
    end)
    |> Map.values()
  end

  defp groups_by_track(indexed, programme) do
    indexed
    |> Enum.reduce(%{}, fn {{session, _symmetry, _placements}, i}, acc ->
      case Programme.track_of(programme, session.name) do
        nil -> acc
        track -> Map.update(acc, track.name, [i], &[i | &1])
      end
    end)
    |> Map.values()
  end

  defp groups_by_precedence(indexed, %Programme{precedences: precedences}) do
    positions =
      Map.new(indexed, fn {{session, _symmetry, _placements}, i} -> {session.name, i} end)

    for precedence <- precedences,
        first = Map.get(positions, precedence.first),
        then = Map.get(positions, precedence.then),
        first != nil and then != nil,
        do: [first, then]
  end

  # Every member of a group is connected to every other, and a chain
  # through the first is enough to make them one component.
  defp join(edges, groups) do
    Enum.reduce(groups, edges, fn
      [_only], acc ->
        acc

      [head | rest], acc ->
        Enum.reduce(rest, acc, fn member, inner ->
          inner
          |> Map.update(head, [member], &[member | &1])
          |> Map.update(member, [head], &[head | &1])
        end)

      [], acc ->
        acc
    end)
  end

  defp group_components([], _edges, _seen, components), do: Enum.reverse(components)

  defp group_components([node | rest], edges, seen, components) do
    if Map.has_key?(seen, node) do
      group_components(rest, edges, seen, components)
    else
      members = reachable([node], edges, %{})

      group_components(
        rest,
        edges,
        Map.merge(seen, members),
        [members |> Map.keys() |> Enum.sort() | components]
      )
    end
  end

  defp reachable([], _edges, seen), do: seen

  defp reachable([node | rest], edges, seen) do
    if Map.has_key?(seen, node) do
      reachable(rest, edges, seen)
    else
      reachable(Map.get(edges, node, []) ++ rest, edges, Map.put(seen, node, true))
    end
  end

  defp resource_names(placements) do
    for placement <- placements,
        resource <- Arrangement.resources(placement),
        into: MapSet.new(),
        do: resource.name
  end

  defp resolve(candidates, programme, pinned, unplaceable, options, starved) do
    allow? = allow_unplaced?(options)

    if not allow? and unplaceable != [] do
      {:error, hd(unplaceable)}
    else
      candidates
      |> optimise(programme, pinned, allow?, options, [])
      |> refine(candidates, programme, pinned, allow?, options)
      |> to_result(programme, unplaceable, starved)
    end
  end

  # Sessions cannot all be placed in fewer distinct placements than
  # there are sessions, so when the enumeration offers fewer than that
  # the search is doomed before it starts and no node budget will save
  # it. Saying so is the difference between a caller raising `:nodes`
  # — which only makes the same failure slower — and raising
  # `:candidates`, which fixes it.
  defp starvation(candidates) do
    distinct =
      candidates
      |> Enum.flat_map(fn {_session, _symmetry, placements} ->
        Enum.map(placements, &placement_key/1)
      end)
      |> Enum.uniq()
      |> length()

    if distinct < length(candidates), do: {distinct, length(candidates)}
  end

  defp placement_key(%Arrangement{} = arrangement) do
    {arrangement.interval.from, arrangement.interval.to,
     arrangement |> Arrangement.resources() |> Enum.map(& &1.name) |> Enum.sort()}
  end

  # Only two values are meaningful, and a third is a typo worth hearing
  # about rather than silently reading as the default.
  defp allow_unplaced?(options) do
    case Keyword.get(options, :unplaced, :error) do
      :error -> false
      :allow -> true
    end
  end

  # Branch and bound over the number of sessions left out.
  #
  # One search, carrying the best complete layout found so far. Any
  # branch already leaving out as many as that best is cut, because it
  # cannot beat it. Two properties follow, and both matter:
  #
  # * **No round is ever re-explored.** Iterative deepening — search
  #   for "all placed", then "all but one", then "all but two" — redoes
  #   every earlier round's work on each pass.
  #
  # * **It is *anytime*.** The first descent to a leaf already yields a
  #   usable layout, which later descents only improve. Deepening finds
  #   nothing at all until it reaches the correct round, so exhausting
  #   the node cap on a badly overbooked programme returned an error
  #   where it could have returned most of a conference.
  #
  # The relaxation bound closes it off: once the best layout places as
  # many sessions as the resources could possibly hold, it is optimal
  # and the search stops rather than proving the point exhaustively.
  defp optimise(candidates, programme, pinned, allow?, options, preferences, ceiling \\ nil) do
    context = %{programme: programme, options: options}
    widest = if allow?, do: length(candidates), else: 0

    explore(candidates, context, Enum.map(pinned, &{&1, exempt(&1)}), [], %{
      best: nil,
      stuck: nil,
      budget: budget(options, preferences),
      exhausted?: false,
      ceiling: ceiling || widest,
      floor: if(allow?, do: fewest_possible_unplaced(candidates), else: 0),
      preferences: preferences,
      count_proven?: nil,
      scoring: %{programme: programme, pool: Keyword.get(options, :pool, [])}
    })
  end

  # Lexicographic optimisation, done in two passes rather than one.
  #
  # The first pass ignores preferences entirely, so it keeps every
  # property it had before them: `>=` pruning, the early exit at the
  # capacity bound, and a *proven* minimum number of sessions left out.
  #
  # The second pass takes that number as a hard ceiling and looks only
  # for a better-scoring layout that places exactly as many. It cannot
  # cost a placement, because a branch that leaves out one more is cut
  # before it is explored.
  #
  # Doing this in a single pass was tried and was badly wrong. Soft
  # constraints force `>` pruning — a tie on count is precisely where a
  # better score lives — and that plus the loss of the early exit made
  # every programme burn its whole node budget: a four-session layout
  # went from 5ms to 1951ms, and larger ones stopped being able to
  # prove minimality at all. Separating the passes gives the soft
  # search its own budget, so it can never spend the guarantee.
  defp refine(state, candidates, programme, pinned, allow?, options)

  defp refine(state, _candidates, %Programme{preferences: []}, _pinned, _allow?, _options),
    do: state

  defp refine(%{best: nil} = state, _candidates, _programme, _pinned, _allow?, _options),
    do: state

  defp refine(
         %{best: {count, _score, _placed, _skipped}} = proven,
         candidates,
         programme,
         pinned,
         allow?,
         options
       ) do
    scored =
      optimise(candidates, programme, pinned, allow?, options, programme.preferences, count)

    # Minimality was settled by the first pass and cannot be unsettled
    # by the second, whose exhaustion says only that a better *score*
    # may exist.
    case scored.best do
      nil -> proven
      _found -> %{scored | floor: proven.floor, count_proven?: minimal?(proven)}
    end
  end

  # The scoring pass gets its own budget so that looking for a prettier
  # layout can never eat the budget that proves how many fit.
  defp budget(options, []), do: Keyword.get(options, :nodes, @default_nodes)

  defp budget(options, [_first | _rest]) do
    Keyword.get(options, :score_nodes, @default_score_nodes)
  end

  # As with `:candidates`, an explicit `:nodes` is taken at face value.
  defp node_budget(session_count, options) do
    Keyword.get(options, :nodes) || max(@default_nodes, session_count * @nodes_per_session)
  end

  # --- the relaxation bound ---------------------------------------

  # The fewest sessions that must be left out, ignoring every
  # constraint except that a resource cannot hold more overlapping
  # placements than its concurrency.
  #
  # For one resource, the largest set of pairwise-disjoint candidate
  # intervals is exact by a greedy earliest-end scan; a set whose
  # overlap never exceeds `c` splits into `c` such sets, so
  # `disjoint × concurrency` bounds what it can hold. Summing across
  # resources overcounts a session needing two of them at once, which
  # keeps the total an upper bound rather than breaking it.
  #
  # The bound is computed from the same candidate lists the search
  # uses, so it bounds the space actually being searched — which is
  # what makes "optimal" mean the same thing to both.
  defp fewest_possible_unplaced(candidates) do
    capacity =
      candidates
      |> Enum.flat_map(fn {_session, _symmetry, placements} ->
        for placement <- placements, resource <- Arrangement.resources(placement) do
          {resource.name, resource.concurrency, placement.interval}
        end
      end)
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {_name, held} -> holdable(held) end)
      |> Enum.sum()

    max(length(candidates) - capacity, 0)
  end

  defp holdable([{_name, concurrency, _interval} | _rest] = held) do
    held
    |> Enum.map(&elem(&1, 2))
    |> Enum.sort(&(Compare.compare_endpoints(&1.to, &2.to) != :later))
    |> Enum.reduce({0, nil}, fn interval, {count, busy_until} ->
      if busy_until && Compare.compare_endpoints(interval.from, busy_until) == :earlier do
        {count, busy_until}
      else
        {count + 1, interval.to}
      end
    end)
    |> elem(0)
    |> Kernel.*(concurrency)
  end

  # --- depth-first search with backtracking -----------------------

  # `placed` holds `{arrangement, symmetry}` pairs and `skipped` holds
  # `{session, symmetry}` pairs — the symmetry keys are search
  # bookkeeping and never reach the caller.
  defp explore(remaining, context, placed, skipped, state) do
    cond do
      settled?(state) -> state
      state.budget <= 0 -> %{state | exhausted?: true}
      remaining == [] -> record(state, placed, skipped)
      hopeless?(skipped, state) -> state
      true -> descend(remaining, context, placed, skipped, state)
    end
  end

  defp descend([{session, symmetry, candidates} | rest], context, placed, skipped, state) do
    state
    |> place_each(candidates, symmetry, rest, context, placed, skipped)
    |> leave_out(session, symmetry, rest, context, placed, skipped)
  end

  defp place_each(state, [], _symmetry, _rest, _context, _placed, _skipped), do: state

  defp place_each(state, [candidate | others], symmetry, rest, context, placed, skipped) do
    cond do
      settled?(state) ->
        state

      state.budget <= 0 ->
        %{state | exhausted?: true}

      true ->
        state
        |> spend()
        |> try_placing(candidate, symmetry, rest, context, placed, skipped)
        |> place_each(others, symmetry, rest, context, placed, skipped)
    end
  end

  # Forward checking — filtering every remaining session's candidates
  # against each new placement, and reordering by how few survive —
  # was implemented here and reverted. It is textbook for constraint
  # problems, and it made this one 16 to 20 times slower.
  #
  # Two reasons, both particular to this search. `compatible?/4` is
  # not a table lookup but a scan over everything already placed, so
  # look-ahead costs `remaining × candidates × placed` at *every*
  # node, where checking a candidate when its own session comes up
  # pays that once. And there is little left for it to find: the
  # symmetry rules below already collapse the interchangeable
  # sessions that generate the redundant branches forward checking
  # exists to prune. It also cost more than it saved in answers —
  # two programmes that had been solved to proven optimality came
  # back merely good, the budget spent on look-ahead instead.
  #
  # Worth revisiting only if `compatible?/4` becomes cheap enough to
  # memoise per candidate pair.
  defp try_placing(state, candidate, symmetry, rest, context, placed, skipped) do
    if worth_trying?(candidate, symmetry, context, placed, skipped) do
      explore(rest, context, [{candidate, symmetry} | placed], skipped, state)
    else
      state
    end
  end

  # Leaving a session out is explored as a branch in its own right,
  # not merely as a fallback once its placements fail: placing a
  # session can foreclose two others, so the best layout sometimes
  # gives up one to keep more.
  defp leave_out(state, session, symmetry, rest, context, placed, skipped) do
    cond do
      length(skipped) >= state.ceiling -> note_stuck(state, session)
      settled?(state) -> state
      state.budget <= 0 -> %{state | exhausted?: true}
      true -> skip_it(state, session, symmetry, rest, context, placed, skipped)
    end
  end

  defp skip_it(state, session, symmetry, rest, context, placed, skipped) do
    explore(rest, context, placed, [{session, symmetry} | skipped], spend(state))
  end

  defp spend(state), do: %{state | budget: state.budget - 1}

  # No layout can leave out fewer than the resources force, so one that
  # matches the bound is optimal and there is nothing left to prove —
  # unless preferences are declared, in which case another layout
  # placing just as many may still score better, and stopping here
  # would return the first workable answer rather than a good one.
  defp settled?(%{best: nil}), do: false

  # Penalties are never negative, so a score of zero is the best any
  # layout can do and the scoring pass has nothing left to look for.
  defp settled?(%{preferences: [_first | _rest], best: {_count, 0, _placed, _skipped}}), do: true

  defp settled?(%{preferences: [_first | _rest]}), do: false
  defp settled?(%{best: {count, _score, _placed, _skipped}, floor: floor}), do: count <= floor

  # Without preferences a branch that ties the best count cannot
  # improve on it, so `>=` cuts it. With preferences a tie is exactly
  # where a better score lives, so only a strictly worse count is cut.
  # That is what makes soft constraints cost something: the search can
  # no longer dismiss the layouts it would otherwise never look at.
  defp hopeless?(_skipped, %{best: nil}), do: false

  defp hopeless?(skipped, %{best: {count, _score, _placed, _skipped}} = state) do
    if state.preferences == [] do
      length(skipped) >= count
    else
      length(skipped) > count
    end
  end

  # Lexicographic: fewer sessions left out always wins, and the score
  # only separates layouts that leave out the same number.
  defp record(state, placed, skipped) do
    count = length(skipped)
    arrangements = placed |> Enum.reverse() |> Enum.map(&elem(&1, 0))
    score = Preference.score(state.preferences, arrangements, state.scoring)

    if better_than_best?(state.best, count, score) do
      %{
        state
        | best: {count, score, arrangements, skipped |> Enum.reverse() |> Enum.map(&elem(&1, 0))}
      }
    else
      state
    end
  end

  defp better_than_best?(nil, _count, _score), do: true

  defp better_than_best?({best_count, best_score, _placed, _skipped}, count, score) do
    count < best_count or (count == best_count and score < best_score)
  end

  # The first session whose placements all failed with no room to drop
  # it. Only reached when `:unplaced` is `:error`, and only used to name
  # the session in the failure.
  defp note_stuck(%{stuck: nil} = state, session), do: %{state | stuck: session}
  defp note_stuck(state, _session), do: state

  # Symmetry breaking, and the reason the search is tractable at all.
  #
  # Interchangeable sessions — same length, same window, same
  # requirements, same track — produce identical subproblems under any
  # permutation. Without a canonical order the search explores all of
  # them, so proving a tight programme infeasible costs a factorial in
  # the number of look-alike sessions.
  #
  # Two rules collapse those permutations to one representative, and
  # neither loses a solution because the sessions are identical and any
  # arrangement can be relabelled into canonical form. Each must start
  # no earlier than the last placed member of its group, and once one
  # member has been left out no later member may be placed — so the
  # sessions a group gives up are always its last, not an arbitrary
  # subset of it.
  defp worth_trying?(candidate, symmetry, context, placed, skipped) do
    not left_out_already?(symmetry, skipped) and
      in_symmetry_order?(candidate, symmetry, placed) and
      compatible?(candidate, placed, context.programme, context.options)
  end

  defp left_out_already?(symmetry, skipped) do
    Enum.any?(skipped, fn {_session, key} -> key == symmetry end)
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

  # --- shaping the outcome ----------------------------------------

  defp to_result(
         %{best: {_count, score, arrangements, skipped}} = state,
         programme,
         unplaceable,
         _starved
       ) do
    placed = in_programme_order(arrangements, programme)

    case unplaceable ++ Enum.map(skipped, &clashed/1) do
      [] ->
        {:ok, placed}

      left_out ->
        {:partial,
         %{
           Layout.new(programme.name, placed, left_out, minimal?(state))
           | score: score,
             score_proven?: not state.exhausted?
         }}
    end
  end

  # Running out of budget outranks getting stuck. A session whose
  # placements all failed may have failed only because the search never
  # got far enough to try the arrangement that would have fitted it, so
  # claiming it is impossible would be claiming more than was proved.
  defp to_result(%{best: nil, exhausted?: true}, programme, _unplaceable, starved) do
    {:error, Infeasible.new(programme.name, [exhausted_because(starved)])}
  end

  # The programme is the subject when the whole thing fails, because
  # the whole thing is what the caller asked for. Inside a layout the
  # session is the subject instead — there, the programme succeeded and
  # this one session is what did not.
  defp to_result(%{best: nil, stuck: %Session{} = session}, programme, _unplaceable, _starved) do
    {:error, Infeasible.new(programme.name, [unplaceable_because(session.name)])}
  end

  # No layout, nothing named, no exhaustion flag — the budget ran out
  # somewhere that did not record it. Reporting the cap is the honest
  # reading, and a clause here is cheaper than a FunctionClauseError.
  defp to_result(%{best: nil}, programme, _unplaceable, starved) do
    {:error, Infeasible.new(programme.name, [exhausted_because(starved)])}
  end

  # Two different failures wear the same face. Which one it is decides
  # what the caller should do about it, and the wrong advice here costs
  # them a slower run of the identical failure.
  defp exhausted_because(nil) do
    "the search reached its node limit before placing every session — " <>
      "raise :nodes, or narrow the programme"
  end

  defp exhausted_because({distinct, sessions}) do
    "the sessions were offered only #{distinct} distinct placements between " <>
      "#{sessions} of them, so no arrangement can place them all — raise " <>
      ":candidates, widen the window, or add resources. Raising :nodes will " <>
      "not help: the placements searched do not contain an answer"
  end

  # A layout is provably the fewest left out when the search finished
  # on its own terms, or when it matched the relaxation bound before
  # the budget ran out. When a scoring pass has run, the answer is the
  # one the counting pass reached — the scoring pass never changes how
  # many were placed, so its budget cannot cost the guarantee.
  defp minimal?(%{count_proven?: proven}) when is_boolean(proven), do: proven

  defp minimal?(%{best: {count, _score, _placed, _skipped}, floor: floor, exhausted?: exhausted?}) do
    not exhausted? or count <= floor
  end

  defp clashed(session) do
    Infeasible.new(session.name, [
      "cannot be placed without clashing with something already placed"
    ])
  end

  defp unplaceable_because(name) do
    "#{name} cannot be placed without clashing with something already placed"
  end

  defp in_programme_order(arrangements, programme) do
    order =
      programme
      |> Programme.all_sessions()
      |> Enum.with_index()
      |> Map.new(fn {session, index} -> {session.name, index} end)

    Enum.sort_by(arrangements, &Map.get(order, &1.session, 0))
  end

  @doc """
  `true` when two placements cannot both stand.

  Two placements conflict when they share a resource at overlapping
  times, when they belong to the same track and overlap, or when a
  delegate could not walk between them in the gap. This is the whole
  of what `arrange/3` enforces between any *pair*, exposed so that
  another solver can be handed the same question and give an answer
  this library agrees with.

  Capacity beyond one is not a pairwise property — three placements
  can each be fine with the other two and still exceed a concurrency
  of two — so a caller relying on this to build a model must handle
  `concurrency > 1` itself.

  ### Arguments

  * `a` and `b` are each a `t:Agenda.Arrangement.t/0`.

  * `programme` is the `t:Agenda.Programme.t/0` they belong to,
    consulted for their tracks.

  ### Options

  * `:travel` is passed to `Agenda.travel_time/3`.

  ### Returns

  * `true` when the two cannot both stand.

  ### Examples

      iex> import Tempo.Sigils
      iex> room = Agenda.resource("Hall")
      iex> a = %Agenda.Arrangement{session: "A", allocations: %{room: [room]},
      ...>       interval: ~o"2026-09-15T09:00:00/2026-09-15T10:00:00"}
      iex> b = %Agenda.Arrangement{session: "B", allocations: %{room: [room]},
      ...>       interval: ~o"2026-09-15T09:30:00/2026-09-15T10:30:00"}
      iex> Agenda.Arranger.conflict?(a, b, Agenda.programme("Conf"))
      true

  """
  @spec conflict?(Arrangement.t(), Arrangement.t(), Programme.t(), keyword()) :: boolean()
  def conflict?(%Arrangement{} = a, %Arrangement{} = b, %Programme{} = programme, options \\ []) do
    not compatible?(a, [{b, nil}], programme, options)
  end

  # --- the three constraints --------------------------------------

  defp compatible?(candidate, placed, programme, options) do
    within_capacity?(candidate, placed) and
      within_limits?(candidate, placed, options) and
      Enum.all?(placed, fn {arrangement, _symmetry} ->
        track_ok?(candidate, arrangement, programme, options) and
          order_ok?(candidate, arrangement, programme)
      end)
  end

  # Precedence relates exactly two sessions, so it belongs here beside
  # the track check rather than needing machinery of its own. A chain
  # of three is two precedences, each enforced independently.
  defp order_ok?(_a, _b, %Programme{precedences: []}), do: true

  defp order_ok?(a, b, %Programme{} = programme) do
    case Precedence.between(programme.precedences, a.session, b.session) do
      nil -> true
      {precedence, :in_order} -> follows?(b, a, precedence)
      {precedence, :reversed} -> follows?(a, b, precedence)
    end
  end

  # `later` must begin after `earlier` ends, by at least `:gap` and —
  # when given — by no more than `:within`. Both are measured from the
  # end of the predecessor, so a predecessor that runs long pushes its
  # successor rather than eating the allowance.
  defp follows?(later, earlier, %Precedence{} = precedence) do
    earliest = shifted(earlier.interval.to, precedence.gap)

    not_before?(later.interval.from, earliest) and
      within_limit?(later.interval.from, earlier.interval.to, precedence.within)
  end

  defp shifted(moment, nil), do: moment
  defp shifted(moment, duration), do: Tempo.shift(moment, duration)

  defp not_before?(moment, earliest) do
    Compare.compare_endpoints(moment, earliest) in [:later, :same]
  end

  defp within_limit?(_moment, _from, nil), do: true

  defp within_limit?(moment, from, within) do
    Compare.compare_endpoints(moment, Tempo.shift(from, within)) in [:earlier, :same]
  end

  # Capacity is a question about the whole set of placements, not about
  # any pair: a resource with concurrency 3 tolerates two overlapping
  # holders and refuses the third. Asking pairwise could only ever
  # answer "is it free at all", which is the concurrency-1 special case.
  defp within_capacity?(candidate, placed) do
    Enum.all?(Arrangement.resources(candidate), fn resource ->
      claim = turnaround(candidate.interval, resource)
      holders = Enum.count(placed, &holds_at?(&1, resource, claim))

      holders + 1 <= resource.concurrency
    end)
  end

  # A resource costs more than the time it is booked for: a room has to
  # be reset, a machine has to cool, a van has to be reloaded. That is
  # what `buffer_before` and `buffer_after` say, and until now they said
  # it only against bookings that already existed — two sessions the
  # search placed together could sit back to back in a room that needs
  # twenty minutes between them.
  #
  # Both sides of the pair are widened, and both have to be: stretching
  # only the newcomer's end would still let it start the instant the
  # session before it finished. Two intervals each widened by the
  # resource's turnaround overlap exactly when the real gap between
  # them is smaller than that turnaround, so one overlap test measures
  # the separation in either direction.
  defp turnaround(interval, %Resource{buffer_before: nil, buffer_after: nil}), do: interval

  defp turnaround(%Interval{} = interval, %Resource{} = resource) do
    %{
      interval
      | from: earlier_by(interval.from, resource.buffer_before),
        to: later_by(interval.to, resource.buffer_after)
    }
  end

  defp earlier_by(moment, nil), do: moment
  defp earlier_by(moment, duration), do: Tempo.shift(moment, Duration.negate(duration))

  defp later_by(moment, nil), do: moment
  defp later_by(moment, duration), do: Tempo.shift(moment, duration)

  defp holds_at?({arrangement, _symmetry}, %Resource{} = resource, interval) do
    Enum.any?(Arrangement.resources(arrangement), &(&1.name == resource.name)) and
      Tempo.overlaps?(turnaround(arrangement.interval, resource), interval)
  end

  # A limit counts claims that fall in the same *period*, however far
  # apart they sit — "five shifts a week" is not five overlapping
  # shifts. Like capacity it is a question about the whole set rather
  # than any pair, which is why it lives here and not beside the
  # precedence and track checks.
  #
  # Claims already in `:busy` count too. Concurrency can lean on
  # `free/2` to have subtracted existing bookings before the search
  # begins, but no availability calculation can express "at most five
  # this week" — so a nurse who has already worked four is only four
  # if the ledger is consulted here.
  defp within_limits?(candidate, placed, options) do
    Enum.all?(Arrangement.resources(candidate), fn resource ->
      Enum.all?(resource.limits, fn %Limit{} = limit ->
        {count, duration} = claims(resource, candidate, placed, limit.period, options)
        Limit.permits?(limit, count, duration)
      end)
    end)
  end

  # Every claim on `resource` that shares the candidate's bucket, the
  # candidate included — so the answer is what the period *would* hold
  # if this placement were made, which is the question a ceiling asks.
  #
  # A floor asks a different question and is deliberately absent here:
  # a partial layout is supposed to be under its floor, so rejecting it
  # would reject every layout before the last placement. `Limit.permits?/3`
  # ignores floors, and `Agenda.reconcile/3` is where they are checked.
  defp claims(resource, candidate, placed, period, options) do
    bucket = Limit.bucket(candidate.interval.from, period)

    already =
      placed
      |> Enum.filter(fn {arrangement, _symmetry} ->
        Enum.any?(Arrangement.resources(arrangement), &(&1.name == resource.name)) and
          Limit.bucket(arrangement.interval.from, period) == bucket
      end)
      |> Enum.map(fn {arrangement, _symmetry} -> arrangement.interval end)

    booked =
      options
      |> Keyword.get(:busy, %{})
      |> Map.get(resource.name, [])
      |> List.wrap()
      |> Enum.filter(&(Limit.bucket(interval_start(&1), period) == bucket))

    Limit.sum([candidate.interval | already] ++ booked)
  end

  defp interval_start(%Interval{from: from}), do: from
  defp interval_start(other), do: other

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
      case Agenda.travel_time(from, to, travel) do
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
