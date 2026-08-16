import { one, q } from "../db.js";
import { complete, parseJson } from "./coachContext.js";
import type { CoachContext } from "./coachContext.js";
import { WORKOUT_SYSTEM } from "../ai/prompts.js";
import type { Usage } from "../ai/types.js";

/**
 * Structured workouts, so the client can render a card the user can actually
 * work through — start, log each set, finish — rather than a wall of chat text
 * they have to retype into a log.
 *
 * The model chooses exercises and rep ranges; the *weights* come from what the
 * user has already lifted. A model inventing a starting weight is how someone
 * gets hurt, so progression is computed here from real history.
 */

export type PlannedExercise = {
  exercise_name: string;
  sets: number;
  reps: string;              // "8-12" — a range, not a false precision
  rest_seconds: number;
  /** Suggested load, only ever derived from logged history. */
  suggested_weight_kg: number | null;
  /** Why this weight — shown so the number is never mysterious. */
  progression_note: string | null;
  instructions: string;
  targets: string;
};

export type WorkoutPlan = {
  workout_title: string;
  goal: string;
  focus: string;
  duration_minutes: number;
  warmup: string[];
  exercises: PlannedExercise[];
  optional_cardio: string | null;
  cooldown: string[];
  coach_note: string;
};

/** Rotate focus so the same muscles are not trained two sessions running. */
export function nextFocus(recent: Array<{ focus: string; date: string }>, trainingDays: number): string {
  const last = recent[0]?.focus;
  const lastTwo = recent.slice(0, 2).map((w) => w.focus);

  // Fewer than three sessions a week is better served by full-body work than
  // by a split that trains each muscle once a fortnight.
  if (trainingDays <= 2) return last === "full_body" ? "full_body" : "full_body";

  if (trainingDays >= 5) {
    if (last === "push") return "pull";
    if (last === "pull") return "lower";
    if (last === "lower") return "push";
    return "push";
  }

  if (last === "upper") return "lower";
  if (last === "lower") return "upper";
  if (lastTwo.includes("full_body")) return "upper";
  return "full_body";
}

/**
 * Whether today should be recovery instead.
 *
 * Recommending rest is a real recommendation. A coach that only ever says
 * "train" is not reading the data.
 */
export function needsRecovery(recent: Array<{ date: string; effort: number | null }>): boolean {
  if (recent.length < 3) return false;

  const dates = recent.map((w) => w.date).sort().reverse();
  let consecutive = 1;
  for (let i = 1; i < dates.length; i++) {
    const gap = (new Date(dates[i - 1]!).getTime() - new Date(dates[i]!).getTime()) / 864e5;
    if (gap === 1) consecutive++;
    else break;
  }
  if (consecutive >= 4) return true;

  const recentHard = recent.slice(0, 3).filter((w) => (w.effort ?? 0) >= 8).length;
  return recentHard >= 3;
}

/**
 * Suggested load for an exercise, from what they actually lifted.
 *
 * Progression is one variable at a time: add reps within the range first, and
 * only nudge weight once the top of the range was reached. Never more than
 * ~5%, and never a number for an exercise with no history.
 */
export async function suggestLoad(
  userId: string,
  exercise: string
): Promise<{ weight: number | null; note: string | null }> {
  const history = await q<{ weight_kg: string | null; reps: number | null; sets: number }>(
    `SELECT s.weight_kg, s.reps, s.sets
       FROM workout_sets s
       JOIN workouts w ON w.id = s.workout_id
      WHERE w.user_id = $1 AND lower(s.exercise) = lower($2)
        AND s.weight_kg IS NOT NULL
      ORDER BY w.performed_on DESC
      LIMIT 3`,
    [userId, exercise]
  );

  if (history.length === 0) {
    return {
      weight: null,
      note: "No history for this one — start light and find a weight you can control for all sets.",
    };
  }

  const last = history[0]!;
  const weight = Number(last.weight_kg);
  const reps = last.reps ?? 0;

  // Hit the top of the range twice → small increase. Otherwise hold and add
  // reps, which is the cheaper and safer progression.
  const repeatedTop = history.length >= 2
    && (history[1]!.reps ?? 0) >= 12
    && reps >= 12;

  if (repeatedTop) {
    const next = Math.round(weight * 1.05 * 2) / 2;   // nearest 0.5kg
    return {
      weight: next,
      note: `Up from ${weight}kg — you hit the top of the range twice.`,
    };
  }

  return {
    weight,
    note: `Same ${weight}kg as last time. Add a rep or two before adding weight.`,
  };
}

