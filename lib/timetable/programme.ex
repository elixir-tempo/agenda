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
  alias Timetable.Session
  alias Timetable.Track

  @typedoc "A whole layout waiting to be arranged."
  @type t :: %__MODULE__{
          name: String.t(),
          window: Availability.pattern() | nil,
          tracks: [Track.t()],
          sessions: [Session.t()]
        }

  defstruct name: nil, window: nil, tracks: [], sessions: []

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
