import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/semantic-diagnostic-cases.json"), "utf8"));
const { NakoCompiler } = await import(pathToFileURL(resolve(oracleRoot, "core/src/nako3.mjs")));
const probe = spawnSync("zig", ["build", "semantic-probe", "--", ...cases.map((testCase) => testCase.source)], {
  cwd: root,
  encoding: "utf8",
  env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
  maxBuffer: 16 * 1024 * 1024,
});
if (probe.status !== 0) throw new Error(`semantic-probe失敗:\n${probe.stderr}`);
const actual = probe.stdout.trimEnd().split("\n").map((line) => JSON.parse(line));

let failures = 0;
for (const [index, testCase] of cases.entries()) {
  const { id, source } = testCase;
  let officialError;
  try {
    new NakoCompiler().parse(source, "main.nako3");
  } catch (error) {
    officialError = error;
  }
  const diagnostic = actual[index].firstDiagnostic;
  if (!officialError || actual[index].diagnosticCount === 0 || !diagnostic) {
    failures += 1;
    console.error(`引数個数診断の差分 ${id}: ${JSON.stringify(source)} official=${Boolean(officialError)} lnako=${JSON.stringify(actual[index])}`);
    continue;
  }
  if (diagnostic.code !== "invalid_argument_count" || diagnostic.line !== officialError.line) {
    failures += 1;
    console.error(`引数個数診断位置の差分 ${id}: officialLine=${officialError.line} lnako=${JSON.stringify(diagnostic)}`);
  }
  if (testCase.checkMessage) {
    const officialMessage = String(officialError.message ?? "");
    const separator = officialMessage.lastIndexOf(": ");
    const expectedMessage = separator >= 0 ? officialMessage.slice(separator + 2) : officialMessage;
    if (diagnostic.message !== expectedMessage) {
      failures += 1;
      console.error(`引数個数診断文言の差分 ${id}: official=${JSON.stringify(expectedMessage)} lnako=${JSON.stringify(diagnostic.message)}`);
    }
  }
}
if (failures > 0) throw new Error(`意味診断の差分が${failures}件あります`);
console.log(`公式v3.7.24との意味診断差分テスト: ${cases.length}件成功`);
