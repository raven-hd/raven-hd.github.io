-- обновление 035: настройки баланса в одной таблице и управление ими из админ-панели.
-- выполнять после 034. новые значения действуют только для будущих результатов;
-- уже начисленный рейтинг не пересчитывается.
--
-- что внутри:
--   1) таблица game_settings: K-фактор рейтинга, очки за турнирный матч, лимит рейтинговых игр пары;
--      у каждой настройки есть допустимый диапазон, запоминается кто и когда менял;
--   2) админские RPC: admin_get_game_settings(), admin_update_game_setting(key, value) — только для админа;
--   3) публичный RPC get_public_game_settings() — числа для подсказок игрокам;
--   4) три функции, где числа были зашиты, теперь читают настройки
--      (копии актуальных версий из 029 и 020, изменены только числа);
--   5) самопроверка защиты знает о новых RPC (копия 033 + три имени в белом списке).

begin;

-- 1) таблица настроек. напрямую из браузера недоступна — только через функции ниже.
create table if not exists public.game_settings (
  key text primary key,
  title text not null,
  description text not null,
  value integer not null,
  min_value integer not null,
  max_value integer not null,
  sort_order integer not null default 0,
  updated_at timestamptz,
  updated_by uuid references auth.users(id) on delete set null,
  constraint game_settings_value_in_range check (min_value <= value and value <= max_value)
);

alter table public.game_settings enable row level security;
revoke all on public.game_settings from anon, authenticated;

-- значения по умолчанию = нынешние правила игры. повторный запуск не трогает уже изменённые значения.
insert into public.game_settings(key, title, description, value, min_value, max_value, sort_order) values
  ('elo_k', 'K-фактор рейтинга',
   'насколько сильно меняется рейтинг за одну рейтинговую партию. при равных соперниках победитель получает половину этого числа.',
   16, 4, 64, 1),
  ('tournament_points', 'очки за турнирный матч',
   'сколько очков получает победитель и теряет проигравший в турнирном матче.',
   12, 1, 50, 2),
  ('pair_daily_limit', 'лимит рейтинговых матчей пары',
   'сколько рейтинговых матчей одна пара может сыграть за 24 часа. следующие матчи этой пары пройдут без рейтинга.',
   3, 1, 20, 3)
on conflict (key) do nothing;

-- чтение настройки внутри серверных функций. если строки нет — безопасное значение по умолчанию,
-- чтобы игра не сломалась из-за испорченной таблицы.
create or replace function public.game_setting(p_key text, p_default integer)
returns integer
language sql stable security definer set search_path=''
as $$
  select coalesce((select s.value from public.game_settings s where s.key = p_key), p_default);
$$;

-- 2) админские функции
create or replace function public.admin_get_game_settings()
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
begin
  perform public.require_game_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'key', s.key,
      'title', s.title,
      'description', s.description,
      'value', s.value,
      'min_value', s.min_value,
      'max_value', s.max_value,
      'updated_at', s.updated_at,
      'updated_by_name', p.display_name
    ) order by s.sort_order, s.key)
    from public.game_settings s
    left join public.profiles p on p.user_id = s.updated_by
  ), '[]'::jsonb);
end;
$$;

create or replace function public.admin_update_game_setting(p_key text, p_value integer)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  s public.game_settings%rowtype;
begin
  perform public.require_game_admin();

  select * into s from public.game_settings where key = p_key for update;
  if not found then raise exception 'Unknown game setting'; end if;
  if p_value is null or p_value < s.min_value or p_value > s.max_value then
    raise exception 'Game setting out of range';
  end if;

  update public.game_settings
  set value = p_value, updated_at = now(), updated_by = auth.uid()
  where key = p_key
  returning * into s;

  return jsonb_build_object('key', s.key, 'value', s.value, 'updated_at', s.updated_at);
end;
$$;