export async function generateWorkout(
  userId: string,
  context: CoachContext,
  opts: { minutesOverride?: number; focusOverride?: string } = {}
): Promise<{ plan: WorkoutPlan; usage: Usage }> {
  const fitness = context.fitness;
  const recent = (context.recentWorkouts ?? []).map((w) => ({
    focus: w.focus, date: w.date, effort: w.effort,
  }));

  const trainingDays = fitness?.trainingDays ?? 3;
  const minutes = opts.minutesOverride ?? fitness?.sessionMinutes ?? 45;
  const recovery = needsRecovery(recent);
  const focus = opts.focusOverride
    ?? (recovery ? "mobility" : nextFocus(recent, trainingDays));

  const prompt = [
    `Goal: ${fitness?.experience ?? "unknown"} lifter, primary goal ${context.goal ?? "general health"}.`,
    `Equipment: ${(fitness?.equipment ?? "bodyweight")}.`,
    fitness?.injuries?.length
      ? `MUST AVOID loading these areas: ${fitness.injuries.join(", ")}.`
      : "",
    `Session focus: ${focus}. Time available: ${minutes} minutes.`,
    recent.length
      ? `Recent sessions (newest first): ${recent.map((w) => `${w.date} ${w.focus}`).join("; ")}.`
      : "No training logged yet — keep it simple and teachable.",
    recovery
      ? "They have trained hard several days running. Program a genuine recovery session: mobility, light cardio, no heavy loading."
      : "",
    "Do NOT include weights or loads. Give sets and rep ranges only.",
  ].filter(Boolean).join("\n");

  const { text, usage } = await complete(WORKOUT_SYSTEM, prompt, {
    json: true,
    maxTokens: 700,
  });

  const parsed = parseJson<any>(text);
  if (!parsed?.exercises?.length) {
    throw Object.assign(new Error("workout_unavailable"), {
      statusCode: 502, code: "workout_unavailable",
    });
  }

  // Weights are attached here, from history — never from the model.
  const exercises: PlannedExercise[] = [];
  for (const e of parsed.exercises.slice(0, 10)) {
    const name = String(e.exercise_name ?? e.name ?? "").slice(0, 60);
    if (!name) continue;

    const { weight, note } = recovery
      ? { weight: null, note: null }
      : await suggestLoad(userId, name);

    exercises.push({
      exercise_name: name,
      sets: Math.min(Math.max(Number(e.sets) || 3, 1), 10),
      reps: String(e.reps ?? "8-12").slice(0, 20),
      rest_seconds: Math.min(Math.max(Number(e.rest_seconds) || 60, 15), 300),
      suggested_weight_kg: weight,
      progression_note: note,
      instructions: String(e.instructions ?? "").slice(0, 200),
      targets: String(e.targets ?? "").slice(0, 60),
    });
  }

  const plan: WorkoutPlan = {
    workout_title: String(parsed.workout_title ?? "Today's Session").slice(0, 60),
    goal: String(parsed.goal ?? context.goal ?? "general health").slice(0, 60),
    focus,
    duration_minutes: minutes,
    warmup: (parsed.warmup ?? []).slice(0, 5).map((w: any) => String(w).slice(0, 120)),
    exercises,
    optional_cardio: parsed.optional_cardio ? String(parsed.optional_cardio).slice(0, 200) : null,
    cooldown: (parsed.cooldown ?? []).slice(0, 5).map((c: any) => String(c).slice(0, 120)),
    coach_note: String(parsed.coach_note ?? "").slice(0, 300),
  };

  return { plan, usage };
}

/** Persist a generated plan so it can be started and completed later. */
export async function savePlan(userId: string, plan: WorkoutPlan, date: string) {
  return one<{ id: string }>(
    `INSERT INTO workout_plans (user_id, plan, focus, minutes, generated_on)
     VALUES ($1,$2,$3,$4,$5) RETURNING id`,
    [userId, JSON.stringify(plan), plan.focus, plan.duration_minutes, date]
  );
}
