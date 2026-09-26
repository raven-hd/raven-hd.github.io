-- обновление 07: один активный матч на пару и добровольная сдача.
-- выполните после 005_slow_connection_safety.sql.

alter table public.games
add column if not exists finish_reason text,
add column if not exists surrendered_by uuid references auth.users(id);

update public.games
set finish_reason='fleet_destroyed'
where status='finished' and finish_reason is null;

alter table public.games drop constraint if exists games_finish_reason_check;
alter table public.games add constraint games_finish_reason_check
check(finish_reason is null or finish_reason in('fleet_destroyed','surrender'));

create index if not exists games_active_pair_lookup_idx
on public.games(player1_id,player2_id,status)
where player2_id is not null;

-- Обычная победа через последний выстрел автоматически получает причину.
create or replace function public.set_default_finish_reason()
returns trigger
language plpgsql
set search_path=''
as $$
begin
  if new.status='finished'
     and old.status is distinct from 'finished'
     and new.finish_reason is null then
    new.finish_reason:='fleet_destroyed';
  end if;
  return new;
end;
$$;

drop trigger if exists games_default_finish_reason on public.games;
create trigger games_default_finish_reason
before update on public.games
for each row execute function public.set_default_finish_reason();

-- На текущем этапе старые матчи чистит администратор вручную.
-- Функция остается, чтобы установленный клиент и прежние RPC не ломались,
-- но новые автопаузы через 72 часа больше не создаются.
create or replace function public.pause_expired_games()
returns integer
language sql security definer set search_path=''
as $$
  select 0;
$$;

revoke execute on function public.pause_expired_games() from public,anon,authenticated;

create or replace function public.join_public_game(p_game_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  p public.profiles%rowtype;
  g public.games%rowtype;
  existing_game_id uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into p from public.profiles where user_id=uid;
  if not found then raise exception 'Profile required'; end if;

  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.player1_id=uid then raise exception 'Cannot join your own game'; end if;
  if g.player2_id=uid and g.status in('placing','playing','paused') then
    return to_jsonb(g);
  end if;
  if g.visibility<>'public' or g.status<>'waiting' or g.player2_id is not null then
    raise exception 'Game is full';
  end if;

  -- Одинаковая блокировка двух профилей защищает даже от двух
  -- одновременных попыток присоединиться к разным комнатам одной пары.
  perform locked.user_id
  from public.profiles locked
  where locked.user_id in(uid,g.player1_id)
  order by locked.user_id
  for update;

  select active_game.id into existing_game_id
  from public.games active_game
  where active_game.id<>g.id
    and active_game.status in('placing','playing','paused')
    and (
      (active_game.player1_id=g.player1_id and active_game.player2_id=uid)
      or
      (active_game.player1_id=uid and active_game.player2_id=g.player1_id)
    )
  order by active_game.updated_at desc
  limit 1;

  if existing_game_id is not null then
    raise exception 'Pair already has active game: %',existing_game_id;
  end if;

  update public.games
  set player2_id=uid,player2_name=p.display_name,status='placing',
      player2_action_at=now(),updated_at=now()
  where public.games.id=g.id returning * into g;
  return to_jsonb(g);
end;
$$;

create or replace function public.surrender_game(p_game_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  g public.games%rowtype;
  opponent_id uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;

  -- Повтор того же запроса при медленном соединении безопасен.
  if g.status='finished'
     and g.finish_reason='surrender'
     and g.surrendered_by=uid then
    return to_jsonb(g);
  end if;

  if uid=g.player1_id then opponent_id:=g.player2_id;
  elsif uid=g.player2_id then opponent_id:=g.player1_id;
  else raise exception 'Not a participant';
  end if;

  if g.status<>'playing' then raise exception 'Game cannot be surrendered'; end if;
  if opponent_id is null then raise exception 'Opponent missing'; end if;

  update public.games
  set status='finished',winner_id=opponent_id,current_turn=null,
      turn_started_at=null,paused_at=null,pause_reason=null,
      finish_reason='surrender',surrendered_by=uid,
      player1_action_at=case when uid=g.player1_id then now() else player1_action_at end,
      player2_action_at=case when uid=g.player2_id then now() else player2_action_at end,
      finished_at=now(),updated_at=now()
  where id=g.id
  returning * into g;

  return to_jsonb(g);
end;
$$;

drop function if exists public.list_match_history();
create function public.list_match_history()
returns table(
  player1_name text,
  player2_name text,
  winner_name text,
  game_type text,
  finish_reason text,
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
    coalesce(g.finish_reason,'fleet_destroyed') as finish_reason,
    g.finished_at
  from public.games g
  where g.status='finished'
    and g.finished_at is not null
  order by g.finished_at desc
  limit 50;
$$;

revoke execute on function public.join_public_game(uuid) from public,anon;
revoke execute on function public.surrender_game(uuid) from public,anon;
revoke execute on function public.list_match_history() from public,anon;

grant execute on function public.join_public_game(uuid) to authenticated;
grant execute on function public.surrender_game(uuid) to authenticated;
grant execute on function public.list_match_history() to authenticated;
