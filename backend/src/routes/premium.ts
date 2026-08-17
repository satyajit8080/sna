import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { q, one, tx } from "../db.js";
import { requireAuth } from "../middleware/auth.js";
import { adminUserIds, cfg, usdaKey } from "../config.js";
import { searchUsdaMany } from "../nutrition/usda.js";
import { ai, ProviderError, type Usage } from "../ai/index.js";
import { COACH_SYSTEM, MEAL_PLAN_SYSTEM } from "../ai/prompts.js";
import { buildContext, complete, parseJson } from "../services/coachContext.js";
import { chat, cheapestModels } from "../ai/openrouter.js";
import { suggestNextMeal } from "../services/suggest.js";
import * as safety from "../services/safety.js";
import { recall, memoriesForPrompt } from "../services/brain.js";
import { buildHealthState, summariseForPrompt } from "../services/healthState.js";
import { buildFollowUp, followUpForPrompt, followUpSteer } from "../services/followUp.js";
import { onboardingState, welcomeLine } from "../services/coachOnboarding.js";
import { topPatterns } from "../services/patterns.js";
import { generateWorkout, savePlan } from "../services/workoutPlanner.js";
import {
  classify, isOnTopic, answerContainsRefusal, guardFor,
  maxTokensFor, keepsStructure, validateResponse,
} from "../services/coachIntent.js";
import { activityFor, recordActivity, activityHistory } from "../services/activity.js";
import {
  entitlementsFor, reserve, settle, release, subscriptionFor,
  type Reservation,
} from "../services/entitlements.js";
import { localDate, daysAgo, localClock } from "../util/dates.js";

/** reserve → work → settle, so no path can leak a reservation. */
async function metered<T>(
  req: FastifyRequest, kind: string,
  work: () => Promise<{ value: T; usages: Usage[] }>
): Promise<T> {
  const reservation: Reservation = await reserve(req.userId, kind);
  try {
    const { value, usages } = await work();
    await settle(reservation, req.userId, kind, ai.primary().name, usages);
    return value;
  } catch (e: any) {
    await release(reservation, e instanceof ProviderError ? e.usages : []);
    throw e;
  }
}

