import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawn, spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/node-http-cases.json"), "utf8"));
const temporary = await mkdtemp(join(tmpdir(), "lnako-http-"));
const server = spawn(process.execPath, [resolve(root, "tools/oracle/http_loopback_server.mjs")], { stdio: ["ignore", "pipe", "inherit"] });

try {
  const port = await firstLine(server.stdout);
  const base = `http://127.0.0.1:${port}`;
  const discordFile = resolve(temporary, "discord.txt");
  await writeFile(discordFile, "hello-file", "utf8");
  buildLnako();
  let failures = 0;
  for (const testCase of cases) {
    const officialDirectory = resolve(temporary, testCase.id, "official");
    const lnakoDirectory = resolve(temporary, testCase.id, "lnako");
    await mkdir(officialDirectory, { recursive: true });
    await mkdir(lnakoDirectory, { recursive: true });
    const aotDirectories = {};
    if (testCase.aot === true) {
      for (const optimization of ["O0", "O1", "O2", "O3"]) {
        const directory = resolve(temporary, testCase.id, `aot-${optimization}`);
        aotDirectories[optimization] = directory;
        await mkdir(directory, { recursive: true });
      }
    }
    const source = testCase.source.replaceAll("${BASE}", base).replaceAll("${FILE}", discordFile.replaceAll("\\", "/"));
    const officialSource = resolve(officialDirectory, "case.nako3");
    const lnakoSource = resolve(lnakoDirectory, "case.nako3");
    await writeFile(officialSource, source, "utf8");
    await writeFile(lnakoSource, source, "utf8");
    for (const directory of Object.values(aotDirectories)) await writeFile(resolve(directory, "case.nako3"), source, "utf8");
    const environment = { ...process.env, TZ: "Asia/Tokyo", NAKO3_DISABLE_NEW_CONSOLE: "1" };
    const options = { encoding: "utf8", maxBuffer: 16 * 1024 * 1024, env: environment };
    const official = spawnSync(process.execPath, [officialCli, officialSource], { ...options, cwd: officialDirectory });
    const actual = spawnSync(executable, ["run", lnakoSource], { ...options, cwd: lnakoDirectory });
    const expected = normalize(official);
    const received = normalize(actual);
    const expectedError = classifyError(official);
    const receivedError = classifyError(actual);
    const aotResults = {};
    const aotStderr = {};
    let aotCompileFailure = false;
    if (testCase.aot === true) {
      for (const optimization of ["O0", "O1", "O2", "O3"]) {
        const aotDirectory = aotDirectories[optimization];
        const aotSource = resolve(aotDirectory, "case.nako3");
        const nativeExecutable = resolve(temporary, `${testCase.id}-${optimization}${process.platform === "win32" ? ".exe" : ""}`);
        const nativeCompile = spawnSync(executable, ["build", aotSource, "-o", nativeExecutable, `-${optimization}`], {
          ...options,
          cwd: aotDirectory,
        });
        const nativeResult = nativeCompile.status === 0
          ? spawnSync(nativeExecutable, [], { ...options, cwd: aotDirectory })
          : nativeCompile;
        aotResults[optimization] = normalize(nativeResult);
        aotStderr[optimization] = nativeResult.stderr;
        if (nativeCompile.status !== 0) aotCompileFailure = true;
      }
    }
    const aotError = Object.values(aotResults).every((result) => result.exitCode !== 0);
    const aotSuccess = Object.values(aotResults).every((result) => result.exitCode === 0);
    const aotOutputMatches = Object.values(aotResults).every((result) => JSON.stringify(result) === JSON.stringify(expected));
    const mismatch = testCase.expectError
      ? !expectedError || !receivedError || (testCase.aot === true && (!aotError || aotCompileFailure))
      : official.status !== 0 || actual.status !== 0 || JSON.stringify(expected) !== JSON.stringify(received) ||
        (testCase.aot === true && (!aotSuccess || aotCompileFailure || !aotOutputMatches));
    if (mismatch) {
      failures += 1;
      console.error(`Node HTTP差分 ${testCase.id}:\nofficial=${JSON.stringify(expected)}\nlnako  =${JSON.stringify(received)}\nofficial stderr=${official.stderr}\nlnako stderr=${actual.stderr}${testCase.aot === true ? `\naot=${JSON.stringify(aotResults)}\naotStderr=${JSON.stringify(aotStderr)}` : ""}`);
    }
  }
  if (failures > 0) throw new Error(`Node HTTP公式差分が${failures}件あります`);
  console.log(`Node HTTP公式差分テスト: ${cases.length}ケース・${new Set(cases.flatMap((item) => item.commands)).size}命令成功（AOT O0〜O3: ${cases.filter((item) => item.aot === true).length}ケース）`);
} finally {
  server.kill("SIGTERM");
  await rm(temporary, { recursive: true, force: true });
}

function normalize(result) {
  return { stdout: result.stdout.replaceAll("\r\n", "\n"), stderrClass: result.status === 0 ? "success" : "runtime-error", exitCode: result.status };
}

function classifyError(result) {
  return result.status !== 0 || `${result.stdout}${result.stderr}`.includes("エラー") || `${result.stdout}${result.stderr}`.includes("使えなくなりました");
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], { cwd: root, encoding: "utf8", env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") }, maxBuffer: 16 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}

async function firstLine(stream) {
  let buffered = "";
  for await (const chunk of stream) {
    buffered += chunk.toString("utf8");
    const newline = buffered.indexOf("\n");
    if (newline >= 0) return buffered.slice(0, newline).trim();
  }
  throw new Error("loopback HTTPサーバがポートを通知せず終了しました");
}
