import type { AIProvider, ProviderResponse, Usage } from "./types.js";

const usage: Usage = { model: "mock", inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUsd: 0, latencyMs: 40, escalated: false };

/** Deterministic provider for CI, simulator builds and demo videos. */
export class MockProvider implements AIProvider {
  readonly name = "mock";

  async analyzeImage(): Promise<ProviderResponse> {
    await new Promise((r) => setTimeout(r, 600));
    return {
      usages: [usage],
      result: {
        foods: [
          { name: "Roti", grams: 90, unit: "roti", quantity: 2, cuisine: "indian", confidence: 0.91 },
          { name: "Dal tadka", grams: 150, unit: "katori", quantity: 1, cuisine: "indian", confidence: 0.84 },
          { name: "Mixed vegetable sabzi", grams: 120, cuisine: "indian", confidence: 0.72 },
        ],
        assumptions: ["Assumed ~1 tsp oil per serving", "Ghee on roti not visible"],
        confidence: 0.82,
      },
    };
  }

  async analyzeText(text: string): Promise<ProviderResponse> {
    return {
      usages: [usage],
      result: {
        foods: [{ name: text.split(",")[0]?.trim() || "Mixed meal", grams: 200, confidence: 0.7 }],
        assumptions: ["Portion assumed standard"],
        confidence: 0.7,
      },
    };
  }
}
