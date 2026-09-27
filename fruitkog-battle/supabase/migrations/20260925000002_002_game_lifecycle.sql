-- Общий игровой зал, параллельные открытые матчи, наблюдение и таймер бездействия.
-- Выполните этот файл после 001_schema.sql.

alter table public.games drop constraint if exists games_status_check;
alter table public.games add constraint games_status_check
check(status in ('waiting','placing','playing','paused','finished','cancelled'));

-- Приватные комнаты удалены из MVP. Существующие тестовые комнаты становятся открытыми.
update public.games set visibility='public' where visibility<>'public';
alter table public.games drop constraint if exists games_visibility_check;
alter table public.games add constraint games_visibility_check check(visibility='public');

alter table public.games add column if not exists player1_action_at timestamptz;
alter table public.games add column if not exists player2_action_at timestamptz;
alter table public.games add column if not exists turn_started_at timestamptz;
alter table public.games add column if not exists paused_at timestamptz;
alter table public.games add column if not exists pause_reason text;

-- Существующие тестовые матчи получают новый полный срок после установки обновления.
update public.games
set player1_action_at=coalesce(player1_action_at,now()),
    player2_action_at=case when player2_id is null then null else coalesce(player2_action_at,now()) end,
    turn_started_at=case when status='playing' then coalesce(turn_started_at,now()) else turn_started_at end;

create or replace function public.is_game_admin(p_user_id uuid)
returns boolean
language sql security definer stable set search_path=''
as $$
  select exists(
    select 1 from public.profiles
    where user_id=p_user_id and is_admin=true
  );
$$;

revoke execute on function public.is_game_admin(uuid) from public,anon;
grant execute on function public.is_game_admin(uuid) to authenticated;

drop policy if exists "games readable" on public.games;
create policy "games readable" on public.games for select to authenticated
using(
  auth.uid() in(player1_id,player2_id)
  or public.is_game_admin(auth.uid())
  or status in('waiting','playing','paused','finished')
);

drop policy if exists "own fleet readable" on public.fleets;
create policy "own fleet readable" on public.fleets for select to authenticated
using(
  auth.uid()=owner_id
  or public.is_game_admin(auth.uid())
  or exists(
    select 1 from public.games g
    where g.id=fleets.game_id and g.status='finished'
  )
);

drop policy if exists "shots readable" on public.shots;
create policy "shots readable" on public.shots for select to authenticated
using(
  public.is_game_admin(auth.uid())
  or exists(
    select 1 from public.games g
    where g.id=shots.game_id
      and (
        auth.uid() in(g.player1_id,g.player2_id)
        or g.status in('playing','paused','finished')
      )
  )
);

create or replace function public.pause_expired_games()
returns integer
language plpgsql security definer set search_path=''
as $$
declare affected integer:=0;step_count integer:=0;
begin
  update public.games
  set status='paused',paused_at=now(),pause_reason='placement_timeout',updated_at=now()
  where status='placing'
    and (
      (not player1_ready and coalesce(player1_action_at,updated_at)<=now()-interval '72 hours')
      or
      (not player2_ready and coalesce(player2_action_at,updated_at)<=now()-interval '72 hours')
    );
  get diagnostics step_count=row_count;
  affected:=affected+step_count;

  update public.games
  set status='paused',paused_at=now(),pause_reason='turn_timeout',updated_at=now()
  where status='playing'
    and coalesce(turn_started_at,updated_at)<=now()-interval '72 hours';
  get diagnostics step_count=row_count;
  affected:=affected+step_count;

  return affected;
end;
$$;

revoke execute on function public.pause_expired_games() from public,anon,authenticated;

create or replace function public.list_active_games()
returns table(
  id uuid,
  code text,
  game_type text,
  visibility text,
  status text,
  player1_id uuid,
  player1_name text,
  player2_id uuid,
  player2_name text,
  player1_ready boolean,
  player2_ready boolean,
  current_turn uuid,
  turn_started_at timestamptz,
  paused_at timestamptz,
  pause_reason text,
  updated_at timestamptz,
  is_participant boolean
)
language plpgsql security definer set search_path=''
as $$
declare uid uuid:=auth.uid();
begin
  if uid is null then raise exception 'Authentication required'; end if;
  perform public.pause_expired_games();

  return query
  select
    g.id,
    case when uid in(g.player1_id,g.player2_id) then g.code else null end,
    g.game_type,
    g.visibility,
    g.status,
    g.player1_id,
    g.player1_name,
    g.player2_id,
    g.player2_name,
    g.player1_ready,
    g.player2_ready,
    g.current_turn,
    g.turn_started_at,
    g.paused_at,
    g.pause_reason,
    g.updated_at,
    uid in(g.player1_id,g.player2_id)
  from public.games g
  where g.status in('waiting','placing','playing','paused')
  order by
    case g.status when 'waiting' then 1 when 'playing' then 2 when 'placing' then 3 else 4 end,
    g.updated_at desc;
