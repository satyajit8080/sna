import Fastify from "fastify";
import cors from "@fastify/cors";
import helmet from "@fastify/helmet";
import multipart from "@fastify/multipart";
import rateLimit from "@fastify/rate-limit";

import { createHash } from "node:crypto";
import { cfg, isProd, allowedOrigins, assertProviderConfigured } from "./config.js";
import { pool } from "./db.js";
import { migrate, verifySchema } from "./migrate.js";
import { registerErrorHandler } from "./middleware/errors.js";
import authRoutes from "./routes/auth.js";
import foodRoutes from "./routes/food.js";
import logRoutes from "./routes/log.js";
import subRoutes from "./routes/subscription.js";
import premiumRoutes from "./routes/premium.js";

const app = Fastify({
  logger: {
    level: process.env.LOG_LEVEL ?? (isProd ? "info" : "debug"),
    // Health data, food images and tokens must never reach the log sink.
    redact: {
      paths: [
        "req.headers.authorization",
        "req.headers.cookie",
        "req.body",
        "res.body",
      ],
      remove: true,
    },
    serializers: {
      req: (r) => ({ method: r.method, url: r.url, id: r.id }),
    },
  },
  bodyLimit: cfg.MAX_UPLOAD_BYTES,
  // Railway terminates TLS at the edge and forwards X-Forwarded-*.
  trustProxy: true,
});

await app.register(helmet, {
  contentSecurityPolicy: false,          // no browser surface; API only
  hsts: isProd ? { maxAge: 31_536_000, includeSubDomains: true } : false,
});

await app.register(cors, {
  // The iOS client sends no Origin, so an empty allowlist is the safe default.
  origin: allowedOrigins.length ? allowedOrigins : (isProd ? false : true),
  credentials: false,
});

await app.register(multipart, { limits: { fileSize: cfg.MAX_UPLOAD_BYTES, files: 1, fields: 4 } });

/**
 * Rate-limit key.
 *
 * `req.userId` is set by the auth preHandler, which runs AFTER the rate
 * limiter — so keying on it silently fell back to the IP for every request,
 * meaning users behind one NAT throttled each other. Hashing the bearer token
 * gives a stable per-user key at the right point in the lifecycle, without
 * verifying the JWT twice or logging anything sensitive.
 */
function rateKey(req: { headers: Record<string, any>; ip: string }): string {
  const header = req.headers.authorization;
  if (typeof header === "string" && header.startsWith("Bearer ")) {
    return "u:" + createHash("sha256").update(header.slice(7)).digest("hex").slice(0, 32);
  }
  return "ip:" + req.ip;
}

await app.register(rateLimit, {
  max: 120,
  timeWindow: "1 minute",
  keyGenerator: rateKey as any,
});

// ── health ───────────────────────────────────────────────────────────────────
// Railway probes this. Cheap, no auth, reports readiness rather than liveness.
app.get("/health", async (_req, reply) => {
  try {
    await pool.query("SELECT 1");
    return { ok: true, provider: cfg.AI_PROVIDER, model: cfg.AI_MODEL, version: process.env.RAILWAY_GIT_COMMIT_SHA ?? "dev" };
  } catch {
    return reply.code(503).send({ ok: false, error: "database_unavailable" });
  }
});

app.get("/", async () => ({ service: "snapcal-api", health: "/health" }));

// Must be registered BEFORE the route plugins: Fastify error handlers are
// encapsulated, so a scope registered earlier keeps the default handler and
// would leak Zod stack traces as 500s.
registerErrorHandler(app);

// ── routes ───────────────────────────────────────────────────────────────────
// Tighter bucket on the expensive AI path.
await app.register(async (scope) => {
  await scope.register(rateLimit, {
    max: 30,
    timeWindow: "1 minute",
    keyGenerator: rateKey as any,
  });
  await scope.register(foodRoutes);
}, { prefix: "/api/v1" });

await app.register(authRoutes, { prefix: "/api/v1" });
await app.register(logRoutes, { prefix: "/api/v1" });
await app.register(subRoutes, { prefix: "/api/v1" });

// Coach and planner are AI-metered too, so they share the tighter bucket.
await app.register(async (scope) => {
  await scope.register(rateLimit, {
    max: 30, timeWindow: "1 minute",
    keyGenerator: rateKey as any,
  });
  await scope.register(premiumRoutes);
}, { prefix: "/api/v1" });

// ── boot ─────────────────────────────────────────────────────────────────────
assertProviderConfigured();

if (cfg.RUN_MIGRATIONS_ON_BOOT) {
  // Advisory-locked and forward-only, so multiple Railway replicas booting
  // together is safe and never destructive.
  await migrate();
}
await verifySchema();

await app.listen({ port: cfg.PORT, host: "0.0.0.0" });

// ── graceful shutdown ────────────────────────────────────────────────────────
let shuttingDown = false;
async function shutdown(signal: string) {
  if (shuttingDown) return;
  shuttingDown = true;
  app.log.info({ signal }, "shutting down");

  const force = setTimeout(() => process.exit(1), 10_000);
  force.unref();

  try {
    await app.close();       // stops accepting, drains in-flight requests
    await pool.end();
    process.exit(0);
  } catch (e) {
    app.log.error({ e }, "shutdown failed");
    process.exit(1);
  }
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("unhandledRejection", (reason) => app.log.error({ reason }, "unhandled rejection"));
