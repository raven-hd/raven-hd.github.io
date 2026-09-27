-- обновление 14: заявки игроков на участие в турнирах.
-- выполните после 012_tournament_close_and_delete.sql.

create table if not exists public.tournament_applications (
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending'
    check(status in ('pending','approved','rejected','withdrawn')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  primary key(tournament_id,user_id)
);

create index if not exists tournament_applications_review_idx
on public.tournament_applications(tournament_id,status,created_at);

alter table public.tournament_applications enable row level security;
revoke all on public.tournament_applications from anon,authenticated;

create or replace function public.close_pending_tournament_applications()
returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  if old.status in('draft','registration') and new.status not in('draft','registration') then
    update public.tournament_applications
    set status='rejected',updated_at=now(),reviewed_at=now(),reviewed_by=auth.uid()
    where tournament_id=new.id and status='pending';
  end if;
  return new;
end;
$$;

drop trigger if exists close_pending_tournament_applications_trigger on public.tournaments;
create trigger close_pending_tournament_applications_trigger
after update of status on public.tournaments
for each row execute function public.close_pending_tournament_applications();

-- Существующие участники считаются уже одобренными.
insert into public.tournament_applications(
  tournament_id,user_id,status,created_at,updated_at,reviewed_at,reviewed_by
)
select tp.tournament_id,tp.user_id,'approved',t.created_at,now(),now(),t.created_by
from public.tournament_players tp
join public.tournaments t on t.id=tp.tournament_id
where tp.status='active'
on conflict(tournament_id,user_id) do nothing;

create or replace function public.get_tournament_board(p_tournament_id uuid)
returns jsonb
language plpgsql security definer stable set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  viewer_id uuid:=auth.uid();
  viewer_is_admin boolean:=public.is_game_admin(auth.uid());
  result jsonb;
begin
  select * into t from public.tournaments where id=p_tournament_id;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status='draft' and not viewer_is_admin then
    raise exception 'Tournament not found';
  end if;

  select jsonb_build_object(
    'tournament',jsonb_build_object(
      'id',t.id,
      'name',t.name,
      'slug',t.slug,
      'status',t.status,
      'description',t.description,
      'max_players',t.max_players,
      'created_at',t.created_at,
      'updated_at',t.updated_at,
      'started_at',t.started_at,
      'finished_at',t.finished_at
    ),
    'my_application',(
      select jsonb_build_object(
        'status',ta.status,
        'created_at',ta.created_at,
        'updated_at',ta.updated_at,
        'reviewed_at',ta.reviewed_at
      )
      from public.tournament_applications ta
      where ta.tournament_id=t.id and ta.user_id=viewer_id
    ),
    'applications',case when viewer_is_admin then coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id',ta.user_id,
        'display_name',p.display_name,
        'avatar_emoji',p.avatar_emoji,
        'school_verified',p.school_verified,
        'status',ta.status,
        'created_at',ta.created_at,
        'updated_at',ta.updated_at,
        'reviewed_at',ta.reviewed_at
      ) order by
        case ta.status when 'pending' then 1 when 'approved' then 2 when 'rejected' then 3 else 4 end,
        ta.created_at
      )
      from public.tournament_applications ta
      join public.profiles p on p.user_id=ta.user_id
      where ta.tournament_id=t.id
    ),'[]'::jsonb) else '[]'::jsonb end,
    'players',coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id',tp.user_id,
        'display_name',p.display_name,
        'avatar_emoji',p.avatar_emoji,
        'seed',tp.seed,
        'status',tp.status
      ) order by tp.seed nulls last,lower(p.display_name))
      from public.tournament_players tp
      join public.profiles p on p.user_id=tp.user_id
      where tp.tournament_id=t.id
    ),'[]'::jsonb),
    'matches',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',tm.id,
        'round_no',tm.round_no,
        'position',tm.position,
        'player1_id',tm.player1_id,
        'player1_name',p1.display_name,
        'player1_avatar',p1.avatar_emoji,
        'player2_id',tm.player2_id,
        'player2_name',p2.display_name,
        'player2_avatar',p2.avatar_emoji,
        'winner_id',tm.winner_id,
        'game_id',tm.game_id,
        'status',tm.status,
        'result_reason',tm.result_reason,
        'next_match_id',tm.next_match_id,
        'next_slot',tm.next_slot,
        'resolved_at',tm.resolved_at
      ) order by tm.round_no,tm.position)
      from public.tournament_matches tm
      left join public.profiles p1 on p1.user_id=tm.player1_id
      left join public.profiles p2 on p2.user_id=tm.player2_id
      where tm.tournament_id=t.id
    ),'[]'::jsonb)
  ) into result;

  return result;
end;
$$;

