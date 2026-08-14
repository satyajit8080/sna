-- 0004 — entitlements, per-feature usage, notifications, analytics.
-- Additive and idempotent, like every migration before it.

-- ─── backend-configured limits (source of truth; iOS renders these) ──────────
CREATE TABLE IF NOT EXISTS entitlement_config (
  plan            text NOT NULL,
  feature         text NOT NULL,
  period_limit    int,                        -- NULL = unlimited
  abuse_limit     int NOT NULL DEFAULT 200,   -- applies even to "unlimited"
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (plan, feature)
);

INSERT INTO entitlement_config (plan, feature, period_limit, abuse_limit) VALUES
  ('free', 'food_scan',   2,    20),
  ('free', 'coach',       2,    20),
  ('free', 'meal_plan',   0,     0),
  ('pro',  'food_scan',   NULL, 300),
  ('pro',  'coach',       NULL, 300),
  ('pro',  'meal_plan',   NULL, 100)
ON CONFLICT (plan, feature) DO NOTHING;

-- ─── billing period, so usage resets with the subscription, not a rolling 7d ─
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS period_start timestamptz NOT NULL DEFAULT now();
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS period_end   timestamptz NOT NULL DEFAULT (now() + interval '30 days');

-- ai_usage already carries kind/status/request_id/counts_against_quota from
-- 0002. `feature` maps a raw AI kind onto a billable entitlement.
ALTER TABLE ai_usage ADD COLUMN IF NOT EXISTS feature text;
UPDATE ai_usage SET feature = 'food_scan'
  WHERE feature IS NULL AND kind IN ('image', 'text', 'voice', 'barcode');

CREATE INDEX IF NOT EXISTS ai_usage_feature_idx
  ON ai_usage (user_id, feature, created_at DESC)
  WHERE status <> 'failed' AND cache_hit = false;

-- ─── AI coach ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS coach_messages (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role        text NOT NULL CHECK (role IN ('user', 'assistant')),
  content     text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS coach_user_time ON coach_messages (user_id, created_at DESC);

-- ─── meal planner ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS meal_plans (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  span        text NOT NULL CHECK (span IN ('day', 'week')),
  starts_on   date NOT NULL,
  plan        jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS meal_plans_user ON meal_plans (user_id, starts_on DESC);

CREATE TABLE IF NOT EXISTS food_preferences (
  user_id     uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  diet        text,                      -- vegetarian | vegan | halal | none
  cuisines    text[] NOT NULL DEFAULT '{}',
  dislikes    text[] NOT NULL DEFAULT '{}',
  allergies   text[] NOT NULL DEFAULT '{}',
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ─── notifications ───────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS notification_prefs (
  user_id          uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  daily_coach      boolean NOT NULL DEFAULT true,
  morning_hour     int     NOT NULL DEFAULT 8 CHECK (morning_hour BETWEEN 0 AND 23),
  morning_minute   int     NOT NULL DEFAULT 0 CHECK (morning_minute BETWEEN 0 AND 59),
  meal_reminders   boolean NOT NULL DEFAULT false,
  food_logging     boolean NOT NULL DEFAULT false,
  coach_reminder   boolean NOT NULL DEFAULT false,
  premium_offers   boolean NOT NULL DEFAULT true,
  timezone         text    NOT NULL DEFAULT 'UTC',
  permission       text    NOT NULL DEFAULT 'undetermined'
                     CHECK (permission IN ('undetermined','granted','denied')),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

-- Rate-limits promotional pushes so a free user is never spammed.
CREATE TABLE IF NOT EXISTS conversion_notifications (
  id          bigserial PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  trigger     text NOT NULL,
  sent_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS conv_notif_user ON conversion_notifications (user_id, sent_at DESC);

-- ─── analytics ───────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS analytics_events (
  id          bigserial PRIMARY KEY,
  user_id     uuid REFERENCES users(id) ON DELETE CASCADE,
  name        text NOT NULL,
  props       jsonb NOT NULL DEFAULT '{}',
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS analytics_name_time ON analytics_events (name, created_at DESC);
CREATE INDEX IF NOT EXISTS analytics_user_time ON analytics_events (user_id, created_at DESC);

-- ─── weekly premium report ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS weekly_reports (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  week_start  date NOT NULL,
  metrics     jsonb NOT NULL,
  insight     text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, week_start)
);

-- ─── HealthKit daily rollup (written by the app, read by coach/report) ───────
CREATE TABLE IF NOT EXISTS health_daily (
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  logged_on     date NOT NULL,
  steps         int,
  active_kcal   int,
  resting_kcal  int,
  exercise_min  int,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, logged_on)
);
