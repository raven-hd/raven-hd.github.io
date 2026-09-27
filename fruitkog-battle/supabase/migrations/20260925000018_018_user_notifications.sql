-- обновление 19: уведомления игроков и объявления администратора.
-- выполните после 017_tournament_registration_deadline.sql.

create table if not exists public.user_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check(kind in(
    'opponent_joined',
    'tournament_application',
    'tournament_match_assigned',
    'tournament_match_finished',
    'reward'
  )),
  title text not null,
  body text not null,
  game_id uuid references public.games(id) on delete cascade,
  tournament_id uuid references public.tournaments(id) on delete cascade,
  tournament_match_id uuid references public.tournament_matches(id) on delete cascade,
  dedupe_key text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  unique(recipient_id,dedupe_key)
);

create index if not exists user_notifications_recipient_idx
on public.user_notifications(recipient_id,read_at,created_at desc);

create table if not exists public.user_announcements (
  id uuid primary key default gen_random_uuid(),
  kind text not null check(kind in('tournament_registration','admin_message')),
  title text not null,
  body text not null,
  tournament_id uuid references public.tournaments(id) on delete cascade,
  created_by uuid references auth.users(id) on delete set null,
  dedupe_key text not null unique,
  audience_before timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create index if not exists user_announcements_created_idx
on public.user_announcements(created_at desc);

create table if not exists public.user_announcement_reads (
  announcement_id uuid not null references public.user_announcements(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key(announcement_id,user_id)
);

alter table public.user_notifications enable row level security;
alter table public.user_announcements enable row level security;
alter table public.user_announcement_reads enable row level security;

revoke all on public.user_notifications,public.user_announcements,public.user_announcement_reads
from anon,authenticated;

create or replace function public.push_user_notification(
  p_recipient_id uuid,
  p_kind text,
  p_title text,
  p_body text,
  p_game_id uuid,
  p_tournament_id uuid,
  p_tournament_match_id uuid,
  p_dedupe_key text
)
returns void
language plpgsql security definer set search_path=''
as $$
begin
  if not exists(
    select 1 from public.profiles
    where user_id=p_recipient_id and account_type='registered'
  ) then return; end if;

  insert into public.user_notifications(
    recipient_id,kind,title,body,game_id,tournament_id,tournament_match_id,
    dedupe_key,created_at,read_at
  ) values(
    p_recipient_id,p_kind,left(trim(p_title),120),left(trim(p_body),500),
    p_game_id,p_tournament_id,p_tournament_match_id,p_dedupe_key,now(),null
  )
  on conflict(recipient_id,dedupe_key) do update
  set kind=excluded.kind,
      title=excluded.title,
      body=excluded.body,
      game_id=excluded.game_id,
      tournament_id=excluded.tournament_id,
      tournament_match_id=excluded.tournament_match_id,
      created_at=now(),
      read_at=null;
end;
$$;

create or replace function public.notify_user_opponent_joined()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  perform public.push_user_notification(
    new.player1_id,
    'opponent_joined',
    'к игре присоединился соперник',
    coalesce(new.player2_name,'игрок')||' присоединился к вашей комнате.',
    new.id,
    null,
    null,
    'opponent-joined:'||new.id::text
  );
  return new;
end;
$$;

drop trigger if exists notify_user_opponent_joined_trigger on public.games;
create trigger notify_user_opponent_joined_trigger
after update of player2_id on public.games
for each row
when(old.player2_id is null and new.player2_id is not null)
execute function public.notify_user_opponent_joined();

create or replace function public.notify_user_tournament_application()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  tournament_name text;
begin
  if old.status is not distinct from new.status or new.status not in('approved','rejected') then
    return new;
  end if;
  select name into tournament_name from public.tournaments where id=new.tournament_id;
  perform public.push_user_notification(
    new.user_id,
    'tournament_application',
    case new.status when 'approved' then 'заявка на турнир одобрена' else 'заявка на турнир отклонена' end,
    case new.status
      when 'approved' then 'вы добавлены в состав турнира «'||coalesce(tournament_name,'турнир')||'».'
      else 'заявка на турнир «'||coalesce(tournament_name,'турнир')||'» отклонена.'
    end,
    null,
    new.tournament_id,
    null,
    'tournament-application-decision:'||new.tournament_id::text||':'||new.user_id::text
  );
  return new;
end;
$$;

drop trigger if exists notify_user_tournament_application_trigger on public.tournament_applications;
create trigger notify_user_tournament_application_trigger
after update of status on public.tournament_applications
for each row execute function public.notify_user_tournament_application();

create or replace function public.publish_tournament_registration_announcement()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  should_publish boolean:=false;
  deadline_text text;
begin
  if tg_op='INSERT' then
    should_publish:=new.status='registration';
  elsif old.status is distinct from new.status and new.status='registration' then
    should_publish:=true;
  end if;
  if not should_publish then return new; end if;

  deadline_text:=case
    when new.registration_deadline is null then 'срок подачи заявок указан на странице турнира.'
    else 'запись открыта до '||to_char(new.registration_deadline at time zone 'Europe/Moscow','DD.MM.YYYY, HH24:MI')||'.'
  end;

  insert into public.user_announcements(
    kind,title,body,tournament_id,created_by,dedupe_key,audience_before,created_at
  ) values(
    'tournament_registration',
    'открыта запись на новый турнир',
    '«'||new.name||'». '||deadline_text,
    new.id,
    new.created_by,
    'tournament-registration:'||new.id::text,
    now(),
    now()
  ) on conflict(dedupe_key) do nothing;
  return new;
end;
$$;

drop trigger if exists publish_tournament_registration_announcement_trigger on public.tournaments;
create trigger publish_tournament_registration_announcement_trigger
after insert or update of status on public.tournaments
for each row execute function public.publish_tournament_registration_announcement();

create or replace function public.notify_user_tournament_match_assignment()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  assignment_changed boolean:=false;
  tournament_name text;
  player1_name text;
  player2_name text;
begin
  if tg_op='INSERT' then
    assignment_changed:=new.player1_id is not null and new.player2_id is not null;
  else
    assignment_changed:=new.player1_id is not null and new.player2_id is not null and (
      old.player1_id is distinct from new.player1_id or old.player2_id is distinct from new.player2_id
    );
  end if;
  if not assignment_changed or new.status='cancelled' then return new; end if;

  select name into tournament_name from public.tournaments where id=new.tournament_id;
  select display_name into player1_name from public.profiles where user_id=new.player1_id;
  select display_name into player2_name from public.profiles where user_id=new.player2_id;

  perform public.push_user_notification(
    new.player1_id,
    'tournament_match_assigned',
    'назначен турнирный соперник',
    'ваш соперник в турнире «'||coalesce(tournament_name,'турнир')||'» — '||coalesce(player2_name,'игрок')||'.',
    new.game_id,new.tournament_id,new.id,
    'tournament-match-assigned:'||new.id::text||':'||new.player1_id::text
  );
  perform public.push_user_notification(
    new.player2_id,
    'tournament_match_assigned',
    'назначен турнирный соперник',
    'ваш соперник в турнире «'||coalesce(tournament_name,'турнир')||'» — '||coalesce(player1_name,'игрок')||'.',
    new.game_id,new.tournament_id,new.id,
    'tournament-match-assigned:'||new.id::text||':'||new.player2_id::text
  );
  return new;
end;
$$;

drop trigger if exists notify_user_tournament_match_assignment_trigger on public.tournament_matches;
create trigger notify_user_tournament_match_assignment_trigger
after insert or update of player1_id,player2_id on public.tournament_matches
for each row execute function public.notify_user_tournament_match_assignment();

create or replace function public.notify_user_tournament_match_finished()
returns trigger
language plpgsql security definer set search_path=''
as $$
declare
  tournament_name text;
  match_game public.games%rowtype;
  player_id uuid;
  result_text text;
  rating_text text;
  current_rating integer;
begin
  if old.status is not distinct from new.status or new.status not in('finished','technical') then
    return new;
  end if;
  select name into tournament_name from public.tournaments where id=new.tournament_id;
  if new.game_id is not null then
    select * into match_game from public.games where id=new.game_id;
  end if;

  foreach player_id in array array[new.player1_id,new.player2_id] loop
    if player_id is null then continue; end if;
    result_text:=case
      when new.winner_id is null then 'матч завершен без победителя.'
      when new.winner_id=player_id then 'вы победили.'
      else 'вы проиграли.'
    end;
    rating_text:='';
    if match_game.id is not null and coalesce(match_game.rating_applied,false) then
      select rating into current_rating from public.profiles where user_id=player_id;
      rating_text:=case
        when match_game.winner_id=player_id then ' рейтинг +'||coalesce(match_game.rating_delta,0)::text
        else ' рейтинг −'||coalesce(match_game.rating_delta,0)::text
      end||' — теперь '||coalesce(current_rating,1000)::text||'.';
    end if;
    perform public.push_user_notification(
      player_id,
      'tournament_match_finished',
      'турнирный матч завершен',
      'турнир «'||coalesce(tournament_name,'турнир')||'»: '||result_text||rating_text,
      new.game_id,new.tournament_id,new.id,
      'tournament-match-finished:'||new.id::text||':'||player_id::text
    );
  end loop;
  return new;
end;
$$;

drop trigger if exists notify_user_tournament_match_finished_trigger on public.tournament_matches;
create trigger notify_user_tournament_match_finished_trigger
after update of status,winner_id on public.tournament_matches
for each row execute function public.notify_user_tournament_match_finished();

create or replace function public.admin_publish_user_announcement(p_title text,p_body text)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  clean_title text:=left(trim(regexp_replace(coalesce(p_title,''),'\s+',' ','g')),120);
  clean_body text:=left(trim(regexp_replace(coalesce(p_body,''),'\s+',' ','g')),500);
  announcement public.user_announcements%rowtype;
begin
  perform public.require_game_admin();
  if char_length(clean_title)<3 then raise exception 'Announcement title required'; end if;
  if char_length(clean_body)<3 then raise exception 'Announcement body required'; end if;

  insert into public.user_announcements(
    kind,title,body,tournament_id,created_by,dedupe_key,audience_before,created_at
  ) values(
    'admin_message',clean_title,clean_body,null,auth.uid(),
    'admin-message:'||gen_random_uuid()::text,now(),now()
  ) returning * into announcement;
  return to_jsonb(announcement);
end;
$$;

create or replace function public.list_user_notifications(p_limit integer default 30)
returns jsonb
language plpgsql security definer stable set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  viewer public.profiles%rowtype;
  item_limit integer:=least(greatest(coalesce(p_limit,30),1),100);
  result jsonb;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into viewer from public.profiles where user_id=uid;
  if not found or viewer.account_type<>'registered' then
    return jsonb_build_object('unread_count',0,'items','[]'::jsonb);
  end if;

  with visible_announcements as (
    select a.*,r.read_at
    from public.user_announcements a
    left join public.user_announcement_reads r
      on r.announcement_id=a.id and r.user_id=uid
    where viewer.created_at<=a.audience_before
  ), combined as (
    select
      n.id,'personal'::text as item_type,n.kind,n.title,n.body,
      n.game_id,n.tournament_id,n.tournament_match_id,n.created_at,n.read_at
    from public.user_notifications n
    where n.recipient_id=uid
    union all
    select
      a.id,'announcement'::text,a.kind,a.title,a.body,
      null::uuid,a.tournament_id,null::uuid,a.created_at,a.read_at
    from visible_announcements a
  ), selected as (
    select * from combined
    order by (read_at is null) desc,created_at desc
    limit item_limit
  )
  select jsonb_build_object(
    'unread_count',(select count(*) from combined where read_at is null),
    'items',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',s.id,
        'item_type',s.item_type,
        'kind',s.kind,
        'title',s.title,
        'body',s.body,
        'game_id',s.game_id,
        'tournament_id',s.tournament_id,
        'tournament_match_id',s.tournament_match_id,
        'created_at',s.created_at,
        'read_at',s.read_at
      ) order by (s.read_at is null) desc,s.created_at desc)
      from selected s
    ),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function public.mark_user_notifications_read(
  p_item_type text default null,
  p_item_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  viewer public.profiles%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into viewer from public.profiles where user_id=uid;
  if not found or viewer.account_type<>'registered' then
    raise exception 'Registered profile required';
  end if;

  if p_item_type is null and p_item_id is null then
    update public.user_notifications
    set read_at=coalesce(read_at,now())
    where recipient_id=uid and read_at is null;

    insert into public.user_announcement_reads(announcement_id,user_id,read_at)
    select a.id,uid,now()
    from public.user_announcements a
    where viewer.created_at<=a.audience_before
    on conflict(announcement_id,user_id) do nothing;
  elsif p_item_type='personal' and p_item_id is not null then
    update public.user_notifications
    set read_at=coalesce(read_at,now())
    where id=p_item_id and recipient_id=uid;
  elsif p_item_type='announcement' and p_item_id is not null then
    insert into public.user_announcement_reads(announcement_id,user_id,read_at)
    select a.id,uid,now()
    from public.user_announcements a
    where a.id=p_item_id and viewer.created_at<=a.audience_before
    on conflict(announcement_id,user_id) do nothing;
  else
    raise exception 'Invalid notification';
  end if;
  return public.list_user_notifications(30);
end;
$$;

revoke execute on function public.push_user_notification(uuid,text,text,text,uuid,uuid,uuid,text) from public,anon,authenticated;
revoke execute on function public.notify_user_opponent_joined() from public,anon,authenticated;
revoke execute on function public.notify_user_tournament_application() from public,anon,authenticated;
revoke execute on function public.publish_tournament_registration_announcement() from public,anon,authenticated;
revoke execute on function public.notify_user_tournament_match_assignment() from public,anon,authenticated;
revoke execute on function public.notify_user_tournament_match_finished() from public,anon,authenticated;
revoke execute on function public.admin_publish_user_announcement(text,text) from public,anon;
revoke execute on function public.list_user_notifications(integer) from public,anon;
revoke execute on function public.mark_user_notifications_read(text,uuid) from public,anon;

grant execute on function public.admin_publish_user_announcement(text,text) to authenticated;
grant execute on function public.list_user_notifications(integer) to authenticated;
grant execute on function public.mark_user_notifications_read(text,uuid) to authenticated;
