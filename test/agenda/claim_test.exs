defmodule Agenda.ClaimTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Ledger
  alias Agenda.Reconciliation

  @shift [~o"T09/T12", ~o"T13/T17"]

  defp dana do
    {:ok, workdays} = Tempo.select(~o"2026-08-01/2026-09-01", Tempo.workdays(:AU))
    {:ok, hours} = Tempo.select(workdays, @shift)
    {:ok, dana} = Agenda.open(Agenda.resource("Dana"), hours)
    dana
  end

  describe "claim/4 books what the resource can honour" do
    test "an interval inside the working pattern is claimed" do
      assert {:ok, ledger} =
               Agenda.claim(Agenda.ledger(), dana(), ~o"2026-08-10T09:00:00/2026-08-10T12:00:00")

      assert Agenda.count(ledger) == 1
    end

    test "the tag is carried through" do
      assert {:ok, ledger} =
               Agenda.claim(Agenda.ledger(), dana(), ~o"2026-08-10T09:00:00/2026-08-10T12:00:00",
                 tag: {:project, "ACME"}
               )

      assert [%{tag: {:project, "ACME"}}] = Ledger.to_list(ledger)
    end

    test "the role defaults to :resource and can be overridden" do
      resource = dana()
      span = ~o"2026-08-10T09:00:00/2026-08-10T12:00:00"

      assert {:ok, default} = Agenda.claim(Agenda.ledger(), resource, span)
      assert [%{role: :resource}] = Ledger.to_list(default)

      assert {:ok, named} = Agenda.claim(Agenda.ledger(), resource, span, role: :consultant)
      assert [%{role: :consultant}] = Ledger.to_list(named)
    end

    test "the session defaults to the interval and is what release takes" do
      resource = dana()
      span = ~o"2026-08-10T09:00:00/2026-08-10T12:00:00"

      assert {:ok, ledger} = Agenda.claim(Agenda.ledger(), resource, span)
      assert {:ok, released} = Agenda.release(ledger, Tempo.to_iso8601(span))
      assert Agenda.count(released) == 0
    end

    test "an ISO 8601 string is accepted, not only a Tempo value" do
      assert {:ok, ledger} =
               Agenda.claim(Agenda.ledger(), dana(), "2026-08-10T09:00:00/2026-08-10T12:00:00")

      assert Agenda.count(ledger) == 1
    end
  end

  describe "claim/4 refuses what it cannot" do
    test "a day the resource does not work" do
      assert {:error, reason} =
               Agenda.claim(Agenda.ledger(), dana(), ~o"2026-08-15T09:00:00/2026-08-15T12:00:00")

      assert reason =~ "Dana is not open"
      assert reason =~ "2026Y8M15D"
    end

    test "an hour outside the working day names only the part that is outside" do
      assert {:error, reason} =
               Agenda.claim(Agenda.ledger(), dana(), ~o"2026-08-10T16:00:00/2026-08-10T19:00:00")

      # 16:00-17:00 is open; only 17:00-19:00 is refused.
      assert reason == "Dana is not open for 2026Y8M10DT17H0M0S/2026Y8M10DT19H0M0S"
    end

    test "the lunch break is not open time" do
      assert {:error, reason} =
               Agenda.claim(Agenda.ledger(), dana(), ~o"2026-08-10T09:00:00/2026-08-10T14:00:00")

      assert reason == "Dana is not open for 2026Y8M10DT12H0M0S/2026Y8M10DT13H0M0S"
    end

    test "an hour already claimed" do
      resource = dana()

      assert {:ok, ledger} =
               Agenda.claim(
                 Agenda.ledger(),
                 resource,
                 ~o"2026-08-10T09:00:00/2026-08-10T12:00:00"
               )

      # Wholly inside the morning session, so the only objection can be
      # the existing claim.
      assert {:error, reason} =
               Agenda.claim(ledger, resource, ~o"2026-08-10T11:00:00/2026-08-10T11:30:00")

      assert reason == "Dana is already claimed for 2026Y8M10DT11H0M0S/2026Y8M10DT11H30M0S"
    end

    test "not-open is reported ahead of already-claimed" do
      # A Saturday cannot be "already claimed" in any useful sense, and
      # saying so would send the caller looking in the ledger rather
      # than at the contract.
      resource = dana()

      assert {:ok, ledger} =
               Agenda.claim(
                 Agenda.ledger(),
                 resource,
                 ~o"2026-08-10T09:00:00/2026-08-10T12:00:00"
               )

      assert {:error, reason} =
               Agenda.claim(ledger, resource, ~o"2026-08-15T09:00:00/2026-08-15T12:00:00")

      assert reason =~ "not open"
    end

    test "a refused claim leaves the ledger untouched" do
      resource = dana()

      assert {:ok, ledger} =
               Agenda.claim(
                 Agenda.ledger(),
                 resource,
                 ~o"2026-08-10T09:00:00/2026-08-10T12:00:00"
               )

      assert {:error, _reason} =
               Agenda.claim(ledger, resource, ~o"2026-08-10T09:00:00/2026-08-10T12:00:00")

      assert Agenda.count(ledger) == 1
    end
  end

  describe "claim and allocate share one ledger" do
    test "a recorded hour blocks a later booking of the same hour" do
      resource = dana()
      span = ~o"2026-08-10T09:00:00/2026-08-10T12:00:00"

      recorded = %Agenda.Arrangement{
        session: "timesheet",
        interval: span,
        allocations: %{consultant: [resource]}
      }

      assert {:ok, ledger} = Agenda.allocate(Agenda.ledger(), recorded, tag: {:project, "ACME"})
      assert {:error, reason} = Agenda.claim(ledger, resource, span)
      assert reason =~ "already claimed"
    end

    test "allocate still records time the contract does not cover" do
      # The world is not obliged to match the contract: someone did work
      # that Saturday, and refusing to write it down would leave the
      # system unable to represent overtime.
      resource = dana()

      overtime = %Agenda.Arrangement{
        session: "saturday",
        interval: ~o"2026-08-15T09:00:00/2026-08-15T12:00:00",
        allocations: %{consultant: [resource]}
      }

      assert {:ok, ledger} = Agenda.allocate(Agenda.ledger(), overtime, tag: {:project, "ACME"})
      assert Agenda.count(ledger) == 1

      # And reconciliation is what reports the disagreement.
      assert {:ok, report} =
               Agenda.reconcile(ledger, resource, within: ~o"2026-08-15/2026-08-16")

      refute Reconciliation.balanced?(report)
    end
  end
end
