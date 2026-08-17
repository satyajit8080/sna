import { q, one } from "../db.js";
import { localDate, localClock } from "../util/dates.js";
import { buildHealthState, type HealthState } from "./healthState.js";
import { detectPatterns } from "./patterns.js";
import { buildFollowUp } from "./followUp.js";
import { recall } from "./brain.js";

/**
 * The notification decision engine.
 *
 * A reminder app asks "is it 9am yet". This asks whether there is anything
 * worth saying, whether it has already been said, and whether this person
 * opens things like it. The default answer is no.
 *
 * Structure mirrors the coach: deterministic candidate generation over real
 * data, then scoring, then hard limits. No model call — a notification that
 * cost an AI request per user per hour would be both expensive and, worse,
 * capable of inventing a reason to interrupt someone.
 */

export type Priority = "critical" | "high" | "medium" | "low";

export type Category =
  | "morning" | "sleep" | "nutrition" | "hydration"
  | "activity" | "recovery" | "pattern" | "achievement" | "coach";

export type NotificationCandidate = {
  category: Category;
  priority: Priority;
  title: string;
  body: string;
  deeplink?: string;
  /** Local hour it should arrive. */
  hour: number;
  minute?: number;
  /** Why this is worth an interruption. Stored, and always answerable. */
  rationale: string;
  /** Collapses repeats — one per key per day. */
  dedupeKey: string;
  /** Impact before engagement and fatigue adjustments. */
  impact: number;
};

/** Priority weights. Critical is not merely "more important" — it bypasses limits. */
const PRIORITY_WEIGHT: Record<Priority, number> = {
  critical: 1000, high: 100, medium: 40, low: 15,
};

/** Below this, an interruption is not worth someone's attention. */
const SEND_FLOOR = 25;

/** A category sent this often with no opens is one this person doesn't want. */
const IGNORE_THRESHOLD = 5;

type Context = {
  userId: string;
  tz: string;
  today: string;
  hour: number;
  state: HealthState;
  prefs: any;
  profile: any;
  targets: any;
  consumed: { calories: number; protein_g: number; meals: number };
  waterMl: number;
  steps: number;
  streak: number;
  workoutsThisWeek: number;
  trainedToday: boolean;
  patterns: Array<{ kind: string; finding: string; weight: number }>;
  followUp: Awaited<ReturnType<typeof buildFollowUp>>;
  memories: Awaited<ReturnType<typeof recall>>;
};

async function gather(userId: string, tz: string): Promise<Context> {
  const today = localDate(tz);
  const clock = localClock(tz);

  const [state, prefs, profile, targets, consumed, water, activity, workouts,
         streak, patterns, followUp, memories] = await Promise.all([
    buildHealthState(userId, today),
    one<any>(`SELECT * FROM notification_prefs WHERE user_id = $1`, [userId]),
    one<any>(`SELECT name, goal FROM profiles WHERE user_id = $1`, [userId]),
    one<any>(`SELECT calories, protein_g, water_ml FROM nutrition_targets WHERE user_id = $1`, [userId]),
    one<any>(
      `SELECT COALESCE(ROUND(SUM(i.grams * i.kcal_100g / 100)),0)::int    AS calories,
              COALESCE(ROUND(SUM(i.grams * i.protein_100g / 100)),0)::int AS protein_g,
              COUNT(DISTINCT m.id)::int                                    AS meals
         FROM meals m JOIN meal_items i ON i.meal_id = m.id
        WHERE m.user_id = $1 AND m.logged_on = $2`, [userId, today]),
    one<any>(`SELECT COALESCE(SUM(ml),0)::int AS ml FROM water_logs
               WHERE user_id = $1 AND logged_on = $2`, [userId, today]),
    one<any>(`SELECT COALESCE(steps,0)::int AS steps FROM health_daily
               WHERE user_id = $1 AND logged_on = $2`, [userId, today]),
    one<any>(`SELECT COUNT(*)::int AS week,
                     COUNT(*) FILTER (WHERE performed_on = $2)::int AS today
                FROM workouts WHERE user_id = $1 AND performed_on > $2::date - 7`,
             [userId, today]),
    one<any>(`SELECT COUNT(DISTINCT logged_on)::int AS n FROM meals
               WHERE user_id = $1 AND logged_on > $2::date - 30`, [userId, today]),
    detectPatterns(userId),
    buildFollowUp(userId, tz),
    recall(userId, { limit: 8 }),
  ]);

  return {
    userId, tz, today, hour: clock.hour, state, prefs, profile, targets,
    consumed: consumed ?? { calories: 0, protein_g: 0, meals: 0 },
    waterMl: water?.ml ?? 0,
    steps: activity?.steps ?? 0,
    streak: streak?.n ?? 0,
    workoutsThisWeek: workouts?.week ?? 0,
    trainedToday: (workouts?.today ?? 0) > 0,
    patterns, followUp, memories,
  };
}

