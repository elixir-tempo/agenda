# Calendar plugins — a discussion document

**Status: an assessment, not a design.** No prototype was built and none is proposed yet. Everything here about Microsoft's and Apple's programmes is from general knowledge and **must be checked against current vendor documentation before any of it is costed** — certification tiers, manifest formats and consent rules all move, and some of what follows will have moved since it was written.

The idea is to reach organisers where they already are rather than asking them to come to an API. That is a good instinct. The difficulty is that the surface a calendar plugin offers is a poor match for the half of Agenda that is worth anything, and it is better to know that before building a manifest.

## The framing that decides this

Outlook already has Suggested Times. It intersects attendee free/busy, filters rooms, and ranks the result — which is what `Agenda.plan/3` does. Our differentiated half is `arrange/3`: laying out *many* sessions together with tracks, precedence, load limits and travel.

**A meeting compose window has one meeting in it.** So the obvious plugin — a task pane in the compose window — puts us head to head with Microsoft on the one function they already ship, using only the part of the library that is not distinctive.

Two things could still make it worth doing, and they are the plan's real subject:

* **Explanations.** Outlook's answer to *"why can't I book this"* is a colour on a grid. Ours is a sentence naming the constraint and the session on the other side of it. That is a demo that needs no explanation, and it is available in a single-meeting surface.

* **A different job than the compose window.** Multi-session work that Outlook is genuinely bad at — an interview loop, a panel day, a series of site visits — is `arrange/3`'s home ground, and it can live in its own task pane rather than in the compose flow. **Interview scheduling is the strongest candidate**: it is precedence, rosters, optional attendees and travel at once, people pay for products that do it badly today, and it is a set of meetings rather than one.

If a plugin is built, it should be built for the second of those. Competing with Suggested Times on its own surface is not a plan.

## Outlook: what "plugin" actually means

The word covers several unrelated things and picking the wrong one wastes months.

* **Office Add-in (web).** HTML and JavaScript in a webview, declared by a manifest, running across Outlook on the web, new Outlook for Windows, Mac and mobile. This is the only path worth considering. Note that Microsoft has been migrating from the older XML manifest to a unified JSON manifest for Microsoft 365 — which of these is current, and which surfaces each supports, is the first thing to verify.

* **COM/VSTO add-in.** Windows-only, classic Outlook, and outside the direction of travel. Not a candidate.

* **Server-side integration via Graph.** Not a plugin at all: no UI, but no store review either. Worth keeping in mind as the fallback if the plugin path proves too costly, because most of the value is in the answer rather than the chrome.

### Where the availability comes from — the decision everything else follows from

There are two ways to get attendee free/busy, and the choice determines the security and privacy posture of the whole product.

**Option A — the add-in fetches, our API computes.** The add-in calls Microsoft Graph from the client with the user's own token, and posts the resulting free/busy to our API, which returns ranked times and explanations. We never hold a Graph token, never register for tenant-wide scopes, and see calendar data only in transit.

**Option B — our API calls Graph on the user's behalf.** Requires an on-behalf-of flow, token storage, refresh handling, and tenant-wide application permissions.

**Option A is strongly preferred and the rest of this document assumes it.** It keeps the service a pure function over data the customer already trusts the client with — which is the same stateless posture the [booking plan](booking.md) recommends, for the same reason: one person cannot carry the operational and audit weight of the alternative. Option B buys background processing and nothing else we need.

## Certification and consent — the real gate

This is where a single-person product most plausibly stalls, and it is not a technical problem.

* **App registration and scopes.** Reaching Graph needs an Entra ID application and permissions — calendars, and room lists if we filter rooms. Anything beyond the signed-in user's own data tends toward permissions that require an administrator's approval.

* **Admin consent.** In most enterprises an IT administrator must approve the add-in before anyone can use it. That is a sales gate disguised as a technical one: the buyer is now IT, not the organiser with the problem.

* **Publisher verification and AppSource review.** Listing publicly means passing Microsoft's validation — functionality, security, accessibility, privacy disclosures. Slow rather than hard.

* **Microsoft 365 Certification.** A separate, formal programme covering security controls, data handling and evidence of testing. Many enterprises will not grant consent without it. **This is the item to cost first**, because it is the one that can be genuinely out of reach for one person, and discovering that after building the add-in would be the expensive order to find out.

Two ways to soften it, both worth investigating before committing:

* **Org-only deployment.** A customer's admin can deploy an add-in to their own tenant without AppSource. Fewer gates, no listing, and it fits a business with a handful of customers rather than a funnel.

* **Stay out of Graph entirely.** If the add-in only reads the item being composed and the organiser pastes or picks participants, the permission surface shrinks dramatically. Weaker product, far lighter certification story — possibly the right first version.

## Security

* **No tokens at rest** under Option A, which removes the largest single class of incident.

* **Transient processing only.** Calendar data arrives in a request and is gone when the response is written. Nothing to breach, nothing to encrypt at rest, nothing to expire.

