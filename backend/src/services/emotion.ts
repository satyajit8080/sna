/**
 * Emotional intelligence.
 *
 * The coach had ten intents and every one of them was a task. Someone saying
 * "I'm exhausted and everything feels like too much" got routed to nutrition
 * advice, which is the wrong answer delivered confidently — worse than no
 * answer at all.
 *
 * This detects emotional weight in a message and changes what the coach does
 * with it: acknowledge first, ask at most one question, and hold back the
 * advice until there is some understanding of what actually happened.
 *
 * Deliberately conservative. Reading distress into an ordinary message is its
 * own failure — being solemn at someone who is fine is patronising.
 */

export type EmotionalState =
  | "exhausted"      // physically or mentally spent
  | "overwhelmed"    // too much at once
  | "frustrated"     // effort not producing results
  | "discouraged"    // ready to give up on the goal
  | "anxious"        // worried about health or a result
  | "low"            // flat mood, no energy for anything
  | "positive"       // something went well
  | null;

export type EmotionalRead = {
  state: EmotionalState;
  /** How strongly this reads as emotional rather than informational. */
  intensity: "high" | "moderate" | "low";
  /**
   * Whether the message is primarily about how they feel rather than a
   * request for information. Decides whether advice waits.
   */
  needsAcknowledgement: boolean;
};

type Pattern = { state: Exclude<EmotionalState, null>; strong: RegExp[]; soft: RegExp[] };

