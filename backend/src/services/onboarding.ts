import { q, one } from "../db.js";

/**
 * Screen-based onboarding.
 *
 * The existing engine asked one question at a time, which suits a short
 * fitness setup and is punishing across forty fields. This groups related
 * questions into screens a person can finish in half a minute, and — more
 * importantly — decides which screens to show at all.
 *
 * Two rules drive everything here:
 *
 *   Never ask what we already know. Age, height and weight come from the
 *   nutrition profile; sleep duration comes from HealthKit once there is data.
 *   Asking again tells the user the app is not paying attention.
 *
 *   Never ask what would not change the coaching. Every field below earns its
 *   place by altering a recommendation, a safety check, or a reminder.
 */

export type FieldType =
  | "text" | "number" | "time" | "chips" | "chips_multi"
  | "toggle" | "slider" | "list";

export type Field = {
  key: string;
  label: string;
  type: FieldType;
  options?: Array<{ value: string; label: string }>;
  placeholder?: string;
  optional?: boolean;
  /** Shown under the field. Used sparingly — mostly to say why we're asking. */
  hint?: string;
  min?: number;
  max?: number;
  unit?: string;
};

export type Screen = {
  id: string;
  title: string;
  subtitle?: string;
  fields: Field[];
  /** Whole screen skippable. Everything sensitive is. */
  skippable: boolean;
};

export type OnboardingPlan = {
  screens: Screen[];
  currentIndex: number;
  totalScreens: number;
  completed: boolean;
};

type Known = {
  hasProfile: boolean;
  hasSleepData: boolean;
  hasFitnessProfile: boolean;
  exercises: boolean | null;
  takesMedication: boolean | null;
  completedScreens: string[];
};

/** Present on every sensitive screen. */
const PREFER_NOT = { value: "prefer_not_to_say", label: "Prefer not to say" };

// ─── screen definitions ─────────────────────────────────────────────────────

const ABOUT_YOU: Screen = {
  id: "about_you",
  title: "About you",
  subtitle: "The basics your coach needs to get anything else right.",
  skippable: false,
  fields: [
    { key: "name", label: "What should I call you?", type: "text", placeholder: "First name" },
    { key: "birth_year", label: "Year of birth", type: "number", min: 1920, max: 2015 },
    { key: "sex", label: "Sex", type: "chips",
      // Affects calorie and protein targets, which is the only reason it is here.
      hint: "Used for your calorie and protein targets.",
      options: [{ value: "male", label: "Male" }, { value: "female", label: "Female" },
                { value: "other", label: "Other" }] },
    { key: "height_cm", label: "Height", type: "number", unit: "cm", min: 100, max: 250 },
    { key: "start_weight_kg", label: "Current weight", type: "number", unit: "kg", min: 30, max: 300 },
    { key: "work_type", label: "Most of your day is…", type: "chips", optional: true,
      options: [
        { value: "desk", label: "At a desk" }, { value: "standing", label: "On my feet" },
        { value: "physical", label: "Physical work" }, { value: "shift", label: "Shift work" },
        { value: "student", label: "Studying" }, { value: "other", label: "Something else" },
      ] },
  ],
};

const YOUR_DAY: Screen = {
  id: "your_day",
  title: "Your day",
  subtitle: "So advice fits your actual routine, not a generic one.",
  skippable: true,
  fields: [
    { key: "typical_bedtime", label: "Usual bedtime", type: "time" },
    { key: "typical_wake_time", label: "Usual wake time", type: "time" },
    { key: "sleep_quality", label: "How do you usually sleep?", type: "chips",
      options: [
        { value: "good", label: "Well" }, { value: "mixed", label: "Mixed" },
        { value: "poor", label: "Badly" }, PREFER_NOT,
      ] },
    { key: "activity_level", label: "A normal day is…", type: "chips",
      options: [
        { value: "sedentary", label: "Mostly sitting" },
        { value: "mixed", label: "A bit of both" },
        { value: "active", label: "On the move" },
      ] },
  ],
};

