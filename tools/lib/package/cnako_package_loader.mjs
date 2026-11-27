#!/usr/bin/env node
// 公式 cnako3 に `パッケージ:` / `pkg:` 取り込みを委譲するloader（#61契約のテスト用adapter）。
//
// 公式 cnako3 v3.7.24 は `パッケージ:` 構文を持たない。仕様 v1 では
// 依存解決・同期は lnako へ委譲し、cnako 側は `lnako sync` が公開した
// `.nako/v1` 環境の package/export 対応だけを使って export を解決する。
// このモジュールはその契約をテストから実行できる形にした adapter であり、
// cnako 本体への実装（#61）を置き換えるものではない。旧
// `.nako/environment.json`・旧 lock・旧 manifest は読まない。
//
// 重要: fixture のソースは書き換えない。公式 cnako3 の loader
// （`resolvePath`）を差し替え、パッケージ指定子だけを環境上の
// `<package path>/<export path>` へ解決する。構文解析・名前空間・実行は
// すべて公式 cnako3 が行う。
//
// 使い方:
//   node tools/lib/package/cnako_package_loader.mjs \
//     --root <project root> --entry <main.nako3> --oracle <nadesiko3 root> \
//     [--lnako <lnako executable>] [--v1-fixture <dir>] \
//     [--registry <https url>] [--no-sync]
//
// `--no-sync` は lnako を起動せず、既存 `.nako/v1` 環境の `lock_sha256` と
// `nako.lock` の実 SHA-256 を照合してから実行する。このadapterの
// `--no-sync` 検証は v1 environment の世代・profile・runtime・
// `lock_sha256`（3形式）、managed path成分のsymlink検査のみ。profile・
// 命令metadata・lockグラフの完全一致は cnako 本体実装（#61）の範囲。
// 診断コードは本体と完全一致しない（例: 同一aliasが複数packageを指す環境は
// 本体では生成時に拒否され、このadapterではE034）。
import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const SPECIFIER_PREFIXES = ["パッケージ:", "pkg:"];
const SOURCE_EXTENSION = /\.nako3$/i;
const repositoryRoot = path.resolve(import.meta.dirname, "..", "..", "..");

/** loader自身の診断。cnako 本体の診断コード体系と衝突しないようE###を使う。 */
export class PackageLoaderError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
    // 公式cnako3の loader は `logger.error(err.msg)` で読み込めなかった理由を
    // 出すため、msg が無いと `[エラー]undefined` になる。
    this.msg = message;
  }
}

/** 引数・使い方の誤り。環境参照の診断（E034）とは区別する。 */
export class UsageError extends Error {}

export function usage() {
  return [
    "cnako package loader: --root <dir> --entry <file> --oracle <dir> [--lnako <path>] [--v1-fixture <dir>] [--registry <url>] [--no-sync]",
    "  --root        nako.toml を持つプロジェクトroot",
    "  --entry       実行する .nako3（root相対または絶対path）",
    "  --oracle      nadesiko3 v3.7.24 の展開先（src/cnako3mod.mjs を含む）",
    "  --lnako       lnako 実行ファイル（省略時は zig-out/bin/lnako）",
    "  --v1-fixture  lnako sync に渡す静的ローカル index のルート",
    "  --registry    lnako sync に渡す HTTPS の registry URL",
    "  --no-sync     lnako を起動せず既存 .nako/v1 環境を検証して使う",
  ].join("\n");
}

function parseArguments(argv) {
  const options = { sync: true };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const takeValue = (name) => {
      const value = argv[index + 1];
      if (value === undefined || value.startsWith("--")) {
        throw new UsageError(`${name} には値が必要です`);
      }
      index += 1;
      return value;
    };
    switch (argument) {
      case "--root":
        options.root = takeValue(argument);
        break;
      case "--entry":
        options.entry = takeValue(argument);
        break;
      case "--oracle":
        options.oracle = takeValue(argument);
        break;
      case "--lnako":
        options.lnako = takeValue(argument);
        break;
      case "--v1-fixture":
        options.v1Fixture = takeValue(argument);
        break;
      case "--registry":
        options.registry = takeValue(argument);
        break;
      case "--no-sync":
        options.sync = false;
        break;
      case "--help":
        console.log(usage());
        process.exit(0);
        break;
      default:
        throw new UsageError(`未知の引数です: ${argument}`);
    }
  }
  for (const required of ["root", "entry", "oracle"]) {
    if (!options[required]) throw new UsageError(`${required} を指定してください`);
  }
  if (options.sync && !options.v1Fixture) {
    throw new UsageError("--v1-fixture を指定してください（v1 sync の取得元）");
  }
  options.registry = options.registry ?? "https://registry.example.invalid";
  return options;
}

