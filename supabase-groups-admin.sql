-- 21 Days Fast: pastors manage group members by name. Run in the SAME project the app uses. Safe to run again.
-- Needs supabase-groups.sql to have been run first.

create or replace function public.staff_find_people(q text)
returns table(uid uuid, name text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_staff() then raise exception 'not allowed'; end if;
  return query
    select p.user_id, p.name from public.profiles p
    where p.name <> '' and (btrim(coalesce(q,'')) = '' or p.name ilike '%' || btrim(q) || '%')
    order by p.name limit 20;
end $$;

create or replace function public.group_admin_members(gid uuid)
returns table(mid uuid, name text, role text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public._is_staff() then raise exception 'not allowed'; end if;
  return query
    select m.user_id, coalesce(nullif(p.name,''), 'Member'), m.role
    from public.group_members m left join public.profiles p on p.user_id = m.user_id
    where m.group_id = gid order by (m.role = 'leader') desc, p.name;
end $$;

create or replace function public.group_set_role(gid uuid, mid uuid, r text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public._is_staff() then raise exception 'not allowed'; end if;
  if r not in ('member','leader') then raise exception 'bad role'; end if;
  if not exists (select 1 from public.groups where id = gid) then raise exception 'no such group'; end if;
  insert into public.group_members (group_id, user_id, role) values (gid, mid, r)
    on conflict (group_id, user_id) do update set role = excluded.role;
end $$;

revoke all on function public.staff_find_people(text), public.group_admin_members(uuid), public.group_set_role(uuid,uuid,text) from public, anon;
grant execute on function public.staff_find_people(text), public.group_admin_members(uuid), public.group_set_role(uuid,uuid,text) to authenticated;
notify pgrst, 'reload schema';
