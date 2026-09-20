// Windows native AOT shardのcompiler buildをproducer jobへ集約するための
// artifact作成・検証ツール。誤commit・別構成のcompilerが使われないよう、
// metadata（commit・OS・arch・Zig version・build mode・compat-js）と
// binaryのSHA-256を厳密に照合してからinstallする。
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCHEMA = "lnako.aot-compiler-artifact.v1";
const METADATA_NAME = "compiler-artifact.json";
const BUILD_MODE = "Debug";
const COMPAT_JS = false;
// compilerは<exe>/../lib/のAOTランタイム静的ライブラリを必要とするため、
// binaryとruntime libを1組の成果物として扱う。
const EXPECTED_KEYS = ["schema", "commit", "os", "arch", "zig", "buildMode", "compatJs", "binaryName", "binarySha256", "runtimeLibName", "runtimeLibSha256"];
const HEX_64 = /^[0-9a-f]{64}$/;

export function sha256Hex(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function fail(message) {
  throw new Error(`AOT compiler artifact: ${message}`);
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

export function createArtifact({ binaryPath, runtimeLibPath, outDir, root = process.cwd(), env = process.env, platform = process.platform, arch = process.arch }) {
  if (!existsSync(binaryPath)) fail(`compiler binaryがありません: ${binaryPath}`);
  if (!existsSync(runtimeLibPath)) fail(`AOT runtime libraryがありません: ${runtimeLibPath}`);
  const binaryBytes = readFileSync(binaryPath);
  const runtimeLibBytes = readFileSync(runtimeLibPath);
  const metadata = {
    schema: SCHEMA,
    commit: resolveCommit(root, env),
    os: platform,
    arch,
    zig: zigVersion(root),
    buildMode: BUILD_MODE,
    compatJs: COMPAT_JS,
    binaryName: basename(binaryPath),
    binarySha256: sha256Hex(binaryBytes),
    runtimeLibName: basename(runtimeLibPath),
    runtimeLibSha256: sha256Hex(runtimeLibBytes),
  };
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, METADATA_NAME), `${JSON.stringify(metadata, null, 2)}\n`);
  copyFileSync(binaryPath, join(outDir, metadata.binaryName));
  copyFileSync(runtimeLibPath, join(outDir, metadata.runtimeLibName));
  return metadata;
}

export function verifyArtifact({ dir, installTo, root = process.cwd(), env = process.env, platform = process.platform, arch = process.arch }) {
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
  if (metadata.os !== platform || metadata.arch !== arch) fail(`platformが不一致です: artifact=${metadata.os}/${metadata.arch} runner=${platform}/${arch}`);
  if (metadata.zig !== zigVersion(root)) fail(`Zig versionが不一致です: artifact=${metadata.zig}`);
  if (metadata.buildMode !== BUILD_MODE || metadata.compatJs !== COMPAT_JS) fail("build構成が不一致です");
  if (!HEX_64.test(metadata.binarySha256) || !HEX_64.test(metadata.runtimeLibSha256)) fail("成果物のSHA-256が不正です");
  for (const [field, name] of [["binaryName", metadata.binaryName], ["runtimeLibName", metadata.runtimeLibName]]) {
    if (typeof name !== "string" || name.length === 0 || basename(name) !== name) fail(`${field}が不正です: ${name}`);
  }
  const binaryPath = join(dir, metadata.binaryName);
  if (!existsSync(binaryPath)) fail(`compiler binaryがありません: ${binaryPath}`);
  const actualSha256 = sha256Hex(readFileSync(binaryPath));
  if (actualSha256 !== metadata.binarySha256) fail(`compiler binaryのSHA-256が不一致です: expected=${metadata.binarySha256} actual=${actualSha256}`);
  const runtimeLibPath = join(dir, metadata.runtimeLibName);
  if (!existsSync(runtimeLibPath)) fail(`AOT runtime libraryがありません: ${runtimeLibPath}`);
  const actualLibSha256 = sha256Hex(readFileSync(runtimeLibPath));
  if (actualLibSha256 !== metadata.runtimeLibSha256) fail(`AOT runtime libraryのSHA-256が不一致です: expected=${metadata.runtimeLibSha256} actual=${actualLibSha256}`);
  if (installTo) {
    mkdirSync(installTo, { recursive: true });
    const installedBinary = join(installTo, metadata.binaryName);
    copyFileSync(binaryPath, installedBinary);
    // upload-artifact／download-artifactは実行ビットを保証しないため、
    // POSIXではinstall時に明示的に付与する（Linux consumerで
    // `spawn ... EACCES`になる実測不具合の再発防止）。Windowsでは不要。
    if (platform !== "win32") chmodSync(installedBinary, 0o755);
    // compilerは<exe>/../lib/を探索するため、binの兄弟libへinstallする。
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
    const metadata = createArtifact({ binaryPath: required("--binary"), runtimeLibPath: required("--runtime-lib"), outDir: required("--out-dir") });
    console.log(`AOT compiler artifactを作成しました: commit=${metadata.commit} ${metadata.os}/${metadata.arch} zig=${metadata.zig} sha256=${metadata.binarySha256.slice(0, 12)}...`);
  } else if (command === "verify") {
    const { metadata } = verifyArtifact({ dir: required("--dir"), installTo: required("--install-to") });
    console.log(`AOT compiler artifactを検証しました: commit=${metadata.commit} sha256=${metadata.binarySha256.slice(0, 12)}...`);
  } else {
    fail("create または verify を指定してください");
  }
}
