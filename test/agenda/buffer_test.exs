defmodule Agenda.BufferTest do
  use ExUnit.Case, async: true

  import Tempo.Sigils

  alias Agenda.Availability
  alias Agenda.Session
  alias Tempo.IntervalSet

  @day "2027-03-02T09:00:00/2027-03-02T17:00:00"
  @window "2027-03-02/2027-03-03"

  defp room(options) do
    {:ok, room} = Agenda.open(Agenda.resource("Room", options), @day)
    room
  end

  defp free(room, busy) do
    {:ok, free} = Availability.free(room, within: @window, busy: busy)

    free |> IntervalSet.to_list() |> Enum.map(&Tempo.to_iso8601/1)
  end

  describe "turnaround blocks more than the claim itself" do
    test "with no buffers only the claim is unavailable" do
      assert free(room([]), "2027-03-02T12:00:00/2027-03-02T12:30:00") == [
               "2027Y3M2DT9H0M0S/T12H0M0S",
               "2027Y3M2DT12H30M0S/T17H0M0S"
             ]
    end

    test "buffer_after extends the claim forwards" do
      # AshScheduling's own worked case: a 30-minute claim with a
      # 15-minute after-buffer blocks 45 minutes.
      assert free(
               room(buffer_after: ~o"PT15M"),
               "2027-03-02T12:00:00/2027-03-02T12:30:00"
             ) == [
               "2027Y3M2DT9H0M0S/T12H0M0S",
               "2027Y3M2DT12H45M0S/T17H0M0S"
             ]
    end

    test "buffer_before extends the claim backwards" do
      assert free(
               room(buffer_before: ~o"PT10M"),
               "2027-03-02T12:00:00/2027-03-02T12:30:00"
             ) == [
               "2027Y3M2DT9H0M0S/T11H50M0S",
               "2027Y3M2DT12H30M0S/T17H0M0S"
             ]
    end

    test "both buffers apply together" do
      assert free(
               room(buffer_before: ~o"PT10M", buffer_after: ~o"PT15M"),
               "2027-03-02T12:00:00/2027-03-02T12:30:00"
             ) == [
               "2027Y3M2DT9H0M0S/T11H50M0S",
               "2027Y3M2DT12H45M0S/T17H0M0S"
             ]
    end

    test "the gap between two claims shrinks by both buffers" do
      # Claims at 12:00-12:30 and 14:00-14:30 leave 90 minutes between
      # them; a 15-minute turnaround each side leaves 60.
      busy = [
        "2027-03-02T12:00:00/2027-03-02T12:30:00",
        "2027-03-02T14:00:00/2027-03-02T14:30:00"
      ]

      assert free(room(buffer_before: ~o"PT15M", buffer_after: ~o"PT15M"), busy) == [
               "2027Y3M2DT9H0M0S/T11H45M0S",
               "2027Y3M2DT12H45M0S/T13H45M0S",
               "2027Y3M2DT14H45M0S/T17H0M0S"
             ]
    end

    test "buffers can close a gap entirely" do
      busy = [
        "2027-03-02T12:00:00/2027-03-02T12:30:00",
        "2027-03-02T13:00:00/2027-03-02T13:30:00"
      ]

      assert free(room(buffer_after: ~o"PT30M"), busy) == [
               "2027Y3M2DT9H0M0S/T12H0M0S",
               "2027Y3M2DT14H0M0S/T17H0M0S"
             ]
    end

    test "a resource with no claims is unaffected by its buffers" do
      assert free(room(buffer_before: ~o"PT1H", buffer_after: ~o"PT1H"), []) == [
               "2027Y3M2DT9H0M0S/T17H0M0S"
             ]
    end
  end

  describe "buffers and concurrency together" do
    test "turnaround applies to each claim before saturation is measured" do
      # Two claims on a concurrency-2 desk: neither saturates it, so the
      # buffers cost nothing.
      desk =
        room(concurrency: 2, buffer_after: ~o"PT30M")

      busy = [
        "2027-03-02T12:00:00/2027-03-02T12:30:00",
        "2027-03-02T12:00:00/2027-03-02T12:30:00"
      ]

      assert free(desk, busy) == [
               "2027Y3M2DT9H0M0S/T12H0M0S",
               "2027Y3M2DT13H0M0S/T17H0M0S"
             ]
    end
  end

  describe "plan/3 respects turnaround" do
    test "a slot butting up against a claim's buffer is not offered" do
      cleaned = room(buffer_after: ~o"PT30M")

      session =
        Agenda.session("Meeting", duration: ~o"PT1H", window: ~o"2027-03-02/2027-03-03")
        |> Session.needs(:room, [])

      {:ok, options} =
        Agenda.plan(session, [cleaned],
          busy: %{"Room" => ["2027-03-02T10:00:00/2027-03-02T11:00:00"]}
        )

      starts = Enum.map(options, & &1.interval.from)

      # 11:00 would be free without the buffer; the first slot after the
      # claim is 11:30.
      refute ~o"2027Y3M2DT11H0M0S" in starts
      assert ~o"2027Y3M2DT11H30M0S" in starts
    end
  end
end
