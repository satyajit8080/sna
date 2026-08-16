-- 0016 — record which onboarding questions have actually been answered.
--
-- `training_days` and `session_minutes` were created NOT NULL DEFAULT in 0014,
-- so their value cannot distinguish "the user chose 3" from "nobody has been
-- asked". Onboarding therefore re-asked them forever. An explicit list of
-- answered fields is unambiguous and survives future default changes.
ALTER TABLE fitness_profile
  ADD COLUMN IF NOT EXISTS answered_fields text[] NOT NULL DEFAULT '{}';

-- Anyone already marked complete has answered everything.
UPDATE fitness_profile
   SET answered_fields = ARRAY['primary_goal','experience','training_location',
                               'equipment_list','training_days','session_minutes',
                               'average_sleep_hours','limitations_asked']
 WHERE profile_completed
   AND cardinality(answered_fields) = 0;
