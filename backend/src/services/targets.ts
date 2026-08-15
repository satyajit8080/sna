export type Profile = {
  birth_year: number;
  sex: "male" | "female" | "other";
  height_cm: number;
  start_weight_kg: number;
  goal_weight_kg: number;
  goal: "lose" | "maintain" | "gain";
  activity_level: keyof typeof ACTIVITY;
};

const ACTIVITY = {
  sedentary: 1.2,
  light: 1.375,
  moderate: 1.55,
  active: 1.725,
  very_active: 1.9,
} as const;

/** Mifflin-St Jeor — the standard for non-athlete populations. */
export function computeTargets(p: Profile, currentWeightKg?: number) {
  const weight = currentWeightKg ?? p.start_weight_kg;
  const age = new Date().getFullYear() - p.birth_year;
  const sexOffset = p.sex === "male" ? 5 : p.sex === "female" ? -161 : -78;

  const bmr = Math.round(10 * weight + 6.25 * p.height_cm - 5 * age + sexOffset);
  const tdee = Math.round(bmr * ACTIVITY[p.activity_level]);

  // 20% deficit / 12% surplus, floored at BMR so we never prescribe a crash diet.
  let calories =
    p.goal === "lose" ? Math.round(tdee * 0.8) :
    p.goal === "gain" ? Math.round(tdee * 1.12) : tdee;

  const floor = Math.max(bmr, p.sex === "male" ? 1500 : 1200);
  calories = Math.max(calories, floor);

  // Protein anchored to bodyweight (preserves lean mass in a deficit), fat 25-30%,
  // carbs fill the remainder.
  const proteinPerKg = p.goal === "lose" ? 1.8 : 1.6;
  const protein_g = Math.round(Math.min(weight, 120) * proteinPerKg);
  const fat_g = Math.round((calories * 0.27) / 9);
  const carbs_g = Math.max(50, Math.round((calories - protein_g * 4 - fat_g * 9) / 4));

  return {
    bmr,
    tdee,
    calories,
    protein_g,
    carbs_g,
    fat_g,
    water_ml: Math.round(Math.min(4000, weight * 33) / 100) * 100,
  };
}

export function projectedWeeks(p: Profile, calories: number, tdee: number): number | null {
  const deltaKg = p.goal_weight_kg - p.start_weight_kg;
  if (p.goal === "maintain" || Math.abs(deltaKg) < 0.5) return null;
  const dailyDeficit = tdee - calories;
  if (dailyDeficit === 0) return null;
  const kcalPerKg = 7700;
  const weeks = Math.abs((deltaKg * kcalPerKg) / (dailyDeficit * 7));
  return Math.max(1, Math.round(weeks));
}
