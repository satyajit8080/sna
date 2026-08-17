import { q, one } from "../db.js";
import { localDate } from "../util/dates.js";
import { metricState, type MetricState } from "./healthState.js";

/**
 * Cross-domain reasoning.
 *
 * Every pattern detector so far looks at one domain: protein is low, steps are
 * down, sleep is irregular. Each is true and none explains anything. The thing
 * people actually experience is a chain —
 *
 *   short sleep → low energy → training skipped → convenience food →
 *   frustration → later bedtime → short sleep
 *
 * — and the useful intervention is almost never at the point where it hurts.
 * Telling someone eating badly to eat better addresses the symptom; the sleep
 * is what moved first.
 *
 * This finds those chains and, crucially, names where to intervene.
 *
 * Also handles the case the spec is emphatic about: when the wearable says one
 * thing and the person says another, the person is right. A device can measure
 * time asleep; it cannot measure whether someone is exhausted.
 */

export type ChainLink = {
  domain: string;
  /** What the data shows for this link. */
  observation: string;
  /** Days ago it started moving — used to order the chain. */
  startedDaysAgo: number;
};

export type CausalChain = {
  id: string;
  /** Plain-language summary of the whole chain. */
  summary: string;
  links: ChainLink[];
  /** Where to act — usually the earliest link, not the loudest. */
  interveneAt: string;
  intervention: string;
  /** How confident we are the chain is real, not coincidence. */
  confidence: "high" | "medium" | "low";
  strength: number;
};

/** "a, b and c" — joining with " and " throughout reads as a stammer. */
function list(items: string[]): string {
  if (items.length <= 1) return items[0] ?? "";
  return `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`;
}

/** Nothing under this many days can show a sequence. */
const MIN_DAYS = 10;

/** A metric that moved, and roughly when it started. */
type Movement = {
  domain: string;
  direction: "up" | "down";
  magnitude: number;
  startedDaysAgo: number;
  observation: string;
};

/**
 * When a metric started deviating.
 *
 * Walks backwards from today to find the first day of a run that is still
 * going, which is what makes ordering the chain possible — a change that began
 * six days ago plausibly caused one that began two days ago, and not the
 * reverse.
 */
async function findMovement(
  userId: string, metric: string, today: string,
  opts: { label: string; domain: string; goodDirection: "up" | "down" }
): Promise<Movement | null> {
  const state = await metricState(userId, metric, today);
  if (state.confidence === "none" || state.baseline == null) return null;

  const rows = await q<{ observed_on: unknown; value: string }>(
    `SELECT observed_on, value FROM health_observations
      WHERE user_id = $1 AND metric = $2 AND observed_on > $3::date - 21
      ORDER BY observed_on DESC`,
    [userId, metric, today]
  );

  if (rows.length < 5) return null;

  const baseline = state.baseline;
  // 12% is comfortably outside normal day-to-day noise for these metrics.
  const threshold = baseline * 0.12;

  let run = 0;
  let total = 0;
  for (const row of rows) {
    const value = Number(row.value);
    const deviation = value - baseline;
    const isBad = opts.goodDirection === "up" ? deviation < -threshold : deviation > threshold;
    if (!isBad) break;
    run++;
    total += Math.abs(deviation);
  }

  // Two consecutive days is noise; three starts to mean something.
  if (run < 3) return null;

  const magnitude = Math.round((total / run / baseline) * 100);

  return {
    domain: opts.domain,
    direction: opts.goodDirection === "up" ? "down" : "up",
    magnitude,
    startedDaysAgo: run,
    observation: `${opts.label} ${opts.goodDirection === "up" ? "down" : "up"} ${magnitude}% for ${run} days`,
  };
}

