import assert from "node:assert/strict";
import { test } from "node:test";

import { parseRange, rangesIntersect, jointSetsIntersect } from "./lib/package/semver_range.mjs";

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

test("prerelease専用の共通範囲は同tupleの比較子を要求する", () => {
  // `>=1.5.0-alpha <1.5.0` の候補は 1.5.0 の prerelease のみ。
  assert.equal(
    rangesIntersect(parseRange(">=1.0.0-alpha <2.0.0"), parseRange(">=1.5.0-alpha <1.5.0")),
    false,
  );
  assert.equal(
    rangesIntersect(parseRange(">=1.0.0 <2.0.0"), parseRange(">=1.5.0-alpha <1.5.0")),
    false,
  );
  assert.equal(
    rangesIntersect(parseRange(">=1.5.0-alpha <1.5.0"), parseRange(">=1.5.0-beta <1.5.0")),
    true,
  );
  // 共通部分に release が残るならゲートは不要。
  assert.equal(
    rangesIntersect(parseRange(">=1.0.0-alpha <2.0.0"), parseRange(">=1.5.0 <2.0.0")),
    true,
  );
});

test("3集合の組合せではprereleaseゲートを構成集合毎に評価する", () => {
  // `>=1.0.0 <1.9.0` は 1.5.0 の prerelease 比較子を持たないため、
  // `>=1.5.0-alpha` が同タプルの比較子を持っていてもゲートを代行しない。
  const a = parseRange(">=1.5.0-alpha <2.0.0")[0];
  const b = parseRange(">=1.0.0 <1.9.0")[0];
  const c = parseRange(">=1.5.0-beta <1.5.0")[0];
  assert.equal(jointSetsIntersect([a, b, c]), false);
  // match-all（空集合）も prerelease 比較子を持たないためゲートを通らない。
  assert.equal(jointSetsIntersect([[], c]), false);
  // exact 版: `=1.5.0-beta` は `>=1.0.0` では prerelease ゲートを通らない。
  const a2 = parseRange(">=1.5.0-alpha")[0];
  const b2 = parseRange(">=1.0.0")[0];
  const c2 = parseRange("1.5.0-beta")[0];
  assert.equal(jointSetsIntersect([a2, b2, c2]), false);
});

test("隣接tuple間のprerelease専用区間もゲートを要求する", () => {
  // `>1.5.0 <1.5.1` の候補は 1.5.1 の prerelease のみ。
  assert.equal(rangesIntersect(parseRange(">1.5.0 <1.5.1"), parseRange(">=1.0.0")), false);
  // 自身の集合がゲート用の比較子を持たないため、相手が同tupleの
  // prerelease 比較子を持っても非交差のまま。
  assert.equal(rangesIntersect(parseRange(">1.5.0 <1.5.1"), parseRange(">=1.5.1-alpha")), false);
  // 両方が 1.5.1 の prerelease 比較子を持つなら交差する。
  assert.equal(
    rangesIntersect(parseRange(">1.5.0 <1.5.1-alpha"), parseRange(">=1.5.1-0 <1.5.1")),
    true,
  );
  // 上端に release が含まれる、または隣接tupleでなければゲートは不要。
  assert.equal(rangesIntersect(parseRange(">1.5.0 <=1.5.1"), parseRange(">=1.0.0")), true);
  assert.equal(rangesIntersect(parseRange(">1.5.0 <1.5.3"), parseRange(">=1.0.0")), true);
});

test("下限なしの上端のみの空範囲は非交差と判定する", () => {
  // `>x`/`<x` は `<0.0.0-0`（空範囲）に展開されるため `*` とも交差しない。
  assert.equal(rangesIntersect(parseRange(">x"), parseRange("*")), false);
  assert.equal(rangesIntersect(parseRange("<x"), parseRange("*")), false);
  // `<0.0.0` の候補は (0,0,0) の prerelease のみで常に空。
  assert.equal(rangesIntersect(parseRange("<0.0.0"), parseRange("*")), false);
  // `<=0.0.0-0` ∩ `*` は prerelease ゲートを通らず非交差。
  assert.equal(rangesIntersect(parseRange("<=0.0.0-0"), parseRange("*")), false);
  // 同タプルのゲートを持つ集合とは交差する。
  assert.equal(rangesIntersect(parseRange("<=0.0.0-0"), parseRange(">=0.0.0-0")), true);
  // release が候補に残る上端は非空。
  assert.equal(rangesIntersect(parseRange("<1.0.0"), parseRange("*")), true);
  assert.equal(rangesIntersect(parseRange("<=0.0.0"), parseRange("*")), true);
});

test("改行区切りの比較子を受理する", () => {
  // TOML 複数行文字列では範囲内に改行を含められる。
  assert.deepEqual(parseRange(">=1.0.0\n<2.0.0"), parseRange(">=1.0.0 <2.0.0"));
  // 前後の改行はトリムされる。
  assert.deepEqual(parseRange("\n>=1.0.0\r\n"), parseRange(">=1.0.0"));
  // 改行のみの選択肢は `*` として扱う。
  assert.deepEqual(parseRange("1.0.0 || \n"), parseRange("1.0.0 || "));
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
