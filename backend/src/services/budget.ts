import type { DailyActivity } from "./activity.js";

/**
 * The one place the daily calorie budget is computed.
 *
 * Dashboard, coach context and meal planner all call this. The formula lived
 * in two files before and drifted — the coach reported remaining against the
 * base target while the ring used the activity-adjusted budget, so a walk made
 * them disagree by the credited amount. Keeping it in one function means a
 * future change cannot reintroduce that.
 *
 *     remaining = base_target + credited_activity − consumed
 */

export type Macros = {
  calories: number;
  protein_g: number;
  carbs_g: number;
  fat_g: number;
};

export type Targets = Macros & { water_ml?: number };

export type Budget = {
  base_calories: number;
  activity_bonus: number;
  total_calories: number;
};

export type DailyBalance = {
  targets: Targets;
  consumed: Macros;
  budget: Budget;
  remaining: Macros;
};

const ZERO: Macros = { calories: 0, protein_g: 0, carbs_g: 0, fat_g: 0 };

function macros(input: Partial<Macros> | null | undefined): Macros {
  return {
    calories: Math.round(Number(input?.calories ?? 0)),
    protein_g: Math.round(Number(input?.protein_g ?? 0)),
    carbs_g: Math.round(Number(input?.carbs_g ?? 0)),
    fat_g: Math.round(Number(input?.fat_g ?? 0)),
  };
}

export const DEFAULT_TARGETS: Targets = {
  calories: 2000, protein_g: 120, carbs_g: 220, fat_g: 60, water_ml: 2500,
};

/**
 * Only calories get an activity bonus. Protein, carbs and fat targets are
 * composition goals, not an energy budget — walking further does not mean you
 * need more protein, so crediting activity against them would be wrong.
 */
export function dailyBalance(
  targets: Partial<Targets> | null | undefined,
  consumed: Partial<Macros> | null | undefined,
  activity: Pick<DailyActivity, "credited_kcal"> | null | undefined
): DailyBalance {
  const t: Targets = {
    calories: Math.round(Number(targets?.calories ?? DEFAULT_TARGETS.calories)),
    protein_g: Math.round(Number(targets?.protein_g ?? DEFAULT_TARGETS.protein_g)),
    carbs_g: Math.round(Number(targets?.carbs_g ?? DEFAULT_TARGETS.carbs_g)),
    fat_g: Math.round(Number(targets?.fat_g ?? DEFAULT_TARGETS.fat_g)),
    water_ml: Math.round(Number(targets?.water_ml ?? DEFAULT_TARGETS.water_ml)),
  };

  const eaten = consumed ? macros(consumed) : ZERO;
  const bonus = Math.max(0, Math.round(Number(activity?.credited_kcal ?? 0)));
  const total = t.calories + bonus;

  return {
    targets: t,
    consumed: eaten,
    budget: { base_calories: t.calories, activity_bonus: bonus, total_calories: total },
    remaining: {
      calories: total - eaten.calories,
      protein_g: t.protein_g - eaten.protein_g,
      carbs_g: t.carbs_g - eaten.carbs_g,
      fat_g: t.fat_g - eaten.fat_g,
    },
  };
}
