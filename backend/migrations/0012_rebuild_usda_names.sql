-- 0012 — rebuild USDA names from the original description.
--
-- 0010 stripped the commas before 0011 could remove grouping fragments, so
-- "Chicken, broilers or fryers, breast, ..." was left as "Broilers Or Fryers".
-- Editing either migration is not an option once applied, so this rebuilds
-- affected rows from the untouched original held in `aliases`.
--
-- Idempotent: rows already correct match none of the noise patterns.
WITH original AS (
  SELECT f.id,
         f.name AS current_name,
         (SELECT a FROM unnest(f.aliases) AS a
           WHERE a LIKE '%,%'
           ORDER BY length(a) DESC
           LIMIT 1) AS source_name
    FROM food_database f
   WHERE f.source = 'usda'
),
cleaned AS (
  SELECT id,
         current_name,
         (string_to_array(
            regexp_replace(
              regexp_replace(
                source_name,
                ',\s*[^,]*\y(broilers|fryers|includes|variet|all classes|composite|usda distribution|commodity)\y[^,]*',
                '', 'g'),
              ',\s*(raw|cooked|boiled|canned|frozen|dried|unprepared|dry heat|moist heat|with salt|without salt|drained|solids|commercially prepared|prepared|all commercial varieties|commercial|nfs|not further specified|meat only|meat and skin)\y[^,]*',
              '', 'g'),
            ',')) AS parts
    FROM original
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
   AND btrim(c.parts[1]) <> ''
   -- Only touch rows that still look like a classification.
   AND (c.current_name ~* '\y(broiler|fryer|includes|variet|all classes|composite)\y'
        OR c.current_name LIKE '%,%');
