# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

* Requires `ex_tempo ~> 1.3`, the first release carrying the RFC 7953 availability support `from_ical/1` is built on, and `ical ~> 3.2`, the first release that parses `VAVAILABILITY` at all.

### Fixed

* `buffer_before` and `buffer_after` now hold between two sessions the search places together, not only against bookings that already existed. A room needing ten minutes to reset could previously be handed back-to-back talks by `Agenda.Arranger.arrange/3`, which is the one thing the option exists to prevent. Candidate start times account for the turnaround too, so four forty-minute talks in such a room fall at 9:00, 9:50, 10:40 and 11:30 rather than losing a whole slot to the gap.

* `Agenda.Planner.plan/3` no longer reports a malformed resource as "no window is long enough with everyone free". An error computing a resource's availability — an unparseable buffer, a bad `:busy` value — was discarded and read as an absence of free time, sending the caller to look at their calendar instead of at their code. Absence of availability is still `{:ok, []}`; a configuration that will not compute is now returned as the error it is.

* A resource's `buffer_before` or `buffer_after` written as a string — `buffer_after: "PT10M"`, the spelling every other duration in the library accepts — raised a `FunctionClauseError` from inside `Tempo.shift/2` the first time that resource turned out to be busy. Buffers are now parsed when the resource is built, and a value that is not a duration is reported as `{:error, {:invalid_buffer, name, which, value}}` rather than crashing several frames away on a later call.

* `Agenda.Arranger.arrange/3` no longer reports a satisfiable programme as impossible. Both caps were fixed while the work they bound grows with the programme: `:candidates` at 40 made any programme of more than 40 interchangeable sessions unsatisfiable however long it searched, and `:nodes` at 10,000 ran out somewhere past 120 sessions. Both now scale with the session count, and the error says which cap was reached, since raising the wrong one only makes the same failure slower.

* The fixpoint solver tests no longer flake. `Agenda.Fixpoint.solve/3` returns whatever the search has when its budget expires, so a test asserting a definite answer was really asserting how much CPU the machine spared it — one instance was measured settling anywhere between 3.8 s and 24 s. They now run non-async, the instance that varied sixfold was narrowed to a smaller search space, budgets sit well clear of the worst observed time, and a timeout is retried with more clock rather than failing the build.

* Duration comparison and addition now come from `Tempo.Duration` rather than being hand-rolled. `Agenda.Limit` compared by converting both sides to seconds; `Agenda.Planner` picked the longest buffer by shifting a fabricated `2000-01-01` epoch and diffing, and added two durations by building a `%Tempo.Duration{}` struct by hand. All three are `compare/3` and `add/2`. Requires `ex_tempo ~> 1.5`.

* Weekly `:limits` follow each calendar's own convention, so a Hebrew resource's week runs Sunday to Saturday and a Gregorian one Monday to Sunday, over the very same span. Requires `calendrical ~> 1.3`, which supplies culturally-correct week starts for ten calendars; on earlier versions non-Gregorian calendars fall back to a Monday week.

* **Fixed:** a weekly `:limits` budget counted the wrong seven days for any calendar whose week does not start on Monday. `Agenda.Limit.bucket/2` took the boundary from `Date.beginning_of_week/1`, whose default is Monday, so a Sunday shift was charged to the preceding week under a Sunday-start convention. The boundary now comes from `Tempo.trunc/2`, which reads the week start from the value's own calendar. A bucket is `{year, month, day}` for every period, and calendars for which Calendrical defines no `week_of_year/3` — `Calendrical.Hebrew`, `Calendrical.Coptic` — bucket consistently instead of collapsing to `:undated`, where a weekly limit had behaved as a global one.

* `Agenda.Arrangement.resources/2` and `resource/2` read the resources filling one role. `resources/1` answers "who and what is booked"; these answer "what is in the room slot". Without them a caller reaches into `arrangement.allocations`, or hunts every resource for one carrying a `:seats` attribute — guessing at something a role already states.

* `Agenda.Arrangement.compare/2`, so `Enum.sort(arrangements, Agenda.Arrangement)` works the way it does for `Date`, `Time` and `Tempo`. Sorting a layout by time is the commonest thing anyone does with one, and it previously meant reaching through the arrangement to its interval and often to that interval's start. Ordering is by start then end — a total order, where `Tempo.relation/2` remains the way to reason about overlap.

* `Agenda.reconcile/3`'s `:by_tag` is an interval set per tag rather than a duration, making every field of the report the same kind of thing. It answers *which* hours went to a project — what an invoice line is made of — and `Tempo.duration/1` still recovers the total, where nothing recovers the hours from a total.

