/**
 * The safety engine.
 *
 * Separate from intent classification on purpose: intent decides what kind of
 * help to give, safety decides whether to help at all. Conflating them means
 * a well-phrased dangerous request gets routed as an ordinary question.
 *
 * Two layers, both mandatory:
 *   pre-model  — rewrites the instruction, or blocks the call entirely
 *   post-model — inspects the response and can replace it
 *
 * The model is never the last word on a safety decision.
 */

export type SafetyCategory =
  | "emergency"          // possible medical emergency
  | "self_harm"
  | "disordered_eating"
  | "extreme_restriction" // dangerous calorie targets
  | "medication"
  | "diagnosis_request"
  | "supplement_brand"
  | "unverifiable"        // live data we cannot check
  | "exercise_risk"       // training through injury or illness
  | null;

export type SafetyVerdict = {
  category: SafetyCategory;
  /** block = never reaches the model. steer = model runs with a hard instruction. */
  action: "block" | "steer" | "allow";
  /** Used verbatim when action is "block". */
  response?: string;
  /** Appended to the prompt when action is "steer". */
  instruction?: string;
};

type Rule = {
  category: Exclude<SafetyCategory, null>;
  patterns: RegExp[];
  action: "block" | "steer";
  response?: string;
  instruction?: string;
};

/**
 * Ordered by severity — the first match wins, so an emergency phrased as a
 * nutrition question is still an emergency.
 */
