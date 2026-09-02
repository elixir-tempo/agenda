# TODO

## Vocabulary alignment with iCalendar and CalDAV

Agenda's lexicon was chosen in [plans/agenda.md](plans/agenda.md) to dodge collisions with Elixir's stdlib, Tempo and the Ash scheduling library. That constraint still governs: where the two pull in different directions, the collision wins and the RFC loses. What follows is a review of the remaining terms against the vendored specifications — RFC 5545 (iCalendar), RFC 5546 (iTIP), RFC 4791 (CalDAV), RFC 6638 (CalDAV scheduling), RFC 7953 (`VAVAILABILITY`), RFC 7986 (new calendar properties), RFC 9073 (event publishing extensions) and RFC 9253 (relationships) — sorted into what already lines up, what is worth changing, and what should stay divergent with the reason recorded so it is not re-litigated.

Agenda is at 0.1.0, so a rename costs a CHANGELOG line and nothing else. That is the cheapest this will ever be.

### Already aligned — record the mapping, change nothing

* `Agenda.precede/4`'s `:gap` option is RFC 9253's `GAP` parameter under the same name, and the relation itself is `RELATED-TO;RELTYPE=FINISHTOSTART`. This is an exact match arrived at independently; say so in `Agenda.Precedence`'s moduledoc before someone "improves" the option name.

* `Agenda.open/2` is RFC 7953's `AVAILABLE` inside a `VAVAILABILITY`, which `Agenda.from_ical/1` already imports. The import direction is done; the export direction is not written down anywhere.

* `Agenda.Session.window` is CalDAV's `time-range` and `Agenda.Session.duration` is `DURATION`. No change.

* `Agenda.hold/3`, `confirm/2` and `release/2` line up with `STATUS:TENTATIVE`, `STATUS:CONFIRMED` and `STATUS:CANCELLED` — see the naming note below, but the concepts match one for one.

* **Required and optional attendance is already the roster/invitee split.** `Requirement.roster/2` gates feasibility and is allocated; `Session.invite/3` names resources who only make a time score better and are deliberately not allocated. That is `ATTENDEE;ROLE=REQ-PARTICIPANT` and `ATTENDEE;ROLE=OPT-PARTICIPANT`, and the reasoning in `Agenda.Session.invite/3`'s docs — that an optional attendee which can cost a placement is not optional — is a sharper statement of the distinction than RFC 5545 makes. `Arrangement.attending` has no iCalendar counterpart: it records which invitees a candidate time suits, which is a planning output rather than a calendar fact, and the nearest thing after the event is `PARTSTAT=ACCEPTED`.

### Recommended changes

1. **Rename `Allocation.role` to `Allocation.requirement`, and stop calling the key a "role".** Agenda's `role` is `:room`, `:attendees`, `:presenter` — *which requirement a resource satisfies*. iCalendar's `ROLE` is `CHAIR` / `REQ-PARTICIPANT` / `OPT-PARTICIPANT` / `NON-PARTICIPANT` — *how much a participant's presence matters*. The two are different axes that will appear in the same line of adapter code the moment anything writes `ATTENDEE;ROLE=`, and a reader arriving from iCalendar will read Agenda's `role` as the other thing. The collision is already visible in the library: `Agenda.Session.invite/3`'s own doctest is `invite(session, :optional, [bob])`, where an argument named `role` is passed a literal iCalendar `ROLE` value — and means something else by it, since optionality there comes from being an invitee rather than from the atom. `requirement` is precise, is already the word for the thing being satisfied (`Session.requirements`, `Agenda.needs/2`), and makes `Arrangement.allocations` read as "a resource for every requirement". Touches `lib/agenda/allocation.ex`, `lib/agenda/arrangement.ex`, and the prose in `lib/agenda.ex` and `plans/agenda.md`. The alternative — keep `role` and reserve `participation` for the iCalendar axis — is cheaper but leaves the trap in place.

2. **Teach `Agenda.busy/2` the distinction iCalendar already names.** `Ledger.busy/2` groups holds and firm allocations into one list of intervals, discarding the `held_until` that separates them. RFC 5545's `FBTYPE` and RFC 7953's `BUSYTYPE` both distinguish `BUSY` from `BUSY-TENTATIVE`, and `BUSY-UNAVAILABLE` covers time outside a resource's `open` hours. Returning the type alongside the interval — or a `:type` option to select — is worth having whether or not anything is ever exported: a caller planning around somebody else's tentative hold should be able to see that it is tentative. Touches `lib/agenda/ledger.ex:859`.

