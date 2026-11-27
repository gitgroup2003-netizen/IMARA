// UI controller. Talks to the backend only through api.js.
import * as api from "./api.js";
import { money, usd, quote, esc, CATEGORIES, inCategory, placeholderFor } from "./format.js";

const $ = id => document.getElementById(id);
const S = { signup: false, uid: null, profile: null, countries: [], curMap: {}, services: [], svc: null, fee: 0.01, txs: [], idem: crypto.randomUUID() };
const cur = () => S.curMap[S.profile.currency];
const newKey = () => { S.idem = crypto.randomUUID(); };
const toast = m => { const t = $("toast"); t.textContent = m; t.hidden = false; clearTimeout(toast.h); toast.h = setTimeout(() => t.hidden = true, 3200); };
const guard = fn => async (...a) => { try { await fn(...a); } catch (e) { toast(e.message); } };

/* ---------- welcome / auth ---------- */
const setDial = () => {
  const c = S.countries.find(x => x.code === $("country").value);
  $("phone").placeholder = c ? c.dial + " …" : "Phone (optional)";
  $("curNote").textContent = c ? `Your balance is kept in USD. You pay bills in ${c.currency}.` : "";
};
async function loadCountries() {
  S.countries = await api.listCountries();
  $("country").innerHTML = S.countries.map(c => `<option value="${esc(c.code)}">${esc(c.name)}</option>`).join("");
  setDial();
}
$("country").onchange = setDial;
$("toggle").onclick = () => {
  S.signup = !S.signup;
  $("signupFields").hidden = !S.signup;
  $("authBtn").textContent = S.signup ? "Create account" : "Log in";
  $("toggle").textContent = S.signup ? "Already have an account? Log in" : "New here? Create an account";
  $("pw").autocomplete = S.signup ? "new-password" : "current-password";
  $("authMsg").textContent = "";
};
$("authBtn").onclick = async () => {
  const m = $("authMsg"), btn = $("authBtn"); m.className = "msg"; m.textContent = "Please wait…"; btn.disabled = true;
  try {
    const email = $("email").value.trim(), pw = $("pw").value;
    if (S.signup) {
      const fullName = $("fullName").value.trim();
      if (fullName.length < 2) throw new Error("Enter your full name");
      if (pw.length < 8) throw new Error("Use a password with at least 8 characters");
      const d = await api.signUp({ email, password: pw, fullName, country: $("country").value, phone: $("phone").value.trim() });
      if (!d.session) { m.className = "msg good"; m.textContent = "Check your email to confirm your account, then log in."; return; }
    } else await api.signIn(email, pw);
    m.textContent = "";
  } catch (e) {
    m.textContent = /database error/i.test(e.message) ? "Sign-up failed. Check your details and try again." : e.message;
  } finally { btn.disabled = false; }
};
$("out").onclick = () => api.signOut();

/* ---------- navigation ---------- */
function setView(v) {
  document.querySelectorAll(".view").forEach(e => e.classList.toggle("on", e.id === "v" + v));
  document.querySelectorAll("nav button").forEach(b => b.dataset.v === v ? b.setAttribute("aria-current", "page") : b.removeAttribute("aria-current"));
  window.scrollTo(0, 0);
}
document.querySelector("nav").onclick = e => { const b = e.target.closest("button"); if (b) setView(b.dataset.v); };
$("aPay").onclick = () => setView("Pay"); $("aHis").onclick = () => setView("Act"); $("seeAll").onclick = () => setView("Act");

