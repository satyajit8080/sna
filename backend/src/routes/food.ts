import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { cfg } from "../config.js";
import { q, one } from "../db.js";
import { requireAuth } from "../middleware/auth.js";
import { ai, ProviderError, type Usage } from "../ai/index.js";
import { normaliseImage, pHash } from "../util/image.js";
import { resolveFoods, searchFoods, type ResolvedItem } from "../nutrition/resolve.js";
import { searchUsdaMany, usdaDetail, portion } from "../nutrition/usda.js";
import { lookupBarcode } from "../nutrition/openfoodfacts.js";
import {
  reserve, settle, release, entitlementsFor,
  type Reservation,
} from "../services/entitlements.js";
import { assessScan } from "../services/scanVerdict.js";

/**
 * Every response carries `is_estimate` — never a medical-grade claim — and a
 * verdict.
 *
 * Async and centralised on purpose: there are five scan paths (photo, text,
 * voice, barcode, search) and attaching the verdict at each one meant the
 * first attempt wired it to a single path and silently missed four.
 */
async function envelope(
  userId: string, tz: string,
  items: ResolvedItem[], assumptions: string[], confidence: number
) {
  const sum = (f: (i: ResolvedItem) => number) => items.reduce((a, i) => a + f(i), 0);

  return {
    foods: items.map((i) => ({
      ...i,
      calories: Math.round((i.grams * i.kcal_100g) / 100),
      protein_g: Math.round((i.grams * i.protein_100g) / 100),
      carbs_g: Math.round((i.grams * i.carbs_100g) / 100),
      fat_g: Math.round((i.grams * i.fat_100g) / 100),
    })),
    total: {
      calories: Math.round(sum((i) => (i.grams * i.kcal_100g) / 100)),
      protein_g: Math.round(sum((i) => (i.grams * i.protein_100g) / 100)),
      carbs_g: Math.round(sum((i) => (i.grams * i.carbs_100g) / 100)),
      fat_g: Math.round(sum((i) => (i.grams * i.fat_100g) / 100)),
    },
    confidence,
    assumptions,
    is_estimate: true,
    disclaimer: "AI estimate. Not a medical or clinical measurement.",
    verdict: await assessScan(userId, tz, items.map((i) => ({
      name: i.name, grams: i.grams,
      kcal_100g: i.kcal_100g, protein_100g: i.protein_100g,
      carbs_100g: i.carbs_100g, fat_100g: i.fat_100g,
      fiber_100g: (i as any).fiber_100g ?? null,
    }))),
  };
}

/**
 * Wraps the reserve → call → settle lifecycle so no path can leak a reservation.
 * On failure the reservation is marked failed, which returns the scan to the
 * user's allowance while still recording any tokens actually burned.
 */
async function withReservation<T>(
  req: FastifyRequest,
  kind: string,
  work: (reservation: Reservation) => Promise<{ value: T; usages: Usage[]; cacheHit?: boolean }>
): Promise<T> {
  const reservation = await reserve(req.userId, kind);
  try {
    const { value, usages, cacheHit } = await work(reservation);
    await settle(reservation, req.userId, kind, ai.primary().name, usages, { cacheHit });
    return value;
  } catch (e: any) {
    await release(reservation, e instanceof ProviderError ? e.usages : []);
    throw e;
  }
}

