-- Запуск: supabase test db   (нужны Supabase CLI и локальная база: supabase start).
-- Тест выполняется в транзакции и откатывается — данные базы не меняются.
-- supabase/tests/database/08_match_admin_actions.test.sql
-- Техническая победа и переигровка турнирного матча (миграция 037): права, отказы,
-- плей-офф (продвижение, финал, завершение турнира), переигровка (в том числе после
-- «закрыть матч»), квалификация, рейтинг и уведомления.
begin;
create extension if not exists pgtap with schema extensions;
select plan(46);

insert into auth.users(id, email, raw_user_meta_data) values
  ('0000eeee-0000-4000-8000-000000000000', 'ta.admin@test.local', '{"school_nick":"Админ Решений"}'),
  ('eeee0001-0000-4000-8000-000000000001', 'ta.p1@test.local', '{"school_nick":"Решение Первый"}'),
  ('eeee0002-0000-4000-8000-000000000002', 'ta.p2@test.local', '{"school_nick":"Решение Второй"}'),
  ('eeee0003-0000-4000-8000-000000000003', 'ta.p3@test.local', '{"school_nick":"Решение Третий"}'),
  ('eeee0004-0000-4000-8000-000000000004', 'ta.p4@test.local', '{"school_nick":"Решение Четвёртый"}');
update public.profiles set is_admin = true where user_id = '0000eeee-0000-4000-8000-000000000000';
update public.profiles set school_verified = true where user_id::text like 'eeee000%';

create function pg_temp.new_cup(p_id uuid, p_count int, p_format text default 'knockout') returns void
language sql as $$
  insert into public.tournaments(id, name, slug, status, tournament_format, max_players)
  values (p_id, 'Кубок решений на ' || p_count, 'ta-cup-' || p_id, 'registration', p_format, 32);
  insert into public.tournament_players(tournament_id, user_id, status)
  select p_id, u.id, 'active' from auth.users u where u.email like 'ta.p%' order by u.email limit p_count;
$$;

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$$;

-- оба игрока расставляют флот: игра переходит в «идёт игра»
create function pg_temp.start(p_game uuid) returns void language plpgsql as $$
declare
  g public.games%rowtype;
  fleet jsonb := '[{"length":4,"cells":["A1","B1","C1","D1"]},{"length":3,"cells":["F1","G1","H1"]},
    {"length":3,"cells":["A3","B3","C3"]},{"length":2,"cells":["E3","F3"]},
    {"length":2,"cells":["H3","I3"]},{"length":2,"cells":["A5","B5"]},
    {"length":1,"cells":["D5"]},{"length":1,"cells":["F5"]},
    {"length":1,"cells":["H5"]},{"length":1,"cells":["J5"]}]';
begin
  select * into g from public.games where id = p_game;
  perform pg_temp.as_user(g.player1_id);
  perform public.ready_with_fleet(p_game, fleet);
  perform pg_temp.as_user(g.player2_id);
  perform public.ready_with_fleet(p_game, fleet);
end $$;

-- сыграть матч: расстановка, второй игрок сдаётся. возвращает победителя
create function pg_temp.play(p_game uuid) returns uuid language plpgsql as $$
declare g public.games%rowtype;
begin
  perform pg_temp.start(p_game);
  select * into g from public.games where id = p_game;
  perform pg_temp.as_user(g.player2_id);
  perform public.surrender_game(p_game);
  return g.player1_id;
end $$;

create function pg_temp.match_of(p_cup uuid, p_round int, p_with_game boolean default true) returns public.tournament_matches
language sql as $$
  select * from public.tournament_matches
  where tournament_id = p_cup and round_no = p_round and (not p_with_game or game_id is not null)
  order by position limit 1;
$$;

-- ── права ──────────────────────────────────────────────────────────────────
select ok(has_function_privilege('authenticated', 'public.admin_award_technical_win(uuid,uuid)', 'EXECUTE'),
  'техпобеду может вызвать вошедший пользователь (внутри — проверка админа)');
select ok(not has_function_privilege('anon', 'public.admin_award_technical_win(uuid,uuid)', 'EXECUTE'),
  'без входа техпобеда недоступна');
select ok(has_function_privilege('authenticated', 'public.admin_replay_tournament_match(uuid)', 'EXECUTE'),
  'переигровку может вызвать вошедший пользователь (внутри — проверка админа)');
select ok(not has_function_privilege('anon', 'public.admin_replay_tournament_match(uuid)', 'EXECUTE'),
  'без входа переигровка недоступна');
