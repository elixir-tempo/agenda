defmodule Agenda do
  @moduledoc """
  Resource-constrained scheduling for `Tempo`.

  `Tempo` answers *when is this free?* This library answers *what
  should I book, and where?* — it adds the named resources, the
  attributes describing them, the places containing them, and the
  requirements a session places on them.

  ### The vocabulary

  * **Resource** — a named thing that can be allocated. People and
    rooms differ only in their attributes. See
    `Agenda.Resource`.

  * **Place** — a container of resources and other places, forming a
    tree. Travel between resources is *derived* from the tree rather
    than configured. See `Agenda.Place`.

  * **Requirement** — what a session demands, written in the predicate
    vocabulary of `Agenda.Predicate`. See
    `Agenda.Requirement`.

  * **Session** — something to be held: how long it runs, the window it
    must fall inside, and what it demands of resources. A session is a
    *request*, not a booking. See `Agenda.Session`.

  * **Programme** — sessions to be laid out together, with whatever
    relates them: tracks, orderings, preferences and interests. See
    `Agenda.Programme`.

  * **Track** — sessions that may not overlap each other, and that
    somebody following them must be able to travel between. Not
    overlapping is intrinsic to a track rather than an option on one:
    a set of sessions that may collide is already expressible, as a
    list. See `Agenda.Track`.

  * **Interest** — one resource would like a session with another.
    The demand side of the model: where interest is returned,
    `meetings/3` writes the sessions. See `Agenda.Interest`.

  * **Arrangement** — one workable way to hold a session: a particular
    interval, and the particular resources it would take. A *proposal*
    rather than a commitment — `plan/3` returns many, and none of them
    is booked. See `Agenda.Arrangement`.

  * **Allocation** — one resource, held for one session, over one
    interval. The unit a ledger stores, and what a `:tag` labels. See
    `Agenda.Allocation`.

  * **Ledger** — the record of what is allocated and to whom, and the
    only authority on it. Nothing stores availability: `free/2` is
    open hours minus what the ledger holds, computed when asked, so a
    booking cannot drift out of step with the calendar it came from.

    A ledger is an ordinary immutable value rather than a running
    store, and that is deliberate — it is what lets `arrange/3` fork
    one, try a layout, abandon it and try another. Durable shared
    state belongs in whatever persists the answer, not here. See
    `Agenda.Ledger`.

  ### Reading a match aloud

      iex> import Agenda.Predicate
      iex> boardroom = Agenda.resource("Boardroom", seats: 8, video_conferencing: true)
      iex> small = Agenda.resource("Meeting room 2", seats: 4)
      iex> needs_a_room = Agenda.needs(:room, seats: at_least(8), video_conferencing: true)
      iex> Agenda.eligible(needs_a_room, [boardroom, small])
      ...> |> Enum.map(& &1.name)
      ["Boardroom"]

  > *"Of the two rooms, only the boardroom seats eight and has video
  > conferencing."*

  And when a resource does not qualify, the reason is a sentence:

      iex> import Agenda.Predicate
      iex> small = Agenda.resource("Meeting room 2", seats: 4)
      iex> needs_a_room = Agenda.needs(:room, seats: at_least(8))
      iex> Agenda.explain(needs_a_room, small)
      "Meeting room 2: seats is 4 — needs at least 8"

  ### Status

  First release. Resources and places, matching by description or by
  name, derived availability, single-session planning, whole-programme
  arrangement, ordering, tracks, load limits, preferences, the
  allocation ledger, recurrence, reconciliation, and meetings
  generated from mutual interest are all here, and each has a guide.

  Two things are deliberately outside it. **Booking** — durable shared
  state, a clock, and concurrent claims — belongs in a sibling
  library, because the arranger's freedom to fork and abandon ledgers
  depends on a ledger being an ordinary value. And **holiday
  calendars** are accepted as data rather than resolved here, since
  jurisdiction rules have far broader use than scheduling. An
  adapter for Ash is planned; see
  [the plan](https://github.com/elixir-tempo/agenda/blob/v0.1.0/plans/agenda.md).

  """

  import Tempo.Sigils

  alias Agenda.Arrangement
  alias Agenda.Arranger
  alias Agenda.Availability
  alias Agenda.Infeasible
  alias Agenda.Layout
  alias Agenda.Ledger
  alias Agenda.Place
  alias Agenda.Planner
  alias Agenda.Preference
  alias Agenda.Programme
  alias Agenda.Reconciliation
  alias Agenda.Refine
  alias Agenda.Requirement
  alias Agenda.Resource
  alias Agenda.Series
  alias Agenda.Session
  alias Agenda.Track

  # How long it takes to travel between two resources, keyed by how far
  # apart they sit in the place tree. These are a starting guess, not a
  # survey of your building: override any specific pair with `:between`,
  # or replace the table wholesale with `:levels`.
  @default_levels %{0 => ~o"PT0M", 1 => ~o"PT5M", 2 => ~o"PT10M"}
  @default_distant ~o"PT20M"

  @doc """
  Build a place. Delegates to `Agenda.Place.new/2`.

  ### Arguments

  * `name` is the place's name.

  * `options` is a keyword list of options.

  ### Options

  * `:within` is the enclosing `t:Agenda.Place.t/0`. The default is `nil`, making
    this place a root.

  ### Returns

  * a `t:Agenda.Place.t/0`.

  ### Examples

      iex> Agenda.place("Level 2").name
      "Level 2"

  """
  @spec place(String.t(), keyword()) :: Place.t()
  defdelegate place(name, options \\ []), to: Place, as: :new

  @doc """
  Build a resource. Delegates to `Agenda.Resource.new/2`.

  ### Arguments

  * `name` is the resource's name.

  * `options` is a keyword list of options.

  ### Options

  * `:within` is the enclosing `t:Agenda.Place.t/0`. The
    default is `nil`.

  * `:requires` is a keyword list of attributes this resource demands
    of resources allocated alongside it. The default is `[]`.

  * `:concurrency` is how many sessions may hold this resource
    simultaneously. The default is `1`.

  * `:limits` budgets the resource *over a period*, as
    `[day: 1, week: 5]` — at most one shift a day and five a week.
    Recognised periods are `:day`, `:week` and `:month`. A value may be
    a count, a duration (`~o"PT7H36M"`), or a keyword list carrying
    `:at_most` and `:at_least`. This is not concurrency: concurrency is
    how many claims may overlap at one instant, a limit is how much
    falls inside a stretch of calendar however far apart. Parsed on
    construction, so a malformed limit raises here rather than being
    silently unenforced. The default is none. See `Agenda.Limit`.

  * `:avoids` is when the resource would *rather not* be used — a
    Tempo value, an ISO 8601 string, or a recurrence. Unlike `:open`
    this is a wish, not a rule: it makes a placement worse rather than
    invalid, and only counts when the programme declares the
    `:resource_wishes` preference. The default is none.

  * `:prefers` is the mirror — when the resource would *rather* be
    used. A placement outside it is a violation. The default is none.

  * `:open` is when the resource is available at all — see
    `Agenda.open/2`, which validates it. The default is `nil`,
    meaning the resource is never open.

  * `:buffer_before` is turnaround needed before each claim — set-up,
    travel in, a room being unlocked. A `t:Tempo.Duration.t/0`; the
    default is none.

  * `:buffer_after` is turnaround needed after each claim — cleaning,
    resetting the room, a machine cooling down. A
    `t:Tempo.Duration.t/0`; the default is none.

  * every other option is taken as an attribute.

  ### Returns

  * a `t:Agenda.Resource.t/0`.

  ### Examples

      iex> Agenda.resource("Boardroom", seats: 8).attributes
      %{seats: 8}

  """
  @spec resource(String.t(), keyword()) :: Resource.t()
  defdelegate resource(name, options \\ []), to: Resource, as: :new

  @doc """
  Build an attribute requirement. Delegates to
  `Agenda.Requirement.new/2`.

  ### Arguments

  * `name` is the role name, such as `:room`.

  * `predicates` is a keyword list of attribute predicates.

  ### Returns

  * a `t:Agenda.Requirement.t/0`.

  ### Examples

      iex> Agenda.needs(:room, seats: 8).name
      :room

  """
  @spec needs(atom(), keyword()) :: Requirement.t()
  defdelegate needs(name, predicates \\ []), to: Requirement, as: :new

  @doc """
  Build a requirement naming specific resources. Delegates to
  `Agenda.Requirement.roster/2`.

  ### Arguments

  * `name` is the role name, such as `:attendees`.

  * `resources` is the list of required `t:Agenda.Resource.t/0`.

  ### Returns

  * a `t:Agenda.Requirement.t/0`.

  ### Examples

      iex> alice = Agenda.resource("Alice")
      iex> Agenda.roster(:attendees, [alice]).name
      :attendees

  """
  @spec roster(atom(), [Resource.t()]) :: Requirement.t()
  defdelegate roster(name, resources), to: Requirement

  @doc """
  Invite resources who may attend but are not required. Delegates to
  `Agenda.Session.invite/3`.

  The counterpart to `roster/2`. An invitee never affects whether a
  session can be held, only which time is best: `Agenda.plan/3` scores
  a placement higher when more of them are free, and the arrangement
  records which of them it suits. They are not allocated — an optional
  attendee that could cost some other session its placement would not
  be optional.

  ### Arguments

  * `session` is a `t:Agenda.Session.t/0`.

  * `role` names what the invitees would be there as, the same way
    `Agenda.Session.roster/3` does.

  * `resources` is a list of `t:Agenda.Resource.t/0`.

  ### Returns

  * The session, with the invitees added.

  ### Examples

      iex> bob = Agenda.resource("Bob")
      iex> session = Agenda.session("Review", duration: "PT1H")
      iex> Agenda.invite(session, :optional, [bob]).invitees
      ...> |> Keyword.keys()
      [:optional]

  """
  @spec invite(Session.t(), atom(), [Resource.t()]) :: Session.t()
  defdelegate invite(session, role, resources), to: Session

  @doc """
  The resources satisfying `requirement`. Delegates to
  `Agenda.Requirement.eligible/2`.

  ### Arguments

  * `requirement` is a `t:Agenda.Requirement.t/0`.

  * `candidates` is a list of `t:Agenda.Resource.t/0`.

  ### Returns

  * the eligible resources, in the order given.

  ### Examples

      iex> boardroom = Agenda.resource("Boardroom", seats: 8)
      iex> Agenda.eligible(Agenda.needs(:room, seats: 8), [boardroom])
      ...> |> Enum.map(& &1.name)
      ["Boardroom"]

  """
  @spec eligible(Requirement.t(), [Resource.t()]) :: [Resource.t()]
  defdelegate eligible(requirement, candidates), to: Requirement

  @doc """
  Why `resource` does or does not satisfy `requirement`, as a sentence.

  ### Arguments

  * `requirement` is a `t:Agenda.Requirement.t/0`.

  * `resource` is a `t:Agenda.Resource.t/0`.

  ### Returns

  * a sentence naming the resource and every unmet attribute, or
    stating that it qualifies.

  ### Examples

      iex> import Agenda.Predicate
      iex> boardroom = Agenda.resource("Boardroom", seats: 8)
      iex> Agenda.explain(Agenda.needs(:room, seats: at_least(8)), boardroom)
      "Boardroom qualifies"

  """
  @spec explain(Requirement.t(), Resource.t()) :: String.t()
  def explain(%Requirement{} = requirement, %Resource{} = resource) do
    case Requirement.unmet(requirement, resource) do
      [] -> "#{resource.name} qualifies"
      reasons -> "#{resource.name}: #{Enum.join(reasons, "; ")}"
    end
  end

  @doc """
  Build a session. Delegates to `Agenda.Session.new/2`.

  ### Arguments

  * `name` is the session's name.

  * `options` is a keyword list of options.

  ### Options

  * `:duration` is how long the session runs, a `t:Tempo.Duration.t/0`.

  * `:window` is the interval it must fall inside, a
    `t:Tempo.t/0` interval.

  ### Returns

  * a `t:Agenda.Session.t/0`.

  ### Examples

      iex> Agenda.session("Review", duration: "PT1H").name
      "Review"

  """
  @spec session(String.t(), keyword()) :: Session.t()
  defdelegate session(name, options \\ []), to: Session, as: :new

  @doc """
  Set when a resource is open. Delegates to
  `Agenda.Availability.open/2`.

  ### Arguments

  * `resource` is a `t:Agenda.Resource.t/0`.

  * `pattern` is a Tempo value, an ISO 8601 string (preferred), or an
    RFC 5545 `RRULE` string.

  ### Returns

  * `{:ok, resource}` with its open hours set, or

  * `{:error, reason}` when `pattern` cannot be read as a span.

  ### Examples

      iex> boardroom = Agenda.resource("Boardroom")
      iex> {:ok, boardroom} = Agenda.open(boardroom, "2026-06-15T09:00:00/2026-06-15T17:00:00")
      iex> is_nil(boardroom.open)
      false

  """
  @spec open(Resource.t(), Availability.pattern()) :: {:ok, Resource.t()} | {:error, term()}
  defdelegate open(resource, pattern), to: Availability

  @doc """
  Open hours on a resource, raising on a pattern it cannot read.
  Delegates to `Agenda.Availability.open!/2`.

  The `!` companion to `open/2`, for a pattern that is a literal in the
  source — a guide, a notebook, a fixture — where the tuple is ceremony
  around what cannot fail except by typo.

  ### Arguments

  * `resource` is a `t:Agenda.Resource.t/0`.

  * `pattern` is as for `Agenda.Availability.open/2`.

  ### Returns

  * the resource with its open hours set; or raises `ArgumentError`.

  ### Examples

      iex> import Tempo.Sigils
      iex> Agenda.open!(Agenda.resource("Boardroom"), ~o"2026-06-15T09:00:00/2026-06-15T17:00:00").open
      ~o"2026Y6M15DT9H0M0S/2026Y6M15DT17H0M0S"

  """
  @spec open!(Resource.t(), Availability.pattern()) :: Resource.t()
  defdelegate open!(resource, pattern), to: Availability

  @doc """
  Read open hours from an RFC 7953 `VAVAILABILITY`. Delegates to
  `Agenda.Availability.from_ical/1`.

  This is what a CalDAV server hands you when asked when someone is
  available. The result is a pattern for `open/2`.

  Hours imported in UTC (`Z`) or in a zone are on that time line, and a
  claim, a refinement or a session's window combined with them is written
  on it too: a floating one beside them is a `Tempo.FrameError`, as Tempo
  has it. A `within:` window alone may be floating, and is read on the
  hours' clock.

  ### Arguments

  * `ics` is iCalendar data as a string.

  ### Returns

  * `{:ok, pattern}` to hand to `Agenda.Availability.open/2`, or

  * `{:error, reason}` when the data cannot be read, or when `ical`
    is not available.

  ### Examples

      iex> ics = \"\"\"
      ...> BEGIN:VCALENDAR
      ...> VERSION:2.0
      ...> BEGIN:VAVAILABILITY
      ...> UID:consulting-room
      ...> DTSTAMP:20260601T000000Z
      ...> BEGIN:AVAILABLE
      ...> UID:tuesdays
      ...> DTSTAMP:20260601T000000Z
      ...> DTSTART:20260602T090000Z
      ...> DTEND:20260602T170000Z
      ...> RRULE:FREQ=WEEKLY;BYDAY=TU
      ...> END:AVAILABLE
      ...> END:VAVAILABILITY
      ...> END:VCALENDAR
      ...> \"\"\"
      iex> {:ok, hours} = Agenda.from_ical(ics)
      iex> {:ok, room} = Agenda.open(Agenda.resource("Consulting room"), hours)
      iex> {:ok, free} = Agenda.free(room, within: "2026-06-01/2026-06-30")
      iex> Tempo.IntervalSet.count(free)
      5

  """
  @spec from_ical(String.t()) ::
          {:ok, Availability.imported()} | {:error, :ical_not_available | String.t()}
  defdelegate from_ical(ics), to: Availability

  @doc """
  When a resource is open and not already taken. Delegates to
  `Agenda.Availability.free/2`.

  ### Arguments

  * `resource` is a `t:Agenda.Resource.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:within` is the query window — a Tempo value or ISO 8601 string.
    Required: an unbounded recurrence has no materialisation without
    one.

  * `:busy` is what already claims the resource — a Tempo value, a
    string, a `t:Tempo.t/0` interval set, or a list of them. The
    default is `[]`.

  ### Returns

  * `{:ok, interval_set}` of the free spans, or

  * `{:error, reason}` when the window or a pattern cannot be read.

  ### Examples

      iex> boardroom = Agenda.resource("Boardroom")
      iex> {:ok, boardroom} = Agenda.open(boardroom, "2026-06-15T09:00:00/2026-06-15T17:00:00")
      iex> {:ok, free} = Agenda.free(boardroom, within: "2026-06-15/2026-06-15")
      iex> Tempo.IntervalSet.count(free)
      1

  """
  @spec free(Resource.t(), keyword()) :: {:ok, Tempo.t()} | {:error, term()}
  defdelegate free(resource, options), to: Availability

  @doc """
  Keep only free time inside `constraint`. Delegates to
  `Agenda.Refine.only_during/2`.

  ### Arguments

  * `free` is an interval set, or the `{:ok, set}` from a previous
    step.

  * `constraint` is a Tempo value or ISO 8601 string bounding it.

  ### Returns

  * `{:ok, interval_set}`, or

  * `{:error, reason}`, including any error passed in.

  ### Examples

      iex> {:ok, room} = Agenda.open(Agenda.resource("R"), "2027-03-02T09:00:00/2027-03-02T17:00:00")
      iex> {:ok, clinic} =
      ...>   room
      ...>   |> Agenda.free(within: "2027-03-02/2027-03-02")
      ...>   |> Agenda.only_during("2027-03-02T13:00:00/2027-03-02T16:00:00")
      iex> Tempo.IntervalSet.count(clinic)
      1

  """
  @spec only_during(Refine.refinable(), Availability.pattern()) ::
          {:ok, Tempo.t()} | {:error, term()}
  defdelegate only_during(free, constraint), to: Refine

  @doc """
  Keep only free time inside any of `constraints`. Delegates to
  `Agenda.Refine.during_any/2`.

  ### Arguments

  * `free` is an interval set, or the `{:ok, set}` from a previous
    step.

  * `constraints` is a list of Tempo values or ISO 8601 strings.

  ### Returns

  * `{:ok, interval_set}`, or

  * `{:error, reason}`.

  ### Examples

      iex> {:ok, room} = Agenda.open(Agenda.resource("R"), "2027-03-02T09:00:00/2027-03-02T17:00:00")
      iex> {:ok, staffed} =
      ...>   room
      ...>   |> Agenda.free(within: "2027-03-02/2027-03-02")
      ...>   |> Agenda.during_any(["2027-03-02T09:00:00/2027-03-02T10:00:00"])
      iex> Tempo.IntervalSet.count(staffed)
      1

  """
  @spec during_any(Refine.refinable(), [Availability.pattern()]) ::
          {:ok, Tempo.t()} | {:error, term()}
  defdelegate during_any(free, constraints), to: Refine

  @doc """
  Keep only windows of at least `duration`. Delegates to
  `Agenda.Refine.lasting_at_least/2`.

  ### Arguments

  * `free` is an interval set, or the `{:ok, set}` from a previous
    step.

  * `duration` is the shortest useful window, a `t:Tempo.Duration.t/0`
    or ISO 8601 string.

  ### Returns

  * `{:ok, interval_set}`, or

  * `{:error, reason}`.

  ### Examples

      iex> {:ok, room} = Agenda.open(Agenda.resource("R"), "2027-03-02T09:00:00/2027-03-02T09:30:00")
      iex> {:ok, usable} =
      ...>   room
      ...>   |> Agenda.free(within: "2027-03-02/2027-03-02")
      ...>   |> Agenda.lasting_at_least("PT1H")
      iex> Tempo.empty?(usable)
      true

  """
  @spec lasting_at_least(Refine.refinable(), Availability.pattern()) ::
          {:ok, Tempo.t()} | {:error, term()}
  defdelegate lasting_at_least(free, duration), to: Refine

  @doc """
  Expand a repeating session into its occurrences. Delegates to
  `Agenda.Series.expand/3`.

  ### Arguments

  * `session` is the `t:Agenda.Session.t/0` to repeat. Its own
    window, if any, is replaced by each occurrence's.

  * `pattern` is a recurrence — an ISO 8601 repeating interval
    (preferred) or an RFC 5545 `RRULE`.

  * `options` is a keyword list of options.

  ### Options

  * `:bound` bounds an otherwise unbounded recurrence: the occurrences
    that overlap it are expanded. Required when `pattern` does not state
    its own count or end.

  ### Returns

  * `{:ok, sessions}`, one per occurrence, in time order, or

  * `{:error, reason}` when the pattern cannot be read or is unbounded
    and unbounded by `:bound`.

  ### Examples

      iex> standup = Agenda.session("Stand-up", duration: "PT15M")
      iex> {:ok, occurrences} = Agenda.every(standup, "R3/2027-03-02T09:00:00/P1W")
      iex> length(occurrences)
      3

  """
  @spec every(Session.t(), Availability.pattern(), keyword()) ::
          {:ok, [Session.t()]} | {:error, term()}
  defdelegate every(session, pattern, options \\ []), to: Series, as: :expand

  @doc """
  Rank the ways a session could be held. Delegates to
  `Agenda.Planner.plan/3`.

  ### Arguments

  * `session` is a `t:Agenda.Session.t/0` with a duration and a
    window.

  * `pool` is the list of `t:Agenda.Resource.t/0` available to
    choose from.

  * `options` is a keyword list of options.

  ### Options

  * `:busy` is a map of resource name to what already claims it — any
    value `Agenda.Availability.free/2` accepts. The default is
    `%{}`.

  * `:limit` is the most arrangements to return. The default is `20`.
    Truncation is reported rather than silent — see `:truncated?` on
    the result.

  * `:spread` chooses *how* the list is truncated. `false`, the
    default, keeps the best `:limit` placements, which is what a caller
    picking one time wants. `true` samples start moments evenly across
    the window instead and round-robins between them, trading depth at
    the front of the window for coverage of all of it — which is what
    `Agenda.Arranger.arrange/3` needs, since sessions handed identical
    placements collide. The coverage is what makes a cap safe to set:
    with `:spread`, `limit: 4` over two days offers both days rather
    than four times on the first.

  ### Returns

  * `{:ok, arrangements}` ranked best-first, or

  * `{:error, t:Agenda.Infeasible.t/0}` carrying the reasons — which
    includes a session that never said when it may be held.

  ### Examples

      iex> boardroom = Agenda.resource("Boardroom", seats: 8)
      iex> {:ok, boardroom} = Agenda.open(boardroom, "2026-06-15T09:00:00/2026-06-15T11:00:00")
      iex> session =
      ...>   Agenda.session("Review", duration: "PT1H", window: "2026-06-15/2026-06-15")
      ...>   |> Agenda.Session.needs(:room, seats: 8)
      iex> {:ok, [best | _]} = Agenda.plan(session, [boardroom])
      iex> Agenda.explain(best)
      "2026Y6M15DT9H0M0S/T10H0M0S — room: Boardroom"

  """
  @spec plan(Session.t(), [Resource.t()], keyword()) ::
          {:ok, [Arrangement.t()]} | {:error, Infeasible.t()}
  defdelegate plan(session, pool, options \\ []), to: Planner

  @doc """
  Describe an arrangement, a partial layout, or an infeasible result as
  a sentence.

  ### Arguments

  * `result` is a `t:Agenda.Arrangement.t/0`, a
    `t:Agenda.Layout.t/0`, or a `t:Agenda.Infeasible.t/0`.

  ### Returns

  * a sentence.

  ### Examples

      iex> reason = Agenda.Infeasible.new("Review", ["no room seats 8"])
      iex> Agenda.explain(reason)
      "Review cannot be held: no room seats 8"

      iex> reason = Agenda.Infeasible.new("Workshop", ["no room seats 8"])
      iex> Agenda.explain(Agenda.Layout.new("Conf", [], [reason]))
      "Conf: 0 of 1 sessions placed. Workshop cannot be held: no room seats 8"

  """
  @spec explain(Arrangement.t() | Layout.t() | Infeasible.t()) :: String.t()
  def explain(result)

  def explain(%Arrangement{} = arrangement) do
    Arrangement.explain(arrangement)
  end

  def explain(%Layout{} = layout) do
    Layout.explain(layout)
  end

  def explain(%Infeasible{} = reason) do
    Infeasible.message(reason)
  end

  @doc """
  An empty ledger. Delegates to `Agenda.Ledger.new/0`.

  ### Returns

  * a `t:Agenda.Ledger.t/0` holding no allocations.

  ### Examples

      iex> Agenda.count(Agenda.ledger())
      0

  """
  @spec ledger() :: Ledger.t()
  defdelegate ledger, to: Ledger, as: :new

  @doc """
  Record an arrangement. Delegates to `Agenda.Ledger.allocate/3`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `arrangement` is a `t:Agenda.Arrangement.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:tag` is what the claim was for, as a `t:Agenda.Allocation.tag/0`
    — `{:project, "ACME-2026-01"}`, `{:leave, :annual}`. Recorded on
    every allocation the arrangement implies, and grouped on by
    `Agenda.reconcile/3`. The default is `nil`.

  ### Returns

  * `{:ok, ledger}`.

  ### Examples

      iex> import Tempo.Sigils
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [Agenda.resource("Boardroom")]}
      ...> }
      iex> {:ok, ledger} = Agenda.allocate(Agenda.ledger(), arrangement)
      iex> Agenda.count(ledger)
      1

  Tagging what the time was for:

      iex> import Tempo.Sigils
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Discovery",
      ...>   interval: ~o"2026-06-16T09:00:00/2026-06-16T17:00:00",
      ...>   allocations: %{consultant: [Agenda.resource("Dana")]}
      ...> }
      iex> {:ok, ledger} = Agenda.allocate(Agenda.ledger(), arrangement, tag: {:project, "ACME"})
      iex> ledger
      ...> |> Agenda.Ledger.to_list()
      ...> |> Enum.map(& &1.tag)
      [project: "ACME"]

  """
  @spec allocate(Ledger.t(), Arrangement.t(), keyword()) :: {:ok, Ledger.t()}
  defdelegate allocate(ledger, arrangement, options \\ []), to: Ledger

  @doc """
  Book one resource over one interval, refusing what it cannot honour.
  Delegates to `Agenda.Ledger.claim/4`.

  `record/4` writes down what happened; `claim/4` books what is to
  happen, and checks. See `Agenda.Ledger.claim/4` for why a timesheet
  wants the first and a schedule wants the second.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `resource` is the `t:Agenda.Resource.t/0` being claimed.

  * `interval` is when — a Tempo value or an ISO 8601 string.

  * `options` is a keyword list of options.

  ### Options

  * `:tag` is what the claim is for, as a `t:Agenda.Allocation.tag/0`.

  * `:role` is the role the resource is filling. The default is
    `:resource`.

  * `:session` names the claim, and is what `Agenda.Ledger.release/2` takes. The
    default is the interval's ISO 8601 form, which is unique per
    resource per span.

  ### Returns

  * `{:ok, ledger}`, or

  * `{:error, reason}` — a sentence naming the time that could not be
    claimed and why, when the resource is not open then or is already
    claimed for part of it.

  ### Examples

      iex> import Tempo.Sigils
      iex> {:ok, dana} = Agenda.open(Agenda.resource("Dana"), "2026-08-10T09:00:00/2026-08-10T17:00:00")
      iex> {:ok, ledger} = Agenda.claim(Agenda.ledger(), dana, ~o"2026-08-10T09:00:00/2026-08-10T12:00:00", tag: {:project, "ACME"})
      iex> ledger
      ...> |> Agenda.Ledger.to_list()
      ...> |> Enum.map(& &1.tag)
      [project: "ACME"]

      iex> import Tempo.Sigils
      iex> {:ok, dana} = Agenda.open(Agenda.resource("Dana"), "2026-08-10T09:00:00/2026-08-10T17:00:00")
      iex> Agenda.claim(Agenda.ledger(), dana, ~o"2026-08-10T16:00:00/2026-08-10T19:00:00")
      {:error, "Dana is not open for 2026Y8M10DT17H0M0S/T19H0M0S"}

  """
  @spec claim(Ledger.t(), Resource.t(), Availability.pattern(), keyword()) ::
          {:ok, Ledger.t()} | {:error, term()}
  defdelegate claim(ledger, resource, interval, options \\ []), to: Ledger

  @doc """
  Record one resource over one interval, checking nothing. Delegates
  to `Agenda.Ledger.record/4`.

  The unchecked half of the pair `claim/4` completes: a schedule is a
  request and must be validated, a timesheet is a record and the world
  is not obliged to match the contract. See `Agenda.Ledger.record/4`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `resource` is the `t:Agenda.Resource.t/0` whose time is recorded.

  * `interval` is when — a Tempo value or an ISO 8601 string.

  * `options` is a keyword list of options.

  ### Options

  As `Agenda.Ledger.claim/4`: `:tag`, `:role` and `:session`.

  ### Returns

  * `{:ok, ledger}`, or

  * `{:error, reason}` when `interval` cannot be read as a span. Never
    for a reason of availability — that is `Agenda.Ledger.claim/4`'s business.

  ### Examples

      iex> import Tempo.Sigils
      iex> {:ok, dana} = Agenda.open(Agenda.resource("Dana"), "2026-08-10T09:00:00/2026-08-10T17:00:00")
      iex> {:ok, ledger} = Agenda.record(Agenda.ledger(), dana, ~o"2026-08-15T09:00:00/2026-08-15T12:00:00", tag: {:project, "ACME"})
      iex> ledger
      ...> |> Agenda.Ledger.to_list()
      ...> |> Enum.map(& &1.tag)
      [project: "ACME"]

  """
  @spec record(Ledger.t(), Resource.t(), Availability.pattern(), keyword()) ::
          {:ok, Ledger.t()} | {:error, term()}
  defdelegate record(ledger, resource, interval, options \\ []), to: Ledger

  @doc """
  Free everything a session holds. Delegates to
  `Agenda.Ledger.release/2`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `session` is the session's name.

  ### Returns

  * `{:ok, ledger}`. Releasing a session that holds nothing is a no-op,
    so this is safe to call twice.

  ### Examples

      iex> {:ok, ledger} = Agenda.release(Agenda.ledger(), "Review")
      iex> Agenda.count(ledger)
      0

  """
  @spec release(Ledger.t(), String.t()) :: {:ok, Ledger.t()}
  defdelegate release(ledger, session), to: Ledger

  @doc """
  Claim resources tentatively, until a moment. Delegates to
  `Agenda.Ledger.hold/3`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `arrangement` is a `t:Agenda.Arrangement.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:until` is when the hold lapses — a Tempo value or an ISO 8601
    string. Required.

  * `:tag` is what the claim was for, as a `t:Agenda.Allocation.tag/0`.
    A hold occupies a resource exactly as a booking does, so it carries
    the same tag. The default is `nil`.

  ### Returns

  * `{:ok, ledger}`, or

  * `{:error, reason}` when `:until` cannot be read as a moment.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Agenda.resource("Boardroom")
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Agenda.hold(Agenda.ledger(), arrangement,
      ...>                   until: "2026-06-15T10:15:00")
      iex> Agenda.holds(ledger)
      ...> |> length()
      1

  """
  @spec hold(Ledger.t(), Arrangement.t(), keyword()) :: {:ok, Ledger.t()} | {:error, term()}
  defdelegate hold(ledger, arrangement, options), to: Ledger

  @doc """
  Turn a session's hold into a firm allocation. Delegates to
  `Agenda.Ledger.confirm/2`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `session` is the session's name.

  ### Returns

  * `{:ok, ledger}`. Confirming a session that holds nothing, or one
    already firm, is a no-op.

  ### Examples

      iex> {:ok, ledger} = Agenda.confirm(Agenda.ledger(), "Review")
      iex> Agenda.count(ledger)
      0

  """
  @spec confirm(Ledger.t(), String.t()) :: {:ok, Ledger.t()}
  defdelegate confirm(ledger, session), to: Ledger

  @doc """
  Drop every hold that has lapsed by a moment. Delegates to
  `Agenda.Ledger.expire/2`.

  Nothing expires on its own — this is what advances time, and it
  takes the moment as an argument so that no function in this library
  reads a clock.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `now` is the current moment — a Tempo value or an ISO 8601 string.

  ### Returns

  * `{:ok, ledger}` with lapsed holds removed, or

  * `{:error, reason}` when `now` cannot be read as a moment.

  ### Examples

      iex> {:ok, ledger} = Agenda.expire(Agenda.ledger(), "2026-06-15T10:15:00")
      iex> Agenda.count(ledger)
      0

  """
  @spec expire(Ledger.t(), Availability.pattern()) :: {:ok, Ledger.t()} | {:error, term()}
  defdelegate expire(ledger, now), to: Ledger

  @doc """
  Whether a resource's claims account for the time it owed. Delegates
  to `Agenda.Reconciliation.reconcile/3`.

  The schedule and the timesheet are the same ledger read forwards and
  backwards, so reconciling is a set difference rather than a sum:
  `unaccounted` names *which* time is missing, not merely how much.

  Holidays are not this library's business — pass them in through
  `:excluding` as an ordinary interval set, from wherever they are
  resolved.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `resource` is a `t:Agenda.Resource.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:within` is the window to reconcile — a Tempo value or an ISO 8601
    string. Required, because open hours may be an unbounded recurrence
    and have no materialisation without one.

  * `:excluding` is time the resource did not owe — public holidays, a
    shutdown — as a `t:Tempo.t/0` interval set, any Tempo value that
    denotes a span (a bare day, `~o"2026-08-12"`, is the natural way to
    write a holiday), a string, or a list of any of those. Subtracted from the expectation before any claim is
    compared against it. The default is none.

  * `:expected` states the owed time outright, as an
    `t:Tempo.t/0` interval set, instead of deriving it from the
    resource's open hours. `:excluding` still applies to it.

  ### Returns

  * `{:ok, reconciliation}`, or

  * `{:error, reason}` when the window or a set cannot be read.

  ### Examples

      iex> import Tempo.Sigils
      iex> {:ok, dana} =
      ...>   Agenda.open(Agenda.resource("Dana"), ~o"2026-06-16T09:00:00/2026-06-16T17:00:00")
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Acme",
      ...>   interval: ~o"2026-06-16T09:00:00/2026-06-16T12:00:00",
      ...>   allocations: %{consultant: [dana]}
      ...> }
      iex> {:ok, ledger} = Agenda.allocate(Agenda.ledger(), arrangement, tag: {:project, "ACME"})
      iex> {:ok, report} = Agenda.reconcile(ledger, dana, within: ~o"2026-06-16/2026-06-16")
      iex> Agenda.Reconciliation.explain(report)
      ["Dana: 5 hours unaccounted — 2026Y6M16DT12H0M0S/T17H0M0S"]

  """
  @spec reconcile(Ledger.t(), Resource.t(), keyword()) ::
          {:ok, Reconciliation.t()} | {:error, term()}
  defdelegate reconcile(ledger, resource, options), to: Reconciliation

  @doc """
  Every allocation that is still only a hold. Delegates to
  `Agenda.Ledger.holds/1`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  ### Returns

  * the held allocations, ordered as `Agenda.Ledger.to_list/1` orders them.

  ### Examples

      iex> Agenda.holds(Agenda.ledger())
      []

  """
  @spec holds(Ledger.t()) :: [Agenda.Allocation.t()]
  defdelegate holds(ledger), to: Ledger

  @doc """
  Free everything held by a whole series. Delegates to
  `Agenda.Ledger.release_series/3`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `series` is the series name — the original session's name, before
    it was expanded.

  * `options` is a keyword list of options.

  ### Options

  * `:from` releases only the occurrences starting at or after this
    point, a Tempo value or ISO 8601 string. Cancelling the rest of a
    term should not unpick the sessions already held.

  ### Returns

  * `{:ok, ledger}`, or

  * `{:error, reason}` when `:from` cannot be read.

  ### Examples

      iex> Agenda.release_series(Agenda.ledger(), "Stand-up")
      {:ok, Agenda.ledger()}

  """
  @spec release_series(Ledger.t(), String.t(), keyword()) ::
          {:ok, Ledger.t()} | {:error, term()}
  defdelegate release_series(ledger, series, options \\ []), to: Ledger

  @doc """
  What would change if a session moved. Delegates to
  `Agenda.Ledger.diff/3`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `session` is the session's name.

  * `arrangement` is the `t:Agenda.Arrangement.t/0` it should move
    to.

  ### Returns

  * a list of `t:Agenda.Ledger.change/0`, ordered `:keep`, then `:release`, then
    `:allocate`.

  ### Examples

      iex> import Tempo.Sigils
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [Agenda.resource("Boardroom")]}
      ...> }
      iex> Agenda.rearrange(Agenda.ledger(), "Review", arrangement)
      ...> |> Enum.map(&elem(&1, 0))
      [:allocate]

  """
  @spec rearrange(Ledger.t(), String.t(), Arrangement.t()) :: [Ledger.change()]
  defdelegate rearrange(ledger, session, arrangement), to: Ledger, as: :diff

  @doc """
  What each resource is already claimed for. Delegates to
  `Agenda.Ledger.busy/2`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:except` is a session name, or a list of them, whose allocations
    are ignored — use it when re-planning a session so it does not
    collide with the copy of itself it is about to replace, or when
    pinning sessions in `Agenda.arrange/3`, which claims what its
    pins hold and so must not be told about them twice.

  ### Returns

  * a map of resource name to the intervals claiming it.

  ### Examples

      iex> Agenda.busy(Agenda.ledger())
      %{}

  """
  @spec busy(Ledger.t(), keyword()) :: %{optional(String.t()) => [Tempo.t()]}
  defdelegate busy(ledger, options \\ []), to: Ledger

  @doc """
  How many allocations a ledger holds. Delegates to
  `Agenda.Ledger.count/1`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  ### Returns

  * the count.

  ### Examples

      iex> Agenda.count(Agenda.ledger())
      0

  """
  @spec count(Ledger.t()) :: non_neg_integer()
  defdelegate count(ledger), to: Ledger

  @doc """
  Build a track — sessions that cannot clash with each other.
  Delegates to `Agenda.Track.new/2`.

  ### Arguments

  * `name` is the track's name.

  * `options` is a keyword list of options.

  ### Options

  * `:of` is the list of `t:Agenda.Session.t/0` in the track. The
    default is `[]`.

  ### Returns

  * a `t:Agenda.Track.t/0`.

  ### Examples

      iex> Agenda.track("Elixir", of: [Agenda.session("Keynote")]).name
      "Elixir"

  """
  @spec track(String.t(), keyword()) :: Track.t()
  defdelegate track(name, options \\ []), to: Track, as: :new

  @doc """
  Require that a delegate can get between consecutive track sessions.
  Delegates to `Agenda.Track.reachable/2`.

  ### Arguments

  * `track` is a `t:Agenda.Track.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:within` is the longest journey a delegate is expected to make, a
    duration.

  ### Returns

  * `{:ok, track}` with the reachability requirement set, or

  * `{:error, {:missing_option, :within}}`.

  ### Examples

      iex> import Tempo.Sigils
      iex> {:ok, track} =
      ...>   Agenda.track("Elixir")
      ...>   |> Agenda.reachable(within: ~o"PT10M")
      iex> track.reachable_within
      ~o"PT10M"

  """
  @spec reachable(Track.t(), keyword()) :: {:ok, Track.t()} | {:error, {:missing_option, :within}}
  defdelegate reachable(track, options), to: Track

  @doc """
  Build a programme. Delegates to `Agenda.Programme.new/2`.

  ### Arguments

  * `name` is the programme's name.

  * `options` is a keyword list of options.

  ### Options

  * `:across` is the window every session must fall inside.

  ### Returns

  * a `t:Agenda.Programme.t/0`.

  ### Examples

      iex> Agenda.programme("ElixirConf AU").name
      "ElixirConf AU"

  """
  @spec programme(String.t(), keyword()) :: Programme.t()
  defdelegate programme(name, options \\ []), to: Programme, as: :new

  @doc """
  Find a placement for every session in a programme. Delegates to
  `Agenda.Arranger.arrange/3`.

  ### Arguments

  * `programme` is a `t:Agenda.Programme.t/0`.

  * `pool` is the list of `t:Agenda.Resource.t/0` to choose from.

  * `options` is a keyword list of options.

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

  * `:score_nodes` caps the search steps of the second pass, which
    looks for a better-scoring layout once the first has proved how
    many sessions can be placed. The default is `2_000`; a layout that
    stops at it reports `score_proven?: false`.

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
    programme order, or

  * `{:partial, t:Agenda.Layout.t/0}` under `unplaced: :allow`, when
    some sessions could not be held, or

  * `{:error, t:Agenda.Infeasible.t/0}` naming the session that
    could not be placed, reporting a bad pin, or reporting that the cap
    was hit.

  ### Examples

      iex> room = Agenda.resource("Hall", seats: 100)
      iex> {:ok, room} = Agenda.open(room, "2026-09-15T09:00:00/2026-09-15T11:00:00")
      iex> talk = Agenda.session("Keynote", duration: "PT1H")
      ...>         |> Agenda.Session.needs(:room, seats: 100)
      iex> programme =
      ...>   Agenda.programme("Conf", across: "2026-09-15/2026-09-15")
      ...>   |> Agenda.Programme.add_session(talk)
      iex> {:ok, [only]} = Agenda.arrange(programme, [room])
      iex> only.session
      "Keynote"

  """
  @spec arrange(Programme.t(), [Resource.t()], keyword()) :: Arranger.result()
  defdelegate arrange(programme, pool, options \\ []), to: Arranger

  @doc """
  The smallest set of things that cannot hold together — sessions for a
  programme, demands for a session.

  Delegates to `Agenda.Arranger.conflict/3` or
  `Agenda.Planner.conflict/3` according to what it is given. Reach
  for it when `arrange/3` or `plan/3` has failed and the question is
  what to change.

  ### Arguments

  * `subject` is a `t:Agenda.Programme.t/0` or a
    `t:Agenda.Session.t/0`.

  * `pool` is the list of `t:Agenda.Resource.t/0` to choose from.

  * `options` is a keyword list of options.

  ### Options

  * For a programme, `:busy`, `:pinned`, `:candidates`, `:nodes`,
    `:score_nodes`, `:concurrency` and `:travel` are as for
    `arrange/3`.

  * For a session, `:busy`, `:limit` and `:spread` are as for
    `plan/3`.

  ### Returns

  * `:none` when there is nothing to explain, or

  * `{:ok, conflict}` — a minimal set of session names, or of demands.

  ### Examples

      iex> room = Agenda.resource("Hall", seats: 100)
      iex> {:ok, room} = Agenda.open(room, "2026-09-15T09:00:00/2026-09-15T10:00:00")
      iex> talk = fn name ->
      ...>   Agenda.session(name, duration: "PT1H", window: "2026-09-15/2026-09-15")
      ...>   |> Agenda.Session.needs(:room, seats: 100)
      ...> end
      iex> programme =
      ...>   Agenda.programme("Conf")
      ...>   |> Agenda.Programme.add_session(talk.("Keynote"))
      ...>   |> Agenda.Programme.add_session(talk.("Deep dive"))
      iex> Agenda.conflict(programme, [room])
      {:ok, ["Keynote", "Deep dive"]}

  """
  @spec conflict(Programme.t() | Session.t(), [Resource.t()], keyword()) ::
          {:ok, [term()]} | :none
  def conflict(subject, pool, options \\ [])

  def conflict(%Programme{} = programme, pool, options) do
    Arranger.conflict(programme, pool, options)
  end

  def conflict(%Session{} = session, pool, options) do
    Planner.conflict(session, pool, options)
  end

  @doc """
  What a layout costs against a programme's preferences.

  `arrange/3` already prefers a lower score, so this is for comparing
  layouts you are choosing between yourself — or for reading the score
  of an `{:ok, arrangements}` result, which returns the placements
  without one.

  ### Arguments

  * `arrangements` is a list of `t:Agenda.Arrangement.t/0`, or a
    `t:Agenda.Layout.t/0`.

  * `programme` is the `t:Agenda.Programme.t/0` whose preferences
    to score against.

  * `options` is a keyword list of options.

  ### Options

  * `:pool` is the resources the layout drew on, for preferences that
    consult them. The default is `[]`.

  ### Returns

  * the total penalty, where `0` is ideal.

  ### Examples

      iex> {:ok, programme} = Agenda.Programme.prefer(Agenda.programme("Conf"), :room_changes)
      iex> Agenda.score([], programme)
      0

  """
  @spec score([Arrangement.t()] | Layout.t(), Programme.t(), keyword()) :: number()
  def score(arrangements, programme, options \\ [])

  def score(%Layout{} = layout, programme, options) do
    score(layout.placed, programme, options)
  end

  def score(arrangements, %Programme{} = programme, options) when is_list(arrangements) do
    Preference.score(programme.preferences, arrangements, scoring(programme, options))
  end

  @doc """
  What each preference contributed, as sentences.

  A score is a number, and a number says a layout is worse without
  saying how. This says how.

  ### Arguments

  * `arrangements` is a list of `t:Agenda.Arrangement.t/0`, or a
    `t:Agenda.Layout.t/0`.

  * `programme` is the `t:Agenda.Programme.t/0` whose preferences
    to score against.

  * `options` is a keyword list of options.

  ### Options

  * `:pool` is the resources the layout drew on. The default is `[]`.

  ### Returns

  * one sentence per preference, in the order they were declared.

  ### Examples

      iex> {:ok, programme} =
      ...>   Agenda.Programme.prefer(Agenda.programme("Conf"), :room_changes, weight: 10)
      iex> Agenda.explain_score([], programme)
      ["room_changes: 0 × 10 = 0"]

  """
  @spec explain_score([Arrangement.t()] | Layout.t(), Programme.t(), keyword()) :: [String.t()]
  def explain_score(arrangements, programme, options \\ [])

  def explain_score(%Layout{} = layout, programme, options) do
    explain_score(layout.placed, programme, options)
  end

  def explain_score(arrangements, %Programme{} = programme, options) when is_list(arrangements) do
    Preference.explain(programme.preferences, arrangements, scoring(programme, options))
  end

  defp scoring(programme, options) do
    %{programme: programme, pool: Keyword.get(options, :pool, [])}
  end

  @doc """
  Add a soft constraint to a programme. Delegates to
  `Agenda.Programme.prefer/3`.

  ### Arguments

  * `programme` is a `t:Agenda.Programme.t/0`.

  * `preference` is a built-in name — `:room_changes` or
    `:room_spread` — or a `{name, function}` pair of your own.

  * `options` is a keyword list of options.

  ### Options

  * `:weight` is how much each violation costs. The default is `1`.

  ### Returns

  * `{:ok, programme}`, or

  * `{:error, reason}` when the preference is not recognised.

  ### Examples

      iex> {:ok, programme} = Agenda.prefer(Agenda.programme("Conf"), :room_spread)
      iex> Enum.map(programme.preferences, & &1.name)
      [:room_spread]

  """
  @spec prefer(Programme.t(), atom() | {atom(), function()}, keyword()) ::
          {:ok, Programme.t()} | {:error, term()}
  defdelegate prefer(programme, preference, options \\ []), to: Programme

  @doc """
  Require that one session finishes before another starts. Delegates
  to `Agenda.Programme.precede/4`.

  ### Arguments

  * `programme` is a `t:Agenda.Programme.t/0`.

  * `first` is the name of the session that must finish first.

  * `then` is the name of the session that follows it.

  * `options` is a keyword list of options.

  ### Options

  * `:gap` is the least time that must pass between them.

  * `:within` is the most, measured from the end of `first`.

  ### Returns

  * `{:ok, programme}`, or

  * `{:error, reason}` naming a session the programme does not have.

  ### Examples

      iex> programme =
      ...>   Agenda.programme("Job")
      ...>   |> Agenda.Programme.add_session(Agenda.session("Survey"))
      ...>   |> Agenda.Programme.add_session(Agenda.session("Quote"))
      iex> {:ok, programme} = Agenda.precede(programme, "Survey", "Quote", gap: "PT30M")
      iex> length(programme.precedences)
      1

  """
  @spec precede(Programme.t(), String.t(), String.t(), keyword()) ::
          {:ok, Programme.t()} | {:error, term()}
  defdelegate precede(programme, first, then, options \\ []), to: Programme

  @doc """
  Register that one resource would like a session with another.
  Delegates to `Agenda.Programme.interest/3`.

  Interest is one-directional. A meeting is held where it is returned,
  so both parties must say so — see `meetings/3`.

  ### Arguments

  * `programme` is a `t:Agenda.Programme.t/0`.

  * `from` is the resource registering the interest, as a
    `t:Agenda.Resource.t/0` or its name.

  * `to` is the resource it would like to meet, in the same two forms.

  ### Returns

  * `{:ok, programme}`, or

  * `{:error, :self_interest}` when a resource names itself.

  ### Examples

      iex> {:ok, programme} = Agenda.interest(Agenda.programme("Show"), "Kim", "Harbour")
      iex> {:ok, programme} = Agenda.interest(programme, "Harbour", "Kim")
      iex> Agenda.Interest.mutual(programme.interests)
      [{"Harbour", "Kim"}]

  """
  @spec interest(Programme.t(), Resource.t() | String.t(), Resource.t() | String.t()) ::
          {:ok, Programme.t()} | {:error, term()}
  defdelegate interest(programme, from, to), to: Programme

  @doc """
  Turn returned interest into sessions. Delegates to
  `Agenda.Programme.meetings/3`.

  One session per mutually interested pair, each rostering both
  parties, so nobody being in two places at once is the constraint the
  library already enforces rather than one anybody writes.

  ### Arguments

  * `programme` is a `t:Agenda.Programme.t/0` carrying the interests.

  * `pool` is the resources the interests name.

  * `options` is a keyword list of options.

  ### Options

  * `:duration` is how long each meeting runs. Required.

  * `:window` is when meetings may be held. Defaults to the
    programme's own window.

  * `:needs` is what every meeting requires beyond its two parties, as
    `[role: predicates]` — a table, most often.

  * `:as` is the role both parties are rostered under. The default is
    `:party`, which says neither of them is substitutable.

  * `:name` is a two-argument function naming a meeting from the pair.
    The default reads `"Kim with Harbour Tours"`.

  ### Returns

  * `{:ok, programme}` with one session added per mutual pair, or

  * `{:error, {:missing_option, :duration}}`, or

  * `{:error, {:unknown_resources, names}}` when an interest names a
    resource the pool does not hold.

  ### Examples

      iex> kim = Agenda.resource("Kim")
      iex> harbour = Agenda.resource("Harbour")
      iex> programme = Agenda.programme("Show", across: "2027-06-15/2027-06-16")
      iex> {:ok, programme} = Agenda.interest(programme, kim, harbour)
      iex> {:ok, programme} = Agenda.interest(programme, harbour, kim)
      iex> {:ok, programme} = Agenda.meetings(programme, [kim, harbour], duration: "PT15M")
      iex> length(programme.sessions)
      1

  """
  @spec meetings(Programme.t(), [Resource.t()], keyword()) ::
          {:ok, Programme.t()} | {:error, term()}
  defdelegate meetings(programme, pool, options \\ []), to: Programme

  @doc """
  Rebuild what a ledger holds as arrangements, ready to pin. Delegates
  to `Agenda.Ledger.arrangements/3`.

  ### Arguments

  * `ledger` is a `t:Agenda.Ledger.t/0`.

  * `pool` is the list of `t:Agenda.Resource.t/0` the allocations
    were made from.

  * `options` is a keyword list of options.

  ### Options

  * `:only` is a session name, or a list of them, to rebuild. The
    default is every session in the ledger.

  ### Returns

  * `{:ok, arrangements}` — one per session, ordered by session name,
    or

  * `{:error, t:Agenda.Infeasible.t/0}` naming the resources the
    pool does not have.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Agenda.resource("Boardroom")
      iex> arrangement = %Agenda.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Agenda.allocate(Agenda.ledger(), arrangement)
      iex> {:ok, [pinned]} = Agenda.arrangements(ledger, [boardroom])
      iex> pinned.session
      "Review"

  """
  @spec arrangements(Ledger.t(), [Resource.t()], keyword()) ::
          {:ok, [Arrangement.t()]} | {:error, Infeasible.t()}
  defdelegate arrangements(ledger, pool, options \\ []), to: Ledger

  @doc """
  How long it takes to get from one resource to another.

  Derived from the resources' separation in the place tree — the
  further up you must climb to get from one to the other, the longer
  the journey. Resources in unrelated trees, or with no place at all,
  return `{:error, :unknown}` rather than a guess: nothing can be said
  about a journey between two places that are not related.

  ### Arguments

  * `from` and `to` are each a `t:Agenda.Resource.t/0`.

  * `options` is a keyword list of options.

  ### Options

  * `:between` is a keyword-style list of `{{from_name, to_name},
    duration}` overrides, consulted in either direction before the
    table. Use it wherever the building disagrees with the geometry —
    two adjacent rooms separated by a locked fire door, for instance.

  * `:levels` is a map of separation to duration, replacing the default
    table (`0` → `PT0M`, `1` → `PT5M`, `2` → `PT10M`).

  * `:distant` is the duration used for separations beyond the table.
    The default is `PT20M`.

  ### Returns

  * `{:ok, duration}` where `duration` is a `t:Tempo.Duration.t/0`, or

  * `{:error, :unknown}` when the two resources share no place.

  ### Examples

      iex> import Tempo.Sigils
      iex> sydney = Agenda.place("Sydney Convention Centre")
      iex> level_2 = Agenda.place("Level 2", within: sydney)
      iex> level_3 = Agenda.place("Level 3", within: sydney)
      iex> boardroom = Agenda.resource("Boardroom", within: level_2)
      iex> annexe = Agenda.resource("Annexe", within: level_3)
      iex> Agenda.travel_time(boardroom, annexe)
      {:ok, ~o"PT5M"}

      iex> here = Agenda.resource("Here")
      iex> there = Agenda.resource("There")
      iex> Agenda.travel_time(here, there)
      {:error, :unknown}

  """
  @spec travel_time(Resource.t(), Resource.t(), keyword()) ::
          {:ok, Tempo.Duration.t()} | {:error, :unknown}
  def travel_time(%Resource{} = from, %Resource{} = to, options \\ []) do
    duration = override(options, from.name, to.name)

    if is_nil(duration) do
      from_separation(Resource.separation(from, to), options)
    else
      {:ok, duration}
    end
  end

  # Overrides are consulted in either direction — a journey stated once
  # holds both ways round.
  defp override(options, from_name, to_name) do
    options
    |> Keyword.get(:between, [])
    |> Enum.find_value(fn
      {{^from_name, ^to_name}, duration} -> duration
      {{^to_name, ^from_name}, duration} -> duration
      _other -> nil
    end)
  end

  defp from_separation(:disjoint, _options) do
    {:error, :unknown}
  end

  defp from_separation(separation, options) do
    levels = Keyword.get(options, :levels, @default_levels)
    distant = Keyword.get(options, :distant, @default_distant)

    {:ok, Map.get(levels, separation, distant)}
  end
end
