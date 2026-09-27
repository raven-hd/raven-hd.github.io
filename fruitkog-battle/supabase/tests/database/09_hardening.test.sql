-- Запуск: supabase test db   (нужны Supabase CLI и локальная база: supabase start).
-- Тест выполняется в транзакции и откатывается — данные базы не меняются.
-- supabase/tests/database/09_hardening.test.sql
-- Укрепление после повторной проверки (миграция 038): права по умолчанию, проверка защиты
-- видит лишнее, ники без невидимых символов и с одинаковыми пробелами, лимиты частоты,
-- возврат рейтингового режима, архив из последних 100 матчей, турнирные комнаты нельзя
-- открыть заново.
begin;
create extension if not exists pgtap with schema extensions;
select plan(26);

insert into auth.users(id, email, raw_user_meta_data) values
  ('0000ffff-0000-4000-8000-000000000000', 'hd.admin@test.local', '{"school_nick":"Админ Укрепления"}'),
  ('ffff0001-0000-4000-8000-000000000001', 'hd.p1@test.local', '{"school_nick":"Крепкий Первый"}'),
  ('ffff0002-0000-4000-8000-000000000002', 'hd.p2@test.local', '{"school_nick":"Крепкий Второй"}');
insert into auth.users(id, raw_user_meta_data, is_anonymous) values
  ('ffff0009-0000-4000-8000-000000000009', '{}', true),
  ('ffff000a-0000-4000-8000-00000000000a', '{}', true);
insert into public.profiles(user_id, display_name, account_type) values
  ('ffff0009-0000-4000-8000-000000000009', 'Проверочный Гость', 'guest'),
  ('ffff000a-0000-4000-8000-00000000000a', 'Второй Гость', 'guest');
update public.profiles set is_admin = true where user_id = '0000ffff-0000-4000-8000-000000000000';
update public.profiles set school_verified = true
where user_id::text like 'ffff000%' or user_id = '0000ffff-0000-4000-8000-000000000000';

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- ── 1. права по умолчанию и проверка защиты ─────────────────────────────────
create table public.hd_probe(x int);
select ok(not has_table_privilege('anon', 'public.hd_probe', 'SELECT')
      and not has_table_privilege('authenticated', 'public.hd_probe', 'INSERT'),
  'новая таблица в public не открыта браузеру автоматически');
drop table public.hd_probe;

select pg_temp.as_user('0000ffff-0000-4000-8000-000000000000');
select is((public.admin_security_audit()->>'passed')::boolean, true, 'проверка защиты проходит на чистой схеме');
create function public.get_leaderboard(p_extra boolean) returns int language sql as 'select 1';
grant execute on function public.get_leaderboard(boolean) to anon;
select is((public.admin_security_audit()->>'passed')::boolean, false,
  'проверка защиты замечает вторую версию открытой функции с тем же именем');
drop function public.get_leaderboard(boolean);
create view public.hd_probe_view as select user_id from public.profiles;
grant select on public.hd_probe_view to authenticated;
select is((public.admin_security_audit()->>'passed')::boolean, false,
  'проверка защиты замечает открытое представление');
drop view public.hd_probe_view;

-- ── 2. ники без невидимых символов ──────────────────────────────────────────
select throws_ok(
  $$ insert into auth.users(id, email, raw_user_meta_data)
     values ('ffff0003-0000-4000-8000-000000000003', 'hd.p3@test.local',
             jsonb_build_object('school_nick', 'Крепкий' || chr(8203) || ' Второй')) $$,
  'P0001', 'School nick has hidden characters', 'регистрация с символом нулевой ширины отклоняется');
select is(public.is_school_nick_available('Новый' || chr(8238) || 'Ник'), false,
  'ник со сменой направления текста считается недоступным');
select is(public.is_school_nick_available('Совсем Новый Ник'), true, 'обычный свободный ник доступен');
select throws_ok(
  $$ select public.admin_change_school_nick('ffff0001-0000-4000-8000-000000000001', 'Крепкий' || chr(65279) || 'Первый') $$,
  'P0001', 'School nick has hidden characters', 'админ тоже не может поставить ник с невидимым символом');

-- пробелы любого вида (неразрывный, широкий, узкий) — это тот же ник, а не новый
select throws_ok(
  $$ insert into auth.users(id, email, raw_user_meta_data)
     values ('ffff0004-0000-4000-8000-000000000004', 'hd.p4@test.local',
             jsonb_build_object('school_nick', 'Крепкий Первый' || chr(160))) $$,
  'P0001', 'School nick already registered', 'ник с неразрывным пробелом в конце — тот же ник');
