import { readdir, readFile, stat } from "node:fs/promises";
import { createHash } from "node:crypto";
import { isAbsolute, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const options = parseArguments(process.argv.slice(2));
const targetSpecifications = new Map([
  ["macos-arm64", { extension: "tar.gz" }],
  ["linux-x64", { extension: "tar.gz" }],
  ["windows-x64", { extension: "zip" }],
]);
const entries = await readdir(options.directory, { withFileTypes: true });
if (entries.some((entry) => entry.isDirectory())) throw new Error("Release asset directoryにサブディレクトリがあります");
const archives = entries
  .filter((entry) => entry.isFile())
  .map((entry) => entry.name)
  .map((name) => /^(lnako-(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)-(macos-arm64|linux-x64|windows-x64)\.(tar\.gz|zip))$/.exec(name))
  .filter((match) => match !== null)
  .map((match) => ({ archive: match[1], version: match[2], target: match[3], extension: match[4] }));
if (archives.length !== targetSpecifications.size) throw new Error(`Release archiveは3 targetが必要です: ${archives.length}/${targetSpecifications.size}`);

const versions = new Set();
const targets = new Set();
for (const item of archives) {
  const specification = targetSpecifications.get(item.target);
  if (specification === undefined || specification.extension !== item.extension || targets.has(item.target)) throw new Error(`Release archiveのtargetまたは拡張子が不正です: ${item.archive}`);
  versions.add(item.version);
  targets.add(item.target);
  if (!(await isFile(join(options.directory, item.archive)))) throw new Error(`archiveが見つかりません: ${item.archive}`);
  const sbom = `${item.archive.slice(0, -item.extension.length - 1)}.spdx.json`;
  if (!(await isFile(join(options.directory, sbom)))) throw new Error(`SBOMが見つかりません: ${sbom}`);
  if (!(await isFile(join(options.directory, `${item.archive}.sha256`)))) throw new Error(`archive checksum sidecarが見つかりません: ${item.archive}`);
  verifyDistribution(join(options.directory, item.archive));
}
if (targets.size !== targetSpecifications.size || versions.size !== 1) throw new Error("Release archiveのtargetまたはversionが揃っていません");
const version = [...versions][0];
if (options.version !== null && options.version !== version) throw new Error(`Release versionが一致しません: ${options.version}/${version}`);

const checksumPath = join(options.directory, "SHA256SUMS");
const checksumText = await readFile(checksumPath, "utf8");
const checksums = parseChecksums(checksumText);
const required = new Set();
for (const item of archives) {
  const archiveBytes = await readFile(join(options.directory, item.archive));
  const archiveDigest = sha256(archiveBytes);
  const sbom = `${item.archive.slice(0, -item.extension.length - 1)}.spdx.json`;
  const sbomDigest = sha256(await readFile(join(options.directory, sbom)));
  required.add(item.archive);
  required.add(sbom);
  if (checksums.get(item.archive) !== archiveDigest || checksums.get(sbom) !== sbomDigest) throw new Error(`SHA256SUMSのdigestが一致しません: ${item.target}`);
  const sidecar = await readFile(join(options.directory, `${item.archive}.sha256`), "utf8");
  if (sidecar !== `${archiveDigest}  ${item.archive}\n`) throw new Error(`archive SHA-256 sidecarが一致しません: ${item.archive}`);
}
if (checksums.size !== required.size || [...required].some((name) => !checksums.has(name))) throw new Error("SHA256SUMSが3 targetのarchive／SBOMだけを正確に列挙していません");
console.log(`Release asset検証: ${version} / macos-arm64・linux-x64・windows-x64 / archive・checksum・SPDX SBOM成功`);

function parseArguments(arguments_) {
  const parsed = { directory: null, version: null };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--directory") parsed.directory = nextValue(arguments_, ++index, argument);
    else if (argument === "--version") parsed.version = nextValue(arguments_, ++index, argument);
    else throw new Error(`未知の引数です: ${argument}\n使い方: node tools/check_release_assets.mjs --directory /absolute/path [--version VERSION]`);
  }
  if (parsed.directory === null || !isAbsolute(parsed.directory)) throw new Error("--directoryには絶対パスを指定してください");
  parsed.directory = resolve(parsed.directory);
  return parsed;
}

function nextValue(arguments_, index, argument) {
  const value = arguments_[index];
  if (value === undefined || value.startsWith("--")) throw new Error(`${argument}の値がありません`);
  return value;
}

async function isFile(path) {
  const information = await stat(path).catch(() => null);
  return information?.isFile() ?? false;
}

function verifyDistribution(archive) {
  const result = spawnSync(process.execPath, [resolve(root, "tools/check_distribution.mjs"), "--archive", archive], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`配布物検証に失敗しました: ${archive}\n${result.stdout}\n${result.stderr}`);
}

function parseChecksums(text) {
  const checksums = new Map();
  for (const line of text.trimEnd().split("\n")) {
    const match = /^([0-9a-f]{64})  ([^\r\n]+)$/.exec(line.replace(/\r$/, ""));
    if (match === null || checksums.has(match[2])) throw new Error(`SHA256SUMSの行が不正です: ${line}`);
    checksums.set(match[2], match[1]);
  }
  return checksums;
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}
