import assert from "node:assert/strict";
import { test } from "node:test";
import {
  assertEvidenceForm,
  isCanonicalEnvironment,
  assertCanonicalProvenanceEnvironment,
} from "./lib/evidence/validators.mjs";
import {
  canonicalizeEvidenceDocument,
  stripEnvironmentForComparison,
  freshnessBytes,
  normalizeManifestForHash,
  manifestContentSha256,
  normalizedManifestSourcePath,
  normalizeVolatileProcessOutput,
  processOutputSha256,
} from "./lib/evidence/provenance.mjs";

const manifestText = (sourcePath, entry = "src/main.nako3") =>
  JSON.stringify({ format: "lnako-aot-manifest-v1", sourcePath, target: "native" }) + "\n" +
  JSON.stringify({ file: entry, sha256: "ab" }) + "\n";

test("manifestContentSha256 は header の sourcePath 差を正規化して一致する", () => {
  const left = manifestText("/tmp/alpha/work/main.nako3");
  const right = manifestText("/var/folders/xyz/beta/main.nako3");
  assert.notEqual(left, right);
  assert.equal(manifestContentSha256(left), manifestContentSha256(right));
});

test("manifestContentSha256 は header 以外の差分を検出する", () => {
  const base = manifestText("/tmp/a/main.nako3", "src/a.nako3");
  const changed = manifestText("/tmp/a/main.nako3", "src/b.nako3");
  assert.notEqual(manifestContentSha256(base), manifestContentSha256(changed));
});

test("normalizeManifestForHash は sourcePath のみを固定トークンへ置換する", () => {
  const normalized = normalizeManifestForHash(manifestText("/tmp/secret/main.nako3"));
  const header = JSON.parse(normalized.split("\n")[0]);
  assert.equal(header.sourcePath, normalizedManifestSourcePath);
  assert.equal(header.format, "lnako-aot-manifest-v1");
});

test("normalizeVolatileProcessOutput は揮発パスを file:// 形式含めて畳む", () => {
  const temporary = "/tmp/lnako-case-AbC123";
  const raw = `cwd=${temporary}\ntrace: file://${temporary}/case.mjs:120:5\n`;
  const normalized = normalizeVolatileProcessOutput(raw, { volatilePaths: [temporary] });
  assert.equal(normalized, "cwd=<lnako-volatile>\ntrace: <lnako-volatile>/case.mjs:120:5\n");
});

test("normalizeVolatileProcessOutput は包含関係のあるパスを長い方から畳む", () => {
  const root = "/repo";
  const oracle = "/repo/.cache/oracle/nadesiko3";
  const raw = `${oracle}/node_modules/x.js と ${root}/src`;
  const normalized = normalizeVolatileProcessOutput(raw, { volatilePaths: [root, oracle] });
  assert.equal(normalized, "<lnako-volatile>/node_modules/x.js と <lnako-volatile>/src");
});

test("normalizeVolatileProcessOutput は volatileStrings・PID・Node 版数・port を畳む", () => {
  const raw = "http://127.0.0.1:18081/ ポート番号(18081) (node:42) Warning\nNode.js v26.8.2\nhttp://localhost:8080/x";
  const normalized = normalizeVolatileProcessOutput(raw, { volatileStrings: ["http://127.0.0.1:18081"] });
  assert.equal(
    normalized,
    "<lnako-volatile>/ ポート番号(<port>) (node:<pid>) Warning\nNode.js <version>\nhttp://<addr>:<port>/x",
  );
});

test("processOutputSha256 は揮発値差・改行差を吸収して一致する", () => {
  const context = { volatilePaths: ["/tmp/one", "/tmp/two"] };
  const left = processOutputSha256("out=/tmp/one/case.mjs\r\nNode.js v24.15.0\r\n", context);
  const right = processOutputSha256("out=/tmp/two/case.mjs\nNode.js v26.8.2\n", context);
  assert.equal(left, right);
});

test("normalizeVolatileProcessOutput は公式eval関数名のfuncIDを畳む", () => {
  const left = "at __eval_nako3sync_1789567484418_3883383896__ (eval at evalJS)\n// <nadesiko3::gen::async id=\"1789567484418_3883383896\">";
  const right = "at __eval_nako3sync_1789567500000_123456__ (eval at evalJS)\n// <nadesiko3::gen::async id=\"1789567500000_123456\">";
  assert.equal(normalizeVolatileProcessOutput(left), normalizeVolatileProcessOutput(right));
  assert.ok(normalizeVolatileProcessOutput(left).includes("__eval_nako3sync__"));
});

test("processOutputSha256 は eval 匿名位置の列差（ソース絶対パス長）を畳み行番号は残す", () => {
  const shortRoot = "/Users/runner/work/lnako/lnako";
  const longRoot = "/Users/sora/Repositories/soramikan/lnako.improve-compat";
  const stack = (root, line, column) =>
    "[eval] SyntaxError: Function statements require a function name\n" +
    `    at sys.__evalJS (file://${root}/.cache/oracle/nadesiko3-3.7.24/core/src/plugin_system.mjs:204:33)\n` +
    `    at __eval_nako3sync_1789630962195_1515687614__ (eval at evalJS (file://${root}/.cache/oracle/nadesiko3-3.7.24/core/src/nako_runner.mjs:59:23), <anonymous>:${line}:${column})\n`;
  const left = processOutputSha256(stack(shortRoot, 59, 189), { volatilePaths: [shortRoot] });
  const right = processOutputSha256(stack(longRoot, 59, 214), { volatilePaths: [longRoot] });
  assert.equal(left, right);
  assert.ok(normalizeVolatileProcessOutput(stack(longRoot, 59, 214), { volatilePaths: [longRoot] }).includes("<anonymous>:59:<col>"));
  assert.notEqual(processOutputSha256(stack(shortRoot, 60, 189), { volatilePaths: [shortRoot] }), left);
  assert.notEqual(
    processOutputSha256(stack(shortRoot, 59, 189).replace("Function statements require a function name", "Unexpected token '('"), { volatilePaths: [shortRoot] }),
    left,
  );
});

