import assert from "node:assert/strict";
import { test } from "node:test";
import { mergeCoverageShards } from "./lib/coverage_merge.mjs";
import { coverageFixtureStem } from "./lib/coverage_fixtures.mjs";

const catalog = {
  commands: [
    { id: "c1", name: "命令A", status: "native" },
    { id: "c2", name: "命令B", status: "native" },
    { id: "c3", name: "命令C", status: "native" },
    { id: "c4", name: "命令D", status: "interpreter" },
  ],
};
const fixtureOrder = ["f.json/fa", "f.json/fb", "f.json/fc", "f.json/fd"];

const fixtureReport = (file, id, names = ["命令A"]) => ({
  id,
  file,
  sourceSha256: "ab",
  associatedCommandNames: names,
  associationWithoutDispatch: names.map((name) => ({ name, catalogIds: [] })),
});
const site = (fixtureId, siteId, catalogId = "c1", name = "命令A") => ({ fixtureId, file: "f.json", siteId, catalogId, name });
const shardDoc = (index, fixtures, { sites = [], unresolved = [], count = 2 } = {}) => ({
  schema: "lnako.dispatch-coverage.v1",
  kind: "sampled-unattested-dispatch-audit-shard",
  baseline: { tag: "3.7.24", commit: "aa18c7e" },
  scope: {
    catalogEntries: 4,
    nativeEntries: 3,
    nativeUniqueNames: 3,
    fixtureSelection: "full",
    fixtureCount: fixtures.length,
    fixtureShard: { mode: "weighted-source-command", index, count, totalFixtureCount: fixtureOrder.length, selectedFixtureCount: fixtures.length },
    excludedFixtures: [{ key: "f.json/fx", reason: "r" }],
    commandAssociationIsNotExecutionEvidence: true,
  },
  provenance: { environment: { platform: "linux", arch: "x64", node: "v24" }, oracle: { build: 4 } },
  coverage: { unresolvedObservedSites: unresolved },
  fixtures,
  sites,
});

test("coverageFixtureStem は shard index に依存せず fixture identity から一意になる", () => {
  const left = coverageFixtureStem({ file: "plugin-system-cases.json", id: "plugin-system-math" });
  const right = coverageFixtureStem({ file: "plugin-system-cases.json", id: "plugin-system-math" });
  assert.equal(left, "plugin-system-cases-plugin-system-math");
  assert.equal(left, right);
  assert.notEqual(
    coverageFixtureStem({ file: "native-cases.json", id: "plugin-system-math" }),
    left,
  );
  assert.throws(() => coverageFixtureStem({ file: "a/b.json", id: "x" }), /stemが不正/);
});

test("mergeCoverageShards は pool 順で fixture/unresolved を並べ coverage を再計算する", () => {
  const shards = [
    shardDoc(0, [fixtureReport("f.json", "fd"), fixtureReport("f.json", "fa")], {
      sites: [site("fd", "0x4"), site("fa", "0x2")],
      unresolved: [{ fixtureId: "fd", file: "f.json", siteId: "0x9", sourceName: "不明B" }],
    }),
    shardDoc(1, [fixtureReport("f.json", "fc"), fixtureReport("f.json", "fb")], {
      sites: [site("fc", "0x1", "c2", "命令B")],
      unresolved: [{ fixtureId: "fb", file: "f.json", siteId: "0x8", sourceName: "不明A" }],
    }),
  ];
  const merged = mergeCoverageShards(shards, { fixtureOrder, catalog });
  assert.equal(merged.kind, "sampled-unattested-dispatch-audit");
  assert.equal(merged.scope.fixtureCount, 4);
  assert.equal(merged.scope.fixtureShard, undefined);
  assert.deepEqual(merged.fixtures.map((fixture) => fixture.id), ["fa", "fb", "fc", "fd"]);
  assert.deepEqual(merged.sites.map((entry) => `${entry.fixtureId}/${entry.siteId}`), ["fa/0x2", "fc/0x1", "fd/0x4"]);
  assert.deepEqual(merged.coverage.unresolvedObservedSites.map((entry) => entry.siteId), ["0x8", "0x9"]);
  assert.equal(merged.coverage.unambiguousObservedNativeEntries, 2);
  assert.deepEqual(merged.coverage.unobservedNativeEntryIds, ["c3"]);
  assert.equal(merged.coverage.associationWithoutDispatchCount, 4);
  assert.equal(merged.provenance.environment.platform, "linux");
});

test("mergeCoverageShards は重複fixtureを拒否する", () => {
  const shards = [
    shardDoc(0, [fixtureReport("f.json", "fa"), fixtureReport("f.json", "fb")]),
    shardDoc(1, [fixtureReport("f.json", "fb"), fixtureReport("f.json", "fc"), fixtureReport("f.json", "fd")]),
  ];
  assert.throws(() => mergeCoverageShards(shards, { fixtureOrder, catalog }), /重複実行/);
});

test("mergeCoverageShards は不完全なfixture集合を拒否する", () => {
  const shards = [
    shardDoc(0, [fixtureReport("f.json", "fa")]),
    shardDoc(1, [fixtureReport("f.json", "fb"), fixtureReport("f.json", "fc")]),
  ];
  assert.throws(() => mergeCoverageShards(shards, { fixtureOrder, catalog }), /不完全/);
});

test("mergeCoverageShards は pool 外fixtureを拒否する", () => {
  const shards = [
    shardDoc(0, [fixtureReport("f.json", "fa"), fixtureReport("f.json", "fz")]),
    shardDoc(1, [fixtureReport("f.json", "fb"), fixtureReport("f.json", "fc"), fixtureReport("f.json", "fd")]),
  ];
  assert.throws(() => mergeCoverageShards(shards, { fixtureOrder, catalog }), /選択集合外/);
});

test("mergeCoverageShards は index 重複と scope 不一致を拒否する", () => {
  const duplicated = [
    shardDoc(0, [fixtureReport("f.json", "fa"), fixtureReport("f.json", "fb")]),
    shardDoc(0, [fixtureReport("f.json", "fc"), fixtureReport("f.json", "fd")]),
  ];
  assert.throws(() => mergeCoverageShards(duplicated, { fixtureOrder, catalog }), /index\/count/);

  const mismatched = [
    shardDoc(0, [fixtureReport("f.json", "fa"), fixtureReport("f.json", "fb")]),
    shardDoc(1, [fixtureReport("f.json", "fc"), fixtureReport("f.json", "fd")]),
  ];
  mismatched[1].scope.fixtureSelection = "default";
  assert.throws(() => mergeCoverageShards(mismatched, { fixtureOrder, catalog }), /fixtureSelection/);
});

test("mergeCoverageShards は全件artifactや不足したshardを拒否する", () => {
  const full = shardDoc(0, [fixtureReport("f.json", "fa")]);
  full.kind = "sampled-unattested-dispatch-audit";
  delete full.scope.fixtureShard;
  assert.throws(() => mergeCoverageShards([full, shardDoc(1, [])], { fixtureOrder, catalog }), /shard artifactではありません/);
  assert.throws(() => mergeCoverageShards([shardDoc(0, [fixtureReport("f.json", "fa")])], { fixtureOrder, catalog }), /不足/);
});
