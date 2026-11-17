-- 21 Days Fast: names and pastor view. Paste all of this into Supabase > SQL Editor and press Run.
-- Safe to run more than once.

-- 1) Each person's name and whether pastors may see it.
create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '' check (char_length(name) <= 60),
  visible boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.profiles enable row level security;
drop policy if exists "own profile select" on public.profiles;
drop policy if exists "own profile insert" on public.profiles;
drop policy if exists "own profile update" on public.profiles;
drop policy if exists "own profile delete" on public.profiles;
create policy "own profile select" on public.profiles for select using (auth.uid() = user_id);
create policy "own profile insert" on public.profiles for insert with check (auth.uid() = user_id);
create policy "own profile update" on public.profiles for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "own profile delete" on public.profiles for delete using (auth.uid() = user_id);

-- 2) Who counts as a pastor. Nobody can read or change this from the app; only you, here in SQL.
create table if not exists public.staff (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.staff enable row level security;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid());
$$;
revoke all on function public.is_staff() from public, anon;
grant execute on function public.is_staff() to authenticated;

-- 3) Totals for pastors (anonymous numbers).
create or replace function public.pastor_totals() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.staff where user_id = auth.uid()) then
    raise exception 'not allowed';
  end if;
  return jsonb_build_object(
    'accounts', (select count(*) from auth.users),
    'active_today', (select count(*) from public.progress where (updated_at at time zone 'Europe/Stockholm')::date = (now() at time zone 'Europe/Stockholm')::date),
    'finished', (select count(*) from public.progress where jsonb_array_length(coalesce(data->'done', '[]'::jsonb)) >= 21),
    'per_day', (select coalesce(jsonb_agg(c order by d), '[]'::jsonb) from (
        select g as d, (select count(*) from public.progress where coalesce(data->'done', '[]'::jsonb) @> to_jsonb(g)) as c
        from generate_series(1, 21) g) x)
  );
end $$;
revoke all on function public.pastor_totals() from public, anon;
grant execute on function public.pastor_totals() to authenticated;

-- 4) Member list for pastors: only people who chose to be visible. Never includes prayers or notes.
create or replace function public.pastor_overview()
returns table(name text, days_done int, current_day int, last_active timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.staff where user_id = auth.uid()) then
    raise exception 'not allowed';
  end if;
  return query
    select p.name,
           jsonb_array_length(coalesce(pr.data->'done', '[]'::jsonb))::int,
           coalesce((select min(g) from generate_series(1, 21) g where not (coalesce(pr.data->'done', '[]'::jsonb) @> to_jsonb(g))), 21)::int,
           pr.updated_at
    from public.profiles p
    left join public.progress pr on pr.user_id = p.user_id
    where p.visible
    order by pr.updated_at desc nulls last;
end $$;
revoke all on function public.pastor_overview() from public, anon;
grant execute on function public.pastor_overview() to authenticated;

-- 5) Make someone a pastor: they first create a normal account in the app, then you run this
--    with their email (remove the two dashes at the start of the next two lines):
-- insert into public.staff (user_id) select id from auth.users where email = 'PASTOR-EMAIL@example.com'
-- on conflict do nothing;
