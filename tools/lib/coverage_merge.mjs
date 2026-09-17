// dispatch coverage shard artifact を全件実行と同じ形へ merge する。
// fixture/unresolved site の順序は loadSelectedFixtures() の pool 順（= 全件実行順）、
// sites は compareSites 順、coverage.* は merge 済み集合から再計算する。
// 再計算しないメタデータ（kind/scope/provenance）は代表 shard の値を使い、
// 比較側が freshnessBytes（environment 除去）で正本と照合する。

import { compareSites, coverageSummary } from "./coverage_sites.mjs";

export function mergeCoverageShards(shardDocuments, { fixtureOrder, catalog }) {
  if (!Array.isArray(shardDocuments) || shardDocuments.length < 2) {
    throw new Error("merge対象のdispatch coverage shardが不足しています");
  }
  const orderIndex = new Map(fixtureOrder.map((key, index) => [key, index]));
  const reference = shardDocuments[0];
  const seenIndexes = new Set();
  const fixtureKeys = new Set();
  const fixtureReports = [];
  const sites = [];
  const unresolvedSites = [];

  for (const shard of shardDocuments) {
    if (shard?.schema !== "lnako.dispatch-coverage.v1" || shard?.kind !== "sampled-unattested-dispatch-audit-shard") {
      throw new Error("merge対象がdispatch coverage shard artifactではありません");
    }
    const shardMeta = shard.scope?.fixtureShard;
    if (shardMeta === undefined || !Number.isSafeInteger(shardMeta.index) || !Number.isSafeInteger(shardMeta.count) ||
        shardMeta.index < 0 || shardMeta.index >= shardMeta.count || shardMeta.count !== shardDocuments.length ||
        seenIndexes.has(shardMeta.index)) {
      throw new Error("dispatch coverage shardのindex/countが不正または重複しています");
    }
    seenIndexes.add(shardMeta.index);
    for (const key of ["catalogEntries", "nativeEntries", "nativeUniqueNames", "fixtureSelection", "commandAssociationIsNotExecutionEvidence"]) {
      if (JSON.stringify(shard.scope?.[key]) !== JSON.stringify(reference.scope?.[key])) {
        throw new Error(`dispatch coverage shard間でscope.${key}が一致しません`);
      }
    }
    if (JSON.stringify(shard.baseline) !== JSON.stringify(reference.baseline) ||
        JSON.stringify(shard.scope?.excludedFixtures) !== JSON.stringify(reference.scope?.excludedFixtures)) {
      throw new Error("dispatch coverage shard間でbaseline/excludedFixturesが一致しません");
    }
    for (const fixture of shard.fixtures ?? []) {
      const key = `${fixture.file}/${fixture.id}`;
      if (fixtureKeys.has(key)) throw new Error(`dispatch coverage shardがfixtureを重複実行しています: ${key}`);
      if (!orderIndex.has(key)) throw new Error(`dispatch coverage shardのfixtureが選択集合外です: ${key}`);
      fixtureKeys.add(key);
      fixtureReports.push({ key, fixture });
    }
    for (const site of shard.sites ?? []) sites.push(site);
    for (const site of shard.coverage?.unresolvedObservedSites ?? []) {
      const key = `${site.file}/${site.fixtureId}`;
      if (!orderIndex.has(key)) throw new Error(`dispatch coverage shardのunresolved siteが選択集合外です: ${key}`);
      unresolvedSites.push({ key, site });
    }
  }
  if (fixtureKeys.size !== fixtureOrder.length) {
    throw new Error(`dispatch coverage shardのfixture集合が不完全です: ${fixtureKeys.size}/${fixtureOrder.length}`);
  }

  fixtureReports.sort((left, right) => orderIndex.get(left.key) - orderIndex.get(right.key));
  unresolvedSites.sort((left, right) => orderIndex.get(left.key) - orderIndex.get(right.key));
  const orderedFixtures = fixtureReports.map((entry) => entry.fixture);
  const orderedUnresolved = unresolvedSites.map((entry) => entry.site);
  const { summary } = coverageSummary({ fixtureReports: orderedFixtures, sites, unresolvedSites: orderedUnresolved, catalog });

  return {
    schema: "lnako.dispatch-coverage.v1",
    kind: "sampled-unattested-dispatch-audit",
    baseline: reference.baseline,
    scope: {
      catalogEntries: reference.scope.catalogEntries,
      nativeEntries: reference.scope.nativeEntries,
      nativeUniqueNames: reference.scope.nativeUniqueNames,
      fixtureSelection: reference.scope.fixtureSelection,
      fixtureCount: orderedFixtures.length,
      excludedFixtures: reference.scope.excludedFixtures,
      commandAssociationIsNotExecutionEvidence: true,
    },
    provenance: reference.provenance,
    coverage: summary,
    fixtures: orderedFixtures,
    sites: sites.sort(compareSites),
  };
}
