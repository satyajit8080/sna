import { q, one } from "../db.js";

/**
 * The first AI Coach conversation.
 *
 * Onboarding established a baseline. This is where the coach goes deeper — and
 * the one thing it must never do is ask again. A user who has just told the
 * app they sleep at 11pm and wake at 6:30 should not be asked what time they
 * sleep; that undoes the goodwill onboarding just earned.
 *
 * So the opener quotes what is already known, and every topic chip carries a
 * question that starts from that knowledge rather than from zero.
 */

export type WelcomeTopic = {
  id: string;
  label: string;
  /** The question asked when this topic is chosen — always built from context. */
  opener: string;
  /** Skipped when there is nothing known to build on. */
  available: boolean;
};

export type CoachWelcome = {
  /** Null once the user has had this conversation. */
  greeting: string | null;
  knows: string[];
  topics: WelcomeTopic[];
  seen: boolean;
};

function timeLabel(value: unknown): string | null {
  if (!value) return null;
  const raw = String(value).slice(0, 5);
  const parts = raw.split(":").map(Number);
  const h = parts[0], m = parts[1] ?? 0;
  if (h == null || Number.isNaN(h)) return null;

  const hour12 = h % 12 === 0 ? 12 : h % 12;
  return `${hour12}${m ? `:${String(m).padStart(2, "0")}` : ""}${h < 12 ? "am" : "pm"}`;
}

const GOAL_LABEL: Record<string, string> = {
  lose_weight: "losing weight",
  build_muscle: "building muscle",
  improve_sleep: "sleeping better",
  more_energy: "having more energy",
  eat_better: "eating better",
  exercise_consistently: "training consistently",
  reduce_stress: "less stress",
  general_health: "general health",
};

export async function coachWelcome(userId: string): Promise<CoachWelcome> {
  const [profile, schedule, fitness, food, mind, messages] = await Promise.all([
    one<any>(`SELECT name, primary_goal, success_looks_like FROM profiles WHERE user_id = $1`, [userId]),
    one<any>(`SELECT typical_bedtime, typical_wake_time, sleep_quality, activity_level
                FROM daily_schedule WHERE user_id = $1`, [userId]),
    one<any>(`SELECT experience, training_days, equipment_list FROM fitness_profile WHERE user_id = $1`, [userId]),
    one<any>(`SELECT diet, allergies FROM food_preferences WHERE user_id = $1`, [userId]),
    one<any>(`SELECT stress_level, coping FROM mind_profile WHERE user_id = $1`, [userId]),
    one<any>(`SELECT COUNT(*)::int AS n FROM coach_messages WHERE user_id = $1`, [userId]),
  ]);

  // One exchange is enough to count as met.
  const seen = (messages?.n ?? 0) > 0;

  const bedtime = timeLabel(schedule?.typical_bedtime);
  const wake = timeLabel(schedule?.typical_wake_time);

  /** What the coach can say it already knows. Only genuinely-known things. */
  const knows: string[] = [];
  if (bedtime && wake) knows.push(`you're usually asleep around ${bedtime} and up by ${wake}`);
  if (fitness?.training_days) knows.push(`you're training about ${fitness.training_days} days a week`);
  if (profile?.primary_goal) knows.push(`${GOAL_LABEL[profile.primary_goal] ?? "your goal"} is the priority`);
  if (food?.diet && food.diet !== "omnivore") knows.push(`you eat ${food.diet}`);

  const firstName = profile?.name?.split(" ")[0];

  const greeting = seen ? null : [
    firstName ? `Hi ${firstName} 👋` : "Hi 👋",
    knows.length
      ? `I've picked up a few things already — ${knows.slice(0, 2).join(", and ")}.`
      : "We haven't got much history yet, so I'll learn as we go.",
    "There's a lot I can't tell from data alone though. Anything you'd like me to understand?",
  ].join("\n\n");

  /**
   * Topic openers.
   *
   * Each starts from something already known, because the point of this
   * conversation is depth. A topic with nothing to build on is hidden rather
   * than asked cold.
   */
  const topics: WelcomeTopic[] = [
    {
      id: "sleep", label: "My sleep 😴",
      available: !!(bedtime && wake),
      opener: bedtime && wake
        ? `I know you're usually down around ${bedtime} and up by ${wake}. When you wake up, do you generally feel rested, or still tired?`
        : "How does sleep usually go for you?",
    },
    {
      id: "goals", label: "My goals 🎯",
      available: !!profile?.primary_goal,
      opener: profile?.success_looks_like
        ? `You said you'd know this was working when ${profile.success_looks_like.replace(/^I /, "you ").toLowerCase()}. What's made that hard before?`
        : profile?.primary_goal
          ? `${(GOAL_LABEL[profile.primary_goal] ?? "That")[0]!.toUpperCase()}${(GOAL_LABEL[profile.primary_goal] ?? "that").slice(1)} — what's got in the way of that previously?`
          : "What are you hoping to change?",
    },
    {
      id: "fitness", label: "My training 🏃",
      available: !!fitness?.training_days,
      opener: fitness?.training_days
        ? `${fitness.training_days} days a week is a decent rhythm. Which of those is hardest to actually make happen?`
        : "How does training fit into your week?",
    },
    {
      id: "food", label: "My food 🥗",
      available: true,
      opener: food?.diet && food.diet !== "omnivore"
        ? `You eat ${food.diet} — what does a normal weekday of eating look like for you?`
        : "What does a normal weekday of eating look like for you?",
    },
    {
      id: "stress", label: "Stress 🧠",
      available: !!mind?.stress_level && mind.stress_level !== "prefer_not_to_say",
      opener: mind?.coping?.length
        ? `You mentioned ${mind.coping[0]} helps when things get heavy. What usually tips you into that?`
        : "What tends to make a week feel heavy for you?",
    },
    {
      id: "routine", label: "My days 🕐",
      available: !!schedule?.activity_level,
      opener: "Walk me through a normal day — where does it usually fall apart?",
    },
    {
      id: "other", label: "Something else 💬",
      available: true,
      opener: "Go ahead — what should I know?",
    },
  ].filter((t) => t.available);

  return { greeting, knows, topics, seen };
}

/**
 * Facts worth keeping from this conversation.
 *
 * Deliberately narrow: onboarding answers are already stored, and re-saving a
 * paraphrase of them would pollute the brain with near-duplicates of things it
 * already knows precisely.
 */
export async function recordWelcomeReply(
  userId: string, topic: string, reply: string
): Promise<void> {
  const { consolidate } = await import("./brain.js");

  const subject = {
    sleep: "sleep_experience",
    goals: "goal_motivation",
    fitness: "training_barrier",
    food: "eating_pattern",
    stress: "stress_coping",
    routine: "daily_barrier",
  }[topic];

  if (!subject) return;

  // Their own words, trimmed. Paraphrasing here would lose the thing that
  // makes it worth storing.
  const content = reply.trim().slice(0, 180);
  if (content.length < 8) return;

  await consolidate(userId, {
    layer: "semantic",
    subject,
    content,
    // Told to us directly, so it starts higher than anything inferred.
    confidence: 0.8,
  });
}
