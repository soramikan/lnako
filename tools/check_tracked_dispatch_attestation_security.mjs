import { createHash } from "node:crypto";
import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import { computeSourceManifestSha256Sync } from "./lib/evidence/manifest.mjs";
import { trackedAttestationSubjects } from "./lib/evidence/attested_files.mjs";
import { sourceManifestDeclarationBasename, sourceManifestDeclarationBytes } from "./lib/evidence/source_manifest.mjs";

const root = resolve(import.meta.dirname, "..");
const source = resolve(root, "compat/v3.7.24/attestations/32983175945");
const temporary = await mkdtemp(join(tmpdir(), "lnako-tracked-attestation-"));
try {
  await cp(source, temporary, { recursive: true });
  const manifestPath = join(temporary, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.targetCommit = "0".repeat(40);
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  const result = spawnSync(process.execPath, [resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "--directory", temporary], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes("target commitが不正です")) {
    throw new Error(`対象commitの改変を拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  console.log("追跡dispatch attestation安全性検査: manifestの対象commit改変を拒否");
} finally {
  await rm(temporary, { recursive: true, force: true });
}

const catalogTemporary = await mkdtemp(join(tmpdir(), "lnako-tracked-catalog-"));
try {
  await cp(source, catalogTemporary, { recursive: true });
  const catalogPath = join(catalogTemporary, "catalog-evidence-verified.json");
  const catalog = JSON.parse(await readFile(catalogPath, "utf8"));
  catalog.entries[0].reason = "改変されたcatalog evidence";
  const catalogBytes = `${JSON.stringify(catalog, null, 2)}\n`;
  await writeFile(catalogPath, catalogBytes);
  const manifestPath = join(catalogTemporary, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.artifactSha256["catalog-evidence-verified.json"] = createHash("sha256").update(catalogBytes).digest("hex");
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  const result = spawnSync(process.execPath, [resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "--directory", catalogTemporary, "--offline"], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes("historical catalog evidenceがbase catalogと署名dispatchから導出できません")) {
    throw new Error(`catalog entryの改変を拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  console.log("追跡dispatch attestation安全性検査: catalog entry改変を拒否");
} finally {
  await rm(catalogTemporary, { recursive: true, force: true });
}

const bundleTemporary = await mkdtemp(join(tmpdir(), "lnako-tracked-bundle-"));
try {
  await cp(source, bundleTemporary, { recursive: true });
  const bundlePath = join(bundleTemporary, "sigstore-bundle.json");
  const bundle = JSON.parse(await readFile(bundlePath, "utf8"));
  bundle.dsseEnvelope.signatures[0].sig = Buffer.from("forged-signature").toString("base64");
  const bundleBytes = `${JSON.stringify(bundle, null, 2)}\n`;
  await writeFile(bundlePath, bundleBytes);
  const attestationPath = join(bundleTemporary, "dispatch-attestation.json");
  const attestation = JSON.parse(await readFile(attestationPath, "utf8"));
  attestation.bundleSha256 = createHash("sha256").update(bundleBytes).digest("hex");
  const attestationBytes = `${JSON.stringify(attestation, null, 2)}\n`;
  await writeFile(attestationPath, attestationBytes);
  const manifestPath = join(bundleTemporary, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.artifactSha256["sigstore-bundle.json"] = attestation.bundleSha256;
  manifest.artifactSha256["dispatch-attestation.json"] = createHash("sha256").update(attestationBytes).digest("hex");
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  const result = spawnSync(process.execPath, [resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "--directory", bundleTemporary], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes("公式gh attestation verifyに失敗しました")) {
    throw new Error(`署名改変bundleを拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  console.log("追跡dispatch attestation安全性検査: bundle改変後に公式gh検証が非成功になることを確認");
} finally {
  await rm(bundleTemporary, { recursive: true, force: true });
}

const stateTemporary = await mkdtemp(join(tmpdir(), "lnako-tracked-state-"));
try {
  await cp(source, stateTemporary, { recursive: true });
  const basePath = join(stateTemporary, "catalog-evidence-unattested.json");
  const base = JSON.parse(await readFile(basePath, "utf8"));
  base.entries[0].executionEvidenceState = "trace-confirmed-unattested";
  const baseDisplaced = base.entries.find((entry) => entry.id === "command-0141");
  baseDisplaced.executionEvidenceState = "unverified";
  baseDisplaced.executionEvidence = null;
  base.executionEvidenceStates = { verified: 0, "trace-confirmed-unattested": 4, unverified: 523 };
  const baseBytes = `${JSON.stringify(base, null, 2)}\n`;
  await writeFile(basePath, baseBytes);
  const historicalPath = join(stateTemporary, "catalog-evidence-verified.json");
  const historical = JSON.parse(await readFile(historicalPath, "utf8"));
  historical.entries[0].executionEvidenceState = "verified";
  historical.entries[0].executionEvidence = null;
  const displaced = historical.entries.find((entry) => entry.id === "command-0141");
  displaced.executionEvidenceState = "unverified";
  displaced.executionEvidence = null;
  const historicalBytes = `${JSON.stringify(historical, null, 2)}\n`;
  await writeFile(historicalPath, historicalBytes);
  const manifestPath = join(stateTemporary, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.artifactSha256["catalog-evidence-unattested.json"] = createHash("sha256").update(baseBytes).digest("hex");
  manifest.artifactSha256["catalog-evidence-verified.json"] = createHash("sha256").update(historicalBytes).digest("hex");
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  const result = spawnSync(process.execPath, [resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "--directory", stateTemporary, "--offline"], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes("base catalogのdispatch stateが不一致です")) {
    throw new Error(`非dispatch entryのstate改変を拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  console.log("追跡dispatch attestation安全性検査: 非dispatch entryのverified改変を拒否");
} finally {
  await rm(stateTemporary, { recursive: true, force: true });
}

const historicalTemporary = await mkdtemp(join(tmpdir(), "lnako-historical-commit-"));
try {
  const dispatchPath = resolve(source, "dispatch/dispatch-evidence-macos-15.json");
  const missingOutput = spawnSync(process.execPath, [
    resolve(root, "tools/sync_compat_evidence.mjs"),
    "--generate",
    "--dispatch-evidence", dispatchPath,
    "--historical-commit", "1ee47232d34711abaddb28038218258232ac3800",
  ], { cwd: root, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 });
  if (missingOutput.status === 0 || !`${missingOutput.stdout}\n${missingOutput.stderr}`.includes("--historical-commitでは--dispatch-evidenceと明示的な非canonical --outputが必須です")) {
    throw new Error(`historical modeのoutput省略を拒否しませんでした: ${JSON.stringify({ status: missingOutput.status, stdout: missingOutput.stdout, stderr: missingOutput.stderr })}`);
  }
  const canonicalOutput = spawnSync(process.execPath, [
    resolve(root, "tools/sync_compat_evidence.mjs"),
    "--generate",
    "--dispatch-evidence", dispatchPath,
    "--historical-commit", "1ee47232d34711abaddb28038218258232ac3800",
    "--output", resolve(root, "compat/v3.7.24/evidence.json"),
  ], { cwd: root, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 });
  if (canonicalOutput.status === 0 || !`${canonicalOutput.stdout}\n${canonicalOutput.stderr}`.includes("--historical-commitでは--dispatch-evidenceと明示的な非canonical --outputが必須です")) {
    throw new Error(`historical modeのcanonical outputを拒否しませんでした: ${JSON.stringify({ status: canonicalOutput.status, stdout: canonicalOutput.stdout, stderr: canonicalOutput.stderr })}`);
  }
  const outputPath = join(historicalTemporary, "evidence.json");
  const result = spawnSync(process.execPath, [
    resolve(root, "tools/sync_compat_evidence.mjs"),
    "--generate",
    "--dispatch-evidence", dispatchPath,
    "--historical-commit", "0".repeat(40),
    "--output", outputPath,
  ], { cwd: root, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 });
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes("--historical-commitとdispatch証拠のcommitが一致しません")) {
    throw new Error(`誤ったhistorical commitを拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  console.log("tracked dispatch attestation安全性検査: 誤ったhistorical commitを拒否");
} finally {
  await rm(historicalTemporary, { recursive: true, force: true });
}

// 現行snapshotの解決は走査型（attestations/<run>/manifest.jsonのうち
// sourceManifestSha256が現行と一致する最大workflowRun）。偽の大きなrun番号
// ディレクトリや偽造宣言が「現行」として受理されないことを、最新snapshotを
// 材料にした自己完結した偽snapshotでoffline検証する。
const forgedBase = resolve(root, "compat/v3.7.24/attestations/34402208204");
const headCommit = gitHead();
const currentSourceManifest = computeSourceManifestSha256Sync(root).sha256;
const forgedRun = "99999999999";
const dispatchRunners = [
  ["macos-15", "darwin", "arm64"],
  ["ubuntu-24.04", "linux", "x64"],
  ["windows-2025", "win32", "x64"],
];

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

// 現行manifestに一致するv2 manifestを持つ偽snapshotを構築する。
// dispatch証拠のprovenance・tracked digest・宣言・v3 attestation記録は
// すべて内部整合させるため、構造検査を通過して署名subject照合に到達する。
async function buildForgedSnapshot(attestationsRoot, options = {}) {
  const directory = join(attestationsRoot, options.directory ?? forgedRun);
  await cp(forgedBase, directory, { recursive: true });
  const dispatchEvidence = [];
  for (const [runner, platform, arch] of dispatchRunners) {
    const relativePath = `dispatch/dispatch-evidence-${runner}.json`;
    const fullPath = join(directory, relativePath);
    const evidence = JSON.parse(await readFile(fullPath, "utf8"));
    evidence.provenance.lnako.sourceManifestSha256 = currentSourceManifest;
    const bytes = `${JSON.stringify(evidence, null, 2)}\n`;
    await writeFile(fullPath, bytes);
    dispatchEvidence.push({ platform, arch, runner, path: relativePath, sha256: sha256(bytes) });
  }
  const declarationBytes = options.declarationBytes ?? sourceManifestDeclarationBytes(options.declarationCommit ?? headCommit, options.declarationManifest ?? currentSourceManifest);
  await writeFile(join(directory, "source-manifest.json"), declarationBytes);
  const declarationSha256 = sha256(declarationBytes);
  const trackedEvidence = trackedAttestationSubjects.map((path) => ({ path, sha256: sha256(readFileSync(resolve(root, path))) }));
  if (options.forgedTrackedDigest) trackedEvidence[0].sha256 = "0".repeat(64);
  const bundleBytes = await readFile(join(directory, "sigstore-bundle.json"));
  const attestation = {
    schema: "lnako.dispatch-attestation.v3",
    repository: "soramikan/lnako",
    workflow: "soramikan/lnako/.github/workflows/ci.yml",
    sourceRef: "refs/heads/main",
    commit: headCommit,
    predicateType: "https://slsa.dev/provenance/v1",
    verifiedBy: "gh attestation verify",
    bundleSha256: sha256(bundleBytes),
    subjects: dispatchEvidence.map((record) => ({ platform: record.platform, arch: record.arch, evidenceSha256: record.sha256 })),
    trackedSubjects: trackedEvidence,
    sourceManifest: { name: sourceManifestDeclarationBasename, sha256: declarationSha256 },
  };
  const attestationBytes = `${JSON.stringify(attestation, null, 2)}\n`;
  await writeFile(join(directory, "dispatch-attestation.json"), attestationBytes);
  const artifactSha256 = {
    "dispatch-attestation.json": sha256(attestationBytes),
    "sigstore-bundle.json": sha256(bundleBytes),
    "native-aot-attestation.json": sha256(await readFile(join(directory, "native-aot-attestation.json"))),
    "native-aot-aggregate-evidence.json": sha256(await readFile(join(directory, "native-aot-aggregate-evidence.json"))),
    "catalog-evidence-verified.json": sha256(await readFile(join(directory, "catalog-evidence-verified.json"))),
    "source-manifest.json": declarationSha256,
  };
  const manifest = {
    schema: options.manifestSchema ?? "lnako.canonical-attestation.v2",
    workflowRun: options.workflowRun ?? forgedRun,
    workflowAttempt: 1,
    targetCommit: options.targetCommit ?? headCommit,
    sourceRef: "refs/heads/main",
    workflow: "soramikan/lnako/.github/workflows/ci.yml",
    sourceManifestSha256: currentSourceManifest,
    sourceManifest: "source-manifest.json",
    attestation: "dispatch-attestation.json",
    bundle: "sigstore-bundle.json",
    nativeAotAttestation: "native-aot-attestation.json",
    nativeAotAggregate: "native-aot-aggregate-evidence.json",
    catalogEvidence: "catalog-evidence-verified.json",
    dispatchEvidence,
    trackedEvidence,
    artifactSha256,
  };
  await writeFile(join(directory, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  return directory;
}

function runTrackedCheck(attestationsRoot, extra = []) {
  return spawnSync(process.execPath, [
    resolve(root, "tools/check_tracked_dispatch_attestation.mjs"),
    "--attestations-root", attestationsRoot,
    "--offline",
    ...extra,
  ], { cwd: root, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
}

function assertTrackedRejected(result, message, label) {
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes(message)) {
    throw new Error(`${label}を期待どおり拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
}

// 署名なしの自己整合snapshot: run番号が大きいだけでは現行にならない。
// 宣言digest・dispatch digestはいずれも実bundleのsubjectに存在しない。
const unsignedTemporary = await mkdtemp(join(tmpdir(), "lnako-forged-snapshot-"));
try {
  await buildForgedSnapshot(unsignedTemporary);
  assertTrackedRejected(runTrackedCheck(unsignedTemporary), "current bundleが宣言された証拠digestを含みません", "署名なし偽snapshot");
  console.log("tracked dispatch attestation安全性検査: 署名なしの大きなrun番号snapshotを拒否");
} finally {
  await rm(unsignedTemporary, { recursive: true, force: true });
}

// manifestの対象commitだけを変えた場合、宣言identityと一致せず拒否される。
const commitTemporary = await mkdtemp(join(tmpdir(), "lnako-forged-commit-"));
try {
  await buildForgedSnapshot(commitTemporary, { targetCommit: "0".repeat(40) });
  assertTrackedRejected(runTrackedCheck(commitTemporary), "source manifest宣言のschemaまたはidentityが不正です", "manifest対象commit偽造");
  console.log("tracked dispatch attestation安全性検査: manifest対象commitの偽造を拒否");
} finally {
  await rm(commitTemporary, { recursive: true, force: true });
}

// 宣言が別commit／別manifest値を名乗る場合、canonical宣言identity検査で拒否される。
const declarationTemporary = await mkdtemp(join(tmpdir(), "lnako-forged-declaration-"));
try {
  await buildForgedSnapshot(declarationTemporary, { declarationCommit: "0".repeat(40) });
  assertTrackedRejected(runTrackedCheck(declarationTemporary), "source manifest宣言のschemaまたはidentityが不正です", "宣言commit偽造");
  console.log("tracked dispatch attestation安全性検査: 宣言commitの偽造を拒否");
} finally {
  await rm(declarationTemporary, { recursive: true, force: true });
}

const manifestTemporary = await mkdtemp(join(tmpdir(), "lnako-forged-decl-manifest-"));
try {
  await buildForgedSnapshot(manifestTemporary, { declarationManifest: "0".repeat(64) });
  assertTrackedRejected(runTrackedCheck(manifestTemporary), "source manifest宣言のschemaまたはidentityが不正です", "宣言manifest digest偽造");
  console.log("tracked dispatch attestation安全性検査: 宣言manifest digestの偽造を拒否");
} finally {
  await rm(manifestTemporary, { recursive: true, force: true });
}

// 同じ内容でもcanonical byte列でない宣言は拒否される。
const noncanonicalTemporary = await mkdtemp(join(tmpdir(), "lnako-noncanonical-decl-"));
try {
  const noncanonical = `${JSON.stringify({ schema: "lnako.source-manifest.v1", commit: headCommit, sourceManifestSha256: currentSourceManifest })}\n`;
  await buildForgedSnapshot(noncanonicalTemporary, { declarationBytes: noncanonical });
  assertTrackedRejected(runTrackedCheck(noncanonicalTemporary), "canonical byte列ではありません", "非canonical宣言");
  console.log("tracked dispatch attestation安全性検査: 非canonical宣言byte列を拒否");
} finally {
  await rm(noncanonicalTemporary, { recursive: true, force: true });
}

// manifestのtracked証拠digestが現行ファイルと一致しないsnapshotは拒否される。
const trackedTemporary = await mkdtemp(join(tmpdir(), "lnako-forged-tracked-"));
try {
  await buildForgedSnapshot(trackedTemporary, { forgedTrackedDigest: true });
  assertTrackedRejected(runTrackedCheck(trackedTemporary), "current tracked", "tracked証拠digest偽造");
  console.log("tracked dispatch attestation安全性検査: tracked証拠digestの偽造を拒否");
} finally {
  await rm(trackedTemporary, { recursive: true, force: true });
}

// manifest.workflowRunがdirectory名と一致しないsnapshotは候補にならず、
// 現行snapshot無しとして扱われる（--require-currentでは失敗）。
const mismatchedTemporary = await mkdtemp(join(tmpdir(), "lnako-mismatched-run-"));
try {
  await buildForgedSnapshot(mismatchedTemporary, { workflowRun: "88888888888" });
  const result = runTrackedCheck(mismatchedTemporary);
  if (result.status !== 0 || !`${result.stdout}\n${result.stderr}`.includes("一致するsnapshotなし")) {
    throw new Error(`run名不一致snapshotを無視できませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  const required = runTrackedCheck(mismatchedTemporary, ["--require-current"]);
  assertTrackedRejected(required, "現行source manifestに一致するattestation snapshotがありません", "run名不一致時のrequire-current");
  console.log("tracked dispatch attestation安全性検査: run名不一致snapshotを候補から除外しrequire-currentを拒否");
} finally {
  await rm(mismatchedTemporary, { recursive: true, force: true });
}

// v1 manifestのsnapshotは、sourceManifestSha256が偶然一致しても現行候補に
// ならない（現行解決はcanonical-attestation.v2 manifestのみを走査する）。
const v1Temporary = await mkdtemp(join(tmpdir(), "lnako-v1-snapshot-"));
try {
  await buildForgedSnapshot(v1Temporary, { manifestSchema: "lnako.canonical-attestation.v1" });
  const result = runTrackedCheck(v1Temporary);
  if (result.status !== 0 || !`${result.stdout}\n${result.stderr}`.includes("一致するsnapshotなし")) {
    throw new Error(`v1 manifest snapshotを無視できませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  assertTrackedRejected(runTrackedCheck(v1Temporary, ["--require-current"]), "現行source manifestに一致するattestation snapshotがありません", "v1 manifest時のrequire-current");
  console.log("tracked dispatch attestation安全性検査: v1 manifest snapshotを候補から除外しrequire-currentを拒否");
} finally {
  await rm(v1Temporary, { recursive: true, force: true });
}

function gitHead() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  const commit = result.stdout.trim();
  if (result.status !== 0 || !/^[0-9a-f]{40}$/i.test(commit)) throw new Error("現行commitを取得できません");
  return commit;
}
