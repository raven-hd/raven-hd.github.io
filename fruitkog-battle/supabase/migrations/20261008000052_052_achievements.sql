-- Ачивки независимы от игровых наград. Применять после завершения турнира.
-- Номер 052 оставлен после миграций 042–051 из ветки наград; зависимостей от них нет.
begin;

create table public.player_achievements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  code text not null check (code in ('tournament_player','tournament_winner','games_50','rating_leader')),
  context_key text not null,
  tournament_id uuid references public.tournaments(id) on delete cascade,
  evidence text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected','revoked')),
  earned_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null,
  unique(user_id,code,context_key)
);
create index player_achievements_pending_idx on public.player_achievements(earned_at,id) where status='pending';
create index player_achievements_public_idx on public.player_achievements(user_id,earned_at desc) where status='approved';
alter table public.player_achievements enable row level security;
revoke all on public.player_achievements from anon,authenticated;

create or replace function public.propose_player_achievement(
  p_user_id uuid,p_code text,p_context_key text,p_evidence text,p_tournament_id uuid default null
)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not exists(select 1 from public.profiles where user_id=p_user_id and account_type='registered') then return; end if;
  insert into public.player_achievements(user_id,code,context_key,evidence,tournament_id)
  values(p_user_id,p_code,p_context_key,left(p_evidence,300),p_tournament_id)
  on conflict(user_id,code,context_key) do nothing;
end;
$$;

create or replace function public.propose_achievements_for_game()
returns trigger language plpgsql security definer set search_path=''
as $$
declare
  tournament_id_for_game uuid;
  player_id uuid;
  total_games bigint;
begin
  if new.status<>'finished' or new.finished_at is null or new.winner_id is null then return new; end if;
  if tg_op='UPDATE' then
    if old.status='finished' then return new; end if;
  end if;
  if new.game_type='tournament' then
    select tm.tournament_id into tournament_id_for_game
    from public.tournament_matches tm where tm.game_id=new.id limit 1;
  end if;
  foreach player_id in array array[new.player1_id,new.player2_id] loop
    if player_id is null then continue; end if;
    select count(*) into total_games from public.games g
    where g.status='finished' and g.finished_at is not null and g.winner_id is not null
      and player_id in(g.player1_id,g.player2_id);
    if total_games>=50 then
      perform public.propose_player_achievement(player_id,'games_50','games:50','50 завершенных матчей');
    end if;
    if tournament_id_for_game is not null then
      perform public.propose_player_achievement(player_id,'tournament_player',
        'tournament:'||tournament_id_for_game::text,'сыгран турнирный матч',tournament_id_for_game);
    end if;
  end loop;
  return new;
end;
$$;
create trigger propose_achievements_for_game_trigger
after insert or update of status on public.games
for each row execute function public.propose_achievements_for_game();

create or replace function public.propose_achievements_for_tournament()
returns trigger language plpgsql security definer set search_path=''
as $$
declare champion_id uuid;
begin
  if new.status<>'finished' or old.status='finished' then return new; end if;
  select tm.winner_id into champion_id from public.tournament_matches tm
  where tm.tournament_id=new.id and tm.stage='playoff'
    and tm.next_match_id is null and tm.winner_id is not null
  order by tm.round_no desc,tm.position limit 1;
  if champion_id is not null then
    perform public.propose_player_achievement(champion_id,'tournament_winner',
      'tournament:'||new.id::text,'победитель турнира «'||new.name||'»',new.id);
  end if;
  return new;
end;
$$;
create trigger propose_achievements_for_tournament_trigger
after update of status on public.tournaments
for each row execute function public.propose_achievements_for_tournament();

-- История рейтинга начинается с установки миграции. Прошлых лидеров по текущему рейтингу не восстанавливаем.
create table public.achievement_rating_snapshots (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(user_id) on delete cascade,
  rating integer not null,
  wins integer not null,
  games integer not null,
  recorded_at timestamptz not null default clock_timestamp()
);
create index achievement_rating_snapshots_lookup_idx
on public.achievement_rating_snapshots(user_id,recorded_at desc,id desc);
alter table public.achievement_rating_snapshots enable row level security;
revoke all on public.achievement_rating_snapshots from anon,authenticated;

