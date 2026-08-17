import { q, one } from "../db.js";

/**
 * The Personal Health Brain.
 *
 * A chat transcript is not memory. `coach_messages` records what was said;
 * this records what was *learned* — and consolidates it, so the same fact
 * observed five times becomes one confident memory rather than five rows.
 *
 * Consolidation is the whole point. Without it a memory store fills with
 * near-duplicates and retrieval returns noise, which is worse than no memory
 * at all because it looks like the system knows things it doesn't.
 */

export type MemoryLayer =
  | "semantic"    // learned facts: "prefers eggs", "dislikes running"
  | "episodic"    // notable events worth recalling
  | "routine"     // time-of-day and day-of-week patterns
  | "preference"  // how this person wants to be coached
  | "procedural"; // which interventions actually work for them

export type Memory = {
  id: string;
  layer: MemoryLayer;
  content: string;
  subject: string | null;
  confidence: number;
  evidenceCount: number;
  userEdited: boolean;
};

export type MemoryCandidate = {
  layer: MemoryLayer;
  content: string;
  /** Grouping key. Two candidates with the same subject are the same fact. */
  subject: string;
  confidence?: number;
};

/** What consolidation decided to do, and why. */
export type ConsolidationResult = {
  action: "ADD" | "UPDATE" | "REINFORCE" | "NOOP";
  memoryId: string | null;
  reason: string;
};

/** Confidence gained each time a fact is independently observed again. */
const REINFORCE_STEP = 0.15;
const MAX_CONFIDENCE = 0.95;
/** Below this a memory is too weak to put in a prompt. */
const RETRIEVAL_FLOOR = 0.35;

/**
 * Normalises content for comparison — case, punctuation and filler removed.
 * "Usually skips breakfast" and "usually skips breakfast." are one fact.
 */
