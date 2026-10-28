# TODO

The vocabulary review against iCalendar and CalDAV, with the reasoning for
each change and for each deliberate divergence, is in
[plans/icalendar-vocabulary.md](plans/icalendar-vocabulary.md). Agenda is at
0.1.0, so a rename costs a CHANGELOG line and nothing else.

## Open

* [ ] **Rename `Allocation.role` to `Allocation.requirement`** — Agenda's `role` names which requirement a resource satisfies; iCalendar's `ROLE` names how much a participant matters. Touches `lib/agenda/allocation.ex`, `lib/agenda/arrangement.ex` and the prose in `lib/agenda.ex` and `plans/agenda.md`.

* [ ] **Teach `Agenda.busy/2` the busy-type distinction** — return `BUSY` / `BUSY-TENTATIVE` / `BUSY-UNAVAILABLE` alongside each interval, or select by a `:type` option, instead of discarding `held_until` in `Ledger.busy/2`.

* [ ] **Add `Agenda.cancel/2`** — the session-facing name for `release/2`, completing the hold/confirm/cancel trio; keep `release/2` and delegate.

* [ ] **Give `Agenda.Resource` a `cutype:` attribute** — `INDIVIDUAL|GROUP|RESOURCE|ROOM` for invitable resources and RFC 9073 `RESOURCE-TYPE` for equipment; document that an Agenda resource is never RFC 5545's free-text `RESOURCES`.

* [ ] **Map `Agenda.Place` onto `VLOCATION` and record what is lost** — `LOCATION-TYPE` as the conventional attribute; `within` and `travel_time/3` do not survive a round trip because `VLOCATION` does not nest.

* [ ] **Carry recurrence identity through `Agenda.Series`** — a master identity on the series and an instance identity on each expansion, so a round trip does not turn one weekly stand-up into fifty-two unrelated events. Touches `lib/agenda/series.ex`.

* [ ] **Adopt `CONCEPT` as the export of `Agenda.Track`** — keep the word `Track`; `CONCEPT` names the grouping, not the no-overlap rule, which export loses.

* [ ] **Record the mappings that already line up** — in the moduledocs: `precede/4`'s `:gap` is RFC 9253's `GAP` and `RELTYPE=FINISHTOSTART`; `open/2` is `VAVAILABILITY`'s `AVAILABLE` (export direction still unwritten); `Session.window` and `duration` are CalDAV `time-range` and `DURATION`; hold/confirm/release are `TENTATIVE`/`CONFIRMED`/`CANCELLED`; roster and invitees are `REQ-` and `OPT-PARTICIPANT`.
