-- 21 Days Fast: life groups. Paste all into Supabase > SQL Editor and press Run. Safe to run again.
-- Run supabase-pastors.sql first (it creates the staff table).

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  code text not null unique,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('member','leader')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create table if not exists public.group_posts (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('wall','devo')),
  body text not null check (char_length(body) between 1 and 1000),
  anon boolean not null default false,
  created_at timestamptz not null default now()
);
-- No policies on purpose: the app only uses the functions below.
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_posts enable row level security;

create or replace function public._is_staff() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid()); $$;
create or replace function public._is_member(gid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members where group_id = gid and user_id = auth.uid()); $$;
create or replace function public._is_leader(gid uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.group_members where group_id = gid and user_id = auth.uid() and role = 'leader'); $$;
revoke all on function public._is_staff(), public._is_member(uuid), public._is_leader(uuid) from public, anon, authenticated;

create or replace function public.group_create(nm text) returns table(id uuid, code text)
language plpgsql security definer set search_path = public as $$
declare c text; gid uuid; alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int;
begin
  if not public._is_staff() then raise exception 'not allowed'; end if;
  if char_length(btrim(coalesce(nm,''))) < 1 or char_length(btrim(nm)) > 60 then raise exception 'bad name'; end if;
  loop
    c := '';
    for i in 1..6 loop c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1); end loop;
    exit when not exists (select 1 from public.groups g where g.code = c);
  end loop;
  insert into public.groups (name, code, created_by) values (btrim(nm), c, auth.uid()) returning groups.id into gid;
  insert into public.group_members (group_id, user_id, role) values (gid, auth.uid(), 'leader');
  return query select gid, c;
end $$;

create or replace function public.group_join(c text) returns uuid
language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  select g.id into gid from public.groups g where g.code = upper(btrim(coalesce(c,'')));
  if gid is null then raise exception 'no such group'; end if;
  insert into public.group_members (group_id, user_id) values (gid, auth.uid()) on conflict do nothing;
  return gid;
end $$;

create or replace function public.group_leave(gid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  delete from public.group_members where group_id = gid and user_id = auth.uid();
end $$;

create or replace function public.group_mine()
returns table(id uuid, name text, code text, role text, members int)
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  return query
    select g.id, g.name, case when m.role = 'leader' then g.code else null end, m.role,
           (select count(*)::int from public.group_members x where x.group_id = g.id)
    from public.group_members m join public.groups g on g.id = m.group_id
    where m.user_id = auth.uid() order by g.name;
end $$;

create or replace function public.group_members_list(gid uuid)
returns table(name text, role text, days_done int, done_today boolean, mid uuid)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_member(gid) then raise exception 'not allowed'; end if;
  return query
    select coalesce(nullif(p.name,''), 'Member'), m.role,
           jsonb_array_length(coalesce(pr.data->'done','[]'::jsonb))::int,
           exists (select 1 from public.completions c where c.user_id = m.user_id and c.completed_on = (now() at time zone 'Europe/Stockholm')::date),
           case when public._is_leader(gid) or public._is_staff() then m.user_id else null end
    from public.group_members m
    left join public.profiles p on p.user_id = m.user_id
    left join public.progress pr on pr.user_id = m.user_id
    where m.group_id = gid
    order by (m.role = 'leader') desc, p.name;
end $$;

create or replace function public.group_posts_list(gid uuid, k text)
returns table(id uuid, body text, author text, created_at timestamptz, mine boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_member(gid) then raise exception 'not allowed'; end if;
  return query
    select x.id, x.body,
           case when x.anon then null else coalesce(nullif(p.name,''), 'Member') end,
           x.created_at, (x.user_id = auth.uid())
    from public.group_posts x left join public.profiles p on p.user_id = x.user_id
    where x.group_id = gid and x.kind = k order by x.created_at desc limit 50;
end $$;

create or replace function public.group_post(gid uuid, k text, txt text, is_anon boolean) returns void
language plpgsql security definer set search_path = public as $$
declare t text := btrim(coalesce(txt,''));
begin
  if not public._is_member(gid) then raise exception 'not allowed'; end if;
  if k not in ('wall','devo') then raise exception 'bad kind'; end if;
  if k = 'devo' and not public._is_leader(gid) then raise exception 'not allowed'; end if;
  if char_length(t) < 1 or char_length(t) > 1000 then raise exception 'bad length'; end if;
  if (select count(*) from public.group_posts where user_id = auth.uid() and created_at > now() - interval '1 day') >= 20 then
    raise exception 'too many posts today';
  end if;
  insert into public.group_posts (group_id, user_id, kind, body, anon) values (gid, auth.uid(), k, t, coalesce(is_anon,false) and k = 'wall');
end $$;

create or replace function public.group_post_delete(pid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid; uid uuid;
begin
  select group_id, user_id into gid, uid from public.group_posts where id = pid;
  if gid is null then return; end if;
  if uid = auth.uid() or public._is_leader(gid) or public._is_staff() then delete from public.group_posts where id = pid;
  else raise exception 'not allowed'; end if;
end $$;

create or replace function public.group_remove(gid uuid, mid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (public._is_leader(gid) or public._is_staff()) then raise exception 'not allowed'; end if;
  delete from public.group_members where group_id = gid and user_id = mid;
end $$;

create or replace function public.group_add_leader(gid uuid, em text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not public._is_staff() then raise exception 'not allowed'; end if;
  select u.id into uid from auth.users u where lower(u.email) = lower(btrim(em));
  if uid is null then raise exception 'no such account'; end if;
  insert into public.group_members (group_id, user_id, role) values (gid, uid, 'leader')
    on conflict (group_id, user_id) do update set role = 'leader';
end $$;

create or replace function public.pastor_groups()
returns table(id uuid, name text, code text, leader text, members int, active_today int, finished int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_staff() then raise exception 'not allowed'; end if;
  return query
    select g.id, g.name, g.code,
      (select coalesce(nullif(p.name,''),'?') from public.group_members m left join public.profiles p on p.user_id = m.user_id where m.group_id = g.id and m.role = 'leader' order by m.joined_at limit 1),
      (select count(*)::int from public.group_members m where m.group_id = g.id),
      (select count(*)::int from public.group_members m where m.group_id = g.id and exists (select 1 from public.completions c where c.user_id = m.user_id and c.completed_on = (now() at time zone 'Europe/Stockholm')::date)),
      (select count(*)::int from public.group_members m join public.progress pr on pr.user_id = m.user_id where m.group_id = g.id and jsonb_array_length(coalesce(pr.data->'done','[]'::jsonb)) >= 21)
    from public.groups g order by g.name;
end $$;

revoke all on function public.group_create(text), public.group_join(text), public.group_leave(uuid), public.group_mine(),
  public.group_members_list(uuid), public.group_posts_list(uuid,text), public.group_post(uuid,text,text,boolean),
  public.group_post_delete(uuid), public.group_remove(uuid,uuid), public.group_add_leader(uuid,text), public.pastor_groups() from public, anon;
grant execute on function public.group_create(text), public.group_join(text), public.group_leave(uuid), public.group_mine(),
  public.group_members_list(uuid), public.group_posts_list(uuid,text), public.group_post(uuid,text,text,boolean),
  public.group_post_delete(uuid), public.group_remove(uuid,uuid), public.group_add_leader(uuid,text), public.pastor_groups() to authenticated;
