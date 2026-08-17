import { q, one } from "../db.js";

/**
 * Patterns across recent history, computed from logged data only.
 *
 * A coach that only reacts to today is a calculator. Noticing that activity
 * collapses at weekends, or that protein has missed target six days running,
 * is the difference between answering questions and actually coaching.
 *
 * Every pattern here is derived arithmetic — no model call — so it costs
 * nothing and cannot hallucinate. The model is given the findings, not the
 * raw history, which also keeps the prompt small.
 */

export type Pattern = {
  kind: string;
  /** One line, already phrased for the user. */
  finding: string;
  /** Rough ranking so the coach can lead with what matters most. */
  weight: number;
};

const MIN_DAYS = 4;   // below this, "patterns" are noise

export async function detectPatterns(userId: string, days = 14): Promise<Pattern[]> {
  const patterns: Pattern[] = [];

  const [nutrition, targets, activity, workouts, weights, logging] = await Promise.all([
    q<any>(
      `SELECT m.logged_on,
              SUM(i.grams * i.kcal_100g / 100)    AS kcal,
              SUM(i.grams * i.protein_100g / 100) AS protein
         FROM meals m JOIN meal_items i ON i.meal_id = m.id
        WHERE m.user_id = $1 AND m.logged_on > CURRENT_DATE - $2::int
        GROUP BY m.logged_on ORDER BY m.logged_on`,
      [userId, days]
    ),
    one<any>(`SELECT calories, protein_g, water_ml FROM nutrition_targets WHERE user_id = $1`, [userId]),
    q<any>(
      `SELECT logged_on, steps, active_kcal
         FROM health_daily
        WHERE user_id = $1 AND logged_on > CURRENT_DATE - $2::int
        ORDER BY logged_on`,
      [userId, days]
    ),
    q<any>(
      `SELECT performed_on, focus, perceived_effort
         FROM workouts
        WHERE user_id = $1 AND performed_on > CURRENT_DATE - $2::int
        ORDER BY performed_on`,
      [userId, days]
    ),
    q<any>(
      `SELECT logged_on, weight_kg FROM weight_logs
        WHERE user_id = $1 AND logged_on > CURRENT_DATE - $2::int
        ORDER BY logged_on`,
      [userId, days]
    ),
    one<any>(
      `SELECT COUNT(DISTINCT logged_on)::int AS n FROM meals
        WHERE user_id = $1 AND logged_on > CURRENT_DATE - $2::int`,
      [userId, days]
    ),
  ]);

  const loggedDays = Number(logging?.n ?? 0);

  // ── logging consistency ───────────────────────────────────────────────────
  // Stated first because every other pattern is unreliable without it.
  if (loggedDays > 0 && loggedDays < days * 0.5) {
    patterns.push({
      kind: "logging_gaps",
      finding: `Food logged on ${loggedDays} of the last ${days} days, so calorie figures are probably an undercount.`,
      weight: 90,
    });
  }

  if (loggedDays < MIN_DAYS) {
    return patterns;   // not enough to say anything else honestly
  }

  // ── protein ───────────────────────────────────────────────────────────────
  // `nutrition` only has rows for days with meal *items*. A day logged with no
  // items produced an empty set, an average of NaN, and a finding that read
  // "averaged NaNg against 148g — short on 0 of 0 days".
  if (targets?.protein_g && nutrition.length >= MIN_DAYS) {
    const missed = nutrition.filter((d: any) => Number(d.protein) < targets.protein_g * 0.85).length;
    if (missed >= Math.ceil(nutrition.length * 0.6)) {
      const avg = Math.round(
        nutrition.reduce((a: number, d: any) => a + Number(d.protein), 0) / nutrition.length);
      patterns.push({
        kind: "protein_low",
        finding: `Protein has averaged ${avg}g against a ${targets.protein_g}g target — short on ${missed} of ${nutrition.length} logged days.`,
        weight: 80,
      });
    }
  }

  // ── weekday vs weekend ────────────────────────────────────────────────────
  if (activity.length >= 7) {
    const weekend = activity.filter((d: any) => [0, 6].includes(new Date(d.logged_on).getDay()));
    const weekday = activity.filter((d: any) => ![0, 6].includes(new Date(d.logged_on).getDay()));

    if (weekend.length >= 2 && weekday.length >= 3) {
      const avg = (rows: any[]) =>
        rows.reduce((a, d) => a + Number(d.steps ?? 0), 0) / rows.length;
      const weekendAvg = avg(weekend);
      const weekdayAvg = avg(weekday);

      if (weekdayAvg > 0 && weekendAvg < weekdayAvg * 0.6) {
        patterns.push({
          kind: "weekend_inactive",
          finding: `Steps drop to about ${Math.round(weekendAvg).toLocaleString()} at weekends versus ${Math.round(weekdayAvg).toLocaleString()} on weekdays.`,
          weight: 60,
        });
      }
    }
  }

  // ── training frequency and recovery ───────────────────────────────────────
  if (workouts.length > 0) {
    const dates = workouts.map((w: any) => String(w.performed_on).slice(0, 10)).sort();

    let run = 1, longestRun = 1;
    for (let i = 1; i < dates.length; i++) {
      const gap = (new Date(dates[i]!).getTime() - new Date(dates[i - 1]!).getTime()) / 864e5;
      run = gap === 1 ? run + 1 : 1;
      longestRun = Math.max(longestRun, run);
    }

    if (longestRun >= 5) {
      patterns.push({
        kind: "no_recovery",
        finding: `Trained ${longestRun} days in a row recently — a lighter day would likely help more than another session.`,
        weight: 85,
      });
    }

    const hard = workouts.filter((w: any) => Number(w.perceived_effort ?? 0) >= 8).length;
    if (hard >= 4) {
      patterns.push({
        kind: "high_effort_load",
        finding: `${hard} sessions at effort 8+ in ${days} days. Sustainable progress usually needs some easier work in between.`,
        weight: 70,
      });
    }
  } else if (loggedDays >= MIN_DAYS) {
    patterns.push({
      kind: "no_training_logged",
      finding: `No workouts logged in ${days} days.`,
      weight: 50,
    });
  }

  // ── weight trend ──────────────────────────────────────────────────────────
  if (weights.length >= 4) {
    const first = Number(weights[0].weight_kg);
    const last = Number(weights.at(-1)!.weight_kg);
    const change = Math.round((last - first) * 10) / 10;

    if (Math.abs(change) < 0.3) {
      patterns.push({
        kind: "plateau",
        finding: `Weight has moved ${Math.abs(change)}kg over ${days} days — essentially flat.`,
        weight: 75,
      });
    } else {
      patterns.push({
        kind: "weight_trend",
        finding: `Weight is ${change < 0 ? "down" : "up"} ${Math.abs(change)}kg over ${days} days.`,
        weight: 40,
      });
    }
  }

  // ── things going well, which matter too ───────────────────────────────────
  if (loggedDays >= days * 0.8) {
    patterns.push({
      kind: "consistent_logging",
      finding: `Logged ${loggedDays} of ${days} days — that consistency is what makes the rest of this work.`,
      weight: 30,
    });
  }

  return patterns.sort((a, b) => b.weight - a.weight);
}

/** The few findings worth putting in a prompt. */
export async function topPatterns(userId: string, limit = 3): Promise<string[]> {
  return (await detectPatterns(userId)).slice(0, limit).map((p) => p.finding);
}
