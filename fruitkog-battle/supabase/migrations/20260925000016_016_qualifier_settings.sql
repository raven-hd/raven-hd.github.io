-- обновление 17: настройки квалификации и размера плей-офф.
-- выполните после 015_tournament_formats.sql.

alter table public.tournaments
add column if not exists qualifying_matches_per_player integer;

alter table public.tournaments
add column if not exists playoff_size integer;

alter table public.tournaments drop constraint if exists tournaments_qualifying_matches_check;
alter table public.tournaments add constraint tournaments_qualifying_matches_check
check(qualifying_matches_per_player is null or qualifying_matches_per_player between 1 and 10);

alter table public.tournaments drop constraint if exists tournaments_playoff_size_check;
alter table public.tournaments add constraint tournaments_playoff_size_check
check(playoff_size is null or playoff_size in(4,8,16));

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
  participant_count bigint,
  round_count integer,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz
)
language sql security definer stable set search_path=''
as $$
  select t.id,t.name,t.slug,t.status,t.tournament_format,t.max_players,
         t.qualifying_matches_per_player,t.playoff_size,
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

create or replace function public.admin_configure_tournament_qualifiers(
  p_tournament_id uuid,
  p_qualifying_matches integer,
  p_playoff_size integer
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
  if t.tournament_format<>'qualifiers_playoff' then raise exception 'Qualifying settings unavailable'; end if;
  if p_qualifying_matches is null or p_qualifying_matches not between 1 and 10 then
    raise exception 'Invalid qualifying match count';
  end if;
  if p_playoff_size is null or p_playoff_size not in(4,8,16) then
    raise exception 'Invalid playoff size';
  end if;
  if p_playoff_size>t.max_players then raise exception 'Playoff size exceeds tournament limit'; end if;

  update public.tournaments
  set qualifying_matches_per_player=p_qualifying_matches,
      playoff_size=p_playoff_size,
      updated_at=now()
  where id=t.id;

  return public.get_tournament_board(t.id);
end;
$$;

revoke execute on function public.list_public_tournaments() from public;
revoke execute on function public.get_tournament_board(uuid) from public;
revoke execute on function public.admin_configure_tournament_qualifiers(uuid,integer,integer) from public,anon;

grant execute on function public.list_public_tournaments() to anon,authenticated;
grant execute on function public.get_tournament_board(uuid) to anon,authenticated;
grant execute on function public.admin_configure_tournament_qualifiers(uuid,integer,integer) to authenticated;
