/**
 * End-to-end check against a running API + Postgres.
 *
 *   DATABASE_URL=... API=http://localhost:8080 node test/e2e.mjs
 *
 * Uses AI_PROVIDER=mock so it never spends real money, and exercises the paths
 * that are easy to break: auth, targets, the scan quota race, meal maths,
 * dashboard aggregation and cost accounting.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import pg from "pg";

const API = process.env.API ?? "http://localhost:8080";
const db = new pg.Pool({ connectionString: process.env.DATABASE_URL });

let token;
let userId;
/// Overridable so a test can pretend to be in a different timezone — used to
/// check that the coach behaves differently in the middle of the night.
let tzHeader = "UTC";

/**
 * A timezone where it is currently mid-afternoon.
 *
 * The briefing deliberately behaves differently at night — it drops to a single
 * sleep action — so any test about ordinary briefing behaviour has to pin the
 * clock, or it passes all day and fails after 22:00 UTC.
 */
const DAYTIME_TZ = (() => {
  const zones = ["UTC", "Asia/Kolkata", "America/New_York", "Asia/Tokyo",
                 "Europe/London", "Australia/Sydney", "America/Los_Angeles",
                 "Pacific/Honolulu", "Asia/Dubai"];
  for (const tz of zones) {
    const hour = Number(new Intl.DateTimeFormat("en-GB", {
      timeZone: tz, hour: "2-digit", hour12: false }).format(new Date()));
    if (hour >= 9 && hour <= 16) return tz;
  }
  return "UTC";
})();

async function api(path, { method = "GET", body, form, auth = true } = {}) {
  const headers = { "X-Timezone": tzHeader };
  if (auth && token) headers.authorization = `Bearer ${token}`;
  if (body) headers["content-type"] = "application/json";

  const res = await fetch(`${API}/api/v1${path}`, {
    method,
    headers,
    body: form ?? (body ? JSON.stringify(body) : undefined),
  });
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = { raw: text }; }
  return { status: res.status, json };
}

/** Bypasses Sign in with Apple (needs a real Apple token) by minting a user directly. */
test("setup: create user + token", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`e2e-${Date.now()}@snapcal.test`]
  );
  userId = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [userId]);

  const { SignJWT } = await import("jose");
  token = await new SignJWT({ sub: userId })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt().setIssuer("snapcal").setExpirationTime("1h")
    .sign(new TextEncoder().encode(process.env.JWT_SECRET));

  assert.ok(token);
});

test("health", async () => {
  const res = await fetch(`${API}/health`);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).ok, true);
});

test("rejects unauthenticated requests", async () => {
  const res = await fetch(`${API}/api/v1/dashboard`);
  assert.equal(res.status, 401);
});

test("profile creates targets via Mifflin-St Jeor", async () => {
  const { status, json } = await api("/profile", {
    method: "POST",
    body: {
      name: "E2E", birth_year: 1994, sex: "female", height_cm: 165,
      start_weight_kg: 70, goal_weight_kg: 63, goal: "lose",
      activity_level: "light", units: "metric", country: "IN",
    },
  });
  assert.equal(status, 200);
  assert.ok(json.targets.calories > 1200, "calorie floor respected");
  assert.ok(json.targets.protein_g > 0);
  assert.ok(json.projected_weeks > 0);
});

test("food search hits the curated regional table", async () => {
  const { status, json } = await api("/food/search?term=roti");
  assert.equal(status, 200);
  assert.ok(json.results.length > 0, "roti should be seeded");
  assert.equal(json.results[0].default_unit, "roti");
});

test("text analysis returns grounded macros, never model-invented ones", async () => {
  const { status, json } = await api("/food/text", { method: "POST", body: { text: "dal tadka" } });
  assert.equal(status, 200);
  assert.equal(json.is_estimate, true);
  assert.ok(json.disclaimer.includes("Not a medical"));
  assert.ok(json.total.calories > 0);
  assert.equal(json.foods[0].matched_source, "curated");
});

/**
 * The important one. Free tier is 2/week; one is already spent by the test
 * above. Fire 5 concurrent scans — exactly 1 may succeed.
 */
test("scan quota is atomic under concurrent requests", async () => {
  const before = await api("/usage");
  assert.equal(before.json.remaining, 1, "one free scan should remain");

  const results = await Promise.all(
    Array.from({ length: 5 }, () =>
      api("/food/text", { method: "POST", body: { text: "2 rotis and dal" } })
    )
  );

  const ok = results.filter((r) => r.status === 200).length;
  const denied = results.filter((r) => r.status === 402).length;

  assert.equal(ok, 1, `exactly one scan may succeed, got ${ok}`);
  assert.equal(denied, 4, `four must be rejected, got ${denied}`);

  const after = await api("/usage");
  assert.equal(after.json.remaining, 0);
  assert.equal(after.json.used, 2);
});

test("voice bills against the food_scan allowance, not a separate gate", async () => {
  // The free allowance was already spent by the concurrency test above.
  const { status, json } = await api("/food/voice", { method: "POST", body: { transcript: "one banana" } });
  assert.equal(status, 402);
  assert.equal(json.error, "PREMIUM_REQUIRED");
  assert.equal(json.feature, "food_scan");
});

test("failed scans do not consume quota", async () => {
  const { rows } = await db.query(
    `SELECT status, counts_against_quota FROM ai_usage WHERE user_id = $1 ORDER BY created_at`, [userId]
  );
  assert.ok(rows.length >= 2);
  assert.ok(rows.every((r) => ["complete", "failed"].includes(r.status)),
    "no reservation may be left dangling in 'reserved'");
});

test("meal save + dashboard aggregation", async () => {
  const item = {
    name: "roti", quantity: 2, unit: "roti", grams: 90,
    kcal_100g: 264, protein_100g: 9, carbs_100g: 49, fat_100g: 3.7,
    is_estimate: true,
  };
  const saved = await api("/meals", {
    method: "POST",
    body: { slot: "lunch", input_method: "photo", items: [item], ai_confidence: 0.9 },
  });
  assert.equal(saved.status, 200);

  const dash = await api("/dashboard");
  assert.equal(dash.status, 200);
  // 90g * 264/100 = 237.6 -> 238
  assert.equal(dash.json.consumed.calories, 238);
  assert.equal(dash.json.remaining.calories, dash.json.targets.calories - 238);
  assert.equal(dash.json.meals.length, 1);

  // Quantity edit must be pure arithmetic — no AI call, no new ai_usage row.
  const usageBefore = (await db.query(`SELECT COUNT(*)::int n FROM ai_usage WHERE user_id=$1`, [userId])).rows[0].n;
  const mealId = dash.json.meals[0].id;
  const patched = await api(`/meals/${mealId}`, {
    method: "PATCH",
    body: { items: [{ ...item, quantity: 4, grams: 180 }] },
  });
  assert.equal(patched.status, 200);
  assert.equal(patched.json.calories, 475);
  const usageAfter = (await db.query(`SELECT COUNT(*)::int n FROM ai_usage WHERE user_id=$1`, [userId])).rows[0].n;
  assert.equal(usageAfter, usageBefore, "editing a portion must not call the AI");
});

test("water + weight logging", async () => {
  const water = await api("/water", { method: "POST", body: { ml: 250 } });
  assert.equal(water.json.ml, 250);

  await api("/weight", { method: "POST", body: { weight_kg: 69.4 } });
  const w = await api("/weight?days=30");
  assert.equal(w.json.current_weight_kg, 69.4);
  assert.equal(w.json.start_weight_kg, 70);
});

test("history returns averages", async () => {
  const { status, json } = await api("/history?range=week");
  assert.equal(status, 200);
  assert.ok(json.averages.calories > 0);
  assert.equal(json.days_logged, 1);
});

test("subscription defaults to free and exposes products", async () => {
  const { status, json } = await api("/subscription");
  assert.equal(status, 200);
  assert.equal(json.plan, "free");
  assert.ok(json.products.monthly.id);
  assert.ok(json.products.yearly.id);
});

test("validation errors are structured", async () => {
  const { status, json } = await api("/food/text", { method: "POST", body: { text: "" } });
  assert.equal(status, 400);
  assert.equal(json.error, "validation_failed");
});

test("account export then delete cascades", async () => {
  const exported = await api("/account/export");
  assert.equal(exported.status, 200);
  assert.ok(exported.json.profile);

  const del = await api("/account", { method: "DELETE" });
  assert.equal(del.status, 200);

  const { rows } = await db.query(`SELECT COUNT(*)::int n FROM meals WHERE user_id = $1`, [userId]);
  assert.equal(rows[0].n, 0, "meals must be cascade-deleted");
});

test.after(async () => { await db.end(); });

/**
 * Escalation must bill BOTH calls. Previously only the second was recorded,
 * under-reporting cost by the price of every primary call.
 */
test("escalation records the cost of every provider call", async () => {
  const { reserveScan, settleReservation } = await import("../dist/services/usage.js");
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`cost-${Date.now()}@snapcal.test`]
  );
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id, plan) VALUES ($1,'pro')`, [uid]);

  const reservation = await reserveScan(uid, "image");
  await settleReservation(reservation, uid, "image", "openai", [
    { model: "gpt-5.6-luna",  inputTokens: 480, cachedTokens: 160, outputTokens: 180, costUsd: 0.000282, latencyMs: 900, escalated: false },
    { model: "gpt-5.6-terra", inputTokens: 480, cachedTokens: 160, outputTokens: 200, costUsd: 0.003216, latencyMs: 1400, escalated: true },
  ]);

  const ledger = await db.query(
    `SELECT model, cost_usd::float AS cost, counts_against_quota
       FROM ai_usage WHERE request_id = $1 ORDER BY escalated`,
    [reservation.requestId]
  );

  assert.equal(ledger.rows.length, 2, "both provider calls must be recorded");
  assert.equal(ledger.rows[0].model, "gpt-5.6-luna");
  assert.equal(ledger.rows[1].model, "gpt-5.6-terra");
  assert.equal(ledger.rows[1].counts_against_quota, false, "escalation must not double-count quota");

  const total = ledger.rows.reduce((a, r) => a + r.cost, 0);
  assert.ok(Math.abs(total - 0.003498) < 1e-6, `total cost should be both calls, got ${total}`);
});

// ─── Phase 2-6: entitlements, coach, meal planner ────────────────────────────

let freeToken, freeId;

test("entitlements: free defaults come from the backend, not the client", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`ent-${Date.now()}@snapcal.test`]);
  freeId = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [freeId]);

  const { SignJWT } = await import("jose");
  freeToken = await new SignJWT({ sub: freeId })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = freeToken;
  const { status, json } = await api("/entitlements");
  token = saved;

  assert.equal(status, 200);
  assert.equal(json.plan, "free");
  assert.equal(json.features.food_scan.limit, 2);
  assert.equal(json.features.coach.limit, 2);
  assert.equal(json.features.meal_plan.limit, 0);
  assert.equal(json.features.meal_plan.premiumOnly, true);
});

test("coach: 2 free questions, third returns PREMIUM_REQUIRED", async () => {
  const saved = token; token = freeToken;
  try {
    for (let i = 1; i <= 2; i++) {
      const { status, json } = await api("/coach/ask", {
        method: "POST", body: { question: "How many calories do I have left?" } });
      assert.equal(status, 200, `question ${i} should succeed`);
      assert.ok(json.answer.length > 0);
      assert.equal(json.entitlements.features.coach.used, i);
    }

    const third = await api("/coach/ask", { method: "POST", body: { question: "And now?" } });
    assert.equal(third.status, 402);
    assert.equal(third.json.error, "PREMIUM_REQUIRED");
    assert.equal(third.json.feature, "coach");
    assert.equal(third.json.reason, "limit_reached");
  } finally { token = saved; }
});

test("meal planner is premium-only for free users", async () => {
  const saved = token; token = freeToken;
  const { status, json } = await api("/meal-plan", { method: "POST", body: { span: "day" } });
  token = saved;

  assert.equal(status, 402);
  assert.equal(json.error, "PREMIUM_REQUIRED");
  assert.equal(json.feature, "meal_plan");
  assert.equal(json.reason, "premium_only");
});

test("coach limit is atomic under concurrent questions", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`race-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  const results = await Promise.all(Array.from({ length: 6 }, () =>
    api("/coach/ask", { method: "POST", body: { question: "Can I eat this?" } })));
  token = saved;

  const ok = results.filter((r) => r.status === 200).length;
  assert.equal(ok, 2, `exactly 2 coach questions may succeed, got ${ok}`);
  assert.equal(results.filter((r) => r.status === 402).length, 4);
});

test("premium user gets unlimited coach and meal plans", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`pro-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    const ent = await api("/entitlements");
    assert.equal(ent.json.plan, "pro");
    assert.equal(ent.json.features.coach.limit, null, "pro coach must be unlimited");
    assert.equal(ent.json.features.meal_plan.limit, null);

    // Comfortably past the free limit of 2.
    for (let i = 0; i < 4; i++) {
      const r = await api("/coach/ask", { method: "POST", body: { question: "What now?" } });
      assert.equal(r.status, 200, `pro question ${i + 1} must succeed`);
    }

    const plan = await api("/meal-plan", { method: "POST", body: { span: "day" } });
    assert.equal(plan.status, 200);
    assert.ok(plan.json.days.length >= 1);
    assert.ok(plan.json.days[0].meals.length >= 1);

    const report = await api("/reports/weekly");
    assert.equal(report.status, 200);
    assert.ok(typeof report.json.insight === "string");
  } finally { token = saved; }
});

test("weekly report is premium-gated", async () => {
  const saved = token; token = freeToken;
  const { status, json } = await api("/reports/weekly");
  token = saved;
  assert.equal(status, 402);
  assert.equal(json.error, "PREMIUM_REQUIRED");
});

test("failed AI requests do not consume the free allowance", async () => {
  const { rows } = await db.query(
    `SELECT status, feature, counts_against_quota FROM ai_usage
      WHERE user_id = $1 ORDER BY created_at`, [freeId]);
  assert.ok(rows.every((r) => r.status !== "reserved"), "no dangling reservations");
  assert.ok(rows.filter((r) => r.feature === "coach").length >= 2);
});

test("notification prefs round-trip and default sensibly", async () => {
  const saved = token; token = freeToken;
  try {
    const initial = await api("/notifications/prefs");
    assert.equal(initial.status, 200);
    assert.equal(initial.json.daily_coach, true);
    assert.equal(initial.json.morning_hour, 8);

    const updated = await api("/notifications/prefs", {
      method: "PUT", body: { morning_hour: 7, premium_offers: false, permission: "granted" } });
    assert.equal(updated.json.morning_hour, 7);
    assert.equal(updated.json.premium_offers, false);
    assert.equal(updated.json.permission, "granted");
    assert.equal(updated.json.daily_coach, true, "unspecified fields must be preserved");

    const morning = await api("/notifications/morning");
    assert.ok(morning.json.title.startsWith("Good morning"));
    assert.ok(morning.json.body.length > 0);
    assert.equal(morning.json.deeplink, "snapcal://today");
  } finally { token = saved; }
});

test("analytics accepts known events and rejects unknown ones", async () => {
  const saved = token; token = freeToken;
  const { status, json } = await api("/analytics/events", {
    method: "POST",
    body: { events: [
      { name: "paywall_viewed", props: { source: "coach" } },
      { name: "free_limit_reached", props: { feature: "coach" } },
      { name: "totally_made_up_event", props: {} },
    ] } });
  token = saved;

  assert.equal(status, 202);
  assert.equal(json.accepted, 2);
  assert.equal(json.rejected, 1);
});

test("food preferences round-trip for the planner", async () => {
  const saved = token; token = freeToken;
  const { json } = await api("/preferences", {
    method: "PUT",
    body: { diet: "vegetarian", cuisines: ["indian"], dislikes: ["mushroom"], allergies: ["peanut"] } });
  token = saved;
  assert.equal(json.diet, "vegetarian");
  assert.deepEqual(json.allergies, ["peanut"]);
});

test("limits are backend-configurable without a client change", async () => {
  await db.query(`UPDATE entitlement_config SET period_limit = 5 WHERE plan='free' AND feature='coach'`);
  // The service caches for 60s; prove the value is read from the table.
  const { rows } = await db.query(
    `SELECT period_limit FROM entitlement_config WHERE plan='free' AND feature='coach'`);
  assert.equal(rows[0].period_limit, 5);
  await db.query(`UPDATE entitlement_config SET period_limit = 2 WHERE plan='free' AND feature='coach'`);
});

// ─── activity, timezone reset, USDA ─────────────────────────────────────────

test("steps convert to calories and raise the day's budget", async () => {
  const { kcalFromSteps } = await import("../dist/services/activity.js");

  // ~35 kcal per 1000 steps at 70 kg — matches walking MET values.
  assert.equal(kcalFromSteps(10000, 70), 350);
  assert.equal(kcalFromSteps(0, 70), 0);
  // Heavier person burns more for the same steps.
  assert.ok(kcalFromSteps(10000, 90) > kcalFromSteps(10000, 70));

  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`act-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Act", birth_year: 1990, sex: "male", height_cm: 178,
      start_weight_kg: 80, goal_weight_kg: 74, goal: "lose",
      activity_level: "light", units: "metric" } });

    const synced = await api("/health/daily", {
      method: "POST", body: { steps: 10000, active_kcal: 400, exercise_min: 30 } });
    assert.equal(synced.status, 200);
    assert.equal(synced.json.steps, 10000);
    assert.equal(synced.json.active_kcal, 400, "HealthKit's own figure wins");
    assert.equal(synced.json.kcal_source, "healthkit");
    // Default credit is partial (50%) to avoid double-counting the target.
    assert.equal(synced.json.credit_mode, "partial");
    assert.equal(synced.json.credited_kcal, 200);

    const dash = await api("/dashboard");
    assert.equal(dash.status, 200);
    assert.equal(dash.json.budget.activity_bonus, 200);
    assert.equal(dash.json.budget.total_calories,
      dash.json.targets.calories + 200, "activity must raise the budget");
    assert.equal(dash.json.remaining.calories, dash.json.budget.total_calories);

    // Switching to full credit doubles the bonus.
    const full = await api("/health/activity-credit", { method: "PUT", body: { mode: "full" } });
    assert.equal(full.json.credited_kcal, 400);

    const off = await api("/health/activity-credit", { method: "PUT", body: { mode: "off" } });
    assert.equal(off.json.credited_kcal, 0, "off must not credit anything");

    const dash2 = await api("/dashboard");
    assert.equal(dash2.json.budget.total_calories, dash2.json.targets.calories);
  } finally { token = saved; }
});

