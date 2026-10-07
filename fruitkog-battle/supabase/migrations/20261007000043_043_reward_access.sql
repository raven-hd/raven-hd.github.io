-- обновление 130: безопасный доступ к будущим наградам Fruitkog.
-- не применять на основном проекте до завершения текущего турнира.

create or replace function public.get_my_fruitkog_rewards()
returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  reward_row public.fruitkog_player_rewards%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if not exists(
    select 1 from public.profiles p
    where p.user_id=uid and p.account_type='registered'
  ) then
    return jsonb_build_object(
      'mushroom_skin_unlocked',false,
      'auto_miss_uses',0,
      'square_ship_uses',0,
      'selected_ship_skin','vegetable'
    );
  end if;

  select * into reward_row
  from public.fruitkog_player_rewards
  where user_id=uid;

  if not found then
    return jsonb_build_object(
      'mushroom_skin_unlocked',false,
      'auto_miss_uses',0,
      'square_ship_uses',0,
      'selected_ship_skin','vegetable'
    );
  end if;

  return jsonb_build_object(
    'mushroom_skin_unlocked',reward_row.mushroom_skin_unlocked,
    'auto_miss_uses',reward_row.auto_miss_uses,
    'square_ship_uses',reward_row.square_ship_uses,
    'selected_ship_skin',reward_row.selected_ship_skin
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
  reward_row public.fruitkog_player_rewards%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if not exists(
    select 1 from public.profiles p
    where p.user_id=uid and p.account_type='registered'
  ) then raise exception 'Registered profile required'; end if;
  if wanted not in('vegetable','mushroom') then raise exception 'Unknown ship skin'; end if;

  select * into reward_row
  from public.fruitkog_player_rewards
  where user_id=uid
  for update;

  if wanted='mushroom' and (not found or not reward_row.mushroom_skin_unlocked) then
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

create or replace function public.admin_set_fruitkog_rewards(
  p_user_id uuid,
  p_mushroom_skin_unlocked boolean default null,
  p_auto_miss_uses integer default null,
  p_square_ship_uses integer default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  reward_row public.fruitkog_player_rewards%rowtype;
begin
  perform public.require_game_admin();

  if not exists(
    select 1 from public.profiles p
    where p.user_id=p_user_id and p.account_type='registered'
  ) then raise exception 'Registered profile not found'; end if;
  if p_auto_miss_uses is not null and p_auto_miss_uses<0 then raise exception 'Invalid auto miss uses'; end if;
  if p_square_ship_uses is not null and p_square_ship_uses<0 then raise exception 'Invalid square ship uses'; end if;

  insert into public.fruitkog_player_rewards(
    user_id,mushroom_skin_unlocked,auto_miss_uses,square_ship_uses,updated_at
  ) values(
    p_user_id,
    coalesce(p_mushroom_skin_unlocked,false),
    coalesce(p_auto_miss_uses,0),
    coalesce(p_square_ship_uses,0),
    now()
  )
  on conflict(user_id) do update
  set mushroom_skin_unlocked=coalesce(p_mushroom_skin_unlocked,fruitkog_player_rewards.mushroom_skin_unlocked),
      auto_miss_uses=coalesce(p_auto_miss_uses,fruitkog_player_rewards.auto_miss_uses),
      square_ship_uses=coalesce(p_square_ship_uses,fruitkog_player_rewards.square_ship_uses),
      selected_ship_skin=case
        when coalesce(p_mushroom_skin_unlocked,fruitkog_player_rewards.mushroom_skin_unlocked)=false
          and fruitkog_player_rewards.selected_ship_skin='mushroom'
        then 'vegetable'
        else fruitkog_player_rewards.selected_ship_skin
      end,
      updated_at=now()
  returning * into reward_row;

  return jsonb_build_object(
    'user_id',reward_row.user_id,
    'mushroom_skin_unlocked',reward_row.mushroom_skin_unlocked,
    'auto_miss_uses',reward_row.auto_miss_uses,
    'square_ship_uses',reward_row.square_ship_uses,
    'selected_ship_skin',reward_row.selected_ship_skin
  );
end;
$$;

revoke execute on function public.get_my_fruitkog_rewards() from public,anon;
revoke execute on function public.set_fruitkog_ship_skin(text) from public,anon;
revoke execute on function public.admin_set_fruitkog_rewards(uuid,boolean,integer,integer) from public,anon;

grant execute on function public.get_my_fruitkog_rewards() to authenticated;
grant execute on function public.set_fruitkog_ship_skin(text) to authenticated;
grant execute on function public.admin_set_fruitkog_rewards(uuid,boolean,integer,integer) to authenticated;
