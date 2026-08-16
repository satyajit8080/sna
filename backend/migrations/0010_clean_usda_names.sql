-- 0010 — clean USDA record names already cached in food_database.
--
-- `cacheUsda` used to store the raw FDC description, so rows like
-- "Onions, red, raw" ended up in search results and coach suggestions and
-- were shown to users verbatim. New rows are humanised on insert; this fixes
-- the ones already stored.
--
-- The original description is preserved in `aliases`, so search still matches
-- the USDA wording.
UPDATE food_database
   SET aliases = array_append(aliases, lower(name))
 WHERE source = 'usda'
   AND name LIKE '%,%'
   AND NOT (lower(name) = ANY(aliases));

-- Drop preparation and sourcing clauses, then reorder "category, qualifier"
-- into "qualifier category".
WITH parsed AS (
  SELECT id,
         name,
         (string_to_array(
            regexp_replace(
              lower(name),
              ',\s*(raw|cooked|boiled|canned|frozen|dried|unprepared|dry heat|moist heat|with salt|without salt|drained|solids|commercially prepared|prepared|all commercial varieties|commercial|nfs|not further specified|meat only|meat and skin|all classes)\y[^,]*',
              '', 'g'),
            ',')) AS parts
    FROM food_database
   WHERE source = 'usda' AND name LIKE '%,%'
)
UPDATE food_database f
   SET name = initcap(
         btrim(
           CASE
             WHEN array_length(p.parts, 1) >= 2
              AND btrim(p.parts[2]) IN ('red','white','green','yellow','brown','black',
                                        'ground','whole','skim','sweet','baby','wild','fresh','lean')
               THEN btrim(p.parts[2]) || ' ' || btrim(p.parts[1])
             WHEN array_length(p.parts, 1) >= 2
              AND btrim(p.parts[2]) IN ('breast','thigh','wing','drumstick','leg','loin',
                                        'fillet','filet','mince','steak','chop','rib',
                                        'shoulder','belly','shank','tenderloin','liver','roast')
               THEN btrim(p.parts[1]) || ' ' || btrim(p.parts[2])
             WHEN array_length(p.parts, 1) >= 2
              AND btrim(p.parts[1]) IN ('fish','chicken','beef','pork','lamb','turkey','veal',
                                        'bread','cheese','milk','oil','nuts','cereals','soup',
                                        'snacks','beverages','candies')
               THEN btrim(p.parts[2])
             WHEN array_length(p.parts, 1) >= 2
               THEN btrim(p.parts[2]) || ' ' || btrim(p.parts[1])
             ELSE btrim(p.parts[1])
           END))
  FROM parsed p
 WHERE f.id = p.id
   AND array_length(p.parts, 1) >= 1
   AND btrim(p.parts[1]) <> '';

-- Anything still carrying a comma keeps only its first fragment.
UPDATE food_database
   SET name = initcap(btrim(split_part(name, ',', 1)))
 WHERE source = 'usda' AND name LIKE '%,%';
