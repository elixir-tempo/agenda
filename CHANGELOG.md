# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

* `Timetable.Resource` honours `concurrency` — previously the field was accepted, documented, and enforced nowhere, so a twenty-locker bank went fully unavailable after one booking. A window is now unavailable only where overlapping claims reach the resource's concurrency.

* `buffer_before` and `buffer_after` on a resource — turnaround that is genuinely unavailable rather than something the caller must remember to leave free. A 30-minute claim with a 15-minute after-buffer blocks 45 minutes.

* `Timetable.every/3` expands a session over an ISO 8601 recurrence or RFC 5545 `RRULE` into one session per occurrence, sharing a `:series` name; `Timetable.release_series/3` cancels the run, or with `:from` only the part still ahead.

* `Timetable.only_during/2`, `during_any/2` and `lasting_at_least/2` — constraint composition, grouped-OR constraints, and minimum durations as named verbs. Each accepts a set or the `{:ok, set}` from a previous step, so refinements read as one sentence and still short-circuit on error.

* A timezone database is configured for development and test. Without one Elixir resolves every zone as UTC and daylight-saving arithmetic is silently wrong; consuming applications must configure their own, which the README now explains.

### Performance

* `Timetable.Arranger.arrange/3` breaks symmetry between interchangeable sessions — same track, length, window, and requirements — by fixing a canonical chronological order among them. Proving a tight programme infeasible previously cost a factorial in the number of look-alike sessions: nine one-hour talks into eight hours took over 100 seconds and now takes 9 ms; seven into six went from 373 ms to 2 ms. No arrangement is lost, because interchangeable sessions can always be relabelled into the canonical order.

* `Timetable.Availability.free/2` collapses everything claiming a resource into one interval set before subtracting, rather than folding one sweep per claim. A resource with 800 prior bookings no longer pays 800 passes over its own open hours.

### Fixed

* Named resources are now recorded in the arrangement they were matched for. Previously a `roster/3` requirement was honoured when planning but never appeared in `allocations`, so the ledger did not know a named person or site was in use and would happily double-book them.

* A resource with no place no longer makes every journey unmeasurable. People and equipment travel with the session; only located resources count as a leg of a journey, so a track with named speakers is now reachable rather than always infeasible.

### Added

Phases 1 to 4 of the design — the model, matching, availability, single-session planning, the allocation ledger, and whole-programme arrangement. The AshScheduling adapter follows.

* `Timetable.Track` — sessions constrained against each other rather than against a resource. Not overlapping is intrinsic to being a track; `reachable/2` adds the requirement that a delegate can walk between consecutive sessions in the gap, derived from the place tree.

* `Timetable.Programme` — the whole layout: tracks, standalone sessions, and the span they fall inside.

* `Timetable.Arranger.arrange/3` — a placement for every session such that no resource is in two places at once, no track clashes with itself, and every consecutive pair is reachable. Depth-first with backtracking, ordered most-constrained first. Both the `:candidates` and `:nodes` caps report when they are hit rather than returning a partial programme as though it were finished.

* Three worked case-study guides — consultants on customer sites, meeting rooms with AV, and a two-day conference with parallel tracks. Every value shown in them is executed output, not illustration.


* `Timetable.Ledger` — what is allocated, keyed by the session holding it. `allocate/2` is idempotent, `release/2` frees everything a session held, and `busy/2` shapes the ledger for `plan/3` so planning and allocating compose into a loop.

* `Timetable.Ledger.diff/3` — what would change if a session moved, as `:keep` / `:release` / `:allocate`. A binding the new arrangement still wants is never released and re-allocated; that pair would hand the resource to a competing booking in the gap.

* `Timetable.Allocation` — one resource bound to one session over one interval.


* `Timetable.Session` — what is being scheduled: a duration, a window, requirements by attribute or by named roster, and soft preferences.

* `Timetable.Availability` — `open/2` accepts a Tempo value, an ISO 8601 string (preferred), or an RFC 5545 `RRULE`; `free/2` derives `open − busy` on demand, so free time can never go stale.

* `Timetable.Planner.plan/3` — ranks the ways a session could be held: attribute eligibility, then availability, then co-availability across the roster, then slotting, then preference ranking.

* `Timetable.Arrangement` and `Timetable.Infeasible` — a candidate placement, and a failure that always carries its reasons.

Phase 1:

* `Timetable.Resource` — named, allocatable things. People and rooms differ only in their attributes. Carries `requires` (attributes it demands of co-allocated resources) and `concurrency` (how many sessions may hold it at once, which is *not* `seats`).

* `Timetable.Place` — a containment tree of arbitrary depth, with `separation/2` measuring how far apart two places are in levels.

* `Timetable.Predicate` — the attribute vocabulary: `at_least/1`, `at_most/1`, `exactly/1`, `any_of/1`, `all_of/1`, `none_of/1`, mirroring Tempo's duration predicates.

* `Timetable.Requirement` — what a session demands, by attribute or by named roster. `unmet/2` returns the reasons a resource fails, so eligibility and its explanation are computed together rather than separately.

* `Timetable.Requirement.induce/2` — folds a resource's own requirements into a requirement, so a person needing step-free access constrains the room they are booked into.

* `Timetable.travel_time/3` — derives journey time from the place tree, with per-pair overrides. Unrelated places return `{:error, :unknown}` rather than a guessed duration.
