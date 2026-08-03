# Case study: consultants on customer sites

An IT services business sells its people's time. The scheduling problem is not "find a free hour" but *"who is qualified, are they free, and can they physically get from the last job to this one?"* This guide works that problem end to end.

## The shape of it

The insight that makes everything else fall out: **a customer site is a resource, not an attribute.** It is tempting to give each engagement a `location: :acme` label, but a site is something that gets used up — two consultants cannot both run a workshop in Acme's only meeting room — and the journey between two jobs is a journey between two *places*. Both fall out for free once the site is a resource sitting in the place tree.

```elixir
sydney   = Timetable.place("Sydney")
cbd      = Timetable.place("CBD", within: sydney)
north    = Timetable.place("North Sydney", within: sydney)
regional = Timetable.place("Newcastle")

{:ok, acme} =
  Timetable.resource("Acme HQ", within: cbd, concurrency: 2)
  |> Timetable.open("2027-03-01T09:00:00/2027-03-01T17:00:00")

{:ok, beta} =
  Timetable.resource("Beta Corp", within: north)
  |> Timetable.open("2027-03-01T09:00:00/2027-03-01T17:00:00")
```

> *"Acme's CBD office can host two engagements at once and is open nine to five; Beta Corp in North Sydney can host one."*

Note `concurrency: 2` on Acme. That is *how many engagements can run there at once* — it is not a count of seats or of anything else about the building. Keeping those two ideas apart is what stops a twenty-seat training room accepting twenty simultaneous bookings.

## Consultants are resources with skills

People and rooms are the same kind of thing here; only the attributes differ.

```elixir
{:ok, dana} =
  Timetable.resource("Dana", skills: [:elixir, :postgres, :security])
  |> Timetable.open("2027-03-01T09:00:00/2027-03-01T17:00:00")

{:ok, raj} =
  Timetable.resource("Raj", skills: [:elixir, :phoenix])
  |> Timetable.open("2027-03-01T09:00:00/2027-03-01T17:00:00")
```

A skills list wants the `all_of/1` predicate — the consultant must hold *every* skill the job needs, not merely one of them:

```elixir
import Timetable.Predicate

certified = Timetable.needs(:consultant, skills: all_of([:elixir, :security]))

Timetable.eligible(certified, [dana, raj, mia])
|> Enum.map(& &1.name)
#=> ["Dana"]
```

> *"Only Dana holds both Elixir and security clearance."*

When a consultant is ruled out, the reason is a sentence rather than a `false`:

```elixir
Timetable.explain(certified, raj)
#=> "Raj: skills is [:elixir, :phoenix] — needs all of :elixir, :security"
```

That sentence is what an account manager can forward to a customer. It is computed as part of the eligibility decision, not reconstructed afterwards, so it cannot drift out of step with the answer.

## Booking the engagement

The engagement needs a qualified consultant, and it happens at a named site:

```elixir
audit =
  Timetable.session("Security audit", lasting: ~o"PT3H", between: ~o"2027-03-01/2027-03-02")
  |> Timetable.Session.needs(:consultant, skills: all_of([:elixir, :security]))
  |> Timetable.Session.roster(:site, [acme])

{:ok, options} = Timetable.plan(audit, [dana, raj, mia])
length(options)
#=> 2

Timetable.explain(hd(options))
#=> "2027Y3M1DT9H0M0S/2027Y3M1DT12H0M0S — consultant: Dana, site: Acme HQ"
```

> *"The three-hour audit can run two ways; the first is Dana at Acme, starting at nine."*

Two roles, expressed two ways. `needs/3` describes a resource and lets the planner choose; `roster/3` names one. The site is named because the customer is not negotiable; the consultant is described because any qualified person will do.

Every arrangement also records which resources' free time produced it:

```elixir
Tempo.Interval.metadata(hd(options).interval)
#=> %{free: ["Acme HQ", "Dana"]}
```

## Committing, and what that frees up