/**
 * Candidate generation.
 *
 * Every rule below fires only on real data. None invents a target, and none
 * fires without the metric it needs — a missing measurement produces silence,
 * not a guess.
 */
function generate(c: Context): NotificationCandidate[] {
  const out: NotificationCandidate[] = [];
  const firstName = c.profile?.name?.split(" ")[0];
  const greeting = firstName ? `Morning, ${firstName}` : "Morning";

  const wakeHour = c.prefs?.target_wake_time
    ? Number(String(c.prefs.target_wake_time).slice(0, 2))
    : (c.prefs?.morning_hour ?? 8);

  // ── morning check-in ────────────────────────────────────────────────────
  // One notification carrying the day's single most useful thing, rather than
  // a summary nobody reads.
  if (c.state.mode === "recovery") {
    out.push({
      category: "morning", priority: "high", hour: wakeHour,
      title: greeting,
      body: c.state.modeRationale.length
        ? `You ${c.state.modeRationale[0]}. Worth keeping today lighter than planned.`
        : "Your recovery signals are down. Worth keeping today lighter.",
      // Rationale is for us; body is for the user. Kept separate because the
      // same sentence cannot serve both.
      rationale: `recovery mode: ${c.state.modeRationale.join("; ")}`,
      dedupeKey: "morning", impact: 85, deeplink: "snapcal://home",
    });
  } else if (c.state.mode === "growth") {
    out.push({
      category: "morning", priority: "medium", hour: wakeHour,
      title: greeting,
      body: "Sleep and recovery are where they should be — a good day to push.",
      rationale: "growth mode with stable recovery",
      dedupeKey: "morning", impact: 45, deeplink: "snapcal://home",
    });
  }

  // ── sleep ───────────────────────────────────────────────────────────────
  const bedtime = c.prefs?.target_bedtime
    ? Number(String(c.prefs.target_bedtime).slice(0, 2))
    : null;

  if (bedtime != null) {
    const regularity = c.state.sleepRegularity;
    if (regularity.regularityScore != null && regularity.regularityScore < 60
        && regularity.nightsObserved >= 7) {
      out.push({
        category: "sleep", priority: "medium",
        // Half an hour before target: enough time to act on.
        hour: bedtime === 0 ? 23 : bedtime - 1, minute: 30,
        title: "Wind-down time",
        body: `Your bedtime has been moving by about ${regularity.bedtimeVarianceMin} minutes. Tonight's a good one to hold steady.`,
        rationale: `bedtime variance ${regularity.bedtimeVarianceMin}min over ${regularity.nightsObserved} nights`,
        dedupeKey: "bedtime", impact: 60, deeplink: "snapcal://coach",
      });
    }
  }

  // Several short nights is a pattern worth naming, not a single bad night.
  const shortSleep = c.patterns.find((p) => p.kind === "no_recovery");
  if (c.state.sleep.confidence !== "none"
      && c.state.sleep.trend === "falling"
      && c.state.sleep.daysObserved >= 7) {
    out.push({
      category: "pattern", priority: "high", hour: Math.max(wakeHour + 1, 9),
      title: "Your sleep is trending down",
      body: `You're averaging ${Math.round((c.state.sleep.avg7 ?? 0) / 60 * 10) / 10}h against a usual ${Math.round((c.state.sleep.baseline ?? 0) / 60 * 10) / 10}h. That shows up as energy and recovery before anything else — try moving bedtime 30 minutes earlier tonight.`,
      rationale: `sleep 7d avg ${c.state.sleep.avg7} vs baseline ${c.state.sleep.baseline}`,
      dedupeKey: "sleep_trend", impact: 90, deeplink: "snapcal://coach",
    });
  }

  // ── nutrition ───────────────────────────────────────────────────────────
  // Only when there is a real gap and time left to close it.
  if (c.targets?.protein_g && c.consumed.meals >= 2 && c.hour >= 16 && c.hour < 20) {
    const remaining = c.targets.protein_g - c.consumed.protein_g;
    if (remaining > c.targets.protein_g * 0.4) {
      out.push({
        category: "nutrition", priority: "medium", hour: 17,
        title: "Protein's behind today",
        body: `${Math.round(remaining)}g to go with one meal left. Making dinner protein-led covers most of it.`,
        rationale: `protein ${c.consumed.protein_g}/${c.targets.protein_g}g with ${c.consumed.meals} meals logged`,
        dedupeKey: "protein_gap", impact: 55, deeplink: "snapcal://scan",
      });
    }
  }

  // A missed logging day, but only for someone who normally logs — otherwise
  // it is nagging a person who has not formed the habit yet.
  if (c.consumed.meals === 0 && c.hour >= 14 && c.streak >= 10) {
    out.push({
      category: "nutrition", priority: "medium", hour: 14,
      title: "Nothing logged yet",
      body: "Unusual for you — a quick photo keeps today's picture accurate.",
      rationale: `no meals by ${c.hour}:00 despite ${c.streak} logged days in 30`,
      dedupeKey: "missed_logging", impact: 50, deeplink: "snapcal://scan",
    });
  }

  // ── hydration ───────────────────────────────────────────────────────────
  // Deliberately low priority and easily crowded out. Water reminders are the
  // classic example of a notification people mute the whole app over.
  if (c.targets?.water_ml && c.waterMl < c.targets.water_ml * 0.3
      && c.hour >= 15 && c.consumed.meals >= 2) {
    out.push({
      category: "hydration", priority: "low", hour: 15,
      title: "Water's low today",
      body: `${(c.waterMl / 1000).toFixed(1)}L so far against ${(c.targets.water_ml / 1000).toFixed(1)}L.`,
      rationale: `water ${c.waterMl}/${c.targets.water_ml}ml`,
      dedupeKey: "hydration", impact: 25, deeplink: "snapcal://home",
    });
  }

  // ── activity and training ───────────────────────────────────────────────
  const steps = c.state.steps;
  if (steps.confidence !== "none" && steps.baseline != null
      && c.steps > 0 && c.steps < steps.baseline * 0.4
      && c.hour >= 16 && c.hour < 20) {
    out.push({
      category: "activity", priority: "medium", hour: 17,
      title: "Quiet day so far",
      body: `${c.steps.toLocaleString()} steps against a usual ${Math.round(steps.baseline).toLocaleString()}. A 20-minute walk closes most of the gap.`,
      rationale: `steps ${c.steps} vs baseline ${steps.baseline}`,
      dedupeKey: "low_activity", impact: 50, deeplink: "snapcal://home",
    });
  }

  // Recovery warning outranks any training nudge.
  if (c.state.mode === "recovery" && !c.trainedToday) {
    out.push({
      category: "recovery", priority: "high", hour: Math.max(wakeHour + 2, 10),
      title: "Take it easier today",
      body: c.state.modeRationale.length
        ? `You ${c.state.modeRationale[0]} — a walk or some mobility will do more than a session today.`
        : "Your recovery signals are below baseline. A lighter day will do more.",
      rationale: `recovery mode: ${c.state.modeRationale.join("; ")}`,
      dedupeKey: "recovery", impact: 80, deeplink: "snapcal://coach",
    });
  }

  // ── achievements ────────────────────────────────────────────────────────
  // Real milestones only. Congratulating someone for existing is noise.
  if ([7, 14, 30, 60, 100].includes(c.streak)) {
    out.push({
      category: "achievement", priority: "low", hour: Math.max(wakeHour, 9),
      title: `${c.streak} days logged`,
      body: "That consistency is what makes everything else here work.",
      rationale: `streak milestone ${c.streak}`,
      dedupeKey: `streak_${c.streak}`, impact: 30, deeplink: "snapcal://progress",
    });
  }

  if (c.trainedToday) {
    out.push({
      category: "achievement", priority: "low", hour: Math.min(c.hour + 1, 21),
      title: "Session logged",
      body: `${c.workoutsThisWeek} this week. Next one adapts to what you just did.`,
      rationale: "workout completed today",
      dedupeKey: "workout_done", impact: 20, deeplink: "snapcal://progress",
    });
  }

  // ── patterns worth naming ───────────────────────────────────────────────
  // Format: what changed → why it matters → what to do.
  const weekendGap = c.patterns.find((p) => p.kind === "weekend_inactive");
  if (weekendGap) {
    out.push({
      category: "pattern", priority: "medium", hour: 10,
      title: "Weekends are your gap",
      body: `${weekendGap.finding} Weekday effort doesn't need to increase — a single weekend walk evens it out.`,
      rationale: weekendGap.finding,
      dedupeKey: "weekend_pattern", impact: 45, deeplink: "snapcal://coach",
    });
  }

  const proteinLow = c.patterns.find((p) => p.kind === "protein_low");
  // Guarded on the finding carrying a real number: a malformed pattern should
  // never become a notification.
  if (proteinLow && !/NaN|0 of 0/.test(proteinLow.finding)) {
    out.push({
      category: "pattern", priority: "medium", hour: 11,
      title: "Protein keeps falling short",
      body: `${proteinLow.finding} It's the single change most likely to move things for you.`,
      rationale: proteinLow.finding,
      dedupeKey: "protein_pattern", impact: 60, deeplink: "snapcal://coach",
    });
  }

  // ── follow-up ───────────────────────────────────────────────────────────
  const awaiting = c.followUp.awaitingAnswer;
  if (awaiting) {
    out.push({
      category: "coach", priority: "low", hour: Math.max(wakeHour + 1, 9),
      title: "Yesterday's plan",
      body: `You were going to ${awaiting.action.charAt(0).toLowerCase()}${awaiting.action.slice(1)}. Did it happen?`,
      rationale: `unanswered recommendation from ${awaiting.offeredOn}`,
      dedupeKey: "followup", impact: 35, deeplink: "snapcal://home",
    });
  }

  return out;
}

