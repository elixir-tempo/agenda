defmodule Agenda.ResourceWishesTest do
  use ExUnit.Case, async: true

  alias Agenda.Arrangement
  alias Agenda.Programme
  alias Agenda.Session

  @day "2027-04-05/2027-04-06"
  @morning "2027-04-05T09:00:00/2027-04-05T12:00:00"
  @afternoon "2027-04-05T13:00:00/2027-04-05T17:00:00"

  defp staff(name, wishes) do
    {:ok, person} =
      Agenda.resource(name, [qualified: true] ++ wishes)
      |> Agenda.open("2027-04-05T09:00:00/2027-04-05T17:00:00")

    person
  end

  defp shift(name) do
    name
    |> Agenda.session(duration: "PT1H", window: @day)
    |> Session.needs(:staff, qualified: true)
  end

  defp roster(names, wishes) do
    programme =
      Enum.reduce(
        names,
        Agenda.programme("Roster", across: @day),
        &Programme.add_session(&2, shift(&1))
      )

    {:ok, programme} = Agenda.prefer(programme, :resource_wishes, weight: wishes)
    programme
  end

  defp hours(arrangements) do
    arrangements |> Enum.map(& &1.interval.from.time[:hour]) |> Enum.sort()
  end

  describe "avoids" do
    test "a placement in avoided time is preferred against" do
      ann = staff("Ann", avoids: @morning)

      assert {:ok, arrangements} = Agenda.arrange(roster(["Shift"], 10), [ann])
      # The avoided morning runs to noon, so noon is the first hour
      # Ann is content with.
      assert hours(arrangements) == [12]
    end

    test "and it is a wish, not a rule — the morning is still bookable" do
      # The distinction that matters: `avoids` makes a placement worse,
      # `open/2` makes it impossible. Four shifts cannot all miss the
      # morning, so some take it.
      ann = staff("Ann", avoids: @morning)

      assert {:ok, arrangements} = Agenda.arrange(roster(~w(A B C D E F), 10), [ann])
      assert length(arrangements) == 6
      assert 9 in hours(arrangements)
    end

    test "the violations are counted, not merely detected" do
      ann = staff("Ann", avoids: @morning)
      programme = roster(~w(A B C D E F), 10)

      {:ok, arrangements} = Agenda.arrange(programme, [ann])

      # Five hours sit outside the avoided morning, so exactly one of
      # the six shifts has to land in it.
      assert [sentence] = Agenda.explain_score(arrangements, programme)
      assert sentence =~ "resource_wishes: 1 × 10 = 10"
    end
  end

  describe "prefers" do
    test "a placement outside preferred time is preferred against" do
      raj = staff("Raj", prefers: @afternoon)

      assert {:ok, arrangements} = Agenda.arrange(roster(["Shift"], 10), [raj])
      assert hd(hours(arrangements)) >= 13
    end

    test "a placement inside it scores zero" do
      raj = staff("Raj", prefers: @afternoon)
      programme = roster(["Shift"], 10)

      {:ok, arrangements} = Agenda.arrange(programme, [raj])

      assert Agenda.score(arrangements, programme) == 0
    end
  end

  describe "wishes across people" do
    test "work lands on whoever wants it" do
      # Ann will not work mornings, Raj would rather not work
      # afternoons. Two shifts, one each way round.
      ann = staff("Ann", avoids: @morning)
      raj = staff("Raj", avoids: @afternoon)

      programme = roster(~w(First Second), 10)

      assert {:ok, arrangements} = Agenda.arrange(programme, [ann, raj])
      assert Agenda.score(arrangements, programme) == 0
    end

    test "a resource with no wishes is never a violation" do
      indifferent = staff("Sam", [])
      programme = roster(~w(A B C), 10)

      {:ok, arrangements} = Agenda.arrange(programme, [indifferent])

      assert Agenda.score(arrangements, programme) == 0
    end
  end

  describe "wishes and the rest of the library" do
    test "a wish never costs a placement" do
      # The lexicographic guarantee holds for this preference as for
      # any other: eight open hours, eight shifts, all placed even
      # though most of them land where Ann would rather not be.
      ann = staff("Ann", avoids: "2027-04-05T09:00:00/2027-04-05T17:00:00")

      assert {:ok, arrangements} =
               Agenda.arrange(roster(~w(A B C D E F G H), 100), [ann])

      assert length(arrangements) == 8
    end

    test "wishes are ignored unless the programme asks for them" do
      ann = staff("Ann", avoids: @morning)

      plain =
        Agenda.programme("Roster", across: @day)
        |> Programme.add_session(shift("Shift"))

      assert {:ok, arrangements} = Agenda.arrange(plain, [ann])
      assert Agenda.score(arrangements, plain) == 0
      assert length(arrangements) == 1
    end

    test "an unreadable wish scores nothing rather than failing the layout" do
      # A preference must never be able to break an arrangement that is
      # otherwise valid.
      ann = staff("Ann", avoids: "whenever I feel like it")

      assert {:ok, arrangements} = Agenda.arrange(roster(["Shift"], 10), [ann])
      assert length(arrangements) == 1
    end

    test "a wish applies to whichever role the resource fills" do
      # Rooms have wishes too — a hall that would rather not be used
      # before noon is the same mechanism.
      {:ok, hall} =
        Agenda.resource("Hall", qualified: true, avoids: @morning)
        |> Agenda.open("2027-04-05T09:00:00/2027-04-05T17:00:00")

      assert {:ok, arrangements} = Agenda.arrange(roster(["Shift"], 10), [hall])
      assert [%Arrangement{}] = arrangements
      assert hours(arrangements) == [12]
    end
  end
end