function normalise(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\w\s]/g, "")
    .replace(/\b(usually|often|typically|generally|tends to|seems to)\b/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Stores one candidate, deciding between add, update, reinforce and no-op.
 *
 * The four-way decision matters: blindly adding creates duplicates, blindly
 * updating destroys history, and doing nothing means the brain never learns.
 */
export async function consolidate(
  userId: string,
  candidate: MemoryCandidate
): Promise<ConsolidationResult> {
  const existing = await q<{
    id: string; content: string; confidence: string;
    evidence_count: number; user_edited: boolean;
  }>(
    `SELECT id, content, confidence, evidence_count, user_edited
       FROM memories
      WHERE user_id = $1 AND layer = $2 AND subject = $3
        AND valid_until IS NULL
      ORDER BY confidence DESC
      LIMIT 3`,
    [userId, candidate.layer, candidate.subject]
  );

  // Nothing on this subject yet.
  if (existing.length === 0) {
    const row = await one<{ id: string }>(
      `INSERT INTO memories (user_id, layer, content, subject, confidence)
       VALUES ($1,$2,$3,$4,$5) RETURNING id`,
      [userId, candidate.layer, candidate.content, candidate.subject,
       candidate.confidence ?? 0.5]
    );
    return { action: "ADD", memoryId: row!.id, reason: "no existing memory on this subject" };
  }

  const match = existing.find((m) => normalise(m.content) === normalise(candidate.content));

  // Same fact again — more confident, not a second row.
  if (match) {
    const next = Math.min(MAX_CONFIDENCE, Number(match.confidence) + REINFORCE_STEP);
    await q(
      `UPDATE memories
          SET confidence = $2, evidence_count = evidence_count + 1,
              last_seen_at = now()
        WHERE id = $1`,
      [match.id, next]
    );
    return {
      action: "REINFORCE",
      memoryId: match.id,
      reason: `observed again, confidence ${Number(match.confidence).toFixed(2)} → ${next.toFixed(2)}`,
    };
  }

  const top = existing[0]!;

  // The user's own words outrank anything inferred. Overwriting what someone
  // explicitly told us with a guess is the fastest way to lose their trust in
  // the whole memory system.
  if (top.user_edited) {
    return {
      action: "NOOP",
      memoryId: top.id,
      reason: "user-authored memory on this subject is authoritative",
    };
  }

  // Same subject, different content: the fact changed. Close the old one
  // rather than deleting it, so history survives a routine change.
  await q(
    `UPDATE memories SET valid_until = now() WHERE id = $1`,
    [top.id]
  );
  const row = await one<{ id: string }>(
    `INSERT INTO memories (user_id, layer, content, subject, confidence, evidence_count)
     VALUES ($1,$2,$3,$4,$5,1) RETURNING id`,
    [userId, candidate.layer, candidate.content, candidate.subject,
     candidate.confidence ?? 0.5]
  );
  return {
    action: "UPDATE",
    memoryId: row!.id,
    reason: `superseded "${top.content}"`,
  };
}

/**
 * Memories worth putting in a prompt.
 *
 * Filtered by confidence and capped: an unbounded memory dump would grow the
 * token bill every week and bury the relevant facts among the trivial ones.
 */
export async function recall(
  userId: string,
  opts: { layers?: MemoryLayer[]; limit?: number } = {}
): Promise<Memory[]> {
  const layers = opts.layers ?? ["semantic", "routine", "preference", "procedural"];

  const rows = await q<any>(
    `SELECT id, layer, content, subject, confidence, evidence_count, user_edited
       FROM memories
      WHERE user_id = $1
        AND layer = ANY($2::text[])
        AND valid_until IS NULL
        AND (confidence >= $3 OR user_edited)
      ORDER BY user_edited DESC, confidence DESC, evidence_count DESC
      LIMIT $4`,
    [userId, layers, RETRIEVAL_FLOOR, opts.limit ?? 12]
  );

  return rows.map((r: any) => ({
    id: r.id,
    layer: r.layer,
    content: r.content,
    subject: r.subject,
    confidence: Number(r.confidence),
    evidenceCount: r.evidence_count,
    userEdited: r.user_edited,
  }));
}

/** Everything, for the "what SnapCal knows about you" screen. */
export async function allMemories(userId: string) {
  return q<any>(
    `SELECT id, layer, content, subject, confidence, evidence_count,
            user_edited, valid_from, valid_until
       FROM memories
      WHERE user_id = $1 AND valid_until IS NULL
      ORDER BY layer, confidence DESC`,
    [userId]
  );
}

/** User correction. Marked authoritative so extraction cannot overwrite it. */
export async function editMemory(userId: string, id: string, content: string) {
  return one(
    `UPDATE memories
        SET content = $3, user_edited = true, confidence = 1.0, last_seen_at = now()
      WHERE id = $2 AND user_id = $1
      RETURNING id, layer, content, confidence`,
    [userId, id, content]
  );
}

/**
 * Deletion is real deletion, not a validity window.
 *
 * If someone asks the app to forget something about their health, leaving it
 * in the table with an end-date is not forgetting.
 */
export async function forgetMemory(userId: string, id: string) {
  return one(`DELETE FROM memories WHERE id = $2 AND user_id = $1 RETURNING id`,
             [userId, id]);
}

/**
 * Derives routine memories from logged behaviour.
 *
 * Routines are computed, not inferred by a model: the data already says when
 * someone eats and trains, and arithmetic cannot invent a pattern that isn't
 * there.
 */
export async function learnRoutines(userId: string): Promise<ConsolidationResult[]> {
  const results: ConsolidationResult[] = [];

  // Typical meal times by slot, from at least four observations.
  const mealTimes = await q<{ slot: string; hour: string; n: string }>(
    `SELECT slot,
            ROUND(AVG(EXTRACT(HOUR FROM logged_at)))::text AS hour,
            COUNT(*) AS n
       FROM meals
      WHERE user_id = $1 AND logged_on > CURRENT_DATE - 21
      GROUP BY slot
     HAVING COUNT(*) >= 4`,
    [userId]
  );

  for (const row of mealTimes) {
    const hour = Number(row.hour);
    const label = hour === 0 ? "midnight" : hour < 12 ? `${hour}am` : `${hour === 12 ? 12 : hour - 12}pm`;
    results.push(await consolidate(userId, {
      layer: "routine",
      subject: `meal_time_${row.slot}`,
      content: `usually eats ${row.slot} around ${label}`,
      confidence: Math.min(0.9, 0.4 + Number(row.n) * 0.05),
    }));
  }

  // Typical training time.
  const trainingTime = await one<{ hour: string; n: string }>(
    `SELECT ROUND(AVG(EXTRACT(HOUR FROM created_at)))::text AS hour, COUNT(*) AS n
       FROM workouts
      WHERE user_id = $1 AND performed_on > CURRENT_DATE - 28`,
    [userId]
  );

  if (trainingTime && Number(trainingTime.n) >= 4) {
    const hour = Number(trainingTime.hour);
    const label = hour < 12 ? `${hour}am` : `${hour === 12 ? 12 : hour - 12}pm`;
    results.push(await consolidate(userId, {
      layer: "routine",
      subject: "training_time",
      content: `usually trains around ${label}`,
      confidence: Math.min(0.9, 0.4 + Number(trainingTime.n) * 0.06),
    }));
  }

  // Weekday versus weekend logging — the gap is usually where habits break.
  const split = await one<{ weekday: string; weekend: string }>(
    `SELECT
       COUNT(*) FILTER (WHERE EXTRACT(DOW FROM logged_on) BETWEEN 1 AND 5)::text AS weekday,
       COUNT(*) FILTER (WHERE EXTRACT(DOW FROM logged_on) IN (0,6))::text AS weekend
       FROM (SELECT DISTINCT logged_on FROM meals
              WHERE user_id = $1 AND logged_on > CURRENT_DATE - 28) d`,
    [userId]
  );

  if (split && Number(split.weekday) >= 8) {
    const weekdayRate = Number(split.weekday) / 20;
    const weekendRate = Number(split.weekend) / 8;
    if (weekendRate < weekdayRate * 0.6) {
      results.push(await consolidate(userId, {
        layer: "routine",
        subject: "weekend_logging",
        content: "logs far less at weekends than on weekdays",
        confidence: 0.7,
      }));
    }
  }

  // Foods eaten repeatedly are worth remembering as preferences.
  const staples = await q<{ name: string; n: string }>(
    `SELECT lower(i.name) AS name, COUNT(*) AS n
       FROM meals m JOIN meal_items i ON i.meal_id = m.id
      WHERE m.user_id = $1 AND m.logged_on > CURRENT_DATE - 28
      GROUP BY lower(i.name)
     HAVING COUNT(*) >= 4
      ORDER BY COUNT(*) DESC
      LIMIT 5`,
    [userId]
  );

  for (const food of staples) {
    results.push(await consolidate(userId, {
      layer: "semantic",
      subject: `staple_${food.name.replace(/\s+/g, "_")}`,
      content: `eats ${food.name} regularly`,
      confidence: Math.min(0.85, 0.4 + Number(food.n) * 0.05),
    }));
  }

  return results;
}

/**
 * Learns which interventions work for this person.
 *
 * This is the procedural layer, and it is what separates coaching from
 * guessing: after enough outcomes, the coach knows that caffeine timing moves
 * this person's sleep but step targets don't.
 */
export async function learnFromOutcomes(userId: string): Promise<ConsolidationResult[]> {
  const results: ConsolidationResult[] = [];

  const byDomain = await q<{
    domain: string; total: string; completed: string; improved: string;
  }>(
    `SELECT r.domain,
            COUNT(*)::text AS total,
            COUNT(*) FILTER (WHERE r.status = 'completed')::text AS completed,
            COUNT(*) FILTER (WHERE o.direction = 'improved')::text AS improved
       FROM recommendations r
       LEFT JOIN recommendation_outcomes o ON o.recommendation_id = r.id
      WHERE r.user_id = $1 AND r.offered_on > CURRENT_DATE - 60
      GROUP BY r.domain
     HAVING COUNT(*) >= 4`,
    [userId]
  );

  for (const row of byDomain) {
    const total = Number(row.total);
    const completed = Number(row.completed);
    const improved = Number(row.improved);

    const completionRate = completed / total;

    if (completionRate >= 0.6) {
      results.push(await consolidate(userId, {
        layer: "procedural",
        subject: `adherence_${row.domain}`,
        content: `follows through on ${row.domain} suggestions`,
        confidence: Math.min(0.9, completionRate),
      }));
    } else if (completionRate <= 0.2 && total >= 5) {
      results.push(await consolidate(userId, {
        layer: "procedural",
        subject: `adherence_${row.domain}`,
        content: `rarely acts on ${row.domain} suggestions — try a different angle`,
        confidence: 0.7,
      }));
    }

    if (improved >= 3) {
      results.push(await consolidate(userId, {
        layer: "procedural",
        subject: `effective_${row.domain}`,
        content: `${row.domain} changes measurably help this person`,
        confidence: Math.min(0.9, 0.5 + improved * 0.1),
      }));
    }
  }

  return results;
}

/** Compact memory block for a prompt. */
export function memoriesForPrompt(memories: Memory[]) {
  return memories.map((m) => ({
    layer: m.layer,
    fact: m.content,
    // The model must be able to hedge on a weak memory rather than assert it.
    certainty: m.confidence >= 0.75 ? "high" : m.confidence >= 0.5 ? "medium" : "low",
  }));
}