const RULES: Rule[] = [
  {
    category: "self_harm",
    action: "block",
    patterns: [
      /\b(kill myself|end my life|want to die|suicidal|self harm|hurt myself)\b/i,
      /\bno reason to (live|go on)\b/i,
    ],
    response:
      "I'm not the right kind of help for this, and I don't want to give you a nutrition answer when something harder is going on. Please talk to someone who can help properly — a doctor, a crisis line, or someone you trust. If you're in immediate danger, contact emergency services.",
  },
  {
    category: "emergency",
    action: "block",
    patterns: [
      /\bchest pain\b/i,
      /\b(can'?t|cannot|difficulty) breath/i,
      /\b(fainted|fainting|passed out|blacked out)\b/i,
      /\bsevere (pain|bleeding)\b/i,
      /\b(allergic reaction|anaphyla)/i,
      /\b(numb|weak) on one side\b/i,
      /\bslurred speech\b/i,
      /\bcoughing up blood\b/i,
    ],
    response:
      "That needs proper medical attention now, not coaching advice. Please contact emergency services or get to a doctor — don't wait to see if it settles.",
  },
  {
    category: "disordered_eating",
    action: "steer",
    patterns: [
      /\b(purge|purging|vomit after|throw up after|laxative)\b/i,
      /\b(starve|starving) myself\b/i,
      /\bhow (little|few) can i eat\b/i,
      /\b(fat|disgusting|hate my body)\b/i,
      /\bnot eat (for|all) (a|the) (day|week)\b/i,
      /\bcompensate for (eating|what i ate)\b/i,
    ],
    instruction:
      "This message contains language associated with disordered eating. Do NOT provide restriction advice, compensatory exercise, or any calorie target. Respond with warmth and without judgement, do not moralise about food, and gently suggest that speaking to a doctor or a registered dietitian would help. Keep it short and kind.",
  },
  {
    category: "extreme_restriction",
    action: "steer",
    patterns: [
      /\b([0-9]{3})\s*(calories|kcal|cal)\s*(a|per)?\s*day\b/i,
      /\blose \d+\s*(kg|kilos|pounds|lbs)\s*(in|within)\s*(a|1|one|two|2)\s*(week|day)/i,
      /\b(crash|extreme|water) (diet|fast)\b/i,
      /\bfast(ing)? for \d+ days\b/i,
    ],
    instruction:
      "The user is describing an unsafe rate of loss or an extreme restriction. Do not endorse it or provide a plan for it. Explain briefly and without alarm why a slower approach works better and is safer, offer a realistic alternative, and suggest a doctor or dietitian if they want to go faster than that.",
  },
  {
    category: "medication",
    action: "steer",
    patterns: [
      /\b(medicine|medication|tablets?|pills?|prescription|prescribe)\b/i,
      /\b(antibiotic|insulin|statin|metformin|ozempic|wegovy|semaglutide)\b/i,
      /\b(dose|dosage|mg of|how much .* should i take)\b/i,
      /\bshould i (stop|start|change) taking\b/i,
      /\bside effects?\b/i,
    ],
    instruction:
      "This touches on medication. Name no medication, no dose, and no change to what they take — that is a doctor or pharmacist's job, and say so plainly. Then help fully with any food, training, sleep or recovery part of the question.",
  },
  {
    category: "diagnosis_request",
    action: "steer",
    patterns: [
      /\b(do i have|could i have|am i)\s+(diabetic|diabetes|anaemic|anemic|hypothyroid|pcos|ibs)\b/i,
      /\bwhat('?s| is) wrong with me\b/i,
      /\bdiagnos/i,
      /\bis this (normal|serious|dangerous)\b/i,
    ],
    instruction:
      "The user is asking for a diagnosis. Do not offer one, and do not speculate about conditions. Say that only a clinician can answer it properly, note that getting it checked is worthwhile, and then help with anything practical in their question.",
  },
  {
    category: "exercise_risk",
    action: "steer",
    patterns: [
      /\btrain (through|with) (the )?(pain|injury)\b/i,
      /\bwork ?out (while|when) (sick|ill|injured|fever)\b/i,
      /\b(sharp|shooting) pain\b/i,
      /\bpopped|tore|torn\b/i,
    ],
    instruction:
      "The user is describing pain, injury or illness around training. Do not program loaded exercise for the affected area or encourage training through pain. Recommend rest and, for anything sharp, sudden or persistent, a physiotherapist or doctor. Offer a safe alternative if there is one.",
  },
  {
    category: "supplement_brand",
    action: "steer",
    patterns: [
      /\b(which|what|best) (brand|protein powder|supplement|product)\b/i,
      /\bshould i buy\b/i,
      /\brecommend a brand\b/i,
    ],
    instruction:
      "They are asking which product to buy. Name no brand. Explain what to compare — protein per serving, ingredient list, third-party testing, cost per serving, how it sits with them — and answer the rest of the question properly.",
  },
  {
    category: "unverifiable",
    action: "steer",
    patterns: [
      /\b(in stock|available (in|at)|price of|how much does it cost)\b/i,
      /\b(open (right )?now|opening hours)\b/i,
      /\b(which|what) (store|shop|restaurant|gym)\b/i,
    ],
    instruction:
      "They are asking about live availability, price or opening hours, which you cannot check. Say that in one clause — do not pretend to know — then answer the general part of the question fully.",
  },
];

export function assess(question: string): SafetyVerdict {
  for (const rule of RULES) {
    if (rule.patterns.some((p) => p.test(question))) {
      return {
        category: rule.category,
        action: rule.action,
        response: rule.response,
        instruction: rule.instruction,
      };
    }
  }
  return { category: null, action: "allow" };
}

/**
 * Post-model validation.
 *
 * Instruction-following is probabilistic. For medication and unsafe targets
 * the cost of one bad response is high enough that a deterministic check on
 * the way out is worth the small false-positive rate.
 */
export function validate(answer: string, verdict: SafetyVerdict): string | null {
  const a = answer.toLowerCase();

  // A blocked category should never have reached the model at all.
  if (verdict.action === "block" && verdict.response) return verdict.response;

  /**
   * Naming a dose is prescribing, whatever the framing around it.
   *
   * `ml` is deliberately absent from the units: water and drinks are measured
   * in millilitres, and "2000 ml of water daily" was being replaced with a
   * medication refusal — a false positive that made the coach look broken on
   * an ordinary hydration answer.
   *
   * The trigger also now requires a genuinely pharmaceutical word nearby
   * rather than any occurrence of "daily", which appears in most sane
   * nutrition advice.
   */
  const dosePattern = /\b\d+(?:\.\d+)?\s?(mg|mcg|µg|iu)\b/;
  const pharmaceutical =
    /\b(take|taking|dose|dosage|tablet|capsule|pill|prescri|supplement|medication|medicine|doctor|pharmacist|vitamin)\b/;

  if (dosePattern.test(a) && pharmaceutical.test(a)) {
    return "I can't advise on medication or doses — that's a doctor or pharmacist's call. I'm glad to help with food, training, sleep or recovery instead.";
  }

  // Very low calorie targets, however the model arrived at them.
  const calorieClaim = a.match(/\b(\d{3,4})\s*(kcal|calories|cal)\b/);
  if (calorieClaim) {
    const value = Number(calorieClaim[1]);
    if (value > 0 && value < 1000 && /\b(target|aim|eat|stick to|limit)\b/.test(a)) {
      return "I'd rather not put a number that low in front of you — very low intakes tend to backfire and can be unsafe. If you want to lose faster, that's worth planning with a doctor or dietitian.";
    }
  }

  // Diagnostic assertions.
  if (/\byou (have|are) (diabetic|diabetes|anaemic|anemic|deficient|hypothyroid)\b/.test(a)) {
    return "I can't tell you what condition you have — that needs a clinician and usually a blood test. Worth getting checked. In the meantime I can help with the food and training side.";
  }

  return null;
}

/**
 * Phrases that mean nothing to a specific person on a specific day.
 *
 * Not a hard block — occasionally one is genuinely the right thing to say —
 * but an answer built entirely from these is a leaflet, and we can tell the
 * difference by checking whether it cites anything real.
 */
const GENERIC_PHRASES = [
  "balanced meal", "balanced diet", "balanced day",
  "stay hydrated", "drink plenty of water",
  "get a good night", "gentle workout", "listen to your body",
  "eat clean", "healthy fats", "in moderation",
  "support your goals", "stay consistent",
];

/**
 * Whether a reply is generic filler rather than coaching.
 *
 * A concrete answer references a number, a food the user logged, or a trend.
 * One with several stock phrases and no figures at all is the failure mode the
 * product is trying to avoid.
 */
export function isGeneric(answer: string): boolean {
  const a = answer.toLowerCase();

  const stockPhrases = GENERIC_PHRASES.filter((p) => a.includes(p)).length;
  if (stockPhrases === 0) return false;

  // Any real figure — calories, grams, steps, times, percentages.
  const citesData = /\b\d{1,5}\s?(kcal|calories|cal|g\b|grams|steps|kg|ml|hours|hrs|min|%)/.test(a)
    || /\b\d{1,2}[:.]\d{2}\b/.test(a)
    || /\b(below|above|against|compared with) your\b/.test(a);

  return !citesData && stockPhrases >= 2;
}

/** Categories that must never carry a meal card or a workout plan. */
export function suppressesRecommendations(verdict: SafetyVerdict): boolean {
  return verdict.action === "block"
    || verdict.category === "disordered_eating"
    || verdict.category === "extreme_restriction"
    || verdict.category === "exercise_risk";
}
