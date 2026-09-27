-- обновление 26: первый этап защиты данных и проверка прав доступа.
-- выполните после 022_tournament_results_and_rating.sql.

begin;

-- Браузеру не нужны права на прямое изменение таблиц. Все изменения
-- проходят только через проверяющие пользователя серверные функции.
revoke insert,update,delete,truncate,references,trigger
on all tables in schema public from anon,authenticated;

-- Публичные турнирные данные выдаются безопасными функциями, а не прямым
-- чтением внутренних таблиц турнира, заявок и уведомлений.
revoke select on all tables in schema public from anon,authenticated;
grant select on public.profiles to anon,authenticated;
grant select on public.games,public.fleets,public.shots to authenticated;

-- Чужая расстановка видна только после публичного завершенного матча.
-- Участники и администратор сохраняют необходимый им доступ.
drop policy if exists "games readable" on public.games;
create policy "games readable" on public.games for select to authenticated
using(
  auth.uid() in(player1_id,player2_id)
  or public.is_game_admin(auth.uid())
  or (visibility='public' and status in('waiting','playing','paused','finished'))
);

drop policy if exists "own fleet readable" on public.fleets;
create policy "own fleet readable" on public.fleets for select to authenticated
using(
  auth.uid()=owner_id
  or public.is_game_admin(auth.uid())
  or exists(
    select 1
    from public.games g
    where g.id=fleets.game_id
      and g.status='finished'
      and (
        g.visibility='public'
        or auth.uid() in(g.player1_id,g.player2_id)
      )
  )
);

drop policy if exists "shots readable" on public.shots;
create policy "shots readable" on public.shots for select to authenticated
using(
  public.is_game_admin(auth.uid())
  or exists(
    select 1
    from public.games g
    where g.id=shots.game_id
      and (
        auth.uid() in(g.player1_id,g.player2_id)
        or (
          g.visibility='public'
          and g.status in('playing','paused','finished')
        )
      )
  )
);

-- PostgreSQL по умолчанию может выдавать PUBLIC право запуска новой функции.
-- Сначала закрываем все функции проекта, затем открываем только RPC,
-- которыми действительно пользуется приложение.
do $$
declare
  function_signature text;
begin
  for function_signature in
    select format(
      '%I.%I(%s)',
      n.nspname,
      p.proname,
      pg_get_function_identity_arguments(p.oid)
    )
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
  loop
    execute format(
      'revoke execute on function %s from public,anon,authenticated',
      function_signature
    );
  end loop;
end;
$$;

-- Доступ без входа: только безопасные публичные списки и проверки.
grant execute on function public.is_school_nick_available(text) to anon,authenticated;
grant execute on function public.get_leaderboard() to anon,authenticated;
grant execute on function public.list_public_tournaments() to anon,authenticated;
grant execute on function public.get_tournament_board(uuid) to anon,authenticated;

-- Действия вошедшего пользователя.
grant execute on function public.claim_random_guest() to authenticated;
grant execute on function public.is_game_admin(uuid) to authenticated;
grant execute on function public.list_active_games() to authenticated;
grant execute on function public.create_game(uuid,text) to authenticated;
grant execute on function public.join_public_game(uuid) to authenticated;
grant execute on function public.cancel_game(uuid) to authenticated;
grant execute on function public.leave_game(uuid) to authenticated;
grant execute on function public.ready_with_fleet(uuid,jsonb) to authenticated;
grant execute on function public.shoot(uuid,text) to authenticated;
grant execute on function public.surrender_game(uuid) to authenticated;
grant execute on function public.list_match_history() to authenticated;
grant execute on function public.get_public_player_profile(uuid) to authenticated;
grant execute on function public.apply_to_tournament(uuid) to authenticated;
grant execute on function public.withdraw_tournament_application(uuid) to authenticated;
grant execute on function public.list_user_notifications(integer) to authenticated;
grant execute on function public.mark_user_notifications_read(text,uuid) to authenticated;

-- Админские RPC доступны вошедшему пользователю, но каждая из них внутри
-- обязательно вызывает require_game_admin().
grant execute on function public.admin_list_players() to authenticated;
grant execute on function public.admin_set_school_verified(uuid,boolean) to authenticated;
grant execute on function public.admin_list_games(text) to authenticated;
grant execute on function public.admin_get_game_details(uuid) to authenticated;
grant execute on function public.admin_cancel_game(uuid,text) to authenticated;
grant execute on function public.admin_list_notifications(integer) to authenticated;
grant execute on function public.admin_mark_notifications_read(uuid) to authenticated;
grant execute on function public.admin_publish_user_announcement(text,text) to authenticated;
grant execute on function public.admin_create_tournament(text,uuid,integer,text,timestamptz) to authenticated;
grant execute on function public.admin_set_tournament_registration_deadline(uuid,timestamptz) to authenticated;
grant execute on function public.admin_review_tournament_application(uuid,uuid,text) to authenticated;
grant execute on function public.admin_add_tournament_player(uuid,uuid) to authenticated;
grant execute on function public.admin_remove_tournament_player(uuid,uuid) to authenticated;
grant execute on function public.admin_configure_tournament_qualifiers(uuid,integer,integer) to authenticated;
grant execute on function public.admin_generate_tournament(uuid) to authenticated;
grant execute on function public.admin_start_tournament_qualifiers(uuid) to authenticated;
grant execute on function public.admin_start_tournament_playoff(uuid) to authenticated;
grant execute on function public.admin_close_tournament(uuid) to authenticated;
grant execute on function public.admin_delete_tournament(uuid) to authenticated;

