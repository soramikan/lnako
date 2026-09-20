import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  TIMING_SCHEMA,
  buildTimingAggregate,
  createTimingDocument,
  medianOf,
  parseTimingPath,
  platformKey,
  roundMs,
  validateTimingDocument,
  writeTimingDocument,
} from "./native_oracle_timing.mjs";
import { formatMs, formatTimingAggregate, loadTimingDocuments } from "./aggregate_native_timing.mjs";

const commit = "0".repeat(39) + "a";

function fixture(id, options = {}) {
  const optimizations = options.optimizations ?? ["O0"];
  return {
    id,
    platform: options.platform ?? "linux-x64",
    optimizations,
    officialSourceMs: options.officialSourceMs ?? 120,
    officialGeneratedMs: options.officialGeneratedMs ?? 130,
    interpreterMs: options.interpreterMs ?? 310,
    native: optimizations.map((optimization) => ({
      optimization,
      buildMs: options.buildMs ?? 5420,
      runMs: options.runMs ?? 80,
    })),
    totalMs: options.totalMs ?? 5930,
  };
}

function document(overrides = {}) {
  return createTimingDocument({
    generatedAt: "2026-09-19T14:00:00.000Z",
    platform: "linux",
    arch: "x64",
    commit,
    concurrency: 1,
    shard: { index: 0, count: 3 },
    totalFixtureCount: 342,
    optimizations: ["O0"],
    status: "success",
    fixtures: [fixture("example-id")],
    ...overrides,
  });
}

test("parseTimingPath validates argument and environment agreement", () => {
  assert.equal(parseTimingPath([], {}), null);
  assert.equal(parseTimingPath(["--no-build"], {}), null);
  assert.equal(parseTimingPath(["--timing", "/tmp/t.json"], {}), "/tmp/t.json");
  assert.equal(parseTimingPath(["--timing=/tmp/t.json"], {}), "/tmp/t.json");
  assert.equal(parseTimingPath([], { LNAKO_NATIVE_ORACLE_TIMING: "/tmp/e.json" }), "/tmp/e.json");
  assert.equal(parseTimingPath(["--timing", "/tmp/t.json"], { LNAKO_NATIVE_ORACLE_TIMING: "/tmp/t.json" }), "/tmp/t.json");

  assert.throws(() => parseTimingPath(["--timing"], {}), /出力先を指定/);
  assert.throws(() => parseTimingPath(["--timing", "/tmp/a", "--timing", "/tmp/b"], {}), /1回だけ/);
  assert.throws(() => parseTimingPath(["--timing", ""], {}), /空です/);
  assert.throws(() => parseTimingPath(["--timing", "relative/t.json"], {}), /絶対パス/);
  assert.throws(() => parseTimingPath([], { LNAKO_NATIVE_ORACLE_TIMING: "relative/t.json" }), /絶対パス/);
  assert.throws(() => parseTimingPath(["--timing", "/tmp/a"], { LNAKO_NATIVE_ORACLE_TIMING: "/tmp/b" }), /一致しません/);
});

test("createTimingDocument creates a schema-valid document", () => {
  const doc = document();
  assert.equal(doc.schema, TIMING_SCHEMA);
  assert.equal(doc.platform, platformKey("linux", "x64"));
  assert.deepEqual(validateTimingDocument(doc), doc);
  assert.equal(roundMs(12.6), 13);
  assert.throws(() => roundMs(Number.NaN), /timing値が不正/);
  assert.throws(() => roundMs(-1), /timing値が不正/);
});

