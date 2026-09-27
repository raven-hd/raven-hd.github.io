-- Запуск: supabase test db   (нужны Supabase CLI и локальная база: supabase start).
-- Тест выполняется в транзакции и откатывается — данные базы не меняются.
-- supabase/tests/database/01_fleet_rules.test.sql
-- Правила расстановки: сервер принимает только корректный флот.
begin;
create extension if not exists pgtap with schema extensions;
select plan(5);

select lives_ok(
  $$ select public.assert_valid_fleet('[
    {"length":4,"cells":["A1","B1","C1","D1"]},
    {"length":3,"cells":["F1","G1","H1"]},
    {"length":3,"cells":["A3","B3","C3"]},
    {"length":2,"cells":["E3","F3"]},
    {"length":2,"cells":["H3","I3"]},
    {"length":2,"cells":["A5","B5"]},
    {"length":1,"cells":["D5"]},
    {"length":1,"cells":["F5"]},
    {"length":1,"cells":["H5"]},
    {"length":1,"cells":["J5"]}
  ]'::jsonb) $$,
  'правильный флот принимается'
);

select throws_ok(
  $$ select public.assert_valid_fleet('[]'::jsonb) $$,
  'P0001', 'Invalid fleet', 'пустой флот отклоняется'
);

-- катер C4 стоит вплотную к крейсеру A3-C3
select throws_ok(
  $$ select public.assert_valid_fleet('[
    {"length":4,"cells":["A1","B1","C1","D1"]},
    {"length":3,"cells":["F1","G1","H1"]},
    {"length":3,"cells":["A3","B3","C3"]},
    {"length":2,"cells":["E3","F3"]},
    {"length":2,"cells":["H3","I3"]},
    {"length":2,"cells":["A5","B5"]},
    {"length":1,"cells":["C4"]},
    {"length":1,"cells":["F5"]},
    {"length":1,"cells":["H5"]},
    {"length":1,"cells":["J5"]}
  ]'::jsonb) $$,
  'P0001', 'Invalid fleet', 'корабли не могут касаться друг друга'
);

-- вместо катера — второй эсминец сверх нормы
select throws_ok(
  $$ select public.assert_valid_fleet('[
    {"length":4,"cells":["A1","B1","C1","D1"]},
    {"length":3,"cells":["F1","G1","H1"]},
    {"length":3,"cells":["A3","B3","C3"]},
    {"length":2,"cells":["E3","F3"]},
    {"length":2,"cells":["H3","I3"]},
    {"length":2,"cells":["A5","B5"]},
    {"length":1,"cells":["D5"]},
    {"length":1,"cells":["F5"]},
    {"length":1,"cells":["H5"]},
    {"length":2,"cells":["J5","J6"]}
  ]'::jsonb) $$,
  'P0001', 'Invalid fleet', 'состав флота должен быть ровно 1-2-3-4'
);

-- клетка за пределами поля
select throws_ok(
  $$ select public.assert_valid_fleet('[
    {"length":4,"cells":["A1","B1","C1","D1"]},
    {"length":3,"cells":["F1","G1","H1"]},
    {"length":3,"cells":["A3","B3","C3"]},
    {"length":2,"cells":["E3","F3"]},
    {"length":2,"cells":["H3","I3"]},
    {"length":2,"cells":["A5","B5"]},
    {"length":1,"cells":["D5"]},
    {"length":1,"cells":["F5"]},
    {"length":1,"cells":["H5"]},
    {"length":1,"cells":["K5"]}
  ]'::jsonb) $$,
  'P0001', 'Invalid fleet', 'клетки за пределами поля отклоняются'
);

select * from finish();
rollback;
