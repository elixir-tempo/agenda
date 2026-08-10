if Code.ensure_loaded?(CPSolver) do
  defmodule Agenda.Fixpoint do
    @moduledoc """
    Hand a programme to a real constraint solver, and take the answer
    back as arrangements.

    `Agenda.Arranger.arrange/3` is exact and explains itself, and it
    runs out of road somewhere in the low tens of sessions. Past that
    the honest answer has always been "use a solver, then write the
    result back through `Agenda.Ledger.allocate/2`". This module is
    that sentence made executable, using
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

    alias Agenda.Arranger
    alias Agenda.Infeasible
    alias Agenda.Planner
    alias Agenda.Programme
    alias Agenda.Resource
    alias CPSolver.Constraint.Element2D
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
      default is `40`.

    * `:travel` is passed to `Agenda.travel_time/3`.

    * `:timeout` is milliseconds to let the solver run. The default is
      the solver's own.

    ### Returns

    * `{:ok, arrangements}` — one per session, in programme order,
      ready for `Agenda.Ledger.allocate/2`; or

    * `{:error, t:Agenda.Infeasible.t/0}` when a session has no
      eligible placement, the pool contains a resource with
      concurrency above one, or the solver proves there is no layout.

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
            {:ok, [Agenda.Arrangement.t()]} | {:error, Infeasible.t()}
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
    # honest answer — a model that silently drops the capacity would
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
        plan_options = options |> Keyword.take([:busy]) |> Keyword.put(:limit, limit)

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

      Model.new(variables ++ [zero], constraints)
    end

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
      # found anything — an empty solution list is how it says the
      # programme has no layout, not an error.
      case CPSolver.solve(model, solve_options) do
        {:ok, %{solutions: [solution | _rest]}} -> {:ok, chosen(solution, candidates)}
        {:ok, %{solutions: []}} -> {:error, no_layout(programme)}
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
