import type { FoodItem } from "./food.js";

/**
 * Barcode lookup via Open Food Facts.
 *
 * USDA FoodData Central only covers products sold in the United States, so a
 * barcode from anywhere else misses — which is exactly what a user scanning a
 * French or Indian packet sees. Open Food Facts is a global, community-run
 * database with no API key, which makes it the right fallback.
 *
 * Licence: Open Food Facts data is ODbL. Attribution is required wherever the
 * data is shown, which the client does on the result screen.
 */

const BASE = "https://world.openfoodfacts.org/api/v2/product";

/** Fields worth requesting. Asking for everything returns a large payload. */
const FIELDS = [
  "code",
  "product_name",
  "brands",
  "quantity",
  "serving_size",
  "nutriments",
].join(",");

interface OpenFoodFactsResponse {
  status?: number;
  product?: {
    code?: string;
    product_name?: string;
    brands?: string;
    quantity?: string;
    serving_size?: string;
    nutriments?: Record<string, number | string | undefined>;
  };
}

/**
 * Reads a nutriment, preferring the per-100g value.
 *
 * Open Food Facts stores several variants per nutrient and community entries
 * are inconsistent, so a missing key is normal rather than exceptional.
 */
function per100g(
  nutriments: Record<string, number | string | undefined> | undefined,
  key: string
): number | null {
  if (!nutriments) return null;
  for (const suffix of ["_100g", "_serving", ""]) {
    const value = nutriments[`${key}${suffix}`];
    const numeric = typeof value === "string" ? Number(value) : value;
    if (typeof numeric === "number" && Number.isFinite(numeric)) return numeric;
  }
  return null;
}

export async function lookupBarcode(
  barcode: string,
  fetchImpl: typeof fetch = fetch
): Promise<FoodItem | null> {
  // Barcodes are digits. Rejecting anything else keeps arbitrary strings out of
  // the upstream URL.
  if (!/^\d{6,14}$/.test(barcode)) return null;

  const response = await fetchImpl(
    `${BASE}/${barcode}.json?fields=${FIELDS}`,
    {
      headers: {
        // Open Food Facts asks callers to identify themselves.
        "User-Agent": "BPCoach/1.0 (https://bpcoach.app)",
      },
      signal: AbortSignal.timeout(8_000),
    }
  );

  if (!response.ok) return null;

  const data = (await response.json()) as OpenFoodFactsResponse;
  // status 0 means "product not found", which is not an error.
  if (data.status === 0 || !data.product) return null;

  const product = data.product;
  const nutriments = product.nutriments;

  // Sodium may be recorded as sodium (grams) or as salt (grams). Salt is
  // roughly 40% sodium by mass; deriving it is better than reporting nothing,
  // and the client labels the source.
  let sodiumMilligrams: number | null = null;
  const sodiumGrams = per100g(nutriments, "sodium");
  if (sodiumGrams !== null) {
    sodiumMilligrams = sodiumGrams * 1000;
  } else {
    const saltGrams = per100g(nutriments, "salt");
    if (saltGrams !== null) sodiumMilligrams = saltGrams * 400;
  }

  // A product with no sodium figure is useless to a blood pressure app.
  if (sodiumMilligrams === null) return null;

  const name = product.product_name?.trim();
  if (!name) return null;

  // Serving size is free text in Open Food Facts ("30 g", "1 biscuit"). Parse a
  // gram figure where one is present; leave it null rather than guessing.
  const servingText = product.serving_size ?? "";
  const servingMatch = servingText.match(/(\d+(?:[.,]\d+)?)\s*g/i);
  const servingGrams = servingMatch
    ? Number(servingMatch[1].replace(",", "."))
    : null;

  return {
    id: `off:${product.code ?? barcode}`,
    name: product.brands
      ? `${name} (${product.brands.split(",")[0]?.trim()})`
      : name,
    brand: product.brands?.split(",")[0]?.trim() ?? null,
    sodiumMilligramsPer100g: Math.round(sodiumMilligrams),
    energyKilocaloriesPer100g: per100g(nutriments, "energy-kcal"),
    defaultServingGrams:
      servingGrams !== null && Number.isFinite(servingGrams) ? servingGrams : null,
    source: "Open Food Facts (ODbL)",
  };
}
