-- Выдача наград админу и запуск матча с двумя бустерами на локальной тестовой базе.
-- Вся проверка откатывается и не меняет данные после завершения.
begin;
create extension if not exists pgtap with schema extensions;
select plan(20);

insert into auth.users(id,email,raw_user_meta_data) values
  ('a1111111-0000-4000-8000-000000000001','reward-admin@test.local','{"school_nick":"Админ Наград"}'),
  ('b2222222-0000-4000-8000-000000000002','reward-rival@test.local','{"school_nick":"Соперник Наград"}');
update public.profiles set is_admin=true,school_verified=true
where user_id='a1111111-0000-4000-8000-000000000001';
update public.profiles set school_verified=true
where user_id='b2222222-0000-4000-8000-000000000002';

set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"a1111111-0000-4000-8000-000000000001","role":"authenticated"}',true);

select lives_ok($$ select public.admin_grant_fruitkog_reward(
  auth.uid(),'square_ship',1,now()+interval '1 day','проверка 2x2') $$,
  'админ выдает себе квадратный корабль на одну игру');
select lives_ok($$ select public.admin_grant_fruitkog_reward(
  auth.uid(),'auto_miss',2,now()+interval '1 day','проверка автопромахов') $$,
  'админ выдает себе два использования автопромахов');
select lives_ok($$ select public.admin_grant_fruitkog_reward(
  auth.uid(),'mushroom_skin',null,null,'проверка скина') $$,
  'админ выдает себе грибной скин без ограничения игр');
select is((public.get_my_fruitkog_rewards()->>'square_ship_uses')::integer,1,
  'один корабль доступен до матча');
select is((public.get_my_fruitkog_rewards()->>'auto_miss_uses')::integer,2,
  'два автопромаха доступны до матча');
select is((public.get_my_fruitkog_rewards()->>'mushroom_skin_unlocked')::boolean,true,
  'грибной скин доступен');
select is((public.set_fruitkog_ship_skin('mushroom')->>'selected_ship_skin'),
  'mushroom'::text,'админ выбирает активный грибной скин');

select lives_ok($$ select public.create_game(
  'c3333333-0000-4000-8000-000000000003','casual') $$,
  'админ создает обычную комнату');
select set_config('request.jwt.claims',
  '{"sub":"b2222222-0000-4000-8000-000000000002","role":"authenticated"}',true);
select lives_ok($$ select public.join_public_game(
  (select id from public.games where player1_id=
    'a1111111-0000-4000-8000-000000000001' and status='waiting')) $$,
  'соперник входит в комнату');

select set_config('request.jwt.claims',
  '{"sub":"a1111111-0000-4000-8000-000000000001","role":"authenticated"}',true);
select lives_ok($$ select public.ready_with_fleet(
  (select id from public.games where player1_id=auth.uid() and status='placing'),
  '[{"length":4,"shape":"square","cells":["I9","J9","I10","J10"],"skin":"vegetable"},
    {"length":3,"cells":["F1","G1","H1"]},{"length":3,"cells":["A3","B3","C3"]},
    {"length":2,"cells":["E3","F3"]},{"length":2,"cells":["H3","I3"]},
    {"length":2,"cells":["A5","B5"]},{"length":1,"cells":["D5"]},
    {"length":1,"cells":["F5"]},{"length":1,"cells":["H5"]},
    {"length":1,"cells":["J5"]}]'::jsonb,
  '{"auto_miss":true}'::jsonb) $$,
  'админ ставит квадратный корабль и включает автопромахи');
select is((public.get_my_fruitkog_rewards()->>'square_ship_uses')::integer,1,
  'корабль не списан до старта матча');
select is((public.get_my_fruitkog_rewards()->>'auto_miss_uses')::integer,2,
  'автопромахи не списаны до старта матча');

select set_config('request.jwt.claims',
  '{"sub":"b2222222-0000-4000-8000-000000000002","role":"authenticated"}',true);
select lives_ok($$ select public.ready_with_fleet(
  (select id from public.games where player2_id=auth.uid() and status='placing'),
  '[{"length":4,"cells":["A1","B1","C1","D1"],"skin":"mushroom"},
    {"length":3,"cells":["F1","G1","H1"]},{"length":3,"cells":["A3","B3","C3"]},
    {"length":2,"cells":["E3","F3"]},{"length":2,"cells":["H3","I3"]},
    {"length":2,"cells":["A5","B5"]},{"length":1,"cells":["D5"]},
    {"length":1,"cells":["F5"]},{"length":1,"cells":["H5"]},
    {"length":1,"cells":["J5"]}]'::jsonb) $$,
  'второй игрок готов и запускает матч');
select is((select ships->0->>'skin' from public.fleets where owner_id=auth.uid()),
  'vegetable'::text,'соперник не может подставить невыданный грибной скин');

select set_config('request.jwt.claims',
  '{"sub":"a1111111-0000-4000-8000-000000000001","role":"authenticated"}',true);
select is((select status from public.games where player1_id=auth.uid()),
  'playing'::text,'матч начался');
select is((public.get_my_fruitkog_rewards()->>'square_ship_uses')::integer,0,
  'последнее использование корабля списалось до нуля');
select is((public.get_my_fruitkog_rewards()->>'auto_miss_uses')::integer,1,
  'одно использование автопромахов списалось');
select is((public.get_my_game_boosts(
  (select id from public.games where player1_id=auth.uid()))->>'square_ship_used')::boolean,
  true,'корабль 2x2 активирован в этом матче');
select is((public.get_my_game_boosts(
  (select id from public.games where player1_id=auth.uid()))->>'auto_miss_enabled')::boolean,
  true,'автопромахи активированы в этом матче');
select is((select player1_ship_skin from public.games where player1_id=auth.uid()),
  'mushroom'::text,'матч сохранил грибной скин админа');

select * from finish();
rollback;
