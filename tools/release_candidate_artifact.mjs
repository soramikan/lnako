// CIで作ったReleaseSafe+compat-js compilerをReleaseへ昇格するための
// artifact。誤commit・別構成・別CI runの成果物を配布に載せないよう、
// metadata（commit・target・build mode・CI run ID・toolchain lock）と
// binary/runtimeのSHA-256を厳密に照合してからinstallする。
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCHEMA = "lnako.release-candidate.v1";
const METADATA_NAME = "release-candidate.json";
const BUILD_MODE = "ReleaseSafe";
const COMPAT_JS = true;
const TARGETS = new Set(["macos-arm64", "linux-x64", "windows-x64"]);
const EXPECTED_KEYS = [
  "schema", "commit", "os", "arch", "target", "zig", "buildMode", "compatJs", "version",
  "binaryName", "binarySha256", "runtimeLibName", "runtimeLibSha256",
  "ciRunId", "ciWorkflow", "ciJobName", "toolchainLockSha256",
];
const HEX_64 = /^[0-9a-f]{64}$/;
const RUN_ID = /^[0-9]+$/;

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function fail(message) {
  throw new Error(`Release candidate artifact: ${message}`);
}

function assertExactKeys(object, keys, label) {
  const actual = Object.keys(object ?? {}).sort();
  if (JSON.stringify(actual) !== JSON.stringify([...keys].sort())) fail(`${label}のkey構成が不正です: ${actual.join(",")}`);
}

function resolveCommit(root, env) {
  if (env.GITHUB_SHA && HEX_64.test(env.GITHUB_SHA)) return env.GITHUB_SHA;
  try {
    return execFileSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" }).trim();
  } catch {
    fail("commit SHAを解決できません（GITHUB_SHA未設定・git rev-parse失敗）");
  }
}

function zigVersion(root) {
  const lock = JSON.parse(readFileSync(resolve(root, "toolchain.lock.json"), "utf8"));
  if (typeof lock.zig?.version !== "string" || lock.zig.version.length === 0) fail("toolchain.lock.jsonのzig versionが不正です");
  return lock.zig.version;
}

function toolchainLockSha256(root) {
  return sha256Hex(readFileSync(resolve(root, "toolchain.lock.json")));
}

function projectVersion(root) {
  const text = readFileSync(resolve(root, "build.zig.zon"), "utf8");
  const match = text.match(/^\s*\.version\s*=\s*"([^"]+)"/m);
  if (!match) fail("build.zig.zonのversionを読めません");
  return match[1];
}

function requireTarget(target) {
  if (!TARGETS.has(target)) fail(`targetが不正です: ${target}`);
  return target;
}

function requireRunId(value, label) {
  if (typeof value !== "string" || !RUN_ID.test(value)) fail(`${label}が不正です: ${value}`);
  return value;
}

export function createArtifact({
  binaryPath,
  runtimeLibPath,
  outDir,
  target,
  root = process.cwd(),
  env = process.env,
  platform = process.platform,
  arch = process.arch,
}) {
  if (!existsSync(binaryPath)) fail(`compiler binaryがありません: ${binaryPath}`);
  if (!existsSync(runtimeLibPath)) fail(`AOT runtime libraryがありません: ${runtimeLibPath}`);
  const ciRunId = requireRunId(env.GITHUB_RUN_ID, "GITHUB_RUN_ID");
  const ciWorkflow = env.GITHUB_WORKFLOW;
  const ciJobName = env.GITHUB_JOB;
  if (typeof ciWorkflow !== "string" || ciWorkflow.length === 0) fail("GITHUB_WORKFLOWがありません");
  if (typeof ciJobName !== "string" || ciJobName.length === 0) fail("GITHUB_JOBがありません");
  const binaryBytes = readFileSync(binaryPath);
  const runtimeLibBytes = readFileSync(runtimeLibPath);
  const metadata = {
    schema: SCHEMA,
    commit: resolveCommit(root, env),
    os: platform,
    arch,
    target: requireTarget(target),
    zig: zigVersion(root),
    buildMode: BUILD_MODE,
    compatJs: COMPAT_JS,
    version: projectVersion(root),
    binaryName: basename(binaryPath),
    binarySha256: sha256Hex(binaryBytes),
    runtimeLibName: basename(runtimeLibPath),
    runtimeLibSha256: sha256Hex(runtimeLibBytes),
    ciRunId,
    ciWorkflow,
    ciJobName,
    toolchainLockSha256: toolchainLockSha256(root),
  };
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, METADATA_NAME), `${JSON.stringify(metadata, null, 2)}\n`);
  copyFileSync(binaryPath, join(outDir, metadata.binaryName));
  copyFileSync(runtimeLibPath, join(outDir, metadata.runtimeLibName));
  return metadata;
}

