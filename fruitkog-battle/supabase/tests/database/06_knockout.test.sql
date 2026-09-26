-- Запуск: supabase test db   (нужны Supabase CLI и локальная база: supabase start).
-- Тест выполняется в транзакции и откатывается — данные базы не меняются.
-- supabase/tests/database/06_knockout.test.sql
-- Турнир в формате «плей-офф» (миграция 036): сетка строится целиком, лишние места
-- становятся свободными проходами, комнаты создаются сразу, победители продвигаются
-- сами, финал завершает турнир, рейтинг — только за сыгранные матчи.
begin;
create extension if not exists pgtap with schema extensions;
select plan(48);

-- Админ и восемь подтверждённых игроков
insert into auth.users(id, email, raw_user_meta_data) values
  ('0000cccc-0000-4000-8000-000000000000', 'ko.admin@test.local', '{"school_nick":"Админ Кубка"}'),
  ('cccc0001-0000-4000-8000-000000000001', 'ko.p1@test.local', '{"school_nick":"Кубок Первый"}'),
  ('cccc0002-0000-4000-8000-000000000002', 'ko.p2@test.local', '{"school_nick":"Кубок Второй"}'),
  ('cccc0003-0000-4000-8000-000000000003', 'ko.p3@test.local', '{"school_nick":"Кубок Третий"}'),
  ('cccc0004-0000-4000-8000-000000000004', 'ko.p4@test.local', '{"school_nick":"Кубок Четвёртый"}'),
  ('cccc0005-0000-4000-8000-000000000005', 'ko.p5@test.local', '{"school_nick":"Кубок Пятый"}'),
  ('cccc0006-0000-4000-8000-000000000006', 'ko.p6@test.local', '{"school_nick":"Кубок Шестой"}'),
  ('cccc0007-0000-4000-8000-000000000007', 'ko.p7@test.local', '{"school_nick":"Кубок Седьмой"}'),
  ('cccc0008-0000-4000-8000-000000000008', 'ko.p8@test.local', '{"school_nick":"Кубок Восьмой"}');
update public.profiles set is_admin = true where user_id = '0000cccc-0000-4000-8000-000000000000';
update public.profiles set school_verified = true where user_id::text like 'cccc000%';

-- Права: жеребьёвку можно вызвать только войдя (дальше функция пускает только админа)
select ok(has_function_privilege('authenticated', 'public.admin_generate_tournament(uuid)', 'EXECUTE'),
  'вошедший пользователь может вызвать жеребьёвку (внутри — проверка админа)');
select ok(not has_function_privilege('anon', 'public.admin_generate_tournament(uuid)', 'EXECUTE'),
  'без входа жеребьёвка недоступна');

-- Турнир на запись с первыми p_count игроками
create function pg_temp.new_cup(p_id uuid, p_count int, p_format text default 'knockout', p_max int default 32) returns void
language sql as $$
  insert into public.tournaments(id, name, slug, status, tournament_format, max_players)
  values (p_id, 'Кубок на ' || p_count, 'ko-cup-' || p_id, 'registration', p_format, p_max);
  insert into public.tournament_players(tournament_id, user_id, status)
  select p_id, u.id, 'active' from auth.users u where u.email like 'ko.p%' order by u.email limit p_count;
$$;

-- Сыграть турнирный матч: оба расставляют флот, второй игрок сдаётся. Возвращает победителя.
create function pg_temp.play(p_game uuid) returns uuid language plpgsql as $$
declare
  g public.games%rowtype;
  fleet jsonb := '[{"length":4,"cells":["A1","B1","C1","D1"]},{"length":3,"cells":["F1","G1","H1"]},
    {"length":3,"cells":["A3","B3","C3"]},{"length":2,"cells":["E3","F3"]},
    {"length":2,"cells":["H3","I3"]},{"length":2,"cells":["A5","B5"]},
    {"length":1,"cells":["D5"]},{"length":1,"cells":["F5"]},
    {"length":1,"cells":["H5"]},{"length":1,"cells":["J5"]}]';
