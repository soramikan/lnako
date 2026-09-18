import { spawnSync } from "node:child_process";
import { appendFileSync, readFileSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

// 軽量CIで十分な変更対象のallow-list。生成物・文書のみを対象とし、
// これ以外のパス（src, tests, tools, workflows, compat正本など）は
// すべてfull CIを要求する。誤分類は必ずfull側へ倒す。
const LIGHT_PATTERNS = [
  { category: "docs", pattern: /^docs\// },
  { category: "root-markdown", pattern: /^[^/]+\.md$/ },
  { category: "attestation-snapshot", pattern: /^compat\/[^/]+\/attestations\// },
];

export function isLightPath(path) {
  return LIGHT_PATTERNS.some(({ pattern }) => pattern.test(path));
}

export function categoryOf(path) {
  return LIGHT_PATTERNS.find(({ pattern }) => pattern.test(path))?.category ?? "full-required";
}

export function classify(paths) {
  const normalized = paths.map((path) => path.trim()).filter((path) => path.length > 0);
  if (normalized.length === 0) {
    return { level: "full", reason: "empty-diff", heavyPaths: [] };
  }
  const heavyPaths = normalized.filter((path) => !isLightPath(path));
  return heavyPaths.length === 0
    ? { level: "light", reason: "allow-list", heavyPaths }
    : { level: "full", reason: "heavy-paths", heavyPaths };
}

export function diffPaths(base, head = "HEAD", cwd = process.cwd()) {
  // --no-renames でrenameをdelete+addへ分解し、移動元パスも分類対象にする
  // （heavyファイルをdocs/等へ移動する変更をlightと誤分類しない）。
  const result = spawnSync("git", ["diff", "--name-only", "--no-renames", `${base}...${head}`], { cwd, encoding: "utf8" });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`git diff ${base}...${head} failed: ${(result.stderr ?? "").trim()}`);
  }
  return result.stdout.split("\n").filter((path) => path.length > 0);
}

function takeValue(args, index, name) {
  const value = args[index + 1];
  if (value === undefined || value.startsWith("--")) {
    throw new Error(`${name} requires a value`);
  }
  return value;
}

function parseArgs(argv) {
  const args = { event: "", base: "", head: "HEAD", files: "", output: "" };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--event") args.event = takeValue(argv, index, arg);
    else if (arg === "--base") args.base = takeValue(argv, index, arg);
    else if (arg === "--head") args.head = takeValue(argv, index, arg);
    else if (arg === "--files") args.files = takeValue(argv, index, arg);
    else if (arg === "--output") args.output = takeValue(argv, index, arg);
    else if (arg === "--help" || arg === "-h") {
      console.log("Usage: node tools/classify_changes.mjs [--event NAME] [--base SHA] [--head SHA] [--files FILE] [--output FILE]");
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
    index += 1;
  }
  return args;
}

export function decide({ event, base, head, files }) {
  if (event !== "" && event !== "pull_request" && event !== "push") {
    return { level: "full", reason: `event:${event}`, heavyPaths: [] };
  }
  let paths;
  if (files !== "") {
    try {
      paths = readFileSync(files, "utf8").split("\n");
    } catch (error) {
      console.error(`warning: change classification file list unreadable, running full CI: ${error.message}`);
      return { level: "full", reason: "diff-error", heavyPaths: [] };
    }
  } else {
    if (base === "" || /^0+$/.test(base)) {
      return { level: "full", reason: "no-base", heavyPaths: [] };
    }
    try {
      paths = diffPaths(base, head);
    } catch (error) {
      // 判定不能は常にfull側へ倒す（検証をスキップしない）。
      console.error(`warning: change classification diff failed, running full CI: ${error.message}`);
      return { level: "full", reason: "diff-error", heavyPaths: [] };
    }
  }
  return classify(paths);
}

// symlink経由のargv[1]でもmain判定が外れないようrealpathで比較する。
// 判定漏れで出力が書かれないと全jobが静黙skipされるため、CI側はlevel行の
// grep検査で欠落をfailにする多層防御を併用する。
const entryPath = process.argv[1];
const isMain = entryPath !== undefined && (
  import.meta.url === pathToFileURL(resolve(entryPath)).href ||
  import.meta.url === pathToFileURL(realpathSync(resolve(entryPath))).href
);
if (isMain) {
  const args = parseArgs(process.argv.slice(2));
  const { level, reason, heavyPaths } = decide(args);
  const safeReason = reason.replace(/[\r\n]/g, "_");
  console.log(`level=${level}`);
  console.log(`reason=${safeReason}`);
  if (heavyPaths.length > 0) {
    console.log(`full-required paths (${heavyPaths.length}):`);
    for (const path of heavyPaths) console.log(`  ${path}`);
  }
  if (args.output !== "") {
    appendFileSync(args.output, `level=${level}\nreason=${safeReason}\n`);
  }
}
