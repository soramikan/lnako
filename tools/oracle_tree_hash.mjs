import { createHash } from "node:crypto";
import { lstat, readdir } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { join, relative, resolve, sep } from "node:path";

// This is deliberately a content-only tree hash. Only the marker is excluded
// so it can carry the resulting hash without creating a cycle. npm-generated
// metadata must be removed before hashing, not silently omitted here.
export const oracleTreeHashAlgorithm = "sha256-json-records-v3";
export const oracleMarkerName = ".lnako-oracle.json";

export async function oracleTreeHash(directory) {
  const root = resolve(directory);
  const records = [];
  await visit(root, root, records);
  records.sort((left, right) => compareStrings(left.path, right.path));
  const serialized = records.map((record) => JSON.stringify(record)).join("\n");
  return createHash("sha256").update(serialized).digest("hex");
}

async function visit(root, current, records) {
  const entries = await readdir(current, { withFileTypes: true });
  entries.sort((left, right) => compareStrings(left.name, right.name));
  for (const entry of entries) {
    const fullPath = join(current, entry.name);
    const relativePath = toPosix(relative(root, fullPath));
    if (relativePath === oracleMarkerName) continue;
    const stat = await lstat(fullPath);
    if (stat.isDirectory()) {
      records.push({ kind: "directory", path: relativePath });
      await visit(root, fullPath, records);
    } else if (stat.isSymbolicLink()) {
      throw new Error(`公式オラクルproduction treeにsymlinkが残っています: ${relativePath}`);
    } else if (stat.isFile()) {
      records.push({
        kind: "file",
        path: relativePath,
        size: String(stat.size),
        sha256: await hashFile(fullPath),
      });
    } else {
      throw new Error(`公式オラクルtree hashで未対応のentry種別です: ${relativePath}`);
    }
  }
}

async function hashFile(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

function toPosix(path) {
  return path.split(sep).join("/");
}

function compareStrings(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}