const MOVEMENT: Screen = {
  id: "movement",
  title: "Movement",
  subtitle: "What you already do, so I can build on it rather than replace it.",
  skippable: true,
  fields: [
    { key: "exercises", label: "Do you exercise at the moment?", type: "toggle" },
    { key: "activities", label: "What do you do?", type: "chips_multi",
      options: [
        { value: "gym", label: "Gym" }, { value: "walking", label: "Walking" },
        { value: "running", label: "Running" }, { value: "cycling", label: "Cycling" },
        { value: "swimming", label: "Swimming" }, { value: "yoga", label: "Yoga" },
        { value: "sport", label: "Sport" }, { value: "home", label: "Home workouts" },
      ] },
    { key: "training_days", label: "Days a week", type: "slider", min: 1, max: 7 },
    { key: "experience", label: "How long have you been training?", type: "chips",
      options: [
        { value: "beginner", label: "Just starting" },
        { value: "intermediate", label: "A while now" },
        { value: "advanced", label: "Years" },
      ] },
    { key: "limitations", label: "Anything I should program around?", type: "chips_multi",
      optional: true,
      hint: "Injuries or movements you avoid.",
      options: [
        { value: "none", label: "Nothing" }, { value: "knees", label: "Knees" },
        { value: "lower back", label: "Lower back" }, { value: "shoulders", label: "Shoulders" },
        { value: "wrists", label: "Wrists" }, { value: "neck", label: "Neck" },
      ] },
  ],
};

const NUTRITION: Screen = {
  id: "nutrition",
  title: "Food",
  subtitle: "I'll learn the detail from your scans — this is just the shape of it.",
  skippable: true,
  fields: [
    { key: "diet", label: "How do you eat?", type: "chips",
      options: [
        { value: "omnivore", label: "Everything" }, { value: "vegetarian", label: "Vegetarian" },
        { value: "vegan", label: "Vegan" }, { value: "pescatarian", label: "Pescatarian" },
        { value: "halal", label: "Halal" }, { value: "kosher", label: "Kosher" },
      ] },
    { key: "allergies", label: "Allergies or intolerances", type: "list", optional: true,
      placeholder: "Add one at a time",
      // The one field here with a safety consequence, so it is asked plainly.
      hint: "I'll never suggest a food containing these." },
    { key: "dislikes", label: "Anything you'd rather not eat?", type: "list", optional: true },
    { key: "meals_per_day", label: "Meals on a normal day", type: "slider", min: 1, max: 6 },
    { key: "eats_late", label: "Do you often eat after 9pm?", type: "toggle", optional: true },
  ],
};

const HEALTH: Screen = {
  id: "health",
  title: "Health",
  subtitle: "Only what helps me keep advice safe. Skip anything you'd rather not share.",
  skippable: true,
  fields: [
    { key: "conditions", label: "Anything I should know about?", type: "list", optional: true,
      placeholder: "e.g. asthma",
      // Framed as constraint, not diagnosis — which is exactly how it is used.
      hint: "I use this to avoid suggesting something unsuitable. I can't diagnose or treat anything." },
    { key: "restriction", label: "Has a doctor told you to avoid anything?", type: "text",
      optional: true, placeholder: "Foods, activities, exercises" },
  ],
};

const MEDICATIONS: Screen = {
  id: "medications",
  title: "Medications & supplements",
  subtitle: "For reminders and context. I'll never advise on doses.",
  skippable: true,
  fields: [
    { key: "takes_medication", label: "Do you take any medication?", type: "chips",
      options: [
        { value: "no", label: "No" }, { value: "yes", label: "Yes" }, PREFER_NOT,
      ] },
    { key: "medications", label: "Add them", type: "list", optional: true,
      placeholder: "Name — and when you take it",
      hint: "Only for reminders. Changes are always a conversation with your doctor." },
    { key: "supplements", label: "Any supplements?", type: "list", optional: true,
      placeholder: "e.g. vitamin D, creatine" },
  ],
};

const MIND: Screen = {
  id: "mind",
  title: "How things feel",
  subtitle: "Sleep, stress and mood pull on each other. Knowing helps me ask less of you on the hard days.",
  skippable: true,
  fields: [
    { key: "stress_level", label: "Stress, usually", type: "chips",
      options: [
        { value: "low", label: "Low" }, { value: "moderate", label: "Moderate" },
        { value: "high", label: "High" }, { value: "variable", label: "Varies a lot" },
        PREFER_NOT,
      ] },
    { key: "usual_mood", label: "Mood, usually", type: "chips",
      options: [
        { value: "positive", label: "Good" }, { value: "okay", label: "Okay" },
        { value: "up_and_down", label: "Up and down" }, { value: "often_low", label: "Often low" },
        PREFER_NOT,
      ] },
    { key: "coping", label: "What actually helps you?", type: "chips_multi", optional: true,
      // The most actionable field on this screen: suggesting a walk to someone
      // who finds walks helpful is a different proposition from suggesting it
      // cold.
      hint: "I'll lean on these when things are hard.",
      options: [
        { value: "exercise", label: "Exercise" }, { value: "walking", label: "Walking" },
        { value: "music", label: "Music" }, { value: "meditation", label: "Meditation" },
        { value: "sleep", label: "Sleep" }, { value: "talking", label: "Talking to someone" },
        { value: "alone", label: "Time alone" }, { value: "outdoors", label: "Being outside" },
      ] },
  ],
};

