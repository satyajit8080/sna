-- 0008 — North American foods.
-- The curated table was seeded mostly with Indian dishes, so cuisine filtering
-- had almost nothing to choose from for US/CA users and fell through to
-- biryani and curry. Values are cooked, per 100g, home-style.
INSERT INTO food_database (name, aliases, cuisine, source, kcal_100g, protein_100g, carbs_100g, fat_100g, fiber_100g, default_unit, default_grams, verified) VALUES
('grilled chicken thigh',  ARRAY['chicken thigh'],                    'american','curated', 209, 26.0,  0.0, 10.9, 0.0,'piece',  120, true),
('baked salmon',           ARRAY['salmon fillet','salmon'],           'american','curated', 206, 22.1,  0.0, 12.4, 0.0,'fillet', 150, true),
('turkey sandwich',        ARRAY['turkey sub','deli sandwich'],       'american','curated', 175, 13.0, 18.0,  6.0, 1.6,'sandwich',240,true),
('tuna salad sandwich',    ARRAY['tuna sandwich'],                    'american','curated', 205, 12.0, 20.0,  9.0, 1.4,'sandwich',220,true),
('oatmeal',                ARRAY['porridge','oats'],                  'american','curated',  84,  3.0, 15.0,  1.7, 2.4,'bowl',   220, true),
('greek yogurt',           ARRAY['yoghurt','greek yoghurt'],          'american','curated',  59, 10.0,  3.6,  0.4, 0.0,'cup',    170, true),
('scrambled eggs',         ARRAY['eggs','fried eggs'],                'american','curated', 141, 10.0,  1.5, 10.5, 0.0,'egg',     55, true),
('turkey chili',           ARRAY['chili','chilli con carne'],         'american','curated', 118, 11.0,  9.0,  4.0, 2.8,'bowl',   300, true),
('beef burrito bowl',      ARRAY['burrito bowl'],                     'american','curated', 155, 10.0, 17.0,  5.4, 3.0,'bowl',   400, true),
('chicken caesar salad',   ARRAY['caesar salad'],                     'american','curated', 145, 11.0,  5.0,  9.0, 1.8,'bowl',   300, true),
('cheeseburger',           ARRAY['burger','hamburger'],               'american','curated', 255, 14.0, 20.0, 13.0, 1.3,'burger', 180, true),
('pepperoni pizza slice',  ARRAY['pizza','pizza slice'],              'american','curated', 270, 11.5, 30.0, 11.0, 2.0,'slice',  110, true),
('grilled steak',          ARRAY['steak','sirloin'],                  'american','curated', 224, 27.0,  0.0, 12.7, 0.0,'steak',  200, true),
('pork chop',              ARRAY['grilled pork chop'],                'american','curated', 231, 26.0,  0.0, 14.0, 0.0,'chop',   150, true),
('mac and cheese',         ARRAY['macaroni cheese'],                  'american','curated', 164,  6.5, 20.0,  6.6, 1.0,'bowl',   250, true),
('avocado toast',          ARRAY['toast with avocado'],               'american','curated', 210,  5.5, 20.0, 12.0, 5.0,'slice',  120, true),
('peanut butter sandwich', ARRAY['pb sandwich','pbj'],                'american','curated', 300, 11.0, 33.0, 14.0, 3.4,'sandwich',110,true),
('protein smoothie',       ARRAY['smoothie','protein shake'],         'american','curated',  70,  7.0,  8.0,  1.2, 1.0,'glass',  350, true),
('cottage cheese',         ARRAY[]::text[],                           'american','curated',  98, 11.0,  3.4,  4.3, 0.0,'cup',    220, true),
('roast chicken breast',   ARRAY['roasted chicken'],                  'american','curated', 165, 31.0,  0.0,  3.6, 0.0,'breast', 130, true),
('baked sweet potato',     ARRAY['sweet potato'],                     'american','curated',  90,  2.0, 21.0,  0.1, 3.3,'potato', 200, true),
('brown rice',             ARRAY['rice'],                             'american','curated', 123,  2.7, 26.0,  1.0, 1.8,'cup',    160, true),
('quinoa salad',           ARRAY['quinoa'],                           'american','curated', 143,  5.0, 21.0,  4.0, 2.6,'bowl',   220, true),
('garden salad',           ARRAY['side salad','green salad'],         'american','curated',  83,  2.0,  4.0,  6.5, 1.8,'bowl',   120, true),
('bagel with cream cheese',ARRAY['bagel'],                            'american','curated', 290,  9.0, 43.0,  9.0, 2.0,'bagel',  110, true),
('turkey meatballs',       ARRAY['meatballs'],                        'american','curated', 175, 18.0,  6.0,  9.0, 0.6,'serving',150,true),
('shrimp stir fry',        ARRAY['shrimp','prawn stir fry'],          'american','curated', 110, 14.0,  8.0,  2.8, 1.4,'bowl',   280, true),
('poutine',                ARRAY[]::text[],                           'canadian','curated', 250,  7.0, 27.0, 13.0, 2.0,'serving',300,true),
('maple oatmeal',          ARRAY['maple porridge'],                   'canadian','curated', 105,  3.0, 20.0,  1.8, 2.2,'bowl',   220, true),
('montreal smoked meat sandwich', ARRAY['smoked meat sandwich'],      'canadian','curated', 230, 18.0, 20.0,  9.0, 1.2,'sandwich',250,true),
('peameal bacon',          ARRAY['back bacon'],                       'canadian','curated', 160, 21.0,  1.0,  8.0, 0.0,'serving',100,true),
('butter chicken poutine', ARRAY[]::text[],                           'canadian','curated', 245,  9.5, 22.0, 13.5, 1.8,'serving',300,true)
ON CONFLICT (name) WHERE source = 'curated' DO NOTHING;
