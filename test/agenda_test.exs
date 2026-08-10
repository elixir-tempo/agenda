defmodule AgendaTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  doctest Agenda

  setup do
    sydney = Agenda.place("Sydney Convention Centre")
    level_2 = Agenda.place("Level 2", within: sydney)
    level_3 = Agenda.place("Level 3", within: sydney)
    darling = Agenda.place("Darling Harbour Theatre")

    %{
      boardroom: Agenda.resource("Boardroom", within: level_2),
      annexe: Agenda.resource("Annexe", within: level_2),
      upstairs: Agenda.resource("Upstairs", within: level_3),
      main_stage: Agenda.resource("Main Stage", within: darling),
      placeless: Agenda.resource("Placeless")
    }
  end

  describe "travel_time/3" do
    test "no time is needed to stay put", context do
      assert Agenda.travel_time(context.boardroom, context.annexe) == {:ok, ~o"PT0M"}
    end

    test "a different level costs more than the same one", context do
      assert Agenda.travel_time(context.boardroom, context.upstairs) == {:ok, ~o"PT5M"}
    end

    test "unrelated places are unknown rather than guessed", context do
      assert Agenda.travel_time(context.boardroom, context.main_stage) == {:error, :unknown}
      assert Agenda.travel_time(context.boardroom, context.placeless) == {:error, :unknown}
    end

    test "is symmetric", context do
      assert Agenda.travel_time(context.boardroom, context.upstairs) ==
               Agenda.travel_time(context.upstairs, context.boardroom)
    end

    test "a pair override beats the table", context do
      options = [between: [{{"Boardroom", "Upstairs"}, ~o"PT12M"}]]

      assert Agenda.travel_time(context.boardroom, context.upstairs, options) ==
               {:ok, ~o"PT12M"}
    end

    test "a pair override holds in either direction", context do
      options = [between: [{{"Upstairs", "Boardroom"}, ~o"PT12M"}]]

      assert Agenda.travel_time(context.boardroom, context.upstairs, options) ==
               {:ok, ~o"PT12M"}
    end

    test "an override rescues an otherwise unknown journey", context do
      options = [between: [{{"Boardroom", "Main Stage"}, ~o"PT25M"}]]

      assert Agenda.travel_time(context.boardroom, context.main_stage, options) ==
               {:ok, ~o"PT25M"}
    end

    test "the level table can be replaced wholesale", context do
      options = [levels: %{0 => ~o"PT1M", 1 => ~o"PT2M"}]

      assert Agenda.travel_time(context.boardroom, context.annexe, options) == {:ok, ~o"PT1M"}

      assert Agenda.travel_time(context.boardroom, context.upstairs, options) ==
               {:ok, ~o"PT2M"}
    end

    test "separations beyond the table fall back to :distant", context do
      options = [levels: %{0 => ~o"PT1M"}, distant: ~o"PT99M"]

      assert Agenda.travel_time(context.boardroom, context.upstairs, options) ==
               {:ok, ~o"PT99M"}
    end
  end

  describe "explain/2" do
    test "says so plainly when a resource qualifies" do
      boardroom = Agenda.resource("Boardroom", seats: 8)
      requirement = Agenda.needs(:room, seats: 8)

      assert Agenda.explain(requirement, boardroom) == "Boardroom qualifies"
    end

    test "joins several failures into one sentence" do
      small = Agenda.resource("Meeting room 2", seats: 4)
      requirement = Agenda.needs(:room, seats: 8, projector: true)

      assert Agenda.explain(requirement, small) ==
               "Meeting room 2: no projector — needs true; seats is 4 — needs 8"
    end
  end
end
