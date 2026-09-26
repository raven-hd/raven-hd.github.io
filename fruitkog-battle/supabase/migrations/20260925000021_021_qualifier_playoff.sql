-- обновление 24: жеребьевка плей-офф после квалификации и автоматическое продвижение победителей.
-- выполните после 020_tournament_match_independence.sql.

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
    where tournament_id=t.id and stage='qualifying'
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
    select stats.*,random() as draw_order from stats
  )
  select
    array_agg(user_id order by points desc,direct_points desc,opponent_strength desc,draw_order),
    array_agg(points order by points desc,direct_points desc,opponent_strength desc,draw_order),
    array_agg(direct_points order by points desc,direct_points desc,opponent_strength desc,draw_order),
    array_agg(opponent_strength order by points desc,direct_points desc,opponent_strength desc,draw_order)
  into ranked_ids,ranked_points,ranked_direct,ranked_strength
  from shuffled;

  if participant_count>playoff_count
     and ranked_points[playoff_count]=ranked_points[playoff_count+1]
     and ranked_direct[playoff_count]=ranked_direct[playoff_count+1]
     and ranked_strength[playoff_count]=ranked_strength[playoff_count+1] then
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

create or replace function public.sync_tournament_match_from_game()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  current_match public.tournament_matches%rowtype;
  next_match public.tournament_matches%rowtype;
  next_p1 uuid;
  next_p2 uuid;
  next_p1_name text;
  next_p2_name text;
  new_code text;
  new_game_id uuid;
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

  if current_match.next_match_id is null then
    update public.tournaments
    set status='finished',finished_at=coalesce(finished_at,now()),updated_at=now()
    where id=current_match.tournament_id;
    return new;
  end if;

  select * into next_match
  from public.tournament_matches
  where id=current_match.next_match_id
  for update;

  next_p1:=case when current_match.next_slot=1 then current_match.winner_id else next_match.player1_id end;
  next_p2:=case when current_match.next_slot=2 then current_match.winner_id else next_match.player2_id end;

  if next_p1 is not null and next_p2 is not null and next_match.game_id is null then
    select display_name into next_p1_name from public.profiles where user_id=next_p1;
    select display_name into next_p2_name from public.profiles where user_id=next_p2;
    loop
      new_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
      exit when not exists(select 1 from public.games where code=new_code);
    end loop;
    insert into public.games(
      code,game_type,visibility,player1_id,player1_name,player2_id,player2_name,
      status,player1_action_at,player2_action_at,updated_at
    ) values(
      new_code,'tournament','public',next_p1,next_p1_name,next_p2,next_p2_name,
      'placing',now(),now(),now()
    ) returning id into new_game_id;

    update public.tournament_matches
    set player1_id=next_p1,player2_id=next_p2,game_id=new_game_id,status='ready'
    where id=next_match.id;
  else
    update public.tournament_matches
    set player1_id=next_p1,player2_id=next_p2
    where id=next_match.id;
  end if;

  update public.tournaments set updated_at=now() where id=current_match.tournament_id;
  return new;
end;
$$;

drop trigger if exists sync_tournament_match_from_game_trigger on public.games;
create trigger sync_tournament_match_from_game_trigger
after update of status,winner_id on public.games
for each row
when(old.status is distinct from new.status or old.winner_id is distinct from new.winner_id)
execute function public.sync_tournament_match_from_game();

revoke execute on function public.admin_start_tournament_playoff(uuid) from public,anon;
revoke execute on function public.sync_tournament_match_from_game() from public,anon,authenticated;
grant execute on function public.admin_start_tournament_playoff(uuid) to authenticated;