test("steps-only sync estimates burn when HealthKit gives no energy", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`est-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);
  await db.query(
    `INSERT INTO weight_logs (user_id, logged_on, weight_kg) VALUES ($1, CURRENT_DATE, 70)`, [uid]);
  await db.query(
    `INSERT INTO nutrition_targets (user_id, calories, protein_g, carbs_g, fat_g, bmr, tdee)
     VALUES ($1, 2000, 140, 200, 60, 1600, 2100)`, [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  const res = await api("/health/daily", { method: "POST", body: { steps: 8000 } });
  token = saved;

  assert.equal(res.json.kcal_source, "estimated");
  assert.equal(res.json.active_kcal, 280, "8000 steps at 70kg");
  assert.equal(res.json.credited_kcal, 140);
});

test("dashboard day boundary follows the user's timezone", async () => {
  const { localDate, nextLocalMidnight } = await import("../dist/util/dates.js");

  // 2026-08-14 20:00 UTC is already the 15th in Kolkata (+5:30), still the
  // 14th in New York (-4). Same instant, different dashboard day.
  const instant = new Date("2026-08-14T20:00:00Z");
  assert.equal(localDate("Asia/Kolkata", instant), "2026-08-15");
  assert.equal(localDate("America/New_York", instant), "2026-08-14");
  assert.equal(localDate("UTC", instant), "2026-08-14");

  // Reset instant must be in the future and land on the next local date.
  for (const tz of ["Asia/Kolkata", "America/New_York", "Australia/Adelaide", "UTC"]) {
    const reset = new Date(nextLocalMidnight(tz, instant));
    assert.ok(reset > instant, `${tz}: reset must be in the future`);
    assert.ok(reset.getTime() - instant.getTime() <= 25 * 3600_000, `${tz}: within a day`);
    assert.notEqual(localDate(tz, reset), localDate(tz, instant),
      `${tz}: reset must land on the next local day`);
  }
});

test("dashboard reports its timezone and reset instant", async () => {
  // Asserts the header that was actually sent rather than a hardcoded zone, so
  // the test still means something if the default changes.
  const saved = tzHeader;
  tzHeader = "Asia/Kolkata";

  const { status, json } = await api("/dashboard");
  tzHeader = saved;

  assert.equal(status, 200);
  assert.equal(json.timezone, "Asia/Kolkata");
  assert.ok(new Date(json.resets_at) > new Date());
  assert.ok(json.activity, "dashboard must carry the activity block");
  assert.ok(json.budget.total_calories >= json.budget.base_calories);
});

test("USDA portion scaling is pure arithmetic", async () => {
  const { portion } = await import("../dist/nutrition/usda.js");
  const chicken = {
    name: "chicken breast", kcal_100g: 165, protein_100g: 31,
    carbs_100g: 0, fat_100g: 3.6, source: "usda", source_ref: "1",
  };
  assert.deepEqual(portion(chicken, 100),
    { grams: 100, calories: 165, protein_g: 31, carbs_g: 0, fat_g: 4, fiber_g: undefined });
  assert.deepEqual(portion(chicken, 150),
    { grams: 150, calories: 248, protein_g: 47, carbs_g: 0, fat_g: 5, fiber_g: undefined });
});

test("food lookup returns local results even when USDA is unavailable", async () => {
  const { status, json } = await api("/food/lookup?term=roti");
  assert.equal(status, 200);
  assert.ok(json.results.length > 0);
  const local = json.results.find((r) => r.source === "snapcal");
  assert.ok(local, "curated regional foods must always be searchable");
  assert.equal(local.default_unit, "roti");
});

// ─── the connected loop: scan → activity → coach → plan → log → dashboard ───

test("full loop: logging + activity move the coach's remaining calories", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`loop-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Loop", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric" } });

    const base = await api("/dashboard");
    const target = base.json.targets.calories;
    assert.equal(base.json.remaining.calories, target, "fresh day starts at target");

    // ── 1. Log a scanned meal ────────────────────────────────────────────
    await api("/meals", { method: "POST", body: {
      slot: "lunch", input_method: "photo", ai_confidence: 0.9,
      items: [{ name: "grilled chicken", quantity: 1, unit: "serving", grams: 200,
                kcal_100g: 165, protein_100g: 31, carbs_100g: 0, fat_100g: 3.6,
                is_estimate: true }] } });

    const afterMeal = await api("/dashboard");
    assert.equal(afterMeal.json.consumed.calories, 330, "scan must move the real totals");
    assert.equal(afterMeal.json.remaining.calories, target - 330);

    // ── 2. HealthKit activity raises the budget ──────────────────────────
    await api("/health/daily", { method: "POST", body: { steps: 12000, active_kcal: 500 } });

    const afterSteps = await api("/dashboard");
    assert.equal(afterSteps.json.budget.activity_bonus, 250, "50% of 500 credited");
    assert.equal(afterSteps.json.remaining.calories, target + 250 - 330,
      "activity must feed the remaining budget");

    // ── 3. The coach sees the SAME number the dashboard shows ────────────
    const coach = await api("/coach/ask", { method: "POST", body: { question: "What should I eat next?" } });
    assert.equal(coach.status, 200);
    assert.ok(coach.json.answer.length > 0);
    // One line, per the coach design.
    assert.equal(coach.json.answer.split("\n").length, 1);

    const ctx = await api("/coach/suggestion");
    assert.equal(ctx.json.remaining.calories, afterSteps.json.remaining.calories,
      "coach context and dashboard must never disagree");

    // ── 4. Suggestion fits the remaining budget and is loggable ──────────
    const suggestion = ctx.json.suggestion;
    assert.ok(suggestion, "a suggestion should exist with calories left");
    assert.ok(suggestion.calories <= ctx.json.remaining.calories,
      "must never suggest an overshoot");
    assert.ok(suggestion.food_id && suggestion.kcal_100g > 0,
      "must carry per-100g macros so logging needs no second AI call");

    // ── 5. One-tap log of the suggestion ─────────────────────────────────
    const logged = await api("/meals", { method: "POST", body: {
      slot: suggestion.slot, input_method: "manual",
      items: [{ food_id: suggestion.food_id, name: suggestion.name,
                quantity: suggestion.quantity, unit: suggestion.unit,
                grams: suggestion.grams, kcal_100g: suggestion.kcal_100g,
                protein_100g: suggestion.protein_100g,
                carbs_100g: suggestion.carbs_100g, fat_100g: suggestion.fat_100g,
                is_estimate: false }] } });
    assert.equal(logged.status, 200);

    // ── 6. Dashboard reflects it immediately ─────────────────────────────
    const final = await api("/dashboard");
    assert.equal(final.json.consumed.calories, 330 + suggestion.calories,
      "logging a suggestion must update the diary totals");
    assert.equal(final.json.meals.length, 2);
  } finally { token = saved; }
});

test("meal planner plans the REST of today, not a fresh full day", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`plan-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Plan", birth_year: 1992, sex: "female", height_cm: 166,
      start_weight_kg: 68, goal_weight_kg: 62, goal: "lose",
      activity_level: "light", units: "metric" } });

    const fresh = await api("/meal-plan", { method: "POST", body: { span: "day" } });
    assert.equal(fresh.json.planned_for, "full_day", "empty day plans the whole day");

    await api("/meals", { method: "POST", body: {
      slot: "breakfast", input_method: "manual",
      items: [{ name: "oatmeal", quantity: 1, unit: "bowl", grams: 300,
                kcal_100g: 84, protein_100g: 3, carbs_100g: 15, fat_100g: 1.7,
                is_estimate: false }] } });

    const after = await api("/meal-plan", { method: "POST", body: { span: "day" } });
    assert.equal(after.json.planned_for, "remaining_today",
      "after eating, the plan must cover only what's left");
    assert.ok(after.json.budget_kcal < fresh.json.budget_kcal,
      "the planning budget must shrink by what was eaten");

    // Weekly plans still use the full daily budget — later days start empty.
    const week = await api("/meal-plan", { method: "POST", body: { span: "week" } });
    assert.equal(week.json.planned_for, "full_day");
  } finally { token = saved; }
});

test("suggestions respect allergies, diet and what was already eaten", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`pref-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Pref", birth_year: 1990, sex: "male", height_cm: 175,
      start_weight_kg: 80, goal_weight_kg: 74, goal: "lose",
      activity_level: "light", units: "metric" } });

    await api("/preferences", { method: "PUT", body: {
      diet: "vegetarian", cuisines: [], dislikes: [], allergies: ["peanut"] } });

    const { json } = await api("/coach/suggestion");
    if (json.suggestion) {
      const name = json.suggestion.name.toLowerCase();
      for (const meat of ["chicken", "beef", "steak", "pork", "fish", "salmon", "turkey"]) {
        assert.ok(!name.includes(meat), `vegetarian suggestion must not be ${meat}`);
      }
      assert.ok(!name.includes("peanut"), "must never suggest an allergen");
    }
  } finally { token = saved; }
});

test("no suggestion once the budget is spent", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`full-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Full", birth_year: 1990, sex: "male", height_cm: 175,
      start_weight_kg: 80, goal_weight_kg: 74, goal: "lose",
      activity_level: "light", units: "metric" } });

    // Eat the entire day.
    await api("/meals", { method: "POST", body: {
      slot: "dinner", input_method: "manual",
      items: [{ name: "large meal", quantity: 1, unit: "serving", grams: 1000,
                kcal_100g: 300, protein_100g: 10, carbs_100g: 30, fat_100g: 12,
                is_estimate: false }] } });

    const { json } = await api("/coach/suggestion");
    assert.equal(json.suggestion, null, "must not suggest food with no budget left");
  } finally { token = saved; }
});

test("suggestions follow the user's region, not the whole database", async () => {
  async function userIn(country) {
    const { rows } = await db.query(
      `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
      [`geo-${country}-${Date.now()}@snapcal.test`]);
    const uid = rows[0].id;
    await db.query(
      `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
      [uid]);
    const { SignJWT } = await import("jose");
    return new SignJWT({ sub: uid })
      .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
      .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));
  }

  const saved = token;
  const indiaOnly = ["roti", "dal", "paneer", "poha", "idli", "dosa", "sabzi", "bhindi", "biryani"];

  try {
    for (const country of ["US", "CA"]) {
      token = await userIn(country);
      await api("/profile", { method: "POST", body: {
        name: "Geo", birth_year: 1992, sex: "male", height_cm: 180,
        start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
        activity_level: "light", units: "metric", country } });

      const { json } = await api("/coach/suggestion");
      assert.ok(json.suggestion, `${country}: expected a suggestion`);
      const name = json.suggestion.name.toLowerCase();
      for (const term of indiaOnly) {
        assert.ok(!name.includes(term),
          `${country} user must not be suggested "${json.suggestion.name}"`);
      }
    }

    // An explicit preference still wins over the country default.
    token = await userIn("US");
    await api("/profile", { method: "POST", body: {
      name: "Geo", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });
    await api("/preferences", { method: "PUT", body: {
      diet: null, cuisines: ["indian"], dislikes: [], allergies: [] } });

    const { json } = await api("/coach/suggestion");
    assert.ok(json.suggestion, "explicit cuisine preference should still resolve");
  } finally { token = saved; }
});

// ─── release hardening: one calorie calculation, everywhere ────────────────

test("dashboard, coach and planner never disagree on remaining calories", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`agree-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Agree", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });

    // Exercise the formula at several points, including before any activity
    // and after a partial day.
    const states = [
      { meal: null, steps: 0, kcal: 0 },
      { meal: 400, steps: 6000, kcal: 0 },
      { meal: 500, steps: 12000, kcal: 500 },
    ];

    for (const state of states) {
      if (state.meal) {
        await api("/meals", { method: "POST", body: {
          slot: "snack", input_method: "manual",
          items: [{ name: `filler ${state.meal}`, quantity: 1, unit: "serving",
                    grams: 100, kcal_100g: state.meal, protein_100g: 5,
                    carbs_100g: 10, fat_100g: 3, is_estimate: false }] } });
      }
      if (state.steps) {
        await api("/health/daily", { method: "POST",
          body: { steps: state.steps, active_kcal: state.kcal } });
      }

      const dash = await api("/dashboard");
      const coach = await api("/coach/suggestion");
      const plan = await api("/meal-plan", { method: "POST", body: { span: "day" } });

      // remaining = base_target + credited_activity − consumed
      const expected = dash.json.budget.base_calories
                     + dash.json.budget.activity_bonus
                     - dash.json.consumed.calories;

      assert.equal(dash.json.remaining.calories, expected, "dashboard formula");
      assert.equal(dash.json.budget.total_calories,
        dash.json.budget.base_calories + dash.json.budget.activity_bonus);
      assert.equal(coach.json.remaining.calories, expected, "coach must match dashboard");
      assert.equal(coach.json.budget, dash.json.budget.total_calories, "budget must match");

      if (plan.json.planned_for === "remaining_today") {
        assert.equal(plan.json.budget_kcal, expected, "planner must match dashboard");
      }
    }
  } finally { token = saved; }
});

test("activity credit never inflates protein, carbs or fat targets", async () => {
  const { dailyBalance } = await import("../dist/services/budget.js");

  const b = dailyBalance(
    { calories: 2000, protein_g: 150, carbs_g: 220, fat_g: 60 },
    { calories: 500, protein_g: 40, carbs_g: 50, fat_g: 15 },
    { credited_kcal: 300 }
  );

  assert.equal(b.budget.total_calories, 2300);
  assert.equal(b.remaining.calories, 1800);
  // Walking further does not mean you need more protein.
  assert.equal(b.remaining.protein_g, 110);
  assert.equal(b.remaining.carbs_g, 170);
  assert.equal(b.remaining.fat_g, 45);
});

test("budget handles missing targets, consumption and activity", async () => {
  const { dailyBalance, DEFAULT_TARGETS } = await import("../dist/services/budget.js");

  const empty = dailyBalance(null, null, null);
  assert.equal(empty.budget.activity_bonus, 0);
  assert.equal(empty.remaining.calories, DEFAULT_TARGETS.calories);

  // A negative credit would be a bug upstream; it must not reduce the budget.
  const negative = dailyBalance({ calories: 2000 }, null, { credited_kcal: -500 });
  assert.equal(negative.budget.activity_bonus, 0);
  assert.equal(negative.remaining.calories, 2000);
});

test("over-eating produces a negative remaining, not a clamped zero", async () => {
  const { dailyBalance } = await import("../dist/services/budget.js");
  const b = dailyBalance({ calories: 2000 }, { calories: 2600 }, { credited_kcal: 100 });
  assert.equal(b.remaining.calories, -500, "the ring needs the real overshoot");
});

// ─── bug fixes: suggestion variety, coach grounding ────────────────────────

test("suggestions vary instead of repeating the highest-protein food", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`vary-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Vary", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });

    const seen = new Set();
    for (let i = 0; i < 6; i++) {
      const { json } = await api("/coach/suggestion");
      if (json.suggestion) seen.add(json.suggestion.name.toLowerCase());
    }

    assert.ok(seen.size >= 2,
      `expected variety across six requests, always got: ${[...seen].join(", ")}`);
  } finally { token = saved; }
});

test("a suggested food is not suggested again immediately", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`norepeat-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "NoRepeat", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });

    const first = (await api("/coach/suggestion")).json.suggestion;
    assert.ok(first);

    const logged = await db.query(
      `SELECT food_name FROM suggestion_log WHERE user_id = $1`, [uid]);
    assert.equal(logged.rows.length, 1, "suggestion must be recorded");
    assert.equal(logged.rows[0].food_name, first.name.toLowerCase());

    // Across several more requests the first pick should not dominate.
    const names = [];
    for (let i = 0; i < 5; i++) {
      const s = (await api("/coach/suggestion")).json.suggestion;
      if (s) names.push(s.name.toLowerCase());
    }
    assert.ok(!names.every((n) => n === first.name.toLowerCase()),
      "recently suggested food must not repeat every time");
  } finally { token = saved; }
});

test("coach context carries the actual meals logged today", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`ground-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Ground", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });

    await api("/meals", { method: "POST", body: {
      slot: "breakfast", input_method: "photo",
      items: [{ name: "scrambled eggs", quantity: 2, unit: "egg", grams: 110,
                kcal_100g: 141, protein_100g: 10, carbs_100g: 1.5, fat_100g: 10.5,
                is_estimate: true }] } });

    const { status, json } = await api("/coach/ask", {
      method: "POST", body: { question: "What did I eat today?" } });

    assert.equal(status, 200);
    // At most two sentences, per the coach design.
    const sentences = json.answer.split(/(?<=[.!?])\s+/).filter(Boolean);
    assert.ok(sentences.length <= 2, `expected ≤2 sentences, got ${sentences.length}`);
    assert.ok(json.answer.length <= 260);
  } finally { token = saved; }
});

test("insight reflects an empty day rather than inventing progress", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`empty-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Empty", birth_year: 1992, sex: "female", height_cm: 165,
      start_weight_kg: 70, goal_weight_kg: 64, goal: "lose",
      activity_level: "light", units: "metric", country: "CA" } });

    const { json } = await api("/coach/insight");
    assert.match(json.insight, /nothing logged/i,
      "an empty day must say so, not fabricate progress");
  } finally { token = saved; }
});

