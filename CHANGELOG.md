# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.1.0] — 2026-08-27

First release. Resource-constrained scheduling on top of [Tempo](https://hex.pm/packages/ex_tempo): Tempo answers *when is this free?*, Agenda answers *what should I book, and where?*

### Added

* **The model.** `Agenda.Resource`, `Place`, `Session`, `Arrangement` and `Allocation` — people and rooms are the same kind of thing, differing only in their attributes.

* **Requirements by description or by name.** `needs/3` matches on attributes — `at_least/1`, `any_of/1`, `all_of/1`; `roster/3` names exact resources, and a person's own `requires` folds into their room.

* **Availability is derived, never stored.** `open/2` takes a Tempo value, an ISO 8601 string or an `RRULE`; `free/2` computes open minus busy on demand, honouring `concurrency` and `buffer_before`/`buffer_after`.

* **Planning one session.** `Agenda.plan/3` ranks the ways a session could be held — attribute eligibility, then availability, then co-availability across the roster, then slotting.

* **Arranging a whole programme.** `Agenda.arrange/3` places every session with no resource in two places at once, no track clashing with itself, and consecutive sessions reachable across the place tree.

* **Failures are sentences.** Every refusal names the resource and each reason it failed; `Agenda.conflict/3` returns the *minimal* set of sessions or demands in tension, via QuickXplain.

* **When it will not all fit.** `unplaced: :allow` returns `{:partial, layout}` with a reason per omission, and `:pinned` fixes announced placements while searching around them.

* **Preferences that cannot cost a placement.** `Agenda.prefer/3` scores layouts — `:room_changes`, `:room_spread`, or your own. Optimisation is two-pass, so the number placed is settled and proven first.

* **Order, load and wishes.** `Agenda.precede/4` sequences sessions with an optional `:gap`; `:limits` caps claims or hours per period; `:avoids` and `:prefers` make a placement worse rather than impossible.

* **The ledger.** `allocate/2`, `release/2` and `diff/3` keep bookings true as sessions move, `hold/3` and `confirm/2` take a resource tentatively, and `:tag` records what the time was for.

* **Recurrence and reconciliation.** `Agenda.every/3` expands a session over an ISO 8601 recurrence or `RRULE`; `Agenda.reconcile/3` reports unaccounted and overclaimed time as interval sets, not quantities.

* **Scale.** Candidate enumeration runs concurrently and sessions that cannot constrain each other are solved as separate problems: 1,200 sessions across twenty days lay out in under three seconds.

* **Optional integrations.** `Agenda.from_ical/1` reads open hours from an RFC 7953 `VAVAILABILITY` — what a CalDAV server hands you when asked when someone is free.
