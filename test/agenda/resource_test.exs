defmodule Agenda.ResourceTest do
  use ExUnit.Case, async: true

  alias Agenda.Arrangement
  alias Agenda.Place
  alias Agenda.Resource
  alias Agenda.Session

  doctest Agenda.Resource

  describe "new/2" do
    test "unreserved options become attributes" do
      room = Resource.new("Boardroom", seats: 8, video_conferencing: true)

      assert room.attributes == %{seats: 8, video_conferencing: true}
    end

    test "reserved options do not leak into attributes" do
      level_2 = Place.new("Level 2")
      room = Resource.new("Boardroom", within: level_2, concurrency: 3, seats: 8)

      assert room.attributes == %{seats: 8}
      assert room.within == level_2
      assert room.concurrency == 3
    end

    test "concurrency defaults to one — a resource holds one session at a time" do
      assert Resource.new("Boardroom").concurrency == 1
    end

    test "seats and concurrency are independent" do
      hall = Resource.new("Lecture hall", seats: 200)
      lockers = Resource.new("Lockers", seats: 1, concurrency: 20)

      assert hall.concurrency == 1
      assert Resource.attribute(hall, :seats) == 200
      assert lockers.concurrency == 20
    end
  end

  describe "separation/2" do
    setup do
      sydney = Place.new("Sydney Convention Centre")
      level_2 = Place.new("Level 2", within: sydney)

      %{
        boardroom: Resource.new("Boardroom", within: level_2),
        annexe: Resource.new("Annexe", within: level_2),
        placeless: Resource.new("Placeless")
      }
    end

    test "two resources in the same place are not apart", context do
      assert Resource.separation(context.boardroom, context.annexe) == 0
    end

    test "a placeless resource is disjoint from everything", context do
      assert Resource.separation(context.placeless, context.boardroom) == :disjoint
      assert Resource.separation(context.boardroom, context.placeless) == :disjoint
      assert Resource.separation(context.placeless, context.placeless) == :disjoint
    end
  end

  describe "fetch/2 and fetch_all/2" do
    setup do
      %{pool: [Resource.new("Ann"), Resource.new("Bo"), Resource.new("Cee")]}
    end

    test "fetch finds by name", context do
      assert {:ok, resource} = Resource.fetch(context.pool, "Bo")
      assert resource.name == "Bo"
    end

    test "fetch names the resource it could not find", context do
      assert Resource.fetch(context.pool, "Bob") == {:error, {:unknown_resource, "Bob"}}
    end

    test "fetch tolerates an empty pool and an empty name" do
      assert Resource.fetch([], "Ann") == {:error, {:unknown_resource, "Ann"}}
      assert Resource.fetch([Resource.new("Ann")], "") == {:error, {:unknown_resource, ""}}
    end

    test "fetch_all preserves the order asked for, not the pool order", context do
      assert {:ok, resources} = Resource.fetch_all(context.pool, ["Cee", "Ann"])
      assert Enum.map(resources, & &1.name) == ["Cee", "Ann"]
    end

    test "fetch_all repeats a name repeated", context do
      assert {:ok, resources} = Resource.fetch_all(context.pool, ["Ann", "Ann"])
      assert Enum.map(resources, & &1.name) == ["Ann", "Ann"]
    end

    test "fetch_all reports every unknown name, not just the first", context do
      assert Resource.fetch_all(context.pool, ["Ann", "Bob", "Cee", "Dee"]) ==
               {:error, {:unknown_resources, ["Bob", "Dee"]}}
    end

    test "fetch_all of nothing is nothing", context do
      assert Resource.fetch_all(context.pool, []) == {:ok, []}
    end
  end

  describe "calendar user type" do
    test "cutype/1 reads the cutype: attribute, :unknown when there is none" do
      assert Resource.cutype(Resource.new("Alice", cutype: :individual)) == :individual
      assert Resource.cutype(Resource.new("Design team", cutype: :group)) == :group
      assert Resource.cutype(Resource.new("Boardroom", seats: 8)) == :unknown
    end

    test "resource_type/1 reads the resource_type: attribute, nil when there is none" do
      projector = Resource.new("Projector 2", cutype: :resource, resource_type: :projector)

      assert Resource.resource_type(projector) == :projector
      assert Resource.resource_type(Resource.new("Alice")) == nil
    end

    test "a value outside the lists is kept as given" do
      assert Resource.cutype(Resource.new("Kiosk", cutype: :x_kiosk)) == :x_kiosk
      assert Resource.resource_type(Resource.new("Desk", resource_type: :x_desk)) == :x_desk
    end

    test "both are ordinary attributes, so a session can ask for them" do
      projector = Resource.new("Projector 2", cutype: :resource, resource_type: :projector)
      speaker = Resource.new("Speakerphone", resource_type: :remote_conference_audio)

      assert projector.attributes == %{cutype: :resource, resource_type: :projector}

      {:ok, room} =
        Agenda.resource("Boardroom", cutype: :room, resource_type: :room)
        |> Agenda.open("2026-06-15T09:00:00/2026-06-15T17:00:00")

      {:ok, projector} = Agenda.open(projector, "2026-06-15T09:00:00/2026-06-15T17:00:00")
      {:ok, speaker} = Agenda.open(speaker, "2026-06-15T09:00:00/2026-06-15T17:00:00")

      session =
        Agenda.session("Review", duration: "PT1H", window: "2026-06-15/2026-06-15")
        |> Session.needs(:room, cutype: :room)
        |> Session.needs(:kit, resource_type: :projector)

      {:ok, [best | _]} = Agenda.plan(session, [room, projector, speaker])

      assert Arrangement.resource(best, :kit).name == "Projector 2"
      assert Arrangement.resource(best, :room).name == "Boardroom"
    end
  end
end
