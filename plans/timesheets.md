# Timesheets, leave, and working-time reconciliation — a discussion document

**Audience:** Kip Cole and Josh Price. This is a proposal to talk about, not a design to sign off. Everything that is Alembic's call is marked as a question rather than answered.

**Note on circulation:** this document quotes Alembic's internal discussion and describes their commercial context. It should stay internal until Alembic are happy for it to travel — in particular it should not ship in a public release of `agenda`, nor survive the repository being made public. The Hex package is unaffected: `mix.exs` does not include `plans/` in its `files:` list.

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

## Holidays are somebody else's problem, and the seam is an `IntervalSet`

**Decision (Kip, 2026-08-25): the jurisdiction tree and holiday resolution stay outside this family entirely.** Holidays are resolved externally and handed to `agenda` as a `t:Tempo.IntervalSet.t/0`, or as an `.ics` feed that becomes one. The reasoning is that the problem has much broader usage than scheduling, and that accurate sub-national holiday data is hard to find and harder to keep current — which makes it a library with its own release cadence and its own maintainers, not a corner of a scheduling engine.

This is the same line Tempo already draws. The workdays guide states it plainly: which territory's holidays and which year's calendar are choices the library cannot make for you, so Tempo ships the weekend logic and none of the holiday data.

### The seam already exists, and needs no new code

This is the part worth checking rather than assuming, and it holds. `Agenda.Availability.open/2` accepts an `IntervalSet` as one of its patterns, and `free/2`'s `:busy` option accepts *"a Tempo value, a string, an `IntervalSet`, or a list of them"*. So an externally-resolved holiday set drops straight in:

```elixir
iex> {:ok, dana} = Agenda.open(Agenda.resource("Dana"), business_hours)
iex> {:ok, free} = Agenda.free(dana, within: ~o"2026-08-10/2026-08-15")
iex> Tempo.IntervalSet.count(free)
5

iex> {:ok, holidays} = Tempo.IntervalSet.new([~o"2026-08-12/2026-08-13"])
iex> {:ok, free} = Agenda.free(dana, within: ~o"2026-08-10/2026-08-15", busy: holidays)
iex> Tempo.IntervalSet.count(free)
4
```

> *"Five working days that week; four once Brisbane's show day is subtracted."*

Wednesday 12 August is simply gone from the free set, and nothing in `agenda` learned what a public holiday is. `Tempo.ICal.from_ical/1` covers the other input path, returning an `IntervalSet` with each entry's `summary` and other metadata preserved — so a CalDAV or officeholidays.com feed reaches the same seam without an intermediate format.

The practical consequence for the reconciliation algebra earlier in this document: `holidays` is a parameter, not a computation. Everything in that section stands unchanged, with the set arriving from outside.

### The decision makes the interstate case easier, not harder

The awkward case for consulting is a Sydney-employed consultant on a client site in Brisbane during the Ekka. Two things are true at once:

* **The client's building is shut** — an availability fact about a *site resource*.
* **The consultant still owes a normal working day** — their entitlement follows their own place of employment, not wherever they are standing.

Had holidays been resolved inside `agenda` from a jurisdiction tree, these two would have had to be untangled from a single hierarchy, and the tree would have needed to distinguish "closes this building" from "excuses this person". With holidays arriving as data, they are just **two different `IntervalSet`s attached to two different resources** — the site's and the person's — which is the correct model and requires no mechanism at all. The awkward case disappears rather than being handled.

That also removes the first design question this document originally posed. Jurisdiction and place are not one tree or two inside `agenda`; jurisdiction is not in `agenda`.

### What the external library will have to get right

Recorded here because the analysis is already done and whoever builds it will need it — not as a proposal for this family.

The structure is a containment hierarchy with **inheritance and override at every level**, and the depth at which an authoritative answer appears varies by holiday. Australia Day is national. Labour Day is per state, on different dates in different states. Easter Sunday is a public holiday in some states and not others. And under the *Holidays Act 1983* (Qld) a show holiday is appointed **per district**, so Brisbane's falls on the Ekka Wednesday while Toowoomba's, Cairns's and Townsville's fall on entirely different dates. Josh's 🤯 is the right reaction, but micro-regional is not a special case — it is one more level of the same nesting, and a flat `state:` or `region:` key cannot express it because there is no fixed depth to flatten to.

Three properties that will bite whoever takes it on, and that argue the maintenance burden is real:

* **Some holidays have no calendrical rule at all.** Victoria's AFL Grand Final Friday is declared each year against a sporting fixture. No recurrence expression will ever produce it. Tempo can express *"the third Monday in January"* natively as `R/../P1Y/FL1M3I1KN`, which covers a great many holidays — but not this class, which has to come from a feed or a human.

* **Some are sectoral rather than regional.** The NSW Bank Holiday on the first Monday in August applies to banks and parts of the finance industry, not to everyone in the state. The resolution key is therefore not purely geographic.

* **The data is effective-dated, not a pure function.** Holidays get proclaimed late, and one-off national days of mourning have been declared with weeks of notice. A reconciliation that ran clean in September must be re-runnable in November and produce a different, also-correct answer.

That last property is the one with a consequence *inside* Josh's system regardless of who supplies the data: **a closed period must record which calendar version it was closed against**, or restatement is not reproducible. That is question 3 below.

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

