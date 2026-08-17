-- 0018 — the notification decision engine.
--
-- `notification_prefs` records what a user is willing to receive and
-- `notification_log` records what was sent. Neither answers the question that
-- actually matters: *should this be sent at all*.
--
-- A reminder app asks "is it 9am yet". A coach asks whether it has anything
-- worth saying, whether it already said it, and whether this person opens
-- things like it. These tables hold what that decision needs.

-- ─── decided notifications ──────────────────────────────────────────────────
-- The client polls this and schedules locally (no APNs), so the server owns
-- the judgement and the phone owns the delivery.
CREATE TABLE IF NOT EXISTS notification_plan (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,

  -- morning | sleep | nutrition | hydration | activity | recovery |
  -- pattern | achievement | coach
  category     text NOT NULL,
  -- critical | high | medium | low
  priority     text NOT NULL CHECK (priority IN ('critical','high','medium','low')),

  title        text NOT NULL,
  body         text NOT NULL,
  -- Deep link so a tap lands somewhere useful rather than the home screen.
  deeplink     text,

  -- When the client should fire it, in the user's local timezone.
  deliver_at   timestamptz NOT NULL,
  planned_on   date NOT NULL,

  /**
   * Why this was worth sending. Stored so a notification can always be
   * explained after the fact — if we cannot say why, it should not have gone.
   */
  rationale    text NOT NULL,
  -- Score at decision time, for tuning the thresholds later.
  score        int NOT NULL DEFAULT 0,

  -- Collapses repeats: one row per user per key per day.
  dedupe_key   text NOT NULL,

  -- planned | sent | opened | dismissed | suppressed | expired
  status       text NOT NULL DEFAULT 'planned',
  suppressed_reason text,

  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, dedupe_key, planned_on)
);
CREATE INDEX IF NOT EXISTS notification_plan_due
  ON notification_plan (user_id, deliver_at)
  WHERE status = 'planned';

-- ─── learned timing and engagement ──────────────────────────────────────────
-- Which categories this person actually opens, and when. Sending at a time
-- someone reliably ignores is indistinguishable from not sending at all,
-- except that it costs their attention.
CREATE TABLE IF NOT EXISTS notification_engagement (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  category    text NOT NULL,
  -- Local hour the notification was delivered at.
  hour        int  NOT NULL CHECK (hour BETWEEN 0 AND 23),
  sent        int  NOT NULL DEFAULT 0,
  opened      int  NOT NULL DEFAULT 0,
  dismissed   int  NOT NULL DEFAULT 0,
  -- Acted on: the recommendation it carried was completed.
  acted       int  NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, category, hour)
);

-- ─── quiet hours and volume ─────────────────────────────────────────────────
ALTER TABLE notification_prefs
  ADD COLUMN IF NOT EXISTS quiet_start time NOT NULL DEFAULT '22:00';
ALTER TABLE notification_prefs
  ADD COLUMN IF NOT EXISTS quiet_end   time NOT NULL DEFAULT '07:00';

-- A ceiling the engine will not exceed regardless of how much it has to say.
-- Three is deliberate: notification fatigue is a leading cause of people
-- turning notifications off entirely, and then we have no channel at all.
ALTER TABLE notification_prefs
  ADD COLUMN IF NOT EXISTS daily_limit int NOT NULL DEFAULT 3
    CHECK (daily_limit BETWEEN 0 AND 10);

-- Categories the user has switched off. Empty means all are allowed.
ALTER TABLE notification_prefs
  ADD COLUMN IF NOT EXISTS muted_categories text[] NOT NULL DEFAULT '{}';

-- Their usual bedtime, used for the wind-down reminder. Distinct from quiet
-- hours: quiet hours are when we stay silent, bedtime is what we coach toward.
ALTER TABLE notification_prefs
  ADD COLUMN IF NOT EXISTS target_bedtime time;
ALTER TABLE notification_prefs
  ADD COLUMN IF NOT EXISTS target_wake_time time;
