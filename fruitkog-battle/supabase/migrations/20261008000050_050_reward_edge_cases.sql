-- обновление 137: исправления граничных случаев универсальных наград.
-- ветка fruitkog-rewards; не применять на основном проекте до завершения текущего турнира.

begin;

-- Остаток использований должен иметь право дойти до нуля после последней игры.
alter table public.fruitkog_reward_entitlements
drop constraint if exists fruitkog_reward_entitlements_remaining_uses_check;

alter table public.fruitkog_reward_entitlements
add constraint fruitkog_reward_entitlements_remaining_uses_check
check (remaining_uses is null or remaining_uses >= 0);

-- Для скина количество игр не имеет смысла: он ограничивается только сроком.
create or replace function public.admin_grant_fruitkog_reward(
  p_user_id uuid,
  p_reward_code text,
  p_uses integer default null,
  p_expires_at timestamptz default null,
  p_source text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  wanted text:=lower(trim(coalesce(p_reward_code,'')));
  entitlement public.fruitkog_reward_entitlements%rowtype;
begin
  perform public.require_game_admin();

  if not exists(
    select 1
    from public.profiles p
    where p.user_id=p_user_id and p.account_type='registered'
  ) then
    raise exception 'Registered profile not found';
  end if;

  if wanted not in('mushroom_skin','auto_miss','square_ship') then
    raise exception 'Unknown reward';
  end if;

  if wanted='mushroom_skin' and p_uses is not null then
    raise exception 'Skin rewards cannot have usage limits';
  end if;

  if wanted<>'mushroom_skin' and p_uses is not null and p_uses<1 then
    raise exception 'Reward uses must be positive or null';
  end if;

  if p_expires_at is not null and p_expires_at<=now() then
    raise exception 'Reward expiration must be in the future';
  end if;

  insert into public.fruitkog_reward_entitlements(
    user_id,reward_code,remaining_uses,expires_at,source,granted_by
  )
  values(
    p_user_id,wanted,p_uses,p_expires_at,nullif(trim(coalesce(p_source,'')),''),uid
  )
  returning * into entitlement;

  return jsonb_build_object(
    'id',entitlement.id,
    'user_id',entitlement.user_id,
    'reward_code',entitlement.reward_code,
    'remaining_uses',entitlement.remaining_uses,
    'unlimited',entitlement.remaining_uses is null,
    'expires_at',entitlement.expires_at,
    'source',entitlement.source,
    'granted_at',entitlement.granted_at
  );
end;
$$;

-- Не даем отозвать бонус, который уже зарезервирован готовым игроком:
-- иначе второй игрок не смог бы корректно запустить матч.
create or replace function public.admin_revoke_fruitkog_reward(p_entitlement_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  entitlement public.fruitkog_reward_entitlements%rowtype;
begin
  perform public.require_game_admin();

  if exists(
    select 1
    from public.fruitkog_reward_reservations r
    where r.entitlement_id=p_entitlement_id
  ) then
    raise exception 'Reward is reserved for an active game';
  end if;

  update public.fruitkog_reward_entitlements
  set revoked_at=coalesce(revoked_at,now())
  where id=p_entitlement_id
  returning * into entitlement;

  if not found then raise exception 'Reward grant not found'; end if;

  return jsonb_build_object(
    'id',entitlement.id,
    'user_id',entitlement.user_id,
    'reward_code',entitlement.reward_code,
    'revoked_at',entitlement.revoked_at
  );
end;
$$;

-- Если среди активных выдач есть бессрочная, итоговый expires_at тоже должен быть null,
-- а не датой другой, временной выдачи.
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
  mushroom_never_expires boolean:=false;
  auto_unlimited boolean:=false;
  square_unlimited boolean:=false;
  auto_never_expires boolean:=false;
  square_never_expires boolean:=false;
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
    count(*)>0,
    coalesce(bool_or(e.expires_at is null),false),
    max(e.expires_at) filter(where e.expires_at is not null)
  into mushroom_active,mushroom_never_expires,mushroom_expires
  from public.fruitkog_reward_entitlements e
  where e.user_id=uid
    and e.reward_code='mushroom_skin'
    and e.revoked_at is null
    and (e.expires_at is null or e.expires_at>now());

  select
    coalesce(bool_or(e.remaining_uses is null),false),
    coalesce(sum(e.remaining_uses) filter(where e.remaining_uses is not null),0)::integer,
    coalesce(bool_or(e.expires_at is null),false),
    max(e.expires_at) filter(where e.expires_at is not null)
  into auto_unlimited,auto_uses,auto_never_expires,auto_expires
  from public.fruitkog_reward_entitlements e
  where e.user_id=uid
    and e.reward_code='auto_miss'
    and e.revoked_at is null
    and (e.expires_at is null or e.expires_at>now())
    and (e.remaining_uses is null or e.remaining_uses>0);

  select
    coalesce(bool_or(e.remaining_uses is null),false),
    coalesce(sum(e.remaining_uses) filter(where e.remaining_uses is not null),0)::integer,
    coalesce(bool_or(e.expires_at is null),false),
    max(e.expires_at) filter(where e.expires_at is not null)
  into square_unlimited,square_uses,square_never_expires,square_expires
  from public.fruitkog_reward_entitlements e
  where e.user_id=uid
    and e.reward_code='square_ship'
    and e.revoked_at is null
    and (e.expires_at is null or e.expires_at>now())
    and (e.remaining_uses is null or e.remaining_uses>0);

  if mushroom_never_expires then mushroom_expires:=null; end if;
  if auto_never_expires then auto_expires:=null; end if;
  if square_never_expires then square_expires:=null; end if;

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

-- Расходуем сначала то, что раньше истечет; среди одинаковых сроков —
-- конечные использования раньше безлимитных.
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
    e.expires_at asc nulls last,
    (e.remaining_uses is null) asc,
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

revoke execute on function public.reserve_fruitkog_reward(uuid,uuid,text)
from public,anon,authenticated;

commit;
