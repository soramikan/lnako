import { readFileSync } from "node:fs";
import { access, link, readFile, rm, writeFile } from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { oracleTreeHash, oracleTreeHashAlgorithm } from "../oracle_tree_hash.mjs";
import { coverageEnv as env } from "./coverage_env.mjs";

export const throwStatementOpcode = 0xffff;

export function gitState() {
  const commit = spawnSync("git", ["rev-parse", "HEAD"], { cwd: env.root, encoding: "utf8" });
  if (commit.status !== 0) throw new Error("lnakoのcommitを取得できません");
  const hash = commit.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(hash)) throw new Error("lnakoのcommit形式が不正です");
  const status = spawnSync("git", ["status", "--porcelain"], { cwd: env.root, encoding: "utf8" });
  if (status.status !== 0) throw new Error("lnakoのdirty状態を取得できません");
  return { commit: hash, dirty: status.stdout.length > 0 };
}


export function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}


export function sha256FileSync(path) {
  return sha256(readFileSync(path));
}


export function normalizeLineEndings(value) {
  return value.replaceAll("\r\n", "\n").replaceAll("\r", "\n");
}


export async function readOracleIdentity(directory, expectedBaseline) {
  const markerPath = resolve(directory, ".lnako-oracle.json");
  const cliPath = resolve(directory, "src/cnako3.mjs");
  const markerBytes = await readFile(markerPath);
  const marker = JSON.parse(markerBytes.toString("utf8"));
  const expected = expectedBaseline.oracleIdentity;
  const treeSha256 = await oracleTreeHash(directory);
  const cliSha256 = sha256(await readFile(cliPath));
  const markerSha256 = sha256(markerBytes);
  const platform = `${process.platform}-${process.arch}`;
  if (marker.tag !== expectedBaseline.tag || marker.commit !== expectedBaseline.commit || marker.archiveSha256 !== expectedBaseline.archive.sha256 ||
      marker.treeSha256 !== treeSha256 || marker.treeSha256 !== expected?.treeSha256ByPlatform?.[platform] ||
      marker.oracleBuild !== expected?.build || cliSha256 !== expected?.cliSha256 || markerSha256 !== expected?.markerSha256 ||
      expected?.treeHashAlgorithm !== oracleTreeHashAlgorithm) {
    throw new Error("公式オラクルの固定情報がlockと一致しません");
  }
  return {
    build: marker.oracleBuild,
    archiveSha256: marker.archiveSha256,
    cliSha256,
    markerSha256,
    treeHashAlgorithm: oracleTreeHashAlgorithm,
    treeSha256,
  };
}


export async function assertOutputDoesNotExist(path) {
  try {
    await access(path);
  } catch (error) {
    if (error?.code === "ENOENT") return;
    throw error;
  }
  throw new Error(`dispatch coverage auditの出力先は既に存在します: ${path}`);
}


export async function writeExclusive(path, content) {
  const temporaryPath = resolve(dirname(path), `.lnako-dispatch-coverage-${process.pid}-${randomUUID()}.tmp`);
  try {
    await writeFile(temporaryPath, content, { encoding: "utf8", flag: "wx" });
    try {
      await link(temporaryPath, path);
    } catch (error) {
      if (error?.code === "EEXIST") throw new Error(`dispatch coverage auditの出力先は既に存在します: ${path}`);
      throw new Error(`dispatch coverage auditを出力できません: ${path}`, { cause: error });
    }
  } finally {
    await rm(temporaryPath, { force: true });
  }
}

export function validDispatchExpectationPlatforms(platforms) {
  return platforms === undefined ||
    (Array.isArray(platforms) && platforms.length > 0 && new Set(platforms).size === platforms.length &&
      platforms.every((platform) => ["darwin", "linux", "win32"].includes(platform)));
}

