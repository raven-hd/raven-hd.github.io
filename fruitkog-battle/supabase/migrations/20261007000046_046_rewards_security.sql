-- обновление 133: безопасность наград и аватаров после добавления новых RPC.
-- ветка fruitkog-rewards; не применять на основном проекте до завершения текущего турнира.

begin;

-- Аватар можно читать как публичное оформление профиля, но менять его
-- пользователь должен только через серверную функцию.
revoke insert,update,delete on public.fruitkog_avatars from anon,authenticated;
grant select on public.fruitkog_avatars to authenticated;

create or replace function public.set_fruitkog_avatar(p_avatar_id text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  wanted text:=lower(trim(coalesce(p_avatar_id,'')));
begin
  if uid is null then raise exception 'Authentication required'; end if;

  if not exists(
    select 1
    from public.profiles p
    where p.user_id=uid and p.account_type='registered'
  ) then
    raise exception 'Registered profile required';
  end if;

  if wanted !~ '^(tomato|celery|mushroom|eggplant|garlic|corn)-(happy|grumpy|cool|surprised)$' then
    raise exception 'Invalid avatar';
  end if;

  insert into public.fruitkog_avatars(user_id,avatar_id)
  values(uid,wanted)
  on conflict(user_id) do update
  set avatar_id=excluded.avatar_id;

  return jsonb_build_object('user_id',uid,'avatar_id',wanted);
end;
$$;

revoke execute on function public.set_fruitkog_avatar(text) from public,anon;
grant execute on function public.set_fruitkog_avatar(text) to authenticated;

-- Обновленная встроенная проверка защиты:
-- fruitkog_avatars разрешена только на чтение, остальные новые таблицы наград скрыты.
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
      and c.relkind in('r','p','v','m','f')
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
      and c.relkind in('r','p','v','m','f')
      and c.relname not in('profiles','games','fleets','shots','fruitkog_avatars')
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
        'admin_list_games','admin_list_games_page','admin_game_counts','admin_get_game_details','admin_cancel_game',
        'admin_list_notifications','admin_mark_notifications_read',
        'admin_publish_user_announcement','admin_create_tournament',
        'admin_set_tournament_registration_deadline','admin_review_tournament_application',
        'admin_add_tournament_player','admin_remove_tournament_player',
        'admin_configure_tournament_qualifiers','admin_generate_tournament',
        'admin_start_tournament_qualifiers','admin_start_tournament_playoff',
        'admin_close_tournament','admin_delete_tournament','admin_security_audit',
        'admin_set_tournament_archived','admin_set_tournament_format',
        'admin_change_school_nick','admin_get_game_settings','admin_update_game_setting',
        'get_public_game_settings','admin_award_technical_win','admin_replay_tournament_match',
        'admin_start_qualifier_tiebreak',
        'set_fruitkog_avatar','get_my_fruitkog_rewards','set_fruitkog_ship_skin',
        'get_my_game_boosts','admin_grant_fruitkog_reward',
        'admin_revoke_fruitkog_reward','admin_list_fruitkog_rewards'
      )
  ) into rpc_allowlist_safe;

  rpc_allowlist_safe:=rpc_allowlist_safe and not exists(
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and (
        has_function_privilege('anon',p.oid,'EXECUTE')
        or has_function_privilege('authenticated',p.oid,'EXECUTE')
      )
    group by p.proname
    having count(*)>1
  );

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

commit;
