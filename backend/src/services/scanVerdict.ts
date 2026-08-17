import { one, q } from "../db.js";
import { localDate, localClock } from "../util/dates.js";
import { dailyBalance } from "./budget.js";
import { activityFor } from "./activity.js";

/**
 * The verdict shown after a scan.
 *
 * A scan currently identifies food and stops, which leaves the most useful
 * moment in the product unused: the person is standing in front of the food,
 * deciding. This turns the identification into a decision — but a nuanced one.
 *
 * The hard constraint is that no food is ever forbidden or called bad. The
 * research on calorie trackers is consistent that moralising about food drives
 * both churn and disordered eating, and "you failed" is the single most
 * damaging thing an app in this category can say. Everything here is framed as
 * fit-for-right-now, which is both kinder and more accurate: a bagel is a
 * different proposition before a long run than at 11pm.
 *
 * Deterministic. No model call — the verdict runs on every scan, and the
 * arithmetic is more reliable than a model asked to do the same sums.
 */

export type Fit = "good" | "moderate" | "poor" | "unknown";

export type ScanVerdict = {
  fit: Fit;
  /** One line, readable in about three seconds. */
  headline: string;
  /** Two sentences at most. Practical, never moralising. */
  detail: string;
  /** Short bullets for the "why" disclosure. */
  reasons: string[];
  /** Only when it genuinely helps — never as a rebuke. */
  alternative: string | null;
  /** A concrete portion when portion is the issue. */
  portionHint: string | null;
  /**
   * False when there isn't enough logged data to personalise. The client
   * should say so rather than implying the verdict knows more than it does.
   */
  personalised: boolean;
};

type ScanItem = {
  name: string;
  grams: number;
  kcal_100g: number;
  protein_100g: number;
  carbs_100g: number;
  fat_100g: number;
  fiber_100g?: number | null;
};

type Context = {
  remainingKcal: number | null;
  remainingProtein: number | null;
  targetKcal: number | null;
  targetProtein: number | null;
  eatenKcal: number;
  mealsToday: number;
  hour: number;
  goal: string | null;
  trainedToday: boolean;
  allergies: string[];
  dislikes: string[];
};

/** Under this many logged days, a "personalised" verdict would be a pretence. */
const MIN_CONTEXT_MEALS = 1;

async function gather(userId: string, tz: string): Promise<Context> {
  const today = localDate(tz);
  const clock = localClock(tz);

  const [targets, consumed, activity, profile, prefs, workout] = await Promise.all([
    one<any>(`SELECT calories, protein_g FROM nutrition_targets WHERE user_id = $1`, [userId]),
    one<any>(
      `SELECT COALESCE(ROUND(SUM(i.grams * i.kcal_100g / 100)),0)::int    AS calories,
              COALESCE(ROUND(SUM(i.grams * i.protein_100g / 100)),0)::int AS protein_g,
              COUNT(DISTINCT m.id)::int                                    AS meals
         FROM meals m JOIN meal_items i ON i.meal_id = m.id
        WHERE m.user_id = $1 AND m.logged_on = $2`, [userId, today]),
    activityFor(userId, tz, today),
    one<any>(`SELECT goal, primary_goal FROM profiles WHERE user_id = $1`, [userId]),
    one<any>(`SELECT allergies, dislikes FROM food_preferences WHERE user_id = $1`, [userId]),
    one<any>(`SELECT COUNT(*)::int AS n FROM workouts
               WHERE user_id = $1 AND performed_on = $2`, [userId, today]),
  ]);

  const balance = targets ? dailyBalance(targets, consumed, activity) : null;

  return {
    remainingKcal: balance?.remaining.calories ?? null,
    remainingProtein: balance?.remaining.protein_g ?? null,
    targetKcal: targets?.calories ?? null,
    targetProtein: targets?.protein_g ?? null,
    eatenKcal: consumed?.calories ?? 0,
    mealsToday: consumed?.meals ?? 0,
    hour: clock.hour,
    goal: profile?.primary_goal ?? profile?.goal ?? null,
    trainedToday: (workout?.n ?? 0) > 0,
    allergies: prefs?.allergies ?? [],
    dislikes: prefs?.dislikes ?? [],
  };
}

