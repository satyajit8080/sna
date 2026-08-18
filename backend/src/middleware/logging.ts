import type { FastifyInstance } from "fastify";

/**
 * Request logging that cannot leak health data.
 *
 * Bodies are never logged. Only method, route, status and duration — enough to
 * diagnose a problem, not enough to reconstruct anyone's readings. This is a
 * deliberate trade: richer logs would make debugging easier and would also mean
 * blood pressure history sitting in a log aggregator.
 */
export function registerLogging(app: FastifyInstance): void {
  app.addHook("onResponse", async (request, reply) => {
    request.log.info(
      {
        method: request.method,
        route: request.routeOptions?.url ?? request.url.split("?")[0],
        status: reply.statusCode,
        durationMs: Math.round(reply.elapsedTime),
      },
      "request"
    );
  });
}
