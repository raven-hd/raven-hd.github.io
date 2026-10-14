-- обновление 131: призовой корабль 2x2 вместо стандартного корабля 1x4.
-- ветка fruitkog-rewards; не применять на основном проекте до завершения текущего турнира.

begin;

create table if not exists public.fruitkog_reward_reservations (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  reward_type text not null check (reward_type in ('square_ship')),
  created_at timestamptz not null default now(),
  primary key (game_id,user_id,reward_type)
);

create index if not exists fruitkog_reward_reservations_user_idx
on public.fruitkog_reward_reservations(user_id,reward_type);

alter table public.fruitkog_reward_reservations enable row level security;
revoke all on public.fruitkog_reward_reservations from anon,authenticated;

create or replace function public.assert_valid_fleet(p_ships jsonb)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  ship_rec record;
  cell_text text;
  ship_len int;
  ship_cells jsonb;
  ship_shape text;
  square_count int:=0;
  ship_rows int[];
  ship_cols int[];
  all_rows int[]:=array[]::int[];
  all_cols int[]:=array[]::int[];
  all_ship_idx int[]:=array[]::int[];
  all_cells text[]:=array[]::text[];
  r int;
  c int;
  min_r int;
  max_r int;
  min_c int;
  max_c int;
  i int;
  j int;
begin
  if jsonb_typeof(p_ships)<>'array' or jsonb_array_length(p_ships)<>10 then
    raise exception 'Invalid fleet';
  end if;

  if (select count(*) from jsonb_array_elements(p_ships) s(value) where (s.value->>'length')::int=4)<>1
  or (select count(*) from jsonb_array_elements(p_ships) s(value) where (s.value->>'length')::int=3)<>2
  or (select count(*) from jsonb_array_elements(p_ships) s(value) where (s.value->>'length')::int=2)<>3
  or (select count(*) from jsonb_array_elements(p_ships) s(value) where (s.value->>'length')::int=1)<>4
  then
    raise exception 'Invalid fleet';
  end if;

  for ship_rec in
    select value as ship, ordinality::int as ship_idx
    from jsonb_array_elements(p_ships) with ordinality
  loop
    ship_len:=(ship_rec.ship->>'length')::int;
    ship_shape:=coalesce(nullif(lower(ship_rec.ship->>'shape'),''),'line');
    ship_cells:=ship_rec.ship->'cells';

    if ship_shape not in('line','square') then raise exception 'Invalid fleet'; end if;
    if ship_shape='square' then
      if ship_len<>4 then raise exception 'Invalid fleet'; end if;
      square_count:=square_count+1;
      if square_count>1 then raise exception 'Invalid fleet'; end if;
    end if;

    if ship_cells is null
       or jsonb_typeof(ship_cells)<>'array'
       or jsonb_array_length(ship_cells)<>ship_len then
      raise exception 'Invalid fleet';
    end if;

    ship_rows:=array[]::int[];
    ship_cols:=array[]::int[];

    for cell_text in
      select upper(value) from jsonb_array_elements_text(ship_cells)
    loop
      if cell_text !~ '^[A-J](10|[1-9])$' then raise exception 'Invalid fleet'; end if;
      if cell_text=any(all_cells) then raise exception 'Invalid fleet'; end if;

      c:=ascii(substr(cell_text,1,1))-ascii('A')+1;
      r:=substr(cell_text,2)::int;

      ship_rows:=array_append(ship_rows,r);
      ship_cols:=array_append(ship_cols,c);
      all_cells:=array_append(all_cells,cell_text);
      all_rows:=array_append(all_rows,r);
      all_cols:=array_append(all_cols,c);
      all_ship_idx:=array_append(all_ship_idx,ship_rec.ship_idx);
    end loop;

    select min(x),max(x) into min_r,max_r from unnest(ship_rows)x;
    select min(x),max(x) into min_c,max_c from unnest(ship_cols)x;

    if ship_shape='square' then
      if max_r-min_r<>1 or max_c-min_c<>1
         or (select count(distinct x) from unnest(ship_rows)x)<>2
         or (select count(distinct x) from unnest(ship_cols)x)<>2 then
        raise exception 'Invalid fleet';
      end if;
    elsif not(
      (min_r=max_r and max_c-min_c+1=ship_len)
      or
      (min_c=max_c and max_r-min_r+1=ship_len)
    ) then
      raise exception 'Invalid fleet';
    end if;
  end loop;

  if array_length(all_cells,1) is not null then
    for i in 1..array_length(all_cells,1) loop
      if i<array_length(all_cells,1) then
        for j in (i+1)..array_length(all_cells,1) loop
          if all_ship_idx[i]<>all_ship_idx[j]
             and abs(all_rows[i]-all_rows[j])<=1
             and abs(all_cols[i]-all_cols[j])<=1 then
            raise exception 'Invalid fleet';
          end if;
        end loop;
      end if;
    end loop;
  end if;