/* ---------- services & quote ---------- */
function drawCats() {
  $("cats").innerHTML = CATEGORIES.map(c => `<button class="cat" data-c="${c.id}" aria-pressed="${c.id === S.cat}">${esc(c.label)}</button>`).join("");
}
$("cats").onclick = e => { const b = e.target.closest(".cat"); if (b) setCat(b.dataset.c); };
function setCat(c) {
  S.cat = c; drawCats();
  const list = inCategory(S.services, c), s = list.find(x => x.id === S.svc?.id) || list[0];
  if (s) pickSvc(s.id); else $("payTiles").innerHTML = `<p style="color:var(--mute)">Nothing here yet for your country.</p>`;
}
function homeCats() {
  $("homeTiles").innerHTML = CATEGORIES.map(c => `<button class="tile" data-c="${c.id}"><b style="background:${c.color};color:${c.text}">${c.badge}</b>${esc(c.label)}</button>`).join("");
  $("homeTiles").onclick = e => { const b = e.target.closest(".tile"); if (b) { setCat(b.dataset.c); setView("Pay"); } };
}
function tiles(el, pick) {
  el.innerHTML = inCategory(S.services, S.cat).map(x => `<button class="tile" data-id="${esc(x.id)}" aria-pressed="${x.id === S.svc?.id}"><b style="background:${esc(x.color)};color:${esc(x.text_color)}">${esc(x.badge)}</b>${esc(x.short)}</button>`).join("");
  el.onclick = e => { const b = e.target.closest(".tile"); if (b) pick(b.dataset.id); };
}
function pickSvc(id) {
  S.svc = S.services.find(x => x.id === id) || S.services[0];
  const dial = S.countries.find(c => c.code === S.profile.country)?.dial ?? "";
  $("rcpL").textContent = S.svc.field_label;
  $("rcp").placeholder = placeholderFor(S.svc.input_kind, dial);
  $("rcp").type = S.svc.input_kind === "email" ? "email" : S.svc.input_kind === "phone" ? "tel" : "text";
  tiles($("payTiles"), pickSvc); newKey();
}
function renderQuote() {
  const a = Number($("amt").value), c = cur(), q = $("quote");
  if (!a || a < c.per_usd * 0.25) { q.hidden = true; return; }
  const r = quote(a, c.per_usd, S.fee);
  q.hidden = false;
  q.innerHTML = `You pay <b>${usd(r.total)}</b><br><small>Rate: ${money(c.per_usd, c)} per $1 (updated ${new Date(c.updated_at).toLocaleDateString()}). Fee: ${usd(r.fee)}</small>`;
}
$("amt").addEventListener("input", () => { renderQuote(); newKey(); });
$("rcp").addEventListener("input", newKey);

/* ---------- data ---------- */
const txRow = t => {
  const dep = t.kind === "deposit", s = S.services.find(x => x.name === t.service) || { color: "#0B5F58", text_color: "#fff", badge: "+" };
  const c = S.curMap[t.currency];
  return `<div class="tx"><div class="b" style="background:${esc(s.color)};color:${esc(s.text_color)}">${esc(s.badge)}</div>
    <div>${esc(t.service)}<small>${esc(t.recipient || "Test deposit")} · ${new Date(t.created_at).toLocaleDateString()}</small></div>
    <div class="amt ${dep ? "pos" : ""}">${dep ? "+" : "−"}${usd(t.amount_usd)}${dep ? "" : `<small>${money(t.amount_local, c)}</small>`}</div></div>`;
};
const none = `<p style="color:var(--mute);margin:4px 0">Nothing yet. Tap Add to get test dollars, then pay a bill.</p>`;
async function loadWallet() {
  const [w, lim] = await Promise.all([api.getWallet(), api.getLimits().catch(() => null)]), b = Number(w?.balance_usd || 0);
  const left = lim ? Math.max(0, lim.daily_limit_usd - lim.spent_24h_usd) : null;
  $("bal").textContent = usd(b);
  $("balLocal").textContent = "About " + money(b * cur().per_usd, cur()) + (left === null ? "" : ` · ${usd(left)} left to spend today`);
  renderQuote();
}
async function loadTx() {
  S.txs = await api.listTx();
  $("recent").innerHTML = S.txs.length ? S.txs.slice(0, 3).map(txRow).join("") : none;
  $("all").innerHTML = S.txs.length ? S.txs.map(txRow).join("") : none;
  const now = new Date(), pays = S.txs.filter(t => t.kind === "payment" && new Date(t.created_at).getMonth() === now.getMonth() && new Date(t.created_at).getFullYear() === now.getFullYear());
  const totU = pays.reduce((a, t) => a + Number(t.amount_usd), 0), totL = pays.filter(t => t.currency === cur().code).reduce((a, t) => a + Number(t.amount_local), 0);
  $("spent").textContent = usd(totU); $("spentLocal").textContent = money(totL, cur());
  const by = {}; pays.forEach(t => by[t.service] = (by[t.service] || 0) + Number(t.amount_usd));
  const max = Math.max(0, ...Object.values(by));
  $("split").innerHTML = max ? Object.entries(by).sort((a, b) => b[1] - a[1]).map(([k, v]) => `<div class="row2"><span>${esc(k)}</span><b>${usd(v)}</b></div><div class="sp"><i style="width:${Math.round(v / max * 100)}%"></i></div>`).join("") : `<p style="color:var(--mute);margin:4px 0">No payments this month yet.</p>`;
}
const refresh = () => Promise.all([loadWallet(), loadTx()]);

