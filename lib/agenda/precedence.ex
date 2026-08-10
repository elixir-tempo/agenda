defmodule Agenda.Precedence do
  @moduledoc """
  One session must finish before another starts.

  Every other constraint in this library asks *whether* two things can
  coexist. This one asks about **order**, and it is what separates a
  bag of tasks from a task graph: preparation before delivery, the
  survey before the quote, the first interview before the second.

  ### The gap is part of the constraint

  A precedence with no gap means the successor may begin the instant
  its predecessor ends. `:gap` widens that — thirty minutes to write
  up the survey — and `:within` caps it, which is what makes an
  interview loop a loop rather than two appointments a fortnight
  apart:

      Programme.precede(programme, "Screening", "Panel", gap: "PT15M", within: "PT2H")

  > *"The panel follows screening, no sooner than fifteen minutes
  > after and no later than two hours."*

  `:within` is measured from the end of the predecessor, not its
  start, so it does not shorten as the predecessor runs long.

  ### Why it is a pairwise constraint

  Precedence relates exactly two sessions, which is why it lives
  alongside the track and resource checks rather than needing new
  machinery. A chain of three is two precedences, and the search
  enforces them independently — it never has to reason about the
  chain as a whole.

  That is also why `Agenda.Arranger.conflict?/4` covers it, and so
  the fixpoint bridge gets precedence for free: both solvers ask the
  same question about the same pair.

  """

  alias Agenda.Availability

  @typedoc "An ordering between two sessions."
  @type t :: %__MODULE__{
          first: String.t(),
          then: String.t(),
          gap: Availability.pattern() | nil,
          within: Availability.pattern() | nil
        }

  defstruct [:first, :then, :gap, :within]

  @doc """
  Build a precedence.

  ### Arguments

  * `first` is the name of the session that must finish first.

  * `then` is the name of the session that follows it.

  ### Options

  * `:gap` is the least time that must pass between them, a duration.
    The default is none, meaning the successor may start immediately.

  * `:within` is the most time that may pass, measured from the end of
    `first`. The default is none, meaning no upper bound.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> precedence = Agenda.Precedence.new("Survey", "Quote", gap: "PT30M")
      iex> {precedence.first, precedence.then}
      {"Survey", "Quote"}

  """
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(first, then, options \\ []) when is_binary(first) and is_binary(then) do
    %__MODULE__{
      first: first,
      then: then,
      gap: Keyword.get(options, :gap),
      within: Keyword.get(options, :within)
    }
  end

  @doc """
  The precedence relating two sessions, whichever way round they are
  given, or `nil` when they are unordered.

  ### Arguments

  * `precedences` is a list of `t:t/0`.

  * `a` and `b` are session names.

  ### Returns

  * `{precedence, :in_order}` when `a` precedes `b`,
    `{precedence, :reversed}` when `b` precedes `a`, or `nil`.

  ### Examples

      iex> precedences = [Agenda.Precedence.new("Survey", "Quote")]
      iex> {_precedence, order} = Agenda.Precedence.between(precedences, "Quote", "Survey")
      iex> order
      :reversed

      iex> Agenda.Precedence.between([], "A", "B")
      nil

  """
  @spec between([t()], String.t(), String.t()) :: {t(), :in_order | :reversed} | nil
  def between(precedences, a, b) do
    Enum.find_value(precedences, fn precedence ->
      cond do
        precedence.first == a and precedence.then == b -> {precedence, :in_order}
        precedence.first == b and precedence.then == a -> {precedence, :reversed}
        true -> nil
      end
    end)
  end
end
