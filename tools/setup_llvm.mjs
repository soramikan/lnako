import { createHash } from "node:crypto";
import { createWriteStream } from "node:fs";
import { access, appendFile, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const lock = JSON.parse(await readFile(resolve(root, "toolchain.lock.json"), "utf8")).llvm;
const platformKey = platformArtifactKey();
const artifact = lock.artifacts[platformKey];
if (!artifact) throw new Error(`LLVM ${lock.version}の配布物が未定義です: ${platformKey}`);

const cacheRoot = resolve(root, ".cache/toolchains");
const target = resolve(cacheRoot, `llvm-${lock.version}-${platformKey}`);
const marker = resolve(target, ".lnako-toolchain.json");
const clang = resolve(target, "bin", process.platform === "win32" ? "clang.exe" : "clang");
const lld = resolve(target, "bin", lldName());

if (!(await isCurrent())) await install();
verifyTool(clang, lock.version);
verifyTool(lld, lock.version);
await exportEnvironment();
console.log(`LLVM/LLD ${lock.version}を確認しました: ${target}`);

async function isCurrent() {
  try {
    const current = JSON.parse(await readFile(marker, "utf8"));
    await access(clang);
    await access(lld);
    return current.version === lock.version && current.platform === platformKey && current.sha256 === artifact.sha256;
  } catch {
    return false;
  }
}

async function install() {
  await mkdir(cacheRoot, { recursive: true });
  const staging = resolve(cacheRoot, `.llvm-staging-${platformKey}-${process.pid}`);
  const archive = resolve(staging, "llvm.tar.xz");
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  try {
    const response = await fetch(artifact.url);
    if (!response.ok || !response.body) throw new Error(`LLVM配布物の取得に失敗しました: HTTP ${response.status}`);
    const hash = createHash("sha256");
    const hashingStream = new Transform({
      transform(chunk, _encoding, callback) {
        hash.update(chunk);
        callback(null, chunk);
      },
    });
    await pipeline(Readable.fromWeb(response.body), hashingStream, createWriteStream(archive));
    const actualHash = hash.digest("hex");
    if (actualHash !== artifact.sha256) {
      throw new Error(`LLVM配布物のSHA-256不一致: expected=${artifact.sha256} actual=${actualHash}`);
    }
    run("tar", ["-xJf", archive, "-C", staging]);
    const entries = (await readdir(staging, { withFileTypes: true })).filter((entry) => entry.isDirectory());
    if (entries.length !== 1) throw new Error(`LLVM配布物の展開ルートが一意ではありません: ${entries.map((entry) => entry.name).join(", ")}`);
    const extracted = resolve(staging, entries[0].name);
    await rm(target, { recursive: true, force: true });
    await rename(extracted, target);
    await writeFile(marker, `${JSON.stringify({ version: lock.version, platform: platformKey, sha256: artifact.sha256 }, null, 2)}\n`);
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

async function exportEnvironment() {
  if (process.env.GITHUB_ENV) await appendFile(process.env.GITHUB_ENV, `LNAKO_LLVM_DIR=${target}\n`);
  if (process.env.GITHUB_PATH) await appendFile(process.env.GITHUB_PATH, `${resolve(target, "bin")}\n`);
}

function platformArtifactKey() {
  if (process.platform === "darwin" && process.arch === "arm64") return "macos-aarch64";
  if (process.platform === "linux" && process.arch === "x64") return "linux-x86_64";
  if (process.platform === "win32" && process.arch === "x64") return "windows-x86_64";
  throw new Error(`正式対応外のホストです: ${process.platform}-${process.arch}`);
}

function lldName() {
  if (process.platform === "darwin") return "ld64.lld";
  if (process.platform === "win32") return "lld-link.exe";
  return "ld.lld";
}

function verifyTool(command, version) {
  const result = spawnSync(command, ["--version"], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(`${command}を実行できません:\n${result.stderr}`);
  if (!`${result.stdout}\n${result.stderr}`.includes(version)) throw new Error(`${command}はLLVM ${version}ではありません`);
}

function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: "inherit" });
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} が失敗しました`);
}