end;
$$;

drop function if exists public.create_game(text);
drop function if exists public.join_game_by_code(text);

create or replace function public.create_game()
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare uid uuid:=auth.uid();p public.profiles%rowtype;g public.games%rowtype;new_code text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into p from public.profiles where user_id=uid;
  if not found then raise exception 'Profile required'; end if;

  loop
    new_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
    exit when not exists(select 1 from public.games where code=new_code);
  end loop;

  insert into public.games(code,game_type,visibility,player1_id,player1_name,player1_action_at)
  values(new_code,'casual','public',uid,p.display_name,now()) returning * into g;
  return to_jsonb(g);
end;
$$;

create or replace function public.join_public_game(p_game_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare uid uuid:=auth.uid();p public.profiles%rowtype;g public.games%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into p from public.profiles where user_id=uid;
  if not found then raise exception 'Profile required'; end if;

  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.player1_id=uid then raise exception 'Cannot join your own game'; end if;
  if g.visibility<>'public' or g.status<>'waiting' or g.player2_id is not null then raise exception 'Game is full'; end if;

  update public.games
  set player2_id=uid,player2_name=p.display_name,status='placing',
      player2_action_at=now(),updated_at=now()
  where public.games.id=g.id returning * into g;
  return to_jsonb(g);
end;
$$;

create or replace function public.cancel_game(p_game_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare uid uuid:=auth.uid();g public.games%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.player1_id<>uid then raise exception 'Only the room creator can close it'; end if;
  if g.status not in('waiting','placing') then raise exception 'Game can no longer be closed'; end if;

  update public.games set status='cancelled',current_turn=null,updated_at=now()
  where public.games.id=g.id returning * into g;
  return to_jsonb(g);
end;
$$;

create or replace function public.leave_game(p_game_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare uid uuid:=auth.uid();g public.games%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.player2_id<>uid then raise exception 'Only the second player can leave'; end if;
  if g.status<>'placing' then raise exception 'Game can no longer be left'; end if;

  delete from public.fleets where game_id=g.id;
  update public.games
  set player2_id=null,player2_name=null,player1_ready=false,player2_ready=false,
      player1_action_at=now(),player2_action_at=null,status='waiting',current_turn=null,updated_at=now()
  where public.games.id=g.id returning * into g;
  return to_jsonb(g);
end;
$$;

create or replace function public.ready_with_fleet(p_game_id uuid,p_ships jsonb)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare uid uuid:=auth.uid();g public.games%rowtype;first_turn uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  perform public.pause_expired_games();
  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;
  if uid not in(g.player1_id,g.player2_id) then raise exception 'Not a participant'; end if;
  if g.status='paused' then raise exception 'Game is paused'; end if;
  if g.player2_id is null or g.status<>'placing' then raise exception 'Game is not ready'; end if;
  if (uid=g.player1_id and g.player1_ready) or (uid=g.player2_id and g.player2_ready) then raise exception 'Fleet already locked'; end if;

  perform public.assert_valid_fleet(p_ships);
  insert into public.fleets(game_id,owner_id,ships) values(g.id,uid,p_ships)
  on conflict(game_id,owner_id) do update set ships=excluded.ships,created_at=now();

  if uid=g.player1_id then
    update public.games set player1_ready=true,player1_action_at=now(),updated_at=now() where id=g.id;
  else
    update public.games set player2_ready=true,player2_action_at=now(),updated_at=now() where id=g.id;
  end if;

  select * into g from public.games where id=p_game_id;
  if g.player1_ready and g.player2_ready then
    first_turn:=case when random()<0.5 then g.player1_id else g.player2_id end;
    update public.games
    set status='playing',current_turn=first_turn,turn_started_at=now(),updated_at=now()
    where id=g.id returning * into g;
  end if;
  return to_jsonb(g);
end;
$$;

create or replace function public.shoot(p_game_id uuid,p_cell text)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  uid uuid:=auth.uid();g public.games%rowtype;target_uid uuid;cell_text text:=upper(trim(p_cell));
  fleet_json jsonb;ship_rec record;hit_ship jsonb:=null;ship_len int:=0;
  prior_hits_on_ship int:=0;prior_total_hits int:=0;total_fleet_cells int:=0;result_text text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if cell_text !~ '^[A-J](10|[1-9])$' then raise exception 'Invalid cell'; end if;
  perform public.pause_expired_games();

  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.status='paused' then raise exception 'Game is paused'; end if;
  if g.status<>'playing' then raise exception 'Game is not active'; end if;
  if g.current_turn<>uid then raise exception 'Not your turn'; end if;

  if uid=g.player1_id then target_uid:=g.player2_id;
  elsif uid=g.player2_id then target_uid:=g.player1_id;
  else raise exception 'Not a participant'; end if;

  if exists(select 1 from public.shots where game_id=g.id and shooter_id=uid and cell=cell_text) then raise exception 'Cell already fired'; end if;

  select ships into fleet_json from public.fleets where game_id=g.id and owner_id=target_uid;
  if fleet_json is null then raise exception 'Target fleet missing'; end if;

  for ship_rec in select value as ship from jsonb_array_elements(fleet_json) loop
    if exists(select 1 from jsonb_array_elements_text(ship_rec.ship->'cells') c(value) where upper(c.value)=cell_text) then
      hit_ship:=ship_rec.ship; exit;
    end if;
  end loop;

  if hit_ship is null then result_text:='miss';
  else
    ship_len:=jsonb_array_length(hit_ship->'cells');

    select count(*) into prior_hits_on_ship
    from public.shots s
    where s.game_id=g.id and s.shooter_id=uid and s.target_id=target_uid and s.result in('hit','sunk','win')
      and exists(select 1 from jsonb_array_elements_text(hit_ship->'cells') c(value) where upper(c.value)=s.cell);

    select count(*) into prior_total_hits
    from public.shots s
    where s.game_id=g.id and s.shooter_id=uid and s.target_id=target_uid and s.result in('hit','sunk','win');

    select coalesce(sum(jsonb_array_length(s.value->'cells')),0)::int into total_fleet_cells
    from jsonb_array_elements(fleet_json)s(value);

    if prior_total_hits+1>=total_fleet_cells then result_text:='win';
    elsif prior_hits_on_ship+1>=ship_len then result_text:='sunk';
    else result_text:='hit'; end if;
  end if;

  insert into public.shots(game_id,shooter_id,target_id,cell,result)
  values(g.id,uid,target_uid,cell_text,result_text);

  if result_text='miss' then
    update public.games set current_turn=target_uid,turn_started_at=now(),updated_at=now() where id=g.id;
  elsif result_text='win' then
    update public.games set status='finished',winner_id=uid,current_turn=null,turn_started_at=null,
      finished_at=now(),updated_at=now() where id=g.id;
  else
    update public.games set current_turn=uid,turn_started_at=now(),updated_at=now() where id=g.id;
  end if;

  return jsonb_build_object('result',result_text,'cell',cell_text);
end;
$$;

revoke execute on function public.list_active_games() from public,anon;
revoke execute on function public.create_game() from public,anon;
revoke execute on function public.join_public_game(uuid) from public,anon;
revoke execute on function public.cancel_game(uuid) from public,anon;
revoke execute on function public.leave_game(uuid) from public,anon;
revoke execute on function public.ready_with_fleet(uuid,jsonb) from public,anon;
revoke execute on function public.shoot(uuid,text) from public,anon;

grant execute on function public.list_active_games() to authenticated;
grant execute on function public.create_game() to authenticated;
grant execute on function public.join_public_game(uuid) to authenticated;
grant execute on function public.cancel_game(uuid) to authenticated;
grant execute on function public.leave_game(uuid) to authenticated;
grant execute on function public.ready_with_fleet(uuid,jsonb) to authenticated;
grant execute on function public.shoot(uuid,text) to authenticated;
