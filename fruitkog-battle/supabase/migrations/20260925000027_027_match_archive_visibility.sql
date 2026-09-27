-- обновление базы 27: общий архив матчей с закрытым просмотром чужих игр.
-- выполните после 026_match_replay_and_profile.sql.

begin;

drop function if exists public.list_match_history();
create function public.list_match_history()
returns table(
  game_id uuid,
  player1_name text,
  player2_name text,
  winner_name text,
  game_type text,
  finish_reason text,
  rating_applied boolean,
  rating_delta integer,
  rating_skip_reason text,
  tournament_rating_applied boolean,
  tournament_rating_delta integer,
  finished_at timestamptz,
  viewer_can_open boolean
)
language sql
security definer
stable
set search_path=''
as $$
  select
    g.id,
    g.player1_name,
    g.player2_name,
    case
      when g.winner_id=g.player1_id then g.player1_name
      when g.winner_id=g.player2_id then g.player2_name
      else '—'
    end,
    g.game_type,
    coalesce(g.finish_reason,'fleet_destroyed'),
    g.rating_applied,
    g.rating_delta,
    g.rating_skip_reason,
    g.tournament_rating_applied,
    g.tournament_rating_delta,
    g.finished_at,
    coalesce(auth.uid() in(g.player1_id,g.player2_id),false)
  from public.games g
  where auth.uid() is not null
    and g.status='finished'
    and g.finished_at is not null
  order by g.finished_at desc;
$$;

revoke execute on function public.list_match_history() from public,anon;
grant execute on function public.list_match_history() to authenticated;

commit;