select throws_ok(
  $$ insert into auth.users(id, email, raw_user_meta_data)
     values ('ffff0004-0000-4000-8000-000000000004', 'hd.p4@test.local',
             jsonb_build_object('school_nick', chr(12288) || 'Крепкий' || chr(8239) || 'Первый')) $$,
  'P0001', 'School nick already registered', 'широкий пробел в начале и узкий внутри — тоже тот же ник');
select is(public.is_school_nick_available('Крепкий' || chr(160) || 'Первый'), false,
  'проверка «свободен ли ник» очищает пробелы так же, как регистрация');
select throws_ok(
  $$ insert into auth.users(id, email, raw_user_meta_data)
     values ('ffff0004-0000-4000-8000-000000000004', 'hd.p4@test.local',
             jsonb_build_object('school_nick', 'Крепкий' || chr(10240) || 'Четвертый')) $$,
  'P0001', 'School nick has hidden characters', '«пустой» символ Брайля не принимается');
select throws_ok(
  $$ insert into auth.users(id, email, raw_user_meta_data)
     values ('ffff0004-0000-4000-8000-000000000004', 'hd.p4@test.local',
             jsonb_build_object('school_nick', 'Крепкий Четвертый' || chr(917536))) $$,
  'P0001', 'School nick has hidden characters', 'невидимый символ-тег не принимается');
select is(public.admin_change_school_nick('ffff0002-0000-4000-8000-000000000002',
            chr(160) || 'Крепкий' || chr(9) || 'Второй Новый' || chr(12288))->>'display_name',
  'Крепкий Второй Новый', 'админ исправляет ник: пробелы по краям убраны, внутри — обычные');
select set_config('request.jwt.claims', '', true);
update public.profiles set school_verified = true where user_id = 'ffff0002-0000-4000-8000-000000000002';

-- ── 3. вход и выход: рейтинговый режим возвращается, частота ограничена ─────
select pg_temp.as_user('ffff0001-0000-4000-8000-000000000001');
create temp table hd_room as select (public.create_game('5d5d5d5d-0000-4000-8000-000000000001', 'rated')->>'id')::uuid as id;
select pg_temp.as_user('ffff0009-0000-4000-8000-000000000009');
select public.join_public_game((select id from hd_room));
select results_eq($$ select game_type, rating_skip_reason from public.games where id = (select id from hd_room) $$,
  $$ values ('casual'::text, 'guest'::text) $$, 'гость в рейтинговой комнате — матч без рейтинга');
select public.leave_game((select id from hd_room));
select results_eq($$ select game_type, rating_skip_reason, status from public.games where id = (select id from hd_room) $$,
  $$ values ('rated'::text, null::text, 'waiting'::text) $$, 'после выхода гостя комната снова рейтинговая');

select lives_ok($$
  do $b$ begin
    for i in 1..9 loop
      perform public.join_public_game((select id from hd_room));
      perform public.leave_game((select id from hd_room));
    end loop;
  end $b$ $$, 'двадцать входов и выходов за минуту проходят');
select throws_ok($$ select public.join_public_game((select id from hd_room)) $$,
  'P0001', 'Rate limit exceeded', 'двадцать первый вход за минуту отклоняется');

-- пока гость в комнате, админ исправил создателю ник (ник снова не подтвержден):
-- гость все равно может выйти, а комната остается обычной, без рейтинга
select pg_temp.as_user('ffff000a-0000-4000-8000-00000000000a');
select public.join_public_game((select id from hd_room));
select set_config('request.jwt.claims', '', true);
update public.profiles set school_verified = false where user_id = 'ffff0001-0000-4000-8000-000000000001';
select pg_temp.as_user('ffff000a-0000-4000-8000-00000000000a');
select lives_ok($$ select public.leave_game((select id from hd_room)) $$,
  'гость выходит, даже если создателю комнаты сняли подтверждение ника');
select results_eq($$ select game_type, rating_skip_reason, status from public.games where id = (select id from hd_room) $$,
  $$ values ('casual'::text, 'guest'::text, 'waiting'::text) $$, 'такая комната остается обычной');
select set_config('request.jwt.claims', '', true);
update public.profiles set school_verified = true where user_id = 'ffff0001-0000-4000-8000-000000000001';

