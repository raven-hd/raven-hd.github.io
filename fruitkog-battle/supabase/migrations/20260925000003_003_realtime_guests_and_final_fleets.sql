-- Обновление 03: автоматические гостевые профили и данные для аватаров.
-- Выполните после 001_schema.sql и 002_game_lifecycle.sql.

alter table public.profiles
add column if not exists avatar_emoji text;

-- Старые гостевые профили сохраняют свои имена, но получают гостевой аватар.
update public.profiles
set avatar_emoji=(array['🍅','🥒','🍆','🎃','🍎','🍐','🍑','🥕','🍒','🍉'])[
  1 + mod(abs(hashtext(user_id::text)::bigint),10)::integer
]
where account_type='guest' and avatar_emoji is null;

create or replace function public.is_school_nick_available(p_nick text)
returns boolean
language sql
security definer
stable
set search_path=''
as $$
  with cleaned as (
    select lower(left(regexp_replace(trim(p_nick), '\s+', ' ', 'g'),48)) as nick
  )
  select
    (select nick from cleaned) not in (
      'сочный томат',
      'хрустящий огурец',
      'боевой баклажан',
      'задумчивая тыква',
      'спелое яблоко',
      'веселая груша',
      'солнечный персик',
      'бодрая морковь',
      'серьезная вишня',
      'смелый арбуз'
    )
    and not exists(
      select 1 from public.profiles
      where account_type='registered'
        and lower(display_name)=(select nick from cleaned)
    );
$$;

create or replace function public.claim_random_guest()
returns public.profiles
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  names text[]:=array[
    'Сочный Томат',
    'Хрустящий Огурец',
    'Боевой Баклажан',
    'Задумчивая Тыква',
    'Спелое Яблоко',
    'Веселая Груша',
    'Солнечный Персик',
    'Бодрая Морковь',
    'Серьезная Вишня',
    'Смелый Арбуз'
  ];
  emojis text[]:=array['🍅','🥒','🍆','🎃','🍎','🍐','🍑','🥕','🍒','🍉'];
  candidate text;
  selected_emoji text;
  identity_index integer;
  attempt integer;
  suffix integer;
  p public.profiles%rowtype;
begin
  if uid is null then raise exception 'Authentication required'; end if;

  if exists(select 1 from auth.users where id=uid and email is not null) then
    raise exception 'Guest profile requires anonymous user';
  end if;

  select * into p from public.profiles where user_id=uid;
  if found then
    if p.account_type<>'guest' then raise exception 'Guest profile requires anonymous user'; end if;
    return p;
  end if;

  for attempt in 1..30 loop
    identity_index:=1+floor(random()*array_length(names,1))::integer;
    candidate:=names[identity_index];
    selected_emoji:=emojis[identity_index];
    exit when not exists(
      select 1 from public.profiles where lower(display_name)=lower(candidate)
    );
    candidate:=null;
  end loop;

  if candidate is null then
    identity_index:=1+floor(random()*array_length(names,1))::integer;
    selected_emoji:=emojis[identity_index];
    loop
      suffix:=1000+floor(random()*9000)::integer;
      candidate:=names[identity_index]||' '||suffix::text;
      exit when not exists(
        select 1 from public.profiles where lower(display_name)=lower(candidate)
      );
    end loop;
  end if;

  insert into public.profiles(user_id,display_name,account_type,avatar_emoji)
  values(uid,candidate,'guest',selected_emoji)
  returning * into p;

  return p;
end;
$$;

revoke execute on function public.claim_random_guest() from public,anon;
grant execute on function public.claim_random_guest() to authenticated;

revoke execute on function public.claim_guest_name(text) from public,anon,authenticated;
drop function if exists public.claim_guest_name(text);
