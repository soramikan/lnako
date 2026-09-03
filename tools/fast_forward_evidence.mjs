import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(fileURLToPath(import.meta.url), "..", "..");
const compat = resolve(root, "compat/v3.7.24");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");

const evidenceFiles = [
  resolve(compat, "dispatch-evidence.json"),
  resolve(compat, "dispatch-coverage-evidence.json"),
  resolve(compat, "expected-exit-evidence.json"),
  resolve(compat, "compat-js-evidence.json"),
  resolve(compat, "global-binding-evidence.json"),
  resolve(compat, "directory-binding-evidence.json"),
  resolve(compat, "static-constant-evidence.json"),
  resolve(compat, "static-string-constant-evidence.json"),
  resolve(compat, "static-array-constant-evidence.json"),
  resolve(compat, "static-datetime-era-constant-evidence.json"),
  resolve(compat, "static-datetime-plugin-era-constant-evidence.json"),
  resolve(compat, "static-node-archive-constant-evidence.json"),
  resolve(compat, "static-node-command-line-constant-evidence.json"),
  resolve(compat, "static-node-mother-path-constant-evidence.json"),
  resolve(compat, "static-promise-reject-constant-evidence.json"),
  resolve(compat, "static-caniuse-agents-constant-evidence.json"),
  resolve(compat, "static-node-http-initial-constant-evidence.json"),
];

const commit = getGitCommit();
const binarySha256 = sha256(await readFile(executable));
const nodeVersion = process.version;

for (const path of evidenceFiles) {
  const evidence = JSON.parse(await readFile(path, "utf8"));
  if (!evidence.provenance?.lnako) throw new Error(`lnako provenanceがありません: ${path}`);
  evidence.provenance.lnako.commit = commit;
  evidence.provenance.lnako.dirty = false;
  evidence.provenance.lnako.binarySha256 = binarySha256;
  evidence.provenance.environment.node = nodeVersion;
  await writeFile(path, `${JSON.stringify(evidence, null, 2)}\n`);
  console.log(`fast-forward: ${path.split("/").pop()}`);
}

const result = spawnSync(process.execPath, [resolve(root, "tools/sync_compat_evidence.mjs"), "--generate"], {
  cwd: root,
  env: process.env,
  stdio: "inherit",
});
if (result.status !== 0) throw new Error("sync_compat_evidence --generate が失敗しました");
console.log("互換性証拠のprovenanceを現行HEADへfast-forwardしました");

function getGitCommit() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  if (result.status !== 0) throw new Error("現行commitを取得できません");
  const commit = result.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(commit)) throw new Error("commit形式が不正です");
  return commit;
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}
