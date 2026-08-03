defmodule Timetable.Track do
  @moduledoc """
  A family of sessions constrained against *each other*.

  Every other constraint in this library relates a session to a
  resource. A track is the first that does not: it says these sessions
  share an audience, so no two of them may run at once, and — if asked
  — a delegate must be able to walk between consecutive ones in the gap
  between them.

  **Not overlapping is intrinsic, not an option.** A set of sessions
  that may collide with each other is just a list; what makes a track a
  track is that it cannot clash with itself. `reachable/2` is the
  optional extra.

  The word is deliberately not "stream": Elixir's `Stream` owns that
  name and a conference stream would shadow it at every call site.

  ### Example

      iex> import Tempo.Sigils
      iex> keynote = Timetable.session("Keynote", lasting: ~o"PT1H")
      iex> deep_dive = Timetable.session("OTP internals", lasting: ~o"PT1H")
      iex> track =
      ...>   Timetable.track("Elixir", of: [keynote, deep_dive])
      ...>   |> Timetable.Track.reachable(within: ~o"PT10M")
      iex> {length(track.sessions), Tempo.to_iso8601(track.reachable_within)}
      {2, "PT10M"}

  > *"No two talks in the Elixir track may overlap, and a delegate must
  > be able to walk between consecutive ones inside the ten-minute
  > break."*

  """

  alias Timetable.Availability
  alias Timetable.Session

  @typedoc "Sessions that cannot clash with each other."
  @type t :: %__MODULE__{
          name: String.t(),
          sessions: [Session.t()],
          reachable_within: Availability.pattern() | nil
        }

  defstruct name: nil, sessions: [], reachable_within: nil

  @doc """
  Build a track.

  ### Arguments

  * `name` is the track's name.

  ### Options

  * `:of` is the list of `t:Timetable.Session.t/0` in the track. The
    default is `[]`.

  ### Returns

  * a `t:t/0`.

  ### Examples

      iex> Timetable.Track.new("Elixir").name
      "Elixir"

  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, options \\ []) when is_binary(name) do
    %__MODULE__{name: name, sessions: Keyword.get(options, :of, [])}
  end

  @doc """
  Require that a delegate can get between consecutive sessions.

  Two sessions running back to back in rooms twenty minutes apart, with
  a ten-minute break, cannot both be attended. This is what makes the
  place tree earn its keep — the journey is derived from where the
  rooms are, not configured per pair.

  ### Arguments

  * `track` is a `t:t/0`.

  ### Options

  * `:within` is the longest journey a delegate is expected to make, a
    duration.

  ### Returns

  * the track, with the reachability requirement set.

  ### Examples

      iex> import Tempo.Sigils
      iex> track = Timetable.Track.new("Elixir")
      iex> Tempo.to_iso8601(Timetable.Track.reachable(track, within: ~o"PT10M").reachable_within)
      "PT10M"

  """
  @spec reachable(t(), keyword()) :: t()
  def reachable(%__MODULE__{} = track, options) do
    %{track | reachable_within: Keyword.fetch!(options, :within)}
  end

  @doc """
  Add a session to the track.

  ### Arguments

  * `track` is a `t:t/0`.

  * `session` is a `t:Timetable.Session.t/0`.

  ### Returns

  * the track, with the session added.

  ### Examples

      iex> session = Timetable.session("Keynote")
      iex> track = Timetable.Track.add(Timetable.Track.new("Elixir"), session)
      iex> Enum.map(track.sessions, & &1.name)
      ["Keynote"]

  """
  @spec add(t(), Session.t()) :: t()
  def add(%__MODULE__{} = track, %Session{} = session) do
    %{track | sessions: track.sessions ++ [session]}
  end

  @doc """
  The names of the sessions in `track`.

  ### Arguments

  * `track` is a `t:t/0`.

  ### Returns

  * the session names, in track order.

  ### Examples

      iex> track = Timetable.track("Elixir", of: [Timetable.session("Keynote")])
      iex> Timetable.Track.session_names(track)
      ["Keynote"]

  """
  @spec session_names(t()) :: [String.t()]
  def session_names(%__MODULE__{sessions: sessions}), do: Enum.map(sessions, & &1.name)
end
