# Timesheets, leave, and working-time reconciliation — a discussion document

**Audience:** Kip Cole and Josh Price. This is a proposal to talk about, not a design to sign off. Everything that is Alembic's call is marked as a question rather than answered.

**Basis:** Josh's three notes of 2026-08-25 on timesheets, multi-jurisdiction leave, and OR-based allocation. `agenda` at `c3c6157`, `ex_tempo` 1.3.1, `calendrical` as vendored in `agenda`'s lockfile. Code blocks written with `iex>` prompts were executed against those versions and show real output; blocks without them are proposed API that does not exist yet.

## The three questions

Josh asked three things that look like one problem and are actually three, with a different answer each:

1. **Timesheets.** Consultants record time; it is billed to clients and allocated to projects.
2. **Leave.** The same structure, allocated to a leave type rather than a project — across jurisdictions whose public holidays vary down to the local government area.
3. **Reconciliation.** Both must add up to the expected total working hours per time unit — day, week, month, quarter, and year in both the calendar and the financial sense.

The third is the one that makes the first two hard, and it is the one most timesheet systems get structurally wrong.

## The one idea: work and leave are the same claim

Josh already has this — *"leave is the same structure but allocated to a leave type rather than a project"* — and it is worth stating as the load-bearing decision rather than an implementation convenience, because everything downstream either falls out of it or fights it.

A timesheet line and a leave line are both **a claim on a person's time, tagged with what it was for**. The tag is a sum type, not a foreign key to one table:

```elixir
{:project, "ACME-2026-01"}    # billable, has a client
{:internal, :business_development}
{:leave, :annual}
{:leave, :personal}
{:holiday, "Brisbane show day"}    # not taken, not owed
```

The consequence that matters: **a day cannot be two things.** A person on annual leave cannot also bill six hours to Acme, and that is not a validation rule somebody has to remember to write — it is the same overlap check `agenda` already runs when two sessions want the same consultant. One structure means one conflict predicate.

There is a second consequence that is easy to miss. A public holiday is a *third* tag, and it must not be modelled as a kind of leave. Leave is drawn from a balance; a holiday is not. Conflating them is what produces the perennial payroll bug in the next section.

### A schedule and a timesheet are the same ledger, read in opposite directions

`agenda`'s `Agenda.Ledger` already records "this resource is claimed over this interval, for this reason". A forward schedule is that ledger read as **intent** — who *should* be on the Acme engagement next Tuesday. A timesheet is the same ledger read as **record** — who *was*.

This is worth exploiting rather than rebuilding. The interesting queries a consulting business asks are all comparisons between the two readings: planned versus actual utilisation, the engagement that took 40% longer than sold, the consultant whose booked week and submitted week disagree. If the two live in separate schemas with separate vocabularies, every one of those questions becomes a join and a reconciliation of its own.

`Agenda.Allocation` is close to the right grain today — `session`, `role`, `resource`, `interval` — and short by exactly one field: the tag above. That is a small, real change to propose.

## Reconciliation is set algebra, not a sum

Here is the part to argue for hardest.

The natural implementation of "the timesheet must add up to the expected hours" is to sum the entries and compare to a number. That check passes on data that is wrong. A consultant who misses a Tuesday and works the following Saturday sums to exactly 38 hours; so does one who books eight hours to a project on a day the office was shut. A total that balances is not evidence that the week is correct — it is evidence that two errors were the same size.

The check that does work is **set difference against the person's working-time set**, because it answers *where*, not just *how much*:

```elixir
expected = workdays(person) − holidays(person's jurisdiction) − approved_leave(person)
unaccounted = expected − claimed
overclaimed = claimed − expected
```

`unaccounted` is a list of intervals — *"Tuesday 14 July, and Thursday afternoon"* — which is the sentence a consultant can act on. A shortfall of 11.4 hours is not.

This composes out of primitives that exist today. Executed, for the first quarter of Australian FY2026:

```elixir
iex> q = ~o"2026-07-01/2026-10-01"
iex> {:ok, workdays} = Tempo.select(q, Tempo.workdays(:AU))
iex> Tempo.IntervalSet.count(workdays)
66

iex> {:ok, holidays} = Tempo.IntervalSet.new([~o"2026-08-12/2026-08-13", ~o"2026-10-05/2026-10-06"])
iex> {:ok, net} = Tempo.members_outside(workdays, holidays)
iex> Tempo.IntervalSet.count(net)
65

iex> {:ok, leave} = Tempo.IntervalSet.new([~o"2026-09-14/2026-09-19"])
iex> {:ok, owed} = Tempo.members_outside(net, leave)
iex> Tempo.IntervalSet.count(owed)
60
```