/** Totals for the scanned meal. */
function totals(items: ScanItem[]) {
  const sum = (pick: (i: ScanItem) => number) =>
    items.reduce((total, item) => total + pick(item) * item.grams / 100, 0);

  const kcal = Math.round(sum((i) => i.kcal_100g));
  const protein = Math.round(sum((i) => i.protein_100g));
  const carbs = Math.round(sum((i) => i.carbs_100g));
  const fat = Math.round(sum((i) => i.fat_100g));
  const fiber = Math.round(sum((i) => i.fiber_100g ?? 0));
  const grams = items.reduce((t, i) => t + i.grams, 0);

  return {
    kcal, protein, carbs, fat, fiber, grams,
    /** Calories per 100g. The clearest single signal of energy density. */
    density: grams > 0 ? Math.round(kcal / grams * 100) : 0,
    /** Protein as a share of calories. */
    proteinRatio: kcal > 0 ? (protein * 4) / kcal : 0,
  };
}

/**
 * The verdict.
 *
 * Rules are ordered so the most consequential thing wins: an allergen outranks
 * everything, then how the meal sits against what is left of the day, then
 * composition.
 */
export async function assessScan(
  userId: string, tz: string, items: ScanItem[]
): Promise<ScanVerdict> {
  const c = await gather(userId, tz);
  const t = totals(items);

  const names = items.map((i) => i.name.toLowerCase());
  const reasons: string[] = [];

  // ── allergens: the one hard stop ────────────────────────────────────────
  // Not a judgement about the food; a fact about this person.
  const allergen = c.allergies.find((a) =>
    names.some((n) => n.includes(a.toLowerCase())));

  if (allergen) {
    return {
      fit: "poor",
      headline: "Contains something you've flagged",
      detail: `You told me you react to ${allergen}. Worth double-checking the ingredients before this one.`,
      reasons: [`You've listed ${allergen} as an allergy`],
      alternative: null,
      portionHint: null,
      personalised: true,
    };
  }

  // ── not enough context to personalise ───────────────────────────────────
  // Saying something general is honest; dressing it up as personal is not.
  if (c.remainingKcal == null || c.mealsToday < MIN_CONTEXT_MEALS) {
    return generalAssessment(t, items);
  }

  const proteinGap = c.remainingProtein ?? 0;

  // ── how it sits against the rest of the day ─────────────────────────────
  const overBudget = t.kcal > c.remainingKcal;

  /**
   * How far over, relative to what is actually left.
   *
   * The first version compared the meal to the daily *target*, so 1120 kcal
   * against 407 remaining scored 56% of target and came back "slightly over" —
   * plainly wrong to anyone reading it. What matters is the overshoot against
   * the remainder.
   */
  const overshoot = c.remainingKcal > 0 ? t.kcal / c.remainingKcal : Infinity;
  const dominates = overshoot >= 1.5;

  if (t.proteinRatio >= 0.25 && proteinGap > 20 && !overBudget) {
    reasons.push(`${t.protein}g protein, and you're ${Math.round(proteinGap)}g short today`);
    if (t.fiber >= 5) reasons.push(`${t.fiber}g fibre`);

    return {
      fit: "good",
      headline: "Good fit right now",
      detail: `${t.kcal} kcal and ${t.protein}g protein — that covers a decent chunk of what you've got left today.`,
      reasons,
      alternative: null,
      portionHint: null,
      personalised: true,
    };
  }

  if (overBudget && dominates) {
    reasons.push(`${t.kcal} kcal against ${Math.max(0, Math.round(c.remainingKcal))} left today`);
    if (t.proteinRatio < 0.12) reasons.push("Not much protein for the calories");

    // A fraction that actually fits, rather than a flat "no".
    const fitsFraction = c.remainingKcal > 0
      ? Math.max(0.25, Math.min(0.75, c.remainingKcal / t.kcal))
      : 0.5;
    const fittingGrams = Math.round(t.grams * fitsFraction);

    return {
      fit: "poor",
      headline: "A lot for what's left today",
      detail: `This is ${t.kcal} kcal against about ${Math.max(0, Math.round(c.remainingKcal))} left. Roughly ${fittingGrams}g of it would fit, or it's an easy one to move to tomorrow.`,
      reasons,
      alternative: suggestAlternative(c, t),
      portionHint: `About ${fittingGrams}g ≈ ${Math.round(t.kcal * fitsFraction)} kcal`,
      personalised: true,
    };
  }

  /**
   * A meal taking most of what is left is worth flagging even when it
   * technically fits. 1120 kcal inside 1700 remaining is not "fine" — it
   * leaves very little for the rest of the day, and saying so is the useful
   * thing a coach does here.
   */
  const takesMostOfDay = c.remainingKcal > 0 && t.kcal / c.remainingKcal >= 0.6;

  if (overBudget || takesMostOfDay || t.density > 300 || t.proteinRatio < 0.10) {
    if (takesMostOfDay && !overBudget) {
      const left = Math.max(0, Math.round(c.remainingKcal - t.kcal));
      reasons.push(`Uses ${Math.round(t.kcal / c.remainingKcal * 100)}% of what's left, leaving about ${left} kcal`);
    }

    if (overBudget) {
      reasons.push(`${t.kcal} kcal against ${Math.max(0, Math.round(c.remainingKcal))} left`);
    }
    if (t.density > 300) reasons.push(`Calorie-dense at ${t.density} kcal per 100g`);
    if (t.proteinRatio < 0.10) reasons.push(`Light on protein (${t.protein}g)`);

    return {
      fit: "moderate",
      headline: "Fine — keep an eye on the portion",
      detail: takesMostOfDay && !overBudget
        ? `You can have this — it just uses most of what's left, so the rest of the day will need to be light. A smaller portion keeps your options open.`
        : t.proteinRatio < 0.10
          ? `You can have this. It's light on protein, so adding something like eggs, yoghurt or chicken alongside would make it sit better.`
          : `You can have this. It's calorie-dense, so a moderate portion keeps the rest of your day easy.`,
      reasons,
      alternative: null,
      portionHint: t.grams > 200 ? `Around ${Math.round(t.grams * 0.7)}g would fit better` : null,
      personalised: true,
    };
  }

  // ── nothing wrong with it ───────────────────────────────────────────────
  reasons.push(`${t.kcal} kcal, comfortably within your remaining ${Math.round(c.remainingKcal)}`);
  if (t.protein >= 15) reasons.push(`${t.protein}g protein`);
  if (t.fiber >= 4) reasons.push(`${t.fiber}g fibre`);

  // Post-training is worth naming: it is genuinely a better moment for this.
  const trainedNote = c.trainedToday && t.carbs > 30
    ? " Good timing too, after training."
    : "";

  return {
    fit: "good",
    headline: "Good fit right now",
    detail: `${t.kcal} kcal sits fine against what you've got left.${trainedNote}`,
    reasons,
    alternative: null,
    portionHint: null,
    personalised: true,
  };
}

