if Code.ensure_loaded?(CPSolver) do
  defmodule Agenda.Fixpoint do
    @moduledoc """
    Hand a programme to a real constraint solver, and take the answer
    back as arrangements.

    `Agenda.Arranger.arrange/3` is exact and explains itself, and it
    runs out of road somewhere in the low tens of sessions. Past that
    the answer has always been "use a solver, then write the result
    back through `Agenda.Ledger.allocate/2`". This module is that
    sentence made executable, using
    [fixpoint](https://hex.pm/packages/fixpoint).

    Nothing about the model changes. Resources, requirements, places
    and travel are still this library's; the solver is only asked to
    choose, and its answer comes back as ordinary
    `t:Agenda.Arrangement.t/0` values that the ledger accepts
    without knowing who produced them.

    ## How the programme becomes a model

    Not as start times. Each session already has a finite, ranked list
    of candidate placements from `Agenda.Planner.plan/3` — every
    combination of time and resources that satisfies its requirements
    — so the decision is *which candidate*, and the variable is an
    index into that list.

    That choice matters. It keeps eligibility, induced requirements,
    availability and the place tree on this side of the boundary,
    where they are explained; the solver never learns what a room is.
    It also means the model is small: one variable per session, and
    one `Element2D` conflict lookup per pair of sessions, rather than
    interval variables the solver has no constraint for.

    Conflicts come from `Agenda.Arranger.conflict?/4` — the same
    predicate the built-in search uses, so the two cannot disagree
    about what a clash is.

    ## Load limits

    A limit is not a clash, so it cannot ride on that matrix: three
    placements can each be fine with the other two and still be three
    shifts in a day that allows two. It does not need a cumulative
    constraint either, which is what separates it from concurrency —
    a limit counts whole claims rather than overlapping ones, so it is
    a sum over indicators. Each session's contribution to one resource
    in one period is read out of its own candidate list with
    `Element`, the contributions are added, and the total is bounded.

    Ceilings are enforced; **floors are ignored**, exactly as in
    `Agenda.Arranger`. A floor is a completion condition rather than a
    placement one — see `Agenda.Limit` — and honouring it here would
    make the bridge disagree with the search it stands in for.

    Two things follow, and both are worth knowing before reaching for
    a limited pool:

    * **The model gets harder.** Each limited resource-period-bucket
      adds a variable per session that can reach it. On small
      programmes this has cost a few times the search of the same
      programme unlimited. A search that runs out of time says
      `{:error, :timeout}`, which is a different fact from
      `Agenda.Infeasible` and can be retried with a longer one.

    * **`:candidates` matters more.** A limit bounds a *period*, so a
      candidate list that does not reach across enough periods cannot
      satisfy one. Candidates are planned with `spread: true` so that
      truncation takes placements from across the window rather than
      the earliest few, but a cap set low enough still drops whole
      days — and the solver will then prove a satisfiable programme
      impossible against the model it was handed rather than against
      the programme.

    ## What it will not do

    **Concurrency above one.** A resource that admits several
    simultaneous holders is not a pairwise property: three placements
    can each be fine with the other two and still exceed a capacity of
    two. Expressing that needs a cumulative constraint, which fixpoint
    does not have. A pool containing one is refused rather than
    quietly mis-solved.

    **Partial layouts and preferences.** This answers the
    all-or-nothing question only. `unplaced: :allow`, `minimal?` and
    `Agenda.Preference` all stay with `arrange/3`.

    Note also that fixpoint describes itself as a proof of concept and
    warns of API changes, which is why it is an optional dependency
    and this module is only compiled when it is present.

    """

    alias Agenda.Arrangement
    alias Agenda.Arranger
    alias Agenda.Infeasible
    alias Agenda.Limit
    alias Agenda.Planner
    alias Agenda.Programme
    alias Agenda.Resource
    alias CPSolver.Constraint.Element
    alias CPSolver.Constraint.Element2D
    alias CPSolver.Constraint.Sum
    alias CPSolver.IntVariable
    alias CPSolver.Model

    @default_candidates 40

    @doc """
    Lay out a whole programme with the fixpoint solver.

    ### Arguments

    * `programme` is a `t:Agenda.Programme.t/0`.

    * `pool` is the list of `t:Agenda.Resource.t/0` to choose from.

    ### Options

    * `:busy` is a map of resource name to what already claims it, as
      `Agenda.Ledger.busy/2` returns.

    * `:candidates` caps how many placements are considered per
      session, which is the size of each variable's domain. The
      default is `40`. Raise it when the pool carries limits — see
      **Load limits** above, since too small a cap can drop the
      periods a limit needs to spread across.

    * `:travel` is passed to `Agenda.travel_time/3`.

    * `:timeout` is milliseconds to let the solver run. The default is
      the solver's own, currently 30 seconds.

    ### Returns

    * `{:ok, arrangements}` — one per session, in programme order,
      ready for `Agenda.Ledger.allocate/2`; or

    * `{:error, t:Agenda.Infeasible.t/0}` when a session has no
      eligible placement, the pool contains a resource with
      concurrency above one, or the solver *proves* there is no
      layout — which it proves against the candidate lists it was
      given, so `:candidates` bounds what "no layout" means; or

    * `{:error, :timeout}` when the solver ran out of time before it
      could decide. This is deliberately not an `t:Agenda.Infeasible.t/0`
      — "no arrangement exists" and "nobody finished looking" are
      different facts, and a caller that retries with a longer
      `:timeout` needs to tell them apart.

    ### Examples

        iex> room = Agenda.resource("Hall", seats: 100)
        iex> {:ok, room} = Agenda.open(room, "2026-09-15T09:00:00/2026-09-15T12:00:00")
        iex> talk = fn name ->
        ...>   Agenda.session(name, lasting: "PT1H", between: "2026-09-15/2026-09-16")
        ...>   |> Agenda.Session.needs(:room, seats: 100)
        ...> end
        iex> programme =
        ...>   Agenda.programme("Conf")
        ...>   |> Agenda.Programme.add_session(talk.("Keynote"))
        ...>   |> Agenda.Programme.add_session(talk.("Deep dive"))
        iex> {:ok, arrangements} = Agenda.Fixpoint.solve(programme, [room])
        iex> length(arrangements)
        2

    """
    @spec solve(Programme.t(), [Resource.t()], keyword()) ::
            {:ok, [Agenda.Arrangement.t()]} | {:error, Infeasible.t() | :timeout}
    def solve(%Programme{} = programme, pool, options \\ []) when is_list(pool) do
      with :ok <- all_exclusive(pool, programme),
           {:ok, programme} <- Arranger.readable(programme),
           {:ok, candidates} <- candidates_per_session(programme, pool, options) do
        attempt(candidates, programme, options)
      end
    end

    # fixpoint signals a model that is infeasible on sight by throwing
    # `{:fail, ref}` out of `Model.new/3` — before any search runs, and
    # as a throw rather than a return. That happens here whenever two
    # sessions conflict in every combination of their candidates, which
    # is an ordinary answer ("this programme has no layout"), not an
    # exceptional one. Catching it is what keeps a proof-of-concept
    # solver's rough edge from reaching a caller as a crash.
    defp attempt(candidates, programme, options) do
      candidates
      |> build(programme, options)
      |> run(programme, candidates, options)
    catch
      {:fail, _reference} -> {:error, no_layout(programme)}
    end

    # Concurrency above one is not a pairwise property, and there is no
    # cumulative constraint to express it with. Refusing is the only
    # safe answer — a model that silently drops the capacity would
    # produce layouts this library would reject.
    defp all_exclusive(pool, programme) do
      case Enum.filter(pool, &(&1.concurrency > 1)) do
        [] ->
          :ok

        shared ->
          {:error,
           Infeasible.new(
             programme.name,
             Enum.map(
               shared,
               &("#{&1.name} has concurrency #{&1.concurrency} — the fixpoint bridge " <>
                   "models exclusive resources only; use Agenda.arrange/3 instead")
             )
           )}
      end
    end

    defp candidates_per_session(programme, pool, options) do
      limit = Keyword.get(options, :candidates, @default_candidates)

      programme
      |> Programme.all_sessions()
      |> Enum.reduce_while({:ok, []}, fn session, {:ok, acc} ->
        # `spread: true` matches `Agenda.Arranger`. Without it a
        # truncated candidate list is the *earliest* placements, which
        # cluster into the first day or two of the window — so a
        # resource limited per day is offered candidates that cannot
        # reach the later periods, and a satisfiable programme is
        # proved impossible against a model that never saw them.
        plan_options =
          options
          |> Keyword.take([:busy])
          |> Keyword.put(:limit, limit)
          |> Keyword.put(:spread, true)

        case Planner.plan(bounded_by(session, programme), pool, plan_options) do
          {:ok, placements} -> {:cont, {:ok, acc ++ [{session, placements}]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end

    defp bounded_by(%{window: nil} = session, %Programme{window: window}),
      do: %{session | window: window}

    defp bounded_by(session, _programme), do: session

    ## --- the model ------------------------------------------------

    defp build(candidates, programme, options) do
      variables =
        Enum.map(candidates, fn {session, placements} ->
          IntVariable.new(Enum.to_list(0..(length(placements) - 1)), name: session.name)
        end)

      # One shared zero. `Element2D` reads a cell and binds it to a
      # variable; pinning that variable to zero is how "these two
      # choices do not conflict" is said.
      zero = IntVariable.new([0], name: "no-conflict")

      constraints =
        for {{_a_session, a_places}, a_index} <- Enum.with_index(candidates),
            {{_b_session, b_places}, b_index} <- Enum.with_index(candidates),
            a_index < b_index do
          Element2D.new([
            conflict_matrix(a_places, b_places, programme, options),
            Enum.at(variables, a_index),
            Enum.at(variables, b_index),
            zero
          ])
        end

      {limit_variables, limit_constraints} = limits(candidates, variables, options)

      Model.new(variables ++ [zero] ++ limit_variables, constraints ++ limit_constraints)
    end

    ## --- load limits ----------------------------------------------

    # A limit is not pairwise, so it cannot ride on the conflict matrix
    # the way a clash does: three placements can each be fine with the
    # other two and still be three shifts in a day that allows two.
    #
    # It does not need a cumulative constraint either, which is what
    # separates it from concurrency. A limit counts whole claims rather
    # than overlapping ones, so it is a sum over indicators: read each
    # session's contribution to one resource in one period out of its
    # own candidate list with `Element`, add them up, and bound the
    # total. That is expressible with what fixpoint has.
    #
    # Floors are deliberately absent, exactly as in `Agenda.Arranger`.
    # A floor is a completion condition rather than a placement one —
    # see `Agenda.Limit` — and enforcing it here would make the bridge
    # disagree with the search it is supposed to stand in for.
    defp limits(candidates, variables, options) do
      busy = Keyword.get(options, :busy, %{})

      candidates
      |> limited_resources()
      |> Enum.flat_map(fn resource ->
        Enum.flat_map(resource.limits, &periods(resource, &1, candidates, variables, busy))
      end)
      |> Enum.reduce({[], []}, fn {new_variables, new_constraints}, {all_vars, all_cons} ->
        {all_vars ++ new_variables, all_cons ++ new_constraints}
      end)
    end

    # Only resources that actually appear in a candidate can be loaded
    # by one, so the model never carries a constraint about a resource
    # the programme cannot reach.
    defp limited_resources(candidates) do
      candidates
      |> Enum.flat_map(fn {_session, placements} ->
        Enum.flat_map(placements, &Arrangement.resources/1)
      end)
      |> Enum.uniq_by(& &1.name)
      |> Enum.filter(fn resource -> Enum.any?(resource.limits, &(&1.at_most != nil)) end)
    end

    defp periods(_resource, %Limit{at_most: nil}, _candidates, _variables, _busy), do: []

    defp periods(resource, %Limit{} = limit, candidates, variables, busy) do
      contributions =
        candidates
        |> Enum.zip(variables)
        |> Enum.map(fn {{_session, placements}, variable} ->
          {variable, Enum.map(placements, &contribution(&1, resource, limit))}
        end)

      contributions
      |> Enum.flat_map(fn {_variable, rows} ->
        Enum.map(rows, fn {bucket, _amount} -> bucket end)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(&bucket(&1, resource, limit, contributions, busy))
    end

    # What one placement adds to one resource's load, and where. A
    # placement that does not use the resource contributes nowhere.
    defp contribution(placement, resource, limit) do
      if Enum.any?(Arrangement.resources(placement), &(&1.name == resource.name)) do
        {_count, duration} = Limit.total([placement.interval])
        {Limit.bucket(placement.interval.from, limit.period), Limit.measure(limit, 1, duration)}
      else
        {nil, 0}
      end
    end

    defp bucket(bucket, resource, limit, contributions, busy) do
      budget = budget(bucket, resource, limit, busy)

      arrays =
        contributions
        |> Enum.map(fn {variable, rows} ->
          {variable, Enum.map(rows, fn {at, amount} -> if at == bucket, do: amount, else: 0 end)}
        end)
        |> Enum.reject(fn {_variable, array} -> Enum.all?(array, &(&1 == 0)) end)

      cond do
        arrays == [] -> []
        worst_case(arrays) <= budget -> []
        true -> [bound(arrays, budget, resource, limit, bucket)]
      end
    end

    # Nothing is gained by telling the solver about a limit no choice
    # could breach, and every constraint costs propagation.
    defp worst_case(arrays) do
      Enum.sum(Enum.map(arrays, fn {_variable, array} -> Enum.max(array) end))
    end

    defp bound(arrays, budget, resource, limit, bucket) do
      # Every contribution and the budget are divided through by their
      # greatest common divisor first. This is exact — each achievable
      # sum is a multiple of the divisor, so `sum <= budget` and
      # `sum/g <= div(budget, g)` accept exactly the same layouts — and
      # it is what makes the model tractable.
      #
      # Without it, an eight-hour ceiling gives the total a domain of
      # 0..28800 and the solver branches over every second in it. Hours
      # measured against hours share a divisor of 3600, so the same
      # constraint becomes a domain of 0..8.
      divisor = divisor(arrays, budget)
      scaled = Enum.map(arrays, fn {variable, array} -> {variable, div_all(array, divisor)} end)

      {indicators, elements} =
        scaled
        |> Enum.with_index()
        |> Enum.map(fn {{variable, array}, index} ->
          name = "#{resource.name}/#{limit.period}/#{inspect(bucket)}/#{index}"
          indicator = IntVariable.new(Enum.uniq(array), name: name)
          {indicator, Element.new(array, variable, indicator)}
        end)
        |> Enum.unzip()

      # The ceiling is the total's *domain* rather than a separate
      # comparison — a sum that cannot take a value above the budget is
      # a sum that is bounded by it.
      total =
        IntVariable.new(0..div(budget, divisor),
          name: "#{resource.name}/#{limit.period}/#{inspect(bucket)}"
        )

      {[total | indicators], elements ++ [Sum.new(total, indicators)]}
    end

    # The budget joins the reduction because a ceiling that is not a
    # multiple of the contributions must round *down*, and dividing by
    # a divisor it does not share would round it up.
    defp divisor(arrays, budget) do
      arrays
      |> Enum.flat_map(fn {_variable, array} -> array end)
      |> Enum.reject(&(&1 == 0))
      |> Enum.reduce(budget, &Integer.gcd/2)
      |> max(1)
    end

    defp div_all(array, divisor), do: Enum.map(array, &div(&1, divisor))

    # What the ledger already holds comes off the budget, because a
    # limit counts claims that exist as well as claims being made. A
    # resource already at or past its ceiling has a budget of zero,
    # which forbids every further placement in that period rather than
    # going negative.
    defp budget(bucket, resource, limit, busy) do
      claimed =
        busy
        |> Map.get(resource.name, [])
        |> List.wrap()
        |> Enum.filter(&(Limit.bucket(interval_start(&1), limit.period) == bucket))

      {count, duration} = Limit.total(claimed)

      max(0, Limit.ceiling(limit) - Limit.measure(limit, count, duration))
    end

    defp interval_start(%Tempo.Interval{from: from}), do: from
    defp interval_start(other), do: other

    # `1` where the two placements cannot both stand. The predicate is
    # `Agenda.Arranger.conflict?/4`, so the solver is answering the
    # question `arrange/3` would have asked.
    defp conflict_matrix(a_places, b_places, programme, options) do
      travel = Keyword.take(options, [:travel])

      Enum.map(a_places, &conflict_row(&1, b_places, programme, travel))
    end

    defp conflict_row(a, b_places, programme, travel) do
      Enum.map(b_places, fn b ->
        if Arranger.conflict?(a, b, programme, travel), do: 1, else: 0
      end)
    end

    ## --- the answer -----------------------------------------------

    defp run(model, programme, candidates, options) do
      solve_options = Keyword.take(options, [:timeout])

      # `CPSolver.solve/2` answers `{:ok, result}` whether or not it
      # found anything, so an empty solution list has to be read against
      # the status before it means anything.
      #
      # The status alone will not do. When fixpoint's timeout fires it
      # logs, calls `set_complete/1`, and returns — so an abandoned run
      # reports `status: :unsatisfiable` with no solutions, exactly as a
      # genuinely impossible programme does. Worse, fixpoint derives
      # that status from `active_node_count <= 1`, so a search with a
      # node still waiting counts as finished.
      #
      # The statistics do separate them, and on principle rather than by
      # timing. Unsatisfiability is a claim about the *whole* search
      # space, so a proof needs both halves of "we looked everywhere":
      #
      #   * `node_count > 0` — the tree was actually walked. A run that
      #     expanded nothing has established nothing.
      #
      #   * `active_node_count == 0` — nothing was left waiting. One
      #     pending node means the search was abandoned mid-flight, and
      #     it is the shape a timeout under load takes.
      #
      # Anything else empty-handed means nobody finished looking, which
      # is a different answer and gets a different reason.
      case CPSolver.solve(model, solve_options) do
        {:ok, %{solutions: [solution | _rest]}} ->
          {:ok, chosen(solution, candidates)}

        {:ok,
         %{
           solutions: [],
           status: :unsatisfiable,
           statistics: %{node_count: explored, active_node_count: 0}
         }}
        when explored > 0 ->
          {:error, no_layout(programme)}

        {:ok, %{solutions: []}} ->
          {:error, :timeout}
      end
    end

    # The solution lists one value per model variable, in the order
    # they were given. The trailing zero is the shared conflict cell,
    # not a session.
    defp chosen(solution, candidates) do
      solution
      |> Enum.zip(candidates)
      |> Enum.map(fn {index, {_session, placements}} -> Enum.at(placements, index) end)
    end

    defp no_layout(programme) do
      Infeasible.new(programme.name, [
        "the solver proved no arrangement places every session — " <>
          "Agenda.conflict/3 will name the sessions in tension"
      ])
    end
  end
end
