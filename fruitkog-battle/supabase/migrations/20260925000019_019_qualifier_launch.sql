-- обновление 20: запуск квалификации и связанные турнирные игры.
-- выполните после 018_user_notifications.sql.

alter table public.tournaments
add column if not exists qualifying_started_at timestamptz;

alter table public.tournament_matches
add column if not exists stage text;

update public.tournament_matches
set stage='playoff'
where stage is null;

alter table public.tournament_matches
alter column stage set default 'playoff';

alter table public.tournament_matches
alter column stage set not null;

alter table public.tournament_matches
drop constraint if exists tournament_matches_stage_check;

alter table public.tournament_matches
add constraint tournament_matches_stage_check
check(stage in('qualifying','playoff'));

alter table public.tournament_matches
drop constraint if exists tournament_matches_tournament_id_round_no_position_key;

create unique index if not exists tournament_matches_stage_position_unique
on public.tournament_matches(tournament_id,stage,round_no,position);

create unique index if not exists tournament_matches_game_unique
on public.tournament_matches(game_id)
where game_id is not null;

drop function if exists public.list_public_tournaments();
create function public.list_public_tournaments()
returns table(
  id uuid,
  name text,
  slug text,
  status text,
  tournament_format text,
  max_players integer,
  qualifying_matches_per_player integer,
  playoff_size integer,
  registration_deadline timestamptz,
  qualifying_started_at timestamptz,
  participant_count bigint,
  round_count integer,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz
)
language sql security definer stable set search_path=''
as $$
  select t.id,t.name,t.slug,t.status,t.tournament_format,t.max_players,
         t.qualifying_matches_per_player,t.playoff_size,t.registration_deadline,
         t.qualifying_started_at,
         count(distinct tp.user_id) filter(where tp.status='active') as participant_count,
         coalesce(max(tm.round_no) filter(where tm.stage='playoff'),0)::integer as round_count,
         t.created_at,t.started_at,t.finished_at
  from public.tournaments t
  left join public.tournament_players tp on tp.tournament_id=t.id
  left join public.tournament_matches tm on tm.tournament_id=t.id
  where t.status<>'draft' or public.is_game_admin(auth.uid())
  group by t.id
  order by
    case t.status when 'active' then 1 when 'registration' then 2 when 'draft' then 3 when 'finished' then 4 else 5 end,
    t.created_at desc;
$$;

create or replace function public.get_tournament_board(p_tournament_id uuid)
returns jsonb
language plpgsql security definer stable set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  viewer_id uuid:=auth.uid();
  viewer_is_admin boolean:=public.is_game_admin(auth.uid());
  result jsonb;
begin
  select * into t from public.tournaments where id=p_tournament_id;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status='draft' and not viewer_is_admin then
    raise exception 'Tournament not found';
  end if;

  select jsonb_build_object(
    'tournament',jsonb_build_object(
      'id',t.id,
      'name',t.name,
      'slug',t.slug,
      'status',t.status,
      'tournament_format',t.tournament_format,
      'description',t.description,
      'max_players',t.max_players,
      'qualifying_matches_per_player',t.qualifying_matches_per_player,
      'playoff_size',t.playoff_size,
      'registration_deadline',t.registration_deadline,
      'qualifying_started_at',t.qualifying_started_at,
      'created_at',t.created_at,
      'updated_at',t.updated_at,
      'started_at',t.started_at,
      'finished_at',t.finished_at
    ),
    'my_application',(
      select jsonb_build_object(
        'status',ta.status,
        'created_at',ta.created_at,
        'updated_at',ta.updated_at,
        'reviewed_at',ta.reviewed_at
      )
      from public.tournament_applications ta
      where ta.tournament_id=t.id and ta.user_id=viewer_id
    ),
    'applications',case when viewer_is_admin then coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id',ta.user_id,
        'display_name',p.display_name,
        'avatar_emoji',p.avatar_emoji,
        'school_verified',p.school_verified,
        'status',ta.status,
        'created_at',ta.created_at,
        'updated_at',ta.updated_at,
        'reviewed_at',ta.reviewed_at
      ) order by
        case ta.status when 'pending' then 1 when 'approved' then 2 when 'rejected' then 3 else 4 end,
        ta.created_at
      )
      from public.tournament_applications ta
      join public.profiles p on p.user_id=ta.user_id
      where ta.tournament_id=t.id
    ),'[]'::jsonb) else '[]'::jsonb end,
    'players',coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id',tp.user_id,
        'display_name',p.display_name,
        'avatar_emoji',p.avatar_emoji,
        'seed',tp.seed,
        'status',tp.status
      ) order by tp.seed nulls last,lower(p.display_name))
      from public.tournament_players tp
      join public.profiles p on p.user_id=tp.user_id
      where tp.tournament_id=t.id
    ),'[]'::jsonb),
    'matches',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',tm.id,
        'stage',tm.stage,
        'round_no',tm.round_no,
        'position',tm.position,
        'player1_id',tm.player1_id,
        'player1_name',p1.display_name,
        'player1_avatar',p1.avatar_emoji,
        'player2_id',tm.player2_id,
        'player2_name',p2.display_name,
        'player2_avatar',p2.avatar_emoji,
        'winner_id',tm.winner_id,
        'game_id',tm.game_id,
        'game_status',g.status,
        'status',tm.status,
        'result_reason',tm.result_reason,
        'next_match_id',tm.next_match_id,
        'next_slot',tm.next_slot,
        'resolved_at',tm.resolved_at
      ) order by
        case tm.stage when 'qualifying' then 1 else 2 end,
        tm.round_no,tm.position)
      from public.tournament_matches tm
      left join public.profiles p1 on p1.user_id=tm.player1_id
      left join public.profiles p2 on p2.user_id=tm.player2_id
      left join public.games g on g.id=tm.game_id
      where tm.tournament_id=t.id
    ),'[]'::jsonb)
  ) into result;

  return result;
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

