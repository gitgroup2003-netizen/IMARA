import test from "node:test";
import assert from "node:assert/strict";
import { quote, money, usd, esc, round2, CATEGORIES, inCategory, placeholderFor, segments } from "../js/format.js";

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

test("services are filtered by category", () => {
  const list = [{ id: "a", category: "online" }, { id: "b", category: "bills" }, { id: "c", category: "online" }];
  assert.deepEqual(inCategory(list, "online").map(s => s.id), ["a", "c"]);
  assert.equal(CATEGORIES.length, 4);
});
test("placeholder depends on the input type", () => {
  assert.equal(placeholderFor("email", "+254"), "you@example.com");
  assert.equal(placeholderFor("phone", "+254"), "+254 …");
  assert.equal(placeholderFor("number", "+254"), "Number on your bill");
});

test("spending segments are sorted and add up to 100%", () => {
  const s = segments({ Water: 1, Netflix: 3 });
  assert.deepEqual(s.map(x => x.label), ["Netflix", "Water"]);
  assert.equal(s.reduce((a, x) => a + x.pct, 0), 100);
  assert.deepEqual(segments({}), []);
});