/** Behavioural movements, which live in tables rather than observations. */
async function behaviouralMovements(userId: string, today: string): Promise<Movement[]> {
  const out: Movement[] = [];

  // Training that has stopped.
  const training = await one<{ recent: string; prior: string }>(
    `SELECT
       COUNT(*) FILTER (WHERE performed_on > $2::date - 7)::text  AS recent,
       COUNT(*) FILTER (WHERE performed_on BETWEEN $2::date - 21 AND $2::date - 8)::text AS prior
       FROM workouts WHERE user_id = $1 AND performed_on > $2::date - 21`,
    [userId, today]
  );

  const recentTraining = Number(training?.recent ?? 0);
  const priorWeekly = Number(training?.prior ?? 0) / 2;

  if (priorWeekly >= 2 && recentTraining < priorWeekly * 0.5) {
    out.push({
      domain: "training", direction: "down",
      magnitude: Math.round((1 - recentTraining / priorWeekly) * 100),
      startedDaysAgo: 7,
      observation: `training dropped from about ${Math.round(priorWeekly)} sessions a week to ${recentTraining}`,
    });
  }

  // Logging that has stopped — usually the first thing to go when life gets busy.
  const logging = await one<{ recent: string; prior: string }>(
    `SELECT
       COUNT(DISTINCT logged_on) FILTER (WHERE logged_on > $2::date - 7)::text AS recent,
       COUNT(DISTINCT logged_on) FILTER (WHERE logged_on BETWEEN $2::date - 21 AND $2::date - 8)::text AS prior
       FROM meals WHERE user_id = $1 AND logged_on > $2::date - 21`,
    [userId, today]
  );

  const recentDays = Number(logging?.recent ?? 0);
  const priorDays = Number(logging?.prior ?? 0) / 2;

  if (priorDays >= 4 && recentDays < priorDays * 0.6) {
    out.push({
      domain: "logging", direction: "down",
      magnitude: Math.round((1 - recentDays / priorDays) * 100),
      startedDaysAgo: 7,
      observation: `logging dropped from ${Math.round(priorDays)} days a week to ${recentDays}`,
    });
  }

  // Protein falling while calories hold — the signature of convenience eating.
  const nutrition = await q<{ logged_on: unknown; kcal: string; protein: string }>(
    `SELECT m.logged_on,
            SUM(i.grams * i.kcal_100g / 100)    AS kcal,
            SUM(i.grams * i.protein_100g / 100) AS protein
       FROM meals m JOIN meal_items i ON i.meal_id = m.id
      WHERE m.user_id = $1 AND m.logged_on > $2::date - 21
      GROUP BY m.logged_on ORDER BY m.logged_on DESC`,
    [userId, today]
  );

  if (nutrition.length >= 8) {
    const recent = nutrition.slice(0, 4);
    const prior = nutrition.slice(4);
    const mean = (rows: typeof nutrition, pick: (r: any) => number) =>
      rows.reduce((total, row) => total + pick(row), 0) / rows.length;

    const recentProtein = mean(recent, (r) => Number(r.protein));
    const priorProtein = mean(prior, (r) => Number(r.protein));

    if (priorProtein > 0 && recentProtein < priorProtein * 0.75) {
      out.push({
        domain: "nutrition", direction: "down",
        magnitude: Math.round((1 - recentProtein / priorProtein) * 100),
        startedDaysAgo: 4,
        observation: `protein down about ${Math.round((1 - recentProtein / priorProtein) * 100)}% over the last few days`,
      });
    }
  }

  return out;
}

/**
 * Known chains.
 *
 * Each is a sequence that shows up repeatedly in lifestyle research and in
 * ordinary experience. Requiring at least two links means a single bad metric
 * never gets narrated as a spiral — which would be exactly the health anxiety
 * this is meant to avoid.
 */
