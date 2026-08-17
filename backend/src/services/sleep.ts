import { q, one } from "../db.js";
import { localDate } from "../util/dates.js";

/**
 * Sleep coaching.
 *
 * Built on *timing*, not stages. A phone or watch can tell when someone fell
 * asleep and woke up to within a few minutes; it cannot reliably tell REM from
 * deep — consumer devices score barely better than chance on staging. Reporting
 * "you got 47 minutes of deep sleep" as fact is the pseudoscience this
 * deliberately avoids.
 *
 * What it does report is well supported: regularity of sleep and wake times
 * predicts outcomes at least as well as duration, and unlike duration it is
 * something a person can act on tonight.
 *
 * Everything here is arithmetic over stored observations. No model call.
 */

export type SleepInsight = {
  kind: string;
  /** One line, already phrased for the user. */
  finding: string;
  /** What to do about it. Null when the finding is just context. */
  action: string | null;
  /** How much this is worth saying, 0-100. */
  weight: number;
  confidence: "high" | "medium" | "low";
};

export type SleepSummary = {
  nights: number;
  avgDurationMin: number | null;
  /** Minutes past midnight; 1380 = 23:00. */
  avgBedtimeMin: number | null;
  avgWakeMin: number | null;
  bedtimeVarianceMin: number | null;
  wakeVarianceMin: number | null;
  /** 0-100 from timing variance. Never presented as a health score. */
  regularityScore: number | null;
  /**
   * Weekend bedtime shift, in minutes. Sometimes called social jetlag: going
   * to bed two hours later at weekends has an effect comparable to changing
   * timezone every week.
   */
  weekendShiftMin: number | null;
  /** Cumulative shortfall against their own typical night, last 7 days. */
  sleepDebtMin: number | null;
  insights: SleepInsight[];
};

/** Below this, variance is noise rather than a pattern. */
const MIN_NIGHTS = 5;
/** Duration below which the coach says something, relative to their own norm. */
const SHORT_NIGHT_PCT = 0.85;

function mean(xs: number[]): number | null {
  return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
}

function stdDev(xs: number[]): number | null {
  if (xs.length < 3) return null;
  const m = mean(xs)!;
  return Math.round(Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / xs.length));
}

/**
 * Bedtimes cross midnight, so a naive average of 23:40 and 00:20 gives midday.
 * Values after 18:00 are shifted below zero so the arithmetic works, then
 * wrapped back.
 */
function circularBedtime(values: number[]): number | null {
  if (!values.length) return null;
  const shifted = values.map((v) => (v >= 18 * 60 ? v - 24 * 60 : v));
  const avg = mean(shifted)!;
  return Math.round(avg < 0 ? avg + 24 * 60 : avg);
}

function circularVariance(values: number[]): number | null {
  if (values.length < 3) return null;
  return stdDev(values.map((v) => (v >= 18 * 60 ? v - 24 * 60 : v)));
}

