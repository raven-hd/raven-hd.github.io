-- выполнять после 030_admin_nickname_corrections.sql
-- проверка на стороне базы: интерфейс можно обойти, эти правила нельзя.

create or replace function public.require_verified_competitive_players()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if new.game_type in ('rated','tournament')
     and new.status in ('waiting','placing','playing','paused') then
    if not exists (
      select 1 from public.profiles p
      where p.user_id=new.player1_id and p.account_type='registered'
        and p.school_verified=true
    ) or (new.player2_id is not null and not exists (
      select 1 from public.profiles p
      where p.user_id=new.player2_id and p.account_type='registered'
        and p.school_verified=true
    )) then
      raise exception 'Verified school nick required';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists require_verified_competitive_players_trigger on public.games;
create trigger require_verified_competitive_players_trigger
before insert or update of game_type,player1_id,player2_id on public.games
for each row execute function public.require_verified_competitive_players();

create or replace function public.require_verified_tournament_player()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if new.status='active' and not exists (
    select 1 from public.profiles p
    where p.user_id=new.user_id and p.account_type='registered'
      and p.school_verified=true
  ) then
    raise exception 'Verified school nick required';
  end if;
  return new;
end;
$$;

drop trigger if exists require_verified_tournament_player_trigger on public.tournament_players;
create trigger require_verified_tournament_player_trigger
before insert or update of status on public.tournament_players
for each row execute function public.require_verified_tournament_player();

revoke execute on function public.require_verified_competitive_players() from public,anon,authenticated;
revoke execute on function public.require_verified_tournament_player() from public,anon,authenticated;
