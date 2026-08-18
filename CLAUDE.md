# CLAUDE.md — BP Coach

> Read this file first in every Claude Code session, together with `docs/IMPLEMENTATION_LOG.md`.

## Status

- **Current phase:** 0 — in progress
- **Branch:** `bp-coach`
- **Phase 0 complete:** NO

## ⚠️ Unverified values — must be filled by running the commands in `docs/phases/PHASE_00.md`

Nothing below has been verified. Do not use any of these values until the corresponding
command has actually been run on macOS and its real output pasted in.

| Item | Value | Verified? |
|---|---|---|
| Xcode version | _not yet run_ | ❌ |
| Swift toolchain version | _not yet run_ | ❌ |
| Project path | _not yet created_ | ❌ |
| Scheme name | _not yet discovered_ | ❌ |
| Simulator destination | _not yet discovered_ | ❌ |
| Build command | _not yet verified_ | ❌ |
| Test command | _not yet verified_ | ❌ |
| Bundle identifier | _not yet set_ | ❌ |
| Deployment target | 17.0 decided — **compile verification outstanding** | ❌ |

**Rule:** if a row above is ❌, Claude Code must not claim a build or test result.

## Confirmed project decisions

| Setting | Value | Status |
|---|---|---|
| UI framework | SwiftUI only | Owner-approved |
| Charts | Swift Charts | Owner-approved |
| Third-party dependencies | None without owner approval | Owner-approved |
| Branch policy | `bp-coach`, never land on `main` | Owner-approved |
| BP units | mmHg | Owner-approved |
| Sodium units | mg | Owner-approved |
| Weight units | Device locale | Owner-approved |
| Deep link scheme | `bpcoach://` | Owner-approved |

## Owner decisions — RECORDED 2026-08-17

All eight decisions below are **owner-approved and final** unless a compile disproves one.

| # | Decision | Value | Basis |
|---|---|---|---|
| 1 | SnapCal salvage | COPY `Haptics`, `Keychain`. ADAPT `HealthService`, `Theme`. REJECT everything else. | Audit A1–A6 |
| 2 | Deployment target | **iOS 17.0** — unless compilation proves a required API forces 18.0 | Audit §5; must be verified by compiling, not inspection |
| 3 | Persistence | **SwiftData**, local-first. No Core Data without a concrete technical requirement. | Audit A5 — no persistence coupling found |
| 4 | Fonts | **System fonts.** Do not bundle Plus Jakarta Sans in Phase 0. | D21 |
| 5 | Sodium / food data | SnapCal provides **no** sodium infrastructure. Logged as a new-data-source requirement for Phase 6. | Audit A2 |
| 6 | Blood pressure | SnapCal has **no** BP implementation. BP Coach builds its own model, readings, pulse, timestamps, history, trends, HealthKit integration, manual entry and coaching logic. | Audit A5 |
| 7 | HealthKit privacy | **`HealthKit → BP Coach → SwiftData`.** Never `HealthKit → server`. The two `APIClient` calls in `HealthService` are removed at copy time. Any future server path requires an explicitly justified, documented, privacy-reviewed requirement. | Audit A5, lines 129 and 149 |
| 8 | Framing | BP Coach is a **new application**, not a SnapCal fork. | Master Prompt |

### Carried forward as requirements

- **Phase 6 — new data source required.** No sodium dataset exists in SnapCal. `sodium` is a
  transient USDA API field; `food_database` has no sodium column. Phase 6 must select and
  licence its own food/sodium source. Do not plan against SnapCal.
- **Phase 2 — BP model is greenfield.** No prior art to adapt.
- **Phase 4 — HealthKit BP types must be added.** `bloodPressureSystolic` / `bloodPressureDiastolic`
  are absent from the donor wrapper.
- **Phase 2 — verify iOS 17.0 by compiling** the adapted `HealthService`. If it fails, raise the
  target to 18.0 and record why.

## Superseded — resolved

1. ~~Persistence: SwiftData vs Core Data~~ → decision 3 above.
2. **AI provider:** still open. Phase 7. No provider, SDK or key before then.
3. **Bundle identifier:** owner must supply the reverse-DNS prefix. **STILL OPEN.**
4. ~~Minimum iOS~~ → decision 2 above; pending compile verification.
5. ~~Font~~ → decision 4 above.

## SnapCal audit outcome — commit `db7c6281`

| Component | Verdict |
|---|---|
| Food database | REJECT — server-side PostgreSQL, no sodium column |
| Sodium data | REJECT — does not exist; never persisted |
| NL meal parsing | REJECT — backend LLM call, no on-device parser |
| AI / networking | REJECT for Phases 0–6; reconsider at 7 and 14 |
| **HealthKit wrapper** | **ADAPT** — `Features/Health/HealthService.swift` |
| **Haptics, Keychain** | **COPY** — `Core/Haptics.swift`, `Core/Keychain.swift` |
| **Theme** | **ADAPT** — `Core/Theme.swift`, palette replaced |

~390 of 9,800 iOS lines are worth carrying. **Nothing copied yet — owner sign-off pending.**
Sever-at-copy edits are mandatory: see `DELETION_CANDIDATES.md` §2.

## Documentation

| File | Purpose |
|---|---|
| `docs/DEPLOYMENT.md` | Deploying: architecture, stage-by-stage runbook, env vars, troubleshooting |
| `docs/TESTFLIGHT.md` | Signing, App Store Connect, and distributing builds |
| `docs/DEVELOPMENT.md` | Day-to-day: local setup, conventions, testing, debugging |
| `docs/IMPLEMENTATION_LOG.md` | What shipped per phase, what was deferred |
| `docs/SNAPCAL_AUDIT.md` | Reuse audit against commit db7c6281 |
| `docs/DELETION_CANDIDATES.md` | What must not be carried over |

## Architecture

Features: Home, History, Add, Coach, Medications, Lifestyle, Documents, Reports,
Appointments, Safety, Settings, Profile.

Services: BPEngine, GuidelineEngine, HealthKitService, MedicationEngine,
NotificationEngine, AIContextEngine, DocumentEngine, ReportEngine, Persistence, Security.

Dependency direction: features → services. Services never import features.
Features never import each other.

## Invariants

- Clinical categories come only from the active `BPGuideline`. Never from the design boards.
- Urgency decisions are deterministic. The AI never decides urgency.
- HealthKit data belongs to the owner profile only. Enforced at the persistence layer.
- Every model carries a `profileID`. Profiles never mix in any read path.
- No fake UI, APIs, Bluetooth, HealthKit, AI, or notifications.
- Design-reference PNGs are never bundled into the app.

## Session protocol

1. Read this file and `docs/IMPLEMENTATION_LOG.md`.
2. State the phase being executed and what the previous phase left open.
3. Confirm the verified build command above is filled in.
4. Work only within that phase.
5. Complete the phase gate in `docs/phases/`, then stop.
