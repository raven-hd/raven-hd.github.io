-- обновление 18: срок регистрации и автоматический выбор актуального турнира.
-- выполните после 016_qualifier_settings.sql.

alter table public.tournaments
add column if not exists registration_deadline timestamptz;

drop function if exists public.list_public_tournaments();
create function public.list_public_tournaments()
returns table(
  id uuid,
  name text,
  slug text,
  status text,
  tournament_format text,
  max_players integer,
  qualifying_matches_per_player integer,
  playoff_size integer,
  registration_deadline timestamptz,
  participant_count bigint,
  round_count integer,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz
)
language sql security definer stable set search_path=''
as $$
  select t.id,t.name,t.slug,t.status,t.tournament_format,t.max_players,
         t.qualifying_matches_per_player,t.playoff_size,t.registration_deadline,
         count(distinct tp.user_id) filter(where tp.status='active') as participant_count,
         coalesce(max(tm.round_no),0)::integer as round_count,
         t.created_at,t.started_at,t.finished_at
  from public.tournaments t
  left join public.tournament_players tp on tp.tournament_id=t.id
  left join public.tournament_matches tm on tm.tournament_id=t.id
  where t.status<>'draft' or public.is_game_admin(auth.uid())
  group by t.id
  order by
    case t.status when 'active' then 1 when 'registration' then 2 when 'draft' then 3 when 'finished' then 4 else 5 end,
    t.created_at desc;
$$;

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
      'tournament_format',t.tournament_format,
      'description',t.description,
      'max_players',t.max_players,
      'qualifying_matches_per_player',t.qualifying_matches_per_player,
      'playoff_size',t.playoff_size,
      'registration_deadline',t.registration_deadline,
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

drop function if exists public.admin_create_tournament(text,uuid,integer,text);
create or replace function public.admin_create_tournament(
  p_name text,
  p_request_id uuid,
  p_max_players integer,
  p_tournament_format text,
  p_registration_deadline timestamptz
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  clean_name text:=left(trim(regexp_replace(coalesce(p_name,''),'\s+',' ','g')),80);
  limit_players integer:=coalesce(p_max_players,32);
  selected_format text:=coalesce(p_tournament_format,'knockout');
  t public.tournaments%rowtype;
begin
  perform public.require_game_admin();
  if char_length(clean_name)<3 then raise exception 'Tournament name required'; end if;
  if p_request_id is null then raise exception 'Request id required'; end if;
  if limit_players not between 2 and 128 then raise exception 'Invalid tournament size'; end if;
  if selected_format not in('knockout','qualifiers_playoff') then raise exception 'Invalid tournament format'; end if;
  if p_registration_deadline is null or p_registration_deadline<=now() then
    raise exception 'Invalid registration deadline';
  end if;

  select * into t from public.tournaments
  where created_by=uid and create_request_id=p_request_id;
  if found then return to_jsonb(t); end if;

  insert into public.tournaments(
    name,slug,status,created_by,tournament_format,max_players,registration_deadline,create_request_id,updated_at
  ) values(
    clean_name,'tournament-'||lower(substr(replace(gen_random_uuid()::text,'-',''),1,12)),
    'registration',uid,selected_format,limit_players,p_registration_deadline,p_request_id,now()
  ) returning * into t;
  return to_jsonb(t);
end;
$$;

create or replace function public.admin_set_tournament_registration_deadline(
  p_tournament_id uuid,
  p_registration_deadline timestamptz
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
  if t.status not in('draft','registration') then raise exception 'Tournament already started'; end if;
  if p_registration_deadline is null or p_registration_deadline<=now() then
    raise exception 'Invalid registration deadline';
  end if;

  update public.tournaments
  set registration_deadline=p_registration_deadline,updated_at=now()
  where id=t.id;
  return public.get_tournament_board(t.id);
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
  if t.status<>'registration' or (t.registration_deadline is not null and t.registration_deadline<=now()) then
    raise exception 'Tournament registration closed';
  end if;

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
  if t.status<>'registration' or (t.registration_deadline is not null and t.registration_deadline<=now()) then
    raise exception 'Tournament registration closed';
  end if;
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

revoke execute on function public.list_public_tournaments() from public;
revoke execute on function public.get_tournament_board(uuid) from public;
revoke execute on function public.admin_create_tournament(text,uuid,integer,text,timestamptz) from public,anon;
revoke execute on function public.admin_set_tournament_registration_deadline(uuid,timestamptz) from public,anon;
revoke execute on function public.apply_to_tournament(uuid) from public,anon;
revoke execute on function public.withdraw_tournament_application(uuid) from public,anon;

grant execute on function public.list_public_tournaments() to anon,authenticated;
grant execute on function public.get_tournament_board(uuid) to anon,authenticated;
grant execute on function public.admin_create_tournament(text,uuid,integer,text,timestamptz) to authenticated;
grant execute on function public.admin_set_tournament_registration_deadline(uuid,timestamptz) to authenticated;
grant execute on function public.apply_to_tournament(uuid) to authenticated;
grant execute on function public.withdraw_tournament_application(uuid) to authenticated;
