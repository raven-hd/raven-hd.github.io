-- обновление 132: расходуемый бонус автопометок вокруг потопленного корабля.
-- ветка fruitkog-rewards; не применять на основном проекте до завершения текущего турнира.

begin;

alter table public.fruitkog_reward_reservations
drop constraint if exists fruitkog_reward_reservations_reward_type_check;

alter table public.fruitkog_reward_reservations
add constraint fruitkog_reward_reservations_reward_type_check
check (reward_type in ('square_ship','auto_miss'));

create table if not exists public.fruitkog_game_boosts (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  auto_miss_enabled boolean not null default false,
  square_ship_used boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (game_id,user_id)
);

alter table public.fruitkog_game_boosts enable row level security;
revoke all on public.fruitkog_game_boosts from anon,authenticated;

create or replace function public.get_my_game_boosts(p_game_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  g public.games%rowtype;
  boost public.fruitkog_game_boosts%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select * into g
  from public.games
  where id=p_game_id;

  if not found then raise exception 'Game not found'; end if;
  if uid not in(g.player1_id,g.player2_id) then raise exception 'Not a participant'; end if;

  select * into boost
  from public.fruitkog_game_boosts
  where game_id=g.id and user_id=uid;

  return jsonb_build_object(
    'auto_miss_enabled',coalesce(boost.auto_miss_enabled,false),
    'square_ship_used',coalesce(boost.square_ship_used,false)
  );
end;
$$;

drop function if exists public.ready_with_fleet(uuid,jsonb);

create or replace function public.ready_with_fleet(
  p_game_id uuid,
  p_ships jsonb,
  p_options jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  g public.games%rowtype;
  first_turn uuid;
  uses_square boolean:=false;
  wants_auto_miss boolean:=false;
  square_uses integer:=0;
  auto_miss_uses integer:=0;
  reserved_square integer:=0;
  reserved_auto_miss integer:=0;
  reward_rec record;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  perform public.pause_expired_games();

  select * into g
  from public.games
  where id=p_game_id
  for update;

  if not found then raise exception 'Game not found'; end if;
  if uid not in(g.player1_id,g.player2_id) then raise exception 'Not a participant'; end if;
  if g.status='paused' then raise exception 'Game is paused'; end if;

  if ((uid=g.player1_id and g.player1_ready) or (uid=g.player2_id and g.player2_ready))
     and g.status in('placing','playing') then
    return to_jsonb(g);
  end if;

  if g.player2_id is null or g.status<>'placing' then
    raise exception 'Game is not ready';
  end if;

  perform public.assert_valid_fleet(p_ships);

  select exists(
    select 1
    from jsonb_array_elements(p_ships) ship(value)
    where coalesce(nullif(lower(ship.value->>'shape'),''),'line')='square'
  ) into uses_square;

  wants_auto_miss:=lower(coalesce(p_options->>'auto_miss','false')) in ('true','1','yes','on');

  if g.game_type='tournament' and (uses_square or wants_auto_miss) then
    raise exception 'Game boosts unavailable in tournament';
  end if;

  if uses_square or wants_auto_miss then
    select r.square_ship_uses,r.auto_miss_uses
    into square_uses,auto_miss_uses
    from public.fruitkog_player_rewards r
    where r.user_id=uid
    for update;

    square_uses:=coalesce(square_uses,0);
    auto_miss_uses:=coalesce(auto_miss_uses,0);
  end if;

  if uses_square then
    select count(*)::integer into reserved_square
    from public.fruitkog_reward_reservations rr
    where rr.user_id=uid
      and rr.reward_type='square_ship'
      and rr.game_id<>g.id;

    if square_uses<=reserved_square then
      raise exception 'Square ship reward unavailable';
    end if;

    insert into public.fruitkog_reward_reservations(game_id,user_id,reward_type)
    values(g.id,uid,'square_ship')
    on conflict(game_id,user_id,reward_type) do nothing;
  else
    delete from public.fruitkog_reward_reservations
    where game_id=g.id and user_id=uid and reward_type='square_ship';
  end if;

  if wants_auto_miss then
    select count(*)::integer into reserved_auto_miss
    from public.fruitkog_reward_reservations rr
    where rr.user_id=uid
      and rr.reward_type='auto_miss'
      and rr.game_id<>g.id;

    if auto_miss_uses<=reserved_auto_miss then
      raise exception 'Auto miss reward unavailable';
    end if;

    insert into public.fruitkog_reward_reservations(game_id,user_id,reward_type)
    values(g.id,uid,'auto_miss')
    on conflict(game_id,user_id,reward_type) do nothing;
  else
    delete from public.fruitkog_reward_reservations
    where game_id=g.id and user_id=uid and reward_type='auto_miss';
  end if;

  insert into public.fleets(game_id,owner_id,ships)
  values(g.id,uid,p_ships)
  on conflict(game_id,owner_id)
  do update set ships=excluded.ships,created_at=now();

  if uid=g.player1_id then
    update public.games
    set player1_ready=true,player1_action_at=now(),updated_at=now()
    where id=g.id;
  else
    update public.games
    set player2_ready=true,player2_action_at=now(),updated_at=now()
    where id=g.id;
  end if;

  select * into g
  from public.games
  where id=p_game_id;

  if g.player1_ready and g.player2_ready then
    -- Блокируем все затронутые счетчики в одном порядке: два параллельно
    -- стартующих матча одного игрока не смогут потратить одно использование дважды.
    perform r.user_id
    from public.fruitkog_player_rewards r
    where r.user_id in(
      select distinct rr.user_id
      from public.fruitkog_reward_reservations rr
      where rr.game_id=g.id
    )
    order by r.user_id
    for update;

    insert into public.fruitkog_game_boosts(
      game_id,user_id,auto_miss_enabled,square_ship_used,created_at
    )
    select
      g.id,
      participant.user_id,
      exists(
        select 1 from public.fruitkog_reward_reservations rr
        where rr.game_id=g.id
          and rr.user_id=participant.user_id
          and rr.reward_type='auto_miss'
      ),
      exists(
        select 1 from public.fruitkog_reward_reservations rr
        where rr.game_id=g.id
          and rr.user_id=participant.user_id
          and rr.reward_type='square_ship'
      ),
      now()
    from (values(g.player1_id),(g.player2_id)) participant(user_id)
    on conflict(game_id,user_id) do update
    set auto_miss_enabled=excluded.auto_miss_enabled,
        square_ship_used=excluded.square_ship_used,
        created_at=excluded.created_at;

    for reward_rec in
      select rr.user_id,rr.reward_type
      from public.fruitkog_reward_reservations rr
      where rr.game_id=g.id
      order by rr.user_id,rr.reward_type
    loop
      if reward_rec.reward_type='square_ship' then
        update public.fruitkog_player_rewards
        set square_ship_uses=square_ship_uses-1,
            updated_at=now()
        where user_id=reward_rec.user_id and square_ship_uses>0;
      else
        update public.fruitkog_player_rewards
        set auto_miss_uses=auto_miss_uses-1,
            updated_at=now()
        where user_id=reward_rec.user_id and auto_miss_uses>0;
      end if;

      if not found then
        raise exception 'Game reward unavailable';
      end if;
    end loop;

    delete from public.fruitkog_reward_reservations
    where game_id=g.id;

    first_turn:=case when random()<0.5 then g.player1_id else g.player2_id end;

    update public.games
    set status='playing',
        current_turn=first_turn,
        turn_started_at=now(),
        updated_at=now()
    where id=g.id
    returning * into g;
  end if;

  return to_jsonb(g);
end;
$$;

revoke execute on function public.get_my_game_boosts(uuid) from public,anon;
grant execute on function public.get_my_game_boosts(uuid) to authenticated;

revoke execute on function public.ready_with_fleet(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.ready_with_fleet(uuid,jsonb,jsonb) to authenticated;

commit;
