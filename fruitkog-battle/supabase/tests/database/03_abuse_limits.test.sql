-- Запуск: supabase test db   (нужны Supabase CLI и локальная база: supabase start).
-- Тест выполняется в транзакции и откатывается — данные базы не меняются.
-- supabase/tests/database/03_abuse_limits.test.sql
-- Защита от флуда (миграция 034): лимит открытых комнат, лимит частоты,
-- системные вставки без пользователя не ограничиваются, предел размера флота.
begin;
create extension if not exists pgtap with schema extensions;
select plan(7);

insert into auth.users(id, email, raw_user_meta_data) values
  ('cccccccc-0000-4000-8000-000000000003', 'c@test.local', '{"school_nick":"Тест В"}');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"cccccccc-0000-4000-8000-000000000003","role":"authenticated"}', true);

-- Не больше 5 открытых комнат одновременно
select lives_ok(
  $$ select public.create_game(gen_random_uuid(), 'casual') from generate_series(1, 5) $$,
  'можно держать 5 открытых комнат'
);
select throws_ok(
  $$ select public.create_game(gen_random_uuid(), 'casual') $$,
  'P0001', 'Too many open rooms', 'шестая открытая комната — отказ'
);

-- Не больше 15 новых игр в минуту: закрываем комнаты и создаём дальше
select lives_ok(
  $$ select public.cancel_game(id) from public.games
     where player1_id = auth.uid() and status = 'waiting' $$,
  'игрок закрывает свои комнаты'
);
select lives_ok(
  $$ select public.cancel_game((public.create_game(gen_random_uuid(), 'casual') ->> 'id')::uuid)
     from generate_series(1, 10) $$,
  'до 15 новых игр за минуту можно (создал — закрыл)'
);
select throws_ok(
  $$ select public.create_game(gen_random_uuid(), 'casual') $$,
  'P0001', 'Rate limit exceeded', '16-я игра за минуту — отказ'
);

-- Вставки без пользователя (SQL Editor, миграции, серверные задачи) не ограничиваются
reset role;
select set_config('request.jwt.claims', '', true);
select lives_ok(
  $$ insert into public.games(code, player1_id, player1_name)
     select 'SYSTEM' || g, 'cccccccc-0000-4000-8000-000000000003', 'Тест В'
     from generate_series(1, 6) g $$,
  'системные вставки без пользователя не ограничиваются'
);

-- Раздутый флот не сохраняется, даже в обход RPC
select throws_ok(
  $$ insert into public.fleets(game_id, owner_id, ships)
     values ((select id from public.games where code = 'SYSTEM1'),
             'cccccccc-0000-4000-8000-000000000003',
             jsonb_build_array(repeat('x', 20000))) $$,
  'P0001', 'Invalid fleet', 'флот больше 8 КБ отклоняется'
);

select * from finish();
rollback;