function sha256HexFile(file) {
  return createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

// §7.3 は `sha256:<64 hex>`・生64桁hex・SRI (`sha256-<43 base64>=`) を許容する。
function normalizeSha256(value) {
  if (typeof value !== "string") return null;
  if (/^sha256:[0-9a-f]{64}$/.test(value)) return value.slice("sha256:".length);
  if (/^[0-9a-f]{64}$/.test(value)) return value;
  const sri = /^sha256-([A-Za-z0-9+/]{43}=)$/.exec(value);
  if (sri === null) return null;
  const digest = Buffer.from(sri[1], "base64");
  return digest.length === 32 ? digest.toString("hex") : null;
}

function readRegularFile(file, label) {
  let stat;
  try {
    stat = fs.lstatSync(file);
  } catch (error) {
    throw new PackageLoaderError(
      "E034_INVALID_ENVIRONMENT_REFERENCE",
      `${label} を読めません（先に lnako sync が必要です）: ${error.message}`,
    );
  }
  if (stat.isSymbolicLink()) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${label} がsymlinkです`);
  }
  if (!stat.isFile()) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${label} が通常ファイルではありません`);
  }
  return fs.readFileSync(file, "utf8");
}

/** `--no-sync` 用の v1 `nako.lock`（JSON）を読み、最小構造を検査する。 */
function readLock(root) {
  const text = readRegularFile(path.join(root, "nako.lock"), "nako.lock");
  let lock;
  try {
    lock = JSON.parse(text);
  } catch (error) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `nako.lock が不正なJSONです: ${error.message}`);
  }
  if (lock?.schema_version !== 1 || !Array.isArray(lock.profiles)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "nako.lock が v1 形式ではありません");
  }
  return lock;
}

function localName(id) {
  const slash = id.lastIndexOf("/");
  return slash < 0 ? id : id.slice(slash + 1);
}

function edgeDependency(edge) {
  if (typeof edge?.to !== "string" || typeof edge?.id !== "string") {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "nako.lock の依存edgeが不正です");
  }
  const alias = typeof edge.alias === "string" ? edge.alias : localName(edge.id);
  return { alias, package: edge.to };
}

function exportName(subpath) {
  if (subpath === ".") return "main";
  if (typeof subpath === "string" && subpath.startsWith("./")) return subpath.slice(2);
  throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `environment の export subpath が不正です: ${String(subpath)}`);
}

/**
 * v1 environment（`.nako/v1/generations/<gen>/environment.json` と
 * `lnako sync --json` の出力）を、既存 resolver の adapter 形式へ写す。
 * package の実体は materialize 済みの v1 世代 dir を指す。
 */
