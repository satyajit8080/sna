# SnapCal Reuse Audit

**Status:** COMPLETE — awaiting owner sign-off
**Repository:** `https://github.com/satyajit8080/sna` (public)
**Audited commit SHA:** `db7c6281aee65c742826a446215c2c813011e109`
**Commit date:** Mon 17 Aug 2026 19:34:56 +0530 — *"Merge remote-tracking branch 'origin/healthkit-entitlements'"*
**Working tree at audit:** clean
**Method:** static read-only inspection. **Not compiled, not run, not tested.**

---

## 1. Rules

- Reuse is copy-in, never link-out. No submodule, no shared package, no remote.
- Reject is the default. The burden is on justifying reuse.
- **No file is copied until the owner signs section 6.**
- Licensing or data-ownership uncertainty is REJECT until resolved.

---

## 2. What SnapCal actually is

This materially affects every verdict below.

SnapCal is a **thin SwiftUI client over a server-side product**. The iOS app is 40 Swift
files, roughly 9,800 lines. It holds no food data, performs no nutrition computation, and
does no natural-language parsing. All of that lives in a Fastify + PostgreSQL backend that
calls OpenAI/Gemini and fetches from USDA FDC and Open Food Facts.

| Fact | Value | Consequence for BP Coach |
|---|---|---|
| iOS deployment target | **18.0** (`ios/Config/Base.xcconfig:9`) | Our 17.0 default is below SnapCal's floor. See §5. |
| Third-party dependencies | **None** — no SPM packages, no CocoaPods | Good. Nothing to inherit. |
| Test framework | Swift Testing (`SnapCalTests/NutritionMathTests.swift`, 985 lines) | Confirms Swift Testing is viable on the toolchain. |
| `.xcodeproj` generation | Python scripts, `ios/tools/generate_xcodeproj.py` | Relevant to the Phase 13 target rule. |
| Repository licence | **No LICENSE file** | Owner-owned; note for any third-party data. |
| Architecture | Client → own API → OpenAI/Gemini, USDA, Open Food Facts | Conflicts with BP Coach local-first. |

---

## 3. Audit records

### A1 — Food database

| Field | Value |
|---|---|
| Source path | `backend/migrations/0001_init.sql` (schema), `0003_seed_regional.sql`, `0008_seed_north_america.sql` |
| Component | Food database |
| Purpose | PostgreSQL `food_database` table; nutrition lookup for meal logging |
| Dependencies | PostgreSQL with `pg_trgm`; USDA FDC API key; Open Food Facts; the whole Fastify service |
| Data ownership | 82 curated seed rows are owner-authored. Everything else is fetched at runtime from USDA FDC (public domain) and Open Food Facts (**ODbL — share-alike**) |
| Licensing considerations | ODbL on Open Food Facts imposes attribution and share-alike on derived databases. USDA FDC is public domain. Runtime-fetched rows mix both. |
| Adaptation required | Total rewrite. There is no on-device dataset to copy; it would have to be exported, filtered, de-duplicated, licence-separated and shipped as a bundled store. |
| **Verdict** | **REJECT** |
| Rationale | Server-side by construction, and **the schema has no sodium column** — see A2. Nothing here serves a local-first BP app. |
| Blocks | Phase 6 must source its own food/sodium data |

---

### A2 — Sodium data

| Field | Value |
|---|---|
| Source path | `backend/src/nutrition/usda.ts:13,25,73`; `backend/src/routes/food.ts:283` |
| Component | Sodium data |
| Purpose | Maps USDA nutrient ID 1093 into a `sodium_100g` response field |
| Dependencies | USDA FDC API |
| Data ownership | USDA FDC — public domain |
| Licensing considerations | None blocking |
| Adaptation required | N/A |
| **Verdict** | **REJECT — the asset does not exist** |
| Rationale | **`sodium` appears in zero migrations.** It is never persisted. It is a transient field read from a USDA API response and passed straight through to the client. There is no sodium dataset in this repository to reuse. The iOS app contains no reference to sodium at all. |
| Blocks | **Phase 6 has no sodium source.** The largest gap the audit found. |