select ok(not has_function_privilege('authenticated', 'public.advance_playoff_winner(uuid)', 'EXECUTE')
      and not has_function_privilege('authenticated', 'public.create_tournament_room(uuid,uuid)', 'EXECUTE')
      and not has_function_privilege('authenticated', 'public.cancel_tournament_room(uuid,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.advance_playoff_winner(uuid)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.create_tournament_room(uuid,uuid)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.cancel_tournament_room(uuid,text)', 'EXECUTE'),
  'внутренние помощники из браузера недоступны ни с входом, ни без');

-- ── 3 участника: техпобеда в полуфинале, переигровка финала ───────────────
select pg_temp.new_cup('ca000003-0000-4000-8000-000000000003', 3);
select pg_temp.as_user('0000eeee-0000-4000-8000-000000000000');
select public.admin_generate_tournament('ca000003-0000-4000-8000-000000000003');
create temp table semi as select * from pg_temp.match_of('ca000003-0000-4000-8000-000000000003', 1);
create temp table bye as select * from public.tournament_matches
  where tournament_id = 'ca000003-0000-4000-8000-000000000003' and result_reason = 'bye';
select pg_temp.start((select game_id from semi));   -- игроки уже начали бой

select pg_temp.as_user('eeee0001-0000-4000-8000-000000000001');
select throws_ok($$ select public.admin_award_technical_win((select id from semi), (select player1_id from semi)) $$,
  'P0001', 'Admin required', 'игрок не может засчитать техпобеду');
select throws_ok($$ select public.admin_replay_tournament_match((select id from semi)) $$,
  'P0001', 'Admin required', 'игрок не может назначить переигровку');

select pg_temp.as_user('0000eeee-0000-4000-8000-000000000000');
select throws_ok($$ select public.admin_award_technical_win('00000000-0000-4000-8000-000000000000', null) $$,
  'P0001', 'Tournament match not found', 'несуществующий матч');
select throws_ok($$ select public.admin_award_technical_win((select id from semi), '0000eeee-0000-4000-8000-000000000000') $$,
  'P0001', 'Winner must be a match player', 'победитель — только игрок этой пары');
select throws_ok($$ select public.admin_award_technical_win((select id from bye), (select winner_id from bye)) $$,
  'P0001', 'Tournament match already resolved', 'свободный проход уже решён');
select throws_ok($$ select public.admin_award_technical_win(
    (select id from pg_temp.match_of('ca000003-0000-4000-8000-000000000003', 2, false)), (select winner_id from bye)) $$,
  'P0001', 'Tournament match players missing', 'в финале ещё нет второго игрока');

-- админ исправил ник прошедшему без игры (подтверждение снялось) — сетке это не мешает
select public.admin_change_school_nick((select winner_id from bye), 'Решение Исправленный');
-- техпобеда второму игроку полуфинала, хотя бой уже шёл
select lives_ok($$ select public.admin_award_technical_win((select id from semi), (select player2_id from semi)) $$,
  'админ засчитывает техническую победу (у соперника по финалу сейчас не подтверждён ник)');
select results_eq(
  $$ select status, result_reason, winner_id from public.tournament_matches where id = (select id from semi) $$,
  $$ select 'technical'::text, 'technical'::text, player2_id from semi $$,
  'матч решён технически, победитель — выбранный игрок');
select results_eq(
  $$ select status, admin_cancel_reason from public.games where id = (select game_id from semi) $$,
  $$ values ('cancelled'::text, 'техническая победа в турнире'::text) $$,
  'шедшая игра пары отменена, причина записана');
select results_eq(
  $$ select player1_id, player2_id, status, game_id is not null
     from public.tournament_matches where tournament_id = 'ca000003-0000-4000-8000-000000000003' and round_no = 2 $$,
  $$ select (select winner_id from bye), (select player2_id from semi), 'ready'::text, true $$,
  'победитель по техпобеде прошёл в финал, для финала открыта комната');
select is(
  (select count(*)::int from public.user_notifications
   where tournament_match_id = (select id from semi) and kind = 'tournament_match_finished'
     and body like '%техническая победа%' and game_id is null),
  2, 'оба игрока полуфинала узнали о техпобеде, ссылка ведёт на турнир, а не на отменённую игру');

-- финал начали и переигрываем
create temp table final_before as select * from pg_temp.match_of('ca000003-0000-4000-8000-000000000003', 2);
select pg_temp.start((select game_id from final_before));
select pg_temp.as_user('0000eeee-0000-4000-8000-000000000000');
select lives_ok($$ select public.admin_replay_tournament_match((select id from final_before)) $$,
  'админ назначает переигровку финала');
