/**
 * What the user is actually asking for.
 *
 * The coach previously attached a meal card to every answer, including ones
 * that said "I'll need a food scanned first" — a card and a refusal on screen
 * at the same time. Classifying the request means a recommendation card only
 * appears when a recommendation was requested.
 *
 * Deliberately keyword-based, not a model call: this runs on every question,
 * and spending a second AI request to label the first would double the cost of
 * the cheapest part of the product.
 */
export type CoachIntent =
  | "recommendation"   // "what should I eat", "suggest a food"
  | "analysis"         // "how many calories in what I ate"
  | "progress"         // "how am I doing", "why isn't my weight dropping"
  | "general";         // anything else on-topic

const RECOMMENDATION = [
  "what should i eat", "what can i eat", "what do i eat", "what to eat",
  "suggest", "recommend", "recommendation", "give me a", "give me one",
  "what food", "which food", "what fruit", "which fruit", "what snack",
  "which snack", "what meal", "which meal", "ideas for", "options for",
  "something to eat", "high protein", "low calorie", "under ", "fits my",
  "what's good", "whats good", "what should i have", "for dinner",
  "for lunch", "for breakfast", "post workout", "pre workout",
];

const ANALYSIS = [
  "i ate", "i had", "i just ate", "i've eaten", "ive eaten", "did i eat",
  "how many calories in", "how much protein in", "calories did i",
  "what did i eat", "is this ok", "was that", "logged",
];

const PROGRESS = [
  "how am i doing", "am i on track", "why isn't", "why isnt", "why is my",
  "my weight", "losing weight", "gaining", "progress", "streak",
  "how many calories do i have", "how much left", "remaining",
];

/** Food and nutrition words — used to spot genuinely off-topic questions. */
const ON_TOPIC = [
  "eat", "food", "meal", "calorie", "protein", "carb", "fat", "fibre", "fiber",
  "diet", "weight", "hungry", "snack", "breakfast", "lunch", "dinner", "fruit",
  "veg", "drink", "water", "sugar", "workout", "exercise", "step", "walk",
  "gym", "fast", "nutrition", "portion", "serving", "cook", "recipe",
];

export function classify(question: string): CoachIntent {
  const q = question.toLowerCase().trim();

  // Analysis wins over recommendation: "what should I eat, I already had eggs"
  // is still a recommendation, but "how many calories in what I ate" is not.
  if (ANALYSIS.some((k) => q.includes(k)) && !RECOMMENDATION.some((k) => q.includes(k))) {
    return "analysis";
  }
  if (RECOMMENDATION.some((k) => q.includes(k))) return "recommendation";
  if (PROGRESS.some((k) => q.includes(k))) return "progress";
  return "general";
}

/**
 * Whether the question has anything to do with food, health or progress.
 * "President of Australia" should get a short redirect, not a calorie total.
 */
export function isOnTopic(question: string): boolean {
  const q = question.toLowerCase();
  return ON_TOPIC.some((k) => q.includes(k));
}

/**
 * Guards against a card contradicting the words above it.
 *
 * If the model still hedges — "I'd need that scanned" — no recommendation was
 * actually made, so no card should render regardless of intent.
 */
export function answerContainsRefusal(answer: string): boolean {
  const a = answer.toLowerCase();
  return [
    "scanned or searched", "scan or search", "need it scanned",
    "need the food scanned", "search for it first", "log it first",
    "i don't have", "i do not have", "can only help with",
  ].some((k) => a.includes(k));
}
