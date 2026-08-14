import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { cfg } from "../config.js";
import { q, one } from "../db.js";
import { requireAuth } from "../middleware/auth.js";
import { ai, ProviderError, type Usage } from "../ai/index.js";
import { normaliseImage, pHash } from "../util/image.js";
import { resolveFoods, searchFoods, type ResolvedItem } from "../nutrition/resolve.js";
import { lookupBarcode } from "../nutrition/openfoodfacts.js";
import {
  reserveScan, settleReservation, releaseReservation, scanQuota,
  type Reservation,
} from "../services/usage.js";

/** Every response carries `is_estimate` — never a medical-grade claim. */
function envelope(items: ResolvedItem[], assumptions: string[], confidence: number) {
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
  const reservation = await reserveScan(req.userId, kind);
  try {
    const { value, usages, cacheHit } = await work(reservation);
    await settleReservation(reservation, req.userId, kind, ai.primary().name, usages, { cacheHit });
    return value;
  } catch (e: any) {
    await releaseReservation(reservation, e instanceof ProviderError ? e.usages : []);
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
      const payload = envelope(items, result.assumptions, result.confidence);

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
      return { value: envelope(items, result.assumptions, result.confidence), usages };
    });
  });

  // ── POST /food/voice — transcript from on-device SFSpeechRecognizer ───────
  // Audio never leaves the phone; only the transcript reaches us.
  app.post("/food/voice", { preHandler: requireAuth }, async (req) => {
    const { transcript } = z.object({ transcript: z.string().min(2).max(400) }).parse(req.body);

    return withReservation(req, "voice", async () => {
      const { result, usages } = await ai.withFailover((p) => p.analyzeText(transcript));
      const items = await resolveFoods(result.foods);
      return { value: envelope(items, result.assumptions, result.confidence), usages };
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
      const value = envelope([{
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

  app.get("/usage", { preHandler: requireAuth }, async (req) => scanQuota(req.userId));
}