begin
  select * into g from public.games where id = p_game;
  perform set_config('request.jwt.claims', json_build_object('sub', g.player1_id, 'role', 'authenticated')::text, true);
  perform public.ready_with_fleet(p_game, fleet);
  perform set_config('request.jwt.claims', json_build_object('sub', g.player2_id, 'role', 'authenticated')::text, true);
  perform public.ready_with_fleet(p_game, fleet);
  perform public.surrender_game(p_game);
  return g.player1_id;
end $$;

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- ── Проверки перед жеребьёвкой ─────────────────────────────────────────────
select pg_temp.new_cup('c0c00002-0000-4000-8000-000000000002', 2);
select pg_temp.new_cup('c0c00001-0000-4000-8000-000000000001', 1);
select pg_temp.new_cup('c0c00009-0000-4000-8000-000000000009', 2, null);
select pg_temp.new_cup('c0c0000a-0000-4000-8000-00000000000a', 2, 'qualifiers_playoff');
select pg_temp.new_cup('c0c0000b-0000-4000-8000-00000000000b', 3, 'knockout', 2);

select pg_temp.as_user('cccc0001-0000-4000-8000-000000000001');
select throws_ok($$ select public.admin_generate_tournament('c0c00002-0000-4000-8000-000000000002') $$,
  'P0001', 'Admin required', 'игрок не может проводить жеребьёвку');
select pg_temp.as_user('0000cccc-0000-4000-8000-000000000000');
select throws_ok($$ select public.admin_generate_tournament('c0c00001-0000-4000-8000-000000000001') $$,
  'P0001', 'Tournament needs two players', 'одного участника мало');
select throws_ok($$ select public.admin_generate_tournament('c0c00009-0000-4000-8000-000000000009') $$,
  'P0001', 'Tournament format required', 'без выбранного формата жеребьёвки нет');
select throws_ok($$ select public.admin_generate_tournament('c0c0000a-0000-4000-8000-00000000000a') $$,
  'P0001', 'Qualifying stage setup required', 'для «квалификация + плей-офф» — свой запуск');
select throws_ok($$ select public.admin_generate_tournament('c0c0000b-0000-4000-8000-00000000000b') $$,
  'P0001', 'Tournament is full', 'участников больше лимита');

-- неподтверждённый ник у участника: понятная ошибка, а не случайный сбой при создании комнаты
update public.profiles set school_verified = false where user_id = 'cccc0002-0000-4000-8000-000000000002';
select throws_ok($$ select public.admin_generate_tournament('c0c00002-0000-4000-8000-000000000002') $$,
  'P0001', 'Tournament players must be verified', 'жеребьёвка требует подтверждённые ники всех участников');
update public.profiles set school_verified = true where user_id = 'cccc0002-0000-4000-8000-000000000002';

-- ── 2 участника: сразу финал с комнатой ────────────────────────────────────
select lives_ok($$ select public.admin_generate_tournament('c0c00002-0000-4000-8000-000000000002') $$,
  '2 участника: жеребьёвка проходит');
select results_eq(
  $$ select round_no, status, game_id is not null, player1_id is not null and player2_id is not null
     from public.tournament_matches where tournament_id = 'c0c00002-0000-4000-8000-000000000002' $$,
  $$ values (1, 'ready'::text, true, true) $$,
  '2 участника: один матч (финал) с игровой комнатой');
select is((select status from public.tournaments where id = 'c0c00002-0000-4000-8000-000000000002'),
  'active'::text, 'турнир начался');
select throws_ok($$ select public.admin_generate_tournament('c0c00002-0000-4000-8000-000000000002') $$,
  'P0001', 'Tournament already started', 'повторная жеребьёвка невозможна');

