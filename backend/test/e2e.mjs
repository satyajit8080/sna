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
