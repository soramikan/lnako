import { readdir, readFile, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { isAbsolute, join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const options = parseArguments(process.argv.slice(2));
const targetSpecifications = new Map([
  ["macos-arm64", { extension: "tar.gz" }],
  ["linux-x64", { extension: "tar.gz" }],
  ["windows-x64", { extension: "zip" }],
]);
const directory = options.directory;
const files = await readdir(directory, { withFileTypes: true });
if (files.some((entry) => entry.isDirectory())) throw new Error("Release asset directoryにサブディレクトリがあります");

const archiveCandidates = files
  .filter((entry) => entry.isFile())
  .map((entry) => entry.name)
  .map((name) => /^(lnako-(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)-(macos-arm64|linux-x64|windows-x64)\.(tar\.gz|zip))$/.exec(name))
  .filter((match) => match !== null)
  .map((match) => ({ archive: match[1], version: match[2], target: match[3], extension: match[4] }));

if (archiveCandidates.length !== targetSpecifications.size) {
  throw new Error(`Release archiveは3 targetが必要です: ${archiveCandidates.length}/${targetSpecifications.size}`);
}
const targets = new Set();
const versions = new Set();
for (const candidate of archiveCandidates) {
  if (targets.has(candidate.target)) throw new Error(`Release archiveのtargetが重複しています: ${candidate.target}`);
  const specification = targetSpecifications.get(candidate.target);
  if (specification.extension !== candidate.extension) throw new Error(`Release archiveの拡張子が不正です: ${candidate.archive}`);
  targets.add(candidate.target);
  versions.add(candidate.version);
}
if (targets.size !== targetSpecifications.size || versions.size !== 1) throw new Error("Release archiveのtargetまたはversionが揃っていません");
const version = [...versions][0];
if (options.version !== null && options.version !== version) throw new Error(`Release versionが一致しません: ${options.version}/${version}`);

const checksumEntries = [];
for (const candidate of archiveCandidates.sort((left, right) => left.archive.localeCompare(right.archive))) {
  const archivePath = join(directory, candidate.archive);
  const archiveBytes = await readRequiredFile(archivePath);
  const archiveDigest = sha256(archiveBytes);
  const sidecarName = `${candidate.archive}.sha256`;
  const sidecar = (await readRequiredFile(join(directory, sidecarName))).toString("utf8");
  if (sidecar !== `${archiveDigest}  ${candidate.archive}\n`) throw new Error(`archive SHA-256 sidecarが一致しません: ${candidate.archive}`);

  const sbomName = `${candidate.archive.slice(0, -candidate.extension.length - 1)}.spdx.json`;
  const sbomDigest = sha256(await readRequiredFile(join(directory, sbomName)));
  checksumEntries.push([candidate.archive, archiveDigest], [sbomName, sbomDigest]);
}
checksumEntries.sort(([left], [right]) => left.localeCompare(right));
await writeFile(join(directory, "SHA256SUMS"), checksumEntries.map(([name, digest]) => `${digest}  ${name}`).join("\n") + "\n");
console.log(`Release checksumを生成しました: version ${version} / ${checksumEntries.length} assets`);

function parseArguments(arguments_) {
  const parsed = { directory: null, version: null };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--directory") parsed.directory = nextValue(arguments_, ++index, argument);
    else if (argument === "--version") parsed.version = nextValue(arguments_, ++index, argument);
    else throw new Error(`未知の引数です: ${argument}\n使い方: node tools/create_release_checksums.mjs --directory /absolute/path [--version VERSION]`);
  }
  if (parsed.directory === null || !isAbsolute(parsed.directory)) throw new Error("--directoryには絶対パスを指定してください");
  parsed.directory = resolve(parsed.directory);
  if (parsed.version !== null && !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(parsed.version)) throw new Error(`versionがsemver形式ではありません: ${parsed.version}`);
  return parsed;
}

function nextValue(arguments_, index, argument) {
  const value = arguments_[index];
  if (value === undefined || value.startsWith("--")) throw new Error(`${argument}の値がありません`);
  return value;
}

async function readRequiredFile(path) {
  const information = await stat(path).catch(() => null);
  if (information === null || !information.isFile()) throw new Error(`Release assetが見つかりません: ${path}`);
  return readFile(path);
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}
