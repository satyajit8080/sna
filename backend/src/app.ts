import Fastify, { type FastifyInstance } from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import type { Config } from "./config.js";
import { LIMITS } from "./schema.js";
import { registerLogging } from "./middleware/logging.js";
import { registerErrorHandler } from "./middleware/errors.js";
import { registerHealthRoutes } from "./routes/health.js";
import { registerCoachRoutes } from "./routes/coach.js";
import { registerFoodRoutes } from "./routes/food.js";

export async function buildApp(config: Config): Promise<FastifyInstance> {
  const app = Fastify({
    logger: {
      level: config.environment === "production" ? "info" : "debug",
      // Health data must never reach a log line, and headers carry the API key
      // on the way out, so both are redacted at the logger rather than trusted
      // to never be passed in.
      redact: {
        paths: ["req.body", "res.body", "req.headers.authorization", "req.headers[\"x-api-key\"]"],
        remove: true,
      },
    },
    bodyLimit: LIMITS.maxBodyBytes,
    trustProxy: true, // Railway terminates TLS upstream
  });

  await app.register(cors, {
    // A native iOS app sends no Origin header, so requests with no origin are
    // allowed. Browser origins must be listed explicitly.
    origin: (origin, callback) => {
      if (!origin) return callback(null, true);
      callback(null, config.corsOrigins.includes(origin));
    },
    methods: ["GET", "POST"],
    maxAge: 86_400,
  });

  await app.register(rateLimit, {
    max: config.rateLimit.max,
    timeWindow: `${config.rateLimit.windowMinutes} minutes`,
    // No accounts exist, so the client IP is the only available key.
    keyGenerator: (request) => request.ip,
    addHeaders: { "x-ratelimit-limit": true, "x-ratelimit-remaining": true, "x-ratelimit-reset": true },
  });

  registerLogging(app);
  registerErrorHandler(app);

  registerHealthRoutes(app, config);
  registerCoachRoutes(app, config);
  registerFoodRoutes(app, config);

  return app;
}
