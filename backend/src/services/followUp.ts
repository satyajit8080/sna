import { q, one } from "../db.js";
import { localDate } from "../util/dates.js";

/**
 * Follow-up intelligence.
 *
 * The orchestrator has been persisting recommendations and outcomes for a
 * while, but `/coach/ask` never read them back — so the coach could suggest
 * something on Monday and have no idea on Tuesday whether it happened. That
 * gap is the difference between a coaching relationship and a series of
 * unrelated conversations.
 *
 * Everything here is a database read. No model call, so it costs nothing and
 * cannot invent a history that did not happen.
 */

export type PriorAdvice = {
  id: string;
  domain: string;
  action: string;
  reason: string;
  offeredOn: string;
  /** pending | accepted | dismissed | completed | expired */
  status: string;
  daysAgo: number;
  /** improved | unchanged | worse | unknown — only where measurable. */
  outcome: string | null;
  metric: string | null;
  beforeValue: number | null;
  afterValue: number | null;
};

export type FollowUp = {
  /** Advice from the last few days, newest first. */
  recent: PriorAdvice[];
  /** Offered yesterday and never answered — the natural thing to ask about. */
  awaitingAnswer: PriorAdvice | null;
  /** Domains this person reliably acts on. */
  respondsTo: string[];
  /** Domains they have repeatedly ignored — stop repeating these. */
  ignores: string[];
  /** Interventions that measurably moved a metric for this person. */
  proven: Array<{ domain: string; action: string; metric: string }>;
};

/** Below this, a completion rate is noise rather than a signal. */
const MIN_FOR_ADHERENCE = 4;

export async function buildFollowUp(userId: string, tz: string): Promise<FollowUp> {
  const today = localDate(tz);

  const rows = await q<any>(
    `SELECT r.id, r.domain, r.action, r.reason, r.offered_on, r.status,
            ($2::date - r.offered_on)::int AS days_ago,
            o.direction, o.metric, o.before_value, o.after_value
       FROM recommendations r
       LEFT JOIN recommendation_outcomes o ON o.recommendation_id = r.id
      WHERE r.user_id = $1
        AND r.offered_on > $2::date - 7
        AND r.offered_on < $2::date
      ORDER BY r.offered_on DESC, r.created_at DESC
      LIMIT 10`,
    [userId, today]
  );

  const recent: PriorAdvice[] = rows.map((r: any) => ({
    id: r.id,
    domain: r.domain,
    action: r.action,
    reason: r.reason,
    offeredOn: String(r.offered_on).slice(0, 10),
    status: r.status,
    daysAgo: r.days_ago,
    outcome: r.direction ?? null,
    metric: r.metric ?? null,
    beforeValue: r.before_value == null ? null : Number(r.before_value),
    afterValue: r.after_value == null ? null : Number(r.after_value),
  }));

  /**
   * The one worth asking about: offered yesterday, never answered.
   *
   * Older than that and the question is odd — nobody wants to be asked on
   * Friday whether they took Monday's walk.
   */
  const awaitingAnswer = recent.find(
    (r) => r.daysAgo === 1 && (r.status === "pending" || r.status === "accepted")
  ) ?? null;

  // Adherence by domain, over a longer window than the follow-up itself.
  const adherence = await q<{ domain: string; total: string; completed: string; improved: string }>(
    `SELECT r.domain,
            COUNT(*)::text AS total,
            COUNT(*) FILTER (WHERE r.status = 'completed')::text AS completed,
            COUNT(*) FILTER (WHERE o.direction = 'improved')::text AS improved
       FROM recommendations r
       LEFT JOIN recommendation_outcomes o ON o.recommendation_id = r.id
      WHERE r.user_id = $1 AND r.offered_on > $2::date - 60
      GROUP BY r.domain
     HAVING COUNT(*) >= $3`,
    [userId, today, MIN_FOR_ADHERENCE]
  );

  const respondsTo: string[] = [];
  const ignores: string[] = [];

  for (const row of adherence) {
    const rate = Number(row.completed) / Number(row.total);
    if (rate >= 0.6) respondsTo.push(row.domain);
    else if (rate <= 0.2) ignores.push(row.domain);
  }

  // Interventions that actually moved something for this person.
  const proven = await q<{ domain: string; action: string; metric: string }>(
    `SELECT r.domain, r.action, o.metric
       FROM recommendations r
       JOIN recommendation_outcomes o ON o.recommendation_id = r.id
      WHERE r.user_id = $1
        AND o.direction = 'improved'
        AND o.metric IS NOT NULL
      GROUP BY r.domain, r.action, o.metric
     HAVING COUNT(*) >= 2
      LIMIT 3`,
    [userId]
  );

  return { recent, awaitingAnswer, respondsTo, ignores, proven };
}