const CHAINS: Array<{
  id: string;
  sequence: string[];
  summary: (links: ChainLink[]) => string;
  interveneAt: string;
  intervention: string;
}> = [
  {
    id: "sleep_cascade",
    sequence: ["sleep", "activity", "training", "nutrition"],
    summary: (links) =>
      `Your sleep dropped first, and ${list(links.slice(1).map((l) => l.domain))} followed.`,
    interveneAt: "sleep",
    intervention:
      "The useful thing here is protecting sleep for a few nights, rather than trying to fix the food or the training directly — those tend to come back on their own once you're rested.",
  },
  {
    id: "recovery_spiral",
    sequence: ["recovery", "training", "activity"],
    summary: () =>
      "Your recovery signals dropped and training fell away after it.",
    interveneAt: "recovery",
    intervention:
      "A deliberate easy week usually resolves this faster than pushing through does.",
  },
  {
    id: "busy_collapse",
    sequence: ["logging", "nutrition", "training"],
    summary: () =>
      "Logging slipped first, then food and training — that pattern usually means the week got busy rather than anything about motivation.",
    interveneAt: "logging",
    intervention:
      "Rather than rebuilding everything, pick the one meal a day you can log reliably. The rest tends to follow.",
  },
  {
    id: "under_fuelled",
    sequence: ["nutrition", "activity", "sleep"],
    summary: () =>
      "Protein dropped, then activity, and sleep after that.",
    interveneAt: "nutrition",
    intervention:
      "Getting protein back up at one meal a day is usually enough to stop this one.",
  },
];

export async function detectChains(userId: string, tz: string): Promise<CausalChain[]> {
  const today = localDate(tz);

  const logged = await one<{ n: string }>(
    `SELECT COUNT(DISTINCT logged_on)::text AS n FROM meals
      WHERE user_id = $1 AND logged_on > $2::date - 21`,
    [userId, today]
  );

  // Below this there is no sequence to see, and inventing one would be worse
  // than saying nothing.
  if (Number(logged?.n ?? 0) < MIN_DAYS) return [];

  const movements = [
    ...(await Promise.all([
      findMovement(userId, "sleep_minutes", today,
                   { label: "sleep", domain: "sleep", goodDirection: "up" }),
      findMovement(userId, "steps", today,
                   { label: "steps", domain: "activity", goodDirection: "up" }),
      findMovement(userId, "hrv", today,
                   { label: "HRV", domain: "recovery", goodDirection: "up" }),
      findMovement(userId, "resting_hr", today,
                   { label: "resting heart rate", domain: "recovery", goodDirection: "down" }),
    ])).filter((m): m is Movement => m !== null),
    ...(await behaviouralMovements(userId, today)),
  ];

  const byDomain = new Map<string, Movement>();
  for (const movement of movements) {
    const existing = byDomain.get(movement.domain);
    // Keep the longest-running movement per domain — it is the one that
    // started the sequence.
    if (!existing || movement.startedDaysAgo > existing.startedDaysAgo) {
      byDomain.set(movement.domain, movement);
    }
  }

  const chains: CausalChain[] = [];

  for (const chain of CHAINS) {
    const present = chain.sequence
      .map((domain) => byDomain.get(domain))
      .filter((m): m is Movement => m !== undefined);

    // One moving metric is not a chain. Narrating it as one is how an app
    // manufactures anxiety.
    if (present.length < 2) continue;

    // The chain only holds if the earlier domains moved earlier.
    const ordered = [...present].sort((a, b) => b.startedDaysAgo - a.startedDaysAgo);
    const followsSequence = ordered[0]!.domain === chain.sequence[0];
    if (!followsSequence) continue;

    const links: ChainLink[] = ordered.map((m) => ({
      domain: m.domain,
      observation: m.observation,
      startedDaysAgo: m.startedDaysAgo,
    }));

    chains.push({
      id: chain.id,
      summary: chain.summary(links),
      links,
      interveneAt: chain.interveneAt,
      intervention: chain.intervention,
      confidence: present.length >= 3 ? "high" : "medium",
      strength: present.length * 30 + ordered[0]!.magnitude,
    });
  }

  return chains.sort((a, b) => b.strength - a.strength);
}