end;
$$;

create or replace function public.ready_with_fleet(p_game_id uuid,p_ships jsonb)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  g public.games%rowtype;
  first_turn uuid;
  uses_square boolean:=false;
  square_uses integer:=0;
  reserved_elsewhere integer:=0;
  reward_user uuid;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  perform public.pause_expired_games();

  select * into g
  from public.games
  where id=p_game_id
  for update;

  if not found then raise exception 'Game not found'; end if;
  if uid not in(g.player1_id,g.player2_id) then raise exception 'Not a participant'; end if;
  if g.status='paused' then raise exception 'Game is paused'; end if;

  if ((uid=g.player1_id and g.player1_ready) or (uid=g.player2_id and g.player2_ready))
     and g.status in('placing','playing') then
    return to_jsonb(g);
  end if;

  if g.player2_id is null or g.status<>'placing' then
    raise exception 'Game is not ready';
  end if;

  perform public.assert_valid_fleet(p_ships);

  select exists(
    select 1
    from jsonb_array_elements(p_ships) ship(value)
    where coalesce(nullif(lower(ship.value->>'shape'),''),'line')='square'
  ) into uses_square;

  if uses_square then
    if g.game_type='tournament' then
      raise exception 'Square ship unavailable in tournament';
    end if;

    select r.square_ship_uses into square_uses
    from public.fruitkog_player_rewards r
    where r.user_id=uid
    for update;

    if square_uses is null or square_uses<=0 then
      raise exception 'Square ship reward unavailable';
    end if;

    select count(*)::integer into reserved_elsewhere
    from public.fruitkog_reward_reservations rr
    where rr.user_id=uid
      and rr.reward_type='square_ship'
      and rr.game_id<>g.id;

    if reserved_elsewhere>=square_uses then
      raise exception 'Square ship reward unavailable';
    end if;

    insert into public.fruitkog_reward_reservations(game_id,user_id,reward_type)
    values(g.id,uid,'square_ship')
    on conflict(game_id,user_id,reward_type) do nothing;
  else
    delete from public.fruitkog_reward_reservations
    where game_id=g.id and user_id=uid and reward_type='square_ship';
  end if;

  insert into public.fleets(game_id,owner_id,ships)
  values(g.id,uid,p_ships)
  on conflict(game_id,owner_id)
  do update set ships=excluded.ships,created_at=now();

  if uid=g.player1_id then
    update public.games
    set player1_ready=true,player1_action_at=now(),updated_at=now()
    where id=g.id;
  else
    update public.games
    set player2_ready=true,player2_action_at=now(),updated_at=now()
    where id=g.id;
  end if;

  select * into g from public.games where id=p_game_id;

  if g.player1_ready and g.player2_ready then
    for reward_user in
      select rr.user_id
      from public.fruitkog_reward_reservations rr
      where rr.game_id=g.id and rr.reward_type='square_ship'
      order by rr.user_id
    loop
      update public.fruitkog_player_rewards
      set square_ship_uses=square_ship_uses-1,
          updated_at=now()
      where user_id=reward_user and square_ship_uses>0;

      if not found then
        raise exception 'Square ship reward unavailable';
      end if;
    end loop;

    delete from public.fruitkog_reward_reservations
    where game_id=g.id and reward_type='square_ship';

    first_turn:=case when random()<0.5 then g.player1_id else g.player2_id end;

    update public.games
    set status='playing',
        current_turn=first_turn,
        turn_started_at=now(),
        updated_at=now()
    where id=g.id
    returning * into g;
  end if;

  return to_jsonb(g);
end;
$$;

create or replace function public.cleanup_fruitkog_reward_reservations()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.status<>'placing' or new.player2_id is null then
    delete from public.fruitkog_reward_reservations
    where game_id=new.id;
  end if;
  return new;
end;
$$;

revoke execute on function public.assert_valid_fleet(jsonb) from public,anon,authenticated;
revoke execute on function public.cleanup_fruitkog_reward_reservations() from public,anon,authenticated;
revoke execute on function public.ready_with_fleet(uuid,jsonb) from public,anon;
grant execute on function public.ready_with_fleet(uuid,jsonb) to authenticated;

drop trigger if exists cleanup_fruitkog_reward_reservations_trigger on public.games;
create trigger cleanup_fruitkog_reward_reservations_trigger
after update of status,player2_id on public.games
for each row
execute function public.cleanup_fruitkog_reward_reservations();

commit;
