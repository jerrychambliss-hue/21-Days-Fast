// Supabase Edge Function: sends the daily "21 Days" reminder to people whose chosen time has arrived.
// Called every 10 minutes by pg_cron (see supabase-push.sql). Needs these secrets:
//   VAPID_PUBLIC, VAPID_PRIVATE, VAPID_SUBJECT (mailto:...), CRON_KEY
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const MSG = {
  en: { title: "21 Days of Prayer and Fasting", body: "Take a few minutes to pause, rejoice, ask and yield. Today's reading is ready." },
  sv: { title: "21 dagar av bön och fasta", body: "Ta några minuter att pausa, glädjas, be och överlåta. Dagens läsning väntar." },
};

function localParts(tz: string, now: Date) {
  try {
    const f = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
    const p: Record<string, string> = {};
    for (const x of f.formatToParts(now)) p[x.type] = x.value;
    return { date: `${p.year}-${p.month}-${p.day}`, minutes: parseInt(p.hour, 10) * 60 + parseInt(p.minute, 10) };
  } catch (_e) { return null; }
}

Deno.serve(async (req) => {
  if (req.headers.get("x-cron-key") !== Deno.env.get("CRON_KEY")) return new Response("forbidden", { status: 403 });
  webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT")!, Deno.env.get("VAPID_PUBLIC")!, Deno.env.get("VAPID_PRIVATE")!);
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: subs, error } = await db.from("push_subs").select("*").gt("expires_at", new Date().toISOString());
  if (error) return new Response(error.message, { status: 500 });
  const now = new Date();
  let sent = 0, removed = 0, failed = 0;
  for (const s of subs || []) {
    const lp = localParts(s.tz || "Europe/Stockholm", now);
    if (!lp) continue;
    // due: today's chosen time has passed (but not by more than 3 hours) and we have not sent today
    if (s.last_sent_date === lp.date) continue;
    if (lp.minutes < s.minute_of_day || lp.minutes > s.minute_of_day + 180) continue;
    const m = MSG[s.lang === "sv" ? "sv" : "en"];
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify({ title: m.title, body: m.body, url: "./" }), { TTL: 3600 });
      await db.from("push_subs").update({ last_sent_date: lp.date }).eq("endpoint", s.endpoint);
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) { await db.from("push_subs").delete().eq("endpoint", s.endpoint); removed++; } else failed++;
    }
  }
  return new Response(JSON.stringify({ sent, removed, failed }), { headers: { "content-type": "application/json" } });
});
