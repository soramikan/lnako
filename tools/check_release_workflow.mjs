import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const workflow = await readFile(resolve(root, ".github/workflows/release.yml"), "utf8");
const floatingActions = [...workflow.matchAll(/uses: ([^\s@]+)@([^\s#]+)/g)]
  .filter((match) => !/^[0-9a-f]{40}$/.test(match[2]))
  .map((match) => `${match[1]}@${match[2]}`);
if (floatingActions.length > 0) throw new Error(`Release workflowのGitHub Actionをcommit SHAへ固定してください: ${floatingActions.join(", ")}`);

for (const required of [
  'push:\n    tags: ["v*.*.*"]',
  "workflow_dispatch:",
  "inputs:",
  "version:",
  "preflight:",
  "build:",
  "aggregate:",
  "publish:",
  "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09",
  "mlugg/setup-zig@d1434d08867e3ee9daa34448df10607b98908d29",
  "actions/setup-node@a0853c24544627f65ddf259abe73b1d18a591444",
  "actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
  "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
  "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
  "macos-15",
  "ubuntu-24.04",
  "windows-2025",
  "macos-arm64",
  "linux-x64",
  "windows-x64",
  "zig build -Doptimize=ReleaseSafe",
  "node tools/create_distribution.mjs",
  "node tools/check_distribution.mjs",
  "node tools/create_release_checksums.mjs",
  "node tools/check_release_assets.mjs",
  "node tools/check_benchmark_set.mjs",
  "node tools/check_benchmark_result.mjs",
  "gh release create",
  "contents: write",
]) if (!workflow.includes(required)) throw new Error(`Release workflowに必要な要素がありません: ${required}`);

if (!workflow.includes("needs: preflight") || !workflow.includes("needs: [preflight, build]") ||
    !workflow.includes("needs: [preflight, aggregate]") || !workflow.includes("if: github.event_name == 'push'")) {
  throw new Error("Release workflowのjob依存関係またはpublish条件が不正です");
}
if (!workflow.includes("GITHUB_RUN_ID") || !workflow.includes("github.sha") || !workflow.includes("CI --commit") ||
    !workflow.includes("CI_EXPECTED_JOB_COUNT: 53") || !workflow.includes("--json jobs") ||
    !workflow.includes("ci_job_count") || !workflow.includes("ci_non_success_jobs")) {
  throw new Error("Release workflowにsource commit／CI gateの検証がありません");
}
if (!workflow.includes('"$ci_job_count" -ne "$CI_EXPECTED_JOB_COUNT"') ||
    !workflow.includes('"$ci_non_success_jobs" -ne 0')) {
  throw new Error("Release workflowがCIの全job成功を要求していません");
}
if (!workflow.includes("git cat-file -t") || !workflow.includes("verification.verified")) {
  throw new Error("tag Releaseでannotated signed tagを検証していません");
}
if (!workflow.includes("merge-multiple: true") || !workflow.includes("LNAKO_BENCHMARK_COMMIT")) {
  throw new Error("Release workflowのartifact集約またはbenchmark provenanceが不完全です");
}
console.log("Release workflow構成検査: 3正式OS build・benchmark・distribution・checksum／SBOM・tag gate成功");
