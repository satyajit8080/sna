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

/**
 * USDA descriptions are database records, not dish names: "Onions, red, raw",
 * "Fish, salmon, atlantic, farmed, cooked, dry heat". Showing those verbatim
 * turned one scanned plate into "Fish Curry, Onions, Red, Raw, Tomato".
 *
 * The model already produced a human name for what it saw; USDA supplies the
 * numbers. Keep the model's name and only borrow the macros.
 */
export function looksLikeDatabaseRecord(name: string): boolean {
  // Two or more comma-separated fragments, or a trailing preparation clause.
  const commas = (name.match(/,/g) ?? []).length;
  if (commas >= 2) return true;
  if (commas === 1 && /\b(raw|cooked|boiled|canned|frozen|dried|unprepared|dry heat|with salt|without salt)\b/i.test(name)) {
    return true;
  }
  return false;
}

/**
 * Turns a USDA record name into something readable.
 *
 * "Onions, red, raw" → "Red Onion". "Fish, salmon, atlantic, farmed, cooked,
 * dry heat" → "Salmon". USDA orders fragments most-general-first and appends
 * preparation, so reversing the first two fragments and dropping preparation
 * words recovers a usable name.
 */
export function humaniseRecordName(raw: string): string {
  // Preparation and sourcing clauses carry no meaning on a diary row.
  const PREP = new Set([
    "raw", "cooked", "boiled", "canned", "frozen", "dried", "unprepared",
    "dry heat", "moist heat", "with salt", "without salt", "drained",
    "solids", "all commercial varieties", "commercial", "prepared",
    "commercially prepared", "not further specified", "nfs", "commodity",
    "unenriched", "enriched", "meat only", "meat and skin", "flesh only",
    "all classes", "composite of cuts", "trimmed to 0\" fat",
  ]);

  // USDA's internal groupings, never useful to a reader.
  const NOISE = /(broilers|fryers|\bor\b|includes foods|usda distribution|variet)/i;

  /** Broad categories that a species or cut already implies. */
  const GENERIC = new Set([
    "fish", "chicken", "beef", "pork", "lamb", "turkey", "veal", "game meat",
    "bread", "cheese", "milk", "oil", "nuts", "cereals", "soup", "snacks",
    "sausages and luncheon meats", "fast foods", "beverages", "candies",
  ]);

  /** Cuts and parts, which read wrong alone: "Breast" needs "Chicken". */
  const CUT = new Set([
    "breast", "thigh", "wing", "drumstick", "leg", "loin", "fillet", "filet",
    "mince", "steak", "chop", "rib", "shoulder", "belly", "shank", "tenderloin",
    "liver", "roast",
  ]);

  /** Words that qualify a category rather than replace it. */
  const ADJECTIVE = new Set([
    "red", "white", "green", "yellow", "brown", "black", "ground", "whole",
    "skim", "low fat", "nonfat", "sweet", "baby", "wild", "fresh", "lean",
  ]);

  const parts = raw.split(",")
    .map((p) => p.trim().toLowerCase())
    .filter((p) => p.length > 0 && !PREP.has(p) && !NOISE.test(p));

  if (parts.length === 0) return titleCase(raw.split(",")[0]!.trim());
  if (parts.length === 1) return titleCase(parts[0]!);

  const [category, second] = parts as [string, string];

  // "onions, red" → "Red Onions": the qualifier belongs in front.
  if (ADJECTIVE.has(second)) return titleCase(`${second} ${category}`);

  // "chicken, breast" → "Chicken Breast": a cut needs its animal.
  if (CUT.has(second)) return titleCase(`${category} ${second}`);

  // "fish, salmon" → "Salmon": the species already says it is a fish.
  if (GENERIC.has(category)) return titleCase(second);

  return titleCase(`${second} ${category}`);
}

function titleCase(s: string): string {
  return s.split(" ")
    .map((w) => (w.length ? w[0]!.toUpperCase() + w.slice(1) : w))
    .join(" ");
}

/** Title-cased, comma-free display name derived from the model's label. */
export function displayName(modelName: string, dbName: string | undefined): string {
  if (!dbName) return modelName;
  return looksLikeDatabaseRecord(dbName) ? modelName : dbName;
}

async function cacheUsda(name: string): Promise<Row | null> {
  const hit = await searchUsda(name);
  if (!hit) return null;

  // Store a readable name, not the USDA identifier. These rows are later
  // searched and suggested by name, so caching "Onions, red, raw" means it
  // eventually surfaces to a user verbatim.
  const stored = looksLikeDatabaseRecord(hit.name) ? humaniseRecordName(hit.name) : hit.name;

  return one<Row>(
    `INSERT INTO food_database (name, aliases, source, source_ref, kcal_100g, protein_100g, carbs_100g, fat_100g, fiber_100g)
     VALUES ($1, ARRAY[$2, $3]::text[], 'usda', $4, $5, $6, $7, $8, $9)
     RETURNING id, name, kcal_100g, protein_100g, carbs_100g, fat_100g, default_unit, default_grams, source, 1.0 AS sim`,
    [stored, name.toLowerCase(), hit.name.toLowerCase(), hit.source_ref,
     hit.kcal_100g, hit.protein_100g, hit.carbs_100g, hit.fat_100g, hit.fiber_100g ?? null]
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
      // Macros from the database, name from the model. A USDA record name is
      // an identifier, not something to show a user mid-meal.
      name: useDb ? displayName(f.name, row!.name) : f.name,
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
