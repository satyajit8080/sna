/**
 * What the user is asking for, and whether the request needs a guard rail.
 *
 * The coach answers nutrition, training, activity, hydration, sleep and
 * progress questions. Each needs different context, a different response
 * length, and — for medical and supplement questions — a hard boundary that
 * cannot be left to the model's discretion.
 *
 * Keyword-based on purpose: this runs on every message, and spending a model
 * call to label another model call would double the cost of the cheapest part
 * of the product.
 */

export type CoachIntent =
  | "meal_recommendation"   // "what should I eat", "suggest a food"
  | "food_analysis"         // "how many calories in what I ate"
  | "workout_request"       // "what workout today", "should I go to the gym"
  | "daily_plan"            // "what should I do today", "what should I improve"
  | "progress"              // "how am I doing", "why isn't my weight dropping"
  | "hydration"
  | "activity"              // steps, walking
  | "sleep"
  | "education"             // "how much protein do I need", general how/why
  | "general";

/** Requests that need a boundary regardless of what the model would say. */
export type CoachGuard =
  | "medical"       // diagnosis, medication, symptoms
  | "urgent"        // possible emergency
  | "brand"         // "which protein powder should I buy"
  | "live_data"     // "is this in stock in the Netherlands"
  | null;

type Rule = { intent: CoachIntent; patterns: string[] };

/**
 * Order matters: the first match wins, so more specific intents come first.
 */
const RULES: Rule[] = [
  {
    intent: "food_analysis",
    patterns: [
      "i ate", "i had", "i just ate", "i've eaten", "ive eaten", "did i eat",
      "how many calories in", "how much protein in", "calories did i",
      "what did i eat", "was that too much", "already logged",
    ],
  },
  {
    intent: "workout_request",
    patterns: [
      "workout", "work out", "gym", "train", "training", "exercise", "lift",
      "sets and reps", "leg day", "upper body", "lower body", "push day",
      "pull day", "cardio", "squat", "bench", "deadlift", "rest day",
      "should i rest", "muscle", "strength", "hypertrophy", "reps",
    ],
  },
  {
    intent: "daily_plan",
    patterns: [
      "what should i do today", "what should i do", "plan my day", "todays plan",
      "today's plan", "what should i improve", "what should i focus",
      "help me today", "coach me", "whats my plan", "what's my plan",
    ],
  },
  {
    intent: "meal_recommendation",
    patterns: [
      "what should i eat", "what can i eat", "what do i eat", "what to eat",
      "suggest", "recommend", "give me a", "give me one", "what food",
      "which food", "what fruit", "which fruit", "what snack", "which snack",
      "what meal", "which meal", "something to eat", "for dinner", "for lunch",
      "for breakfast", "high protein meal", "under ", "fits my",
    ],
  },
  {
    intent: "hydration",
    patterns: ["water", "hydrat", "drink", "fluid", "thirsty"],
  },
  {
    intent: "activity",
    patterns: ["steps", "walk", "walking", "sedentary", "move more"],
  },
  {
    intent: "sleep",
    patterns: ["sleep", "slept", "bedtime", "insomnia", "nap", "rest better"],
  },
  {
    intent: "progress",
    patterns: [
      "how am i doing", "am i on track", "why isn't", "why isnt", "why is my",
      "my weight", "losing weight", "gaining weight", "progress", "streak",
      "plateau", "stalled", "how much left", "calories left", "remaining",
    ],
  },
  {
    intent: "education",
    patterns: [
      "how much protein", "how many calories should", "what is", "what are",
      "how does", "why does", "explain", "difference between", "is it better",
      "how do i lose", "how do i gain", "how can i",
    ],
  },
];

const MEDICAL = [
  "medicine", "medication", "tablet", "pill", "prescription", "prescribe",
  "antibiotic", "insulin", "dosage", "diagnos", "disease",
  "infection", "thyroid", "diabetes", "blood pressure", "side effect",
  "should i stop taking",
];

