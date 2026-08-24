import { createHash } from "node:crypto";
import { access, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const cacheRoot = resolve(root, ".cache/oracle");
const target = resolve(cacheRoot, "nadesiko3-3.7.24");
const marker = resolve(target, ".lnako-oracle.json");
const lock = JSON.parse(await readFile(resolve(root, "compat/upstream.lock.json"), "utf8")).nadesiko3;

try {
  const current = JSON.parse(await readFile(marker, "utf8"));
  await access(resolve(target, "core/src/nako_lexer.mjs"));
  if (current.commit === lock.commit && current.archiveSha256 === lock.archive.sha256) {
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
      "--pretty",
      "false",
    ],
    extracted,
  );
  await writeFile(
    resolve(extracted, ".lnako-oracle.json"),
    `${JSON.stringify({ tag: lock.tag, commit: lock.commit, archiveSha256: lock.archive.sha256 }, null, 2)}\n`,
  );
  await rm(target, { recursive: true, force: true });
  await rename(extracted, target);
} finally {
  await rm(stagingRoot, { recursive: true, force: true });
}

console.log(`公式オラクルを構築しました: ${lock.tag} (${lock.commit.slice(0, 7)})`);

function run(command, args, cwd = root) {
  const result = spawnSync(command, args, { cwd, stdio: "inherit", shell: process.platform === "win32" });
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} が失敗しました`);
}