> *"Sixty-six working days in the quarter; sixty-five after the one public holiday that falls inside it; sixty after a week of annual leave."*

Note what the second step did on its own: the 5 October holiday is outside the window and was not subtracted. Nobody wrote that condition.

`Tempo.members_outside/2` is doing the load-bearing work, and it is the right operation rather than `Tempo.difference/2` because it is **member-preserving** — each surviving day stays a distinct member with its own endpoints, so the result is a list of days you can name, not a fused interval you can only measure.

### The trap this design walks past

**A public holiday inside a leave period must not consume leave balance.** Someone taking the fortnight over Christmas does not spend ten days of annual leave, and every payroll system that has ever conflated holidays with leave has shipped this bug.

In the algebra above it cannot occur, because of the order of subtraction: holidays leave the working-day set *before* leave is applied, so a leave request only ever consumes days that were owed in the first place. The rule is not enforced; it is unrepresentable. That is the strongest argument for doing reconciliation as sets rather than as counters, and it is worth showing Josh's team explicitly, because the counter-based version of this code is where the bug lives.

## Jurisdiction is a tree, and micro-regional is just a deeper node

Josh's 🤯 is the right reaction to Queensland show days, and the reassuring part is that they are not a special case needing special code. They are evidence that the thing being modelled has more levels than most systems give it.

Under the *Holidays Act 1983* (Qld), a show holiday is appointed **per district**, so Brisbane's falls on the Ekka Wednesday and Toowoomba's, Cairns's and Townsville's fall on entirely different dates. A flat `state: :qld` attribute cannot express that, and neither can a flat `region:` — because the levels nest, and how deep you must go before you find an authoritative answer varies by holiday. Australia Day is national. Labour Day is per state, on different dates in different states. Show day is per district. Easter Sunday is a holiday in some states and not others.

That is a containment hierarchy with **inheritance and override at every level**, which is exactly the structure `Agenda.Place` already implements for travel time. Borrowing its shape — `holidays:` is proposed here, not built:

```elixir
australia = Agenda.place("Australia", holidays: national)
qld       = Agenda.place("Queensland", within: australia, holidays: qld_statewide)
brisbane  = Agenda.place("Brisbane", within: qld, holidays: brisbane_show_day)
```

Resolution is *"the union of every holiday set declared on the path from this node to the root"*, with a node able to suppress an inherited entry. Micro-regional then needs no new concept — it is one more `within:`. A district that has not been modelled resolves to its state's answer, which is the correct behaviour and, notably, is correct *silently* in a way that a missing key in a flat map is not.

The one thing to be careful of: `Agenda.Place` is currently a **travel** tree — campus, building, floor — and a legal jurisdiction is not the same tree. Level 3 of the Brisbane office is a place; Queensland is a jurisdiction. They coincide often enough to be tempting and diverge exactly where it hurts: a consultant living in Cairns and employed out of the Brisbane office. Whether these are one tree with two kinds of node or two trees that a resource points into separately is the first real design question below.

### Which jurisdiction, when the consultant is interstate

This is where a consulting business differs from an employer with one office, and it is the question that decides the schema.

A Sydney-employed consultant is on a client site in Brisbane during the Ekka. Two different things are true at once:

* **The client's building is shut.** That is an availability fact about a *site resource*, and `agenda` already models it — the site is a resource with open hours, and no session can be placed there.
* **The consultant still owes a normal working day.** Their entitlement follows their own place of employment, not wherever they happen to be standing.

So the site's holiday calendar and the person's holiday calendar are **different axes that must not be merged**, and the consultant's day reconciles against Sydney while their booking fails against Brisbane. A system with one `location` per engagement can express neither cleanly. This is the same lesson `agenda` already learned about the customer site being a resource rather than an attribute, arriving from a different direction.

### Two things that break the "holidays are a calendar rule" assumption

Worth raising with Josh early, because both argue against precomputing a holiday table and then trusting it:

