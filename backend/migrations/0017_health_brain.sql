-- 0017 — the Personal Health Brain.
--
-- Three things the current schema cannot express:
--
--   1. A normalized health observation with a baseline and a confidence.
--      Today the coach gets "HRV = 42" and has no idea whether that is good
--      for this person. Trends and baselines are what make a number mean
--      something.
--
--   2. Memory beyond a chat transcript. `coach_messages` records what was
--      said; nothing records what was *learned*. Without extraction and
--      consolidation, week 8 is no better than week 1.
--
--   3. Whether advice worked. Recommendations are generated and forgotten,
--      so the coach cannot tell a lever that works for this person from one
--      that does not. This is the difference between coaching and guessing.

-- ─── normalized observations ────────────────────────────────────────────────
-- One row per metric per day. Deliberately relational, not a JSON blob:
-- trends are computed with window functions, and a blob cannot be indexed by
-- metric or aggregated across days.
CREATE TABLE IF NOT EXISTS health_observations (
  id          bigserial PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  observed_on date NOT NULL,
  -- steps | resting_hr | hrv | sleep_minutes | sleep_start | sleep_end |
  -- weight_kg | active_kcal | exercise_min | protein_g | calories | water_ml
  metric      text NOT NULL,
  value       numeric(10,2) NOT NULL,
  -- healthkit | manual | derived | photo
  source      text NOT NULL DEFAULT 'healthkit',
  -- 0..1. A photo-estimated calorie count is not a scale reading, and the
  -- coach must be able to tell the difference.
  confidence  numeric(3,2) NOT NULL DEFAULT 1.0,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, observed_on, metric, source)
);
CREATE INDEX IF NOT EXISTS health_obs_lookup
  ON health_observations (user_id, metric, observed_on DESC);

-- ─── the brain ──────────────────────────────────────────────────────────────
-- One table, typed by layer, because the layers share retrieval, decay and
-- user-facing editing. Splitting them into five tables would duplicate all of
-- that for no benefit.
CREATE TABLE IF NOT EXISTS memories (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- semantic  — learned facts ("prefers eggs", "dislikes running")
  -- episodic  — notable events worth recalling
  -- routine   — time-of-day / day-of-week patterns
  -- preference— how this person wants to be coached
  -- procedural— which interventions actually work for them
  layer        text NOT NULL CHECK (layer IN
                 ('semantic','episodic','routine','preference','procedural')),
  -- Short, human-readable. Shown verbatim in "what SnapCal knows about you",
  -- so it must always be something a person would recognise as true.
  content      text NOT NULL,
  -- Grouping key for consolidation: two memories with the same subject are
  -- candidates for UPDATE rather than a second ADD.
  subject      text,
  -- 0..1, raised by repeated evidence, lowered by contradiction.
  confidence   numeric(3,2) NOT NULL DEFAULT 0.5,
  -- How many times this has been observed. Distinguishes a one-off from a
  -- pattern.
  evidence_count int NOT NULL DEFAULT 1,
  -- Bi-temporal: a memory stays in history when it stops being true, so
  -- "used to train mornings" is not lost when the routine changes.
  valid_from   timestamptz NOT NULL DEFAULT now(),
  valid_until  timestamptz,
  -- User-authored memories are never overwritten by extraction.
  user_edited  boolean NOT NULL DEFAULT false,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS memories_active
  ON memories (user_id, layer, confidence DESC)
  WHERE valid_until IS NULL;
CREATE INDEX IF NOT EXISTS memories_subject
  ON memories (user_id, subject)
  WHERE valid_until IS NULL;

-- ─── the learning loop ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS recommendations (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- nutrition | fitness | sleep | recovery | hydration | activity | habit
  domain       text NOT NULL,
  action       text NOT NULL,
  -- Why this, now. Every recommendation must be explainable; one without a
  -- reason is a random suggestion, which is what we are removing.
  reason       text NOT NULL,
  confidence   numeric(3,2) NOT NULL DEFAULT 0.5,
  -- Which health-state findings triggered it, for later analysis.
  triggered_by jsonb NOT NULL DEFAULT '[]',
  offered_on   date NOT NULL,
  -- pending | accepted | dismissed | completed | expired
  status       text NOT NULL DEFAULT 'pending',
  responded_at timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS recommendations_user
  ON recommendations (user_id, offered_on DESC);
CREATE INDEX IF NOT EXISTS recommendations_open
  ON recommendations (user_id, status) WHERE status = 'pending';

-- Did it help? Measured where possible, reported where not.
CREATE TABLE IF NOT EXISTS recommendation_outcomes (
  id                bigserial PRIMARY KEY,
  recommendation_id uuid NOT NULL REFERENCES recommendations(id) ON DELETE CASCADE,
  user_id           uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- The metric expected to move, and what it did.
  metric            text,
  before_value      numeric(10,2),
  after_value       numeric(10,2),
  -- improved | unchanged | worse | unknown
  direction         text NOT NULL DEFAULT 'unknown',
  user_feedback     text,
  measured_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rec_outcomes_user ON recommendation_outcomes (user_id);

-- ─── notification restraint ─────────────────────────────────────────────────
-- Sending is recorded so fatigue can be measured rather than assumed.
CREATE TABLE IF NOT EXISTS notification_log (
  id          bigserial PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind        text NOT NULL,
  sent_at     timestamptz NOT NULL DEFAULT now(),
  opened      boolean,
  acted_on    boolean
);
CREATE INDEX IF NOT EXISTS notification_log_user
  ON notification_log (user_id, sent_at DESC);
