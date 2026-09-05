import { readdir, readFile, stat } from "node:fs/promises";
import { basename, dirname, posix, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const config = JSON.parse(await readFile(resolve(root, "tools/source_structure.json"), "utf8"));

function fail(message) {
  throw new Error(`ソース構造検査: ${message}`);
}

async function* walkZigFiles(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      yield* walkZigFiles(path);
    } else if (entry.name.endsWith(".zig")) {
      yield path;
    }
  }
}

const sizeRules = config.size;
const excludeDirectories = sizeRules.excludeDirectories.map((entry) => resolve(root, entry));
const excludeBasenames = new Set(sizeRules.excludeBasenames);
const excludeSuffixes = sizeRules.excludeSuffixes;
const facadeSet = new Set(sizeRules.facades);
const exceptionEntries = Object.entries(sizeRules.exceptions ?? {});
const exceptionMap = new Map(exceptionEntries);
const layers = config.layers;

const warnings = [];
const errors = [];
const seenExceptions = new Set();

for await (const path of walkZigFiles(resolve(root, "src"))) {
  const relativePath = posix.join(...path.slice(root.length + 1).split(/[\\/]/));
  const source = await readFile(path, "utf8");
  const parts = relativePath.split("/");
  const isRootFile = parts.length === 1;

  for (const match of source.matchAll(/@import\("([^"]+)"\)/g)) {
    const target = match[1];
    if (!target.endsWith(".zig") || isRootFile) continue;
    const resolved = posix.normalize(posix.join(posix.dirname(relativePath), target));
    if (resolved.startsWith("../")) {
      errors.push(`${relativePath} がsrc外をimportしています: ${target}`);
      continue;
    }
    const sourceLayer = parts[0];
    const targetLayer = resolved.split("/")[0];
    if (targetLayer === sourceLayer) continue;
    const targetIsRootFile = !resolved.includes("/");
    if (targetIsRootFile) continue;
    if (!(layers[sourceLayer] ?? []).includes(targetLayer)) {
      errors.push(`${relativePath} から ${targetLayer}/ への新規依存は許可されていません: ${target}（tools/source_structure.json のlayersを参照）`);
    }
  }

  if (excludeDirectories.some((directory) => path.startsWith(`${directory}/`))) continue;
  if (excludeBasenames.has(basename(path)) || excludeSuffixes.some((suffix) => basename(path).endsWith(suffix))) continue;

  const sizeKb = (await stat(path)).size / 1024;
  const exception = exceptionMap.get(relativePath);
  if (exception !== undefined) {
    seenExceptions.add(relativePath);
    if (sizeKb > exception.limitKb) {
      errors.push(`${relativePath} は例外上限 ${exception.limitKb} KB を超えています: ${sizeKb.toFixed(1)} KB（理由: ${exception.reason}）`);
    } else {
      warnings.push(`${relativePath} は例外台帳の対象です: ${sizeKb.toFixed(1)} KB（理由: ${exception.reason}）`);
    }
    continue;
  }
  const className = facadeSet.has(relativePath) ? "facade" : "default";
  const rule = sizeRules.classes[className];
  if (sizeKb > rule.limitKb) {
    errors.push(`${relativePath} は ${className} 上限 ${rule.limitKb} KB を超えています: ${sizeKb.toFixed(1)} KB`);
  } else if (sizeKb > rule.warnKb) {
    warnings.push(`${relativePath} は ${className} 警告閾値 ${rule.warnKb} KB を超えています: ${sizeKb.toFixed(1)} KB`);
  }
}

for (const [path, exception] of exceptionEntries) {
  if (seenExceptions.has(path)) continue;
  try {
    const sizeKb = (await stat(resolve(root, path))).size / 1024;
    if (sizeKb <= (sizeRules.classes.default?.warnKb ?? 60)) {
      warnings.push(`${path} の例外台帳は不要になりました（${sizeKb.toFixed(1)} KB）— 削除してください`);
    }
  } catch {
    warnings.push(`${path} の例外台帳は対象ファイルが存在しないため削除してください`);
  }
}
for (const facade of facadeSet) {
  try {
    await stat(resolve(root, facade));
  } catch {
    errors.push(`ファサード台帳の対象ファイルがありません: ${facade}`);
  }
}

for (const warning of warnings) console.warn(`警告: ${warning}`);
if (errors.length > 0) fail(errors.join("\n"));
console.log(`ソース構造検査: サイズ・import層・例外台帳を検証しました（警告${warnings.length}件）`);
