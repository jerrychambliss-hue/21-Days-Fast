-- 21 Days Fast: daily push reminders.
-- Run in the SAME project the app uses (qlewbortlinmyhmseozz). Safe to run again.
-- Run it AFTER you have deployed the send-reminders function (see the steps).

create table if not exists public.push_subs (
  endpoint text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  tz text not null default 'Europe/Stockholm',
  minute_of_day int not null default 420 check (minute_of_day between 0 and 1439),
  lang text not null default 'en',
  last_sent_date text,
  expires_at timestamptz not null default (now() + interval '35 days'),
  created_at timestamptz not null default now()
);
alter table public.push_subs enable row level security;

create or replace function public.push_save(ep text, p256 text, au text, zone text, mins int, lng text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  insert into public.push_subs(endpoint, user_id, p256dh, auth, tz, minute_of_day, lang, last_sent_date, expires_at)
  values (ep, auth.uid(), p256, au, coalesce(nullif(zone, ''), 'Europe/Stockholm'), greatest(0, least(1439, coalesce(mins, 420))), case when lng = 'sv' then 'sv' else 'en' end, null, now() + interval '35 days')
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth, tz = excluded.tz,
    minute_of_day = excluded.minute_of_day, lang = excluded.lang, expires_at = excluded.expires_at;
end $$;
revoke all on function public.push_save(text, text, text, text, int, text) from public, anon;
grant execute on function public.push_save(text, text, text, text, int, text) to authenticated;

create or replace function public.push_delete(ep text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  delete from public.push_subs where endpoint = ep and user_id = auth.uid();
end $$;
revoke all on function public.push_delete(text) from public, anon;
grant execute on function public.push_delete(text) to authenticated;

-- Timer: call the function every 10 minutes.
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
select cron.unschedule('send-reminders') where exists (select 1 from cron.job where jobname = 'send-reminders');
select cron.schedule('send-reminders', '*/10 * * * *', $$
  select net.http_post(
    url := 'https://qlewbortlinmyhmseozz.supabase.co/functions/v1/send-reminders',
    headers := '{"Content-Type":"application/json","x-cron-key":"5829695e1fca82b5607ab492458640c46266fc56921bf2b5"}'::jsonb,
    body := '{}'::jsonb
  );
$$);

notify pgrst, 'reload schema';
