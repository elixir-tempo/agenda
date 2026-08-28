defmodule Agenda.Interest do
  @moduledoc """
  One resource would like a session with another.

  Everything else in this library is supply: what exists, when it is
  free, and what may not collide. An interest is the other half —
  **demand** — and it is what turns a pile of resources into a
  programme without anybody writing the sessions by hand.

  The motivating case is a hosted-buyer programme, where buyers and
  suppliers register interest in each other and the organiser holds a
  meeting wherever the interest is returned. Interest that is not
  returned is not a meeting, which is why `mutual/1` is the function
  that matters and `one_sided/1` is reported separately rather than
  quietly scheduled.

  An interest is deliberately *not* a session. It says two parties
  would like to meet, and says nothing about when, for how long, or
  where — those belong to the session it becomes, and one set of
  interests can be turned into meetings of different lengths for
  different days without being restated.

  """

  alias Agenda.Resource

  @typedoc "A resource's stated interest in meeting another."
  @type t :: %__MODULE__{
          from: String.t(),
          to: String.t()
        }

  @typedoc "Two resources that named each other."
  @type pair :: {String.t(), String.t()}

  defstruct [:from, :to]

  @doc """
  Build an interest.

  ### Arguments

  * `from` is the resource registering the interest, as a
    `t:Agenda.Resource.t/0` or its name.

  * `to` is the resource it would like to meet, in the same two forms.

  ### Returns

  * `{:ok, interest}`; or

  * `{:error, :self_interest}` when a resource names itself, which no
    meeting can satisfy.

  ### Examples

      iex> {:ok, interest} = Agenda.Interest.new("Kim", "Harbour Tours")
      iex> {interest.from, interest.to}
      {"Kim", "Harbour Tours"}

      iex> Agenda.Interest.new("Kim", "Kim")
      {:error, :self_interest}

  """
  @spec new(Resource.t() | String.t(), Resource.t() | String.t()) ::
          {:ok, t()} | {:error, :self_interest}
  def new(from, to) do
    case {name_of(from), name_of(to)} do
      {same, same} -> {:error, :self_interest}
      {from_name, to_name} -> {:ok, %__MODULE__{from: from_name, to: to_name}}
    end
  end

  defp name_of(%Resource{name: name}), do: name
  defp name_of(name) when is_binary(name), do: name

  @doc """
  The pairs who named each other.

  Each pair is returned once, in a stable order, so the same set of
  interests always produces the same meetings regardless of the order
  they were registered in.

  ### Arguments

  * `interests` is a list of `t:t/0`.

  ### Returns

  * A list of `{first, second}` name pairs, sorted.

  ### Examples

      iex> {:ok, asked} = Agenda.Interest.new("Kim", "Harbour Tours")
      iex> {:ok, agreed} = Agenda.Interest.new("Harbour Tours", "Kim")
      iex> Agenda.Interest.mutual([asked, agreed])
      [{"Harbour Tours", "Kim"}]

      iex> {:ok, asked} = Agenda.Interest.new("Kim", "Harbour Tours")
      iex> Agenda.Interest.mutual([asked])
      []

  """
  @spec mutual([t()]) :: [pair()]
  def mutual(interests) when is_list(interests) do
    stated = MapSet.new(interests, &{&1.from, &1.to})

    interests
    |> Enum.filter(&MapSet.member?(stated, {&1.to, &1.from}))
    |> Enum.map(&canonical/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The interests that were never returned.

  Reported rather than scheduled: a meeting only one party asked for
  is a decision for the organiser, not something to book on their
  behalf.

  ### Arguments

  * `interests` is a list of `t:t/0`.

  ### Returns

  * A list of `t:t/0`, in the order they were registered.

  ### Examples

      iex> {:ok, asked} = Agenda.Interest.new("Kim", "Harbour Tours")
      iex> {:ok, agreed} = Agenda.Interest.new("Harbour Tours", "Kim")
      iex> {:ok, hopeful} = Agenda.Interest.new("Sam", "Harbour Tours")
      iex> Agenda.Interest.one_sided([asked, agreed, hopeful]) |> Enum.map(& &1.from)
      ["Sam"]

  """
  @spec one_sided([t()]) :: [t()]
  def one_sided(interests) when is_list(interests) do
    stated = MapSet.new(interests, &{&1.from, &1.to})

    Enum.reject(interests, &MapSet.member?(stated, {&1.to, &1.from}))
  end

  defp canonical(%__MODULE__{from: from, to: to}) when from <= to, do: {from, to}
  defp canonical(%__MODULE__{from: from, to: to}), do: {to, from}
end
