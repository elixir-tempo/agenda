# Case study: consultants on customer sites

An IT services business sells its people's time. The scheduling problem is not "find a free hour" but *"who is qualified, are they free, and can they physically get from the last job to this one?"* This guide works that problem end to end.

## The shape of it

The insight that makes everything else fall out: **a customer site is a resource, not an attribute.** It is tempting to give each engagement a `location: :acme` label, but a site is something that gets used up — two consultants cannot both run a workshop in Acme's only meeting room — and the journey between two jobs is a journey between two *places*. Both fall out for free once the site is a resource sitting in the place tree.

```elixir
sydney   = Agenda.place("Sydney")
cbd      = Agenda.place("CBD", within: sydney)
north    = Agenda.place("North Sydney", within: sydney)
regional = Agenda.place("Newcastle")

{:ok, acme} =
  Agenda.resource("Acme HQ", within: cbd, concurrency: 2)
  |> Agenda.open("2027-03-01T09:00:00/2027-03-01T17:00:00")

{:ok, beta} =
  Agenda.resource("Beta Corp", within: north)
  |> Agenda.open("2027-03-01T09:00:00/2027-03-01T17:00:00")
```

> *"Acme's CBD office can host two engagements at once and is open nine to five; Beta Corp in North Sydney can host one."*

Note `concurrency: 2` on Acme. That is *how many engagements can run there at once* — it is not a count of seats or of anything else about the building. Keeping those two ideas apart is what stops a twenty-seat training room accepting twenty simultaneous bookings.

## Consultants are resources with skills

People and rooms are the same kind of thing here; only the attributes differ.

```elixir
{:ok, dana} =
  Agenda.resource("Dana", skills: [:elixir, :postgres, :security])
  |> Agenda.open("2027-03-01T09:00:00/2027-03-01T17:00:00")

{:ok, raj} =
  Agenda.resource("Raj", skills: [:elixir, :phoenix])
  |> Agenda.open("2027-03-01T09:00:00/2027-03-01T17:00:00")
```

A skills list wants the `all_of/1` predicate — the consultant must hold *every* skill the job needs, not merely one of them:

```elixir
import Agenda.Predicate

certified = Agenda.needs(:consultant, skills: all_of([:elixir, :security]))

Agenda.eligible(certified, [dana, raj, mia])
|> Enum.map(& &1.name)
#=> ["Dana"]
```

> *"Only Dana holds both Elixir and security clearance."*

When a consultant is ruled out, the reason is a sentence rather than a `false`:

```elixir
Agenda.explain(certified, raj)
#=> "Raj: skills is [:elixir, :phoenix] — needs all of :elixir, :security"
```

That sentence is what an account manager can forward to a customer. It is computed as part of the eligibility decision, not reconstructed afterwards, so it cannot drift out of step with the answer.

## Booking the engagement

The engagement needs a qualified consultant, and it happens at a named site:

```elixir
audit =
  Agenda.session("Security audit", duration: ~o"PT3H", window: ~o"2027-03-01/2027-03-02")
  |> Agenda.Session.needs(:consultant, skills: all_of([:elixir, :security]))
  |> Agenda.Session.roster(:site, [acme])

{:ok, options} = Agenda.plan(audit, [dana, raj, mia])
length(options)
#=> 2

Agenda.explain(hd(options))
#=> "2027Y3M1DT9H0M0S/T12H0M0S — consultant: Dana, site: Acme HQ"
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
{:ok, ledger} = Agenda.allocate(Agenda.ledger(), hd(options))

Agenda.count(ledger)
#=> 2

Agenda.busy(ledger) |> Map.keys()
#=> ["Acme HQ", "Dana"]
```

Two allocations from one booking — the consultant *and* the site. Both are now unavailable to the next plan, which is the point: a site that can host one engagement should not accept a second.

Cancelling is dropping the key:

```elixir
{:ok, ledger} = Agenda.release(ledger, "Security audit")
Agenda.busy(ledger)
#=> %{}
```

