import { mkdtemp, mkdir, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { basename, join, relative, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/node-file-cases.json"), "utf8"));
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const fixedHost = resolve(root, "tools/oracle/fixed_host.mjs");
const temporary = await mkdtemp(join(tmpdir(), "lnako-node-file-"));

try {
  buildLnako();
  let failures = 0;
  for (const testCase of cases) {
    const officialDirectory = resolve(temporary, testCase.id, "official");
    const lnakoDirectory = resolve(temporary, testCase.id, "lnako");
    await mkdir(officialDirectory, { recursive: true });
    await mkdir(lnakoDirectory, { recursive: true });
    for (const [name, contents] of Object.entries(testCase.files ?? {})) {
      await writeFile(resolve(officialDirectory, name), contents, "utf8");
      await writeFile(resolve(lnakoDirectory, name), contents, "utf8");
    }
    const officialSource = resolve(officialDirectory, "case.nako3");
    const lnakoSource = resolve(lnakoDirectory, "case.nako3");
    await writeFile(officialSource, testCase.source, "utf8");
    await writeFile(lnakoSource, testCase.source, "utf8");
    const environment = {
      ...process.env,
      TZ: "Asia/Tokyo",
      LNAKO_NODE_TEST: "fixed-value",
      LNAKO_TEST_NOW_MS: "1735689845678",
      LNAKO_TEST_RANDOM_SEED: "5573589319906701683",
      NAKO3_DISABLE_NEW_CONSOLE: "1",
    };
    const spawnOptions = { input: testCase.stdin ?? undefined, env: environment, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 };
    const official = spawnSync(process.execPath, ["--import", pathToFileURL(fixedHost).href, officialCli, officialSource], { ...spawnOptions, cwd: officialDirectory });
    const actual = spawnSync(executable, ["run", lnakoSource], { ...spawnOptions, cwd: lnakoDirectory });
    const expectedResult = normalize(official);
    const actualResult = normalize(actual);
    const expectedFiles = await snapshot(officialDirectory, basename(officialSource));
    const actualFiles = await snapshot(lnakoDirectory, basename(lnakoSource));
    if (official.status !== 0 || actual.status !== 0 || JSON.stringify(expectedResult) !== JSON.stringify(actualResult) || JSON.stringify(expectedFiles) !== JSON.stringify(actualFiles)) {
      failures += 1;
      console.error(`Nodeファイル差分 ${testCase.id}:\nofficial=${JSON.stringify(expectedResult)}\nlnako  =${JSON.stringify(actualResult)}\nofficialFiles=${JSON.stringify(expectedFiles)}\nlnakoFiles  =${JSON.stringify(actualFiles)}`);
      if (official.stderr) console.error(`公式stderr:\n${official.stderr}`);
      if (actual.stderr) console.error(`lnako stderr:\n${actual.stderr}`);
    }
  }
  if (failures > 0) throw new Error(`Nodeファイル実行結果の差分が${failures}件あります`);
  console.log(`Nodeパス・ホスト・ファイル公式差分テスト: ${cases.length}ケース・${new Set(cases.flatMap((testCase) => testCase.commands)).size}命令成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], { cwd: root, encoding: "utf8", env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") }, maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}

function normalize(result) {
  return { stdout: result.stdout.replaceAll("\r\n", "\n"), stderrClass: result.status === 0 ? "success" : "runtime-error", exitCode: result.status, signal: result.signal };
}

async function snapshot(directory, excludedName) {
  const result = [];
  await visit(directory);
  return result.sort((left, right) => left.path.localeCompare(right.path));

  async function visit(current) {
    for (const entry of await readdir(current, { withFileTypes: true })) {
      const path = resolve(current, entry.name);
      const rel = relative(directory, path).replaceAll("\\", "/");
      if (rel === excludedName) continue;
      if (entry.isDirectory()) {
        result.push({ path: `${rel}/`, kind: "directory" });
        await visit(path);
      } else {
        const info = await stat(path);
        const bytes = await readFile(path);
        result.push({ path: rel, kind: "file", size: info.size, sha256: createHash("sha256").update(bytes).digest("hex") });
      }
    }
  }
}
