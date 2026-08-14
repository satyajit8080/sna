-- 0002 — constraints required for idempotent seeding and for atomic scan quota.

-- Lets 0003 re-run safely without duplicating curated foods.
CREATE UNIQUE INDEX IF NOT EXISTS food_curated_name_uniq
  ON food_database (name) WHERE source = 'curated';

-- ai_usage doubles as the quota ledger. A row is INSERTed *before* the provider
-- is called (status='reserved') and updated afterwards, so two concurrent
-- requests cannot both observe "1 scan remaining".
ALTER TABLE ai_usage ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'complete';
ALTER TABLE ai_usage ADD COLUMN IF NOT EXISTS reserved_at timestamptz;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ai_usage_status_chk') THEN
    ALTER TABLE ai_usage
      ADD CONSTRAINT ai_usage_status_chk
      CHECK (status IN ('reserved', 'complete', 'failed'));
  END IF;
END $$;

-- The counting index for the rolling-7-day free tier window.
CREATE INDEX IF NOT EXISTS ai_usage_quota_idx
  ON ai_usage (user_id, created_at DESC)
  WHERE status <> 'failed' AND cache_hit = false;

-- One AI call can produce several billed provider calls (Luna then Terra).
-- Each gets its own ai_usage row; they share a request_id so cost analysis can
-- roll them up per user-visible scan.
ALTER TABLE ai_usage ADD COLUMN IF NOT EXISTS request_id uuid;
CREATE INDEX IF NOT EXISTS ai_usage_request_idx ON ai_usage (request_id);

-- Only the primary row of a scan counts against quota; escalation rows do not.
ALTER TABLE ai_usage ADD COLUMN IF NOT EXISTS counts_against_quota boolean NOT NULL DEFAULT true;
