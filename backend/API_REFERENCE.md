# SnapCal API Reference

Base URL: `https://sna-production-5e29.up.railway.app/api/v1`

Every endpoint except `/health` requires:

```http
Authorization: Bearer <jwt>
X-Timezone: Asia/Kolkata        # IANA zone — decides the dashboard day
Content-Type: application/json
```

`X-Timezone` is not optional in practice. It determines which local day a meal
lands on and when the dashboard resets. Send the device's
`TimeZone.current.identifier` on every request.

---

## Conventions

**Errors** all share one shape:

```json
{ "error": "code_string", "message": "Human readable" }
```

| Status | `error` | Meaning |
|---|---|---|
| 400 | `validation_failed` | Body failed schema. Includes `issues[]`. |
| 401 | `unauthorized` | Missing/expired token → re-auth |
| 402 | `PREMIUM_REQUIRED` | Allowance spent → open paywall |
| 404 | `not_found` | |
| 413 | `image_too_large` | > 1.5 MB |
| 422 | `no_food_detected` | AI found no food in the photo |
| 429 | `rate_limited` | Too many requests, or abuse ceiling |
| 500 | `internal_error` | Never exposes internals |

**402 carries everything needed to open the right paywall:**

```json
{
  "error": "PREMIUM_REQUIRED",
  "feature": "coach",
  "reason": "limit_reached",
  "usage": { "feature": "coach", "used": 2, "limit": 2, "remaining": 0, "premiumOnly": false }
}
```

`reason` is `limit_reached` (free allowance spent) or `premium_only` (never
available on free). `feature` is `food_scan` | `coach` | `meal_plan` | `weekly_report`.

**Money and macros.** All macros are integers in grams. Calories are integers.
Per-100g values are floats. The client derives portion macros as
`grams × per_100g ÷ 100` — the server uses the identical formula, so editing a
quantity never needs a network call.

---

## Auth

### `POST /auth/apple`
```json
{ "identity_token": "<apple jwt>", "name": "Satya" }
→ { "token": "<jwt>", "onboarded": false }
```
Token is valid 90 days. Store in Keychain.

### `POST /profile` — onboarding
```json
{
  "name": "Satya", "birth_year": 1994, "sex": "male",
  "height_cm": 178, "start_weight_kg": 80, "goal_weight_kg": 72,
  "goal": "lose", "activity_level": "light",
  "units": "metric", "country": "IN"
}
→ {
  "targets": { "bmr": 1750, "tdee": 2406, "calories": 1925,
               "protein_g": 144, "carbs_g": 215, "fat_g": 58, "water_ml": 2600 },
  "projected_weeks": 17
}
```
`sex`: `male|female|other`. `goal`: `lose|maintain|gain`.
`activity_level`: `sedentary|light|moderate|active|very_active`.

### `GET /profile` · `PATCH /targets` · `GET /account/export` · `DELETE /account`
`DELETE /account` hard-deletes everything and cascades. Required by App Store
review because the app creates accounts.

---

## Dashboard

### `GET /dashboard`
One call for the whole Home screen.

```json
{
  "date": "2026-08-15",
  "timezone": "Asia/Kolkata",
  "resets_at": "2026-08-15T18:30:00.000Z",

  "targets": { "calories": 1925, "protein_g": 144, "carbs_g": 215, "fat_g": 58, "water_ml": 2600 },
  "consumed": { "calories": 1240, "protein_g": 78, "carbs_g": 118, "fat_g": 41 },

  "activity": {
    "date": "2026-08-15",
    "steps": 8543,
    "distance_m": 6100,
    "flights_climbed": 4,
    "exercise_min": 30,
    "active_kcal": 320,
    "kcal_source": "healthkit",
    "credited_kcal": 160,
    "credit_mode": "partial"
  },

  "budget": {
    "base_calories": 1925,
    "activity_bonus": 160,
    "total_calories": 2085
  },

  "remaining": { "calories": 845, "protein_g": 66, "carbs_g": 97, "fat_g": 17 },

  "water_ml": 1600,
  "current_weight_kg": 70.3,
  "streak_days": 7,
  "meals": [ /* see GET /meals/today */ ]
}
```

**Daily reset.** `date` is the user's local day; `resets_at` is the exact UTC
instant of their next local midnight. Schedule a refresh at that instant rather
than polling. Correct across DST and half-hour offsets.

**The coach and the dashboard now agree.** `/coach/*` computes remaining
against the same activity-adjusted budget, so a walk that raises the ring also
raises what the coach says is left.

