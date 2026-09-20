// Native AOT差分検証のfixture別timing telemetry。
//
// 性能値は毎回変動するため、canonicalな互換性artifact／attestation evidenceには
// 含めない。本モジュールが出力するtiming documentは別ファイル・別artifactとして
// 扱い、shard再配分（median weight table）の入力にのみ使用する。
import { writeFile } from "node:fs/promises";
import { isAbsolute } from "node:path";

export const TIMING_SCHEMA = "lnako.native-oracle-timing.v1";
export const TIMING_STATUSES = ["success", "comparison-failure", "infrastructure-failure"];
const OPTIMIZATIONS = ["O0", "O1", "O2", "O3"];

export function platformKey(platform = process.platform, arch = process.arch) {
  return `${platform}-${arch}`;
}

export function roundMs(value) {
  if (!Number.isFinite(value) || value < 0) throw new Error(`timing値が不正です: ${value}`);
  return Math.round(value);
}

/**
 * `--timing <path>` / `--timing=<path>` / `LNAKO_NATIVE_ORACLE_TIMING` を解決する。
 * 出力先は絶対パス必須で、引数とenvが両方あれば一致を要求する（設定ミスの検出）。
 */
export function parseTimingPath(argv, env = process.env) {
  const arguments_ = argv.filter((argument) => argument === "--timing" || argument.startsWith("--timing="));
  if (arguments_.length > 1) throw new Error("--timingは1回だけ指定してください");
  const flagIndex = argv.indexOf("--timing");
  const inline = argv.find((argument) => argument.startsWith("--timing="));
  if (flagIndex >= 0 && argv[flagIndex + 1] === undefined) throw new Error("--timingには出力先を指定してください");
  const argumentPath = flagIndex >= 0 ? argv[flagIndex + 1] : inline?.slice("--timing=".length);
  const environmentPath = env.LNAKO_NATIVE_ORACLE_TIMING;
  if (argumentPath !== undefined && argumentPath.length === 0) throw new Error("--timingの出力先が空です");
  if (environmentPath !== undefined && environmentPath.length === 0) throw new Error("LNAKO_NATIVE_ORACLE_TIMINGの出力先が空です");
  if (argumentPath !== undefined && !isAbsolute(argumentPath)) throw new Error("--timingには絶対パスを指定してください");
  if (environmentPath !== undefined && !isAbsolute(environmentPath)) throw new Error("LNAKO_NATIVE_ORACLE_TIMINGには絶対パスを指定してください");
  if (argumentPath !== undefined && environmentPath !== undefined && argumentPath !== environmentPath) {
    throw new Error("--timingとLNAKO_NATIVE_ORACLE_TIMINGの出力先が一致しません");
  }
  if (argumentPath !== undefined) return argumentPath;
  if (environmentPath !== undefined) return environmentPath;
  return null;
}

export function createTimingDocument({
  generatedAt = new Date().toISOString(),
  platform = process.platform,
  arch = process.arch,
  commit,
  concurrency,
  shard,
  totalFixtureCount,
  optimizations,
  status,
  fixtures,
}) {
  const document = {
    schema: TIMING_SCHEMA,
    generatedAt,
    platform: platformKey(platform, arch),
    commit,
    concurrency,
    shard,
    totalFixtureCount,
    optimizations,
    status,
    fixtures,
  };
  validateTimingDocument(document);
  return document;
}

