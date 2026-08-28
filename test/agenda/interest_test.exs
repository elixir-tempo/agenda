defmodule Agenda.InterestTest do
  use ExUnit.Case, async: true

  alias Agenda.Interest

  doctest Agenda.Interest

  describe "new/2" do
    test "accepts resources as well as names" do
      kim = Agenda.resource("Kim")
      harbour = Agenda.resource("Harbour Tours")

      assert {:ok, interest} = Interest.new(kim, harbour)
      assert interest.from == "Kim"
      assert interest.to == "Harbour Tours"
    end

    test "refuses a resource naming itself" do
      assert {:error, :self_interest} = Interest.new(Agenda.resource("Kim"), "Kim")
    end
  end

  describe "mutual/1" do
    test "a pair appears once however many times it was stated" do
      {:ok, a} = Interest.new("Kim", "Harbour")
      {:ok, b} = Interest.new("Harbour", "Kim")

      assert Interest.mutual([a, b, a, b]) == [{"Harbour", "Kim"}]
    end

    test "the order interests were registered in does not change the answer" do
      {:ok, a} = Interest.new("Kim", "Harbour")
      {:ok, b} = Interest.new("Harbour", "Kim")
      {:ok, c} = Interest.new("Sam", "Harbour")
      {:ok, d} = Interest.new("Harbour", "Sam")

      assert Interest.mutual([a, b, c, d]) == Interest.mutual([d, c, b, a])
    end

    test "one-sided interest is not a match" do
      {:ok, a} = Interest.new("Kim", "Harbour")
      {:ok, c} = Interest.new("Sam", "Harbour")

      assert Interest.mutual([a, c]) == []
      assert Interest.one_sided([a, c]) |> length() == 2
    end

    test "mutual and one-sided partition the interests" do
      interests =
        for {from, to} <- [{"A", "B"}, {"B", "A"}, {"C", "A"}, {"A", "D"}] do
          {:ok, interest} = Interest.new(from, to)
          interest
        end

      # Two of the four are the A/B pair; the other two were never returned.
      assert Interest.mutual(interests) == [{"A", "B"}]
      assert Interest.one_sided(interests) |> Enum.map(& &1.from) == ["C", "A"]
    end
  end
end
