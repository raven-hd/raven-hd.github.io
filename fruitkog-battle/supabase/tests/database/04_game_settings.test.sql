-- Запуск: supabase test db   (нужны Supabase CLI и локальная база: supabase start).
-- Тест выполняется в транзакции и откатывается — данные базы не меняются.
-- supabase/tests/database/04_game_settings.test.sql
-- Настройки баланса (миграция 035): права, диапазоны и то, что рейтинг
-- действительно считается по настройкам, а не по старым зашитым числам.
begin;
create extension if not exists pgtap with schema extensions;
select plan(19);

-- Значения по умолчанию совпадают с правилами, которые были зашиты в коде
select results_eq(
  $$ select key, value from public.game_settings order by sort_order $$,
  $$ values ('elo_k'::text, 16), ('tournament_points'::text, 12), ('pair_daily_limit'::text, 3) $$,
  'значения по умолчанию совпадают с прежними правилами'
);

-- Игроки: админ и четыре подтверждённых игрока
insert into auth.users(id, email, raw_user_meta_data) values
  ('0000aaaa-0000-4000-8000-000000000001', 'admin.settings@test.local', '{"school_nick":"Админ Настроек"}'),
  ('1111aaaa-0000-4000-8000-000000000001', 'p1.settings@test.local', '{"school_nick":"Игрок Раз"}'),
  ('2222aaaa-0000-4000-8000-000000000002', 'p2.settings@test.local', '{"school_nick":"Игрок Два"}'),
  ('3333aaaa-0000-4000-8000-000000000003', 'p3.settings@test.local', '{"school_nick":"Игрок Три"}'),
  ('4444aaaa-0000-4000-8000-000000000004', 'p4.settings@test.local', '{"school_nick":"Игрок Четыре"}');
update public.profiles set is_admin = true where user_id = '0000aaaa-0000-4000-8000-000000000001';
update public.profiles set school_verified = true where user_id in (
  '1111aaaa-0000-4000-8000-000000000001', '2222aaaa-0000-4000-8000-000000000002',
  '3333aaaa-0000-4000-8000-000000000003', '4444aaaa-0000-4000-8000-000000000004');

set local role authenticated;