* `Agenda.reconcile/3`'s `:excluding` and `:expected` accept any Tempo value that denotes a span, a string, or a list of either, as their documentation already promised. A holiday is naturally written as the day it falls on — `excluding: ~o"2026-08-12"` — rather than as the half-open pair `2026-08-12/2026-08-13`.

* `Agenda.claim/4` books one resource over one interval and refuses what it cannot honour, naming the span that is not open or is already claimed.

* `Agenda.record/4` is its unchecked twin, writing down what happened without asking whether it was available. A schedule is a request and must be validated; a timesheet is a record, and refusing to write down a worked Saturday would leave the system unable to represent overtime. Both write the same shape to the same ledger, so a recorded hour blocks a later booking of it.

* `Agenda.Fixpoint.solve/3` enforces a resource's `:limits` instead of silently ignoring them. The bridge could return a layout the built-in search would reject — three shifts in a day that allows two — because limits never reached the model. Each ceiling is now a sum over `Element` indicators bounded by its budget, with claims already in `:busy` coming off that budget. Floors stay ignored, exactly as in `Agenda.Arranger`, so the two engines still agree.

* `Agenda.Fixpoint.solve/3` plans candidates with `spread: true`, matching `Agenda.Arranger`. A truncated candidate list was the earliest placements, which cluster into the first days of the window, so a resource limited per day could be offered candidates that never reach the later periods.

* `Agenda.Fixpoint.solve/3` returns `{:error, :timeout}` when the solver runs out of time, rather than the `Agenda.Infeasible` it previously gave. A timed-out search reports the same status as a proven-impossible one, so the two were indistinguishable and a satisfiable programme could be called impossible.

### Added

* Reconciliation. `Agenda.reconcile/3` compares what a resource claimed against what it owed over a period, returning `unaccounted` and `overclaimed` as interval sets rather than quantities — the missing Tuesday afternoon, not "5 hours short". Holidays are passed in through `:excluding` as ordinary interval sets, since this library does not resolve them.

* A claim tag. `Agenda.allocate/3` takes `:tag`, recording what time was for as `{:project, "ACME"}` or `{:leave, :annual}`, so work and absence share one ledger and one conflict check.

* Limits may measure duration, not only claims — `limits: [day: ~o"PT7H36M"]` — and may set a floor as well as a ceiling. Only ceilings constrain the search; a floor is a completion condition and is checked by `Agenda.reconcile/3`. See `Agenda.Limit`.

* Independent work now runs concurrently, across `System.schedulers_online/0` processes by default. Candidate enumeration parallelises for every programme and the disjoint subproblems parallelise when there are any, taking 240 sessions over six days from 4.6 seconds to 400 milliseconds and 1,200 over twenty days to under three. Set `:concurrency` per call or `config :agenda, concurrency:` for the application; results are collected in order, so the layout is the same at any setting.

* Sessions that cannot constrain each other are now solved as separate problems. A shared resource, track or precedence is what relates two sessions; without one they are independent, so a conference whose days share no room splits into one subproblem per day. This is exact — no layout is lost and `minimal?` still means proven — and it is skipped where preferences are declared, since those score a layout as a whole.

* `Agenda.Planner.plan/3` takes `:spread`, which round-robins the returned placements across distinct start moments instead of taking the best `:limit` of them. `arrange/3` uses it: a ranked prefix of 40 placements across ten rooms covers only the earliest four hours, so sessions were handed near-identical options and collided. The default is unchanged, since a caller picking one meeting time wants the best, not the broadest.

* `Agenda.Arranger.arrange/3` takes `unplaced: :allow`, which leaves out the fewest sessions it can rather than failing the whole programme, and returns a `Agenda.Layout` under a `{:partial, layout}` tag. Each unplaced session carries its own reason, and `{:ok, arrangements}` still means every session was placed.

* `Agenda.Arranger.arrange/3` takes `:pinned`, a list of arrangements whose placements are fixed while everything else is searched around them. `Agenda.Ledger.arrangements/3` rebuilds what is already booked into pinnable arrangements, and `Agenda.Ledger.busy/2`'s `:except` now accepts a list of session names.

* Precedence. `Agenda.precede/4` requires one session to finish before another starts, with an optional `:gap` and `:within` measured from the predecessor's end — which is what makes a task graph out of a set of tasks, and an interview loop out of two appointments. It is a pairwise constraint, so `Agenda.Arranger.conflict?/4` covers it and the fixpoint bridge enforces it too.

