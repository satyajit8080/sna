import { q, one } from "../db.js";
import { localDate } from "../util/dates.js";
import type { CoachContext } from "./coachContext.js";

/**
 * Picks a concrete next meal that fits what's actually left today.
 *
 * Deliberately **not** an AI call. The coach already spent a request producing
 * its one-line answer; asking a model again just to name a food would double
 * the cost for something the nutrition database can answer exactly — and
 * exactly is better here, because these macros go straight into the diary
 * without a confirmation round-trip.
 */

export type MealSuggestion = {
  food_id: string;
  name: string;
  slot: "breakfast" | "lunch" | "dinner" | "snack";
  grams: number;
  quantity: number;
  unit: string;
  kcal_100g: number;
  protein_100g: number;
  carbs_100g: number;
  fat_100g: number;
  calories: number;
  protein_g: number;
  carbs_g: number;
  fat_g: number;
  /** Why this one — shown under the card. */
  reason: string;
};

function slotForNow(tz: string): MealSuggestion["slot"] {
  const hour = Number(
    new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", hour12: false })
      .format(new Date())
  );
  if (hour >= 4 && hour < 11) return "breakfast";
  if (hour >= 11 && hour < 16) return "lunch";
  if (hour >= 16 && hour < 22) return "dinner";
  return "snack";
}

/**
 * Scores candidates on how well one serving fits the remaining budget.
 *
 * Protein density is weighted because a deficit day usually fails on protein
 * before it fails on calories, and the coach's job is to steer that.
 */
function score(kcal: number, protein: number, remainingKcal: number, remainingProtein: number) {
  if (kcal > remainingKcal) return -Infinity;         // never suggest an overshoot
  const kcalFit = 1 - Math.abs(remainingKcal * 0.45 - kcal) / Math.max(remainingKcal, 1);
  const proteinFit = remainingProtein > 0
    ? Math.min(protein / Math.max(remainingProtein * 0.4, 1), 1.5)
    : 0.5;
  return kcalFit + proteinFit * 1.3;
}

