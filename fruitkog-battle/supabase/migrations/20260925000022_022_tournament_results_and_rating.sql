-- обновление 25: явные итоги турниров, этапы матчей и отдельное турнирное начисление рейтинга.
-- выполните после 021_qualifier_playoff.sql.

alter table public.tournaments
add column if not exists rating_applied boolean not null default false,
add column if not exists rating_applied_at timestamptz;

alter table public.games
add column if not exists tournament_rating_applied boolean not null default false,
add column if not exists tournament_rating_delta integer;

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
    winner_after:=winner_before+8;
    loser_after:=loser_before-8;

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
        tournament_rating_delta=8,
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
      coalesce(sum(case when tm.winner_id=player_rec.user_id then 8 else -8 end),0)::integer
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
  winner_id uuid,
  winner_name text,
  rating_applied boolean,
  rating_applied_at timestamptz,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz
)
language sql security definer stable set search_path=''
as $$
  select
    t.id,t.name,t.slug,t.status,t.tournament_format,t.max_players,
    t.qualifying_matches_per_player,t.playoff_size,t.registration_deadline,
    t.qualifying_started_at,
    (select count(*) from public.tournament_players tp
      where tp.tournament_id=t.id and tp.status='active') as participant_count,
    coalesce((select max(tm.round_no) from public.tournament_matches tm
      where tm.tournament_id=t.id and tm.stage='playoff'),0)::integer as round_count,
    champion.winner_id,
    champion.winner_name,
    t.rating_applied,
    t.rating_applied_at,
    t.created_at,t.started_at,t.finished_at
  from public.tournaments t
  left join lateral(
    select tm.winner_id,p.display_name as winner_name
    from public.tournament_matches tm
    left join public.profiles p on p.user_id=tm.winner_id
    where tm.tournament_id=t.id
      and tm.stage='playoff'
      and tm.next_match_id is null
      and tm.winner_id is not null
    order by tm.round_no desc,tm.position
    limit 1
  ) champion on true
  where t.status<>'draft' or public.is_game_admin(auth.uid())
  order by
    case t.status when 'active' then 1 when 'registration' then 2 when 'draft' then 3 when 'finished' then 4 else 5 end,
    coalesce(t.finished_at,t.created_at) desc;
$$;

create or replace function public.get_tournament_board(p_tournament_id uuid)
returns jsonb
language plpgsql security definer stable set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  viewer_id uuid:=auth.uid();
  viewer_is_admin boolean:=public.is_game_admin(auth.uid());
  champion_id uuid;
  champion_name text;
  result jsonb;
begin
  select * into t from public.tournaments where id=p_tournament_id;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status='draft' and not viewer_is_admin then raise exception 'Tournament not found'; end if;

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
      'winner_id',champion_id,
      'winner_name',champion_name,
      'rating_applied',t.rating_applied,
      'rating_applied_at',t.rating_applied_at,
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
        'tournament_rating_applied',g.tournament_rating_applied,
        'tournament_rating_delta',g.tournament_rating_delta,
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

drop function if exists public.list_active_games();
create function public.list_active_games()
returns table(
  id uuid,
  code text,
  game_type text,
  visibility text,
  status text,
  player1_id uuid,
  player1_name text,
  player2_id uuid,
  player2_name text,
  player1_ready boolean,
  player2_ready boolean,
  current_turn uuid,
  turn_started_at timestamptz,
  paused_at timestamptz,
  pause_reason text,
  updated_at timestamptz,
  is_participant boolean,
  tournament_id uuid,
  tournament_name text,
  tournament_stage text,
  tournament_round_no integer,
  tournament_total_rounds integer
)
language plpgsql security definer set search_path=''
as $$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Authentication required'; end if;
  perform public.pause_expired_games();

  return query
  select
    g.id,
    case when uid in(g.player1_id,g.player2_id) then g.code else null end,
    g.game_type,
    g.visibility,
    g.status,
    g.player1_id,
    g.player1_name,
    g.player2_id,
    g.player2_name,
    g.player1_ready,
    g.player2_ready,
    g.current_turn,
    g.turn_started_at,
    g.paused_at,
    g.pause_reason,
    g.updated_at,
    uid in(g.player1_id,g.player2_id),
    tm.tournament_id,
    t.name,
    tm.stage,
    tm.round_no,
    coalesce(rounds.total_rounds,0)
  from public.games g
  left join public.tournament_matches tm on tm.game_id=g.id
  left join public.tournaments t on t.id=tm.tournament_id
  left join lateral(
    select max(all_matches.round_no)::integer as total_rounds
    from public.tournament_matches all_matches
    where all_matches.tournament_id=tm.tournament_id and all_matches.stage='playoff'
  ) rounds on true
  where g.status in('waiting','placing','playing','paused')
  order by
    case g.status when 'waiting' then 1 when 'playing' then 2 when 'placing' then 3 else 4 end,
    g.updated_at desc;
