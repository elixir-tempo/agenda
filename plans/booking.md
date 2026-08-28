# Booking — a sibling library, and where it stops being one

**Status: a proposal to argue with, not a design to sign off.** The measurements are from this codebase on 2026-08-28. No prototype was built; the contention claims in *The concert* are reasoned from the shape of the problem and are the part most worth attacking.

Agenda answers *what should I book, and where?* It does not book. That is not an omission to fill in later — the reason it does not is load-bearing, and understanding it decides what the sibling is.

## Why booking cannot live in Agenda

Three things are missing, and all three are visible in the API rather than hidden in the implementation:

* **No identity.** `%Agenda.Ledger{sessions: %{}}` is a value. There is nothing to point at, nothing to name, nothing two callers can share.

* **No concurrency control.** `claim/4` validates against *the ledger it is handed*. Two processes holding the same value both succeed, and both are right, because immutability means neither can see the other.

* **No clock.** `expire(ledger, now)` makes the caller pass `now` in. A library that will not read the time has consciously stayed out of the runtime.

Any of those could be added. The reason none of them should be is different and stronger: **Agenda's purity is what makes the arranger work.** It explores thousands of hypothetical layouts, forking and abandoning ledgers freely, because a ledger is a value. Make it live shared state and speculative search becomes impossible. Booking wants the exact opposite property — one authoritative mutable truth — from the same concept, and two opposite requirements on one abstraction is precisely when a library splits.

## What Agenda already gives the sibling

The performance objection to a split does not survive measurement. The hot path of a booking service is *"is this resource free in this window"*, and that is already effectively free:

| Query | Cost |
| --- | --- |
| `free/2`, one resource, one day | **below timer resolution** |
| `busy/1` over 1,000 allocations | 0.33 ms |
| `plan/3`, 1 resource | 0.36 ms |
| `plan/3`, 5 resources | 1.35 ms |
| `plan/3`, 50 resources | 15.3 ms |
| `plan/3`, 200 resources | 78.4 ms |

Two things follow, and they are the whole performance story.

**`free/2` is the booking primitive and it is fast enough already.** Nothing needs to be added to Agenda to make a booking path quick.

**`plan/3` costs about 0.39 ms per resource in the pool, so the pool is the budget.** It answers a different question — *what are my options* — and a booking service asks it rarely. The design rule that follows is worth stating as a rule: **scope the pool to the parties involved.** Booking one delegate into one room is a two-resource query and takes well under a millisecond; handing the same call a pool of five thousand delegates takes two seconds, and would be the same answer.

The vocabulary is already booking-shaped, too — `claim`, `hold` with `until:`, `confirm`, `expire`, `release`, `reconcile`. The sibling does not invent concepts. It makes those durable and atomic.

## Three events, and they are not three sizes of one problem

The brief spans a corporate offsite, a multi-venue convention, and a stadium concert. The instinct is to treat these as small, medium and large, and build one system with headroom. That is the wrong reading. **What changes across them is not volume but contention on a single resource**, and at the top end the architecture inverts.

### A. The offsite — contention is zero

Twenty people, one track, one venue, a handful of rooms. Bookings arrive minutes apart and rarely collide. Nobody is racing anybody.

Almost everything is already done. Agenda arranges the programme, `free/2` answers availability, the ledger holds the answer. The sibling adds exactly two things: somewhere to keep the ledger between requests, and a way to name it. Optimistic writes are fine — read the ledger, plan, write, and on the rare conflict re-read and retry. A single process serialising all writes is not a bottleneck at this size and removes the problem entirely.

**The temptation to resist is building for regime C here.** A queue, a sharded inventory and an admission gate are all pure cost for an event where two people never want the same room in the same second.

### B. The convention — contention is real but spread

Several thousand delegates, multiple venues, parallel tracks, sessions with capacity. Delegates build personal agendas over days or weeks; a few sessions are hot and most are not.

This is the regime the sibling should be designed around, because it is the one where the interesting problems are and the one Agenda helps with most.

**A delegate is a resource.** That single decision — the same one the ElixirConf case study turns on for speakers — means *"a delegate cannot be in two sessions at once"* is not a rule the booking system writes. It is the constraint Agenda already enforces, and a personal agenda is just that delegate's allocations. Nothing about clash detection needs building.

**Session capacity is probably `concurrency`, and this needs deciding early.** A workshop with thirty places can be a resource with `concurrency: 30`, each delegate's attendance a session holding one of them — capacity accounting then falls out of availability arithmetic that already exists, rather than a counter the sibling maintains and has to keep true.

The care needed is that `Agenda.Resource` warns specifically against reading `concurrency` as seats: a 200-seat lecture hall is `seats: 200, concurrency: 1`, because it holds *one lecture*. The proposal above is not that reading. It is the locker reading — thirty independent holders of the same resource — and it is only right when each attendance really is its own claim. For a plenary nobody books individually, `seats` remains an attribute and capacity is not a scheduling concern at all. Getting this wrong in either direction produces a system that either double-books a hall or cannot sell a workshop, so it should be settled before anything is stored.

