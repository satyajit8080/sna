import type { FastifyInstance } from "fastify";
import { ZodError } from "zod";
import { isProd } from "../config.js";

export function registerErrorHandler(app: FastifyInstance) {
  app.setErrorHandler((err: any, req, reply) => {
    if (err instanceof ZodError) {
      return reply.code(400).send({ error: "validation_failed", issues: err.issues });
    }
    const status = err.statusCode ?? 500;

    if (status >= 500) {
      // Never log request bodies — they contain food images and health data.
      req.log.error({ err: err.message, url: req.url, status }, "request failed");
    }

    reply.code(status).send({
      error: err.code ?? (status >= 500 ? "internal_error" : "bad_request"),
      // Raw provider errors, stack traces and keys must never reach a client.
      message: status >= 500 && isProd ? "Something went wrong." : err.message,
      ...(err.quota ? { quota: err.quota } : {}),
      ...(err.feature ? { feature: err.feature } : {}),
      ...(err.usage ? { usage: err.usage } : {}),
      ...(err.reason ? { reason: err.reason } : {}),
    });
  });

  app.setNotFoundHandler((_req, reply) => reply.code(404).send({ error: "not_found" }));
}