* **Some holidays have no calendrical rule at all.** Victoria's AFL Grand Final Friday is declared each year against a sporting fixture. No recurrence expression will ever produce it; it has to come from a feed or a human. Tempo can express *"the third Monday in January"* as a native ISO 8601 recurrence — `R/../P1Y/FL1M3I1KN` — and that covers a great many holidays, but the family must not assume it covers all of them.

* **Some are sectoral rather than regional.** The NSW Bank Holiday on the first Monday in August applies to banks and parts of the finance industry, not to everyone in the state. So the resolution key is not purely geographic. If Alembic ever takes on a client in banking, the tree above needs a second discriminator, and it is much cheaper to leave room for it now than to retrofit it.

Both point the same way: **holiday calendars are versioned data with an effective date, not a pure function.** Holidays get proclaimed late, and one-off national days of mourning have been declared with weeks of notice. A reconciliation that ran clean in September must be able to be re-run in November and produce a different, also-correct answer — which means a closed period needs to record *which* calendar version it was closed against.

Tempo deliberately ships no holiday data — the guide states plainly that holidays are a domain concern — and consumes iCalendar feeds instead through `Tempo.ICal.from_ical/1`, preserving each entry's metadata. That is the right seam. **What does not exist anywhere in the family today is the resolver**: the tree, the inheritance, the override, the effective date. That is the genuinely new component, and it is small.

## Expected hours: the contract, and the two kinds of year

Josh's *"per time unit (day, week, month, quarter, year (fin/cal))"* is asking for a granularity ladder, and the parenthetical is the interesting half.

### The financial year is a calendar, not an offset

The common implementation is to keep Gregorian dates and add six months wherever a report says "FY". That works until someone asks for the third fiscal quarter, or compares a fiscal period to a calendar one, and then it becomes arithmetic nobody trusts.

Tempo's answer is that a fiscal year is a *calendar*, so fiscal and Gregorian values sit on the same timeline and comparison needs no conversion. Executed:

```elixir
iex> {:ok, calendar} = Calendrical.FiscalYear.calendar_for(:AU)
{:ok, Calendrical.FiscalYear.AU}

iex> {:ok, fy26} = Tempo.from_iso8601("2026", calendar)
iex> {:ok, months} = Tempo.to_interval(fy26)
iex> Enum.count(months)
12

iex> months |> Enum.at(0) |> Tempo.to_iso8601()
"2026Y1M"
```

> *"Australian FY2026 is twelve fiscal months, and the first of them is July 2026."*

The territory data is already there — `1 July - 30 June` for `AU` — for every country Alembic is likely to employ anyone in. The whole of Josh's day/week/month/quarter/year ladder is then one mechanism rather than five, because each is a granule of some calendar, and the same set algebra runs at every level. A quarter is `~o"2026Y3Q"`; a fiscal quarter is the same expression in a fiscal calendar.

The ladder also has to include the **ISO week**, which belongs to neither of Josh's two years. A 38-hour week is defined against a week, and week 1 of 2027 begins in December 2026. Any system that reconciles weekly and reports annually will meet the boundary case where the last week of the year is split; deciding *now* whether a week belongs to the year containing its Thursday, or is pro-rated, is much cheaper than discovering it in a year-end report.

### The contract is a pattern, not a number

"Expected total working hours" reads like a scalar and is not one. The realistic cases in a consulting business are:

* Full time, 38 hours over five days — which is **7.6 hours a day**, a number chosen to embarrass anyone storing hours as a float. Decimal throughout, or minutes as integers.
* 0.8 FTE, four days a week — and *which* four matters, because it decides whether a Monday public holiday is owed at all.
* A nine-day fortnight, where the rostered day off lands on a different weekday each cycle.
* Someone who changed from full time to 0.8 in March, so the same fiscal year has two contracts and the year-level expectation is a sum over sub-periods.

So the contract is an **availability pattern with an effective date range**, which is a thing `agenda` already has — `Agenda.open/2` puts open hours on a resource, and Tempo's recurrences express a nine-day fortnight directly. Expected hours for any period is then the measure of that pattern intersected with the period, minus holidays. It is derived, never stored, for exactly the reason `agenda` derives availability rather than storing free/busy: a stored expectation is a number that goes stale silently when a contract changes or a holiday is proclaimed.

### The gap: `limits:` counts claims, not hours

`agenda` has a period-scoped budget on a resource today, and it is the right *shape* with the wrong *measure*:

