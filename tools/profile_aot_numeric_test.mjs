import assert from "node:assert/strict";
import { summarizeCode } from "./profile_aot_numeric.mjs";

const summary = summarizeCode(`define internal double @lnako.number.1(double %a) {
  %r = call double @llvm.sqrt.f64(double %a)
  call void @lnako_aot_index_get(ptr null)
  call void @lnako_aot_index_get(ptr null)
}`, "callq __chkstk\nvsqrtsd %xmm0, %xmm0, %xmm1\n");
assert.equal(summary.static_call_sites.lnako_aot_index_get, 2);
assert.equal(summary.static_call_sites["llvm.sqrt.f64"], 1);
assert.deepEqual(summary.typed_definitions, ["lnako.number.1"]);
assert.equal(summary.stack_probe_mentions, 1);
assert.equal(summary.sqrt_mentions, 1);
assert.deepEqual(summarizeCode("", "").static_call_sites, {});
console.log("numeric profile code classification: PASS");

// Run the actual workflow shell body under macOS's Bash 3 when available.
// Stub node so the test checks argument handling without profiling or WPR.
const { readFileSync } = await import("node:fs");
const { spawnSync } = await import("node:child_process");
const workflow = readFileSync(new URL("../.github/workflows/comparison-benchmark.yml", import.meta.url), "utf8");
const step = workflow.split("      - name: Collect numeric code and CPU profile\n")[1].split("\n      - name:")[0];
const script = step.split("        run: |\n")[1].split("\n").filter((line) => line.startsWith("          ")).map((line) => line.slice(10)).join("\n").replaceAll("${{ matrix.target }}", "test-target");
for (const os of ["macOS", "Linux", "Windows"]) {
  const checked = spawnSync(process.platform === "darwin" ? "/bin/bash" : "bash", ["-c", 'node() { printf "<%s>\\n" "$@"; }\n' + script], {
    encoding: "utf8", env: { ...process.env, RUNNER_OS: os, RUNNER_TEMP: "/tmp/profile path with spaces" },
  });
  assert.equal(checked.status, 0, checked.stderr);
  assert.ok(checked.stdout.includes("<--output>\n</tmp/profile path with spaces/numeric-profile-test-target>"));
  assert.equal(checked.stdout.includes("<--windows-sampling>"), os === "Windows");
}
console.log("numeric profile workflow arguments: PASS");