const URGENT = [
  "chest pain", "can't breathe", "cant breathe", "difficulty breathing",
  "fainted", "fainting", "passed out", "severe pain", "bleeding heavily",
  "allergic reaction", "anaphyla", "numb on one side", "slurred speech",
];

const BRAND = [
  "which brand", "what brand", "best brand", "which protein powder",
  "what protein powder", "which supplement", "what supplement",
  "should i buy", "recommend a brand", "which product",
];

const LIVE_DATA = [
  "in stock", "available in", "available at", "price of", "how much does it cost",
  "open right now", "which store", "which restaurant", "todays price",
  "today's price", "delivery",
];

/** Anything the coach can legitimately talk about. */
const ON_TOPIC = [
  "eat", "food", "meal", "calorie", "protein", "carb", "fat", "fibre", "fiber",
  "diet", "weight", "hungry", "snack", "breakfast", "lunch", "dinner", "fruit",
  "veg", "drink", "water", "sugar", "workout", "exercise", "step", "walk",
  "gym", "nutrition", "portion", "serving", "cook", "recipe", "muscle", "fit",
  "train", "sleep", "energy", "health", "habit", "routine", "goal",
  "progress", "cardio", "strength", "recovery", "rest", "stretch", "mobility",
  "improve", "plan", "today", "body", "lose", "gain",
];

export function classify(question: string): CoachIntent {
  const q = question.toLowerCase().trim();
  for (const rule of RULES) {
    if (rule.patterns.some((p) => q.includes(p))) return rule.intent;
  }
  return "general";
}

export function guardFor(question: string): CoachGuard {
  const q = question.toLowerCase();
  if (URGENT.some((k) => q.includes(k))) return "urgent";
  if (MEDICAL.some((k) => q.includes(k))) return "medical";
  if (BRAND.some((k) => q.includes(k))) return "brand";
  if (LIVE_DATA.some((k) => q.includes(k))) return "live_data";
  return null;
}

export function isOnTopic(question: string): boolean {
  const q = question.toLowerCase();
  return ON_TOPIC.some((k) => q.includes(k));
}

/**
 * Token budget per intent.
 *
 * A workout needs the full session; "how many calories left" needs a line.
 * Charging a workout-sized budget for every question would multiply the coach
 * bill for no benefit.
 */
export function maxTokensFor(intent: CoachIntent): number {
  switch (intent) {
    case "workout_request": return 420;
    case "daily_plan":      return 320;
    case "education":       return 220;
    case "progress":        return 160;
    default:                return 120;
  }
}

/** Structured answers keep their line breaks; conversational ones get trimmed. */
export function keepsStructure(intent: CoachIntent): boolean {
  return intent === "workout_request" || intent === "daily_plan";
}

/**
 * A card must not accompany an answer that declined to recommend anything.
 */
export function answerContainsRefusal(answer: string): boolean {
  const a = answer.toLowerCase();
  return [
    "scanned or searched", "scan or search", "need it scanned",
    "need the food scanned", "search for it first", "log it first",
    "i can't verify", "i cannot verify", "can only help with",
  ].some((k) => a.includes(k));
}

/**
 * Post-response check.
 *
 * The model is told not to name supplement brands or advise on medication, but
 * instruction-following is probabilistic and these are the two places where
 * being wrong matters most. Returns a replacement when a line is crossed.
 */
export function validateResponse(answer: string, guard: CoachGuard): string | null {
  const a = answer.toLowerCase();

  if (guard === "urgent") {
    return "That sounds like it needs proper medical attention — please contact emergency services or a doctor now rather than waiting.";
  }

  // Naming a dose is prescribing, whatever the framing around it.
  if (/\b\d+\s?(mg|mcg|iu)\b/.test(a) && /(take|dose|daily|twice|per day)/.test(a)) {
    return "I can't advise on medication or doses — a doctor or pharmacist is the right person for that. I'm glad to help with food, training or recovery instead.";
  }

  return null;
}
