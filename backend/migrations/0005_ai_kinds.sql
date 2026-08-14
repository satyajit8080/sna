-- 0005 — coach and meal_plan are AI request kinds too. The 0001 CHECK predates
-- them, so it rejected every coach question with a constraint violation.
ALTER TABLE ai_usage DROP CONSTRAINT IF EXISTS ai_usage_kind_check;
ALTER TABLE ai_usage ADD CONSTRAINT ai_usage_kind_check
  CHECK (kind IN ('image', 'text', 'voice', 'barcode', 'coach', 'meal_plan'));
