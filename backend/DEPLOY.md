# Backend Deployment Guide

Deploying the AI Coach, USDA nutrition, HealthKit activity and timezone reset
work to Railway.

Nothing here touches the iOS app. The UI developer can keep working against the
current build while this ships.

---

## Step 1 — Get the two new API keys

### Data.gov (USDA FoodData Central) — free, 2 minutes

1. https://api.data.gov/signup/
2. Enter name and email
3. The key arrives by email immediately

Without it the code falls back to `DEMO_KEY`, throttled to ~30 requests/hour.
`/food/lookup` degrades to local results only rather than erroring, so this is
not a hard blocker — but food search will feel thin.

### OpenRouter — for the AI Coach

1. https://openrouter.ai → sign in
2. **Keys** → **Create Key**
3. **Credits** → add a balance. $5 goes a very long way: coach answers are one
   line, so a typical question costs a small fraction of a cent.

Note the 5.5% card fee on top-ups. Topping up $5 at a time pays a
disproportionate share in fees; $20+ is more sensible.

---

## Step 2 — Pick the coach model

Slugs and prices change weekly, so don't trust any list — including mine. After
deploying, ask the running service:

```bash
curl -H "Authorization: Bearer <your-jwt>" \
  https://sna-production-5e29.up.railway.app/api/v1/admin/openrouter/models
```

Returns the cheapest text models live, sorted by combined input+output price:

```json
{
  "configured": "meta-llama/llama-3.3-70b-instruct",
  "cheapest_paid": [
    { "id": "...", "input_per_1m": 0.01, "output_per_1m": 0.02, "context": 128000 }
  ],
  "free": [ ... ]
}
```

Requires your user UUID in `ADMIN_USER_IDS` (Step 3).

**Don't use the free models.** They're capped around 200 requests/day across
your whole account — fine for testing, an outage waiting to happen in
production.

**Do sanity-check the model you pick.** The cheapest listing is sometimes a
tiny model that ignores instructions. Ask it three real questions through
`/coach/ask` before committing; if answers run long or ignore the numbers, move
one step up the list. The fallback chain handles outages, not bad output.

---

## Step 3 — Railway environment variables

Railway → your `sna` service → **Variables**.

| Variable | Value | Required |
|---|---|---|
| `OPENROUTER_API_KEY` | from Step 1 | Coach 503s without it |
| `OPENROUTER_COACH_MODEL` | slug from Step 2 | Has a default |
| `OPENROUTER_FALLBACK_MODELS_RAW` | comma-separated slugs | Has a default |
| `DATA_GOV_API_KEY` | from Step 1 | Degrades gracefully |
| `PUBLIC_APP_URL` | `https://snapcal.app` | OpenRouter attribution |
| `ADMIN_USER_IDS` | your user UUID | Unlocks `/admin/*` |

Find your user UUID:

```bash
railway run psql $DATABASE_URL -c "SELECT id, email FROM users ORDER BY created_at LIMIT 5;"
```

Everything already set (`DATABASE_URL`, `JWT_SECRET`, `OPENAI_API_KEY`,
`NODE_ENV`) stays as it is.

---

## Step 4 — Deploy

```bash
cd C:\Users\ASUS\sna
git add backend/
git commit -m "coach via openrouter, usda nutrition, activity calories, tz reset"
git push
```

Railway redeploys on push. Watch **Deployments** for a green build.

**Migrations 0004, 0005 and 0006 apply automatically at boot**, behind a
Postgres advisory lock so concurrent replicas are safe. They are additive and
idempotent — nothing drops or truncates.

To run them manually instead, set `RUN_MIGRATIONS_ON_BOOT=false` and use a
Railway one-off command:

```bash
npm run migrate
```

---

## Step 5 — Verify

### Service is alive

```bash
curl https://sna-production-5e29.up.railway.app/health
# {"ok":true,"provider":"openai","model":"gpt-5.6-luna","version":"..."}
```

If `provider` says `mock`, set `AI_PROVIDER=openai` — every scan is returning a
canned thali.

### Migrations landed

```bash
railway run psql $DATABASE_URL -c "SELECT name FROM schema_migrations ORDER BY name;"
```

Expect `0001` through `0006`.

```bash
railway run psql $DATABASE_URL -c "\d health_daily"
```

Should show `distance_m`, `flights_climbed`, `kcal_source`.

