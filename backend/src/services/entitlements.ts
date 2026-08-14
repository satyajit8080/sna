import { randomUUID } from "node:crypto";
import { q, one, tx } from "../db.js";
import type { Usage } from "../ai/types.js";

export type Plan = "free" | "pro";
export type Feature = "food_scan" | "coach" | "meal_plan";

export const FEATURES: Feature[] = ["food_scan", "coach", "meal_plan"];

/** Maps a raw AI request kind onto the entitlement it bills against. */
export function featureForKind(kind: string): Feature {
  if (kind === "coach") return "coach";
  if (kind === "meal_plan") return "meal_plan";
  return "food_scan";
}

export type Limits = { periodLimit: number | null; abuseLimit: number };

/**
 * Limits live in the database, not in code or the client, so they can be
 * retuned without shipping a build. Cached briefly because they are read on
 * every AI request but change roughly never.
 */
let cache: { at: number; rows: Map<string, Limits> } | null = null;
const CACHE_MS = 60_000;

export async function limitsFor(plan: Plan, feature: Feature): Promise<Limits> {
  if (!cache || Date.now() - cache.at > CACHE_MS) {
    const rows = await q<{ plan: string; feature: string; period_limit: number | null; abuse_limit: number }>(
      `SELECT plan, feature, period_limit, abuse_limit FROM entitlement_config`
    );
    cache = {
      at: Date.now(),
      rows: new Map(rows.map((r) => [`${r.plan}:${r.feature}`,
        { periodLimit: r.period_limit, abuseLimit: r.abuse_limit }])),
    };
  }
  return cache.rows.get(`${plan}:${feature}`) ?? { periodLimit: 0, abuseLimit: 0 };
}

export function invalidateLimitsCache() { cache = null; }

export type Subscription = {
  plan: Plan;
  periodStart: string;
  periodEnd: string;
  expiresAt: string | null;
  autoRenew: boolean;
  inTrial: boolean;
};

/**
 * The server decides entitlement. A client-sent `isPremium` is never consulted
 * anywhere in this codebase.
 */
export async function subscriptionFor(userId: string): Promise<Subscription> {
  const row = await one<any>(
    `SELECT plan, expires_at, auto_renew, in_trial, period_start, period_end
       FROM subscriptions WHERE user_id = $1`, [userId]
  );

  const expired = row?.expires_at ? new Date(row.expires_at) < new Date() : false;
  const plan: Plan = row?.plan === "pro" && !expired ? "pro" : "free";

  // A free user's period still needs to roll, or their 2 scans never come back.
  let periodStart = row?.period_start ?? new Date().toISOString();
  let periodEnd = row?.period_end ?? new Date(Date.now() + 30 * 864e5).toISOString();

  if (new Date(periodEnd) < new Date()) {
    const rolled = await one<any>(
      `UPDATE subscriptions
          SET period_start = now(), period_end = now() + interval '30 days', updated_at = now()
        WHERE user_id = $1 RETURNING period_start, period_end`, [userId]
    );
    if (rolled) { periodStart = rolled.period_start; periodEnd = rolled.period_end; }
  }

  return {
    plan,
    periodStart, periodEnd,
    expiresAt: row?.expires_at ?? null,
    autoRenew: row?.auto_renew ?? false,
    inTrial: row?.in_trial ?? false,
  };
}

export type FeatureUsage = {
  feature: Feature;
  used: number;
  limit: number | null;      // null = unlimited
  remaining: number | null;
  premiumOnly: boolean;
};

export type Entitlements = {
  plan: Plan;
  periodStart: string;
  periodEnd: string;
  features: Record<Feature, FeatureUsage>;
};

async function usedInPeriod(userId: string, feature: Feature, periodStart: string): Promise<number> {
  const row = await one<{ n: string }>(
    `SELECT COUNT(*) AS n FROM ai_usage
      WHERE user_id = $1 AND feature = $2
        AND counts_against_quota AND status <> 'failed' AND cache_hit = false
        AND created_at >= $3`,
    [userId, feature, periodStart]
  );
  return Number(row?.n ?? 0);
}

/** One call powers every usage badge in the app. */
export async function entitlementsFor(userId: string): Promise<Entitlements> {
  const sub = await subscriptionFor(userId);
  const features = {} as Record<Feature, FeatureUsage>;

  for (const feature of FEATURES) {
    const { periodLimit } = await limitsFor(sub.plan, feature);
    const used = await usedInPeriod(userId, feature, sub.periodStart);
    features[feature] = {
      feature,
      used,
      limit: periodLimit,
      remaining: periodLimit === null ? null : Math.max(0, periodLimit - used),
      premiumOnly: sub.plan === "free" && periodLimit === 0,
    };
  }

  return { plan: sub.plan, periodStart: sub.periodStart, periodEnd: sub.periodEnd, features };
}

/** 402 with everything iOS needs to open the right paywall. */
export class PremiumRequiredError extends Error {
  statusCode = 402;
  code = "PREMIUM_REQUIRED";
  constructor(public feature: Feature, public usage: FeatureUsage, public reason: "limit_reached" | "premium_only") {
    super("PREMIUM_REQUIRED");
  }
}

