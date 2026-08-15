import { q, one } from "../db.js";
import { searchUsda } from "./usda.js";
import type { DetectedFood } from "../ai/types.js";

export type ResolvedItem = {
  food_id: string | null;
  name: string;
  grams: number;
  quantity: number;
  unit: string;
  kcal_100g: number;
  protein_100g: number;
  carbs_100g: number;
  fat_100g: number;
  confidence: number;
  is_estimate: boolean;
  matched_source: string;
};

type Row = {
  id: string; name: string; kcal_100g: number; protein_100g: number;
  carbs_100g: number; fat_100g: number; default_unit: string | null;
  default_grams: number | null; source: string; sim: number;
};

const SIM_FLOOR = 0.34;

async function fromLocalDb(name: string): Promise<Row | null> {
  return one<Row>(
    `SELECT id, name, kcal_100g, protein_100g, carbs_100g, fat_100g,
            default_unit, default_grams, source,
            GREATEST(similarity(name, $1),
                     COALESCE((SELECT MAX(similarity(a, $1)) FROM unnest(aliases) a), 0)) AS sim
       FROM food_database
      WHERE name % $1 OR aliases && ARRAY[$1]::text[]
      ORDER BY sim DESC, verified DESC
      LIMIT 1`,
    [name.toLowerCase()]
  );
}

async function cacheUsda(name: string): Promise<Row | null> {
  const hit = await searchUsda(name);
  if (!hit) return null;
  return one<Row>(
    `INSERT INTO food_database (name, aliases, source, source_ref, kcal_100g, protein_100g, carbs_100g, fat_100g, fiber_100g)
     VALUES ($1, ARRAY[$2]::text[], 'usda', $3, $4, $5, $6, $7, $8)
     RETURNING id, name, kcal_100g, protein_100g, carbs_100g, fat_100g, default_unit, default_grams, source, 1.0 AS sim`,
    [hit.name, name.toLowerCase(), hit.source_ref, hit.kcal_100g, hit.protein_100g, hit.carbs_100g, hit.fat_100g, hit.fiber_100g ?? null]
  );
}

/**
 * Grounds model output in real nutrition data.
 * Order: curated/local DB (cached USDA lives here too) → USDA API → model fallback.
 */
export async function resolveFoods(foods: DetectedFood[]): Promise<ResolvedItem[]> {
  const out: ResolvedItem[] = [];

  for (const f of foods) {
    let row = await fromLocalDb(f.name);
    if (!row || row.sim < SIM_FLOOR) row = (await cacheUsda(f.name)) ?? row;

    const useDb = row != null && row.sim >= SIM_FLOOR;
    const unit = f.unit ?? row?.default_unit ?? "g";
    const quantity = f.quantity ?? (unit === "g" ? f.grams : 1);
    // Prefer the curated household weight over the model's guess for known units.
    const grams =
      f.quantity && row?.default_grams ? f.quantity * row.default_grams : f.grams;

    out.push({
      food_id: useDb ? row!.id : null,
      name: useDb ? row!.name : f.name,
      grams: Math.round(grams),
      quantity: Math.round(quantity * 100) / 100,
      unit,
      kcal_100g: useDb ? row!.kcal_100g : f.fallback?.kcal_100g ?? 150,
      protein_100g: useDb ? row!.protein_100g : f.fallback?.protein_100g ?? 6,
      carbs_100g: useDb ? row!.carbs_100g : f.fallback?.carbs_100g ?? 18,
      fat_100g: useDb ? row!.fat_100g : f.fallback?.fat_100g ?? 5,
      confidence: useDb ? f.confidence : Math.min(f.confidence, 0.5),
      is_estimate: true,
      matched_source: useDb ? row!.source : "ai",
    });
  }
  return out;
}

export async function searchFoods(term: string, limit = 20) {
  return q(
    `SELECT id, name, brand, kcal_100g, protein_100g, carbs_100g, fat_100g, default_unit, default_grams
       FROM food_database
      WHERE name % $1 OR name ILIKE $2
      ORDER BY similarity(name, $1) DESC, verified DESC
      LIMIT $3`,
    [term.toLowerCase(), `%${term}%`, limit]
  );
}
