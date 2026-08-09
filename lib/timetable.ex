defmodule Timetable do
  @moduledoc """
  Resource-constrained scheduling for `Tempo`.

  `Tempo` answers *when is this free?* This library answers *what
  should I book, and where?* — it adds the named resources, the
  attributes describing them, the places containing them, and the
  requirements a session places on them.

  ### The vocabulary

  * **Resource** — a named thing that can be allocated. People and
    rooms differ only in their attributes. See
    `Timetable.Resource`.

  * **Place** — a container of resources and other places, forming a
    tree. Travel between resources is *derived* from the tree rather
    than configured. See `Timetable.Place`.

  * **Requirement** — what a session demands, written in the predicate
    vocabulary of `Timetable.Predicate`. See
    `Timetable.Requirement`.

  ### Reading a match aloud

      iex> import Timetable.Predicate
      iex> boardroom = Timetable.resource("Boardroom", seats: 8, video_conferencing: true)
      iex> small = Timetable.resource("Meeting room 2", seats: 4)
      iex> needs_a_room = Timetable.needs(:room, seats: at_least(8), video_conferencing: true)
      iex> Timetable.eligible(needs_a_room, [boardroom, small]) |> Enum.map(& &1.name)
      ["Boardroom"]

  > *"Of the two rooms, only the boardroom seats eight and has video
  > conferencing."*

  And when a resource does not qualify, the reason is a sentence:

      iex> import Timetable.Predicate
      iex> small = Timetable.resource("Meeting room 2", seats: 4)
      iex> needs_a_room = Timetable.needs(:room, seats: at_least(8))
      iex> Timetable.explain(needs_a_room, small)
      "Meeting room 2: seats is 4 — needs at least 8"

  ### Status

  Phases 1 to 4 of the plan — the model, matching, availability,
  single-session planning, the allocation ledger, and whole-programme
  arrangement. The AshScheduling adapter follows; see
  [the plan](https://github.com/elixir-tempo/timetable/blob/main/plans/tempo-timetable.md).

  """

  import Tempo.Sigils

  alias Timetable.Arrangement
  alias Timetable.Arranger
  alias Timetable.Availability
  alias Timetable.Infeasible
  alias Timetable.Layout
  alias Timetable.Ledger
  alias Timetable.Place
  alias Timetable.Planner
  alias Timetable.Preference
  alias Timetable.Programme
  alias Timetable.Refine
  alias Timetable.Requirement
  alias Timetable.Resource
  alias Timetable.Series
  alias Timetable.Session
  alias Timetable.Track

  # How long it takes to travel between two resources, keyed by how far
  # apart they sit in the place tree. These are a starting guess, not a
  # survey of your building: override any specific pair with `:between`,
  # or replace the table wholesale with `:levels`.
  @default_levels %{0 => ~o"PT0M", 1 => ~o"PT5M", 2 => ~o"PT10M"}
  @default_distant ~o"PT20M"

  @doc """
  Build a place. Delegates to `Timetable.Place.new/2`.

  ### Examples

      iex> Timetable.place("Level 2").name
      "Level 2"

  """
  @spec place(String.t(), keyword()) :: Place.t()
  defdelegate place(name, options \\ []), to: Place, as: :new

  @doc """
  Build a resource. Delegates to `Timetable.Resource.new/2`.

  ### Examples

      iex> Timetable.resource("Boardroom", seats: 8).attributes
      %{seats: 8}

  """
  @spec resource(String.t(), keyword()) :: Resource.t()
  defdelegate resource(name, options \\ []), to: Resource, as: :new

  @doc """
  Build an attribute requirement. Delegates to
  `Timetable.Requirement.new/2`.

  ### Examples

      iex> Timetable.needs(:room, seats: 8).name
      :room

  """
  @spec needs(atom(), keyword()) :: Requirement.t()
  defdelegate needs(name, predicates \\ []), to: Requirement, as: :new

  @doc """
  Build a requirement naming specific resources. Delegates to
  `Timetable.Requirement.roster/2`.

  ### Examples

      iex> alice = Timetable.resource("Alice")
      iex> Timetable.roster(:attendees, [alice]).name
      :attendees

  """
  @spec roster(atom(), [Resource.t()]) :: Requirement.t()
  defdelegate roster(name, resources), to: Requirement

  @doc """
  The resources satisfying `requirement`. Delegates to
  `Timetable.Requirement.eligible/2`.

  ### Examples

      iex> boardroom = Timetable.resource("Boardroom", seats: 8)
      iex> Timetable.eligible(Timetable.needs(:room, seats: 8), [boardroom])
      ...> |> Enum.map(& &1.name)
      ["Boardroom"]

  """
  @spec eligible(Requirement.t(), [Resource.t()]) :: [Resource.t()]
  defdelegate eligible(requirement, candidates), to: Requirement

  @doc """
  Why `resource` does or does not satisfy `requirement`, as a sentence.

  ### Arguments

  * `requirement` is a `t:Timetable.Requirement.t/0`.

  * `resource` is a `t:Timetable.Resource.t/0`.

  ### Returns

  * a sentence naming the resource and every unmet attribute, or
    stating that it qualifies.

  ### Examples

      iex> import Timetable.Predicate
      iex> boardroom = Timetable.resource("Boardroom", seats: 8)
      iex> Timetable.explain(Timetable.needs(:room, seats: at_least(8)), boardroom)
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
  Build a session. Delegates to `Timetable.Session.new/2`.

  ### Examples

      iex> Timetable.session("Review", lasting: "PT1H").name
      "Review"

  """
  @spec session(String.t(), keyword()) :: Session.t()
  defdelegate session(name, options \\ []), to: Session, as: :new

  @doc """
  Set when a resource is open. Delegates to
  `Timetable.Availability.open/2`.

  ### Examples

      iex> boardroom = Timetable.resource("Boardroom")
      iex> {:ok, boardroom} = Timetable.open(boardroom, "2026-06-15T09:00:00/2026-06-15T17:00:00")
      iex> is_nil(boardroom.open)
      false

  """
  @spec open(Resource.t(), Availability.pattern()) :: {:ok, Resource.t()} | {:error, term()}
  defdelegate open(resource, pattern), to: Availability

  @doc """
  Read open hours from an RFC 7953 `VAVAILABILITY`. Delegates to
  `Timetable.Availability.from_ical/1`.

  This is what a CalDAV server hands you when asked when someone is
  available. The result is a pattern for `open/2`.

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
      iex> {:ok, hours} = Timetable.from_ical(ics)
      iex> {:ok, room} = Timetable.open(Timetable.resource("Consulting room"), hours)
      iex> {:ok, free} = Timetable.free(room, within: "2026-06-01/2026-07-01")
      iex> Tempo.IntervalSet.count(free)
      5

  """
  @spec from_ical(String.t()) ::
          {:ok, Availability.imported()} | {:error, :ical_not_available | String.t()}
  defdelegate from_ical(ics), to: Availability

  @doc """
  When a resource is open and not already taken. Delegates to
  `Timetable.Availability.free/2`.

  ### Examples

      iex> boardroom = Timetable.resource("Boardroom")
      iex> {:ok, boardroom} = Timetable.open(boardroom, "2026-06-15T09:00:00/2026-06-15T17:00:00")
      iex> {:ok, free} = Timetable.free(boardroom, within: "2026-06-15/2026-06-16")
      iex> Tempo.IntervalSet.count(free)
      1

  """
  @spec free(Resource.t(), keyword()) :: {:ok, Tempo.IntervalSet.t()} | {:error, term()}
  defdelegate free(resource, options), to: Availability

  @doc """
  Keep only free time inside `constraint`. Delegates to
  `Timetable.Refine.only_during/2`.

  ### Examples

      iex> {:ok, room} = Timetable.open(Timetable.resource("R"), "2027-03-02T09:00:00/2027-03-02T17:00:00")
      iex> {:ok, clinic} =
      ...>   room
      ...>   |> Timetable.free(within: "2027-03-02/2027-03-03")
      ...>   |> Timetable.only_during("2027-03-02T13:00:00/2027-03-02T16:00:00")
      iex> Tempo.IntervalSet.count(clinic)
      1

  """
  @spec only_during(Refine.refinable(), Availability.pattern()) ::
          {:ok, Tempo.IntervalSet.t()} | {:error, term()}
  defdelegate only_during(free, constraint), to: Refine

  @doc """
  Keep only free time inside any of `constraints`. Delegates to
  `Timetable.Refine.during_any/2`.

  ### Examples

      iex> {:ok, room} = Timetable.open(Timetable.resource("R"), "2027-03-02T09:00:00/2027-03-02T17:00:00")
      iex> {:ok, staffed} =
      ...>   room
      ...>   |> Timetable.free(within: "2027-03-02/2027-03-03")
      ...>   |> Timetable.during_any(["2027-03-02T09:00:00/2027-03-02T10:00:00"])
      iex> Tempo.IntervalSet.count(staffed)
      1

  """
  @spec during_any(Refine.refinable(), [Availability.pattern()]) ::
          {:ok, Tempo.IntervalSet.t()} | {:error, term()}
  defdelegate during_any(free, constraints), to: Refine

  @doc """
  Keep only windows of at least `duration`. Delegates to
  `Timetable.Refine.lasting_at_least/2`.

  ### Examples

      iex> {:ok, room} = Timetable.open(Timetable.resource("R"), "2027-03-02T09:00:00/2027-03-02T09:30:00")
      iex> {:ok, usable} =
      ...>   room
      ...>   |> Timetable.free(within: "2027-03-02/2027-03-03")
      ...>   |> Timetable.lasting_at_least("PT1H")
      iex> Tempo.IntervalSet.empty?(usable)
      true

  """
  @spec lasting_at_least(Refine.refinable(), Availability.pattern()) ::
          {:ok, Tempo.IntervalSet.t()} | {:error, term()}
  defdelegate lasting_at_least(free, duration), to: Refine

  @doc """
  Expand a repeating session into its occurrences. Delegates to
  `Timetable.Series.expand/3`.

  ### Examples

      iex> standup = Timetable.session("Stand-up", lasting: "PT15M")
      iex> {:ok, occurrences} = Timetable.every(standup, "R3/2027-03-02T09:00:00/P1W")
      iex> length(occurrences)
      3

  """
  @spec every(Session.t(), Availability.pattern(), keyword()) ::
          {:ok, [Session.t()]} | {:error, term()}
  defdelegate every(session, pattern, options \\ []), to: Series, as: :expand

  @doc """
  Rank the ways a session could be held. Delegates to
  `Timetable.Planner.plan/3`.

  ### Examples

      iex> boardroom = Timetable.resource("Boardroom", seats: 8)
      iex> {:ok, boardroom} = Timetable.open(boardroom, "2026-06-15T09:00:00/2026-06-15T11:00:00")
      iex> session =
      ...>   Timetable.session("Review", lasting: "PT1H", between: "2026-06-15/2026-06-16")
      ...>   |> Timetable.Session.needs(:room, seats: 8)
      iex> {:ok, [best | _]} = Timetable.plan(session, [boardroom])
      iex> Timetable.explain(best)
      "2026Y6M15DT9H0M0S/2026Y6M15DT10H0M0S — room: Boardroom"

  """
  @spec plan(Session.t(), [Resource.t()], keyword()) ::
          {:ok, [Arrangement.t()]} | {:error, Infeasible.t()}
  defdelegate plan(session, pool, options \\ []), to: Planner

  @doc """
  Describe an arrangement, a partial layout, or an infeasible result as
  a sentence.

  ### Arguments

  * `result` is a `t:Timetable.Arrangement.t/0`, a
    `t:Timetable.Layout.t/0`, or a `t:Timetable.Infeasible.t/0`.

  ### Returns

  * a sentence.

  ### Examples

      iex> reason = Timetable.Infeasible.new("Review", ["no room seats 8"])
      iex> Timetable.explain(reason)
      "Review cannot be held: no room seats 8"

      iex> reason = Timetable.Infeasible.new("Workshop", ["no room seats 8"])
      iex> Timetable.explain(Timetable.Layout.new("Conf", [], [reason]))
      "Conf: 0 of 1 sessions placed. Workshop cannot be held: no room seats 8"

  """
  @spec explain(Arrangement.t() | Layout.t() | Infeasible.t()) :: String.t()
  def explain(%Arrangement{} = arrangement), do: Arrangement.explain(arrangement)
  def explain(%Layout{} = layout), do: Layout.explain(layout)
  def explain(%Infeasible{} = reason), do: Infeasible.message(reason)

  @doc """
  An empty ledger. Delegates to `Timetable.Ledger.new/0`.

  ### Examples

      iex> Timetable.count(Timetable.ledger())
      0

  """
  @spec ledger() :: Ledger.t()
  defdelegate ledger, to: Ledger, as: :new

  @doc """
  Record an arrangement. Delegates to `Timetable.Ledger.allocate/2`.

  ### Examples

      iex> import Tempo.Sigils
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [Timetable.resource("Boardroom")]}
      ...> }
      iex> {:ok, ledger} = Timetable.allocate(Timetable.ledger(), arrangement)
      iex> Timetable.count(ledger)
      1

  """
  @spec allocate(Ledger.t(), Arrangement.t()) :: {:ok, Ledger.t()}
  defdelegate allocate(ledger, arrangement), to: Ledger

  @doc """
  Free everything a session holds. Delegates to
  `Timetable.Ledger.release/2`.

  ### Examples

      iex> {:ok, ledger} = Timetable.release(Timetable.ledger(), "Review")
      iex> Timetable.count(ledger)
      0

  """
  @spec release(Ledger.t(), String.t()) :: {:ok, Ledger.t()}
  defdelegate release(ledger, session), to: Ledger

  @doc """
  Claim resources tentatively, until a moment. Delegates to
  `Timetable.Ledger.hold/3`.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.hold(Timetable.ledger(), arrangement,
      ...>                   until: "2026-06-15T10:15:00")
      iex> Timetable.holds(ledger) |> length()
      1

  """
  @spec hold(Ledger.t(), Arrangement.t(), keyword()) :: {:ok, Ledger.t()} | {:error, term()}
  defdelegate hold(ledger, arrangement, options), to: Ledger

  @doc """
  Turn a session's hold into a firm allocation. Delegates to
  `Timetable.Ledger.confirm/2`.

  ### Examples

      iex> {:ok, ledger} = Timetable.confirm(Timetable.ledger(), "Review")
      iex> Timetable.count(ledger)
      0

  """
  @spec confirm(Ledger.t(), String.t()) :: {:ok, Ledger.t()}
  defdelegate confirm(ledger, session), to: Ledger

  @doc """
  Drop every hold that has lapsed by a moment. Delegates to
  `Timetable.Ledger.expire/2`.

  Nothing expires on its own — this is what advances time, and it
  takes the moment as an argument so that no function in this library
  reads a clock.

  ### Examples

      iex> {:ok, ledger} = Timetable.expire(Timetable.ledger(), "2026-06-15T10:15:00")
      iex> Timetable.count(ledger)
      0

  """
  @spec expire(Ledger.t(), Availability.pattern()) :: {:ok, Ledger.t()} | {:error, term()}
  defdelegate expire(ledger, now), to: Ledger

  @doc """
  Every allocation that is still only a hold. Delegates to
  `Timetable.Ledger.holds/1`.

  ### Examples

      iex> Timetable.holds(Timetable.ledger())
      []

  """
  @spec holds(Ledger.t()) :: [Timetable.Allocation.t()]
  defdelegate holds(ledger), to: Ledger

  @doc """
  Free everything held by a whole series. Delegates to
  `Timetable.Ledger.release_series/3`.

  ### Examples

      iex> Timetable.release_series(Timetable.ledger(), "Stand-up")
      {:ok, Timetable.ledger()}

  """
  @spec release_series(Ledger.t(), String.t(), keyword()) ::
          {:ok, Ledger.t()} | {:error, term()}
  defdelegate release_series(ledger, series, options \\ []), to: Ledger

  @doc """
  What would change if a session moved. Delegates to
  `Timetable.Ledger.diff/3`.

  ### Examples

      iex> import Tempo.Sigils
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [Timetable.resource("Boardroom")]}
      ...> }
      iex> Timetable.rearrange(Timetable.ledger(), "Review", arrangement)
      ...> |> Enum.map(&elem(&1, 0))
      [:allocate]

  """
  @spec rearrange(Ledger.t(), String.t(), Arrangement.t()) :: [Ledger.change()]
  defdelegate rearrange(ledger, session, arrangement), to: Ledger, as: :diff

  @doc """
  What each resource is already claimed for. Delegates to
  `Timetable.Ledger.busy/2`.

  ### Examples

      iex> Timetable.busy(Timetable.ledger())
      %{}

  """
  @spec busy(Ledger.t(), keyword()) :: %{optional(String.t()) => [Tempo.Interval.t()]}
  defdelegate busy(ledger, options \\ []), to: Ledger

  @doc """
  How many allocations a ledger holds. Delegates to
  `Timetable.Ledger.count/1`.

  ### Examples

      iex> Timetable.count(Timetable.ledger())
      0

  """
  @spec count(Ledger.t()) :: non_neg_integer()
  defdelegate count(ledger), to: Ledger

  @doc """
  Build a track — sessions that cannot clash with each other.
  Delegates to `Timetable.Track.new/2`.

  ### Examples

      iex> Timetable.track("Elixir", of: [Timetable.session("Keynote")]).name
      "Elixir"

  """
  @spec track(String.t(), keyword()) :: Track.t()
  defdelegate track(name, options \\ []), to: Track, as: :new

  @doc """
  Require that a delegate can get between consecutive track sessions.
  Delegates to `Timetable.Track.reachable/2`.

  ### Examples

      iex> import Tempo.Sigils
      iex> track = Timetable.track("Elixir") |> Timetable.reachable(within: ~o"PT10M")
      iex> Tempo.to_iso8601(track.reachable_within)
      "PT10M"

  """
  @spec reachable(Track.t(), keyword()) :: Track.t()
  defdelegate reachable(track, options), to: Track

  @doc """
  Build a programme. Delegates to `Timetable.Programme.new/2`.

  ### Examples

      iex> Timetable.programme("ElixirConf AU").name
      "ElixirConf AU"

  """
  @spec programme(String.t(), keyword()) :: Programme.t()
  defdelegate programme(name, options \\ []), to: Programme, as: :new

  @doc """
  Find a placement for every session in a programme. Delegates to
  `Timetable.Arranger.arrange/3`.

  ### Examples

      iex> room = Timetable.resource("Hall", seats: 100)
      iex> {:ok, room} = Timetable.open(room, "2026-09-15T09:00:00/2026-09-15T11:00:00")
      iex> talk = Timetable.session("Keynote", lasting: "PT1H")
      ...>         |> Timetable.Session.needs(:room, seats: 100)
      iex> programme =
      ...>   Timetable.programme("Conf", across: "2026-09-15/2026-09-16")
      ...>   |> Timetable.Programme.add_session(talk)
      iex> {:ok, [only]} = Timetable.arrange(programme, [room])
      iex> only.session
      "Keynote"

  """
  @spec arrange(Programme.t(), [Resource.t()], keyword()) :: Arranger.result()
  defdelegate arrange(programme, pool, options \\ []), to: Arranger

  @doc """
  The smallest set of things that cannot hold together — sessions for a
  programme, demands for a session.

  Delegates to `Timetable.Arranger.conflict/3` or
  `Timetable.Planner.conflict/3` according to what it is given. Reach
  for it when `arrange/3` or `plan/3` has failed and the question is
  what to change.

  ### Arguments

  * `subject` is a `t:Timetable.Programme.t/0` or a
    `t:Timetable.Session.t/0`.

  * `pool` is the list of `t:Timetable.Resource.t/0` to choose from.

  ### Options

  * the same options as `arrange/3` or `plan/3` respectively.

  ### Returns

  * `:none` when there is nothing to explain; or

  * `{:ok, conflict}` — a minimal set of session names, or of demands.

  ### Examples

      iex> room = Timetable.resource("Hall", seats: 100)
      iex> {:ok, room} = Timetable.open(room, "2026-09-15T09:00:00/2026-09-15T10:00:00")
      iex> talk = fn name ->
      ...>   Timetable.session(name, lasting: "PT1H", between: "2026-09-15/2026-09-16")
      ...>   |> Timetable.Session.needs(:room, seats: 100)
      ...> end
      iex> programme =
      ...>   Timetable.programme("Conf")
      ...>   |> Timetable.Programme.add_session(talk.("Keynote"))
      ...>   |> Timetable.Programme.add_session(talk.("Deep dive"))
      iex> Timetable.conflict(programme, [room])
      {:ok, ["Keynote", "Deep dive"]}

  """
  @spec conflict(Programme.t() | Session.t(), [Resource.t()], keyword()) ::
          {:ok, [term()]} | :none
  def conflict(subject, pool, options \\ [])

  def conflict(%Programme{} = programme, pool, options),
    do: Arranger.conflict(programme, pool, options)

  def conflict(%Session{} = session, pool, options),
    do: Planner.conflict(session, pool, options)

  @doc """
  What a layout costs against a programme's preferences.

  `arrange/3` already prefers a lower score, so this is for comparing
  layouts you are choosing between yourself — or for reading the score
  of an `{:ok, arrangements}` result, which returns the placements
  without one.

  ### Arguments

  * `arrangements` is a list of `t:Timetable.Arrangement.t/0`, or a
    `t:Timetable.Layout.t/0`.

  * `programme` is the `t:Timetable.Programme.t/0` whose preferences
    to score against.

  ### Options

  * `:pool` is the resources the layout drew on, for preferences that
    consult them. The default is `[]`.

  ### Returns

  * the total penalty, where `0` is ideal.

  ### Examples

      iex> {:ok, programme} = Timetable.Programme.prefer(Timetable.programme("Conf"), :room_changes)
      iex> Timetable.score([], programme)
      0

  """
  @spec score([Arrangement.t()] | Layout.t(), Programme.t(), keyword()) :: number()
  def score(arrangements, programme, options \\ [])

  def score(%Layout{} = layout, programme, options),
    do: score(layout.placed, programme, options)

  def score(arrangements, %Programme{} = programme, options) when is_list(arrangements) do
    Preference.score(programme.preferences, arrangements, scoring(programme, options))
  end

  @doc """
  What each preference contributed, as sentences.

  A score is a number, and a number says a layout is worse without
  saying how. This says how.

  ### Arguments

  * `arrangements` is a list of `t:Timetable.Arrangement.t/0`, or a
    `t:Timetable.Layout.t/0`.

  * `programme` is the `t:Timetable.Programme.t/0` whose preferences
    to score against.

  ### Options

  * `:pool` is the resources the layout drew on. The default is `[]`.

  ### Returns

  * one sentence per preference, in the order they were declared.

  ### Examples

      iex> {:ok, programme} =
      ...>   Timetable.Programme.prefer(Timetable.programme("Conf"), :room_changes, weight: 10)
      iex> Timetable.explain_score([], programme)
      ["room_changes: 0 × 10 = 0"]

  """
  @spec explain_score([Arrangement.t()] | Layout.t(), Programme.t(), keyword()) :: [String.t()]
  def explain_score(arrangements, programme, options \\ [])

  def explain_score(%Layout{} = layout, programme, options),
    do: explain_score(layout.placed, programme, options)

  def explain_score(arrangements, %Programme{} = programme, options) when is_list(arrangements) do
    Preference.explain(programme.preferences, arrangements, scoring(programme, options))
  end

  defp scoring(programme, options) do
    %{programme: programme, pool: Keyword.get(options, :pool, [])}
  end

  @doc """
  Add a soft constraint to a programme. Delegates to
  `Timetable.Programme.prefer/3`.

  ### Examples

      iex> {:ok, programme} = Timetable.prefer(Timetable.programme("Conf"), :room_spread)
      iex> Enum.map(programme.preferences, & &1.name)
      [:room_spread]

  """
  @spec prefer(Programme.t(), atom() | {atom(), function()}, keyword()) ::
          {:ok, Programme.t()} | {:error, term()}
  defdelegate prefer(programme, preference, options \\ []), to: Programme

  @doc """
  Rebuild what a ledger holds as arrangements, ready to pin. Delegates
  to `Timetable.Ledger.arrangements/3`.

  ### Examples

      iex> import Tempo.Sigils
      iex> boardroom = Timetable.resource("Boardroom")
      iex> arrangement = %Timetable.Arrangement{
      ...>   session: "Review",
      ...>   interval: ~o"2026-06-16T10:00:00/2026-06-16T11:00:00",
      ...>   allocations: %{room: [boardroom]}
      ...> }
      iex> {:ok, ledger} = Timetable.allocate(Timetable.ledger(), arrangement)
      iex> {:ok, [pinned]} = Timetable.arrangements(ledger, [boardroom])
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

  * `from` and `to` are each a `t:Timetable.Resource.t/0`.

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

  * `{:ok, duration}` where `duration` is a `t:Tempo.Duration.t/0`; or

  * `{:error, :unknown}` when the two resources share no place.

  ### Examples

      iex> import Tempo.Sigils
      iex> sydney = Timetable.place("Sydney Convention Centre")
      iex> level_2 = Timetable.place("Level 2", within: sydney)
      iex> level_3 = Timetable.place("Level 3", within: sydney)
      iex> boardroom = Timetable.resource("Boardroom", within: level_2)
      iex> annexe = Timetable.resource("Annexe", within: level_3)
      iex> Timetable.travel_time(boardroom, annexe)
      {:ok, ~o"PT5M"}

      iex> here = Timetable.resource("Here")
      iex> there = Timetable.resource("There")
      iex> Timetable.travel_time(here, there)
      {:error, :unknown}

  """
  @spec travel_time(Resource.t(), Resource.t(), keyword()) ::
          {:ok, Tempo.Duration.t()} | {:error, :unknown}
  def travel_time(%Resource{} = from, %Resource{} = to, options \\ []) do
    case override(options, from.name, to.name) do
      nil -> from_separation(Resource.separation(from, to), options)
      duration -> {:ok, duration}
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

  defp from_separation(:disjoint, _options), do: {:error, :unknown}

  defp from_separation(separation, options) do
    levels = Keyword.get(options, :levels, @default_levels)
    distant = Keyword.get(options, :distant, @default_distant)

    {:ok, Map.get(levels, separation, distant)}
  end
end