export function verifyArtifact({
  dir,
  installTo,
  expectedTarget,
  expectedRunId,
  expectedVersion = null,
  root = process.cwd(),
  env = process.env,
  platform = process.platform,
  arch = process.arch,
}) {
  const metadataPath = join(dir, METADATA_NAME);
  if (!existsSync(metadataPath)) fail(`metadataがありません: ${metadataPath}`);
  let metadata;
  try {
    metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
  } catch {
    fail("metadata JSONを解釈できません");
  }
  assertExactKeys(metadata, EXPECTED_KEYS, "metadata");
  if (metadata.schema !== SCHEMA) fail(`schemaが不正です: ${metadata.schema}`);
  const expectedCommit = resolveCommit(root, env);
  if (metadata.commit !== expectedCommit) fail(`commitが不一致です: artifact=${metadata.commit} expected=${expectedCommit}`);
  if (metadata.os !== platform || metadata.arch !== arch) {
    fail(`platformが不一致です: artifact=${metadata.os}/${metadata.arch} runner=${platform}/${arch}`);
  }
  if (metadata.target !== requireTarget(expectedTarget)) {
    fail(`targetが不一致です: artifact=${metadata.target} expected=${expectedTarget}`);
  }
  if (metadata.zig !== zigVersion(root)) fail(`Zig versionが不一致です: artifact=${metadata.zig}`);
  if (metadata.toolchainLockSha256 !== toolchainLockSha256(root)) fail("toolchain.lock.jsonのSHA-256が不一致です");
  if (metadata.buildMode !== BUILD_MODE || metadata.compatJs !== COMPAT_JS) fail("build構成が不一致です");
  if (expectedVersion !== null && metadata.version !== expectedVersion) {
    fail(`versionが不一致です: artifact=${metadata.version} expected=${expectedVersion}`);
  }
  if (metadata.version !== projectVersion(root)) {
    fail(`versionがsourceと不一致です: artifact=${metadata.version} source=${projectVersion(root)}`);
  }
  requireRunId(metadata.ciRunId, "ciRunId");
  if (metadata.ciRunId !== requireRunId(expectedRunId, "expectedRunId")) {
    fail(`CI run IDが不一致です: artifact=${metadata.ciRunId} expected=${expectedRunId}`);
  }
  if (typeof metadata.ciWorkflow !== "string" || metadata.ciWorkflow.length === 0) fail("ciWorkflowが不正です");
  if (typeof metadata.ciJobName !== "string" || metadata.ciJobName.length === 0) fail("ciJobNameが不正です");
  if (!HEX_64.test(metadata.binarySha256) || !HEX_64.test(metadata.runtimeLibSha256)) fail("成果物のSHA-256が不正です");
  for (const [field, name] of [["binaryName", metadata.binaryName], ["runtimeLibName", metadata.runtimeLibName]]) {
    if (typeof name !== "string" || name.length === 0 || basename(name) !== name) fail(`${field}が不正です: ${name}`);
  }
  const binaryPath = join(dir, metadata.binaryName);
  if (!existsSync(binaryPath)) fail(`compiler binaryがありません: ${binaryPath}`);
  const actualSha256 = sha256Hex(readFileSync(binaryPath));
  if (actualSha256 !== metadata.binarySha256) {
    fail(`compiler binaryのSHA-256が不一致です: expected=${metadata.binarySha256} actual=${actualSha256}`);
  }
  const runtimeLibPath = join(dir, metadata.runtimeLibName);
  if (!existsSync(runtimeLibPath)) fail(`AOT runtime libraryがありません: ${runtimeLibPath}`);
  const actualLibSha256 = sha256Hex(readFileSync(runtimeLibPath));
  if (actualLibSha256 !== metadata.runtimeLibSha256) {
    fail(`AOT runtime libraryのSHA-256が不一致です: expected=${metadata.runtimeLibSha256} actual=${actualLibSha256}`);
  }
  if (installTo) {
    mkdirSync(installTo, { recursive: true });
    const installedBinary = join(installTo, metadata.binaryName);
    copyFileSync(binaryPath, installedBinary);
    if (platform !== "win32") chmodSync(installedBinary, 0o755);
    const libDir = resolve(installTo, "..", "lib");
    mkdirSync(libDir, { recursive: true });
    copyFileSync(runtimeLibPath, join(libDir, metadata.runtimeLibName));
  }
  return { binaryPath, metadata };
}

function parseArgs(argv) {
  const options = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (!argument.startsWith("--")) fail(`引数が不正です: ${argument}`);
    const value = argv[index + 1];
    if (!value || value.startsWith("--")) fail(`引数の値がありません: ${argument}`);
    options.set(argument, value);
    index += 1;
  }
  return options;
}

const isMain = (() => {
  try {
    return process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
})();

if (isMain) {
  const [command, ...rest] = process.argv.slice(2);
  const options = parseArgs(rest);
  const required = (name) => {
    const value = options.get(name);
    if (!value) fail(`必須引数がありません: ${name}`);
    return value;
  };
  if (command === "create") {
    const metadata = createArtifact({
      binaryPath: required("--binary"),
      runtimeLibPath: required("--runtime-lib"),
      outDir: required("--out-dir"),
      target: required("--target"),
    });
    console.log(
      `Release candidate artifactを作成しました: commit=${metadata.commit} target=${metadata.target} run=${metadata.ciRunId} sha256=${metadata.binarySha256.slice(0, 12)}...`,
    );
  } else if (command === "verify") {
    const { metadata } = verifyArtifact({
      dir: required("--dir"),
      installTo: required("--install-to"),
      expectedTarget: required("--expected-target"),
      expectedRunId: required("--expected-run-id"),
      expectedVersion: options.get("--expected-version") ?? null,
    });
    console.log(
      `Release candidate artifactを検証しました: commit=${metadata.commit} target=${metadata.target} run=${metadata.ciRunId} sha256=${metadata.binarySha256.slice(0, 12)}...`,
    );
  } else {
    fail("create または verify を指定してください");
  }
}