insert into public.achievement_rating_snapshots(user_id,rating,wins,games)
select user_id,rating,rated_wins,rated_games from public.profiles where account_type='registered';

create or replace function public.capture_achievement_rating()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if new.account_type='registered' then
    insert into public.achievement_rating_snapshots(user_id,rating,wins,games)
    values(new.user_id,new.rating,new.rated_wins,new.rated_games);
  end if;
  return new;
end;
$$;
create trigger capture_achievement_rating_trigger
after insert or update of rating,rated_wins,rated_games,account_type on public.profiles
for each row execute function public.capture_achievement_rating();

create table public.achievement_leader_check (
  singleton boolean primary key default true check(singleton),
  last_checked_day date not null
);
insert into public.achievement_leader_check(singleton,last_checked_day)
values(true,(now() at time zone 'Europe/Moscow')::date);
alter table public.achievement_leader_check enable row level security;
revoke all on public.achievement_leader_check from anon,authenticated;

create or replace function public.refresh_achievement_leaders()
returns void language plpgsql security definer set search_path=''
as $$
declare
  check_day date;
  today_moscow date:=(now() at time zone 'Europe/Moscow')::date;
  cutoff timestamptz;
  leader_id uuid;
begin
  perform public.require_game_admin();
  select last_checked_day into check_day from public.achievement_leader_check where singleton=true for update;
  while check_day+1<today_moscow loop
    check_day:=check_day+1;
    cutoff:=(check_day+1)::timestamp at time zone 'Europe/Moscow';
    select p.user_id into leader_id
    from public.profiles p
    join lateral (
      select s.rating,s.wins,s.games from public.achievement_rating_snapshots s
      where s.user_id=p.user_id and s.recorded_at<cutoff
      order by s.recorded_at desc,s.id desc limit 1
    ) snapshot on true
    where p.account_type='registered' and snapshot.games>0
    order by snapshot.rating desc,snapshot.wins desc,snapshot.games asc,lower(p.display_name),p.user_id
    limit 1;
    if leader_id is not null then
      perform public.propose_player_achievement(leader_id,'rating_leader','overall',
        'первое место в общем рейтинге по итогам '||to_char(check_day,'DD.MM.YYYY'));
    end if;
    update public.achievement_leader_check set last_checked_day=check_day where singleton=true;
  end loop;
end;
$$;

-- Старые завершенные матчи и завершенные турниры учитываем при установке.
insert into public.player_achievements(user_id,code,context_key,evidence)
select p.user_id,'games_50','games:50','50 завершенных матчей'
from public.profiles p join public.games g on p.user_id in(g.player1_id,g.player2_id)
where p.account_type='registered' and g.status='finished' and g.finished_at is not null and g.winner_id is not null
group by p.user_id having count(*)>=50
on conflict(user_id,code,context_key) do nothing;

insert into public.player_achievements(user_id,code,context_key,evidence,tournament_id)
select distinct p.user_id,'tournament_player','tournament:'||tm.tournament_id::text,
  'сыгран турнирный матч',tm.tournament_id
from public.tournament_matches tm join public.games g on g.id=tm.game_id
join public.profiles p on p.user_id in(g.player1_id,g.player2_id)
where p.account_type='registered' and g.status='finished' and g.finished_at is not null
  and g.winner_id is not null and g.game_type='tournament'
on conflict(user_id,code,context_key) do nothing;

insert into public.player_achievements(user_id,code,context_key,evidence,tournament_id)
select distinct on(t.id) p.user_id,'tournament_winner','tournament:'||t.id::text,
  'победитель турнира «'||t.name||'»',t.id
from public.tournaments t join public.tournament_matches tm on tm.tournament_id=t.id
join public.profiles p on p.user_id=tm.winner_id
where t.status='finished' and tm.stage='playoff' and tm.next_match_id is null
order by t.id,tm.round_no desc,tm.position
on conflict(user_id,code,context_key) do nothing;

create or replace function public.list_player_achievements(p_user_id uuid)
returns jsonb language plpgsql security definer stable set search_path=''
as $$
declare result jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not exists(select 1 from public.profiles where user_id=p_user_id and account_type='registered') then
    raise exception 'Registered profile not found';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'code',a.code,'tournament_name',t.name,'earned_at',a.earned_at,
    'approved_at',a.decided_at,'evidence',a.evidence
  ) order by a.earned_at desc),'[]'::jsonb) into result
  from public.player_achievements a left join public.tournaments t on t.id=a.tournament_id
  where a.user_id=p_user_id and a.status='approved';
  return result;
