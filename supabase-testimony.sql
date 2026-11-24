-- 21 Days Fast: testimonies sent to the pastors.
-- Run in the SAME project the app uses (qlewbortlinmyhmseozz). Safe to run again.
-- Needs supabase-pastors.sql to have been run first (it creates is_staff and profiles).

create table if not exists public.testimonies (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 5000),
  share_name boolean not null default true,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.testimonies enable row level security;

create or replace function public.testimony_send(txt text, share boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if txt is null or char_length(btrim(txt)) = 0 then raise exception 'empty'; end if;
  insert into public.testimonies(user_id, body, share_name) values (auth.uid(), left(btrim(txt), 5000), coalesce(share, true));
end $$;
revoke all on function public.testimony_send(text, boolean) from public, anon;
grant execute on function public.testimony_send(text, boolean) to authenticated;

drop function if exists public.testimony_list();
create function public.testimony_list()
returns table(id uuid, body text, author text, created_at timestamptz, is_read boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'not allowed'; end if;
  return query
    select x.id, x.body,
           case when x.share_name then coalesce(nullif(p.name, ''), 'Member') else null end,
           x.created_at, x.is_read
    from public.testimonies x left join public.profiles p on p.user_id = x.user_id
    order by x.is_read asc, x.created_at desc limit 200;
end $$;
revoke all on function public.testimony_list() from public, anon;
grant execute on function public.testimony_list() to authenticated;

create or replace function public.testimony_mark(tid uuid, done boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'not allowed'; end if;
  update public.testimonies set is_read = coalesce(done, true) where id = tid;
end $$;
revoke all on function public.testimony_mark(uuid, boolean) from public, anon;
grant execute on function public.testimony_mark(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
