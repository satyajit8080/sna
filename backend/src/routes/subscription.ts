import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { decodeProtectedHeader, importX509, jwtVerify } from "jose";
import { q, one } from "../db.js";
import { cfg, adminUserIds } from "../config.js";
import { requireAuth } from "../middleware/auth.js";
import { planFor, scanQuota } from "../services/usage.js";
import { actual, projectionTable } from "../services/cost.js";

/**
 * StoreKit 2 JWS transaction verification.
 * The client sends `Transaction.jwsRepresentation`; we verify the x5c chain
 * against Apple's root and trust the decoded payload — no receipt round-trip.
 */
async function verifyStoreKitJWS(jws: string): Promise<any> {
  const header: any = decodeProtectedHeader(jws);
  const chain: string[] = header.x5c ?? [];
  if (!chain.length) throw Object.assign(new Error("missing_x5c"), { statusCode: 400 });

  const leaf = `-----BEGIN CERTIFICATE-----\n${chain[0]!.match(/.{1,64}/g)!.join("\n")}\n-----END CERTIFICATE-----`;
  const key = await importX509(leaf, "ES256");
  const { payload } = await jwtVerify(jws, key);

  if (payload.bundleId && payload.bundleId !== cfg.APPLE_BUNDLE_ID) {
    throw Object.assign(new Error("bundle_mismatch"), { statusCode: 400 });
  }
  return payload;
}

const PRO_PRODUCTS = new Set([cfg.PRODUCT_MONTHLY, cfg.PRODUCT_YEARLY]);

async function applyTransaction(userId: string, t: any) {
  const productId = String(t.productId ?? "");
  const expiresAt = t.expiresDate ? new Date(Number(t.expiresDate)) : null;
  const revoked = !!t.revocationDate;
  const active = PRO_PRODUCTS.has(productId) && !revoked && (!expiresAt || expiresAt > new Date());

  await q(
    `INSERT INTO subscriptions (user_id, plan, product_id, original_txn_id, environment,
                                expires_at, auto_renew, in_trial, updated_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8, now())
     ON CONFLICT (user_id) DO UPDATE SET
       plan = EXCLUDED.plan, product_id = EXCLUDED.product_id,
       original_txn_id = EXCLUDED.original_txn_id, environment = EXCLUDED.environment,
       expires_at = EXCLUDED.expires_at, auto_renew = EXCLUDED.auto_renew,
       in_trial = EXCLUDED.in_trial, updated_at = now()`,
    [userId, active ? "pro" : "free", productId, String(t.originalTransactionId ?? ""),
     String(t.environment ?? "Production"), expiresAt, !revoked,
     t.offerType === 1 || t.offerDiscountType === "FREE_TRIAL"]
  );

  return { plan: active ? "pro" : "free", product_id: productId, expires_at: expiresAt };
}

export default async function routes(app: FastifyInstance) {
  /** Called after purchase AND on every `Transaction.updates` emission. */
  app.post("/subscription/verify", { preHandler: requireAuth }, async (req) => {
    const { signed_transaction } = z.object({ signed_transaction: z.string().min(20) }).parse(req.body);
    const payload = await verifyStoreKitJWS(signed_transaction);
    return applyTransaction(req.userId, payload);
  });

  app.get("/subscription", { preHandler: requireAuth }, async (req) => {
    const [sub, quota] = await Promise.all([
      one(`SELECT plan, product_id, expires_at, auto_renew, in_trial FROM subscriptions WHERE user_id = $1`, [req.userId]),
      scanQuota(req.userId),
    ]);
    return {
      ...(sub ?? { plan: "free" }),
      plan: await planFor(req.userId),
      quota,
      products: {
        monthly: { id: cfg.PRODUCT_MONTHLY, display: "$6.99 / month" },
        yearly: { id: cfg.PRODUCT_YEARLY, display: "$39.99 / year" },
      },
    };
  });

  /** App Store Server Notifications V2 — renewals, refunds, expirations. */
  app.post("/subscription/apple-notifications", async (req, reply) => {
    const { signedPayload } = z.object({ signedPayload: z.string() }).parse(req.body);
    const outer = await verifyStoreKitJWS(signedPayload);
    const txJws = outer?.data?.signedTransactionInfo;
    if (!txJws) return reply.code(202).send({ ok: true });

    const tx = await verifyStoreKitJWS(txJws);
    const sub = await one<{ user_id: string }>(
      `SELECT user_id FROM subscriptions WHERE original_txn_id = $1`,
      [String(tx.originalTransactionId ?? "")]
    );
    if (sub) await applyTransaction(sub.user_id, tx);
    return reply.code(200).send({ ok: true });
  });

  /** Internal cost calculator. Restricted to ADMIN_USER_IDS. */
  app.get("/admin/cost", { preHandler: requireAuth }, async (req, reply) => {
    if (!adminUserIds.has(req.userId)) return reply.code(404).send({ error: "not_found" });

    const { days, model } = z.object({
      days: z.coerce.number().min(1).max(365).default(30),
      model: z.string().default(cfg.AI_MODEL),
    }).parse(req.query);

    return {
      actual: await actual(days),
      projection: projectionTable(model),
      comparison: {
        "gpt-5.6-luna": projectionTable("gpt-5.6-luna"),
        "gemini-3.5-flash-lite": projectionTable("gemini-3.5-flash-lite"),
        "gemini-3.6-flash": projectionTable("gemini-3.6-flash"),
      },
    };
  });
}

