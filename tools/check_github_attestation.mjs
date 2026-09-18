import { spawnSync } from "node:child_process";
import { resolve } from "node:path";
import { verifyCurrentGithubAttestation } from "./lib/evidence/github_attestation.mjs";

const root = resolve(import.meta.dirname, "..");
const arguments_ = process.argv.slice(2);
if (arguments_.some((argument) => argument.startsWith("--") && argument !== "--commit") ||
    (arguments_.includes("--commit") && (arguments_[arguments_.indexOf("--commit") + 1] === undefined || arguments_[arguments_.indexOf("--commit") + 1].startsWith("--")))) {
  throw new Error("usage: node tools/check_github_attestation.mjs [--commit 40-hex-commit]");
}

function currentGitCommit() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  if (result.error || result.status !== 0) throw new Error("現行commitを取得できません");
  const value = result.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(value)) throw new Error("現行commit形式が不正です");
  return value;
}

const commitIndex = arguments_.indexOf("--commit");
const commit = commitIndex >= 0 ? arguments_[commitIndex + 1] : currentGitCommit();
const summary = await verifyCurrentGithubAttestation(root, { commit });
console.log(`GitHub attestationを検証しました: commit ${summary.commit} / source manifest ${summary.sourceManifestSha256} / 導出verified ${summary.verified}`);