* Load limits. `Agenda.resource("Ann", limits: [day: 1, week: 5])` caps how often a resource may be claimed over a period. This is not concurrency: concurrency is how many claims may overlap at an instant, a limit is how many may fall inside a stretch of calendar however far apart. Claims already in `:busy` count, because no availability calculation can express "at most five this week".

* Per-resource wishes. `:avoids` and `:prefers` on a resource say when it would rather and rather not be used, and the `:resource_wishes` preference scores them. Unlike `open/2` these are wishes rather than rules — they make a placement worse, not impossible — so "Ann would rather not work Tuesdays" no longer has to be spelled as "Tuesday does not exist".

* Holds. `Agenda.hold/3` claims resources tentatively until a moment, `confirm/2` makes the claim firm, and `expire/2` drops what has lapsed. A hold consumes availability exactly as a booking does, which is why it lives in the ledger; nothing expires on its own, because `expire/2` takes the moment as an argument rather than reading a clock and so the ledger stays a value that answers the same question twice.

* Soft constraints. `Agenda.prefer/3` adds a weighted `Agenda.Preference` to a programme — `:room_changes`, `:room_spread`, or one of your own — and `arrange/3` prefers a lower-scoring layout among those it could already return. Optimisation is lexicographic and two-pass, so a preference can never cost a placement: `minimal?` still means proven, and the new `score_proven?` says whether the scoring pass finished. `Agenda.explain_score/3` breaks the total down per preference.

