import { one } from "../db.js";

/**
 * Conversational fitness onboarding.
 *
 * The server decides what to ask next rather than the client walking a fixed
 * form. Two reasons: the question set depends on answers already given (no
 * point asking about equipment when they train nowhere), and anything SnapCal
 * already knows from the nutrition profile must never be asked again.
 *
 * One question at a time, with selectable options, because a wall of fields is
 * where onboarding completion goes to die.
 */

export type OnboardingOption = { value: string; label: string };

export type OnboardingQuestion = {
  field: string;
  question: string;
  /** Empty for free-text or numeric answers. */
  options: OnboardingOption[];
  multiSelect: boolean;
  /** Steps answered so far, and total, for a progress indicator. */
  step: number;
  total: number;
  skippable: boolean;
};

type ProfileRow = {
  primary_goal: string | null;
  experience: string;
  training_location: string | null;
  equipment_list: string[];
  training_days: number | null;
  session_minutes: number | null;
  average_sleep_hours: string | null;
  limitations: string[];
  profile_completed: boolean;
  answered_fields: string[];
};

/**
 * Required in order. `activity_level` is deliberately absent: the nutrition
 * profile already collected it, and asking twice signals the app isn't paying
 * attention.
 */
const SEQUENCE: Array<{
  field: keyof ProfileRow | "limitations_asked";
  question: string;
  options: OnboardingOption[];
  multiSelect?: boolean;
  skippable?: boolean;
  /** Skip the question entirely when this returns true. */
  skipWhen?: (p: ProfileRow) => boolean;
}> = [
  {
    field: "primary_goal",
    question: "What are you working toward?",
    options: [
      { value: "lose_weight", label: "Lose weight" },
      { value: "lose_fat_keep_muscle", label: "Lose fat, keep muscle" },
      { value: "build_muscle", label: "Build muscle" },
      { value: "gain_weight", label: "Gain weight" },
      { value: "improve_strength", label: "Get stronger" },
      { value: "improve_fitness", label: "Improve fitness" },
      { value: "maintain", label: "Maintain" },
      { value: "general_health", label: "General health" },
    ],
  },
  {
    field: "experience",
    question: "How much training experience do you have?",
    options: [
      { value: "beginner", label: "Beginner" },
      { value: "intermediate", label: "Intermediate" },
      { value: "advanced", label: "Advanced" },
    ],
  },
  {
    field: "training_location",
    question: "Where will you train?",
    options: [
      { value: "gym", label: "Gym" },
      { value: "home", label: "Home" },
      { value: "both", label: "Both" },
      { value: "none", label: "Nowhere regular" },
    ],
  },
  {
    field: "equipment_list",
    question: "What do you have access to?",
    options: [
      { value: "full_gym", label: "Full gym" },
      { value: "dumbbells", label: "Dumbbells" },
      { value: "barbell", label: "Barbell" },
      { value: "machines", label: "Machines" },
      { value: "bands", label: "Resistance bands" },
      { value: "cardio", label: "Cardio machines" },
      { value: "bodyweight", label: "Bodyweight only" },
    ],
    multiSelect: true,
    // Nothing to ask when they train nowhere regular.
    skipWhen: (p) => p.training_location === "none",
  },
  {
    field: "training_days",
    question: "How many days a week can you realistically train?",
    options: [1, 2, 3, 4, 5, 6].map((n) => ({
      value: String(n),
      label: n === 1 ? "1 day" : `${n} days`,
    })),
    skipWhen: (p) => p.training_location === "none",
  },
  {
    field: "session_minutes",
    question: "How long is a typical session?",
    options: [
      { value: "25", label: "15–30 min" },
      { value: "40", label: "30–45 min" },
      { value: "55", label: "45–60 min" },
      { value: "75", label: "60+ min" },
    ],
    skipWhen: (p) => p.training_location === "none",
  },
  {
    field: "average_sleep_hours",
    question: "Roughly how much sleep do you get on a normal night?",
    options: [
      { value: "5", label: "Under 6 hours" },
      { value: "6.5", label: "6–7 hours" },
      { value: "7.5", label: "7–8 hours" },
      { value: "8.5", label: "8+ hours" },
    ],
    skippable: true,
  },
  {
    field: "limitations_asked",
    question: "Anything I should program around — injuries, or movements you avoid?",
    options: [
      { value: "none", label: "Nothing to avoid" },
      { value: "knees", label: "Knees" },
      { value: "lower back", label: "Lower back" },
      { value: "shoulders", label: "Shoulders" },
      { value: "wrists", label: "Wrists" },
      { value: "neck", label: "Neck" },
    ],
    multiSelect: true,
    skippable: true,
  },
];

async function load(userId: string): Promise<ProfileRow> {
  const row = await one<ProfileRow>(
    `SELECT primary_goal, experience, training_location, equipment_list,
            training_days, session_minutes, average_sleep_hours, limitations,
            profile_completed, answered_fields
       FROM fitness_profile WHERE user_id = $1`,
    [userId]
  );

  return row ?? {
    primary_goal: null, experience: "unknown", training_location: null,
    equipment_list: [], training_days: null, session_minutes: null,
    average_sleep_hours: null, limitations: [], profile_completed: false,
    answered_fields: [],
  };
}

/**
 * Whether a field still needs an answer.
 *
 * `answered_fields` is authoritative. Inferring from the stored value cannot
 * work for columns with a NOT NULL default — "3 training days" is
 * indistinguishable from "never asked" — which made onboarding loop on the
 * same question.
 */
function isAnswered(field: string, p: ProfileRow): boolean {
  if (p.answered_fields.includes(field)) return true;

  // A value set outside onboarding still counts, so an existing user is not
  // asked something they have already told us.
  switch (field) {
    case "primary_goal":        return p.primary_goal != null;
    case "experience":          return p.experience !== "unknown";
    case "training_location":   return p.training_location != null;
    case "equipment_list":      return p.equipment_list.length > 0;
    case "average_sleep_hours": return p.average_sleep_hours != null;
    default:                    return false;
  }
}

export type OnboardingState = {
  completed: boolean;
  /** Null once nothing is left to ask. */
  next: OnboardingQuestion | null;
  answered: number;
  total: number;
};

export async function onboardingState(userId: string): Promise<OnboardingState> {
  const profile = await load(userId);

  const applicable = SEQUENCE.filter((q) => !q.skipWhen?.(profile));
  const total = applicable.length;
  const pending = applicable.filter((q) => !isAnswered(q.field as string, profile));
  const answered = total - pending.length;

  if (profile.profile_completed || pending.length === 0) {
    return { completed: true, next: null, answered: total, total };
  }

  const q = pending[0]!;
  return {
    completed: false,
    answered,
    total,
    next: {
      field: q.field as string,
      question: q.question,
      options: q.options,
      multiSelect: q.multiSelect ?? false,
      step: answered + 1,
      total,
      skippable: q.skippable ?? false,
    },
  };
}

/** The opening line, which reflects what SnapCal already knows. */
export function welcomeLine(name: string | undefined, goal: string | undefined): string {
  const who = name ? `, ${name}` : "";
  if (goal === "lose") {
    return `Good to meet you${who}. I've got your calorie targets already — a few questions about training and I can start planning your days properly.`;
  }
  return `Good to meet you${who}. A few quick questions and I can start planning around your goal.`;
}
