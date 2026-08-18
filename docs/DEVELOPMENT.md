# BP Coach — development guide

How to work on this codebase day to day.

---

## What you can run where

| Task | Needs | Where |
|---|---|---|
| Backend: edit, build, test | Node 20+ | Your machine |
| Security sweep | bash | Your machine |
| iOS: edit source | any editor | Your machine |
| **iOS: compile, test, run** | **macOS + Xcode** | **CodeMagic only** |

There is no Mac on this project. Every iOS build and test goes through
CodeMagic, so the loop for Swift changes is: edit → push → read the CI log.
That is slower than a local build, and it is the main reason the Swift code
leans on pure, testable functions rather than logic buried in views.

---

## Backend — local loop

```bash
cd backend
npm install

cp .env.example .env      # fill in keys; .env is gitignored
npm run dev               # http://localhost:8080, restarts on save
```

Verify it came up:

```bash
curl -s localhost:8080/health   # {"status":"ok",...}
curl -s localhost:8080/ready    # which services are configured
```

`/ready` reports `not configured` for anything missing a key, and that is a
working state — the endpoint returns a clean 503 and the app degrades. You do
not need keys to develop most of the backend.

### Keys for local work

| Key | Get it | Needed for |
|---|---|---|
| `OPENROUTER_API_KEY` | <https://openrouter.ai/keys> | `/v1/coach` |
| `USDA_FDC_API_KEY` | <https://fdc.nal.usda.gov/api-key-signup.html> | `/v1/food/*` |

OpenRouter is credit-based — add credit under Settings → Credits or requests
return 402. One key reaches every model it fronts, so trying a different model
is an `OPENROUTER_MODEL` change, not a new account.

Confirm slugs at <https://openrouter.ai/models>. They change as models ship and
retire, and a wrong one produces a 400 that surfaces as "the AI request was
rejected".

### Tests

```bash
npm test                        # builds, then runs everything
node --test test/*.test.js      # skip the build if dist/ is current
```

`npm test` compiles first because the suite imports from `dist/`, not `src/`.
Testing the built output means a TypeScript error fails the test run rather
than being silently skipped.

The OpenRouter suite injects a stub `fetch`, so it never makes a network call
and needs no key:

```js
const result = await requestCoaching(body, config, async () =>
  new Response(JSON.stringify({ choices: [{ message: { content: "…" } }] }),
    { status: 200, headers: { "content-type": "application/json" } }));
```

Both provider clients take `fetchImpl` as a last parameter for exactly this.

### Exercising the coach end to end

```bash
curl -s -X POST localhost:8080/v1/coach \
  -H 'content-type: application/json' \
  -d '{
    "question": "What moved my BP this week?",
    "guidelineName": "ACC/AHA 2017",
    "readings": [
      {"systolic":128,"diastolic":82,"pulse":72,"recordedAt":"2026-08-17T07:38:00Z",
       "timeOfDay":"Morning","source":"Manual","category":"Elevated"},
      {"systolic":134,"diastolic":88,"recordedAt":"2026-08-16T07:52:00Z",
       "timeOfDay":"Morning","source":"Manual","category":"Stage 1"},
      {"systolic":121,"diastolic":78,"recordedAt":"2026-08-15T21:10:00Z",
       "timeOfDay":"Evening","source":"Manual","category":"Normal"}
    ],
    "averages": [{"days":7,"systolic":127,"diastolic":83,"count":9}],
    "medications": [], "lifestyle": []
  }' | jq
```

Three readings matter: under three, `renderContext` appends a note telling the
model to say the data is too thin. Worth seeing both behaviours.

---

## iOS — working without a Mac

You can edit Swift anywhere. You cannot check it until CI runs, so:

**Keep logic out of views.** Anything with a rule in it — categorisation,
statistics, adherence, safety — lives in `Services/` as a pure function or a
plain type. Those are the parts that get tested, and the parts most likely to
be wrong in a way that matters.

**Push small.** A hundred-line change with one compile error is a two-minute
fix. A thousand-line change with thirty errors is an afternoon.

**Read `error:` lines from the bottom.** Swift's first error is often a cascade
from something further down.

### Local checks that catch real problems

```bash
# Duplicate type declarations across files
grep -rhoE '^(struct|final class|enum|class) [A-Za-z]+' Sources --include='*.swift' \
  | awk '{print $NF}' | sort | uniq -d

# References to a type that no longer exists
grep -rn "TypeYouJustDeleted" Sources Tests --include='*.swift'

# Invariants CI also enforces
./scripts/security-check.sh
```

---

## Project structure