create or replace function public.apply_to_tournament(p_tournament_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  t public.tournaments%rowtype;
  p public.profiles%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status<>'registration' then raise exception 'Tournament registration closed'; end if;

  select * into p from public.profiles where user_id=uid;
  if not found or p.account_type<>'registered' then raise exception 'Registered profile required'; end if;

  if exists(
    select 1 from public.tournament_applications
    where tournament_id=t.id and user_id=uid and status='approved'
  ) then return public.get_tournament_board(t.id); end if;

  insert into public.tournament_applications(
    tournament_id,user_id,status,created_at,updated_at,reviewed_at,reviewed_by
  ) values(t.id,uid,'pending',now(),now(),null,null)
  on conflict(tournament_id,user_id) do update
  set status='pending',updated_at=now(),reviewed_at=null,reviewed_by=null;

  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

create or replace function public.withdraw_tournament_application(p_tournament_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  t public.tournaments%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status<>'registration' then raise exception 'Tournament registration closed'; end if;
  if not exists(
    select 1 from public.tournament_applications
    where tournament_id=t.id and user_id=uid and status in('pending','approved')
  ) then raise exception 'Tournament application not found'; end if;

  delete from public.tournament_players
  where tournament_id=t.id and user_id=uid;

  update public.tournament_applications
  set status='withdrawn',updated_at=now(),reviewed_at=null,reviewed_by=null
  where tournament_id=t.id and user_id=uid;

  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

create or replace function public.admin_review_tournament_application(
  p_tournament_id uuid,
  p_user_id uuid,
  p_decision text
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  t public.tournaments%rowtype;
  p public.profiles%rowtype;
  current_count integer;
begin
  perform public.require_game_admin();
  if coalesce(p_decision,'') not in('approved','rejected') then raise exception 'Invalid application decision'; end if;

  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status not in('draft','registration') then raise exception 'Tournament registration closed'; end if;
  if not exists(
    select 1 from public.tournament_applications
    where tournament_id=t.id and user_id=p_user_id and status='pending'
  ) then raise exception 'Tournament application not pending'; end if;

  select * into p from public.profiles where user_id=p_user_id;
  if not found or p.account_type<>'registered' then raise exception 'Registered profile required'; end if;

  if p_decision='approved' then
    select count(*)::integer into current_count
    from public.tournament_players
    where tournament_id=t.id and status='active';
    if current_count>=t.max_players then raise exception 'Tournament is full'; end if;

    insert into public.tournament_players(tournament_id,user_id,status,seed)
    values(t.id,p_user_id,'active',null)
    on conflict(tournament_id,user_id)
    do update set status='active',seed=null;
  else
    delete from public.tournament_players
    where tournament_id=t.id and user_id=p_user_id;
  end if;

  update public.tournament_applications
  set status=p_decision,updated_at=now(),reviewed_at=now(),reviewed_by=uid
  where tournament_id=t.id and user_id=p_user_id;

  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

-- Старый метод остается совместимым, но добавить игрока без его заявки больше нельзя.
create or replace function public.admin_add_tournament_player(
  p_tournament_id uuid,
  p_user_id uuid
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  p public.profiles%rowtype;
  current_count integer;
begin
  perform public.require_game_admin();
  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status not in('draft','registration') then raise exception 'Tournament registration closed'; end if;

  select * into p from public.profiles where user_id=p_user_id;
  if not found or p.account_type<>'registered' then raise exception 'Registered profile required'; end if;
  if not exists(
    select 1 from public.tournament_applications
    where tournament_id=t.id and user_id=p_user_id and status in('pending','approved')
  ) then raise exception 'Tournament application required'; end if;

  select count(*)::integer into current_count
  from public.tournament_players
  where tournament_id=t.id and status='active';
  if current_count>=t.max_players and not exists(
    select 1 from public.tournament_players
    where tournament_id=t.id and user_id=p_user_id and status='active'
  ) then raise exception 'Tournament is full'; end if;

  insert into public.tournament_players(tournament_id,user_id,status,seed)
  values(t.id,p_user_id,'active',null)
  on conflict(tournament_id,user_id)
  do update set status='active',seed=null;

  update public.tournament_applications
  set status='approved',updated_at=now(),reviewed_at=now(),reviewed_by=auth.uid()
  where tournament_id=t.id and user_id=p_user_id;
  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

create or replace function public.admin_remove_tournament_player(
  p_tournament_id uuid,
  p_user_id uuid
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
begin
  perform public.require_game_admin();
  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status not in('draft','registration') then raise exception 'Tournament registration closed'; end if;

  delete from public.tournament_players
  where tournament_id=t.id and user_id=p_user_id;

  update public.tournament_applications
  set status='rejected',updated_at=now(),reviewed_at=now(),reviewed_by=auth.uid()
  where tournament_id=t.id and user_id=p_user_id;

  update public.tournaments set updated_at=now() where id=t.id;
  return public.get_tournament_board(t.id);
end;
$$;

revoke execute on function public.apply_to_tournament(uuid) from public,anon;
revoke execute on function public.withdraw_tournament_application(uuid) from public,anon;
revoke execute on function public.admin_review_tournament_application(uuid,uuid,text) from public,anon;
revoke execute on function public.admin_add_tournament_player(uuid,uuid) from public,anon;
revoke execute on function public.admin_remove_tournament_player(uuid,uuid) from public,anon;
revoke execute on function public.close_pending_tournament_applications() from public,anon,authenticated;

grant execute on function public.apply_to_tournament(uuid) to authenticated;
grant execute on function public.withdraw_tournament_application(uuid) to authenticated;
grant execute on function public.admin_review_tournament_application(uuid,uuid,text) to authenticated;
grant execute on function public.admin_add_tournament_player(uuid,uuid) to authenticated;
grant execute on function public.admin_remove_tournament_player(uuid,uuid) to authenticated;
