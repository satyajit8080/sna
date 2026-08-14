-- 0001_init — base schema. Additive and idempotent: safe to re-run in production.
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "citext";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ─── identity ────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email           citext UNIQUE,
  apple_sub       text UNIQUE,
  password_hash   text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  deleted_at      timestamptz
);

CREATE TABLE IF NOT EXISTS profiles (
  user_id         uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  name            text NOT NULL,
  birth_year      int  NOT NULL,
  sex             text NOT NULL CHECK (sex IN ('male','female','other')),
  height_cm       numeric(5,1) NOT NULL,
  start_weight_kg numeric(5,2) NOT NULL,
  goal_weight_kg  numeric(5,2) NOT NULL,
  goal            text NOT NULL CHECK (goal IN ('lose','maintain','gain')),
  activity_level  text NOT NULL CHECK (activity_level IN ('sedentary','light','moderate','active','very_active')),
  units           text NOT NULL DEFAULT 'metric' CHECK (units IN ('metric','imperial')),
  country         text,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS nutrition_targets (
  user_id     uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  calories    int NOT NULL,
  protein_g   int NOT NULL,
  carbs_g     int NOT NULL,
  fat_g       int NOT NULL,
  water_ml    int NOT NULL DEFAULT 2500,
  bmr         int NOT NULL,
  tdee        int NOT NULL,
  source      text NOT NULL DEFAULT 'auto' CHECK (source IN ('auto','manual')),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ─── food ────────────────────────────────────────────────────────────────────
-- Canonical per-100g nutrition. Seeded with USDA + curated regional items.
CREATE TABLE IF NOT EXISTS food_database (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  aliases       text[] NOT NULL DEFAULT '{}',
  cuisine       text,                       -- indian | american | british | global
  source        text NOT NULL,              -- usda | openfoodfacts | curated | ai
  source_ref    text,                       -- fdcId / barcode
  barcode       text UNIQUE,
  brand         text,
  kcal_100g     numeric(7,2) NOT NULL,
  protein_100g  numeric(6,2) NOT NULL,
  carbs_100g    numeric(6,2) NOT NULL,
  fat_100g      numeric(6,2) NOT NULL,
  fiber_100g    numeric(6,2),
  -- default household portion, e.g. {"unit":"roti","grams":45}
  default_unit  text,
  default_grams numeric(7,2),
  verified      boolean NOT NULL DEFAULT false,
  fetched_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS food_name_trgm ON food_database USING gin (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS food_alias_idx ON food_database USING gin (aliases);
CREATE INDEX IF NOT EXISTS food_cuisine_idx ON food_database (cuisine);

-- ─── logging ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS meals (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  logged_on     date NOT NULL,                -- user-local date
  logged_at     timestamptz NOT NULL DEFAULT now(),
  slot          text NOT NULL CHECK (slot IN ('breakfast','lunch','dinner','snack')),
  input_method  text NOT NULL CHECK (input_method IN ('photo','text','voice','barcode','search','manual')),
  note          text,
  image_url     text,                          -- null unless user opted in
  ai_confidence numeric(3,2),
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS meals_user_day ON meals (user_id, logged_on DESC);

CREATE TABLE IF NOT EXISTS meal_items (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  meal_id       uuid NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
  food_id       uuid REFERENCES food_database(id),
  name          text NOT NULL,
  quantity      numeric(8,2) NOT NULL DEFAULT 1,
  unit          text NOT NULL DEFAULT 'g',
  grams         numeric(8,2) NOT NULL,
  kcal_100g     numeric(7,2) NOT NULL,
  protein_100g  numeric(6,2) NOT NULL,
  carbs_100g    numeric(6,2) NOT NULL,
  fat_100g      numeric(6,2) NOT NULL,
  is_estimate   boolean NOT NULL DEFAULT true,
  confidence    numeric(3,2),
  position      int NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS meal_items_meal ON meal_items (meal_id);

-- Derived macros are always computed from grams * per_100g / 100.
CREATE OR REPLACE VIEW meal_totals AS
SELECT m.id AS meal_id, m.user_id, m.logged_on, m.slot,
       ROUND(SUM(i.grams * i.kcal_100g    / 100))::int AS calories,
       ROUND(SUM(i.grams * i.protein_100g / 100))::int AS protein_g,
       ROUND(SUM(i.grams * i.carbs_100g   / 100))::int AS carbs_g,
       ROUND(SUM(i.grams * i.fat_100g     / 100))::int AS fat_g
FROM meals m JOIN meal_items i ON i.meal_id = m.id
GROUP BY m.id;

CREATE TABLE IF NOT EXISTS weight_logs (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  logged_on  date NOT NULL,
  weight_kg  numeric(5,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, logged_on)
);

CREATE TABLE IF NOT EXISTS water_logs (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  logged_on  date NOT NULL,
  ml         int NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS water_user_day ON water_logs (user_id, logged_on DESC);

-- ─── monetisation ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS subscriptions (
  user_id             uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  plan                text NOT NULL DEFAULT 'free' CHECK (plan IN ('free','pro')),
  product_id          text,
  original_txn_id     text UNIQUE,
  environment         text,                    -- Sandbox | Production
  expires_at          timestamptz,
  auto_renew          boolean NOT NULL DEFAULT false,
  in_trial            boolean NOT NULL DEFAULT false,
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS ai_usage (
  id            bigserial PRIMARY KEY,
  user_id       uuid REFERENCES users(id) ON DELETE SET NULL,
  kind          text NOT NULL CHECK (kind IN ('image','text','voice','barcode')),
  provider      text NOT NULL,
  model         text NOT NULL,
  cache_hit     boolean NOT NULL DEFAULT false,
  escalated     boolean NOT NULL DEFAULT false,
  input_tokens  int NOT NULL DEFAULT 0,
  cached_tokens int NOT NULL DEFAULT 0,
  output_tokens int NOT NULL DEFAULT 0,
  cost_usd      numeric(10,6) NOT NULL DEFAULT 0,
  latency_ms    int,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ai_usage_user_time ON ai_usage (user_id, created_at DESC);

-- Perceptual-hash cache so an identical re-scan never hits the model.
CREATE TABLE IF NOT EXISTS analysis_cache (
  phash      text PRIMARY KEY,
  result     jsonb NOT NULL,
  hits       int NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);