export function validateTimingDocument(document) {
  assertExactKeys(document, ["schema", "generatedAt", "platform", "commit", "concurrency", "shard", "totalFixtureCount", "optimizations", "status", "fixtures"], "AOT timing document");
  if (document.schema !== TIMING_SCHEMA) throw new Error("AOT timing documentのschemaが不正です");
  if (typeof document.generatedAt !== "string" || Number.isNaN(Date.parse(document.generatedAt))) throw new Error("AOT timing documentの生成日時が不正です");
  if (typeof document.platform !== "string" || !/^[a-z0-9]+-[a-z0-9_]+$/.test(document.platform)) throw new Error(`AOT timing documentのplatformが不正です: ${document.platform}`);
  if (typeof document.commit !== "string" || !/^[0-9a-f]{40}$/i.test(document.commit)) throw new Error("AOT timing documentのcommitが不正です");
  if (!Number.isSafeInteger(document.concurrency) || document.concurrency < 1 || document.concurrency > 8) throw new Error("AOT timing documentのconcurrencyが不正です");
  if (!Number.isSafeInteger(document.totalFixtureCount) || document.totalFixtureCount < 0) throw new Error("AOT timing documentのtotalFixtureCountが不正です");
  if (!TIMING_STATUSES.includes(document.status)) throw new Error("AOT timing documentのstatusが不正です");
  assertStringArray(document.optimizations, OPTIMIZATIONS, "AOT timing documentのoptimizations");
  if (document.shard !== null) {
    assertExactKeys(document.shard, ["index", "count"], "AOT timing documentのshard");
    if (!Number.isSafeInteger(document.shard.index) || !Number.isSafeInteger(document.shard.count) ||
        document.shard.count < 1 || document.shard.index < 0 || document.shard.index >= document.shard.count) {
      throw new Error("AOT timing documentのshardが不正です");
    }
  }
  if (!Array.isArray(document.fixtures)) throw new Error("AOT timing documentのfixturesが配列ではありません");
  if (document.status === "infrastructure-failure" && document.fixtures.length !== 0) throw new Error("インフラ失敗のtiming documentにfixture timingがあります");
  if (document.fixtures.length > document.totalFixtureCount) throw new Error("AOT timing documentのfixture数が総数を超えています");
  const ids = new Set();
  for (const fixture of document.fixtures) {
    assertExactKeys(fixture, ["id", "platform", "optimizations", "officialSourceMs", "officialGeneratedMs", "interpreterMs", "native", "totalMs"], "AOT timing fixture");
    if (typeof fixture.id !== "string" || fixture.id.length === 0 || ids.has(fixture.id)) throw new Error(`AOT timing fixtureのidが不正または重複しています: ${fixture.id}`);
    ids.add(fixture.id);
    if (fixture.platform !== document.platform) throw new Error(`AOT timing fixtureのplatformがdocumentと一致しません: ${fixture.id}`);
    assertStringArray(fixture.optimizations, OPTIMIZATIONS, `AOT timing fixture(${fixture.id})のoptimizations`);
    if (fixture.optimizations.some((optimization) => !document.optimizations.includes(optimization))) {
      throw new Error(`AOT timing fixtureのoptimizationsがdocumentの計測対象外です: ${fixture.id}`);
    }
    for (const field of ["officialSourceMs", "officialGeneratedMs", "interpreterMs", "totalMs"]) {
      if (!Number.isSafeInteger(fixture[field]) || fixture[field] < 0) throw new Error(`AOT timing fixtureの${field}が不正です: ${fixture.id}`);
    }
    if (!Array.isArray(fixture.native)) throw new Error(`AOT timing fixtureのnativeが配列ではありません: ${fixture.id}`);
    const measured = fixture.native.map((entry) => {
      assertExactKeys(entry, ["optimization", "buildMs", "runMs"], `AOT timing fixture(${fixture.id})のnative`);
      if (!OPTIMIZATIONS.includes(entry.optimization)) throw new Error(`AOT timing fixtureのoptimizationが不正です: ${fixture.id}`);
      if (!Number.isSafeInteger(entry.buildMs) || entry.buildMs < 0 || !Number.isSafeInteger(entry.runMs) || entry.runMs < 0) {
        throw new Error(`AOT timing fixtureのnative timingが不正です: ${fixture.id}`);
      }
      return entry.optimization;
    });
    if (JSON.stringify(measured) !== JSON.stringify(fixture.optimizations)) {
      throw new Error(`AOT timing fixtureのoptimization一覧が一致しません: ${fixture.id}`);
    }
  }
  return document;
}

/**
 * 複数runのtiming documentから fixture × platform × optimization の代表値を求める。
 * 代表値は平均ではなくmedian（外れ値に強い）。Phase 3のshard weight tableの入力。
 *
 * 集約契約:
 * - 全documentの`concurrency`が一致していることを要求する。worker数が違うと
 *   競合条件が変わり、同じmedianへ混ぜると実在しない重みになるため。
 * - `status === "success"`のdocumentだけを集計する。`comparison-failure`は
 *   計測が途中で終わりうるため、weight推定の入力にしない。
 */
