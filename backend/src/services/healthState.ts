import { q, one } from "../db.js";

/**
 * The health state engine.
 *
 * Raw numbers do not mean anything on their own. "HRV = 42" is good for one
 * person and a warning for another; what matters is where it sits against
 * *this* person's baseline and which way it has been moving. Sending raw
 * values to a model and hoping it infers all that is how you get confident
 * nonsense.
 *
 * Everything here is arithmetic over stored observations — no model call, so
 * it costs nothing and cannot hallucinate.
 */

export type Trend = "rising" | "falling" | "stable" | "unknown";
export type Confidence = "high" | "medium" | "low" | "none";

export type MetricState = {
  metric: string;
  today: number | null;
  avg7: number | null;
  avg30: number | null;
  /** The person's own normal, from the longest window available. */
  baseline: number | null;
  trend: Trend;
  /** How far today sits from baseline, in percent. */
  deviationPct: number | null;
  confidence: Confidence;
  /** Days with data in the last 30 — the basis for `confidence`. */
  daysObserved: number;
};

/**
 * Normalises a date coming back from Postgres.
 *
 * `pg` returns DATE columns as JS `Date` objects, so `String(row.observed_on)`
 * yields "Sun Aug 16 2026 00:00:00 GMT..." rather than "2026-08-16". Keying a
 * map on that silently fails to match today's value, which showed up as a
 * metric with a correct baseline and trend but a null `today`.
 */
function isoDate(value: unknown): string {
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  return String(value).slice(0, 10);
}

/** Minimum days before a baseline means anything. */
const BASELINE_MIN_DAYS = 5;
/** Movement smaller than this is noise, not a trend. */
const TREND_THRESHOLD_PCT = 5;

function confidenceFor(days: number): Confidence {
  if (days === 0) return "none";
  if (days >= 21) return "high";
  if (days >= BASELINE_MIN_DAYS) return "medium";
  return "low";
}

function trendFor(recent: number | null, baseline: number | null): Trend {
  if (recent == null || baseline == null || baseline === 0) return "unknown";
  const change = ((recent - baseline) / baseline) * 100;
  if (Math.abs(change) < TREND_THRESHOLD_PCT) return "stable";
  return change > 0 ? "rising" : "falling";
}

/**
 * State for one metric.
 *
 * Deliberately returns nulls rather than zeros when data is missing: zero
 * steps and no step data are completely different situations, and conflating
 * them makes the coach tell someone off for a day it knows nothing about.
 */
export async function metricState(
  userId: string,
  metric: string,
  today: string
): Promise<MetricState> {
  const rows = await q<{ observed_on: string; value: string }>(
    `SELECT observed_on, value
       FROM health_observations
      WHERE user_id = $1 AND metric = $2
        AND observed_on > $3::date - 30
      ORDER BY observed_on DESC`,
    [userId, metric, today]
  );

  if (rows.length === 0) {
    return {
      metric, today: null, avg7: null, avg30: null, baseline: null,
      trend: "unknown", deviationPct: null, confidence: "none", daysObserved: 0,
    };
  }

  const byDate = new Map(rows.map((r) => [isoDate(r.observed_on), Number(r.value)]));
  const values = rows.map((r) => Number(r.value));

  const mean = (xs: number[]) =>
    xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;

  const daysAgo = (value: unknown) =>
    (new Date(`${today}T00:00:00Z`).getTime() - new Date(`${isoDate(value)}T00:00:00Z`).getTime())
      / 864e5;

  const last7 = rows.filter((r) => daysAgo(r.observed_on) < 7).map((r) => Number(r.value));

  const avg7 = mean(last7);
  const avg30 = mean(values);

  // Baseline excludes the last 7 days so a recent change registers as a
  // deviation rather than quietly moving the baseline with it.
  const older = rows.filter((r) => daysAgo(r.observed_on) >= 7).map((r) => Number(r.value));

  const baseline = older.length >= 3 ? mean(older) : avg30;
  const todayValue = byDate.get(today) ?? null;

  const deviationPct =
    todayValue != null && baseline != null && baseline !== 0
      ? Math.round(((todayValue - baseline) / baseline) * 100)
      : null;

  return {
    metric,
    today: todayValue,
    avg7: avg7 == null ? null : Math.round(avg7 * 10) / 10,
    avg30: avg30 == null ? null : Math.round(avg30 * 10) / 10,
    baseline: baseline == null ? null : Math.round(baseline * 10) / 10,
    trend: trendFor(avg7, baseline),
    deviationPct,
    confidence: confidenceFor(rows.length),
    daysObserved: rows.length,
  };
}

