-- обновление 103: более спокойный обычный рейтинг и повышенный вес турниров.
-- применяется только к будущим результатам; уже начисленные очки не меняются.

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

  if recent_rated_count>=3 then
    update public.games
    set game_type='casual',rating_skip_reason='pair_daily_limit'
    where id=new.id;
    return new;
  end if;

  expected_p1:=1/(1+power(10::numeric,(p2.rating-p1.rating)::numeric/400));
  if new.winner_id=new.player1_id then
    delta:=round(16*(1-expected_p1))::integer;
    p1_after:=p1.rating+delta;
    p2_after:=p2.rating-delta;
  else
    delta:=round(16*expected_p1)::integer;
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
    winner_after:=winner_before+12;
    loser_after:=loser_before-12;

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
        tournament_rating_delta=12,
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
      coalesce(sum(case when tm.winner_id=player_rec.user_id then 12 else -12 end),0)::integer
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

revoke execute on function public.apply_finished_game_rating() from public,anon,authenticated;
revoke execute on function public.apply_tournament_ratings(uuid) from public,anon,authenticated;