-- 3) публичные числа для подсказок игрокам. перечислены явно, чтобы будущие
--    служебные настройки не попали сюда случайно.
create or replace function public.get_public_game_settings()
returns jsonb
language sql stable security definer set search_path=''
as $$
  select jsonb_build_object(
    'elo_k', public.game_setting('elo_k', 16),
    'tournament_points', public.game_setting('tournament_points', 12),
    'pair_daily_limit', public.game_setting('pair_daily_limit', 3)
  );
$$;

revoke execute on function public.game_setting(text, integer) from public, anon, authenticated;
revoke execute on function public.admin_get_game_settings() from public, anon;
revoke execute on function public.admin_update_game_setting(text, integer) from public, anon;
revoke execute on function public.get_public_game_settings() from public;
grant execute on function public.admin_get_game_settings() to authenticated;
grant execute on function public.admin_update_game_setting(text, integer) to authenticated;
grant execute on function public.get_public_game_settings() to anon, authenticated;

-- 4) функции, где числа были зашиты. копии актуальных версий (029 и 020); изменены только числа.

create or replace function public.apply_finished_game_rating()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  p1 public.profiles%rowtype;
  p2 public.profiles%rowtype;
  recent_rated_count integer:=0;
  expected_p1 numeric;
  delta integer;
  p1_after integer;
  p2_after integer;
  v_elo_k integer:=public.game_setting('elo_k',16);
  v_pair_limit integer:=public.game_setting('pair_daily_limit',3);
begin
  if new.game_type<>'rated' or new.rating_applied then return new; end if;
  if new.player2_id is null
     or new.winner_id is null
     or new.winner_id not in(new.player1_id,new.player2_id) then
    return new;
  end if;

  perform locked.user_id
  from public.profiles locked
  where locked.user_id in(new.player1_id,new.player2_id)
  order by locked.user_id
  for update;

  select * into p1 from public.profiles where user_id=new.player1_id;
  select * into p2 from public.profiles where user_id=new.player2_id;

  if p1.account_type<>'registered' or p2.account_type<>'registered' then
    update public.games
    set game_type='casual',rating_skip_reason='guest'
    where id=new.id;
    return new;
  end if;

  select count(*)::integer into recent_rated_count
  from public.games prior
  where prior.id<>new.id
    and prior.rating_applied=true
    and prior.finished_at>now()-interval '24 hours'
    and (
      (prior.player1_id=new.player1_id and prior.player2_id=new.player2_id)
      or
      (prior.player1_id=new.player2_id and prior.player2_id=new.player1_id)
    );

  if recent_rated_count>=v_pair_limit then
    update public.games
    set game_type='casual',rating_skip_reason='pair_daily_limit'
    where id=new.id;
    return new;
  end if;

  expected_p1:=1/(1+power(10::numeric,(p2.rating-p1.rating)::numeric/400));
  if new.winner_id=new.player1_id then
    delta:=round(v_elo_k*(1-expected_p1))::integer;
    p1_after:=p1.rating+delta;
    p2_after:=p2.rating-delta;
  else
    delta:=round(v_elo_k*expected_p1)::integer;
    p1_after:=p1.rating-delta;
    p2_after:=p2.rating+delta;
  end if;

  update public.profiles
  set rating=p1_after,
      rated_games=rated_games+1,
      rated_wins=rated_wins+case when new.winner_id=new.player1_id then 1 else 0 end,
      rated_losses=rated_losses+case when new.winner_id=new.player2_id then 1 else 0 end
  where user_id=new.player1_id;

  update public.profiles
  set rating=p2_after,
      rated_games=rated_games+1,
      rated_wins=rated_wins+case when new.winner_id=new.player2_id then 1 else 0 end,
      rated_losses=rated_losses+case when new.winner_id=new.player1_id then 1 else 0 end
  where user_id=new.player2_id;

  update public.games
  set rating_applied=true,
      rating_delta=delta,
      player1_rating_before=p1.rating,
      player1_rating_after=p1_after,
      player2_rating_before=p2.rating,
      player2_rating_after=p2_after
  where id=new.id;

  return new;
