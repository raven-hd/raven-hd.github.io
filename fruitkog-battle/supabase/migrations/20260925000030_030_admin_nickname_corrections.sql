-- выполнить после 029_rating_balance.sql
-- исправление школьного ника доступно только администратору.

alter table public.user_notifications drop constraint if exists user_notifications_kind_check;
alter table public.user_notifications add constraint user_notifications_kind_check
  check (kind in (
    'opponent_joined','tournament_application','tournament_match_assigned',
    'tournament_match_finished','reward','nickname_changed','nickname_verified'
  ));

create or replace function public.admin_change_school_nick(p_user_id uuid,p_new_nick text)
returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  old_profile public.profiles%rowtype;
  new_profile public.profiles%rowtype;
  cleaned text:=regexp_replace(trim(coalesce(p_new_nick,'')),'\s+',' ','g');
begin
  perform public.require_game_admin();
  if p_user_id is null then raise exception 'Registered profile not found'; end if;
  if length(cleaned)<1 or length(cleaned)>48 then raise exception 'Invalid school nick length'; end if;

  select * into old_profile from public.profiles
  where user_id=p_user_id and account_type='registered' for update;
  if not found then raise exception 'Registered profile not found'; end if;
  if old_profile.display_name=cleaned then return to_jsonb(old_profile); end if;

  if exists(select 1 from public.profiles
            where account_type='registered' and user_id<>p_user_id
              and lower(display_name)=lower(cleaned)) then
    raise exception 'School nick already registered';
  end if;

  update public.profiles
  set display_name=cleaned,school_verified=false
  where user_id=p_user_id returning * into new_profile;

  -- games store player names as snapshots; keep them consistent with the profile.
  update public.games set player1_name=cleaned where player1_id=p_user_id;
  update public.games set player2_name=cleaned where player2_id=p_user_id;

  perform public.push_user_notification(
    p_user_id,'nickname_changed','школьный ник изменен',
    'администратор исправил ваш школьный ник: «'||cleaned||'».',
    null,null,null,'nickname-changed:'||gen_random_uuid()::text
  );
  return to_jsonb(new_profile);
end;
$$;

create or replace function public.notify_school_nick_verified()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if new.account_type='registered'
     and new.school_verified=true and old.school_verified=false then
    perform public.push_user_notification(
      new.user_id,'nickname_verified','школьный ник подтвержден',
      'администратор подтвердил ваш школьный ник: «'||new.display_name||'».',
      null,null,null,'nickname-verified:'||gen_random_uuid()::text
    );
  end if;
  return new;
end;
$$;

drop trigger if exists notify_school_nick_verified_trigger on public.profiles;
create trigger notify_school_nick_verified_trigger
after update of school_verified on public.profiles
for each row execute function public.notify_school_nick_verified();

revoke execute on function public.admin_change_school_nick(uuid,text) from public,anon;
revoke execute on function public.notify_school_nick_verified() from public,anon,authenticated;
grant execute on function public.admin_change_school_nick(uuid,text) to authenticated;
