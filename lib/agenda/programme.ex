defmodule Agenda.Programme do
  @moduledoc """
  Everything being laid out at once — the tracks, the standalone
  sessions, and the span they all fall inside.

  Where `Agenda.Planner.plan/3` answers *"when could this one
  session be held?"*, a programme asks the harder question: *"is there
  a placement for **every** session such that nothing clashes?"* Those
  are different problems. The first enumerates; the second searches,
  and a choice made for one session forecloses choices for another.

  The word is deliberately not "schedule" — that is triple-booked
  already (`Tempo.Schedule` is critical-path planning,
  elsewhere a `Schedule` is the bookable resource itself, and
  colloquially it is this output).

  """

  alias Agenda.Availability
  alias Agenda.Interest
  alias Agenda.Precedence
  alias Agenda.Preference
  alias Agenda.Resource
  alias Agenda.Session
  alias Agenda.Track

  @typedoc "A whole layout waiting to be arranged."
  @type t :: %__MODULE__{
          name: String.t(),
          window: Availability.pattern() | nil,
          tracks: [Track.t()],
          sessions: [Session.t()],
          preferences: [Preference.t()],
          precedences: [Precedence.t()],
          interests: [Interest.t()]
        }

  defstruct name: nil,
            window: nil,
            tracks: [],
            sessions: [],
            preferences: [],
            precedences: [],
            interests: []

  @doc """
  Build a programme.

  ### Arguments

  * `name` is the programme's name.

  ### Options

  * `:across` is the window every session must fall inside.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> Agenda.Programme.new("ElixirConf AU").name
      "ElixirConf AU"

  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, options \\ []) when is_binary(name) do
    %__MODULE__{name: name, window: Keyword.get(options, :across)}
  end

  @doc """
  Set the window every session must fall inside.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `window` is a Tempo value or an ISO 8601 string.

  ### Returns

  * the programme, bounded.

  ### Examples

      iex> programme = Agenda.Programme.new("Conf")
      iex> Agenda.Programme.across(programme, "2026-09-15/2026-09-17").window
      "2026-09-15/2026-09-17"

  """
  @spec across(t(), Availability.pattern()) :: t()
  def across(%__MODULE__{} = programme, window), do: %{programme | window: window}

  @doc """
  Add a track.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `track` is a `t:Agenda.Track.t/0`.

  ### Returns

  * the programme, with the track added.

  ### Examples

      iex> programme = Agenda.Programme.new("Conf")
      iex> track = Agenda.track("Elixir", of: [Agenda.session("Keynote")])
      iex> Agenda.Programme.add_track(programme, track).tracks |> Enum.map(& &1.name)
      ["Elixir"]

  """
  @spec add_track(t(), Track.t()) :: t()
  def add_track(%__MODULE__{} = programme, %Track{} = track) do
    %{programme | tracks: programme.tracks ++ [track]}
  end

  @doc """
  Add a session that belongs to no track.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `session` is a `t:Agenda.Session.t/0`.

  ### Returns

  * the programme, with the session added.

  ### Examples

      iex> programme = Agenda.Programme.new("Conf")
      iex> Agenda.Programme.add_session(programme, Agenda.session("Registration"))
      ...> |> Map.get(:sessions) |> Enum.map(& &1.name)
      ["Registration"]

  """
  @spec add_session(t(), Session.t()) :: t()
  def add_session(%__MODULE__{} = programme, %Session{} = session) do
    %{programme | sessions: programme.sessions ++ [session]}
  end

  @doc """
  Add every session in a list.

  A programme is usually built from a list of sessions rather than one
  at a time, and folding `add_session/2` over that list means writing
  the fold — with the arguments the other way round from the reduce —
  at every such site.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `sessions` is a list of `t:Agenda.Session.t/0`, added in order.

  ### Returns

  * the programme, with the sessions added.

  ### Examples

      iex> programme = Agenda.Programme.new("Conf")
      iex> sessions = [Agenda.session("Registration"), Agenda.session("Keynote")]
      iex> Agenda.Programme.add_sessions(programme, sessions)
      ...> |> Map.get(:sessions) |> Enum.map(& &1.name)
      ["Registration", "Keynote"]

  """
  @spec add_sessions(t(), [Session.t()]) :: t()
  def add_sessions(%__MODULE__{} = programme, sessions) when is_list(sessions) do
    Enum.reduce(sessions, programme, &add_session(&2, &1))
  end

  @doc """
  Require that one session finishes before another starts.

  This is what makes a task graph out of a set of tasks. Both names
  must be sessions in the programme; naming one that is not is an
  error rather than a constraint silently doing nothing.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `first` is the name of the session that must finish first.

  * `then` is the name of the session that follows it.

  ### Options

  * `:gap` is the least time that must pass between them.

  * `:within` is the most, measured from the end of `first`.

  ### Returns

  * `{:ok, programme}`; or

  * `{:error, reason}` naming a session the programme does not have.

  ### Examples

      iex> programme =
      ...>   Agenda.programme("Job")
      ...>   |> Agenda.Programme.add_session(Agenda.session("Survey"))
      ...>   |> Agenda.Programme.add_session(Agenda.session("Quote"))
      iex> {:ok, programme} = Agenda.Programme.precede(programme, "Survey", "Quote", gap: "PT30M")
      iex> Enum.map(programme.precedences, & &1.then)
      ["Quote"]

      iex> Agenda.Programme.precede(Agenda.programme("Job"), "Survey", "Quote")
      {:error, {:unknown_sessions, ["Survey", "Quote"]}}

  """
  @spec precede(t(), String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def precede(%__MODULE__{} = programme, first, then, options \\ []) do
    known = programme |> all_sessions() |> MapSet.new(& &1.name)

    case Enum.reject([first, then], &MapSet.member?(known, &1)) do
      [] ->
        precedence = Precedence.new(first, then, options)
        {:ok, %{programme | precedences: programme.precedences ++ [precedence]}}

      strangers ->
        {:error, {:unknown_sessions, strangers}}
    end
  end

  @doc """
  Add a soft constraint.

  A preference never makes a layout invalid, only worse.
  `Agenda.Arranger.arrange/3` places as many sessions as it can
  first — that part is proven — and prefers a lower score only among
  the layouts it reaches. See `Agenda.Preference` for what is and
  is not promised.

  Declaring even one preference changes how the search runs: it can no
  longer stop at the first layout that places everything it can, since
  a later one may score better. A programme with no preferences is
  unaffected.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `preference` is a built-in name — `:room_changes` or
    `:room_spread` — or a `{name, function}` pair of your own.

  ### Options

  * `:weight` is how much each violation costs. The default is `1`.

  ### Returns

  * `{:ok, programme}`; or

  * `{:error, reason}` when the preference is not recognised.

  ### Examples

      iex> programme = Agenda.programme("Conf")
      iex> {:ok, programme} = Agenda.Programme.prefer(programme, :room_changes, weight: 10)
      iex> Enum.map(programme.preferences, & &1.name)
      [:room_changes]

      iex> Agenda.Programme.prefer(Agenda.programme("Conf"), :teleportation)
      {:error, {:unknown_preference, :teleportation}}

  """
  @spec prefer(t(), atom() | {atom(), function()}, keyword()) :: {:ok, t()} | {:error, term()}
  def prefer(%__MODULE__{} = programme, preference, options \\ []) do
    with {:ok, built} <- Preference.new(preference, options) do
      {:ok, %{programme | preferences: programme.preferences ++ [built]}}
    end
  end

  @doc """
  Every session in the programme, tracked or not.

  ### Arguments

  * `programme` is a `t:t/0`.

  ### Returns

  * the sessions, standalone ones first, then each track's in order.

  ### Examples

      iex> track = Agenda.track("Elixir", of: [Agenda.session("Keynote")])
      iex> Agenda.programme("Conf")
      ...> |> Agenda.Programme.add_session(Agenda.session("Registration"))
      ...> |> Agenda.Programme.add_track(track)
      ...> |> Agenda.Programme.all_sessions()
      ...> |> Enum.map(& &1.name)
      ["Registration", "Keynote"]

  """
  @spec all_sessions(t()) :: [Session.t()]
  def all_sessions(%__MODULE__{} = programme) do
    programme.sessions ++ Enum.flat_map(programme.tracks, & &1.sessions)
  end

  @doc """
  The same programme cut down to the named sessions.

  Tracks keep only the sessions named, and a track left with none is
  dropped rather than kept empty — an empty track constrains nothing
  and would only be noise in the result.

  This exists for `Agenda.Arranger.conflict/3`, which asks whether
  smaller and smaller parts of a programme can be arranged in order to
  find the part that cannot.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `names` is the list of session names to keep.

  ### Returns

  * the programme, holding only those sessions.

  ### Examples

      iex> track = Agenda.track("Elixir", of: [Agenda.session("Keynote")])
      iex> Agenda.programme("Conf")
      ...> |> Agenda.Programme.add_session(Agenda.session("Registration"))
      ...> |> Agenda.Programme.add_track(track)
      ...> |> Agenda.Programme.restrict_to(["Registration"])
      ...> |> Agenda.Programme.all_sessions()
      ...> |> Enum.map(& &1.name)
      ["Registration"]

      iex> track = Agenda.track("Elixir", of: [Agenda.session("Keynote")])
      iex> Agenda.programme("Conf")
      ...> |> Agenda.Programme.add_track(track)
      ...> |> Agenda.Programme.restrict_to([])
      ...> |> Map.get(:tracks)
      []

  """
  @spec restrict_to(t(), [String.t()]) :: t()
  def restrict_to(%__MODULE__{} = programme, names) when is_list(names) do
    keeping = MapSet.new(names)

    kept = fn sessions -> Enum.filter(sessions, &MapSet.member?(keeping, &1.name)) end

    %{
      programme
      | sessions: kept.(programme.sessions),
        tracks:
          programme.tracks
          |> Enum.map(&%{&1 | sessions: kept.(&1.sessions)})
          |> Enum.reject(&(&1.sessions == [])),
        # A precedence needs both its ends. One whose predecessor was
        # dropped is not a weaker constraint, it is no constraint —
        # keeping it would let `conflict/3` blame an ordering that
        # cannot apply to the subset it is testing.
        precedences:
          Enum.filter(
            programme.precedences,
            &(MapSet.member?(keeping, &1.first) and MapSet.member?(keeping, &1.then))
          )
    }
  end

  @doc """
  The track a session belongs to, or `nil` when it stands alone.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `session_name` is the session's name.

  ### Returns

  * a `t:Agenda.Track.t/0`, or `nil`.

  ### Examples

      iex> track = Agenda.track("Elixir", of: [Agenda.session("Keynote")])
      iex> programme = Agenda.Programme.add_track(Agenda.programme("Conf"), track)
      iex> Agenda.Programme.track_of(programme, "Keynote").name
      "Elixir"

      iex> Agenda.Programme.track_of(Agenda.programme("Conf"), "Keynote")
      nil

  """
  @spec track_of(t(), String.t()) :: Track.t() | nil
  def track_of(%__MODULE__{tracks: tracks}, session_name) do
    Enum.find(tracks, fn track -> session_name in Track.session_names(track) end)
  end

  @doc """
  Register that one resource would like a session with another.

  Interest is stated in one direction at a time. A meeting is held
  where it is returned — see `meetings/3` — so both parties must say
  so, and interest that is never returned is reported rather than
  scheduled.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `from` is the resource registering the interest, as a
    `t:Agenda.Resource.t/0` or its name.

  * `to` is the resource it would like to meet, in the same two forms.

  ### Returns

  * `{:ok, programme}`; or

  * `{:error, :self_interest}` when a resource names itself.

  ### Examples

      iex> programme = Agenda.programme("Trade Show")
      iex> {:ok, programme} = Agenda.Programme.interest(programme, "Kim", "Harbour Tours")
      iex> length(programme.interests)
      1

  """
  @spec interest(t(), Resource.t() | String.t(), Resource.t() | String.t()) ::
          {:ok, t()} | {:error, term()}
  def interest(%__MODULE__{} = programme, from, to) do
    with {:ok, interest} <- Interest.new(from, to) do
      {:ok, %{programme | interests: programme.interests ++ [interest]}}
    end
  end

  @doc """
  Turn returned interest into sessions.

  One session per mutually interested pair, each rostering both
  parties, so the constraint that nobody is in two places at once is
  the one the library already enforces rather than a rule anybody
  writes. Interest that was never returned adds nothing and is left
  for `Agenda.Interest.one_sided/1` to report.

  Adding meetings twice would double them, so this is a step that
  produces a programme rather than something `arrange/3` does on the
  way past.

  ### Arguments

  * `programme` is a `t:t/0` carrying the interests.

  * `pool` is the resources the interests name.

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

  * `{:ok, programme}` with one session added per mutual pair; or

  * `{:error, {:missing_option, :duration}}`; or

  * `{:error, {:unknown_resources, names}}` when an interest names a
    resource the pool does not hold.

  ### Examples

      iex> kim = Agenda.resource("Kim")
      iex> harbour = Agenda.resource("Harbour Tours")
      iex> programme = Agenda.programme("Trade Show", across: "2027-06-15/2027-06-17")
      iex> {:ok, programme} = Agenda.Programme.interest(programme, kim, harbour)
      iex> {:ok, programme} = Agenda.Programme.interest(programme, harbour, kim)
      iex> {:ok, programme} = Agenda.Programme.meetings(programme, [kim, harbour], duration: "PT15M")
      iex> Enum.map(programme.sessions, & &1.name)
      ["Harbour Tours with Kim"]

  """
  @spec meetings(t(), [Resource.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def meetings(%__MODULE__{} = programme, pool, options \\ []) do
    with {:ok, duration} <- required(options, :duration),
         {:ok, sessions} <- built(programme, pool, duration, options) do
      {:ok, Enum.reduce(sessions, programme, &add_session(&2, &1))}
    end
  end

  defp required(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp built(programme, pool, duration, options) do
    programme.interests
    |> Interest.mutual()
    |> Enum.reduce_while({:ok, []}, fn pair, {:ok, acc} ->
      case meeting(pair, pool, programme, duration, options) do
        {:ok, session} -> {:cont, {:ok, acc ++ [session]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp meeting({first, second}, pool, programme, duration, options) do
    role = Keyword.get(options, :as, :party)
    naming = Keyword.get(options, :name, &"#{&1} with #{&2}")
    window = Keyword.get(options, :window, programme.window)

    with {:ok, parties} <- Resource.fetch_all(pool, [first, second]) do
      session =
        naming.(first, second)
        |> Session.new(duration: duration, window: window)
        |> Session.roster(role, parties)

      {:ok,
       Enum.reduce(Keyword.get(options, :needs, []), session, fn {needed, predicates}, acc ->
         Session.needs(acc, needed, predicates)
       end)}
    end
  end
end
