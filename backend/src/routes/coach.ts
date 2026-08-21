import type { FastifyInstance } from "fastify";
import type { Config } from "../config.js";
import { validateCoachRequest } from "../schema.js";
import { requestCoaching } from "../services/openrouter.js";

export function registerCoachRoutes(app: FastifyInstance, config: Config): void {
  app.post("/v1/coach", async (request, reply) => {
    if (!config.openRouterApiKey) {
      return reply.status(503).send({
        error: "The AI coach is not set up yet.",
        retryable: false,
        configured: false,
      });
    }

    const validation = validateCoachRequest(request.body);
    if (!validation.ok) {
      return reply.status(400).send({
        error: "The request was not valid.",
        details: validation.failures,
        retryable: false,
      });
    }

    const result = await requestCoaching(validation.body, config);

    if (result.screened) {
      // Logged as a counter, without the generated text: knowing the screen
      // fired matters, keeping the prohibited output around does not.
      request.log.warn(
        { reason: result.screenReason, model: result.modelUsed },
        "coach response screened"
      );
    }

    return reply.send({
      text: result.text,
      // A proposal only. The app shows a confirmation card; nothing is written
      // here, and nothing is written on the device until the user taps confirm.
      action: result.action ?? null,
      readingsUsed: validation.body.readings.length,
      guideline: validation.body.guidelineName,
    });
  });
}
