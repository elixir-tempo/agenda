defmodule Timetable.Predicate do
  @moduledoc """
  The attribute predicate vocabulary — the words a requirement is
  written in.

  These deliberately mirror the duration predicates `Tempo` already
  provides (`Tempo.at_least?/2`, `Tempo.at_most?/2`,
  `Tempo.exactly?/2`). One vocabulary applies to durations on the
  temporal side and to attributes here, so there is one set of words to
  learn rather than two.

  A predicate knows how to describe itself, which is what lets a failed
  match explain *why* in a sentence rather than returning `false`.

  ### Examples

      iex> import Timetable.Predicate
      iex> satisfied?(at_least(8), 12)
      true

      iex> import Timetable.Predicate
      iex> describe(at_least(8))
      "at least 8"

  """

  alias Tempo.Compare

  @typedoc "A comparison a resource attribute must satisfy."
  @type t :: t(op())

  @typedoc """
  A comparison whose operator is known — `t(:at_least)` is what
  `at_least/1` returns. The constructors are specified this precisely so
  that a misplaced predicate is a type error rather than a runtime
  surprise.
  """
  @type t(op) :: %__MODULE__{op: op, operand: term()}

  @typedoc "The supported comparisons."
  @type op :: :at_least | :at_most | :exactly | :any_of | :all_of | :none_of

  defstruct [:op, :operand]

  @doc """
  The attribute must be greater than or equal to `value`.

  ### Arguments

  * `value` is the inclusive lower bound.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> Timetable.Predicate.at_least(8).operand
      8

  """
  @spec at_least(term()) :: t(:at_least)
  def at_least(value), do: %__MODULE__{op: :at_least, operand: value}

  @doc """
  The attribute must be less than or equal to `value`.

  ### Arguments

  * `value` is the inclusive upper bound.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> Timetable.Predicate.at_most(4).operand
      4

  """
  @spec at_most(term()) :: t(:at_most)
  def at_most(value), do: %__MODULE__{op: :at_most, operand: value}

  @doc """
  The attribute must equal `value`. A bare value in a requirement is
  sugar for this.

  ### Arguments

  * `value` is the required value.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> Timetable.Predicate.exactly(:sydney).operand
      :sydney

  """
  @spec exactly(term()) :: t(:exactly)
  def exactly(value), do: %__MODULE__{op: :exactly, operand: value}

  @doc """
  The attribute must be one of `values`.

  ### Arguments

  * `values` is a list of acceptable values.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> Timetable.Predicate.any_of([:sydney, :melbourne]).op
      :any_of

  """
  @spec any_of([term()]) :: t()
  def any_of(values) when is_list(values), do: %__MODULE__{op: :any_of, operand: values}

  @doc """
  The attribute — itself a list — must contain every one of `values`.

  ### Arguments

  * `values` is a list of required members.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> Timetable.Predicate.all_of([:projector, :whiteboard]).op
      :all_of

  """
  @spec all_of([term()]) :: t()
  def all_of(values) when is_list(values), do: %__MODULE__{op: :all_of, operand: values}

  @doc """
  The attribute must be none of `values`.

  ### Arguments

  * `values` is a list of disqualifying values.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> Timetable.Predicate.none_of([:basement]).op
      :none_of

  """
  @spec none_of([term()]) :: t()
  def none_of(values) when is_list(values), do: %__MODULE__{op: :none_of, operand: values}

  @doc """
  Coerce a bare value into a predicate, leaving predicates untouched.

  This is what lets `video_conferencing: true` and
  `seats: at_least(8)` sit side by side in the same requirement.

  ### Arguments

  * `value` is a `t:t/0` or any bare term.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> Timetable.Predicate.coerce(true)
      %Timetable.Predicate{op: :exactly, operand: true}

      iex> predicate = Timetable.Predicate.at_least(8)
      iex> Timetable.Predicate.coerce(predicate) == predicate
      true

  """
  @spec coerce(t() | term()) :: t()
  def coerce(%__MODULE__{} = predicate), do: predicate
  def coerce(value), do: exactly(value)

  @doc """
  `true` when `value` satisfies `predicate`.

  A `nil` value — the attribute is absent from the resource — never
  satisfies a predicate, except `none_of/1`, which an absent attribute
  trivially satisfies.

  ### Arguments

  * `predicate` is a `t:t/0`.

  * `value` is the resource's attribute value, or `nil` when absent.

  ### Returns

  * `true` or `false`.

  ### Examples

      iex> import Timetable.Predicate
      iex> {satisfied?(at_least(8), 8), satisfied?(at_least(8), 4)}
      {true, false}

      iex> import Timetable.Predicate
      iex> satisfied?(at_least(8), nil)
      false

  """
  @spec satisfied?(t(), term()) :: boolean()
  def satisfied?(%__MODULE__{op: :none_of}, nil), do: true
  def satisfied?(%__MODULE__{}, nil), do: false

  def satisfied?(%__MODULE__{op: :at_least, operand: operand}, value) do
    compare(value, operand) in [:eq, :gt]
  end

  def satisfied?(%__MODULE__{op: :at_most, operand: operand}, value) do
    compare(value, operand) in [:eq, :lt]
  end

  def satisfied?(%__MODULE__{op: :exactly, operand: operand}, value) do
    compare(value, operand) == :eq
  end

  def satisfied?(%__MODULE__{op: :any_of, operand: operand}, value) do
    Enum.any?(operand, &(compare(value, &1) == :eq))
  end

  def satisfied?(%__MODULE__{op: :none_of, operand: operand}, value) do
    not Enum.any?(operand, &(compare(value, &1) == :eq))
  end

  def satisfied?(%__MODULE__{op: :all_of, operand: operand}, value) when is_list(value) do
    Enum.all?(operand, fn required -> Enum.any?(value, &(compare(&1, required) == :eq)) end)
  end

  def satisfied?(%__MODULE__{op: :all_of}, _value), do: false

  # Tempo values are ordered on the time line, never by Erlang term
  # order — comparing two `%Tempo{}` structs with `>=` compares their
  # maps field by field, which has nothing to do with chronology.
  # Everything else falls back to the standard term ordering, which is
  # what integers, atoms, and strings want.
  defp compare(%Tempo{} = value, %Tempo{} = operand) do
    case Compare.compare_endpoints(value, operand) do
      :earlier -> :lt
      :same -> :eq
      :later -> :gt
    end
  end

  defp compare(value, operand) when value < operand, do: :lt
  defp compare(value, operand) when value > operand, do: :gt
  defp compare(_value, _operand), do: :eq

  @doc """
  A phrase describing what `predicate` demands, for use in an
  explanation.

  ### Arguments

  * `predicate` is a `t:t/0`.

  ### Returns

  * a phrase such as `"at least 8"`, readable inside a sentence.

  ### Examples

      iex> import Timetable.Predicate
      iex> {describe(at_least(8)), describe(exactly(true))}
      {"at least 8", "true"}

  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{op: :at_least, operand: operand}), do: "at least #{inspect(operand)}"
  def describe(%__MODULE__{op: :at_most, operand: operand}), do: "at most #{inspect(operand)}"
  def describe(%__MODULE__{op: :exactly, operand: operand}), do: inspect(operand)
  def describe(%__MODULE__{op: :any_of, operand: operand}), do: "any of #{list(operand)}"
  def describe(%__MODULE__{op: :all_of, operand: operand}), do: "all of #{list(operand)}"
  def describe(%__MODULE__{op: :none_of, operand: operand}), do: "none of #{list(operand)}"

  defp list(values), do: Enum.map_join(values, ", ", &inspect/1)
end
