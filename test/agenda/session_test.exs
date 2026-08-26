defmodule Agenda.SessionTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Session

  doctest Agenda.Session

  describe "roster/3 with nobody named" do
    test "adds no requirement" do
      session = Session.new("Review") |> Session.roster(:speaker, [])

      assert session.requirements == []
      assert Session.open_roles(session) == []
      assert Session.rosters(session) == []
    end

    test "a role that neither names nor describes never reaches planning" do
      {:ok, room} =
        Agenda.resource("Hall", seats: 250)
        |> Agenda.open(~o"2026-06-15T09:00/T17:00")

      session =
        Agenda.session("Keynote", duration: ~o"PT1H", window: ~o"2026-06-15T09:00/T10:00")
        |> Session.roster(:room, [room])
        |> Session.roster(:speaker, [])

      assert {:ok, [arrangement | _]} = Agenda.plan(session, [room])
      assert Map.keys(arrangement.allocations) == [:room]
    end
  end
end
