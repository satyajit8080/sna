# BP Coach

Your AI Blood Pressure Coach — *Measure. Understand. Improve.*

A local-first iOS blood pressure app with a stateless backend gateway.

---

## Start here

| Document | For |
|---|---|
| **`docs/DEPLOYMENT.md`** | Getting it running: architecture, five-stage runbook, env vars, troubleshooting |
| `docs/DEVELOPMENT.md` | Working on it: local setup, conventions, testing, debugging |
| `CLAUDE.md` | Project state, decisions, invariants — read first in any new session |
| `preview/screens.html` | 15 screens rendered from the design tokens, light and dark |

---

## What's in here

```
Sources/          iOS app — SwiftUI, SwiftData, HealthKit (55 files, ~7,400 lines)
Tests/            Swift Testing suites
backend/          Fastify gateway — OpenRouter + USDA proxy (12 files, ~850 lines)
docs/             Deployment, development, and the SnapCal reuse audit
scripts/          security-check.sh — 12 enforced invariants
preview/          HTML screen gallery
project.yml       XcodeGen spec — the .xcodeproj is generated, never committed
codemagic.yaml    CI: security sweep, iOS build/test, backend tests
```

---

## Status, honestly

| Area | Status |
|---|---|
| Backend build | ✅ typecheck clean |
| Backend tests | ✅ **40/40 passing** |
| Security invariants | ✅ **12/12 passing** |
| iOS build | ⛔ **never compiled** — no Mac on this project |
| iOS tests | ⛔ written, never executed |
| Railway deployment | ⛔ configured, not deployed |
| Live API integrations | ⛔ stubbed in tests, never called for real |

The backend results above were run, not asserted. The iOS app is 7,400 lines
that have not yet met a compiler — expect the first CodeMagic build to surface
errors. That is what stage 4 of the deployment guide is for.

---

## Quick start

```bash
# Backend
cd backend
npm install
cp .env.example .env       # add OPENROUTER_API_KEY and USDA_FDC_API_KEY
npm run dev                # http://localhost:8080
npm test                   # 40 tests

# Security sweep
./scripts/security-check.sh
```

iOS requires macOS with Xcode — all iOS building happens on CodeMagic. See
`docs/DEPLOYMENT.md`.

---

## Design commitments

These are enforced by tests and by the CI security sweep, not just intended.

- **Local-first.** Blood pressure, medications and lifestyle data live on the
  device. Health data read from HealthKit is never transmitted — CI fails the
  build if networking appears in `HealthKitService`.
- **Urgency is deterministic.** `SafetyEngine` is a pure function. The AI never
  sees the crisis path, and generated output is screened before display.
- **No hard-coded thresholds.** Every category resolves through the active
  `BPGuideline` (ACC/AHA 2017 or ESC/ESH 2023).
- **Nothing fabricated.** An unconfigured coach throws. A food record without
  sodium is dropped, not zero-filled. Absent data gets an empty state, never a
  placeholder number.
- **Keys stay server-side.** Anything in an `.ipa` can be extracted from it.
- **No database.** There is no user data to store, so there is nothing to
  secure, back up, or reason about under GDPR.
