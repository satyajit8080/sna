-- 0013 — final pass on USDA names left as classification fragments.
--
-- 0012 matched noise with `\ybroiler\y`, which never fires on "Broilers" —
-- there is no word boundary before the plural s. Using substring matching
-- instead, and rebuilding from the original description kept in `aliases`.
--
-- Idempotent: only rows whose *current* name still reads as a USDA grouping
-- are touched.
WITH candidate AS (
  SELECT f.id,
         f.name AS current_name,
         (SELECT a FROM unnest(f.aliases) AS a
           WHERE a LIKE '%,%'
           ORDER BY length(a) DESC
           LIMIT 1) AS source_name
    FROM food_database f
   WHERE f.source = 'usda'
     AND (f.name ILIKE '%broiler%'
       OR f.name ILIKE '%fryer%'
       OR f.name ILIKE '%includes%'
       OR f.name ILIKE '%variet%'
       OR f.name ILIKE '%all classes%'
       OR f.name ILIKE '%composite%'
       OR f.name ILIKE '%commodity%'
       OR f.name LIKE '%,%')
),
cleaned AS (
  SELECT id,
         (string_to_array(
            regexp_replace(
              regexp_replace(
                lower(source_name),
                ',[^,]*(broiler|fryer|includes|variet|all classes|composite|commodity|usda distribution)[^,]*',
                '', 'g'),
              ',\s*(raw|cooked|boiled|canned|frozen|dried|unprepared|dry heat|moist heat|with salt|without salt|drained|solids|commercially prepared|prepared|commercial|nfs|not further specified|meat only|meat and skin|roasted|baked|grilled|braised|stewed)[^,]*',
              '', 'g'),
            ',')) AS parts
    FROM candidate
   WHERE source_name IS NOT NULL
)
UPDATE food_database f
   SET name = initcap(
         regexp_replace(
           btrim(
             CASE
               WHEN array_length(c.parts, 1) >= 2
                AND btrim(c.parts[2]) IN ('red','white','green','yellow','brown','black',
                                          'ground','whole','skim','sweet','baby','wild','fresh','lean')
                 THEN btrim(c.parts[2]) || ' ' || btrim(c.parts[1])
               WHEN array_length(c.parts, 1) >= 2
                AND btrim(c.parts[2]) IN ('breast','thigh','wing','drumstick','leg','loin',
                                          'fillet','filet','mince','steak','chop','rib',
                                          'shoulder','belly','shank','tenderloin','liver','roast')
                 THEN btrim(c.parts[1]) || ' ' || btrim(c.parts[2])
               WHEN array_length(c.parts, 1) >= 2
                AND btrim(c.parts[1]) IN ('fish','chicken','beef','pork','lamb','turkey','veal',
                                          'bread','cheese','milk','oil','nuts','cereals','soup',
                                          'snacks','beverages','candies')
                 THEN btrim(c.parts[2])
               WHEN array_length(c.parts, 1) >= 2
                 THEN btrim(c.parts[2]) || ' ' || btrim(c.parts[1])
               ELSE btrim(c.parts[1])
             END),
           '\s+', ' ', 'g'))
  FROM cleaned c
 WHERE f.id = c.id
   AND array_length(c.parts, 1) >= 1
   AND btrim(c.parts[1]) <> '';
