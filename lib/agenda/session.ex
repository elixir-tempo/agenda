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
  names the request in some scheduling libraries, not the thing
  requested).

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
          invitees: keyword([Resource.t()]),
          series: String.t() | nil
        }

  defstruct name: nil,
            duration: nil,
            window: nil,
            requirements: [],
            preferences: [],
            invitees: [],
            series: nil

  @doc """
  Build a session.

  ### Arguments

  * `name` is the session's name.

  ### Options

  * `:duration` is how long the session runs, a `t:Tempo.Duration.t/0`.

  * `:window` is the interval it must fall inside, a
    `t:Tempo.Interval.t/0`.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> import Tempo.Sigils
      iex> Agenda.Session.new("Quarterly review", duration: ~o"PT1H").name
      "Quarterly review"

  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, options \\ []) when is_binary(name) do
    %__MODULE__{
      name: name,
      duration: Keyword.get(options, :duration),
      window: Keyword.get(options, :window)
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
    `t:Agenda.Resource.t/0`. Naming nobody adds no requirement — a
    role filled by no one constrains nothing, and a requirement that
    neither names nor describes would otherwise let planning bind any
    resource at all to the role.

  ### Returns

  * the session with the requirement added, or unchanged if
    `resources` is empty.

  ### Examples

      iex> alice = Agenda.Resource.new("Alice")
      iex> session = Agenda.Session.new("Review")
      iex> session = Agenda.Session.roster(session, :attendees, [alice])
      iex> Enum.map(session.requirements, & &1.name)
      [:attendees]

      iex> session = Agenda.Session.new("Review")
      iex> Agenda.Session.roster(session, :attendees, []).requirements
      []

  """
  @spec roster(t(), atom(), [Resource.t()]) :: t()
  def roster(%__MODULE__{} = session, role, []) when is_atom(role) do
    session
  end

  def roster(%__MODULE__{} = session, role, resources) when is_atom(role) do
    add(session, Requirement.roster(role, resources))
  end

  # Naming a role twice states one demand in two calls. An arrangement
  # fills each role once, so keeping both requirements would let the
  # second displace the first and lose whatever the first asked for —
  # silently, and only at planning time. They are combined here
  # instead, where the caller can still see the result.
  #
  # A named role and a described one are not combined: "these four
  # people" and "any room seating 250" under one name is a
  # contradiction rather than a pair of demands, and merging them
  # would answer it by ignoring one.
  defp add(%__MODULE__{} = session, requirement) do
    case Enum.find_index(session.requirements, &combinable?(&1, requirement)) do
      nil ->
        %{session | requirements: session.requirements ++ [requirement]}

      index ->
        combined =
          List.update_at(session.requirements, index, &Requirement.merge(&1, requirement))

        %{session | requirements: combined}
    end
  end

  defp combinable?(%Requirement{name: name, roster: held}, %Requirement{name: name, roster: added}) do
    (held == [] and added == []) or (held != [] and added != [])
  end

  defp combinable?(_requirement, _addition), do: false

  @doc """
  Set the interval the session must fall inside.

  ### Arguments

  * `session` is a `t:t/0`.

  * `window` is a `t:Tempo.Interval.t/0`.

  ### Returns

  * the session, bounded.

  ### Examples

      iex> import Tempo.Sigils
      iex> session = Agenda.Session.new("Review")
      iex> Agenda.Session.window(session, ~o"2026-06-15/2026-06-20").window
      ~o"2026-06-15/2026-06-20"

  """
  @spec window(t(), Availability.pattern()) :: t()
  def window(%__MODULE__{} = session, window), do: %{session | window: window}

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
      iex> Agenda.Session.duration(session, ~o"PT1H").duration
      ~o"PT1H"

  """
  @spec duration(t(), Availability.pattern()) :: t()
  def duration(%__MODULE__{} = session, duration), do: %{session | duration: duration}

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

  @doc """
  Invite resources who may attend but are not required.

  The counterpart to `roster/3`. A rostered resource must be free or
  the session cannot be held; an invitee never affects whether a
  placement is possible, only how good it is — a time when more of
  them can come scores better, and `Agenda.Arrangement` records which
  of them the chosen time actually suits.

  This is deliberately weaker than `roster/3` in a second way: an
  invitee is **not allocated**. Their time is not taken and the ledger
  does not know about them, because a placement that consumed an
  optional person could make some *other* session impossible — and an
  optional attendee that can cost a placement is not optional. Book
  them with `Agenda.Ledger.allocate/3` once the time is settled, if
  they are coming.

  ### Arguments

  * `session` is a `t:t/0`.

  * `role` names what the invitees would be there as, the same way
    `roster/3` does.

  * `resources` is a list of `t:Agenda.Resource.t/0`.

  ### Returns

  * The session, with the invitees added.

  ### Examples

      iex> bob = Agenda.resource("Bob")
      iex> session = Agenda.session("Review", duration: "PT1H")
      iex> Agenda.Session.invite(session, :optional, [bob]).invitees
      [optional: [bob]]

  """
  @spec invite(t(), atom(), [Resource.t()]) :: t()
  def invite(%__MODULE__{} = session, _role, []), do: session

  def invite(%__MODULE__{} = session, role, resources)
      when is_atom(role) and is_list(resources) do
    %{session | invitees: Keyword.update(session.invitees, role, resources, &(&1 ++ resources))}
  end
end
