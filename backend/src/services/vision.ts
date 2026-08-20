import type { Config } from "../config.js";

/**
 * Food photo analysis.
 *
 * A vision model identifies what is on the plate and estimates portions; the
 * nutrition numbers then come from USDA FoodData Central wherever a match
 * exists. That split matters: the model is good at *naming* food and poor at
 * recalling exact nutrient values, so letting it invent numbers would produce
 * confident, wrong figures in a sodium tracker.
 *
 * Everything returned is explicitly an estimate. Portion size from a photograph
 * is genuinely uncertain, and the client labels it as such rather than
 * presenting it like a weighed measurement.
 */

export interface DetectedFood {
  name: string;
  /** The model's own portion estimate, in grams. */
  estimatedGrams: number;
  /** How confident the model is that it identified this correctly. */
  confidence: "high" | "medium" | "low";
  /** A short note where the model is unsure, e.g. "sauce not identifiable". */
  note?: string;
}

export interface AnalysedFood extends DetectedFood {
  /** Populated from USDA where a match was found. */
  sodiumMilligrams: number | null;
  calories: number | null;
  proteinGrams: number | null;
  carbohydrateGrams: number | null;
  fatGrams: number | null;
  /** Where the nutrition figures came from, for display. */
  nutritionSource: "USDA FoodData Central" | "unavailable";
}

const SYSTEM_PROMPT = `You identify food in photographs for a nutrition app.

Return ONLY a JSON object, no prose and no markdown fences:
{"items":[{"name":"...","estimatedGrams":0,"confidence":"high|medium|low","note":"..."}]}

Rules:
- Name each distinct food using plain, searchable terms a food database would
  hold: "grilled chicken breast", not "the chicken".
- estimatedGrams is your best portion estimate. Use common reference points
  (a deck of cards is ~85g of meat, a cupped hand is ~130g of rice).
- confidence reflects identification, not portion size. Use "low" when a food is
  partly hidden, ambiguous, or could be several things.
- Add a note only where it changes how the figure should be read, e.g. "dressing
  quantity not visible".
- Do NOT return nutrient values. You are identifying food, not measuring it.
- If the image contains no food, return {"items":[]}.`;

export async function analyseFoodPhoto(
  imageBase64: string,
  mediaType: string,
  config: Config
): Promise<DetectedFood[]> {
  if (!config.openRouterApiKey) {
    throw new Error("not-configured");
  }

  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.openRouterApiKey}`,
      "Content-Type": "application/json",
      "HTTP-Referer": config.appReferer,
      "X-Title": "BP Coach",
    },
    body: JSON.stringify({
      // A vision-capable model. Kept separate from the coach model because the
      // two jobs have different requirements.
      model: config.visionModel,
      max_tokens: 900,
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        {
          role: "user",
          content: [
            { type: "text", text: "Identify the food in this photo." },
            {
              type: "image_url",
              image_url: { url: `data:${mediaType};base64,${imageBase64}` },
            },
          ],
        },
      ],
    }),
    signal: AbortSignal.timeout(45_000),
  });

  if (!response.ok) {
    throw new Error(`vision-upstream-${response.status}`);
  }

  const payload = (await response.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  const text = payload.choices?.[0]?.message?.content ?? "";

  return parseDetectedFoods(text);
}

/**
 * Parses the model's reply.
 *
 * Written defensively: models wrap JSON in fences, add prose, or return a bare
 * array despite instructions. A parse failure must not become a fabricated
 * result, so anything unrecognisable yields an empty list.
 */
export function parseDetectedFoods(raw: string): DetectedFood[] {
  const cleaned = raw
    .replace(/```json/gi, "")
    .replace(/```/g, "")
    .trim();

  // Take the outermost object or array, ignoring any surrounding prose.
  const start = cleaned.search(/[[{]/);
  if (start === -1) return [];
  const end = Math.max(cleaned.lastIndexOf("}"), cleaned.lastIndexOf("]"));
  if (end <= start) return [];

  let parsed: unknown;
  try {
    parsed = JSON.parse(cleaned.slice(start, end + 1));
  } catch {
    return [];
  }

  const items = Array.isArray(parsed)
    ? parsed
    : (parsed as { items?: unknown }).items;
  if (!Array.isArray(items)) return [];

  return items
    .filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
    .map((item) => {
      const grams = Number(item.estimatedGrams);
      const raw = String(item.confidence ?? "").toLowerCase();
      const confidence: DetectedFood["confidence"] =
        raw === "high" || raw === "low" ? raw : "medium";
      return {
        name: String(item.name ?? "").trim().slice(0, 80),
        // Clamp rather than trust: an absurd portion would distort the day's
        // total badly, and 2kg of anything on one plate is a parsing error.
        estimatedGrams:
          Number.isFinite(grams) && grams > 0 ? Math.min(Math.round(grams), 2_000) : 100,
        confidence,
        note: typeof item.note === "string" && item.note.trim()
          ? item.note.trim().slice(0, 140)
          : undefined,
      };
    })
    .filter((item) => item.name.length >= 2)
    .slice(0, 12);
}
