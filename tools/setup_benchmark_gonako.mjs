import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { createWriteStream } from "node:fs";
import { access, appendFile, chmod, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { arch as hostArch, platform as hostPlatform } from "node:os";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";

export const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const lock = JSON.parse(await readFile(resolve(root, "tools/benchmark_gonako.lock.json"), "utf8"));
export const defaultCacheRoot = resolve(root, ".cache/benchmark-gonako");
export const markerName = ".lnako-gonako.json";
export const receiptName = "provenance.json";

validateLock(lock);

/**
 * Resolve the small set of official GitHub release artifacts used by the
 * formal comparison runners. The key deliberately follows Node's platform
 * and architecture names so it cannot silently select another binary.
 */
export function platformKey(platform = hostPlatform(), architecture = hostArch()) {
  const key = `${platform}-${architecture}`;
  if (!Object.hasOwn(lock.artifacts, key)) {
    throw new Error(`gonako ${lock.release}の正式対応外ホストです: ${key}`);
  }
  return key;
}

export function artifactFor(key, artifacts = lock.artifacts) {
  const artifact = artifacts[key];
  if (!artifact) throw new Error(`gonakoの配布物が未定義です: ${key}`);
  return { ...artifact };
}

/**
 * Read the SHA-256 digest published by the official GitHub release API.
 * Windows does not have a Homebrew formula to use as an independent digest
 * source, so callers can check its lock entry against this API before
 * downloading or accepting a cache hit.
 */
export async function fetchOfficialDigest({
  fetchImpl = globalThis.fetch,
  releaseApi = lock.releaseApi,
  release = lock.release,
  assetName,
  expectedSha256,
  expectedUrl,
  timeoutMs = 60_000,
} = {}) {
  if (typeof fetchImpl !== "function") throw new Error("公式release APIを取得できるfetchがありません");
  const response = await fetchWithTimeout(fetchImpl, releaseApi, {
    headers: {
      Accept: "application/vnd.github+json",
      "User-Agent": "lnako-comparison-benchmark",
    },
  }, timeoutMs);
  if (!response?.ok) throw new Error(`gonako公式release APIの取得に失敗しました: HTTP ${response?.status ?? "?"}`);
  const metadata = await response.json();
  if (metadata?.tag_name !== release) {
    throw new Error(`gonako公式release APIのtagが不一致です: expected=${release} actual=${metadata?.tag_name ?? "?"}`);
  }
  const asset = metadata.assets?.find((candidate) => candidate?.name === assetName);
  if (!asset) throw new Error(`gonako公式release APIにassetがありません: ${assetName}`);
  const digest = normalizeDigest(asset.digest);
  if (digest === null) throw new Error(`gonako公式release APIのasset digestがSHA-256ではありません: ${assetName}`);
  if (expectedSha256 !== undefined && digest !== expectedSha256) {
    throw new Error(`gonako公式release APIのSHA-256がlockと不一致です: expected=${expectedSha256} actual=${digest}`);
  }
  if (expectedUrl !== undefined && asset.browser_download_url !== expectedUrl) {
    throw new Error(`gonako公式release APIのdownload URLがlockと不一致です: expected=${expectedUrl} actual=${asset.browser_download_url ?? "?"}`);
  }
  return { sha256: digest, url: asset.browser_download_url ?? null };
}

export async function sha256File(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

export async function verifyBinary(path, expectedSha256) {
  const actualSha256 = await sha256File(path);
  if (actualSha256 !== expectedSha256) {
    throw new Error(`gonako配布物のSHA-256不一致: expected=${expectedSha256} actual=${actualSha256}`);
  }
  return actualSha256;
}

/**
 * Install or validate one cached release artifact. All inputs are injectable
 * so checksum and cache behavior can be tested without network access.
 */
export async function setupGonako({
  platform = hostPlatform(),
  architecture = hostArch(),
  cacheRoot = defaultCacheRoot,
  fetchImpl = globalThis.fetch,
  releaseApi = lock.releaseApi,
  artifacts = lock.artifacts,
  release = lock.release,
  verifyReleaseApi = false,
  timeoutMs = 60_000,
  versionReader = readReportedVersion,
  envFile = process.env.GITHUB_ENV,
  pathFile = process.env.GITHUB_PATH,
} = {}) {
  const key = `${platform}-${architecture}`;
  const artifact = artifactFor(key, artifacts);
  if (release !== lock.release) throw new Error(`gonako releaseはlockの固定値と一致する必要があります: ${release}`);

  // The Windows formula equivalent is absent. A caller can opt into checking
  // the pinned digest against the official release API; normal CI uses the
  // locked digest and rehashes the binary to avoid an API availability gate.
  if (key === "win32-x64" && verifyReleaseApi) {
    await fetchOfficialDigest({
      fetchImpl,
      releaseApi,
      release,
      assetName: artifact.asset,
      expectedSha256: artifact.sha256,
      expectedUrl: artifact.url,
      timeoutMs,
    });
  }

  const target = resolve(cacheRoot, `gonako-${release}-${key}`);
  const binaryName = key === "win32-x64" ? "gonako.exe" : "gonako";
  const executable = resolve(target, binaryName);
  const marker = resolve(target, markerName);
  const receipt = resolve(target, receiptName);

  if (!(await cacheIsCurrent({ marker, executable, key, artifact, release }))) {
    await installBinary({ target, binaryName, artifact, expectedSha256: artifact.sha256, fetchImpl, key, cacheRoot, timeoutMs });
  }

  // Hash the final path after installation/restore. This also protects the
  // provenance receipt against a modified cache entry.
  const binarySha256 = await verifyBinary(executable, artifact.sha256);
  let reportedVersion = null;
  try {
    reportedVersion = await versionReader(executable);
  } catch (error) {
    console.warn(`gonakoのreported versionを取得できませんでした: ${error instanceof Error ? error.message : String(error)}`);
  }
  const receiptValue = {
    release,
    sha256: binarySha256,
    url: artifact.url,
    ...(reportedVersion ? { reported_version: reportedVersion } : {}),
  };
  await writeFile(receipt, `${JSON.stringify(receiptValue, null, 2)}\n`, "utf8");
  await writeFile(
    marker,
    `${JSON.stringify({ schemaVersion: 1, release, platform: key, asset: artifact.asset, url: artifact.url, sha256: artifact.sha256 }, null, 2)}\n`,
    "utf8",
  );
  await exportEnvironment({ executable, receipt, target, envFile, pathFile });
  return { release, platform: key, asset: artifact.asset, url: artifact.url, executable, receipt, reportedVersion, sha256: binarySha256, cached: await cacheIsCurrent({ marker, executable, key, artifact, release }) };
}

async function cacheIsCurrent({ marker, executable, key, artifact, release }) {
  try {
    const current = JSON.parse(await readFile(marker, "utf8"));
    if (current.schemaVersion !== 1 || current.release !== release || current.platform !== key || current.asset !== artifact.asset || current.url !== artifact.url || current.sha256 !== artifact.sha256) return false;
    await access(executable);
    await verifyBinary(executable, artifact.sha256);
    return true;
  } catch {
    return false;
  }
}

async function installBinary({ target, binaryName, artifact, expectedSha256, fetchImpl, key, cacheRoot, timeoutMs }) {
  if (typeof fetchImpl !== "function") throw new Error("gonako配布物を取得できるfetchがありません");
  await mkdir(cacheRoot, { recursive: true });
  const staging = resolve(cacheRoot, `.gonako-staging-${key}-${process.pid}`);
  const downloaded = resolve(staging, artifact.asset);
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  try {
    const response = await fetchWithTimeout(fetchImpl, artifact.url, {
      headers: { Accept: "application/octet-stream", "User-Agent": "lnako-comparison-benchmark" },
    }, timeoutMs);
    if (!response?.ok || !response.body) throw new Error(`gonako配布物の取得に失敗しました: HTTP ${response?.status ?? "?"}`);
    const hash = createHash("sha256");
    const hashingStream = new Transform({
      transform(chunk, _encoding, callback) {
        hash.update(chunk);
        callback(null, chunk);
      },
    });
    await pipeline(Readable.fromWeb(response.body), hashingStream, createWriteStream(downloaded));
    const actualSha256 = hash.digest("hex");
    if (actualSha256 !== expectedSha256) {
      throw new Error(`gonako配布物のSHA-256不一致: expected=${expectedSha256} actual=${actualSha256}`);
    }
    if (key !== "win32-x64") await chmod(downloaded, 0o755);
    await rename(downloaded, resolve(staging, binaryName));
    await rm(target, { recursive: true, force: true });
    await rename(staging, target);
  } finally {
    await rm(staging, { recursive: true, force: true });
  }
}

async function fetchWithTimeout(fetchImpl, url, options, timeoutMs) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error(`gonako fetch timeoutが不正です: ${timeoutMs}`);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImpl(url, { ...options, signal: controller.signal });
  } catch (error) {
    if (error?.name === "AbortError") throw new Error(`gonako配布物の取得がタイムアウトしました: ${url}`);
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

export async function readReportedVersion(executable) {
  const result = spawnSync(executable, ["--version"], {
    encoding: "utf8",
    shell: false,
    timeout: 5_000,
    maxBuffer: 1024 * 1024,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${executable} --versionの終了コードが${result.status}です`);
  const output = `${result.stdout ?? ""}\n${result.stderr ?? ""}`;
  const firstLine = output.split(/\r?\n/).map((line) => line.trim()).find(Boolean);
  return firstLine ?? null;
}

async function exportEnvironment({ executable, receipt, target, envFile, pathFile }) {
  if (envFile) {
    await appendFile(envFile, `LNAKO_BENCHMARK_GONAKO=${executable}\nLNAKO_BENCHMARK_GONAKO_PROVENANCE=${receipt}\n`, "utf8");
  }
  if (pathFile) await appendFile(pathFile, `${target}\n`, "utf8");
}

function normalizeDigest(value) {
  if (typeof value !== "string") return null;
  const match = /^sha256:([0-9a-f]{64})$/i.exec(value.trim());
  return match ? match[1].toLowerCase() : null;
}

function validateLock(value) {
  if (value?.schemaVersion !== 1 || value?.repository !== "kujirahand/nadesiko3go" || !/^3\.8\.1$/.test(value?.release ?? "") || value?.releaseApi !== "https://api.github.com/repos/kujirahand/nadesiko3go/releases/tags/3.8.1") {
    throw new Error("benchmark_gonako.lock.jsonの固定値が不正です");
  }
  for (const [key, artifact] of Object.entries(value.artifacts ?? {})) {
    if (!/^(darwin|linux|win32)-(arm64|x64)$/.test(key) || typeof artifact.asset !== "string" || !artifact.url.startsWith("https://github.com/kujirahand/nadesiko3go/releases/download/3.8.1/") || !/^[0-9a-f]{64}$/.test(artifact.sha256)) {
      throw new Error(`benchmark_gonako.lock.jsonのassetが不正です: ${key}`);
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  try {
    const result = await setupGonako({ verifyReleaseApi: process.argv.includes("--verify-release-api") });
    console.log(`gonako ${result.release} (${result.platform})を確認しました: executable=${result.executable}`);
    console.log(`gonako provenance receipt: ${result.receipt}`);
    if (result.reportedVersion) console.log(`gonako reported version: ${result.reportedVersion}`);
  } catch (error) {
    console.error(`setup_benchmark_gonako.mjs failed: ${error instanceof Error ? error.message : String(error)}`);
    if (error?.stack) console.error(error.stack);
    process.exitCode = 1;
  }
}