export class AbuseLimitError extends Error {
  statusCode = 429;
  code = "rate_limited";
  constructor(public feature: Feature) { super("rate_limited"); }
}

export type Reservation = { id: string; requestId: string; plan: Plan; feature: Feature };

/**
 * Atomically claims one unit of a feature.
 *
 * The count and the INSERT are one statement behind a row lock on the user, and
 * the row is written before the provider is called — so N concurrent requests
 * against 1 remaining unit produce exactly 1 success.
 */
export async function reserve(userId: string, kind: string): Promise<Reservation> {
  const feature = featureForKind(kind);
  const sub = await subscriptionFor(userId);
  const { periodLimit, abuseLimit } = await limitsFor(sub.plan, feature);

  if (periodLimit === 0) {
    throw new PremiumRequiredError(feature, {
      feature, used: 0, limit: 0, remaining: 0, premiumOnly: true,
    }, "premium_only");
  }

  const requestId = randomUUID();
  const counts = periodLimit !== null;

  return tx(async (c) => {
    await c.query(`SELECT id FROM users WHERE id = $1 FOR UPDATE`, [userId]);

    // "Unlimited" still has an abuse ceiling per period.
    const { rows: abuse } = await c.query<{ n: string }>(
      `SELECT COUNT(*) AS n FROM ai_usage
        WHERE user_id = $1 AND feature = $2 AND status <> 'failed' AND created_at >= $3`,
      [userId, feature, sub.periodStart]
    );
    if (Number(abuse[0]?.n ?? 0) >= abuseLimit) throw new AbuseLimitError(feature);

    const { rows } = await c.query<{ id: string }>(
      `INSERT INTO ai_usage
         (user_id, kind, feature, provider, model, status, reserved_at, request_id, counts_against_quota)
       SELECT $1, $2, $3, 'pending', 'pending', 'reserved', now(), $4, $5
        WHERE $5 = false
           OR (SELECT COUNT(*) FROM ai_usage
                WHERE user_id = $1 AND feature = $3
                  AND counts_against_quota AND status <> 'failed' AND cache_hit = false
                  AND created_at >= $6) < $7
       RETURNING id`,
      [userId, kind, feature, requestId, counts, sub.periodStart, periodLimit ?? 0]
    );

    if (!rows.length) {
      const used = await usedInPeriod(userId, feature, sub.periodStart);
      throw new PremiumRequiredError(feature, {
        feature, used, limit: periodLimit, remaining: 0, premiumOnly: false,
      }, "limit_reached");
    }

    return { id: rows[0]!.id, requestId, plan: sub.plan, feature };
  });
}

/**
 * Settles with the real provider usage. `usages` is a list because one logical
 * request can bill several provider calls (primary, then escalation); all are
 * recorded so cost reporting is not understated.
 */
export async function settle(
  reservation: Reservation, userId: string, kind: string, provider: string,
  usages: Usage[], opts: { cacheHit?: boolean } = {}
): Promise<void> {
  const [first, ...rest] = usages;

  if (!first) {
    await q(
      `UPDATE ai_usage SET status='complete', provider=$2, model='cache', cache_hit=$3, cost_usd=0
        WHERE id = $1`, [reservation.id, provider, opts.cacheHit ?? false]);
    return;
  }

  await tx(async (c) => {
    await c.query(
      `UPDATE ai_usage SET status='complete', provider=$2, model=$3, cache_hit=$4, escalated=$5,
              input_tokens=$6, cached_tokens=$7, output_tokens=$8, cost_usd=$9, latency_ms=$10
        WHERE id = $1`,
      [reservation.id, provider, first.model, opts.cacheHit ?? false, first.escalated,
       first.inputTokens, first.cachedTokens, first.outputTokens, first.costUsd, first.latencyMs]);

    for (const u of rest) {
      await c.query(
        `INSERT INTO ai_usage (user_id, kind, feature, provider, model, status, request_id,
                               counts_against_quota, escalated, input_tokens, cached_tokens,
                               output_tokens, cost_usd, latency_ms)
         VALUES ($1,$2,$3,$4,$5,'complete',$6,false,$7,$8,$9,$10,$11,$12)`,
        [userId, kind, reservation.feature, provider, u.model, reservation.requestId,
         u.escalated, u.inputTokens, u.cachedTokens, u.outputTokens, u.costUsd, u.latencyMs]);
    }
  });
}

/**
 * Marked failed rather than deleted: a provider outage must not silently eat
 * someone's free allowance, but we still keep the error rate and any spend.
 */
export async function release(reservation: Reservation, usages: Usage[] = []): Promise<void> {
  await q(
    `UPDATE ai_usage SET status='failed', cost_usd=$2, input_tokens=$3, output_tokens=$4
      WHERE id = $1`,
    [reservation.id,
     usages.reduce((a, u) => a + u.costUsd, 0),
     usages.reduce((a, u) => a + u.inputTokens, 0),
     usages.reduce((a, u) => a + u.outputTokens, 0)]);
}
