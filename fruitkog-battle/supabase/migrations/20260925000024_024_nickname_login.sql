-- обновление 27: безопасный вход по школьному нику или email.
-- браузер не получает email, связанный с ником: соответствие доступно только Edge Function.

create table if not exists public.login_attempt_limits (
  key_hash text primary key,
  attempts integer not null default 0,
  window_started timestamptz not null default now(),
  blocked_until timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.login_attempt_limits enable row level security;
revoke all on public.login_attempt_limits from public,anon,authenticated;
grant select,insert,update,delete on public.login_attempt_limits to service_role;

create or replace function public.resolve_login_user_id(p_identifier text)
returns uuid
language sql
security definer
stable
set search_path=''
as $$
  select p.user_id
  from public.profiles p
  where p.account_type='registered'
    and lower(p.display_name)=lower(left(regexp_replace(trim(p_identifier),'\s+',' ','g'),48))
  limit 1;
$$;

create or replace function public.consume_login_attempt(p_key_hash text)
returns integer
language plpgsql
security definer
set search_path=''
as $$
declare
  attempt_row public.login_attempt_limits%rowtype;
  current_time timestamptz:=clock_timestamp();
begin
  if p_key_hash is null or length(p_key_hash)<>64 then
    raise exception 'Invalid login attempt key';
  end if;

  delete from public.login_attempt_limits
  where updated_at<current_time-interval '2 days';

  select * into attempt_row
  from public.login_attempt_limits
  where key_hash=p_key_hash
  for update;

  if not found then
    insert into public.login_attempt_limits(key_hash,attempts,window_started,updated_at)
    values(p_key_hash,1,current_time,current_time);
    return 0;
  end if;

  if attempt_row.blocked_until is not null and attempt_row.blocked_until>current_time then
    return greatest(1,ceil(extract(epoch from attempt_row.blocked_until-current_time))::integer);
  end if;

  if attempt_row.window_started<current_time-interval '10 minutes' then
    update public.login_attempt_limits
    set attempts=1,window_started=current_time,blocked_until=null,updated_at=current_time
    where key_hash=p_key_hash;
    return 0;
  end if;

  if attempt_row.attempts>=9 then
    update public.login_attempt_limits
    set attempts=attempts+1,blocked_until=current_time+interval '15 minutes',updated_at=current_time
    where key_hash=p_key_hash;
    return 900;
  end if;

  update public.login_attempt_limits
  set attempts=attempts+1,updated_at=current_time
  where key_hash=p_key_hash;
  return 0;
end;
$$;

create or replace function public.clear_login_attempts(p_key_hash text)
returns void
language sql
security definer
set search_path=''
as $$
  delete from public.login_attempt_limits where key_hash=p_key_hash;
$$;

revoke execute on function public.resolve_login_user_id(text) from public,anon,authenticated;
revoke execute on function public.consume_login_attempt(text) from public,anon,authenticated;
revoke execute on function public.clear_login_attempts(text) from public,anon,authenticated;

grant execute on function public.resolve_login_user_id(text) to service_role;
grant execute on function public.consume_login_attempt(text) to service_role;
grant execute on function public.clear_login_attempts(text) to service_role;