export default async function routes(app: FastifyInstance) {

  // ── entitlements: one call drives every usage badge in the app ────────────
  app.get("/entitlements", { preHandler: requireAuth }, async (req) =>
    entitlementsFor(req.userId));

  // ── AI coach ──────────────────────────────────────────────────────────────
  app.post("/coach/ask", { preHandler: requireAuth }, async (req) => {
    const { question } = z.object({ question: z.string().min(2).max(300) }).parse(req.body);

    // Safety first, before intent and before any context is gathered. A
    // blocked category never reaches the model at all, so no amount of
    // prompt-wrangling can talk it into answering.
    const verdict = safety.assess(question);

    if (verdict.action === "block") {
      await q(`INSERT INTO coach_messages (user_id, role, content, intent)
               VALUES ($1,'user',$2,'safety'), ($1,'assistant',$3,'safety')`,
        [req.userId, question, verdict.response!]);

      return {
        answer: verdict.response!,
        suggestion: null,
        intent: "safety",
        entitlements: await entitlementsFor(req.userId),
      };
    }

    // Classification decides which context is worth gathering and how large a
    // response to pay for.
    const intent = classify(question);
    const guard = guardFor(question);
    const onTopic = isOnTopic(question);

    const answer = await metered(req, "coach", async () => {
      const context = await buildContext(req.userId, req.tz);

      // Patterns are arithmetic over logged history, not model output, so they
      // cannot hallucinate. Only gathered where they change the answer — a
      // calorie check does not need a fortnight of trends.
      const wantsDeepContext = ["daily_plan", "progress", "workout_request", "sleep"]
        .includes(intent);

      const [patterns, memories, healthState, followUp] = await Promise.all([
        wantsDeepContext ? topPatterns(req.userId, 3) : Promise.resolve([]),
        // Memory goes to every turn: knowing someone dislikes running matters
        // as much for a one-line answer as for a plan.
        recall(req.userId, { limit: 10 }),
        wantsDeepContext
          ? buildHealthState(req.userId, localDate(req.tz))
          : Promise.resolve(null),
        // What was advised, whether it was done, and whether it worked. This
        // is what turns a series of separate answers into a coaching loop.
        buildFollowUp(req.userId, req.tz),
      ]);

      // Only the last exchange is replayed. Full history would grow the bill
      // linearly with no benefit for single-turn coaching questions.
      const prior = await q<{ role: string; content: string }>(
        `SELECT role, content FROM coach_messages WHERE user_id = $1
          ORDER BY created_at DESC LIMIT 2`, [req.userId]);

      // Only the numbers the coach can actually use. Sending the whole context
      // object would triple the token bill for answers that are one line long.
      const activity = await activityFor(req.userId, req.tz);
      // Today's actual meals, so the coach answers from what was eaten rather
      // than inferring from a calorie total. Without this it would confidently
      // describe meals the user never logged.
      const todaysMeals = await q<{ name: string; slot: string; calories: number; protein_g: number }>(
        `SELECT i.name, m.slot,
                ROUND(i.grams * i.kcal_100g / 100)::int    AS calories,
                ROUND(i.grams * i.protein_100g / 100)::int AS protein_g
           FROM meals m JOIN meal_items i ON i.meal_id = m.id
          WHERE m.user_id = $1 AND m.logged_on = $2
          ORDER BY m.logged_at`,
        [req.userId, localDate(req.tz)]
      );

      const facts = {
        remaining_kcal: context.remaining?.calories ?? null,
        remaining_protein_g: context.remaining?.protein_g ?? null,
        target_kcal: context.targets?.calories ?? null,
        budget_kcal: context.budget ?? null,
        eaten_kcal: context.today?.calories ?? 0,
        eaten_protein_g: context.today?.protein_g ?? 0,
        meals_today: todaysMeals.map((m) => ({
          food: m.name, when: m.slot, kcal: m.calories, protein_g: m.protein_g,
        })),
        steps: activity.steps,
        burned_kcal_credited: activity.credited_kcal,
        weight_kg: context.currentWeightKg ?? null,
        goal_weight_kg: context.goalWeightKg ?? null,
        change_since_start_kg: context.weightChangeKg ?? null,
        streak_days: context.streakDays,
        goal: context.goal ?? null,
        diet: context.preferences?.diet ?? null,
        allergies: context.preferences?.allergies ?? [],
        water_ml: context.waterMl ?? 0,
        water_target_ml: context.waterTargetMl ?? null,
        recent_workouts: (context.recentWorkouts ?? []).map((w) => ({
          date: w.date, focus: w.focus, minutes: w.minutes, effort: w.effort,
          exercises: w.exercises.map((e) => ({
            exercise: e.exercise, sets: e.sets, reps: e.reps, weight_kg: e.weight_kg,
          })),
        })),
        fitness_profile: context.fitness ?? null,
        patterns_noticed: patterns,
        // What the brain has learned. Each carries a certainty so the model
        // hedges on a weak memory instead of asserting it as fact.
        known_about_user: memoriesForPrompt(memories),
        // Time of day, because advice that ignores the clock is wrong however
        // good it is otherwise — a gym session is not the right answer at
        // half past midnight.
        local_time: localClock(req.tz),
        previous_advice: followUpForPrompt(followUp),
        // Trends and baselines, not raw numbers — "HRV 42" means nothing
        // without knowing this person's normal.
        health_state: healthState ? summariseForPrompt(healthState) : null,
      };

      /**
       * Per-turn steer.
       *
       * The system prompt sets the coach's character; this says what *this*
       * message needs. Guards come first because they must hold regardless of
       * what the question is otherwise about.
       */
      const clock = localClock(req.tz);
      const timeSteer =
        clock.partOfDay === "late_night"
          ? " It is the middle of the night for them. Do not recommend training, a big meal, or anything energising — sleep is the useful answer, and say so briefly without lecturing."
        : clock.partOfDay === "evening"
          ? " It is evening for them, so favour things that still fit today and mention tomorrow for anything that does not."
        : clock.partOfDay === "morning"
          ? " It is morning for them, so the whole day is still available."
          : "";

      const steer =
        (verdict.instruction ? verdict.instruction
        : guard === "urgent"
          ? "The user may be describing a medical emergency. Tell them plainly to seek urgent medical help now. Do not offer nutrition or training advice."
        : guard === "medical"
          ? "This touches on medication or diagnosis. Say a doctor or pharmacist is the right person, name no medication or dose, then offer help with the food, training or recovery side if there is one."
        : guard === "brand"
          ? "They are asking which product or brand to buy. Do not name a brand. Explain what to compare — protein per serving, ingredients, cost, tolerance — and answer any other part of their question fully."
        : guard === "live_data"
          ? "They are asking about live availability, price or opening hours, which you cannot verify. Say so in one clause, then answer the general part of the question properly."
        : !onTopic
          ? "This is not about food, nutrition, training, activity, sleep or their progress. Say briefly that this is outside what you help with, and offer what you do cover. Do NOT mention their calorie numbers."
        : intent === "workout_request"
          ? "Give a complete session: warm-up, exercises with sets and reps, rest between sets, and a cool-down. Respect their equipment, time and experience from the context. Use recentWorkouts to choose today's focus and to avoid repeating what they trained most recently. If they have trained hard several days running, recommend recovery instead."
        : intent === "daily_plan"
          ? "Give a short structured plan for today covering nutrition, activity and training, based on their actual numbers. Lead with the single highest-impact thing. Keep it to a few short lines."
        : intent === "meal_recommendation"
          ? "Recommend specific food. Say in a few words why it fits their remaining calories or protein. Never ask them to scan or search anything."
        : intent === "food_analysis"
          ? "They are asking about food they have eaten. Use meals_today. If it is not there, say it needs scanning or searching."
        : intent === "hydration"
          ? "Answer using their water intake and target. Do not push excessive intake."
        : intent === "activity"
          ? "Answer using their step count and target. If they have already been active, say so rather than pushing more."
        : intent === "sleep"
          ? "Give practical sleep and recovery habits. Do not diagnose a sleep disorder; suggest a professional for persistent problems."
        : intent === "progress"
          ? "Answer using their weight trend, streak and averages. One imperfect day is not failure."
          : "Answer briefly and practically.")
        + timeSteer
        + (verdict.action === "allow" ? " " + followUpSteer(followUp) : "");

      const messages = [
        { role: "system" as const, content: COACH_SYSTEM },
        { role: "system" as const, content: steer },
        ...prior.reverse().map((m) => ({
          role: (m.role === "user" ? "user" : "assistant") as "user" | "assistant",
          content: m.content,
        })),
        { role: "user" as const, content: `${JSON.stringify(facts)}\n${question}` },
      ];

      let { text, usage } = await chat(messages, maxTokensFor(intent));
      const usages = [usage];

      /**
       * One retry when the answer is stock filler.
       *
       * "Have a balanced meal with protein, carbs and healthy fats" fits any
       * person on any day, which makes it worthless as coaching. Retrying with
       * a blunter instruction costs one cheap call and usually fixes it; a
       * second failure means the data genuinely isn't there to be specific
       * about, and the answer stands.
       */
      if (verdict.action === "allow" && safety.isGeneric(text)) {
        const retry = await chat([
          ...messages,
          { role: "assistant" as const, content: text },
          { role: "user" as const, content:
            "That was generic — it would fit anyone. Rewrite it using the actual numbers " +
            "in the context: what they ate, what's left, their steps, their trends. " +
            "If there isn't enough logged to be specific, say that instead." },
        ], maxTokensFor(intent));

        // Only take the retry if it is actually better.
        if (!safety.isGeneric(retry.text) && retry.text.trim().length > 0) {
          text = retry.text;
        }
        usages.push(retry.usage);
      }

      // Workouts and day plans are structured; everything else is trimmed to
      // keep the coach terse and the bill small.
      const cleaned = keepsStructure(intent)
        ? text.trim().slice(0, 1400)
        : text.replace(/\s+/g, " ").split(/(?<=[.!?])\s/).slice(0, 3).join(" ").trim().slice(0, 400);

      // Last line of defence: the model is instructed on medication and brands,
      // but instruction-following is probabilistic and these are the two places
      // where being wrong matters most.
      // Two independent checks: the older guard-based one and the safety
      // engine's. Both are deterministic, and either can replace the answer.
      const reply = safety.validate(cleaned, verdict)
        ?? validateResponse(cleaned, guard)
        ?? (cleaned || "Tell me a bit more and I'll help.");

      await q(`INSERT INTO coach_messages (user_id, role, content, intent)
               VALUES ($1,'user',$2,$4), ($1,'assistant',$3,$4)`,
        [req.userId, question, reply, intent]);

      // A card only when a meal was actually requested and actually given.
      const shouldSuggest =
        onTopic && guard === null &&
        // Never put a meal card next to a conversation about restriction or
        // disordered eating.
        !safety.suppressesRecommendations(verdict) &&
        intent === "meal_recommendation" &&
        !answerContainsRefusal(reply);

      const suggestion = shouldSuggest
        ? await suggestNextMeal(req.userId, req.tz, context)
        : null;

      return { value: { answer: reply, suggestion, intent }, usages };
    });

    return { ...answer, entitlements: await entitlementsFor(req.userId) };
  });

  /**
   * Next-meal suggestion with no AI call and no quota cost. Lets the dashboard
   * and an exhausted-allowance coach screen still be useful.
   */
  app.get("/coach/suggestion", { preHandler: requireAuth }, async (req) => {
    const context = await buildContext(req.userId, req.tz);
    return {
      suggestion: await suggestNextMeal(req.userId, req.tz, context),
      remaining: context.remaining ?? null,
      budget: context.budget ?? null,
    };
  });

  /**
   * One-line insight for the Home card. Deterministic, free, no quota — the
   * dashboard renders on every launch and must not cost an AI call.
   */
  app.get("/coach/insight", { preHandler: requireAuth }, async (req) => {
    const c = await buildContext(req.userId, req.tz);
    const remaining = c.remaining?.calories ?? 0;
    const proteinLeft = c.remaining?.protein_g ?? 0;
    const steps = c.steps ?? 0;

    let text: string;
    if ((c.today?.calories ?? 0) === 0) {
      text = "Nothing logged yet today — scan your first meal to start tracking.";
    } else if (remaining < 0) {
      text = `You're ${Math.abs(remaining)} calories over. A short walk this evening helps.`;
    } else if (proteinLeft > 40) {
      text = `${proteinLeft}g of protein left today. Lean meat, eggs or yogurt close the gap.`;
    } else if (steps > 0 && steps < 4000) {
      text = `${steps.toLocaleString()} steps so far. A 10-minute walk earns back some calories.`;
    } else if (c.streakDays >= 3) {
      text = `${c.streakDays} days logged in a row — that consistency is what moves the weight.`;
    } else {
      text = `${remaining} calories left today. You're on track.`;
    }

    return { insight: text, remaining: c.remaining ?? null };
  });

  app.get("/coach/history", { preHandler: requireAuth }, async (req) => ({
    messages: (await q(
      `SELECT role, content, created_at FROM coach_messages
        WHERE user_id = $1 ORDER BY created_at DESC LIMIT 40`, [req.userId])).reverse(),
  }));

  /** Free, non-AI prompts so the Coach screen is never an empty box. */
  app.get("/coach/suggestions", { preHandler: requireAuth }, async (req) => {
    const sub = await subscriptionFor(req.userId);
    const day = localDate(req.tz);
    const logged = await one<{ n: string }>(
      `SELECT COUNT(*) AS n FROM meals WHERE user_id = $1 AND logged_on = $2`, [req.userId, day]);

    const base = Number(logged?.n ?? 0) === 0
      ? ["What should I eat now?", "How do I start the day well?", "Why isn't my weight dropping?"]
      : ["Can I eat this?", "How many calories do I have left?", "I'm hungry at night.", "Why isn't my weight dropping?"];

    return { suggestions: base, plan: sub.plan };
  });

  // ── AI meal planner ───────────────────────────────────────────────────────
  app.post("/meal-plan", { preHandler: requireAuth }, async (req) => {
    const { span } = z.object({ span: z.enum(["day", "week"]).default("day") }).parse(req.body ?? {});

    const plan = await metered(req, "meal_plan", async () => {
      const context = await buildContext(req.userId, req.tz);
      const days = span === "week" ? 7 : 1;
      const start = localDate(req.tz);

      // A day plan built mid-afternoon must cover what's LEFT, not a fresh
      // 2,000 kcal on top of lunch. Weekly plans use the full daily budget
      // because every day after today starts empty.
      const remainingKcal = context.remaining?.calories ?? context.targets?.calories ?? 2000;
      const remainingProtein = context.remaining?.protein_g ?? context.targets?.protein_g ?? 120;
      const alreadyEaten = context.today?.calories ?? 0;
      const planningRestOfDay = span === "day" && alreadyEaten > 0;

      const budgetLine = planningRestOfDay
        ? `They have already eaten ${alreadyEaten} kcal today. Plan ONLY the remaining meals, totalling about ${remainingKcal} kcal and ${remainingProtein} g protein.`
        : `Daily target: ${context.targets?.calories ?? 2000} kcal, ${context.targets?.protein_g ?? 120} g protein.`;

      const prompt = [
        `Context: ${JSON.stringify(context)}`,
        `Build a ${days}-day plan starting ${start}.`,
        budgetLine,
        context.preferences?.allergies?.length
          ? `ALLERGIES — never include: ${context.preferences.allergies.join(", ")}.`
          : "",
      ].filter(Boolean).join("\n");

      const { text, usage } = await complete(MEAL_PLAN_SYSTEM, prompt, {
        json: true, maxTokens: span === "week" ? 1600 : 400,
      });

      const parsed = parseJson<any>(text);
      if (!parsed?.days?.length) {
        throw Object.assign(new ProviderError("plan_unavailable", [usage], false),
          { statusCode: 502, code: "plan_unavailable" });
      }

      const saved = await one<{ id: string }>(
        `INSERT INTO meal_plans (user_id, span, starts_on, plan) VALUES ($1,$2,$3,$4) RETURNING id`,
        [req.userId, span, start, JSON.stringify(parsed)]);

      return {
        value: {
          id: saved!.id, span, starts_on: start,
          // So the client can label it "rest of today" rather than "today".
          planned_for: planningRestOfDay ? "remaining_today" : "full_day",
          budget_kcal: planningRestOfDay ? remainingKcal : context.targets?.calories ?? 2000,
          ...parsed,
        },
        usages: [usage],
      };
    });

    return { ...plan, entitlements: await entitlementsFor(req.userId) };
  });

  app.get("/meal-plan/latest", { preHandler: requireAuth }, async (req) => {
    const row = await one<any>(
      `SELECT id, span, starts_on, plan FROM meal_plans
        WHERE user_id = $1 ORDER BY created_at DESC LIMIT 1`, [req.userId]);
    return row ? { id: row.id, span: row.span, starts_on: row.starts_on, ...row.plan } : { days: [] };
  });

  app.put("/preferences", { preHandler: requireAuth }, async (req) => {
    const p = z.object({
      diet: z.string().max(30).nullable().optional(),
      cuisines: z.array(z.string().max(30)).max(10).default([]),
      dislikes: z.array(z.string().max(40)).max(30).default([]),
      allergies: z.array(z.string().max(40)).max(20).default([]),
    }).parse(req.body);

    return one(
      `INSERT INTO food_preferences (user_id, diet, cuisines, dislikes, allergies)
       VALUES ($1,$2,$3,$4,$5)
       ON CONFLICT (user_id) DO UPDATE SET diet=EXCLUDED.diet, cuisines=EXCLUDED.cuisines,
         dislikes=EXCLUDED.dislikes, allergies=EXCLUDED.allergies, updated_at=now()
       RETURNING diet, cuisines, dislikes, allergies`,
      [req.userId, p.diet ?? null, p.cuisines, p.dislikes, p.allergies]);
  });

  app.get("/preferences", { preHandler: requireAuth }, async (req) =>
    (await one(`SELECT diet, cuisines, dislikes, allergies FROM food_preferences WHERE user_id = $1`,
      [req.userId])) ?? { diet: null, cuisines: [], dislikes: [], allergies: [] });

  // ── HealthKit ─────────────────────────────────────────────────────────────
  app.post("/health/daily", { preHandler: requireAuth }, async (req) => {
    const h = z.object({
      logged_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
      steps: z.number().int().min(0).max(200_000).optional(),
      active_kcal: z.number().int().min(0).max(20_000).optional(),
      resting_kcal: z.number().int().min(0).max(10_000).optional(),
      exercise_min: z.number().int().min(0).max(1440).optional(),
      distance_m: z.number().int().min(0).max(500_000).optional(),
      flights_climbed: z.number().int().min(0).max(2000).optional(),
    }).parse(req.body);

    const date = h.logged_on ?? localDate(req.tz);
    await recordActivity(req.userId, date, h);

    // Return the recomputed balance so the client doesn't need a second call.
    return activityFor(req.userId, req.tz, date);
  });

  app.get("/health/daily", { preHandler: requireAuth }, async (req) => {
    const { date } = z.object({
      date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
    }).parse(req.query);
    return activityFor(req.userId, req.tz, date);
  });

  app.get("/health/history", { preHandler: requireAuth }, async (req) => {
    const { days } = z.object({
      days: z.coerce.number().min(1).max(90).default(7),
    }).parse(req.query);
    return { days, entries: await activityHistory(req.userId, days) };
  });

  /** How much measured activity feeds back into the calorie budget. */
  app.put("/health/activity-credit", { preHandler: requireAuth }, async (req) => {
    const { mode } = z.object({ mode: z.enum(["off", "partial", "full"]) }).parse(req.body);
    await q(`UPDATE nutrition_targets SET activity_credit = $2, updated_at = now()
              WHERE user_id = $1`, [req.userId, mode]);
    return activityFor(req.userId, req.tz);
  });

  /**
   * Conversational fitness onboarding.
   *
   * The server decides the next question so it can skip anything SnapCal
   * already knows and anything made irrelevant by an earlier answer.
   */
  app.get("/coach/onboarding", { preHandler: requireAuth }, async (req) => {
    const [state, profile] = await Promise.all([
      onboardingState(req.userId),
      one<any>(`SELECT name, goal FROM profiles WHERE user_id = $1`, [req.userId]),
    ]);

    return {
      ...state,
      welcome: state.completed
        ? null
        : welcomeLine(profile?.name?.split(" ")[0], profile?.goal),
    };
  });

  app.post("/coach/onboarding", { preHandler: requireAuth }, async (req, reply) => {
    // `nullish` rather than `optional`: a client sending both keys will pass
    // null for the one it isn't using, and rejecting that stalls onboarding
    // mid-sequence with a validation error the user cannot act on.
    const { field, value, values, skip } = z.object({
      field: z.string().max(40),
      value: z.string().max(60).nullish(),
      values: z.array(z.string().max(60)).max(10).nullish(),
      skip: z.boolean().default(false),
    }).parse(req.body);

    // Ensure a row exists before any targeted update.
    await q(`INSERT INTO fitness_profile (user_id) VALUES ($1)
             ON CONFLICT (user_id) DO NOTHING`, [req.userId]);

    if (!skip) {
      switch (field) {
        case "primary_goal":
          await q(`UPDATE fitness_profile SET primary_goal = $2, updated_at = now()
                    WHERE user_id = $1`, [req.userId, value ?? null]);
          break;
        case "experience":
          await q(`UPDATE fitness_profile SET experience = $2, updated_at = now()
                    WHERE user_id = $1`, [req.userId, value ?? "unknown"]);
          break;
        case "training_location":
          await q(`UPDATE fitness_profile SET training_location = $2,
                          gym_access = ($2 IN ('gym','both')), updated_at = now()
                    WHERE user_id = $1`, [req.userId, value ?? null]);
          break;
        case "equipment_list":
          await q(`UPDATE fitness_profile SET equipment_list = $2, updated_at = now()
                    WHERE user_id = $1`, [req.userId, values ?? []]);
          break;
        case "training_days":
          await q(`UPDATE fitness_profile SET training_days = $2, updated_at = now()
                    WHERE user_id = $1`, [req.userId, Number(value) || 3]);
          break;
        case "session_minutes":
          await q(`UPDATE fitness_profile SET session_minutes = $2, updated_at = now()
                    WHERE user_id = $1`, [req.userId, Number(value) || 45]);
          break;
        case "average_sleep_hours":
          await q(`UPDATE fitness_profile SET average_sleep_hours = $2, updated_at = now()
                    WHERE user_id = $1`, [req.userId, Number(value) || null]);
          break;
        case "limitations_asked":
          await q(`UPDATE fitness_profile SET limitations = $2, updated_at = now()
                    WHERE user_id = $1`,
            [req.userId, (values ?? []).filter((v) => v !== "none")]);
          break;
        default:
          return reply.code(400).send({ error: "unknown_field", field });
      }
    }

    // Recorded even when skipped: the question was asked and answered, and it
    // must not come round again.
    await q(`UPDATE fitness_profile
                SET answered_fields = (
                      SELECT ARRAY(SELECT DISTINCT unnest(answered_fields || $2::text)))
              WHERE user_id = $1`, [req.userId, field]);

    const state = await onboardingState(req.userId);

    // The last answer completes the profile.
    if (!state.next && !state.completed) {
      await q(`UPDATE fitness_profile
                  SET profile_completed = true, completed_at = now()
                WHERE user_id = $1`, [req.userId]);
      return { ...(await onboardingState(req.userId)), justCompleted: true };
    }

    // `limitations_asked` is the final step; answering it finishes onboarding.
    if (field === "limitations_asked") {
      await q(`UPDATE fitness_profile
                  SET profile_completed = true, completed_at = now()
                WHERE user_id = $1`, [req.userId]);
      return { ...(await onboardingState(req.userId)), justCompleted: true };
    }

    return state;
  });

  /**
   * Structured workout the client can render as a card and log set by set.
   *
   * Separate from /coach/ask because the response is data, not prose — chat
   * text cannot be started, ticked off, or turned into history.
   */
  app.post("/coach/workout", { preHandler: requireAuth }, async (req) => {
    const opts = z.object({
      minutes: z.number().int().min(10).max(180).optional(),
      focus: z.enum(["upper", "lower", "full_body", "push", "pull",
                     "cardio", "mobility"]).optional(),
    }).parse(req.body ?? {});

    const plan = await metered(req, "coach", async () => {
      const context = await buildContext(req.userId, req.tz);
      const { plan, usage } = await generateWorkout(req.userId, context, {
        minutesOverride: opts.minutes,
        focusOverride: opts.focus,
      });

      const saved = await savePlan(req.userId, plan, localDate(req.tz));
      return { value: { id: saved?.id ?? null, ...plan }, usages: [usage] };
    });

    return { ...plan, entitlements: await entitlementsFor(req.userId) };
  });

  /** Patterns over recent history. Free — arithmetic, no model call. */
  app.get("/coach/patterns", { preHandler: requireAuth }, async (req) => ({
    patterns: await topPatterns(req.userId, 5),
  }));

  // ── training ──────────────────────────────────────────────────────────────
  // Without a training log the coach recommends the same session every day and
  // cannot suggest progression from real weights.

  app.get("/fitness/profile", { preHandler: requireAuth }, async (req) =>
    (await one(`SELECT gym_access, equipment, experience, training_days,
                       session_minutes, injuries
                  FROM fitness_profile WHERE user_id = $1`, [req.userId]))
    ?? { gym_access: false, equipment: "none", experience: "unknown",
         training_days: 3, session_minutes: 45, injuries: [] });

  app.put("/fitness/profile", { preHandler: requireAuth }, async (req) => {
    const p = z.object({
      gym_access: z.boolean().optional(),
      equipment: z.enum(["none", "bands", "dumbbells", "home_gym", "full_gym"]).optional(),
      experience: z.enum(["unknown", "beginner", "intermediate", "advanced"]).optional(),
      training_days: z.number().int().min(0).max(7).optional(),
      session_minutes: z.number().int().min(10).max(180).optional(),
      injuries: z.array(z.string().max(40)).max(10).optional(),
    }).parse(req.body);

    // Values go in the INSERT as well as the UPDATE: a first write does not
    // hit the conflict path, so a SET-only clause would silently store
    // defaults and discard everything the user just chose.
    return one(
      `INSERT INTO fitness_profile
         (user_id, gym_access, equipment, experience, training_days, session_minutes, injuries)
       VALUES ($1,
               COALESCE($2, false),
               COALESCE($3, 'none'),
               COALESCE($4, 'unknown'),
               COALESCE($5, 3),
               COALESCE($6, 45),
               COALESCE($7, '{}'::text[]))
       ON CONFLICT (user_id) DO UPDATE SET
         gym_access      = COALESCE($2, fitness_profile.gym_access),
         equipment       = COALESCE($3, fitness_profile.equipment),
         experience      = COALESCE($4, fitness_profile.experience),
         training_days   = COALESCE($5, fitness_profile.training_days),
         session_minutes = COALESCE($6, fitness_profile.session_minutes),
         injuries        = COALESCE($7, fitness_profile.injuries),
         updated_at      = now()
       RETURNING gym_access, equipment, experience, training_days, session_minutes, injuries`,
      [req.userId, p.gym_access ?? null, p.equipment ?? null, p.experience ?? null,
       p.training_days ?? null, p.session_minutes ?? null, p.injuries ?? null]);
  });

  app.post("/workouts", { preHandler: requireAuth }, async (req) => {
    const w = z.object({
      performed_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
      focus: z.enum(["upper", "lower", "full_body", "push", "pull",
                     "cardio", "mobility", "rest"]),
      minutes: z.number().int().min(1).max(360).optional(),
      perceived_effort: z.number().int().min(1).max(10).optional(),
      notes: z.string().max(300).optional(),
      /** Set when this session came from a generated plan. */
      plan_id: z.string().uuid().optional(),
      exercises: z.array(z.object({
        exercise: z.string().min(1).max(60),
        sets: z.number().int().min(1).max(20),
        reps: z.number().int().min(1).max(100).optional(),
        weight_kg: z.number().min(0).max(500).optional(),
      })).max(20).default([]),
    }).parse(req.body);

    const date = w.performed_on ?? localDate(req.tz);

    return tx(async (c) => {
      const { rows } = await c.query<{ id: string }>(
        `INSERT INTO workouts (user_id, performed_on, focus, minutes, perceived_effort, notes)
         VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
        [req.userId, date, w.focus, w.minutes ?? null,
         w.perceived_effort ?? null, w.notes ?? null]);

      const id = rows[0]!.id;

      // Close the loop: a completed session marks the plan it came from, so
      // the next recommendation knows it was actually done.
      if (w.plan_id) {
        await c.query(
          `UPDATE workout_plans SET workout_id = $1
            WHERE id = $2 AND user_id = $3`,
          [id, w.plan_id, req.userId]);
      }

      for (const [i, e] of w.exercises.entries()) {
        await c.query(
          `INSERT INTO workout_sets (workout_id, exercise, sets, reps, weight_kg, position)
           VALUES ($1,$2,$3,$4,$5,$6)`,
          [id, e.exercise.toLowerCase(), e.sets, e.reps ?? null, e.weight_kg ?? null, i]);
      }
      return { id, performed_on: date, focus: w.focus };
    });
  });

  app.get("/workouts", { preHandler: requireAuth }, async (req) => {
    const { days } = z.object({
      days: z.coerce.number().min(1).max(90).default(14),
    }).parse(req.query);

    return {
      days,
      workouts: await q(
        `SELECT w.id, w.performed_on, w.focus, w.minutes, w.perceived_effort, w.notes,
                COALESCE(json_agg(json_build_object(
                  'exercise', s.exercise, 'sets', s.sets,
                  'reps', s.reps, 'weight_kg', s.weight_kg
                ) ORDER BY s.position) FILTER (WHERE s.id IS NOT NULL), '[]') AS exercises
           FROM workouts w
           LEFT JOIN workout_sets s ON s.workout_id = w.id
          WHERE w.user_id = $1 AND w.performed_on > CURRENT_DATE - $2::int
          GROUP BY w.id
          ORDER BY w.performed_on DESC`,
        [req.userId, days]),
    };
  });

  app.delete("/workouts/:id", { preHandler: requireAuth }, async (req, reply) => {
    const { id } = z.object({ id: z.string().uuid() }).parse(req.params);
    const gone = await one(
      `DELETE FROM workouts WHERE id = $1 AND user_id = $2 RETURNING id`,
      [id, req.userId]);
    return gone ? { deleted: true } : reply.code(404).send({ error: "not_found" });
  });

  // ── notification preferences ──────────────────────────────────────────────
  app.get("/notifications/prefs", { preHandler: requireAuth }, async (req) =>
    (await one(`SELECT * FROM notification_prefs WHERE user_id = $1`, [req.userId])) ??
    (await one(`INSERT INTO notification_prefs (user_id, timezone) VALUES ($1,$2) RETURNING *`,
      [req.userId, req.tz])));

  app.put("/notifications/prefs", { preHandler: requireAuth }, async (req) => {
    const p = z.object({
      daily_coach: z.boolean().optional(),
      morning_hour: z.number().int().min(0).max(23).optional(),
      morning_minute: z.number().int().min(0).max(59).optional(),
      meal_reminders: z.boolean().optional(),
      food_logging: z.boolean().optional(),
      coach_reminder: z.boolean().optional(),
      premium_offers: z.boolean().optional(),
      quiet_start: z.string().regex(/^\d{2}:\d{2}$/).optional(),
      quiet_end: z.string().regex(/^\d{2}:\d{2}$/).optional(),
      daily_limit: z.number().int().min(0).max(10).optional(),
      muted_categories: z.array(z.string().max(20)).max(12).optional(),
      target_bedtime: z.string().regex(/^\d{2}:\d{2}$/).nullish(),
      target_wake_time: z.string().regex(/^\d{2}:\d{2}$/).nullish(),
      permission: z.enum(["undetermined", "granted", "denied"]).optional(),
    }).parse(req.body);

    // Values go in the INSERT as well as the UPDATE. A first write does not
    // hit the conflict path, so a SET-only clause silently stored defaults and
    // discarded everything the user just chose — quiet hours and the master
    // switch included.
    return one(
      `INSERT INTO notification_prefs
         (user_id, timezone, daily_coach, morning_hour, morning_minute,
          meal_reminders, food_logging, coach_reminder, premium_offers,
          permission, quiet_start, quiet_end, daily_limit, muted_categories,
          target_bedtime, target_wake_time)
       VALUES ($1, $2,
               COALESCE($3, true), COALESCE($4, 8), COALESCE($5, 0),
               COALESCE($6, true), COALESCE($7, true), COALESCE($8, false),
               COALESCE($9, true), COALESCE($10, 'undetermined'),
               COALESCE($11::time, '22:00'), COALESCE($12::time, '07:00'),
               COALESCE($13, 3), COALESCE($14, '{}'::text[]),
               $15::time, $16::time)
       ON CONFLICT (user_id) DO UPDATE SET
         daily_coach    = COALESCE($3, notification_prefs.daily_coach),
         morning_hour   = COALESCE($4, notification_prefs.morning_hour),
         morning_minute = COALESCE($5, notification_prefs.morning_minute),
         meal_reminders = COALESCE($6, notification_prefs.meal_reminders),
         food_logging   = COALESCE($7, notification_prefs.food_logging),
         coach_reminder = COALESCE($8, notification_prefs.coach_reminder),
         premium_offers = COALESCE($9, notification_prefs.premium_offers),
         permission     = COALESCE($10, notification_prefs.permission),
         quiet_start    = COALESCE($11::time, notification_prefs.quiet_start),
         quiet_end      = COALESCE($12::time, notification_prefs.quiet_end),
         daily_limit    = COALESCE($13, notification_prefs.daily_limit),
         muted_categories = COALESCE($14, notification_prefs.muted_categories),
         target_bedtime   = COALESCE($15::time, notification_prefs.target_bedtime),
         target_wake_time = COALESCE($16::time, notification_prefs.target_wake_time),
         timezone = $2, updated_at = now()
       RETURNING *`,
      [req.userId, req.tz, p.daily_coach ?? null, p.morning_hour ?? null, p.morning_minute ?? null,
       p.meal_reminders ?? null, p.food_logging ?? null, p.coach_reminder ?? null,
       p.premium_offers ?? null, p.permission ?? null,
       p.quiet_start ?? null, p.quiet_end ?? null, p.daily_limit ?? null,
       p.muted_categories ?? null, p.target_bedtime ?? null, p.target_wake_time ?? null]);
  });

  /**
   * Content for tomorrow's local morning notification. The app schedules it
   * locally, so no push infrastructure is needed for the daily case.
   */
  app.get("/notifications/morning", { preHandler: requireAuth }, async (req) => {
    const ctx = await buildContext(req.userId, req.tz);
    const first = ctx.name?.split(" ")[0];

    const lines = [
      `Your goal today: stay within ${ctx.targets?.calories ?? 2000} calories and hit ${ctx.targets?.protein_g ?? 120}g protein.`,
      ctx.streakDays >= 3
        ? `${ctx.streakDays} days logged in a row. Keep it going.`
        : "You're one day closer to your goal. Let's stay consistent today.",
      ctx.weightChangeKg != null && ctx.weightChangeKg < 0
        ? `Down ${Math.abs(ctx.weightChangeKg)}kg so far. Today's the same simple plan.`
        : "Ready to make progress today?",
    ];

    return {
      title: first ? `Good morning, ${first}` : "Good morning",
      body: lines[Math.floor(Date.now() / 864e5) % lines.length],
      deeplink: "snapcal://today",
    };
  });

  /** Live cheapest OpenRouter text models, for setting OPENROUTER_COACH_MODEL. */
  app.get("/admin/openrouter/models", { preHandler: requireAuth }, async (req, reply) => {
    if (!adminUserIds.has(req.userId)) return reply.code(404).send({ error: "not_found" });
    return cheapestModels();
  });

  /**
   * Provider self-test. Calls each configured AI provider with a minimal
   * request and reports the raw status, so a failing scan can be diagnosed
   * without reading container logs.
   */
  app.get("/admin/ai/selftest", { preHandler: requireAuth }, async (req, reply) => {
    if (!adminUserIds.has(req.userId)) return reply.code(404).send({ error: "not_found" });

    const results: Record<string, unknown> = {
      config: {
        ai_provider: cfg.AI_PROVIDER,
        vision_model: cfg.AI_MODEL,
        escalation_model: cfg.AI_ESCALATION_MODEL,
        openai_key_set: !!cfg.OPENAI_API_KEY,
        gemini_key_set: !!cfg.GEMINI_API_KEY,
        openrouter_key_set: !!cfg.OPENROUTER_API_KEY,
        openrouter_model: cfg.OPENROUTER_COACH_MODEL,
        usda_key_set: usdaKey !== "DEMO_KEY",
      },
    };

    // Vision path — a 1x1 JPEG is enough to prove auth and model availability.
    const pixel = Buffer.from(
      "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==",
      "base64"
    );
    try {
      const { usages } = await ai.primary().analyzeImage(pixel);
      results.vision = { ok: true, model: usages[0]?.model, cost_usd: usages[0]?.costUsd };
    } catch (e: any) {
      results.vision = {
        ok: false,
        message: e?.message,
        provider_status: e?.providerStatus ?? e?.status,
        provider_body: e?.providerBody,
      };
    }

    // Coach path — OpenRouter.
    try {
      const { text, usage } = await chat([{ role: "user", content: "Reply with the word ok." }], 10);
      results.coach = { ok: true, model: usage.model, reply: text.slice(0, 60), cost_usd: usage.costUsd };
    } catch (e: any) {
      results.coach = { ok: false, message: e?.message, provider_status: e?.status };
    }

    // USDA path.
    try {
      const hits = await searchUsdaMany("chicken breast", { limit: 1 });
      results.usda = { ok: hits.length > 0, first: hits[0]?.name ?? null };
    } catch (e: any) {
      results.usda = { ok: false, message: e?.message, code: e?.code };
    }

    return results;
  });

  // ── analytics ─────────────────────────────────────────────────────────────
  const EVENTS = new Set([
    "onboarding_completed", "healthkit_connected", "first_food_scan", "food_scan_completed",
    "coach_opened", "coach_question_sent", "meal_planner_opened", "meal_plan_generated",
    "free_limit_warning", "free_limit_reached", "paywall_viewed", "premium_cta_clicked",
    "purchase_started", "purchase_completed", "purchase_failed", "restore_purchase",
    "subscription_active", "subscription_cancelled", "notification_permission_granted",
    "notification_opened", "premium_notification_opened",
  ]);

  app.post("/analytics/events", { preHandler: requireAuth }, async (req, reply) => {
    const { events } = z.object({
      events: z.array(z.object({
        name: z.string().max(60),
        props: z.record(z.union([z.string(), z.number(), z.boolean()])).default({}),
      })).min(1).max(50),
    }).parse(req.body);

    const accepted = events.filter((e) => EVENTS.has(e.name));
    for (const e of accepted) {
      await q(`INSERT INTO analytics_events (user_id, name, props) VALUES ($1,$2,$3)`,
        [req.userId, e.name, JSON.stringify(e.props)]);
    }
    return reply.code(202).send({ accepted: accepted.length, rejected: events.length - accepted.length });
  });

  // ── weekly premium report ─────────────────────────────────────────────────
  app.get("/reports/weekly", { preHandler: requireAuth }, async (req, reply) => {
    const sub = await subscriptionFor(req.userId);
    if (sub.plan !== "pro") {
      return reply.code(402).send({
        error: "PREMIUM_REQUIRED", feature: "weekly_report", reason: "premium_only",
      });
    }

    const today = localDate(req.tz);
    const weekStart = daysAgo(today, 7);

    const cached = await one<any>(
      `SELECT metrics, insight FROM weekly_reports WHERE user_id = $1 AND week_start = $2`,
      [req.userId, weekStart]);
    if (cached) return { week_start: weekStart, ...cached.metrics, insight: cached.insight };

    const [nutrition, weights, health, targets] = await Promise.all([
      one<any>(`SELECT ROUND(AVG(d.cal))::int AS avg_calories, ROUND(AVG(d.pro))::int AS avg_protein,
                       COUNT(*)::int AS days_logged FROM (
                  SELECT m.logged_on, SUM(i.grams * i.kcal_100g / 100) cal,
                         SUM(i.grams * i.protein_100g / 100) pro
                    FROM meals m JOIN meal_items i ON i.meal_id = m.id
                   WHERE m.user_id = $1 AND m.logged_on >= $2 GROUP BY m.logged_on) d`,
        [req.userId, weekStart]),
      q<any>(`SELECT weight_kg FROM weight_logs WHERE user_id = $1 AND logged_on >= $2
               ORDER BY logged_on`, [req.userId, weekStart]),
      one<any>(`SELECT COALESCE(SUM(steps),0)::int AS steps, COALESCE(SUM(active_kcal),0)::int AS active
                  FROM health_daily WHERE user_id = $1 AND logged_on >= $2`, [req.userId, weekStart]),
      one<any>(`SELECT calories, protein_g FROM nutrition_targets WHERE user_id = $1`, [req.userId]),
    ]);

    const weightChange = weights.length > 1
      ? Math.round((weights.at(-1)!.weight_kg - weights[0].weight_kg) * 10) / 10 : null;
    const proteinPct = targets?.protein_g && nutrition?.avg_protein
      ? Math.round((nutrition.avg_protein / targets.protein_g) * 100) : null;

    const metrics = {
      weight_change_kg: weightChange,
      avg_calories: nutrition?.avg_calories ?? null,
      avg_protein_g: nutrition?.avg_protein ?? null,
      protein_pct_of_target: proteinPct,
      steps: health?.steps ?? 0,
      active_kcal: health?.active ?? 0,
      days_logged: nutrition?.days_logged ?? 0,
    };

    // Deterministic insight — no AI call, so the report costs nothing to open.
    let insight = "Keep logging this week so next week's report has more to work with.";
    if ((metrics.days_logged ?? 0) >= 4) {
      if (proteinPct != null && proteinPct < 85) {
        insight = "You're consistent on calories. Your biggest opportunity is more protein at breakfast.";
      } else if (weightChange != null && weightChange < 0) {
        insight = `Down ${Math.abs(weightChange)}kg and hitting your targets. Whatever you changed, keep it.`;
      } else if (targets?.calories && metrics.avg_calories && metrics.avg_calories > targets.calories) {
        insight = "You're averaging above target. Trimming evening portions is usually the easiest fix.";
      } else {
        insight = "Steady week. Consistency is doing the work — nothing to change.";
      }
    }

    await q(`INSERT INTO weekly_reports (user_id, week_start, metrics, insight)
             VALUES ($1,$2,$3,$4) ON CONFLICT (user_id, week_start) DO NOTHING`,
      [req.userId, weekStart, JSON.stringify(metrics), insight]);

    return { week_start: weekStart, ...metrics, insight };
  });
}
