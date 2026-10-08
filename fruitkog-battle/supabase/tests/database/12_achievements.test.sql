-- Очередь ачивок: решение админа отделено от проверки условий.
begin;
create extension if not exists pgtap with schema extensions;
select plan(11);

insert into auth.users(id,email,raw_user_meta_data) values
  ('1a000000-0000-4000-8000-000000000001','ach-admin@test.local','{"school_nick":"Админ Ачивок"}'),
  ('1a000000-0000-4000-8000-000000000002','ach-player@test.local','{"school_nick":"Игрок Ачивок"}');
update public.profiles set is_admin=true where user_id='1a000000-0000-4000-8000-000000000001';

create function pg_temp.as_user(p_user uuid) returns void language sql as $$
  select set_config('request.jwt.claims',json_build_object('sub',p_user,'role','authenticated')::text,true);
$$;

select public.propose_player_achievement('1a000000-0000-4000-8000-000000000002','games_50','games:50','50 завершенных матчей');
select public.propose_player_achievement('1a000000-0000-4000-8000-000000000002','games_50','games:50','50 завершенных матчей');
select is((select count(*)::int from public.player_achievements where code='games_50'),1,'повторная проверка не создает дубликат');
select ok(not has_function_privilege('anon','public.admin_decide_achievement(uuid,boolean)','EXECUTE'),'гость не может принимать решение');
select ok(not has_function_privilege('authenticated','public.propose_player_achievement(uuid,text,text,text,uuid)','EXECUTE'),'игрок не может создавать себе кандидатуру');

select pg_temp.as_user('1a000000-0000-4000-8000-000000000002');
select is(jsonb_array_length(public.list_player_achievements('1a000000-0000-4000-8000-000000000002')),0,'ожидающая ачивка не видна в профиле');
select throws_ok(
  $$select public.admin_decide_achievement((select id from public.player_achievements where code='games_50'),true)$$,
  'P0001','Admin required','обычный игрок не может одобрить ачивку');

select pg_temp.as_user('1a000000-0000-4000-8000-000000000001');
select diag(public.admin_security_audit()::text);
select is((public.admin_security_audit()->>'passed')::boolean,true,'новые RPC учтены встроенной проверкой защиты');
select is((public.admin_list_achievement_requests(30)->>'unread_count')::int,1,'админ видит заявку в колокольчике');
select is((public.admin_decide_achievement((select id from public.player_achievements where code='games_50'),true)->>'status'),'approved','админ одобряет заявку');
select is((public.admin_list_achievement_requests(30)->>'unread_count')::int,0,'одобренная заявка исчезает из очереди');
select is(jsonb_array_length(public.list_player_achievements('1a000000-0000-4000-8000-000000000002')),1,'одобренная ачивка видна в профиле');
select is((select count(*)::int from public.user_notifications where dedupe_key like 'achievement:%'),1,'игрок получает уведомление только после одобрения');

select * from finish();
rollback;