const GOALS: Screen = {
  id: "goals",
  title: "What matters most",
  subtitle: "Pick the one thing. I'll keep the rest in mind.",
  skippable: false,
  fields: [
    { key: "primary_goal", label: "The main thing", type: "chips",
      options: [
        { value: "lose_weight", label: "Lose weight" },
        { value: "build_muscle", label: "Build muscle" },
        { value: "improve_sleep", label: "Sleep better" },
        { value: "more_energy", label: "More energy" },
        { value: "eat_better", label: "Eat better" },
        { value: "exercise_consistently", label: "Train consistently" },
        { value: "reduce_stress", label: "Less stress" },
        { value: "general_health", label: "General health" },
      ] },
    { key: "secondary_goals", label: "Anything else?", type: "chips_multi", optional: true,
      options: [
        { value: "lose_weight", label: "Lose weight" },
        { value: "build_muscle", label: "Build muscle" },
        { value: "improve_sleep", label: "Sleep better" },
        { value: "more_energy", label: "More energy" },
        { value: "eat_better", label: "Eat better" },
        { value: "reduce_stress", label: "Less stress" },
      ] },
    { key: "success_looks_like", label: "How would you know this was working?",
      type: "text", optional: true,
      placeholder: "e.g. waking up without hitting snooze",
      // Their own words, and worth more than any checkbox — it says what
      // success actually means to them.
      hint: "In your words. I'll come back to this." },
  ],
};

const ALL_SCREENS = [ABOUT_YOU, YOUR_DAY, MOVEMENT, NUTRITION,
                     HEALTH, MEDICATIONS, MIND, GOALS];

// ─── adaptation ─────────────────────────────────────────────────────────────

async function whatWeKnow(userId: string): Promise<Known> {
  const [profile, sleep, fitness, medication, progress] = await Promise.all([
    one<any>(`SELECT name, birth_year, height_cm FROM profiles WHERE user_id = $1`, [userId]),
    one<any>(`SELECT COUNT(*)::int AS n FROM health_observations
               WHERE user_id = $1 AND metric = 'sleep_minutes'`, [userId]),
    one<any>(`SELECT experience, training_days FROM fitness_profile WHERE user_id = $1`, [userId]),
    one<any>(`SELECT COUNT(*)::int AS n FROM medications WHERE user_id = $1`, [userId]),
    one<any>(`SELECT completed_screens, skipped_screens FROM onboarding_progress
               WHERE user_id = $1`, [userId]),
  ]);

  return {
    hasProfile: !!profile?.name && !!profile?.birth_year,
    // Five nights is enough to trust HealthKit over a self-reported estimate.
    hasSleepData: (sleep?.n ?? 0) >= 5,
    hasFitnessProfile: !!fitness?.experience && fitness.experience !== "unknown",
    exercises: null,
    takesMedication: (medication?.n ?? 0) > 0 ? true : null,
    completedScreens: [
      ...(progress?.completed_screens ?? []),
      ...(progress?.skipped_screens ?? []),
    ],
  };
}

/**
 * Tailors a screen to this user, or removes it entirely.
 *
 * Returning null means the screen never appears — which is the point. Someone
 * who does not exercise should not scroll past four training questions to
 * confirm it.
 */
function adapt(screen: Screen, known: Known, answers: Record<string, any>): Screen | null {
  if (known.completedScreens.includes(screen.id)) return null;

  const fields = screen.fields.filter((field) => {
    // Anything the nutrition profile already holds.
    if (known.hasProfile &&
        ["name", "birth_year", "sex", "height_cm", "start_weight_kg"].includes(field.key)) {
      return false;
    }

    // HealthKit measures sleep better than memory does.
    if (known.hasSleepData && field.key === "typical_sleep_minutes") return false;

    // No point asking how they train if they said they don't.
    if (answers.exercises === false &&
        ["activities", "training_days", "experience", "limitations"].includes(field.key)) {
      return false;
    }

    // Medication detail only follows a yes.
    if (field.key === "medications" && answers.takes_medication !== "yes") return false;

    return true;
  });

  if (fields.length === 0) return null;

  /**
   * A whole screen for one optional question is not worth the tap.
   *
   * Once the known fields are removed, "About you" can be left holding nothing
   * but an optional occupation question — a page someone has to dismiss for no
   * benefit. A single *required* field still earns its screen.
   */
  if (fields.length === 1 && fields[0]!.optional) return null;

  // Everything on this screen is already known.
  if (screen.id === "movement" && known.hasFitnessProfile) return null;

  return { ...screen, fields };
}

