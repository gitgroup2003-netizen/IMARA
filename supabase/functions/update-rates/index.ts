// Scheduled daily. Fetches USD rates and stores them through the guarded set_rate() function.
// Rates by ExchangeRate-API (https://www.exchangerate-api.com), open access, attribution required.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SOURCE = "https://open.er-api.com/v6/latest/USD";

Deno.serve(async (req) => {
  if (!Deno.env.get("CRON_SECRET") || req.headers.get("x-cron-secret") !== Deno.env.get("CRON_SECRET")) {
    return new Response("Forbidden", { status: 403 });
  }
  const db = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  const { data: curs, error } = await db.from("currencies").select("code");
  if (error) return Response.json({ error: error.message }, { status: 500 });

  const res = await fetch(SOURCE);
  const body = await res.json().catch(() => null);
  const rates = body?.rates ?? body?.conversion_rates;
  if (!res.ok || body?.result !== "success" || !rates) {
    return Response.json({ error: "Rate source unavailable" }, { status: 502 });
  }

  const results = [];
  for (const { code } of curs) {
    const rate = Number(rates[code]);
    if (!rate) { results.push({ code, ok: false, error: "no rate in feed" }); continue; }
    const { data, error: e } = await db.rpc("set_rate", { p_currency: code, p_per_usd: rate, p_source: "open.er-api.com" });
    results.push(e ? { code, ok: false, error: e.message } : { code, ok: true, ...data });
  }
  return Response.json({ results });
});
