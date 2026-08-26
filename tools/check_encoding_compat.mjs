import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import iconv from "../.cache/oracle/nadesiko3-3.7.24/node_modules/iconv-lite/lib/index.js";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const temporary = await mkdtemp(join(tmpdir(), "lnako-encoding-"));

try {
  iconv.encodingExists("utf8");
  const names = Object.keys(iconv.encodings).filter((name) => !name.startsWith("_")).toSorted();
  // iconv-liteの名前正規化でだけ現れる代表的な表記も固定して確認する。
  names.push("Shift_JIS", "big5-hkscs", "euc-jp", "euc-kr", "unicode-1-1-utf-7", "utf7-imap", "windows-1252:2000");
  const uniqueNames = [...new Set(names)];
  // The official parser has non-linear cost for one very large generated
  // source. Keep every encoding case, but bound each oracle input to the same
  // 96-statement size used by the other generated compatibility corpora.
  const batchSize = 32;
  buildLnako();
  const options = { cwd: temporary, encoding: "utf8", maxBuffer: 32 * 1024 * 1024, env: { ...process.env, TZ: "Asia/Tokyo", NAKO3_DISABLE_NEW_CONSOLE: "1" } };
  for (let offset = 0; offset < uniqueNames.length; offset += batchSize) {
    const batchNames = uniqueNames.slice(offset, offset + batchSize);
    const source = [];
    for (const [index, name] of batchNames.entries()) {
      source.push(`文字コード変換サポート判定(${JSON.stringify(name)})を表示`);
      source.push(`E${index}=エンコーディング変換("A",${JSON.stringify(name)})`);
      source.push(`エンコーディング取得(E${index},${JSON.stringify(name)})を表示`);
    }
    const batchIndex = Math.floor(offset / batchSize);
    const sourcePath = resolve(temporary, `encodings-${batchIndex}.nako3`);
    await writeFile(sourcePath, `${source.join("\n")}\n`, "utf8");
    const official = spawnSync(process.execPath, [officialCli, sourcePath], options);
    const actual = spawnSync(executable, ["run", sourcePath], options);
    if (official.status !== 0) throw new Error(`公式文字コード検査の実行に失敗しました (batch ${batchIndex}):\n${official.stderr}`);
    if (actual.status !== 0) throw new Error(`lnako文字コード検査の実行に失敗しました (batch ${batchIndex}):\n${actual.stderr}`);
    const expected = official.stdout.replaceAll("\r\n", "\n");
    const received = actual.stdout.replaceAll("\r\n", "\n");
    if (expected !== received) {
      const expectedLines = expected.split("\n");
      const receivedLines = received.split("\n");
      const lineCount = Math.max(expectedLines.length, receivedLines.length);
      let difference = 0;
      while (difference < lineCount && expectedLines[difference] === receivedLines[difference]) difference += 1;
      const name = batchNames[Math.floor(difference / 2)] ?? "<出力末尾>";
      throw new Error(`文字コード別名 ${name} の結果が一致しません: official=${JSON.stringify(expectedLines[difference])} lnako=${JSON.stringify(receivedLines[difference])}`);
    }
  }
  console.log(`iconv-lite文字コード名${uniqueNames.length}件のサポート判定・ASCII往復が一致しました`);
} finally {
  await rm(temporary, { recursive: true, force: true });
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
