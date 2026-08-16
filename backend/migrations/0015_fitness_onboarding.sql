-- 0015 — the fields conversational onboarding collects.
--
-- 0014 gave the coach enough to program a session. This adds what it needs to
-- program a *week*: where they train, what they actually have access to, when
-- they sleep, and what they must avoid.
--
-- `profile_completed` is what the app checks to decide whether to run
-- onboarding, so it is set only when the required answers are all present.

ALTER TABLE fitness_profile ADD COLUMN IF NOT EXISTS primary_goal text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fitness_primary_goal_chk') THEN
    ALTER TABLE fitness_profile ADD CONSTRAINT fitness_primary_goal_chk
      CHECK (primary_goal IS NULL OR primary_goal IN (
        'lose_weight', 'lose_fat_keep_muscle', 'build_muscle', 'gain_weight',
        'improve_strength', 'improve_fitness', 'maintain', 'general_health'));
  END IF;
END $$;

-- 'gym' | 'home' | 'both' | 'none'
ALTER TABLE fitness_profile ADD COLUMN IF NOT EXISTS training_location text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'fitness_location_chk') THEN
    ALTER TABLE fitness_profile ADD CONSTRAINT fitness_location_chk
      CHECK (training_location IS NULL OR training_location IN ('gym','home','both','none'));
  END IF;
END $$;

-- Multi-select, unlike the single `equipment` column from 0014 which is kept
-- for compatibility. Values: full_gym, dumbbells, barbell, machines, bands,
-- cardio, bodyweight, other.
ALTER TABLE fitness_profile ADD COLUMN IF NOT EXISTS equipment_list text[] NOT NULL DEFAULT '{}';

ALTER TABLE fitness_profile ADD COLUMN IF NOT EXISTS average_sleep_hours numeric(3,1);
ALTER TABLE fitness_profile ADD COLUMN IF NOT EXISTS usual_bedtime  time;
ALTER TABLE fitness_profile ADD COLUMN IF NOT EXISTS usual_wake_time time;

-- Free-text limitations the user reports. Never interpreted as a diagnosis —
-- only used to avoid programming a movement they said to avoid.
ALTER TABLE fitness_profile ADD COLUMN IF NOT EXISTS limitations text[] NOT NULL DEFAULT '{}';

ALTER TABLE fitness_profile ADD COLUMN IF NOT EXISTS profile_completed boolean NOT NULL DEFAULT false;
ALTER TABLE fitness_profile ADD COLUMN IF NOT EXISTS completed_at timestamptz;

-- Structured workouts the coach generated, so a recommendation can be started
-- and logged rather than retyped. Links back to the workout once completed.
CREATE TABLE IF NOT EXISTS workout_plans (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan         jsonb NOT NULL,
  focus        text NOT NULL,
  minutes      int,
  generated_on date NOT NULL,
  -- Set when the user actually trains it; null means recommended not done.
  workout_id   uuid REFERENCES workouts(id) ON DELETE SET NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS workout_plans_user ON workout_plans (user_id, generated_on DESC);
