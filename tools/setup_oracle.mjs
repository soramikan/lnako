import { createHash } from "node:crypto";
import { access, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { oracleTreeHash, oracleTreeHashAlgorithm } from "./oracle_tree_hash.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const cacheRoot = resolve(root, ".cache/oracle");
const target = resolve(cacheRoot, "nadesiko3-3.7.24");
const marker = resolve(target, ".lnako-oracle.json");
const lock = JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8")).nadesiko3;
const oracleBuild = 4;
const oracleIdentity = lock.oracleIdentity;
const oraclePlatform = `${process.platform}-${process.arch}`;
const expectedTreeSha256 = oracleIdentity?.treeSha256ByPlatform?.[oraclePlatform];
if (oracleIdentity?.build !== oracleBuild || oracleIdentity.treeHashAlgorithm !== oracleTreeHashAlgorithm ||
    !/^[0-9a-f]{64}$/.test(oracleIdentity?.cliSha256 ?? "") || !/^[0-9a-f]{64}$/.test(oracleIdentity?.markerSha256 ?? "") ||
    !/^[0-9a-f]{64}$/.test(expectedTreeSha256 ?? "")) {
  throw new Error("upstream.lock.jsonの公式オラクル固定hashが不正です");
}

try {
  if (await oracleDirectoryMatches(target)) {
    console.log(`公式オラクルを確認しました: ${lock.tag} (${lock.commit.slice(0, 7)})`);
    process.exit(0);
  }
} catch {
  // 未取得または不完全なキャッシュは、固定アーカイブから作り直す。
}

await mkdir(cacheRoot, { recursive: true });
const stagingRoot = resolve(cacheRoot, `.staging-${process.pid}`);
const archivePath = resolve(stagingRoot, "nadesiko3.tar.gz");
await rm(stagingRoot, { recursive: true, force: true });
await mkdir(stagingRoot, { recursive: true });

try {
  const response = await fetch(lock.archive.url);
  if (!response.ok) throw new Error(`公式アーカイブ取得失敗: ${response.status}`);
  const archive = Buffer.from(await response.arrayBuffer());
  const actualHash = createHash("sha256").update(archive).digest("hex");
  if (actualHash !== lock.archive.sha256) {
    throw new Error(`公式アーカイブのSHA-256不一致: expected=${lock.archive.sha256} actual=${actualHash}`);
  }
  await writeFile(archivePath, archive);

  run("tar", ["-xzf", archivePath, "-C", stagingRoot]);
  const extracted = resolve(stagingRoot, `nadesiko3-${lock.tag}`);
  run("npm", ["ci", "--ignore-scripts", "--no-audit", "--no-fund"], extracted);
  run(
    process.execPath,
    [
      "node_modules/typescript/bin/tsc",
      "-p",
      "core/tsconfig.json",
      "--typeRoots",
      "core/src/@types,node_modules/@types",
      "--newLine",
      "lf",
      "--pretty",
      "false",
    ],
    extracted,
  );
  run(
    process.execPath,
    ["node_modules/typescript/bin/tsc", "-p", "tsconfig.json", "--newLine", "lf", "--pretty", "false"],
    extracted,
  );
  await assertNoProductionOptionalDependencies(extracted);
  run("npm", ["prune", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"], extracted);
  await removeNpmGeneratedMetadata(extracted);
  await writeFile(resolve(extracted, ".lnako-oracle.json"), "{}\n");
  const treeSha256 = await oracleTreeHash(extracted);
  await writeFile(
    resolve(extracted, ".lnako-oracle.json"),
    `${JSON.stringify({ tag: lock.tag, commit: lock.commit, archiveSha256: lock.archive.sha256, oracleBuild, treeSha256 }, null, 2)}\n`,
  );
  if (!(await oracleDirectoryMatches(extracted))) throw new Error("構築した公式オラクルの固定hashが一致しません");
  await replaceDirectory(extracted, target);
} finally {
  await rm(stagingRoot, { recursive: true, force: true });
}

console.log(`公式オラクルを構築しました: ${lock.tag} (${lock.commit.slice(0, 7)})`);

async function assertNoProductionOptionalDependencies(directory) {
  const packageLock = JSON.parse(await readFile(resolve(directory, "package-lock.json"), "utf8"));
  const rootOptional = Object.keys(packageLock.packages?.[""]?.optionalDependencies ?? {});
  const productionOptional = Object.entries(packageLock.packages ?? {}).filter(([, packageInfo]) => packageInfo?.dev !== true && packageInfo?.optional === true);
  if (rootOptional.length > 0 || productionOptional.length > 0) {
    const names = [...rootOptional, ...productionOptional.map(([name]) => name)];
    throw new Error(`公式オラクルにOS依存のproduction optional dependencyがあります: ${names.join(", ")}`);
  }
}

async function removeNpmGeneratedMetadata(directory) {
  const rootNodeModules = resolve(directory, "node_modules");
  const pending = [rootNodeModules];
  while (pending.length > 0) {
    const current = pending.pop();
    let entries;
    try {
      entries = await readdir(current, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      throw error;
    }
    for (const entry of entries) {
      const fullPath = join(current, entry.name);
      if (basename(current) === "node_modules" && (entry.name === ".bin" || entry.name === ".package-lock.json")) {
        await rm(fullPath, { recursive: true, force: true });
      } else if (entry.isDirectory()) {
        pending.push(fullPath);
      }
    }
  }
}

async function oracleDirectoryMatches(directory) {
  try {
    const markerBytes = await readFile(resolve(directory, ".lnako-oracle.json"));
    const current = JSON.parse(markerBytes.toString("utf8"));
    await access(resolve(directory, "core/src/nako_lexer.mjs"));
    const cliPath = resolve(directory, "src/cnako3.mjs");
    await access(cliPath);
    const actualTreeSha256 = await oracleTreeHash(directory);
    return current.tag === lock.tag && current.commit === lock.commit && current.archiveSha256 === lock.archive.sha256 && current.oracleBuild === oracleBuild &&
      current.treeSha256 === actualTreeSha256 && current.treeSha256 === expectedTreeSha256 &&
      sha256(markerBytes) === oracleIdentity.markerSha256 && sha256(await readFile(cliPath)) === oracleIdentity.cliSha256;
  } catch {
    return false;
  }
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function run(command, args, cwd = root) {
  const result = spawnSync(command, args, { cwd, stdio: "inherit", shell: process.platform === "win32" });
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} が失敗しました`);
}

async function replaceDirectory(source, destination) {
  const retryable = new Set(["EACCES", "EBUSY", "EPERM"]);
  const delaysMs = process.platform === "win32" ? [0, 100, 250, 500, 1000, 2000, 4000] : [0];
  let lastFailure;
  for (const delayMs of delaysMs) {
    if (delayMs > 0) await new Promise((resolveDelay) => setTimeout(resolveDelay, delayMs));
    try {
      await rm(destination, { recursive: true, force: true });
      await rename(source, destination);
      return;
    } catch (failure) {
      lastFailure = failure;
      if (!retryable.has(failure?.code)) throw failure;
    }
  }
  throw lastFailure;
}
