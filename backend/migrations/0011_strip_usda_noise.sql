-- 0011 — strip USDA's internal grouping fragments.
--
-- 0010 removed preparation clauses but not groupings like
-- "broilers or fryers", so "Chicken, broilers or fryers, breast, ..." became
-- "Broilers Or Fryers". Anything containing " or ", or the words broilers /
-- fryers / includes / variety, is a USDA classification, never a food name.
--
-- Written as a separate migration because 0010 has already been applied
-- elsewhere and an applied migration must not be edited.
WITH parsed AS (
  SELECT id,
         (string_to_array(
            regexp_replace(
              lower(name),
              ',\s*[^,]*\y(broilers|fryers|includes|variet|all classes|composite)\y[^,]*',
              '', 'g'),
            ',')) AS parts
    FROM food_database
   WHERE source = 'usda'
     AND (name ILIKE '%broiler%' OR name ILIKE '%fryer%'
          OR name ILIKE '%includes%' OR name ILIKE '%variet%'
          OR name ILIKE '%all classes%' OR name ILIKE '%composite%')
)
UPDATE food_database f
   SET name = initcap(btrim(array_to_string(p.parts, ' ')))
  FROM parsed p
 WHERE f.id = p.id
   AND array_length(p.parts, 1) >= 1
   AND btrim(array_to_string(p.parts, ' ')) <> '';

-- Rebuild names that lost their food word entirely: recover it from the
-- original description preserved in aliases.
UPDATE food_database f
   SET name = initcap(btrim(split_part(a.original, ',', 1)) || ' ' || lower(f.name))
  FROM (
    SELECT id, unnest(aliases) AS original
      FROM food_database
     WHERE source = 'usda'
  ) a
 WHERE f.id = a.id
   AND a.original LIKE '%,%'
   AND lower(f.name) IN ('breast','thigh','wing','drumstick','leg','loin',
                         'fillet','filet','mince','steak','chop','rib',
                         'shoulder','belly','shank','tenderloin','liver','roast');

-- Collapse any doubled whitespace left behind.
UPDATE food_database
   SET name = regexp_replace(btrim(name), '\s+', ' ', 'g')
 WHERE source = 'usda' AND name ~ '\s{2,}';