select results_eq(
  $$ select status, result_reason, winner_id is null, resolved_at is null, game_id <> (select game_id from final_before)
     from public.tournament_matches where id = (select id from final_before) $$,
  $$ values ('ready'::text, 'replay'::text, true, true, true) $$,
  'у финала новая игра, результата нет, пометка «переигровка»');
select results_eq(
  $$ select status, admin_cancel_reason from public.games where id = (select game_id from final_before) $$,
  $$ values ('cancelled'::text, 'переигровка в турнире'::text) $$,
  'прежняя игра финала отменена');
select results_eq(
  $$ select g.status, g.game_type, g.player1_id, g.player2_id from public.games g
     join public.tournament_matches m on m.game_id = g.id where m.id = (select id from final_before) $$,
  $$ select 'placing'::text, 'tournament'::text, player1_id, player2_id from final_before $$,
  'новая комната финала — для тех же игроков, на расстановке');
select is(
  (select count(*)::int from public.user_notifications n
   join public.tournament_matches m on m.id = n.tournament_match_id and n.game_id = m.game_id
   where m.id = (select id from final_before) and n.title = 'переигровка матча' and n.read_at is null),
  2, 'оба финалиста получили непрочитанное уведомление со ссылкой на новую комнату');
select ok(not exists(select 1 from public.user_notifications where game_id = (select game_id from final_before)),
  'старое уведомление о финале заменено: ссылок на закрытую комнату не осталось');

-- переигранный финал доигрывают: турнир завершён
select pg_temp.play((select game_id from public.tournament_matches where id = (select id from final_before)));
select is((select status from public.tournaments where id = 'ca000003-0000-4000-8000-000000000003'),
  'finished'::text, 'после переигранного финала турнир завершён');
select is(
  (select result_reason from public.tournament_matches where id = (select id from final_before)),
  'game'::text, 'финал решён игрой');
select results_eq(
  $$ select rated_games, rating from public.profiles where user_id = (select player1_id from semi) $$,
  $$ values (0, 1000) $$,
  'техническое поражение рейтинг не меняет');
select is((select rated_games from public.profiles where user_id = (select player2_id from semi)),
  1, 'победителю по техпобеде засчитан только сыгранный финал');
select is(
  (select sum(rating)::int from public.profiles p
   join public.tournament_players tp on tp.user_id = p.user_id and tp.tournament_id = 'ca000003-0000-4000-8000-000000000003'),
  3000, 'сумма рейтинга участников не изменилась');
select pg_temp.as_user('0000eeee-0000-4000-8000-000000000000');
select throws_ok($$ select public.admin_replay_tournament_match((select id from final_before)) $$,
  'P0001', 'Tournament not active', 'после завершения турнира решения недоступны');

-- ── 2 участника: техпобеда в финале завершает турнир ───────────────────────
update public.profiles set school_verified = true where display_name = 'Решение Исправленный';  -- админ снова подтвердил ник
select pg_temp.new_cup('ca000002-0000-4000-8000-000000000002', 2);
select public.admin_generate_tournament('ca000002-0000-4000-8000-000000000002');
create temp table final2 as select * from pg_temp.match_of('ca000002-0000-4000-8000-000000000002', 1);
create temp table ratings2_before as
  select user_id, rating, rated_games from public.profiles
  where user_id in ((select player1_id from final2), (select player2_id from final2));
select lives_ok($$ select public.admin_award_technical_win((select id from final2), (select player1_id from final2)) $$,
  'техпобеда в финале');
select is((select status from public.tournaments where id = 'ca000002-0000-4000-8000-000000000002'),
  'finished'::text, 'турнир завершён техпобедой в финале');
select is((public.get_tournament_board('ca000002-0000-4000-8000-000000000002')->'tournament'->>'winner_id')::uuid,
  (select player1_id from final2), 'победитель турнира — выбранный игрок');
select ok(
  (select rating_applied from public.tournaments where id = 'ca000002-0000-4000-8000-000000000002')
  and not exists(
    select 1 from ratings2_before b join public.profiles p on p.user_id = b.user_id
    where p.rating <> b.rating or p.rated_games <> b.rated_games),
  'турнир подведён, а рейтинг обоих игроков не изменился — матч не игрался');

-- ── «закрыть матч» → пара застряла → переигровка её оживляет ──────────────
select pg_temp.new_cup('ca000012-0000-4000-8000-000000000012', 2);
select public.admin_generate_tournament('ca000012-0000-4000-8000-000000000012');
create temp table stuck as select * from pg_temp.match_of('ca000012-0000-4000-8000-000000000012', 1);
select public.admin_cancel_game((select game_id from stuck), 'зависла');
select is((select status from public.tournament_matches where id = (select id from stuck)),
  'cancelled'::text, 'после «закрыть матч» пара без результата');
