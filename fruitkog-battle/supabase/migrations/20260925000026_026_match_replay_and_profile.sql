-- обновление базы 26: личный архив матчей и безопасное открытие повторов.
-- выполните после 025_tournament_archive.sql.

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
  finished_at timestamptz
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
    g.finished_at
  from public.games g
  where auth.uid() is not null
    and auth.uid() in(g.player1_id,g.player2_id)
    and g.status='finished'
    and g.finished_at is not null
  order by g.finished_at desc
  limit 50;
$$;

create or replace function public.get_public_player_profile(p_user_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  viewer_id uuid:=auth.uid();
  result jsonb;
begin
  if viewer_id is null then raise exception 'Authentication required'; end if;

  select jsonb_build_object(
    'profile',jsonb_build_object(
      'user_id',p.user_id,
      'display_name',p.display_name,
      'avatar_emoji',p.avatar_emoji,
      'school_verified',p.school_verified,
      'rating',p.rating,
      'rated_games',p.rated_games,
      'rated_wins',p.rated_wins,
      'rated_losses',p.rated_losses,
      'created_at',p.created_at
    ),
    'matches',coalesce((
      select jsonb_agg(match_row.item order by match_row.finished_at desc)
      from (
        select
          g.finished_at,
          jsonb_build_object(
            'game_id',g.id,
            'opponent_id',case when g.player1_id=p.user_id then g.player2_id else g.player1_id end,
            'opponent_name',case when g.player1_id=p.user_id then g.player2_name else g.player1_name end,
            'result',case when g.winner_id=p.user_id then 'win' else 'loss' end,
            'game_type',g.game_type,
            'finish_reason',coalesce(g.finish_reason,'fleet_destroyed'),
            'surrendered_by',g.surrendered_by,
            'rating_applied',g.rating_applied or g.tournament_rating_applied,
            'rating_change',case
              when g.tournament_rating_applied and g.winner_id=p.user_id then g.tournament_rating_delta
              when g.tournament_rating_applied then -g.tournament_rating_delta
              when g.rating_applied and g.winner_id=p.user_id then g.rating_delta
              when g.rating_applied then -g.rating_delta
              else null
            end,
            'viewer_can_open',viewer_id in(g.player1_id,g.player2_id),
            'finished_at',g.finished_at
          ) as item
        from public.games g
        where g.status='finished'
          and g.finished_at is not null
          and p.user_id in(g.player1_id,g.player2_id)
        order by g.finished_at desc
        limit 50
      ) match_row
    ),'[]'::jsonb)
  ) into result
  from public.profiles p
  where p.user_id=p_user_id and p.account_type='registered';

  if result is null then raise exception 'Registered profile not found'; end if;
  return result;
end;
$$;

revoke execute on function public.list_match_history() from public,anon;
revoke execute on function public.get_public_player_profile(uuid) from public,anon;
grant execute on function public.list_match_history() to authenticated;
grant execute on function public.get_public_player_profile(uuid) to authenticated;

commit;
