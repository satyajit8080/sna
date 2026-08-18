# Deletion Candidates

Anything from SnapCal that must **not** be carried into BP Coach.

**Status:** COMPLETE — awaiting owner sign-off
**Audited commit SHA:** `db7c6281aee65c742826a446215c2c813011e109`

---

## 1. Discovered deletion candidates

| # | Path / component | Reason for deletion | Dependency impact | Replacement in BP Coach | Migration risk | Final decision |
|---|---|---|---|---|---|---|
| D1 | `backend/` — entire directory | Fastify + PostgreSQL service. BP Coach is local-first with no backend before Phase 14. | Nothing in the reuse list depends on it once A5's two `APIClient` calls are stripped. | None until Phase 14 caregiver backend | Copying any part invites a server dependency the privacy model forbids | **DO NOT CARRY** |
| D2 | `ios/SnapCal/Net/APIClient.swift` | Client for SnapCal's specific API; JWT auth, quotas, paywall errors | `HealthService` (A5) calls it at lines 129 and 149 — **must be severed at copy time** | None. Phase 14 starts clean. | Silent health-data transmission to a server | **DO NOT CARRY** |
| D3 | `ios/SnapCal/Net/Entitlements.swift` (568) | Subscription entitlement model | Referenced by `EntitlementStore`, `PaywallView`, `APIClient` | None — BP Coach has no paywall in Phases 0–14 | Drags in StoreKit and a purchase flow | **DELETE** |
| D4 | `ios/SnapCal/Net/Models.swift` (323) | Meal, macro and scan DTOs | Used across Confirm, Diary, Dashboard | BP Coach models, Phase 2 | Wrong domain; would contaminate the model layer | **DELETE** |
| D5 | `ios/SnapCal/Store/SubscriptionManager.swift`, `EntitlementStore.swift` | StoreKit purchase and entitlement handling | Paired with D3 | None | Out of scope | **DELETE** |
| D6 | `ios/SnapCal/Features/Paywall/PaywallView.swift` (289) | Subscription paywall | D3, D5 | None | Out of scope | **DELETE** |
| D7 | `ios/SnapCal/Features/Onboarding/` — all 5 files (1,786 lines) | Auth, fitness and calorie-goal onboarding | `AuthView` pulls Sign in with Apple; `HealthOnboardingView` is calorie-target driven | New guideline-centric onboarding, Phase 1 | Wrong first-run model entirely | **DELETE** |
| D8 | Sign in with Apple — `com.apple.developer.applesignin` in `SnapCal.entitlements` | BP Coach creates no accounts before Phase 14 | `AuthView`, `APIClient.signInWithApple` | None; Face ID / PIN instead, Phase 12 | Account creation triggers App Store account-deletion requirements | **DO NOT CARRY** |
| D9 | `ios/SnapCal/Core/Analytics/Analytics.swift` (80) | Event tracking | Called from `HealthService:requestAuthorization` — **strip when adapting A5** | None. Privacy rule: no unnecessary tracking. | Silent telemetry in a health app | **DELETE** |
| D10 | `ios/SnapCal/Features/Scan/`, `Barcode/`, `VoiceLog/`, `TextLog/` | Camera food capture, barcode, voice and text meal logging | `APIClient`, backend AI | Documents camera capture is separate and purpose-built, Phase 8 | Wrong domain; drags in the API client | **DELETE** |
| D11 | `ios/SnapCal/Features/Confirm/`, `Diary/`, `MealPlanner/`, `Workout/` | Calorie/macro domain UI (1,519 lines) | D4 | Lifestyle, Phase 6 | Wrong domain | **DELETE** |
| D12 | `ios/SnapCal/Features/Dashboard/`, `History/ProgressHubView.swift`, `Brain/`, `Coach/` | SnapCal's home, progress, insight and coach surfaces | `APIClient`, D4 | BP Coach Home (Phase 1), History (Phase 3), Coach (Phase 7) | Layout ideas may be worth *reading*; the code assumes calorie semantics | **DELETE** |
| D13 | `ios/SnapCal/Features/Notifications/` | Meal-reminder notification categories | `APIClient` | NotificationEngine, Phase 10 | Wrong categories; deep links point at meal screens | **DELETE** |
| D14 | `ios/SnapCal/App/RootView.swift`, `SnapCalApp.swift` | App lifecycle and tab navigation | Everything | New 5-tab navigation, Phase 1 | Master Prompt forbids importing SnapCal navigation | **DO NOT CARRY** |
| D15 | `ios/SnapCal/Store/AppState.swift`, `DashboardCache.swift` | Global state and dashboard cache | `APIClient`, D4 | New state layer, Phase 1–2 | Wrong domain | **DELETE** |
| D16 | `ios/SnapCal.xcodeproj/`, `ios/tools/generate_xcodeproj.py`, `validate_xcodeproj.py` | Generated project and generator scripts | — | Xcode-created `BPCoach.xcodeproj` | Master Prompt forbids hand-authored pbxproj; generator encodes SnapCal's file layout | **DO NOT CARRY** |
| D17 | `ios/Config/*.xcconfig`, `SnapCal.storekit` | API host config and StoreKit test data | D5, D6 | New xcconfig if needed | Contains `API_HOST` — BP Coach has no API | **DO NOT CARRY** |
| D18 | `codemagic.yaml` | CI pipeline gated on backend `/health` and TestFlight | Backend, App Store Connect keys | Deferred; not a Phase 0–14 deliverable | Pipeline fails without a backend | **DO NOT CARRY** |
| D19 | `ios/SnapCalTests/NutritionMathTests.swift` (985) | Calorie and macro maths tests | D4 | BP maths tests, Phase 2 | Wrong domain — but **read it**: it is the best evidence of Swift Testing conventions | **DELETE (read first)** |
| D20 | `ios/SnapCal/Resources/Assets.xcassets` | SnapCal palette, app icon, `DemoPlate` image | `Theme` | New asset catalogue, Phase 1 | Brand leakage; `DemoPlate` is food imagery | **DELETE** |
| D21 | `Theme.swift` font references to Plus Jakarta Sans | Fonts named but never bundled; no `UIAppFonts` key — silently falls back to system | A6 Theme adaptation | Bundle the OFL files and register, or use system fonts deliberately | Inheriting a latent bug that looks intentional | **RECONSIDER** — decide at Phase 1 |
| D22 | `.env.example`, `ARCHITECTURE.md`, `DESIGN_SPEC.md`, `FIGMA_HANDOFF.md`, `README.md` | SnapCal project documentation | — | BP Coach's own docs | Confusing provenance in a new repo | **DO NOT CARRY** |