-- удаление турнира после жеребьёвки отменяет его комнаты (иначе они висели бы у игроков)
create temp table deleted_cup_game as
  select game_id from public.tournament_matches where tournament_id = 'c0c00002-0000-4000-8000-000000000002';
select lives_ok($$ select public.admin_delete_tournament('c0c00002-0000-4000-8000-000000000002') $$,
  'админ удаляет турнир после жеребьёвки');
select is((select status from public.games where id = (select game_id from deleted_cup_game)),
  'cancelled'::text, 'комната удалённого турнира отменена');

-- ── 3 участника: сетка на 4, один свободный проход ─────────────────────────
select pg_temp.new_cup('c0c00003-0000-4000-8000-000000000003', 3);
select lives_ok($$ select public.admin_generate_tournament('c0c00003-0000-4000-8000-000000000003') $$,
  '3 участника: жеребьёвка проходит (чётное число больше не требуется)');
select results_eq(
  $$ select round_no, count(*)::int from public.tournament_matches
     where tournament_id = 'c0c00003-0000-4000-8000-000000000003' group by round_no order by round_no $$,
  $$ values (1, 2), (2, 1) $$,
  '3 участника: два матча первого раунда и финал');
select results_eq(
  $$ select status, result_reason, winner_id = player1_id, player2_id is null, game_id is null
     from public.tournament_matches
     where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and round_no = 1 and game_id is null $$,
  $$ values ('technical'::text, 'bye'::text, true, true, true) $$,
  'ровно один свободный проход: игрок сразу считается прошедшим, игры нет');
select results_eq(
  $$ select status, player1_id is not null and player2_id is not null
     from public.tournament_matches
     where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and round_no = 1 and game_id is not null $$,
  $$ values ('ready'::text, true) $$,
  'второй матч первого раунда — настоящий, с комнатой');
select ok(
  (select f.player1_id is not null and f.player1_id = b.winner_id
   from public.tournament_matches f, public.tournament_matches b
   where f.tournament_id = 'c0c00003-0000-4000-8000-000000000003' and f.round_no = 2
     and b.tournament_id = f.tournament_id and b.result_reason = 'bye'),
  'прошедший без игры уже стоит в финале');
select ok(
  (select player2_id is null and game_id is null and status = 'pending'
   from public.tournament_matches where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and round_no = 2),
  'финал ждёт победителя второй пары');
select is(
  (select count(*)::int from public.tournament_matches
   where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and round_no = 1
     and next_match_id = (select id from public.tournament_matches
                          where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and round_no = 2)),
  2, 'обе пары первого раунда ведут в финал');
select results_eq(
  $$ select seed from public.tournament_players where tournament_id = 'c0c00003-0000-4000-8000-000000000003' order by seed $$,
  $$ values (1), (2), (3) $$,
  'посев 1–3 без повторов');
select results_eq(
  $$ select n.recipient_id, n.title, n.game_id is null from public.user_notifications n
     join public.tournament_matches m on m.id = n.tournament_match_id
     where m.tournament_id = 'c0c00003-0000-4000-8000-000000000003' and m.result_reason = 'bye' $$,
  $$ select winner_id, 'первый раунд — без игры'::text, true from public.tournament_matches
     where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and result_reason = 'bye' $$,
  'прошедший без игры получил одно уведомление: «первый раунд — без игры»');
select ok(not exists(
  select 1 from public.user_notifications
  where kind = 'tournament_match_finished'
    and tournament_id = 'c0c00003-0000-4000-8000-000000000003'),
  'уведомлений «матч завершён» за свободный проход нет');

-- админ исправил ник прошедшему без игры посреди турнира: подтверждение снялось,
-- но ход соперника, завершающий полуфинал, проходит, и комната финала создаётся
select lives_ok($$ select public.admin_change_school_nick(
    (select winner_id from public.tournament_matches where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and result_reason = 'bye'),
    'Кубок Исправленный') $$,
  'админ исправляет ник участнику посреди турнира');