export async function onboardingPlan(
  userId: string,
  answers: Record<string, any> = {}
): Promise<OnboardingPlan> {
  const known = await whatWeKnow(userId);

  const screens = ALL_SCREENS
    .map((screen) => adapt(screen, known, answers))
    .filter((screen): screen is Screen => screen !== null);

  return {
    screens,
    currentIndex: 0,
    totalScreens: screens.length,
    completed: screens.length === 0,
  };
}

/**
 * Writes one screen's answers to wherever they belong.
 *
 * Deliberately spread across existing tables rather than a blob: the coach,
 * the safety engine and the notification engine all read this data through
 * their own queries, and a JSON column would make every one of them worse.
 */
export async function saveScreen(
  userId: string,
  screenId: string,
  answers: Record<string, any>
): Promise<void> {
  switch (screenId) {
    case "about_you":
      await q(
        `UPDATE profiles SET
           name = COALESCE($2, name),
           birth_year = COALESCE($3, birth_year),
           sex = COALESCE($4, sex),
           height_cm = COALESCE($5, height_cm),
           start_weight_kg = COALESCE($6, start_weight_kg),
           work_type = COALESCE($7, work_type),
           updated_at = now()
         WHERE user_id = $1`,
        [userId, answers.name ?? null, answers.birth_year ?? null, answers.sex ?? null,
         answers.height_cm ?? null, answers.start_weight_kg ?? null, answers.work_type ?? null]);
      break;

    case "your_day":
      await q(
        `INSERT INTO daily_schedule
           (user_id, typical_bedtime, typical_wake_time, sleep_quality, activity_level)
         VALUES ($1, $2::time, $3::time, $4, $5)
         ON CONFLICT (user_id) DO UPDATE SET
           typical_bedtime   = COALESCE($2::time, daily_schedule.typical_bedtime),
           typical_wake_time = COALESCE($3::time, daily_schedule.typical_wake_time),
           sleep_quality     = COALESCE($4, daily_schedule.sleep_quality),
           activity_level    = COALESCE($5, daily_schedule.activity_level),
           updated_at = now()`,
        [userId, answers.typical_bedtime ?? null, answers.typical_wake_time ?? null,
         answers.sleep_quality ?? null, answers.activity_level ?? null]);

      // The bedtime reminder should follow their real bedtime, not a default.
      if (answers.typical_bedtime) {
        await q(
          `INSERT INTO notification_prefs (user_id, target_bedtime, target_wake_time)
           VALUES ($1, $2::time, $3::time)
           ON CONFLICT (user_id) DO UPDATE SET
             target_bedtime = COALESCE($2::time, notification_prefs.target_bedtime),
             target_wake_time = COALESCE($3::time, notification_prefs.target_wake_time)`,
          [userId, answers.typical_bedtime, answers.typical_wake_time ?? null]);
      }
      break;

    case "movement":
      await q(
        `INSERT INTO fitness_profile
           (user_id, experience, training_days, gym_access, equipment_list, limitations)
         VALUES ($1, COALESCE($2,'unknown'), COALESCE($3,3),
                 COALESCE($4,false), COALESCE($5,'{}'::text[]), COALESCE($6,'{}'::text[]))
         ON CONFLICT (user_id) DO UPDATE SET
           experience     = COALESCE($2, fitness_profile.experience),
           training_days  = COALESCE($3, fitness_profile.training_days),
           gym_access     = COALESCE($4, fitness_profile.gym_access),
           equipment_list = COALESCE($5, fitness_profile.equipment_list),
           limitations    = COALESCE($6, fitness_profile.limitations),
           updated_at = now()`,
        [userId, answers.experience ?? null, answers.training_days ?? null,
         (answers.activities ?? []).includes("gym"),
         answers.activities ?? null,
         (answers.limitations ?? []).filter((l: string) => l !== "none")]);
      break;

    case "nutrition":
      await q(
        `INSERT INTO food_preferences
           (user_id, diet, allergies, dislikes, meals_per_day, eats_late)
         VALUES ($1,$2,COALESCE($3,'{}'::text[]),COALESCE($4,'{}'::text[]),$5,$6)
         ON CONFLICT (user_id) DO UPDATE SET
           diet          = COALESCE($2, food_preferences.diet),
           allergies     = COALESCE($3, food_preferences.allergies),
           dislikes      = COALESCE($4, food_preferences.dislikes),
           meals_per_day = COALESCE($5, food_preferences.meals_per_day),
           eats_late     = COALESCE($6, food_preferences.eats_late)`,
        [userId, answers.diet ?? null, answers.allergies ?? null,
         answers.dislikes ?? null, answers.meals_per_day ?? null,
         answers.eats_late ?? null]);

      // Allergies are a safety constraint, so they are stored twice on purpose:
      // once as a food preference, once where the safety engine reads them.
      for (const allergen of answers.allergies ?? []) {
        await q(
          `INSERT INTO user_allergies (user_id, allergen, kind)
           VALUES ($1,$2,'food') ON CONFLICT DO NOTHING`, [userId, allergen]);
      }
      break;

    case "health":
      for (const condition of answers.conditions ?? []) {
        await q(
          `INSERT INTO health_conditions (user_id, condition, restriction)
           VALUES ($1,$2,$3)
           ON CONFLICT (user_id, condition)
           DO UPDATE SET restriction = COALESCE(EXCLUDED.restriction,
                                                health_conditions.restriction)`,
          [userId, condition, answers.restriction ?? null]);
      }
      // A restriction with no named condition is still worth keeping.
      if (answers.restriction && !(answers.conditions ?? []).length) {
        await q(
          `INSERT INTO health_conditions (user_id, condition, restriction)
           VALUES ($1,'unspecified',$2) ON CONFLICT (user_id, condition)
           DO UPDATE SET restriction = EXCLUDED.restriction`,
          [userId, answers.restriction]);
      }
      break;

    case "medications":
      for (const entry of answers.medications ?? []) {
        await q(
          `INSERT INTO medications (user_id, name, kind) VALUES ($1,$2,'medication')`,
          [userId, typeof entry === "string" ? entry : entry.name]);
      }
      for (const entry of answers.supplements ?? []) {
        await q(
          `INSERT INTO medications (user_id, name, kind) VALUES ($1,$2,'supplement')`,
          [userId, typeof entry === "string" ? entry : entry.name]);
      }
      break;

    case "mind":
      await q(
        `INSERT INTO mind_profile (user_id, stress_level, usual_mood, stressors, coping)
         VALUES ($1,$2,$3,COALESCE($4,'{}'::text[]),COALESCE($5,'{}'::text[]))
         ON CONFLICT (user_id) DO UPDATE SET
           stress_level = COALESCE($2, mind_profile.stress_level),
           usual_mood   = COALESCE($3, mind_profile.usual_mood),
           stressors    = COALESCE($4, mind_profile.stressors),
           coping       = COALESCE($5, mind_profile.coping),
           updated_at = now()`,
        [userId, answers.stress_level ?? null, answers.usual_mood ?? null,
         answers.stressors ?? null, answers.coping ?? null]);
      break;

    case "goals":
      await q(
        `UPDATE profiles SET
           primary_goal = COALESCE($2, primary_goal),
           secondary_goals = COALESCE($3, secondary_goals),
           success_looks_like = COALESCE($4, success_looks_like),
           updated_at = now()
         WHERE user_id = $1`,
        [userId, answers.primary_goal ?? null, answers.secondary_goals ?? null,
         answers.success_looks_like ?? null]);
      break;
  }

  await q(
    `INSERT INTO onboarding_progress (user_id, completed_screens)
     VALUES ($1, ARRAY[$2]::text[])
     ON CONFLICT (user_id) DO UPDATE SET
       completed_screens = (
         SELECT ARRAY(SELECT DISTINCT unnest(onboarding_progress.completed_screens || $2::text))),
       updated_at = now()`,
    [userId, screenId]);
}

export async function skipScreen(userId: string, screenId: string): Promise<void> {
  await q(
    `INSERT INTO onboarding_progress (user_id, skipped_screens)
     VALUES ($1, ARRAY[$2]::text[])
     ON CONFLICT (user_id) DO UPDATE SET
       skipped_screens = (
         SELECT ARRAY(SELECT DISTINCT unnest(onboarding_progress.skipped_screens || $2::text))),
       updated_at = now()`,
    [userId, screenId]);
}

export async function finishOnboarding(userId: string): Promise<void> {
  await q(
    `INSERT INTO onboarding_progress (user_id, finished_at)
     VALUES ($1, now())
     ON CONFLICT (user_id) DO UPDATE SET finished_at = now(), updated_at = now()`,
    [userId]);
}
