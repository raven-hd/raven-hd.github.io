-- обновление 10: публичный профиль игрока и личная история матчей.
-- выполните после 008_admin_panel.sql.

create or replace function public.get_public_player_profile(p_user_id uuid)
returns jsonb
language plpgsql security definer stable set search_path=''
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
            'rating_applied',g.rating_applied,
            'rating_change',case
              when not g.rating_applied then null
              when g.winner_id=p.user_id then g.rating_delta
              else -g.rating_delta
            end,
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

revoke execute on function public.get_public_player_profile(uuid) from public,anon;
grant execute on function public.get_public_player_profile(uuid) to authenticated;