create temp table ko3 (bye_player uuid, semi_winner uuid);
insert into ko3(bye_player)
  select winner_id from public.tournament_matches where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and result_reason = 'bye';
select lives_ok($$ update ko3 set semi_winner = pg_temp.play(
    (select game_id from public.tournament_matches where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and round_no = 1 and game_id is not null)) $$,
  'полуфинал завершается, хотя у будущего соперника снято подтверждение ника');
select results_eq(
  $$ select player1_id, player2_id, status, game_id is not null from public.tournament_matches
     where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and round_no = 2 $$,
  $$ select bye_player, semi_winner, 'ready'::text, true from ko3 $$,
  'после первого раунда в финале оба игрока и есть комната');
select is(
  (select count(*)::int from public.user_notifications n
   join public.tournament_matches m on m.id = n.tournament_match_id
   where m.tournament_id = 'c0c00003-0000-4000-8000-000000000003' and m.round_no = 2
     and n.kind = 'tournament_match_assigned' and n.game_id = m.game_id),
  2, 'оба финалиста получили уведомление со ссылкой на комнату');

-- финал: второй игрок финала сдаётся, побеждает прошедший без игры
select pg_temp.play((select game_id from public.tournament_matches where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and round_no = 2));
select is(
  (select winner_id from public.tournament_matches where tournament_id = 'c0c00003-0000-4000-8000-000000000003' and round_no = 2),
  (select bye_player from ko3), 'финал выиграл прошедший без игры');
select is((select status from public.tournaments where id = 'c0c00003-0000-4000-8000-000000000003'),
  'finished'::text, 'после финала турнир завершён');
select pg_temp.as_user('cccc0001-0000-4000-8000-000000000001');
select is((public.get_tournament_board('c0c00003-0000-4000-8000-000000000003')->'tournament'->>'winner_id')::uuid,
  (select bye_player from ko3), 'на странице турнира указан победитель');
select is((select rated_games from public.profiles where user_id = (select bye_player from ko3)),
  1, 'свободный проход не считается сыгранным матчем');
select is((select rating from public.profiles where user_id = (select bye_player from ko3)),
  1012, 'победитель турнира получил очки только за финал (+12)');
select is((select rated_games from public.profiles where user_id = (select semi_winner from ko3)),
  2, 'финалист сыграл два матча');
select is(
  (select sum(rating)::int from public.profiles p
   join public.tournament_players tp on tp.user_id = p.user_id and tp.tournament_id = 'c0c00003-0000-4000-8000-000000000003'),
  3000, 'турнирный рейтинг: сумма очков участников не изменилась');

-- ── 5 участников: сетка на 8, три свободных прохода ────────────────────────
update public.profiles set school_verified = true where display_name = 'Кубок Исправленный';  -- админ снова подтвердил ник
select pg_temp.new_cup('c0c00005-0000-4000-8000-000000000005', 5);
select pg_temp.as_user('0000cccc-0000-4000-8000-000000000000');
select lives_ok($$ select public.admin_generate_tournament('c0c00005-0000-4000-8000-000000000005') $$,
  '5 участников: жеребьёвка проходит');
select results_eq(
  $$ select round_no, count(*)::int from public.tournament_matches
     where tournament_id = 'c0c00005-0000-4000-8000-000000000005' group by round_no order by round_no $$,
  $$ values (1, 4), (2, 2), (3, 1) $$,
  '5 участников: сетка на 8 — четвертьфинал, полуфинал, финал');
select is(
  (select count(*)::int from public.tournament_matches
   where tournament_id = 'c0c00005-0000-4000-8000-000000000005' and round_no = 1 and result_reason = 'bye'),
  3, 'три свободных прохода');
select is(
  (select count(*)::int from public.tournament_matches
   where tournament_id = 'c0c00005-0000-4000-8000-000000000005' and round_no = 1 and game_id is not null),
  1, 'один настоящий матч первого раунда');
