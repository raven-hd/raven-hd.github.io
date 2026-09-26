-- Запуск: supabase test db   (нужны Supabase CLI и локальная база: supabase start).
-- Тест выполняется в транзакции и откатывается — данные базы не меняются.
-- supabase/tests/database/05_security_invariants.test.sql
-- Сторож безопасности: если кто-то случайно откроет лишнюю функцию или таблицу,
-- тест упадёт. Новую публичную функцию нужно сознательно добавить в список ниже.
begin;
create extension if not exists pgtap with schema extensions;
select plan(3);

insert into auth.users(id, email, raw_user_meta_data) values
  ('0000bbbb-0000-4000-8000-000000000001', 'admin.audit@test.local', '{"school_nick":"Админ Проверки"}');
update public.profiles set is_admin = true where user_id = '0000bbbb-0000-4000-8000-000000000001';

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"0000bbbb-0000-4000-8000-000000000001","role":"authenticated"}', true);
select is((public.admin_security_audit()->>'passed')::boolean, true,
  'встроенная проверка защиты (кнопка «проверить защиту») проходит');
reset role;

select results_eq(
  $$ select p.proname::text collate "default" from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE')
     order by 1 $$,
  $$ values ('get_leaderboard'::text), ('get_public_game_settings'), ('get_tournament_board'),
            ('is_school_nick_available'), ('list_public_tournaments') $$,
  'без входа можно вызвать только эти публичные функции'
);

select results_eq(
  $$ select c.relname::text collate "default" from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and has_table_privilege('anon', c.oid, 'SELECT')
     order by 1 $$,
  $$ values ('profiles'::text) $$,
  'без входа напрямую читается только таблица profiles'
);

select * from finish();
rollback;