---

### A3 — Natural-language meal parsing

| Field | Value |
|---|---|
| Source path | `backend/src/ai/` (`index.ts`, `openai.ts`, `gemini.ts`, `openrouter.ts`); client at `ios/SnapCal/Features/TextLog/TextLogView.swift` (67 lines) |
| Component | Natural-language meal parsing |
| Purpose | Converts free text or voice into structured meal items |
| Dependencies | OpenAI or Gemini API key, server-side; the Fastify service |
| Data ownership | Prompts are owner-authored |
| Licensing considerations | Provider terms apply |
| Adaptation required | Complete. `TextLogView` is a text field that POSTs to the API — 67 lines with no parsing logic in it. |
| **Verdict** | **REJECT** |
| Rationale | There is no on-device parser. The capability is an LLM call behind a backend BP Coach does not have and will not have before Phase 14. The prompt design may be worth *reading* at Phase 6/7; no file is worth copying. |
| Blocks | Phase 6 sodium estimation, Phase 7 |

---

### A4 — AI / networking infrastructure

| Field | Value |
|---|---|
| Source path | `ios/SnapCal/Net/APIClient.swift` (551), `Net/Entitlements.swift` (568), `Net/Models.swift` (323) |
| Component | AI / networking infrastructure |
| Purpose | Authenticated JSON client for SnapCal's own API |
| Dependencies | `Keychain` (auth token), Sign in with Apple, JWT bearer auth, StoreKit entitlements, SnapCal's error domain and quota model |
| Data ownership | Owner-authored |
| Licensing considerations | None |
| Adaptation required | Effectively a rewrite. The error taxonomy alone encodes `scanLimitReached`, `premiumRequired`, `proRequired`, `noFoodDetected` — SnapCal product semantics, not transport concerns. |
| **Verdict** | **REJECT for Phases 0–6. RECONSIDER as reference at Phases 7 and 14.** |
| Rationale | This is a client for *a specific backend*. BP Coach has no backend until Phase 14 and no AI provider until Phase 7. Copying it now would import an auth system, a paywall and a quota model BP Coach has no use for — and would quietly contradict the local-first rule. |
| Blocks | Nothing. Phases 7 and 14 start clean. |

---

### A5 — HealthKit wrapper

| Field | Value |
|---|---|
| Source path | `ios/SnapCal/Features/Health/HealthService.swift` (343 lines) |
| Component | HealthKit wrapper |
| Purpose | Read-only HealthKit bridge for steps, active energy, exercise minutes, distance, resting HR, HRV, sleep |
| Dependencies | `HealthKit`, `SwiftUI`, `Observation`. **No persistence framework.** `UserDefaults` for two boolean flags (`health.requested`, `health.hasData`). Calls `APIClient.shared.syncHealth` (line 129) and `sendObservations` (line 149). References `Analytics.track`. |
| Data ownership | Owner-authored |
| Licensing considerations | None |
| Adaptation required | **Moderate.** Strip both `APIClient` calls and `Analytics`. Add `HKQuantityType(.bloodPressureSystolic)` and `.bloodPressureDiastolic` — **absent; `bloodPressure` appears nowhere in the iOS source**. Replace the `shared` singleton with owner-profile scoping. Retain the read-only posture and the `hasData` heuristic. |
| **Verdict** | **ADAPT** |
| Rationale | The only genuinely valuable component in the audit. The permission handling, observer-query setup, and the comment explaining why HealthKit never reports read-denial encode real hard-won knowledge. Uses `@Observable` and `@MainActor` correctly. Background-delivery entitlement already proven in `SnapCal.entitlements`. |
| **Unblocks** | **Persistence decision — see §4.** |

> ⚠️ The two `APIClient` calls transmit health data to a server. Carrying them across would
> directly violate BP Coach's local-first rule. They must be removed at copy time, not later.