**Activity affects the ring.** Draw progress against
`budget.total_calories`, not `targets.calories`. `remaining.calories` already
accounts for it. If `activity_bonus > 0`, showing "+160 from activity" explains
why the allowance moved.

**`credit_mode`** — how much measured burn feeds the budget:

| Mode | Credit | Why |
|---|---|---|
| `off` | 0% | Ignore activity |
| `partial` | 50% | **Default.** The target already assumed an activity level; crediting 100% double-counts it |
| `full` | 100% | For users who set a sedentary target and log everything |

---

## HealthKit

The app reads HealthKit and posts a daily rollup. The server never talks to
Apple; it stores what you send.

### `POST /health/daily`
```json
{
  "logged_on": "2026-08-15",     // optional, defaults to local today
  "steps": 8543,
  "active_kcal": 320,            // HealthKit activeEnergyBurned
  "resting_kcal": 1680,          // optional
  "exercise_min": 30,
  "distance_m": 6100,
  "flights_climbed": 4
}
→ (the recomputed activity block, same shape as dashboard.activity)
```

Idempotent upsert — call it as often as you like; `COALESCE` means a partial
payload never wipes fields you omitted.

**If `active_kcal` is absent or 0**, the server estimates from steps:
`steps × weight_kg × 0.0005` (~35 kcal per 1,000 steps at 70 kg) and returns
`kcal_source: "estimated"`. Send HealthKit's own figure whenever the permission
allows — it accounts for pace and terrain.

### `GET /health/daily?date=YYYY-MM-DD`
### `GET /health/history?days=7` → `{ days, entries: [...] }`
### `PUT /health/activity-credit` → `{ "mode": "off" | "partial" | "full" }`

**Required Info.plist keys** (already present):
`NSHealthShareUsageDescription`, `NSHealthUpdateUsageDescription`, and the
`com.apple.developer.healthkit` entitlement. Read-only: steps, active energy,
exercise time, distance, flights.

---

## Food scanning

Still OpenAI — vision quality matters and it is already cheap.

### `POST /food/analyze` — multipart
```
image: <jpeg>        # resize to 512px longest edge, q0.6, < 1.5 MB
hint:  "lunch"       # optional
```
```json
{
  "foods": [{
    "food_id": "uuid|null", "name": "dal tadka",
    "quantity": 1, "unit": "katori", "grams": 150,
    "kcal_100g": 118, "protein_100g": 6, "carbs_100g": 15, "fat_100g": 3.6,
    "calories": 177, "protein_g": 9, "carbs_g": 23, "fat_g": 5,
    "confidence": 0.84, "is_estimate": true, "matched_source": "curated"
  }],
  "total": { "calories": 553, "protein_g": 19, "carbs_g": 67, "fat_g": 12 },
  "confidence": 0.82,
  "assumptions": ["Assumed 1 tsp oil per serving"],
  "is_estimate": true,
  "disclaimer": "AI estimate. Not a medical or clinical measurement.",
  "cached": false
}
```

The model returns **names and grams only**; macros come from the nutrition
database. `confidence < 0.7` is worth flagging in the UI. `disclaimer` must be
displayed — it is an App Store review consideration.

### `POST /food/text` → `{ "text": "2 rotis and dal" }`
### `POST /food/voice` → `{ "transcript": "..." }` (on-device transcription)
### `POST /food/barcode` → `{ "barcode": "8901234567890", "grams": 30 }`

All return the same envelope. Barcode uses Open Food Facts, costs no AI quota.

---

## Nutrition lookup — USDA FoodData Central

Free, no AI, no quota. Curated regional foods rank first because USDA covers
Indian dishes poorly and users think in `1 roti`, not `45 g`.

### `GET /food/lookup?term=chicken&branded=false&limit=10`
```json
{
  "term": "chicken",
  "results": [
    { "id": "uuid", "source": "snapcal", "name": "chicken curry",
      "kcal_100g": 155, "protein_100g": 14, "carbs_100g": 5, "fat_100g": 9,
      "default_unit": "katori", "default_grams": 180 },
    { "id": null, "fdc_id": 171077, "source": "usda", "name": "chicken breast, raw",
      "data_type": "SR Legacy",
      "kcal_100g": 165, "protein_100g": 31, "carbs_100g": 0, "fat_100g": 3.6,
      "fiber_100g": 0,
      "serving_size": 85, "serving_unit": "g", "household_serving": "3 oz",
      "default_unit": "g", "default_grams": 85 }
  ]
}
```
`branded=true` includes packaged products — noisier, use for a "more results"
affordance rather than the default.