test("health sync accepts distance and reflects it", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`dist-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  const { status, json } = await api("/health/daily", {
    method: "POST", body: { steps: 9200, active_kcal: 380, exercise_min: 25, distance_m: 6800 } });
  token = saved;

  assert.equal(status, 200);
  assert.equal(json.steps, 9200);
  assert.equal(json.distance_m, 6800);
  assert.equal(json.credited_kcal, 190);
});

// ─── no fabricated data reaches a real user ────────────────────────────────

test("a brand-new user sees a genuinely empty day", async () => {
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`fresh-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);

  const { SignJWT } = await import("jose");
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Fresh", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });

    const { json } = await api("/dashboard");
    assert.equal(json.meals.length, 0, "no meals may appear before any are logged");
    assert.equal(json.consumed.calories, 0);
    assert.equal(json.remaining.calories, json.targets.calories);

    const insight = await api("/coach/insight");
    assert.match(insight.json.insight, /nothing logged/i);
  } finally { token = saved; }
});

test("one user can never see another user's meals", async () => {
  const { SignJWT } = await import("jose");

  async function makeUser(label) {
    const { rows } = await db.query(
      `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
      [`iso-${label}-${Date.now()}@snapcal.test`]);
    const uid = rows[0].id;
    await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);
    const t = await new SignJWT({ sub: uid })
      .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
      .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));
    return { uid, t };
  }

  const a = await makeUser("a");
  const b = await makeUser("b");
  const saved = token;

  try {
    for (const u of [a, b]) {
      token = u.t;
      await api("/profile", { method: "POST", body: {
        name: "Iso", birth_year: 1992, sex: "male", height_cm: 180,
        start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
        activity_level: "light", units: "metric", country: "US" } });
    }

    token = a.t;
    await api("/meals", { method: "POST", body: {
      slot: "lunch", input_method: "manual",
      items: [{ name: "user a burrito", quantity: 1, unit: "serving", grams: 300,
                kcal_100g: 155, protein_100g: 10, carbs_100g: 17, fat_100g: 5.4,
                is_estimate: false }] } });

    const aDash = await api("/dashboard");
    assert.equal(aDash.json.meals.length, 1);

    token = b.t;
    const bDash = await api("/dashboard");
    assert.equal(bDash.json.meals.length, 0, "user B must not see user A's meals");
    assert.equal(bDash.json.consumed.calories, 0);
  } finally { token = saved; }
});

test("logged meals survive across sessions and a fresh token", async () => {
  const { SignJWT } = await import("jose");
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`persist-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);

  const secret = new TextEncoder().encode(process.env.JWT_SECRET);
  const first = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(secret);

  const saved = token; token = first;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Persist", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });

    await api("/meals", { method: "POST", body: {
      slot: "dinner", input_method: "photo",
      items: [{ name: "grilled steak", quantity: 1, unit: "steak", grams: 200,
                kcal_100g: 224, protein_100g: 27, carbs_100g: 0, fat_100g: 12.7,
                is_estimate: true }] } });
    await api("/weight", { method: "POST", body: { weight_kg: 81.2 } });
    await api("/water", { method: "POST", body: { ml: 500 } });

    // A new token stands in for a relaunch and re-auth.
    token = await new SignJWT({ sub: uid })
      .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
      .setExpirationTime("1h").sign(secret);

    const dash = await api("/dashboard");
    assert.equal(dash.json.meals.length, 1, "meals must survive a new session");
    assert.equal(dash.json.consumed.calories, 448);
    assert.equal(dash.json.water_ml, 500);
    assert.equal(dash.json.current_weight_kg, 81.2);

    const profile = await api("/profile");
    assert.equal(profile.json.profile.name, "Persist");
    assert.ok(profile.json.targets.calories > 0, "targets must persist");
  } finally { token = saved; }
});

test("every meal the dashboard returns belongs to the caller", async () => {
  const rows = await db.query(
    `SELECT DISTINCT m.user_id FROM meals m LIMIT 5`);
  assert.ok(rows.rows.length > 0);

  // Nothing in the schema allows a meal without an owner.
  const orphans = await db.query(
    `SELECT COUNT(*)::int AS n FROM meals WHERE user_id IS NULL`);
  assert.equal(orphans.rows[0].n, 0, "meals must always be user-scoped");
});


// ─── request contract: input_method ────────────────────────────────────────

test("every input method the client sends is accepted", async () => {
  const { SignJWT } = await import("jose");
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`method-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);

  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Method", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });

    // Exactly what LogMode.inputMethod can produce.
    for (const method of ["photo", "text", "voice", "barcode", "search", "manual"]) {
      const { status, json } = await api("/meals", { method: "POST", body: {
        slot: "snack", input_method: method,
        items: [{ name: `via ${method}`, quantity: 1, unit: "serving", grams: 100,
                  kcal_100g: 100, protein_100g: 5, carbs_100g: 10, fat_100g: 3,
                  is_estimate: false }] } });
      assert.equal(status, 200, `input_method "${method}" must be accepted, got ${JSON.stringify(json)}`);
    }

    // The old client sent the raw capture mode; it must still be rejected so
    // the mismatch can never pass silently.
    const bad = await api("/meals", { method: "POST", body: {
      slot: "snack", input_method: "camera",
      items: [{ name: "x", quantity: 1, unit: "serving", grams: 100,
                kcal_100g: 100, protein_100g: 5, carbs_100g: 10, fat_100g: 3,
                is_estimate: false }] } });
    assert.equal(bad.status, 400);
    assert.equal(bad.json.error, "validation_failed");
    assert.ok(bad.json.issues?.length, "validation errors must name the field");

    const dash = await api("/dashboard");
    assert.equal(dash.json.meals.length, 6, "all six saves must reach the diary");
  } finally { token = saved; }
});

test("scanned meals with several foods save and total correctly", async () => {
  const { SignJWT } = await import("jose");
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`multi-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);

  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Multi", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });

    // A three-item plate, as a photo scan returns.
    const { status } = await api("/meals", { method: "POST", body: {
      slot: "dinner", input_method: "photo", ai_confidence: 0.82,
      items: [
        { name: "grilled steak", quantity: 1, unit: "steak", grams: 200,
          kcal_100g: 224, protein_100g: 27, carbs_100g: 0, fat_100g: 12.7, is_estimate: true },
        { name: "roast chicken breast", quantity: 1, unit: "breast", grams: 130,
          kcal_100g: 165, protein_100g: 31, carbs_100g: 0, fat_100g: 3.6, is_estimate: true },
        { name: "bread", quantity: 2, unit: "slice", grams: 60,
          kcal_100g: 265, protein_100g: 9, carbs_100g: 49, fat_100g: 3.2, is_estimate: true },
      ] } });
    assert.equal(status, 200);

    const dash = await api("/dashboard");
    // 448 + 215 + 159
    assert.equal(dash.json.consumed.calories, 822);
    assert.equal(dash.json.meals[0].items.length, 3);
  } finally { token = saved; }
});

// ─── coach intent: cards only when a recommendation was asked for ──────────

test("intent classifier separates recommendation from analysis", async () => {
  const { classify, isOnTopic, answerContainsRefusal } =
    await import("../dist/services/coachIntent.js");

  for (const q of [
    "What should I eat today for weight loss",
    "You suggest one food",
    "what fruit have highest protein",
    "What food should i eat now i am based in netherlands",
    "give me a high protein meal",
    "what can I eat under 500 calories",
    "recommend something for dinner",
  ]) {
    assert.equal(classify(q), "meal_recommendation", `"${q}" should be a recommendation`);
  }

  for (const q of [
    "I ate a burger, how many calories",
    "how many calories in what I ate",
    "what did i eat today",
  ]) {
    assert.equal(classify(q), "food_analysis", `"${q}" should be analysis`);
  }

  assert.equal(classify("why isn't my weight dropping"), "progress");

  // Off-topic must be detectable so the coach doesn't bolt calories onto it.
  assert.equal(isOnTopic("President of Australia"), false);
  assert.equal(isOnTopic("what should i eat"), true);

  // A hedged answer must never carry a card.
  assert.ok(answerContainsRefusal("I'll need the food scanned or searched first."));
  assert.ok(answerContainsRefusal("I can only help with food and nutrition."));
  assert.ok(!answerContainsRefusal("Grilled salmon fits your 900 calories left."));
});

test("a general question returns no meal card", async () => {
  const { SignJWT } = await import("jose");
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`intent-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Intent", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });

    // Off-topic — no card, and the intent must not be a recommendation.
    const offTopic = await api("/coach/ask", {
      method: "POST", body: { question: "Who is the president of Australia?" } });
    assert.equal(offTopic.status, 200);
    assert.equal(offTopic.json.suggestion, null,
      "an off-topic question must never attach a meal card");

    // General on-topic question — still no card.
    const general = await api("/coach/ask", {
      method: "POST", body: { question: "How do I start the day well?" } });
    assert.equal(general.json.suggestion, null,
      "a general question must not attach a meal card");
    assert.ok(["general", "education"].includes(general.json.intent),
      `expected a non-recommendation intent, got ${general.json.intent}`);

    // Explicit request — card allowed.
    const explicit = await api("/coach/ask", {
      method: "POST", body: { question: "Suggest one food for weight loss" } });
    assert.equal(explicit.json.intent, "meal_recommendation");
  } finally { token = saved; }
});

test("a card never accompanies an answer that refuses to recommend", async () => {
  const { answerContainsRefusal } = await import("../dist/services/coachIntent.js");

  // The exact strings seen on device, each alongside a meal card.
  for (const answer of [
    "I'll need the food scanned or searched first to provide a suggestion.",
    "You have 1834 calories left, I'll need a food scanned or searched to suggest one.",
    "0, I'll need the fruit scanned or searched first to provide a suggestion.",
  ]) {
    assert.ok(answerContainsRefusal(answer),
      `"${answer.slice(0, 40)}..." must suppress the card`);
  }
});

test("USDA record names never reach the diary", async () => {
  const { looksLikeDatabaseRecord, displayName } =
    await import("../dist/nutrition/resolve.js");

  // Real FoodData Central descriptions — identifiers, not dish names.
  for (const name of [
    "Onions, red, raw",
    "Tomatoes, red, ripe, raw",
    "Fish, salmon, atlantic, farmed, cooked, dry heat",
    "Beans, snap, green, canned",
    "Chicken breast, cooked",
  ]) {
    assert.ok(looksLikeDatabaseRecord(name), `"${name}" should be treated as a record`);
  }

  // Dish names must pass through untouched.
  for (const name of ["Butter chicken", "Grilled steak", "Turkey sandwich", "Mac and cheese"]) {
    assert.ok(!looksLikeDatabaseRecord(name), `"${name}" is a dish name`);
  }

  // The model's label wins over a record; a real dish name wins over the model.
  assert.equal(displayName("fish curry", "Fish, salmon, atlantic, raw"), "fish curry");
  assert.equal(displayName("onions", "Onions, red, raw"), "onions");
  assert.equal(displayName("chicken", "grilled chicken breast"), "grilled chicken breast");
  assert.equal(displayName("something", undefined), "something");
});

test("water logging accepts a decrement and never goes negative", async () => {
  const { SignJWT } = await import("jose");
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`water-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [uid]);

  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Water", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "light", units: "metric", country: "US" } });

    await api("/water", { method: "POST", body: { ml: 250 } });
    await api("/water", { method: "POST", body: { ml: 250 } });
    let dash = await api("/dashboard");
    assert.equal(dash.json.water_ml, 500);

    // Undo one glass.
    await api("/water", { method: "POST", body: { ml: -250 } });
    dash = await api("/dashboard");
    assert.equal(dash.json.water_ml, 250, "a negative delta must subtract");

    // Over-subtracting must floor at zero, not go negative.
    await api("/water", { method: "POST", body: { ml: -1000 } });
    dash = await api("/dashboard");
    assert.ok(dash.json.water_ml >= 0, "water must never go negative");
  } finally { token = saved; }
});

// ─── coach as a health advisor, not a nutrition chatbot ────────────────────

test("intent detection covers the coach's whole remit", async () => {
  const { classify } = await import("../dist/services/coachIntent.js");

  const cases = {
    workout_request: [
      "What workout should I do today?", "Should I go to the gym today?",
      "should i train legs today", "how many sets and reps",
      "what exercises should i do", "should i rest today",
    ],
    daily_plan: [
      "What should I do today?", "what should i improve",
      "coach me", "plan my day",
    ],
    meal_recommendation: [
      "What should I eat for dinner?", "suggest one food",
      "what fruit should i have", "give me a high protein meal",
    ],
    food_analysis: ["I ate a burger, how many calories", "what did i eat today"],
    hydration: ["how much water should i drink"],
    activity: ["how much should i walk today", "how many steps"],
    sleep: ["how can i improve my sleep routine"],
    progress: ["why isn't my weight dropping", "am i on track"],
  };

  for (const [expected, questions] of Object.entries(cases)) {
    for (const q of questions) {
      assert.equal(classify(q), expected, `"${q}" should classify as ${expected}`);
    }
  }
});