What the sibling must own here:

* **Per-resource serialisation.** Contention is on individual hot sessions, not on the system, so a lock scoped to a resource is enough. Two delegates booking different workshops must not wait on each other.

* **A cached read model.** *"What is still available"* is asked far more often than anything is booked. It is derived, cheap to compute per resource, and stale-tolerant for display — but it must be recomputed inside the write path, never trusted from cache when actually claiming.

* **Holds with a checkout timer.** `hold/3` and `expire/2` already describe this; the sibling supplies the clock and the sweeper.

* **Waitlists.** A hold that lapses should offer the place to whoever is next rather than returning it to an undifferentiated pool.

### C. The concert — the architecture inverts

Sixty thousand seats, half a million people, the first sixty seconds. Every one of them wants the same inventory at the same instant.

**Nothing above survives this, and the reason is worth being precise about.** Checking availability before writing is the pattern regimes A and B are built on, and here it is not merely slow but *meaningless*: any answer is stale before it reaches the client, and the check itself multiplies load by the number of people who will not get a seat. Per-resource locking does not help either, because the resource under contention is the bottleneck by definition — serialising on it is the problem, not the fix.

What a system in this regime actually does is refuse to let most requests reach the inventory at all:

* **Admission control.** A virtual waiting room admits people at the rate the booking path can serve, and everyone else holds a queue position. This is the load-shedding decision, and it is made before any domain logic runs.

* **Pre-partitioned inventory.** Seats are minted into buckets ahead of time and each worker allocates from its own, so allocation is a local decrement rather than a contended read-modify-write. Fairness comes from the queue, not from competing for a row.

* **Short holds and aggressive expiry.** A checkout timer measured in minutes, swept relentlessly, because unclaimed holds are the whole inventory during the surge.

* **Reconciliation afterwards, not consistency during.** Buckets drift; a bucket empties while another has stock. That is corrected by rebalancing between waves, not by a global lock.

**And Agenda barely appears.** A concert is one event at one time: there is no interval algebra to do, no clash to detect, no layout to search. The seat is not a resource-with-time, it is inventory. The sibling would use Agenda here for the venue and the event, and to write allocations into a ledger *afterwards* — and for nothing on the hot path.

That is worth saying plainly because it is a scope boundary, not a limitation. **A ticketing surge is a different system that happens to end in the same ledger.** Building A and B to accommodate it would compromise both; building C as a mode of the same library would produce something that is bad at all three.

## The shape this implies

One library covering A and B, designed around B, with C explicitly out of scope and a documented seam where a ticketing system writes its results in.

The seam is the allocation. All three regimes end in the same place — a ledger of who holds what, when — and that is what makes it safe for C to live elsewhere. What must not happen is a second answer to *"do these clash"*. Agenda's stated value is that its two solvers cannot disagree about what a conflict is; a booking store that reimplements the check instead of calling `Agenda.Arranger.conflict?/4` and `free/2` turns a split into a fork.

## What exists, and what is new

| Capability | Where it is | Status |
| --- | --- | --- |
| Availability from open hours minus claims | `Agenda.free/2` | Built, fast enough for the write path |
| A delegate who cannot be in two places at once | `Resource`, `concurrency: 1` | Built |
| Session capacity | `Resource`, `concurrency: n` | Built |
| Per-period caps on a participant | `Resource` `:limits`, honoured by `plan/3` | Built |
| Hold, confirm, release, expire | `Agenda.Ledger` | Built as **values** |
| Why a booking was refused | `Agenda.explain/1`, `conflict/3` | Built |
| **Identity and persistence for a ledger** | — | **New — the sibling's core** |
| **Per-resource serialisation of the write path** | — | **New** |
| **A clock, and a sweeper for lapsed holds** | — | **New** |
| **A cached read model for "what is left"** | — | **New** |
| **Waitlists** | — | **New** |
| **Idempotency for retried requests** | — | **New** |
| Admission control, queueing, sharded inventory | — | **Out of scope — regime C, a separate system** |
| Payments, tickets, delivery, fraud | — | Out of scope |

## Open questions

* **One store or two?** Postgres alone is simpler and almost certainly enough for A and B. An ETS read model in front of it is an optimisation to add when a measurement asks for it, not before.

* **Serialise how?** A row lock in a transaction, or a process per resource. The process is more Elixir and gives a natural home for the hold timer; the row lock survives a node restart without ceremony. This is the design's main fork and it should be decided by how the read model is kept fresh, not by taste.

* **Is a waitlist an interest?** `Agenda.Interest` already says *one resource would like a session with another*. A waitlist entry is close to that, and if it is the same thing then matchmaking and booking share a primitive rather than each having one.

* **Does the sibling own the demand side generally?** Delegates choosing sessions is the same shape as buyers choosing suppliers. If the answer is yes, the library is about demand rather than about booking, and the name should say so.

## Suggested next step

Prototype the contention case before committing to the serialisation choice: two processes racing for the last place, under both designs, and measure what each costs when they are not contending — which is the common case and the one that decides the architecture. Everything else in regimes A and B is assembly of parts that already exist.
