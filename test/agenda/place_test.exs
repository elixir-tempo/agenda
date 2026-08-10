defmodule Agenda.PlaceTest do
  use ExUnit.Case, async: true

  alias Agenda.Place

  doctest Agenda.Place

  setup do
    sydney = Place.new("Sydney Convention Centre")
    level_2 = Place.new("Level 2", within: sydney)
    level_3 = Place.new("Level 3", within: sydney)
    east_wing = Place.new("East Wing", within: level_2)
    darling = Place.new("Darling Harbour Theatre")

    %{
      sydney: sydney,
      level_2: level_2,
      level_3: level_3,
      east_wing: east_wing,
      darling: darling
    }
  end

  describe "separation/2" do
    test "a place is zero from itself", %{level_2: level_2} do
      assert Place.separation(level_2, level_2) == 0
    end

    test "siblings are one level apart", %{level_2: level_2, level_3: level_3} do
      assert Place.separation(level_2, level_3) == 1
    end

    test "is symmetric", %{east_wing: east_wing, level_3: level_3} do
      assert Place.separation(east_wing, level_3) == Place.separation(level_3, east_wing)
    end

    test "measures from the deeper place up to the common ancestor",
         %{east_wing: east_wing, level_3: level_3} do
      # east_wing is two below sydney, level_3 is one below.
      assert Place.separation(east_wing, level_3) == 2
    end

    test "a parent and its child are one apart", %{sydney: sydney, level_2: level_2} do
      assert Place.separation(sydney, level_2) == 1
    end

    test "unrelated trees are disjoint", %{sydney: sydney, darling: darling} do
      assert Place.separation(sydney, darling) == :disjoint
    end

    test "separation grows monotonically with distance",
         %{level_2: level_2, level_3: level_3, east_wing: east_wing} do
      assert Place.separation(east_wing, east_wing) <
               Place.separation(east_wing, level_2)

      assert Place.separation(east_wing, level_2) <
               Place.separation(east_wing, level_3)
    end
  end

  describe "contains?/2" do
    test "a place contains itself", %{sydney: sydney} do
      assert Place.contains?(sydney, sydney)
    end

    test "contains transitively", %{sydney: sydney, east_wing: east_wing} do
      assert Place.contains?(sydney, east_wing)
    end

    test "containment is directional", %{sydney: sydney, east_wing: east_wing} do
      refute Place.contains?(east_wing, sydney)
    end

    test "unrelated places do not contain each other", %{sydney: sydney, darling: darling} do
      refute Place.contains?(sydney, darling)
      refute Place.contains?(darling, sydney)
    end
  end

  describe "identity" do
    test "places built independently but naming the same chain are the same place",
         %{sydney: sydney, level_2: level_2} do
      rebuilt = Place.new("Level 2", within: Place.new("Sydney Convention Centre"))

      assert Place.separation(level_2, rebuilt) == 0
      assert Place.contains?(sydney, rebuilt)
    end

    test "the same name under a different parent is a different place", %{level_2: level_2} do
      elsewhere = Place.new("Level 2", within: Place.new("Melbourne Exhibition Centre"))

      assert Place.separation(level_2, elsewhere) == :disjoint
    end
  end

  describe "path/1 and root/1" do
    test "path runs outermost first", %{east_wing: east_wing} do
      assert Enum.map(Place.path(east_wing), & &1.name) ==
               ["Sydney Convention Centre", "Level 2", "East Wing"]
    end

    test "a root is its own root", %{sydney: sydney} do
      assert Place.root(sydney) == sydney
    end

    test "root climbs to the top", %{east_wing: east_wing, sydney: sydney} do
      assert Place.root(east_wing) == sydney
    end
  end
end
