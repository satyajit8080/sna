import { usdaKey } from "../config.js";

const BASE = "https://api.nal.usda.gov/fdc/v1";

/** USDA nutrient numbers. Stable across datasets. */
const N = {
  kcal: 1008,
  protein: 1003,
  fat: 1004,
  carbs: 1005,
  fiber: 1079,
  sugar: 2000,
  sodium: 1093,
} as const;

export type Per100g = {
  name: string;
  brand?: string;
  kcal_100g: number;
  protein_100g: number;
  carbs_100g: number;
  fat_100g: number;
  fiber_100g?: number;
  sugar_100g?: number;
  sodium_100g?: number;
  serving_size?: number;
  serving_unit?: string;
  household_serving?: string;
  source: "usda";
  source_ref: string;
};

export type UsdaSearchHit = Per100g & {
  fdc_id: number;
  data_type: string;
  score: number;
};

function nutrient(food: any, id: number): number | undefined {
  const list = food.foodNutrients ?? [];
  const hit = list.find((n: any) => (n.nutrientId ?? n.nutrient?.id) === id);
  const value = hit?.value ?? hit?.amount;
  return value == null ? undefined : Number(value);
}

/**
 * USDA reports branded foods per 100g already, but `servingSize` is what the
 * label says — so a user can log "1 serving" instead of doing mental grams.
 */
function servingOf(food: any) {
  const size = Number(food.servingSize);
  return {
    serving_size: Number.isFinite(size) && size > 0 ? size : undefined,
    serving_unit: food.servingSizeUnit ?? undefined,
    household_serving: food.householdServingFullText ?? undefined,
  };
}

function toPer100g(food: any): Per100g | null {
  const kcal = nutrient(food, N.kcal);
  // Without energy there is nothing to track; skip rather than store a zero.
  if (!kcal) return null;

  return {
    name: String(food.description ?? "").toLowerCase().trim(),
    brand: food.brandOwner ?? food.brandName ?? undefined,
    kcal_100g: kcal,
    protein_100g: nutrient(food, N.protein) ?? 0,
    carbs_100g: nutrient(food, N.carbs) ?? 0,
    fat_100g: nutrient(food, N.fat) ?? 0,
    fiber_100g: nutrient(food, N.fiber),
    sugar_100g: nutrient(food, N.sugar),
    sodium_100g: nutrient(food, N.sodium),
    ...servingOf(food),
    source: "usda",
    source_ref: String(food.fdcId),
  };
}

async function get(path: string, params: Record<string, string>) {
  const url = new URL(`${BASE}${path}`);
  url.searchParams.set("api_key", usdaKey);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);

  const res = await fetch(url, { signal: AbortSignal.timeout(8000) });

  if (res.status === 429) {
    // DEMO_KEY allows ~30 requests/hour. A real Data.gov key is free and
    // allows 1000/hour, so this almost always means the key is missing.
    throw Object.assign(new Error("usda_rate_limited"), {
      statusCode: 429, code: "usda_rate_limited",
    });
  }
  if (!res.ok) return null;
  return res.json() as Promise<any>;
}

/**
 * Multi-result search for the food picker.
 *
 * Foundation and SR Legacy are whole foods with lab-measured nutrients;
 * Survey (FNDDS) covers prepared dishes; Branded is packaged products. Ordering
 * matters: for "chicken breast" a user wants the generic entry, not a
 * supermarket ready meal.
 */
export async function searchUsdaMany(
  query: string,
  opts: { limit?: number; branded?: boolean } = {}
): Promise<UsdaSearchHit[]> {
  const dataTypes = opts.branded
    ? "Foundation,SR Legacy,Survey (FNDDS),Branded"
    : "Foundation,SR Legacy,Survey (FNDDS)";

  const json = await get("/foods/search", {
    query,
    pageSize: String(Math.min(opts.limit ?? 10, 25)),
    dataType: dataTypes,
    sortBy: "dataType.keyword",
    sortOrder: "asc",
  });

  if (!json?.foods?.length) return [];

  return json.foods
    .map((food: any) => {
      const base = toPer100g(food);
      if (!base) return null;
      return {
        ...base,
        fdc_id: Number(food.fdcId),
        data_type: food.dataType ?? "unknown",
        score: Number(food.score ?? 0),
      } as UsdaSearchHit;
    })
    .filter(Boolean) as UsdaSearchHit[];
}

/** Single best match — used by the AI resolver, which wants one answer. */
export async function searchUsda(query: string): Promise<Per100g | null> {
  const hits = await searchUsdaMany(query, { limit: 3 });
  return hits[0] ?? null;
}

/** Full detail for one food, including serving size. */
export async function usdaDetail(fdcId: number | string): Promise<Per100g | null> {
  const json = await get(`/food/${fdcId}`, { format: "abridged" });
  if (!json) return null;
  return toPer100g(json);
}

/**
 * Scales a per-100g record to a portion. Pure arithmetic — the same maths the
 * client does when a quantity stepper changes, so the numbers always agree.
 */
export function portion(food: Per100g, grams: number) {
  const factor = grams / 100;
  return {
    grams: Math.round(grams),
    calories: Math.round(food.kcal_100g * factor),
    protein_g: Math.round(food.protein_100g * factor),
    carbs_g: Math.round(food.carbs_100g * factor),
    fat_g: Math.round(food.fat_100g * factor),
    fiber_g: food.fiber_100g == null ? undefined : Math.round(food.fiber_100g * factor),
  };
}
