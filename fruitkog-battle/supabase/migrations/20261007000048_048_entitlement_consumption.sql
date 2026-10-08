-- обновление 135: единая модель наград: количество игр + срок действия.
-- Скины ограничиваются только сроком; бустеры могут быть на N игр или безлимитными.
-- ветка fruitkog-rewards; не применять на основном проекте до завершения текущего турнира.

begin;

alter table public.fruitkog_reward_reservations
add column if not exists entitlement_id uuid
references public.fruitkog_reward_entitlements(id) on delete cascade;

create index if not exists fruitkog_reward_reservations_entitlement_idx
on public.fruitkog_reward_reservations(entitlement_id);

create or replace function public.get_my_fruitkog_rewards()
returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  skin_selected text:='vegetable';
  mushroom_active boolean:=false;
  auto_unlimited boolean:=false;
  square_unlimited boolean:=false;
  auto_uses integer:=0;
  square_uses integer:=0;
  auto_expires timestamptz;
  square_expires timestamptz;
  mushroom_expires timestamptz;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  if not exists(
    select 1 from public.profiles p
    where p.user_id=uid and p.account_type='registered'
  ) then
    return jsonb_build_object(
      'mushroom_skin_unlocked',false,
      'mushroom_skin_expires_at',null,
      'auto_miss_uses',0,
      'auto_miss_unlimited',false,
      'auto_miss_expires_at',null,
      'square_ship_uses',0,
      'square_ship_unlimited',false,
      'square_ship_expires_at',null,
      'selected_ship_skin','vegetable'
    );
  end if;

  select coalesce(r.selected_ship_skin,'vegetable')
  into skin_selected
  from public.fruitkog_player_rewards r
  where r.user_id=uid;

  select
    exists(
      select 1 from public.fruitkog_reward_entitlements e
      where e.user_id=uid and e.reward_code='mushroom_skin'
        and e.revoked_at is null
        and (e.expires_at is null or e.expires_at>now())
    ),
    max(e.expires_at) filter(where e.expires_at is not null)
  into mushroom_active,mushroom_expires
  from public.fruitkog_reward_entitlements e
  where e.user_id=uid and e.reward_code='mushroom_skin'
    and e.revoked_at is null
    and (e.expires_at is null or e.expires_at>now());

  select
    coalesce(bool_or(e.remaining_uses is null),false),
    coalesce(sum(e.remaining_uses) filter(where e.remaining_uses is not null),0)::integer,
    max(e.expires_at) filter(where e.expires_at is not null)
  into auto_unlimited,auto_uses,auto_expires
  from public.fruitkog_reward_entitlements e
  where e.user_id=uid and e.reward_code='auto_miss'
    and e.revoked_at is null
    and (e.expires_at is null or e.expires_at>now())
    and (e.remaining_uses is null or e.remaining_uses>0);

  select
    coalesce(bool_or(e.remaining_uses is null),false),
    coalesce(sum(e.remaining_uses) filter(where e.remaining_uses is not null),0)::integer,
    max(e.expires_at) filter(where e.expires_at is not null)
  into square_unlimited,square_uses,square_expires
  from public.fruitkog_reward_entitlements e
  where e.user_id=uid and e.reward_code='square_ship'
    and e.revoked_at is null
    and (e.expires_at is null or e.expires_at>now())
    and (e.remaining_uses is null or e.remaining_uses>0);

  if skin_selected='mushroom' and not mushroom_active then
    skin_selected:='vegetable';
  end if;

  return jsonb_build_object(
    'mushroom_skin_unlocked',mushroom_active,
    'mushroom_skin_expires_at',mushroom_expires,
    'auto_miss_uses',auto_uses,
    'auto_miss_unlimited',auto_unlimited,
    'auto_miss_expires_at',auto_expires,
    'square_ship_uses',square_uses,
    'square_ship_unlimited',square_unlimited,
    'square_ship_expires_at',square_expires,
    'selected_ship_skin',skin_selected
  );
end;
$$;

create or replace function public.set_fruitkog_ship_skin(p_skin text)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  wanted text:=lower(trim(coalesce(p_skin,'')));
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if not exists(
    select 1 from public.profiles p
    where p.user_id=uid and p.account_type='registered'
  ) then raise exception 'Registered profile required'; end if;

  if wanted not in('vegetable','mushroom') then raise exception 'Unknown ship skin'; end if;

  if wanted='mushroom' and not exists(
    select 1
    from public.fruitkog_reward_entitlements e
    where e.user_id=uid
      and e.reward_code='mushroom_skin'
      and e.revoked_at is null
      and (e.expires_at is null or e.expires_at>now())
  ) then
    raise exception 'Ship skin is locked';
  end if;

  insert into public.fruitkog_player_rewards(user_id,selected_ship_skin,updated_at)
  values(uid,wanted,now())
  on conflict(user_id) do update
  set selected_ship_skin=excluded.selected_ship_skin,
      updated_at=now();

  return public.get_my_fruitkog_rewards();
end;
$$;

create or replace function public.reserve_fruitkog_reward(
  p_game_id uuid,
  p_user_id uuid,
  p_reward_code text
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  chosen_id uuid;
begin
  -- Сначала берем бессрочный по использованию grant, затем тот, что сгорит раньше,
  -- затем самый старый: так конечные бонусы не пропадают зря.
  select e.id into chosen_id
  from public.fruitkog_reward_entitlements e
  where e.user_id=p_user_id
    and e.reward_code=p_reward_code
    and e.revoked_at is null
    and (e.expires_at is null or e.expires_at>now())
    and (
      e.remaining_uses is null
      or e.remaining_uses>(
        select count(*)::integer
        from public.fruitkog_reward_reservations rr
        where rr.entitlement_id=e.id and rr.game_id<>p_game_id
      )
    )
  order by
    (e.remaining_uses is null) asc,
    e.expires_at asc nulls last,
    e.granted_at asc
  for update skip locked
  limit 1;

  if chosen_id is null then
    raise exception 'Game reward unavailable';
  end if;

  insert into public.fruitkog_reward_reservations(
    game_id,user_id,reward_type,entitlement_id
  )
  values(p_game_id,p_user_id,p_reward_code,chosen_id)
  on conflict(game_id,user_id,reward_type) do update
  set entitlement_id=excluded.entitlement_id,
      created_at=now();

  return chosen_id;
end;
$$;

create or replace function public.consume_fruitkog_reward(
  p_entitlement_id uuid
)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  e public.fruitkog_reward_entitlements%rowtype;
begin
  select * into e
  from public.fruitkog_reward_entitlements
  where id=p_entitlement_id
  for update;

  if not found
     or e.revoked_at is not null
     or (e.expires_at is not null and e.expires_at<=now())
     or (e.remaining_uses is not null and e.remaining_uses<=0) then
    raise exception 'Game reward unavailable';
  end if;

  if e.remaining_uses is not null then
    update public.fruitkog_reward_entitlements
    set remaining_uses=remaining_uses-1
    where id=e.id;
  end if;
end;
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

revoke execute on function public.reserve_fruitkog_reward(uuid,uuid,text)
from public,anon,authenticated;
revoke execute on function public.consume_fruitkog_reward(uuid)
from public,anon,authenticated;

revoke execute on function public.ready_with_fleet(uuid,jsonb,jsonb) from public,anon;
grant execute on function public.ready_with_fleet(uuid,jsonb,jsonb) to authenticated;

commit;
