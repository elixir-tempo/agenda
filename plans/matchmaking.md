# Hosted-buyer matchmaking — a discussion document

**Status: prototyped, then partly built.** Every measurement below was taken against this codebase on 2026-08-28. The prototype answered the question the plan was written to ask and changed the plan twice — see *Density* and *The answer* — and the first stage has since landed: `Agenda.Interest`, `Agenda.interest/3`, `Agenda.meetings/3`, and a fix to `Agenda.Planner` so that `plan/3` honours a resource's `:limits`.

**On the name.** This document originally called the primitive a *wish*. That word was already taken: `Agenda.Resource`'s `avoids` and `prefers` are documented as "a wish, not a rule" and scored by the `:resource_wishes` preference. The built primitive is an **interest** — the domain's own phrase, and free.

A hosted-buyer programme is the commercial core of most trade shows and a good part of incentive travel. Buyers and suppliers register interest in each other, and the organiser produces a grid of short meetings — typically fifteen or twenty minutes — at numbered tables, over one or two days. Every participant has a cap on how many meetings they will take and a floor below which the event has failed them. The organiser is judged on how many *mutually wanted* meetings they fit, and on nobody going home with an empty card.

It is worth stating plainly why this is the right feature to look at: it is the highest-value thing in MICE software that is *entirely* a scheduling problem. Registration, travel and badging are systems around the event. This one is the event.

## The one idea: a meeting is a session with two rosters

Nothing in the paragraph above needs a new scheduling concept. A meeting between a buyer and a supplier at a table is an ordinary session that names three resources:

```elixir
Agenda.session("Kim Nguyen × Harbour Tours", duration: ~o"PT15M", window: show_hours)
|> Agenda.Session.roster(:buyer, [kim])
|> Agenda.Session.roster(:supplier, [harbour_tours])
|> Agenda.Session.needs(:table, seats: at_least(2))
```

Both participants are resources with the default concurrency of one, so *a person cannot be at two tables at once* is not a rule anybody writes — it is the constraint the library already enforces, and it is the same lesson the ElixirConf case study turns on. The table is chosen by description rather than named, so the search assigns it.

Three more things fall out without being asked for:

* **The slot grid is free.** Candidate start times step by the session's own duration, so uniform fifteen-minute meetings over hours that begin on the quarter produce exactly the grid a show runs on. There is no `:slot` concept to add.

* **Table turnaround is free.** A table that needs two minutes to reset between meetings is `buffer_after`, and candidate starts shift to match.

* **Walking between tables is free.** If tables are spread across halls, the place tree already measures the journey, and `Track.reachable/2` already refuses a layout that does not allow for it.

So the scheduling half is done. What is missing is the other half.

## What is missing is demand

Agenda is a complete supply-side model. It knows what exists, when it is free, and what may not collide. It has no way to say **who wants what**. The delegate appears in `Agenda.Track`'s documentation as a narrative device and nowhere in the code; `seats` is an attribute that `needs/3` matches and nothing ever consumes.

Matchmaking needs one new primitive, and it is small:

> **An interest: one resource would like a session with another.**

```elixir
{:ok, programme} = Agenda.interest(programme, kim, harbour_tours)   # the buyer asked
{:ok, programme} = Agenda.interest(programme, harbour_tours, kim)   # and the supplier agreed

{:ok, programme} =
  Agenda.meetings(programme, pool,
    duration: ~o"PT15M",
    needs: [table: [seats: at_least(2)]])
```

From a set of interests, the sessions above are *generated* rather than written. That is the whole feature: the organiser uploads two lists and a pile of requests, and the programme builds itself. Interest that is never returned is reported by `Agenda.Interest.one_sided/1` rather than quietly scheduled.

The same primitive should pay for three other MICE features that are not matchmaking — demand-driven room sizing, clash avoidance between popular sessions, and delegate-to-excursion allocation — which is the argument for making it a first-class concept rather than a matchmaking-shaped helper.

## Where the fit is not clean

Three places where the existing engine does not do what matchmaking wants. Naming them is the point of this document.