/**
 * Engagement multiplier from this person's actual behaviour.
 *
 * A category sent repeatedly and never opened is one they do not want.
 * Continuing to send it does not just waste the notification — it is how
 * people end up disabling notifications entirely, after which there is no
 * channel left at all.
 */
async function engagementFactor(userId: string, category: Category, hour: number): Promise<number> {
  const stats = await one<{ sent: string; opened: string; dismissed: string }>(
    `SELECT COALESCE(SUM(sent),0)::text AS sent,
            COALESCE(SUM(opened),0)::text AS opened,
            COALESCE(SUM(dismissed),0)::text AS dismissed
       FROM notification_engagement
      WHERE user_id = $1 AND category = $2`,
    [userId, category]
  );

  const sent = Number(stats?.sent ?? 0);
  if (sent < 3) return 1;                     // not enough to judge

  const openRate = Number(stats?.opened ?? 0) / sent;
  const dismissRate = Number(stats?.dismissed ?? 0) / sent;

  if (sent >= IGNORE_THRESHOLD && openRate < 0.15) return 0.2;
  if (dismissRate > 0.5) return 0.4;
  if (openRate > 0.6) return 1.3;
  return 1;
}

/** The hour this person actually opens this category, if there is a clear one. */
async function preferredHour(userId: string, category: Category, fallback: number): Promise<number> {
  const best = await one<{ hour: number; opened: string; sent: string }>(
    `SELECT hour, opened::text, sent::text
       FROM notification_engagement
      WHERE user_id = $1 AND category = $2 AND sent >= 3
      ORDER BY (opened::numeric / NULLIF(sent, 0)) DESC NULLS LAST
      LIMIT 1`,
    [userId, category]
  );

  if (!best || Number(best.sent) < 3) return fallback;
  const rate = Number(best.opened) / Number(best.sent);
  return rate >= 0.5 ? best.hour : fallback;
}