select results_eq(
  $$ select position, player1_id is not null, player2_id is not null, game_id is not null, status
     from public.tournament_matches where tournament_id = 'c0c00005-0000-4000-8000-000000000005' and round_no = 2
     order by position $$,
  $$ values (1, true, false, false, 'pending'::text), (2, true, true, true, 'ready'::text) $$,
  'полуфинал двух прошедших без игры сразу готов, второй ждёт победителя');
select is(
  (select count(*)::int from public.user_notifications n
   join public.tournament_matches m on m.id = n.tournament_match_id
   where m.tournament_id = 'c0c00005-0000-4000-8000-000000000005' and m.round_no = 2
     and n.kind = 'tournament_match_assigned' and n.game_id = m.game_id),
  2, 'игроки готового полуфинала получили уведомление со ссылкой на комнату');
select is(
  (select count(*)::int from public.user_notifications n
   join public.tournament_matches m on m.id = n.tournament_match_id
   where m.tournament_id = 'c0c00005-0000-4000-8000-000000000005' and m.result_reason = 'bye'
     and n.body like '%уже известен%' and n.game_id is not null),
  2, 'двоим прошедшим без игры в готовый полуфинал сообщено, что комната уже открыта');
select ok(
  (select count(distinct u)::int = 5 from public.tournament_matches m
   cross join lateral (values (m.player1_id), (m.player2_id)) as x(u)
   where m.tournament_id = 'c0c00005-0000-4000-8000-000000000005' and m.round_no = 1 and u is not null),
  'каждый участник ровно в одной паре первого раунда');

-- готовый полуфинал играется сразу: победитель встаёт в финал на второе место, финал ждёт
create temp table ko5 as
  select pg_temp.play((select game_id from public.tournament_matches
                       where tournament_id = 'c0c00005-0000-4000-8000-000000000005' and round_no = 2 and position = 2)) as winner;
select results_eq(
  $$ select player1_id, player2_id, game_id, status from public.tournament_matches
     where tournament_id = 'c0c00005-0000-4000-8000-000000000005' and round_no = 3 $$,
  $$ select null::uuid, winner, null::uuid, 'pending'::text from ko5 $$,
  'победитель полуфинала прошедших без игры ждёт в финале соперника');
select is((select status from public.tournaments where id = 'c0c00005-0000-4000-8000-000000000005'),
  'active'::text, 'турнир продолжается');

-- ── 8 участников: полная сетка без свободных проходов ─────────────────────
select pg_temp.new_cup('c0c00008-0000-4000-8000-000000000008', 8);
select pg_temp.as_user('0000cccc-0000-4000-8000-000000000000');
select lives_ok($$ select public.admin_generate_tournament('c0c00008-0000-4000-8000-000000000008') $$,
  '8 участников: жеребьёвка проходит');
select results_eq(
  $$ select round_no, count(*)::int, count(game_id)::int, count(*) filter (where result_reason = 'bye')::int
     from public.tournament_matches where tournament_id = 'c0c00008-0000-4000-8000-000000000008'
     group by round_no order by round_no $$,
  $$ values (1, 4, 4, 0), (2, 2, 0, 0), (3, 1, 0, 0) $$,
  '8 участников: 4 комнаты первого раунда, свободных проходов нет');

-- ── рейтинговые игры по-прежнему требуют подтверждённый ник ────────────────
update public.profiles set school_verified = false where user_id = 'cccc0008-0000-4000-8000-000000000008';
select pg_temp.as_user('cccc0008-0000-4000-8000-000000000008');
select throws_ok($$ select public.create_game('5c5c5c5c-0000-4000-8000-000000000001', 'rated') $$,
  'P0001', 'Verified school nick required', 'рейтинговую игру без подтверждённого ника создать нельзя');

select * from finish();
rollback;