```
Sources/
  App/           entry point, AppModel, RootView, deep-link router
  Core/
    DesignSystem/   Theme tokens, shared components, error views
    Charts/         Swift Charts wrappers
    Persistence/    SwiftData container
    Support/        haptics, AppError
  Models/        @Model types — every one carries profileID
  Services/
    Guideline/   BPGuideline protocol + ACC/AHA + ESC/ESH
    Safety/      SafetyEngine — deterministic, no AI
    Statistics/  pure functions over readings
    Health/      HealthKitService — no networking, ever
    Medication/  adherence and scheduling
    Notifications/
    Food/        provider protocol + backend implementation
    AI/          AICoachService protocol, context engine, backend client
    Export/      CSV
  Features/      one folder per tab

backend/src/
  routes/        thin HTTP handlers
  services/      OpenRouter, USDA, prompt, errors
  middleware/    logging, error handling
```

**Direction of dependency:** features depend on services. Services never depend
on features, and no feature imports another. If you find yourself wanting to,
the shared thing belongs in a service.

---

## Conventions that are not negotiable

These are enforced by tests, by the security sweep, or by both.

**No clinical threshold outside the guideline engine.** Not in a view, not in a
helper, not "just for a colour". Everything goes through
`GuidelineEngine.category(...)`. The sweep greps for the obvious forms.

**Safety is deterministic.** `SafetyEngine` is a pure function of the reading.
It never becomes async, never calls a service, never consults the coach. The
crisis path is the one thing in the app that must behave identically every
time.

**No networking in `HealthKitService`.** CI fails the build if `URLSession`
appears in that directory. Health data flows HealthKit → SwiftData and stops.

**Every model carries `profileID`, and filtering happens at the source.**
`AIContextEngine` filters by profile before it builds anything, not afterwards.
Cross-profile leakage is tested.

**Nothing is fabricated.** An unconfigured coach throws. An unconfigured food
provider returns an empty array. A food record with no sodium is dropped rather
than zero-filled. Absent data shows an empty state, never a placeholder number.

**Estimates are labelled everywhere they appear**, including in exports and in
the AI context, where they are marked `(ESTIMATE, not measured)`.

---

## Adding things

### A new guideline

1. Conform to `BPGuideline` in `Services/Guideline/`
2. Add a case to `BPGuidelineID` with a `displayName` and a `summary`
3. Add it to `GuidelineEngine.guideline(for:)`
4. **Add exhaustive boundary tests** — every threshold, both components, and at
   least one case where systolic and diastolic disagree

Nothing else changes. Every badge in the app already resolves through the
engine.

### A new AI provider

Implement the same shape as `openrouter.ts`: take `(body, config, fetchImpl)`,
throw `UpstreamError` with a sensible status and `retryable` flag, and run
`screenResponse` on the output before returning it. Swap it in `routes/coach.ts`.

The iOS side needs no change — it only knows about `AICoachService`.

### A new food provider

Conform to `FoodDataProvider`. The one hard requirement is sodium: a record
without it is useless here, and returning zero would assert something the data
does not say. Drop those records.

### A new screen

Put it under `Features/`, use `CardView`, `StatTile`, `SectionHeader` and the
`Theme` tokens rather than raw values, and give it a real empty state. Empty
states say what is missing and what to do about it.

---

## Testing

| Suite | Covers |
|---|---|
| `GuidelineTests` | every boundary in both guidelines, mixed components |
| `SafetyTests` | crisis thresholds, symptom escalation, determinism over 50 calls |
| `StatisticsTests` | averages, SD, MAP, Rule-of-3 discard, drift |
| `MedicationTests` | adherence with pending doses excluded |
| `IsolationTests` | profile scoping, context capping, honest stubs |
| `GroupingExportTests` | bucketing, CSV escaping |
| `TimeAndContextTests` | time-of-day boundaries, deep links |
| `BackendClientTests` | wire payload carries no identifiers |
| `backend.test.js` | validation, screening, routes, rate limiting, OpenRouter client |

When you add a rule, add the boundary case. When you fix a bug, add the case
that would have caught it — the medication screen missing `"stopping your
medication"` while catching `"stop your medication"` is exactly that kind of
gap, and it now has a test.

---

## Debugging

**Backend logs.** Bodies are redacted at the logger, deliberately. You will see
method, route, status and duration and nothing else. If you need to see a
payload while developing, log it explicitly and temporarily — never add it to
the redact exceptions, or health data ends up in production logs.

**Screened responses** log the reason and the model, not the text. Knowing the
screen fired is what matters; keeping the prohibited output is not.

**`/ready` before anything else.** Most "the coach is broken" reports are a
missing or misnamed variable, and `/ready` answers that in one request.

---

## Before you push

```bash
cd backend && npx tsc --noEmit && npm test
cd .. && ./scripts/security-check.sh
```

Both clean, then push. CI runs the same checks plus the iOS build.