-- Обычный игрок: не видит таблицу и не может ничего менять, но видит числа для подсказок
select set_config('request.jwt.claims', '{"sub":"1111aaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);
select throws_ok($$ select * from public.game_settings $$, '42501', null, 'таблица настроек напрямую недоступна');
select throws_ok($$ select public.admin_update_game_setting('elo_k', 32) $$,
  'P0001', 'Admin required', 'обычный игрок не может менять настройки');
select throws_ok($$ select public.admin_get_game_settings() $$,
  'P0001', 'Admin required', 'обычный игрок не видит админский список настроек');
select is(public.get_public_game_settings(),
  '{"elo_k":16,"tournament_points":12,"pair_daily_limit":3}'::jsonb,
  'числа для подсказок доступны игрокам');

-- Админ: проверки диапазона и имени, изменение, кто менял
select set_config('request.jwt.claims', '{"sub":"0000aaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);
select throws_ok($$ select public.admin_update_game_setting('elo_k', 1000) $$,
  'P0001', 'Game setting out of range', 'значение вне допустимого диапазона отклоняется');
select throws_ok($$ select public.admin_update_game_setting('no_such_setting', 5) $$,
  'P0001', 'Unknown game setting', 'неизвестная настройка отклоняется');
select lives_ok($$ select public.admin_update_game_setting('elo_k', 32) $$, 'админ меняет K-фактор');
select is(
  (select (s->>'value')::int from jsonb_array_elements(public.admin_get_game_settings()) s where s->>'key' = 'elo_k'),
  32, 'новое значение сохранено');
select is(
  (select s->>'updated_by_name' from jsonb_array_elements(public.admin_get_game_settings()) s where s->>'key' = 'elo_k'),
  'Админ Настроек'::text, 'запомнено, кто изменил настройку');
select is((public.get_public_game_settings()->>'elo_k')::int, 32, 'подсказки для игроков видят новое значение');

-- Рейтинговая партия при K = 32: равные соперники, победитель получает K/2 = 16
select set_config('request.jwt.claims', '{"sub":"1111aaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);
do $$ begin perform public.create_game('51111111-1111-4111-8111-111111111111', 'rated'); end $$;
select set_config('request.jwt.claims', '{"sub":"2222aaaa-0000-4000-8000-000000000002","role":"authenticated"}', true);
do $$ begin
  perform public.join_public_game(
    (select id from public.games where player1_id = '1111aaaa-0000-4000-8000-000000000001' and status = 'waiting'));
  perform public.ready_with_fleet(
    (select id from public.games where player2_id = auth.uid() and status = 'placing'),
    '[{"length":4,"cells":["A1","B1","C1","D1"]},{"length":3,"cells":["F1","G1","H1"]},
      {"length":3,"cells":["A3","B3","C3"]},{"length":2,"cells":["E3","F3"]},
      {"length":2,"cells":["H3","I3"]},{"length":2,"cells":["A5","B5"]},
      {"length":1,"cells":["D5"]},{"length":1,"cells":["F5"]},
      {"length":1,"cells":["H5"]},{"length":1,"cells":["J5"]}]'::jsonb);
end $$;
select set_config('request.jwt.claims', '{"sub":"1111aaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);
do $$ begin
  perform public.ready_with_fleet(
    (select id from public.games where player1_id = auth.uid() and status = 'placing'),
    '[{"length":4,"cells":["A1","B1","C1","D1"]},{"length":3,"cells":["F1","G1","H1"]},
      {"length":3,"cells":["A3","B3","C3"]},{"length":2,"cells":["E3","F3"]},
      {"length":2,"cells":["H3","I3"]},{"length":2,"cells":["A5","B5"]},
      {"length":1,"cells":["D5"]},{"length":1,"cells":["F5"]},
      {"length":1,"cells":["H5"]},{"length":1,"cells":["J5"]}]'::jsonb);
end $$;
select set_config('request.jwt.claims', '{"sub":"2222aaaa-0000-4000-8000-000000000002","role":"authenticated"}', true);
do $$ begin
  perform public.surrender_game(
    (select id from public.games where status = 'playing' and auth.uid() in (player1_id, player2_id)));
end $$;
select is((select rating from public.profiles where user_id = '1111aaaa-0000-4000-8000-000000000001'),
  1016, 'при K = 32 победитель получил 16 очков');
select is((select rating from public.profiles where user_id = '2222aaaa-0000-4000-8000-000000000002'),
  984, 'при K = 32 проигравший потерял 16 очков');

-- Лимит пары = 1: следующая рейтинговая партия той же пары за сутки идёт без рейтинга
select set_config('request.jwt.claims', '{"sub":"0000aaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);
do $$ begin perform public.admin_update_game_setting('pair_daily_limit', 1); end $$;
select set_config('request.jwt.claims', '{"sub":"1111aaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);
do $$ begin perform public.create_game('52222222-2222-4222-8222-222222222222', 'rated'); end $$;
select set_config('request.jwt.claims', '{"sub":"2222aaaa-0000-4000-8000-000000000002","role":"authenticated"}', true);
do $$ begin
  perform public.join_public_game(
    (select id from public.games where player1_id = '1111aaaa-0000-4000-8000-000000000001' and status = 'waiting'));
end $$;
select is(
  (select game_type from public.games where player2_id = auth.uid() and status = 'placing'),
  'casual'::text, 'при лимите 1 вторая партия пары за сутки идёт без рейтинга');
select is(
  (select rating_skip_reason from public.games where player2_id = auth.uid() and status = 'placing'),
  'pair_daily_limit'::text, 'причина — лимит пары');

-- Турнирные очки = 20: матч завершённого турнира начисляется по настройке
select set_config('request.jwt.claims', '{"sub":"0000aaaa-0000-4000-8000-000000000001","role":"authenticated"}', true);
do $$ begin perform public.admin_update_game_setting('tournament_points', 20); end $$;
reset role;
select set_config('request.jwt.claims', '', true);
insert into public.tournaments(id, name, slug, status, tournament_format)
values ('7777aaaa-0000-4000-8000-000000000007', 'Тестовый турнир настроек', 'test-settings-cup', 'finished', 'knockout');
insert into public.games(id, code, game_type, player1_id, player1_name, player2_id, player2_name, status, winner_id, finished_at)
values ('8888aaaa-0000-4000-8000-000000000008', 'TSETT001', 'tournament',
  '3333aaaa-0000-4000-8000-000000000003', 'Игрок Три', '4444aaaa-0000-4000-8000-000000000004', 'Игрок Четыре',
  'finished', '3333aaaa-0000-4000-8000-000000000003', now());
insert into public.tournament_matches(tournament_id, stage, round_no, position, player1_id, player2_id, winner_id, game_id, status, result_reason)
values ('7777aaaa-0000-4000-8000-000000000007', 'playoff', 1, 1,
  '3333aaaa-0000-4000-8000-000000000003', '4444aaaa-0000-4000-8000-000000000004',
  '3333aaaa-0000-4000-8000-000000000003', '8888aaaa-0000-4000-8000-000000000008', 'finished', 'game');
do $$ begin perform public.apply_tournament_ratings('7777aaaa-0000-4000-8000-000000000007'); end $$;
select is((select rating from public.profiles where user_id = '3333aaaa-0000-4000-8000-000000000003'),
  1020, 'победитель турнирного матча получил 20 очков');
select is((select rating from public.profiles where user_id = '4444aaaa-0000-4000-8000-000000000004'),
  980, 'проигравший турнирного матча потерял 20 очков');
select is((select tournament_rating_delta from public.games where id = '8888aaaa-0000-4000-8000-000000000008'),
  20, 'в матче записано изменение 20');
select ok(exists(
  select 1 from public.user_notifications
  where recipient_id = '3333aaaa-0000-4000-8000-000000000003' and kind = 'reward' and body like '%рейтинг +20 %'),
  'уведомление победителю показывает +20');

select * from finish();
rollback;
