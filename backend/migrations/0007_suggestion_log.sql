-- 0007 — remember what the coach has suggested.
-- Without this the highest-scoring food was proposed on every request, so the
-- coach repeated "grilled chicken breast" indefinitely.
CREATE TABLE IF NOT EXISTS suggestion_log (
  id         bigserial PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  food_id    uuid REFERENCES food_database(id) ON DELETE SET NULL,
  food_name  text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS suggestion_log_user_time
  ON suggestion_log (user_id, created_at DESC);
