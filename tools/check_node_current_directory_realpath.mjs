import { mkdir, mkdtemp, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const root = resolve(import.meta.dirname, "..");
const oracleRoot = resolve(process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const fixedHost = resolve(root, "tools/oracle/fixed_host.mjs");
const temporary = await mkdtemp(join(tmpdir(), "lnako-node-cwd-"));
const target = resolve(temporary, "target");
const alias = resolve(temporary, "alias");

try {
  await mkdir(target);
  await symlink(target, alias, process.platform === "win32" ? "junction" : "dir");
  const source = resolve(temporary, "case.nako3");
  await writeFile(source, [
    'カレントディレクトリ変更("alias")',
    "ファイル名抽出(カレントディレクトリ取得())を表示",
    "ファイル名抽出(作業フォルダ取得())を表示",
    "",
  ].join("\n"), "utf8");

  buildLnako();
  const environment = {
    ...process.env,
    TZ: "Asia/Tokyo",
    NAKO3_DISABLE_NEW_CONSOLE: "1",
    ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache"),
  };
  const options = { cwd: temporary, env: environment, encoding: "utf8", maxBuffer: 16 * 1024 * 1024 };
  const official = spawnSync(process.execPath, ["--import", pathToFileURL(fixedHost).href, officialCli, source], options);
  const interpreted = spawnSync(executable, ["run", source], options);
  const results = { official: normalize(official), interpreter: normalize(interpreted) };

  for (const optimization of ["O0", "O1", "O2", "O3"]) {
    const nativePath = resolve(temporary, `case-${optimization}${process.platform === "win32" ? ".exe" : ""}`);
    const compile = spawnSync(executable, ["build", source, "-o", nativePath, `-${optimization}`], options);
    const native = compile.status === 0 ? spawnSync(nativePath, [], options) : compile;
    results[`aot-${optimization}`] = normalize(native);
  }

  const expectedRealpath = await realpath(alias);
  const expected = `${basename(expectedRealpath)}\n${basename(expectedRealpath)}\n`;
  // Windowsのcnako3(process.cwd())はjunctionを解決しないため、公式CLIの期待値を別にする
  const expectedOfficial = process.platform === "win32"
    ? `${basename(alias)}\n${basename(alias)}\n`
    : expected;
  const expectedByResult = {
    official: expectedOfficial,
    interpreter: expected,
    "aot-O0": expected,
    "aot-O1": expected,
    "aot-O2": expected,
    "aot-O3": expected,
  };
  const failures = Object.entries(results).filter(([name, result]) => {
    const want = expectedByResult[name];
    return result.status !== 0 || result.stdout !== want;
  });
  if (failures.length > 0) {
    throw new Error(`Node cwd realpath差分: expected=${JSON.stringify({ expected, expectedRealpath, expectedOfficial })} actual=${JSON.stringify(results)}`);
  }
  console.log(`Nodeカレントディレクトリ実パス差分テスト: 公式CLI・Interpreter・AOT O0〜O3成功 (${expectedRealpath})`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], {
    cwd: root,
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}

function normalize(result) {
  return {
    status: result.status,
    stdout: result.stdout.replaceAll("\r\n", "\n"),
    stderr: result.stderr,
  };
}
