import { readdir, readFile } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const options = parseArguments(process.argv.slice(2));
const expectedTargets = new Map([
  ["macos-arm64", { os: "macos", arch: "aarch64" }],
  ["linux-x64", { os: "linux", arch: "x86_64" }],
  ["windows-x64", { os: "windows", arch: "x86_64" }],
]);
const entries = await readdir(options.directory, { withFileTypes: true });
const reports = [];
for (const [target, expectedTarget] of expectedTargets) {
  const jsonName = `benchmark-${target}.json`;
  const markdownName = `benchmark-${target}.md`;
  if (!entries.some((entry) => entry.isFile() && entry.name === jsonName) || !entries.some((entry) => entry.isFile() && entry.name === markdownName)) {
    throw new Error(`benchmark ${target}のJSON/Markdownが不足しています`);
  }
  const jsonPath = join(options.directory, jsonName);
  const markdownPath = join(options.directory, markdownName);
  const report = JSON.parse(await readFile(jsonPath, "utf8"));
  if (report.target?.os !== expectedTarget.os || report.target?.arch !== expectedTarget.arch) throw new Error(`benchmark targetが不一致です: ${target}`);
  if (options.version !== null && report.version !== options.version) throw new Error(`benchmark versionが不一致です: ${target}`);
  if (options.commit !== null && report.git_commit !== options.commit) throw new Error(`benchmark commitが不一致です: ${target}`);
  verifyBenchmark(jsonPath, markdownPath, report.suite);
  reports.push({ target, report });
}

const first = reports[0].report;
for (const { target, report } of reports.slice(1)) {
  for (const key of ["schema_version", "version", "suite_name", "suite", "suite_sha256", "source", "profile", "git_dirty", "optimization", "iterations", "warmup"]) {
    if (JSON.stringify(report[key]) !== JSON.stringify(first[key])) throw new Error(`benchmark共通条件が不一致です: ${target}/${key}`);
  }
  if (JSON.stringify(report.toolchain) !== JSON.stringify(first.toolchain)) throw new Error(`benchmark toolchainが不一致です: ${target}`);
  compareCaseDefinitions(first.cases, report.cases, target);
}
console.log(`3正式OSのbenchmark結果を検証しました: ${first.version} / schema ${first.schema_version} / profile ${first.profile ?? "legacy"} / ${reports.length} target`);

function parseArguments(arguments_) {
  const parsed = { directory: null, version: null, commit: null };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--directory") parsed.directory = nextValue(arguments_, ++index, argument);
    else if (argument === "--version") parsed.version = nextValue(arguments_, ++index, argument);
    else if (argument === "--commit") parsed.commit = nextValue(arguments_, ++index, argument);
    else throw new Error(`未知の引数です: ${argument}\n使い方: node tools/check_benchmark_set.mjs --directory /absolute/path [--version VERSION] [--commit SHA]`);
  }
  if (parsed.directory === null || !isAbsolute(parsed.directory)) throw new Error("--directoryには絶対パスを指定してください");
  if (parsed.version !== null && !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(parsed.version)) throw new Error(`versionがsemver形式ではありません: ${parsed.version}`);
  if (parsed.commit !== null && !/^[0-9a-f]{40}$/.test(parsed.commit)) throw new Error(`commitが40桁SHA-1ではありません: ${parsed.commit}`);
  return parsed;
}

function nextValue(arguments_, index, argument) {
  const value = arguments_[index];
  if (value === undefined || value.startsWith("--")) throw new Error(`${argument}の値がありません`);
  return value;
}

function verifyBenchmark(jsonPath, markdownPath, suitePath) {
  const args = [resolve(root, "tools/check_benchmark_result.mjs"), "--json", jsonPath, "--markdown", markdownPath];
  if (typeof suitePath === "string" && suitePath.length > 0) args.push("--suite", suitePath);
  const result = spawnSync(process.execPath, args, {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`benchmark結果検証に失敗しました: ${jsonPath}\n${result.stdout}\n${result.stderr}`);
}

function compareCaseDefinitions(firstCases, otherCases, target) {
  if (!Array.isArray(firstCases) || !Array.isArray(otherCases) || firstCases.length !== otherCases.length) {
    throw new Error(`benchmark case数が不一致です: ${target}`);
  }
  for (const [index, firstCase] of firstCases.entries()) {
    const otherCase = otherCases[index];
    for (const key of ["id", "category", "kind", "description", "measurement", "profiles", "tags", "source", "source_sha256", "input", "input_args", "expected_stdout"]) {
      if (JSON.stringify(firstCase[key]) !== JSON.stringify(otherCase?.[key])) throw new Error(`benchmark case定義が不一致です: ${target}/${firstCase?.id ?? index}/${key}`);
    }
  }
}