/** "23:15" from minutes past midnight. */
export function clockLabel(minutes: number | null): string | null {
  if (minutes == null) return null;
  const wrapped = ((minutes % 1440) + 1440) % 1440;
  const h = Math.floor(wrapped / 60);
  const m = Math.round(wrapped % 60);
  return `${String(h).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}

export async function sleepSummary(userId: string, tz: string, days = 21): Promise<SleepSummary> {
  const today = localDate(tz);

  const rows = await q<{ metric: string; observed_on: unknown; value: string }>(
    `SELECT metric, observed_on, value
       FROM health_observations
      WHERE user_id = $1
        AND metric IN ('sleep_minutes', 'sleep_start_min', 'sleep_end_min')
        AND observed_on > $2::date - $3::int
      ORDER BY observed_on`,
    [userId, today, days]
  );

  const byDate = new Map<string, Record<string, number>>();
  for (const row of rows) {
    // pg returns DATE as a JS Date, so String() gives "Sun Aug 16 2026…" and
    // silently fails to match an ISO key.
    const date = row.observed_on instanceof Date
      ? row.observed_on.toISOString().slice(0, 10)
      : String(row.observed_on).slice(0, 10);
    const entry = byDate.get(date) ?? {};
    entry[row.metric] = Number(row.value);
    byDate.set(date, entry);
  }

  const durations: number[] = [];
  const bedtimes: number[] = [];
  const wakes: number[] = [];
  const weekdayBed: number[] = [];
  const weekendBed: number[] = [];

  for (const [date, entry] of byDate) {
    if (entry.sleep_minutes != null) durations.push(entry.sleep_minutes);
    if (entry.sleep_end_min != null) wakes.push(entry.sleep_end_min);

    if (entry.sleep_start_min != null) {
      bedtimes.push(entry.sleep_start_min);
      const day = new Date(`${date}T12:00:00Z`).getUTCDay();
      // Friday and Saturday nights are the "weekend" for bedtime purposes —
      // Sunday night belongs to the working week.
      (day === 5 || day === 6 ? weekendBed : weekdayBed).push(entry.sleep_start_min);
    }
  }

  const nights = Math.max(durations.length, bedtimes.length);
  const bedVariance = circularVariance(bedtimes);
  const wakeVariance = stdDev(wakes);

  /**
   * Calibrated against what actually counts as irregular.
   *
   * A standard deviation under about 20 minutes is a genuinely steady
   * schedule; 45 minutes means bedtime moves by an hour and a half across a
   * normal week, which is meaningfully irregular. The first version scored 49
   * minutes of scatter at 77/100 — comfortably "fine" — which would have told
   * people their sleep was steady when it plainly was not.
   */
  const combinedVariance =
    bedVariance == null && wakeVariance == null
      ? null
      : ((bedVariance ?? wakeVariance!) + (wakeVariance ?? bedVariance!)) / 2;

  const regularityScore =
    combinedVariance == null
      ? null
      : Math.max(0, Math.min(100, Math.round(100 - Math.max(0, combinedVariance - 15) * 1.6)));

  const weekdayAvg = circularBedtime(weekdayBed);
  const weekendAvg = circularBedtime(weekendBed);
  /**
   * The difference has to be wrapped too.
   *
   * `circularBedtime` returns a clock value, so a weekday average of 22:30 and
   * a weekend average of 00:30 subtract to −1320 rather than +120. Wrapping
   * into ±12h gives the real shift and its direction.
   */
  const weekendShift =
    weekdayAvg != null && weekendAvg != null && weekdayBed.length >= 3 && weekendBed.length >= 2
      ? (() => {
          let diff = weekendAvg - weekdayAvg;
          if (diff > 720) diff -= 1440;
          if (diff < -720) diff += 1440;
          return Math.round(diff);
        })()
      : null;

  const avgDuration = mean(durations);
  const recent = durations.slice(-7);
  const sleepDebt =
    avgDuration != null && recent.length >= 4
      ? Math.round(recent.reduce((total, night) => total + Math.max(0, avgDuration - night), 0))
      : null;

  const summary: SleepSummary = {
    nights,
    avgDurationMin: avgDuration == null ? null : Math.round(avgDuration),
    avgBedtimeMin: circularBedtime(bedtimes),
    avgWakeMin: wakes.length ? Math.round(mean(wakes)!) : null,
    bedtimeVarianceMin: bedVariance,
    wakeVarianceMin: wakeVariance,
    regularityScore,
    weekendShiftMin: weekendShift,
    sleepDebtMin: sleepDebt,
    insights: [],
  };

  summary.insights = await buildInsights(userId, tz, summary, byDate);
  return summary;
}

/**
 * Findings worth telling someone.
 *
 * Ordered by weight, and deliberately sparse: three observations about sleep
 * is a report, one is coaching.
 */
async function buildInsights(
  userId: string,
  tz: string,
  s: SleepSummary,
  byDate: Map<string, Record<string, number>>
): Promise<SleepInsight[]> {
  const out: SleepInsight[] = [];

  if (s.nights < MIN_NIGHTS) {
    return [{
      kind: "insufficient_data",
      finding: `${s.nights} night${s.nights === 1 ? "" : "s"} of sleep data so far.`,
      action: s.nights === 0
        ? "Connect Apple Health and I can start coaching your sleep timing."
        : "A week or so and I'll be able to see your pattern.",
      weight: 20,
      confidence: "low",
    }];
  }

  const confidence = s.nights >= 14 ? "high" as const
                   : s.nights >= 7 ? "medium" as const
                   : "low" as const;

  // ── regularity, the headline ────────────────────────────────────────────
  if (s.regularityScore != null && s.bedtimeVarianceMin != null) {
    if (s.regularityScore < 60) {
      out.push({
        kind: "irregular_bedtime",
        finding: `Your bedtime swings by about ${s.bedtimeVarianceMin} minutes night to night.`,
        // Consistency is more achievable than "sleep more", and the evidence
        // for it is at least as strong.
        action: `Aim for the same half-hour window — around ${clockLabel(s.avgBedtimeMin)} — even on the nights you don't feel tired.`,
        weight: 90,
        confidence,
      });
    } else if (s.regularityScore >= 80) {
      out.push({
        kind: "regular_bedtime",
        finding: `Your sleep schedule is steady — within about ${s.bedtimeVarianceMin} minutes most nights.`,
        action: null,
        weight: 30,
        confidence,
      });
    }
  }

  // ── social jetlag ───────────────────────────────────────────────────────
  if (s.weekendShiftMin != null && s.weekendShiftMin >= 60) {
    const hours = Math.round(s.weekendShiftMin / 60 * 10) / 10;
    out.push({
      kind: "weekend_shift",
      finding: `You go to bed about ${hours}h later at weekends.`,
      action: "Monday tends to be the cost of that. Pulling weekend nights back an hour usually helps more than a long lie-in.",
      weight: 70,
      confidence,
    });
  }

  // ── duration against their own norm, never a fixed 8 hours ──────────────
  if (s.avgDurationMin != null) {
    const recent = [...byDate.values()]
      .map((e) => e.sleep_minutes)
      .filter((v): v is number => v != null)
      .slice(-3);

    const shortNights = recent.filter((v) => v < s.avgDurationMin! * SHORT_NIGHT_PCT).length;

    if (shortNights >= 2) {
      out.push({
        kind: "short_nights",
        finding: `${shortNights} of your last 3 nights were well below your usual ${Math.round(s.avgDurationMin / 60 * 10) / 10}h.`,
        action: "Worth an early night before it starts showing up in how training feels.",
        weight: 80,
        confidence,
      });
    }
  }

  // ── timing relationships, only where there is enough data ───────────────
  const lateMeals = await lateEatingEffect(userId, tz, byDate);
  if (lateMeals) out.push(lateMeals);

  return out.sort((a, b) => b.weight - a.weight);
}

