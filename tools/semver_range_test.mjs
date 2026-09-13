import assert from "node:assert/strict";
import { test } from "node:test";

import { parseRange, rangesIntersect } from "./lib/package/semver_range.mjs";

test("空白区切りの比較子列は後続トークンを取りこぼさない", () => {
  const sets = parseRange("> 1.2.3 <= 2.0.0");
  assert.deepEqual(sets, [
    [
      { op: "gt", version: { major: 1, minor: 2, patch: 3, prerelease: "" } },
      { op: "lte", version: { major: 2, minor: 0, patch: 0, prerelease: "" } },
    ],
  ]);
});

test("空白区切り演算子とprereleaseバージョンを受理する", () => {
  const sets = parseRange("> 1.2.3-alpha");
  assert.deepEqual(sets, [
    [{ op: "gt", version: { major: 1, minor: 2, patch: 3, prerelease: "alpha" } }],
  ]);
});

test("3つ以上の空白区切り比較子を連続して展開する", () => {
  const sets = parseRange(">= 1.0.0 < 2.0.0 != 1.5.0");
  // `!=` は比較子として解釈されないため null になる。
  assert.equal(sets, null);
  const spaced = parseRange(">= 1.0.0 < 2.0.0");
  assert.equal(spaced[0].length, 2);
  assert.equal(spaced[0][0].op, "gte");
  assert.equal(spaced[0][1].op, "lt");
});

test("ワイルドカードとの大小比較は空範囲または無制約になる", () => {
  assert.deepEqual(parseRange(">x"), [
    [{ op: "lt", version: { major: 0, minor: 0, patch: 0, prerelease: "0" } }],
  ]);
  assert.deepEqual(parseRange("<*"), [
    [{ op: "lt", version: { major: 0, minor: 0, patch: 0, prerelease: "0" } }],
  ]);
  assert.deepEqual(parseRange(">=*"), [[]]);
  assert.deepEqual(parseRange("<=*"), [[]]);
});

test("~> は ~ と同じ展開になる", () => {
  assert.deepEqual(parseRange("~>1.2.3"), parseRange("~1.2.3"));
  assert.deepEqual(parseRange("~> 1.2"), parseRange("~1.2"));
});

test("v と = の前置を受理する", () => {
  assert.deepEqual(parseRange("v1.2.3"), [
    [{ op: "eq", version: { major: 1, minor: 2, patch: 3, prerelease: "" } }],
  ]);
  assert.deepEqual(parseRange("= 1.2.3"), [
    [{ op: "eq", version: { major: 1, minor: 2, patch: 3, prerelease: "" } }],
  ]);
  assert.deepEqual(parseRange("=v1.2.3"), [
    [{ op: "eq", version: { major: 1, minor: 2, patch: 3, prerelease: "" } }],
  ]);
});

// node-semver 7.x は `[v=\s]*` 前置でこれらを受理するが、本実装は
// npm/node-semver#691 の次期メジャー提案どおり `v?` のみを許容する。
test("バージョン位置の = を拒否する", () => {
  assert.equal(parseRange("==1.2.3"), null);
  assert.equal(parseRange("> =1.2.3"), null);
  assert.equal(parseRange("= =1.2.3"), null);
  assert.equal(parseRange("1.2.3 - =2.0.0"), null);
});

test("prerelease の exact は同一tupleのprerelease比較子を要求する", () => {
  assert.equal(rangesIntersect(parseRange(">=1.0.0"), parseRange("2.0.0-alpha")), false);
  assert.equal(rangesIntersect(parseRange(">=2.0.0-alpha"), parseRange("2.0.0-alpha")), true);
});

test("空の || 枝は無制約として扱う", () => {
  assert.deepEqual(parseRange("2.0.0 ||"), [
    [{ op: "eq", version: { major: 2, minor: 0, patch: 0, prerelease: "" } }],
    [],
  ]);
});

test("範囲の交差判定", () => {
  assert.equal(rangesIntersect(parseRange(">=1.0.0 <2.0.0"), parseRange("^1.5.0")), true);
  assert.equal(rangesIntersect(parseRange(">=1.0.0 <2.0.0"), parseRange(">=2.0.0")), false);
  assert.equal(rangesIntersect(parseRange("1.x || >=3.0.0"), parseRange("^3.1.0")), true);
});
