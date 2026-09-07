import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { test } from "node:test";

import { loadBenchmarkSuite } from "./lib/benchmark_suite.mjs";

const root = resolve(import.meta.dirname, "..");
const suitePath = resolve(root, "benchmarks/suites/diagnostics.json");
const readmePath = resolve(root, "benchmarks/cases/diagnostics/README.md");

const expectedCases = [
  ["local-load-store", "100000", "300000\n"],
  ["global-load-store", "100000", "300000\n"],
  ["direct-call-empty", "100000", "700000\n"],
  ["captured-call-empty", "100000", "700000\n"],
  ["array-read-only", "64000", "2080000\n"],
  ["array-write-only", "64000", "2080\n"],
  ["dict-small", "100000", "100000\n"],
  ["dict-large-read", "64000", "8224000\n"],
  ["string-copy-fixed", "100000", "1000000\n"],
  ["gc-short-lived", "4000", "8006000\n"],
  ["gc-long-lived", "2000", "2001000\n"],
  ["numeric-function-call", "50000", "6250275000\n"],
];

test("diagnostic suiteは12ケースを独立して固定する", () => {
  const suite = loadBenchmarkSuite(suitePath);
  assert.equal(suite.schema_version, 2);
  assert.equal(suite.name, "lnako-benchmark-diagnostics");
  assert.deepEqual(suite.cases.map((item) => item.id), expectedCases.map(([id]) => id));
  for (const [id, input, expected] of expectedCases) {
    const item = suite.cases.find((candidate) => candidate.id === id);
    assert.ok(item);
    assert.equal(item.measurement, "steady_state");
    assert.deepEqual(item.profiles, ["smoke", "normal", "full"]);
    assert.equal(item.source, `benchmarks/cases/diagnostics/${id}/source.nako3`);
    assert.equal(item.sources.cnako, item.source);
    assert.equal(item.sources.lnako, item.source);
    assert.deepEqual(item.input.args, [input]);
    assert.equal(item.expected_stdout, expected);
  }
});

test("diagnostic READMEはprocess全体計測とsetup込みの解釈を明記する", () => {
  const readme = readFileSync(readmePath, "utf8");
  assert.match(readme, /process_batched_wall/);
  assert.match(readme, /setup.*計測区間から除いた値として扱わず/);
  assert.match(readme, /aot_compile/);
  assert.match(readme, /aot_run/);
});
