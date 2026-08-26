defmodule Agenda.ConflictTest do
  use ExUnit.Case, async: true

  import Agenda.Predicate

  alias Agenda.Arranger
  alias Agenda.Conflict
  alias Agenda.Planner
  alias Agenda.Programme
  alias Agenda.Session
  alias Agenda.Track

  doctest Agenda.Conflict

  defp room(name, hours, attributes \\ []) do
    {:ok, room} =
      Agenda.resource(name, [{:seats, 100} | attributes])
      |> Agenda.open("2026-09-15T09:00:00/2026-09-15T#{9 + hours}:00:00")

    room
  end

  defp talk(name) do
    name
    |> Agenda.session(duration: "PT1H")
    |> Session.needs(:room, seats: 100)
  end

  defp conf(tracks_or_sessions) do
    Enum.reduce(
      tracks_or_sessions,
      Agenda.programme("Conf", across: "2026-09-15/2026-09-16"),
      fn
        %Track{} = track, programme -> Programme.add_track(programme, track)
        session, programme -> Programme.add_session(programme, session)
      end
    )
  end

  describe "minimal/3 — the algorithm itself" do
    # A set holds together while its members sum to ten or less. That
    # is monotone, which is all QuickXplain asks of an oracle.
    defp room_for(chosen), do: Enum.sum(chosen) <= 10

    test "nothing to explain when everything fits" do
      assert Conflict.minimal([1, 2, 3], &room_for/1) == :none
    end

    test "finds the pair that is jointly too much" do
      assert Conflict.minimal([6, 7, 1], &room_for/1) == {:ok, [6, 7]}
    end

    test "ignores members that are not part of the conflict" do
      assert Conflict.minimal([1, 2, 6, 7], &room_for/1) == {:ok, [6, 7]}
    end

    test "a single constraint can be the whole conflict" do
      assert Conflict.minimal([1, 2, 11], &room_for/1) == {:ok, [11]}
    end

    test "the result really is minimal" do
      # Twelve ones exceed ten; eleven of them is the smallest set
      # that still does.
      assert {:ok, conflict} = Conflict.minimal(List.duplicate(1, 12), &room_for/1)
      assert length(conflict) == 11

      refute room_for(conflict)
      assert room_for(tl(conflict))
    end

    test "an unsatisfiable background blames nothing in the constraints" do
      assert Conflict.minimal([1, 2], [20], &room_for/1) == {:ok, []}
    end

    test "the background is never named in the conflict" do
      assert {:ok, conflict} = Conflict.minimal([1, 2, 3], [7], &room_for/1)
      refute 7 in conflict
    end

    test "an empty constraint list has nothing to blame" do
      assert Conflict.minimal([], [20], &room_for/1) == {:ok, []}
      assert Conflict.minimal([], [2], &room_for/1) == :none
    end

    test "the conflict keeps the order it was given in" do
      assert {:ok, conflict} = Conflict.minimal([7, 1, 6], &room_for/1)
      assert conflict == [7, 6]
    end
  end

  describe "conflict/3 for a programme" do
    test "nothing to explain when the programme fits" do
      programme = conf([talk("Keynote"), talk("Deep dive")])

      assert Arranger.conflict(programme, [room("Hall", 3)]) == :none
    end

    test "names the sessions that cannot share the room" do
      # One hour of room, two one-hour talks.
      programme = conf([talk("Keynote"), talk("Deep dive")])

      assert {:ok, conflict} = Arranger.conflict(programme, [room("Hall", 1)])
      assert Enum.sort(conflict) == ["Deep dive", "Keynote"]
    end

    test "names only as many sessions as are actually in tension" do
      # Two hours of room and three talks: any two fit, all three do
      # not. The conflict is all three, and dropping any one resolves
      # it.
      programme = conf([talk("A"), talk("B"), talk("C")])
      pool = [room("Hall", 2)]

      assert {:ok, conflict} = Arranger.conflict(programme, pool)
      assert length(conflict) == 3

      assert Arranger.conflict(conf([talk("A"), talk("B")]), pool) == :none
    end

    test "the conflict is smaller than the programme" do
      # Six hours of room. Five talks fit easily; a sixth and seventh
      # do not, but the conflict should not name every session that
      # merely happens to be present.
      hall = room("Hall", 2)

      programme = conf(Enum.map(1..6, &talk("S#{&1}")))

      assert {:ok, conflict} = Arranger.conflict(programme, [hall])
      # Two hours means two placements; three sessions is the smallest
      # set that cannot fit.
      assert length(conflict) == 3
    end

    test "a session nothing can satisfy is a conflict of one" do
      lecture =
        Agenda.session("Lecture", duration: "PT1H")
        |> Session.needs(:room, seats: 500)

      programme = conf([talk("Keynote"), lecture])

      assert Arranger.conflict(programme, [room("Hall", 3)]) == {:ok, ["Lecture"]}
    end

    test "pinned sessions are background, never named" do
      programme = conf([talk("A"), talk("B")])
      pool = [room("Hall", 1)]

      {:ok, arrangements} = Agenda.plan(pick(programme, "A"), pool)
      pin = arrangements |> hd() |> Map.put(:session, "A")

      assert {:ok, conflict} = Arranger.conflict(programme, pool, pinned: [pin])
      assert conflict == ["B"]
    end

    test "pins that cannot be arranged at all blame nothing else" do
      programme = conf([talk("A"), talk("B")])
      pool = [room("Hall", 1)]

      {:ok, arrangements} = Agenda.plan(pick(programme, "A"), pool)
      slot = arrangements |> hd() |> Map.put(:session, "A")
      clash = %{slot | session: "B"}

      assert Arranger.conflict(programme, pool, pinned: [slot, clash]) == {:ok, []}
    end

    defp pick(programme, name) do
      programme
      |> Programme.all_sessions()
      |> Enum.find(&(&1.name == name))
      |> Map.put(:window, programme.window)
    end
  end

  describe "conflict/3 for a session" do
    test "nothing to explain when the session can be held" do
      boardroom = room("Boardroom", 3, video_conferencing: true)

      session =
        Agenda.session("Review", duration: "PT1H", window: "2026-09-15/2026-09-16")
        |> Session.needs(:room, seats: at_least(8), video_conferencing: true)

      assert Planner.conflict(session, [boardroom]) == :none
    end

    test "names the two demands that are impossible together" do
      # Each room satisfies one demand but not both.
      snug = room("Snug", 3, seats: 4, video_conferencing: true)
      barn = room("Barn", 3, seats: 40, video_conferencing: false)

      session =
        Agenda.session("Review", duration: "PT1H", window: "2026-09-15/2026-09-16")
        |> Session.needs(:room, seats: at_least(8), video_conferencing: true)

      assert {:ok, conflict} = Planner.conflict(session, [snug, barn])

      assert Enum.sort(conflict) == [
               needs: {:room, :seats},
               needs: {:room, :video_conferencing}
             ]
    end

    test "a single impossible demand is a conflict of one" do
      barn = room("Barn", 3, seats: 40, video_conferencing: true)

      session =
        Agenda.session("Review", duration: "PT1H", window: "2026-09-15/2026-09-16")
        |> Session.needs(:room, seats: at_least(500), video_conferencing: true)

      assert Planner.conflict(session, [barn]) == {:ok, [needs: {:room, :seats}]}
    end

    test "an induced requirement is named alongside the demand it fights" do
      # The attic has video conferencing but no step-free access; the
      # annexe is accessible but has no video conferencing. Alice needs
      # step-free access, and the session needs video conferencing —
      # separately fine, together impossible.
      attic = room("Attic", 3, video_conferencing: true, step_free_access: false)
      annexe = room("Annexe", 3, video_conferencing: false, step_free_access: true)

      alice = Agenda.resource("Alice", requires: [step_free_access: true])
      {:ok, alice} = Agenda.open(alice, "2026-09-15T09:00:00/2026-09-15T12:00:00")

      session =
        Agenda.session("Review", duration: "PT1H", window: "2026-09-15/2026-09-16")
        |> Session.needs(:room, video_conferencing: true)
        |> Session.roster(:attendees, [alice])

      assert {:ok, conflict} = Planner.conflict(session, [attic, annexe])

      assert Enum.sort(conflict) == [
               needs: {:room, :video_conferencing},
               requires: {"Alice", :step_free_access}
             ]
    end

    test "no demand is to blame when nothing is free" do
      # The room satisfies every demand and is simply never open long
      # enough.
      snug = room("Snug", 1, video_conferencing: true)

      session =
        Agenda.session("Review", duration: "PT3H", window: "2026-09-15/2026-09-16")
        |> Session.needs(:room, seats: at_least(8), video_conferencing: true)

      assert Planner.conflict(session, [snug]) == {:ok, []}
    end
  end

  describe "Agenda.conflict/3 dispatches on what it is given" do
    test "a programme" do
      programme = conf([talk("Keynote"), talk("Deep dive")])

      assert {:ok, conflict} = Agenda.conflict(programme, [room("Hall", 1)])
      assert Enum.sort(conflict) == ["Deep dive", "Keynote"]
    end

    test "a session" do
      session =
        Agenda.session("Review", duration: "PT1H", window: "2026-09-15/2026-09-16")
        |> Session.needs(:room, seats: at_least(500))

      assert Agenda.conflict(session, [room("Hall", 3)]) == {:ok, [needs: {:room, :seats}]}
    end
  end
end