```elixir
Agenda.resource("Dana", limits: [day: 3, week: 12])
```

That reads "at most three engagements a day, twelve a week" — a count of claims over a stretch of calendar. What a timesheet needs is the same construct measuring **duration**: at most 7.6 hours a day, at least 38 a week, at most 1710 billable in the year. The period vocabulary, the ledger it counts against, and the semantics — *"however far apart, unlike concurrency"* — all carry over unchanged. Extending `limits:` to accept a duration alongside a count looks like the single highest-value change to `agenda` that Josh's problem implies, and it is additive.

Note the direction, too. A scheduling limit is a **ceiling**; a timesheet expectation is usually a **floor**, or a pair. That is a genuine extension rather than a re-reading, and it wants stating explicitly rather than being smuggled in as a negative number.

## What exists, and what is new

| Capability | Where it is | Status |
| --- | --- | --- |
| Working days for a territory, weekend-aware | `Tempo.workdays/1`, `working_days_in/2` | Built |
| Holiday sets from iCalendar feeds, metadata preserved | `Tempo.ICal.from_ical/1` | Built |
| Fixed-rule holidays as native recurrences | ISO 8601 recurrence expressions | Built |
| Set algebra that names the days, not just the count | `Tempo.members_outside/2` and family | Built |
| Fiscal calendars per territory | `Calendrical.FiscalYear` | Built |
| The claim ledger, overlap detection, release-by-key | `Agenda.Ledger`, `Agenda.Allocation` | Built |
| Period-scoped budgets on a resource | `Agenda.Resource` `:limits` | Built, **counts claims not hours** |
| Availability patterns with recurrence | `Agenda.open/2` | Built |
| Skills matching with an explanation | `Agenda.Requirement`, `Agenda.explain/2` | Built |
| Minimal conflict sets — *why* it is impossible | `Agenda.conflict/3` | Built |
| **Jurisdiction tree with holiday inheritance and override** | — | **New** |
| **Effective-dated, versioned holiday calendars** | — | **New** |
| **A claim tag: project, leave type, or holiday** | `Agenda.Allocation` + one field | **Small change** |
| **Duration-measured limits, with floors as well as ceilings** | `Agenda.Resource` `:limits` | **Extension** |
| **Leave entitlement, accrual, and balances** | — | **New, and not scheduling** |
| **Reconciliation report over a period** | — | **New, composed of the above** |

The last two rows are where the scope should stop. Everything above them is calendar and scheduling work that this family either does or nearly does; leave *balances* are payroll, with accrual rules, carry-over caps, cash-out, and leave loading, and none of that is expressible as interval algebra. It should live in Alembic's application, not in a Tempo-family library.

## Where OR earns its place, and where it does not

Josh's read — *"for our needs of people-project allocation, the solution is usually very constrained"* — is right, and it is better news than it sounds.

**Constrained is the regime exact search is good at.** `agenda`'s arranger splits a programme into components that cannot affect one another and searches them concurrently, so cost tracks the shape of the problem rather than its size: 1,200 sessions across twenty days lay out in under three seconds, while 200 all competing for a single day take about five. Consulting allocation decomposes unusually well — a practice staffing a client in July rarely interacts with a different practice's October — so the realistic instance is many small components, not one large one. Skills requirements that eliminate most consultants for most engagements shrink the search further. A solver may simply not be needed, and if it is, the `Agenda.Fixpoint` bridge already writes a solver's answer back through the same model.

The failure mode to watch for is the one case that does not decompose: **end of quarter, when everyone wants the same fortnight.** That is one dense component, and it is where the exact search runs out of road and the solver bridge earns its place. Worth knowing in advance which of the two regimes a given planning run is in, rather than discovering it as a timeout.

**Where a solver is the wrong tool is reconciliation.** There is nothing to optimise: the timesheet either accounts for the owed days or it does not, and the product's job is to say precisely which days are missing. Putting an optimiser anywhere near this converts a clear arithmetic answer into an opaque one.

Similarly, when staffing *is* infeasible, the useful output is not "infeasible" but a **minimal conflict set** — remove any one member and the rest fit. `Agenda.conflict/3` returns exactly that, over both sessions and individual demands:

```elixir
Agenda.conflict(session, pool)
#=> {:ok, [needs: {:consultant, :skills}, needs: {:site, :accredited}]}
```

