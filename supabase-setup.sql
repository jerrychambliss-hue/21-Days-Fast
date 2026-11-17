-- 21 Days Fast: database setup. Paste all of this into Supabase > SQL Editor and press Run.

create table if not exists public.progress (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.progress enable row level security;
drop policy if exists "own progress select" on public.progress;
drop policy if exists "own progress insert" on public.progress;
drop policy if exists "own progress update" on public.progress;
drop policy if exists "own progress delete" on public.progress;
create policy "own progress select" on public.progress for select using (auth.uid() = user_id);
create policy "own progress insert" on public.progress for insert with check (auth.uid() = user_id);
create policy "own progress update" on public.progress for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own progress delete" on public.progress for delete using (auth.uid() = user_id);

create table if not exists public.completions (
  user_id uuid not null references auth.users(id) on delete cascade,
  day int not null check (day between 1 and 21),
  completed_on date not null default ((now() at time zone 'Europe/Stockholm')::date),
  primary key (user_id, day)
);
alter table public.completions enable row level security;
drop policy if exists "own completions select" on public.completions;
drop policy if exists "own completions insert" on public.completions;
drop policy if exists "own completions delete" on public.completions;
create policy "own completions select" on public.completions for select using (auth.uid() = user_id);
create policy "own completions insert" on public.completions for insert with check (auth.uid() = user_id);
create policy "own completions delete" on public.completions for delete using (auth.uid() = user_id);

-- Anonymous daily count: how many different people finished a day today.
create or replace function public.today_count() returns int
language sql stable security definer set search_path = public as $$
  select count(distinct user_id)::int from public.completions
  where completed_on = ((now() at time zone 'Europe/Stockholm')::date);
$$;
revoke all on function public.today_count() from public;
grant execute on function public.today_count() to anon, authenticated;

-- Lets a signed-in person delete their own account and all their data.
create or replace function public.delete_my_account() returns void
language sql security definer set search_path = public, auth as $$
  delete from auth.users where id = auth.uid();
$$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
