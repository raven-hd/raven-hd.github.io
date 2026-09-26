-- обновление 08: базовый рейтинг Elo.
-- выполните после 006_active_pair_and_surrender.sql.

alter table public.profiles
add column if not exists rating integer not null default 1000,
add column if not exists rated_games integer not null default 0,
add column if not exists rated_wins integer not null default 0,
add column if not exists rated_losses integer not null default 0;

alter table public.games
add column if not exists rating_applied boolean not null default false,
add column if not exists rating_skip_reason text,
add column if not exists rating_delta integer,
add column if not exists player1_rating_before integer,
add column if not exists player1_rating_after integer,
add column if not exists player2_rating_before integer,
add column if not exists player2_rating_after integer;

alter table public.games drop constraint if exists games_rating_skip_reason_check;
alter table public.games add constraint games_rating_skip_reason_check
check(rating_skip_reason is null or rating_skip_reason in('guest','pair_daily_limit'));

create index if not exists games_pair_rating_window_idx
on public.games(player1_id,player2_id,finished_at desc)
where rating_applied=true;

-- Создатель выбирает рейтинговый или обычный матч. Гость всегда
-- создает обычную игру. request_id сохраняет защиту от двойного клика.
drop function if exists public.create_game(uuid);
drop function if exists public.create_game(uuid,text);

create function public.create_game(
  p_request_id uuid,
  p_game_type text default 'rated'
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  p public.profiles%rowtype;
  g public.games%rowtype;
  new_code text;
  requested_type text:=lower(trim(coalesce(p_game_type,'rated')));
  actual_type text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if p_request_id is null then raise exception 'Request id required'; end if;
  if requested_type not in('rated','casual') then raise exception 'Invalid game type'; end if;

  select * into p from public.profiles where user_id=uid;
  if not found then raise exception 'Profile required'; end if;
  actual_type:=case when p.account_type='guest' then 'casual' else requested_type end;

  select * into g
  from public.games
  where player1_id=uid and create_request_id=p_request_id;
  if found then return to_jsonb(g); end if;

  loop
    new_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
    exit when not exists(select 1 from public.games where code=new_code);
  end loop;

  begin
    insert into public.games(
      code,game_type,visibility,player1_id,player1_name,player1_action_at,
      create_request_id,rating_skip_reason
    ) values(
      new_code,actual_type,'public',uid,p.display_name,now(),p_request_id,
      case when requested_type='rated' and actual_type='casual' then 'guest' else null end
    ) returning * into g;
  exception when unique_violation then
    select * into g
    from public.games
    where player1_id=uid and create_request_id=p_request_id;
    if not found then raise; end if;
  end;

  return to_jsonb(g);
end;
$$;

-- При присоединении сервер сам переводит матч в обычный, если в нем
-- участвует гость или эта пара уже исчерпала три рейтинговых результата
-- за скользящие 24 часа.
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

-- Рейтинг применяется ровно один раз при первом переходе матча в finished.
-- Блокировка профилей в одинаковом порядке защищает параллельные матчи
-- одного игрока от потери обновлений и взаимных блокировок.
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
    delta:=round(32*(1-expected_p1))::integer;
    p1_after:=p1.rating+delta;
    p2_after:=p2.rating-delta;
  else
    delta:=round(32*expected_p1)::integer;
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

drop trigger if exists games_apply_finished_rating on public.games;
create trigger games_apply_finished_rating
after update of status on public.games
for each row
when(old.status is distinct from 'finished' and new.status='finished')
execute function public.apply_finished_game_rating();

drop function if exists public.get_leaderboard();
create function public.get_leaderboard()
returns table(
  user_id uuid,
  display_name text,
  rating integer,
  games_played integer,
  wins integer,
  losses integer,
  win_rate numeric
)
language sql security definer stable set search_path=''
as $$
  select
    p.user_id,
    p.display_name,
    p.rating,
    p.rated_games,
    p.rated_wins,
    p.rated_losses,
    case when p.rated_games=0 then 0::numeric
      else round((p.rated_wins::numeric*100)/p.rated_games,1)
    end
  from public.profiles p
  where p.account_type='registered'
  order by p.rating desc,p.rated_wins desc,p.rated_games asc,lower(p.display_name);
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
    g.finished_at
  from public.games g
  where g.status='finished' and g.finished_at is not null
  order by g.finished_at desc
  limit 50;
$$;

revoke execute on function public.create_game(uuid,text) from public,anon;
revoke execute on function public.join_public_game(uuid) from public,anon;
revoke execute on function public.apply_finished_game_rating() from public,anon,authenticated;
revoke execute on function public.get_leaderboard() from public;
revoke execute on function public.list_match_history() from public,anon;

grant execute on function public.create_game(uuid,text) to authenticated;
grant execute on function public.join_public_game(uuid) to authenticated;
grant execute on function public.get_leaderboard() to anon,authenticated;
grant execute on function public.list_match_history() to authenticated;
