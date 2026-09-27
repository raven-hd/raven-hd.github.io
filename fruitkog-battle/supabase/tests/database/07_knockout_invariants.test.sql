-- Запуск: supabase test db   (нужны Supabase CLI и локальная база: supabase start).
-- Тест выполняется в транзакции и откатывается — данные базы не меняются.
-- supabase/tests/database/07_knockout_invariants.test.sql
-- Сетка «плей-офф» (миграция 036) для любого числа участников: жеребьёвка проводится
-- для N = 2…40, 63, 64, 65, 100 и 128, и для каждой сетки проверяются одни и те же правила.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users(id, email, raw_user_meta_data)
select ('dddd' || lpad(to_hex(i), 4, '0') || '-0000-4000-8000-000000000000')::uuid,
       'inv.p' || lpad(i::text, 3, '0') || '@test.local',
       jsonb_build_object('school_nick', 'Сетка ' || i)
from generate_series(1, 128) as i;
insert into auth.users(id, email, raw_user_meta_data)
values ('0000dddd-0000-4000-8000-000000000000', 'inv.admin@test.local', '{"school_nick":"Админ Сеток"}');
update public.profiles set school_verified = true where user_id::text like 'dddd%';
update public.profiles set is_admin = true where user_id = '0000dddd-0000-4000-8000-000000000000';
select set_config('request.jwt.claims', '{"sub":"0000dddd-0000-4000-8000-000000000000","role":"authenticated"}', true);

create temp table problems(n int, problem text);
create temp table sizes(n int);
insert into sizes select generate_series(2, 40) union all values (63), (64), (65), (100), (128);

do $$
declare
  cup_n int;
  cup uuid;
  bracket int;
  rounds int;
  bad int;
begin
  for cup_n in select n from sizes order by n loop
    cup := gen_random_uuid();
    bracket := 2; rounds := 1;
    while bracket < cup_n loop bracket := bracket * 2; rounds := rounds + 1; end loop;

    insert into public.tournaments(id, name, slug, status, tournament_format, max_players)
    values (cup, 'Сетка на ' || cup_n, 'inv-' || cup_n, 'registration', 'knockout', 128);
    insert into public.tournament_players(tournament_id, user_id, status)
    select cup, u.id, 'active' from auth.users u where u.email like 'inv.p%' order by u.email limit cup_n;
    perform public.admin_generate_tournament(cup);

    -- число пар и раундов
    if (select count(*) from public.tournament_matches where tournament_id = cup) <> bracket - 1 then
      insert into problems values (cup_n, 'пар не bracket-1'); end if;
    if (select max(round_no) from public.tournament_matches where tournament_id = cup) <> rounds then
      insert into problems values (cup_n, 'неверное число раундов'); end if;

    -- свободные проходы: ровно bracket - N, только в первом раунде, один игрок, он же победитель, без игры
    if (select count(*) from public.tournament_matches where tournament_id = cup and result_reason = 'bye') <> bracket - cup_n then
      insert into problems values (cup_n, 'неверное число свободных проходов'); end if;
    if exists (select 1 from public.tournament_matches where tournament_id = cup and result_reason = 'bye'
               and (round_no <> 1 or player1_id is null or player2_id is not null or winner_id is distinct from player1_id
                    or game_id is not null or status <> 'technical')) then
      insert into problems values (cup_n, 'неправильный свободный проход'); end if;

    -- настоящие пары первого раунда: два разных игрока и комната
    if exists (select 1 from public.tournament_matches where tournament_id = cup and round_no = 1
               and result_reason is distinct from 'bye'
               and (player1_id is null or player2_id is null or player1_id = player2_id
                    or game_id is null or status <> 'ready')) then
      insert into problems values (cup_n, 'пара первого раунда без двух игроков или без комнаты'); end if;

    -- каждый участник ровно один раз в первом раунде, посев 1..N без повторов
    select count(*) into bad from (
      select u, count(*) c from public.tournament_matches m
      cross join lateral (values (m.player1_id), (m.player2_id)) x(u)
      where m.tournament_id = cup and m.round_no = 1 and u is not null group by u) t where c <> 1;
    if bad > 0 or (select count(distinct u) from public.tournament_matches m
                   cross join lateral (values (m.player1_id), (m.player2_id)) x(u)
                   where m.tournament_id = cup and m.round_no = 1 and u is not null) <> cup_n then
      insert into problems values (cup_n, 'участник не ровно в одной паре первого раунда'); end if;
    if (select array_agg(seed order by seed) from public.tournament_players where tournament_id = cup)
       <> (select array_agg(i) from generate_series(1, cup_n) i) then
      insert into problems values (cup_n, 'посев не 1..N'); end if;

    -- связи: каждая пара, кроме финала, ведёт в пару следующего раунда на своё место
    if exists (select 1 from public.tournament_matches m
               left join public.tournament_matches nx on nx.id = m.next_match_id
               where m.tournament_id = cup and m.round_no < rounds
                 and (nx.id is null or nx.round_no <> m.round_no + 1 or nx.position <> (m.position + 1) / 2
                      or m.next_slot <> case when m.position % 2 = 1 then 1 else 2 end)) then
      insert into problems values (cup_n, 'неправильная связь со следующим раундом'); end if;
    if exists (select 1 from public.tournament_matches where tournament_id = cup and round_no = rounds and next_match_id is not null) then
      insert into problems values (cup_n, 'у финала есть следующая пара'); end if;

    -- второй раунд: место занято тем, кто прошёл без игры (и только им); два таких — сразу комната
    if exists (
      select 1 from public.tournament_matches r2
      where r2.tournament_id = cup and r2.round_no = 2
        and (r2.player1_id is distinct from (select winner_id from public.tournament_matches b
                                             where b.tournament_id = cup and b.next_match_id = r2.id and b.next_slot = 1 and b.result_reason = 'bye')
          or r2.player2_id is distinct from (select winner_id from public.tournament_matches b
                                             where b.tournament_id = cup and b.next_match_id = r2.id and b.next_slot = 2 and b.result_reason = 'bye')
          or (r2.player1_id is not null and r2.player2_id is not null) <> (r2.game_id is not null)
          or r2.status <> case when r2.game_id is not null then 'ready' else 'pending' end)) then
      insert into problems values (cup_n, 'неправильный второй раунд'); end if;
    if exists (select 1 from public.tournament_matches where tournament_id = cup and round_no > 2
               and (player1_id is not null or player2_id is not null or game_id is not null or status <> 'pending')) then
      insert into problems values (cup_n, 'поздние раунды заполнены раньше времени'); end if;

    -- комнаты: по одной на готовую пару, турнирные, на расстановке
    if (select count(*) from public.games g join public.tournament_matches m on m.game_id = g.id
        where m.tournament_id = cup and g.game_type = 'tournament' and g.status = 'placing'
          and g.player1_id = m.player1_id and g.player2_id = m.player2_id)
       <> (select count(*) from public.tournament_matches where tournament_id = cup and game_id is not null) then
      insert into problems values (cup_n, 'комната не совпадает с парой'); end if;
  end loop;
end $$;

select is((select count(*)::int from problems), 0, 'сетка правильная для всех проверенных N (2…40, 63, 64, 65, 100, 128)');
select is((select count(*)::int from sizes), 44, 'проверено 44 размера турнира');
select is(
  (select count(*)::int from public.tournaments where slug like 'inv-%' and status = 'active'),
  44, 'все 44 турнира начались');
select diag(n || ': ' || problem) from problems order by n;

select * from finish();
rollback;
