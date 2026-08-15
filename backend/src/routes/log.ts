import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { q, one, tx } from "../db.js";
import { requireAuth } from "../middleware/auth.js";
import { localDate, daysAgo, nextLocalMidnight } from "../util/dates.js";
import { activityFor } from "../services/activity.js";

const Item = z.object({
  food_id: z.string().uuid().nullable().optional(),
  name: z.string().min(1).max(80),
  quantity: z.number().min(0.01).max(100).default(1),
  unit: z.string().max(20).default("g"),
  grams: z.number().min(1).max(3000),
  kcal_100g: z.number().min(0).max(950),
  protein_100g: z.number().min(0).max(100),
  carbs_100g: z.number().min(0).max(100),
  fat_100g: z.number().min(0).max(100),
  confidence: z.number().min(0).max(1).optional(),
  is_estimate: z.boolean().default(true),
});

const MealIn = z.object({
  slot: z.enum(["breakfast", "lunch", "dinner", "snack"]),
  input_method: z.enum(["photo", "text", "voice", "barcode", "search", "manual"]),
  logged_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  note: z.string().max(200).optional(),
  ai_confidence: z.number().min(0).max(1).optional(),
  items: z.array(Item).min(1).max(20),
});

const MACROS = `
  ROUND(SUM(i.grams * i.kcal_100g    / 100))::int AS calories,
  ROUND(SUM(i.grams * i.protein_100g / 100))::int AS protein_g,
  ROUND(SUM(i.grams * i.carbs_100g   / 100))::int AS carbs_g,
  ROUND(SUM(i.grams * i.fat_100g     / 100))::int AS fat_g`;

async function dayMeals(userId: string, day: string) {
  return q(
    `SELECT m.id, m.slot, m.input_method, m.note, m.logged_at, m.ai_confidence, ${MACROS},
            COALESCE(json_agg(json_build_object(
              'id', i.id, 'name', i.name, 'quantity', i.quantity, 'unit', i.unit,
              'grams', i.grams, 'kcal_100g', i.kcal_100g, 'protein_100g', i.protein_100g,
              'carbs_100g', i.carbs_100g, 'fat_100g', i.fat_100g,
              'calories', ROUND(i.grams * i.kcal_100g / 100),
              'protein_g', ROUND(i.grams * i.protein_100g / 100),
              'carbs_g', ROUND(i.grams * i.carbs_100g / 100),
              'fat_g', ROUND(i.grams * i.fat_100g / 100),
              'is_estimate', i.is_estimate
            ) ORDER BY i.position), '[]') AS items
       FROM meals m LEFT JOIN meal_items i ON i.meal_id = m.id
      WHERE m.user_id = $1 AND m.logged_on = $2
      GROUP BY m.id ORDER BY m.logged_at`,
    [userId, day]
  );
}