**Field definitions**

| Field | Meaning |
|---|---|
| Path / component | Exact SnapCal path at the pinned commit |
| Reason for deletion | Why it must not cross over |
| Dependency impact | What depends on it; what breaks if a neighbour is copied without it |
| Replacement in BP Coach | The BP Coach service or feature covering the need |
| Migration risk | What goes wrong if it is copied anyway |
| Final decision | `DELETE` · `DO NOT CARRY` · `RECONSIDER` |

---

## 2. Sever-at-copy list

These are **not** deletions of whole files — they are edits required *at the moment* A5 and
A6 are copied. Missing one silently violates a BP Coach invariant.

| Source | Line | Action |
|---|---|---|
| `HealthService.swift` | 129 | Remove `APIClient.shared.syncHealth(...)` — transmits health data off-device |
| `HealthService.swift` | 149 | Remove `APIClient.shared.sendObservations(...)` — same |
| `HealthService.swift` | ~74 | Remove `Analytics.track(.healthkitConnected)` |
| `HealthService.swift` | 14 | Replace `static let shared` singleton with owner-profile scoping |
| `HealthService.swift` | 55–65 | Add `bloodPressureSystolic` / `bloodPressureDiastolic` read types |
| `HealthService.swift` | 304 | Rewrite user-facing string — names SnapCal |
| `Keychain.swift` | 6 | Change service from `app.snapcal.ios` to the BP Coach bundle ID |
| `Theme.swift` | 17–19 | Remove `protein` / `carbs` / `fat` colours; replace with guideline-driven status colours |
| `Theme.swift` | 72–82 | Resolve the font defect — see D21 |

---

## 3. Categorical exclusions — policy

Reject on sight; no audit record required.

| Category | Reason |
|---|---|
| Navigation / routing | BP Coach has its own 5-tab model |
| App lifecycle, scene setup | New app |
| Calorie / macro / weight-loss models | Wrong domain |
| Paywall, subscription, entitlements | Out of scope, Phases 0–14 |
| Analytics, telemetry, crash SDKs | No unnecessary tracking |
| Ads | Product rule |
| Marketing copy, brand assets, store strings | Different product |
| Bundle ID, entitlements, provisioning | New identity required |
| Any shipped string naming SnapCal | Leaks the donor app |

---

## 4. Product-rule exclusions

Never permitted, from any source.

| Item | Rule violated |
|---|---|
| Hard-coded BP thresholds outside the guideline engine | Clinical authority |
| Category labels taken from the design boards | Boards are visual-only |
| Design-reference PNGs in any app target | Never bundled |
| Any AI path reaching an urgency decision | AI never decides urgency |
| Any recommendation to start/stop/change medication | Absolute prohibition |
| HealthKit reads assigned to non-owner profiles | Owner-isolation invariant |
| Full-database dumps into AI context | Structured context layer only |
| Fabricated values for unreadable document fields | Never invent health data |
| Caregiver sharing UI implying a working backend | Never fake it |
| Claims that Apple Watch measures BP | Only if Apple supports it |
| API keys, tokens or secrets in the repository | Security |

---

## 5. Phase-gate sweep

Check at the end of **every** phase.

- [ ] Stubbed functions returning plausible fake data
- [ ] Sample or preview data reachable from a release build
- [ ] Disabled, skipped or expected-failure tests used to pass a gate
- [ ] `TODO` standing in for a feature claimed complete
- [ ] Placeholder numbers where data is genuinely absent
- [ ] Commented-out SnapCal code carried "just in case"
- [ ] Unused SnapCal helpers pulled in as transitive baggage
- [ ] Third-party dependencies added without owner approval
- [ ] `design-reference/` PNGs present in the built `.app`
- [ ] `grep -ri snapcal` across the repo returns only audit documentation

---

## 6. Review

- [ ] Discovered rows D1–D22 reviewed
- [ ] Sever-at-copy list accepted
- [ ] D21 font decision made

**Reviewed by:** ______________  **Date:** ____________