create or replace function public.sync_tournament_match_from_game()
returns trigger
language plpgsql security definer set search_path=''
as $$
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
  where game_id=new.id;

  return new;
end;
$$;

drop trigger if exists sync_tournament_match_from_game_trigger on public.games;
create trigger sync_tournament_match_from_game_trigger
after update of status,winner_id on public.games
for each row
when(old.status is distinct from new.status or old.winner_id is distinct from new.winner_id)
execute function public.sync_tournament_match_from_game();

create or replace function public.protect_tournament_match_room()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  if old.game_type='tournament'
     and old.status='placing'
     and (new.status in('waiting','cancelled') or new.player2_id is null)
     and not public.is_game_admin(auth.uid()) then
    raise exception 'Tournament match cannot be left';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_tournament_match_room_trigger on public.games;
create trigger protect_tournament_match_room_trigger
before update on public.games
for each row execute function public.protect_tournament_match_room();

create or replace function public.admin_close_tournament(p_tournament_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
begin
  perform public.require_game_admin();
  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status='cancelled' then return public.get_tournament_board(t.id); end if;
  if t.status='finished' then raise exception 'Tournament already finished'; end if;

  update public.games g
  set status='cancelled',current_turn=null,winner_id=null,finished_at=null,
      finish_reason=null,surrendered_by=null,updated_at=now(),
      admin_cancelled_by=auth.uid(),admin_cancelled_at=now(),
      admin_cancel_reason='турнир закрыт администратором'
  from public.tournament_matches tm
  where tm.tournament_id=t.id and tm.game_id=g.id
    and g.status in('waiting','placing','playing','paused');

  update public.tournament_matches
  set status='cancelled',result_reason='cancelled',resolved_at=coalesce(resolved_at,now())
  where tournament_id=t.id and status not in('finished','technical','cancelled');

  update public.tournaments
  set status='cancelled',finished_at=coalesce(finished_at,now()),updated_at=now()
  where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

revoke execute on function public.list_public_tournaments() from public;
revoke execute on function public.get_tournament_board(uuid) from public;
revoke execute on function public.admin_start_tournament_qualifiers(uuid) from public,anon;
revoke execute on function public.sync_tournament_match_from_game() from public,anon,authenticated;
revoke execute on function public.protect_tournament_match_room() from public,anon,authenticated;
revoke execute on function public.admin_close_tournament(uuid) from public,anon;

grant execute on function public.list_public_tournaments() to anon,authenticated;
grant execute on function public.get_tournament_board(uuid) to anon,authenticated;
grant execute on function public.admin_start_tournament_qualifiers(uuid) to authenticated;
grant execute on function public.admin_close_tournament(uuid) to authenticated;
