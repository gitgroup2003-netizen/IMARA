// Data-access layer: every call to Supabase lives here.
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm";
import { SUPABASE_URL, SUPABASE_KEY } from "./config.js";

export const db = createClient(SUPABASE_URL, SUPABASE_KEY);
const ok = ({ data, error }) => { if (error) throw new Error(error.message); return data; };

export const listCountries = () => db.from("countries").select("*").order("name").then(ok);
export const listCurrencies = () => db.from("currencies").select("*").then(ok);
export const getServices = country => db.from("services").select("*").eq("country", country).order("sort").then(ok);
export const getProfile = () => db.from("profiles").select("*").maybeSingle().then(ok);
export const getWallet = () => db.from("wallets").select("balance_usd").maybeSingle().then(ok);
export const getFeeRate = async () => Number((await db.from("settings").select("value").eq("key", "fee_rate").maybeSingle().then(ok))?.value ?? 0.01);
export const listTx = () => db.from("transactions").select("*").order("created_at", { ascending: false }).limit(60).then(ok);
export const testDeposit = amount => db.rpc("test_deposit", { p_amount: amount }).then(ok);
export const pay = ({ serviceId, recipient, amount, idem }) =>
  db.rpc("pay_service", { p_service_id: serviceId, p_recipient: recipient, p_amount_local: amount, p_idem: idem }).then(ok);

export const signUp = async ({ email, password, fullName, country, phone }) =>
  ok(await db.auth.signUp({ email, password, options: { data: { full_name: fullName, country, phone } } }));
export const signIn = async (email, password) => ok(await db.auth.signInWithPassword({ email, password }));
export const signOut = () => db.auth.signOut();
export const onSession = cb => {
  db.auth.getSession().then(({ data }) => cb(data.session));
  db.auth.onAuthStateChange((_e, s) => cb(s));
};
