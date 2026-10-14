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


