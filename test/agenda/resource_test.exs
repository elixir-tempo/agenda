defmodule Agenda.ResourceTest do
  use ExUnit.Case, async: true

  alias Agenda.Place
  alias Agenda.Resource

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
end
