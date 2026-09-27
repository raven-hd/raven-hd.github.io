-- обновление 16: форматы турнира и настраиваемый лимит участников.
-- выполните после 014_admin_notifications.sql.

alter table public.tournaments
add column if not exists tournament_format text not null default 'knockout';

alter table public.tournaments drop constraint if exists tournaments_format_check;
alter table public.tournaments add constraint tournaments_format_check
check(tournament_format in('knockout','qualifiers_playoff'));

-- Старые турниры остаются обычным плей-офф.
update public.tournaments
set tournament_format='knockout'
where tournament_format is null;

drop function if exists public.list_public_tournaments();
create function public.list_public_tournaments()
returns table(
  id uuid,
  name text,
  slug text,
  status text,
  tournament_format text,
  max_players integer,
  participant_count bigint,
  round_count integer,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz
)
language sql security definer stable set search_path=''
as $$
  select t.id,t.name,t.slug,t.status,t.tournament_format,t.max_players,
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

drop function if exists public.admin_create_tournament(text,uuid,integer);
create or replace function public.admin_create_tournament(
  p_name text,
  p_request_id uuid,
  p_max_players integer,
  p_tournament_format text
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

  select * into t from public.tournaments
  where created_by=uid and create_request_id=p_request_id;
  if found then return to_jsonb(t); end if;

  insert into public.tournaments(
    name,slug,status,created_by,tournament_format,max_players,create_request_id,updated_at
  ) values(
    clean_name,'tournament-'||lower(substr(replace(gen_random_uuid()::text,'-',''),1,12)),
    'registration',uid,selected_format,limit_players,p_request_id,now()
  ) returning * into t;
  return to_jsonb(t);
end;
$$;

create or replace function public.admin_generate_tournament(p_tournament_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  participant_ids uuid[];
  participant_count integer;
  match_pos integer;
  participant_idx integer:=1;
  p1 uuid;
  p2 uuid;
begin
  perform public.require_game_admin();
  select * into t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'Tournament not found'; end if;
  if t.status not in('draft','registration') then raise exception 'Tournament already started'; end if;
  if t.tournament_format<>'knockout' then
    raise exception 'Qualifying stage setup required';
  end if;
  if exists(select 1 from public.tournament_matches where tournament_id=t.id and game_id is not null) then
    raise exception 'Tournament already has games';
  end if;

  select array_agg(tp.user_id order by random()),count(*)::integer
  into participant_ids,participant_count
  from public.tournament_players tp
  where tp.tournament_id=t.id and tp.status='active';

  if participant_count<2 then raise exception 'Tournament needs two players'; end if;
  if participant_count>t.max_players then raise exception 'Tournament is full'; end if;
  if mod(participant_count,2)=1 then raise exception 'Tournament needs even player count'; end if;

  delete from public.tournament_matches where tournament_id=t.id;
  update public.tournament_players set seed=null where tournament_id=t.id;

  for participant_idx in 1..participant_count loop
    update public.tournament_players
    set seed=participant_idx
    where tournament_id=t.id and user_id=participant_ids[participant_idx];
  end loop;

  participant_idx:=1;
  for match_pos in 1..(participant_count/2) loop
    p1:=participant_ids[participant_idx];
    participant_idx:=participant_idx+1;
    p2:=participant_ids[participant_idx];
    participant_idx:=participant_idx+1;
    insert into public.tournament_matches(
      tournament_id,round_no,position,player1_id,player2_id,status
    ) values(t.id,1,match_pos,p1,p2,'ready');
  end loop;

  update public.tournaments
  set status='active',started_at=now(),finished_at=null,updated_at=now()
  where id=t.id;

  return public.get_tournament_board(t.id);
end;
$$;

revoke execute on function public.list_public_tournaments() from public;
revoke execute on function public.get_tournament_board(uuid) from public;
revoke execute on function public.admin_create_tournament(text,uuid,integer,text) from public,anon;
revoke execute on function public.admin_generate_tournament(uuid) from public,anon;

grant execute on function public.list_public_tournaments() to anon,authenticated;
grant execute on function public.get_tournament_board(uuid) to anon,authenticated;
grant execute on function public.admin_create_tournament(text,uuid,integer,text) to authenticated;
grant execute on function public.admin_generate_tournament(uuid) to authenticated;