* `Agenda.Fixpoint.solve/3` hands a whole programme to the [fixpoint](https://hex.pm/packages/fixpoint) CP solver and takes the answer back as ordinary arrangements the ledger accepts. Each session becomes one variable over its candidate placements and each pair an `Element2D` conflict lookup, so eligibility, availability and the place tree stay on this side of the boundary where they are explained. Conflicts come from the new `Agenda.Arranger.conflict?/4`, which the built-in search uses too, so the two cannot disagree. Exclusive resources only, and all-or-nothing: concurrency above one is refused rather than mis-solved, because capacity is not a pairwise property and fixpoint has no cumulative constraint.

* `Agenda.from_ical/1` reads a resource's open hours from an RFC 7953 `VAVAILABILITY` — what a CalDAV server hands you when asked when someone is available. The result is a pattern for `open/2`, held unmaterialised until a query window is known, so `PRIORITY` and each `AVAILABLE` recurrence resolve against the window actually being asked about.

* `Agenda.Conflict.minimal/3` implements QuickXplain, finding the smallest set of constraints that still cannot hold together. `Agenda.conflict/3` applies it to a programme (which sessions cannot all be held) or a session (which demands are impossible together, including those induced by a rostered resource).

* `Agenda.Resource` honours `concurrency` — previously the field was accepted, documented, and enforced nowhere, so a twenty-locker bank went fully unavailable after one booking. A window is now unavailable only where overlapping claims reach the resource's concurrency.

* `buffer_before` and `buffer_after` on a resource — turnaround that is genuinely unavailable rather than something the caller must remember to leave free. A 30-minute claim with a 15-minute after-buffer blocks 45 minutes.

* `Agenda.every/3` expands a session over an ISO 8601 recurrence or RFC 5545 `RRULE` into one session per occurrence, sharing a `:series` name; `Agenda.release_series/3` cancels the run, or with `:from` only the part still ahead.

* `Agenda.only_during/2`, `during_any/2` and `lasting_at_least/2` — constraint composition, grouped-OR constraints, and minimum durations as named verbs. Each accepts a set or the `{:ok, set}` from a previous step, so refinements read as one sentence and still short-circuit on error.

* A timezone database is configured for development and test. Without one Elixir resolves every zone as UTC and daylight-saving arithmetic is silently wrong; consuming applications must configure their own, which the README now explains.

### Performance

* `Agenda.Arranger.arrange/3` searches by branch and bound rather than by iterative deepening on the number of sessions left out. Deepening found nothing at all until it reached the correct round, so a badly overbooked programme exhausted `:nodes` and returned an error where it could have returned most of a conference — twelve sessions competing for six slots now answers in 194 ms where it previously gave up. The search is also anytime, so hitting the cap returns the best layout found, flagged `minimal?: false`.

* A relaxation bound — the largest set of non-overlapping candidate placements each resource could hold, times its concurrency — lets the search stop as soon as a layout matches it, rather than exhaustively proving the point. Being further overbooked is now cheaper, not dearer: twenty sessions into six slots is faster than eight into six.

* `Agenda.Arranger.arrange/3` breaks symmetry between interchangeable sessions — same track, length, window, and requirements — by fixing a canonical chronological order among them. Proving a tight programme infeasible previously cost a factorial in the number of look-alike sessions: nine one-hour talks into eight hours took over 100 seconds and now takes 9 ms; seven into six went from 373 ms to 2 ms. No arrangement is lost, because interchangeable sessions can always be relabelled into the canonical order.

* `Agenda.Availability.free/2` collapses everything claiming a resource into one interval set before subtracting, rather than folding one sweep per claim. A resource with 800 prior bookings no longer pays 800 passes over its own open hours.

### Fixed

* A track whose `reachable/2` duration was written as a string rather than a Tempo value no longer crashes the search with a `FunctionClauseError` several frames deep. The pattern is resolved once when arranging begins, and one that is not a duration is an ordinary error tuple.

* Named resources are now recorded in the arrangement they were matched for. Previously a `roster/3` requirement was honoured when planning but never appeared in `allocations`, so the ledger did not know a named person or site was in use and would happily double-book them.

* A resource with no place no longer makes every journey unmeasurable. People and equipment travel with the session; only located resources count as a leg of a journey, so a track with named speakers is now reachable rather than always infeasible.

### Added

Phases 1 to 4 of the design — the model, matching, availability, single-session planning, the allocation ledger, and whole-programme arrangement. The AshScheduling adapter follows.

* `Agenda.Track` — sessions constrained against each other rather than against a resource. Not overlapping is intrinsic to being a track; `reachable/2` adds the requirement that a delegate can walk between consecutive sessions in the gap, derived from the place tree.

* `Agenda.Programme` — the whole layout: tracks, standalone sessions, and the span they fall inside.

* `Agenda.Arranger.arrange/3` — a placement for every session such that no resource is in two places at once, no track clashes with itself, and every consecutive pair is reachable. Depth-first with backtracking, ordered most-constrained first. Both the `:candidates` and `:nodes` caps report when they are hit rather than returning a partial programme as though it were finished.

* Three worked case-study guides — consultants on customer sites, meeting rooms with AV, and a two-day conference with parallel tracks. Every value shown in them is executed output, not illustration.


* `Agenda.Ledger` — what is allocated, keyed by the session holding it. `allocate/2` is idempotent, `release/2` frees everything a session held, and `busy/2` shapes the ledger for `plan/3` so planning and allocating compose into a loop.

* `Agenda.Ledger.diff/3` — what would change if a session moved, as `:keep` / `:release` / `:allocate`. A binding the new arrangement still wants is never released and re-allocated; that pair would hand the resource to a competing booking in the gap.

* `Agenda.Allocation` — one resource bound to one session over one interval.


* `Agenda.Session` — what is being scheduled: a duration, a window, requirements by attribute or by named roster, and soft preferences.

* `Agenda.Availability` — `open/2` accepts a Tempo value, an ISO 8601 string (preferred), or an RFC 5545 `RRULE`; `free/2` derives `open − busy` on demand, so free time can never go stale.

* `Agenda.Planner.plan/3` — ranks the ways a session could be held: attribute eligibility, then availability, then co-availability across the roster, then slotting, then preference ranking.

* `Agenda.Arrangement` and `Agenda.Infeasible` — a candidate placement, and a failure that always carries its reasons.

Phase 1:

* `Agenda.Resource` — named, allocatable things. People and rooms differ only in their attributes. Carries `requires` (attributes it demands of co-allocated resources) and `concurrency` (how many sessions may hold it at once, which is *not* `seats`).

* `Agenda.Place` — a containment tree of arbitrary depth, with `separation/2` measuring how far apart two places are in levels.

* `Agenda.Predicate` — the attribute vocabulary: `at_least/1`, `at_most/1`, `exactly/1`, `any_of/1`, `all_of/1`, `none_of/1`, mirroring Tempo's duration predicates.

* `Agenda.Requirement` — what a session demands, by attribute or by named roster. `unmet/2` returns the reasons a resource fails, so eligibility and its explanation are computed together rather than separately.

* `Agenda.Requirement.induce/2` — folds a resource's own requirements into a requirement, so a person needing step-free access constrains the room they are booked into.

* `Agenda.travel_time/3` — derives journey time from the place tree, with per-pair overrides. Unrelated places return `{:error, :unknown}` rather than a guessed duration.