### `GET /food/usda/{fdcId}?grams=150`
```json
{
  "food_id": "uuid", "fdc_id": 171077,
  "name": "chicken breast, raw", "brand": null,
  "per_100g": { "calories": 165, "protein_g": 31, "carbs_g": 0, "fat_g": 3.6,
                "fiber_g": 0, "sugar_g": 0, "sodium_mg": 74 },
  "serving": { "size": 85, "unit": "g", "household": "3 oz" },
  "portion": { "grams": 150, "calories": 248, "protein_g": 47, "carbs_g": 0, "fat_g": 5 },
  "source": "usda"
}
```
Caches into our database on first fetch, so repeat lookups skip USDA. `grams`
defaults to the label serving, then 100. Use `food_id` when saving a meal.

Auth uses the **Data.gov key** (`DATA_GOV_API_KEY`). Without one, USDA falls
back to `DEMO_KEY` at ~30 req/hour and `/food/lookup` silently returns only
local results rather than failing.

### `GET /food/search?term=roti`
Local database only. Fastest; use for type-ahead.

---

## Meals

### `POST /meals`
```json
{
  "slot": "lunch",
  "input_method": "photo",
  "logged_on": "2026-08-15",
  "ai_confidence": 0.82,
  "items": [{
    "food_id": "uuid|null", "name": "roti",
    "quantity": 2, "unit": "roti", "grams": 90,
    "kcal_100g": 264, "protein_100g": 9, "carbs_100g": 49, "fat_100g": 3.7,
    "is_estimate": true
  }]
}
→ { "id": "uuid", "logged_on": "2026-08-15" }
```
`slot`: `breakfast|lunch|dinner|snack`.
`input_method`: `photo|text|voice|barcode|search|manual`.

### `PATCH /meals/{id}` — **never calls the AI**
Send the full `items` array. Portion edits are arithmetic on the stored
per-100g values, so cost is zero and the numbers match what the client shows.

### `DELETE /meals/{id}`
### `GET /meals/today` · `GET /meals?date=YYYY-MM-DD`

---

## AI Coach

Runs on OpenRouter with the cheapest suitable model — coaching is short text
asked often, which is exactly where a $0.01/M model earns its place.

### `POST /coach/ask`
```json
{ "question": "Can I eat a samosa?" }
→ {
  "answer": "Yes — you have 845 kcal left, a samosa is about 180.",
  "entitlements": { /* refreshed, see GET /entitlements */ }
}
```

**Answers are one line, max ~25 words.** Enforced twice: the system prompt asks
for it, and the server truncates to the first sentence. Design the UI for a
single line — do not build a scrolling transcript bubble expecting paragraphs.

Only compact facts are sent to the model (remaining calories, protein, steps,
burn, weight, streak), not the full food history. Keeps the bill near zero and
the answers specific.

Free tier: **2 questions per billing period**, then 402.

**`suggestion`** — a concrete next meal resolved from the nutrition database,
returned alongside the answer:

```json
{
  "answer": "Yes — you have 900 left, chicken is 248.",
  "suggestion": {
    "food_id": "uuid", "name": "grilled chicken breast", "slot": "dinner",
    "grams": 150, "quantity": 1, "unit": "serving",
    "kcal_100g": 165, "protein_100g": 31, "carbs_100g": 0, "fat_100g": 3.6,
    "calories": 248, "protein_g": 47, "carbs_g": 0, "fat_g": 5,
    "reason": "47g protein, fits your 900 kcal left"
  },
  "entitlements": { }
}
```

Not a second AI call — the macros are exact, so "Add to Diary" posts straight
to `POST /meals` with no confirmation step. `null` when under ~120 kcal remain.
Respects allergies, dislikes, vegetarian/vegan, foods already eaten today, and
the user's country for cuisine.

### `GET /coach/suggestion` — free, no AI, no quota
```json
{ "suggestion": { /* as above, or null */ },
  "remaining": { "calories": 900, "protein_g": 62, "carbs_g": 90, "fat_g": 20 },
  "budget": 2250 }
```
Safe on every dashboard refresh. Use it to keep the Coach screen useful once
the AI allowance is spent.

**`intent`** is returned with every answer: `meal_recommendation`,
`food_analysis`, `workout_request`, `daily_plan`, `progress`, `hydration`,
`activity`, `sleep`, `education`, `general`. Use it to decide layout — a
workout answer is a structured block, a calorie check is one line.