-- Администратор может повторять эту проверку после следующих обновлений.
create or replace function public.admin_security_audit()
returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  all_rls_enabled boolean;
  direct_changes_blocked boolean;
  internal_tables_hidden boolean;
  fleet_policy_safe boolean;
  rpc_allowlist_safe boolean;
  result jsonb;
begin
  perform public.require_game_admin();

  select not exists(
    select 1
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relkind in('r','p')
      and not c.relrowsecurity
  ) into all_rls_enabled;

  select not exists(
    select 1
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relkind in('r','p')
      and (
        has_table_privilege('anon',c.oid,'INSERT')
        or has_table_privilege('anon',c.oid,'UPDATE')
        or has_table_privilege('anon',c.oid,'DELETE')
        or has_table_privilege('authenticated',c.oid,'INSERT')
        or has_table_privilege('authenticated',c.oid,'UPDATE')
        or has_table_privilege('authenticated',c.oid,'DELETE')
      )
  ) into direct_changes_blocked;

  select not exists(
    select 1
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relkind in('r','p')
      and c.relname not in('profiles','games','fleets','shots')
      and (
        has_table_privilege('anon',c.oid,'SELECT')
        or has_table_privilege('authenticated',c.oid,'SELECT')
      )
  ) into internal_tables_hidden;

  select coalesce(
    bool_or(
      coalesce(qual,'') ilike '%owner_id%'
      and coalesce(qual,'') ilike '%finished%'
      and coalesce(qual,'') ilike '%visibility%'
    ),false
  )
  from pg_policies
  where schemaname='public'
    and tablename='fleets'
    and policyname='own fleet readable'
  into fleet_policy_safe;

  select not exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and (
        has_function_privilege('anon',p.oid,'EXECUTE')
        or has_function_privilege('authenticated',p.oid,'EXECUTE')
      )
      and p.proname not in(
        'is_school_nick_available','get_leaderboard','list_public_tournaments',
        'get_tournament_board','claim_random_guest','is_game_admin','list_active_games',
        'create_game','join_public_game','cancel_game','leave_game','ready_with_fleet',
        'shoot','surrender_game','list_match_history','get_public_player_profile',
        'apply_to_tournament','withdraw_tournament_application','list_user_notifications',
        'mark_user_notifications_read','admin_list_players','admin_set_school_verified',
        'admin_list_games','admin_get_game_details','admin_cancel_game',
        'admin_list_notifications','admin_mark_notifications_read',
        'admin_publish_user_announcement','admin_create_tournament',
        'admin_set_tournament_registration_deadline','admin_review_tournament_application',
        'admin_add_tournament_player','admin_remove_tournament_player',
        'admin_configure_tournament_qualifiers','admin_generate_tournament',
        'admin_start_tournament_qualifiers','admin_start_tournament_playoff',
        'admin_close_tournament','admin_delete_tournament','admin_security_audit'
      )
  ) into rpc_allowlist_safe;

  result:=jsonb_build_object(
    'passed',all_rls_enabled and direct_changes_blocked and internal_tables_hidden
      and fleet_policy_safe and rpc_allowlist_safe,
    'checked_at',now(),
    'items',jsonb_build_array(
      jsonb_build_object('key','rls','label','защита строк включена у всех таблиц','passed',all_rls_enabled),
      jsonb_build_object('key','writes','label','прямое изменение таблиц из браузера запрещено','passed',direct_changes_blocked),
      jsonb_build_object('key','tables','label','внутренние таблицы скрыты от браузера','passed',internal_tables_hidden),
      jsonb_build_object('key','fleets','label','чужие расстановки скрыты до завершения матча','passed',fleet_policy_safe),
      jsonb_build_object('key','rpc','label','служебные функции закрыты','passed',rpc_allowlist_safe)
    )
  );

  return result;
end;
$$;

revoke execute on function public.admin_security_audit() from public,anon;
grant execute on function public.admin_security_audit() to authenticated;

commit;
