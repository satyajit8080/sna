import { cfg } from "../config.js";

export type BarcodeFood = {
  name: string;
  brand?: string;
  barcode: string;
  kcal_100g: number;
  protein_100g: number;
  carbs_100g: number;
  fat_100g: number;
  fiber_100g?: number;
  default_grams?: number;
  source: "openfoodfacts";
};

/**
 * Open Food Facts — best packaged-food coverage across UK/EU/AU/IN, free.
 * Packaged nutrition comes from here, never from the vision model.
 */
export async function lookupBarcode(barcode: string): Promise<BarcodeFood | null> {
  const clean = barcode.replace(/\D/g, "");
  if (clean.length < 8 || clean.length > 14) return null;

  const res = await fetch(
    `https://world.openfoodfacts.org/api/v2/product/${clean}?fields=product_name,brands,nutriments,serving_quantity`,
    { headers: { "user-agent": cfg.OPEN_FOOD_FACTS_UA }, signal: AbortSignal.timeout(6000) }
  );
  if (!res.ok) return null;

  const json: any = await res.json();
  if (json.status !== 1 || !json.product) return null;
  const n = json.product.nutriments ?? {};

  const kcal = Number(n["energy-kcal_100g"] ?? (n.energy_100g ? n.energy_100g / 4.184 : 0));
  if (!kcal) return null;

  return {
    name: String(json.product.product_name || "Packaged food").slice(0, 80),
    brand: json.product.brands?.split(",")[0]?.trim(),
    barcode: clean,
    kcal_100g: Math.round(kcal * 10) / 10,
    protein_100g: Number(n.proteins_100g ?? 0),
    carbs_100g: Number(n.carbohydrates_100g ?? 0),
    fat_100g: Number(n.fat_100g ?? 0),
    fiber_100g: n.fiber_100g != null ? Number(n.fiber_100g) : undefined,
    default_grams: Number(json.product.serving_quantity) || undefined,
    source: "openfoodfacts",
  };
}