end;
$$;

drop function if exists public.list_match_history();
create function public.list_match_history()
returns table(
  player1_name text,
  player2_name text,
  winner_name text,
  game_type text,
  finish_reason text,
  rating_applied boolean,
  rating_delta integer,
  rating_skip_reason text,
  tournament_rating_applied boolean,
  tournament_rating_delta integer,
  finished_at timestamptz
)
language sql security definer stable set search_path=''
as $$
  select
    g.player1_name,
    g.player2_name,
    case
      when g.winner_id=g.player1_id then g.player1_name
      when g.winner_id=g.player2_id then g.player2_name
      else '—'
    end,
    g.game_type,
    coalesce(g.finish_reason,'fleet_destroyed'),
    g.rating_applied,
    g.rating_delta,
    g.rating_skip_reason,
    g.tournament_rating_applied,
    g.tournament_rating_delta,
    g.finished_at
  from public.games g
  where g.status='finished' and g.finished_at is not null
  order by g.finished_at desc
  limit 50;
$$;

create or replace function public.get_public_player_profile(p_user_id uuid)
returns jsonb
language plpgsql security definer stable set search_path=''
as $$
declare
  viewer_id uuid:=auth.uid();
  result jsonb;
begin
  if viewer_id is null then raise exception 'Authentication required'; end if;

  select jsonb_build_object(
    'profile',jsonb_build_object(
      'user_id',p.user_id,
      'display_name',p.display_name,
      'avatar_emoji',p.avatar_emoji,
      'school_verified',p.school_verified,
      'rating',p.rating,
      'rated_games',p.rated_games,
      'rated_wins',p.rated_wins,
      'rated_losses',p.rated_losses,
      'created_at',p.created_at
    ),
    'matches',coalesce((
      select jsonb_agg(match_row.item order by match_row.finished_at desc)
      from (
        select
          g.finished_at,
          jsonb_build_object(
            'game_id',g.id,
            'opponent_id',case when g.player1_id=p.user_id then g.player2_id else g.player1_id end,
            'opponent_name',case when g.player1_id=p.user_id then g.player2_name else g.player1_name end,
            'result',case when g.winner_id=p.user_id then 'win' else 'loss' end,
            'game_type',g.game_type,
            'finish_reason',coalesce(g.finish_reason,'fleet_destroyed'),
            'surrendered_by',g.surrendered_by,
            'rating_applied',g.rating_applied or g.tournament_rating_applied,
            'rating_change',case
              when g.tournament_rating_applied and g.winner_id=p.user_id then g.tournament_rating_delta
              when g.tournament_rating_applied then -g.tournament_rating_delta
              when g.rating_applied and g.winner_id=p.user_id then g.rating_delta
              when g.rating_applied then -g.rating_delta
              else null
            end,
            'finished_at',g.finished_at
          ) as item
        from public.games g
        where g.status='finished'
          and g.finished_at is not null
          and p.user_id in(g.player1_id,g.player2_id)
        order by g.finished_at desc
        limit 50
      ) match_row
    ),'[]'::jsonb)
  ) into result
  from public.profiles p
  where p.user_id=p_user_id and p.account_type='registered';

  if result is null then raise exception 'Registered profile not found'; end if;
  return result;
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
    perform public.apply_tournament_ratings(current_match.tournament_id);
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

do $$
declare finished_tournament_id uuid;
begin
  for finished_tournament_id in
    select id from public.tournaments
    where status='finished' and not rating_applied
    order by finished_at,created_at
  loop
    perform public.apply_tournament_ratings(finished_tournament_id);
  end loop;
end;
$$;

revoke execute on function public.apply_tournament_ratings(uuid) from public,anon,authenticated;
revoke execute on function public.list_public_tournaments() from public;
revoke execute on function public.get_tournament_board(uuid) from public;
revoke execute on function public.list_active_games() from public,anon;
revoke execute on function public.list_match_history() from public,anon;
revoke execute on function public.get_public_player_profile(uuid) from public,anon;
revoke execute on function public.sync_tournament_match_from_game() from public,anon,authenticated;

grant execute on function public.list_public_tournaments() to anon,authenticated;
grant execute on function public.get_tournament_board(uuid) to anon,authenticated;
grant execute on function public.list_active_games() to authenticated;
grant execute on function public.list_match_history() to authenticated;
grant execute on function public.get_public_player_profile(uuid) to authenticated;
