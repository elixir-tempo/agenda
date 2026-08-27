defmodule Agenda.RequiredOptionsTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  # A library returns `{:error, reason}`; it does not raise on bad input,
  # and an omitted required option is bad input like any other.

  setup do
    {:ok, hall} =
      Agenda.resource("Hall", seats: 100)
      |> Agenda.open(~o"2026-09-15T09:00/T17:00")

    arrangement = %Agenda.Arrangement{
      session: "Keynote",
      interval: ~o"2026-09-15T09:00/T10:00",
      allocations: %{room: [hall]}
    }

    {:ok, ledger} = Agenda.allocate(Agenda.ledger(), arrangement)

    %{hall: hall, arrangement: arrangement, ledger: ledger}
  end

  test "free/2 without :within", context do
    assert Agenda.free(context.hall, []) == {:error, {:missing_option, :within}}
  end

  test "hold/3 without :until", context do
    assert Agenda.hold(context.ledger, context.arrangement, []) ==
             {:error, {:missing_option, :until}}
  end

  test "reconcile/3 without :within", context do
    assert Agenda.reconcile(context.ledger, context.hall, []) ==
             {:error, {:missing_option, :within}}
  end

  test "reachable/2 without :within" do
    assert Agenda.reachable(Agenda.track("Core"), []) == {:error, {:missing_option, :within}}
  end

  test "each still works when the option is given", context do
    assert {:ok, _} = Agenda.free(context.hall, within: ~o"2026-09-15/2026-09-16")

    assert {:ok, _} =
             Agenda.hold(context.ledger, context.arrangement, until: ~o"2026-09-15T09:05")

    assert {:ok, _} =
             Agenda.reconcile(context.ledger, context.hall, within: ~o"2026-09-15/2026-09-16")

    assert {:ok, _} = Agenda.reachable(Agenda.track("Core"), within: ~o"PT10M")
  end
end
