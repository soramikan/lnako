// Windows native AOT shardのcompiler buildをproducer jobへ集約するための
// artifact作成・検証ツール。誤commit・別構成のcompilerが使われないよう、
// metadata（commit・OS・arch・Zig version・build mode・compat-js）と
// binaryのSHA-256を厳密に照合してからinstallする。
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCHEMA = "lnako.aot-compiler-artifact.v1";
const METADATA_NAME = "compiler-artifact.json";
const BUILD_MODE = "Debug";
const COMPAT_JS = false;
const EXPECTED_KEYS = ["schema", "commit", "os", "arch", "zig", "buildMode", "compatJs", "binaryName", "binarySha256"];
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

export function createArtifact({ binaryPath, outDir, root = process.cwd(), env = process.env, platform = process.platform, arch = process.arch }) {
  if (!existsSync(binaryPath)) fail(`compiler binaryがありません: ${binaryPath}`);
  const binaryBytes = readFileSync(binaryPath);
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
  };
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, METADATA_NAME), `${JSON.stringify(metadata, null, 2)}\n`);
  copyFileSync(binaryPath, join(outDir, metadata.binaryName));
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
  if (!HEX_64.test(metadata.binarySha256)) fail("binarySha256が不正です");
  if (typeof metadata.binaryName !== "string" || metadata.binaryName.length === 0 || basename(metadata.binaryName) !== metadata.binaryName) {
    fail(`binaryNameが不正です: ${metadata.binaryName}`);
  }
  const binaryPath = join(dir, metadata.binaryName);
  if (!existsSync(binaryPath)) fail(`compiler binaryがありません: ${binaryPath}`);
  const actualSha256 = sha256Hex(readFileSync(binaryPath));
  if (actualSha256 !== metadata.binarySha256) fail(`compiler binaryのSHA-256が不一致です: expected=${metadata.binarySha256} actual=${actualSha256}`);
  if (installTo) {
    mkdirSync(installTo, { recursive: true });
    copyFileSync(binaryPath, join(installTo, metadata.binaryName));
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
    const metadata = createArtifact({ binaryPath: required("--binary"), outDir: required("--out-dir") });
    console.log(`AOT compiler artifactを作成しました: commit=${metadata.commit} ${metadata.os}/${metadata.arch} zig=${metadata.zig} sha256=${metadata.binarySha256.slice(0, 12)}...`);
  } else if (command === "verify") {
    const { metadata } = verifyArtifact({ dir: required("--dir"), installTo: required("--install-to") });
    console.log(`AOT compiler artifactを検証しました: commit=${metadata.commit} sha256=${metadata.binarySha256.slice(0, 12)}...`);
  } else {
    fail("create または verify を指定してください");
  }
}