3. **Add `Agenda.cancel/2` as the session-facing name for `release/2`.** `release` describes what happens to the *resources*; the calendar word for what happens to the *session* is cancelled, and hold/confirm/cancel is the trio every calendar UI already uses. Keep `release/2` — it is the right word from the ledger's side — and delegate. Touches `lib/agenda.ex` and `lib/agenda/ledger.ex`.

4. **Give `Agenda.Resource` a conventional attribute for its calendar user type.** An Agenda resource is `ATTENDEE;CUTYPE=INDIVIDUAL|GROUP|RESOURCE|ROOM` for anything that can accept an invitation, and RFC 9073's `VRESOURCE` with `RESOURCE-TYPE` (`ROOM`, `PROJECTOR`, `REMOTE-CONFERENCE-AUDIO`, `REMOTE-CONFERENCE-VIDEO`) for equipment that cannot. A conventional `cutype:` attribute makes the adapter mechanical instead of heuristic. Record in the same moduledoc that an Agenda resource is **never** RFC 5545's `RESOURCES` property: that is free text on an event, cannot be booked, and cannot be checked for conflicts — the similarity of the names is the whole reason to say so.

5. **Map `Agenda.Place` onto RFC 9073's `VLOCATION` and record what is lost.** `LOCATION-TYPE` is the natural conventional attribute for a place. `within` has no equivalent — `VLOCATION` does not nest — so any export flattens the tree to the nearest named ancestor, and `travel_time/3`, which is derived from the nesting, does not survive the round trip at all. Better to write that down than to have it discovered.

6. **Carry recurrence identity through `Agenda.Series`.** `Series.expand/3` materialises a recurrence into N independent sessions. iCalendar keeps one component with an `RRULE` plus overrides keyed by `RECURRENCE-ID`, and CalDAV stores the whole set as one calendar object resource. Without a master identity on the series and an instance identity on each expansion, a round trip turns one weekly stand-up into fifty-two unrelated events — and `release_series/3`, which already knows a series is one thing, is the evidence that the identity exists and is simply not written down. Touches `lib/agenda/series.ex`.

7. **Adopt `CONCEPT` as the export of `Agenda.Track`.** RFC 9253's `CONCEPT` (or RFC 7986's `CATEGORIES`, which is weaker) is the closest iCalendar has to a named grouping of sessions. The *constraint* a track carries — that its sessions must not overlap each other — has no iCalendar expression at all, so export loses it. Keep the word `Track`: `CONCEPT` names the grouping, not the rule.

### Deliberate divergences to keep

* **`Session`, not `Event`.** Already decided (`Tempo.Event.Easter` exists, and event-sourcing besides). `Session` maps to `VEVENT`; note it and move on.

* **`Programme` is a CalDAV *calendar collection*, not a `VCALENDAR`.** A `VCALENDAR` is the serialisation envelope around one object; the thing Agenda lays out is the collection. Getting this backwards in an adapter would put every session in one file.

* **`roster` is not `MEMBER`.** iCalendar's `MEMBER` is group membership of a calendar user — Alice is in the sales group. Agenda's roster is the named resources a requirement will accept for one session. Same shape, unrelated meaning.

* **`Agenda.Limit` is not CalDAV's limits.** CalDAV's `max-attendees-per-instance`, `max-instances` and `max-resource-size` bound what a *server* will store. Agenda's `Limit` bounds how much of a resource may or must be claimed over a period — a scheduling constraint, not a storage one.

* **`Track`, `Programme`, `Arrangement`, `Ledger`, `Layout`, `Conflict`, `Preference`, `Reconciliation` and `Infeasible` have no iCalendar counterparts** and should not acquire invented ones. iCalendar describes calendars; it has no vocabulary for laying one out, for why a layout failed, or for what makes one better than another. That absence is the reason the library exists.

### Gaps worth noting in both directions

* **Agenda has one ordering relation where RFC 9253 has four.** `precede` is `FINISHTOSTART`; `STARTTOSTART`, `FINISHTOFINISH` and `STARTTOFINISH` have no Agenda expression. `Tempo.Network`'s relation vocabulary is Allen's interval algebra (`:before`, `:overlaps`, `:starts_during`, …), which relates whole intervals rather than the endpoint pairs RFC 9253 names, so the four are a constraint the STP layer underneath can carry but the relation vocabulary does not name.

* **iCalendar has no word for a hold that expires.** `held_until` is Agenda's own; `STATUS:TENTATIVE` says a session is provisional but not until when. Any export drops the expiry, and `Agenda.expire/2` has no counterpart on the other side.

* **`Agenda.Interest` is nearest to RFC 9073's `PARTICIPANT`,** but `PARTICIPANT-TYPE` values (`ACTIVE`, `SPONSOR`, `SPEAKER`, `CONTACT`, …) describe what someone *is* at an event rather than who they would like to meet. The match is weak enough that borrowing the word would mislead.