/* ---------- actions ---------- */
$("aAdd").onclick = guard(async () => { await api.testDeposit(10); toast("Added $10 test dollars"); await refresh(); });
$("payBtn").onclick = async () => {
  const m = $("payMsg"), b = $("payBtn"), to = $("rcp").value.trim(); m.textContent = ""; b.disabled = true;
  try {
    const r = await api.pay({ serviceId: S.svc.id, recipient: to, amount: Number($("amt").value), idem: S.idem });
    const c = S.curMap[r.currency], row = (a, v) => `<div class="rw"><span>${a}</span><span>${v}</span></div>`;
    $("rcAmt").textContent = money(r.amount_local, c);
    $("rcRows").innerHTML = row("Service", esc(r.service)) + row("To", esc(to)) + row("You spent", usd(r.total_usd)) + row("Fee included", usd(r.fee_usd)) + row("Rate", `${money(r.rate, c)} per $1`) + row("Time", new Date().toLocaleString());
    $("form").hidden = true; $("receipt").hidden = false; newKey(); await refresh();
  } catch (e) { m.textContent = e.message; } finally { b.disabled = false; }
};
$("done").onclick = () => { $("amt").value = ""; $("quote").hidden = true; $("receipt").hidden = true; $("form").hidden = false; setView("Home"); };

/* ---------- session lifecycle ---------- */
async function boot() {
  const [profile, curs, fee] = await Promise.all([api.getProfile(), api.listCurrencies(), api.getFeeRate()]);
  if (!profile) throw new Error("Profile missing. Run migration 0002, then sign up again.");
  if (!S.countries.length) S.countries = await api.listCountries();
  S.profile = profile; S.fee = fee; S.curMap = Object.fromEntries(curs.map(c => [c.code, c]));
  S.services = await api.getServices(profile.country);
  const first = profile.full_name.split(" ")[0], c = cur(), co = S.countries.find(x => x.code === profile.country);
  $("hi").textContent = "Hello, " + first; $("av").textContent = $("av2").textContent = first.charAt(0).toUpperCase(); $("em").textContent = profile.full_name;
  $("meInfo").innerHTML = `<div class="rw"><span>Country</span><span>${esc(co?.name)}</span></div><div class="rw"><span>Pays bills in</span><span>${esc(c.code)}</span></div><div class="rw"><span>Phone</span><span>${esc(profile.phone || "Not set")}</span></div>`;
  $("amtL").textContent = "Amount in " + c.code; $("amt").placeholder = String(Math.round(c.per_usd * 3 / 100) * 100);
  S.cat = "airtime"; homeCats(); setCat(S.cat);
  await refresh(); setView("Home");
}
api.onSession(guard(async session => {
  $("welcome").hidden = !!session; $("app").hidden = !session;
  if (!session) { S.uid = null; if (!S.countries.length) await loadCountries(); return; }
  if (S.uid === session.user.id) return;
  S.uid = session.user.id; await boot();
}));