---

### A6 — Generic UI components

| Field | Value |
|---|---|
| Source path | `ios/SnapCal/Core/Theme.swift` (171), `Core/Haptics.swift` (12), `Core/Keychain.swift` (35) |
| Component | Generic UI and core utilities |
| Purpose | Design tokens, haptic helpers, Keychain wrapper |
| Dependencies | `SwiftUI`, `UIKit`, `Security`. No SnapCal domain imports. |
| Data ownership | Owner-authored. Palette derived from a Figma file. |
| Licensing considerations | None for the code. Plus Jakarta Sans is OFL — see the defect note. |
| Adaptation required | **Low.** `Haptics` and `Keychain` are near-verbatim (change the Keychain service string from `app.snapcal.ios`). `Theme` keeps its *structure* — type scale, spacing, `Color(hex:)` — but the palette is SnapCal's: `protein`/`carbs`/`fat` semantic colours are meaningless here, and BP Coach needs guideline-driven status colours instead. |
| **Verdict** | **ADAPT (Theme) · COPY (Haptics, Keychain)** |
| Rationale | Small, self-contained, genuinely generic. |

> 🐞 **Defect — do not inherit.** `Theme.swift:72–82` requests `PlusJakartaSans-Bold`,
> `-SemiBold` and `-Medium` by name, but no `.ttf`/`.otf` is present in the repository and
> `Info.plist` has no `UIAppFonts` key. Every call silently falls back to the system font.
> BP Coach must either bundle the OFL font files and register them, or use system fonts
> deliberately.

---

## 4. Cross-phase blockers — resolved

| Question | Answer | Effect |
|---|---|---|
| Is the HealthKit wrapper coupled to a persistence stack? | **No.** Only two `UserDefaults` booleans. | **Persistence decision UNBLOCKED. SwiftData is free to choose.** |
| Is the food/sodium dataset redistributable? | Moot — no shippable dataset exists. Open Food Facts is ODbL if ever exported. | Phase 6 needs a new source. |
| Does the networking layer hard-code a provider? | Provider selection is server-side; the client is coupled to SnapCal's own API instead. | Phase 7 starts clean. |
| Do any candidates require iOS above 17.0? | **SnapCal targets 18.0.** | See §5. |

---

## 5. Deployment target — owner decision required

SnapCal is built at iOS **18.0**. `HealthService` (A5) is the only substantial file proposed
for reuse and it uses `@Observable`, `@MainActor` and the `HKQuantityType(.stepCount)`
initialiser — all available from iOS 17.0. Nothing inspected in A5 or A6 *demonstrably*
requires 18.0.

- **Hold at iOS 17.0** — wider device support; A5 must be verified to compile at 17.0.
- **Move to iOS 18.0** — matches the donor, removes the question, narrows reach.

Static reading cannot settle this. It needs a compile.

---

## 6. Owner sign-off

Nothing may be copied before both boxes are ticked.

- [ ] All audit records reviewed
- [ ] COPY / ADAPT list approved: **A5 (adapt), A6 Haptics + Keychain (copy), A6 Theme (adapt)**
- [ ] Deployment target decided — §5

**Approved by:** ______________  **Date:** ____________

---

## 7. Summary

| ID | Component | Verdict |
|---|---|---|
| A1 | Food database | REJECT |
| A2 | Sodium data | REJECT — does not exist |
| A3 | NL meal parsing | REJECT |
| A4 | AI / networking infrastructure | REJECT for 0–6; reconsider at 7 and 14 |
| A5 | HealthKit wrapper | **ADAPT** |
| A6 | Haptics, Keychain | **COPY** |
| A6 | Theme | **ADAPT** |

**Roughly 390 lines of a 9,800-line iOS app are worth carrying across.**
The reuse premise in the Master Prompt — food database, sodium data, meal parsing — does
not survive contact with the repository. All three are server-side or absent.