/**
 * Whether eating late tracks with shorter sleep *for this person*.
 *
 * Stated as an association, never a cause — with this much data that is all it
 * can honestly be, and overstating it is how apps end up asserting things that
 * are not true of the person reading them.
 */
async function lateEatingEffect(
  userId: string,
  tz: string,
  byDate: Map<string, Record<string, number>>
): Promise<SleepInsight | null> {
  const today = localDate(tz);

  const rows = await q<{ logged_on: string; last_meal_hour: string }>(
    `SELECT logged_on::text,
            MAX(EXTRACT(HOUR FROM logged_at))::text AS last_meal_hour
       FROM meals
      WHERE user_id = $1 AND logged_on > $2::date - 21
      GROUP BY logged_on`,
    [userId, today]
  );

  const late: number[] = [];
  const early: number[] = [];

  for (const row of rows) {
    const date = String(row.logged_on).slice(0, 10);
    const sleep = byDate.get(date)?.sleep_minutes;
    if (sleep == null) continue;

    (Number(row.last_meal_hour) >= 21 ? late : early).push(sleep);
  }

  // Four nights either side is the minimum for the comparison to mean anything.
  if (late.length < 4 || early.length < 4) return null;

  const lateAvg = mean(late)!;
  const earlyAvg = mean(early)!;
  const difference = earlyAvg - lateAvg;

  // Under 20 minutes is inside normal night-to-night noise.
  if (difference < 20) return null;

  return {
    kind: "late_eating",
    finding: `On nights you eat after 9pm you sleep about ${Math.round(difference)} minutes less.`,
    action: "Worth trying an earlier dinner for a week to see whether it holds.",
    weight: 65,
    // An association across a few weeks, not a proven cause — the wording and
    // the confidence both say so.
    confidence: "low",
  };
}

/** The one thing worth saying about sleep today, if anything. */
export async function topSleepInsight(userId: string, tz: string): Promise<SleepInsight | null> {
  const summary = await sleepSummary(userId, tz);
  const actionable = summary.insights.filter((i) => i.action != null && i.weight >= 60);
  return actionable[0] ?? null;
}
