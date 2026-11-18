-- 21 Days Fast: anonymous prayer wall. Paste all into Supabase > SQL Editor and press Run. Safe to run again.
-- Requires supabase-pastors.sql to have been run first (it creates the staff table).

create table if not exists public.prayer_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  status text not null default 'pending' check (status in ('pending','approved','removed')),
  created_at timestamptz not null default now()
);
create table if not exists public.prayer_prays (
  request_id uuid not null references public.prayer_requests(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (request_id, user_id)
);
-- No policies on purpose: the app can only use the functions below.
alter table public.prayer_requests enable row level security;
alter table public.prayer_prays enable row level security;

create or replace function public.wall_submit(txt text) returns void
language plpgsql security definer set search_path = public as $$
declare t text := btrim(coalesce(txt, ''));
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if char_length(t) < 1 or char_length(t) > 500 then raise exception 'bad length'; end if;
  if (select count(*) from public.prayer_requests where user_id = auth.uid() and created_at > now() - interval '1 day') >= 3 then
    raise exception 'too many requests today';
  end if;
  insert into public.prayer_requests (user_id, body) values (auth.uid(), t);
end $$;

create or replace function public.wall_list()
returns table(id uuid, body text, created_at timestamptz, prayed int, i_prayed boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  return query
    select r.id, r.body, r.created_at,
           (select count(*)::int from public.prayer_prays p where p.request_id = r.id),
           exists (select 1 from public.prayer_prays p where p.request_id = r.id and p.user_id = auth.uid())
    from public.prayer_requests r where r.status = 'approved'
    order by r.created_at desc limit 100;
end $$;

create or replace function public.wall_mine()
returns table(id uuid, body text, status text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  return query select r.id, r.body, r.status, r.created_at from public.prayer_requests r
    where r.user_id = auth.uid() and r.status <> 'removed' order by r.created_at desc limit 20;
end $$;

create or replace function public.wall_delete(rid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  delete from public.prayer_requests where id = rid and user_id = auth.uid();
end $$;

create or replace function public.wall_pray(rid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if exists (select 1 from public.prayer_requests where id = rid and status = 'approved') then
    insert into public.prayer_prays (request_id, user_id) values (rid, auth.uid()) on conflict do nothing;
  end if;
end $$;

create or replace function public.wall_pending()
returns table(id uuid, body text, created_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.staff where user_id = auth.uid()) then raise exception 'not allowed'; end if;
  return query select r.id, r.body, r.created_at from public.prayer_requests r where r.status = 'pending' order by r.created_at;
end $$;

create or replace function public.wall_moderate(rid uuid, approve boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.staff where user_id = auth.uid()) then raise exception 'not allowed'; end if;
  update public.prayer_requests set status = case when approve then 'approved' else 'removed' end where id = rid;
end $$;

revoke all on function public.wall_submit(text), public.wall_list(), public.wall_mine(), public.wall_delete(uuid),
  public.wall_pray(uuid), public.wall_pending(), public.wall_moderate(uuid, boolean) from public, anon;
grant execute on function public.wall_submit(text), public.wall_list(), public.wall_mine(), public.wall_delete(uuid),
  public.wall_pray(uuid), public.wall_pending(), public.wall_moderate(uuid, boolean) to authenticated;
notify pgrst, 'reload schema';