export function buildTimingAggregate(documents) {
  const validated = documents.map((document) => validateTimingDocument(document));
  const concurrencies = [...new Set(validated.map((document) => document.concurrency))].sort((left, right) => left - right);
  if (concurrencies.length > 1) {
    throw new Error(`timing documentのconcurrencyが混在しています: ${concurrencies.join(", ")}（同一concurrencyのdocumentだけを集約してください）`);
  }
  const usable = validated.filter((document) => document.status === "success");
  // 異なるcommitのfixture timingを混ぜると、同じfixtureの中央値が別リビジョンの
  // 実行を混ぜた値になる（再配分の入力として無意味）。concurrencyと同じく
  // 混在を拒否し、同一commitのdocumentだけを集約する。
  const commits = [...new Set(usable.map((document) => document.commit))].sort();
  if (commits.length > 1) {
    throw new Error(`timing documentのcommitが混在しています: ${commits.join(", ")}（同一commitのdocumentだけを集約してください）`);
  }
  const skipped = new Map();
  for (const document of validated) {
    if (document.status === "success") continue;
    skipped.set(document.status, (skipped.get(document.status) ?? 0) + 1);
  }
  const byFixture = new Map();
  const byOptimization = new Map();
  for (const document of usable) {
    for (const fixture of document.fixtures) {
      // `totalMs`は文書が選んだoptimization集合のbuild/runを全部含むため、
      // 集合が違う文書のtotalを同じ中央値へ混ぜると測定範囲が揃わない
      // （macOSはO0+O1と単独O2/O3の別文書を出す）。optimization集合を
      // 集約キーへ含め、同じ測定範囲の観測だけで中央値を出す。
      const optimizationSignature = [...fixture.optimizations].sort().join("+");
      const fixtureKey = `${fixture.platform}|${optimizationSignature}|${fixture.id}`;
      const fixtureEntry = byFixture.get(fixtureKey) ?? { platform: fixture.platform, optimizations: optimizationSignature, id: fixture.id, observations: [], totalMs: [], officialMs: [], interpreterMs: [] };
      fixtureEntry.observations.push({ commit: document.commit, concurrency: document.concurrency, totalMs: fixture.totalMs });
      fixtureEntry.totalMs.push(fixture.totalMs);
      fixtureEntry.officialMs.push(fixture.officialSourceMs + fixture.officialGeneratedMs);
      fixtureEntry.interpreterMs.push(fixture.interpreterMs);
      byFixture.set(fixtureKey, fixtureEntry);
      for (const entry of fixture.native) {
        const optimizationKey = `${fixture.platform}|${entry.optimization}|${fixture.id}`;
        const optimizationEntry = byOptimization.get(optimizationKey) ?? { platform: fixture.platform, optimization: entry.optimization, id: fixture.id, buildMs: [], runMs: [] };
        optimizationEntry.buildMs.push(entry.buildMs);
        optimizationEntry.runMs.push(entry.runMs);
        byOptimization.set(optimizationKey, optimizationEntry);
      }
    }
  }
  return {
    documents: validated.length,
    aggregatedDocuments: usable.length,
    skippedByStatus: [...skipped].sort(([left], [right]) => left.localeCompare(right)).map(([status, count]) => ({ status, count })),
    concurrency: concurrencies.length === 1 ? concurrencies[0] : null,
    commit: commits.length === 1 ? commits[0] : null,
    fixtures: [...byFixture.values()]
      .map((entry) => ({
        platform: entry.platform,
        optimizations: entry.optimizations,
        id: entry.id,
        observations: entry.observations.length,
        medianTotalMs: medianOf(entry.totalMs),
        medianOfficialMs: medianOf(entry.officialMs),
        medianInterpreterMs: medianOf(entry.interpreterMs),
      }))
      .sort((left, right) => right.medianTotalMs - left.medianTotalMs),
    optimizations: [...byOptimization.values()]
      .map((entry) => ({
        platform: entry.platform,
        optimization: entry.optimization,
        id: entry.id,
        observations: entry.buildMs.length,
        medianBuildMs: medianOf(entry.buildMs),
        medianRunMs: medianOf(entry.runMs),
      }))
      .sort((left, right) => right.medianBuildMs - left.medianBuildMs),
  };
}

export function medianOf(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

export async function writeTimingDocument(path, document) {
  validateTimingDocument(document);
  await writeFile(path, `${JSON.stringify(document, null, 2)}\n`, "utf8");
}

function assertExactKeys(value, expected, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value) || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...expected].sort())) {
    throw new Error(`${label}のkey一覧が不正です`);
  }
}

function assertStringArray(value, allowed, label) {
  if (!Array.isArray(value) || value.length === 0 || value.some((item) => typeof item !== "string" || !allowed.includes(item)) || new Set(value).size !== value.length) {
    throw new Error(`${label}が不正です`);
  }
  const order = allowed.filter((item) => value.includes(item));
  if (JSON.stringify(value) !== JSON.stringify(order)) throw new Error(`${label}の順序が不正です`);
}