* **Logging is the trap.** Attendee addresses and meeting times in request logs are exactly the data we claimed not to keep. Logging must be deliberate from the first commit — identifiers hashed or absent, no request bodies — because retrofitting it after an audit question is far harder than starting that way.

* **Tenant isolation.** With no stored state there is little to isolate, which is the point. Any caching introduced later reintroduces the problem and should be treated as a significant change rather than an optimisation.

* **The add-in itself.** Webview code is delivered by us and runs inside the customer's client: a compromised bundle is a compromised calendar. Subresource integrity, a tight content security policy, and a dependency policy that resists casual additions.

## Privacy and data protection

* **We would be a processor, not a controller.** The customer's organisation owns the calendar data; we act on instruction. That means a data processing agreement, sub-processor disclosure, and a documented retention period — which, under Option A, is *zero*, and that is much easier to say than to argue.

* **Two regimes at least.** Australian Privacy Act obligations, and GDPR the moment a European organisation uses it. GDPR is the stricter and the one to design against.

* **Data residency.** European customers may require processing in the EU. For a single-person operation a second region is a real cost, and it is worth knowing whether the first customers will ask before assuming they will not.

* **Free/busy is more revealing than it looks.** Even without subjects, meeting patterns disclose reorganisations, deal timing and individuals' working hours. Treating it as ordinary telemetry would be a mistake, and *"we never store it"* is the only claim that is cheap to keep.

* **Explanations are a disclosure surface.** *"Alice cannot get into the attic"* is a statement about Alice. Our differentiator is, precisely, revealing why a person does not fit — worth thinking about before it is a support ticket.

## Apple Calendar: there is no plugin

Worth stating plainly, because the answer is not "harder", it is "not a category".

Apple Calendar has no add-in or extension model for scheduling assistance. Nothing corresponds to an Office Add-in. The realistic Apple-adjacent options are:

* **CalDAV interop.** Apple Calendar speaks CalDAV, and Agenda already reads RFC 7953 `VAVAILABILITY` through `Agenda.from_ical/1` — which is the availability primitive CalDAV servers publish. That is an integration story, not a plugin, and it is one we have already half-built.

* **A native macOS or iOS app** using EventKit. That is writing an application, not extending Calendar, and it is a different product with a different cost.

* **Nothing.** Defensible. Apple Calendar's users in the organiser role are a small population next to Outlook's.

**Recommendation: do not pursue an Apple Calendar plugin.** If Apple users matter, reach them through CalDAV and standards, which costs almost nothing extra given `from_ical/1` already exists.

## Google, which is the likelier second

Google Workspace has a genuine add-on model with a calendar surface, and its review and consent process is worth comparing directly against Microsoft's before assuming Outlook is the right first target. If Google's verification burden turns out materially lighter, it may be the better place to learn what the product should be — the same code, a cheaper mistake.

## What exists, and what is new

| Capability | Where it is | Status |
| --- | --- | --- |
| Ranking times for one meeting | `Agenda.plan/3` | Built |
| Required and optional participants | `roster/3`, `invite/3` | Built |
| Room requirements beyond capacity | `needs/3`, `Agenda.Predicate` | Built |
| Travel between rooms | `Place` tree, `travel_time/3` | Built |
| Why a time does not work | `Agenda.explain/1`, `conflict/3` | Built |
| Laying out a set of meetings | `arrange/3`, precedence, tracks | Built — **and has no compose-window surface** |
| Reading availability from CalDAV | `Agenda.from_ical/1` | Built — the Apple story |
| **A stateless HTTP API over the above** | — | **New — the prerequisite for any plugin** |
| **An Office Add-in and manifest** | — | **New** |
| **Entra ID registration, scopes, consent flow** | — | **New, and the gating item** |
| **DPA, sub-processor disclosure, retention statement** | — | **New, small but non-optional** |
| Microsoft 365 Certification | — | **Unknown cost — verify before committing** |
| Apple Calendar plugin | — | **Not a category; use CalDAV instead** |

## Open questions

* **Which surface?** A compose-window pane competes with Suggested Times using our weakest half. An interview-loop pane uses our strongest. These are different products with a shared engine, and choosing is the decision this document exists to force.

* **Can the first version avoid Graph entirely?** If the organiser supplies participants and the add-in reads only the item being composed, certification and consent get dramatically cheaper. Worth designing the smallest thing that still demonstrates the explanations.

* **Is the plugin a product or a demo?** It may be worth more as a thing to show a vendor — *"this is what your scheduling could say"* — than as a channel to organisers. That would change what it must be certified for, which is to say hardly at all.

## Suggested next step

Verify the gate before designing anything behind it. Two hours reading Microsoft's current add-in, consent and certification documentation will establish whether a single-person publisher can realistically clear tenant admin approval, and whether org-only deployment sidesteps it. If it cannot be cleared, the plugin is a demo for vendor conversations rather than a distribution channel — which is still useful, and much cheaper to build.

Nothing here should start before the API exists, because every version of this plan is a client of it.