/**
 * Sleep regularity — the variability of bed and wake times.
 *
 * Chosen over duration deliberately: regularity predicts outcomes better than
 * hours slept, and unlike sleep *stages* it can be measured accurately from a
 * phone or watch. Reporting precise REM and deep minutes as fact would be
 * inventing precision the sensors do not have.
 */
export type SleepRegularity = {
  /** Standard deviation of sleep-start time, in minutes. Lower is better. */
  bedtimeVarianceMin: number | null;
  wakeVarianceMin: number | null;
  avgDurationMin: number | null;
  /** 0-100, derived from variance. Presented as a trend, never a diagnosis. */
  regularityScore: number | null;
  nightsObserved: number;
  confidence: Confidence;
};

export async function sleepRegularity(userId: string, today: string): Promise<SleepRegularity> {
  const rows = await q<{ metric: string; observed_on: string; value: string }>(
    `SELECT metric, observed_on, value
       FROM health_observations
      WHERE user_id = $1
        AND metric IN ('sleep_start_min', 'sleep_end_min', 'sleep_minutes')
        AND observed_on > $2::date - 21
      ORDER BY observed_on DESC`,
    [userId, today]
  );

  const pick = (m: string) => rows.filter((r) => r.metric === m).map((r) => Number(r.value));
  const starts = pick("sleep_start_min");
  const ends = pick("sleep_end_min");
  const durations = pick("sleep_minutes");

  const stdDev = (xs: number[]) => {
    if (xs.length < 3) return null;
    const m = xs.reduce((a, b) => a + b, 0) / xs.length;
    return Math.round(Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / xs.length));
  };

  const bedVar = stdDev(starts);
  const wakeVar = stdDev(ends);

  // Roughly: 30 minutes of variance is very regular, 2 hours is not.
  const score =
    bedVar == null && wakeVar == null
      ? null
      : Math.max(0, Math.min(100, Math.round(
          100 - (((bedVar ?? 0) + (wakeVar ?? 0)) / 2 - 20) * 0.8
        )));

  const nights = Math.max(starts.length, durations.length);

  return {
    bedtimeVarianceMin: bedVar,
    wakeVarianceMin: wakeVar,
    avgDurationMin: durations.length
      ? Math.round(durations.reduce((a, b) => a + b, 0) / durations.length)
      : null,
    regularityScore: score,
    nightsObserved: nights,
    confidence: confidenceFor(nights),
  };
}

/**
 * Coaching mode.
 *
 * An internal decision about how much to ask of someone today — not a score
 * to show them. Presenting it as a number invites the "my readiness is 43,
 * am I ill?" spiral, which is exactly the anxiety this is meant to avoid.
 */
export type CoachingMode = "recovery" | "maintenance" | "growth";

export type ReadinessAssessment = {
  mode: CoachingMode;
  /** Plain-language, for the coach prompt — never shown as a score. */
  rationale: string[];
  confidence: Confidence;
};

