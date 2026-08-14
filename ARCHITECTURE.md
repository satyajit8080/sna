# SnapCal AI — Architecture & Provider Decisions

> Positioning: **"The fastest AI calorie tracker for everyday food."**
> Photo → macros in under 4 seconds. Everything else is secondary.

---

## 1. Provider evaluation (pricing verified 13 Aug 2026)

### Vision LLM candidates

| Model | Input $/1M | Output $/1M | Notes |
|---|---|---|---|
| **GPT-5.6 Luna** | $0.20 | $1.20 | July 30 2026 price cut. Cheapest credible OpenAI vision tier. |
| GPT-5.6 Terra | $2.00 | $12.00 | Escalation tier for low-confidence retries. |
| GPT-5.6 Sol | $5.00 | $30.00 | Overkill for food ID. |
| GPT-5.4 mini | $0.75 | $4.50 | Legacy, still on price sheet. |
| **Gemini 3.5 Flash-Lite** | $0.30 | $2.50 | Cheap, 1M ctx. |
| Gemini 2.5 Flash-Lite | $0.10 | $0.40 | Cheapest anywhere — **but retires 16 Oct 2026**. Do not build on it. |
| Gemini 3.6 Flash | $1.50 | $7.50 | Strong multimodal, 3x Luna cost. |
| Gemini 3.1 Pro | $2.00 | $12.00 | Unnecessary. |

Batch API = 50% off on both vendors, but batch is async (24h) — unusable for the
scan flow. Cached input = 10% of standard on both; our system prompt is cached.

**1. Cheapest reliable API:** GPT-5.6 Luna ($0.20/$1.20).
Gemini 2.5 Flash-Lite is nominally cheaper but is EOL in ~9 weeks.

**2. Best for food recognition:** Gemini 3.6 Flash edges out on fine-grained
multi-item plate decomposition, but the gap does not survive our constrained
JSON prompt + nutrition-DB grounding. Luna wins on cost-per-correct-answer.

**3. Best nutrition database:**
- **USDA FoodData Central** — primary. Free, no key cost, authoritative
  per-100g macros for whole/generic foods (SR Legacy + Foundation + Branded).
- **Open Food Facts** — primary for **barcodes**. Free, global, best UK/EU/AU
  packaged coverage, decent India coverage.
- **Internal `food_database` table** — seeded with ~400 Indian/desi items
  (roti, dal tadka, paneer butter masala, dosa, idli, biryani, poha, upma,
  thali, sabzi, samosa…) with per-unit gram weights, because USDA's Indian
  coverage is thin and portion units are cultural ("1 roti", not "45g").

The LLM **never invents macros**. It returns `{name, portion_g, confidence}`;
the server resolves macros from the DB. LLM macros are a fallback only when
no DB match clears the similarity threshold.

### 4. Expected cost per scan

Per scan, measured: image resized to 512px longest edge (~330 image tokens),
system prompt cached, compact JSON output ~180 tokens.

| | tokens in (uncached) | tokens out | $/scan |
|---|---|---|---|
| GPT-5.6 Luna | ~480 | 180 | **$0.000312** |
| Gemini 3.5 Flash-Lite | ~480 | 180 | $0.000594 |
| Gemini 3.6 Flash | ~480 | 180 | $0.002070 |

| Scans | Luna | 3.5 Flash-Lite | 3.6 Flash |
|---|---|---|---|
| 1,000 | $0.31 | $0.59 | $2.07 |
| 10,000 | $3.12 | $5.94 | $20.70 |
| 100,000 | $31.20 | $59.40 | $207.00 |
| 1,000,000 | $312 | $594 | $2,070 |

Add ~8% for the escalation path (see §2) → **≈$0.00034 blended per scan**.
At 90 scans/month for a heavy Pro user ($6.99/mo): **$0.031 AI COGS/user/month
= 0.4% of revenue.** AI cost is not the business risk; churn is.

### 5. Recommendation

**Primary: OpenAI GPT-5.6 Luna.**
Cheapest sustainable tier, structured outputs are reliable, 6.6x cheaper than
Gemini 3.6 Flash for an accuracy delta that DB-grounding erases.
**Escalation: GPT-5.6 Terra** when Luna returns `confidence < 0.55` or an empty
plate (~8% of scans). **Fallback: Gemini 3.5 Flash-Lite** on OpenAI 5xx/timeout.

`AIProvider` protocol keeps this a one-line env change: `AI_PROVIDER=openai|gemini|mock`.

---

## 2. Request flow

```
iOS  ──HEIC/JPEG, resized 512px, q0.7, ~45KB──▶  Backend
                                                   │
                                          ┌────────┴────────┐
                                          │ perceptual hash │──hit──▶ cache (30d)
                                          └────────┬────────┘
                                                   │ miss
                                        AIProvider.analyzeImage()
                                          Luna → conf<0.55? → Terra
                                                   │
                                          {name, portion_g, conf}[]
                                                   │
                                     resolve() → food_database → USDA
                                                   │
                                          macros computed server-side
                                                   ▼
                                     {items, total, assumptions, estimate:true}
```

**No AI call is made when the user edits a quantity.** Macros scale linearly
from `per_100g` in `meal_items`, computed on-device and re-verified server-side.

---

## 3. Screen flow

```
Launch
 ├─ no token ──▶ Welcome ──▶ Onboarding (7 steps) ──▶ Targets reveal ──▶ Home
 └─ token ─────▶ Home

Home (Dashboard)
 ├─ ring: consumed / target, remaining big number
 ├─ macro bars: P / C / F
 ├─ meal sections: Breakfast · Lunch · Dinner · Snacks
 ├─ [ ⬤ Scan Food ]  ← persistent, thumb-reachable, always primary
 │    ├─ Camera ──▶ Analyzing (skeleton, ~2.5s) ──▶ Confirm ──▶ Home
 │    ├─ Photo library ──▶ same
 │    ├─ Barcode ──▶ OFF lookup ──▶ Confirm
 │    ├─ Describe (text) ──▶ Confirm
 │    └─ Voice (on-device SFSpeech) ──▶ text ──▶ Confirm
 ├─ Diary tab ──▶ day scroller, swipe-to-delete, tap-to-edit
 ├─ Progress tab ──▶ weight chart · water · 7/30/90d calories & protein
 └─ Settings ──▶ profile, targets, subscription, export, delete account
```

Confirm screen is the only editing surface. It must be reachable and dismissible
in one gesture. Free users hitting the 2-scan/week cap see the paywall *after*
analysis is shown blurred — value first, then ask.

---

## 4. Cost & privacy guardrails (implemented)

- Images resized client-side; server rejects payloads > 1.5 MB.
- Original images are **never persisted**. Held in memory, hashed, discarded.
  `MealItem.image_url` is null unless the user explicitly opts into meal photos.
- System prompt is static → prompt caching at 10% input rate.
- `ai_usage` row per call with token counts and computed cost → `/api/v1/admin/cost`.
- Rate limits: 30 req/min/user, plus plan-based scan quotas in `usage.ts`.
- Nutrition lookups cached in `food_database` with 30-day TTL on external hits.
- Account deletion cascades all rows; export returns full JSON.
- OpenAI key exists only in server env. iOS ships zero provider keys.
