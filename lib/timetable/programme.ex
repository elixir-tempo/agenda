defmodule Timetable.Programme do
  @moduledoc """
  Everything being laid out at once — the tracks, the standalone
  sessions, and the span they all fall inside.

  Where `Timetable.Planner.plan/3` answers *"when could this one
  session be held?"*, a programme asks the harder question: *"is there
  a placement for **every** session such that nothing clashes?"* Those
  are different problems. The first enumerates; the second searches,
  and a choice made for one session forecloses choices for another.

  The word is deliberately not "schedule" — that is triple-booked
  already (`Tempo.Schedule` is critical-path planning,
  `AshScheduling.Schedule` is a bookable resource, and colloquially it
  is this output).

  """

  alias Timetable.Availability
  alias Timetable.Preference
  alias Timetable.Session
  alias Timetable.Track

  @typedoc "A whole layout waiting to be arranged."
  @type t :: %__MODULE__{
          name: String.t(),
          window: Availability.pattern() | nil,
          tracks: [Track.t()],
          sessions: [Session.t()],
          preferences: [Preference.t()]
        }

  defstruct name: nil, window: nil, tracks: [], sessions: [], preferences: []

  @doc """
  Build a programme.

  ### Arguments

  * `name` is the programme's name.

  ### Options

  * `:across` is the window every session must fall inside.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> Timetable.Programme.new("ElixirConf AU").name
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

      iex> programme = Timetable.Programme.new("Conf")
      iex> Timetable.Programme.across(programme, "2026-09-15/2026-09-17").window
      "2026-09-15/2026-09-17"

  """
  @spec across(t(), Availability.pattern()) :: t()
  def across(%__MODULE__{} = programme, window), do: %{programme | window: window}

  @doc """
  Add a track.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `track` is a `t:Timetable.Track.t/0`.

  ### Returns

  * the programme, with the track added.

  ### Examples

      iex> programme = Timetable.Programme.new("Conf")
      iex> track = Timetable.track("Elixir", of: [Timetable.session("Keynote")])
      iex> Timetable.Programme.add_track(programme, track).tracks |> Enum.map(& &1.name)
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

  * `session` is a `t:Timetable.Session.t/0`.

  ### Returns

  * the programme, with the session added.

  ### Examples

      iex> programme = Timetable.Programme.new("Conf")
      iex> Timetable.Programme.add_session(programme, Timetable.session("Registration"))
      ...> |> Map.get(:sessions) |> Enum.map(& &1.name)
      ["Registration"]

  """
  @spec add_session(t(), Session.t()) :: t()
  def add_session(%__MODULE__{} = programme, %Session{} = session) do
    %{programme | sessions: programme.sessions ++ [session]}
  end

  @doc """
  Add a soft constraint.

  A preference never makes a layout invalid, only worse.
  `Timetable.Arranger.arrange/3` places as many sessions as it can
  first — that part is proven — and prefers a lower score only among
  the layouts it reaches. See `Timetable.Preference` for what is and
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

      iex> programme = Timetable.programme("Conf")
      iex> {:ok, programme} = Timetable.Programme.prefer(programme, :room_changes, weight: 10)
      iex> Enum.map(programme.preferences, & &1.name)
      [:room_changes]

      iex> Timetable.Programme.prefer(Timetable.programme("Conf"), :teleportation)
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

      iex> track = Timetable.track("Elixir", of: [Timetable.session("Keynote")])
      iex> Timetable.programme("Conf")
      ...> |> Timetable.Programme.add_session(Timetable.session("Registration"))
      ...> |> Timetable.Programme.add_track(track)
      ...> |> Timetable.Programme.all_sessions()
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

  This exists for `Timetable.Arranger.conflict/3`, which asks whether
  smaller and smaller parts of a programme can be arranged in order to
  find the part that cannot.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `names` is the list of session names to keep.

  ### Returns

  * the programme, holding only those sessions.

  ### Examples

      iex> track = Timetable.track("Elixir", of: [Timetable.session("Keynote")])
      iex> Timetable.programme("Conf")
      ...> |> Timetable.Programme.add_session(Timetable.session("Registration"))
      ...> |> Timetable.Programme.add_track(track)
      ...> |> Timetable.Programme.restrict_to(["Registration"])
      ...> |> Timetable.Programme.all_sessions()
      ...> |> Enum.map(& &1.name)
      ["Registration"]

      iex> track = Timetable.track("Elixir", of: [Timetable.session("Keynote")])
      iex> Timetable.programme("Conf")
      ...> |> Timetable.Programme.add_track(track)
      ...> |> Timetable.Programme.restrict_to([])
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
          |> Enum.reject(&(&1.sessions == []))
    }
  end

  @doc """
  The track a session belongs to, or `nil` when it stands alone.

  ### Arguments

  * `programme` is a `t:t/0`.

  * `session_name` is the session's name.

  ### Returns

  * a `t:Timetable.Track.t/0`, or `nil`.

  ### Examples

      iex> track = Timetable.track("Elixir", of: [Timetable.session("Keynote")])
      iex> programme = Timetable.Programme.add_track(Timetable.programme("Conf"), track)
      iex> Timetable.Programme.track_of(programme, "Keynote").name
      "Elixir"

      iex> Timetable.Programme.track_of(Timetable.programme("Conf"), "Keynote")
      nil

  """
  @spec track_of(t(), String.t()) :: Track.t() | nil
  def track_of(%__MODULE__{tracks: tracks}, session_name) do
    Enum.find(tracks, fn track -> session_name in Track.session_names(track) end)
  end
end
