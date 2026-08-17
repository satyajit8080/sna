-- 0014 — data the coach needs to advise on training, not just food.
--
-- Workout programming without training history produces the same session
-- every day. Recovery advice without knowing what was trained yesterday is
-- guesswork. These tables are what turn the coach from a nutrition chatbot
-- into something that can answer "should I go to the gym today".

-- ─── what the user can actually do ──────────────────────────────────────────
CREATE TABLE IF NOT EXISTS fitness_profile (
  user_id           uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  gym_access        boolean NOT NULL DEFAULT false,
  -- 'none' | 'bands' | 'dumbbells' | 'home_gym' | 'full_gym'
  equipment         text NOT NULL DEFAULT 'none',
  -- Unknown means beginner-safe programming; never assume competence.
  experience        text NOT NULL DEFAULT 'unknown'
                      CHECK (experience IN ('unknown','beginner','intermediate','advanced')),
  training_days     int NOT NULL DEFAULT 3 CHECK (training_days BETWEEN 0 AND 7),
  session_minutes   int NOT NULL DEFAULT 45 CHECK (session_minutes BETWEEN 10 AND 180),
  injuries          text[] NOT NULL DEFAULT '{}',
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- ─── training history ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS workouts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  performed_on date NOT NULL,
  -- 'upper' | 'lower' | 'full_body' | 'push' | 'pull' | 'cardio' | 'mobility' | 'rest'
  focus       text NOT NULL,
  minutes     int,
  perceived_effort int CHECK (perceived_effort BETWEEN 1 AND 10),
  notes       text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS workouts_user_date ON workouts (user_id, performed_on DESC);

-- Per-exercise detail, so progression can be suggested from real numbers
-- rather than invented ones.
CREATE TABLE IF NOT EXISTS workout_sets (
  id          bigserial PRIMARY KEY,
  workout_id  uuid NOT NULL REFERENCES workouts(id) ON DELETE CASCADE,
  exercise    text NOT NULL,
  sets        int  NOT NULL CHECK (sets BETWEEN 1 AND 20),
  reps        int  CHECK (reps BETWEEN 1 AND 100),
  weight_kg   numeric(6,2),
  position    int  NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS workout_sets_workout ON workout_sets (workout_id, position);
CREATE INDEX IF NOT EXISTS workout_sets_exercise ON workout_sets (exercise);

-- ─── sleep ──────────────────────────────────────────────────────────────────
-- HealthKit can supply this; the column exists so advice can reference it
-- instead of guessing.
ALTER TABLE health_daily ADD COLUMN IF NOT EXISTS sleep_minutes int;
ALTER TABLE health_daily ADD COLUMN IF NOT EXISTS resting_hr int;

-- ─── coach conversation gains an intent label ───────────────────────────────
-- Lets us see which kinds of question people actually ask, and spot where the
-- classifier is wrong, without reading anyone's messages.
ALTER TABLE coach_messages ADD COLUMN IF NOT EXISTS intent text;
