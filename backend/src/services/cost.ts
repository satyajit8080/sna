import { q } from "../db.js";
import { PRICING } from "../ai/pricing.js";

/**
 * Internal cost calculator. Two modes:
 *  - actual():   what we really spent, from ai_usage
 *  - project():  what a given scan volume would cost on any model
 */
export async function actual(days = 30) {
  const [row] = await q<any>(
    `SELECT COUNT(*)::int                                          AS scans,
            COUNT(*) FILTER (WHERE cache_hit)::int                 AS cache_hits,
            COUNT(*) FILTER (WHERE escalated)::int                 AS escalations,
            COALESCE(SUM(cost_usd), 0)::float                      AS total_usd,
            COALESCE(AVG(cost_usd), 0)::float                      AS cost_per_scan,
            COALESCE(AVG(latency_ms), 0)::float                    AS avg_latency_ms,
            COUNT(DISTINCT user_id)::int                           AS active_users
       FROM ai_usage WHERE created_at > now() - ($1 || ' days')::interval`,
    [String(days)]
  );

  const [payers] = await q<{ n: number }>(
    `SELECT COUNT(*)::int AS n FROM subscriptions
      WHERE plan = 'pro' AND (expires_at IS NULL OR expires_at > now())`
  );

  const payingUsers = payers?.n ?? 0;
  const monthly = (row.total_usd / days) * 30;

  return {
    window_days: days,
    scans: row.scans,
    cache_hit_rate: row.scans ? row.cache_hits / row.scans : 0,
    escalation_rate: row.scans ? row.escalations / row.scans : 0,
    cost_per_scan_usd: round6(row.cost_per_scan),
    daily_scans: Math.round(row.scans / days),
    monthly_scans: Math.round((row.scans / days) * 30),
    monthly_ai_cost_usd: round2(monthly),
    active_users: row.active_users,
    paying_users: payingUsers,
    cost_per_paying_user_usd: payingUsers ? round4(monthly / payingUsers) : null,
    avg_latency_ms: Math.round(row.avg_latency_ms),
  };
}

/** Forward-looking: cost of N scans on a given model at our measured token shape. */
export function project(scans: number, model: string, opts?: { inTokens?: number; cachedShare?: number; outTokens?: number }) {
  const p = PRICING[model];
  if (!p) throw new Error(`unknown model ${model}`);
  const inTok = opts?.inTokens ?? 480;
  const outTok = opts?.outTokens ?? 180;
  const cached = inTok * (opts?.cachedShare ?? 0.35);
  const per =
    ((inTok - cached) * p.in) / 1e6 + (cached * p.in * 0.1) / 1e6 + (outTok * p.out) / 1e6;
  return { model, scans, cost_per_scan_usd: round6(per), total_usd: round2(per * scans) };
}

export function projectionTable(model: string) {
  return [1_000, 10_000, 100_000, 1_000_000].map((n) => project(n, model));
}

const round2 = (n: number) => Math.round(n * 100) / 100;
const round4 = (n: number) => Math.round(n * 1e4) / 1e4;
const round6 = (n: number) => Math.round(n * 1e6) / 1e6;
