defmodule Agenda.RearrangeTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Session

  # Moving a session must not release the bindings it still wants. The
  # release/re-acquire pair hands the resource to a competing booking in
  # the gap, and churns records for resources that never moved.

  setup do
    day = ~o"2027-03-01T09:00/T17:00"

    {:ok, priya} = Agenda.resource("Priya") |> Agenda.open(day)
    {:ok, tom} = Agenda.resource("Tom") |> Agenda.open(day)
    {:ok, boardroom} = Agenda.resource("Boardroom", seats: 14) |> Agenda.open(day)
    {:ok, annexe} = Agenda.resource("Annexe", seats: 12) |> Agenda.open(day)

    review =
      Agenda.session("Quarterly review", duration: ~o"PT1H", window: ~o"2027-03-01/2027-03-02")
      |> Session.roster(:room, [boardroom])
      |> Session.roster(:attendees, [priya, tom])

    {:ok, [booked | _rest]} = Agenda.plan(review, [boardroom, priya, tom])
    {:ok, ledger} = Agenda.allocate(Agenda.ledger(), booked)

    %{ledger: ledger, review: review, annexe: annexe, priya: priya, tom: tom, booked: booked}
  end

  test "changing only the room keeps the people", context do
    moved_session =
      Agenda.session("Quarterly review", duration: ~o"PT1H", window: ~o"2027-03-01/2027-03-02")
      |> Session.roster(:room, [context.annexe])
      |> Session.roster(:attendees, [context.priya, context.tom])

    {:ok, [moved | _rest]} =
      Agenda.plan(moved_session, [context.annexe, context.priya, context.tom],
        busy: Agenda.busy(context.ledger, except: ["Quarterly review"])
      )

    changes = Agenda.rearrange(context.ledger, "Quarterly review", moved)

    kept = for {:keep, allocation} <- changes, do: allocation.resource
    released = for {:release, allocation} <- changes, do: allocation.resource
    allocated = for {:allocate, allocation} <- changes, do: allocation.resource

    assert Enum.sort(kept) == ["Priya", "Tom"]
    assert released == ["Boardroom"]
    assert allocated == ["Annexe"]
  end

  test "moving nothing releases nothing", context do
    changes = Agenda.rearrange(context.ledger, "Quarterly review", context.booked)

    assert Enum.map(changes, &elem(&1, 0)) == [:keep, :keep, :keep]
  end
end
