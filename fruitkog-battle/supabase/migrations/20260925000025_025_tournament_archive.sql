-- 025_tournament_archive.sql
-- архив завершенных турниров без удаления таблиц, сеток и матчей

alter table public.tournaments
add column if not exists archived_at timestamptz;

create index if not exists tournaments_archived_at_idx
on public.tournaments(archived_at desc)
where archived_at is not null;

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
  qualifying_started_at timestamptz,
  participant_count bigint,
  round_count integer,
  winner_id uuid,
  winner_name text,
  rating_applied boolean,
  rating_applied_at timestamptz,
  archived_at timestamptz,
  created_at timestamptz,
  started_at timestamptz,
  finished_at timestamptz
)
language sql security definer stable set search_path=''
as $$
  select
    t.id,t.name,t.slug,t.status,t.tournament_format,t.max_players,
    t.qualifying_matches_per_player,t.playoff_size,t.registration_deadline,
    t.qualifying_started_at,
    (select count(*) from public.tournament_players tp
      where tp.tournament_id=t.id and tp.status='active') as participant_count,
    coalesce((select max(tm.round_no) from public.tournament_matches tm
      where tm.tournament_id=t.id and tm.stage='playoff'),0)::integer as round_count,
    champion.winner_id,
    champion.winner_name,
    t.rating_applied,
    t.rating_applied_at,
    t.archived_at,
    t.created_at,t.started_at,t.finished_at
  from public.tournaments t
  left join lateral(
    select tm.winner_id,p.display_name as winner_name
    from public.tournament_matches tm
    left join public.profiles p on p.user_id=tm.winner_id
    where tm.tournament_id=t.id
      and tm.stage='playoff'
      and tm.next_match_id is null
      and tm.winner_id is not null
    order by tm.round_no desc,tm.position
    limit 1
  ) champion on true
  where t.status<>'draft' or public.is_game_admin(auth.uid())
  order by
    case when t.archived_at is not null then 2 else 1 end,
    case t.status when 'active' then 1 when 'registration' then 2 when 'finished' then 3 when 'draft' then 4 else 5 end,
    coalesce(t.archived_at,t.finished_at,t.created_at) desc;
$$;

create or replace function public.admin_set_tournament_archived(
  p_tournament_id uuid,
  p_archived boolean default true
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  tournament_status text;
begin
  if not public.is_game_admin(auth.uid()) then raise exception 'Admin access required'; end if;

  select status into tournament_status
  from public.tournaments
  where id=p_tournament_id
  for update;

  if tournament_status is null then raise exception 'Tournament not found'; end if;
  if tournament_status<>'finished' then raise exception 'Only finished tournament can be archived'; end if;

  update public.tournaments
  set archived_at=case when p_archived then coalesce(archived_at,now()) else null end,
      updated_at=now()
  where id=p_tournament_id;

  return public.get_tournament_board(p_tournament_id);
end;
$$;

revoke execute on function public.list_public_tournaments() from public;
revoke execute on function public.admin_set_tournament_archived(uuid,boolean) from public,anon;
grant execute on function public.list_public_tournaments() to anon,authenticated;
grant execute on function public.admin_set_tournament_archived(uuid,boolean) to authenticated;