export default async function routes(app: FastifyInstance) {
  // ── meals ─────────────────────────────────────────────────────────────────
  app.post("/meals", { preHandler: requireAuth }, async (req) => {
    const body = MealIn.parse(req.body);
    const day = body.logged_on ?? localDate(req.tz);

    const id = await tx(async (c) => {
      const { rows } = await c.query(
        `INSERT INTO meals (user_id, logged_on, slot, input_method, note, ai_confidence)
         VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
        [req.userId, day, body.slot, body.input_method, body.note ?? null, body.ai_confidence ?? null]
      );
      const mealId = rows[0].id;
      for (const [pos, it] of body.items.entries()) {
        await c.query(
          `INSERT INTO meal_items (meal_id, food_id, name, quantity, unit, grams,
                                   kcal_100g, protein_100g, carbs_100g, fat_100g,
                                   is_estimate, confidence, position)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
          [mealId, it.food_id ?? null, it.name, it.quantity, it.unit, it.grams,
           it.kcal_100g, it.protein_100g, it.carbs_100g, it.fat_100g,
           it.is_estimate, it.confidence ?? null, pos]
        );
      }
      return mealId as string;
    });

    return { id, logged_on: day };
  });

  /**
   * Quantity edits go here — pure arithmetic on stored per-100g values.
   * This endpoint never touches the AI provider.
   */
  app.patch("/meals/:id", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const body = z.object({
      slot: z.enum(["breakfast", "lunch", "dinner", "snack"]).optional(),
      items: z.array(Item.extend({ id: z.string().uuid().optional() })).min(1).max(20).optional(),
    }).parse(req.body);

    const owned = await one(`SELECT id FROM meals WHERE id = $1 AND user_id = $2`, [id, req.userId]);
    if (!owned) return reply.code(404).send({ error: "not_found" });

    await tx(async (c) => {
      if (body.slot) await c.query(`UPDATE meals SET slot = $2 WHERE id = $1`, [id, body.slot]);
      if (body.items) {
        await c.query(`DELETE FROM meal_items WHERE meal_id = $1`, [id]);
        for (const [pos, it] of body.items.entries()) {
          await c.query(
            `INSERT INTO meal_items (meal_id, food_id, name, quantity, unit, grams,
                                     kcal_100g, protein_100g, carbs_100g, fat_100g,
                                     is_estimate, confidence, position)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
            [id, it.food_id ?? null, it.name, it.quantity, it.unit, it.grams,
             it.kcal_100g, it.protein_100g, it.carbs_100g, it.fat_100g,
             it.is_estimate, it.confidence ?? null, pos]
          );
        }
      }
    });

    return one(`SELECT m.id, ${MACROS} FROM meals m JOIN meal_items i ON i.meal_id = m.id
                 WHERE m.id = $1 GROUP BY m.id`, [id]);
  });

  app.delete("/meals/:id", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const rows = await q(`DELETE FROM meals WHERE id = $1 AND user_id = $2 RETURNING id`, [id, req.userId]);
    if (!rows.length) return reply.code(404).send({ error: "not_found" });
    return { deleted: true };
  });

  app.get("/meals/today", { preHandler: requireAuth }, async (req) => ({
    date: localDate(req.tz),
    meals: await dayMeals(req.userId, localDate(req.tz)),
  }));

  app.get("/meals", { preHandler: requireAuth }, async (req) => {
    const { date } = z.object({ date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/) }).parse(req.query);
    return { date, meals: await dayMeals(req.userId, date) };
  });

  // ── dashboard: one call, everything Home needs ────────────────────────────
  app.get("/dashboard", { preHandler: requireAuth }, async (req) => {
    // The day boundary is the user's local midnight. `req.tz` comes from the
    // X-Timezone header, falling back to the profile's stored zone — so the
    // dashboard resets at midnight wherever they are, and a flight does not
    // merge two days into one.
    const day = localDate(req.tz);

    const [targets, totals, water, weight, streak, activity] = await Promise.all([
      one(`SELECT calories, protein_g, carbs_g, fat_g, water_ml FROM nutrition_targets WHERE user_id = $1`, [req.userId]),
      one(`SELECT ${MACROS} FROM meals m JOIN meal_items i ON i.meal_id = m.id
            WHERE m.user_id = $1 AND m.logged_on = $2`, [req.userId, day]),
      one(`SELECT COALESCE(SUM(ml),0)::int AS ml FROM water_logs WHERE user_id = $1 AND logged_on = $2`, [req.userId, day]),
      one(`SELECT weight_kg FROM weight_logs WHERE user_id = $1 ORDER BY logged_on DESC LIMIT 1`, [req.userId]),
      one<{ n: number }>(
        `WITH days AS (SELECT DISTINCT logged_on FROM meals WHERE user_id = $1 ORDER BY logged_on DESC)
         SELECT COUNT(*)::int AS n FROM (
           SELECT logged_on, logged_on + (ROW_NUMBER() OVER (ORDER BY logged_on DESC))::int AS grp FROM days
         ) t WHERE grp = (SELECT logged_on + 1 FROM days LIMIT 1)`, [req.userId]),
      activityFor(req.userId, req.tz, day),
    ]);

    const consumed = totals ?? { calories: 0, protein_g: 0, carbs_g: 0, fat_g: 0 };
    const t: any = targets ?? { calories: 2000, protein_g: 120, carbs_g: 220, fat_g: 60, water_ml: 2500 };

    // Movement raises the day's allowance. `credited_kcal` is already
    // discounted by the user's activity_credit setting, so adding it here
    // cannot double-count what the target assumed.
    const budget = t.calories + activity.credited_kcal;

    return {
      date: day,
      timezone: req.tz,
      // When this day rolls over, so the client can schedule its own refresh
      // instead of polling.
      resets_at: nextLocalMidnight(req.tz),
      targets: t,
      consumed,
      activity,
      budget: {
        base_calories: t.calories,
        activity_bonus: activity.credited_kcal,
        total_calories: budget,
      },
      remaining: {
        calories: budget - (consumed.calories ?? 0),
        protein_g: t.protein_g - (consumed.protein_g ?? 0),
        carbs_g: t.carbs_g - (consumed.carbs_g ?? 0),
        fat_g: t.fat_g - (consumed.fat_g ?? 0),
      },
      water_ml: water?.ml ?? 0,
      current_weight_kg: weight?.weight_kg ?? null,
      streak_days: streak?.n ?? 0,
      meals: await dayMeals(req.userId, day),
    };
  });

  // ── weight ────────────────────────────────────────────────────────────────
  app.post("/weight", { preHandler: requireAuth }, async (req) => {
    const b = z.object({
      weight_kg: z.number().min(25).max(400),
      logged_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
    }).parse(req.body);
    return one(
      `INSERT INTO weight_logs (user_id, logged_on, weight_kg) VALUES ($1,$2,$3)
       ON CONFLICT (user_id, logged_on) DO UPDATE SET weight_kg = EXCLUDED.weight_kg
       RETURNING logged_on, weight_kg`,
      [req.userId, b.logged_on ?? localDate(req.tz), b.weight_kg]
    );
  });

  app.get("/weight", { preHandler: requireAuth }, async (req) => {
    const { days } = z.object({ days: z.coerce.number().min(7).max(365).default(90) }).parse(req.query);
    const [profile, logs] = await Promise.all([
      one(`SELECT start_weight_kg, goal_weight_kg FROM profiles WHERE user_id = $1`, [req.userId]),
      q(`SELECT logged_on, weight_kg FROM weight_logs
          WHERE user_id = $1 AND logged_on > CURRENT_DATE - $2::int ORDER BY logged_on`,
        [req.userId, days]),
    ]);
    return { ...(profile ?? {}), current_weight_kg: logs.at(-1)?.weight_kg ?? null, logs };
  });

  // ── water ─────────────────────────────────────────────────────────────────
  app.post("/water", { preHandler: requireAuth }, async (req) => {
    const b = z.object({ ml: z.number().int().min(-2000).max(2000) }).parse(req.body);
    const day = localDate(req.tz);
    await q(`INSERT INTO water_logs (user_id, logged_on, ml) VALUES ($1,$2,$3)`, [req.userId, day, b.ml]);
    return one(`SELECT COALESCE(SUM(ml),0)::int AS ml FROM water_logs WHERE user_id = $1 AND logged_on = $2`,
      [req.userId, day]);
  });

  // ── history ───────────────────────────────────────────────────────────────
  app.get("/history", { preHandler: requireAuth }, async (req) => {
    const { range } = z.object({ range: z.enum(["week", "month", "quarter"]).default("week") }).parse(req.query);
    const days = range === "week" ? 7 : range === "month" ? 30 : 90;
    const today = localDate(req.tz);

    const [nutrition, weight] = await Promise.all([
      q(`SELECT m.logged_on AS date, ${MACROS}
           FROM meals m JOIN meal_items i ON i.meal_id = m.id
          WHERE m.user_id = $1 AND m.logged_on >= $2
          GROUP BY m.logged_on ORDER BY m.logged_on`, [req.userId, daysAgo(today, days)]),
      q(`SELECT logged_on AS date, weight_kg FROM weight_logs
          WHERE user_id = $1 AND logged_on >= $2 ORDER BY logged_on`, [req.userId, daysAgo(today, days)]),
    ]);

    const avg = (k: string) =>
      nutrition.length ? Math.round(nutrition.reduce((a: number, d: any) => a + d[k], 0) / nutrition.length) : 0;

    return {
      range, days,
      nutrition, weight,
      averages: { calories: avg("calories"), protein_g: avg("protein_g"), carbs_g: avg("carbs_g"), fat_g: avg("fat_g") },
      days_logged: nutrition.length,
    };
  });
}
