defmodule Timetable.Layout do
  @moduledoc """
  A programme laid out as far as it would go — what was placed, and
  what was left out.

  `Timetable.Arranger.arrange/3` fails the whole programme by default:
  if one session cannot be held, there is no arrangement. That is the
  right answer when the programme is a unit, and the wrong one when it
  is a wish list. A conference of forty sessions where thirty-eight fit
  is not a failure — it is thirty-eight sessions and two conversations
  to have.

  A layout is what `arrange/3` returns under `unplaced: :allow` when it
  could not place everything. It is **never** returned as `{:ok, …}`:
  the tag is `{:partial, layout}`, so a caller who has not thought
  about incompleteness cannot mistake one for a finished programme.

      case Timetable.arrange(programme, pool, unplaced: :allow) do
        {:ok, arrangements} -> publish(arrangements)
        {:partial, layout}  -> review(layout.placed, layout.unplaced)
        {:error, reason}    -> abandon(reason)
      end

  Each entry in `unplaced` is a `t:Timetable.Infeasible.t/0`, so a
  session that could not be held still says why.

  ### Whether this is the *best* partial layout

  `minimal?` separates two answers that would otherwise look
  identical:

  * `true` — no layout leaves out fewer sessions. The search either
    finished, or matched the most any arrangement of these candidates
    could place.

  * `false` — the best found before the search hit its `:nodes` cap.
    A better layout may exist; raise `:nodes` and ask again.

  A caller that treats the second as though it were the first will
  turn away work it could have taken, so the distinction is a field
  rather than a footnote.

  ### The score

  `score` is what the layout cost against the programme's
  `Timetable.Preference`s, where `0` is ideal. `score_proven?` is its
  counterpart to `minimal?` and answers a *different* question:

  * `minimal?` — is this the fewest sessions left out? Proven by the
    first pass, and never affected by the second.

  * `score_proven?` — did the scoring pass finish, or stop at its
    `:score_nodes` budget with the best it had found?

  The two are independent. A layout can be provably minimal and merely
  well-scored, which is the common case, because the count is cheap to
  prove and the score is not.

  `Timetable.explain_score/3` breaks the number down per preference,
  since a bare total says a layout is worse without saying how.

  """

  alias Timetable.Arrangement
  alias Timetable.Infeasible

  @typedoc "A programme placed as far as it would go."
  @type t :: %__MODULE__{
          programme: String.t(),
          placed: [Arrangement.t()],
          unplaced: [Infeasible.t()],
          minimal?: boolean(),
          score: number(),
          score_proven?: boolean()
        }

  defstruct programme: nil,
            placed: [],
            unplaced: [],
            minimal?: true,
            score: 0,
            score_proven?: true

  @doc """
  Build a layout.

  ### Arguments

  * `programme` is the programme's name.

  * `placed` is the list of `t:Timetable.Arrangement.t/0` that were
    successfully placed.

  * `unplaced` is a non-empty list of `t:Timetable.Infeasible.t/0`, one
    per session that could not be held.

  * `minimal?` is whether no layout leaves out fewer. The default is
    `true`.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> reason = Timetable.Infeasible.new("Workshop", ["no room seats 8"])
      iex> layout = Timetable.Layout.new("Conf", [], [reason])
      iex> {Enum.map(layout.unplaced, & &1.session), layout.minimal?}
      {["Workshop"], true}

      iex> reason = Timetable.Infeasible.new("Workshop", ["no room seats 8"])
      iex> Timetable.Layout.new("Conf", [], [reason], false).minimal?
      false

  """
  @spec new(String.t(), [Arrangement.t()], [Infeasible.t(), ...], boolean()) :: t()
  def new(programme, placed, unplaced, minimal? \\ true)

  def new(programme, placed, [_first | _rest] = unplaced, minimal?)
      when is_binary(programme) and is_boolean(minimal?) do
    %__MODULE__{
      programme: programme,
      placed: placed,
      unplaced: unplaced,
      minimal?: minimal?
    }
  end

  @doc """
  The names of the sessions that could not be placed.

  ### Arguments

  * `layout` is a `t:t/0`.

  ### Returns

  * the session names, in the order they were given up on.

  ### Examples

      iex> reason = Timetable.Infeasible.new("Workshop", ["no room seats 8"])
      iex> Timetable.Layout.unplaced_sessions(Timetable.Layout.new("Conf", [], [reason]))
      ["Workshop"]

  """
  @spec unplaced_sessions(t()) :: [String.t()]
  def unplaced_sessions(%__MODULE__{unplaced: unplaced}), do: Enum.map(unplaced, & &1.session)

  @doc """
  The layout as a sentence — how much was placed, and why the rest was
  not.

  ### Arguments

  * `layout` is a `t:t/0`.

  ### Returns

  * a sentence naming the programme, the count placed, and each
    session that was left out with its reasons. A layout that is not
    known to be the best says so, since the reader's next move differs.

  ### Examples

      iex> reason = Timetable.Infeasible.new("Workshop", ["no room seats 8"])
      iex> Timetable.Layout.explain(Timetable.Layout.new("Conf", [], [reason]))
      "Conf: 0 of 1 sessions placed. Workshop cannot be held: no room seats 8"

      iex> reason = Timetable.Infeasible.new("Workshop", ["no room seats 8"])
      iex> Timetable.Layout.explain(Timetable.Layout.new("Conf", [], [reason], false))
      "Conf: 0 of 1 sessions placed, and the search stopped at its node limit before proving that is the fewest left out — raise :nodes to be sure. Workshop cannot be held: no room seats 8"

  """
  @spec explain(t()) :: String.t()
  def explain(%__MODULE__{} = layout) do
    placed = length(layout.placed)
    total = placed + length(layout.unplaced)
    left_out = Enum.map_join(layout.unplaced, " ", &Infeasible.message/1)

    "#{layout.programme}: #{placed} of #{total} sessions placed#{caveat(layout)}. #{left_out}"
  end

  defp caveat(%__MODULE__{minimal?: true}), do: ""

  defp caveat(%__MODULE__{minimal?: false}) do
    ", and the search stopped at its node limit before proving that is " <>
      "the fewest left out — raise :nodes to be sure"
  end
end
