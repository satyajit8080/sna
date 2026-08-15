-- 0006 — activity calories, user timezone, dashboard reset semantics.
-- Additive and idempotent like every migration before it.

-- The dashboard resets at the user's local midnight. Storing the zone means a
-- background job (weekly reports, notifications) can compute the same day
-- boundary the app sees, without the request's X-Timezone header.
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'UTC';

-- How much of the day's active burn feeds back into the calorie budget.
--   off     — ignore activity entirely
--   partial — credit 50% (default; TDEE already assumes some movement)
--   full    — credit 100%
-- Partial is the default deliberately: the user's calorie target was derived
-- from an activity level, so crediting 100% of measured activity double-counts
-- movement the target already allowed for.
ALTER TABLE nutrition_targets ADD COLUMN IF NOT EXISTS activity_credit text NOT NULL DEFAULT 'partial'
  ;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'nutrition_targets_activity_credit_chk') THEN
    ALTER TABLE nutrition_targets
      ADD CONSTRAINT nutrition_targets_activity_credit_chk
      CHECK (activity_credit IN ('off', 'partial', 'full'));
  END IF;
END $$;

-- health_daily gained walking distance and a computed burn estimate.
ALTER TABLE health_daily ADD COLUMN IF NOT EXISTS distance_m      int;
ALTER TABLE health_daily ADD COLUMN IF NOT EXISTS flights_climbed int;
-- Whether active_kcal came from HealthKit directly or was estimated from steps.
ALTER TABLE health_daily ADD COLUMN IF NOT EXISTS kcal_source text NOT NULL DEFAULT 'healthkit';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'health_daily_kcal_source_chk') THEN
    ALTER TABLE health_daily
      ADD CONSTRAINT health_daily_kcal_source_chk
      CHECK (kcal_source IN ('healthkit', 'estimated'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS health_daily_user_day ON health_daily (user_id, logged_on DESC);

-- USDA lookups are cached in food_database; record the serving size the API
-- reported so the client can offer "1 serving" instead of only grams.
ALTER TABLE food_database ADD COLUMN IF NOT EXISTS serving_size    numeric(8,2);
ALTER TABLE food_database ADD COLUMN IF NOT EXISTS serving_unit    text;
ALTER TABLE food_database ADD COLUMN IF NOT EXISTS household_serving text;

-- Coach answers are one line; keep the index small and the reads fast.
CREATE INDEX IF NOT EXISTS coach_recent ON coach_messages (user_id, created_at DESC);