export async function suggestNextMeal(
  userId: string,
  tz: string,
  context: CoachContext
): Promise<MealSuggestion | null> {
  const remainingKcal = context.remaining?.calories ?? 0;
  const remainingProtein = context.remaining?.protein_g ?? 0;

  // Nothing sensible to suggest once the budget is spent.
  if (remainingKcal < 120) return null;

  const prefs = context.preferences;
  const day = localDate(tz);

  /**
   * Cuisine bias.
   *
   * The database intentionally carries every cuisine, but a first-run user in
   * Toronto should not be told to eat dal tadka. Their country decides the
   * default; an explicit cuisine preference always overrides it.
   */
  const country = context.country ?? "US";
  const preferredCuisines = prefs?.cuisines?.length
    ? prefs.cuisines.map((c) => c.toLowerCase())
    : country === "IN" ? ["indian"]
    : country === "GB" ? ["british"]
    : country === "AU" ? ["american", "british"]
    : country === "CA" ? ["american", "canadian"]
    : ["american"];

  // Foods eaten today, plus anything suggested in the last three days.
  // Without the second list the same top-scoring food is proposed forever,
  // which is exactly how "grilled chicken breast" became a running joke.
  const [eaten, recent] = await Promise.all([
    q<{ name: string }>(
      `SELECT DISTINCT lower(i.name) AS name
         FROM meals m JOIN meal_items i ON i.meal_id = m.id
        WHERE m.user_id = $1 AND m.logged_on > $2::date - 2`,
      [userId, day]
    ),
    q<{ name: string }>(
      `SELECT DISTINCT lower(food_name) AS name
         FROM suggestion_log
        WHERE user_id = $1 AND created_at > now() - interval '3 days'`,
      [userId]
    ),
  ]);
  const eatenNames = new Set([...eaten, ...recent].map((r) => r.name));

  const banned = [...(prefs?.allergies ?? []), ...(prefs?.dislikes ?? [])]
    .map((s) => s.toLowerCase())
    .filter(Boolean);

  // Vegetarian and vegan are hard constraints, not preferences.
  const meatTerms = ["chicken", "beef", "steak", "pork", "bacon", "turkey", "fish",
                     "salmon", "tuna", "shrimp", "lamb", "ham", "sausage"];
  const animalTerms = [...meatTerms, "egg", "milk", "cheese", "yogurt", "butter", "curd"];
  const excluded =
    prefs?.diet === "vegan" ? animalTerms
    : prefs?.diet === "vegetarian" ? meatTerms
    : [];

  /**
   * Cuisine is a filter, not a tiebreaker.
   *
   * Scoring it as a bonus meant a high-protein off-cuisine dish still won, so
   * US users were offered biryani. Foods tagged `global` stay eligible because
   * eggs and chicken belong on every plate.
   */
  const allowed = [...new Set([...preferredCuisines, "global"])];

  let candidates = await q<any>(
    `SELECT id, name, cuisine, kcal_100g, protein_100g, carbs_100g, fat_100g,
            default_unit, default_grams, true AS on_cuisine
       FROM food_database
      WHERE kcal_100g > 0
        AND verified
        AND COALESCE(default_grams, 100) BETWEEN 30 AND 500
        AND (cuisine = ANY($1::text[]) OR cuisine IS NULL)
      ORDER BY (source = 'curated') DESC, id
      LIMIT 400`,
    [allowed]
  );

  // Only widen if the user's cuisines yield nothing usable — better an
  // off-cuisine suggestion than a blank card.
  if (candidates.length < 5) {
    candidates = await q<any>(
      `SELECT id, name, cuisine, kcal_100g, protein_100g, carbs_100g, fat_100g,
              default_unit, default_grams, false AS on_cuisine
         FROM food_database
        WHERE kcal_100g > 0 AND verified
          AND COALESCE(default_grams, 100) BETWEEN 30 AND 500
        ORDER BY (source = 'curated') DESC, id
        LIMIT 400`
    );
  }

  // Collect every viable option, then pick from the strongest few. Taking the
  // single best is deterministic and produces the same answer every time.
  const scored: Array<{ score: number; suggestion: MealSuggestion }> = [];

  for (const row of candidates) {
    const name = String(row.name).toLowerCase();

    if (eatenNames.has(name)) continue;
    if (banned.some((b) => name.includes(b))) continue;
    if (excluded.some((b) => name.includes(b))) continue;

    const grams = Number(row.default_grams) || 100;
    const kcal = Math.round((grams * Number(row.kcal_100g)) / 100);
    const protein = Math.round((grams * Number(row.protein_100g)) / 100);

    if (kcal < 80) continue;                          // not a meal

    // Off-cuisine foods are still eligible, just outranked by an equally good
    // on-cuisine option.
    const s = score(kcal, protein, remainingKcal, remainingProtein)
            + (row.on_cuisine ? 0.6 : 0);
    if (!Number.isFinite(s)) continue;

    scored.push({
      score: s,
      suggestion: {
        food_id: row.id,
        name: row.name,
        slot: slotForNow(tz),
        grams,
        quantity: 1,
        unit: row.default_unit ?? "serving",
        kcal_100g: Number(row.kcal_100g),
        protein_100g: Number(row.protein_100g),
        carbs_100g: Number(row.carbs_100g),
        fat_100g: Number(row.fat_100g),
        calories: kcal,
        protein_g: protein,
        carbs_g: Math.round((grams * Number(row.carbs_100g)) / 100),
        fat_g: Math.round((grams * Number(row.fat_100g)) / 100),
        reason: remainingProtein > 25
          ? `${protein}g protein, fits your ${remainingKcal} kcal left`
          : `${kcal} kcal — leaves room in your ${remainingKcal} remaining`,
      },
    });
  }

  if (!scored.length) return null;

  // Rotate through the top candidates rather than always returning the peak.
  // They are all good fits; picking one at random is what makes the coach feel
  // like it is thinking rather than reciting.
  scored.sort((a, b) => b.score - a.score);
  const pool = scored.slice(0, Math.min(8, scored.length));
  const picked = pool[Math.floor(Math.random() * pool.length)]!.suggestion;

  // Remember it so the next few days propose something else.
  await q(
    `INSERT INTO suggestion_log (user_id, food_id, food_name) VALUES ($1,$2,$3)`,
    [userId, picked.food_id, picked.name.toLowerCase()]
  ).catch(() => {});

  return picked;
}

/** Same shaping the app uses when saving, so the diary maths agrees exactly. */
export async function suggestionExists(foodId: string): Promise<boolean> {
  const row = await one(`SELECT id FROM food_database WHERE id = $1`, [foodId]);
  return !!row;
}
