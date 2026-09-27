-- Обновление 04: безопасная история завершенных матчей.
-- Выполните после 001_schema.sql, 002_game_lifecycle.sql и
-- 003_realtime_guests_and_final_fleets.sql.

create or replace function public.list_match_history()
returns table(
  player1_name text,
  player2_name text,
  winner_name text,
  game_type text,
  finished_at timestamptz
)
language sql
security definer
stable
set search_path=''
as $$
  select
    g.player1_name,
    g.player2_name,
    case
      when g.winner_id=g.player1_id then g.player1_name
      when g.winner_id=g.player2_id then g.player2_name
      else '—'
    end as winner_name,
    g.game_type,
    g.finished_at
  from public.games g
  where g.status='finished'
    and g.finished_at is not null
  order by g.finished_at desc
  limit 50;
$$;

revoke execute on function public.list_match_history() from public,anon;
grant execute on function public.list_match_history() to authenticated;
