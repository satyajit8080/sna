import { cfg } from "../config.js";

export type Per100g = {
  name: string;
  kcal_100g: number;
  protein_100g: number;
  carbs_100g: number;
  fat_100g: number;
  fiber_100g?: number;
  source: "usda";
  source_ref: string;
};

const N = { kcal: 1008, protein: 1003, fat: 1004, carbs: 1005, fiber: 1079 };

/** USDA FoodData Central — free, authoritative, generic + branded foods. */
export async function searchUsda(query: string): Promise<Per100g | null> {
  if (!cfg.USDA_FDC_API_KEY) return null;
  const url = new URL("https://api.nal.usda.gov/fdc/v1/foods/search");
  url.searchParams.set("api_key", cfg.USDA_FDC_API_KEY);
  url.searchParams.set("query", query);
  url.searchParams.set("pageSize", "3");
  url.searchParams.set("dataType", "Foundation,SR Legacy,Survey (FNDDS)");

  const res = await fetch(url, { signal: AbortSignal.timeout(6000) });
  if (!res.ok) return null;
  const json: any = await res.json();
  const food = json.foods?.[0];
  if (!food) return null;

  const pick = (id: number) =>
    Number(food.foodNutrients?.find((n: any) => n.nutrientId === id)?.value ?? 0);

  const kcal = pick(N.kcal);
  if (!kcal) return null;

  return {
    name: String(food.description ?? query).toLowerCase(),
    kcal_100g: kcal,
    protein_100g: pick(N.protein),
    carbs_100g: pick(N.carbs),
    fat_100g: pick(N.fat),
    fiber_100g: pick(N.fiber) || undefined,
    source: "usda",
    source_ref: String(food.fdcId),
  };
}