Dana and Acme are free again because nothing else was holding them. There is no release step to forget, because there is no stored free/busy record to correct — free time is derived on demand.

## Travel between jobs

Journeys come from the place tree, not from a matrix somebody maintains by hand:

```elixir
Agenda.travel_time(acme, beta)
#=> {:ok, ~o"PT5M"}
```

Acme is in the CBD, Beta in North Sydney; both sit under Sydney, so they are one level apart and the default table says five minutes. That default is a guess about *structure*, not a survey of your city, and the library says so where it does not know:

```elixir
Agenda.travel_time(acme, coalworks)
#=> {:error, :unknown}
```

Newcastle is not under Sydney at all. Rather than invent a number, an unrelated place returns `:unknown` — and an unknown journey is never treated as a short one. Measure it once and state it:

```elixir
Agenda.travel_time(acme, coalworks, between: [{{"Acme HQ", "Coalworks"}, ~o"PT2H"}])
#=> {:ok, ~o"PT2H"}
```

Per-pair overrides are first-class for exactly this reason. Real geography disagrees with tree structure constantly — two adjacent floors joined only by a slow lift, two "nearby" sites separated by a harbour.

## A consultant's day is a track

The constraint that matters most in field work is that a person's own itinerary has to be physically possible. That is a family of sessions constrained against *each other*, which is exactly what a track is:

```elixir
danas_day =
  Agenda.track("Dana", of: [morning_standup, afternoon_review])
  |> Agenda.Track.reachable(within: ~o"PT45M")

week =
  Agenda.programme("Week 9", across: ~o"2027-03-01/2027-03-02")
  |> Agenda.Programme.add_track(danas_day)

{:ok, itinerary} = Agenda.arrange(week, [dana, acme, beta])

Enum.map(itinerary, &Agenda.explain/1)
#=> ["2027Y3M1DT9H0M0S/T10H0M0S — consultant: Dana, site: Acme HQ",
#=>  "2027Y3M1DT11H0M0S/T12H0M0S — consultant: Dana, site: Beta Corp"]
```

> *"Dana is at Acme at nine and Beta at eleven — two hours apart for a five-minute trip, so the day works."*

Only *located* resources count towards a journey. Dana has no place of her own: she travels with the job. Sites do have places, so the leg measured is Acme → Beta. Counting the person as a leg would make every journey unmeasurable and every itinerary infeasible.

### The boundary worth knowing

A track is a **known** set of sessions. That works when the consultant is named — a retained client, a continuity-of-service commitment, a specialist only one person can cover. It does not directly express *"whoever ends up with these three jobs must be able to drive between them"*, because the itinerary does not exist until the assignment is made, and the assignment is what you are trying to compute.

The practical approach is two-pass: let `plan/3` propose who, commit that to the ledger, then validate each person's resulting day as a track. If a day fails, re-plan the offending job with that consultant excluded from the pool. That is honest about what the library does rather than pretending the general case is solved — the general case is vehicle routing, and it belongs with a solver built for it.

## Some jobs have to happen in order

An installation cannot precede the survey that specifies it. That is not a resource clash and not a track — it is *order*, and it is what turns a list of jobs into a job.

```elixir
job = fn name ->
  Agenda.session(name, duration: ~o"PT1H", window: ~o"2027-03-01/2027-03-02")
  |> Agenda.Session.needs(:consultant, skills: all_of([:elixir]))
end

engagement =
  Agenda.programme("Acme rollout", across: ~o"2027-03-01/2027-03-02")
  |> Agenda.Programme.add_session(job.("Site survey"))
  |> Agenda.Programme.add_session(job.("Installation"))

{:ok, engagement} = Agenda.precede(engagement, "Site survey", "Installation", gap: ~o"PT1H")

{:ok, ordered} = Agenda.arrange(engagement, [dana, acme])
Enum.map(ordered, &Agenda.explain/1)
#=> ["2027Y3M1DT9H0M0S/T10H0M0S — consultant: Dana",
#=>  "2027Y3M1DT11H0M0S/T12H0M0S — consultant: Dana"]
```

