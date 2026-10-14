-- обновление 134: универсальная выдача игровых наград администратором.
-- Никаких жестко заданных призов турнира здесь нет.
-- Администратор сам выбирает награду, число игр или бессрочный доступ и срок действия.
-- ветка fruitkog-rewards; не применять на основном проекте до завершения текущего турнира.

begin;

create table if not exists public.fruitkog_reward_entitlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  reward_code text not null check (
    reward_code in ('mushroom_skin','auto_miss','square_ship')
  ),
  -- null = неограниченное число игр; положительное число = остаток использований.
  remaining_uses integer check (remaining_uses is null or remaining_uses > 0),
  -- null = без срока годности.
  expires_at timestamptz,
  source text,
  granted_by uuid references auth.users(id) on delete set null,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz
);

create index if not exists fruitkog_reward_entitlements_user_idx
on public.fruitkog_reward_entitlements(user_id,reward_code);

create index if not exists fruitkog_reward_entitlements_active_idx
on public.fruitkog_reward_entitlements(user_id,reward_code,expires_at)
where revoked_at is null;

alter table public.fruitkog_reward_entitlements enable row level security;
revoke all on public.fruitkog_reward_entitlements from anon,authenticated;

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

  if p_uses is not null and p_uses<1 then
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

create or replace function public.admin_list_fruitkog_rewards(p_user_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
begin
  perform public.require_game_admin();

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id',e.id,
        'reward_code',e.reward_code,
        'remaining_uses',e.remaining_uses,
        'unlimited',e.remaining_uses is null,
        'expires_at',e.expires_at,
        'source',e.source,
        'granted_at',e.granted_at,
        'revoked_at',e.revoked_at,
        'active',
          e.revoked_at is null
          and (e.expires_at is null or e.expires_at>now())
          and (e.remaining_uses is null or e.remaining_uses>0)
      )
      order by e.granted_at desc
    )
    from public.fruitkog_reward_entitlements e
    where e.user_id=p_user_id
  ),'[]'::jsonb);
end;
$$;

revoke execute on function public.admin_grant_fruitkog_reward(uuid,text,integer,timestamptz,text)
from public,anon;
revoke execute on function public.admin_revoke_fruitkog_reward(uuid)
from public,anon;
revoke execute on function public.admin_list_fruitkog_rewards(uuid)
from public,anon;

grant execute on function public.admin_grant_fruitkog_reward(uuid,text,integer,timestamptz,text)
to authenticated;
grant execute on function public.admin_revoke_fruitkog_reward(uuid)
to authenticated;
grant execute on function public.admin_list_fruitkog_rewards(uuid)
to authenticated;

commit;