iex> # And that first fiscal month projects onto a real Gregorian one.
iex> Tempo.relation(Tempo.from_iso8601!("2026-01-01", calendar), ~o"2025-07-01")
:equals
```

> *"Australian FY2026 is twelve fiscal months, and the first of them is July 2025."*

That last line is the trap, and it is worth running rather than reasoning about. `"2026Y1M"` is a *fiscal* label, not a Gregorian date, and Australian FY2026 begins in July **2025** — so "FY26" and "2026" name overlapping but different stretches of time. Any report carrying both has to agree with its reader about which calendar year a financial year starts in, and the projection above is what settles it rather than a convention nobody wrote down.

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
| Holidays accepted as data, no jurisdiction knowledge | `open/2` pattern, `free/2` `:busy` | Built |
| Fixed-rule holidays as native recurrences | ISO 8601 recurrence expressions | Built |
| Set algebra that names the days, not just the count | `Tempo.members_outside/2` and family | Built |
| Fiscal calendars per territory | `Calendrical.FiscalYear` | Built |
| The claim ledger, overlap detection, release-by-key | `Agenda.Ledger`, `Agenda.Allocation` | Built |
| Period-scoped budgets on a resource | `Agenda.Resource` `:limits` | Built, **counts claims not hours** |
| Availability patterns with recurrence | `Agenda.open/2` | Built |
| Skills matching with an explanation | `Agenda.Requirement`, `Agenda.explain/2` | Built |
| Minimal conflict sets — *why* it is impossible | `Agenda.conflict/3` | Built |
| **A claim tag: project, leave type, or holiday** | `Agenda.Allocation` `:tag` | **Built** |
| **Duration-measured limits, with floors as well as ceilings** | `Agenda.Limit` | **Built** |
| **Reconciliation report over a period** | `Agenda.reconcile/3` | **Built** |
| Jurisdiction tree, effective-dated holiday calendars | — | **Out of scope — separate library** |
| Leave entitlement, accrual, and balances | — | Out of scope — payroll, not scheduling |

The three bolded rows are built, tested and documented in `agenda`. The two below them are where the scope stops: holiday resolution for the reasons given above, and leave *balances* because accrual rules, carry-over caps, cash-out and leave loading are payroll, none of it expressible as interval algebra. Both belong outside this family.

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

Entitlement is payroll and holiday data is its own domain, so neither belongs here. What does belong in `agenda` is the part that is already about claims on a resource's time: tagging what a claim was *for*, budgeting a resource's time by duration, and reporting the difference between the two.

The split that seems right:

* **`ex_tempo`** — nothing new required. It already has workdays, the recurrence grammar, the set algebra, and the iCalendar reader.
* **`agenda`** — three additions, built: `Agenda.Allocation`'s `:tag`, `Agenda.Limit` (duration measures, floors and ceilings), and `Agenda.reconcile/3`. All three are useful to every existing user, and none of them mentions timesheets or knows what a holiday is.
* **A separate holiday library** — the jurisdiction tree, effective-dated calendars, and the data behind them. Outside this family entirely, with its own maintainers and cadence, feeding `agenda` an `IntervalSet`.
* **Alembic's application** — leave balances, accrual, approval workflow, billing rates, invoicing. All the things that are not time.

### One naming hazard

**Tempo is already the name of the dominant timesheet product in the Jira ecosystem.** A Tempo-family library about timesheets will collide in search results and in the heads of precisely the buyers Alembic is selling to. This does not affect the design, but it argues for naming the sibling for what it does — working time, attendance, reconciliation — rather than for the family it belongs to. (If Josh's *"— also tempo I guess"* was a nod at that product rather than at this library, then he has already spotted it.)

## Questions for Josh

Marked as questions because each is Alembic's call, and the answers change the schema rather than the code around it.

1. **Is a timesheet entry placed or unplaced?** *"Six hours on Acme on Tuesday"* is a quantity in a bucket; *"09:00–15:00 on Acme"* is an interval. `agenda` deals in intervals, and only the second detects that a consultant was double-booked. Which one do consultants actually enter, and is the wall-clock detail worth asking for?
2. **What granularity is billed?** Six-minute units are conventional in professional services and interact with the 7.6-hour day in ways worth deciding once, in decimal, up front.
3. **Can a closed period be reopened?** If a holiday is proclaimed late or a timesheet is corrected after invoicing, does reconciliation re-run and restate, or is the closed period immutable with an adjustment in the current one? This decides whether calendar versions must be recorded against closed periods.
4. **Half-days and part-days.** A half-day of personal leave plus a half-day billed is common and is the smallest case that breaks a day-granular model.
5. **Does anyone work across time zones?** Perth to Sydney is two hours, three in summer, and a day boundary is a real thing to get wrong. Tempo handles it correctly given a real IANA database configured — Elixir's default is UTC-only and makes DST arithmetic silently wrong rather than failing.

## Suggested next step

The cheapest thing that would tell us whether this analysis is right: build the reconciliation report **for one real Alembic consultant, for one real past quarter**, using only what exists today plus a hand-written holiday set for their jurisdiction. It needs no new library. If the resulting `unaccounted` list matches what Alembic's current process says about that quarter, the model holds and the sibling is worth building; if it does not, the disagreement will be far more informative than any further design.
