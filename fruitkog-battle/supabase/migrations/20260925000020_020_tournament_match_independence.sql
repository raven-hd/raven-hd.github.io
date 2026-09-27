-- обновление 21: обычные и турнирные матчи одной пары не блокируют друг друга.
-- выполните после 019_qualifier_launch.sql.

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
      if recent_rated_count>=3 then
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

create or replace function public.admin_start_tournament_qualifiers(p_tournament_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  participant_ids uuid[];
  participant_count integer;
  match_count integer;
  distance integer;
  player_idx integer;
  opponent_idx integer;
  match_pos integer:=0;
  p1 uuid;
  p2 uuid;
  p1_name text;
  p2_name text;
  new_code text;
  new_game_id uuid;
begin
  perform public.require_game_admin();
  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.tournament_format<>'qualifiers_playoff' then raise exception 'Qualifying settings unavailable'; end if;
  if t.qualifying_started_at is not null then return public.get_tournament_board(t.id); end if;
  if t.status not in('draft','registration') then raise exception 'Tournament already started'; end if;
  if t.qualifying_matches_per_player is null or t.playoff_size is null then
    raise exception 'Qualifying settings required';
  end if;
  if exists(
    select 1 from public.tournament_applications
    where tournament_id=t.id and status='pending'
  ) then raise exception 'Tournament has pending applications'; end if;
  if exists(select 1 from public.tournament_matches where tournament_id=t.id) then
    raise exception 'Tournament already has matches';
  end if;

  select array_agg(tp.user_id order by random()),count(*)::integer
  into participant_ids,participant_count
  from public.tournament_players tp
  where tp.tournament_id=t.id and tp.status='active';

  match_count:=t.qualifying_matches_per_player;
  if participant_count<2 then raise exception 'Tournament needs two players'; end if;
  if participant_count>t.max_players then raise exception 'Tournament is full'; end if;
  if t.playoff_size>participant_count then raise exception 'Playoff size exceeds participants'; end if;
  if match_count>=participant_count then raise exception 'Qualifying match count exceeds opponents'; end if;
  if mod(participant_count*match_count,2)=1 then
    raise exception 'Qualifying schedule requires even total';
  end if;

  update public.tournament_players
  set seed=null
  where tournament_id=t.id;

  if match_count/2>0 then
    for distance in 1..(match_count/2) loop
      for player_idx in 1..participant_count loop
        opponent_idx:=mod(player_idx-1+distance,participant_count)+1;
        p1:=participant_ids[player_idx];
        p2:=participant_ids[opponent_idx];
        match_pos:=match_pos+1;

        select display_name into p1_name from public.profiles where user_id=p1;
        select display_name into p2_name from public.profiles where user_id=p2;
        loop
          new_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
          exit when not exists(select 1 from public.games where code=new_code);
        end loop;
        insert into public.games(
          code,game_type,visibility,player1_id,player1_name,player2_id,player2_name,
          status,player1_action_at,player2_action_at,updated_at
        ) values(
          new_code,'tournament','public',p1,p1_name,p2,p2_name,
          'placing',now(),now(),now()
        ) returning id into new_game_id;

        insert into public.tournament_matches(
          tournament_id,stage,round_no,position,player1_id,player2_id,game_id,status
        ) values(t.id,'qualifying',1,match_pos,p1,p2,new_game_id,'ready');
      end loop;
    end loop;
  end if;

  if mod(match_count,2)=1 then
    for player_idx in 1..(participant_count/2) loop
      opponent_idx:=player_idx+(participant_count/2);
      p1:=participant_ids[player_idx];
      p2:=participant_ids[opponent_idx];
      match_pos:=match_pos+1;

      select display_name into p1_name from public.profiles where user_id=p1;
      select display_name into p2_name from public.profiles where user_id=p2;
      loop
        new_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
        exit when not exists(select 1 from public.games where code=new_code);
      end loop;
      insert into public.games(
        code,game_type,visibility,player1_id,player1_name,player2_id,player2_name,
        status,player1_action_at,player2_action_at,updated_at
      ) values(
        new_code,'tournament','public',p1,p1_name,p2,p2_name,
        'placing',now(),now(),now()
      ) returning id into new_game_id;

      insert into public.tournament_matches(
        tournament_id,stage,round_no,position,player1_id,player2_id,game_id,status
      ) values(t.id,'qualifying',1,match_pos,p1,p2,new_game_id,'ready');
    end loop;
  end if;

  update public.tournaments
  set status='active',qualifying_started_at=now(),started_at=coalesce(started_at,now()),
      finished_at=null,updated_at=now()
  where id=t.id;

  return public.get_tournament_board(t.id);
end;
$$;

revoke execute on function public.join_public_game(uuid) from public,anon;
grant execute on function public.join_public_game(uuid) to authenticated;
revoke execute on function public.admin_start_tournament_qualifiers(uuid) from public,anon;
grant execute on function public.admin_start_tournament_qualifiers(uuid) to authenticated;
