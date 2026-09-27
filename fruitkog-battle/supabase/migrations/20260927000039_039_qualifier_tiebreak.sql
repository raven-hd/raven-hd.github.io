-- дополнительный матч разрешает полное равенство на границе плей-офф.
-- он учитывается после основных критериев квалификации, не меняя их очки.
alter table public.tournament_matches drop constraint tournament_matches_stage_check;
alter table public.tournament_matches add constraint tournament_matches_stage_check
check(stage in('qualifying','tiebreak','playoff'));

create or replace function public.admin_start_tournament_playoff(p_tournament_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  ranked_ids uuid[];
  ranked_points integer[];
  ranked_direct integer[];
  ranked_strength integer[];
  ranked_tiebreak integer[];
  seed_slots integer[]:=array[1,2];
  expanded_slots integer[];
  playoff_count integer;
  participant_count integer;
  total_rounds integer;
  current_size integer:=2;
  round_idx integer;
  round_match_count integer;
  match_pos integer;
  slot_idx integer;
  seed_idx integer;
  p1 uuid;
  p2 uuid;
  p1_name text;
  p2_name text;
  new_code text;
  new_game_id uuid;
  next_id uuid;
begin
  perform public.require_game_admin();
  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.tournament_format<>'qualifiers_playoff' then raise exception 'Qualifying settings unavailable'; end if;
  if t.status<>'active' or t.qualifying_started_at is null then raise exception 'Qualifying stage not started'; end if;
  if exists(
    select 1 from public.tournament_matches
    where tournament_id=t.id and stage='playoff'
  ) then return public.get_tournament_board(t.id); end if;
  if not exists(
    select 1 from public.tournament_matches
    where tournament_id=t.id and stage='qualifying'
  ) then raise exception 'Qualifying matches not found'; end if;
  if exists(
    select 1 from public.tournament_matches
    where tournament_id=t.id and stage in('qualifying','tiebreak')
      and (status not in('finished','technical') or winner_id is null)
  ) then raise exception 'Qualifying matches incomplete'; end if;

  playoff_count:=t.playoff_size;
  if playoff_count not in(4,8,16) then raise exception 'Invalid playoff size'; end if;
  select count(*)::integer into participant_count
  from public.tournament_players
  where tournament_id=t.id and status='active';
  if participant_count<playoff_count then raise exception 'Playoff size exceeds participants'; end if;

  with base as (
    select
      tp.user_id,
      count(tm.id)::integer as games,
      count(tm.id) filter(where tm.winner_id=tp.user_id)::integer as wins,
      (count(tm.id) filter(where tm.winner_id=tp.user_id)*3)::integer as points
    from public.tournament_players tp
    left join public.tournament_matches tm
      on tm.tournament_id=tp.tournament_id
     and tm.stage='qualifying'
     and tm.status in('finished','technical')
     and tp.user_id in(tm.player1_id,tm.player2_id)
    where tp.tournament_id=t.id and tp.status='active'
    group by tp.user_id
  ), stats as (
    select
      b.user_id,
      b.points,
      coalesce(sum(case
        when opponent.points=b.points and tm.winner_id=b.user_id then 3 else 0
      end),0)::integer as direct_points,
      coalesce(sum(opponent.points),0)::integer as opponent_strength
    from base b
    left join public.tournament_matches tm
      on tm.tournament_id=t.id
     and tm.stage='qualifying'
     and tm.status in('finished','technical')
     and b.user_id in(tm.player1_id,tm.player2_id)
    left join base opponent on opponent.user_id=case
      when tm.player1_id=b.user_id then tm.player2_id else tm.player1_id
    end
    group by b.user_id,b.points
  ), shuffled as (
    select stats.*,
      (select count(*)::integer from public.tournament_matches extra
       where extra.tournament_id=t.id and extra.stage='tiebreak'
         and extra.status in('finished','technical') and extra.winner_id=stats.user_id
      ) as tiebreak_wins,
      random() as draw_order from stats
  )
  select
    array_agg(user_id order by points desc,direct_points desc,opponent_strength desc,tiebreak_wins desc,draw_order),
    array_agg(points order by points desc,direct_points desc,opponent_strength desc,tiebreak_wins desc,draw_order),
    array_agg(direct_points order by points desc,direct_points desc,opponent_strength desc,tiebreak_wins desc,draw_order),
    array_agg(opponent_strength order by points desc,direct_points desc,opponent_strength desc,tiebreak_wins desc,draw_order),
    array_agg(tiebreak_wins order by points desc,direct_points desc,opponent_strength desc,tiebreak_wins desc,draw_order)
  into ranked_ids,ranked_points,ranked_direct,ranked_strength,ranked_tiebreak
  from shuffled;

  if participant_count>playoff_count
     and ranked_points[playoff_count]=ranked_points[playoff_count+1]
     and ranked_direct[playoff_count]=ranked_direct[playoff_count+1]
     and ranked_strength[playoff_count]=ranked_strength[playoff_count+1]
     and ranked_tiebreak[playoff_count]=ranked_tiebreak[playoff_count+1] then
    raise exception 'Qualifying tiebreak required';
  end if;

  update public.tournament_players set seed=null where tournament_id=t.id;
  for seed_idx in 1..playoff_count loop
    update public.tournament_players
    set seed=seed_idx
    where tournament_id=t.id and user_id=ranked_ids[seed_idx];
  end loop;

  while current_size<playoff_count loop
    expanded_slots:=array[]::integer[];
    current_size:=current_size*2;
    for slot_idx in 1..coalesce(array_length(seed_slots,1),0) loop
      expanded_slots:=array_append(expanded_slots,seed_slots[slot_idx]);
      expanded_slots:=array_append(expanded_slots,current_size+1-seed_slots[slot_idx]);
    end loop;
    seed_slots:=expanded_slots;
  end loop;

  total_rounds:=case playoff_count when 4 then 2 when 8 then 3 else 4 end;
  for round_idx in 1..total_rounds loop
    round_match_count:=(playoff_count/power(2,round_idx))::integer;
    for match_pos in 1..round_match_count loop
      p1:=null;p2:=null;new_game_id:=null;
      if round_idx=1 then
        p1:=ranked_ids[seed_slots[(match_pos-1)*2+1]];
        p2:=ranked_ids[seed_slots[(match_pos-1)*2+2]];
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
      end if;

      insert into public.tournament_matches(
        tournament_id,stage,round_no,position,player1_id,player2_id,game_id,status
      ) values(
        t.id,'playoff',round_idx,match_pos,p1,p2,new_game_id,
        case when round_idx=1 then 'ready' else 'pending' end
      );
    end loop;
  end loop;

  for round_idx in 1..(total_rounds-1) loop
    round_match_count:=(playoff_count/power(2,round_idx))::integer;
    for match_pos in 1..round_match_count loop
      select id into next_id
      from public.tournament_matches
      where tournament_id=t.id and stage='playoff'
        and round_no=round_idx+1 and position=ceil(match_pos/2.0)::integer;
      update public.tournament_matches
      set next_match_id=next_id,
          next_slot=case when mod(match_pos,2)=1 then 1 else 2 end
      where tournament_id=t.id and stage='playoff'
        and round_no=round_idx and position=match_pos;
    end loop;
  end loop;

  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

create or replace function public.admin_start_qualifier_tiebreak(
  p_tournament_id uuid,p_player1 uuid,p_player2 uuid
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  candidate_ids uuid[];
  next_position integer;
  new_game_id uuid;
  new_match_id uuid;
  player_id uuid;
  opponent_name text;
begin
  perform public.require_game_admin();
  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status<>'active' or t.tournament_format<>'qualifiers_playoff'
     or t.qualifying_started_at is null then
    raise exception 'Qualifying stage not started';
  end if;
  if p_player1 is null or p_player2 is null or p_player1=p_player2 then
    raise exception 'Choose two tied players';
  end if;
  if exists(select 1 from public.tournament_matches
            where tournament_id=t.id and stage='playoff') then
    raise exception 'Playoff already started';
  end if;
  if not exists(select 1 from public.tournament_matches
                where tournament_id=t.id and stage='qualifying')
     or exists(select 1 from public.tournament_matches
               where tournament_id=t.id and stage in('qualifying','tiebreak')
                 and (status not in('finished','technical') or winner_id is null)) then
    raise exception 'Qualifying matches incomplete';
  end if;

  -- Те же основные показатели, что при построении плей-офф. Дополнительные
  -- победы применяются только после очков, личных встреч и силы соперников.
  with base as (
    select tp.user_id,
      (count(tm.id) filter(where tm.winner_id=tp.user_id)*3)::integer as points
    from public.tournament_players tp
    left join public.tournament_matches tm
      on tm.tournament_id=tp.tournament_id and tm.stage='qualifying'
     and tm.status in('finished','technical')
     and tp.user_id in(tm.player1_id,tm.player2_id)
    where tp.tournament_id=t.id and tp.status='active'
    group by tp.user_id
  ), stats as (
    select b.user_id,b.points,
      coalesce(sum(case when opponent.points=b.points
                        and tm.winner_id=b.user_id then 3 else 0 end),0)::integer as direct_points,
      coalesce(sum(opponent.points),0)::integer as opponent_strength,
      (select count(*)::integer from public.tournament_matches extra
       where extra.tournament_id=t.id and extra.stage='tiebreak'
         and extra.status in('finished','technical')
         and extra.winner_id=b.user_id) as tiebreak_wins
    from base b
    left join public.tournament_matches tm
      on tm.tournament_id=t.id and tm.stage='qualifying'
     and tm.status in('finished','technical')
     and b.user_id in(tm.player1_id,tm.player2_id)
    left join base opponent on opponent.user_id=case
      when tm.player1_id=b.user_id then tm.player2_id else tm.player1_id end
    group by b.user_id,b.points
  ), ordered as (
    select stats.*,row_number() over(order by points desc,direct_points desc,
      opponent_strength desc,tiebreak_wins desc,user_id) as row_no from stats
  ), boundary as (
    select a.points,a.direct_points,a.opponent_strength,a.tiebreak_wins
    from ordered a join ordered b on b.row_no=t.playoff_size+1
    where a.row_no=t.playoff_size
      and (a.points,a.direct_points,a.opponent_strength,a.tiebreak_wins)
        =(b.points,b.direct_points,b.opponent_strength,b.tiebreak_wins)
  )
  select array_agg(o.user_id) into candidate_ids
  from ordered o join boundary b
    on (o.points,o.direct_points,o.opponent_strength,o.tiebreak_wins)
      =(b.points,b.direct_points,b.opponent_strength,b.tiebreak_wins);

  if candidate_ids is null or not (p_player1=any(candidate_ids)
       and p_player2=any(candidate_ids)) then
    raise exception 'Choose two tied players';
  end if;

  select coalesce(max(position),0)+1 into next_position
  from public.tournament_matches where tournament_id=t.id and stage='tiebreak';
  new_game_id:=public.create_tournament_room(p_player1,p_player2);
  insert into public.tournament_matches(
    tournament_id,stage,round_no,position,player1_id,player2_id,game_id,status
  ) values(t.id,'tiebreak',2,next_position,p_player1,p_player2,new_game_id,'ready')
  returning id into new_match_id;

  foreach player_id in array array[p_player1,p_player2] loop
    select display_name into opponent_name from public.profiles
    where user_id=case when player_id=p_player1 then p_player2 else p_player1 end;
    perform public.push_user_notification(
      player_id,'tournament_match_assigned','дополнительный матч',
      'назначен дополнительный матч за выход в плей-офф турнира «'||t.name||
        '». соперник — '||coalesce(opponent_name,'игрок')||'.',
      new_game_id,t.id,new_match_id,
      'tournament-match-assigned:'||new_match_id::text||':'||player_id::text
    );
  end loop;
  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

revoke execute on function public.admin_start_qualifier_tiebreak(uuid,uuid,uuid)
from public,anon;
grant execute on function public.admin_start_qualifier_tiebreak(uuid,uuid,uuid)
to authenticated;
