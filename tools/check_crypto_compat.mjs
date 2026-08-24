import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { getHashes } from "node:crypto";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const oracleArg = process.argv.indexOf("--oracle");
const oracleRoot = resolve(oracleArg >= 0 ? process.argv[oracleArg + 1] : process.env.NADESIKO3_ORACLE ?? resolve(root, ".cache/oracle/nadesiko3-3.7.24"));
const officialCli = resolve(oracleRoot, "src/cnako3.mjs");
const executable = resolve(root, "zig-out/bin", process.platform === "win32" ? "lnako.exe" : "lnako");
const temporary = await mkdtemp(join(tmpdir(), "lnako-crypto-"));

try {
  buildLnako();
  const algorithms = getHashes();
  const source = ["JSON変換(ハッシュ関数一覧取得())を表示"];
  for (const algorithm of algorithms) {
    for (const encoding of ["hex", "base64", "base64url", "latin1"]) {
      source.push(`JSON変換(ハッシュ値計算("abc",${JSON.stringify(algorithm)},${JSON.stringify(encoding)}))を表示`);
    }
    source.push(`JSON変換(ハッシュ値計算("abc",${JSON.stringify(algorithm)},undefined))を表示`);
  }
  source.push("U=ランダムUUID生成()");
  source.push("(文字数(U)=36)を表示");
  source.push("U[14]を表示");
  source.push("(文字検索(\"89ab\",U[19],0)>=0)を表示");
  source.push("R=32のランダム配列生成");
  source.push("TYPEOF(R)を表示");
  source.push("要素数(R)を表示");
  source.push("((R[0]>=0)かつ(R[0]<=255))を表示");
  source.push("R0=0のランダム配列生成");
  source.push("要素数(R0)を表示");
  source.push("RN=NaNのランダム配列生成");
  source.push("要素数(RN)を表示");
  source.push("RF=2.9のランダム配列生成");
  source.push("要素数(RF)を表示");

  const sourcePath = resolve(temporary, "crypto.nako3");
  await writeFile(sourcePath, `${source.join("\n")}\n`, "utf8");
  const options = {
    cwd: temporary,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    env: { ...process.env, TZ: "Asia/Tokyo", LNAKO_TEST_RANDOM_SEED: "5573589319906701683", NAKO3_DISABLE_NEW_CONSOLE: "1" },
  };
  const official = spawnSync(process.execPath, [officialCli, sourcePath], options);
  const actual = spawnSync(executable, ["run", sourcePath], options);
  if (official.status !== 0) throw new Error(`公式暗号検査の実行に失敗しました:\n${official.stderr}`);
  if (actual.status !== 0) throw new Error(`lnako暗号検査の実行に失敗しました:\n${actual.stderr}`);
  const expected = official.stdout.replaceAll("\r\n", "\n");
  const received = actual.stdout.replaceAll("\r\n", "\n");
  if (expected !== received) {
    const expectedLines = expected.split("\n");
    const receivedLines = received.split("\n");
    const difference = expectedLines.findIndex((line, index) => line !== receivedLines[index]);
    const field = difference === 0 ? "hash-list" : difference <= algorithms.length * 5 ? `${algorithms[Math.floor((difference - 1) / 5)]}/${["hex", "base64", "base64url", "latin1", "buffer"][((difference - 1) % 5)]}` : `random-invariant-${difference - algorithms.length * 5}`;
    throw new Error(`暗号差分 ${field}: official=${JSON.stringify(expectedLines[difference])} lnako=${JSON.stringify(receivedLines[difference])}`);
  }

  for (const count of [-1, 65537]) {
    const failurePath = resolve(temporary, `invalid-${count}.nako3`);
    await writeFile(failurePath, `${count}のランダム配列生成\n`, "utf8");
    const officialFailure = spawnSync(process.execPath, [officialCli, failurePath], options);
    const actualFailure = spawnSync(executable, ["run", failurePath], options);
    const officialRejected = officialFailure.status !== 0 || `${officialFailure.stdout}${officialFailure.stderr}`.includes("エラー");
    const actualRejected = actualFailure.status !== 0 || `${actualFailure.stdout}${actualFailure.stderr}`.includes("エラー");
    if (!officialRejected || !actualRejected) throw new Error(`乱数配列の不正要素数 ${count} を両処理系が拒否しませんでした`);
  }

  console.log(`Node暗号公式差分テスト: ハッシュ名${algorithms.length}件・5出力形式・乱数境界成功`);
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
