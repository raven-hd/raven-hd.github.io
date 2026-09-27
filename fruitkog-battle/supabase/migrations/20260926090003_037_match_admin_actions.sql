-- обновление 117: техническая победа и переигровка турнирного матча.
-- выполните после 036. повторный запуск безопасен.
--
-- если турнирный матч сорвался (соперник не пришел, игра зависла, админ нажал «закрыть матч»),
-- админ в управлении турниром может:
--   * засчитать техническую победу одному из игроков — матч решен без игры, рейтинг за него
--     не меняется; в плей-офф победитель сразу проходит дальше, а решенный так финал
--     завершает турнир; в квалификации техпобеда считается победой в таблице;
--   * назначить переигровку — текущая игра пары отменяется, открывается новая комната,
--     оба игрока получают уведомление.
-- незавершенная игра пары отменяется так же, как по кнопке «закрыть матч»: поля и ходы
-- остаются в истории для администратора.
--
-- продвижение победителя плей-офф вынесено в общий помощник advance_playoff_winner:
-- им пользуются и триггер завершения игры (022), и техническая победа, чтобы правило было одно.
-- финалом считается только единственная пара последнего раунда: в старых сетках «плей-офф»
-- (до 036) связей между раундами нет, и техпобеда там не должна «завершать» турнир.
--
-- комнаты, которые сервер открывает участникам уже идущего турнира (следующий раунд,
-- переигровка), не блокируются снятым подтверждением ника: состав турнира проверяется при
-- одобрении заявки и при жеребьевке (036). раньше исключение действовало только для комнат,
-- открытых триггером после завершенной игры; теперь — и для действий администратора.

-- комната для пары (как в 021 и 036). внутренняя функция: из браузера недоступна.
create or replace function public.create_tournament_room(p_player1 uuid,p_player2 uuid)
returns uuid
language plpgsql set search_path=''
as $$
declare
  p1_name text;
  p2_name text;
  new_code text;
  new_game_id uuid;
begin
  select display_name into p1_name from public.profiles where user_id=p_player1;
  select display_name into p2_name from public.profiles where user_id=p_player2;
  loop
    new_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
    exit when not exists(select 1 from public.games where code=new_code);
  end loop;
  -- отметка для require_verified_competitive_players: комнату открывает сервер участникам
  -- идущего турнира. действует только внутри этой транзакции и сразу снимается.
  perform set_config('fruitkog.tournament_room','on',true);
  insert into public.games(
    code,game_type,visibility,player1_id,player1_name,player2_id,player2_name,
    status,player1_action_at,player2_action_at,updated_at
  ) values(
    new_code,'tournament','public',p_player1,p1_name,p_player2,p2_name,
    'placing',now(),now(),now()
  ) returning id into new_game_id;
  perform set_config('fruitkog.tournament_room','off',true);
  return new_game_id;
end;
$$;

-- победитель пары плей-офф проходит дальше: встает на свое место в следующей паре, а когда
-- известны оба соперника — для них открывается комната. у финала следующей пары нет:
-- турнир завершается и начисляется турнирный рейтинг. правило — как в 022.
create or replace function public.advance_playoff_winner(p_match_id uuid)
returns void
language plpgsql set search_path=''
as $$
declare
  current_match public.tournament_matches%rowtype;
  next_match public.tournament_matches%rowtype;
  next_p1 uuid;
  next_p2 uuid;
  new_game_id uuid;
begin
  select * into current_match from public.tournament_matches where id=p_match_id;
  if not found or current_match.stage<>'playoff' or current_match.winner_id is null then
    return;
  end if;

  if current_match.next_match_id is null then
    -- финал — единственная пара последнего раунда. в старых сетках без связей (до 036)
    -- у пар первого раунда тоже нет следующей пары: там турнир не завершаем
    if exists(
      select 1 from public.tournament_matches
      where tournament_id=current_match.tournament_id and stage='playoff'
        and id<>current_match.id and round_no>=current_match.round_no
    ) then
      return;
    end if;
    update public.tournaments
    set status='finished',finished_at=coalesce(finished_at,now()),updated_at=now()
    where id=current_match.tournament_id;
    perform public.apply_tournament_ratings(current_match.tournament_id);
    return;
  end if;

  select * into next_match
  from public.tournament_matches
  where id=current_match.next_match_id
  for update;

  next_p1:=case when current_match.next_slot=1 then current_match.winner_id else next_match.player1_id end;
  next_p2:=case when current_match.next_slot=2 then current_match.winner_id else next_match.player2_id end;

  if next_p1 is not null and next_p2 is not null and next_match.game_id is null then
    new_game_id:=public.create_tournament_room(next_p1,next_p2);
    update public.tournament_matches
    set player1_id=next_p1,player2_id=next_p2,game_id=new_game_id,status='ready'
    where id=next_match.id;
  else
    update public.tournament_matches
    set player1_id=next_p1,player2_id=next_p2
    where id=next_match.id;
  end if;

  update public.tournaments set updated_at=now() where id=current_match.tournament_id;
