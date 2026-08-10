defmodule Agenda.VAvailabilityTest do
  use ExUnit.Case, async: true

  alias Agenda.Availability
  alias Agenda.Session
  alias Tempo.IntervalSet

  @june "2026-06-01/2026-06-08"

  defp calendar(components) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    #{components}
    END:VCALENDAR
    """
  end

  defp weekdays(uid \\ "office") do
    """
    BEGIN:VAVAILABILITY
    UID:#{uid}
    DTSTAMP:20260601T000000Z
    BEGIN:AVAILABLE
    UID:#{uid}-available
    DTSTAMP:20260601T000000Z
    DTSTART:20260601T090000Z
    DTEND:20260601T170000Z
    RRULE:FREQ=DAILY;COUNT=5
    END:AVAILABLE
    END:VAVAILABILITY
    """
  end

  defp room_open_from(components, name \\ "Room") do
    {:ok, hours} = Agenda.from_ical(calendar(components))
    {:ok, room} = Agenda.open(Agenda.resource(name, seats: 8), hours)
    room
  end

  defp days(free) do
    free
    |> IntervalSet.to_list()
    |> Enum.map(& &1.from.time[:day])
    |> Enum.sort()
  end

  describe "importing open hours" do
    test "a VAVAILABILITY becomes a resource's open hours" do
      room = room_open_from(weekdays())

      assert {:ok, free} = Agenda.free(room, within: @june)
      assert days(free) == [1, 2, 3, 4, 5]
    end

    test "the pattern is held unmaterialised until a window is known" do
      # Like an ISO recurrence, it has no extent of its own — the same
      # resource answers different windows differently.
      room = room_open_from(weekdays())

      {:ok, whole_week} = Agenda.free(room, within: @june)
      {:ok, two_days} = Agenda.free(room, within: "2026-06-01/2026-06-03")

      assert length(days(whole_week)) == 5
      assert days(two_days) == [1, 2]
    end

    test "existing claims are still subtracted" do
      room = room_open_from(weekdays())

      assert {:ok, free} =
               Agenda.free(room,
                 within: @june,
                 busy: "2026-06-02T09:00:00/2026-06-02T17:00:00"
               )

      assert days(free) == [1, 3, 4, 5]
    end

    test "PRIORITY is honoured through the Agenda layer" do
      # The high-priority component offers mornings only, and its
      # silence about the afternoon overrides the low-priority
      # component that offers the whole day.
      room =
        room_open_from("""
        BEGIN:VAVAILABILITY
        UID:high
        DTSTAMP:20260601T000000Z
        DTSTART:20260601T000000Z
        DTEND:20260608T000000Z
        PRIORITY:1
        BEGIN:AVAILABLE
        UID:high-available
        DTSTAMP:20260601T000000Z
        DTSTART:20260601T090000Z
        DTEND:20260601T120000Z
        END:AVAILABLE
        END:VAVAILABILITY
        BEGIN:VAVAILABILITY
        UID:low
        DTSTAMP:20260601T000000Z
        DTSTART:20260601T000000Z
        DTEND:20260608T000000Z
        PRIORITY:9
        BEGIN:AVAILABLE
        UID:low-available
        DTSTAMP:20260601T000000Z
        DTSTART:20260601T090000Z
        DTEND:20260601T170000Z
        END:AVAILABLE
        END:VAVAILABILITY
        """)

      assert {:ok, free} = Agenda.free(room, within: @june)
      assert [window] = IntervalSet.to_list(free)
      assert {window.from.time[:hour], window.to.time[:hour]} == {9, 12}
    end

    test "VEVENTs in the same document are not treated as open hours" do
      # An event is time that is taken, not offered. Importing a
      # calendar carrying both must not turn a meeting into
      # availability.
      room =
        room_open_from("""
        #{weekdays()}
        BEGIN:VEVENT
        UID:standup
        DTSTAMP:20260601T000000Z
        DTSTART:20260607T100000Z
        DTEND:20260607T103000Z
        SUMMARY:Sunday standup
        END:VEVENT
        """)

      assert {:ok, free} = Agenda.free(room, within: @june)

      # Sunday the 7th is not offered by any AVAILABLE, so it must not
      # appear merely because a VEVENT sits there.
      refute 7 in days(free)
    end
  end

  describe "imported hours compose with the rest of the library" do
    test "planning against imported availability works" do
      room = room_open_from(weekdays(), "Clinic")

      session =
        Agenda.session("Review", lasting: "PT1H", between: @june)
        |> Session.needs(:room, seats: 8)

      assert {:ok, [best | _rest]} = Agenda.plan(session, [room])
      assert best.session == "Review"
      assert best.interval.from.time[:hour] == 9
    end

    test "refinements apply to imported availability" do
      room = room_open_from(weekdays())

      assert {:ok, mornings} =
               room
               |> Agenda.free(within: @june)
               |> Agenda.only_during("2026-06-01T09:00:00/2026-06-01T12:00:00")

      assert IntervalSet.count(mornings) == 1
    end
  end

  describe "bad input" do
    test "a calendar with no VAVAILABILITY leaves the resource never open" do
      room = room_open_from("")

      assert {:ok, free} = Agenda.free(room, within: @june)
      assert IntervalSet.empty?(free)
    end

    test "unreadable data is an error, not a crash" do
      assert {:ok, hours} = Agenda.from_ical("this is not a calendar")
      {:ok, room} = Agenda.open(Agenda.resource("Room"), hours)

      assert {:ok, free} = Agenda.free(room, within: @june)
      assert IntervalSet.empty?(free)
    end

    test "normalise/1 accepts an imported pattern unchanged" do
      {:ok, hours} = Agenda.from_ical(calendar(weekdays()))

      assert {:ok, ^hours} = Availability.normalise(hours)
    end
  end
end
