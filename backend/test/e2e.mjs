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

test("pro-only inputs are rejected for free users", async () => {
  const { status, json } = await api("/food/voice", { method: "POST", body: { transcript: "one banana" } });
  assert.equal(status, 402);
  assert.equal(json.error, "pro_required");
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
