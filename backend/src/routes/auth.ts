import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { randomBytes, scryptSync, timingSafeEqual } from "node:crypto";
import { q, one, tx } from "../db.js";
import { issueToken, requireAuth } from "../middleware/auth.js";
import { computeTargets, projectedWeeks } from "../services/targets.js";

const ProfileIn = z.object({
  name: z.string().min(1).max(60),
  birth_year: z.number().int().min(1920).max(new Date().getFullYear() - 13),
  sex: z.enum(["male", "female", "other"]),
  height_cm: z.number().min(90).max(250),
  start_weight_kg: z.number().min(25).max(400),
  goal_weight_kg: z.number().min(25).max(400),
  goal: z.enum(["lose", "maintain", "gain"]),
  activity_level: z.enum(["sedentary", "light", "moderate", "active", "very_active"]),
  units: z.enum(["metric", "imperial"]).default("metric"),
  country: z.string().length(2).optional(),
});

function hash(pw: string) {
  const salt = randomBytes(16).toString("hex");
  return `${salt}:${scryptSync(pw, salt, 64).toString("hex")}`;
}
function verify(pw: string, stored: string) {
  const [salt, key] = stored.split(":");
  if (!salt || !key) return false;
  return timingSafeEqual(Buffer.from(key, "hex"), scryptSync(pw, salt, 64));
}

