import type { FastifyInstance } from "fastify";
import { UpstreamError } from "../services/errors.js";

/**
 * Central error handling.
 *
 * Clients get a stable shape and a message safe to display. Stack traces and
 * upstream error bodies stay on the server — an upstream 400 can echo the
 * request back, and the request contains health data.
 */
export function registerErrorHandler(app: FastifyInstance): void {
  app.setErrorHandler((error, request, reply) => {
    if (error instanceof UpstreamError) {
      request.log.warn({ err: error.message, status: error.status }, "upstream failure");
      return reply.status(error.status).send({
        error: error.message,
        retryable: error.retryable,
      });
    }

    if ((error as { statusCode?: number }).statusCode === 429) {
      return reply.status(429).send({
        error: "Too many requests. Try again in a few minutes.",
        retryable: true,
      });
    }

    if ((error as { statusCode?: number }).statusCode === 413) {
      return reply.status(413).send({ error: "Request too large.", retryable: false });
    }

    const err = error as Error;
    request.log.error({ err: err.message, stack: err.stack }, "unhandled error");
    return reply.status(500).send({
      error: "Something went wrong on our end.",
      retryable: true,
    });
  });

  app.setNotFoundHandler((_request, reply) => {
    reply.status(404).send({ error: "Not found", retryable: false });
  });
}
