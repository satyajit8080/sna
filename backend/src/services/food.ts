import type { Config } from "../config.js";
import { UpstreamError } from "./errors.js";

/**
 * USDA FoodData Central. Public-domain data, which matters: Open Food Facts is
 * ODbL and would impose share-alike obligations on anything derived from it.
 */
const SEARCH_ENDPOINT = "https://api.nal.usda.gov/fdc/v1/foods/search";
const DETAIL_ENDPOINT = "https://api.nal.usda.gov/fdc/v1/food";
const TIMEOUT_MS = 12_000;

/** FDC nutrient numbers. Sodium is 307; energy in kcal is 208. */
const NUTRIENT_SODIUM_MG = "307";
const NUTRIENT_ENERGY_KCAL = "208";

export interface FoodItem {
  id: string;
  name: string;
  brand: string | null;
  sodiumMilligramsPer100g: number;
  energyKilocaloriesPer100g: number | null;
  defaultServingGrams: number | null;
  source: string;
}

interface FdcNutrient {
  nutrientNumber?: string;
  number?: string;
  value?: number;
  amount?: number;
}

interface FdcFood {
  fdcId: number;
  description: string;
  brandOwner?: string;
  brandName?: string;
  servingSize?: number;
  servingSizeUnit?: string;
  foodNutrients?: FdcNutrient[];
}

function nutrientValue(food: FdcFood, number: string): number | null {
  for (const nutrient of food.foodNutrients ?? []) {
    const id = nutrient.nutrientNumber ?? nutrient.number;
    if (id === number) {
      const value = nutrient.value ?? nutrient.amount;
      if (typeof value === "number" && Number.isFinite(value)) return value;
    }
  }
  return null;
}

/**
 * Maps an FDC record, or returns null when sodium is absent.
 *
 * A food entry with no sodium figure is useless in a blood pressure app, and
 * substituting zero would be worse than useless — it would read as "this food
 * has no sodium", which is a claim the data does not make.
 */
function mapFood(food: FdcFood): FoodItem | null {
  const sodium = nutrientValue(food, NUTRIENT_SODIUM_MG);
  if (sodium === null) return null;

  return {
    id: String(food.fdcId),
    name: food.description,
    brand: food.brandName ?? food.brandOwner ?? null,
    sodiumMilligramsPer100g: sodium,
    energyKilocaloriesPer100g: nutrientValue(food, NUTRIENT_ENERGY_KCAL),
    defaultServingGrams:
      food.servingSize && food.servingSizeUnit?.toLowerCase() === "g"
        ? food.servingSize
        : null,
    source: "USDA FoodData Central",
  };
}

async function callFdc(
  url: string,
  fetchImpl: typeof fetch
): Promise<unknown> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);

  let response: Response;
  try {
    response = await fetchImpl(url, { signal: controller.signal });
  } catch (error) {
    const aborted = error instanceof Error && error.name === "AbortError";
    throw new UpstreamError(
      aborted ? "The food database timed out" : "Could not reach the food database",
      504,
      true
    );
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) {
    const retryable = response.status === 429 || response.status >= 500;
    throw new UpstreamError(
      retryable
        ? "The food database is busy. Try again shortly."
        : "The food search was rejected.",
      retryable ? 503 : 502,
      retryable
    );
  }
  return response.json();
}

export async function searchFoods(
  query: string,
  limit: number,
  config: Config,
  fetchImpl: typeof fetch = fetch
): Promise<FoodItem[]> {
  if (!config.usdaApiKey) {
    throw new UpstreamError("Food database is not configured", 503, false);
  }

  const params = new URLSearchParams({
    api_key: config.usdaApiKey,
    query,
    pageSize: String(Math.min(limit * 2, 50)),
    dataType: "Foundation,SR Legacy,Branded",
  });

  const payload = (await callFdc(`${SEARCH_ENDPOINT}?${params}`, fetchImpl)) as {
    foods?: FdcFood[];
  };

  // Results without sodium are dropped, not padded — so an empty array here
  // honestly means "nothing usable found", never "found nothing so here's zero".
  return (payload.foods ?? [])
    .map(mapFood)
    .filter((item): item is FoodItem => item !== null)
    .slice(0, limit);
}

export async function foodByID(
  id: string,
  config: Config,
  fetchImpl: typeof fetch = fetch
): Promise<FoodItem | null> {
  if (!config.usdaApiKey) {
    throw new UpstreamError("Food database is not configured", 503, false);
  }
  if (!/^\d+$/.test(id)) return null;

  const params = new URLSearchParams({ api_key: config.usdaApiKey });
  const payload = (await callFdc(
    `${DETAIL_ENDPOINT}/${id}?${params}`,
    fetchImpl
  )) as FdcFood;

  return payload?.fdcId ? mapFood(payload) : null;
}