### 1. The search maximises count; matchmaking wants value

`arrange/3` optimises lexicographically: first it places as many sessions as it can, *then* it prefers a better score among layouts that place the same number. For a conference that is right — every talk matters equally, and a preference should never cost a placement.

For matchmaking it is wrong in a specific way. A mutual match — both sides asked — is worth more than a one-sided one. Under count-first optimisation, a layout with 900 one-sided meetings beats one with 880 mutual ones, which is the opposite of what the organiser wants.

**The recommendation is to sidestep this rather than fix it.** Generate sessions only for interest that is returned, so that count and value are the same number and the existing contract is exactly right. One-sided requests become a second, lower tier scheduled into whatever the first pass leaves empty. Making the search maximise a weighted objective would change the `minimal?` guarantee that everything else in the library depends on, and it should not be done for this.

### 2. Floors are completion conditions, not placement constraints

"Every buyer gets at least eight meetings" is the fairness half of the contract, and `Agenda.Limit` deliberately does not enforce floors during the search — a floor cannot prune, and enforcing it would make the arranger disagree with the fixpoint bridge.

That leaves two workable routes, and they are not equivalent:

* **As a preference.** Penalise every participant below their floor, weighted heavily. Costs nothing architecturally, uses machinery that exists, and gives up the guarantee — the search may still return a layout that starves somebody if it cannot do better.

* **As a post-check.** `Agenda.reconcile/3` already reports a period against a contract. Run it after arranging, and re-run the arrangement with the starved participants' interests promoted.

The preference is the right first move. The honest framing for an organiser is that a floor is a *target the layout is scored against*, not a promise, and the report says who missed it.

### 3. Density — the general search cannot carry this, and the reason is specific

This was the open risk when the plan was written. It has been measured, and the answer is no.

| Meetings in one dense component | `arrange/3` |
| --- | --- |
| 90 | 753 ms |
| 160 | 7.4 s |
| 200 | 14.4 s |
| 300 | **node limit, after 88 s** |
| 300 with `nodes: 100_000` | **node limit, after 36 s** |

A mid-sized programme is 900. The search stops at somewhere under 300, and **raising the budget tenfold does not move it** — this is structural, not a budget you can buy your way past.

**Why matchmaking is harder than a conference of the same size.** The arranger's own comment calls symmetry breaking "the reason the search is tractable at all": interchangeable sessions collapse to one representative instead of exploring every permutation. The symmetry key is `{track, duration, window, requirements}` — and `roster/3` puts the *named participants* into requirements. Every meeting names a different buyer and a different supplier, so every meeting is its own group:

| 100 sessions | distinct symmetry groups |
| --- | --- |
| conference talks, same length and window | **1** |
| matchmaking meetings | **100** |

Matchmaking defeats the mechanism the search depends on, completely and by construction. Earlier measurements showing 450 dense sessions inside the default budget were taken on maximally *symmetric* instances and do not transfer to this problem.

**A second, independent obstacle.** Even given budget, the candidate lists cannot describe the grid. Two show days of fifteen-minute slots across forty tables is 64 × 40 = 2,560 placements per meeting, and a truncated list must trade one dimension for the other:

| Planning one meeting | distinct slots | distinct tables |
| --- | --- | --- |
| `limit: 60, spread: true` | 60 | **1** |
| `limit: 60, spread: false` | **2** | 40 |
| `limit: 500, spread: true` | 64 | 8 |

`spread: true` — which is what `arrange/3` uses — offers sixty times on a single table. The search never learns the other thirty-nine exist.

## The answer: booking against a ledger, which needs no new engine

The plan speculated that a grid-aware arranger might be wanted, and worried it would be a large piece of work. It is not — but it is also not the four lines it first appeared to be, and the difference is a correctness bug the prototype caught.

The trick is to stop enumerating. Rather than hand the search a candidate list that must span the whole grid, book one meeting at a time and tell the planner what is already taken, so the options it returns are free by construction:

```elixir
Enum.reduce(programme.sessions, Agenda.ledger(), fn meeting, ledger ->
  case Agenda.plan(meeting, pool, busy: Agenda.busy(ledger), limit: 150, spread: true) do
    {:ok, [choice | _]} ->
      {:ok, ledger} = Agenda.allocate(ledger, choice)
      ledger

    _nothing_free ->
      ledger
  end
end)
```

Eligibility, availability, buffers, travel, the place tree **and now load limits** are all still the library's — only the *choice* is different, exactly as `Agenda.Fixpoint` already shows is possible. Every placement is one the planner offered, so nothing is hand-built, and the ledger refuses anything that clashes.

Measured end to end through the built API — registering interest, generating meetings, then booking — with a cap of eight meetings a day enforced on every participant:

| Show | Generate | Book | Booked |
| --- | --- | --- | --- |
| 15 buyers × 60 suppliers, 6 each (90) | 5 ms | 2.2 s | 90 of 90 |
| 30 × 80, 10 each (300) | 5 ms | 8.4 s | 300 of 300 |
| 60 × 120, 15 each (900) | 22 ms | 28 s | 871 of 900 |

No participant exceeded the cap in any run, and the booking loop above checks nothing — the planner does. The 29 unbooked meetings at the largest size are caps genuinely binding: a buyer wanting fifteen meetings against eight a day over two days has almost no slack once their suppliers are capped too.

Generation is free. Booking is the cost, and enforcing limits roughly doubled it — 900 meetings went from 12 s to 28 s once every candidate had to be checked against what its participants already hold. That is the price of a correct answer and it is worth paying, but it is the obvious place to look if the pass ever needs to be faster.

### Two hazards the prototype found — one now fixed in the library

**`plan/3` did not enforce a resource's `:limits`, and now does.** Limits lived in the arranger's compatibility check and nowhere else, so a booking pass that trusted `plan/3` would cheerfully exceed them: asked for six meetings against a buyer capped at three a day, the first prototype booked **all six**, while `arrange/3` on the identical programme correctly placed three. Caps are not a detail of a hosted-buyer programme — they are most of the contract.

This was fixed where it belongs rather than in the caller. `Agenda.Planner` now filters placements that would take a resource past a limit, whenever `:busy` gives it something to count against; without `:busy` there is nothing to count and every placement stands, which is why `Agenda.Arranger` still checks limits itself as it places. Four tests hold it, including the one that matters: a loop that books each planned placement in turn, checking nothing, stops at the cap.

The general lesson is worth keeping. **Any constraint the arranger enforces and the planner does not is a trap for incremental callers**, because the failure is silent and looks like a good answer. Limits were the one; it is worth asking whether anything else is in the same position.

**Option coverage interacts badly with per-day caps.** `spread: true` with a small `:limit` samples start moments unevenly: on a two-day show, `limit: 20` returned **twenty options all on day two and none on day one**. Combined with a cap of eight a day, that silently pinned the whole show at eight meetings per buyer — 240 of 300 — and looked exactly like a capacity bound rather than a sampling artefact. Raising the limit to 150 made both days visible and the same instance booked 300 of 300.

A booking pass must ask for enough options to span every bucket its limits are measured in, and that number is a property of the window rather than a constant. This one is *not* fixed, and it is the sharpest edge left on the feature.

### How good are the answers?

Better than first-fit deserves, and the reason is worth stating rather than celebrating. Where capacity genuinely bound, the pass placed exactly the theoretical maximum — 896 of 900 against a 64 × 14 table ceiling, 1,280 of 2,000 against a supplier ceiling, 960 of 2,250 against a ceiling of 960 — but every one of those instances is **complete bipartite**: every buyer wants every supplier, so any free slot can be filled by some waiting buyer and greed cannot strand capacity. Real demand is sparse and lumpy, which is precisely where first-fit is expected to fall short.

**The claim to take from this is that greed is good enough to build on, not that it is optimal.** It must be measured against a real request set before anyone promises an organiser a number.