export default async function routes(app: FastifyInstance) {
  // ── email/password ────────────────────────────────────────────────────────
  app.post("/auth/signup", async (req, reply) => {
    const body = z.object({ email: z.string().email(), password: z.string().min(8) }).parse(req.body);
    const existing = await one(`SELECT id FROM users WHERE email = $1`, [body.email]);
    if (existing) return reply.code(409).send({ error: "email_taken" });

    const user = await one<{ id: string }>(
      `INSERT INTO users (email, password_hash) VALUES ($1,$2) RETURNING id`,
      [body.email, hash(body.password)]
    );
    await q(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [user!.id]);
    return { token: await issueToken(user!.id), onboarded: false };
  });

  app.post("/auth/login", async (req, reply) => {
    const body = z.object({ email: z.string().email(), password: z.string() }).parse(req.body);
    const user = await one<any>(
      `SELECT id, password_hash FROM users WHERE email = $1 AND deleted_at IS NULL`, [body.email]
    );
    if (!user?.password_hash || !verify(body.password, user.password_hash))
      return reply.code(401).send({ error: "invalid_credentials" });

    const prof = await one(`SELECT user_id FROM profiles WHERE user_id = $1`, [user.id]);
    return { token: await issueToken(user.id), onboarded: !!prof };
  });

  // ── Sign in with Apple ────────────────────────────────────────────────────
  // identityToken is verified against Apple's JWKS in verifyAppleToken().
  app.post("/auth/apple", async (req) => {
    const body = z.object({ identity_token: z.string(), name: z.string().optional() }).parse(req.body);
    const sub = await verifyAppleToken(body.identity_token);

    let user = await one<{ id: string }>(`SELECT id FROM users WHERE apple_sub = $1`, [sub]);
    if (!user) {
      user = await one<{ id: string }>(`INSERT INTO users (apple_sub) VALUES ($1) RETURNING id`, [sub]);
      await q(`INSERT INTO subscriptions (user_id) VALUES ($1)`, [user!.id]);
    }
    const prof = await one(`SELECT user_id FROM profiles WHERE user_id = $1`, [user!.id]);
    return { token: await issueToken(user!.id), onboarded: !!prof };
  });

  // ── onboarding → profile + targets ────────────────────────────────────────
  app.post("/profile", { preHandler: requireAuth }, async (req) => {
    const p = ProfileIn.parse(req.body);
    const t = computeTargets(p);

    await tx(async (c) => {
      await c.query(
        `INSERT INTO profiles (user_id,name,birth_year,sex,height_cm,start_weight_kg,goal_weight_kg,goal,activity_level,units,country)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
         ON CONFLICT (user_id) DO UPDATE SET
           name=EXCLUDED.name, birth_year=EXCLUDED.birth_year, sex=EXCLUDED.sex,
           height_cm=EXCLUDED.height_cm, start_weight_kg=EXCLUDED.start_weight_kg,
           goal_weight_kg=EXCLUDED.goal_weight_kg, goal=EXCLUDED.goal,
           activity_level=EXCLUDED.activity_level, units=EXCLUDED.units,
           country=EXCLUDED.country, updated_at=now()`,
        [req.userId, p.name, p.birth_year, p.sex, p.height_cm, p.start_weight_kg, p.goal_weight_kg, p.goal, p.activity_level, p.units, p.country ?? null]
      );
      await c.query(
        `INSERT INTO nutrition_targets (user_id,calories,protein_g,carbs_g,fat_g,water_ml,bmr,tdee)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
         ON CONFLICT (user_id) DO UPDATE SET
           calories=EXCLUDED.calories, protein_g=EXCLUDED.protein_g, carbs_g=EXCLUDED.carbs_g,
           fat_g=EXCLUDED.fat_g, water_ml=EXCLUDED.water_ml, bmr=EXCLUDED.bmr,
           tdee=EXCLUDED.tdee, source='auto', updated_at=now()`,
        [req.userId, t.calories, t.protein_g, t.carbs_g, t.fat_g, t.water_ml, t.bmr, t.tdee]
      );
      await c.query(
        `INSERT INTO weight_logs (user_id, logged_on, weight_kg) VALUES ($1, CURRENT_DATE, $2)
         ON CONFLICT (user_id, logged_on) DO UPDATE SET weight_kg = EXCLUDED.weight_kg`,
        [req.userId, p.start_weight_kg]
      );
    });

    return { targets: t, projected_weeks: projectedWeeks(p, t.calories, t.tdee) };
  });

  app.get("/profile", { preHandler: requireAuth }, async (req) => ({
    profile: await one(`SELECT * FROM profiles WHERE user_id = $1`, [req.userId]),
    targets: await one(`SELECT * FROM nutrition_targets WHERE user_id = $1`, [req.userId]),
  }));

  app.patch("/targets", { preHandler: requireAuth }, async (req) => {
    const t = z.object({
      calories: z.number().int().min(1000).max(6000),
      protein_g: z.number().int().min(20).max(400),
      carbs_g: z.number().int().min(0).max(800),
      fat_g: z.number().int().min(10).max(300),
      water_ml: z.number().int().min(500).max(6000).optional(),
    }).parse(req.body);
    return one(
      `UPDATE nutrition_targets SET calories=$2, protein_g=$3, carbs_g=$4, fat_g=$5,
              water_ml=COALESCE($6, water_ml), source='manual', updated_at=now()
        WHERE user_id=$1 RETURNING *`,
      [req.userId, t.calories, t.protein_g, t.carbs_g, t.fat_g, t.water_ml ?? null]
    );
  });

  // ── data rights ───────────────────────────────────────────────────────────
  app.get("/account/export", { preHandler: requireAuth }, async (req) => ({
    profile: await one(`SELECT * FROM profiles WHERE user_id = $1`, [req.userId]),
    targets: await one(`SELECT * FROM nutrition_targets WHERE user_id = $1`, [req.userId]),
    meals: await q(`SELECT m.*, json_agg(i.*) AS items FROM meals m
                      LEFT JOIN meal_items i ON i.meal_id = m.id
                     WHERE m.user_id = $1 GROUP BY m.id ORDER BY m.logged_on DESC`, [req.userId]),
    weight: await q(`SELECT logged_on, weight_kg FROM weight_logs WHERE user_id = $1 ORDER BY logged_on`, [req.userId]),
    water: await q(`SELECT logged_on, ml FROM water_logs WHERE user_id = $1 ORDER BY logged_on`, [req.userId]),
  }));

  app.delete("/account", { preHandler: requireAuth }, async (req) => {
    // Hard delete. ON DELETE CASCADE removes every dependent row.
    await q(`DELETE FROM users WHERE id = $1`, [req.userId]);
    return { deleted: true };
  });
}

// ── Apple identity token verification ───────────────────────────────────────
import { createRemoteJWKSet, jwtVerify } from "jose";
import { cfg } from "../config.js";

const APPLE_JWKS = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

async function verifyAppleToken(token: string): Promise<string> {
  const { payload } = await jwtVerify(token, APPLE_JWKS, {
    issuer: "https://appleid.apple.com",
    audience: cfg.APPLE_BUNDLE_ID,
  });
  if (!payload.sub) throw Object.assign(new Error("bad_apple_token"), { statusCode: 401 });
  return String(payload.sub);
}
