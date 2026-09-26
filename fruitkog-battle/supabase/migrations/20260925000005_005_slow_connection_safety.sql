-- обновление 05: защита от повторных запросов при медленном соединении.
-- выполните после 004_placement_and_history.sql.

alter table public.games
add column if not exists create_request_id uuid;

create unique index if not exists games_creator_request_unique
on public.games(player1_id,create_request_id)
where create_request_id is not null;

drop function if exists public.create_game();

create or replace function public.create_game(p_request_id uuid)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare uid uuid:=auth.uid();p public.profiles%rowtype;g public.games%rowtype;new_code text;
begin
  if uid is null then raise exception 'Authentication required'; end if;
  if p_request_id is null then raise exception 'Request id required'; end if;
  select * into p from public.profiles where user_id=uid;
  if not found then raise exception 'Profile required'; end if;

  select * into g
  from public.games
  where player1_id=uid and create_request_id=p_request_id;
  if found then return to_jsonb(g); end if;

  loop
    new_code:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,8));
    exit when not exists(select 1 from public.games where code=new_code);
  end loop;

  begin
    insert into public.games(
      code,game_type,visibility,player1_id,player1_name,player1_action_at,create_request_id
    ) values(
      new_code,'casual','public',uid,p.display_name,now(),p_request_id
    ) returning * into g;
  exception when unique_violation then
    select * into g
    from public.games
    where player1_id=uid and create_request_id=p_request_id;
    if not found then raise; end if;
  end;

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
  if g.player2_id=uid and g.status in('placing','playing','paused') then return to_jsonb(g); end if;
  if g.visibility<>'public' or g.status<>'waiting' or g.player2_id is not null then raise exception 'Game is full'; end if;

  update public.games
  set player2_id=uid,player2_name=p.display_name,status='placing',
      player2_action_at=now(),updated_at=now()
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
  if ((uid=g.player1_id and g.player1_ready) or (uid=g.player2_id and g.player2_ready))
     and g.status in('placing','playing') then
    return to_jsonb(g);
  end if;
  if g.player2_id is null or g.status<>'placing' then raise exception 'Game is not ready'; end if;

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

revoke execute on function public.create_game(uuid) from public,anon;
revoke execute on function public.join_public_game(uuid) from public,anon;
revoke execute on function public.ready_with_fleet(uuid,jsonb) from public,anon;

grant execute on function public.create_game(uuid) to authenticated;
grant execute on function public.join_public_game(uuid) to authenticated;
grant execute on function public.ready_with_fleet(uuid,jsonb) to authenticated;
