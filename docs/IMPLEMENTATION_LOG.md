# Implementation Log — BP Coach

---

## Phase 0 — New project, build verification, SnapCal audit

**Status:** INCOMPLETE — documentation scaffolding only
**Date:** 2026-08-17

### Completed

- Repository documentation scaffolding authored: `CLAUDE.md`, `docs/IMPLEMENTATION_LOG.md`,
  `docs/phases/PHASE_00.md`, `docs/SNAPCAL_AUDIT.md`, `docs/DELETION_CANDIDATES.md`
- Architecture, invariants, and confirmed project decisions recorded in `CLAUDE.md`
- Phase 0 verification procedure written with exact commands to be run on macOS
- **SnapCal audit COMPLETE** against pinned commit `db7c6281aee65c742826a446215c2c813011e109`
  (public repo `satyajit8080/sna`, clean tree). All six records populated from real inspection.
- **Deletion candidates COMPLETE** — 22 rows (D1–D22) plus a 9-item sever-at-copy list

### NOT completed — environment blocked

The following require macOS with Xcode and access to the SnapCal repository. Neither was
available in the environment where this scaffolding was authored. **No value below has
been verified and none may be assumed.**

- Xcode project not created
- Bundle identifier not set
- Git repository and `bp-coach` branch not initialised
- Xcode version, Swift version, scheme, and simulator destination **not discovered**
- Build **not run**
- Tests **not run**
- Swift Testing availability **not determined**
- Nothing compiled — audit is static inspection only, no build performed
- `design-reference/` PNGs not committed
- Nothing committed to any branch

### Audit findings that change the plan

1. **The reuse premise largely fails.** Food database, sodium data and natural-language meal
   parsing are all server-side or absent. SnapCal's iOS app is a thin client; roughly 390 of
   its 9,800 Swift lines are worth carrying.
2. **There is no sodium dataset.** `sodium` appears in zero migrations. It is a transient
   field mapped from a USDA API response and never persisted. Phase 6 needs a new source.
3. **Persistence decision resolved.** `HealthService` has no Core Data or SwiftData coupling —
   two `UserDefaults` booleans only. SwiftData is free to adopt.
4. **SnapCal targets iOS 18.0**, above our 17.0 default. Nothing in the ADAPT/COPY list
   demonstrably requires 18.0, but only a compile settles it.
5. **HealthService transmits health data to a server** (lines 129, 149). Must be severed at
   copy time or it silently breaks the local-first rule.
6. **No blood pressure types exist** in SnapCal's HealthKit wrapper — `bloodPressure` appears
   nowhere in the iOS source. They must be added.
7. **Latent font defect** — Plus Jakarta Sans is requested by name but never bundled and not
   registered in `Info.plist`. Silent system-font fallback. Do not inherit.
8. **No third-party dependencies** in SnapCal iOS. Nothing unwanted to inherit.
9. **Swift Testing already in use** (`NutritionMathTests.swift`, 985 lines) — viable on the toolchain.

### Assumptions made

| Assumption | Basis | Confidence |
|---|---|---|
| Deployment target iOS 17.0 | Master Prompt default; enables SwiftData, Observation, Swift Charts | Medium — must be checked against reused SnapCal code |
| Project name `BPCoach` | Naming convention only | Low — owner may prefer otherwise |
| Xcode-generated scheme will match the project name | Common but **not guaranteed** | Must be discovered, never assumed |
| Swift Testing is available | Depends on the installed toolchain | Unknown |

### Limitations

- Every entry in the `CLAUDE.md` verification table is marked ❌ and must remain so until
  the real command output is pasted in.
- The SnapCal audit cannot proceed without either the repository on disk or an uploaded
  file tree. Until it does, the persistence decision (SwiftData vs Core Data) stays open,
  and Phase 6 has no input.

### Owner decisions RECORDED — 2026-08-17

1. **Salvage approved:** COPY `Haptics`, `Keychain`; ADAPT `HealthService`, `Theme`; REJECT all else.
2. **Deployment target:** iOS 17.0, pending compile verification. Not to be claimed from inspection.
3. **Persistence:** SwiftData, local-first.
4. **Fonts:** system fonts. Jakarta Sans deferred.
5. **Sodium/food:** SnapCal provides none. New data source required at Phase 6.
6. **Blood pressure:** greenfield. BP Coach implements its own model and HealthKit integration.
7. **HealthKit privacy:** `HealthKit → BP Coach → SwiftData` only. Server transmission removed at copy time.
8. **Framing:** new application, not a SnapCal fork.

### Remaining owner decisions

1. Bundle identifier prefix — **still required**
2. Confirm project name `BPCoach`
3. AI provider — deferred to Phase 7
4. ~~SnapCal access~~ — DONE
5. ~~Approve audit verdicts~~ — DONE
6. ~~Deployment target~~ — DONE (17.0, pending compile)
7. ~~SwiftData~~ — DONE
8. ~~Font decision~~ — DONE

### Next

Complete `docs/phases/PHASE_00.md` sections 0.1–0.6 on macOS. Phase 0 is not closed and
Phase 1 must not begin.