const PATTERNS: Pattern[] = [
  {
    state: "overwhelmed",
    strong: [
      /\b(everything|it all|this all)\s+(is\s+)?(too much|falling apart)\b/i,
      /\b(can'?t|cannot)\s+(cope|keep up|do this)\b/i,
      /\bdrowning\b/i,
      /\bfalling behind on everything\b/i,
    ],
    soft: [/\boverwhelm/i, /\btoo much (going on|to do)\b/i, /\bspread thin\b/i],
  },
  {
    state: "exhausted",
    strong: [
      /\b(completely|totally|so) (exhausted|drained|wiped)\b/i,
      /\brunning on empty\b/i,
      /\bno energy (left|at all)\b/i,
    ],
    soft: [/\bexhaust/i, /\bknackered\b/i, /\bshattered\b/i, /\bworn out\b/i,
           /\bdrained\b/i, /\breally tired\b/i, /\bso tired\b/i],
  },
  {
    state: "discouraged",
    strong: [
      /\b(giving|give) up\b/i,
      /\bwhat'?s the point\b/i,
      /\bnothing (is )?work(ing|s)\b/i,
      /\bnever going to\b/i,
      /\bwasting my time\b/i,
    ],
    soft: [/\bnot working\b/i, /\bno progress\b/i, /\bfeel like quitting\b/i,
           /\bdiscouraged\b/i, /\blosing motivation\b/i],
  },
  {
    state: "frustrated",
    strong: [/\b(so|really|incredibly) frustrat/i, /\bfed up\b/i, /\bsick of\b/i],
    soft: [/\bfrustrat/i, /\bannoying\b/i, /\bstuck\b/i],
  },
  {
    state: "anxious",
    strong: [
      /\b(really|very|so) (worried|anxious|scared)\b/i,
      /\bcan'?t stop (worrying|thinking about)\b/i,
      /\bpanic/i,
    ],
    soft: [/\bworried\b/i, /\banxious\b/i, /\bnervous about\b/i, /\bstressed\b/i],
  },
  {
    state: "low",
    strong: [/\b(really|so) (down|low|sad)\b/i, /\bmiserable\b/i,
             /\bcan'?t be bothered with anything\b/i],
    soft: [/\bfeeling (down|low|flat|rubbish|awful)\b/i, /\bno motivation\b/i,
           /\brough day\b/i, /\bbad day\b/i],
  },
  {
    state: "positive",
    strong: [/\b(really|so) (pleased|proud|happy)\b/i, /\bbest week\b/i,
             /\bfeeling great\b/i],
    soft: [/\bwent well\b/i, /\bpleased with\b/i, /\bfeeling good\b/i,
           /\bmade progress\b/i, /\bproud of\b/i],
  },
];

/**
 * Signals the message wants information, not acknowledgement.
 *
 * "I'm tired, what should I eat" is a question with a preamble. Treating it as
 * a moment requiring emotional care would be tone-deaf in the other direction.
 */
const ASKS_FOR_ACTION = [
  /\bwhat should i\b/i, /\bhow (do|can) i\b/i, /\bwhat can i\b/i,
  /\bsuggest\b/i, /\brecommend\b/i, /\bgive me\b/i, /\bplan\b/i,
  /\?$/,
];

export function readEmotion(message: string): EmotionalRead {
  const text = message.trim();

  for (const pattern of PATTERNS) {
    const strong = pattern.strong.some((p) => p.test(text));
    const soft = pattern.soft.some((p) => p.test(text));
    if (!strong && !soft) continue;

    const asksForAction = ASKS_FOR_ACTION.some((p) => p.test(text));

    return {
      state: pattern.state,
      intensity: strong ? "high" : "moderate",
      // A direct question still gets answered — but warmly, and after a line
      // that acknowledges what they led with.
      needsAcknowledgement: strong || !asksForAction,
    };
  }

  return { state: null, intensity: "low", needsAcknowledgement: false };
}

/**
 * How the coach should handle this turn.
 *
 * The instruction is deliberately specific about what *not* to do, because the
 * default failure mode is a well-meaning list of five suggestions at someone
 * who needed one sentence of recognition first.
 */
export function emotionalSteer(read: EmotionalRead): string {
  if (!read.state) return "";

  const base = {
    exhausted:
      "They are describing real tiredness. Acknowledge it in one plain sentence before anything else. Do not open with advice, and do not suggest training today. If their sleep or recovery data explains it, say so — knowing why is often more useful than a suggestion.",
    overwhelmed:
      "They are overwhelmed. Reduce the load rather than adding to it: no lists, no plans, no multiple suggestions. One small thing, or simply permission to let today be a smaller day.",
    frustrated:
      "They are frustrated that effort is not producing results. Do not be relentlessly upbeat about it. If their data shows something genuinely moving, point at it; if it does not, say that honestly and look at what might be in the way.",
    discouraged:
      "They are close to giving up. Do not sell the goal back to them or use motivational language. Be curious about what has made it hard, and make the next step small enough that it is obviously doable.",
    anxious:
      "They are worried. Be calm and specific rather than reassuring in general terms. If the worry is about a health symptom, say plainly that a clinician is the right person and do not speculate.",
    low:
      "Their mood is low. Warmth matters more than advice here. One gentle, very small suggestion at most, and no cheerfulness that would feel like being talked at.",
    positive:
      "Something went well for them. Acknowledge it specifically — name the thing — without turning it into a lecture about maintaining momentum.",
  }[read.state];

  const questionRule = read.needsAcknowledgement
    ? " Ask at most one question, and only if the answer would change what you say next."
    : "";

  return base + questionRule;
}

/** No meal card or workout plan belongs next to a conversation about feeling low. */
export function suppressesCards(read: EmotionalRead): boolean {
  return read.needsAcknowledgement
    && ["overwhelmed", "discouraged", "low", "anxious"].includes(read.state ?? "");
}

/**
 * Phrases that shame, however gently they are meant.
 *
 * Checked on the way out because "you should have" and "why didn't you" arrive
 * naturally in a coaching voice, and a person who already feels they have
 * failed does not need it confirmed.
 */
const SHAMING = [
  /\bwhy (didn'?t|did not|haven'?t) you\b/i,
  /\byou should have\b/i,
  /\byou failed\b/i,
  /\bthat'?s (not good|bad|poor|disappointing)\b/i,
  /\byou need to try harder\b/i,
  /\bno excuse\b/i,
  /\bif you (really|actually) wanted\b/i,
  /\byou(?:'?re| are) (not|never) going to (lose|reach|get|make)\b/i,
  /\b(bad|guilty|naughty) (food|choice|meal)\b/i,
  /\byou'?ve undone\b/i,
];

/** Whether a reply blames the person for where they are. */
export function isShaming(answer: string): boolean {
  return SHAMING.some((p) => p.test(answer));
}

/** Question marks. The obvious half of the problem. */
export function countQuestions(answer: string): number {
  return (answer.match(/\?/g) ?? []).length;
}

/**
 * Too much asked at once.
 *
 * Counting question marks alone misses the commoner failure: "How was your
 * sleep, stress, nutrition and mood?" is four questions wearing one coat, with
 * a single question mark, and it reliably gets none of them answered.
 *
 * So a question listing three or more distinct topics counts as asking too
 * much, even though it is grammatically one question.
 */
const TOPICS = [
  "sleep", "stress", "nutrition", "mood", "energy", "exercise", "training",
  "water", "hydration", "protein", "weight", "steps", "recovery", "appetite",
];

export function asksTooMuch(answer: string): boolean {
  if (countQuestions(answer) > 1) return true;

  // Only the question itself — a statement listing topics is fine.
  const question = answer.split(/(?<=[.!])\s/).find((s) => s.includes("?"));
  if (!question) return false;

  const topics = TOPICS.filter((t) => new RegExp(`\\b${t}`, "i").test(question));
  return topics.length >= 3;
}