> *"The installation follows the survey, with at least an hour in between to write it up."*

`:within` caps the other end, which is what makes a follow-up a follow-up rather than something that happens eventually:

```elixir
Agenda.precede(programme, "Screening", "Panel", gap: ~o"PT15M", within: ~o"PT2H")
```

Both are measured from the **end** of the predecessor, so a survey that runs long pushes the installation rather than eating its allowance. A chain of three is two precedences, and the search enforces each independently — it never reasons about the chain as a whole.

Because precedence relates exactly two sessions, it is the same kind of constraint as "these two cannot share a room": `Agenda.Arranger.conflict?/4` covers it, so the fixpoint bridge enforces it too without knowing what a survey is.

## Nobody does five jobs a day

A consultant with eight open hours and one-hour jobs is not available for eight jobs. Contracts, fatigue and paperwork all say otherwise, and none of them are expressible as availability:

```elixir
{:ok, dana} =
  Agenda.resource("Dana", skills: [:elixir, :postgres], limits: [day: 3, week: 12])
  |> Agenda.open("2027-03-01T09:00:00/2027-03-01T17:00:00")
```

> *"Dana takes at most three jobs a day and twelve a week."*

**This is not concurrency.** Concurrency asks how many claims may overlap at one instant — Dana can only be in one place at a time, so hers is 1. A limit asks how many may fall inside a stretch of calendar, however far apart they sit. Both are needed and they say different things.

Weeks bucket by the calendar's Monday, not seven days from the first job, so "twelve a week" means what a contract means by it.

Limits count **what is already booked**, not only what this search places:

```elixir
Agenda.arrange(week, [dana, acme, beta], busy: Agenda.busy(ledger))
```

That matters more than it looks. Availability can be derived from the ledger — `free/2` does it on every call — but no availability calculation can express "at most twelve this week". A consultant who has already done nine is only nine if the limit consults the ledger itself.

## What a consultant would rather

Skills say what someone *can* do. Wishes say what they would *rather*:

```elixir
{:ok, priya} =
  Agenda.resource("Priya", skills: [:elixir], avoids: ~o"2027-03-01T13:00:00/2027-03-01T17:00:00")
  |> Agenda.open("2027-03-01T09:00:00/2027-03-01T17:00:00")

{:ok, week} = Agenda.prefer(week, :resource_wishes, weight: 5)
```

> *"Priya would rather not work that afternoon, and we would rather she did not have to."*

The distinction that earns this its own field: `avoids` makes a placement **worse**, `open/2` makes it **impossible**. Spelling "Priya would rather not work Friday afternoons" as "Friday afternoon does not exist for Priya" is the mistake — it takes an entire afternoon off the table for everyone, and it fails the whole week rather than booking her reluctantly when there is no alternative. A wish bends; availability does not.

`prefers` is the mirror, for someone who would rather be used at particular times, and a wish may be a recurrence rather than a fixed span. Wishes are ignored entirely unless the programme asks for them with `prefer/3`, so a resource can carry them without every caller paying attention to them.

## What to take away

* **Model anything scarce as a resource.** Sites, people, and equipment are the same kind of thing; only their attributes differ. If two bookings can exhaust it, it is a resource.

* **Four constraints, four different questions.** A *requirement* asks whether a resource qualifies; *concurrency* how many claims may overlap at an instant; a *limit* how many fall inside a stretch of calendar; a *precedence* which of two comes first. Reaching for the wrong one is the commonest modelling mistake here.

* **A wish is not an absence.** `avoids` makes a placement worse; `open/2` makes it impossible. Writing a preference as unavailability takes the option away from everyone and turns a reluctant booking into a failed week.

* **`needs` describes, `roster` names.** Use `needs/3` when any qualified resource will do and `roster/3` when the choice is already made.

* **Measure the journeys you care about.** The place tree gives a sensible default shape; `:between` overrides are where the real world goes.

* **Read the failures.** `explain/2` on a requirement, and `explain/1` on an infeasible result, are the difference between "no availability" and a sentence somebody can act on.
