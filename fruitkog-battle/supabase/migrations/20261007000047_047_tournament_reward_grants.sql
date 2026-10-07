-- обновление 134: идемпотентная выдача игровых наград по итогам Fruitkog.
-- Выдает только внутриигровые награды. Галлеоны и трофеи остаются вне игры.
-- Функция пока закрыта от браузера: откроем админскую кнопку только после финальной проверки.

begin;

create table if not exists public.fruitkog_reward_grants (
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  reward_tier text not null check (reward_tier in ('first','second','semifinal','playoff','participant')),
  mushroom_skin_unlocked boolean not null default true,
  auto_miss_uses integer not null default 0 check (auto_miss_uses>=0),
  square_ship_uses integer not null default 0 check (square_ship_uses>=0),
  granted_at timestamptz not null default now(),
  primary key (tournament_id,user_id)
);

alter table public.fruitkog_reward_grants enable row level security;
revoke all on public.fruitkog_reward_grants from anon,authenticated;

create or replace function public.admin_grant_fruitkog_tournament_rewards(p_tournament_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  t public.tournaments%rowtype;
  final_round integer;
  final_match public.tournament_matches%rowtype;
  champion_id uuid;
  runner_up_id uuid;
  player_rec record;
  tier text;
  auto_uses integer;
  square_uses integer;
  inserted_count integer:=0;
  row_inserted integer:=0;
begin
  perform public.require_game_admin();

  select * into t
  from public.tournaments
  where id=p_tournament_id
  for update;

  if not found then raise exception 'Tournament not found'; end if;
  if t.status<>'finished' then raise exception 'Tournament is not finished'; end if;

  select coalesce(max(tm.round_no),0)::integer
  into final_round
  from public.tournament_matches tm
  where tm.tournament_id=t.id and tm.stage='playoff';

  if final_round<1 then raise exception 'Tournament playoff not found'; end if;

  select * into final_match
  from public.tournament_matches tm
  where tm.tournament_id=t.id
    and tm.stage='playoff'
    and tm.round_no=final_round
    and tm.winner_id is not null
  order by tm.position
  limit 1;

  if not found then raise exception 'Tournament winner not found'; end if;

  champion_id:=final_match.winner_id;
  runner_up_id:=case
    when final_match.player1_id=champion_id then final_match.player2_id
    else final_match.player1_id
  end;

  for player_rec in
    select tp.user_id
    from public.tournament_players tp
    join public.profiles p on p.user_id=tp.user_id and p.account_type='registered'
    where tp.tournament_id=t.id and tp.status='active'
    order by tp.user_id
  loop
    if player_rec.user_id=champion_id then
      tier:='first'; auto_uses:=30; square_uses:=15;
    elsif player_rec.user_id=runner_up_id then
      tier:='second'; auto_uses:=20; square_uses:=10;
    elsif final_round>1 and exists(
      select 1
      from public.tournament_matches tm
      where tm.tournament_id=t.id
        and tm.stage='playoff'
        and tm.round_no=final_round-1
        and player_rec.user_id in(tm.player1_id,tm.player2_id)
        and tm.winner_id is not null
        and tm.winner_id<>player_rec.user_id
    ) then
      tier:='semifinal'; auto_uses:=10; square_uses:=5;
    elsif exists(
      select 1
      from public.tournament_matches tm
      where tm.tournament_id=t.id
        and tm.stage='playoff'
        and player_rec.user_id in(tm.player1_id,tm.player2_id)
    ) then
      tier:='playoff'; auto_uses:=5; square_uses:=5;
    else
      tier:='participant'; auto_uses:=0; square_uses:=0;
    end if;

    insert into public.fruitkog_reward_grants(
      tournament_id,user_id,reward_tier,mushroom_skin_unlocked,
      auto_miss_uses,square_ship_uses,granted_at
    )
    values(
      t.id,player_rec.user_id,tier,true,auto_uses,square_uses,now()
    )
    on conflict(tournament_id,user_id) do nothing;

    get diagnostics row_inserted = row_count;

    if row_inserted=1 then
      inserted_count:=inserted_count+1;

      insert into public.fruitkog_player_rewards(
        user_id,mushroom_skin_unlocked,auto_miss_uses,square_ship_uses,updated_at
      )
      values(
        player_rec.user_id,true,auto_uses,square_uses,now()
      )
      on conflict(user_id) do update
      set mushroom_skin_unlocked=true,
          auto_miss_uses=public.fruitkog_player_rewards.auto_miss_uses+excluded.auto_miss_uses,
          square_ship_uses=public.fruitkog_player_rewards.square_ship_uses+excluded.square_ship_uses,
          updated_at=now();
    end if;
  end loop;

  return jsonb_build_object(
    'tournament_id',t.id,
    'new_grants',inserted_count,
    'total_grants',(
      select count(*)::integer
      from public.fruitkog_reward_grants g
      where g.tournament_id=t.id
    ),
    'tiers',(
      select coalesce(jsonb_object_agg(x.reward_tier,x.cnt),'{}'::jsonb)
      from (
        select g.reward_tier,count(*)::integer as cnt
        from public.fruitkog_reward_grants g
        where g.tournament_id=t.id
        group by g.reward_tier
      ) x
    )
  );
end;
$$;

revoke execute on function public.admin_grant_fruitkog_tournament_rewards(uuid)
from public,anon,authenticated;

commit;