-- ── 4. заявки на турнир: не больше 5 действий за 10 минут ───────────────────
insert into public.tournaments(id, name, slug, status, tournament_format, max_players)
values ('cd000001-0000-4000-8000-000000000001', 'Кубок лимитов', 'hd-limits', 'registration', 'knockout', 32);
select pg_temp.as_user('ffff0002-0000-4000-8000-000000000002');
select lives_ok($$
  do $b$ begin
    perform public.apply_to_tournament('cd000001-0000-4000-8000-000000000001');
    perform public.withdraw_tournament_application('cd000001-0000-4000-8000-000000000001');
    perform public.apply_to_tournament('cd000001-0000-4000-8000-000000000001');
    perform public.withdraw_tournament_application('cd000001-0000-4000-8000-000000000001');
    perform public.apply_to_tournament('cd000001-0000-4000-8000-000000000001');
  end $b$ $$, 'пять действий с заявкой проходят');
select throws_ok($$ select public.withdraw_tournament_application('cd000001-0000-4000-8000-000000000001') $$,
  'P0001', 'Rate limit exceeded', 'шестое действие за 10 минут отклоняется');

-- ── 5. архив: последние 100 матчей ─────────────────────────────────────────
select set_config('request.jwt.claims', '', true);   -- вставка «от сервера»: лимиты игроков не действуют
insert into public.games(code, game_type, player1_id, player1_name, player2_id, player2_name, status, winner_id, finished_at)
select 'HD' || lpad(i::text, 6, '0'), 'casual',
       'ffff0001-0000-4000-8000-000000000001', 'Крепкий Первый', 'ffff0002-0000-4000-8000-000000000002', 'Крепкий Второй',
       'finished', 'ffff0001-0000-4000-8000-000000000001', now() - (i || ' minutes')::interval
from generate_series(1, 105) as i;
select pg_temp.as_user('ffff0001-0000-4000-8000-000000000001');
select is((select count(*)::int from public.list_match_history()), 100, 'архив отдает последние 100 матчей');

-- ── 6–7. турнирные комнаты: не открыть заново, победитель — только игрок пары ─
select set_config('request.jwt.claims', '', true);
insert into public.tournaments(id, name, slug, status, tournament_format, max_players)
values ('cd000002-0000-4000-8000-000000000002', 'Кубок комнат', 'hd-rooms', 'active', 'knockout', 32);
insert into public.games(id, code, game_type, player1_id, player1_name, player2_id, player2_name, status)
values ('9d9d9d9d-0000-4000-8000-000000000001', 'HDROOM01', 'tournament',
        'ffff0001-0000-4000-8000-000000000001', 'Крепкий Первый', '0000ffff-0000-4000-8000-000000000000', 'Админ Укрепления', 'placing');
insert into public.tournament_matches(tournament_id, stage, round_no, position, player1_id, player2_id, game_id, status)
values ('cd000002-0000-4000-8000-000000000002', 'playoff', 1, 1,
        'ffff0001-0000-4000-8000-000000000001', '0000ffff-0000-4000-8000-000000000000', '9d9d9d9d-0000-4000-8000-000000000001', 'ready');
select pg_temp.as_user('0000ffff-0000-4000-8000-000000000000');
select throws_ok($$ select public.leave_game('9d9d9d9d-0000-4000-8000-000000000001') $$,
  'P0001', 'Tournament match cannot be left', 'даже админ не может «открыть заново» турнирную комнату');
select lives_ok($$ select public.admin_cancel_game('9d9d9d9d-0000-4000-8000-000000000001', 'проверка') $$,
  'закрыть турнирную комнату админ по-прежнему может');

-- посторонний «победитель» (данные поправили в обход функций) не проходит дальше и не завершает турнир
insert into public.games(id, code, game_type, player1_id, player1_name, player2_id, player2_name, status)
values ('9d9d9d9d-0000-4000-8000-000000000002', 'HDROOM02', 'tournament',
        'ffff0001-0000-4000-8000-000000000001', 'Крепкий Первый', 'ffff0002-0000-4000-8000-000000000002', 'Крепкий Второй', 'playing');
insert into public.tournament_matches(tournament_id, stage, round_no, position, player1_id, player2_id, game_id, status)
values ('cd000002-0000-4000-8000-000000000002', 'playoff', 2, 1,
        'ffff0001-0000-4000-8000-000000000001', 'ffff0002-0000-4000-8000-000000000002', '9d9d9d9d-0000-4000-8000-000000000002', 'playing');
select set_config('request.jwt.claims', '', true);
update public.games set status = 'finished', winner_id = 'ffff0009-0000-4000-8000-000000000009', finished_at = now()
where id = '9d9d9d9d-0000-4000-8000-000000000002';
select is((select status from public.tournaments where id = 'cd000002-0000-4000-8000-000000000002'),
  'active'::text, 'победа постороннего не завершает турнир');

select * from finish();
rollback;
