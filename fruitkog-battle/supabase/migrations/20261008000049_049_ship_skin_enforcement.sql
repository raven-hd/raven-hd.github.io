-- обновление 136: активный скин матча определяется сервером.
-- Клиент не может подставить наградной грибной скин без действующего права.
-- Косметический скин игрока сохраняется в строке матча, чтобы соперник и зритель
-- могли видеть правильный скин уже потопленных кораблей.
-- ветка fruitkog-rewards; не применять на основном проекте до завершения текущего турнира.

begin;

alter table public.games
add column if not exists player1_ship_skin text not null default 'vegetable'
  check (player1_ship_skin in ('vegetable','mushroom')),
add column if not exists player2_ship_skin text not null default 'vegetable'
  check (player2_ship_skin in ('vegetable','mushroom'));

create or replace function public.resolve_fruitkog_ship_skin(p_user_id uuid)
returns text
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  wanted text:='vegetable';
begin
  select coalesce(r.selected_ship_skin,'vegetable')
  into wanted
  from public.fruitkog_player_rewards r
  where r.user_id=p_user_id;

  if wanted='mushroom' and exists(
    select 1
    from public.fruitkog_reward_entitlements e
    where e.user_id=p_user_id
      and e.reward_code='mushroom_skin'
      and e.revoked_at is null
      and (e.expires_at is null or e.expires_at>now())
  ) then
    return 'mushroom';
  end if;

  return 'vegetable';
end;
$$;

create or replace function public.normalize_fruitkog_fleet_skin(
  p_ships jsonb,
  p_skin text
)
returns jsonb
language sql
immutable
set search_path=''
as $$
  select coalesce(
    jsonb_agg((item.value-'skin')||jsonb_build_object('skin',p_skin) order by item.ordinality),
    '[]'::jsonb
  )
  from jsonb_array_elements(p_ships) with ordinality item(value,ordinality);
$$;

drop function if exists public.ready_with_fleet(uuid,jsonb,jsonb);

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
  chosen_skin text:='vegetable';
  normalized_ships jsonb;
  rr record;
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

  chosen_skin:=public.resolve_fruitkog_ship_skin(uid);
  normalized_ships:=public.normalize_fruitkog_fleet_skin(p_ships,chosen_skin);

  perform public.assert_valid_fleet(normalized_ships);

  select exists(
    select 1
    from jsonb_array_elements(normalized_ships) ship(value)
    where coalesce(nullif(lower(ship.value->>'shape'),''),'line')='square'
  ) into uses_square;

  wants_auto_miss:=lower(coalesce(p_options->>'auto_miss','false')) in ('true','1','yes','on');

  if g.game_type='tournament' and (uses_square or wants_auto_miss) then
    raise exception 'Game boosts unavailable in tournament';
  end if;

  if uses_square then
    perform public.reserve_fruitkog_reward(g.id,uid,'square_ship');
  else
    delete from public.fruitkog_reward_reservations
    where game_id=g.id and user_id=uid and reward_type='square_ship';
  end if;

  if wants_auto_miss then
    perform public.reserve_fruitkog_reward(g.id,uid,'auto_miss');
  else
    delete from public.fruitkog_reward_reservations
    where game_id=g.id and user_id=uid and reward_type='auto_miss';
  end if;

  insert into public.fleets(game_id,owner_id,ships)
  values(g.id,uid,normalized_ships)
  on conflict(game_id,owner_id)
  do update set ships=excluded.ships,created_at=now();

  if uid=g.player1_id then
    update public.games
    set player1_ready=true,
        player1_ship_skin=chosen_skin,
        player1_action_at=now(),
        updated_at=now()
    where id=g.id;
  else
    update public.games
    set player2_ready=true,
        player2_ship_skin=chosen_skin,
        player2_action_at=now(),
        updated_at=now()
    where id=g.id;
  end if;

  select * into g from public.games where id=p_game_id;

  if g.player1_ready and g.player2_ready then
    insert into public.fruitkog_game_boosts(
      game_id,user_id,auto_miss_enabled,square_ship_used,created_at
    )
    select
      g.id,
      participant.user_id,
      exists(
        select 1 from public.fruitkog_reward_reservations r
        where r.game_id=g.id and r.user_id=participant.user_id and r.reward_type='auto_miss'
      ),
      exists(
        select 1 from public.fruitkog_reward_reservations r
        where r.game_id=g.id and r.user_id=participant.user_id and r.reward_type='square_ship'
      ),
      now()
    from (values(g.player1_id),(g.player2_id)) participant(user_id)
    on conflict(game_id,user_id) do update
    set auto_miss_enabled=excluded.auto_miss_enabled,
        square_ship_used=excluded.square_ship_used,
        created_at=excluded.created_at;

    for rr in
      select r.entitlement_id
      from public.fruitkog_reward_reservations r
      where r.game_id=g.id
      order by r.entitlement_id
    loop
      perform public.consume_fruitkog_reward(rr.entitlement_id);
    end loop;

    delete from public.fruitkog_reward_reservations where game_id=g.id;

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

revoke execute on function public.resolve_fruitkog_ship_skin(uuid)
from public,anon,authenticated;
revoke execute on function public.normalize_fruitkog_fleet_skin(jsonb,text)
from public,anon,authenticated;

revoke execute on function public.ready_with_fleet(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.ready_with_fleet(uuid,jsonb,jsonb) to authenticated;

commit;