```elixir
{:ok, ledger} = Timetable.allocate(Timetable.ledger(), hd(options))

Timetable.count(ledger)
#=> 2

Timetable.busy(ledger) |> Map.keys()
#=> ["Acme HQ", "Dana"]
```

Two allocations from one booking — the consultant *and* the site. Both are now unavailable to the next plan, which is the point: a site that can host one engagement should not accept a second.

Cancelling is dropping the key:

```elixir
{:ok, ledger} = Timetable.release(ledger, "Security audit")
Timetable.busy(ledger)
#=> %{}
```

Dana and Acme are free again because nothing else was holding them. There is no release step to forget, because there is no stored free/busy record to correct — free time is derived on demand.

## Travel between jobs

Journeys come from the place tree, not from a matrix somebody maintains by hand:

```elixir
Timetable.travel_time(acme, beta)
#=> {:ok, ~o"PT5M"}
```

Acme is in the CBD, Beta in North Sydney; both sit under Sydney, so they are one level apart and the default table says five minutes. That default is a guess about *structure*, not a survey of your city, and the library says so where it does not know:

```elixir
Timetable.travel_time(acme, coalworks)
#=> {:error, :unknown}
```

Newcastle is not under Sydney at all. Rather than invent a number, an unrelated place returns `:unknown` — and an unknown journey is never treated as a short one. Measure it once and state it:

```elixir
Timetable.travel_time(acme, coalworks, between: [{{"Acme HQ", "Coalworks"}, ~o"PT2H"}])
#=> {:ok, ~o"PT2H"}
```

Per-pair overrides are first-class for exactly this reason. Real geography disagrees with tree structure constantly — two adjacent floors joined only by a slow lift, two "nearby" sites separated by a harbour.

## A consultant's day is a track

The constraint that matters most in field work is that a person's own itinerary has to be physically possible. That is a family of sessions constrained against *each other*, which is exactly what a track is:

```elixir
danas_day =
  Timetable.track("Dana", of: [morning_standup, afternoon_review])
  |> Timetable.Track.reachable(within: ~o"PT45M")

week =
  Timetable.programme("Week 9", across: ~o"2027-03-01/2027-03-02")
  |> Timetable.Programme.add_track(danas_day)

{:ok, itinerary} = Timetable.arrange(week, [dana, acme, beta])

Enum.map(itinerary, &Timetable.explain/1)
#=> ["2027Y3M1DT9H0M0S/2027Y3M1DT10H0M0S — consultant: Dana, site: Acme HQ",
#=>  "2027Y3M1DT11H0M0S/2027Y3M1DT12H0M0S — consultant: Dana, site: Beta Corp"]
```

> *"Dana is at Acme at nine and Beta at eleven — two hours apart for a five-minute trip, so the day works."*

Only *located* resources count towards a journey. Dana has no place of her own: she travels with the job. Sites do have places, so the leg measured is Acme → Beta. Counting the person as a leg would make every journey unmeasurable and every itinerary infeasible.

### The boundary worth knowing

A track is a **known** set of sessions. That works when the consultant is named — a retained client, a continuity-of-service commitment, a specialist only one person can cover. It does not directly express *"whoever ends up with these three jobs must be able to drive between them"*, because the itinerary does not exist until the assignment is made, and the assignment is what you are trying to compute.

The practical approach is two-pass: let `plan/3` propose who, commit that to the ledger, then validate each person's resulting day as a track. If a day fails, re-plan the offending job with that consultant excluded from the pool. That is honest about what the library does rather than pretending the general case is solved — the general case is vehicle routing, and it belongs with a solver built for it.

## What to take away

* **Model anything scarce as a resource.** Sites, people, and equipment are the same kind of thing; only their attributes differ. If two bookings can exhaust it, it is a resource.

* **`needs` describes, `roster` names.** Use `needs/3` when any qualified resource will do and `roster/3` when the choice is already made.

* **Measure the journeys you care about.** The place tree gives a sensible default shape; `:between` overrides are where the real world goes.

* **Read the failures.** `explain/2` on a requirement, and `explain/1` on an infeasible result, are the difference between "no availability" and a sentence somebody can act on.
