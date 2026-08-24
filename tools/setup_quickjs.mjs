import { createHash } from "node:crypto";
import { createWriteStream } from "node:fs";
import { access, appendFile, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const lock = JSON.parse(await readFile(resolve(root, "toolchain.lock.json"), "utf8")).quickjs;
const cacheRoot = resolve(root, ".cache/toolchains");
const target = resolve(cacheRoot, `quickjs-${lock.version}`);
const marker = resolve(target, ".lnako-toolchain.json");

if (!(await isCurrent())) await install();
await verifySource();
if (process.env.GITHUB_ENV) await appendFile(process.env.GITHUB_ENV, `LNAKO_QUICKJS_DIR=${target}\n`);
console.log(`QuickJS ${lock.version}を確認しました: ${target}`);

async function isCurrent() {
  try {
    const current = JSON.parse(await readFile(marker, "utf8"));
    await access(resolve(target, "quickjs.c"));
    await access(resolve(target, "quickjs.h"));
    return current.version === lock.version && current.sha256 === lock.sha256;
  } catch {
    return false;
  }
}

async function install() {
  await mkdir(cacheRoot, { recursive: true });
  const staging = resolve(cacheRoot, `.quickjs-staging-${process.pid}`);
  const archive = resolve(staging, `quickjs-${lock.version}.tar.xz`);
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  try {
    const response = await fetch(lock.source);
    if (!response.ok || !response.body) throw new Error(`QuickJS配布物の取得に失敗しました: HTTP ${response.status}`);
    const hash = createHash("sha256");
    const hashingStream = new Transform({
      transform(chunk, _encoding, callback) {
        hash.update(chunk);
        callback(null, chunk);
      },
    });
    await pipeline(Readable.fromWeb(response.body), hashingStream, createWriteStream(archive));
    const actualHash = hash.digest("hex");
    if (actualHash !== lock.sha256) throw new Error(`QuickJS配布物のSHA-256不一致: expected=${lock.sha256} actual=${actualHash}`);
    run("tar", ["-xJf", archive, "-C", staging]);
    const directories = (await readdir(staging, { withFileTypes: true })).filter((entry) => entry.isDirectory());
    if (directories.length !== 1) throw new Error(`QuickJS配布物の展開ルートが一意ではありません: ${directories.map((entry) => entry.name).join(", ")}`);
    await rm(target, { recursive: true, force: true });
    await rename(resolve(staging, directories[0].name), target);
    await writeFile(marker, `${JSON.stringify({ version: lock.version, sha256: lock.sha256 }, null, 2)}\n`);
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

async function verifySource() {
  const version = (await readFile(resolve(target, "VERSION"), "utf8")).trim();
  if (version !== lock.version) throw new Error(`QuickJS VERSIONが不一致です: expected=${lock.version} actual=${version}`);
  for (const file of ["quickjs.c", "quickjs.h", "cutils.c", "libregexp.c", "libunicode.c", "dtoa.c", "LICENSE"]) await access(resolve(target, file));
}

function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: "inherit" });
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} が失敗しました`);
}
