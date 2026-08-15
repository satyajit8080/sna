import { one, q } from "../db.js";
import { localDate } from "../util/dates.js";

export type ActivityCredit = "off" | "partial" | "full";

/**
 * Share of measured active calories that feeds back into the calorie budget.
 *
 * `partial` is the default and it is the important decision here. The user's
 * daily target came from Mifflin-St Jeor multiplied by a declared activity
 * level, so their allowance *already assumes* a typical day of movement.
 * Crediting 100% of measured activity on top of that double-counts it and
 * quietly erodes the deficit — the classic reason people "eat back" their
 * exercise and stop losing weight.
 */
const CREDIT_FACTOR: Record<ActivityCredit, number> = {
  off: 0,
  partial: 0.5,
  full: 1,
};

/**
 * Estimated calories burned walking, when HealthKit's own activeEnergyBurned
 * is unavailable (permission granted for steps only, or an older device).
 *
 * ~0.0005 kcal per step per kg of bodyweight: a 70 kg person burns roughly
 * 35 kcal per 1,000 steps, which matches published walking MET values closely
 * enough for a budget that is itself an estimate.
 */
export function kcalFromSteps(steps: number, weightKg: number): number {
  if (steps <= 0) return 0;
  const weight = weightKg > 0 ? weightKg : 70;
  return Math.round(steps * weight * 0.0005);
}

export type DailyActivity = {
  date: string;
  steps: number;
  distance_m: number | null;
  flights_climbed: number | null;
  exercise_min: number | null;
  /** What HealthKit measured, or our estimate if it reported nothing. */
  active_kcal: number;
  kcal_source: "healthkit" | "estimated";
  /** How much of active_kcal is actually added to the budget. */
  credited_kcal: number;
  credit_mode: ActivityCredit;
};

export async function activityFor(
  userId: string,
  tz: string,
  day?: string
): Promise<DailyActivity> {
  const date = day ?? localDate(tz);

  const [row, weightRow, targets] = await Promise.all([
    one<any>(
      `SELECT steps, distance_m, flights_climbed, exercise_min, active_kcal, kcal_source
         FROM health_daily WHERE user_id = $1 AND logged_on = $2`,
      [userId, date]
    ),
    one<{ weight_kg: number }>(
      `SELECT weight_kg FROM weight_logs WHERE user_id = $1 ORDER BY logged_on DESC LIMIT 1`,
      [userId]
    ),
    one<{ activity_credit: ActivityCredit }>(
      `SELECT activity_credit FROM nutrition_targets WHERE user_id = $1`,
      [userId]
    ),
  ]);

  const mode: ActivityCredit = targets?.activity_credit ?? "partial";
  const steps = row?.steps ?? 0;
  const weight = weightRow?.weight_kg ?? 70;

  // Trust HealthKit's own figure when we have it; fall back to steps.
  const measured = Number(row?.active_kcal ?? 0);
  const active = measured > 0 ? measured : kcalFromSteps(steps, weight);
  const source: "healthkit" | "estimated" = measured > 0 ? "healthkit" : "estimated";

  return {
    date,
    steps,
    distance_m: row?.distance_m ?? null,
    flights_climbed: row?.flights_climbed ?? null,
    exercise_min: row?.exercise_min ?? null,
    active_kcal: active,
    kcal_source: source,
    credited_kcal: Math.round(active * CREDIT_FACTOR[mode]),
    credit_mode: mode,
  };
}

/** Upsert from the app's HealthKit sync. Idempotent; safe to call often. */
export async function recordActivity(
  userId: string,
  date: string,
  input: {
    steps?: number;
    active_kcal?: number;
    resting_kcal?: number;
    exercise_min?: number;
    distance_m?: number;
    flights_climbed?: number;
  }
) {
  const source = input.active_kcal != null && input.active_kcal > 0 ? "healthkit" : "estimated";

  return one<any>(
    `INSERT INTO health_daily
       (user_id, logged_on, steps, active_kcal, resting_kcal, exercise_min,
        distance_m, flights_climbed, kcal_source)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
     ON CONFLICT (user_id, logged_on) DO UPDATE SET
       steps           = COALESCE(EXCLUDED.steps,           health_daily.steps),
       active_kcal     = COALESCE(EXCLUDED.active_kcal,     health_daily.active_kcal),
       resting_kcal    = COALESCE(EXCLUDED.resting_kcal,    health_daily.resting_kcal),
       exercise_min    = COALESCE(EXCLUDED.exercise_min,    health_daily.exercise_min),
       distance_m      = COALESCE(EXCLUDED.distance_m,      health_daily.distance_m),
       flights_climbed = COALESCE(EXCLUDED.flights_climbed, health_daily.flights_climbed),
       kcal_source     = EXCLUDED.kcal_source,
       updated_at      = now()
     RETURNING logged_on, steps, active_kcal, exercise_min, distance_m, flights_climbed, kcal_source`,
    [userId, date, input.steps ?? null, input.active_kcal ?? null, input.resting_kcal ?? null,
     input.exercise_min ?? null, input.distance_m ?? null, input.flights_climbed ?? null, source]
  );
}

/** Trailing activity, for the coach and the weekly report. */
export async function activityHistory(userId: string, days = 7) {
  return q<any>(
    `SELECT logged_on AS date, steps, active_kcal, exercise_min, distance_m
       FROM health_daily
      WHERE user_id = $1 AND logged_on > CURRENT_DATE - $2::int
      ORDER BY logged_on`,
    [userId, days]
  );
}