> *"No one holding those skills works at an accredited site. Choose which demand moves."*

An account manager can act on that sentence. Most OR tooling answers this question badly, and it is the question a staffing desk asks most often.

**On soft constraints, the direction differs from Josh's school work, and the difference is load-bearing.** `agenda` optimises lexicographically in two passes: it first *proves* how many sessions can be placed, then improves the score without ever placing fewer. So a preference can never cost you a placement — which is exactly right for staffing, where you never leave an engagement unstaffed to give someone their preferred Friday, and exactly wrong for timetabling, where a school will trade one lesson's preferred slot for a cohort's whole-week compactness without hesitating. That divergence is why `plans/timetable.md` proposes a sibling with a local-search engine rather than an extension of `agenda`, and it is worth Josh's team knowing which side of that line each of their products sits on. Primary school scheduling, as he says, sits nearer the staffing side: one teacher per cohort for most of the week collapses most of the grid before the search starts.

Consultant preferences themselves are already expressible as wishes rather than as availability, which is the modelling point worth stealing:

```elixir
Agenda.resource("Priya", avoids: friday_afternoons)
```

Spelling a preference as unavailability takes the option away permanently and fails the week rather than booking reluctantly when there is no alternative.

## Where this should live

Not in `agenda`. Timesheets are a record of the past, entitlement is payroll, and neither belongs in a library whose subject is choosing a placement. But not in Alembic's application either, for the parts that are pure calendar work.

The split that seems right:

* **`ex_tempo`** — nothing new required. It already has workdays, the recurrence grammar, the set algebra, and the iCalendar reader.
* **`agenda`** — two additive changes: a tag on `Agenda.Allocation`, and duration-measured `:limits` with floors. Both are useful to every existing user, neither mentions timesheets.
* **A new sibling** — the jurisdiction tree, effective-dated holiday resolution, the working-time contract, and the reconciliation report. Perhaps 1,500 lines, most of it the resolver. Depends on `agenda`, the same direction `timetable` does.
* **Alembic's application** — leave balances, accrual, approval workflow, billing rates, invoicing. All the things that are not time.

### One naming hazard

**Tempo is already the name of the dominant timesheet product in the Jira ecosystem.** A Tempo-family library about timesheets will collide in search results and in the heads of precisely the buyers Alembic is selling to. This does not affect the design, but it argues for naming the sibling for what it does — working time, attendance, reconciliation — rather than for the family it belongs to. (If Josh's *"— also tempo I guess"* was a nod at that product rather than at this library, then he has already spotted it.)

## Questions for Josh

Marked as questions because each is Alembic's call, and the answers change the schema rather than the code around it.

1. **Are jurisdiction and place one tree or two?** A legal jurisdiction and a building both nest, and they coincide often enough to be tempting to merge. The consultant who lives in Cairns and is employed out of Brisbane is the case that decides it.
2. **Is a timesheet entry placed or unplaced?** *"Six hours on Acme on Tuesday"* is a quantity in a bucket; *"09:00–15:00 on Acme"* is an interval. `agenda` deals in intervals, and only the second detects that a consultant was double-booked. Which one do consultants actually enter, and is the wall-clock detail worth asking for?
3. **What granularity is billed?** Six-minute units are conventional in professional services and interact with the 7.6-hour day in ways worth deciding once, in decimal, up front.
4. **Can a closed period be reopened?** If a holiday is proclaimed late or a timesheet is corrected after invoicing, does reconciliation re-run and restate, or is the closed period immutable with an adjustment in the current one? This decides whether calendar versions must be recorded against closed periods.
5. **Half-days and part-days.** A half-day of personal leave plus a half-day billed is common and is the smallest case that breaks a day-granular model.
6. **Does anyone work across time zones?** Perth to Sydney is two hours, three in summer, and a day boundary is a real thing to get wrong. Tempo handles it correctly given a real IANA database configured — Elixir's default is UTC-only and makes DST arithmetic silently wrong rather than failing.

## Suggested next step

The cheapest thing that would tell us whether this analysis is right: build the reconciliation report **for one real Alembic consultant, for one real past quarter**, using only what exists today plus a hand-written holiday set for their jurisdiction. It needs no new library. If the resulting `unaccounted` list matches what Alembic's current process says about that quarter, the model holds and the sibling is worth building; if it does not, the disagreement will be far more informative than any further design.
