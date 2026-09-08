import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const workflow = await readFile(resolve(root, ".github/workflows/release.yml"), "utf8");
const distribution = await readFile(resolve(root, "tools/create_distribution.mjs"), "utf8");
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
  "zig build -Doptimize=ReleaseSafe -Dcompat-js=true",
  "node tools/setup_quickjs.mjs",
  "Verify bundled QuickJS packaging boundaries",
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
    !workflow.includes("CI_EXPECTED_JOB_COUNT: 54") || !workflow.includes("--json jobs") ||
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
const preflightBlock = workflow.match(/  preflight:[\s\S]*?(?=\n  build:)/)?.[0];
if (!preflightBlock) throw new Error("Release workflowにpreflight jobがありません");
const attestationGate = preflightBlock.match(/- name: Verify canonical compatibility evidence is fully attested\n[\s\S]*?(?=\n      - name:|$)/)?.[0];
if (!attestationGate) throw new Error("Release workflowのpreflightにcanonical attestation検証stepがありません");
if (!attestationGate.includes("if: github.event_name == 'push'") ||
    !attestationGate.includes("attestations/current.json") ||
    !attestationGate.includes("node tools/sync_compat_evidence.mjs --check") ||
    !attestationGate.includes("node tools/check_tracked_dispatch_attestation.mjs")) {
  throw new Error("canonical attestation検証stepが不完全です（current pointer必須・証拠再生成check・追跡snapshotの公式gh verifyが必要）");
}
if (!workflow.includes("merge-multiple: true") || !workflow.includes("LNAKO_BENCHMARK_COMMIT")) {
  throw new Error("Release workflowのartifact集約またはbenchmark provenanceが不完全です");
}
// upload-artifactは複数directoryを指定すると共通祖先基準で階層を保持するため、
// artifactへdist/等のサブディレクトリが混入し集約側の平坦directory検査を壊す。
// upload対象は単一の平坦なstaging directoryに限定する。
const uploadBlock = workflow.match(/- name: Upload target release assets\n[\s\S]*?(?=\n      - name:|\n  \w)/)?.[0];
if (!uploadBlock || !uploadBlock.includes("path: ${{ runner.temp }}/release-assets-${{ matrix.target }}/*")) {
  throw new Error("Release assetのuploadが単一平坦directory経由になっていません");
}
if (!workflow.includes("key: release-toolchains-llvm-22.1.8-quickjs-2026-06-04-${{ matrix.target }}-v3-minimal") ||
    !workflow.includes("release-toolchains-llvm-22.1.8-${{ matrix.target }}-v1") ||
    !workflow.includes("run: node tools/prune_llvm_toolchain.mjs")) {
  throw new Error("Release workflowのLLVM toolchain cache最小化が不完全です");
}
// 配布コンパイラはQuickJSを静的同梱し、生成物には利用時のみ含める境界を検証する。
if (!workflow.includes("run tests/fixtures/compat-js-basic.nako3 --compat-js") ||
    !workflow.includes("build tests/fixtures/compat-js-basic.nako3 --compat-js") ||
    !workflow.includes('! grep -aq "unexpected token in expression" zig-out/lib/${{ matrix.runtime }}')) {
  throw new Error("Release workflowのQuickJS同梱・非同梱境界検証が不完全です");
}
for (const required of ["lib/libc++.1.dylib", "lib/libc++abi.1.dylib", "lib/libunwind.1.dylib"]) {
  if (!distribution.includes(`source: \"${required}\"`) || !distribution.includes(`destination: \"${required}\"`)) {
    throw new Error(`macOS配布物にLLVM runtime依存がありません: ${required}`);
  }
}
console.log("Release workflow構成検査: 3正式OS build・benchmark・distribution・checksum／SBOM・tag gate成功");
