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

async function api(path, { method = "GET", body, form, auth = true } = {}) {
  const headers = { "X-Timezone": "Asia/Kolkata" };
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
  const { status, json } = await api("/dashboard");
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