Response length scales with intent: workouts up to ~420 tokens, day plans
~320, ordinary questions ~120. Only `meal_recommendation` can carry a
`suggestion` card, and only when the answer actually made a recommendation.

**Safety guards** apply before and after the model. Medication, dosing,
diagnosis, supplement brands, and unverifiable live facts (stock, prices,
opening hours) are refused with a useful redirect rather than a flat no. A
suspected emergency returns a fixed message directing the user to urgent care.

### `GET /coach/history` → last 40 messages, oldest first
### `GET /coach/suggestions` → `{ suggestions: ["Can I eat this?", ...] }`
Free, no AI call. Use to fill the empty state.

---

## Daily briefing

### `GET /coach/briefing?regenerate=false`
```json
{
  "date": "2026-08-16",
  "mode": "recovery",
  "headline": "Lighter day. Your body's asking for a bit of slack...",
  "actions": [{
    "id": "uuid",
    "domain": "recovery",
    "action": "Take today easy — a walk or some mobility rather than a session",
    "reason": "Your slept 24% below their usual, so recovery will do more than training today.",
    "confidence": 0.85,
    "triggeredBy": ["recovery_mode", "slept 24% below their usual"]
  }],
  "missing": ["hrv", "weight"],
  "generated": true
}
```

At most **3 actions** (2 in recovery mode), **one per domain**, each with a
reason citing real data. Idempotent per day — `generated: false` means today's
set already existed.

Actions are produced by rules over stored observations, not by asking a model
what to do. Nothing fires without the data it needs, so a new user never sees
"below your usual". `missing` lists metrics with no data — show a connect
prompt rather than a zero.

Each action is persisted as a recommendation with its `id`, so responses and
outcomes can be recorded against it.

### `POST /coach/learn-cycle`
```json
{ "outcomesMeasured": 4, "memoriesAdded": 1,
  "memoriesUpdated": 0, "memoriesReinforced": 3 }
```
Measures what last week's advice did, then updates the brain. Call once a day —
lazily, on app open. Free, no AI call.

## Health state

### `POST /observations`
```json
{ "observations": [
  { "metric": "hrv", "value": 42, "observed_on": "2026-08-16",
    "source": "healthkit", "confidence": 1.0 }
] }
```
Any metric, any source, with a confidence. Upserts per (metric, day, source).

Send: `steps`, `resting_hr`, `hrv`, `sleep_minutes`, `sleep_start_min`,
`sleep_end_min`, `weight_kg`, `active_kcal`, `exercise_min`.

`sleep_start_min` / `sleep_end_min` are minutes past midnight — they power
sleep-regularity coaching, which is measurable, unlike sleep stages.

### `GET /health/state` · `GET /health/metric/{metric}`
```json
{ "metric": "hrv", "today": 38, "avg7": 40, "avg30": 50,
  "baseline": 52, "trend": "falling", "deviationPct": -27,
  "confidence": "high", "daysObserved": 21 }
```
`null` means no data — never zero. `confidence`: none / low (<5 days) /
medium (5–20) / high (21+).

`GET /health/state` adds `mode` (recovery / maintenance / growth) and
`modeRationale`. **The mode is an internal coaching decision, not a score —
don't render it as a number.**

## Personal Health Brain

### `GET /brain/memories`
```json
{ "layers": {
    "routine": [{ "id": "uuid", "content": "usually eats breakfast around 7am",
                  "confidence": 0.9, "evidence_count": 6, "user_edited": false }]
  },
  "labels": { "routine": "Your usual patterns" },
  "total": 3 }
```
Use `labels` for headings — never show "semantic" to a user.

### `PATCH /brain/memories/{id}` · `DELETE /brain/memories/{id}`
Editing marks a memory authoritative: extraction will never overwrite it.
Deletion is permanent, not a soft delete.

### `POST /brain/learn`
Extracts routines and outcome patterns from logged behaviour. Idempotent —
repeat observations reinforce rather than duplicate.

## Recommendations

### `GET /recommendations?status=pending`
### `POST /recommendations/{id}/respond` → `{ "status": "completed", "feedback": "..." }`
### `GET /recommendations/effectiveness`

`enough_data: false` until a domain has 4+ recommendations. Completion and
improvement rates feed procedural memory, which then reranks future actions —
a domain the user ignores drops down.

## Coach onboarding

First run only. The server decides the next question, so it can skip anything
SnapCal already knows and anything an earlier answer made irrelevant
("nowhere regular" removes the equipment, days and duration questions).

