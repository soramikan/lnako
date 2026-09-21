import { access, readdir, readFile } from "node:fs/promises";
import { extname, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const currentFiles = [
  "README.md",
  "docs/ARCHITECTURE.md",
  "docs/CI.md",
  "docs/COMPATIBILITY.md",
  "docs/COMPATIBILITY_EVIDENCE.md",
  "docs/COMPATIBILITY_QUIRKS.md",
  "docs/DEVELOPMENT.md",
  "docs/compatibility/AOT.md",
  "docs/compatibility/COMPAT_JS.md",
  "docs/compatibility/NODE_HOST.md",
  "docs/compatibility/PARSER.md",
  "docs/compatibility/RUNTIME.md",
  "docs/compatibility/QUIRKS.md",
];

async function read(relativePath) {
  return readFile(resolve(root, relativePath), "utf8");
}

async function readJson(relativePath) {
  return JSON.parse(await read(relativePath));
}

function fail(message) {
  throw new Error(`現行ドキュメント検査: ${message}`);
}

function requireText(text, needle, label) {
  if (!text.includes(needle)) fail(`${label}に必要な記述がありません: ${needle}`);
}

function requireTableValue(text, label, marker, value) {
  const markerStart = `<!-- attestation:${marker} -->`;
  const markerEnd = `<!-- /attestation:${marker} -->`;
  const plain = `| \`${label}\` | ${value} |`;
  const marked = `| \`${label}\` | ${markerStart}${value}${markerEnd} |`;
  if (!text.includes(plain) && !text.includes(marked)) {
    fail(`${label}の表記述がありません: ${plain} または ${marked}`);
  }
}

async function assertExists(relativePath) {
  try {
    await access(resolve(root, relativePath));
  } catch {
    fail(`必要なファイルがありません: ${relativePath}`);
  }
}

for (const relativePath of currentFiles) await assertExists(relativePath);

const summary = await readJson("compat/v3.7.24/summary.json");
const evidence = await readJson("compat/v3.7.24/evidence.json");
const dispatchCoverage = await readJson("compat/v3.7.24/dispatch-coverage-evidence.json");
const compatJsEvidence = await readJson("compat/v3.7.24/compat-js-evidence.json");
const workflow = await read(".github/workflows/ci.yml");
const currentDocuments = await Promise.all(currentFiles.map(async (relativePath) => ({
  relativePath,
  text: await read(relativePath),
})));
const currentText = currentDocuments.map(({ text }) => text).join("\n");

const standardStatuses = summary.standardCnakoStatuses;
const evidenceStates = evidence.executionEvidenceStates;
if (summary.baseline?.tag !== "3.7.24" || summary.baseline?.commit !== "aa18c7e640523938c680958fe731418cc6f7a58f") {
  fail("summary.jsonのupstream baselineが固定値と一致しません");
}
if (evidence.commandCount !== 527 || evidence.entries?.length !== 527) fail("evidence.jsonの527 entry構造が不正です");
for (const [name, expected] of [["native", 523], ["compat-js", 4], ["blocked", 0]]) {
  if (standardStatuses?.[name] !== expected) fail(`summary.jsonの${name}分類が不一致です`);
  requireText(currentText, `| \`${name}\` | ${expected} |`, "現行互換性文書");
}
// canonical evidence.json は常時 unattested。外部署名の確認は git snapshot ではなく
// CI / Release の GitHub Attestations（gh attestation verify）が担う。
for (const [name, expected] of [["verified", 0], ["trace-confirmed-unattested", 527], ["unverified", 0]]) {
  if (evidenceStates?.[name] !== expected) fail(`evidence.jsonの${name} stateが不一致です`);
}
const compatibilityText = await read("docs/COMPATIBILITY.md");
requireTableValue(compatibilityText, "verified", "verified", evidenceStates.verified);
requireTableValue(compatibilityText, "trace-confirmed-unattested", "trace", evidenceStates["trace-confirmed-unattested"]);
requireTableValue(compatibilityText, "unverified", "unverified", evidenceStates.unverified);
if (compatibilityText.includes("attestation snapshotから導出したview") || compatibilityText.includes("attestations/*/manifest.json")) {
  fail("COMPATIBILITY.mdが廃止したgit snapshot導出viewを現行説明に残しています");
}

const fixtureInventory = evidence.fixtureInventory;
if (fixtureInventory?.total !== 625 || fixtureInventory?.nativeAot !== 379 || fixtureInventory?.interpreter !== 256 || fixtureInventory?.compatJs !== 9) {
  fail("evidence.jsonのfixture inventoryが不一致です");
}
if (dispatchCoverage.scope?.fixtureCount !== 231 || dispatchCoverage.sites?.length !== 4602 ||
    dispatchCoverage.coverage?.unambiguousObservedNativeEntries !== 426 ||
    dispatchCoverage.coverage?.unambiguousObservedNativeUniqueNames !== 424) {
  fail("dispatch coverageの現行集計が不一致です");
}
if (compatJsEvidence.scope?.catalogEntries !== 4 || compatJsEvidence.scope?.caseCount !== 9 ||
    compatJsEvidence.scope?.successCaseCount !== 6 || compatJsEvidence.scope?.expectedFailureCaseCount !== 3) {
  fail("compat-js evidenceの現行集計が不一致です");
}

const readme = await read("README.md");
if (readme.split(/\r?\n/).length > 100) fail("README.mdは利用者向け入口として100行以内に保ってください");
for (const staleReference of [
  "docs/UNVERIFIED_EVIDENCE_PLAN.md",
  "docs/COMPATIBILITY_QUIRKS_2026.md",
  "3正式OSの外部署名attestationがまだ完了",
  "3正式OSの外部署名attestationは未完了",
]) {
  if (currentText.includes(staleReference)) fail(`現行文書に履歴専用または古い状態の記述があります: ${staleReference}`);
}
for (const category of ["PARSER.md", "RUNTIME.md", "NODE_HOST.md", "AOT.md", "COMPAT_JS.md"]) {
  requireText(readme + currentText, category, "互換性quirksの領域導線");
}
requireText(await read("docs/CI.md"), "**40 matrix job＋変更分類・軽量検証・Windows／Linux AOT compiler producer・3後段job、合計47 job**", "CI.md");
// release手順のjob数もCI定義へ追従させる（2026-09-20に39件のまま留まり
// 指摘された。CI.mdだけを検査していたため検出できなかった）。
requireText(await read("docs/RELEASE.md"), "40 matrix job＋変更分類・軽量検証・Windows／Linux compiler producer・後段3 job、**合計47 job**", "RELEASE.md");
requireText(workflow, "node tools/check_docs_current.mjs", "CI workflow");

async function walkMarkdown(directory) {
  const entries = await readdir(resolve(root, directory), { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    if (entry.isDirectory() && entry.name === "history") continue;
    const relativePath = `${directory}/${entry.name}`;
    if (entry.isDirectory()) files.push(...await walkMarkdown(relativePath));
    else if (extname(entry.name).toLowerCase() === ".md") files.push(relativePath);
  }
  return files;
}

function isExternal(target) {
  return target.startsWith("#") || target.startsWith("/") || target.startsWith("mailto:") || /^[a-z][a-z0-9+.-]*:/i.test(target);
}

async function assertMarkdownLinks(relativePath, text) {
  const linkPattern = /\]\((<[^>]+>|[^)\s]+)(?:\s+["'][^)]*["'])?\)/g;
  for (const match of text.matchAll(linkPattern)) {
    const rawTarget = match[1];
    const target = rawTarget.startsWith("<") && rawTarget.endsWith(">") ? rawTarget.slice(1, -1) : rawTarget;
    if (isExternal(target)) continue;
    const [pathPart] = target.split("#", 1);
    if (pathPart === "") continue;
    try {
      await access(resolve(root, relativePath, "..", pathPart));
    } catch {
      fail(`Markdown内部リンクが存在しません: ${relativePath} -> ${target}`);
    }
  }
}

for (const relativePath of ["README.md", ...(await walkMarkdown("docs"))]) {
  await assertMarkdownLinks(relativePath, await read(relativePath));
}

console.log(`現行ドキュメント検査: 成功 (standard native=${standardStatuses.native}, compat-js=${standardStatuses["compat-js"]}, evidence verified=${evidenceStates.verified}/${evidence.commandCount}, docs表 verified=${evidenceStates.verified}, CI=47 jobs)`);