end;
$$;

-- триггер завершения турнирной игры (022): то же самое, только продвижение — через помощник
create or replace function public.sync_tournament_match_from_game()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  current_match public.tournament_matches%rowtype;
begin
  if new.game_type<>'tournament' then return new; end if;

  update public.tournament_matches
  set status=case
        when new.status='playing' then 'playing'
        when new.status='finished' then 'finished'
        when new.status='cancelled' then 'cancelled'
        else status
      end,
      winner_id=case when new.status='finished' then new.winner_id else winner_id end,
      result_reason=case
        when new.status='finished' then 'game'
        when new.status='cancelled' then 'cancelled'
        else result_reason
      end,
      resolved_at=case
        when new.status in('finished','cancelled') then coalesce(resolved_at,now())
        else resolved_at
      end
  where game_id=new.id
  returning * into current_match;

  if not found
     or current_match.stage<>'playoff'
     or new.status<>'finished'
     or old.status='finished'
     or current_match.winner_id is null then
    return new;
  end if;

  perform public.advance_playoff_winner(current_match.id);
  return new;
end;
$$;

-- незавершенную игру пары закрывает администратор (как admin_cancel_game)
create or replace function public.cancel_tournament_room(p_game_id uuid,p_reason text)
returns void
language plpgsql set search_path=''
as $$
begin
  if p_game_id is null then return; end if;
  update public.games
  set status='cancelled',current_turn=null,winner_id=null,finished_at=null,
      finish_reason=null,surrendered_by=null,updated_at=now(),
      admin_cancelled_by=auth.uid(),admin_cancelled_at=now(),
      admin_cancel_reason=p_reason
  where id=p_game_id and status in('waiting','placing','playing','paused');
end;
$$;