test("normalizeVolatileProcessOutput は行一致のplatform値のみ畳む", () => {
  const darwin = normalizeVolatileProcessOutput("darwin\narm64\n共通linux勉強\n", { volatileLines: ["darwin", "arm64"] });
  const linux = normalizeVolatileProcessOutput("linux\nx64\n共通linux勉強\n", { volatileLines: ["linux", "x64"] });
  assert.equal(darwin, linux);
  assert.ok(darwin.includes("共通linux勉強"));
});

test("processOutputSha256 は volatileLines で platform 差を畳み内容差を検出する", () => {
  const context = { volatileLines: ["darwin", "linux", "arm64", "x64"] };
  assert.equal(processOutputSha256("darwin\narm64\nok\n", context), processOutputSha256("linux\nx64\nok\n", context));
  assert.notEqual(processOutputSha256("darwin\narm64\nok\n", context), processOutputSha256("linux\nx64\nng\n", context));
});

test("processOutputSha256 は意味ある出力差を検出する", () => {
  const context = { volatilePaths: ["/tmp/one"] };
  assert.notEqual(
    processOutputSha256("result=1 /tmp/one", context),
    processOutputSha256("result=2 /tmp/one", context),
  );
});

const evidence = (environment, withLnako = true) => ({
  schema: "lnako.test.v1",
  provenance: {
    environment,
    oracle: { build: 4 },
    ...(withLnako ? { lnako: { binarySha256: "aa", sourceManifestSha256: "bb" } } : {}),
    auditScriptSha256: "cc",
  },
  fixtures: [{ id: "f1", officialComparison: { status: "match" } }],
});

test("canonicalizeEvidenceDocument は lnako provenance と node を除去し入力を変異させない", () => {
  const measured = evidence({ platform: "darwin", arch: "arm64", node: "v26.8.2" });
  const canonical = canonicalizeEvidenceDocument(measured);
  assert.deepEqual(canonical.provenance.environment, { platform: "darwin", arch: "arm64" });
  assert.equal(canonical.provenance.lnako, undefined);
  assert.equal(measured.provenance.environment.node, "v26.8.2");
  assert.equal(measured.provenance.lnako.binarySha256, "aa");
});

test("canonicalizeEvidenceDocument は冪等である", () => {
  const once = canonicalizeEvidenceDocument(evidence({ platform: "darwin", arch: "arm64", node: "v24.15.0" }));
  assert.deepEqual(canonicalizeEvidenceDocument(once), once);
});

test("freshnessBytes は environment と lnako provenance の差を無視して一致する", () => {
  const darwin = evidence({ platform: "darwin", arch: "arm64", node: "v24.15.0" });
  const linux = evidence({ platform: "linux", arch: "x64", node: "v24.15.0" });
  delete linux.provenance.lnako;
  assert.equal(freshnessBytes(darwin), freshnessBytes(linux));
});

test("freshnessBytes は意味内容の差を検出し末尾改行を持つ", () => {
  const left = evidence({ platform: "darwin", arch: "arm64", node: "v24.15.0" });
  const right = evidence({ platform: "darwin", arch: "arm64", node: "v24.15.0" });
  right.fixtures[0].officialComparison.status = "mismatch";
  const bytes = freshnessBytes(left);
  assert.notEqual(bytes, freshnessBytes(right));
  assert.ok(bytes.endsWith("\n"));
});

test("stripEnvironmentForComparison は environment のみを除去する", () => {
  const stripped = stripEnvironmentForComparison(evidence({ platform: "darwin", arch: "arm64" }));
  assert.equal(stripped.provenance.environment, undefined);
  assert.equal(stripped.provenance.lnako.binarySha256, "aa");
});

test("assertEvidenceForm は measured/canonical のみを許可する", () => {
  assert.doesNotThrow(() => assertEvidenceForm("measured"));
  assert.doesNotThrow(() => assertEvidenceForm("canonical"));
  assert.throws(() => assertEvidenceForm("generated"), /evidence formが不正/);
});

test("isCanonicalEnvironment は darwin/arm64 のみを認める", () => {
  assert.equal(isCanonicalEnvironment({ platform: "darwin", arch: "arm64" }), true);
  assert.equal(isCanonicalEnvironment({ platform: "linux", arch: "x64" }), false);
  assert.throws(() => assertCanonicalProvenanceEnvironment({ platform: "linux", arch: "x64" }, "test"), /darwin\/arm64ではありません/);
  assert.doesNotThrow(() => assertCanonicalProvenanceEnvironment({ platform: "darwin", arch: "arm64" }, "test"));
});