end;
$$;

create or replace function public.apply_tournament_ratings(p_tournament_id uuid)
returns void
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  match_rec record;
  player_rec record;
  winner_before integer;
  loser_before integer;
  winner_after integer;
  loser_after integer;
  loser_id uuid;
  champion_id uuid;
  champion_name text;
  player_change integer;
  player_rating integer;
  rated_match_count integer;
  v_points integer:=public.game_setting('tournament_points',12);
begin
  select * into t
  from public.tournaments
  where id=p_tournament_id
  for update;

  if not found or t.status<>'finished' or t.rating_applied then return; end if;

  select tm.winner_id,p.display_name
  into champion_id,champion_name
  from public.tournament_matches tm
  left join public.profiles p on p.user_id=tm.winner_id
  where tm.tournament_id=t.id
    and tm.stage='playoff'
    and tm.next_match_id is null
    and tm.winner_id is not null
  order by tm.round_no desc,tm.position
  limit 1;

  for match_rec in
    select
      tm.id as tournament_match_id,
      tm.player1_id,
      tm.player2_id,
      tm.winner_id,
      g.id as game_id
    from public.tournament_matches tm
    join public.games g on g.id=tm.game_id
    join public.profiles p1 on p1.user_id=tm.player1_id and p1.account_type='registered'
    join public.profiles p2 on p2.user_id=tm.player2_id and p2.account_type='registered'
    where tm.tournament_id=t.id
      and tm.status='finished'
      and tm.result_reason='game'
      and tm.winner_id in(tm.player1_id,tm.player2_id)
      and g.status='finished'
      and not g.tournament_rating_applied
    order by coalesce(tm.resolved_at,g.finished_at,g.updated_at),tm.created_at,tm.id
  loop
    loser_id:=case
      when match_rec.winner_id=match_rec.player1_id then match_rec.player2_id
      else match_rec.player1_id
    end;

    perform locked.user_id
    from public.profiles locked
    where locked.user_id in(match_rec.winner_id,loser_id)
    order by locked.user_id
    for update;

    select rating into winner_before from public.profiles where user_id=match_rec.winner_id;
    select rating into loser_before from public.profiles where user_id=loser_id;
    winner_after:=winner_before+v_points;
    loser_after:=loser_before-v_points;

    update public.profiles
    set rating=winner_after,
        rated_games=rated_games+1,
        rated_wins=rated_wins+1
    where user_id=match_rec.winner_id;

    update public.profiles
    set rating=loser_after,
        rated_games=rated_games+1,
        rated_losses=rated_losses+1
    where user_id=loser_id;

    update public.games
    set tournament_rating_applied=true,
        tournament_rating_delta=v_points,
        player1_rating_before=case when player1_id=match_rec.winner_id then winner_before else loser_before end,
        player1_rating_after=case when player1_id=match_rec.winner_id then winner_after else loser_after end,
        player2_rating_before=case when player2_id=match_rec.winner_id then winner_before else loser_before end,
        player2_rating_after=case when player2_id=match_rec.winner_id then winner_after else loser_after end
    where id=match_rec.game_id;
  end loop;

  update public.tournaments
  set rating_applied=true,rating_applied_at=now(),updated_at=now()
  where id=t.id;

  for player_rec in
    select distinct participant.user_id,p.display_name
    from public.tournament_matches tm
    join public.games g on g.id=tm.game_id and g.tournament_rating_applied
    cross join lateral (values(tm.player1_id),(tm.player2_id)) as participant(user_id)
    join public.profiles p on p.user_id=participant.user_id and p.account_type='registered'
    where tm.tournament_id=t.id
  loop
    select
      count(*)::integer,
      coalesce(sum(case when tm.winner_id=player_rec.user_id then v_points else -v_points end),0)::integer
    into rated_match_count,player_change
    from public.tournament_matches tm
    join public.games g on g.id=tm.game_id and g.tournament_rating_applied
    where tm.tournament_id=t.id
      and player_rec.user_id in(tm.player1_id,tm.player2_id);

    if rated_match_count=0 then continue; end if;
    select rating into player_rating from public.profiles where user_id=player_rec.user_id;
    perform public.push_user_notification(
      player_rec.user_id,
      'reward',
      case when player_rec.user_id=champion_id then 'вы победили в турнире' else 'турнир завершен' end,
      '«'||t.name||'». рейтинг '
        ||case when player_change>=0 then '+' else '−' end||abs(player_change)::text
        ||' — теперь '||player_rating::text||'. победитель: '||coalesce(champion_name,'не определен')||'.',
      null,t.id,null,
      'tournament-rating:'||t.id::text||':'||player_rec.user_id::text
    );
  end loop;
