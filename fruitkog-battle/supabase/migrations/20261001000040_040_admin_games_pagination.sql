-- Постраничный просмотр матчей в админке. Существующие данные не изменяются.
create or replace function public.admin_game_counts()
returns jsonb
language plpgsql security definer stable set search_path=''
as $$
declare result jsonb;
begin
  perform public.require_game_admin();
  select jsonb_build_object(
    'all', count(*),
    'active', count(*) filter (where status in ('waiting','placing','playing','paused')),
    'paused', count(*) filter (where status='paused'),
    'finished', count(*) filter (where status='finished'),
    'cancelled', count(*) filter (where status='cancelled')
  ) into result from public.games;
  return result;
end;
$$;

create or replace function public.admin_list_games_page(
  p_filter text,
  p_offset integer,
  p_limit integer
)
returns table(
  id uuid,
  player1_id uuid,
  player1_name text,
  player2_id uuid,
  player2_name text,
  player1_ready boolean,
  player2_ready boolean,
  game_type text,
  status text,
  current_turn uuid,
  winner_id uuid,
  finish_reason text,
  surrendered_by uuid,
  rating_applied boolean,
  rating_delta integer,
  rating_skip_reason text,
  created_at timestamptz,
  updated_at timestamptz,
  finished_at timestamptz,
  paused_at timestamptz,
  pause_reason text,
  admin_cancelled_by uuid,
  admin_cancelled_at timestamptz,
  admin_cancel_reason text,
  shot_count bigint,
  pair_finished_24h bigint,
  pair_surrenders_24h bigint
)
language plpgsql security definer stable set search_path=''
as $$
declare wanted text:=lower(trim(coalesce(p_filter,'active')));
begin
  perform public.require_game_admin();
  if wanted not in ('all','active','paused','finished','cancelled')
     or p_offset is null or p_offset<0
     or p_limit is null or p_limit<1 or p_limit>100 then
    raise exception 'Invalid admin game page';
  end if;

  return query
  select g.id,g.player1_id,g.player1_name,g.player2_id,g.player2_name,
         g.player1_ready,g.player2_ready,g.game_type,g.status,g.current_turn,
         g.winner_id,g.finish_reason,g.surrendered_by,g.rating_applied,
         g.rating_delta,g.rating_skip_reason,g.created_at,g.updated_at,g.finished_at,
         g.paused_at,g.pause_reason,g.admin_cancelled_by,g.admin_cancelled_at,
         g.admin_cancel_reason,
         (select count(*) from public.shots s where s.game_id=g.id) as shot_count,
         case when g.player2_id is null then 0::bigint else (
           select count(*) from public.games prior
           where prior.status='finished'
             and prior.finished_at>now()-interval '24 hours'
             and ((prior.player1_id=g.player1_id and prior.player2_id=g.player2_id)
               or (prior.player1_id=g.player2_id and prior.player2_id=g.player1_id))
         ) end as pair_finished_24h,
         case when g.player2_id is null then 0::bigint else (
           select count(*) from public.games prior
           where prior.status='finished' and prior.finish_reason='surrender'
             and prior.finished_at>now()-interval '24 hours'
             and ((prior.player1_id=g.player1_id and prior.player2_id=g.player2_id)
               or (prior.player1_id=g.player2_id and prior.player2_id=g.player1_id))
         ) end as pair_surrenders_24h
  from public.games g
  where wanted='all'
     or (wanted='active' and g.status in ('waiting','placing','playing','paused'))
     or (wanted='paused' and g.status='paused')
     or (wanted='finished' and g.status='finished')
     or (wanted='cancelled' and g.status='cancelled')
  order by
    case when g.status in ('paused','playing','placing','waiting') then 0 else 1 end,
    coalesce(g.updated_at,g.created_at) desc,
    g.id desc
  limit p_limit offset p_offset;
end;
$$;

revoke execute on function public.admin_game_counts() from public,anon;
revoke execute on function public.admin_list_games_page(text,integer,integer) from public,anon;
grant execute on function public.admin_game_counts() to authenticated;
grant execute on function public.admin_list_games_page(text,integer,integer) to authenticated;


-- Встроенная проверка защиты учитывает две новые админские функции.
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
        'admin_start_qualifier_tiebreak'
      )
  ) into rpc_allowlist_safe;

  -- у открытой браузеру функции должна быть ровно одна версия: вторая (перегрузка с тем же
  -- именем) прошла бы проверку белого списка по имени, хотя ее никто сознательно не открывал
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