export function environmentFromV1(v1Environment, lock) {
  if (v1Environment?.schema_version !== 1 || !Array.isArray(v1Environment.packages)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "v1 environment の形状が不正です");
  }
  if (typeof v1Environment.profile !== "string") {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "v1 environment の profile がありません");
  }
  if (v1Environment.runtime !== "lnako") {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `v1 environment の runtime が lnako ではありません: ${String(v1Environment.runtime)}`);
  }
  if (typeof v1Environment.generation !== "string" || !/^gen-[0-9a-f]{16}$/.test(v1Environment.generation)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "v1 environment の generation が不正です");
  }
  const profile = lock.profiles.find((candidate) => candidate?.name === v1Environment.profile);
  if (profile === undefined || !Array.isArray(profile.nodes) || !Array.isArray(profile.root) || !Array.isArray(profile.edges)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `nako.lock に profile ${v1Environment.profile} がありません`);
  }
  const keyByIdentity = new Map();
  for (const node of profile.nodes) {
    if (typeof node?.key !== "string" || typeof node.id !== "string" || typeof node.version !== "string" || typeof node.sha256 !== "string") {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "nako.lock の node が不正です");
    }
    keyByIdentity.set(`${node.id}\0${node.version}\0${node.sha256}`, node.key);
  }

  const packages = {};
  for (const pkg of v1Environment.packages) {
    if (typeof pkg?.id !== "string" || typeof pkg.version !== "string" || typeof pkg.sha256 !== "string" || typeof pkg.root !== "string") {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "v1 environment の package record が不正です");
    }
    const key = keyByIdentity.get(`${pkg.id}\0${pkg.version}\0${pkg.sha256}`);
    if (key === undefined) {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `v1 environment の package ${pkg.id}@${pkg.version} が nako.lock にありません`);
    }
    if (packages[key] !== undefined) {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `v1 environment の package key が重複しています: ${key}`);
    }
    if (!Array.isArray(pkg.exports)) {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `v1 environment の package ${pkg.id} に exports がありません`);
    }
    const exports = pkg.exports.map((entry) => {
      if (typeof entry?.subpath !== "string" || typeof entry.entry !== "string") {
        throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `v1 environment の export が不正です: ${pkg.id}`);
      }
      return { name: exportName(entry.subpath), path: entry.entry };
    });
    packages[key] = {
      name: localName(pkg.id),
      version: pkg.version,
      path: path.posix.join(".nako", "v1", "generations", v1Environment.generation, pkg.root),
      exports,
      dependencies: profile.edges.filter((edge) => edge?.from === key).map(edgeDependency),
    };
  }
  return {
    schemaVersion: 1,
    lockSha256: v1Environment.lock_sha256,
    profile: v1Environment.profile,
    runtime: v1Environment.runtime,
    packages,
    dependencies: profile.root.map(edgeDependency),
  };
}

/** `lnako sync --json` の委譲呼出し。v1 環境を adapter 形式へ写す。 */
function syncEnvironment(root, lnako, options) {
  const result = spawnSync(lnako, ["sync", "--v1-fixture", options.v1Fixture, "--registry", options.registry, "--json"], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    timeout: 600_000,
  });
  if (result.error) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `lnako sync を実行できません: ${result.error.message}`);
  }
  if (result.status === null) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `lnako sync がtimeoutで終了しました（signal: ${result.signal ?? "unknown"}）`);
  }
  if (result.status !== 0) {
    const detail = (result.stderr ?? "").trim();
    if (detail.length > 0) console.error(detail);
    throw new PackageLoaderError(
      "E034_INVALID_ENVIRONMENT_REFERENCE",
      `lnako sync が失敗しました（終了コード ${result.status}）。上記の委譲先診断を確認してください`,
    );
  }
  const text = (result.stdout ?? "").trim();
  if (text.length === 0) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "lnako sync --json の出力が空です");
  }
  let v1Environment;
  try {
    v1Environment = JSON.parse(text);
  } catch (error) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `lnako sync --json の出力がJSONとして不正です: ${error.message}`);
  }
  validateEnvironmentLock(v1Environment, path.join(root, "nako.lock"));
  return environmentFromV1(v1Environment, readLock(root));
}

