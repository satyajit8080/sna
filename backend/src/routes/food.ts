import type { FastifyInstance } from "fastify";
import type { Config } from "../config.js";
import { searchFoods, foodByID } from "../services/food.js";

export function registerFoodRoutes(app: FastifyInstance, config: Config): void {
  app.get<{ Querystring: { q?: string; limit?: string } }>(
    "/v1/food/search",
    async (request, reply) => {
      if (!config.usdaApiKey) {
        return reply.status(503).send({
          error: "Food search is not available.",
          retryable: false,
          configured: false,
        });
      }

      const query = (request.query.q ?? "").trim();
      if (query.length < 2) {
        return reply.status(400).send({
          error: "Enter at least two characters to search.",
          retryable: false,
        });
      }
      if (query.length > 100) {
        return reply.status(400).send({ error: "Search text is too long.", retryable: false });
      }

      const limit = Math.min(Math.max(parseInt(request.query.limit ?? "10", 10) || 10, 1), 25);
      const items = await searchFoods(query, limit, config);

      return reply.send({
        items,
        // The client shows this verbatim. USDA is public domain, but naming the
        // source is what lets a user judge a number they are about to act on.
        attribution: "Nutrition data from USDA FoodData Central",
      });
    }
  );

  app.get<{ Params: { id: string } }>("/v1/food/:id", async (request, reply) => {
    if (!config.usdaApiKey) {
      return reply.status(503).send({ error: "Food lookup is not available.", retryable: false });
    }

    const item = await foodByID(request.params.id, config);
    if (!item) {
      return reply.status(404).send({
        error: "That food was not found, or it has no sodium data.",
        retryable: false,
      });
    }
    return reply.send({ item, attribution: "Nutrition data from USDA FoodData Central" });
  });
}
