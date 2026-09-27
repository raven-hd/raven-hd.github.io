-- Дополнительный матч решает полное равенство на границе 4 мест из 6.
begin;
create extension if not exists pgtap with schema extensions;
select plan(15);

insert into auth.users(id,email,raw_user_meta_data) values
  ('0000aaaa-0000-4000-8000-000000000000','tb.admin@test.local','{"school_nick":"Админ Равенства"}'),
  ('aaaa0001-0000-4000-8000-000000000001','tb.p1@test.local','{"school_nick":"Пара Один"}'),
  ('aaaa0002-0000-4000-8000-000000000002','tb.p2@test.local','{"school_nick":"Пара Два"}'),
  ('aaaa0003-0000-4000-8000-000000000003','tb.p3@test.local','{"school_nick":"Пара Три"}'),
  ('aaaa0004-0000-4000-8000-000000000004','tb.p4@test.local','{"school_nick":"Пара Четыре"}'),
  ('aaaa0005-0000-4000-8000-000000000005','tb.p5@test.local','{"school_nick":"Пара Пять"}'),
  ('aaaa0006-0000-4000-8000-000000000006','tb.p6@test.local','{"school_nick":"Пара Шесть"}');
update public.profiles set is_admin=true
where user_id='0000aaaa-0000-4000-8000-000000000000';
update public.profiles set school_verified=true where user_id::text like 'aaaa000%';

insert into public.tournaments(id,name,slug,status,tournament_format,max_players)
values ('aa000000-0000-4000-8000-000000000001','Тест равенства','tb-tournament','registration','qualifiers_playoff',6);
insert into public.tournament_players(tournament_id,user_id,status)
select 'aa000000-0000-4000-8000-000000000001',id,'active'
from auth.users where email like 'tb.p%';
select set_config('request.jwt.claims',json_build_object('sub','0000aaaa-0000-4000-8000-000000000000','role','authenticated')::text,true);
select public.admin_configure_tournament_qualifiers('aa000000-0000-4000-8000-000000000001',1,4);
select public.admin_start_tournament_qualifiers('aa000000-0000-4000-8000-000000000001');
select is((select count(*)::integer from public.tournament_matches where tournament_id='aa000000-0000-4000-8000-000000000001'),3,'три отборочных пары');

-- Каждый первый игрок выигрывает одну пару, остальные три имеют полное равенство.
select public.admin_award_technical_win(id,player1_id)
from public.tournament_matches where tournament_id='aa000000-0000-4000-8000-000000000001' and stage='qualifying';
select throws_ok($$ select public.admin_start_tournament_playoff('aa000000-0000-4000-8000-000000000001') $$,
  'P0001','Qualifying tiebreak required','четвертое место нельзя определить случайно');
select ok(has_function_privilege('authenticated','public.admin_start_qualifier_tiebreak(uuid,uuid,uuid)','EXECUTE')
  and not has_function_privilege('anon','public.admin_start_qualifier_tiebreak(uuid,uuid,uuid)','EXECUTE'),
  'дополнительный матч доступен только после входа');
select is((public.admin_security_audit()->>'passed')::boolean,true,'проверка безопасности знает новую функцию');

create temp table tied as
select player2_id as user_id, row_number() over(order by position) as place
from public.tournament_matches where tournament_id='aa000000-0000-4000-8000-000000000001' and stage='qualifying';
select set_config('request.jwt.claims',json_build_object('sub',(select user_id from tied where place=1),'role','authenticated')::text,true);
select throws_ok($$ select public.admin_start_qualifier_tiebreak(
    'aa000000-0000-4000-8000-000000000001',
    (select user_id from tied where place=1),(select user_id from tied where place=2)) $$,
  'P0001','Admin required','игрок не может назначить дополнительный матч');
select set_config('request.jwt.claims',json_build_object('sub','0000aaaa-0000-4000-8000-000000000000','role','authenticated')::text,true);
select throws_ok($$ select public.admin_start_qualifier_tiebreak(
    'aa000000-0000-4000-8000-000000000001',
    (select user_id from tied where place=1),
    (select player1_id from public.tournament_matches where tournament_id='aa000000-0000-4000-8000-000000000001' and stage='qualifying' order by position limit 1)) $$,
  'P0001','Choose two tied players','лидера нельзя назначить на отсев');
select lives_ok($$ select public.admin_start_qualifier_tiebreak(
    'aa000000-0000-4000-8000-000000000001',
    (select user_id from tied where place=1),(select user_id from tied where place=2)) $$,
  'админ назначил игру двум равным игрокам');
select results_eq(
  $$ select stage,status,game_id is not null from public.tournament_matches
     where tournament_id='aa000000-0000-4000-8000-000000000001' and stage='tiebreak' $$,
  $$ values ('tiebreak'::text,'ready'::text,true) $$,'игровая комната создана');
select is((select count(*)::integer from public.user_notifications n
  join public.tournament_matches m on m.id=n.tournament_match_id
  where m.tournament_id='aa000000-0000-4000-8000-000000000001' and m.stage='tiebreak'),2,
  'оба игрока получили уведомление');
select throws_ok($$ select public.admin_start_tournament_playoff('aa000000-0000-4000-8000-000000000001') $$,
  'P0001','Qualifying matches incomplete','плей-офф ожидает завершения дополнительного матча');
select throws_ok($$ select public.admin_start_qualifier_tiebreak(
    'aa000000-0000-4000-8000-000000000001',
    (select user_id from tied where place=1),(select user_id from tied where place=3)) $$,
  'P0001','Qualifying matches incomplete','параллельный дополнительный матч не назначается');
select lives_ok($$ select public.admin_award_technical_win(
    (select id from public.tournament_matches where tournament_id='aa000000-0000-4000-8000-000000000001' and stage='tiebreak'),
    (select user_id from tied where place=1)) $$,'админ может решить дополнительный матч технически');
select lives_ok($$ select public.admin_start_tournament_playoff('aa000000-0000-4000-8000-000000000001') $$,
  'после разрешения равенства плей-офф строится');
select is((select seed from public.tournament_players where tournament_id='aa000000-0000-4000-8000-000000000001'
  and user_id=(select user_id from tied where place=1)),4,'победитель дополнительного матча занимает четвертое место');
select is((select count(*)::integer from public.tournament_matches where tournament_id='aa000000-0000-4000-8000-000000000001' and stage='playoff'),3,
  'сетка плей-офф на четыре места построена');

select * from finish();
rollback;
