-- 21 Days Fast: prayer-support counts on your own requests and on group walls.
-- Run in the SAME project the app uses (qlewbortlinmyhmseozz). Safe to run again.
-- Needs supabase-wall.sql and supabase-groups.sql to have been run first.

drop function if exists public.wall_mine();
create function public.wall_mine()
returns table(id uuid, body text, status text, created_at timestamptz, prayed int)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  return query select r.id, r.body, r.status, r.created_at,
      (select count(*)::int from public.prayer_prays p where p.request_id = r.id)
    from public.prayer_requests r
    where r.user_id = auth.uid() and r.status <> 'removed' order by r.created_at desc limit 20;
end $$;

create table if not exists public.group_prays (
  post_id uuid not null references public.group_posts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (post_id, user_id)
);
alter table public.group_prays enable row level security;

drop function if exists public.group_posts_list(uuid, text);
create function public.group_posts_list(gid uuid, k text)
returns table(id uuid, body text, author text, created_at timestamptz, mine boolean, prayed int, i_prayed boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_member(gid) then raise exception 'not allowed'; end if;
  return query
    select x.id, x.body,
           case when x.anon then null else coalesce(nullif(p.name,''), 'Member') end,
           x.created_at, (x.user_id = auth.uid()),
           (select count(*)::int from public.group_prays gp where gp.post_id = x.id),
           exists (select 1 from public.group_prays gp where gp.post_id = x.id and gp.user_id = auth.uid())
    from public.group_posts x left join public.profiles p on p.user_id = x.user_id
    where x.group_id = gid and x.kind = k order by x.created_at desc limit 50;
end $$;

create or replace function public.group_pray(pid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  select group_id into gid from public.group_posts where id = pid and kind = 'wall';
  if gid is null or not public._is_member(gid) then raise exception 'not allowed'; end if;
  insert into public.group_prays (post_id, user_id) values (pid, auth.uid()) on conflict do nothing;
end $$;

revoke all on function public.wall_mine(), public.group_posts_list(uuid,text), public.group_pray(uuid) from public, anon;
grant execute on function public.wall_mine(), public.group_posts_list(uuid,text), public.group_pray(uuid) to authenticated;
notify pgrst, 'reload schema';