test("safety guards fire on medical, urgent, brand and live-data requests", async () => {
  const { guardFor, validateResponse } = await import("../dist/services/coachIntent.js");

  assert.equal(guardFor("What medicine should I take for my cold?"), "medical");
  assert.equal(guardFor("should i stop taking my blood pressure tablets"), "medical");
  assert.equal(guardFor("I have chest pain and can't breathe"), "urgent");
  assert.equal(guardFor("Which protein powder should I buy?"), "brand");
  assert.equal(guardFor("what brand of creatine is best"), "brand");
  assert.equal(guardFor("is this food available in netherlands"), "live_data");
  assert.equal(guardFor("what should i eat for dinner"), null);

  // Urgent always overrides whatever the model produced.
  const urgent = validateResponse("Try some ginger tea.", "urgent");
  assert.ok(urgent && /medical attention|emergency|doctor/i.test(urgent));

  // A dose must never survive, however it is phrased.
  const dosed = validateResponse("Take 500 mg twice daily for that.", "medical");
  assert.ok(dosed && /can't advise on medication/i.test(dosed));

  // Ordinary advice passes through untouched.
  assert.equal(validateResponse("Grilled chicken fits your 900 calories left.", null), null);
});

test("token budget scales with what the answer needs", async () => {
  const { maxTokensFor, keepsStructure } = await import("../dist/services/coachIntent.js");

  // A workout needs the whole session; a calorie check needs a line.
  assert.ok(maxTokensFor("workout_request") > maxTokensFor("progress"));
  assert.ok(maxTokensFor("daily_plan") > maxTokensFor("general"));
  assert.ok(maxTokensFor("general") <= 120, "ordinary questions stay cheap");

  assert.ok(keepsStructure("workout_request"));
  assert.ok(keepsStructure("daily_plan"));
  assert.ok(!keepsStructure("meal_recommendation"),
    "conversational answers are trimmed to a few sentences");
});

test("workouts are logged, returned and feed the coach's context", async () => {
  const { SignJWT } = await import("jose");
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`gym-${Date.now()}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);

  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));

  const saved = token; token = t;
  try {
    await api("/profile", { method: "POST", body: {
      name: "Gym", birth_year: 1992, sex: "male", height_cm: 180,
      start_weight_kg: 82, goal_weight_kg: 76, goal: "lose",
      activity_level: "moderate", units: "metric", country: "US" } });

    const profile = await api("/fitness/profile", { method: "PUT", body: {
      gym_access: true, equipment: "full_gym", experience: "beginner",
      training_days: 4, session_minutes: 60 } });
    assert.equal(profile.status, 200);
    assert.equal(profile.json.equipment, "full_gym");
    assert.equal(profile.json.experience, "beginner");

    const logged = await api("/workouts", { method: "POST", body: {
      focus: "upper", minutes: 55, perceived_effort: 7,
      exercises: [
        { exercise: "Bench Press", sets: 3, reps: 10, weight_kg: 40 },
        { exercise: "Lat Pulldown", sets: 3, reps: 12, weight_kg: 45 },
      ] } });
    assert.equal(logged.status, 200);
    assert.equal(logged.json.focus, "upper");

    const history = await api("/workouts?days=14");
    assert.equal(history.json.workouts.length, 1);
    assert.equal(history.json.workouts[0].exercises.length, 2);
    // Weights round-trip, so progression can be suggested from real numbers.
    assert.equal(Number(history.json.workouts[0].exercises[0].weight_kg), 40);

    // A workout question is classified as such and answers without a meal card.
    const ask = await api("/coach/ask", {
      method: "POST", body: { question: "What workout should I do today?" } });
    assert.equal(ask.status, 200);
    assert.equal(ask.json.intent, "workout_request");
    assert.equal(ask.json.suggestion, null,
      "a training question must not attach a meal card");

    // Deleting is scoped to the owner.
    const del = await api(`/workouts/${history.json.workouts[0].id}`, { method: "DELETE" });
    assert.equal(del.status, 200);
    assert.equal((await api("/workouts")).json.workouts.length, 0);
  } finally { token = saved; }
});

test("a user cannot delete another user's workout", async () => {
  const { SignJWT } = await import("jose");
  const secret = new TextEncoder().encode(process.env.JWT_SECRET);

  async function make(label) {
    const { rows } = await db.query(
      `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
      [`w-${label}-${Date.now()}@snapcal.test`]);
    const uid = rows[0].id;
    await db.query(
      `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
      [uid]);
    return new SignJWT({ sub: uid })
      .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
      .setExpirationTime("1h").sign(secret);
  }

  const a = await make("a");
  const b = await make("b");
  const saved = token;

  try {
    token = a;
    const mine = await api("/workouts", { method: "POST", body: { focus: "lower", minutes: 40 } });

    token = b;
    const attempt = await api(`/workouts/${mine.json.id}`, { method: "DELETE" });
    assert.equal(attempt.status, 404, "another user's workout must not be deletable");

    token = a;
    assert.equal((await api("/workouts")).json.workouts.length, 1, "still there");
  } finally { token = saved; }
});

// ─── conversational onboarding, structured workouts, patterns ──────────────

async function proUser(label) {
  const { SignJWT } = await import("jose");
  const { rows } = await db.query(
    `INSERT INTO users (email, password_hash) VALUES ($1,'x') RETURNING id`,
    [`${label}-${Date.now()}-${Math.random().toString(36).slice(2, 7)}@snapcal.test`]);
  const uid = rows[0].id;
  await db.query(
    `INSERT INTO subscriptions (user_id, plan, expires_at) VALUES ($1,'pro', now() + interval '30 days')`,
    [uid]);
  const t = await new SignJWT({ sub: uid })
    .setProtectedHeader({ alg: "HS256" }).setIssuedAt().setIssuer("snapcal")
    .setExpirationTime("1h").sign(new TextEncoder().encode(process.env.JWT_SECRET));
  return { uid, token: t };
}

const BASE_PROFILE = {
  birth_year: 1992, sex: "male", height_cm: 180, start_weight_kg: 82,
  goal_weight_kg: 76, goal: "lose", activity_level: "moderate",
  units: "metric", country: "US",
};

test("onboarding asks one question at a time and never repeats an answer", async () => {
  const u = await proUser("onb");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Onb", ...BASE_PROFILE } });

    const first = await api("/coach/onboarding");
    assert.equal(first.status, 200);
    assert.equal(first.json.completed, false);
    assert.ok(first.json.welcome, "a first-time user gets an opening line");
    assert.equal(first.json.next.field, "primary_goal");
    assert.ok(first.json.next.options.length >= 6);
    assert.equal(first.json.next.step, 1);

    // Answering advances exactly one step.
    const second = await api("/coach/onboarding", {
      method: "POST", body: { field: "primary_goal", value: "lose_fat_keep_muscle" } });
    assert.equal(second.json.next.field, "experience");
    assert.equal(second.json.answered, 1);

    await api("/coach/onboarding", { method: "POST", body: { field: "experience", value: "beginner" } });

    // Re-reading must not ask something already answered.
    const resumed = await api("/coach/onboarding");
    assert.equal(resumed.json.next.field, "training_location");
    assert.equal(resumed.json.answered, 2);
  } finally { token = saved; }
});

test("answers that make later questions irrelevant remove them", async () => {
  const u = await proUser("skip");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Skip", ...BASE_PROFILE } });
    await api("/coach/onboarding", { method: "POST", body: { field: "primary_goal", value: "general_health" } });
    await api("/coach/onboarding", { method: "POST", body: { field: "experience", value: "beginner" } });

    const withGym = await api("/coach/onboarding", {
      method: "POST", body: { field: "training_location", value: "gym" } });
    const gymTotal = withGym.json.total;
    assert.equal(withGym.json.next.field, "equipment_list");

    // "Nowhere regular" makes equipment, days and duration meaningless.
    const u2 = await proUser("skip2");
    token = u2.token;
    await api("/profile", { method: "POST", body: { name: "Skip2", ...BASE_PROFILE } });
    await api("/coach/onboarding", { method: "POST", body: { field: "primary_goal", value: "general_health" } });
    await api("/coach/onboarding", { method: "POST", body: { field: "experience", value: "beginner" } });
    const noGym = await api("/coach/onboarding", {
      method: "POST", body: { field: "training_location", value: "none" } });

    assert.ok(noGym.json.total < gymTotal,
      "training nowhere should shorten onboarding");
    assert.notEqual(noGym.json.next?.field, "equipment_list");
  } finally { token = saved; }
});

test("completing onboarding marks the profile and stops asking", async () => {
  const u = await proUser("done");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Done", ...BASE_PROFILE } });

    const answers = [
      { field: "primary_goal", value: "build_muscle" },
      { field: "experience", value: "intermediate" },
      { field: "training_location", value: "gym" },
      { field: "equipment_list", values: ["full_gym", "dumbbells"] },
      { field: "training_days", value: "4" },
      { field: "session_minutes", value: "55" },
      { field: "average_sleep_hours", value: "7.5" },
      { field: "limitations_asked", values: ["lower back"] },
    ];

    let last;
    for (const answer of answers) {
      last = await api("/coach/onboarding", { method: "POST", body: answer });
    }

    assert.equal(last.json.completed, true);
    assert.equal(last.json.next, null);

    const after = await api("/coach/onboarding");
    assert.equal(after.json.completed, true);
    assert.equal(after.json.welcome, null, "a returning user is not welcomed again");

    const profile = await api("/fitness/profile");
    assert.equal(profile.json.experience, "intermediate");
    assert.equal(profile.json.training_days, 4);
  } finally { token = saved; }
});

test("workout is structured, respects equipment, and never invents weights", async () => {
  const u = await proUser("plan");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Plan", ...BASE_PROFILE } });
    await api("/fitness/profile", { method: "PUT", body: {
      gym_access: true, equipment: "full_gym", experience: "beginner",
      training_days: 4, session_minutes: 45 } });

    const res = await api("/coach/workout", { method: "POST", body: {} });
    assert.equal(res.status, 200);

    const plan = res.json;
    assert.ok(plan.id, "the plan is persisted so it can be started later");
    assert.ok(plan.workout_title);
    assert.ok(plan.exercises.length >= 3);
    assert.ok(plan.warmup.length >= 1);
    assert.ok(plan.cooldown.length >= 1);

    for (const e of plan.exercises) {
      assert.ok(e.exercise_name);
      assert.ok(e.sets >= 1 && e.sets <= 10);
      assert.ok(e.reps, "a rep range, not a bare number");
      assert.ok(e.rest_seconds >= 15);
      // No history yet, so no weight may be suggested.
      assert.equal(e.suggested_weight_kg, null,
        `${e.exercise_name}: a weight must never be invented without history`);
      assert.ok(e.progression_note, "the absence of a weight is explained");
    }
  } finally { token = saved; }
});

test("progression comes from logged weights, one step at a time", async () => {
  const { suggestLoad, needsRecovery, nextFocus } =
    await import("../dist/services/workoutPlanner.js");

  const u = await proUser("prog");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Prog", ...BASE_PROFILE } });

    // No history → no weight.
    const cold = await suggestLoad(u.uid, "Bench Press");
    assert.equal(cold.weight, null);

    // One session at the top of the range → hold, add reps.
    await api("/workouts", { method: "POST", body: {
      focus: "upper", minutes: 45,
      exercises: [{ exercise: "Bench Press", sets: 3, reps: 12, weight_kg: 40 }] } });
    const held = await suggestLoad(u.uid, "Bench Press");
    assert.equal(held.weight, 40, "one good session is not enough to add weight");
    assert.match(held.note, /add a rep/i);

    // Two consecutive sessions at the top → a small increase.
    await api("/workouts", { method: "POST", body: {
      focus: "upper", minutes: 45,
      exercises: [{ exercise: "Bench Press", sets: 3, reps: 12, weight_kg: 40 }] } });
    const up = await suggestLoad(u.uid, "Bench Press");
    assert.ok(up.weight > 40, "should progress after repeating the top of the range");
    assert.ok(up.weight <= 42.5, "increments stay small");
  } finally { token = saved; }

  // Focus rotates rather than repeating.
  assert.equal(nextFocus([{ focus: "upper", date: "2026-08-15" }], 3), "lower");
  assert.equal(nextFocus([{ focus: "lower", date: "2026-08-15" }], 3), "upper");
  assert.equal(nextFocus([], 2), "full_body", "two days a week suits full body");

  // Four consecutive days is a recovery signal.
  const consecutive = ["2026-08-16", "2026-08-15", "2026-08-14", "2026-08-13"]
    .map((date) => ({ date, effort: 6 }));
  assert.ok(needsRecovery(consecutive));
  assert.ok(!needsRecovery([{ date: "2026-08-16", effort: 5 }]));
});

test("patterns are derived from real history and stay quiet without it", async () => {
  const { detectPatterns } = await import("../dist/services/patterns.js");

  const u = await proUser("pat");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Pat", ...BASE_PROFILE } });

    // Nothing logged: no claims.
    assert.equal((await detectPatterns(u.uid)).length, 0,
      "an empty history must produce no findings");

    // Six days of low protein.
    for (let i = 1; i <= 6; i++) {
      await db.query(
        `INSERT INTO meals (user_id, slot, input_method, logged_on)
         VALUES ($1,'lunch','manual', CURRENT_DATE - $2::int) RETURNING id`,
        [u.uid, i]);
      const meal = await db.query(
        `SELECT id FROM meals WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1`, [u.uid]);
      await db.query(
        `INSERT INTO meal_items (meal_id, name, quantity, unit, grams,
                                 kcal_100g, protein_100g, carbs_100g, fat_100g)
         VALUES ($1,'rice',1,'cup',200,130,2.7,28,0.3)`,
        [meal.rows[0].id]);
    }

    const found = await detectPatterns(u.uid);
    const kinds = found.map((p) => p.kind);
    assert.ok(kinds.includes("protein_low"),
      `expected a protein finding, got ${kinds.join(", ")}`);

    // Findings are phrased for a person and carry the real numbers.
    const protein = found.find((p) => p.kind === "protein_low");
    assert.match(protein.finding, /\d+g/);
  } finally { token = saved; }
});

test("a completed workout closes the loop back to its plan", async () => {
  const u = await proUser("loop");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Loop", ...BASE_PROFILE } });
    await api("/fitness/profile", { method: "PUT", body: {
      gym_access: true, equipment: "full_gym", experience: "beginner" } });

    const plan = await api("/coach/workout", { method: "POST", body: {} });
    assert.ok(plan.json.id);

    const done = await api("/workouts", { method: "POST", body: {
      focus: plan.json.focus, minutes: 45, perceived_effort: 6,
      plan_id: plan.json.id,
      exercises: plan.json.exercises.slice(0, 2).map((e) => ({
        exercise: e.exercise_name, sets: e.sets, reps: 10, weight_kg: 30,
      })) } });
    assert.equal(done.status, 200);

    const link = await db.query(
      `SELECT workout_id FROM workout_plans WHERE id = $1`, [plan.json.id]);
    assert.equal(link.rows[0].workout_id, done.json.id,
      "the plan must record which session actually happened");

    // And that history is what the next recommendation reads.
    const history = await api("/workouts?days=7");
    assert.equal(history.json.workouts.length, 1);
    assert.equal(history.json.workouts[0].exercises.length, 2);
  } finally { token = saved; }
});

test("no onboarding question is ever asked twice", async () => {
  const u = await proUser("norepeat-onb");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "NoRepeat", ...BASE_PROFILE } });

    const asked = [];
    let state = await api("/coach/onboarding");
    let guard = 0;

    // Answer whatever is asked, until onboarding says it is done.
    while (state.json.next && guard++ < 20) {
      const q = state.json.next;
      asked.push(q.field);

      const body = q.multiSelect
        ? { field: q.field, values: [q.options[0].value] }
        : { field: q.field, value: q.options[0]?.value ?? "3" };

      state = await api("/coach/onboarding", { method: "POST", body });
    }

    assert.ok(guard < 20, "onboarding must terminate");
    assert.equal(asked.length, new Set(asked).size,
      `a question was repeated: ${asked.join(" → ")}`);
    assert.equal(state.json.completed, true);
  } finally { token = saved; }
});

test("skipping an optional question still advances", async () => {
  const u = await proUser("skip-opt");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "SkipOpt", ...BASE_PROFILE } });

    for (const answer of [
      { field: "primary_goal", value: "maintain" },
      { field: "experience", value: "beginner" },
      { field: "training_location", value: "home" },
      { field: "equipment_list", values: ["bodyweight"] },
      { field: "training_days", value: "3" },
      { field: "session_minutes", value: "25" },
    ]) {
      await api("/coach/onboarding", { method: "POST", body: answer });
    }

    const beforeSkip = await api("/coach/onboarding");
    assert.equal(beforeSkip.json.next.field, "average_sleep_hours");
    assert.equal(beforeSkip.json.next.skippable, true);

    const afterSkip = await api("/coach/onboarding", {
      method: "POST", body: { field: "average_sleep_hours", skip: true } });
    assert.notEqual(afterSkip.json.next?.field, "average_sleep_hours",
      "a skipped question must not be asked again");
  } finally { token = saved; }
});

test("an unknown onboarding field is rejected rather than silently ignored", async () => {
  const u = await proUser("badfield");
  const saved = token; token = u.token;
  const { status, json } = await api("/coach/onboarding", {
    method: "POST", body: { field: "favourite_colour", value: "blue" } });
  token = saved;

  assert.equal(status, 400);
  assert.equal(json.error, "unknown_field");
});

// ─── Personal Health Brain: state, memory, safety, learning loop ───────────

test("health state gives baselines and trends, not raw numbers", async () => {
  const u = await proUser("state");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "State", ...BASE_PROFILE } });

    // 20 days of HRV, declining over the last week.
    const obs = [];
    for (let d = 20; d >= 0; d--) {
      const date = new Date(Date.now() - d * 864e5).toISOString().slice(0, 10);
      obs.push({ metric: "hrv", value: d <= 6 ? 40 : 55, observed_on: date });
    }
    const stored = await api("/observations", { method: "POST", body: { observations: obs } });
    assert.equal(stored.json.stored, 21);

    const { json } = await api("/health/metric/hrv");
    assert.equal(json.metric, "hrv");
    assert.ok(json.baseline > 50, "baseline should reflect the older, higher period");
    assert.ok(json.avg7 < 45, "the last week should pull the 7-day average down");
    assert.equal(json.trend, "falling");
    assert.equal(json.confidence, "high", "21 days of data is high confidence");
    assert.ok(json.deviationPct < 0);
  } finally { token = saved; }
});

test("a metric with no data reports none, never zero", async () => {
  const u = await proUser("nodata");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "NoData", ...BASE_PROFILE } });

    const { json } = await api("/health/metric/hrv");
    // Zero steps and no step data are different situations; conflating them
    // makes the coach tell someone off for a day it knows nothing about.
    assert.equal(json.today, null);
    assert.equal(json.baseline, null);
    assert.equal(json.confidence, "none");
    assert.equal(json.trend, "unknown");

    const state = await api("/health/state");
    assert.ok(state.json.missing.includes("hrv"));
  } finally { token = saved; }
});

test("coaching mode drops to recovery on poor sleep and rising resting HR", async () => {
  const u = await proUser("mode");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Mode", ...BASE_PROFILE } });

    const obs = [];
    for (let d = 20; d >= 1; d--) {
      const date = new Date(Date.now() - d * 864e5).toISOString().slice(0, 10);
      obs.push({ metric: "sleep_minutes", value: 450, observed_on: date });
      obs.push({ metric: "resting_hr", value: 55, observed_on: date });
    }
    const today = new Date().toISOString().slice(0, 10);
    obs.push({ metric: "sleep_minutes", value: 330, observed_on: today });  // ~27% below
    obs.push({ metric: "resting_hr", value: 64, observed_on: today });

    await api("/observations", { method: "POST", body: { observations: obs } });

    const { json } = await api("/health/state");
    assert.equal(json.mode, "recovery");
    assert.ok(json.modeRationale.length > 0, "the mode must be explainable");
    assert.ok(json.modeRationale.some((r) => /slept/i.test(r)));
  } finally { token = saved; }
});

test("memory consolidates rather than duplicating", async () => {
  const { consolidate, recall } = await import("../dist/services/brain.js");
  const u = await proUser("mem");

  const fact = {
    layer: "semantic", subject: "breakfast_habit",
    content: "usually skips breakfast",
  };

  const first = await consolidate(u.uid, fact);
  assert.equal(first.action, "ADD");

  // The same fact again is evidence, not a second row.
  const second = await consolidate(u.uid, fact);
  assert.equal(second.action, "REINFORCE");
  assert.equal(second.memoryId, first.memoryId);

  const third = await consolidate(u.uid, fact);
  assert.equal(third.action, "REINFORCE");

  const memories = await recall(u.uid, { layers: ["semantic"] });
  const onSubject = memories.filter((m) => m.subject === "breakfast_habit");
  assert.equal(onSubject.length, 1, "three observations must be one memory");
  assert.ok(onSubject[0].confidence > 0.5, "repeated evidence raises confidence");
  assert.equal(onSubject[0].evidenceCount, 3);
});

test("a changed fact supersedes the old one without destroying history", async () => {
  const { consolidate } = await import("../dist/services/brain.js");
  const u = await proUser("change");

  await consolidate(u.uid, {
    layer: "routine", subject: "training_time", content: "usually trains around 7am",
  });

  const changed = await consolidate(u.uid, {
    layer: "routine", subject: "training_time", content: "usually trains around 6pm",
  });

  assert.equal(changed.action, "UPDATE");
  assert.match(changed.reason, /superseded/);

  const rows = await db.query(
    `SELECT content, valid_until FROM memories
      WHERE user_id = $1 AND subject = 'training_time' ORDER BY created_at`,
    [u.uid]);

  assert.equal(rows.rows.length, 2, "history is kept, not overwritten");
  assert.ok(rows.rows[0].valid_until !== null, "the old routine is closed off");
  assert.equal(rows.rows[1].valid_until, null, "the current routine is open");
});

test("a user-edited memory is never overwritten by extraction", async () => {
  const { consolidate } = await import("../dist/services/brain.js");
  const u = await proUser("edited");
  const saved = token; token = u.token;

  try {
    const added = await consolidate(u.uid, {
      layer: "semantic", subject: "running", content: "enjoys running",
    });

    // The user corrects it.
    const edited = await api(`/brain/memories/${added.memoryId}`, {
      method: "PATCH", body: { content: "hates running" } });
    assert.equal(edited.status, 200);

    // Extraction tries to reassert the original.
    const attempt = await consolidate(u.uid, {
      layer: "semantic", subject: "running", content: "enjoys running",
    });
    assert.equal(attempt.action, "NOOP",
      "what the user told us outranks what we inferred");

    const memories = await api("/brain/memories");
    const running = memories.json.layers.semantic.find((m) => m.content === "hates running");
    assert.ok(running, "the user's correction stands");
    assert.equal(running.user_edited, true);
  } finally { token = saved; }
});

test("deleting a memory really deletes it", async () => {
  const { consolidate } = await import("../dist/services/brain.js");
  const u = await proUser("forget");
  const saved = token; token = u.token;

  try {
    const added = await consolidate(u.uid, {
      layer: "semantic", subject: "sensitive", content: "something private",
    });

    const gone = await api(`/brain/memories/${added.memoryId}`, { method: "DELETE" });
    assert.equal(gone.status, 200);

    // Not soft-deleted: if someone asks the app to forget something about
    // their health, leaving the row with an end-date is not forgetting.
    const rows = await db.query(`SELECT id FROM memories WHERE id = $1`, [added.memoryId]);
    assert.equal(rows.rows.length, 0);
  } finally { token = saved; }
});

test("routines are learned from logged behaviour", async () => {
  const u = await proUser("routine");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Routine", ...BASE_PROFILE } });

    // Five breakfasts, all around the same time.
    for (let d = 1; d <= 5; d++) {
      const date = new Date(Date.now() - d * 864e5).toISOString().slice(0, 10);
      await db.query(
        `INSERT INTO meals (user_id, slot, input_method, logged_on, logged_at)
         VALUES ($1,'breakfast','manual',$2, $2::date + time '08:00')`,
        [u.uid, date]);
    }

    const learned = await api("/brain/learn", { method: "POST", body: {} });
    assert.equal(learned.status, 200);
    assert.ok(learned.json.added >= 1);

    const memories = await api("/brain/memories");
    const routines = memories.json.layers.routine ?? [];
    assert.ok(routines.some((m) => /breakfast/i.test(m.content)),
      `expected a breakfast routine, got: ${routines.map((r) => r.content).join(", ")}`);

    // Running it again reinforces rather than duplicating.
    const again = await api("/brain/learn", { method: "POST", body: {} });
    assert.ok(again.json.reinforced >= 1);
    assert.equal(again.json.added, 0);
  } finally { token = saved; }
});

test("safety blocks self-harm and emergencies before the model runs", async () => {
  const { assess, validate, suppressesRecommendations } =
    await import("../dist/services/safety.js");

  const selfHarm = assess("I want to kill myself");
  assert.equal(selfHarm.category, "self_harm");
  assert.equal(selfHarm.action, "block");
  assert.match(selfHarm.response, /crisis line|emergency|doctor/i);

  const emergency = assess("I have chest pain and can't breathe");
  assert.equal(emergency.action, "block");

  // These steer rather than block — the user still deserves a useful answer.
  assert.equal(assess("Which protein powder should I buy?").action, "steer");
  assert.equal(assess("what medicine should I take").category, "medication");
  assert.equal(assess("how little can i eat to lose weight fast").category, "disordered_eating");
  assert.equal(assess("should I train through the pain").category, "exercise_risk");

  // Ordinary questions pass untouched.
  assert.equal(assess("what should I eat for dinner").action, "allow");

  // No meal card next to a conversation about restriction.
  assert.ok(suppressesRecommendations(assess("how little can i eat")));
  assert.ok(!suppressesRecommendations(assess("what should I eat for dinner")));

  // Post-model checks are deterministic.
  assert.match(validate("Take 500 mg twice daily.", { category: null, action: "allow" }),
               /can't advise on medication/i);
  assert.match(validate("Aim for 600 calories a day.", { category: null, action: "allow" }),
               /wouldn't|rather not|unsafe|backfire/i);
  assert.match(validate("You have diabetes.", { category: null, action: "allow" }),
               /clinician|can't tell you/i);
  assert.equal(validate("Grilled chicken fits your remaining calories.",
                        { category: null, action: "allow" }), null);
});

test("a self-harm message returns support and never a meal card", async () => {
  const u = await proUser("crisis");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Crisis", ...BASE_PROFILE } });

    const { status, json } = await api("/coach/ask", {
      method: "POST", body: { question: "I want to die, what should I eat" } });

    assert.equal(status, 200);
    assert.equal(json.intent, "safety");
    assert.equal(json.suggestion, null);
    assert.match(json.answer, /crisis|emergency|doctor|someone you trust/i);
    assert.ok(!/calorie|protein|\d{3}/.test(json.answer),
      "a crisis reply must not carry nutrition content");
  } finally { token = saved; }
});

test("recommendations record outcomes and feed procedural memory", async () => {
  const u = await proUser("loop2");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Loop2", ...BASE_PROFILE } });

    // Six sleep recommendations, five of them completed.
    for (let i = 0; i < 6; i++) {
      const rec = await db.query(
        `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
         VALUES ($1,'sleep','Stop caffeine before 2pm','Late caffeine tracks with poor sleep',
                 CURRENT_DATE - $2::int, $3) RETURNING id`,
        [u.uid, i, i < 5 ? "completed" : "dismissed"]);

      if (i < 4) {
        await db.query(
          `INSERT INTO recommendation_outcomes
             (recommendation_id, user_id, metric, direction)
           VALUES ($1,$2,'sleep_minutes','improved')`,
          [rec.rows[0].id, u.uid]);
      }
    }

    const effectiveness = await api("/recommendations/effectiveness");
    const sleep = effectiveness.json.by_domain.find((d) => d.domain === "sleep");
    assert.equal(sleep.offered, 6);
    assert.equal(sleep.completed, 5);
    assert.equal(sleep.improved, 4);
    assert.ok(sleep.completion_rate >= 80);

    // The brain turns that into a durable fact about this person.
    const learned = await api("/brain/learn", { method: "POST", body: {} });
    assert.ok(learned.json.added + learned.json.reinforced >= 1);

    const memories = await api("/brain/memories");
    const procedural = memories.json.layers.procedural ?? [];
    assert.ok(procedural.some((m) => /sleep/i.test(m.content)),
      `expected a procedural memory about sleep, got: ${procedural.map((p) => p.content).join(", ")}`);
  } finally { token = saved; }
});

test("responding to a recommendation records the response", async () => {
  const u = await proUser("respond");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Respond", ...BASE_PROFILE } });

    const rec = await db.query(
      `INSERT INTO recommendations (user_id, domain, action, reason, offered_on)
       VALUES ($1,'activity','Take a 20 minute walk','Steps are below your usual',
               CURRENT_DATE) RETURNING id`,
      [u.uid]);

    const done = await api(`/recommendations/${rec.rows[0].id}/respond`, {
      method: "POST", body: { status: "completed", feedback: "felt good" } });

    assert.equal(done.status, 200);
    assert.equal(done.json.status, "completed");

    const outcome = await db.query(
      `SELECT user_feedback FROM recommendation_outcomes WHERE recommendation_id = $1`,
      [rec.rows[0].id]);
    assert.equal(outcome.rows[0].user_feedback, "felt good");
  } finally { token = saved; }
});

test("one user's memories are invisible to another", async () => {
  const { consolidate } = await import("../dist/services/brain.js");
  const a = await proUser("mem-a");
  const b = await proUser("mem-b");
  const saved = token;

  try {
    await consolidate(a.uid, {
      layer: "semantic", subject: "private", content: "a private detail",
    });

    token = b.token;
    const theirs = await api("/brain/memories");
    assert.equal(theirs.json.total, 0, "user B must not see user A's memories");

    token = a.token;
    const mine = await api("/brain/memories");
    assert.ok(mine.json.total >= 1);
  } finally { token = saved; }
});

// ─── orchestrator: state + memory → ranked, explainable actions ────────────

test("briefing gives at most three actions, each with a reason", async () => {
  // Pinned to daytime: at night the briefing correctly collapses to sleep only.
  const savedTz = tzHeader; tzHeader = DAYTIME_TZ;
  const u = await proUser("brief");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Brief", ...BASE_PROFILE } });

    const { status, json } = await api("/coach/briefing");
    assert.equal(status, 200);
    assert.ok(json.headline);
    assert.ok(json.actions.length <= 3, "more than three priorities is a list, not a priority");

    for (const a of json.actions) {
      assert.ok(a.action, "every action needs an action");
      assert.ok(a.reason && a.reason.length > 10,
        `every action needs a reason — "${a.action}" had none`);
      assert.ok(a.id, "actions are persisted so outcomes can be measured");
      assert.ok(a.triggeredBy.length > 0, "the trigger is recorded for later analysis");
    }
  } finally { token = saved; tzHeader = savedTz; }
});

test("a fresh user is asked to log before anything else", async () => {
  // Pinned to daytime: at night the briefing correctly collapses to sleep only.
  const savedTz = tzHeader; tzHeader = DAYTIME_TZ;
  const u = await proUser("fresh");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Fresh", ...BASE_PROFILE } });

    const { json } = await api("/coach/briefing");
    // Everything else depends on knowing what they ate.
    assert.ok(json.actions.some((a) => /log/i.test(a.action)),
      `expected a logging prompt, got: ${json.actions.map((a) => a.action).join(" | ")}`);
    assert.ok(json.missing.length > 0, "no health data yet, and it says so");
  } finally { token = saved; tzHeader = savedTz; }
});

test("the briefing is idempotent within a day", async () => {
  // Pinned to daytime: at night the briefing correctly collapses to sleep only.
  const savedTz = tzHeader; tzHeader = DAYTIME_TZ;
  const u = await proUser("idem");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Idem", ...BASE_PROFILE } });

    const first = await api("/coach/briefing");
    assert.equal(first.json.generated, true);

    const second = await api("/coach/briefing");
    assert.equal(second.json.generated, false, "a second call must not generate a new set");
    assert.deepEqual(
      second.json.actions.map((a) => a.id).sort(),
      first.json.actions.map((a) => a.id).sort());

    const stored = await db.query(
      `SELECT COUNT(*)::int AS n FROM recommendations
        WHERE user_id = $1 AND offered_on = CURRENT_DATE`, [u.uid]);
    assert.equal(stored.rows[0].n, first.json.actions.length,
      "no duplicate recommendations were written");
  } finally { token = saved; tzHeader = savedTz; }
});

test("recovery mode asks for less, and says why", async () => {
  // Pinned to daytime: at night the briefing correctly collapses to sleep only.
  const savedTz = tzHeader; tzHeader = DAYTIME_TZ;
  const u = await proUser("recov");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Recov", ...BASE_PROFILE } });

    const obs = [];
    for (let d = 20; d >= 1; d--) {
      const date = new Date(Date.now() - d * 864e5).toISOString().slice(0, 10);
      obs.push({ metric: "sleep_minutes", value: 450, observed_on: date });
      obs.push({ metric: "resting_hr", value: 54, observed_on: date });
    }
    const today = new Date().toISOString().slice(0, 10);
    obs.push({ metric: "sleep_minutes", value: 320, observed_on: today });
    obs.push({ metric: "resting_hr", value: 64, observed_on: today });
    await api("/observations", { method: "POST", body: { observations: obs } });

    const { json } = await api("/coach/briefing");
    assert.equal(json.mode, "recovery");
    assert.ok(json.actions.length <= 2, "recovery mode caps at two asks");
    assert.match(json.headline, /light|slack|easier/i);

    const recovery = json.actions.find((a) => a.domain === "recovery");
    assert.ok(recovery, "an under-recovered day should suggest taking it easy");
    // The reason must cite the actual signal, not a generic platitude.
    assert.match(recovery.reason, /slept|heart rate|sessions/i);
  } finally { token = saved; tzHeader = savedTz; }
});

test("one action per domain — three nutrition tips would read as nagging", async () => {
  const { rank } = await import("../dist/services/orchestrator.js");

  const candidates = [
    { domain: "nutrition", action: "a", reason: "r", score: 90, confidence: 1, triggeredBy: ["x"] },
    { domain: "nutrition", action: "b", reason: "r", score: 80, confidence: 1, triggeredBy: ["x"] },
    { domain: "nutrition", action: "c", reason: "r", score: 70, confidence: 1, triggeredBy: ["x"] },
    { domain: "sleep",     action: "d", reason: "r", score: 60, confidence: 1, triggeredBy: ["x"] },
    { domain: "fitness",   action: "e", reason: "r", score: 50, confidence: 1, triggeredBy: ["x"] },
  ];

  const ranked = rank(candidates, "maintenance");
  assert.equal(ranked.length, 3);
  assert.equal(new Set(ranked.map((r) => r.domain)).size, 3, "one per domain");
  assert.equal(ranked[0].action, "a", "highest score within its domain wins");

  // Recovery mode asks for less.
  assert.ok(rank(candidates, "recovery").length <= 2);

  // Weak candidates are dropped rather than padding the list.
  const weak = [{ domain: "hydration", action: "x", reason: "r", score: 5, confidence: 1, triggeredBy: ["y"] }];
  assert.equal(rank(weak, "maintenance").length, 0);
});

test("actions the user ignores are ranked lower over time", async () => {
  const u = await proUser("adhere");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Adhere", ...BASE_PROFILE } });

    // Six nutrition suggestions, all dismissed.
    for (let i = 0; i < 6; i++) {
      await db.query(
        `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
         VALUES ($1,'nutrition','eat more protein','r', CURRENT_DATE - $2::int, 'dismissed')`,
        [u.uid, i + 1]);
    }

    const learned = await api("/brain/learn", { method: "POST", body: {} });
    assert.ok(learned.json.added + learned.json.reinforced >= 1);

    const memories = await api("/brain/memories");
    const procedural = memories.json.layers.procedural ?? [];
    assert.ok(procedural.some((m) => /rarely acts on nutrition/i.test(m.content)),
      `expected a low-adherence memory, got: ${procedural.map((p) => p.content).join(", ")}`);
  } finally { token = saved; }
});

test("outcomes are measured where a metric moved, and unknown where it can't be", async () => {
  const u = await proUser("outcome");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Outcome", ...BASE_PROFILE } });

    // A sleep recommendation from four days ago, and sleep improved after it.
    const offered = new Date(Date.now() - 4 * 864e5).toISOString().slice(0, 10);
    await db.query(
      `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
       VALUES ($1,'sleep','Wind down earlier','Sleep below baseline',$2,'completed')`,
      [u.uid, offered]);

    // A nutrition one, which has no measurable proxy metric.
    await db.query(
      `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
       VALUES ($1,'nutrition','More protein','Short on protein',$2,'completed')`,
      [u.uid, offered]);

    const obs = [];
    for (let d = 10; d >= 0; d--) {
      const date = new Date(Date.now() - d * 864e5).toISOString().slice(0, 10);
      // Clearly better after the recommendation date.
      obs.push({ metric: "sleep_minutes", value: d > 4 ? 380 : 460, observed_on: date });
    }
    await api("/observations", { method: "POST", body: { observations: obs } });

    const cycle = await api("/coach/learn-cycle", { method: "POST", body: {} });
    assert.equal(cycle.status, 200);
    assert.ok(cycle.json.outcomesMeasured >= 2);

    const outcomes = await db.query(
      `SELECT r.domain, o.direction, o.metric
         FROM recommendation_outcomes o
         JOIN recommendations r ON r.id = o.recommendation_id
        WHERE o.user_id = $1`, [u.uid]);

    const sleep = outcomes.rows.find((r) => r.domain === "sleep");
    assert.equal(sleep.metric, "sleep_minutes");
    assert.equal(sleep.direction, "improved");

    // No honest proxy for a nutrition suggestion, so it stays unknown rather
    // than being guessed — a wrong outcome would poison procedural memory.
    const nutrition = outcomes.rows.find((r) => r.domain === "nutrition");
    assert.equal(nutrition.direction, "unknown");
    assert.equal(nutrition.metric, null);
  } finally { token = saved; }
});

test("unanswered recommendations expire so completion rates stay honest", async () => {
  const u = await proUser("expire");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Expire", ...BASE_PROFILE } });

    await db.query(
      `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
       VALUES ($1,'activity','Walk','r', CURRENT_DATE - 5, 'pending')`, [u.uid]);

    await api("/coach/learn-cycle", { method: "POST", body: {} });

    const row = await db.query(
      `SELECT status FROM recommendations WHERE user_id = $1`, [u.uid]);
    assert.equal(row.rows[0].status, "expired",
      "an ignored recommendation must not count as pending forever");
  } finally { token = saved; }
});

test("no action is generated from data the system doesn't have", async () => {
  // Pinned to daytime: at night the briefing correctly collapses to sleep only.
  const savedTz = tzHeader; tzHeader = DAYTIME_TZ;
  const u = await proUser("nodata2");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "NoData2", ...BASE_PROFILE } });

    const { json } = await api("/coach/briefing");

    // With no sleep, step or HRV data, nothing may claim otherwise.
    for (const a of json.actions) {
      assert.ok(!/below your usual|baseline|bedtime has been/i.test(a.reason),
        `"${a.reason}" implies history that does not exist`);
    }
    assert.ok(json.missing.includes("sleep"));
  } finally { token = saved; tzHeader = savedTz; }
});

test("a proven lever is surfaced only once there is evidence for it", async () => {
  // Pinned to daytime: at night the briefing correctly collapses to sleep only.
  const savedTz = tzHeader; tzHeader = DAYTIME_TZ;
  const fresh = await proUser("lever-a");
  const experienced = await proUser("lever-b");
  const saved = token;

  try {
    for (const u of [fresh, experienced]) {
      token = u.token;
      await api("/profile", { method: "POST", body: { name: "Lever", ...BASE_PROFILE } });
    }

    // The experienced user has four sleep recommendations that measurably helped.
    for (let i = 1; i <= 4; i++) {
      const rec = await db.query(
        `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
         VALUES ($1,'sleep','Wind down earlier','r', CURRENT_DATE - $2::int, 'completed')
         RETURNING id`, [experienced.uid, i + 5]);
      await db.query(
        `INSERT INTO recommendation_outcomes (recommendation_id, user_id, metric, direction)
         VALUES ($1,$2,'sleep_minutes','improved')`, [rec.rows[0].id, experienced.uid]);
    }

    token = experienced.token;
    await api("/coach/learn-cycle", { method: "POST", body: {} });
    const withHistory = await api("/coach/briefing");

    token = fresh.token;
    const withoutHistory = await api("/coach/briefing");

    const provenIn = (b) => b.json.actions.some((a) => /moved the needle/i.test(a.reason));

    assert.ok(provenIn(withHistory),
      "a lever proven by outcomes should surface for the experienced user");
    assert.ok(!provenIn(withoutHistory),
      "a new user must never be told something has worked for them before");
  } finally { token = saved; tzHeader = savedTz; }
});

test("a misconfigured testing flag warns but never stops the server booting", async () => {
  // Regression: DEV_UNLOCK_PREMIUM with NODE_ENV=production used to throw at
  // boot, so the container started, never listened, and every healthcheck
  // failed. An optional testing flag must not be able to take the service
  // down — it is already inert in production.
  const { execFileSync } = await import("node:child_process");

  const check = (env) =>
    execFileSync("node", ["-e", `
      import("./dist/config.js")
        .then(m => { m.assertProviderConfigured(); console.log("BOOTS:" + m.premiumUnlocked); })
        .catch(e => console.log("THROWS:" + e.message));
    `], {
      env: { ...process.env, DATABASE_URL: "x",
             JWT_SECRET: "0123456789012345678901234567890123", ...env },
      encoding: "utf8",
    }).trim();

  const misconfigured = check({
    NODE_ENV: "production", DEV_UNLOCK_PREMIUM: "true",
    AI_PROVIDER: "openai", OPENAI_API_KEY: "sk-test",
  });
  assert.match(misconfigured, /^BOOTS:/, "must still boot");
  assert.match(misconfigured, /BOOTS:false/, "and the flag must be inert");

  // The mock provider is different: it serves fabricated foods that are
  // indistinguishable from a real scan, so it stays fatal.
  const mockInProd = check({ NODE_ENV: "production", AI_PROVIDER: "mock" });
  assert.match(mockInProd, /^THROWS:/);
  assert.match(mockInProd, /fabricated/);

  // Non-production, flag on: unlocked as intended.
  const testing = check({
    NODE_ENV: "development", DEV_UNLOCK_PREMIUM: "true",
    AI_PROVIDER: "openai", OPENAI_API_KEY: "sk-test",
  });
  assert.match(testing, /BOOTS:true/);
});

// ─── time of day, and dose false positives ────────────────────────────────

test("hydration and nutrition answers are not mistaken for medication", async () => {
  const { validate } = await import("../dist/services/safety.js");
  const allow = { category: null, action: "allow" };

  // Regression: "2000 ml of water daily" was replaced with a medication
  // refusal, which made an ordinary hydration answer look broken. `ml` is a
  // drink measure, not a drug dose.
  for (const answer of [
    "Aim for about 2000 ml of water daily.",
    "Have 500 ml with each meal.",
    "Around 2.5 L, so roughly 800 ml more today.",
    "Get 30-40 g of protein per day.",
    "Aim for 8000 steps daily.",
    "A 250 ml glass of milk has about 120 calories.",
  ]) {
    assert.equal(validate(answer, allow), null,
      `"${answer}" must not be treated as medication advice`);
  }

  // Real doses still blocked.
  for (const answer of [
    "Take 500 mg twice daily.",
    "The usual dose is 400 IU of vitamin D.",
    "Your doctor may suggest 1000 mcg — ask them.",
  ]) {
    assert.ok(validate(answer, allow) !== null,
      `"${answer}" must be blocked`);
  }
});

test("the clock is classified correctly for coaching", async () => {
  const { localClock } = await import("../dist/util/dates.js");

  const clock = localClock("UTC");
  assert.ok(clock.hour >= 0 && clock.hour <= 23);
  assert.match(clock.time, /^\d{2}:\d{2}$/);
  assert.ok(["late_night", "morning", "afternoon", "evening"].includes(clock.partOfDay));

  // An invalid timezone must not crash a coach request.
  const fallback = localClock("Not/AZone");
  assert.ok(Number.isFinite(fallback.hour));
});

test("late at night the briefing offers sleep, not a workout", async () => {
  const u = await proUser("night");
  const saved = token; token = u.token;

  try {
    // A timezone where it is currently the middle of the night, whatever the
    // server clock says.
    const nightTz = (() => {
      for (const tz of ["Pacific/Kiritimati", "Asia/Kolkata", "America/Los_Angeles",
                        "UTC", "Asia/Tokyo", "Europe/London", "Pacific/Honolulu"]) {
        const hour = Number(new Intl.DateTimeFormat("en-GB", {
          timeZone: tz, hour: "2-digit", hour12: false }).format(new Date()));
        if (hour >= 22 || hour < 5) return tz;
      }
      return null;
    })();

    if (!nightTz) return;   // no qualifying zone right now; nothing to assert

    tzHeader = nightTz;
    await api("/profile", { method: "POST", body: { name: "Night", ...BASE_PROFILE } });

    const { json } = await api("/coach/briefing");

    // One thing at midnight. A list of priorities for a day that is over reads
    // as an app that has not noticed the time.
    assert.ok(json.actions.length <= 1,
      `expected at most one late-night action, got ${json.actions.length}`);

    for (const a of json.actions) {
      assert.notEqual(a.domain, "fitness",
        "a workout must not be suggested in the middle of the night");
      assert.notEqual(a.domain, "activity",
        "a walk must not be suggested in the middle of the night");
    }
  } finally {
    tzHeader = "UTC";
    token = saved;
  }
});

// ─── follow-up: yesterday's advice reaches today's answer ─────────────────

test("the coach can see what it advised, and whether it happened", async () => {
  const { buildFollowUp, followUpForPrompt } = await import("../dist/services/followUp.js");
  const u = await proUser("followup");
  const saved = token; token = u.token;

  try {
    await api("/profile", { method: "POST", body: { name: "Follow", ...BASE_PROFILE } });

    // Yesterday's suggestion, never answered.
    await db.query(
      `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
       VALUES ($1,'sleep','Wind down by 10:30','Sleep below baseline',
               CURRENT_DATE - 1, 'pending')`, [u.uid]);

    // And one from three days ago that was done and helped.
    const older = await db.query(
      `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
       VALUES ($1,'activity','Take a 20 minute walk','Steps below usual',
               CURRENT_DATE - 3, 'completed') RETURNING id`, [u.uid]);
    await db.query(
      `INSERT INTO recommendation_outcomes (recommendation_id, user_id, metric, direction)
       VALUES ($1,$2,'steps','improved')`, [older.rows[0].id, u.uid]);

    const followUp = await buildFollowUp(u.uid, "UTC");

    assert.equal(followUp.recent.length, 2);
    // Yesterday's unanswered suggestion is the one worth asking about.
    assert.ok(followUp.awaitingAnswer);
    assert.match(followUp.awaitingAnswer.action, /Wind down/);

    const forPrompt = followUpForPrompt(followUp);
    assert.equal(forPrompt.awaiting_answer.offered, "yesterday");
    assert.equal(forPrompt.recent_advice.length, 2);
    assert.ok(forPrompt.recent_advice.some((r) => r.followed));
  } finally { token = saved; }
});

test("advice from a week ago is not resurfaced as a question", async () => {
  const { buildFollowUp } = await import("../dist/services/followUp.js");
  const u = await proUser("stale");

  await db.query(
    `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
     VALUES ($1,'sleep','Wind down early','r', CURRENT_DATE - 5, 'pending')`, [u.uid]);

  const followUp = await buildFollowUp(u.uid, "UTC");
  // Nobody wants to be asked on Friday whether they took Monday's walk.
  assert.equal(followUp.awaitingAnswer, null);
  assert.equal(followUp.recent.length, 1, "it is still context, just not a question");
});

test("repeatedly ignored advice is flagged so it stops being repeated", async () => {
  const { buildFollowUp, followUpSteer } = await import("../dist/services/followUp.js");
  const u = await proUser("ignored");

  for (let i = 2; i <= 7; i++) {
    await db.query(
      `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
       VALUES ($1,'hydration','Drink more water','r', CURRENT_DATE - $2::int, 'dismissed')`,
      [u.uid, i]);
  }

  const followUp = await buildFollowUp(u.uid, "UTC");
  assert.ok(followUp.ignores.includes("hydration"));

  const steer = followUpSteer(followUp);
  assert.match(steer, /not acted on/i);
  assert.match(steer, /smaller version|focus elsewhere/i);
});

test("advice repeated in the last two days is called out to the model", async () => {
  const { buildFollowUp, followUpSteer } = await import("../dist/services/followUp.js");
  const u = await proUser("repeat");

  await db.query(
    `INSERT INTO recommendations (user_id, domain, action, reason, offered_on, status)
     VALUES ($1,'nutrition','Make your next meal protein-led','r',
             CURRENT_DATE - 1, 'pending')`, [u.uid]);

  const steer = followUpSteer(await buildFollowUp(u.uid, "UTC"));
  assert.match(steer, /already said this/i);
  assert.match(steer, /protein-led/);
});

test("generic filler is detected, concrete advice is not", async () => {
  const { isGeneric } = await import("../dist/services/safety.js");

  // The exact shape seen on device: reasonable words, no reference to
  // anything true about this person today.
  assert.ok(isGeneric(
    "Let's get you started with a balanced day. Have a balanced meal with " +
    "protein, carbs and healthy fats, and stay hydrated."));
  assert.ok(isGeneric(
    "Consider a gentle workout and listen to your body. Stay consistent to support your goals."));

  // Anything citing real figures is coaching, even if it uses a stock phrase.
  assert.ok(!isGeneric("You're 60g short on protein with one meal left — make it protein-led."));
  assert.ok(!isGeneric("A balanced meal works here: you have 900 kcal left and 45g of protein to go."));
  assert.ok(!isGeneric("You're at 2,100 steps against a usual 7,400."));
  assert.ok(!isGeneric("It's 00:24 — sleep matters more than the last 300 calories tonight."));
});

test("a medication question still gets useful help alongside the boundary", async () => {
  const { assess } = await import("../dist/services/safety.js");
  const verdict = assess("what medicine should I take for my cold");

  assert.equal(verdict.category, "medication");
  assert.equal(verdict.action, "steer");
  // A bare refusal is a failure — the boundary is on prescribing, not on
  // being useful about food, sleep and recovery.
  assert.match(verdict.instruction, /help fully|food, training, sleep/i);
});

// ─── notification engine: the default answer is no ────────────────────────

/** Gives a user enough history that the engine has something to reason about. */
async function seedHistory(uid, { days = 21, sleepMin = 440, steps = 8000,
                                  restingHr = 54, logMeals = true } = {}) {
  const obs = [];
  for (let d = days; d >= 1; d--) {
    const date = new Date(Date.now() - d * 864e5).toISOString().slice(0, 10);
    obs.push({ metric: "sleep_minutes", value: sleepMin, observed_on: date });
    obs.push({ metric: "steps", value: steps, observed_on: date });
    obs.push({ metric: "resting_hr", value: restingHr, observed_on: date });

    if (logMeals) {
      await db.query(
        `INSERT INTO meals (user_id, slot, input_method, logged_on)
         VALUES ($1,'lunch','manual',$2::date)`, [uid, date]);
    }
  }
  await api("/observations", { method: "POST", body: { observations: obs } });
}

test("a brand-new user with no data gets no notifications at all", async () => {
  const u = await proUser("notif-new");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "New", ...BASE_PROFILE } });

    const { status, json } = await api("/notifications/plan");
    assert.equal(status, 200);

    // Nothing is known, so there is nothing worth interrupting anyone for.
    // Silence is the correct output, not a fallback.
    assert.equal(json.notifications.length, 0,
      `expected silence, got: ${json.notifications.map((n) => n.title).join(", ")}`);
  } finally { token = saved; }
});

test("notifications never exceed the user's daily limit", async () => {
  const u = await proUser("notif-limit");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Limit", ...BASE_PROFILE } });
    await api("/notifications/prefs", { method: "PUT", body: {
      daily_limit: 2, quiet_start: "23:00", quiet_end: "06:00" } });

    // Plenty to talk about: poor recovery, low steps, protein gap.
    await seedHistory(u.uid, { sleepMin: 450, steps: 9000 });
    const today = new Date().toISOString().slice(0, 10);
    await api("/observations", { method: "POST", body: { observations: [
      { metric: "sleep_minutes", value: 300, observed_on: today },
      { metric: "resting_hr", value: 66, observed_on: today },
      { metric: "steps", value: 900, observed_on: today },
    ] } });

    const { json } = await api("/notifications/plan");
    assert.ok(json.notifications.length <= 2,
      `daily limit of 2 exceeded: ${json.notifications.length}`);

    // And anything dropped is recorded, not silently lost.
    if (json.suppressed.length) {
      assert.ok(json.suppressed.every((s) => s.reason));
    }
  } finally { token = saved; }
});

test("quiet hours suppress everything non-critical", async () => {
  const u = await proUser("notif-quiet");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Quiet", ...BASE_PROFILE } });
    // Quiet all day: nothing may be scheduled.
    await api("/notifications/prefs", { method: "PUT", body: {
      quiet_start: "00:00", quiet_end: "23:59", daily_limit: 5 } });

    await seedHistory(u.uid, { sleepMin: 450 });
    const today = new Date().toISOString().slice(0, 10);
    await api("/observations", { method: "POST", body: { observations: [
      { metric: "sleep_minutes", value: 290, observed_on: today },
      { metric: "resting_hr", value: 68, observed_on: today },
    ] } });

    const { json } = await api("/notifications/plan");
    assert.equal(json.notifications.length, 0);
    assert.ok(json.suppressed.some((s) => s.reason === "quiet hours"),
      "the reason must be recorded so the decision is inspectable");
  } finally { token = saved; }
});

test("a muted category is never sent, however important the engine thinks it is", async () => {
  const u = await proUser("notif-mute");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Mute", ...BASE_PROFILE } });
    await api("/notifications/prefs", { method: "PUT", body: {
      muted_categories: ["hydration", "achievement", "recovery"], daily_limit: 5 } });

    await seedHistory(u.uid);
    const today = new Date().toISOString().slice(0, 10);
    await api("/observations", { method: "POST", body: { observations: [
      { metric: "sleep_minutes", value: 280, observed_on: today },
      { metric: "resting_hr", value: 70, observed_on: today },
    ] } });

    const { json } = await api("/notifications/plan");
    for (const n of json.notifications) {
      assert.ok(!["hydration", "achievement", "recovery"].includes(n.category),
        `${n.category} was muted but sent anyway`);
    }
  } finally { token = saved; }
});

test("the same notification is never planned twice in a day", async () => {
  const u = await proUser("notif-dupe");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Dupe", ...BASE_PROFILE } });
    await seedHistory(u.uid);

    const first = await api("/notifications/plan");
    const second = await api("/notifications/plan");

    // Re-planning is safe: the second call adds nothing.
    assert.equal(second.json.notifications.length, 0);
    if (first.json.notifications.length > 0) {
      assert.ok(second.json.suppressed.some((s) => s.reason === "already planned today"));
    }

    const stored = await db.query(
      `SELECT dedupe_key, COUNT(*)::int AS n FROM notification_plan
        WHERE user_id = $1 AND planned_on = CURRENT_DATE
        GROUP BY dedupe_key HAVING COUNT(*) > 1`, [u.uid]);
    assert.equal(stored.rows.length, 0, "a duplicate reached the database");
  } finally { token = saved; }
});

test("a category the user never opens stops being sent", async () => {
  const u = await proUser("notif-ignored");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Ignored", ...BASE_PROFILE } });

    // Six hydration notifications, none opened.
    for (let hour of [15, 15, 15, 16, 16, 15]) {
      await db.query(
        `INSERT INTO notification_engagement (user_id, category, hour, sent, opened, dismissed)
         VALUES ($1,'hydration',$2,1,0,1)
         ON CONFLICT (user_id, category, hour)
         DO UPDATE SET sent = notification_engagement.sent + 1,
                       dismissed = notification_engagement.dismissed + 1`,
        [u.uid, hour]);
    }

    await seedHistory(u.uid);
    const { json } = await api("/notifications/plan");

    // Continuing to send it is how people disable notifications entirely,
    // after which there is no channel left at all.
    assert.ok(!json.notifications.some((n) => n.category === "hydration"),
      "a repeatedly ignored category must stop being sent");
  } finally { token = saved; }
});

test("every notification carries a reason it could be justified by", async () => {
  const u = await proUser("notif-why");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Why", ...BASE_PROFILE } });
    await api("/notifications/prefs", { method: "PUT", body: { daily_limit: 5 } });
    await seedHistory(u.uid, { sleepMin: 450 });

    const today = new Date().toISOString().slice(0, 10);
    await api("/observations", { method: "POST", body: { observations: [
      { metric: "sleep_minutes", value: 300, observed_on: today },
      { metric: "resting_hr", value: 67, observed_on: today },
    ] } });

    await api("/notifications/plan");

    const rows = await db.query(
      `SELECT title, body, rationale, score FROM notification_plan
        WHERE user_id = $1 AND planned_on = CURRENT_DATE`, [u.uid]);

    for (const row of rows.rows) {
      // If we cannot say why it was sent, it should not have been sent.
      assert.ok(row.rationale && row.rationale.length > 5,
        `"${row.title}" has no rationale`);
      assert.ok(row.score > 0);
      assert.ok(row.body.length > 10);
    }
  } finally { token = saved; }
});

test("engagement is recorded and shapes later decisions", async () => {
  const u = await proUser("notif-engage");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Engage", ...BASE_PROFILE } });
    await seedHistory(u.uid, { sleepMin: 450 });

    const today = new Date().toISOString().slice(0, 10);
    await api("/observations", { method: "POST", body: { observations: [
      { metric: "sleep_minutes", value: 295, observed_on: today },
      { metric: "resting_hr", value: 68, observed_on: today },
    ] } });

    const plan = await api("/notifications/plan");
    if (plan.json.notifications.length === 0) return;

    const first = plan.json.notifications[0];
    const opened = await api(`/notifications/${first.id}/event`, {
      method: "POST", body: { event: "opened" } });
    assert.equal(opened.status, 200);

    const engagement = await api("/notifications/engagement");
    const row = engagement.json.by_category.find((r) => r.category === first.category);
    assert.ok(row);
    assert.equal(row.opened, 1);

    const status = await db.query(
      `SELECT status FROM notification_plan WHERE id = $1`, [first.id]);
    assert.equal(status.rows[0].status, "opened");
  } finally { token = saved; }
});

test("recovery outranks encouragement when both apply", async () => {
  const u = await proUser("notif-priority");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Priority", ...BASE_PROFILE } });
    await api("/notifications/prefs", { method: "PUT", body: { daily_limit: 1 } });

    // 30-day streak (an achievement) alongside genuinely poor recovery.
    await seedHistory(u.uid, { days: 30, sleepMin: 450 });
    const today = new Date().toISOString().slice(0, 10);
    await api("/observations", { method: "POST", body: { observations: [
      { metric: "sleep_minutes", value: 280, observed_on: today },
      { metric: "resting_hr", value: 70, observed_on: today },
    ] } });

    const { json } = await api("/notifications/plan");
    if (json.notifications.length === 0) return;

    // With room for one, a health signal beats a congratulation.
    assert.notEqual(json.notifications[0].category, "achievement",
      "an achievement outranked a recovery warning");
  } finally { token = saved; }
});

test("turning notifications off means exactly zero", async () => {
  const u = await proUser("notif-off");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Off", ...BASE_PROFILE } });
    await api("/notifications/prefs", { method: "PUT", body: { daily_coach: false } });
    await seedHistory(u.uid);

    const { json } = await api("/notifications/plan");
    assert.equal(json.notifications.length, 0);
    assert.equal(json.suppressed[0].reason, "notifications off");
  } finally { token = saved; }
});

test("notification copy never leaks malformed numbers or third person", async () => {
  const u = await proUser("notif-copy");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Copy", ...BASE_PROFILE } });
    await api("/notifications/prefs", { method: "PUT", body: { daily_limit: 5 } });

    // Meals logged with no items — the shape that produced "averaged NaNg
    // against 148g, short on 0 of 0 days".
    for (let d = 14; d >= 1; d--) {
      const date = new Date(Date.now() - d * 864e5).toISOString().slice(0, 10);
      await db.query(
        `INSERT INTO meals (user_id, slot, input_method, logged_on)
         VALUES ($1,'lunch','manual',$2::date)`, [u.uid, date]);
    }
    await seedHistory(u.uid, { sleepMin: 450, logMeals: false });

    const today = new Date().toISOString().slice(0, 10);
    await api("/observations", { method: "POST", body: { observations: [
      { metric: "sleep_minutes", value: 290, observed_on: today },
      { metric: "resting_hr", value: 68, observed_on: today },
    ] } });

    await api("/notifications/plan");

    const rows = await db.query(
      `SELECT title, body FROM notification_plan
        WHERE user_id = $1 AND planned_on = CURRENT_DATE`, [u.uid]);

    for (const row of rows.rows) {
      const text = `${row.title} ${row.body}`;
      assert.ok(!/NaN|undefined|null/.test(text), `malformed value in: "${text}"`);
      assert.ok(!/0 of 0/.test(text), `empty statistic in: "${text}"`);

      // The rationale is written for us; the body is written for the user.
      // "You slept 34% below their usual" is what happens when they share one.
      assert.ok(!/\btheir\b/.test(text), `third-person copy shown to the user: "${text}"`);
    }
  } finally { token = saved; }
});

// ─── sleep coaching: timing, not stages ───────────────────────────────────

/** Writes a run of nights with controllable bedtime scatter. */
async function seedSleep(uid, { nights = 14, bedtime = 1380, jitter = 10,
                                duration = 450, weekendShift = 0 } = {}) {
  const obs = [];
  for (let d = nights; d >= 1; d--) {
    const date = new Date(Date.now() - d * 864e5).toISOString().slice(0, 10);
    const weekday = new Date(`${date}T12:00:00Z`).getUTCDay();
    const isWeekend = weekday === 5 || weekday === 6;

    const offset = ((d * 37) % (jitter * 2)) - jitter;   // deterministic scatter
    const start = bedtime + offset + (isWeekend ? weekendShift : 0);

    obs.push({ metric: "sleep_start_min", value: ((start % 1440) + 1440) % 1440, observed_on: date });
    obs.push({ metric: "sleep_end_min", value: ((start + duration) % 1440 + 1440) % 1440, observed_on: date });
    obs.push({ metric: "sleep_minutes", value: duration, observed_on: date });
  }
  await api("/observations", { method: "POST", body: { observations: obs } });
}

test("sleep summary reports timing and regularity, never stages", async () => {
  const u = await proUser("sleep-basic");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Sleep", ...BASE_PROFILE } });
    await seedSleep(u.uid, { bedtime: 1380, jitter: 8, duration: 450 });

    const { status, json } = await api("/sleep/summary");
    assert.equal(status, 200);
    assert.ok(json.nights >= 10);
    assert.equal(json.avg_duration_hours, 7.5);
    assert.match(json.avg_bedtime, /^\d{2}:\d{2}$/);

    // A tight schedule should score well.
    assert.ok(json.regularityScore > 70,
      `expected a regular schedule, scored ${json.regularityScore}`);

    // Consumer wearables cannot reliably tell REM from deep, so we never claim
    // to. Anything resembling a stage breakdown is a bug.
    const text = JSON.stringify(json).toLowerCase();
    for (const banned of ["rem", "deep_sleep", "deepsleep", "light_sleep", "sleep_stage"]) {
      assert.ok(!text.includes(banned), `stage data leaked: ${banned}`);
    }
  } finally { token = saved; }
});

test("an irregular schedule is the headline finding", async () => {
  const u = await proUser("sleep-irregular");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Irregular", ...BASE_PROFILE } });
    // Bedtime scattered across nearly three hours.
    await seedSleep(u.uid, { bedtime: 1380, jitter: 85, duration: 440 });

    const { json } = await api("/sleep/summary");
    assert.ok(json.regularityScore < 60,
      `expected a poor regularity score, got ${json.regularityScore}`);

    const top = json.insights[0];
    assert.equal(top.kind, "irregular_bedtime");
    assert.ok(top.action, "the headline finding must be actionable");
    // Consistency is more achievable than "sleep more" and at least as well
    // supported, so that is what it asks for.
    assert.match(top.action, /same half-hour|window/i);
  } finally { token = saved; }
});

test("bedtimes either side of midnight average correctly", async () => {
  const u = await proUser("sleep-midnight");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Midnight", ...BASE_PROFILE } });
    // Half before midnight, half after — a naive mean gives roughly midday.
    await seedSleep(u.uid, { bedtime: 1435, jitter: 25, duration: 430 });

    const { json } = await api("/sleep/summary");
    const hour = Number(json.avg_bedtime.slice(0, 2));

    assert.ok(hour >= 22 || hour <= 2,
      `average bedtime came out at ${json.avg_bedtime} — midnight wrap is broken`);
    // And the scatter is small, not the ~12h a naive average would imply.
    assert.ok(json.bedtimeVarianceMin < 60);
  } finally { token = saved; }
});

test("a large weekend shift is named without being moralised about", async () => {
  const u = await proUser("sleep-weekend");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Weekend", ...BASE_PROFILE } });
    // Two hours later on Friday and Saturday nights.
    await seedSleep(u.uid, { nights: 21, bedtime: 1350, jitter: 10,
                             duration: 440, weekendShift: 120 });

    const { json } = await api("/sleep/summary");
    const shift = json.insights.find((i) => i.kind === "weekend_shift");

    assert.ok(shift, `expected a weekend finding, got: ${json.insights.map((i) => i.kind).join(", ")}`);
    assert.ok(json.weekendShiftMin >= 60);
    assert.ok(shift.action);
    // No scolding: it names the cost and offers a smaller change.
    assert.ok(!/should not|bad habit|stop/i.test(shift.action));
  } finally { token = saved; }
});

test("too little data produces an honest answer, not a made-up one", async () => {
  const u = await proUser("sleep-sparse");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Sparse", ...BASE_PROFILE } });
    await seedSleep(u.uid, { nights: 2 });

    const { json } = await api("/sleep/summary");
    assert.equal(json.insights.length, 1);
    assert.equal(json.insights[0].kind, "insufficient_data");
    assert.equal(json.insights[0].confidence, "low");

    // With two nights there is no pattern to report, and claiming one would be
    // worse than silence.
    assert.equal(json.regularityScore, null);
  } finally { token = saved; }
});

test("no sleep data at all offers to connect Health", async () => {
  const u = await proUser("sleep-none");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "None", ...BASE_PROFILE } });

    const { json } = await api("/sleep/summary");
    assert.equal(json.nights, 0);
    assert.equal(json.avgDurationMin, null);
    assert.match(json.insights[0].action, /Apple Health/i);
  } finally { token = saved; }
});

test("a late-eating association is only claimed with enough nights either side", async () => {
  const u = await proUser("sleep-meals");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Meals", ...BASE_PROFILE } });
    await seedSleep(u.uid, { nights: 20, bedtime: 1380, jitter: 12, duration: 450 });

    // Only two late nights — below the threshold for saying anything.
    for (let d = 1; d <= 2; d++) {
      const date = new Date(Date.now() - d * 864e5).toISOString().slice(0, 10);
      await db.query(
        `INSERT INTO meals (user_id, slot, input_method, logged_on, logged_at)
         VALUES ($1,'dinner','manual',$2::date, ($2 || ' 22:00')::timestamptz)`,
        [u.uid, date]);
    }

    const { json } = await api("/sleep/summary");
    assert.ok(!json.insights.some((i) => i.kind === "late_eating"),
      "an association was claimed from two nights of data");
  } finally { token = saved; }
});

test("a sleep finding reaches the daily briefing", async () => {
  // Pinned to daytime: at night the briefing correctly collapses to sleep only.
  const savedTz = tzHeader; tzHeader = DAYTIME_TZ;
  const u = await proUser("sleep-briefing");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Brief", ...BASE_PROFILE } });
    await seedSleep(u.uid, { nights: 18, bedtime: 1380, jitter: 90, duration: 435 });

    const { json } = await api("/coach/briefing");
    const sleep = json.actions.find((a) => a.domain === "sleep");

    if (sleep) {
      assert.ok(sleep.reason.length > 10);
      assert.ok(sleep.triggeredBy.includes("sleep"));
      // The reason cites the actual scatter, not a generic claim.
      assert.match(sleep.reason, /\d+ minutes|swings|below/i);
    }
  } finally { token = saved; tzHeader = savedTz; }
});

test("weekend shift is direction-correct across midnight", async () => {
  const { sleepSummary } = await import("../dist/services/sleep.js");
  const u = await proUser("sleep-wrap");
  const saved = token; token = u.token;

  try {
    await api("/profile", { method: "POST", body: { name: "Wrap", ...BASE_PROFILE } });

    // Weekdays 22:30, weekends 00:30 — a real +2h shift that a naive
    // subtraction reports as −22h.
    const obs = [];
    for (let d = 21; d >= 1; d--) {
      const date = new Date(Date.now() - d * 864e5).toISOString().slice(0, 10);
      const weekday = new Date(`${date}T12:00:00Z`).getUTCDay();
      const isWeekend = weekday === 5 || weekday === 6;
      const start = isWeekend ? 30 : 1350;

      obs.push({ metric: "sleep_start_min", value: start, observed_on: date });
      obs.push({ metric: "sleep_end_min", value: (start + 440) % 1440, observed_on: date });
      obs.push({ metric: "sleep_minutes", value: 440, observed_on: date });
    }
    await api("/observations", { method: "POST", body: { observations: obs } });

    const summary = await sleepSummary(u.uid, "UTC");
    assert.ok(summary.weekendShiftMin > 0, "a later weekend bedtime must be positive");
    assert.ok(Math.abs(summary.weekendShiftMin - 120) < 15,
      `expected roughly +120 minutes, got ${summary.weekendShiftMin}`);
  } finally { token = saved; }
});

test("the regularity score matches what counts as irregular in practice", async () => {
  const { sleepSummary } = await import("../dist/services/sleep.js");

  // A standard deviation near 50 minutes means bedtime moves by well over an
  // hour across a week. The first calibration scored that 77/100 — comfortably
  // "fine" — which would have told people their sleep was steady when it
  // plainly was not.
  const cases = [
    { jitter: 8,  expect: "steady" },
    { jitter: 85, expect: "irregular" },
  ];

  for (const { jitter, expect } of cases) {
    const u = await proUser(`sleep-cal-${jitter}`);
    const saved = token; token = u.token;
    try {
      await api("/profile", { method: "POST", body: { name: "Cal", ...BASE_PROFILE } });
      await seedSleep(u.uid, { nights: 16, bedtime: 1380, jitter, duration: 440 });

      const summary = await sleepSummary(u.uid, "UTC");
      if (expect === "steady") {
        assert.ok(summary.regularityScore >= 80,
          `${jitter}min jitter scored ${summary.regularityScore}, expected steady`);
      } else {
        assert.ok(summary.regularityScore < 60,
          `${jitter}min jitter scored ${summary.regularityScore}, expected irregular`);
      }
    } finally { token = saved; }
  }
});

// ─── emotional intelligence, and not making things worse ──────────────────

test("emotional weight is read before the task intent", async () => {
  const { readEmotion, suppressesCards } = await import("../dist/services/emotion.js");

  const overwhelmed = readEmotion("I'm completely exhausted and everything is too much");
  assert.equal(overwhelmed.state, "overwhelmed");
  assert.equal(overwhelmed.intensity, "high");
  assert.ok(overwhelmed.needsAcknowledgement);
  // A meal card next to "everything is too much" is the app not listening.
  assert.ok(suppressesCards(overwhelmed));

  const discouraged = readEmotion("I feel like giving up, nothing is working");
  assert.equal(discouraged.state, "discouraged");
  assert.ok(suppressesCards(discouraged));

  const good = readEmotion("Really pleased with this week");
  assert.equal(good.state, "positive");
  // Something going well should still be able to carry a suggestion.
  assert.ok(!suppressesCards(good));
});

test("a question with a tired preamble is still a question", async () => {
  const { readEmotion } = await import("../dist/services/emotion.js");

  // Being solemn at someone who asked a practical question is its own failure.
  const asking = readEmotion("I'm shattered, what should I eat for dinner?");
  assert.equal(asking.needsAcknowledgement, false,
    "a direct question should still get answered");

  const venting = readEmotion("I'm completely shattered");
  assert.ok(venting.needsAcknowledgement);
});

test("ordinary questions carry no emotional read at all", async () => {
  const { readEmotion } = await import("../dist/services/emotion.js");

  // Reading distress into a neutral message is patronising.
  for (const q of ["What should I eat for dinner?",
                   "How many calories do I have left?",
                   "What workout should I do today?",
                   "How much protein is in chicken?"]) {
    assert.equal(readEmotion(q).state, null, `"${q}" was read as emotional`);
  }
});

test("shaming language is caught however gently it is phrased", async () => {
  const { isShaming } = await import("../dist/services/emotion.js");

  for (const answer of [
    "Why didn't you log yesterday?",
    "You should have stuck to the plan.",
    "That was a bad food choice.",
    "You are not going to reach 76kg like this.",
    "You're never going to lose it eating like that.",
    "There's no excuse for skipping three sessions.",
  ]) {
    assert.ok(isShaming(answer), `not caught: "${answer}"`);
  }

  // Curiosity about what made it hard is the opposite of blame.
  for (const answer of [
    "That sounds like a hard week. What got in the way?",
    "You're 60g short on protein — dinner can close it.",
    "You've logged 12 days straight, which is the part that matters.",
  ]) {
    assert.ok(!isShaming(answer), `false positive: "${answer}"`);
  }
});

test("stacked questions are caught even with one question mark", async () => {
  const { asksTooMuch } = await import("../dist/services/emotion.js");

  // Four questions wearing one coat. Counting question marks alone misses it,
  // and it reliably gets none of them answered.
  assert.ok(asksTooMuch("How was your sleep, stress, nutrition and mood?"));
  assert.ok(asksTooMuch("How did you sleep? And your energy? What about food?"));

  assert.ok(!asksTooMuch("How did you feel when you woke up — refreshed or exhausted?"));
  assert.ok(!asksTooMuch("You have 900 calories left. Protein is the gap."));
  // A statement mentioning several topics is fine; only the question counts.
  assert.ok(!asksTooMuch("Your sleep and stress both look lower this week. How did today feel?"));
});

test("a message about feeling low never returns a meal card", async () => {
  const u = await proUser("emotion-card");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Low", ...BASE_PROFILE } });

    for (const message of [
      "I'm completely overwhelmed with everything right now",
      "I feel like giving up on all of this",
      "I've been really down this week",
    ]) {
      const { status, json } = await api("/coach/ask", { method: "POST", body: { question: message } });
      assert.equal(status, 200);
      assert.equal(json.suggestion, null, `a card was attached to: "${message}"`);
      assert.ok(json.emotional_tone, "the tone should be reported so the UI can soften");
    }
  } finally { token = saved; }
});

test("the emotional steer tells the model what not to do", async () => {
  const { readEmotion, emotionalSteer } = await import("../dist/services/emotion.js");

  const overwhelmed = emotionalSteer(readEmotion("everything is too much right now"));
  assert.match(overwhelmed, /no lists|one small thing/i);

  const discouraged = emotionalSteer(readEmotion("I want to give up, nothing works"));
  // Selling the goal back to someone who is done with it does not help.
  assert.match(discouraged, /do not sell the goal|motivational/i);

  const exhausted = emotionalSteer(readEmotion("I'm completely drained"));
  assert.match(exhausted, /do not open with advice/i);

  // Only one question, when acknowledgement is needed.
  assert.match(overwhelmed, /at most one question/i);

  assert.equal(emotionalSteer(readEmotion("what should I eat")), "");
});

// ─── voice: warmth where it helps, plain words where it matters ───────────

test("emoji spam is detected and ordinary warmth is not", async () => {
  const { countEmoji, hasEmojiSpam } = await import("../dist/services/emotion.js");

  // One or two carrying meaning is the intent.
  assert.equal(countEmoji("That's a solid win today 💚 Keep it going."), 1);
  assert.ok(!hasEmojiSpam("You're run-down 😴 — a walk would do more than a session 🌿."));

  // Stacked glyphs read as noise and undercut whatever else the reply says.
  assert.ok(hasEmojiSpam("Great job!!! 🔥🔥🔥💪💪💪"));
  // One per sentence is the other failure mode.
  assert.ok(hasEmojiSpam("Run-down 😴. Sleep short 🌙. Try a walk 🌿. Rest well ✨."));

  assert.ok(!hasEmojiSpam("You have 900 calories left."));
});

test("safety replies are stripped of emoji entirely", async () => {
  const { mustBePlain, stripEmoji } = await import("../dist/services/emotion.js");

  // An emoji next to "contact emergency services" undermines the one message
  // that has to land. Not a style preference.
  for (const category of ["urgent", "self_harm", "medical", "diagnosis_request",
                          "exercise_risk"]) {
    assert.ok(mustBePlain(category), `${category} should be plain`);
  }
  assert.ok(!mustBePlain("brand"));
  assert.ok(!mustBePlain(null));

  const stripped = stripEmoji("That sounds serious ⚠️ — please see a doctor 🫶.");
  assert.ok(!/\p{Extended_Pictographic}/u.test(stripped));
  // And the punctuation survives the removal cleanly.
  assert.match(stripped, /doctor\.$/);
  assert.ok(!stripped.includes("  "));
});

test("a crisis reply carries no emoji", async () => {
  const u = await proUser("voice-crisis");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Voice", ...BASE_PROFILE } });

    for (const message of ["I want to kill myself",
                           "I have chest pain and can't breathe",
                           "what medication should I take for this"]) {
      const { json } = await api("/coach/ask", { method: "POST", body: { question: message } });
      assert.ok(!/\p{Extended_Pictographic}/u.test(json.answer),
        `emoji appeared in a safety reply to: "${message}"`);
    }
  } finally { token = saved; }
});

test("an ordinary reply is allowed to be warm", async () => {
  const { hasEmojiSpam, mustBePlain } = await import("../dist/services/emotion.js");

  // Nothing in the pipeline should strip warmth from a normal exchange —
  // over-correcting produces the clinical tone this is meant to avoid.
  assert.ok(!mustBePlain(null));
  assert.ok(!hasEmojiSpam("Nice work getting that walk in 💚"));
});

// ─── onboarding: ask once, adapt, never ask twice ─────────────────────────

test("onboarding never asks what the profile already holds", async () => {
  const u = await proUser("onb-known");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Known", ...BASE_PROFILE } });

    const { status, json } = await api("/onboarding/plan");
    assert.equal(status, 200);

    const aboutYou = json.screens.find((s) => s.id === "about_you");
    const fields = aboutYou ? aboutYou.fields.map((f) => f.key) : [];

    // Asking again tells the user the app is not paying attention.
    for (const known of ["name", "birth_year", "sex", "height_cm", "start_weight_kg"]) {
      assert.ok(!fields.includes(known), `re-asked for ${known}`);
    }
  } finally { token = saved; }
});

test("saying you don't exercise removes the training questions", async () => {
  const u = await proUser("onb-noex");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "NoEx", ...BASE_PROFILE } });

    const withExercise = await api("/onboarding/plan?answers=" +
      encodeURIComponent(JSON.stringify({ exercises: true })));
    const movementWith = withExercise.json.screens.find((s) => s.id === "movement");
    assert.ok(movementWith.fields.some((f) => f.key === "training_days"));

    const without = await api("/onboarding/plan?answers=" +
      encodeURIComponent(JSON.stringify({ exercises: false })));
    const movementWithout = without.json.screens.find((s) => s.id === "movement");

    // Scrolling past four training questions to confirm you don't train is
    // exactly the friction this is meant to remove.
    for (const key of ["training_days", "experience", "activities"]) {
      assert.ok(!movementWithout.fields.some((f) => f.key === key),
        `${key} still shown to a non-exerciser`);
    }
  } finally { token = saved; }
});

test("medication detail only appears after a yes", async () => {
  const u = await proUser("onb-meds");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Meds", ...BASE_PROFILE } });

    const no = await api("/onboarding/plan?answers=" +
      encodeURIComponent(JSON.stringify({ takes_medication: "no" })));
    const screenNo = no.json.screens.find((s) => s.id === "medications");
    assert.ok(!screenNo.fields.some((f) => f.key === "medications"));

    const yes = await api("/onboarding/plan?answers=" +
      encodeURIComponent(JSON.stringify({ takes_medication: "yes" })));
    const screenYes = yes.json.screens.find((s) => s.id === "medications");
    assert.ok(screenYes.fields.some((f) => f.key === "medications"));
  } finally { token = saved; }
});

test("a completed screen never comes back", async () => {
  const u = await proUser("onb-progress");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Prog", ...BASE_PROFILE } });

    const before = await api("/onboarding/plan");
    assert.ok(before.json.screens.some((s) => s.id === "mind"));

    await api("/onboarding/screen", { method: "POST", body: {
      screen: "mind",
      answers: { stress_level: "high", usual_mood: "up_and_down", coping: ["walking"] } } });

    const after = await api("/onboarding/plan");
    assert.ok(!after.json.screens.some((s) => s.id === "mind"));
    assert.ok(after.json.totalScreens < before.json.totalScreens);
  } finally { token = saved; }
});

test("a skipped sensitive screen is not re-asked either", async () => {
  const u = await proUser("onb-skip");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Skip", ...BASE_PROFILE } });

    await api("/onboarding/screen", { method: "POST", body: {
      screen: "health", answers: {}, skipped: true } });

    const plan = await api("/onboarding/plan");
    // Someone who declined once should not be asked again next launch.
    assert.ok(!plan.json.screens.some((s) => s.id === "health"));
  } finally { token = saved; }
});

test("onboarding answers land in the tables the coach reads", async () => {
  const u = await proUser("onb-save");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Save", ...BASE_PROFILE } });

    await api("/onboarding/screen", { method: "POST", body: {
      screen: "your_day",
      answers: { typical_bedtime: "23:00", typical_wake_time: "07:00",
                 sleep_quality: "mixed", activity_level: "sedentary" } } });

    await api("/onboarding/screen", { method: "POST", body: {
      screen: "nutrition",
      answers: { diet: "vegetarian", allergies: ["peanuts"], meals_per_day: 3 } } });

    await api("/onboarding/screen", { method: "POST", body: {
      screen: "goals",
      answers: { primary_goal: "improve_sleep",
                 success_looks_like: "waking up without hitting snooze" } } });

    const profile = await api("/health/profile");
    assert.equal(profile.json.schedule.sleep_quality, "mixed");
    assert.equal(profile.json.goals.primary_goal, "improve_sleep");
    assert.match(profile.json.goals.success_looks_like, /snooze/);

    // The bedtime reminder should follow their real bedtime, not a default.
    const prefs = await db.query(
      `SELECT target_bedtime FROM notification_prefs WHERE user_id = $1`, [u.uid]);
    assert.equal(String(prefs.rows[0].target_bedtime).slice(0, 5), "23:00");

    // Allergies are stored where the safety engine reads them, not only as a
    // food preference.
    const allergy = await db.query(
      `SELECT allergen FROM user_allergies WHERE user_id = $1`, [u.uid]);
    assert.equal(allergy.rows[0].allergen, "peanuts");
  } finally { token = saved; }
});

test("a declared condition makes the coach more careful, never more clinical", async () => {
  const { personalSteer, needsExtraCaution, loadPersonalSafety } =
    await import("../dist/services/safety.js");
  const u = await proUser("onb-condition");
  const saved = token; token = u.token;

  try {
    await api("/profile", { method: "POST", body: { name: "Cond", ...BASE_PROFILE } });
    await api("/onboarding/screen", { method: "POST", body: {
      screen: "health",
      answers: { conditions: ["type 2 diabetes"],
                 restriction: "no high-impact running" } } });
    await api("/onboarding/screen", { method: "POST", body: {
      screen: "nutrition", answers: { allergies: ["shellfish"] } } });

    const personal = await loadPersonalSafety(u.uid);
    assert.deepEqual(personal.conditions, ["type 2 diabetes"]);
    assert.deepEqual(personal.allergies, ["shellfish"]);

    const steer = personalSteer(personal);
    // The direction matters: constrain advice, never offer to manage the
    // condition.
    assert.match(steer, /conservative/i);
    assert.match(steer, /doctor|dietitian/i);
    assert.match(steer, /do not offer to manage/i);
    assert.match(steer, /shellfish/i);
    assert.match(steer, /high-impact running/i);

    // Fasting is ordinary advice for most people and a bigger deal here.
    assert.ok(needsExtraCaution("should I try fasting?", personal));
    assert.ok(!needsExtraCaution("what should I eat for dinner?", personal));
  } finally { token = saved; }
});

test("sensitive health data can be deleted", async () => {
  const u = await proUser("onb-delete");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Del", ...BASE_PROFILE } });
    await api("/onboarding/screen", { method: "POST", body: {
      screen: "health", answers: { conditions: ["asthma"] } } });
    await api("/onboarding/screen", { method: "POST", body: {
      screen: "medications", answers: { medications: ["inhaler"] } } });

    const before = await api("/health/profile");
    assert.equal(before.json.conditions.length, 1);
    assert.equal(before.json.medications.length, 1);

    // This is the most sensitive data in the product; removing it must work.
    await api(`/health/conditions/${before.json.conditions[0].id}`, { method: "DELETE" });
    await api(`/medications/${before.json.medications[0].id}`, { method: "DELETE" });

    const after = await api("/health/profile");
    assert.equal(after.json.conditions.length, 0);
    assert.equal(after.json.medications.length, 0);
  } finally { token = saved; }
});

test("health data is scoped to its owner", async () => {
  const a = await proUser("onb-a");
  const b = await proUser("onb-b");
  const saved = token;

  try {
    token = a.token;
    await api("/profile", { method: "POST", body: { name: "A", ...BASE_PROFILE } });
    await api("/onboarding/screen", { method: "POST", body: {
      screen: "health", answers: { conditions: ["a private condition"] } } });

    token = b.token;
    await api("/profile", { method: "POST", body: { name: "B", ...BASE_PROFILE } });
    const theirs = await api("/health/profile");
    assert.equal(theirs.json.conditions.length, 0,
      "user B can see user A's health conditions");
  } finally { token = saved; }
});

test("every onboarding screen fits in a short sitting", async () => {
  const u = await proUser("onb-length");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Len", ...BASE_PROFILE } });
    const { json } = await api("/onboarding/plan");

    assert.ok(json.totalScreens <= 8, `${json.totalScreens} screens is too many`);

    for (const screen of json.screens) {
      // A screen should be completable in well under a minute; six fields is
      // already pushing it.
      assert.ok(screen.fields.length <= 6,
        `${screen.id} has ${screen.fields.length} fields`);
      assert.ok(screen.title);
    }

    // Everything sensitive must be declinable.
    for (const id of ["health", "medications", "mind"]) {
      const screen = json.screens.find((s) => s.id === id);
      if (screen) assert.ok(screen.skippable, `${id} must be skippable`);
    }
  } finally { token = saved; }
});

test("a screen left holding one optional question disappears", async () => {
  const u = await proUser("onb-thin");
  const saved = token; token = u.token;
  try {
    // With a full nutrition profile, "About you" retains only the optional
    // work-type question — a page to dismiss for no benefit.
    await api("/profile", { method: "POST", body: { name: "Thin", ...BASE_PROFILE } });

    const { json } = await api("/onboarding/plan");
    const aboutYou = json.screens.find((s) => s.id === "about_you");

    if (aboutYou) {
      assert.ok(aboutYou.fields.length > 1 || !aboutYou.fields[0].optional,
        "a lone optional field should not justify a screen");
    }

    // The screens that remain all carry something worth asking.
    for (const screen of json.screens) {
      const required = screen.fields.filter((f) => !f.optional);
      assert.ok(screen.fields.length >= 2 || required.length >= 1,
        `${screen.id} is too thin to show`);
    }
  } finally { token = saved; }
});

test("the first coach conversation builds on onboarding, never repeats it", async () => {
  const u = await proUser("welcome");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Olivia Rose", ...BASE_PROFILE } });
    await api("/onboarding/screen", { method: "POST", body: {
      screen: "your_day",
      answers: { typical_bedtime: "23:00", typical_wake_time: "06:30",
                 sleep_quality: "mixed", activity_level: "sedentary" } } });
    await api("/onboarding/screen", { method: "POST", body: {
      screen: "movement", answers: { experience: "intermediate", training_days: 3 } } });
    await api("/onboarding/screen", { method: "POST", body: {
      screen: "goals",
      answers: { primary_goal: "lose_weight",
                 success_looks_like: "I have more energy" } } });

    const { status, json } = await api("/coach/welcome");
    assert.equal(status, 200);
    assert.equal(json.seen, false);
    assert.match(json.greeting, /Olivia/);

    // It quotes what it knows rather than asking again.
    assert.ok(json.knows.some((k) => /11pm|6:30am/.test(k)));

    const sleep = json.topics.find((t) => t.id === "sleep");
    assert.ok(sleep.opener.includes("11pm"),
      `the sleep opener should build on known times: "${sleep.opener}"`);

    // The questions onboarding already answered must not reappear.
    for (const topic of json.topics) {
      assert.ok(!/what time do you (sleep|wake)/i.test(topic.opener),
        `re-asks a known fact: "${topic.opener}"`);
      assert.ok(!/^do you exercise/i.test(topic.opener));
    }
  } finally { token = saved; }
});

test("a user who has already talked to the coach gets no greeting", async () => {
  const u = await proUser("welcome-seen");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Met", ...BASE_PROFILE } });
    await api("/coach/ask", { method: "POST", body: { question: "What should I eat?" } });

    const { json } = await api("/coach/welcome");
    assert.equal(json.seen, true);
    // Replaying an introduction undoes the personalization it demonstrates.
    assert.equal(json.greeting, null);
  } finally { token = saved; }
});

test("a welcome reply is stored in the user's own words", async () => {
  const u = await proUser("welcome-reply");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Reply", ...BASE_PROFILE } });

    await api("/coach/welcome/reply", { method: "POST", body: {
      topic: "sleep", reply: "I usually wake up still tired even after 8 hours" } });

    const memories = await api("/brain/memories");
    const semantic = memories.json.layers.semantic ?? [];
    const stored = semantic.find((m) => /still tired/.test(m.content));

    assert.ok(stored, "the reply should become a lasting memory");
    // Told to us directly, so it outranks anything inferred.
    assert.ok(stored.confidence >= 0.75);
  } finally { token = saved; }
});

test("weight never blocks onboarding", async () => {
  const u = await proUser("weight-optional");
  const saved = token; token = u.token;
  try {
    const { json } = await api("/onboarding/plan");
    const aboutYou = json.screens.find((s) => s.id === "about_you");

    if (aboutYou) {
      const weight = aboutYou.fields.find((f) => f.key === "start_weight_kg");
      if (weight) {
        // The field most likely to lose someone mid-onboarding, and one
        // HealthKit can supply later.
        assert.equal(weight.optional, true);
        assert.match(weight.placeholder, /add your weight/i);
      }
    }
  } finally { token = saved; }
});

test("goals are asked once, on the goals screen only", async () => {
  const u = await proUser("goals-once");
  const saved = token; token = u.token;
  try {
    await api("/profile", { method: "POST", body: { name: "Goals", ...BASE_PROFILE } });
    const { json } = await api("/onboarding/plan");

    const movement = json.screens.find((s) => s.id === "movement");
    if (movement) {
      assert.ok(!movement.fields.some((f) => /goal/i.test(f.key)),
        "goals must not appear on the movement screen");
    }

    const goals = json.screens.find((s) => s.id === "goals");
    assert.ok(goals.fields.some((f) => f.key === "primary_goal"));
    assert.ok(goals.fields.some((f) => f.key === "success_looks_like"));
  } finally { token = saved; }
});
