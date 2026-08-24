import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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
    const sourcePath = resolve(temporary, `${testCase.id}.nako3`);
    await writeFile(sourcePath, testCase.source.replaceAll("${BASE}", base).replaceAll("${FILE}", discordFile.replaceAll("\\", "/")), "utf8");
    const options = { cwd: temporary, encoding: "utf8", maxBuffer: 16 * 1024 * 1024, env: { ...process.env, TZ: "Asia/Tokyo", NAKO3_DISABLE_NEW_CONSOLE: "1" } };
    const official = spawnSync(process.execPath, [officialCli, sourcePath], options);
    const actual = spawnSync(executable, ["run", sourcePath], options);
    const expected = normalize(official);
    const received = normalize(actual);
    const expectedError = classifyError(official);
    const receivedError = classifyError(actual);
    const mismatch = testCase.expectError ? !expectedError || !receivedError : official.status !== 0 || actual.status !== 0 || JSON.stringify(expected) !== JSON.stringify(received);
    if (mismatch) {
      failures += 1;
      console.error(`Node HTTP差分 ${testCase.id}:\nofficial=${JSON.stringify(expected)}\nlnako  =${JSON.stringify(received)}\nofficial stderr=${official.stderr}\nlnako stderr=${actual.stderr}`);
    }
  }
  if (failures > 0) throw new Error(`Node HTTP公式差分が${failures}件あります`);
  console.log(`Node HTTP公式差分テスト: ${cases.length}ケース・${new Set(cases.flatMap((item) => item.commands)).size}命令成功`);
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
