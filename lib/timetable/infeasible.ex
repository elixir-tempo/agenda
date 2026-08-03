defmodule Timetable.Infeasible do
  @moduledoc """
  Why a session cannot be held.

  Every infeasible result carries reasons, and the struct cannot be
  built without them — an empty explanation is a defect, not a
  degraded answer. "No arrangement found" tells a user nothing they can
  act on; "the Boardroom qualifies but is allocated to the Board
  meeting all week" tells them who to ask.

  """

  @typedoc "A session that cannot be placed, and why."
  @type t :: %__MODULE__{session: String.t(), reasons: [String.t(), ...]}

  defexception [:session, :reasons]

  @doc """
  Build an infeasible result.

  ### Arguments

  * `session` is the session's name.

  * `reasons` is a non-empty list of phrases explaining the failure.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> reason = Timetable.Infeasible.new("Review", ["no room seats 8"])
      iex> reason.reasons
      ["no room seats 8"]

  """
  @spec new(String.t(), [String.t(), ...]) :: t()
  def new(session, [_first | _rest] = reasons) when is_binary(session) do
    %__MODULE__{session: session, reasons: reasons}
  end

  @doc """
  The failure as a sentence.

  ### Arguments

  * `reason` is a `t:t/0`.

  ### Returns

  * a sentence naming the session and every reason.

  ### Examples

      iex> reason = Timetable.Infeasible.new("Review", ["no room seats 8", "Alice is away"])
      iex> Timetable.Infeasible.message(reason)
      "Review cannot be held: no room seats 8; Alice is away"

  """
  @impl Exception
  @spec message(t()) :: String.t()
  def message(%__MODULE__{session: session, reasons: reasons}) do
    "#{session} cannot be held: #{Enum.join(reasons, "; ")}"
  end

  @doc false
  @impl Exception
  def exception(options) when is_list(options) do
    new(Keyword.fetch!(options, :session), Keyword.fetch!(options, :reasons))
  end
end
