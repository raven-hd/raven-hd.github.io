-- обновление 129: основа будущих наград и турнирная статистика профиля.
-- ветка fruitkog-rewards; не применять на основном сайте до завершения текущего турнира.

create table if not exists public.fruitkog_player_rewards (
  user_id uuid primary key references public.profiles(user_id) on delete cascade,
  mushroom_skin_unlocked boolean not null default false,
  auto_miss_uses integer not null default 0 check (auto_miss_uses >= 0),
  square_ship_uses integer not null default 0 check (square_ship_uses >= 0),
  selected_ship_skin text not null default 'vegetable'
    check (selected_ship_skin in ('vegetable','mushroom')),
  updated_at timestamptz not null default now()
);

alter table public.fruitkog_player_rewards enable row level security;

-- таблица наград остается внутренней: браузеру не выдаются прямые права
-- на чтение или изменение. игровые RPC будут добавлены вместе с механикой
-- списания бонусов, чтобы счетчики нельзя было подкручивать из клиента.
revoke all on public.fruitkog_player_rewards from anon,authenticated;

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
      'created_at',p.created_at,
      'tournament_count',(
        select count(*)::integer
        from public.tournament_players tp
        join public.tournaments t on t.id=tp.tournament_id
        where tp.user_id=p.user_id
          and tp.status='active'
          and t.status='finished'
      )
    ),
    'tournaments',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',t.id,
          'name',t.name,
          'finished_at',t.finished_at,
          'result',
            case
              when exists(
                select 1
                from public.tournament_matches tm
                where tm.tournament_id=t.id
                  and tm.stage='playoff'
                  and tm.round_no=rounds.final_round
                  and tm.winner_id=p.user_id
              ) then 'I место'
              when exists(
                select 1
                from public.tournament_matches tm
                where tm.tournament_id=t.id
                  and tm.stage='playoff'
                  and tm.round_no=rounds.final_round
                  and p.user_id in(tm.player1_id,tm.player2_id)
                  and tm.winner_id is not null
                  and tm.winner_id<>p.user_id
              ) then 'II место'
              when rounds.final_round>1 and exists(
                select 1
                from public.tournament_matches tm
                where tm.tournament_id=t.id
                  and tm.stage='playoff'
                  and tm.round_no=rounds.final_round-1
                  and p.user_id in(tm.player1_id,tm.player2_id)
                  and tm.winner_id is not null
                  and tm.winner_id<>p.user_id
              ) then 'полуфинал'
              when exists(
                select 1
                from public.tournament_matches tm
                where tm.tournament_id=t.id
                  and tm.stage='playoff'
                  and p.user_id in(tm.player1_id,tm.player2_id)
              ) then 'плей-офф'
              else 'участник'
            end
        )
        order by t.finished_at desc nulls last,t.created_at desc
      )
      from public.tournament_players tp
      join public.tournaments t on t.id=tp.tournament_id
      cross join lateral (
        select coalesce(max(tm.round_no),0)::integer as final_round
        from public.tournament_matches tm
        where tm.tournament_id=t.id and tm.stage='playoff'
      ) rounds
      where tp.user_id=p.user_id
        and tp.status='active'
        and t.status='finished'
    ),'[]'::jsonb),
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