### `GET /coach/onboarding`
```json
{
  "completed": false,
  "answered": 2,
  "total": 8,
  "welcome": "Good to meet you, Satya. I've got your calorie targets already — ...",
  "next": {
    "field": "training_location",
    "question": "Where will you train?",
    "options": [{ "value": "gym", "label": "Gym" }],
    "multiSelect": false,
    "step": 3,
    "total": 8,
    "skippable": false
  }
}
```
`welcome` is null for a returning user. `next` is null once complete.

### `POST /coach/onboarding`
```json
{ "field": "equipment_list", "values": ["full_gym", "dumbbells"] }
{ "field": "primary_goal", "value": "lose_fat_keep_muscle" }
{ "field": "average_sleep_hours", "skip": true }
```
Returns the same shape, advanced by one. `justCompleted: true` on the final
answer. Render `options` as chips; `multiSelect` decides single or multi.

## Structured workouts

### `POST /coach/workout` → `{ "minutes": 30, "focus": "upper" }` (both optional)
```json
{
  "id": "uuid",
  "workout_title": "Lower Body Strength",
  "focus": "lower",
  "duration_minutes": 45,
  "warmup": ["5 min easy cardio", "Dynamic mobility"],
  "exercises": [{
    "exercise_name": "Leg Press",
    "sets": 3, "reps": "8-12", "rest_seconds": 90,
    "suggested_weight_kg": 42.5,
    "progression_note": "Up from 40kg — you hit the top of the range twice.",
    "instructions": "Drive through mid-foot, don't lock out.",
    "targets": "quads, glutes"
  }],
  "optional_cardio": "15 min moderate walking",
  "cooldown": ["Hamstring stretch"],
  "coach_note": "Straightforward session to build a base."
}
```

Render as a card the user can work through, not a chat bubble. Focus rotates
from recent sessions; four consecutive training days returns a recovery
session instead.

**`suggested_weight_kg` is computed from logged history, never by the model** —
null when there is none, with `progression_note` explaining why. Weight only
increases after the top of the rep range was hit twice, capped at ~5%.

Costs one AI request against the coach allowance.

### Closing the loop
`POST /workouts` accepts `plan_id`. Passing it marks the plan as completed, and
that session becomes the history the next recommendation reads.

### `GET /coach/patterns`
```json
{ "patterns": [
  "Protein has averaged 78g against a 144g target — short on 6 of 9 logged days.",
  "Steps drop to about 2,100 at weekends versus 7,400 on weekdays."
] }
```
Free — arithmetic over logged history, no model call. Empty until there are at
least four logged days.

## Training

The coach cannot program sensibly without history — it will otherwise suggest
the same session daily and cannot progress from real weights.

### `GET /fitness/profile` · `PUT /fitness/profile`
```json
{ "gym_access": true, "equipment": "full_gym", "experience": "beginner",
  "training_days": 4, "session_minutes": 60, "injuries": [] }
```
`equipment`: `none|bands|dumbbells|home_gym|full_gym`.
`experience`: `unknown|beginner|intermediate|advanced` — unknown programs
beginner-safe, never assume competence.

### `POST /workouts`
```json
{
  "performed_on": "2026-08-16",
  "focus": "upper",
  "minutes": 55,
  "perceived_effort": 7,
  "exercises": [
    { "exercise": "Bench Press", "sets": 3, "reps": 10, "weight_kg": 40 }
  ]
}
```
`focus`: `upper|lower|full_body|push|pull|cardio|mobility|rest`.

### `GET /workouts?days=14` · `DELETE /workouts/{id}`

Logged sessions feed `/coach/ask` automatically: the last 14 days decide
today's focus, flag when recovery is the better answer, and supply the weights
progression is suggested from.

## Meal Planner — Premium only

### `POST /meal-plan` → `{ "span": "day" | "week" }`

A `day` plan requested after the user has already eaten covers only what is
**left** of today. The response says which:

```json
{ "planned_for": "remaining_today", "budget_kcal": 900 }
```
`full_day` otherwise. Weekly plans are always `full_day` — later days start
empty. Label the UI accordingly; "Today's plan" is misleading at 4pm.
```json
{
  "id": "uuid", "span": "day", "starts_on": "2026-08-15",
  "days": [{
    "date": "2026-08-15",
    "meals": [{ "slot": "breakfast", "name": "Poha", "grams": 180,
                "kcal": 279, "protein_g": 5, "carbs_g": 47, "fat_g": 8 }]
  }],
  "note": "Balanced around your protein target.",
  "entitlements": { /* ... */ }
}
```
Plans hit the calorie target within 5%, meet or beat protein, and respect diet,
allergies and dislikes absolutely. Free users get 402 `premium_only` — show the
preview, not an error.