test("validateTimingDocument rejects malformed documents", () => {
  const base = document();
  const mutate = (change) => {
    const copy = structuredClone(base);
    change(copy);
    return copy;
  };
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.extra = 1; })), /key一覧/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.schema = "other"; })), /schema/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.commit = "abc"; })), /commit/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.platform = "linux"; })), /platform/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.status = "ok"; })), /status/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.concurrency = 0; })), /concurrency/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.shard = { index: 3, count: 3 }; })), /shard/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.totalFixtureCount = 0; })), /総数を超え/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.status = "infrastructure-failure"; })), /インフラ失敗/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.fixtures = [fixture("a"), fixture("a")]; copy.totalFixtureCount = 342; })), /重複/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.fixtures[0].platform = "win32-x64"; })), /platformがdocumentと一致/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.fixtures[0].totalMs = -1; })), /totalMs/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.fixtures[0].totalMs = 1.5; })), /totalMs/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.fixtures[0].optimizations = ["O2"]; })), /計測対象外/);
  assert.throws(() => validateTimingDocument(mutate((copy) => { copy.optimizations = ["O1"]; })), /計測対象外/);
  const multi = document({
    optimizations: ["O0", "O1"],
    fixtures: [fixture("multi", { optimizations: ["O0", "O1"] })],
  });
  assert.equal(multi.fixtures[0].native.length, 2);
  assert.throws(
    () => validateTimingDocument({ ...structuredClone(multi), fixtures: [{ ...structuredClone(multi.fixtures[0]), native: [structuredClone(multi.fixtures[0].native[0])] }] }),
    /optimization一覧/,
  );
  const infrastructure = createTimingDocument({
    generatedAt: "2026-09-19T14:00:00.000Z",
    platform: "linux",
    arch: "x64",
    commit,
    concurrency: 2,
    shard: null,
    totalFixtureCount: 342,
    optimizations: ["O0", "O1"],
    status: "infrastructure-failure",
    fixtures: [],
  });
  assert.equal(infrastructure.fixtures.length, 0);
  assert.equal(infrastructure.shard, null);
});

test("buildTimingAggregate uses medians across runs", () => {
  const documents = [
    document({ fixtures: [fixture("a", { totalMs: 1000, buildMs: 100 }), fixture("b", { totalMs: 3000, buildMs: 300 })] }),
    document({ fixtures: [fixture("a", { totalMs: 1400, buildMs: 200 }), fixture("b", { totalMs: 5000, buildMs: 500 })] }),
    document({ fixtures: [fixture("a", { totalMs: 1200, buildMs: 300 }), fixture("b", { totalMs: 4000, buildMs: 400 })] }),
  ];
  const aggregate = buildTimingAggregate(documents);
  assert.equal(aggregate.documents, 3);
  assert.deepEqual(aggregate.fixtures.map((entry) => entry.id), ["b", "a"]);
  const a = aggregate.fixtures.find((entry) => entry.id === "a");
  assert.equal(a.observations, 3);
  assert.equal(a.medianTotalMs, 1200);
  assert.equal(a.medianOfficialMs, 250);
  assert.equal(a.medianInterpreterMs, 310);
  const aO0 = aggregate.optimizations.find((entry) => entry.id === "a");
  assert.equal(aO0.optimization, "O0");
  assert.equal(aO0.medianBuildMs, 200);
  assert.equal(aO0.medianRunMs, 80);
  assert.equal(medianOf([3, 1, 2]), 2);
  assert.equal(medianOf([4, 1, 3, 2]), 2.5);
  assert.equal(medianOf([]), null);
});

test("buildTimingAggregate separates optimizations and platforms", () => {
  const documents = [
    document({ optimizations: ["O0", "O3"], fixtures: [fixture("a", { optimizations: ["O0", "O3"] })] }),
    document({ platform: "win32", arch: "x64", optimizations: ["O0"], fixtures: [fixture("a", { platform: "win32-x64" })] }),
  ];
  const aggregate = buildTimingAggregate(documents);
  assert.equal(aggregate.fixtures.length, 2);
  assert.deepEqual([...new Set(aggregate.optimizations.map((entry) => entry.platform))].sort(), ["linux-x64", "win32-x64"]);
  assert.equal(aggregate.optimizations.filter((entry) => entry.platform === "linux-x64").length, 2);
});

