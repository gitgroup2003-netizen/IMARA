import test from "node:test";
import assert from "node:assert/strict";
import { quote, money, usd, esc, round2 } from "../js/format.js";

test("quote converts local currency to USD and adds the fee", () => {
  assert.deepEqual(quote(13000, 130, 0.01), { base: 100, fee: 1, total: 101 });
});
test("quote rounds to whole cents", () => {
  assert.deepEqual(quote(10000, 3600, 0.01), { base: 2.78, fee: 0.03, total: 2.81 });
});
test("money formats with symbol and separators", () => {
  assert.equal(money(130000, { symbol: "KSh", decimals: 0 }), "KSh 130,000");
});
test("usd always shows two decimals", () => { assert.equal(usd(2.5), "$2.50"); assert.equal(round2(1.005 + 0.0001), 1.01); });
test("esc neutralises HTML", () => { assert.equal(esc('<img src=x onerror="a">'), "&lt;img src=x onerror=&quot;a&quot;&gt;"); });
