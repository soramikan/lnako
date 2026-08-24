import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const cases = JSON.parse(await readFile(resolve(root, "tests/oracle/supplemental-plugin-cases.json"), "utf8"));
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const temporary = await mkdtemp(join(tmpdir(), "lnako-supplemental-"));
const replacements = {
  "${PLUGIN_MARKUP}": resolve(oracleRoot, "src/plugin_markup.mjs").replaceAll("\\", "/"),
  "${PLUGIN_KANSUJI}": resolve(oracleRoot, "src/plugin_kansuji.mjs").replaceAll("\\", "/"),
  "${PLUGIN_CANIUSE}": resolve(oracleRoot, "src/plugin_caniuse.mjs").replaceAll("\\", "/"),
};
const suites = [...cases, kansujiCorpus()];

try {
  buildLnako();
  let failures = 0;
  for (const testCase of suites) {
    let source = testCase.source;
    for (const [placeholder, path] of Object.entries(replacements)) source = source.replaceAll(placeholder, path);
    const path = resolve(temporary, `${testCase.id}.nako3`);
    await writeFile(path, source, "utf8");
    const options = { cwd: temporary, encoding: "utf8", env: { ...process.env, TZ: "Asia/Tokyo" }, maxBuffer: 32 * 1024 * 1024 };
    const official = spawnSync(process.execPath, [officialCli, path], options);
    const actual = spawnSync(executable, ["run", path], options);
    const expected = normalize(official);
    const received = normalize(actual);
    if (JSON.stringify(expected) !== JSON.stringify(received)) {
      failures += 1;
      console.error(`追加標準プラグイン差分 ${testCase.id}:\nofficial=${JSON.stringify(expected, null, 2)}\nlnako=${JSON.stringify(received, null, 2)}`);
    }
  }
  if (failures > 0) throw new Error(`追加標準プラグインの公式差分が${failures}件あります`);
  const count = new Set(suites.flatMap((testCase) => testCase.commands)).size;
  console.log(`markup・caniuse・kansuji公式差分テスト: ${suites.length}ケース・${count}命令成功`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}

function normalize(result) {
  return {
    stdout: result.stdout.replaceAll("\r\n", "\n"),
    stderrClass: result.status === 0 ? "success" : "runtime-error",
    exitCode: result.status,
    signal: result.signal,
  };
}

function buildLnako() {
  const result = spawnSync("zig", ["build"], {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, ZIG_GLOBAL_CACHE_DIR: process.env.ZIG_GLOBAL_CACHE_DIR ?? resolve(root, ".zig-global-cache") },
    maxBuffer: 16 * 1024 * 1024,
  });
  if (result.status !== 0) throw new Error(`lnakoのビルドに失敗しました:\n${result.stderr}`);
}

function kansujiCorpus() {
  const values = [
    ...Array.from({ length: 513 }, (_, index) => String(index)),
    "9999", "10000", "10001", "99999999", "100000000", "9007199254740991", "9007199254740992",
    "1e3", "1e-3", "1e+3", "10e1", "01e2", ".5e1", "1.2e-3", "-1e3", "+1e3",
    "１２３", ".5", "-.5", "1.", "+0.", "000.50", " 1 ", "　1　", " 1 ", "",
    "Infinity", "-Infinity", "0x10", "0b10", "0o10",
  ];
  const lines = [`!"${replacements["${PLUGIN_KANSUJI}"]}"を取り込む`];
  for (const value of values) {
    lines.push(`漢数字(${JSON.stringify(value)})を表示`);
    if (/^[0-9]+$/.test(value)) lines.push(`算用数字(漢数字(${JSON.stringify(value)}))を表示`);
  }
  for (const value of ["一二", "一二万", "二三四万", "一二十", "十百", "万", "𥝱", "一𥝱", "無量大数", "一無量大数"]) lines.push(`算用数字(${JSON.stringify(value)})を表示`);
  return { id: "plugin-kansuji-generated", commands: [], source: `${lines.join("\n")}\n` };
}
