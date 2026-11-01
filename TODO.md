# TODO

The vocabulary review against iCalendar and CalDAV, with the reasoning for
each change and for each deliberate divergence, is in
[plans/icalendar-vocabulary.md](plans/icalendar-vocabulary.md). A rename is a
breaking change, recorded in the CHANGELOG for the next minor release.

## Open

* [ ] **Carry recurrence identity through `Agenda.Series`** — a master identity on the series and an instance identity on each expansion, so a round trip does not turn one weekly stand-up into fifty-two unrelated events. Touches `lib/agenda/series.ex`.

* [ ] **Adopt `CONCEPT` as the export of `Agenda.Track`** — keep the word `Track`; `CONCEPT` names the grouping, not the no-overlap rule, which export loses.

* [ ] **Record the mappings that already line up** — in the moduledocs: `precede/4`'s `:gap` is RFC 9253's `GAP` and `RELTYPE=FINISHTOSTART`; `open/2` is `VAVAILABILITY`'s `AVAILABLE` (export direction still unwritten); `Session.window` and `duration` are CalDAV `time-range` and `DURATION`; hold/confirm/cancel are `TENTATIVE`/`CONFIRMED`/`CANCELLED`; roster and invitees are `REQ-` and `OPT-PARTICIPANT`.

## Done

* [x] **Map `Agenda.Place` onto `VLOCATION`** — a `:location_type` field for `LOCATION-TYPE`, and the moduledoc records that the nesting, `separation/2` and `travel_time/3` do not survive export. 2026-11-01, v0.3.0 (unreleased).

* [x] **Give `Agenda.Resource` a calendar user type** — conventional `cutype:` and `resource_type:` attributes, read by `cutype/1` and `resource_type/1`; the moduledoc says a resource is never RFC 5545's `RESOURCES`. 2026-11-01, v0.3.0 (unreleased).

* [x] **Add `Agenda.cancel/2`** — the session-facing name for `release/2`, in `Agenda` and `Agenda.Ledger`; the guides cancel sessions with it. 2026-11-01, v0.3.0 (unreleased).

* [x] **Teach Agenda the busy-type distinction** — `Agenda.free_busy/2` gives `:busy` or `:tentative` with each interval; `busy/2` is unchanged for planning, and `BUSY-UNAVAILABLE` stays with `Availability`. 2026-11-01, v0.3.0 (unreleased).

* [x] **Rename `Allocation.role` to `Allocation.requirement`** — the field, the `:requirement` option of `claim/4` and `record/4`, and the prose. 2026-11-01, v0.3.0 (unreleased).
