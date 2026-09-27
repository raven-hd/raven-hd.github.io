-- обновление 15: уведомления администратора.
-- выполните после 013_tournament_applications.sql.

create table if not exists public.admin_notifications (
  id uuid primary key default gen_random_uuid(),
  kind text not null check(kind in('nickname_pending','tournament_application','tournament_withdrawn')),
  title text not null,
  body text not null,
  actor_id uuid references auth.users(id) on delete set null,
  tournament_id uuid references public.tournaments(id) on delete cascade,
  dedupe_key text not null unique,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists admin_notifications_unread_idx
on public.admin_notifications(read_at,created_at desc);

alter table public.admin_notifications enable row level security;
revoke all on public.admin_notifications from anon,authenticated;

create or replace function public.push_admin_notification(
  p_kind text,
  p_title text,
  p_body text,
  p_actor_id uuid,
  p_tournament_id uuid,
  p_dedupe_key text
)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  insert into public.admin_notifications(
    kind,title,body,actor_id,tournament_id,dedupe_key,created_at,read_at
  ) values(
    p_kind,left(p_title,120),left(p_body,500),p_actor_id,p_tournament_id,p_dedupe_key,now(),null
  )
  on conflict(dedupe_key) do update
  set kind=excluded.kind,
      title=excluded.title,
      body=excluded.body,
      actor_id=excluded.actor_id,
      tournament_id=excluded.tournament_id,
      created_at=now(),
      read_at=null;
end;
$$;

create or replace function public.notify_admin_profile_change()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  relevant_change boolean:=tg_op='INSERT';
begin
  if tg_op='UPDATE' then
    relevant_change:=old.account_type is distinct from new.account_type
      or old.school_verified is distinct from new.school_verified;
  end if;
  if new.account_type='registered' and not coalesce(new.school_verified,false) then
    if relevant_change then
      perform public.push_admin_notification(
        'nickname_pending',
        'ник требует подтверждения',
        new.display_name||' ожидает проверки школьного ника.',
        new.user_id,
        null,
        'nickname:'||new.user_id::text
      );
    end if;
  elsif new.account_type<>'registered' or coalesce(new.school_verified,false) then
    update public.admin_notifications
    set read_at=coalesce(read_at,now())
    where dedupe_key='nickname:'||new.user_id::text;
  end if;
  return new;
end;
$$;

drop trigger if exists notify_admin_profile_change_trigger on public.profiles;
create trigger notify_admin_profile_change_trigger
after insert or update of account_type,school_verified on public.profiles
for each row execute function public.notify_admin_profile_change();

create or replace function public.notify_admin_tournament_application()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  player_name text;
  tournament_name text;
  application_key text:='tournament-application:'||new.tournament_id::text||':'||new.user_id::text;
  withdrawn_key text:='tournament-withdrawn:'||new.tournament_id::text||':'||new.user_id::text;
  status_changed boolean:=tg_op='INSERT';
begin
  if tg_op='UPDATE' then status_changed:=old.status is distinct from new.status; end if;
  select display_name into player_name from public.profiles where user_id=new.user_id;
  select name into tournament_name from public.tournaments where id=new.tournament_id;

  if new.status='pending' and status_changed then
    update public.admin_notifications
    set read_at=coalesce(read_at,now())
    where dedupe_key=withdrawn_key;

    perform public.push_admin_notification(
      'tournament_application',
      'новая заявка на турнир',
      coalesce(player_name,'игрок')||' подал заявку на турнир «'||coalesce(tournament_name,'турнир')||'».',
      new.user_id,
      new.tournament_id,
      application_key
    );
  elsif new.status='withdrawn' and status_changed then
    update public.admin_notifications
    set read_at=coalesce(read_at,now())
    where dedupe_key=application_key;

    perform public.push_admin_notification(
      'tournament_withdrawn',
      'участник отозвал заявку',
      coalesce(player_name,'игрок')||' отказался от участия в турнире «'||coalesce(tournament_name,'турнир')||'».',
      new.user_id,
      new.tournament_id,
      withdrawn_key
    );
  elsif new.status in('approved','rejected') then
    update public.admin_notifications
    set read_at=coalesce(read_at,now())
    where dedupe_key=application_key;
  end if;
  return new;
end;
$$;

drop trigger if exists notify_admin_tournament_application_trigger on public.tournament_applications;
create trigger notify_admin_tournament_application_trigger
after insert or update of status on public.tournament_applications
for each row execute function public.notify_admin_tournament_application();

-- Создаем актуальные уведомления для данных, которые появились до установки обновления.
insert into public.admin_notifications(
  kind,title,body,actor_id,tournament_id,dedupe_key,created_at,read_at
)
select
  'nickname_pending',
  'ник требует подтверждения',
  p.display_name||' ожидает проверки школьного ника.',
  p.user_id,
  null,
  'nickname:'||p.user_id::text,
  p.created_at,
  null
from public.profiles p
where p.account_type='registered' and not coalesce(p.school_verified,false)
on conflict(dedupe_key) do nothing;

insert into public.admin_notifications(
  kind,title,body,actor_id,tournament_id,dedupe_key,created_at,read_at
)
select
  'tournament_application',
  'новая заявка на турнир',
  p.display_name||' подал заявку на турнир «'||t.name||'».',
  ta.user_id,
  ta.tournament_id,
  'tournament-application:'||ta.tournament_id::text||':'||ta.user_id::text,
  ta.updated_at,
  null
from public.tournament_applications ta
join public.profiles p on p.user_id=ta.user_id
join public.tournaments t on t.id=ta.tournament_id
where ta.status='pending'
on conflict(dedupe_key) do update
set title=excluded.title,body=excluded.body,created_at=excluded.created_at,read_at=null;

insert into public.admin_notifications(
  kind,title,body,actor_id,tournament_id,dedupe_key,created_at,read_at
)
select
  'tournament_withdrawn',
  'участник отозвал заявку',
  p.display_name||' отказался от участия в турнире «'||t.name||'».',
  ta.user_id,
  ta.tournament_id,
  'tournament-withdrawn:'||ta.tournament_id::text||':'||ta.user_id::text,
  ta.updated_at,
  null
from public.tournament_applications ta
join public.profiles p on p.user_id=ta.user_id
join public.tournaments t on t.id=ta.tournament_id
where ta.status='withdrawn'
on conflict(dedupe_key) do nothing;

create or replace function public.admin_list_notifications(p_limit integer default 30)
returns jsonb
language plpgsql security definer stable set search_path=''
as $$
declare
  item_limit integer:=least(greatest(coalesce(p_limit,30),1),100);
  result jsonb;
begin
  perform public.require_game_admin();
  select jsonb_build_object(
    'unread_count',(select count(*) from public.admin_notifications where read_at is null),
    'items',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',n.id,
        'kind',n.kind,
        'title',n.title,
        'body',n.body,
        'actor_id',n.actor_id,
        'tournament_id',n.tournament_id,
        'created_at',n.created_at,
        'read_at',n.read_at
      ) order by (n.read_at is null) desc,n.created_at desc)
      from (
        select * from public.admin_notifications
        order by (read_at is null) desc,created_at desc
        limit item_limit
      ) n
    ),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function public.admin_mark_notifications_read(p_notification_id uuid default null)
returns jsonb
language plpgsql security definer set search_path=''
as $$
begin
  perform public.require_game_admin();
  if p_notification_id is null then
    update public.admin_notifications set read_at=now() where read_at is null;
  else
    update public.admin_notifications
    set read_at=coalesce(read_at,now())
    where id=p_notification_id;
  end if;
  return public.admin_list_notifications(30);
end;
$$;

revoke execute on function public.push_admin_notification(text,text,text,uuid,uuid,text) from public,anon,authenticated;
revoke execute on function public.notify_admin_profile_change() from public,anon,authenticated;
revoke execute on function public.notify_admin_tournament_application() from public,anon,authenticated;
revoke execute on function public.admin_list_notifications(integer) from public,anon;
revoke execute on function public.admin_mark_notifications_read(uuid) from public,anon;

grant execute on function public.admin_list_notifications(integer) to authenticated;
grant execute on function public.admin_mark_notifications_read(uuid) to authenticated;
