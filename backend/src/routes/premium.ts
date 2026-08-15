import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { q, one } from "../db.js";
import { requireAuth } from "../middleware/auth.js";
import { adminUserIds } from "../config.js";
import { ai, ProviderError, type Usage } from "../ai/index.js";
import { COACH_SYSTEM, MEAL_PLAN_SYSTEM } from "../ai/prompts.js";
import { buildContext, complete, parseJson } from "../services/coachContext.js";
import { chat, cheapestModels } from "../ai/openrouter.js";
import { suggestNextMeal } from "../services/suggest.js";
import { activityFor, recordActivity, activityHistory } from "../services/activity.js";
import {
  entitlementsFor, reserve, settle, release, subscriptionFor,
  type Reservation,
} from "../services/entitlements.js";
import { localDate, daysAgo } from "../util/dates.js";

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

    const answer = await metered(req, "coach", async () => {
      const context = await buildContext(req.userId, req.tz);

      // Only the last exchange is replayed. Full history would grow the bill
      // linearly with no benefit for single-turn coaching questions.
      const prior = await q<{ role: string; content: string }>(
        `SELECT role, content FROM coach_messages WHERE user_id = $1
          ORDER BY created_at DESC LIMIT 2`, [req.userId]);

      // Only the numbers the coach can actually use. Sending the whole context
      // object would triple the token bill for answers that are one line long.
      const activity = await activityFor(req.userId, req.tz);
      const facts = {
        remaining_kcal: context.remaining?.calories,
        remaining_protein_g: context.remaining?.protein_g,
        target_kcal: context.targets?.calories,
        eaten_kcal: context.today?.calories,
        steps: activity.steps,
        burned_kcal: activity.credited_kcal,
        weight_kg: context.currentWeightKg,
        goal_kg: context.goalWeightKg,
        change_kg: context.weightChangeKg,
        streak_days: context.streakDays,
      };

      const messages = [
        { role: "system" as const, content: COACH_SYSTEM },
        ...prior.reverse().map((m) => ({
          role: (m.role === "user" ? "user" : "assistant") as "user" | "assistant",
          content: m.content,
        })),
        { role: "user" as const, content: `${JSON.stringify(facts)}\n${question}` },
      ];

      const { text, usage } = await chat(messages, 60);

      // Enforce one line server-side. A cheap model will occasionally ignore
      // the instruction, and the UI is built for a single sentence.
      const reply = text
        .replace(/\s+/g, " ")
        .split(/(?<=[.!?])\s/)[0]
        ?.trim()
        .slice(0, 200)
        || "Log a meal and ask again — I need today's numbers first.";

      await q(`INSERT INTO coach_messages (user_id, role, content) VALUES ($1,'user',$2), ($1,'assistant',$3)`,
        [req.userId, question, reply]);

      // Resolved from the nutrition database, not a second model call: the
      // macros are exact, so the client can log it in one tap with no
      // confirmation round-trip and no extra cost.
      const suggestion = await suggestNextMeal(req.userId, req.tz, context);

      return { value: { answer: reply, suggestion }, usages: [usage] };
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
      permission: z.enum(["undetermined", "granted", "denied"]).optional(),
    }).parse(req.body);

    return one(
      `INSERT INTO notification_prefs (user_id, timezone) VALUES ($1,$2)
       ON CONFLICT (user_id) DO UPDATE SET
         daily_coach    = COALESCE($3, notification_prefs.daily_coach),
         morning_hour   = COALESCE($4, notification_prefs.morning_hour),
         morning_minute = COALESCE($5, notification_prefs.morning_minute),
         meal_reminders = COALESCE($6, notification_prefs.meal_reminders),
         food_logging   = COALESCE($7, notification_prefs.food_logging),
         coach_reminder = COALESCE($8, notification_prefs.coach_reminder),
         premium_offers = COALESCE($9, notification_prefs.premium_offers),
         permission     = COALESCE($10, notification_prefs.permission),
         timezone = $2, updated_at = now()
       RETURNING *`,
      [req.userId, req.tz, p.daily_coach ?? null, p.morning_hour ?? null, p.morning_minute ?? null,
       p.meal_reminders ?? null, p.food_logging ?? null, p.coach_reminder ?? null,
       p.premium_offers ?? null, p.permission ?? null]);
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
