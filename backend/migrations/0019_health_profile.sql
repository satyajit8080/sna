-- 0019 — health context the coach needs to be *safer*, not cleverer.
--
-- Everything here exists to constrain advice, never to generate it. A recorded
-- condition makes the coach more conservative and more likely to point at a
-- clinician; it must never let it diagnose, dose, or manage treatment. The
-- safety engine reads these tables for exactly that purpose.
--
-- This is the most sensitive data in the product. Two consequences:
--   * every table cascades on user delete, so "delete my account" is complete;
--   * `prefer_not_to_say` is a first-class answer everywhere, because a user
--     who feels interrogated will give worse answers than one who can decline.

-- ─── daily rhythm ───────────────────────────────────────────────────────────
-- Distinct from `notification_prefs.target_bedtime`, which is a reminder
-- setting. This is what the coach reasons about: their actual life.
CREATE TABLE IF NOT EXISTS daily_schedule (
  user_id        uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  typical_bedtime   time,
  typical_wake_time time,
  -- Self-reported; HealthKit overrides it once there is real data.
  typical_sleep_minutes int CHECK (typical_sleep_minutes BETWEEN 120 AND 900),
  sleep_quality  text CHECK (sleep_quality IN
                   ('poor','mixed','good','prefer_not_to_say')),
  work_start     time,
  work_end       time,
  -- desk | standing | physical | shift | student | other
  work_type      text,
  -- sedentary | mixed | active
  activity_level text,
  updated_at     timestamptz NOT NULL DEFAULT now()
);

-- ─── health context ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS health_conditions (
  id          bigserial PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Free text as the user described it. Deliberately not a coded vocabulary:
  -- mapping "sugar problem" to an ICD code is a clinical judgement we are not
  -- qualified or licensed to make.
  condition   text NOT NULL,
  -- Anything a clinician told them to avoid. The single most useful field here.
  restriction text,
  noted_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, condition)
);

CREATE TABLE IF NOT EXISTS user_allergies (
  id        bigserial PRIMARY KEY,
  user_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  allergen  text NOT NULL,
  -- food | medication | other
  kind      text NOT NULL DEFAULT 'food',
  severity  text CHECK (severity IN ('mild','moderate','severe','unknown')),
  UNIQUE (user_id, allergen, kind)
);

-- ─── medications and supplements ────────────────────────────────────────────
-- Recorded for *context and reminders only*. SnapCal never advises on dosing,
-- never suggests starting or stopping anything, and the safety engine blocks
-- any reply that tries.
CREATE TABLE IF NOT EXISTS medications (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        text NOT NULL,
  -- Stored verbatim as the user typed it. Never parsed, never validated
  -- against a drug database, never used to compute anything.
  dose        text,
  -- daily | twice_daily | weekly | as_needed | other
  frequency   text,
  times       time[] NOT NULL DEFAULT '{}',
  -- Their words for why. Helps the coach avoid saying something tone-deaf.
  purpose     text,
  -- medication | supplement — separated because the boundaries differ.
  kind        text NOT NULL DEFAULT 'medication'
                CHECK (kind IN ('medication','supplement')),
  reminders   boolean NOT NULL DEFAULT false,
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS medications_user
  ON medications (user_id, kind) WHERE active;

-- ─── mind and stress ────────────────────────────────────────────────────────
-- Non-clinical by design. The point is knowing how someone's emotional state
-- interacts with their routine, not screening for anything.
CREATE TABLE IF NOT EXISTS mind_profile (
  user_id      uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  stress_level text CHECK (stress_level IN
                 ('low','moderate','high','variable','prefer_not_to_say')),
  usual_mood   text CHECK (usual_mood IN
                 ('positive','okay','up_and_down','often_low','prefer_not_to_say')),
  stressors    text[] NOT NULL DEFAULT '{}',
  -- What has actually helped them before. The most actionable field here by
  -- some distance: suggesting a walk to someone who finds walks helpful is a
  -- different proposition from suggesting it cold.
  coping       text[] NOT NULL DEFAULT '{}',
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ─── goals ──────────────────────────────────────────────────────────────────
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS primary_goal text;
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS secondary_goals text[] NOT NULL DEFAULT '{}';

-- "I want to wake up feeling energetic." In their own words, and worth more
-- than any checkbox — it says what success actually looks like to them.
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS success_looks_like text;

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS work_type text;

-- ─── eating pattern ─────────────────────────────────────────────────────────
ALTER TABLE food_preferences ADD COLUMN IF NOT EXISTS meals_per_day int
  CHECK (meals_per_day BETWEEN 1 AND 8);
ALTER TABLE food_preferences ADD COLUMN IF NOT EXISTS eats_late boolean;
ALTER TABLE food_preferences ADD COLUMN IF NOT EXISTS typical_water_ml int;

-- ─── onboarding progress ────────────────────────────────────────────────────
-- Screen-level rather than question-level, so a returning user resumes where
-- they stopped instead of starting again.
CREATE TABLE IF NOT EXISTS onboarding_progress (
  user_id         uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  completed_screens text[] NOT NULL DEFAULT '{}',
  skipped_screens   text[] NOT NULL DEFAULT '{}',
  finished_at     timestamptz,
  updated_at      timestamptz NOT NULL DEFAULT now()
);
