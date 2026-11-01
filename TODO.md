# TODO

The vocabulary review against iCalendar and CalDAV, with the reasoning for
each change and for each deliberate divergence, is in
[plans/icalendar-vocabulary.md](plans/icalendar-vocabulary.md). A rename is a
breaking change, recorded in the CHANGELOG for the next minor release.

## Done

* [x] **Record the mappings that already line up** — "In iCalendar" sections in the `Precedence`, `Availability`, `Session` and `Ledger` moduledocs; `Session.open_roles/1`, which the rename missed, is `open_requirements/1`. 2026-11-01, v0.3.0.

* [x] **Record `Agenda.Track`'s iCalendar export** — the moduledoc names RFC 9253's `REFID` for the grouping and a minted `CONCEPT` for the classification, and says the no-overlap rule is lost. 2026-11-01.

* [x] **Carry recurrence identity through `Agenda.Series`** — `series` is the run, and a new `recurrence_id`, the repetition's start, is the occurrence, carried through `Session`, `Arrangement` and `Allocation`. 2026-11-01, v0.3.0.

* [x] **Map `Agenda.Place` onto `VLOCATION`** — a `:location_type` field for `LOCATION-TYPE`, and the moduledoc records that the nesting, `separation/2` and `travel_time/3` do not survive export. 2026-11-01, v0.3.0.

* [x] **Give `Agenda.Resource` a calendar user type** — conventional `cutype:` and `resource_type:` attributes, read by `cutype/1` and `resource_type/1`; the moduledoc says a resource is never RFC 5545's `RESOURCES`. 2026-11-01, v0.3.0.

* [x] **Add `Agenda.cancel/2`** — the session-facing name for `release/2`, in `Agenda` and `Agenda.Ledger`; the guides cancel sessions with it. 2026-11-01, v0.3.0.

* [x] **Teach Agenda the busy-type distinction** — `Agenda.free_busy/2` gives `:busy` or `:tentative` with each interval; `busy/2` is unchanged for planning, and `BUSY-UNAVAILABLE` stays with `Availability`. 2026-11-01, v0.3.0.

* [x] **Rename `Allocation.role` to `Allocation.requirement`** — the field, the `:requirement` option of `claim/4` and `record/4`, and the prose. 2026-11-01, v0.3.0.
