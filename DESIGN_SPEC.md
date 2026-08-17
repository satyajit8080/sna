# SnapCal — Design Specification

For the designer. Every screen below maps to an API that exists and returns
real data. Where something doesn't exist yet, it says so — please don't design
around it until we've discussed the cost.

Read §1 and §12 before drawing anything.

---

## 1. What this app is

**A coach that tells you the two or three things that matter today, and why.**

Not a dashboard. Not a database of numbers. The test for any screen: could a
tired person glance at it and know what to do next?

Three rules that override every other instruction here:

**Honesty.** A calorie estimate from a photo is roughly ±25%. We show that.
Missing data shows a prompt, never a zero — "no step data" and "zero steps" are
different situations and conflating them makes the app scold someone for a day
it knows nothing about.

**Restraint.** Maximum three priorities. Two in recovery mode. A screen that
asks for eight things asks for nothing.

**Warmth without judgement.** No guilt, no red alarms for being over, no
punishment for a missed day. Someone over their calories already knows.

---

## 2. Navigation

**Four tabs**, already built: Home · Scan · AI Coach · Meal Plan.

Diary, Progress and Settings are reached from Home:
- Diary ← "View All" on Today's Meals
- Progress ← the streak card
- Settings ← profile icon, top right of the header

Settings must stay reachable — account deletion and subscription management
live there, and both are App Store requirements.

**Scan is an action, not a destination.** Tapping it opens the camera over
whatever tab you were on.

---

## 3. Design tokens

Match `Theme.swift` exactly. Change values freely; keep the names.

| Token | Value | Use |
|---|---|---|
| `color/accent` | `#15B87B` | primary, progress, active tab |
| `color/secondary` | `#7C7D89` | all secondary text |
| `color/bg` | `#F1F1F1` / dark `#0B0B0C` | screen background |
| `color/card` | `#FFFFFF` / dark `#161618` | every card |
| `color/protein` | `#15B87B` | |
| `color/carbs` | `#60A5FA` | |
| `color/fat` | `#FB923C` | |
| `color/steps` | `#15B87B` | |
| `color/weight` | `#5296ED` | |
| `color/activeCal` | `#EC5F28` | |
| `color/water` | `#997AF3` | |
| `color/streak` | `#F86A3C` | |
| `color/danger` | `#EF4444` | errors only — never "you went over" |
| `radius/card` | 17 | overview + metric tiles |
| `radius/row` | 13 | meal rows |
| `radius/control` | 11 | |
| `space/gutter` | 25 | screen edge |

**Type — Plus Jakarta Sans.** Send the `.ttf` files; the app currently falls
back to SF Pro because we don't have them.

| Style | Size / weight |
|---|---|
| `title` | 20 bold |
| `section` | 16 bold |
| `rowTitle` | 16 bold |
| `bigNum` | 20 bold |
| `body` | 16 regular |
| `label` | 13 semibold |
| `caption` | 12 semibold |
| `micro` | 10 semibold |

**Every number that animates uses monospaced digits**, or values jitter as they
count. Calories, macros, weight, steps.

Two modes on the colour collection: Light and Dark. If you only design light,
we'll derive dark and you may not like the result.

Canvas 393×852. Everything on Auto Layout.

---

## 4. Home — `Screen/Home`

The most important screen. Order top to bottom:

**Header**
"Good Morning, Satya" + one line of sub-copy. Profile icon top-right → Settings.

**Streak card** — only when `streak_days > 0`. Tappable → Progress.

**Today's priorities** ← `GET /coach/briefing`

The hero block. 1–3 cards, each:
- **Action**, `rowTitle`: *"Make your next meal protein-led — about 60g to go"*
- **Reason**, `caption`, secondary: *"You're 60g short of your 144g target with most of the day gone"*
- Two controls: **Done** · **Not today** → `POST /recommendations/{id}/respond`

Every card carries a reason. If there's no reason there's no card. Give this
block real space — it is the product.

```json
{ "mode": "recovery",
  "headline": "Lighter day. Your body's asking for a bit of slack.",
  "actions": [{ "id": "uuid", "domain": "recovery",
    "action": "Take today easy — a walk rather than a session",
    "reason": "You slept 24% below your usual." }],
  "missing": ["hrv", "weight"] }
```