select lives_ok($$ select public.admin_replay_tournament_match((select id from stuck)) $$,
  'переигровка закрытого матча');
select is((select status from public.tournament_matches where id = (select id from stuck)),
  'ready'::text, 'у пары снова открыта комната');
select pg_temp.play((select game_id from public.tournament_matches where id = (select id from stuck)));
select pg_temp.as_user('0000eeee-0000-4000-8000-000000000000');
select is((select status from public.tournaments where id = 'ca000012-0000-4000-8000-000000000012'),
  'finished'::text, 'переигранный матч доигран, турнир завершён');

-- ── квалификация: техпобеда засчитывается как победа при посеве в плей-офф ─
select pg_temp.new_cup('ca000004-0000-4000-8000-000000000004', 4, 'qualifiers_playoff');
select pg_temp.as_user('0000eeee-0000-4000-8000-000000000000');
select public.admin_configure_tournament_qualifiers('ca000004-0000-4000-8000-000000000004', 1, 4);
select public.admin_start_tournament_qualifiers('ca000004-0000-4000-8000-000000000004');
create temp table q as
  select * from public.tournament_matches
  where tournament_id = 'ca000004-0000-4000-8000-000000000004' and stage = 'qualifying' order by position;
select is((select count(*)::int from q), 2, 'квалификация: два матча');
select lives_ok($$ select public.admin_award_technical_win((select id from q order by position limit 1),
                                                        (select player2_id from q order by position limit 1)) $$,
  'техпобеда в матче квалификации');
select ok(
  (select status = 'technical' from public.tournament_matches where id = (select id from q order by position limit 1))
  and not exists(select 1 from public.tournament_matches
                 where tournament_id = 'ca000004-0000-4000-8000-000000000004' and stage = 'playoff'),
  'в квалификации техпобеда только записывает результат — плей-офф сам не создаётся');
create temp table q2 as select pg_temp.play((select game_id from q order by position offset 1 limit 1)) as winner;
select pg_temp.as_user('0000eeee-0000-4000-8000-000000000000');
select throws_ok($$ select public.admin_award_technical_win((select id from q order by position offset 1 limit 1),
                                                         (select player1_id from q order by position offset 1 limit 1)) $$,
  'P0001', 'Tournament match already resolved', 'сыгранный матч техпобедой не переписать');
select throws_ok($$ select public.admin_replay_tournament_match((select id from q order by position limit 1)) $$,
  'P0001', 'Tournament match already resolved', 'решённый техпобедой матч не переиграть');
select lives_ok($$ select public.admin_start_tournament_playoff('ca000004-0000-4000-8000-000000000004') $$,
  'плей-офф запускается: квалификация завершена');
select ok(
  (select seed <= 2 from public.tournament_players
   where tournament_id = 'ca000004-0000-4000-8000-000000000004'
     and user_id = (select player2_id from q order by position limit 1)),
  'победитель по техпобеде посеян среди победителей квалификации');

-- ── старая сетка «плей-офф» (до 036): связей между раундами нет ─────────────
-- техпобеда в одной из пар не должна «завершать» турнир и назначать чемпиона
insert into public.tournaments(id, name, slug, status, tournament_format, max_players)
values ('ca000099-0000-4000-8000-000000000099', 'Старая сетка', 'ta-legacy', 'active', 'knockout', 32);
insert into public.tournament_matches(tournament_id, stage, round_no, position, player1_id, player2_id, status) values
  ('ca000099-0000-4000-8000-000000000099', 'playoff', 1, 1, 'eeee0001-0000-4000-8000-000000000001', 'eeee0002-0000-4000-8000-000000000002', 'ready'),
  ('ca000099-0000-4000-8000-000000000099', 'playoff', 1, 2, 'eeee0003-0000-4000-8000-000000000003', 'eeee0004-0000-4000-8000-000000000004', 'ready');
select lives_ok($$ select public.admin_award_technical_win(
    (select id from public.tournament_matches where tournament_id = 'ca000099-0000-4000-8000-000000000099' and position = 1),
    'eeee0001-0000-4000-8000-000000000001') $$,
  'старая сетка: техпобеда записывается');
select is((select status from public.tournaments where id = 'ca000099-0000-4000-8000-000000000099'),
  'active'::text, 'старая сетка: турнир не завершён по техпобеде в одной из пар');

-- ── самопроверка защиты знает о новых функциях ─────────────────────────────
select is((public.admin_security_audit()->>'passed')::boolean, true, 'встроенная проверка защиты проходит');

select * from finish();
rollback;