test("writeTimingDocument writes validated JSON", async () => {
  const directory = await mkdtemp(join(tmpdir(), "lnako-timing-"));
  try {
    const path = join(directory, "timing.json");
    await writeTimingDocument(path, document());
    const written = JSON.parse(await readFile(path, "utf8"));
    assert.equal(written.schema, TIMING_SCHEMA);
    assert.equal(written.fixtures[0].id, "example-id");
    await assert.rejects(writeTimingDocument(path, { schema: "bad" }), /key一覧/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("loadTimingDocuments loads, validates and aggregates artifact directories", async () => {
  const directory = await mkdtemp(join(tmpdir(), "lnako-timing-artifacts-"));
  try {
    await writeTimingDocument(join(directory, "shard-0.json"), document({ fixtures: [fixture("a", { totalMs: 1000 })] }));
    await writeTimingDocument(join(directory, "shard-1.json"), document({ fixtures: [fixture("a", { totalMs: 2000 }), fixture("b", { totalMs: 500 })] }));
    await writeFile(join(directory, "notes.txt"), "ignore me", "utf8");
    const documents = await loadTimingDocuments(directory);
    assert.equal(documents.length, 2);
    const markdown = formatTimingAggregate(buildTimingAggregate(documents));
    assert.match(markdown, /AOT fixture timing aggregate/);
    assert.match(markdown, /入力document数: 2/);
    assert.match(markdown, /\| linux-x64 \| a \| O0 \| 2 \| 1\.50s \|/);

    // schema違い・破損JSONは黙って無視せず失敗させる。
    await writeFile(join(directory, "broken.json"), "{ not json", "utf8");
    await assert.rejects(loadTimingDocuments(directory), /JSONとして読めません/);
    await rm(join(directory, "broken.json"), { force: true });
    await writeFile(join(directory, "other.json"), JSON.stringify({ schema: "other.v1" }), "utf8");
    await assert.rejects(loadTimingDocuments(directory), /未知のtiming document schema/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("formatMs renders milliseconds and seconds", () => {
  assert.equal(formatMs(999), "999ms");
  assert.equal(formatMs(1500), "1.50s");
  assert.equal(formatMs(null), "-");
});

test("loadTimingDocuments reads artifact-name subdirectories and rejects deeper nesting", async () => {
  const directory = await mkdtemp(join(tmpdir(), "lnako-timing-nested-"));
  try {
    // `gh run download -p 'lnako-native-timing-*'` の既定展開（artifact名ディレクトリ）を再現する。
    await mkdir(join(directory, "lnako-native-timing-linux-x64-shard-0-O0-O1"), { recursive: true });
    await writeTimingDocument(join(directory, "lnako-native-timing-linux-x64-shard-0-O0-O1", "timing.json"), document({ fixtures: [fixture("a", { totalMs: 1000 })] }));
    await writeTimingDocument(join(directory, "top.json"), document({ fixtures: [fixture("a", { totalMs: 2000 })] }));
    const documents = await loadTimingDocuments(directory);
    assert.equal(documents.length, 2);
    assert.equal(documents.reduce((total, item) => total + item.fixtures.length, 0), 2);

    // 契約より深い階層は黙って無視せず失敗させる。
    await mkdir(join(directory, "too", "deep"), { recursive: true });
    await assert.rejects(loadTimingDocuments(directory), /展開階層が深すぎます/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("formatTimingAggregateは既定で全fixtureを出力する（--limitは明示時のみ）", () => {
  // この表はLPT再配分のweight入力であり、既定で切ると軽いfixtureが欠落する。
  const fixtures = Array.from({ length: 40 }, (_, index) => fixture(`fixture-${String(index).padStart(2, "0")}`, { totalMs: 100 + index }));
  const aggregate = buildTimingAggregate([document({ fixtures })]);
  const unlimited = formatTimingAggregate(aggregate);
  for (const entry of fixtures) assert.ok(unlimited.includes(`| linux-x64 | ${entry.id} |`), `${entry.id}が既定出力にありません`);
  const countRows = (markdown) => (markdown.match(/^\| linux-x64 \| fixture-/gm) ?? []).length;
  assert.equal(countRows(unlimited), fixtures.length);
  const limited = formatTimingAggregate(aggregate, { limit: 3 });
  assert.equal(countRows(limited), 3);
});

test("buildTimingAggregateはoptimization集合が違う文書を別行へ分ける", () => {
  // totalMsは文書の最適化集合のbuild/runを全部含むため、集合が違う観測を同じ
  // 中央値へ混ぜると測定範囲が揃わない（macOSはO0+O1と単独O2/O3の別文書を出す）。
  const aggregate = buildTimingAggregate([
    document({ optimizations: ["O0", "O1"], fixtures: [fixture("a", { optimizations: ["O0", "O1"], totalMs: 12_000 })] }),
    document({ optimizations: ["O2"], fixtures: [fixture("a", { optimizations: ["O2"], totalMs: 7_000 })] }),
    document({ optimizations: ["O3"], fixtures: [fixture("a", { optimizations: ["O3"], totalMs: 8_000 })] }),
  ]);
  const rows = aggregate.fixtures.filter((entry) => entry.id === "a");
  assert.equal(rows.length, 3);
  assert.deepEqual(rows.map((entry) => entry.optimizations).sort(), ["O0+O1", "O2", "O3"]);
  assert.equal(rows.find((entry) => entry.optimizations === "O0+O1").medianTotalMs, 12_000);
  assert.equal(rows.find((entry) => entry.optimizations === "O2").medianTotalMs, 7_000);
  const markdown = formatTimingAggregate(aggregate);
  assert.match(markdown, /\| linux-x64 \| a \| O0\+O1 \| 1 \| 12\.00s \|/);
});

test("buildTimingAggregate rejects mixed commits", () => {
  // 別commitのfixture timingを混ぜると同じfixtureの中央値が別リビジョンの実行を
  // 混ぜた値になり、再配分の入力として無意味になるため拒否する。
  const otherCommit = "b".repeat(40);
  assert.throws(
    () => buildTimingAggregate([document({}), document({ commit: otherCommit })]),
    /commitが混在/,
  );
  const aggregate = buildTimingAggregate([document({ fixtures: [fixture("a", { totalMs: 1000, buildMs: 100 })] })]);
  assert.equal(aggregate.commit, commit);
});

test("buildTimingAggregate rejects mixed concurrency and excludes non-success documents", () => {
  assert.throws(() => buildTimingAggregate([document({ concurrency: 1 }), document({ concurrency: 2 })]), /concurrencyが混在/);
  const aggregate = buildTimingAggregate([
    document({ fixtures: [fixture("a", { totalMs: 1000, buildMs: 100 }), fixture("b", { totalMs: 3000, buildMs: 300 })] }),
    document({ status: "comparison-failure", fixtures: [fixture("a", { totalMs: 9000, buildMs: 900 }), fixture("b", { totalMs: 9000, buildMs: 900 })] }),
  ]);
  assert.equal(aggregate.documents, 2);
  assert.equal(aggregate.aggregatedDocuments, 1);
  assert.deepEqual(aggregate.skippedByStatus, [{ status: "comparison-failure", count: 1 }]);
  assert.equal(aggregate.concurrency, 1);
  assert.equal(aggregate.fixtures.find((entry) => entry.id === "a").medianTotalMs, 1000);
  assert.equal(aggregate.optimizations.find((entry) => entry.id === "a").medianBuildMs, 100);
  const markdown = formatTimingAggregate(aggregate);
  assert.match(markdown, /集約対象: 1、concurrency: 1/);
  assert.match(markdown, /除外したstatus: comparison-failure×1/);
});
