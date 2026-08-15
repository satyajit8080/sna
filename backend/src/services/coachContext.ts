import { cfg } from "../config.js";
import { one, q } from "../db.js";
import { costUsd } from "../ai/pricing.js";
import { parseJson } from "../util/json.js";
import { ProviderError, type Usage } from "../ai/types.js";
import { localDate } from "../util/dates.js";
import { activityFor } from "./activity.js";

/**
 * Compact snapshot of everything the coach or planner may reason about.
 * Deliberately small: sending the full food history would multiply token cost
 * for no measurable answer quality.
 */
export type CoachContext = {
  name?: string;
  goal?: string;
  /** ISO country from the profile; steers cuisine defaults. */
  country?: string;
  currentWeightKg?: number;
  goalWeightKg?: number;
  weightChangeKg?: number;
  targets?: { calories: number; protein_g: number; carbs_g: number; fat_g: number };
  today?: { calories: number; protein_g: number; carbs_g: number; fat_g: number };
  /** Activity-adjusted. This is the number the coach and planner must use. */
  remaining?: { calories: number; protein_g: number; carbs_g: number; fat_g: number };
  /** Base target + credited activity. */
  budget?: number;
  steps?: number;
  activeKcal?: number;
  creditedKcal?: number;
  recentMeals: string[];
  streakDays: number;
  avgCalories7d?: number;
  preferences?: { diet?: string; cuisines: string[]; dislikes: string[]; allergies: string[] };
};

export async function buildContext(userId: string, tz: string): Promise<CoachContext> {
  const day = localDate(tz);

  const [profile, targets, today, weights, activity, meals, avg, prefs, streak] = await Promise.all([
    one<any>(`SELECT name, goal, goal_weight_kg, start_weight_kg, country FROM profiles WHERE user_id = $1`, [userId]),
    one<any>(`SELECT calories, protein_g, carbs_g, fat_g FROM nutrition_targets WHERE user_id = $1`, [userId]),
    one<any>(`SELECT ROUND(SUM(i.grams * i.kcal_100g    / 100))::int AS calories,
                     ROUND(SUM(i.grams * i.protein_100g / 100))::int AS protein_g,
                     ROUND(SUM(i.grams * i.carbs_100g   / 100))::int AS carbs_g,
                     ROUND(SUM(i.grams * i.fat_100g     / 100))::int AS fat_g
                FROM meals m JOIN meal_items i ON i.meal_id = m.id
               WHERE m.user_id = $1 AND m.logged_on = $2`, [userId, day]),
    q<any>(`SELECT weight_kg FROM weight_logs WHERE user_id = $1 ORDER BY logged_on DESC LIMIT 14`, [userId]),
    activityFor(userId, tz, day),
    q<any>(`SELECT DISTINCT i.name FROM meals m JOIN meal_items i ON i.meal_id = m.id
             WHERE m.user_id = $1 ORDER BY i.name LIMIT 12`, [userId]),
    one<any>(`SELECT ROUND(AVG(d.cal))::int AS avg FROM (
                SELECT m.logged_on, SUM(i.grams * i.kcal_100g / 100) AS cal
                  FROM meals m JOIN meal_items i ON i.meal_id = m.id
                 WHERE m.user_id = $1 AND m.logged_on > CURRENT_DATE - 7
                 GROUP BY m.logged_on) d`, [userId]),
    one<any>(`SELECT diet, cuisines, dislikes, allergies FROM food_preferences WHERE user_id = $1`, [userId]),
    one<any>(`SELECT COUNT(DISTINCT logged_on)::int AS n FROM meals
               WHERE user_id = $1 AND logged_on > CURRENT_DATE - 7`, [userId]),
  ]);

  const current = weights[0]?.weight_kg;
  const start = profile?.start_weight_kg;

  return {
    name: profile?.name,
    goal: profile?.goal,
    country: profile?.country ?? undefined,
    currentWeightKg: current,
    goalWeightKg: profile?.goal_weight_kg,
    weightChangeKg: current != null && start != null ? Math.round((current - start) * 10) / 10 : undefined,
    targets: targets ?? undefined,
    today: today ?? undefined,
    // Movement raises the allowance, so remaining must be computed against the
    // activity-adjusted budget — not the base target. Using the base here was
    // why the coach could say "you have 200 left" while the dashboard showed
    // 400 after a walk.
    budget: targets ? targets.calories + activity.credited_kcal : undefined,
    remaining: targets ? {
      calories: targets.calories + activity.credited_kcal - (today?.calories ?? 0),
      protein_g: targets.protein_g - (today?.protein_g ?? 0),
      carbs_g: targets.carbs_g - (today?.carbs_g ?? 0),
      fat_g: targets.fat_g - (today?.fat_g ?? 0),
    } : undefined,
    steps: activity.steps || undefined,
    activeKcal: activity.active_kcal || undefined,
    creditedKcal: activity.credited_kcal || undefined,
    recentMeals: meals.map((m: any) => m.name),
    streakDays: streak?.n ?? 0,
    avgCalories7d: avg?.avg ?? undefined,
    preferences: prefs ? {
      diet: prefs.diet ?? undefined,
      cuisines: prefs.cuisines ?? [],
      dislikes: prefs.dislikes ?? [],
      allergies: prefs.allergies ?? [],
    } : undefined,
  };
}

