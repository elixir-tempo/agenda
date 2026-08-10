defmodule Agenda.RequirementTest do
  use ExUnit.Case, async: true

  import Agenda.Predicate

  alias Agenda.Requirement
  alias Agenda.Resource

  doctest Agenda.Requirement

  setup do
    %{
      boardroom:
        Resource.new("Boardroom",
          seats: 8,
          video_conferencing: true,
          step_free_access: true
        ),
      meeting_room_2: Resource.new("Meeting room 2", seats: 4),
      alice: Resource.new("Alice", requires: [step_free_access: true])
    }
  end

  describe "eligible?/2" do
    test "a resource meeting every predicate qualifies", context do
      requirement = Requirement.new(:room, seats: at_least(8), video_conferencing: true)

      assert Requirement.eligible?(requirement, context.boardroom)
    end

    test "a missing attribute disqualifies", context do
      requirement = Requirement.new(:room, projector: true)

      refute Requirement.eligible?(requirement, context.boardroom)
    end

    test "an empty requirement admits anything", context do
      assert Requirement.eligible?(Requirement.new(:room), context.meeting_room_2)
    end
  end

  describe "unmet/2 — the explanation is the decision" do
    test "names the attribute, the actual value, and what was needed", context do
      requirement = Requirement.new(:room, seats: at_least(8))

      assert Requirement.unmet(requirement, context.meeting_room_2) ==
               ["seats is 4 — needs at least 8"]
    end

    test "reports an absent attribute distinctly from a wrong one", context do
      requirement = Requirement.new(:room, projector: true)

      assert Requirement.unmet(requirement, context.meeting_room_2) ==
               ["no projector — needs true"]
    end

    test "reports every failure, not just the first", context do
      requirement =
        Requirement.new(:room, seats: at_least(8), video_conferencing: true, projector: true)

      assert length(Requirement.unmet(requirement, context.meeting_room_2)) == 3
    end

    test "is empty exactly when the resource is eligible", context do
      requirement = Requirement.new(:room, seats: at_least(8))

      assert Requirement.unmet(requirement, context.boardroom) == []
      assert Requirement.eligible?(requirement, context.boardroom)
    end

    test "is ordered by attribute name so explanations are stable", context do
      requirement = Requirement.new(:room, video_conferencing: true, projector: true)

      assert ["no projector" <> _, "no video_conferencing" <> _] =
               Requirement.unmet(requirement, context.meeting_room_2)
    end
  end

  describe "induce/2 — a person's needs bind the room" do
    test "folds a resource's requires into the requirement", context do
      room = Requirement.new(:room, seats: at_least(8))
      tightened = Requirement.induce(room, [context.alice])

      assert tightened.attributes |> Map.keys() |> Enum.sort() == [:seats, :step_free_access]
    end

    test "an accessible room still qualifies once Alice is added", context do
      room = Requirement.new(:room, seats: at_least(8))
      tightened = Requirement.induce(room, [context.alice])

      assert Requirement.eligible?(tightened, context.boardroom)
    end

    test "an inaccessible room stops qualifying once Alice is added", context do
      inaccessible = Resource.new("Attic", seats: 12)
      room = Requirement.new(:room, seats: at_least(8))

      assert Requirement.eligible?(room, inaccessible)

      tightened = Requirement.induce(room, [context.alice])

      refute Requirement.eligible?(tightened, inaccessible)

      assert Requirement.unmet(tightened, inaccessible) ==
               ["no step_free_access — needs true"]
    end

    test "resources with no requires change nothing", _context do
      room = Requirement.new(:room, seats: at_least(8))
      bob = Resource.new("Bob")

      assert Requirement.induce(room, [bob]) == room
    end
  end

  describe "eligible/2" do
    test "filters candidates and preserves order", context do
      requirement = Requirement.new(:room, seats: at_least(8))

      assert requirement
             |> Requirement.eligible([context.meeting_room_2, context.boardroom])
             |> Enum.map(& &1.name) == ["Boardroom"]
    end
  end

  describe "roster/2" do
    test "names specific resources rather than describing them", context do
      requirement = Requirement.roster(:attendees, [context.alice])

      assert Enum.map(requirement.roster, & &1.name) == ["Alice"]
      assert requirement.attributes == %{}
    end
  end
end
