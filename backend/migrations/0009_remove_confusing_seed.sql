-- 0009 — remove a seeded dish whose name reads as an unwanted suggestion.
--
-- "butter chicken poutine" is a real Canadian dish, but it surfaces to US/CA
-- users as "Butter Chicken" — the exact recommendation reported as wrong. The
-- name is not worth the confusion.
DELETE FROM food_database
 WHERE source = 'curated'
   AND name = 'butter chicken poutine';

-- Nothing may reference it afterwards.
DELETE FROM suggestion_log
 WHERE lower(food_name) = 'butter chicken poutine';

-- Replacement so the Canadian set does not shrink.
INSERT INTO food_database
  (name, aliases, cuisine, source, kcal_100g, protein_100g, carbs_100g, fat_100g,
   fiber_100g, default_unit, default_grams, verified)
VALUES
  ('maple glazed salmon', ARRAY['glazed salmon'], 'canadian', 'curated',
   215, 22.0, 7.0, 11.0, 0.0, 'fillet', 150, true)
ON CONFLICT (name) WHERE source = 'curated' DO NOTHING;