### End-to-end smoke test

Grab a JWT by signing in on the app, then:

```bash
API=https://sna-production-5e29.up.railway.app/api/v1
TOKEN=<your jwt>
H="-H \"Authorization: Bearer $TOKEN\" -H \"X-Timezone: Asia/Kolkata\" -H \"Content-Type: application/json\""

# 1. USDA search — must return both snapcal and usda sources
curl -s "$API/food/lookup?term=chicken" -H "Authorization: Bearer $TOKEN" | head -c 400

# 2. HealthKit sync — must return credited_kcal ≈ half of active_kcal
curl -s -X POST "$API/health/daily" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "X-Timezone: Asia/Kolkata" \
  -d '{"steps":10000,"active_kcal":400,"exercise_min":30}'

# 3. Dashboard — budget.total_calories must exceed targets.calories
curl -s "$API/dashboard" -H "Authorization: Bearer $TOKEN" \
  -H "X-Timezone: Asia/Kolkata" | python -m json.tool | head -40

# 4. Coach — answer must be ONE line
curl -s -X POST "$API/coach/ask" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -H "X-Timezone: Asia/Kolkata" \
  -d '{"question":"Can I eat a samosa?"}'
```

What each proves:

| Check | Pass looks like |
|---|---|
| 1 | Results with `"source":"usda"` present. Only `snapcal` → `DATA_GOV_API_KEY` missing or throttled |
| 2 | `credited_kcal: 200`, `kcal_source: "healthkit"` |
| 3 | `budget.activity_bonus: 200`, `total_calories` = target + 200, `resets_at` in the future |
| 4 | One sentence, under ~25 words, referencing a real number |

If 4 returns 503 `openrouter_not_configured`, the key isn't set. If it returns
402, that account has spent its 2 free coach questions — expected on a free
account, and itself a valid test.

### Timezone reset

```bash
curl -s "$API/dashboard" -H "Authorization: Bearer $TOKEN" \
  -H "X-Timezone: Asia/Kolkata" | grep -o '"resets_at":"[^"]*"'
curl -s "$API/dashboard" -H "Authorization: Bearer $TOKEN" \
  -H "X-Timezone: America/New_York" | grep -o '"resets_at":"[^"]*"'
```

Two different instants. Same user, same moment — the day boundary follows the
header.

---

## Step 6 — Watch the cost

```bash
curl -s "$API/admin/cost?days=7" -H "Authorization: Bearer $TOKEN" | python -m json.tool
```

```json
{
  "actual": {
    "scans": 412,
    "cache_hit_rate": 0.11,
    "escalation_rate": 0.07,
    "cost_per_scan_usd": 0.00034,
    "monthly_ai_cost_usd": 0.61,
    "cost_per_paying_user_usd": 0.031,
    "avg_latency_ms": 2140
  }
}
```

Worth checking in the first week:

- **`escalation_rate` above 15%** — the primary model is struggling on real
  photos; the escalation path is costing more than it should
- **`cache_hit_rate` near 0** — expected early, should rise as users re-scan
  familiar meals
- **`cost_per_scan_usd` far above $0.0004** — check `AI_MODEL`; something has
  switched to an expensive tier

Coach costs appear in the same ledger under `feature = 'coach'`, billed from
OpenRouter's reported generation cost rather than a guessed price table.

---

## Rollback

Migrations are additive, so rolling back code is safe — no schema needs
reverting.

Railway → **Deployments** → find the last good deploy → **⋯** → **Redeploy**.

If only the coach is broken, unset `OPENROUTER_API_KEY`: `/coach/ask` returns a
clean 503 and everything else keeps working. Better than a half-working coach.

---

## What this doesn't cover

The iOS app doesn't call the new endpoints yet. `/food/lookup`,
`/health/activity-credit`, `/health/history` and the enriched `/dashboard`
fields are live and unused until the UI work lands.

`HealthService.swift` already posts to `/health/daily`, so activity data starts
flowing as soon as a user grants the permission — the dashboard's
`activity_bonus` will populate on its own.

Two things still needed before HealthKit works on a real device:

1. **HealthKit enabled on the App ID** — developer.apple.com → Identifiers →
   `app.snapcal.ios` → tick HealthKit. Without it the archive fails at signing.
2. A TestFlight build carrying the entitlement and usage strings.
