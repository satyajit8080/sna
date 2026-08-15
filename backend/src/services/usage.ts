import { randomUUID } from "node:crypto";
import { q, one, tx } from "../db.js";
import { cfg } from "../config.js";
import type { Usage } from "../ai/types.js";

export type Plan = "free" | "pro";

export async function planFor(userId: string): Promise<Plan> {
  const row = await one<{ plan: Plan; expires_at: string | null }>(
    `SELECT plan, expires_at FROM subscriptions WHERE user_id = $1`, [userId]
  );
  if (!row || row.plan !== "pro") return "free";
  if (row.expires_at && new Date(row.expires_at) < new Date()) return "free";
  return "pro";
}

export type Quota = {
  plan: Plan;
  used: number;
  limit: number | null;
  remaining: number | null;
  resetsAt: string;
};

const QUOTA_KINDS = ["image", "text", "voice"];
const PRO_ONLY = new Set(["barcode", "voice"]);

export async function scanQuota(userId: string): Promise<Quota> {
  const plan = await planFor(userId);
  const resetsAt = new Date(Date.now() + 7 * 864e5).toISOString();
  if (plan === "pro") return { plan, used: 0, limit: null, remaining: null, resetsAt };

  const row = await one<{ n: string }>(
    `SELECT COUNT(*) AS n FROM ai_usage
      WHERE user_id = $1
        AND counts_against_quota
        AND status <> 'failed'
        AND cache_hit = false
        AND created_at > now() - interval '7 days'`,
    [userId]
  );
  const used = Number(row?.n ?? 0);
  const limit = cfg.FREE_SCANS_PER_WEEK;
  return { plan, used, limit, remaining: Math.max(0, limit - used), resetsAt };
}

export class QuotaError extends Error {
  statusCode = 402;
  constructor(
    public code: "scan_limit_reached" | "pro_required",
    public quota?: Quota,
    public feature?: string
  ) {
    super(code);
  }
}

export type Reservation = { id: string; requestId: string; plan: Plan };

/**
 * Atomically claims one scan against the free-tier allowance.
 *
 * The count and the INSERT are a single statement, executed after taking a row
 * lock on the user, and the row is written *before* any provider call. So N
 * concurrent requests against 1 remaining scan yield exactly 1 insert — the
 * others see the committed row and get zero rows back.
 *
 * The caller must later settle() or release() the reservation.
 */
export async function reserveScan(userId: string, kind: string): Promise<Reservation> {
  const plan = await planFor(userId);

  if (PRO_ONLY.has(kind) && plan !== "pro") {
    throw new QuotaError("pro_required", undefined, kind);
  }

  const requestId = randomUUID();
  const counts = plan === "free" && QUOTA_KINDS.includes(kind);

  return tx(async (c) => {
    // Serialises concurrent scans for this user only. One row, released on commit.
    await c.query(`SELECT id FROM users WHERE id = $1 FOR UPDATE`, [userId]);

    const { rows } = await c.query<{ id: string }>(
      `INSERT INTO ai_usage
         (user_id, kind, provider, model, status, reserved_at, request_id, counts_against_quota)
       SELECT $1, $2, 'pending', 'pending', 'reserved', now(), $3, $4
        WHERE $4 = false
           OR (SELECT COUNT(*) FROM ai_usage
                WHERE user_id = $1
                  AND counts_against_quota
                  AND status <> 'failed'
                  AND cache_hit = false
                  AND created_at > now() - interval '7 days') < $5
       RETURNING id`,
      [userId, kind, requestId, counts, cfg.FREE_SCANS_PER_WEEK]
    );

    if (!rows.length) {
      throw new QuotaError("scan_limit_reached", await scanQuota(userId));
    }
    return { id: rows[0]!.id, requestId, plan };
  });
}

/**
 * Settles a reservation with the real provider usage.
 *
 * `usages` is an array because one user-visible scan can bill several provider
 * calls — Luna, then Terra on low confidence. The first fills the reserved row;
 * the rest become sibling rows sharing request_id, excluded from quota. Cost
 * reporting therefore sees the true total rather than only the final call.
 */
export async function settleReservation(
  reservation: Reservation,
  userId: string,
  kind: string,
  provider: string,
  usages: Usage[],
  opts: { cacheHit?: boolean } = {}
): Promise<void> {
  const [first, ...rest] = usages;

  if (!first) {
    await q(
      `UPDATE ai_usage SET status='complete', provider=$2, model='cache', cache_hit=$3, cost_usd=0
        WHERE id = $1`,
      [reservation.id, provider, opts.cacheHit ?? false]
    );
    return;
  }

  await tx(async (c) => {
    await c.query(
      `UPDATE ai_usage SET status='complete', provider=$2, model=$3, cache_hit=$4, escalated=$5,
              input_tokens=$6, cached_tokens=$7, output_tokens=$8, cost_usd=$9, latency_ms=$10
        WHERE id = $1`,
      [reservation.id, provider, first.model, opts.cacheHit ?? false, first.escalated,
       first.inputTokens, first.cachedTokens, first.outputTokens, first.costUsd, first.latencyMs]
    );

    for (const u of rest) {
      await c.query(
        `INSERT INTO ai_usage (user_id, kind, provider, model, status, request_id,
                               counts_against_quota, escalated, input_tokens, cached_tokens,
                               output_tokens, cost_usd, latency_ms)
         VALUES ($1,$2,$3,$4,'complete',$5,false,$6,$7,$8,$9,$10,$11)`,
        [userId, kind, provider, u.model, reservation.requestId, u.escalated,
         u.inputTokens, u.cachedTokens, u.outputTokens, u.costUsd, u.latencyMs]
      );
    }
  });
}

/**
 * Releases a reservation when the request failed before producing a result.
 * Marked 'failed' rather than deleted, so we keep the error rate and a provider
 * outage does not silently consume someone's free scans. Tokens actually burned
 * before the failure are still recorded.
 */
export async function releaseReservation(reservation: Reservation, usages: Usage[] = []): Promise<void> {
  await q(
    `UPDATE ai_usage SET status='failed', cost_usd=$2, input_tokens=$3, output_tokens=$4
      WHERE id = $1`,
    [reservation.id,
     usages.reduce((a, u) => a + u.costUsd, 0),
     usages.reduce((a, u) => a + u.inputTokens, 0),
     usages.reduce((a, u) => a + u.outputTokens, 0)]
  );
}
