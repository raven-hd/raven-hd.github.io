-- Аватар относится только к «Фруктовому бою». Аккаунты и другие игры не меняются.
create table if not exists public.fruitkog_avatars (
  user_id uuid primary key references public.profiles(user_id) on delete cascade,
  avatar_id text not null check (
    avatar_id ~ '^(tomato|celery|mushroom|eggplant|garlic|corn)-(happy|grumpy|cool|surprised)$'
  )
);

alter table public.fruitkog_avatars enable row level security;
grant select, insert, update on public.fruitkog_avatars to authenticated;

drop policy if exists "fruitkog avatars readable" on public.fruitkog_avatars;
create policy "fruitkog avatars readable" on public.fruitkog_avatars
for select to authenticated using (true);

drop policy if exists "registered user chooses fruitkog avatar" on public.fruitkog_avatars;
create policy "registered user chooses fruitkog avatar" on public.fruitkog_avatars
for insert to authenticated
with check (
  auth.uid() = user_id
  and exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.account_type = 'registered')
);

drop policy if exists "registered user changes fruitkog avatar" on public.fruitkog_avatars;
create policy "registered user changes fruitkog avatar" on public.fruitkog_avatars
for update to authenticated
using (auth.uid() = user_id)
with check (
  auth.uid() = user_id
  and exists (select 1 from public.profiles p where p.user_id = auth.uid() and p.account_type = 'registered')
);
