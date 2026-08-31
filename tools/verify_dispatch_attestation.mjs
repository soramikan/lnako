import { createHash } from "node:crypto";
import { access, readdir, readFile, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { isAbsolute, resolve } from "node:path";
import { platformIndependentOfficialComparison } from "./dispatch_evidence_semantics.mjs";

const root = resolve(import.meta.dirname, "..");
const args = process.argv.slice(2);
const valueFor = (name) => {
  const index = args.indexOf(name);
  if (index < 0) return null;
  const value = args[index + 1];
  if (value === undefined || value.startsWith("--")) throw new Error(`${name}の値がありません`);
  return value;
};
const directory = absoluteOption("--directory");
const bundle = absoluteOption("--bundle");
const output = absoluteOption("--output");
const catalogOutput = absoluteOption("--catalog-evidence");
const repository = valueFor("--repository");
const commit = valueFor("--commit");
const sourceRef = valueFor("--source-ref");
const workflow = valueFor("--workflow");
const allowed = new Set(["--directory", "--bundle", "--output", "--catalog-evidence", "--repository", "--commit", "--source-ref", "--workflow"]);
if (args.some((argument) => argument.startsWith("--") && !allowed.has(argument))) throw new Error("未知のオプションです");
if (directory === null || bundle === null || output === null || repository === null || commit === null || sourceRef === null || workflow === null ||
    !/^[0-9a-f]{40}$/i.test(commit) || repository !== "soramikan/lnako" || workflow !== "soramikan/lnako/.github/workflows/ci.yml" ||
    sourceRef !== "refs/heads/main") {
  throw new Error("attestation検証のidentity引数が不正です");
}

const forbiddenFields = new Set(["source", "sourceText", "sourcePath", "args", "arguments", "stdout", "stderr", "value", "values", "pointer", "address"]);
const expectedPlatforms = new Set(["darwin-arm64", "linux-x64", "win32-x64"]);
const bundleBytes = await readFile(bundle);
const bundleSha256 = sha256(bundleBytes);
const files = (await readdir(directory)).filter((file) => file.endsWith(".json")).sort();
if (files.length !== expectedPlatforms.size) throw new Error("dispatch証拠artifactが3正式OS分ありません");

const subjects = [];
const evidenceByPlatform = new Map();
let semanticReference = null;
for (const file of files) {
  const path = resolve(directory, file);
  const bytes = await readFile(path);
  const evidence = JSON.parse(bytes.toString("utf8"));
  rejectForbidden(evidence);
  validateEvidence(evidence, commit);
  const platform = `${evidence.provenance.environment.platform}-${evidence.provenance.environment.arch}`;
  if (!expectedPlatforms.has(platform) || evidenceByPlatform.has(platform)) throw new Error(`dispatch証拠のOSが不正または重複しています: ${platform}`);
  const evidenceSha256 = sha256(bytes);
  const semantic = JSON.stringify({
    baseline: evidence.baseline,
    fixture: evidence.fixture,
    officialComparison: platformIndependentOfficialComparison(evidence.officialComparison),
    sites: evidence.sites.map((site) => ({
      catalogId: site.catalogId,
      name: site.name,
      plugin: site.plugin,
      siteId: site.siteId,
      sourceName: site.sourceName,
      canonicalOpcode: site.canonicalOpcode,
      opcode: site.opcode,
      route: site.route,
      officialEquivalent: site.officialEquivalent,
    })),
  });
  if (semanticReference === null) semanticReference = semantic;
  if (semanticReference !== semantic) throw new Error("3正式OSのdispatch証拠の意味内容が一致しません");
  evidenceByPlatform.set(platform, path);
  subjects.push({ platform: evidence.provenance.environment.platform, arch: evidence.provenance.environment.arch, evidenceSha256 });
  verifyWithGh(path, evidenceSha256);
}
if (evidenceByPlatform.size !== expectedPlatforms.size) throw new Error("dispatch証拠のOS集合が不足しています");

subjects.sort((left, right) => `${left.platform}-${left.arch}`.localeCompare(`${right.platform}-${right.arch}`));
const attestation = {
  schema: "lnako.dispatch-attestation.v1",
  repository,
  workflow,
  sourceRef,
  commit,
  predicateType: "https://slsa.dev/provenance/v1",
  verifiedBy: "gh attestation verify",
  bundleSha256,
  subjects,
};
await writeExclusive(output, `${JSON.stringify(attestation, null, 2)}\n`);

if (catalogOutput !== null) {
  const preferred = evidenceByPlatform.get("darwin-arm64");
  if (preferred === undefined) throw new Error("catalog evidence用のmacOS dispatch証拠がありません");
  const result = spawnSync(process.execPath, [
    resolve(root, "tools/sync_compat_evidence.mjs"),
    "--generate",
    "--dispatch-evidence", preferred,
    "--attestation", output,
    "--attestation-bundle", bundle,
    "--output", catalogOutput,
  ], { cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`attestation済みcatalog evidenceの生成に失敗しました: ${result.stderr}`);
}
console.log(`dispatch attestationを検証しました: ${subjects.length} OS・${subjects.reduce((count, subject) => count + subject.evidenceSha256.length, 0) / 2} digest文字`);

function absoluteOption(name) {
  const value = valueFor(name);
  if (value === null) return null;
  if (!isAbsolute(value)) throw new Error(`${name}には絶対パスを指定してください`);
  return resolve(value);
}

function validateEvidence(evidence, expectedCommit) {
  if (evidence?.schema !== "lnako.dispatch-evidence.v2" || evidence.generator !== "tools/check_dispatch_trace.mjs" ||
      evidence.attestation !== null || evidence.fixture?.id !== "native-cut-commands" || evidence.fixture?.file !== "native-cases.json" ||
      evidence.officialComparison?.equivalent !== true || evidence.provenance?.lnako?.commit !== expectedCommit || evidence.provenance?.lnako?.dirty !== false ||
      !Array.isArray(evidence.sites) || evidence.sites.length === 0) {
    throw new Error("dispatch証拠の安全なschemaまたは対象commitが不正です");
  }
  const expectedRoutes = ["officialSource", "officialGenerated", "lnakoRun", "lnakoNativeO0"];
  const routes = evidence.officialComparison.routes;
  if (JSON.stringify(routes) !== JSON.stringify(expectedRoutes) || JSON.stringify(Object.keys(evidence.officialComparison.results ?? {}).sort()) !== JSON.stringify([...expectedRoutes].sort())) {
    throw new Error("dispatch証拠の公式差分routeが不正です");
  }
  const official = evidence.officialComparison.results.officialSource;
  for (const result of Object.values(evidence.officialComparison.results)) {
    if (result.status !== 0 || result.signal !== null || !/^[0-9a-f]{64}$/.test(result.stdoutSha256) || !/^[0-9a-f]{64}$/.test(result.stderrSha256)) {
      throw new Error("dispatch証拠の公式差分結果が不正です");
    }
    if (result.stdoutSha256 !== official.stdoutSha256 || result.stderrSha256 !== official.stderrSha256) throw new Error("dispatch証拠の公式差分hashが一致しません");
  }
}

function verifyWithGh(path, digest) {
  const result = spawnSync("gh", [
    "attestation", "verify", path,
    "--bundle", bundle,
    "--repo", repository,
    "--signer-workflow", workflow,
    "--signer-digest", commit,
    "--source-digest", commit,
    "--source-ref", sourceRef,
    "--cert-oidc-issuer", "https://token.actions.githubusercontent.com",
    "--deny-self-hosted-runners",
    "--predicate-type", "https://slsa.dev/provenance/v1",
    "--format", "json",
  ], { cwd: root, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`公式gh attestation verifyに失敗しました: ${result.stderr}`);
  let entries;
  try {
    entries = JSON.parse(result.stdout);
  } catch (error) {
    throw new Error(`gh attestation verifyのJSON出力が不正です: ${error.message}`);
  }
  if (!Array.isArray(entries) || entries.length === 0) throw new Error("gh attestation verifyが検証済みattestationを返しませんでした");
  const matched = entries.some((entry) => (entry.verificationResult?.statement?.subject ?? []).some((subject) => {
    if (Array.isArray(subject.digest)) return subject.digest.some((value) => value.algorithm === "sha256" && value.value === digest);
    return subject.digest?.sha256 === digest;
  }));
  if (!matched) throw new Error("検証済みattestationのsubject digestがdispatch証拠と一致しません");
}

function rejectForbidden(value, path = "dispatch-evidence") {
  if (Array.isArray(value)) {
    value.forEach((item, index) => rejectForbidden(item, `${path}[${index}]`));
    return;
  }
  if (value === null || typeof value !== "object") return;
  for (const [key, item] of Object.entries(value)) {
    if (forbiddenFields.has(key)) throw new Error(`artifactに禁止fieldがあります: ${path}.${key}`);
    rejectForbidden(item, `${path}.${key}`);
  }
}

async function writeExclusive(path, content) {
  try {
    await access(path);
    throw new Error(`出力先は既に存在します: ${path}`);
  } catch (error) {
    if (error?.message?.startsWith("出力先は既に存在します")) throw error;
    if (error?.code !== "ENOENT") throw error;
  }
  await writeFile(path, content, { encoding: "utf8", flag: "wx" });
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}
