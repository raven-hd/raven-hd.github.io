-- Запуск: supabase test db   (нужны Supabase CLI и локальная база: supabase start).
-- Тест выполняется в транзакции и откатывается — данные базы не меняются.
-- supabase/tests/database/02_game_flow.test.sql
-- Сквозной сценарий через настоящие RPC от имени настоящих ролей:
-- комната → присоединение → расстановка → выстрелы → сдача → повтор.
begin;
create extension if not exists pgtap with schema extensions;
select plan(13);

-- Тестовые игроки. Триггер on_auth_user_created сам создаст им профили по school_nick.
insert into auth.users(id, email, raw_user_meta_data) values
  ('aaaaaaaa-0000-4000-8000-000000000001', 'a@test.local', '{"school_nick":"Тест А"}'),
  ('bbbbbbbb-0000-4000-8000-000000000002', 'b@test.local', '{"school_nick":"Тест Б"}');

-- Дальше всё — как из браузера: роль authenticated + JWT конкретного игрока.
set local role authenticated;

-- Игрок А создаёт комнату
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select public.create_game('11111111-1111-4111-8111-111111111111', 'casual') $$,
  'игрок А создаёт комнату'
);

-- Игрок Б присоединяется и выставляет флот
select set_config('request.jwt.claims', '{"sub":"bbbbbbbb-0000-4000-8000-000000000002","role":"authenticated"}', true);
select lives_ok(
  $$ select public.join_public_game(
       (select id from public.games
        where player1_id = 'aaaaaaaa-0000-4000-8000-000000000001' and status = 'waiting')) $$,
  'игрок Б присоединяется'
);
select lives_ok(
  $$ select public.ready_with_fleet(
       (select id from public.games where player2_id = auth.uid() and status = 'placing'),
       '[{"length":4,"cells":["A1","B1","C1","D1"]},{"length":3,"cells":["F1","G1","H1"]},
         {"length":3,"cells":["A3","B3","C3"]},{"length":2,"cells":["E3","F3"]},
         {"length":2,"cells":["H3","I3"]},{"length":2,"cells":["A5","B5"]},
         {"length":1,"cells":["D5"]},{"length":1,"cells":["F5"]},
         {"length":1,"cells":["H5"]},{"length":1,"cells":["J5"]}]'::jsonb) $$,
  'игрок Б выставляет флот'
);

-- Игрок А выставляет флот — бой начинается
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);
select lives_ok(
  $$ select public.ready_with_fleet(
       (select id from public.games where player1_id = auth.uid() and status = 'placing'),
       '[{"length":4,"cells":["A1","B1","C1","D1"]},{"length":3,"cells":["F1","G1","H1"]},
         {"length":3,"cells":["A3","B3","C3"]},{"length":2,"cells":["E3","F3"]},
         {"length":2,"cells":["H3","I3"]},{"length":2,"cells":["A5","B5"]},
         {"length":1,"cells":["D5"]},{"length":1,"cells":["F5"]},
         {"length":1,"cells":["H5"]},{"length":1,"cells":["J5"]}]'::jsonb) $$,
  'игрок А выставляет флот'
);
select is(
  (select status from public.games where player1_id = auth.uid() order by created_at desc limit 1),
  'playing'::text,
  'после готовности обоих бой начинается'
);

-- Главный инвариант честной игры: во время боя флот соперника не виден
select is(
  (select count(*) from public.fleets where owner_id = 'bbbbbbbb-0000-4000-8000-000000000002'),
  0::bigint,
  'во время боя флот соперника скрыт'
);

-- Выстрелы. Действуем от имени того, чей сейчас ход (первый ход выбирается случайно).
-- Флоты у обоих одинаковые: A1 — попадание, J10 — промах.
select set_config('request.jwt.claims', json_build_object(
  'sub', (select current_turn from public.games where player1_id = auth.uid() and status = 'playing'),
  'role', 'authenticated')::text, true);
select is(
  public.shoot((select id from public.games where status = 'playing' and auth.uid() in (player1_id, player2_id)), 'A1') ->> 'result',
  'hit'::text,
  'попадание засчитывается'
);
select is(
  (select current_turn from public.games where status = 'playing' and auth.uid() in (player1_id, player2_id)),
  auth.uid(),
  'после попадания ход остаётся у стрелявшего'
);
select is(
  public.shoot((select id from public.games where status = 'playing' and auth.uid() in (player1_id, player2_id)), 'J10') ->> 'result',
  'miss'::text,
  'промах засчитывается'
);
select isnt(
  (select current_turn from public.games where status = 'playing' and auth.uid() in (player1_id, player2_id)),
  auth.uid(),
  'после промаха ход переходит к сопернику'
);

-- Теперь ход соперника: повторный выстрел должен быть отклонён
select throws_ok(
  $$ select public.shoot(
       (select id from public.games where status = 'playing' and auth.uid() in (player1_id, player2_id)),
       'B1') $$,
  'P0001', 'Not your turn', 'стрелять не в свой ход нельзя'
);

-- Сдаться можно в любой момент боя
select lives_ok(
  $$ select public.surrender_game(
       (select id from public.games where status = 'playing' and auth.uid() in (player1_id, player2_id))) $$,
  'игрок может сдаться'
);

-- После конца матча флот соперника открывается для повтора
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is(
  (select count(*) from public.fleets where owner_id = 'bbbbbbbb-0000-4000-8000-000000000002'),
  1::bigint,
  'после конца матча флот соперника открыт для повтора'
);

select * from finish();
rollback;