end;
$$;

create or replace function public.join_public_game(p_game_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  p public.profiles%rowtype;
  creator public.profiles%rowtype;
  g public.games%rowtype;
  existing_game_id uuid;
  recent_rated_count integer:=0;
  actual_type text;
  skip_reason text;
  v_pair_limit integer:=public.game_setting('pair_daily_limit',3);
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into p from public.profiles where user_id=uid;
  if not found then raise exception 'Profile required'; end if;

  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.player1_id=uid then raise exception 'Cannot join your own game'; end if;
  if g.player2_id=uid and g.status in('placing','playing','paused') then
    return to_jsonb(g);
  end if;
  if g.visibility<>'public' or g.status<>'waiting' or g.player2_id is not null then
    raise exception 'Game is full';
  end if;

  perform locked.user_id
  from public.profiles locked
  where locked.user_id in(uid,g.player1_id)
  order by locked.user_id
  for update;

  select * into creator from public.profiles where user_id=g.player1_id;

  select active_game.id into existing_game_id
  from public.games active_game
  where active_game.id<>g.id
    and active_game.game_type<>'tournament'
    and active_game.status in('placing','playing','paused')
    and (
      (active_game.player1_id=g.player1_id and active_game.player2_id=uid)
      or
      (active_game.player1_id=uid and active_game.player2_id=g.player1_id)
    )
  order by active_game.updated_at desc
  limit 1;

  if existing_game_id is not null then
    raise exception 'Pair already has active game: %',existing_game_id;
  end if;

  actual_type:=g.game_type;
  skip_reason:=g.rating_skip_reason;
  if g.game_type='rated' then
    if p.account_type='guest' or creator.account_type='guest' then
      actual_type:='casual';
      skip_reason:='guest';
    else
      select count(*)::integer into recent_rated_count
      from public.games prior
      where prior.rating_applied=true
        and prior.finished_at>now()-interval '24 hours'
        and (
          (prior.player1_id=g.player1_id and prior.player2_id=uid)
          or
          (prior.player1_id=uid and prior.player2_id=g.player1_id)
        );
      if recent_rated_count>=v_pair_limit then
        actual_type:='casual';
        skip_reason:='pair_daily_limit';
      end if;
    end if;
  end if;

  update public.games
  set player2_id=uid,player2_name=p.display_name,status='placing',
      game_type=actual_type,rating_skip_reason=skip_reason,
      player2_action_at=now(),updated_at=now()
  where public.games.id=g.id returning * into g;
  return to_jsonb(g);
end;
$$;

revoke execute on function public.apply_finished_game_rating() from public, anon, authenticated;
revoke execute on function public.apply_tournament_ratings(uuid) from public, anon, authenticated;
revoke execute on function public.join_public_game(uuid) from public, anon;
grant execute on function public.join_public_game(uuid) to authenticated;

-- 5) самопроверка защиты: копия 033, в белый список добавлены новые RPC.

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
        'admin_close_tournament','admin_delete_tournament','admin_security_audit',
        'admin_set_tournament_archived','admin_set_tournament_format',
        'admin_change_school_nick','admin_get_game_settings','admin_update_game_setting',
        'get_public_game_settings'
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

commit;