function inQuietHours(hour: number, prefs: any): boolean {
  const start = Number(String(prefs?.quiet_start ?? "22:00").slice(0, 2));
  const end = Number(String(prefs?.quiet_end ?? "07:00").slice(0, 2));

  // Quiet hours normally wrap midnight.
  return start > end ? hour >= start || hour < end : hour >= start && hour < end;
}

export type PlanResult = {
  planned: Array<NotificationCandidate & { id: string; deliverAt: string; score: number }>;
  suppressed: Array<{ category: string; reason: string }>;
};

/**
 * Decides today's notifications.
 *
 * Idempotent per day: re-running replaces nothing already sent, and the unique
 * constraint on (user, dedupe key, day) makes a duplicate impossible even
 * under a double call.
 */
export async function planNotifications(userId: string, tz: string): Promise<PlanResult> {
  const c = await gather(userId, tz);
  const suppressed: PlanResult["suppressed"] = [];

  // Permission and the master switch come first — everything else is moot.
  if (c.prefs?.permission === "denied" || c.prefs?.daily_coach === false) {
    return { planned: [], suppressed: [{ category: "all", reason: "notifications off" }] };
  }

  const muted: string[] = c.prefs?.muted_categories ?? [];
  const limit = c.prefs?.daily_limit ?? 3;

  const scored: Array<NotificationCandidate & { score: number; hour: number }> = [];

  for (const candidate of generate(c)) {
    if (muted.includes(candidate.category)) {
      suppressed.push({ category: candidate.category, reason: "muted by user" });
      continue;
    }

    const hour = await preferredHour(c.userId, candidate.category, candidate.hour);

    if (inQuietHours(hour, c.prefs) && candidate.priority !== "critical") {
      suppressed.push({ category: candidate.category, reason: "quiet hours" });
      continue;
    }

    const factor = await engagementFactor(c.userId, candidate.category, hour);
    const score = Math.round(
      (candidate.impact + PRIORITY_WEIGHT[candidate.priority] / 4) * factor
    );

    if (score < SEND_FLOOR) {
      suppressed.push({
        category: candidate.category,
        reason: factor < 1 ? "consistently ignored" : "not important enough",
      });
      continue;
    }

    scored.push({ ...candidate, hour, score });
  }

  // Highest value first, then the daily ceiling. Critical bypasses the cap —
  // a safety message is not something to hold back because the budget is
  // spent — but nothing here currently generates one.
  scored.sort((a, b) => b.score - a.score);

  const critical = scored.filter((s) => s.priority === "critical");
  const rest = scored.filter((s) => s.priority !== "critical").slice(0, Math.max(0, limit));

  for (const dropped of scored.filter((s) => !critical.includes(s) && !rest.includes(s))) {
    suppressed.push({ category: dropped.category, reason: "daily limit reached" });
  }

  const planned: PlanResult["planned"] = [];

  for (const item of [...critical, ...rest]) {
    const deliverAt = new Date(`${c.today}T${String(item.hour).padStart(2, "0")}:${String(item.minute ?? 0).padStart(2, "0")}:00`);

    const row = await one<{ id: string }>(
      `INSERT INTO notification_plan
         (user_id, category, priority, title, body, deeplink,
          deliver_at, planned_on, rationale, score, dedupe_key)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)
       ON CONFLICT (user_id, dedupe_key, planned_on) DO NOTHING
       RETURNING id`,
      [userId, item.category, item.priority, item.title, item.body,
       item.deeplink ?? null, deliverAt.toISOString(), c.today,
       item.rationale, item.score, item.dedupeKey]
    );

    if (row) {
      planned.push({ ...item, id: row.id, deliverAt: deliverAt.toISOString() });
    } else {
      suppressed.push({ category: item.category, reason: "already planned today" });
    }
  }

  return { planned, suppressed };
}

/** Records what happened, which is what makes the next decision better. */
export async function recordEngagement(
  userId: string,
  notificationId: string,
  event: "sent" | "opened" | "dismissed" | "acted"
) {
  const row = await one<{ category: string; deliver_at: string }>(
    `UPDATE notification_plan
        SET status = CASE
              WHEN $3 = 'opened'    THEN 'opened'
              WHEN $3 = 'dismissed' THEN 'dismissed'
              WHEN $3 = 'sent'      THEN 'sent'
              ELSE status END
      WHERE id = $2 AND user_id = $1
      RETURNING category, deliver_at`,
    [userId, notificationId, event]
  );

  if (!row) return null;

  const hour = new Date(row.deliver_at).getHours();
  const column = { sent: "sent", opened: "opened", dismissed: "dismissed", acted: "acted" }[event];

  await q(
    `INSERT INTO notification_engagement (user_id, category, hour, ${column})
     VALUES ($1,$2,$3,1)
     ON CONFLICT (user_id, category, hour)
     DO UPDATE SET ${column} = notification_engagement.${column} + 1,
                   updated_at = now()`,
    [userId, row.category, hour]
  );

  return { category: row.category, hour };
}
