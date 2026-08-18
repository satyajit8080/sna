import type { FastifyInstance } from "fastify";
import type { Config } from "../config.js";

/**
 * Health checks for Railway.
 *
 * /health is a liveness probe and must stay dependency-free: if it called the
 * AI provider, an upstream outage would make Railway restart a perfectly
 * healthy container. /ready reports which downstreams are configured, for
 * humans rather than for the orchestrator.
 */
export function registerHealthRoutes(app: FastifyInstance, config: Config): void {
  const startedAt = Date.now();

  app.get("/health", async () => ({
    status: "ok",
    uptimeSeconds: Math.round((Date.now() - startedAt) / 1000),
  }));

  app.get("/ready", async () => ({
    status: "ok",
    environment: config.environment,
    services: {
      // Booleans only. Never echo a key, a prefix, or a length.
      coach: config.openRouterApiKey ? "configured" : "not configured",
      food: config.usdaApiKey ? "configured" : "not configured",
    },
    // The slug, never the key. Useful when diagnosing which model answered.
    model: config.openRouterApiKey ? config.openRouterModel : null,
  }));
}