/**
 * Plain text/JSON completion against the configured provider. The image path
 * lives in ai/openai.ts; this shares the pricing and error handling but not the
 * vision-specific prompt shaping.
 */
export async function complete(
  system: string, user: string, opts: { json?: boolean; maxTokens?: number } = {}
): Promise<{ text: string; usage: Usage }> {
  const started = Date.now();

  if (cfg.AI_PROVIDER === "mock") {
    return {
      text: opts.json
        ? JSON.stringify({ days: [{ date: new Date().toISOString().slice(0, 10), meals: [
            { slot: "breakfast", name: "Oatmeal with berries", grams: 300, kcal: 290, protein_g: 9, carbs_g: 52, fat_g: 6 },
            { slot: "lunch", name: "Turkey sandwich", grams: 240, kcal: 420, protein_g: 31, carbs_g: 44, fat_g: 14 },
            { slot: "dinner", name: "Grilled chicken with rice", grams: 320, kcal: 480, protein_g: 42, carbs_g: 48, fat_g: 11 },
          ] }], note: "Balanced around your protein target." })
        : "You have room left today. Grilled chicken with rice keeps you on target and adds protein.",
      usage: { model: "mock", inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUsd: 0, latencyMs: 20, escalated: false },
    };
  }

  if (cfg.AI_PROVIDER === "gemini") {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent`,
      { method: "POST",
        headers: { "content-type": "application/json", "x-goog-api-key": cfg.GEMINI_API_KEY ?? "" },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: system }] },
          contents: [{ role: "user", parts: [{ text: user }] }],
          generationConfig: {
            responseMimeType: opts.json ? "application/json" : "text/plain",
            maxOutputTokens: opts.maxTokens ?? 300, temperature: 0.4,
          },
        }),
        signal: AbortSignal.timeout(cfg.AI_TIMEOUT_MS) });
    if (!res.ok) throw new ProviderError(`gemini ${res.status}`, [], res.status >= 500, res.status);
    const j: any = await res.json();
    const u = j.usageMetadata ?? {};
    return {
      text: j.candidates?.[0]?.content?.parts?.map((p: any) => p.text ?? "").join("") ?? "",
      usage: { model: "gemini-3.5-flash-lite", inputTokens: u.promptTokenCount ?? 0,
               cachedTokens: u.cachedContentTokenCount ?? 0, outputTokens: u.candidatesTokenCount ?? 0,
               costUsd: costUsd("gemini-3.5-flash-lite", u.promptTokenCount ?? 0, u.cachedContentTokenCount ?? 0, u.candidatesTokenCount ?? 0),
               latencyMs: Date.now() - started, escalated: false },
    };
  }

  const res = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${cfg.OPENAI_API_KEY}` },
    body: JSON.stringify({
      model: cfg.AI_MODEL,
      instructions: system,
      input: [{ role: "user", content: [{ type: "input_text", text: user }] }],
      max_output_tokens: opts.maxTokens ?? 300,
      ...(opts.json ? { text: { format: { type: "json_object" } } } : {}),
    }),
    signal: AbortSignal.timeout(cfg.AI_TIMEOUT_MS),
  });

  if (!res.ok) {
    throw new ProviderError(`openai ${res.status}`, [], res.status >= 500 || res.status === 429, res.status);
  }

  const j: any = await res.json();
  const text = j.output_text ??
    j.output?.flatMap((o: any) => o.content ?? []).find((c: any) => c.type === "output_text")?.text ?? "";
  const u = j.usage ?? {};
  const input = u.input_tokens ?? 0, cached = u.input_tokens_details?.cached_tokens ?? 0, output = u.output_tokens ?? 0;

  return {
    text,
    usage: { model: cfg.AI_MODEL, inputTokens: input, cachedTokens: cached, outputTokens: output,
             costUsd: costUsd(cfg.AI_MODEL, input, cached, output),
             latencyMs: Date.now() - started, escalated: false },
  };
}

export { parseJson };
