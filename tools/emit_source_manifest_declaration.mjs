import { access, writeFile } from "node:fs/promises";
import { isAbsolute, resolve } from "node:path";
import { computeSourceManifestSha256Sync } from "./lib/evidence/manifest.mjs";
import { sourceManifestDeclarationBytes } from "./lib/evidence/source_manifest.mjs";

// lnako.source-manifest.v1 宣言をcanonical byte列で書き出す。
// CI attestation jobが actions/attest のsubjectとして署名する対象で、
// snapshotへはそのまま保存される。commitは checkout 対象commit、
// sourceManifestSha256は現行ソースから計算した値。
const root = resolve(import.meta.dirname, "..");
const args = process.argv.slice(2);
const commitIndex = args.indexOf("--commit");
const outputIndex = args.indexOf("--output");
if (args.length !== 4 || commitIndex < 0 || outputIndex < 0 || args[commitIndex + 1] === undefined || args[outputIndex + 1] === undefined ||
    args[commitIndex + 1].startsWith("--") || args[outputIndex + 1].startsWith("--")) {
  throw new Error("usage: node tools/emit_source_manifest_declaration.mjs --commit 40-hex-commit --output /absolute/path");
}
const commit = args[commitIndex + 1];
const output = args[outputIndex + 1];
if (!isAbsolute(output)) throw new Error("--outputには絶対パスを指定してください");
const { sha256 } = computeSourceManifestSha256Sync(root);
const bytes = sourceManifestDeclarationBytes(commit, sha256);
try {
  await access(output);
  throw new Error(`出力先は既に存在します: ${output}`);
} catch (error) {
  if (error?.message?.startsWith("出力先は既に存在します")) throw error;
  if (error?.code !== "ENOENT") throw error;
}
await writeFile(output, bytes, { encoding: "utf8", flag: "wx" });
console.log(`source manifest宣言を出力しました: ${output} (commit ${commit} / manifest ${sha256})`);
