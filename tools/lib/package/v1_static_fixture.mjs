// v1 パッケージ比較用の「静的ローカル index」fixture を組み立てる。
//
// 仕様 v1 のクライアントは、`--v1-fixture <dir>` 以下の固定ファイルを
// registry/artifact の応答として読む（`src/package/v1_client_fixture.zig`）。
// このモジュールはテスト用に次の2段階を提供する:
//
// 1. `lnako package build` で各パッケージ source から `.npkg` を生成する。
// 2. 生成物の実 SHA-256 とサイズから §4 の index JSON と config を書き、
//    `.npkg` を fixture の URL ツリーへ配置する。
//
// index はテスト実行中に固定内容から生成するが、クライアントからは静的
// ファイルとしてだけ見える。ネットワークや実レジストリには接続しない。
// ここはテスト専用で、製品のパッケージ形式（v1 のみ）には触れない。
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";

export const registryUrl = "https://registry.example.invalid";
export const artifactBaseUrl = "https://cdn.example.invalid/artifacts";
export const publishedAt = "2026-11-27T13:30:00Z";

export class FixtureError extends Error {}

function fail(message) {
  throw new FixtureError(message);
}

function runChecked(executable, args, cwd) {
  const result = spawnSync(executable, args, {
    cwd,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 16 * 1024 * 1024,
    timeout: 600_000,
  });
  if (result.error) fail(`${executable} を実行できません: ${result.error.message}`);
  if (result.status === null) fail(`${executable} がtimeoutで終了しました（signal: ${result.signal ?? "unknown"}）`);
  return { status: result.status, stdout: result.stdout ?? "", stderr: result.stderr ?? "" };
}

/**
 * `lnako package build` で `.npkg` を作り、実バイト列と SHA-256 を返す。
 * 出力先は package source の外に置き、include 対象へ混ざらないようにする。
 */
export function buildArtifact(executable, packageRoot, outputPath, cwd, extraArgs = []) {
  const result = runChecked(executable, ["package", "build", packageRoot, "-o", outputPath, ...extraArgs], cwd);
  if (result.status !== 0) {
    fail(`package buildが失敗しました: ${packageRoot}\n${result.stderr}`);
  }
  if (!fs.existsSync(outputPath)) fail(`package buildの生成物がありません: ${outputPath}`);
  const bytes = fs.readFileSync(outputPath);
  return {
    bytes,
    sha256: `sha256:${createHash("sha256").update(bytes).digest("hex")}`,
    size: bytes.length,
  };
}

function releaseDocument(entry) {
  // `artifact` は native-prebuilt のようなプラットフォーム固有の
  // アーティファクトを index へ載せるための任意指定。省略時は従来どおり
  // universal（全ランタイム）として公開する。
  const artifact = entry.artifact ?? {};
  const document = {
    kind: artifact.kind ?? "universal",
    runtimes: artifact.runtimes ?? ["lnako", "cnako", "wnako"],
    target: artifact.target ?? null,
    hosting: "registry",
    url: `${artifactBaseUrl}/${entry.artifactName}`,
    sha256: entry.sha256,
    size: entry.size,
  };
  return {
    version: entry.version,
    published_at: publishedAt,
    yanked: false,
    yank_reason: null,
    license: entry.license,
    capabilities: entry.capabilities ?? ["pure-nako"],
    engines: {},
    exports_global_commands: false,
    global_commands: [],
    features: {},
    dependencies: entry.dependencies ?? [],
    provenance: { verified: false },
    advisories: [],
    artifacts: [document],
  };
}

/**
 * fixture ルートへ config・package index・`.npkg` を書き出す。
 *
 * `packages` の各要素は `{ id, version, license, capabilities, artifactName,
 * sha256, size, bytes, dependencies?, artifact? }`。`artifact` を指定する場合は
 * index の `{ kind, runtimes, target }` を渡す。`artifactName` は
 * `https://cdn.example.invalid/artifacts/<artifactName>` に対応する。
 */
export function writeStaticIndex(fixtureRoot, packages) {
  const configPath = path.join(fixtureRoot, "index", "v1", "config.json");
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  fs.writeFileSync(
    configPath,
    `${JSON.stringify({
      schema_version: 1,
      registry_id: "local-fixture",
      api_base_url: "https://api.registry.example.invalid/v1",
      artifact_base_url: artifactBaseUrl,
      allowed_external_hosts: [],
    }, null, 2)}\n`,
    "utf8",
  );

  for (const entry of packages) {
    const slash = entry.id.indexOf("/");
    if (!entry.id.startsWith("@") || slash < 0) fail(`Package IDが不正です: ${entry.id}`);
    const scope = entry.id.slice(1, slash);
    const name = entry.id.slice(slash + 1);
    const indexDir = path.join(fixtureRoot, "index", "v1", "packages", scope);
    fs.mkdirSync(indexDir, { recursive: true });
    const document = {
      schema_version: 1,
      id: entry.id,
      scope_id: "sc01",
      updated_at: publishedAt,
      deprecated: null,
      versions: [releaseDocument(entry)],
    };
    fs.writeFileSync(path.join(indexDir, `${name}.json`), `${JSON.stringify(document, null, 2)}\n`, "utf8");

    const artifactPath = path.join(
      fixtureRoot,
      "urls",
      "cdn.example.invalid",
      "artifacts",
      entry.artifactName,
    );
    fs.mkdirSync(path.dirname(artifactPath), { recursive: true });
    fs.writeFileSync(artifactPath, entry.bytes);
  }
}

/**
 * `lnako sync --v1-fixture` を実行する。`--json` は付けず、環境は
 * `.nako/v1` と `nako.lock` に作らせる（比較側で実環境を使う）。
 */
export function syncProject(executable, projectRoot, fixtureRoot) {
  const result = runChecked(
    executable,
    ["sync", "--v1-fixture", fixtureRoot, "--registry", registryUrl],
    projectRoot,
  );
  if (result.status !== 0) {
    fail(`syncが失敗しました: ${projectRoot}\n${result.stderr}`);
  }
  return result;
}