/** `--no-sync` 用: lnako を起動せず v1 環境と lock の対応だけを検証する。 */
function readEnvironmentWithoutSync(root) {
  const v1Dir = path.join(root, ".nako", "v1");
  assertNoSymlinkComponents(root, v1Dir);
  const pointerText = readRegularFile(path.join(v1Dir, "environment.json"), ".nako/v1/environment.json");
  let pointer;
  try {
    pointer = JSON.parse(pointerText);
  } catch (error) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `.nako/v1/environment.json が不正なJSONです: ${error.message}`);
  }
  if (pointer?.schema_version !== 1 || typeof pointer.generation !== "string" || !/^gen-[0-9a-f]{16}$/.test(pointer.generation)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", ".nako/v1/environment.json の generation が不正です");
  }
  const generationPath = path.join(v1Dir, "generations", pointer.generation);
  assertNoSymlinkComponents(root, generationPath);
  const text = readRegularFile(path.join(generationPath, "environment.json"), `.nako/v1/generations/${pointer.generation}/environment.json`);
  let v1Environment;
  try {
    v1Environment = JSON.parse(text);
  } catch (error) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `v1 世代の environment.json が不正なJSONです: ${error.message}`);
  }
  if (v1Environment.generation !== pointer.generation) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", ".nako/v1/environment.json の generation が世代の environment.json と一致しません");
  }
  validateEnvironmentLock(v1Environment, path.join(root, "nako.lock"));
  return environmentFromV1(v1Environment, readLock(root));
}

/** v1 environment の identity と `nako.lock` の実digestを照合する（テスト用にexport）。 */
export function validateEnvironmentLock(environment, lockPath) {
  if (environment?.schema_version !== 1) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `environment の schema_version が不正です: ${String(environment?.schema_version)}`);
  }
  if (typeof environment.generation !== "string" || !/^gen-[0-9a-f]{16}$/.test(environment.generation)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "environment の generation がありません");
  }
  if (typeof environment.profile !== "string") {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "environment の profile がありません");
  }
  if (environment.runtime !== "lnako") {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `environment の runtime が lnako ではありません: ${String(environment.runtime)}`);
  }
  if (!fs.existsSync(lockPath)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "nako.lock がありません");
  }
  const actual = sha256HexFile(lockPath);
  if (normalizeSha256(environment.lock_sha256) !== actual) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "v1 environment の lock_sha256 が nako.lock と一致しません");
  }
}

function isInside(parent, child) {
  const relative = path.relative(parent, child);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function realPathOrNull(target) {
  try {
    return fs.realpathSync(target);
  } catch {
    return null;
  }
}

// §7.3 の no-follow 契約: managed pathの成分がsymlink/reparse pointなら
// その環境は管理外を指すため再利用しない。対象は project root 配下の成分
// （`.nako`/世代dir/package path）に限る。root外の宣言path成分の検証は
// lnako 側の環境検証が担う（ここで filesystem root から辿ると、macOS の
// /var のような OS 標準の symlink を誤検出する）。
function assertNoSymlinkComponents(projectRoot, targetPath) {
  if (!isInside(projectRoot, targetPath)) return;
  let cursor = projectRoot;
  for (const component of path.relative(projectRoot, targetPath).split(path.sep)) {
    if (component.length === 0) continue;
    cursor = path.join(cursor, component);
    let stat;
    try {
      stat = fs.lstatSync(cursor);
    } catch (error) {
      if (error.code === "ENOENT" || error.code === "ENOTDIR") return;
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `環境pathを検査できません: ${error.message}`);
    }
    if (stat.isSymbolicLink()) {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `環境pathにsymlink成分があります: ${cursor}`);
    }
  }
}

// lnako の `namespaceFor`（alias部分）と同じ正規化。lnako は UTF-8 バイト単位で
// byte>=0x80 をそのまま保持するため、astral コードポイントもバイト列で扱う。
// 正規化後に同じ公開名へ落ちる別aliasは、runtime登録名を一意に分解できない
// ため環境として不正。
function normalizeAlias(alias) {
  const body = alias.startsWith("@") ? alias.slice(1) : alias;
  const bytes = Buffer.from(body, "utf8");
  const output = [];
  let atStart = true;
  for (const byte of bytes) {
    if (byte === 0x2f) {
      // lnako の appendNamespacePart は `/` で at_start を落とさない。
      output.push(0x5f, 0x5f);
    } else if ((byte >= 0x61 && byte <= 0x7a) || (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x30 && byte <= 0x39) || byte === 0x5f || byte >= 0x80) {
      if (atStart && byte >= 0x30 && byte <= 0x39) output.push(0x5f);
      output.push(byte);
      atStart = false;
    } else {
      output.push(0x5f);
      atStart = false;
    }
  }
  return Buffer.from(output).toString("utf8");
}

