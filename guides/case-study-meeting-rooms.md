# Case study: meeting rooms and AV equipment

Every business above a certain size has the same problem, and almost every one of them solves it badly: a pool of rooms, a pool of equipment, teams who want both, and an accessibility requirement that somebody forgets. This guide shows the shape that stops those failures being possible.

## Rooms are described by what they have

```elixir
day = "2027-03-01T09:00:00/2027-03-01T17:00:00"

{:ok, boardroom} =
  Timetable.resource("Boardroom",
    within: level_4, seats: 14, video_conferencing: true, step_free_access: true)
  |> Timetable.open(day)

{:ok, huddle} =
  Timetable.resource("Huddle 4A", within: level_4, seats: 4)
  |> Timetable.open(day)

{:ok, training} =
  Timetable.resource("Training Room", within: level_1, seats: 20, step_free_access: true)
  |> Timetable.open(day)
```

Attributes are whatever your building actually has — there is no fixed vocabulary. `seats`, `video_conferencing`, and `step_free_access` are just names; a room with a `hearing_loop` or a `standing_desk` needs no library change.

**`seats` is not concurrency.** A twenty-seat training room still holds one meeting at a time, so it is `seats: 20` with the default `concurrency: 1`. The two are orthogonal, and conflating them is the bug that lets a lecture theatre accept two simultaneous lectures. Concurrency above one is for genuinely poolable things — a bank of identical lockers, a set of hot desks booked as a block.

## A booking says what it needs

```elixir
import Timetable.Predicate

review =
  Timetable.session("Quarterly review", lasting: ~o"PT1H", between: ~o"2027-03-01/2027-03-02")
  |> Timetable.Session.needs(:room, seats: at_least(10), video_conferencing: true)
  |> Timetable.Session.roster(:attendees, [priya, tom])

{:ok, options} = Timetable.plan(review, [boardroom, huddle, training])

length(options)
#=> 8

Timetable.explain(hd(options))
#=> "2027Y3M1DT9H0M0S/2027Y3M1DT10H0M0S — attendees: Priya, Tom, room: Boardroom"
```

> *"The review needs a room seating at least ten with video conferencing, plus Priya and Tom; there are eight ways to hold it, the earliest at nine in the boardroom."*

Eight, not twenty-four: the huddle room is too small and the training room has no video conferencing, so only the boardroom's eight free hours qualify. Nothing had to be filtered by hand.

## The failure is a sentence

This is the part that saves the most time in practice. When somebody asks why they cannot book a room, the answer is specific:

```elixir
Timetable.explain(Timetable.needs(:room, seats: at_least(10), video_conferencing: true), huddle)
#=> "Huddle 4A: seats is 4 — needs at least 10; no video_conferencing — needs true"
```

Both reasons, not the first one. An absent attribute reads differently from a wrong one — `no video_conferencing` rather than `video_conferencing is false` — because "this room has no VC kit" and "this room has VC kit that is switched off" are different conversations.

## Accessibility that cannot be forgotten

Here is the failure mode worth designing out. Priya uses a wheelchair. In most systems that fact lives in somebody's memory, and the booking that forgets it is discovered on the day.

`step_free_access: true` on Priya is **not** a fact about Priya's availability. It is a constraint she places on whatever room she is booked into:

```elixir
priya = Timetable.resource("Priya", requires: [step_free_access: true])
```

Adding her to a session tightens the room requirement automatically:

```elixir
Timetable.needs(:room, seats: at_least(10), video_conferencing: true)
|> Timetable.Requirement.induce([priya])
|> Timetable.explain(attic)
#=> "Attic: no step_free_access — needs true"
```

> *"The attic seats twelve and has video conferencing, but it is out — Priya cannot get into it."*

The attic satisfies every stated requirement. It is excluded because of who is attending, and nobody had to remember to check. That is the difference between a requirement being modelled and a requirement being a habit.

## Two roles at once: a room *and* the kit

Portable equipment is a resource like any other. It has no seats; it has a projector:

```elixir
{:ok, cart} =
  Timetable.resource("Projector cart", within: level_1, projector: true)
  |> Timetable.open(day)

workshop =
  Timetable.session("Onboarding workshop", lasting: ~o"PT2H", between: ~o"2027-03-01/2027-03-02")
  |> Timetable.Session.needs(:room, seats: at_least(15))
  |> Timetable.Session.needs(:equipment, projector: true)

{:ok, options} = Timetable.plan(workshop, [boardroom, huddle, training, cart])

length(options)
#=> 4

Timetable.explain(hd(options))
#=> "2027Y3M1DT9H0M0S/2027Y3M1DT11H0M0S — equipment: Projector cart, room: Training Room"
```

> *"The workshop needs a room for fifteen and a projector; four two-hour windows work, the first at nine in the training room with the cart."*

Two independent roles, each satisfied by a different resource, both booked together and both freed together. Four options rather than eight because the session runs two hours instead of one — the cart happens to be free whenever the room is.

## The ledger makes the second booking see the first

```elixir
{:ok, ledger} = Timetable.allocate(Timetable.ledger(), hd(options))

{:ok, remaining} = Timetable.plan(review, rooms, busy: Timetable.busy(ledger))
length(remaining)
#=> 7

Timetable.explain(hd(remaining))
#=> "2027Y3M1DT10H0M0S/2027Y3M1DT11H0M0S — attendees: Priya, Tom, room: Boardroom"
```

> *"Once the nine o'clock slot is taken, seven remain and the earliest is ten."*

And releasing puts it straight back:

```elixir
{:ok, ledger} = Timetable.release(ledger, "Quarterly review")
{:ok, restored} = Timetable.plan(review, rooms, busy: Timetable.busy(ledger))
length(restored)
#=> 8
```

Eight again. Nothing had to be un-marked, because nothing was marked — busy time is derived from the ledger every time it is asked for.

## Moving a meeting without losing the room

The operation every hand-rolled system gets wrong. The naive implementation releases everything and re-acquires it, which hands the room to a competing booking in the gap and churns records that never moved. Ask instead what actually changed:

```elixir
changes = Timetable.rearrange(ledger, "Quarterly review", new_arrangement)

Enum.map(changes, &elem(&1, 0))
#=> [:keep, :keep, :release, :allocate]
```

> *"Moving the review keeps Priya and Tom, gives back the boardroom, and takes the annexe instead."*

Re-planning to exactly where it already is yields nothing but `:keep`. The changeset is an ordinary value — the library never applies it, so your persistence layer can apply it inside its own transaction, touching only what genuinely moved.

## What to take away

* **Attributes are yours.** There is no fixed vocabulary; name what your building has.

* **Keep `seats` and `concurrency` apart.** One is a fact about the room, the other is how many bookings it can hold at once.

* **Put a person's access needs on the person.** `requires:` turns "somebody must remember" into "the room is not eligible".

* **Ask for several roles in one session.** A room and a projector are two `needs`, booked and released as one unit.

* **Derive busy time, never store it.** That is what makes `release/2` a one-liner and stale free/busy records impossible.