-- техническая победа: матч решен без игры
create or replace function public.admin_award_technical_win(p_match_id uuid,p_winner_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  m public.tournament_matches%rowtype;
begin
  perform public.require_game_admin();
  select * into m from public.tournament_matches where id=p_match_id;
  if not found then raise exception 'Tournament match not found'; end if;
  -- блокировки в том же порядке, что и при завершении игры (игра → пара → следующая пара →
  -- турнир): если игрок в этот момент делает последний ход, одно действие подождет другое
  if m.game_id is not null then
    perform 1 from public.games where id=m.game_id for update;
  end if;
  select * into m from public.tournament_matches where id=p_match_id for update;
  select * into t from public.tournaments where id=m.tournament_id;
  if t.status<>'active' then raise exception 'Tournament not active'; end if;
  if m.status in('finished','technical')
     or exists(select 1 from public.games where id=m.game_id and status='finished') then
    raise exception 'Tournament match already resolved';
  end if;
  if m.player1_id is null or m.player2_id is null then raise exception 'Tournament match players missing'; end if;
  if p_winner_id is null or p_winner_id not in(m.player1_id,m.player2_id) then
    raise exception 'Winner must be a match player';
  end if;

  perform public.cancel_tournament_room(m.game_id,'техническая победа в турнире');
  update public.tournament_matches
  set status='technical',winner_id=p_winner_id,result_reason='technical',resolved_at=now()
  where id=m.id;
  perform public.advance_playoff_winner(m.id);

  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

-- переигровка: текущая игра пары отменяется, открывается новая комната
create or replace function public.admin_replay_tournament_match(p_match_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  m public.tournament_matches%rowtype;
  new_game_id uuid;
  player_id uuid;
  opponent_name text;
begin
  perform public.require_game_admin();
  select * into m from public.tournament_matches where id=p_match_id;
  if not found then raise exception 'Tournament match not found'; end if;
  -- блокировки в том же порядке, что и при завершении игры (игра → пара → следующая пара →
  -- турнир): если игрок в этот момент делает последний ход, одно действие подождет другое
  if m.game_id is not null then
    perform 1 from public.games where id=m.game_id for update;
  end if;
  select * into m from public.tournament_matches where id=p_match_id for update;
  select * into t from public.tournaments where id=m.tournament_id;
  if t.status<>'active' then raise exception 'Tournament not active'; end if;
  if m.status in('finished','technical')
     or exists(select 1 from public.games where id=m.game_id and status='finished') then
    raise exception 'Tournament match already resolved';
  end if;
  if m.player1_id is null or m.player2_id is null then raise exception 'Tournament match players missing'; end if;

  perform public.cancel_tournament_room(m.game_id,'переигровка в турнире');
  new_game_id:=public.create_tournament_room(m.player1_id,m.player2_id);
  update public.tournament_matches
  set game_id=new_game_id,status='ready',winner_id=null,result_reason='replay',resolved_at=null
  where id=m.id;

  foreach player_id in array array[m.player1_id,m.player2_id] loop
    select display_name into opponent_name
    from public.profiles
    where user_id=case when player_id=m.player1_id then m.player2_id else m.player1_id end;
    perform public.push_user_notification(
      player_id,
      'tournament_match_assigned',
      'переигровка матча',
      'администратор назначил переигровку в турнире «'||t.name||'». соперник — '
        ||coalesce(opponent_name,'игрок')||'. новая комната уже открыта.',
      new_game_id,t.id,m.id,
      -- тот же ключ, что у «назначен турнирный соперник» (018): уведомление пары обновляется
      -- и снова становится непрочитанным, ссылка ведет в новую комнату, а не в закрытую
      'tournament-match-assigned:'||m.id::text||':'||player_id::text
    );
  end loop;

  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

-- проверка ника для рейтинговых и турнирных игр (031, исключение из 036 расширено):
-- не блокирует комнаты, которые сервер открывает участникам идущего турнира
create or replace function public.require_verified_competitive_players()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if tg_op='INSERT' and new.game_type='tournament'
     and (pg_trigger_depth()>1 or current_setting('fruitkog.tournament_room',true)='on') then
    return new;
  end if;
  if new.game_type in ('rated','tournament')
     and new.status in ('waiting','placing','playing','paused') then
    if not exists (
      select 1 from public.profiles p
      where p.user_id=new.player1_id and p.account_type='registered'
        and p.school_verified=true
    ) or (new.player2_id is not null and not exists (
      select 1 from public.profiles p
      where p.user_id=new.player2_id and p.account_type='registered'
        and p.school_verified=true
    )) then
      raise exception 'Verified school nick required';
    end if;
  end if;
  return new;
end;
$$;

-- уведомление о завершенном турнирном матче (018): для технической победы — понятный текст
-- и ссылка на страницу турнира, а не на отмененную игру
create or replace function public.notify_user_tournament_match_finished()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  tournament_name text;
  match_game public.games%rowtype;
  player_id uuid;
  result_text text;
  rating_text text;
  current_rating integer;
begin
  if old.status is not distinct from new.status or new.status not in('finished','technical') then
    return new;
  end if;
  select name into tournament_name from public.tournaments where id=new.tournament_id;
  if new.game_id is not null then
    select * into match_game from public.games where id=new.game_id;
  end if;

  foreach player_id in array array[new.player1_id,new.player2_id] loop
    if player_id is null then continue; end if;
    result_text:=case
      when new.winner_id is null then 'матч завершен без победителя.'
      when new.result_reason='technical' and new.winner_id=player_id
        then 'вам засчитана техническая победа (решение администратора).'
      when new.result_reason='technical'
        then 'сопернику засчитана техническая победа (решение администратора).'
      when new.winner_id=player_id then 'вы победили.'
      else 'вы проиграли.'
    end;
    rating_text:='';
    if match_game.id is not null and coalesce(match_game.rating_applied,false) then
      select rating into current_rating from public.profiles where user_id=player_id;
      rating_text:=case
        when match_game.winner_id=player_id then ' рейтинг +'||coalesce(match_game.rating_delta,0)::text
        else ' рейтинг −'||coalesce(match_game.rating_delta,0)::text
      end||' — теперь '||coalesce(current_rating,1000)::text||'.';
    end if;
    perform public.push_user_notification(
      player_id,
      'tournament_match_finished',
      'турнирный матч завершен',
      'турнир «'||coalesce(tournament_name,'турнир')||'»: '||result_text||rating_text,
      case when new.result_reason='technical' then null else new.game_id end,new.tournament_id,new.id,
      'tournament-match-finished:'||new.id::text||':'||player_id::text
    );
  end loop;
  return new;
end;
$$;

-- самопроверка защиты (035) знает о двух новых админских функциях
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
        'get_public_game_settings','admin_award_technical_win','admin_replay_tournament_match'
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


-- права: админские функции — только вошедшим (внутри проверка админа), помощники — никому
revoke all on function public.admin_award_technical_win(uuid,uuid) from public,anon;
grant execute on function public.admin_award_technical_win(uuid,uuid) to authenticated;
revoke all on function public.admin_replay_tournament_match(uuid) from public,anon;
grant execute on function public.admin_replay_tournament_match(uuid) to authenticated;
revoke all on function public.create_tournament_room(uuid,uuid) from public,anon,authenticated;
revoke all on function public.advance_playoff_winner(uuid) from public,anon,authenticated;
revoke all on function public.cancel_tournament_room(uuid,text) from public,anon,authenticated;
revoke all on function public.sync_tournament_match_from_game() from public,anon,authenticated;
revoke all on function public.notify_user_tournament_match_finished() from public,anon,authenticated;
revoke all on function public.require_verified_competitive_players() from public,anon,authenticated;
revoke all on function public.admin_security_audit() from public,anon;
grant execute on function public.admin_security_audit() to authenticated;