/**
 * When there is nothing logged to compare against.
 *
 * Stated as a general nutritional read, and flagged as such — implying a
 * personalised verdict from no data is the kind of small dishonesty that costs
 * trust in everything else the app says.
 */
function generalAssessment(t: ReturnType<typeof totals>, items: ScanItem[]): ScanVerdict {
  const reasons: string[] = [`${t.kcal} kcal`, `${t.protein}g protein`];
  if (t.fiber >= 4) reasons.push(`${t.fiber}g fibre`);

  if (t.proteinRatio >= 0.25) {
    return {
      fit: "good",
      headline: "Solid choice",
      detail: `${t.protein}g of protein for ${t.kcal} kcal — that's a good ratio. Log a few more meals and I can tell you how it fits your day.`,
      reasons,
      alternative: null,
      portionHint: null,
      personalised: false,
    };
  }

  if (t.density > 350 || t.proteinRatio < 0.08) {
    return {
      fit: "moderate",
      headline: "Fine — watch the portion",
      detail: `${t.kcal} kcal and fairly light on protein. Pairing it with a protein source would balance it out.`,
      reasons,
      alternative: null,
      portionHint: t.grams > 200 ? `Around ${Math.round(t.grams * 0.7)}g` : null,
      personalised: false,
    };
  }

  return {
    fit: "good",
    headline: "Nothing to flag",
    detail: `${t.kcal} kcal with ${t.protein}g protein. Once you've logged a bit more I can tell you how things fit your day.`,
    reasons,
    alternative: null,
    portionHint: null,
    personalised: false,
  };
}

/**
 * A better option, when one is genuinely useful.
 *
 * Offered as an alternative for right now, never as a correction — and never
 * when there is nothing meaningfully better to suggest.
 */
function suggestAlternative(c: Context, t: ReturnType<typeof totals>): string | null {
  if (t.proteinRatio >= 0.20) return null;   // protein is fine; nothing to fix

  const wantsProtein = (c.remainingProtein ?? 0) > 25;

  if (wantsProtein && c.hour < 15) {
    return "Eggs on toast or Greek yoghurt would hit similar calories with far more protein";
  }
  if (wantsProtein) {
    return "Grilled chicken or fish with vegetables would land similar calories with more protein";
  }
  if (t.density > 350) {
    return "Something with more volume — a big salad or soup — would feel like more food for the same calories";
  }
  return null;
}
