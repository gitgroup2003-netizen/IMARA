// Pure helpers (no DOM) so they can be unit-tested in Node.
export const round2 = n => Math.round((n + Number.EPSILON) * 100) / 100;
export const usd = n => "$" + Number(n).toFixed(2);
export const money = (n, c) => {
  const d = c?.decimals ?? 0;
  return `${c?.symbol ?? ""} ${Number(n).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d })}`.trim();
};
// Mirrors pay_service() in the database. The server is the source of truth.
export const quote = (amountLocal, perUsd, feeRate) => {
  const base = round2(amountLocal / perUsd), fee = round2(base * feeRate);
  return { base, fee, total: round2(base + fee) };
};
export const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