**What is given up.** `arrange/3` proves it left out the fewest possible; this proves nothing. There are no preferences, so nothing expresses "spread a buyer's meetings through the day" or "honour first choices". Both are recoverable — the order meetings are offered in is the obvious lever — but neither is free.

## What exists, and what is new

| Capability | Where it is | Status |
| --- | --- | --- |
| Two participants, neither in two places at once | `Session.roster/3`, `concurrency: 1` | Built |
| A table chosen by description | `Session.needs/3` | Built |
| A fifteen-minute grid across the show's hours | candidate stepping in `Agenda.Planner` | Built |
| Table reset between meetings | `Resource` `:buffer_after` | Built |
| Walking between halls | `Place` tree, `Track.reachable/2` | Built |
| Caps: "no more than twelve meetings" | `Resource` `:limits` | Built |
| Book what fits and report the rest | `arrange/3` `unplaced: :allow` | Built |
| Why a meeting could not be placed | `Agenda.explain/1`, `conflict/3` | Built |
| The result as ordinary allocations | `Agenda.Ledger` | Built |
| **An interest: one resource would like a session with another** | `Agenda.Interest`, `Agenda.interest/3` | **Built** |
| **Sessions generated from returned interest** | `Agenda.meetings/3` | **Built** |
| **Floors as a scored target, and a report of who missed** | `Preference`, `reconcile/3` | **New, assembly of built parts** |
| **Booking a show against a ledger, one meeting at a time** | `plan/3` `:busy`, `Ledger.allocate/3` | **Measured: 899 of 900 in 12 s, caps enforced** |
| **`plan/3` honouring `:limits` when given `:busy`** | `Agenda.Planner` | **Built — closes a silent-wrong-answer trap** |
| Solving a show through `arrange/3` | — | **Ruled out — stops under 300, and budget does not fix it** |
| Weighted objective — mutual outranking one-sided | — | Rejected: costs the `minimal?` guarantee |
| Preferences over a booked show — spread, first choices | — | **Open: the booking order is the lever, unmeasured** |
| A proof that the fewest were left out | — | Given up by the booking approach, deliberately |

## Where the scope stops

Registration, payments, travel and accommodation booking, badge printing, lead capture, no-show handling and the buyer-qualification workflow are all systems *around* this. They meet Agenda at the ledger, the same seam holidays use. None of them should come inside.

## Open questions

* **Is an interest between two resources, or from a resource to a session?** Matchmaking wants the first; excursion allocation wants the second. If one primitive cannot serve both cleanly, matchmaking should get the pairwise one and the other can wait.

* **Where do one-sided requests go?** A second pass into the gaps is the obvious answer, but organisers differ on whether an unrequited meeting is worth scheduling at all.

* **Is the cap a `:limit` or an interest-level concern?** `limits: [day: 12]` already says twelve a day. It is probably enough.

## Suggested next step

The prototype has answered the question this plan was written to ask, so the next step is no longer measurement.

**It is about adding a primitive, not a solver.** The scheduling works today; what was missing is the interest, now built, and a booking pass of about ten lines that already runs at show scale. Neither needs a change to the arranger, and the arranger should not be changed to accommodate this — its guarantees are worth more to conferences than they would be here.

Three things, in order:

1. ~~**The interest primitive and mutual-match generation.**~~ **Built.** `Agenda.Interest`, `Agenda.interest/3` and `Agenda.meetings/3`, with `plan/3` taught to honour `:limits` so an incremental caller cannot exceed a cap by accident.

2. **Real demand data before trusting the greed.** Every instance measured was complete bipartite, which is the easy case. A sparse, lumpy request set from an actual show is the test that matters, and it decides whether first-fit is enough or whether the booking order needs to be smarter.

3. **Then, and only then, preferences over the booked result** — spreading a buyer's day, honouring first choices, filling the starved. The booking order is the lever and none of it has been measured.

What should **not** happen is teaching `arrange/3` to do this. The two problems want different things from a search, and the library already demonstrates in `Agenda.Fixpoint` that a second strategy can share the whole model and differ only in how it chooses.