export async function assessReadiness(
  userId: string,
  today: string
): Promise<ReadinessAssessment> {
  const [sleep, hrv, rhr, regularity, training] = await Promise.all([
    metricState(userId, "sleep_minutes", today),
    metricState(userId, "hrv", today),
    metricState(userId, "resting_hr", today),
    sleepRegularity(userId, today),
    one<{ n: string }>(
      `SELECT COUNT(*) AS n FROM workouts
        WHERE user_id = $1 AND performed_on > $2::date - 4`,
      [userId, today]
    ),
  ]);

  const rationale: string[] = [];
  let recoveryPoints = 0;
  let growthPoints = 0;

  // Short sleep against their own normal, not a fixed 8-hour rule.
  if (sleep.today != null && sleep.baseline != null) {
    if (sleep.deviationPct != null && sleep.deviationPct <= -15) {
      recoveryPoints += 2;
      rationale.push(`slept ${Math.abs(sleep.deviationPct)}% below their usual`);
    } else if (sleep.deviationPct != null && sleep.deviationPct >= 5) {
      growthPoints += 1;
      rationale.push("slept well relative to their normal");
    }
  }

  // HRV falling and resting HR rising together is the classic under-recovery
  // signal. Either alone is too noisy to act on.
  if (hrv.trend === "falling" && hrv.confidence !== "none") {
    recoveryPoints += 1;
    rationale.push("HRV trending below baseline");
  }
  if (rhr.trend === "rising" && rhr.confidence !== "none") {
    recoveryPoints += 1;
    rationale.push("resting heart rate elevated");
  }
  if (hrv.trend === "rising" && rhr.trend !== "rising") {
    growthPoints += 1;
    rationale.push("HRV above baseline");
  }

  const consecutive = Number(training?.n ?? 0);
  if (consecutive >= 4) {
    recoveryPoints += 2;
    rationale.push(`${consecutive} sessions in the last 4 days`);
  } else if (consecutive === 0) {
    growthPoints += 1;
  }

  if (regularity.regularityScore != null && regularity.regularityScore >= 75) {
    growthPoints += 1;
    rationale.push("sleep schedule is consistent");
  }

  const anyData = [sleep, hrv, rhr].some((m) => m.confidence !== "none");
  const mode: CoachingMode =
    recoveryPoints >= 2 ? "recovery"
    : growthPoints >= 2 && recoveryPoints === 0 ? "growth"
    : "maintenance";

  return {
    mode,
    rationale,
    // Without data this is a default, and the coach should know that rather
    // than treating "maintenance" as an observation.
    confidence: anyData ? confidenceFor(Math.max(sleep.daysObserved, hrv.daysObserved)) : "none",
  };
}

/** Everything the coach needs about physical state, in one shaped object. */
export type HealthState = {
  date: string;
  mode: CoachingMode;
  modeRationale: string[];
  sleep: MetricState;
  sleepRegularity: SleepRegularity;
  hrv: MetricState;
  restingHr: MetricState;
  steps: MetricState;
  weight: MetricState;
  /** Metrics with no data — so the coach says "I don't know" not "it's zero". */
  missing: string[];
};

export async function buildHealthState(userId: string, today: string): Promise<HealthState> {
  const [readiness, sleep, regularity, hrv, rhr, steps, weight] = await Promise.all([
    assessReadiness(userId, today),
    metricState(userId, "sleep_minutes", today),
    sleepRegularity(userId, today),
    metricState(userId, "hrv", today),
    metricState(userId, "resting_hr", today),
    metricState(userId, "steps", today),
    metricState(userId, "weight_kg", today),
  ]);

  const missing = [
    ["sleep", sleep], ["hrv", hrv], ["resting heart rate", rhr],
    ["steps", steps], ["weight", weight],
  ]
    .filter(([, m]) => (m as MetricState).confidence === "none")
    .map(([name]) => name as string);

  return {
    date: today,
    mode: readiness.mode,
    modeRationale: readiness.rationale,
    sleep, sleepRegularity: regularity, hrv, restingHr: rhr, steps, weight,
    missing,
  };
}

/** Compact shape for the prompt — full objects would bloat every request. */
export function summariseForPrompt(state: HealthState) {
  const brief = (m: MetricState) =>
    m.confidence === "none"
      ? null
      : {
          today: m.today, baseline: m.baseline, trend: m.trend,
          vs_baseline_pct: m.deviationPct, confidence: m.confidence,
        };

  return {
    coaching_mode: state.mode,
    mode_because: state.modeRationale,
    sleep: brief(state.sleep),
    sleep_regularity: state.sleepRegularity.regularityScore == null ? null : {
      score: state.sleepRegularity.regularityScore,
      bedtime_variance_min: state.sleepRegularity.bedtimeVarianceMin,
      nights: state.sleepRegularity.nightsObserved,
    },
    hrv: brief(state.hrv),
    resting_hr: brief(state.restingHr),
    steps: brief(state.steps),
    weight: brief(state.weight),
    no_data_for: state.missing,
  };
}
