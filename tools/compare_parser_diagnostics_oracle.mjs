import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(
  oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"),
);
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/parser-diagnostic-cases.json"), "utf8"));
const { NakoCompiler } = await import(pathToFileURL(resolve(oracleRoot, "core/src/nako3.mjs")));
const probe = spawnSync("zig", ["build", "parser-probe", "--", ...cases], {
  cwd: root,
  encoding: "utf8",
  env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
  maxBuffer: 16 * 1024 * 1024,
});
if (probe.status !== 0) throw new Error(`parser-probe失敗:\n${probe.stderr}`);
const actual = probe.stdout.trimEnd().split("\n").map((line) => JSON.parse(line));

let failures = 0;
for (const [index, source] of cases.entries()) {
  let officialError;
  try {
    new NakoCompiler().parse(source, "main.nako3");
  } catch (error) {
    officialError = error;
  }
  const diagnostic = actual[index].diagnostics?.[0];
  if (!officialError || !diagnostic) {
    failures += 1;
    console.error(`拒否結果の差分: ${JSON.stringify(source)} official=${Boolean(officialError)} lnako=${Boolean(diagnostic)}`);
    continue;
  }
  if (diagnostic.file !== "main.nako3" || diagnostic.span.line !== officialError.line ||
      diagnostic.span.source_start > Buffer.byteLength(source)) {
    failures += 1;
    console.error(`診断位置の差分: ${JSON.stringify(source)} officialLine=${officialError.line} lnako=${JSON.stringify(diagnostic)}`);
  }
}
if (failures > 0) throw new Error(`構文診断の差分が${failures}件あります`);
console.log(`公式v3.7.24との構文診断差分テスト: ${cases.length}件成功`);