function validateExports(entries, label) {
  if (entries === undefined) return [];
  if (!Array.isArray(entries)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${label} の exports が配列ではありません`);
  }
  for (const entry of entries) {
    // environment schema は name を必須、alias/path を任意の文字列とする。
    if (typeof entry?.name !== "string" || entry.name.length === 0) {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${label} の exports に name が文字列でないrecordがあります`);
    }
    if (entry.alias !== undefined && typeof entry.alias !== "string") {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${label} の exports の alias が文字列ではありません`);
    }
    if (entry.path !== undefined && typeof entry.path !== "string") {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${label} の exports の path が文字列ではありません`);
    }
  }
  return entries;
}

function validateImportDependencies(entries, label) {
  if (entries === undefined) return [];
  if (!Array.isArray(entries)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${label} の dependencies が配列ではありません`);
  }
  for (const entry of entries) {
    if (typeof entry?.alias !== "string" || typeof entry.package !== "string") {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${label} の dependencies に alias/package が文字列でないrecordがあります`);
    }
    // lnako は空alias・正規化後に空になるalias（`@` 単体）を環境として拒否する。
    if (entry.alias.length === 0 || entry.alias === "@") {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${label} の dependencies に空namespaceのaliasがあります`);
    }
  }
  // 同一scopeで正規化後に同じ公開namespaceへ落ちる別packageは拒否する。
  const normalized = new Map();
  for (const entry of entries) {
    const namespace = normalizeAlias(entry.alias);
    const previous = normalized.get(namespace);
    if (previous !== undefined && previous !== entry.package) {
      throw new PackageLoaderError(
        "E034_INVALID_ENVIRONMENT_REFERENCE",
        `${label} の alias "${entry.alias}" は正規化後に "${namespace}" で別packageと衝突します`,
      );
    }
    normalized.set(namespace, entry.package);
  }
  return entries;
}

// §6.1 の規範 path。posix `/` 区切りで `..`/`.`/空成分・`\`・制御文字・
// 先頭/末尾 `/` を含まない（src/package/npkg_files.zig の isCanonicalPath と同規則）。
function isCanonicalPath(value) {
  if (typeof value !== "string" || value.length === 0) return false;
  if (value.startsWith("/") || value.endsWith("/")) return false;
  return value.split("/").every((component) => {
    if (component.length === 0 || component === "." || component === "..") return false;
    for (const character of component) {
      const code = character.codePointAt(0);
      if (code < 0x20 || code === 0x7f || character === "\\") return false;
    }
    return true;
  });
}

function canonicalExportPath(file, specifier) {
  if (!isCanonicalPath(file) || path.isAbsolute(file)) {
    throw new PackageLoaderError("E029_INVALID_VALUE", `${specifier} のexport pathが規範pathではありません: ${String(file)}`);
  }
  return file;
}

/** export entry から実pathを選ぶ（テスト用にexport）。 */
export function normalizeExportPath(exportEntry, specifier) {
  const file = exportEntry?.path;
  if (typeof file !== "string" || file.length === 0) {
    throw new PackageLoaderError(
      "E031_UNSUPPORTED_RUNTIME",
      `${specifier} をcnakoで実行できるsource exportがありません（path指定のみ対応）`,
    );
  }
  canonicalExportPath(file, specifier);
  // このadapterは source export だけを実行する。ESM/native artifact は
  // cnako 本体実装（#61）の範囲なので、nako3ソース以外は明示的に拒否する。
  if (!SOURCE_EXTENSION.test(file)) {
    throw new PackageLoaderError("E031_UNSUPPORTED_RUNTIME", `${specifier} のexportはsource (.nako3/.nako) ではありません: ${file}`);
  }
  return file;
}

/**
 * 公開exportの選択（テスト用にexport）。subpathなしは lnako 本体
 * （src/package/import_resolver.zig の selectExport）と同じ3段フォールバック:
 * name main/index → path basename main.nako3/index.nako3 → exports 1件。
 */
export function selectExportEntry(exports, subpath, specifier) {
  if (subpath === null) {
    const byName = exports.filter((entry) => entry?.name === "main" || entry?.name === "index");
    if (byName.length === 1) return byName[0];
    if (byName.length > 1) {
      throw new PackageLoaderError("E005_AMBIGUOUS_SELECTION", `${specifier} の既定export（main/index）を一意に選べません`);
    }
    const byBasename = exports.filter((entry) => {
      if (typeof entry?.path !== "string") return false;
      const basename = path.posix.basename(entry.path);
      return basename === "main.nako3" || basename === "index.nako3";
    });
    if (byBasename.length === 1) return byBasename[0];
    if (byBasename.length > 1) {
      throw new PackageLoaderError("E005_AMBIGUOUS_SELECTION", `${specifier} の既定export（main.nako3/index.nako3）を一意に選べません`);
    }
    if (exports.length === 1) return exports[0];
    throw new PackageLoaderError("E013_MISSING_PACKAGE", `${specifier} の既定exportを一意に選べません`);
  }
  const matches = exports.filter((entry) => entry?.name === subpath || entry?.alias === subpath);
  if (matches.length === 1) return matches[0];
  if (matches.length > 1) {
    throw new PackageLoaderError("E005_AMBIGUOUS_SELECTION", `${specifier} のsubpath "${subpath}" が複数exportに一致します`);
  }
  throw new PackageLoaderError("E013_MISSING_PACKAGE", `${specifier} のsubpath "${subpath}" は公開されていません`);
}

/**
 * `パッケージ:alias[/subpath]` を環境上の実ファイルへ解決する。
 * aliasは取り込み元ファイルの依存scope（rootまたはpackage自身）で照合し、
 * subpathは公開exportの name または alias に一致するものだけを選ぶ。
 */
export function createResolver(environment, projectRoot, options = {}) {
  if (environment === null || typeof environment !== "object" || Array.isArray(environment)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "environment がJSON objectではありません");
  }
  if (environment.packages === null || typeof environment.packages !== "object" || Array.isArray(environment.packages)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", "environment の packages がJSON objectではありません");
  }
  const untrusted = options.untrusted === true;
  const packages = new Map();
  for (const [key, record] of Object.entries(environment.packages)) {
    if (typeof record?.path !== "string") {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `environment の package ${key} に path がありません`);
    }
    if (typeof record.name !== "string" || typeof record.version !== "string") {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `environment の package ${key} に name/version がありません`);
    }
    const absolute = path.resolve(projectRoot, record.path);
    // `--no-sync` では環境は外部入力なので、§7.3のno-follow契約どおりmanaged
    // path成分のsymlinkを拒否する（root外の宣言path自体はlnakoが許容するため
    // 包含では判定しない）。sync経路は lnako の解決結果を信頼する。
    if (untrusted) assertNoSymlinkComponents(projectRoot, absolute);
    if (realPathOrNull(absolute) === null) {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `environment の package ${key} の path が存在しません: ${record.path}`);
    }
    validateImportDependencies(record.dependencies, `package ${key}`);
    validateExports(record.exports, `package ${key}`);
    packages.set(key, { ...record, absolute });
  }
  const rootDependencies = validateImportDependencies(environment.dependencies, "project root");

  // 取り込み元の所有scopeを最長一致で選ぶ。lnako 本体と同じく realpath で
  // package境界を判定し、project sourceの取り込み元はproject rootへ厳密に
  // 包含されるpackageだけにscopeを奪わせる（祖先path依存がrootのentryを
  // 自分のscopeへ引き込まないためのguard）。
  const realProjectRoot = realPathOrNull(projectRoot) ?? projectRoot;
  function scopeFor(file) {
    const realFile = realPathOrNull(file) ?? file;
    const importerIsProjectSource = isInside(realProjectRoot, realFile);
    let selected = null;
    for (const record of packages.values()) {
      const realRoot = record.real_absolute ??= realPathOrNull(record.absolute) ?? record.absolute;
      const packageIsProjectLocal = isInside(realProjectRoot, realRoot) && realRoot.length > realProjectRoot.length;
      if (importerIsProjectSource && !packageIsProjectLocal) continue;
      const inside = isInside(record.absolute, file) || isInside(realRoot, realFile);
      if (inside && (selected === null || record.absolute.length > selected.absolute.length)) selected = record;
    }
    return selected;
  }

  function dependenciesFor(file) {
    const scope = scopeFor(file);
    // package scopeは自身の依存表だけを見る（rootのaliasを継承しない）。
    // 空の `dependencies` はenvironmentで省略されるため、scope所有時は
    // 空配列へ倒す。
    if (scope !== null) return { scope, dependencies: scope.dependencies ?? [] };
    return { scope: null, dependencies: rootDependencies };
  }

  function resolve(file, specifier) {
    let reference = null;
    for (const prefix of SPECIFIER_PREFIXES) {
      if (specifier.startsWith(prefix)) {
        reference = specifier.slice(prefix.length);
        break;
      }
    }
    if (reference === null) return null;
    if (reference.length === 0 || reference.includes("\0") || reference.includes("\\")) {
      throw new PackageLoaderError("E013_MISSING_PACKAGE", `パッケージ参照が不正です: ${specifier}`);
    }
    const { scope, dependencies } = dependenciesFor(file);
    let selected = null;
    for (const dependency of dependencies) {
      const alias = dependency.alias;
      const subpath = reference === alias ? null : reference.startsWith(`${alias}/`) ? reference.slice(alias.length + 1) : undefined;
      if (subpath === undefined) continue;
      if (selected === null || alias.length > selected.alias.length) {
        selected = { alias, subpath, key: dependency.package };
        continue;
      }
      if (alias.length !== selected.alias.length) continue;
      if (alias === selected.alias) {
        if (dependency.package !== selected.key) {
          throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${specifier} のalias "${alias}" が複数packageを指しています`);
        }
        continue;
      }
      // 同じ長さの別aliasは曖昧。lnako 本体は fail closed に倒す。
      throw new PackageLoaderError("E013_MISSING_PACKAGE", `${specifier} のaliasが曖昧です: "${selected.alias}" と "${alias}"`);
    }
    if (selected === null) {
      // version指定（`alias@1.0.0`）はalias照合に必ず失敗するため、
      // 診断だけ原因が分かるように区別する。
      const versionMatch = /^([^/]+)@/.exec(reference);
      const versionAlias = versionMatch === null ? null : dependencies.find((dependency) => dependency.alias === versionMatch[1])?.alias;
      if (versionAlias !== undefined && versionAlias !== null) {
        throw new PackageLoaderError("E013_MISSING_PACKAGE", `${specifier} はversion指定を受け付けません（versionはlockで解決します）`);
      }
      const where = scope === null ? "project root" : `package "${scope.name ?? scope.id ?? "unknown"}"`;
      throw new PackageLoaderError("E013_MISSING_PACKAGE", `${specifier} のalias "${reference.split("/")[0]}" は ${where} の依存scopeにありません`);
    }
    if (selected.subpath !== null && !isCanonicalPath(selected.subpath)) {
      throw new PackageLoaderError("E013_MISSING_PACKAGE", `${specifier} のsubpathが規範pathではありません`);
    }
    const record = packages.get(selected.key);
    if (!record) {
      throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${specifier} のpackage key ${selected.key} が environment にありません`);
    }
    const exportEntry = selectExportEntry(Array.isArray(record.exports) ? record.exports : [], selected.subpath, specifier);
    const target = path.resolve(record.absolute, normalizeExportPath(exportEntry, specifier));
    if (!isInside(record.absolute, target)) {
      throw new PackageLoaderError("E029_INVALID_VALUE", `${specifier} のexportがpackage境界の外を指しています: ${target}`);
    }
    // symlink経由でpackage境界の外を読まない（no-follow契約）。dangling
    // symlinkも entry として拒否する（existsSyncはlink先を見るためlstatで見る）。
    let linkStat = null;
    try {
      linkStat = fs.lstatSync(target);
    } catch (error) {
      if (error.code !== "ENOENT") {
        throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `${specifier} のexportを検査できません: ${error.message}`);
      }
    }
    if (linkStat !== null) {
      const realTarget = realPathOrNull(target);
      const realRoot = realPathOrNull(record.absolute);
      if (realTarget === null || realRoot === null) {
        throw new PackageLoaderError("E029_INVALID_VALUE", `${specifier} のexportが解決できません（dangling symlink等）: ${target}`);
      }
      if (!isInside(realRoot, realTarget)) {
        throw new PackageLoaderError("E029_INVALID_VALUE", `${specifier} のexportがsymlinkでpackage境界の外を指しています: ${realTarget}`);
      }
    }
    return target;
  }
  // 相対importのpackage境界検査で使う。関数オブジェクトに添えることで
  // `resolve(file, specifier)` の呼出し契約を変えない。
  resolve.scopeOf = scopeFor;
  return resolve;
}

/** 公式 cnako3 の resolvePath だけを差し替えた runner。 */
async function runWithOfficialCnako(options, environment) {
  const officialModule = path.join(options.oracle, "src", "cnako3mod.mjs");
  if (!fs.existsSync(officialModule)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `公式cnako3のmoduleがありません: ${officialModule}`);
  }
  const { CNako3 } = await import(pathToFileURL(officialModule).href);
  const resolvePackage = createResolver(environment, options.root, { untrusted: !options.sync });
  const entry = path.resolve(options.root, options.entry);
  if (!fs.existsSync(entry)) {
    throw new PackageLoaderError("E034_INVALID_ENVIRONMENT_REFERENCE", `entry が見つかりません: ${entry}`);
  }
  class PackageImportCNako3 extends CNako3 {
    getLoaderTools() {
      const tools = super.getLoaderTools();
      const delegate = tools.resolvePath;
      tools.resolvePath = (name, token, fromFile) => {
        const importer = path.resolve(fromFile ?? entry);
        const target = resolvePackage(importer, name);
        const resolved = target === null ? delegate(name, token, fromFile) : { filePath: target, type: "nako3" };
        // package所有sourceからの相対・絶対取り込みはpackage境界の内側だけを
        // 許可する（lnako の module graph と同じ境界）。
        const scope = resolvePackage.scopeOf(importer);
        if (scope !== null && resolved?.type === "nako3") {
          const realRoot = scope.real_absolute ??= realPathOrNull(scope.absolute) ?? scope.absolute;
          const realTarget = realPathOrNull(resolved.filePath) ?? resolved.filePath;
          if (!isInside(realRoot, realTarget)) {
            throw new PackageLoaderError("E029_INVALID_VALUE", `${name} がpackage "${scope.name ?? scope.id ?? "unknown"}" の境界外を指しています: ${realTarget}`);
          }
        }
        return resolved;
      };
      return tools;
    }
  }
  const nako = new PackageImportCNako3();
  // 公式CLIの `checkArguments` と同じく、loggerのstdout/エラーを標準出力へ流す。
  // stdout(6) は error(5) 以上のlistenerへ届くため、公式CLIの既定と同じ
  // 'error' で登録すれば `表示` と実行時エラーの双方が同じ体裁で出る。
  nako.getLogger().addListener("error", ({ nodeConsole }) => console.log(nodeConsole));
  await nako.runAsync(fs.readFileSync(entry, "utf8"), entry);
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  options.root = path.resolve(options.root);
  options.oracle = path.resolve(options.oracle);
  if (options.v1Fixture) options.v1Fixture = path.resolve(options.v1Fixture);
  options.lnako = options.lnako ?? path.join(repositoryRoot, "zig-out", "bin", process.platform === "win32" ? "lnako.exe" : "lnako");
  const environment = options.sync ? syncEnvironment(options.root, options.lnako, options) : readEnvironmentWithoutSync(options.root);
  await runWithOfficialCnako(options, environment);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    const message = error instanceof Error ? error.message : String(error);
    if (error instanceof UsageError) {
      console.error(`cnako package loader: ${message}\n${usage()}`);
      process.exit(2);
    }
    const code = error instanceof PackageLoaderError ? error.code : "E999_UNEXPECTED";
    console.error(`パッケージ取り込み: ${code}: ${message}`);
    process.exit(1);
  });
}