export default async function routes(app: FastifyInstance) {
  // ── POST /food/analyze — the product. Everything else is secondary. ───────
  app.post("/food/analyze", { preHandler: requireAuth }, async (req, reply) => {
    const file = await (req as any).file({ limits: { fileSize: cfg.MAX_UPLOAD_BYTES } });
    if (!file) return reply.code(400).send({ error: "image_required" });

    const raw = await file.toBuffer();
    if (raw.length === 0) return reply.code(400).send({ error: "image_required" });
    if (raw.length > cfg.MAX_UPLOAD_BYTES) return reply.code(413).send({ error: "image_too_large" });

    let jpeg: Buffer;
    try {
      jpeg = await normaliseImage(raw);
    } catch {
      return reply.code(400).send({ error: "unreadable_image" });
    }

    const hash = await pHash(jpeg);
    const hint = typeof file.fields?.hint?.value === "string" ? file.fields.hint.value : undefined;

    return withReservation(req, "image", async () => {
      // Identical plate photographed twice → zero model spend.
      const cached = await one<{ result: any }>(
        `UPDATE analysis_cache SET hits = hits + 1
          WHERE phash = $1 AND created_at > now() - interval '30 days'
          RETURNING result`,
        [hash]
      );
      if (cached) return { value: { ...cached.result, cached: true }, usages: [], cacheHit: true };

      const { result, usages } = await ai.withFailover((p) => p.analyzeImage(jpeg, hint));

      if (result.foods.length === 0) {
        throw Object.assign(new ProviderError("no_food_detected", usages, false), {
          statusCode: 422, code: "no_food_detected", assumptions: result.assumptions,
        });
      }

      const items = await resolveFoods(result.foods);
      const payload = await envelope(req.userId, req.tz, items,
                                     result.assumptions, result.confidence);

      await q(
        `INSERT INTO analysis_cache (phash, result) VALUES ($1,$2) ON CONFLICT (phash) DO NOTHING`,
        [hash, JSON.stringify(payload)]
      );

      // The image buffer is never written to disk or object storage.
      return { value: payload, usages };
    });
  });

  // ── POST /food/text — "2 eggs, 2 rotis and chicken curry" ─────────────────
  app.post("/food/text", { preHandler: requireAuth }, async (req) => {
    const { text } = z.object({ text: z.string().min(2).max(400) }).parse(req.body);

    return withReservation(req, "text", async () => {
      const { result, usages } = await ai.withFailover((p) => p.analyzeText(text));
      const items = await resolveFoods(result.foods);
      return { value: await envelope(req.userId, req.tz, items, result.assumptions, result.confidence), usages };
    });
  });

  // ── POST /food/voice — transcript from on-device SFSpeechRecognizer ───────
  // Audio never leaves the phone; only the transcript reaches us.
  app.post("/food/voice", { preHandler: requireAuth }, async (req) => {
    const { transcript } = z.object({ transcript: z.string().min(2).max(400) }).parse(req.body);

    return withReservation(req, "voice", async () => {
      const { result, usages } = await ai.withFailover((p) => p.analyzeText(transcript));
      const items = await resolveFoods(result.foods);
      return { value: await envelope(req.userId, req.tz, items, result.assumptions, result.confidence), usages };
    });
  });

  // ── POST /food/barcode — database lookup, zero AI spend ───────────────────
  app.post("/food/barcode", { preHandler: requireAuth }, async (req, reply) => {
    const { barcode, grams } = z.object({
      barcode: z.string().regex(/^\d{8,14}$/),
      grams: z.number().min(1).max(2000).optional(),
    }).parse(req.body);

    return withReservation(req, "barcode", async () => {
      let row = await one<any>(`SELECT * FROM food_database WHERE barcode = $1`, [barcode]);

      if (!row) {
        const off = await lookupBarcode(barcode);
        if (!off) {
          throw Object.assign(new Error("barcode_not_found"), { statusCode: 404, code: "barcode_not_found" });
        }
        row = await one<any>(
          `INSERT INTO food_database (name, brand, barcode, source, source_ref, cuisine,
                                      kcal_100g, protein_100g, carbs_100g, fat_100g, fiber_100g,
                                      default_unit, default_grams, verified)
           VALUES ($1,$2,$3,'openfoodfacts',$3,'global',$4,$5,$6,$7,$8,'serving',$9,true)
           ON CONFLICT (barcode) DO UPDATE SET fetched_at = now()
           RETURNING *`,
          [off.name, off.brand ?? null, off.barcode, off.kcal_100g, off.protein_100g,
           off.carbs_100g, off.fat_100g, off.fiber_100g ?? null, off.default_grams ?? 100]
        );
      }

      const g = grams ?? (Number(row.default_grams) || 100);
      const value = await envelope(req.userId, req.tz, [{
        food_id: row.id,
        name: row.brand ? `${row.brand} ${row.name}` : row.name,
        grams: g, quantity: 1, unit: row.default_unit ?? "serving",
        kcal_100g: row.kcal_100g, protein_100g: row.protein_100g,
        carbs_100g: row.carbs_100g, fat_100g: row.fat_100g,
        confidence: 0.99, is_estimate: false, matched_source: row.source,
      }], [], 0.99);

      return { value, usages: [] };
    }).catch((e) => {
      if (e?.statusCode === 404) return reply.code(404).send({ error: "barcode_not_found", barcode });
      throw e;
    });
  });

  // ── GET /food/search — plain DB search, zero AI ──────────────────────────
  app.get("/food/search", { preHandler: requireAuth }, async (req) => {
    const { term } = z.object({ term: z.string().min(2).max(60) }).parse(req.query);
    return { results: await searchFoods(term) };
  });

  // Kept for the existing client; /entitlements is the richer replacement.
  // ── USDA FoodData Central — free, no AI, no quota ────────────────────────
  // Local curated table first (regional foods USDA covers poorly), then USDA.
  app.get("/food/lookup", { preHandler: requireAuth }, async (req) => {
    const { term, branded, limit } = z.object({
      term: z.string().min(2).max(60),
      branded: z.coerce.boolean().default(false),
      limit: z.coerce.number().min(1).max(25).default(10),
    }).parse(req.query);

    const local = await searchFoods(term, limit);
    let usda: any[] = [];
    try {
      usda = await searchUsdaMany(term, { limit, branded });
    } catch (e: any) {
      // A throttled USDA key must not break the picker; local results stand.
      if (e?.code !== "usda_rate_limited") throw e;
    }

    return {
      term,
      results: [
        ...local.map((f: any) => ({
          id: f.id, source: "snapcal", name: f.name, brand: f.brand ?? null,
          kcal_100g: f.kcal_100g, protein_100g: f.protein_100g,
          carbs_100g: f.carbs_100g, fat_100g: f.fat_100g,
          default_unit: f.default_unit, default_grams: f.default_grams,
        })),
        ...usda.map((f) => ({
          id: null, fdc_id: f.fdc_id, source: "usda", name: f.name, brand: f.brand ?? null,
          data_type: f.data_type,
          kcal_100g: f.kcal_100g, protein_100g: f.protein_100g,
          carbs_100g: f.carbs_100g, fat_100g: f.fat_100g,
          fiber_100g: f.fiber_100g ?? null,
          serving_size: f.serving_size ?? null, serving_unit: f.serving_unit ?? null,
          household_serving: f.household_serving ?? null,
          default_unit: f.serving_unit ?? "g",
          default_grams: f.serving_size ?? 100,
        })),
      ],
    };
  });

  /** Full detail plus macros scaled to a portion, ready to add to a meal. */
  app.get("/food/usda/:fdcId", { preHandler: requireAuth }, async (req, reply) => {
    const { fdcId } = z.object({ fdcId: z.string().regex(/^\d+$/) }).parse(req.params);
    const { grams } = z.object({
      grams: z.coerce.number().min(1).max(3000).optional(),
    }).parse(req.query);

    const food = await usdaDetail(fdcId);
    if (!food) return reply.code(404).send({ error: "food_not_found", fdc_id: fdcId });

    const g = grams ?? food.serving_size ?? 100;

    // Cache into food_database so repeat lookups skip USDA entirely.
    const cached = await one<{ id: string }>(
      `INSERT INTO food_database (name, brand, source, source_ref, cuisine,
                                  kcal_100g, protein_100g, carbs_100g, fat_100g, fiber_100g,
                                  default_unit, default_grams, serving_size, serving_unit,
                                  household_serving, verified)
       VALUES ($1,$2,'usda',$3,'global',$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,true)
       ON CONFLICT DO NOTHING
       RETURNING id`,
      [food.name, food.brand ?? null, food.source_ref, food.kcal_100g, food.protein_100g,
       food.carbs_100g, food.fat_100g, food.fiber_100g ?? null,
       food.serving_unit ?? "g", food.serving_size ?? 100,
       food.serving_size ?? null, food.serving_unit ?? null, food.household_serving ?? null]
    );

    return {
      food_id: cached?.id ?? null,
      fdc_id: Number(fdcId),
      name: food.name,
      brand: food.brand ?? null,
      per_100g: {
        calories: food.kcal_100g, protein_g: food.protein_100g,
        carbs_g: food.carbs_100g, fat_g: food.fat_100g,
        fiber_g: food.fiber_100g ?? null, sugar_g: food.sugar_100g ?? null,
        sodium_mg: food.sodium_100g ?? null,
      },
      serving: {
        size: food.serving_size ?? null,
        unit: food.serving_unit ?? null,
        household: food.household_serving ?? null,
      },
      portion: portion(food, g),
      source: "usda",
    };
  });

  app.get("/usage", { preHandler: requireAuth }, async (req) => {
    const e = await entitlementsFor(req.userId);
    const scan = e.features.food_scan;
    return { plan: e.plan, used: scan.used, limit: scan.limit,
             remaining: scan.remaining, resetsAt: e.periodEnd };
  });
}