Design an **empty state**: a new user gets one card — "Log your first meal".
That's correct, not a bug.

**Calorie ring + macro bars** ← `GET /dashboard`

Ring tracks `budget.total_calories` — target *plus* credited activity — not
`targets.calories`. When `budget.activity_bonus > 0`, add a quiet line:
*"+160 earned from movement"*.

Over budget: ring passes 100%, shows the overshoot as a positive number
("282 over"). No red fill, no warning icon.

**Four metric tiles** — Steps · Weight · Active Cal · Water

Water needs **plus and minus**. It's currently add-only and users overshoot
with no way back.

A tile whose metric is in `missing` shows **"Connect Health"** and is tappable.
Never a zero.

**Today's meals** ← `dashboard.meals`

Row: slot glyph, slot name, food names, time, calories.

**No food photos.** We hash and discard scan images for privacy; that's what
our App Store privacy label says. Photo thumbnails need object storage and a
label change — discuss before designing them in.

**Scan CTA** — floating, always reachable.

### Home states to draw
`— Empty` (day 1) · `— Recovery` (2 cards, calmer) · `— OverBudget` ·
`— NoHealthData` · `— Loading` · `— Offline` (we show the last saved day)

---

## 5. Scan flow

**`Screen/Scan/Capture`** — camera, shutter, gallery, close.

**`Screen/Scan/Analyzing`** — 2–4 seconds. Design something worth watching.

**`Screen/Scan/Confirm`** ← the most-used editing screen

Per detected food:
- Name, portion
- **Minus / value / plus, always visible** — no tap-to-expand. Correcting a
  portion is the single most common action after a scan
- Macro chips
- Remove

Header: total calories, macros, and a **confidence line**:
*"AI estimate · roughly ±25%"* when `confidence < 0.7`.

This is a differentiator. Competitors hide uncertainty; we show it.

Slot picker, then **Add to Diary**.

States: `— LowConfidence` · `— NoFoodDetected` · `— SaveFailed` (keep the scan
on screen, offer Try again) · `— Empty` (manual entry).

---

## 6. AI Coach — `Screen/Coach`

Currently one chat bubble per message. That breaks for structured output.

**Answers vary by `intent`**, returned with every reply:

| intent | Render as |
|---|---|
| `meal_recommendation` | 1–2 lines + optional meal card |
| `workout_request` | **structured card** — see below |
| `daily_plan` | short structured list |
| `progress`, `education` | 1–3 lines |
| `safety` | plain text, **never** a card |

**Meal card** (only when `suggestion` is present): name, calories, macros,
*Add to Diary*.

**Workout card** ← `POST /coach/workout`

```json
{ "workout_title": "Lower Body Strength", "duration_minutes": 45,
  "warmup": ["5 min easy cardio"],
  "exercises": [{ "exercise_name": "Leg Press", "sets": 3, "reps": "8-12",
    "rest_seconds": 90, "suggested_weight_kg": 42.5,
    "progression_note": "Up from 40kg — you hit the top of the range twice." }],
  "cooldown": ["Hamstring stretch"] }
```

Design it as a **session you work through**: exercise list, tick each set,
rest timer, finish → logs to history. Not a wall of chat text.

`suggested_weight_kg` can be `null` — show `progression_note` instead
("No history — start light"). We never invent a starting weight.

Composer sits above the tab bar and above the keyboard.

States: `— Empty` (suggestion chips) · `— Thinking` · `— LimitReached` (free
tier) · `— WorkoutCard` · `— Safety`.

---

## 7. Meal Plan — `Screen/MealPlanner`

Free users see a **description of the feature**, not a fake plan. We removed
the invented sample meals; please don't reintroduce them.

Premium: day tabs, meals with macros, one-tap log each. When
`planned_for: "remaining_today"`, label it *"Planned around your remaining
1,200 cal"* — not "Today's plan", which is misleading at 4pm.

States: `— Locked` · `— Empty` · `— Generating` · `— RestOfDay` · `— Week`.

---

## 8. What SnapCal knows about you — `Screen/Brain` (new)

← `GET /brain/memories`

The personalization moat, and it has to be visible and correctable or it reads
as the app making things up.

Grouped by layer, using the `labels` the API returns:

> **Your usual patterns**
> · usually eats breakfast around 7am
> · logs less at weekends
>
> **Things I've learned about you**
> · eats oatmeal regularly
>
> **What works for you**
> · sleep changes measurably help

Every row: **edit** and **delete**. Editing marks it authoritative — we'll
never overwrite it. Deletion is permanent.

Never show layer names like "semantic" or confidence scores.

Empty state matters: a new user sees *"I'll learn as you go."*

---

## 9. Fitness onboarding — `Screen/Onboarding/Fitness` (new)

← `GET /coach/onboarding`, `POST /coach/onboarding`

Conversational, one question at a time, chips not a form. The server decides
the next question and skips anything already known.

```json
{ "next": { "question": "Where will you train?",
    "options": [{ "value": "gym", "label": "Gym" }],
    "multiSelect": false, "step": 3, "total": 8, "skippable": true } }
```

Progress indicator from `step`/`total`. Show **Skip** only when
`skippable: true`. `multiSelect` decides single vs multi.

---

## 10. Progress, Diary, Settings, Paywall

**Progress** — weight trend (smoothed, never raw daily noise), calorie and
protein charts, weekly report (premium; free sees a teaser).

**Diary** — day navigation, meals by slot, edit and delete, daily totals.

**Settings** — plan + usage, notifications, targets, preferences, **Restore
Purchases**, **Terms**, **Privacy**, **Delete Account**. The last four are
required.

**Paywall** — four context variants: `FoodScan`, `Coach`, `MealPlan`,
`General`. Copy speaks to whatever the user just tried to do. Prices come from
StoreKit, never hardcoded.

---

## 11. Notifications

One daily morning message, user-set time. Optional meal, logging and coach
reminders — all default **off**.

Nudge copy is never guilt-based. *"You usually eat around 7 — anything to log?"*
not *"You've forgotten to log!"*

---

## 12. Do not design these

**Meal photo thumbnails** — images are discarded; storing them is a backend and
privacy-label change.

**A readiness or recovery score.** The API returns a coaching `mode` — it's an
internal decision about how much to ask of someone today, not a number to
display. Showing "readiness 43" invites "am I ill?" anxiety, which is exactly
what the design avoids.

**Sleep stages** (REM / deep minutes). Consumer wearables aren't accurate
enough to state them as fact. We coach on sleep *regularity*, which is
measurable.

**Biological age.** Vendor implementations disagree by decades.

**Streak counters on Home.** Streaks belong on Progress, and they forgive a
missed day when recovery data justifies it.

**Medication, supplements, or health conditions.** No tables, no API. These
have real regulatory weight and need deciding deliberately, not designing
first.

**Calorie clawback** — never take back "earned" calories or frame exercise as
paying off food.

---

## 13. Data rules

`null` ≠ `0`. Missing data gets a prompt.

Use realistic content, longest and shortest:

| Element | Typical | Also design |
|---|---|---|
| Calories | `1,847` | `0`, `12,450` |
| Weight | `70.3 kg` | `—`, lb variant |
| Food name | `Turkey sandwich` | a 40-char name that truncates |
| Coach reply | 1–2 sentences | 1 line, and a 15-line workout |
| Meals | 3 | 0, and 12 |

Foods are North American by default — chicken, eggs, oatmeal, steak, turkey
sandwich. Regional cuisines appear only when a user selects them.

---

## 14. Handoff

Send: **Figma link** (Dev Mode needs a paid seat — check before promising it),
**token JSON**, **SVGs** for any non-SF-Symbol icon, **Plus Jakarta Sans .ttf**.

Naming: `Screen/Dashboard`, `Screen/Coach`, `Card/Meal`, `Button/Primary`.
Frame names become our file map.

**Sequence, and this matters:** Home first, with all its states. We ship it,
verify on device, settle disagreements about spacing and type at the cost of
one screen. Then the rest in parallel.

There is no way to preview a rendered screen without a TestFlight build, so
each one takes 2–3 rounds. Handing over twelve finished screens at once
compounds any misunderstanding across all of them.

---

## Priority

1. **Home** + states — the product
2. **Confirm** — most-used editing screen
3. **Coach** with workout card — largest gap between backend and UI
4. **Brain** — the differentiator, and currently invisible
5. Fitness onboarding
6. Meal Plan, Progress, Diary, Settings, Paywall polish
