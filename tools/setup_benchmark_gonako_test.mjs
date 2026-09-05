import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { access, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";

import {
  fetchOfficialDigest,
  lock,
  platformKey,
  setupGonako,
} from "./setup_benchmark_gonako.mjs";

function hash(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function temporaryDirectory(prefix = "lnako-gonako-test-") {
  return mkdtemp(join(tmpdir(), prefix));
}

test("gonako lock covers formal hosts and official release URLs", () => {
  assert.equal(platformKey("darwin", "arm64"), "darwin-arm64");
  assert.equal(platformKey("linux", "x64"), "linux-x64");
  assert.equal(platformKey("win32", "x64"), "win32-x64");
  assert.throws(() => platformKey("linux", "arm64"), /正式対応外ホスト/);
  for (const artifact of Object.values(lock.artifacts)) {
    assert.match(artifact.url, /^https:\/\/github\.com\/kujirahand\/nadesiko3go\/releases\/download\/3\.8\.1\//);
    assert.match(artifact.sha256, /^[0-9a-f]{64}$/);
  }
});

test("setup downloads, verifies, exports a receipt, and reuses a valid cache", async () => {
  const directory = await temporaryDirectory();
  const envFile = join(directory, "github-env");
  const pathFile = join(directory, "github-path");
  const payload = Buffer.from("#!/bin/sh\nprintf 'gonako v3.6.0 (linux/amd64)\\n'\n", "utf8");
  const artifact = {
    asset: "fake-gonako-linux",
    url: "https://example.invalid/fake-gonako-linux",
    sha256: hash(payload),
  };
  const artifacts = { "linux-x64": artifact };
  let downloads = 0;
  const fetchImpl = async (url) => {
    assert.equal(url, artifact.url);
    downloads += 1;
    return new Response(payload, { status: 200 });
  };
  try {
    const first = await setupGonako({
      platform: "linux",
      architecture: "x64",
      cacheRoot: directory,
      artifacts,
      fetchImpl,
      versionReader: async () => "gonako v3.6.0 (linux/amd64)",
      envFile,
      pathFile,
    });
    assert.equal(downloads, 1);
    assert.equal(first.reportedVersion, "gonako v3.6.0 (linux/amd64)");
    assert.equal(first.sha256, artifact.sha256);
    assert.match(await readFile(first.receipt, "utf8"), /"release": "3.8.1"/);
    assert.match(await readFile(first.receipt, "utf8"), /"reported_version": "gonako v3.6.0 \(linux\/amd64\)"/);
    assert.match(await readFile(envFile, "utf8"), new RegExp(`LNAKO_BENCHMARK_GONAKO=${escapeRegExp(first.executable)}`));
    assert.match(await readFile(envFile, "utf8"), new RegExp(`LNAKO_BENCHMARK_GONAKO_PROVENANCE=${escapeRegExp(first.receipt)}`));

    const second = await setupGonako({
      platform: "linux",
      architecture: "x64",
      cacheRoot: directory,
      artifacts,
      fetchImpl: async () => { throw new Error("cache hit must not download"); },
      versionReader: async () => "gonako v3.6.0 (linux/amd64)",
    });
    assert.equal(downloads, 1);
    assert.equal(second.executable, first.executable);

    await writeFile(first.executable, "tampered\n", "utf8");
    await setupGonako({
      platform: "linux",
      architecture: "x64",
      cacheRoot: directory,
      artifacts,
      fetchImpl,
      versionReader: async () => "gonako v3.6.0 (linux/amd64)",
    });
    assert.equal(downloads, 2);
    await access(first.executable);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Windows supports an explicit API audit and default offline cache reuse", async () => {
  const directory = await temporaryDirectory();
  const payload = Buffer.from("fake windows gonako", "utf8");
  const artifact = {
    asset: "fake-gonako-windows.exe",
    url: "https://github.com/kujirahand/nadesiko3go/releases/download/3.8.1/fake-gonako-windows.exe",
    sha256: hash(payload),
  };
  const releaseApi = "https://api.example.invalid/releases/3.8.1";
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(url);
    if (url === releaseApi) {
      return new Response(JSON.stringify({
        tag_name: "3.8.1",
        assets: [{ name: artifact.asset, digest: `sha256:${artifact.sha256}`, browser_download_url: artifact.url }],
      }), { status: 200, headers: { "content-type": "application/json" } });
    }
    assert.equal(url, artifact.url);
    return new Response(payload, { status: 200 });
  };
  try {
    const first = await setupGonako({
      platform: "win32",
      architecture: "x64",
      cacheRoot: directory,
      artifacts: { "win32-x64": artifact },
      fetchImpl,
      releaseApi,
      verifyReleaseApi: true,
      versionReader: async () => "gonako v3.6.0 (windows/amd64)",
    });
    assert.deepEqual(calls, [releaseApi, artifact.url]);
    calls.length = 0;
    await setupGonako({
      platform: "win32",
      architecture: "x64",
      cacheRoot: directory,
      artifacts: { "win32-x64": artifact },
      fetchImpl: async () => { throw new Error("offline cache must not fetch"); },
      releaseApi,
      versionReader: async () => "gonako v3.6.0 (windows/amd64)",
    });
    assert.deepEqual(calls, []);
    assert.equal(JSON.parse(await readFile(first.receipt, "utf8")).reported_version, "gonako v3.6.0 (windows/amd64)");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("checksum mismatch and API digest mismatch stop setup before publishing a binary", async () => {
  const directory = await temporaryDirectory();
  const payload = Buffer.from("wrong payload", "utf8");
  const artifact = {
    asset: "fake-gonako",
    url: "https://github.com/kujirahand/nadesiko3go/releases/download/3.8.1/fake-gonako",
    sha256: "0".repeat(64),
  };
  try {
    await assert.rejects(
      setupGonako({
        platform: "linux",
        architecture: "x64",
        cacheRoot: directory,
        artifacts: { "linux-x64": artifact },
        fetchImpl: async () => new Response(payload, { status: 200 }),
        versionReader: async () => null,
      }),
      /SHA-256不一致/,
    );
    await assert.rejects(access(resolve(directory, "gonako-3.8.1-linux-x64/gonako")));

    const windowsArtifact = { ...artifact, asset: "fake-gonako.exe", url: `${artifact.url}.exe`, sha256: hash(payload) };
    await assert.rejects(
      setupGonako({
        platform: "win32",
        architecture: "x64",
        cacheRoot: directory,
        artifacts: { "win32-x64": windowsArtifact },
        releaseApi: "https://api.example.invalid/releases/3.8.1",
        verifyReleaseApi: true,
        fetchImpl: async (url) => url.includes("api.example")
          ? new Response(JSON.stringify({ tag_name: "3.8.1", assets: [{ name: windowsArtifact.asset, digest: `sha256:${"f".repeat(64)}`, browser_download_url: windowsArtifact.url }] }), { status: 200 })
          : new Response(payload, { status: 200 }),
        versionReader: async () => null,
      }),
      /公式release APIのSHA-256がlockと不一致/,
    );
    await assert.rejects(access(resolve(directory, "gonako-3.8.1-win32-x64/gonako.exe")));
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("release API digest parser rejects an untrusted or incomplete response", async () => {
  await assert.rejects(
    fetchOfficialDigest({
      fetchImpl: async () => new Response(JSON.stringify({ tag_name: "3.8.1", assets: [] }), { status: 200 }),
      releaseApi: "https://api.example.invalid/releases/3.8.1",
      assetName: "gonako.exe",
      expectedSha256: "0".repeat(64),
    }),
    /assetがありません/,
  );
});

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
