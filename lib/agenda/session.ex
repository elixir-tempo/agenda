defmodule Agenda.Session do
  @moduledoc """
  A session — the thing being scheduled.

  A session states how long it runs, the window it must fall inside,
  what it requires of resources, and what it would merely prefer. It
  says nothing about *when* it actually happens: that is what planning
  works out.

  The word is deliberately not "meeting" (too narrow — a court hearing
  and a conference talk are neither), not "event" (`Tempo.Event` is
  taken, and it collides with event sourcing), and not "booking" (which
  names the request in AshScheduling, not the thing requested).

  """

  alias Agenda.Availability
  alias Agenda.Requirement
  alias Agenda.Resource

  @typedoc "Something to be scheduled."
  @type t :: %__MODULE__{
          name: String.t(),
          duration: Availability.pattern() | nil,
          window: Availability.pattern() | nil,
          requirements: [Requirement.t()],
          preferences: keyword(),
          series: String.t() | nil
        }

  defstruct name: nil,
            duration: nil,
            window: nil,
            requirements: [],
            preferences: [],
            series: nil

  @doc """
  Build a session.

  ### Arguments

  * `name` is the session's name.

  ### Options

  * `:lasting` is how long the session runs, a `t:Tempo.Duration.t/0`.

  * `:between` is the window it must fall inside, a
    `t:Tempo.Interval.t/0`.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> import Tempo.Sigils
      iex> Agenda.Session.new("Quarterly review", lasting: ~o"PT1H").name
      "Quarterly review"

  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, options \\ []) when is_binary(name) do
    %__MODULE__{
      name: name,
      duration: Keyword.get(options, :lasting),
      window: Keyword.get(options, :between)
    }
  end

  @doc """
  Add an attribute requirement under `role`.

  ### Arguments

  * `session` is a `t:t/0`.

  * `role` is the role name, such as `:room`.

  * `predicates` is a keyword list of attribute predicates.

  ### Returns

  * the session with the requirement added.

  ### Examples

      iex> import Agenda.Predicate
      iex> session = Agenda.Session.new("Review")
      iex> session = Agenda.Session.needs(session, :room, seats: at_least(8))
      iex> Enum.map(session.requirements, & &1.name)
      [:room]

  """
  @spec needs(t(), atom(), keyword()) :: t()
  def needs(%__MODULE__{} = session, role, predicates) when is_atom(role) do
    add(session, Requirement.new(role, predicates))
  end

  @doc """
  Add a requirement naming specific resources under `role`.

  ### Arguments

  * `session` is a `t:t/0`.

  * `role` is the role name, such as `:attendees`.

  * `resources` is the list of required
    `t:Agenda.Resource.t/0`.

  ### Returns

  * the session with the requirement added.

  ### Examples

      iex> alice = Agenda.Resource.new("Alice")
      iex> session = Agenda.Session.new("Review")
      iex> session = Agenda.Session.roster(session, :attendees, [alice])
      iex> Enum.map(session.requirements, & &1.name)
      [:attendees]

  """
  @spec roster(t(), atom(), [Resource.t()]) :: t()
  def roster(%__MODULE__{} = session, role, resources) when is_atom(role) do
    add(session, Requirement.roster(role, resources))
  end

  defp add(%__MODULE__{} = session, requirement) do
    %{session | requirements: session.requirements ++ [requirement]}
  end

  @doc """
  Set the window the session must fall inside.

  ### Arguments

  * `session` is a `t:t/0`.

  * `window` is a `t:Tempo.Interval.t/0`.

  ### Returns

  * the session, bounded.

  ### Examples

      iex> import Tempo.Sigils
      iex> session = Agenda.Session.new("Review")
      iex> Agenda.Session.between(session, ~o"2026-06-15/2026-06-20").window
      ~o"2026-06-15/2026-06-20"

  """
  @spec between(t(), Availability.pattern()) :: t()
  def between(%__MODULE__{} = session, window), do: %{session | window: window}

  @doc """
  Set how long the session runs.

  ### Arguments

  * `session` is a `t:t/0`.

  * `duration` is a `t:Tempo.Duration.t/0`.

  ### Returns

  * the session, with its duration set.

  ### Examples

      iex> import Tempo.Sigils
      iex> session = Agenda.Session.new("Review")
      iex> Agenda.Session.lasting(session, ~o"PT1H").duration
      ~o"PT1H"

  """
  @spec lasting(t(), Availability.pattern()) :: t()
  def lasting(%__MODULE__{} = session, duration), do: %{session | duration: duration}

  @doc """
  Add soft preferences — they rank arrangements but never exclude one.

  ### Arguments

  * `session` is a `t:t/0`.

  * `preferences` is a keyword list. `within: place` prefers resources
    inside that place; any other key is matched against resource
    attributes.

  ### Returns

  * the session, with the preferences added.

  ### Examples

      iex> sydney = Agenda.Place.new("Sydney")
      iex> session = Agenda.Session.new("Review")
      iex> Agenda.Session.prefers(session, within: sydney).preferences |> Keyword.keys()
      [:within]

  """
  @spec prefers(t(), keyword()) :: t()
  def prefers(%__MODULE__{} = session, preferences) when is_list(preferences) do
    %{session | preferences: session.preferences ++ preferences}
  end

  @doc """
  The requirements naming specific resources.

  ### Arguments

  * `session` is a `t:t/0`.

  ### Returns

  * the roster requirements.

  ### Examples

      iex> alice = Agenda.Resource.new("Alice")
      iex> session = Agenda.Session.new("Review") |> Agenda.Session.roster(:attendees, [alice])
      iex> Enum.map(Agenda.Session.rosters(session), & &1.name)
      [:attendees]

  """
  @spec rosters(t()) :: [Requirement.t()]
  def rosters(%__MODULE__{requirements: requirements}) do
    Enum.filter(requirements, &(&1.roster != []))
  end

  @doc """
  The requirements described by attribute rather than named.

  Each of these is a role that planning must *choose* a resource for.

  ### Arguments

  * `session` is a `t:t/0`.

  ### Returns

  * the attribute requirements.

  ### Examples

      iex> session = Agenda.Session.new("Review") |> Agenda.Session.needs(:room, seats: 8)
      iex> Enum.map(Agenda.Session.open_roles(session), & &1.name)
      [:room]

  """
  @spec open_roles(t()) :: [Requirement.t()]
  def open_roles(%__MODULE__{requirements: requirements}) do
    Enum.filter(requirements, &(&1.roster == []))
  end

  @doc """
  Every resource named by a roster requirement.

  These are the resources whose own `requires` tighten the open roles —
  see `Agenda.Requirement.induce/2`.

  ### Arguments

  * `session` is a `t:t/0`.

  ### Returns

  * the named resources, in requirement order.

  ### Examples

      iex> alice = Agenda.Resource.new("Alice")
      iex> session = Agenda.Session.new("Review") |> Agenda.Session.roster(:attendees, [alice])
      iex> Enum.map(Agenda.Session.named_resources(session), & &1.name)
      ["Alice"]

  """
  @spec named_resources(t()) :: [Resource.t()]
  def named_resources(%__MODULE__{} = session) do
    session |> rosters() |> Enum.flat_map(& &1.roster)
  end
end