/**
 * Compact shape for the prompt.
 *
 * Only what changes the answer: the model does not need seven days of history
 * to ask one useful question, and a long block would push out the numbers that
 * matter more.
 */
export function followUpForPrompt(followUp: FollowUp) {
  if (followUp.recent.length === 0) return null;

  return {
    awaiting_answer: followUp.awaitingAnswer
      ? {
          action: followUp.awaitingAnswer.action,
          offered: "yesterday",
        }
      : null,

    // Enough to avoid repeating yesterday's suggestion verbatim.
    recent_advice: followUp.recent.slice(0, 4).map((r) => ({
      action: r.action,
      days_ago: r.daysAgo,
      followed: r.status === "completed",
      dismissed: r.status === "dismissed",
      outcome: r.outcome === "unknown" ? null : r.outcome,
    })),

    responds_well_to: followUp.respondsTo,
    // The important one: stop repeating what this person never acts on.
    tends_to_ignore: followUp.ignores,
    proven_for_them: followUp.proven.map((p) => p.action),
  };
}

/**
 * The instruction that turns history into a coaching loop.
 *
 * Split from the facts because a steer is an instruction, not data — and the
 * model follows a direct sentence far better than it infers behaviour from a
 * JSON field.
 */
export function followUpSteer(followUp: FollowUp): string {
  const parts: string[] = [];

  if (followUp.awaitingAnswer) {
    parts.push(
      `Yesterday you suggested: "${followUp.awaitingAnswer.action}". ` +
      `If it fits naturally, ask whether they managed it before giving new advice — ` +
      `briefly, in one clause, not as an interrogation.`
    );
  }

  if (followUp.ignores.length) {
    parts.push(
      `They have repeatedly not acted on ${followUp.ignores.join(" and ")} suggestions. ` +
      `Do not repeat that advice in the same form — either find a smaller version of it ` +
      `or focus elsewhere.`
    );
  }

  if (followUp.proven.length) {
    parts.push(
      `These have measurably helped this person before: ` +
      `${followUp.proven.map((p) => p.action).join("; ")}. ` +
      `Prefer them over untested alternatives.`
    );
  }

  const repeated = followUp.recent.filter((r) => r.daysAgo <= 2).map((r) => r.action);
  if (repeated.length) {
    parts.push(
      `You already said this in the last two days: ${repeated.join("; ")}. ` +
      `Do not say it again word for word.`
    );
  }

  return parts.join(" ");
}

/**
 * Records that the user reported doing something in conversation.
 *
 * "I did get to bed early" is an outcome, and losing it because it arrived as
 * chat rather than a button press would make adherence data quietly wrong.
 */
export async function markFromConversation(
  userId: string,
  recommendationId: string,
  status: "completed" | "dismissed",
  feedback?: string
) {
  const updated = await one<{ id: string }>(
    `UPDATE recommendations
        SET status = $3, responded_at = now()
      WHERE id = $2 AND user_id = $1 AND status IN ('pending', 'accepted')
      RETURNING id`,
    [userId, recommendationId, status]
  );

  if (updated && feedback) {
    await q(
      `INSERT INTO recommendation_outcomes
         (recommendation_id, user_id, user_feedback, direction)
       VALUES ($1,$2,$3,'unknown')`,
      [recommendationId, userId, feedback]
    );
  }

  return updated;
}
