import type { FastifyInstance } from "fastify";
import type { Config } from "../config.js";
import { analyseFoodPhoto, type AnalysedFood } from "../services/vision.js";
import { searchFoods } from "../services/food.js";

/** Photos are capped: a 6MB base64 payload is already a very large image. */
const MAX_IMAGE_BYTES = 6 * 1024 * 1024;

export async function registerVisionRoutes(app: FastifyInstance, config: Config) {
  /**
   * Analyses a food photo.
   *
   * The vision model names the foods and estimates portions; nutrition figures
   * come from USDA. Splitting it this way keeps the model away from inventing
   * nutrient values, which it will do confidently and wrongly.
   */
  app.post<{ Body: { imageBase64?: string; mediaType?: string } }>(
    "/v1/vision/food",
    async (request, reply) => {
      const { imageBase64, mediaType } = request.body ?? {};

      if (!config.openRouterApiKey) {
        return reply.code(503).send({
          error: "Food photo analysis is not configured on this server.",
          retryable: false,
        });
      }

      if (typeof imageBase64 !== "string" || imageBase64.length < 100) {
        return reply.code(400).send({
          error: "No image was provided.",
          retryable: false,
        });
      }

      if (imageBase64.length > MAX_IMAGE_BYTES) {
        return reply.code(413).send({
          error: "That image is too large. Try a smaller photo.",
          retryable: false,
        });
      }

      const type = mediaType === "image/png" ? "image/png" : "image/jpeg";

      try {
        const detected = await analyseFoodPhoto(imageBase64, type, config);

        if (detected.length === 0) {
          return { items: [], note: "No food was identified in that photo." };
        }

        // Look each food up in USDA. Sequential rather than parallel: the
        // upstream is rate limited, and a dozen simultaneous requests is a
        // reliable way to get throttled.
        const items: AnalysedFood[] = [];
        for (const food of detected) {
          let enriched: AnalysedFood = {
            ...food,
            sodiumMilligrams: null,
            calories: null,
            proteinGrams: null,
            carbohydrateGrams: null,
            fatGrams: null,
            nutritionSource: "unavailable",
          };

          try {
            const matches = await searchFoods(food.name, 1, config);
            const match = matches[0];
            if (match) {
              const scale = food.estimatedGrams / 100;
              enriched = {
                ...enriched,
                sodiumMilligrams: Math.round(match.sodiumMilligramsPer100g * scale),
                calories:
                  match.energyKilocaloriesPer100g === null
                    ? null
                    : Math.round(match.energyKilocaloriesPer100g * scale),
                nutritionSource: "USDA FoodData Central",
              };
            }
          } catch {
            // A lookup failure leaves this item without nutrition rather than
            // failing the whole photo — the identification is still useful.
          }

          items.push(enriched);
        }

        return { items };
      } catch (error) {
        const message = error instanceof Error ? error.message : "unknown";
        if (message === "not-configured") {
          return reply.code(503).send({
            error: "Food photo analysis is not configured.",
            retryable: false,
          });
        }
        request.log.error({ err: error }, "food photo analysis failed");
        return reply.code(502).send({
          error: "The photo could not be analysed. Please try again.",
          retryable: true,
        });
      }
    }
  );
}
