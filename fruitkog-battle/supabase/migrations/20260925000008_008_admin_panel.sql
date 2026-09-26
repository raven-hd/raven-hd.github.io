-- обновление 09: базовая админ-панель.
-- выполните после 007_rating.sql.

alter table public.games
add column if not exists admin_cancelled_by uuid references auth.users(id) on delete set null,
add column if not exists admin_cancelled_at timestamptz,
add column if not exists admin_cancel_reason text;

create index if not exists games_admin_status_updated_idx
on public.games(status,updated_at desc);

create or replace function public.require_game_admin()
returns void
language plpgsql security definer stable set search_path=''
as $$
begin
  if auth.uid() is null or not public.is_game_admin(auth.uid()) then
    raise exception 'Admin required';
  end if;
end;
$$;

revoke execute on function public.require_game_admin() from public,anon;
grant execute on function public.require_game_admin() to authenticated;

create or replace function public.admin_list_players()
returns table(
  user_id uuid,
  display_name text,
  account_type text,
  school_verified boolean,
  is_admin boolean,
  avatar_emoji text,
  rating integer,
  rated_games integer,
  rated_wins integer,
  rated_losses integer,
  created_at timestamptz
)
language plpgsql security definer stable set search_path=''
as $$
begin
  perform public.require_game_admin();
  return query
  select p.user_id,p.display_name,p.account_type,p.school_verified,p.is_admin,
         p.avatar_emoji,p.rating,p.rated_games,p.rated_wins,p.rated_losses,p.created_at
  from public.profiles p
  order by (p.account_type='registered') desc,lower(p.display_name),p.created_at;
end;
$$;

create or replace function public.admin_set_school_verified(
  p_user_id uuid,
  p_verified boolean
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  changed public.profiles%rowtype;
begin
  perform public.require_game_admin();

  update public.profiles p
  set school_verified=coalesce(p_verified,false)
  where p.user_id=p_user_id and p.account_type='registered'
  returning * into changed;

  if not found then raise exception 'Registered profile not found'; end if;
  return to_jsonb(changed);
end;
$$;

create or replace function public.admin_list_games(p_filter text default 'active')
returns table(
  id uuid,
  player1_id uuid,
  player1_name text,
  player2_id uuid,
  player2_name text,
  player1_ready boolean,
  player2_ready boolean,
  game_type text,
  status text,
  current_turn uuid,
  winner_id uuid,
  finish_reason text,
  surrendered_by uuid,
  rating_applied boolean,
  rating_delta integer,
  rating_skip_reason text,
  created_at timestamptz,
  updated_at timestamptz,
  finished_at timestamptz,
  paused_at timestamptz,
  pause_reason text,
  admin_cancelled_by uuid,
  admin_cancelled_at timestamptz,
  admin_cancel_reason text,
  shot_count bigint,
  pair_finished_24h bigint,
  pair_surrenders_24h bigint
)
language plpgsql security definer stable set search_path=''
as $$
declare
  wanted text:=lower(trim(coalesce(p_filter,'active')));
begin
  perform public.require_game_admin();
  if wanted not in('all','active','paused','finished','cancelled') then
    raise exception 'Invalid admin game filter';
  end if;

  return query
  select g.id,g.player1_id,g.player1_name,g.player2_id,g.player2_name,
         g.player1_ready,g.player2_ready,g.game_type,g.status,g.current_turn,
         g.winner_id,g.finish_reason,g.surrendered_by,g.rating_applied,
         g.rating_delta,g.rating_skip_reason,g.created_at,g.updated_at,g.finished_at,
         g.paused_at,g.pause_reason,g.admin_cancelled_by,g.admin_cancelled_at,
         g.admin_cancel_reason,
         (select count(*) from public.shots s where s.game_id=g.id) as shot_count,
         case when g.player2_id is null then 0::bigint else (
           select count(*)
           from public.games prior
           where prior.status='finished'
             and prior.finished_at>now()-interval '24 hours'
             and (
               (prior.player1_id=g.player1_id and prior.player2_id=g.player2_id)
               or
               (prior.player1_id=g.player2_id and prior.player2_id=g.player1_id)
             )
         ) end as pair_finished_24h,
         case when g.player2_id is null then 0::bigint else (
           select count(*)
           from public.games prior
           where prior.status='finished'
             and prior.finish_reason='surrender'
             and prior.finished_at>now()-interval '24 hours'
             and (
               (prior.player1_id=g.player1_id and prior.player2_id=g.player2_id)
               or
               (prior.player1_id=g.player2_id and prior.player2_id=g.player1_id)
             )
         ) end as pair_surrenders_24h
  from public.games g
  where wanted='all'
     or (wanted='active' and g.status in('waiting','placing','playing','paused'))
     or (wanted='paused' and g.status='paused')
     or (wanted='finished' and g.status='finished')
     or (wanted='cancelled' and g.status='cancelled')
  order by
    case when g.status in('paused','playing','placing','waiting') then 0 else 1 end,
    coalesce(g.updated_at,g.created_at) desc
  limit 200;
end;
$$;

create or replace function public.admin_get_game_details(p_game_id uuid)
returns jsonb
language plpgsql security definer stable set search_path=''
as $$
declare
  result jsonb;
begin
  perform public.require_game_admin();

  select jsonb_build_object(
    'game',to_jsonb(g),
    'fleets',coalesce((
      select jsonb_agg(to_jsonb(f) order by f.created_at,f.owner_id)
      from public.fleets f where f.game_id=g.id
    ),'[]'::jsonb),
    'shots',coalesce((
      select jsonb_agg(to_jsonb(s) order by s.id)
      from public.shots s where s.game_id=g.id
    ),'[]'::jsonb)
  ) into result
  from public.games g
  where g.id=p_game_id;

  if result is null then raise exception 'Game not found'; end if;
  return result;
end;
$$;

create or replace function public.admin_cancel_game(
  p_game_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  g public.games%rowtype;
  reason text:=left(nullif(trim(coalesce(p_reason,'')),''),240);
begin
  perform public.require_game_admin();

  select * into g from public.games where id=p_game_id for update;
  if not found then raise exception 'Game not found'; end if;
  if g.status not in('waiting','placing','playing','paused') then
    raise exception 'Game cannot be cancelled';
  end if;

  update public.games
  set status='cancelled',current_turn=null,winner_id=null,finished_at=null,
      finish_reason=null,surrendered_by=null,updated_at=now(),
      admin_cancelled_by=auth.uid(),admin_cancelled_at=now(),
      admin_cancel_reason=coalesce(reason,'закрыт администратором')
  where public.games.id=p_game_id
  returning * into g;

  return to_jsonb(g);
end;
$$;

revoke execute on function public.admin_list_players() from public,anon;
revoke execute on function public.admin_set_school_verified(uuid,boolean) from public,anon;
revoke execute on function public.admin_list_games(text) from public,anon;
revoke execute on function public.admin_get_game_details(uuid) from public,anon;
revoke execute on function public.admin_cancel_game(uuid,text) from public,anon;

grant execute on function public.admin_list_players() to authenticated;
grant execute on function public.admin_set_school_verified(uuid,boolean) to authenticated;
grant execute on function public.admin_list_games(text) to authenticated;
grant execute on function public.admin_get_game_details(uuid) to authenticated;
grant execute on function public.admin_cancel_game(uuid,text) to authenticated;