A planned meal converts straight to a diary entry: `POST /meals` with
`kcal_100g = kcal ÷ grams × 100`. No second AI call.

### `GET /meal-plan/latest`
### `GET /preferences` · `PUT /preferences`
```json
{ "diet": "vegetarian", "cuisines": ["indian"],
  "dislikes": ["mushroom"], "allergies": ["peanut"] }
```

---

## Entitlements

### `GET /entitlements`
```json
{
  "plan": "free",
  "periodStart": "2026-08-01T00:00:00Z",
  "periodEnd": "2026-08-31T00:00:00Z",
  "features": {
    "food_scan": { "feature": "food_scan", "used": 1, "limit": 2, "remaining": 1, "premiumOnly": false },
    "coach":     { "feature": "coach", "used": 0, "limit": 2, "remaining": 2, "premiumOnly": false },
    "meal_plan": { "feature": "meal_plan", "used": 0, "limit": 0, "remaining": 0, "premiumOnly": true }
  }
}
```

`limit: null` means unlimited. **Render these numbers; never hardcode them** —
they are configured server-side in `entitlement_config` and can change without
an app release. Refresh after every AI call and after any purchase.

---

## Subscription

### `GET /subscription` · `POST /subscription/verify`
```json
{ "signed_transaction": "<Transaction.jwsRepresentation>" }
```
Send on purchase **and** on every `Transaction.updates` emission. The server
verifies the JWS x5c chain — a client-side `isPremium` boolean is never trusted
anywhere in this codebase. Upgrading starts a fresh billing period so a new
subscriber does not inherit a spent free allowance.

---

## Weight, water, history

### `POST /weight` → `{ "weight_kg": 70.3, "logged_on": "..." }`
### `GET /weight?days=90`
### `POST /water` → `{ "ml": 250 }` (negative to undo)
### `GET /history?range=week|month|quarter`
### `GET /reports/weekly` — Premium; 402 for free users

---

## Notifications

### `GET /notifications/prefs` · `PUT /notifications/prefs`
```json
{ "daily_coach": true, "morning_hour": 8, "morning_minute": 0,
  "meal_reminders": false, "food_logging": false, "coach_reminder": false,
  "premium_offers": true, "permission": "granted" }
```
PUT is partial — omitted fields keep their value.

### `GET /notifications/morning`
```json
{ "title": "Good morning, Satya",
  "body": "Your goal today: stay within 1925 calories and hit 144g protein.",
  "deeplink": "snapcal://today" }
```
Fetch and schedule locally. No push infrastructure needed for the daily case.

Deep links: `snapcal://today` `/scan` `/coach` `/meals` `/premium`

---

## Analytics

### `POST /analytics/events`
```json
{ "events": [{ "name": "paywall_viewed", "props": { "source": "coach" } }] }
→ 202 { "accepted": 1, "rejected": 0 }
```
Batch up to 50. Unknown event names are silently rejected — see the allow-list
in `routes/premium.ts`. Props must be string, number or boolean.

---

## Rate limits

| Scope | Limit |
|---|---|
| Global | 120 req/min per user |
| AI endpoints (`/food/*`, `/coach/*`, `/meal-plan`) | 30 req/min per user |
| Abuse ceiling per feature per period | free 20, pro 300 |

Keyed on a hash of the bearer token, not IP — users behind one NAT do not
throttle each other.

---

## Environment

```bash
DATABASE_URL=                  # Railway injects
JWT_SECRET=                    # openssl rand -base64 48

AI_PROVIDER=openai             # food scanning
OPENAI_API_KEY=

OPENROUTER_API_KEY=            # coach only
OPENROUTER_COACH_MODEL=meta-llama/llama-3.3-70b-instruct
OPENROUTER_FALLBACK_MODELS_RAW=google/gemini-2.0-flash-001

DATA_GOV_API_KEY=              # USDA FoodData Central
ADMIN_USER_IDS=                # unlocks /admin/*
```

Model slugs and prices change weekly. `GET /admin/openrouter/models` returns
the cheapest text models live, so `OPENROUTER_COACH_MODEL` can be set from real
data rather than a stale table. Free OpenRouter models exist but are limited to
~200 requests/day — not viable in production.

`GET /admin/cost` reports actual spend per scan, cache hit rate, escalation
rate and cost per paying user.