end;
$$;

create or replace function public.admin_list_achievement_requests(p_limit integer default 30)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare result jsonb;
begin
  perform public.require_game_admin();
  perform public.refresh_achievement_leaders();
  select jsonb_build_object(
    'unread_count',(select count(*) from public.player_achievements where status='pending'),
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'id',a.id,'kind','achievement_pending','title','ачивка ждет подтверждения',
      'body',p.display_name||' · '||case a.code
        when 'tournament_player' then 'участник турнира'
        when 'tournament_winner' then 'победитель турнира'
        when 'games_50' then '50 игр'
        else 'лидер рейтинга' end,
      'actor_id',a.user_id,'player_name',p.display_name,'code',a.code,
      'evidence',a.evidence,'tournament_name',t.name,
      'created_at',a.earned_at,'read_at',null
    ) order by a.earned_at desc) from (
      select * from public.player_achievements where status='pending'
      order by earned_at desc limit least(greatest(coalesce(p_limit,30),1),100)
    ) a join public.profiles p on p.user_id=a.user_id
    left join public.tournaments t on t.id=a.tournament_id),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function public.admin_decide_achievement(p_achievement_id uuid,p_approve boolean)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare
  row_to_decide public.player_achievements%rowtype;
  title text;
begin
  perform public.require_game_admin();
  select * into row_to_decide from public.player_achievements
  where id=p_achievement_id for update;
  if not found or row_to_decide.status<>'pending' then raise exception 'Achievement request is no longer pending'; end if;
  update public.player_achievements
  set status=case when p_approve then 'approved' else 'rejected' end,
      decided_at=now(),decided_by=auth.uid()
  where id=p_achievement_id;
  if p_approve then
    title:=case row_to_decide.code
      when 'tournament_player' then 'участник турнира'
      when 'tournament_winner' then 'победитель турнира'
      when 'games_50' then '50 игр'
      else 'лидер рейтинга' end;
    perform public.push_user_notification(row_to_decide.user_id,'reward','новая ачивка',
      'вам выдана ачивка «'||title||'».',null,row_to_decide.tournament_id,null,
      'achievement:'||row_to_decide.id::text);
  end if;
  return jsonb_build_object('id',p_achievement_id,'status',case when p_approve then 'approved' else 'rejected' end);
end;
$$;

revoke execute on function public.propose_player_achievement(uuid,text,text,text,uuid) from public,anon,authenticated;
revoke execute on function public.propose_achievements_for_game() from public,anon,authenticated;
revoke execute on function public.propose_achievements_for_tournament() from public,anon,authenticated;
revoke execute on function public.capture_achievement_rating() from public,anon,authenticated;
revoke execute on function public.refresh_achievement_leaders() from public,anon,authenticated;
revoke execute on function public.list_player_achievements(uuid) from public,anon;
revoke execute on function public.admin_list_achievement_requests(integer) from public,anon;
revoke execute on function public.admin_decide_achievement(uuid,boolean) from public,anon;
grant execute on function public.list_player_achievements(uuid) to authenticated;
grant execute on function public.admin_list_achievement_requests(integer) to authenticated;
grant execute on function public.admin_decide_achievement(uuid,boolean) to authenticated;

-- Проверка защиты содержит белый список открытых RPC. Расширяем ее текущую
-- версию, сохраняя дополнения из других веток при будущем объединении.
do $achievement_audit$
declare
  audit_definition text:=pg_get_functiondef('public.admin_security_audit()'::regprocedure);
  revised_definition text;
begin
  revised_definition:=replace(audit_definition,
    '''admin_start_qualifier_tiebreak''',
    '''admin_start_qualifier_tiebreak'',''list_player_achievements'',''admin_list_achievement_requests'',''admin_decide_achievement''');
  if revised_definition=audit_definition then
    raise exception 'Achievement security audit allowlist anchor missing';
  end if;
  execute revised_definition;
end;
$achievement_audit$;

commit;
