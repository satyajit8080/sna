import { cfg } from "../config.js";
import { one, q } from "../db.js";
import { costUsd } from "../ai/pricing.js";
import { parseJson } from "../util/json.js";
import { ProviderError, type Usage } from "../ai/types.js";
import { localDate } from "../util/dates.js";
import { activityFor } from "./activity.js";
import { dailyBalance } from "./budget.js";

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
  waterMl?: number;
  waterTargetMl?: number;
  sleepMinutes?: number;
  /** Most recent sessions, newest first — drives focus and recovery advice. */
  recentWorkouts?: Array<{
    date: string;
    focus: string;
    minutes: number | null;
    effort: number | null;
    exercises: Array<{ exercise: string; sets: number; reps: number | null; weight_kg: number | null }>;
  }>;
  fitness?: {
    gymAccess: boolean;
    equipment: string;
    experience: string;
    trainingDays: number;
    sessionMinutes: number;
    injuries: string[];
    primaryGoal?: string;
    trainingLocation?: string;
    profileCompleted: boolean;
  };
  /** Findings from recent history — see services/patterns.ts. */
  patterns?: string[];
  avgCalories7d?: number;
  preferences?: { diet?: string; cuisines: string[]; dislikes: string[]; allergies: string[] };
};

export async function buildContext(userId: string, tz: string): Promise<CoachContext> {
  const day = localDate(tz);

  const [profile, targets, today, weights, activity, meals, avg, prefs, streak,
         water, fitness, workouts] = await Promise.all([
    one<any>(`SELECT name, goal, goal_weight_kg, start_weight_kg, country FROM profiles WHERE user_id = $1`, [userId]),
    one<any>(`SELECT calories, protein_g, carbs_g, fat_g, water_ml FROM nutrition_targets WHERE user_id = $1`, [userId]),
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
    one<any>(`SELECT COALESCE(SUM(ml),0)::int AS ml FROM water_logs
               WHERE user_id = $1 AND logged_on = $2`, [userId, day]),
    one<any>(`SELECT gym_access, equipment, experience, training_days,
                     session_minutes, injuries, primary_goal, training_location,
                     equipment_list, limitations, profile_completed
                FROM fitness_profile WHERE user_id = $1`, [userId]),
    // Recent sessions with their exercises, so today's recommendation can
    // avoid repeating yesterday and can progress from real weights.
    q<any>(`SELECT w.performed_on, w.focus, w.minutes, w.perceived_effort,
                   COALESCE(json_agg(json_build_object(
                     'exercise', s.exercise, 'sets', s.sets,
                     'reps', s.reps, 'weight_kg', s.weight_kg
                   ) ORDER BY s.position) FILTER (WHERE s.id IS NOT NULL), '[]') AS exercises
              FROM workouts w
              LEFT JOIN workout_sets s ON s.workout_id = w.id
             WHERE w.user_id = $1 AND w.performed_on > CURRENT_DATE - 14
             GROUP BY w.id
             ORDER BY w.performed_on DESC
             LIMIT 5`, [userId]),
  ]);

  const current = weights[0]?.weight_kg;
  const start = profile?.start_weight_kg;
  const balance = dailyBalance(targets, today, activity);

  return {
    name: profile?.name,
    goal: profile?.goal,
    country: profile?.country ?? undefined,
    currentWeightKg: current,
    goalWeightKg: profile?.goal_weight_kg,
    weightChangeKg: current != null && start != null ? Math.round((current - start) * 10) / 10 : undefined,
    targets: targets ?? undefined,
    today: today ?? undefined,
    // Same function the dashboard uses. Do not inline this maths again.
    budget: targets ? balance.budget.total_calories : undefined,
    remaining: targets ? balance.remaining : undefined,
    steps: activity.steps || undefined,
    activeKcal: activity.active_kcal || undefined,
    creditedKcal: activity.credited_kcal || undefined,
    recentMeals: meals.map((m: any) => m.name),
    streakDays: streak?.n ?? 0,
    avgCalories7d: avg?.avg ?? undefined,
    waterMl: water?.ml ?? 0,
    waterTargetMl: targets?.water_ml ?? undefined,
    sleepMinutes: undefined,
    recentWorkouts: workouts.map((w: any) => ({
      date: String(w.performed_on).slice(0, 10),
      focus: w.focus,
      minutes: w.minutes ?? null,
      effort: w.perceived_effort ?? null,
      exercises: w.exercises ?? [],
    })),
    fitness: fitness ? {
      gymAccess: fitness.gym_access,
      // The multi-select list is richer than the legacy single column; fall
      // back to it only when onboarding has not run.
      equipment: fitness.equipment_list?.length
        ? fitness.equipment_list.join(", ")
        : fitness.equipment,
      experience: fitness.experience,
      trainingDays: fitness.training_days,
      sessionMinutes: fitness.session_minutes,
      injuries: [...(fitness.injuries ?? []), ...(fitness.limitations ?? [])]
        .filter((x: string) => x && x !== "none"),
      primaryGoal: fitness.primary_goal ?? undefined,
      trainingLocation: fitness.training_location ?? undefined,
      profileCompleted: fitness.profile_completed ?? false,
    } : undefined,
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
    // A workout-shaped fixture when the caller asked for one, so the planner
    // path is exercisable in CI without spending anything.
    if (opts.json && system.includes("program training sessions")) {
      return {
        text: JSON.stringify({
          workout_title: "Full Body Strength",
          goal: "general health",
          warmup: ["5 min easy cardio", "Dynamic mobility"],
          exercises: [
            { exercise_name: "Leg Press", sets: 3, reps: "8-12", rest_seconds: 90,
              instructions: "Drive through mid-foot, don't lock out.", targets: "quads, glutes" },
            { exercise_name: "Chest Press", sets: 3, reps: "8-12", rest_seconds: 90,
              instructions: "Elbows about 45 degrees from your ribs.", targets: "chest, triceps" },
            { exercise_name: "Lat Pulldown", sets: 3, reps: "8-12", rest_seconds: 75,
              instructions: "Lead with the elbows, not the hands.", targets: "back, biceps" },
            { exercise_name: "Plank", sets: 3, reps: "30-45 sec", rest_seconds: 45,
              instructions: "Ribs down, squeeze glutes.", targets: "core" },
          ],
          optional_cardio: "15 min moderate walking",
          cooldown: ["Hamstring stretch", "Chest doorway stretch"],
          coach_note: "Straightforward session to build a base.",
        }),
        usage: { model: "mock", inputTokens: 0, cachedTokens: 0, outputTokens: 0,
                 costUsd: 0, latencyMs: 20, escalated: false },
      };
    }

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

  /**
   * Chat Completions is the fallback.
   *
   * The Responses API's `text.format` shape is not accepted by every model, and
   * a 400 there killed the whole meal planner — the same failure the vision
   * path already guards against.
   */
  async function viaChat(model: string) {
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${cfg.OPENAI_API_KEY}` },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: system },
          { role: "user", content: user },
        ],
        max_tokens: opts.maxTokens ?? 300,
        temperature: 0.4,
        ...(opts.json ? { response_format: { type: "json_object" } } : {}),
      }),
      signal: AbortSignal.timeout(cfg.AI_TIMEOUT_MS),
    });

    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      const err = new ProviderError(`openai chat ${res.status} (${model}): ${detail.slice(0, 200)}`,
                                    [], res.status >= 500 || res.status === 429, res.status);
      (err as any).providerStatus = res.status;
      (err as any).providerBody = detail.slice(0, 500);
      throw err;
    }

    const j: any = await res.json();
    const u = j.usage ?? {};
    const input = u.prompt_tokens ?? 0;
    const cached = u.prompt_tokens_details?.cached_tokens ?? 0;
    const output = u.completion_tokens ?? 0;

    return {
      text: j.choices?.[0]?.message?.content ?? "",
      usage: { model: j.model ?? model, inputTokens: input, cachedTokens: cached, outputTokens: output,
               costUsd: costUsd(model, input, cached, output),
               latencyMs: Date.now() - started, escalated: false },
    };
  }

  async function viaResponses(model: string) {
    const res = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${cfg.OPENAI_API_KEY}` },
      body: JSON.stringify({
        model,
        instructions: system,
        input: [{ role: "user", content: [{ type: "input_text", text: user }] }],
        max_output_tokens: opts.maxTokens ?? 300,
        ...(opts.json ? { text: { format: { type: "json_object" } } } : {}),
      }),
      signal: AbortSignal.timeout(cfg.AI_TIMEOUT_MS),
    });

    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      const err = new ProviderError(`openai ${res.status} (${model}): ${detail.slice(0, 200)}`,
                                    [], res.status >= 500 || res.status === 429, res.status);
      (err as any).providerStatus = res.status;
      (err as any).providerBody = detail.slice(0, 500);
      throw err;
    }

    const j: any = await res.json();
    const text = j.output_text ??
      j.output?.flatMap((o: any) => o.content ?? []).find((c: any) => c.type === "output_text")?.text ?? "";
    const u = j.usage ?? {};
    const input = u.input_tokens ?? 0;
    const cached = u.input_tokens_details?.cached_tokens ?? 0;
    const output = u.output_tokens ?? 0;

    return {
      text,
      usage: { model: cfg.AI_MODEL, inputTokens: input, cachedTokens: cached, outputTokens: output,
               costUsd: costUsd(cfg.AI_MODEL, input, cached, output),
               latencyMs: Date.now() - started, escalated: false },
    };
  }

  const attempts = [
    () => viaResponses(cfg.AI_MODEL),
    () => viaChat(cfg.AI_MODEL),
    () => viaChat("gpt-4o-mini"),
  ];

  let last: unknown;
  for (const attempt of attempts) {
    try {
      return await attempt();
    } catch (e: any) {
      last = e;
      const status = e?.providerStatus ?? e?.status;
      // A bad key cannot be fixed by another endpoint.
      if (status === 401 || status === 403) throw e;
    }
  }
  throw last;
}

export { parseJson };