// ─── felt vs measured ───────────────────────────────────────────────────────

export type Reconciliation = {
  /** True when what they said conflicts with what the data shows. */
  conflict: boolean;
  /** For the prompt. Always resolves in the person's favour. */
  guidance: string;
  measured: string | null;
};

/**
 * Reconciles a stated feeling with the measurements.
 *
 * The rule is not negotiable: **the person is right**. A wearable can measure
 * time asleep; it cannot measure whether someone is exhausted. Telling
 * somebody their data says they slept well when they feel terrible is both
 * wrong and the fastest way to make them stop trusting the app — and it is a
 * failure mode every device-led product in this category has.
 *
 * What the data is good for is narrowing *why*. Good sleep plus exhaustion
 * points somewhere else: stress, illness, workload, under-eating.
 */
export async function reconcile(
  userId: string, tz: string, feeling: "tired" | "low" | "great" | null
): Promise<Reconciliation> {
  if (!feeling) return { conflict: false, guidance: "", measured: null };

  const today = localDate(tz);
  const [sleep, hrv, rhr] = await Promise.all([
    metricState(userId, "sleep_minutes", today),
    metricState(userId, "hrv", today),
    metricState(userId, "resting_hr", today),
  ]);

  /** "sleep at your usual" reads better than "above your usual by 0%". */
  const describe = (m: MetricState, name: string) => {
    if (m.confidence === "none" || m.deviationPct == null) return null;
    const delta = m.deviationPct;
    if (Math.abs(delta) < 5) return `${name} at your usual level`;
    return `${name} ${delta > 0 ? "above" : "below"} your usual by ${Math.abs(delta)}%`;
  };

  const measured = [describe(sleep, "sleep"), describe(hrv, "HRV")]
    .filter(Boolean).join(", ") || null;

  /**
   * Only a conflict when the data genuinely looks fine.
   *
   * If sleep is down 25% the numbers already explain the tiredness, and there
   * is nothing to reconcile — saying "your numbers look normal" there would be
   * plainly wrong. A missing reading is not evidence of fine either.
   */
  const sleepKnown = sleep.confidence !== "none" && sleep.deviationPct != null;
  const dataLooksFine =
    sleepKnown &&
    (sleep.deviationPct ?? 0) > -10 &&
    (hrv.deviationPct ?? 0) > -10;

  if ((feeling === "tired" || feeling === "low") && dataLooksFine && measured) {
    return {
      conflict: true,
      measured,
      guidance:
        `Their numbers look normal (${measured}) but they have told you they feel ` +
        `${feeling === "tired" ? "exhausted" : "low"}. Believe them. Do NOT say the data ` +
        `suggests they should feel fine — a device measures time asleep, not how someone ` +
        `feels. Say the numbers do not explain it, and look elsewhere: stress, workload, ` +
        `illness, under-eating, or something going on outside of training. Ask one question ` +
        `that might narrow it.`,
    };
  }

  if (feeling === "great" && (sleep.deviationPct ?? 0) < -15) {
    return {
      conflict: true,
      measured,
      guidance:
        `They feel good despite short sleep. Do not undercut that — take it at face ` +
        `value and note gently that sleep has been below their usual, without turning ` +
        `a good day into a warning.`,
    };
  }

  return { conflict: false, guidance: "", measured };
}

/** Words that report a felt state, for the reconciliation check. */
export function detectFeeling(message: string): "tired" | "low" | "great" | null {
  const text = message.toLowerCase();
  if (/\b(exhausted|shattered|knackered|drained|wiped|so tired|no energy)\b/.test(text)) return "tired";
  if (/\b(feel (low|down|rubbish|awful|terrible)|miserable|flat)\b/.test(text)) return "low";
  if (/\b(feel (great|good|amazing|strong)|full of energy)\b/.test(text)) return "great";
  return null;
}
