defmodule Agenda.ReconciliationTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Arrangement
  alias Agenda.Limit
  alias Agenda.Reconciliation
  alias Tempo.Duration
  alias Tempo.IntervalSet

  doctest Agenda.Reconciliation

  # Monday to Friday, 9 to 5, in one week.
  @week "2026-06-15/2026-06-20"

  defp business_hours(days) do
    IntervalSet.new!(
      for day <- days do
        Tempo.from_iso8601!("2026-06-#{day}T09:00:00/2026-06-#{day}T17:00:00")
      end
    )
  end

  defp dana(options \\ []) do
    {:ok, dana} =
      Agenda.open(Agenda.resource("Dana", options), business_hours(15..19))

    dana
  end

  defp claim(ledger, resource, session, interval, tag) do
    {:ok, ledger} =
      Agenda.allocate(
        ledger,
        %Arrangement{
          session: session,
          interval: Tempo.from_iso8601!(interval),
          allocations: %{consultant: [resource]}
        },
        tag: tag
      )

    ledger
  end

  defp hours(duration) do
    {:ok, hours} = Duration.to_unit(duration, :hour)
    hours
  end

  defp total(set) do
    {_count, duration} = Limit.total(IntervalSet.to_list(set))
    hours(duration)
  end

  describe "a full week accounted for" do
    test "balances when every open hour is claimed" do
      dana = dana()

      ledger =
        Enum.reduce(15..19, Agenda.ledger(), fn day, ledger ->
          claim(
            ledger,
            dana,
            "Acme day #{day}",
            "2026-06-#{day}T09:00:00/2026-06-#{day}T17:00:00",
            {:project, "ACME"}
          )
        end)

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: @week)

      assert Reconciliation.balanced?(report)
      assert Reconciliation.explain(report) == []
      assert total(report.expected) == 40.0
      assert total(report.claimed) == 40.0
    end
  end

  describe "unaccounted time names the gap" do
    test "a missing afternoon is reported as an interval, not a shortfall" do
      dana = dana()

      ledger =
        claim(
          Agenda.ledger(),
          dana,
          "Acme",
          "2026-06-15T09:00:00/2026-06-15T12:00:00",
          {:project, "ACME"}
        )

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: "2026-06-15/2026-06-16")

      refute Reconciliation.balanced?(report)
      assert total(report.unaccounted) == 5.0

      assert report.unaccounted |> IntervalSet.to_list() |> Enum.map(&Tempo.to_iso8601/1) ==
               ["2026Y6M15DT12H0M0S/2026Y6M15DT17H0M0S"]
    end

    test "a balancing total is still caught when the days are wrong" do
      # This is the case a sum cannot see: a missed Monday and an
      # unexpected Saturday total to exactly the right number of hours.
      # The window runs to the 21st so that Saturday the 20th is inside
      # it — intervals are half-open, so `/2026-06-20` would exclude it.
      dana = dana()
      window = "2026-06-15/2026-06-21"

      ledger =
        claim(
          Agenda.ledger(),
          dana,
          "Saturday",
          "2026-06-20T09:00:00/2026-06-20T17:00:00",
          {:project, "ACME"}
        )

      ledger =
        Enum.reduce(16..19, ledger, fn day, ledger ->
          claim(
            ledger,
            dana,
            "Acme day #{day}",
            "2026-06-#{day}T09:00:00/2026-06-#{day}T17:00:00",
            {:project, "ACME"}
          )
        end)

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: window)

      # The totals match exactly, and the period is still wrong.
      assert total(report.claimed) == total(report.expected)
      refute Reconciliation.balanced?(report)
      assert total(report.unaccounted) == 8.0
      assert total(report.overclaimed) == 8.0
    end
  end

  describe "holidays reduce what is owed" do
    test "a holiday is not time the resource must account for" do
      dana = dana()
      holiday = IntervalSet.new!([~o"2026-06-15/2026-06-16"])

      ledger =
        Enum.reduce(16..19, Agenda.ledger(), fn day, ledger ->
          claim(
            ledger,
            dana,
            "Acme day #{day}",
            "2026-06-#{day}T09:00:00/2026-06-#{day}T17:00:00",
            {:project, "ACME"}
          )
        end)

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: @week, excluding: holiday)

      assert total(report.expected) == 32.0
      assert Reconciliation.balanced?(report)
    end

    test "a holiday inside a period of leave does not consume the leave" do
      # The payroll bug this design is meant to make unrepresentable.
      # Dana takes the whole week; Monday is a public holiday. Only the
      # four non-holiday days are owed, so only four are claimed as
      # leave — and the week still balances.
      dana = dana()
      holiday = IntervalSet.new!([~o"2026-06-15/2026-06-16"])

      ledger =
        Enum.reduce(16..19, Agenda.ledger(), fn day, ledger ->
          claim(
            ledger,
            dana,
            "Leave day #{day}",
            "2026-06-#{day}T09:00:00/2026-06-#{day}T17:00:00",
            {:leave, :annual}
          )
        end)

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: @week, excluding: holiday)

      assert Reconciliation.balanced?(report)

      # Four days of leave drawn, not five.
      assert hours(report.by_tag[{:leave, :annual}]) == 32.0
    end
  end

  describe "by_tag divides the period" do
    test "work and leave are counted separately in one ledger" do
      dana = dana()

      ledger =
        Agenda.ledger()
        |> claim(dana, "Acme", "2026-06-15T09:00:00/2026-06-15T17:00:00", {:project, "ACME"})
        |> claim(dana, "Beta", "2026-06-16T09:00:00/2026-06-16T17:00:00", {:project, "BETA"})
        |> claim(dana, "Leave", "2026-06-17T09:00:00/2026-06-17T17:00:00", {:leave, :annual})

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: @week)

      assert hours(report.by_tag[{:project, "ACME"}]) == 8.0
      assert hours(report.by_tag[{:project, "BETA"}]) == 8.0
      assert hours(report.by_tag[{:leave, :annual}]) == 8.0
    end

    test "untagged claims group under nil rather than being dropped" do
      dana = dana()

      ledger = claim(Agenda.ledger(), dana, "Acme", @week <> "T00:00:00", nil)
      ledger = claim(ledger, dana, "Acme", "2026-06-15T09:00:00/2026-06-15T17:00:00", nil)

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: @week)
      assert Map.has_key?(report.by_tag, nil)
    end
  end

  describe "limits — floors are checked here and nowhere else" do
    test "a weekly floor the claims do not reach is a breach" do
      dana = dana(limits: [week: [at_least: ~o"PT38H"]])

      ledger =
        Enum.reduce(15..18, Agenda.ledger(), fn day, ledger ->
          claim(
            ledger,
            dana,
            "Acme day #{day}",
            "2026-06-#{day}T09:00:00/2026-06-#{day}T17:00:00",
            {:project, "ACME"}
          )
        end)

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: @week)

      assert [%{period: :week, breach: {:under, {:duration, _}}}] = report.breaches
      refute Reconciliation.balanced?(report)

      assert Reconciliation.explain(report) |> Enum.any?(&(&1 =~ "less than 38 hours"))
    end

    test "a floor that is met is not a breach" do
      dana = dana(limits: [week: [at_least: ~o"PT38H"]])

      ledger =
        Enum.reduce(15..19, Agenda.ledger(), fn day, ledger ->
          claim(
            ledger,
            dana,
            "Acme day #{day}",
            "2026-06-#{day}T09:00:00/2026-06-#{day}T17:00:00",
            {:project, "ACME"}
          )
        end)

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: @week)
      assert report.breaches == []
    end

    test "a daily ceiling breach names the day at fault" do
      dana = dana(limits: [day: ~o"PT7H36M"])

      ledger =
        claim(
          Agenda.ledger(),
          dana,
          "Acme",
          "2026-06-15T09:00:00/2026-06-15T17:00:00",
          {:project, "ACME"}
        )

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: @week)

      assert [%{period: :day, bucket: {2026, 6, 15}, breach: {:over, _}}] = report.breaches
      assert Reconciliation.explain(report) |> Enum.any?(&(&1 =~ "2026-06-15"))
    end
  end

  describe "the window bounds everything" do
    test "claims outside the window are not counted" do
      dana = dana()

      ledger =
        claim(
          Agenda.ledger(),
          dana,
          "Next week",
          "2026-06-22T09:00:00/2026-06-22T17:00:00",
          {:project, "ACME"}
        )

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: @week)

      assert total(report.claimed) == 0.0
      assert report.by_tag == %{}
    end

    test "a holiday set outside the window costs nothing" do
      dana = dana()
      distant = IntervalSet.new!([~o"2030-01-01/2030-01-02"])

      assert {:ok, report} =
               Agenda.reconcile(ledger_for(dana), dana, within: @week, excluding: distant)

      assert total(report.expected) == 40.0
    end
  end

  describe ":expected states the obligation outright" do
    test "an explicit expectation replaces the open hours" do
      dana = dana()
      half_day = IntervalSet.new!([~o"2026-06-15T09:00:00/2026-06-15T13:00:00"])

      ledger =
        claim(
          Agenda.ledger(),
          dana,
          "Acme",
          "2026-06-15T09:00:00/2026-06-15T13:00:00",
          {:project, "ACME"}
        )

      assert {:ok, report} = Agenda.reconcile(ledger, dana, within: @week, expected: half_day)

      assert total(report.expected) == 4.0
      assert Reconciliation.balanced?(report)
    end
  end

  defp ledger_for(dana) do
    Enum.reduce(15..19, Agenda.ledger(), fn day, ledger ->
      claim(
        ledger,
        dana,
        "Acme day #{day}",
        "2026-06-#{day}T09:00:00/2026-06-#{day}T17:00:00",
        {:project, "ACME"}
      )
    end)
  end
end
