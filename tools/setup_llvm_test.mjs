import assert from "node:assert/strict";
import { access, cp, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";

import { prune } from "./prune_llvm_toolchain.mjs";
import { cacheStatus, markerName } from "./setup_llvm.mjs";

const fixtureMarker = { version: "22.1.8", platform: "macos-aarch64", sha256: "a".repeat(64) };

async function temporaryDirectory() {
  return mkdtemp(join(tmpdir(), "lnako-setup-llvm-test-"));
}

function clangName(platform) {
  return platform === "win32" ? "clang.exe" : "clang";
}

function lldName(platform) {
  return platform === "win32" ? "lld-link.exe" : platform === "darwin" ? "ld64.lld" : "ld.lld";
}

async function writeFixtureToolchain(directory, platform) {
  await mkdir(join(directory, "bin"), { recursive: true });
  await mkdir(join(directory, "lib", "clang", "22", "include"), { recursive: true });
  await writeFile(join(directory, "bin", clangName(platform)), "clang\n");
  await writeFile(join(directory, "bin", lldName(platform)), "lld\n");
  if (platform === "win32") {
    await writeFile(join(directory, "bin", "LLVM-C.dll"), "library\n");
  } else {
    await writeFile(join(directory, "lib", `libLLVM-C.${platform === "darwin" ? "dylib" : "so"}`), "library\n");
  }
  if (platform === "darwin") {
    await writeFile(join(directory, "lib", "libc++.1.dylib"), "c++\n");
    await writeFile(join(directory, "lib", "libc++abi.1.dylib"), "c++abi\n");
    await writeFile(join(directory, "lib", "libunwind.1.dylib"), "unwind\n");
  }
  await writeFile(join(directory, "lib", "clang", "22", "include", "stddef.h"), "fixture\n");
  await writeFile(join(directory, markerName), `${JSON.stringify(fixtureMarker)}\n`);
  // Entries that prune must remove.
  await writeFile(join(directory, "bin", "unused-tool"), "remove\n");
  await mkdir(join(directory, "share", "unused"), { recursive: true });
  await writeFile(join(directory, "share", "unused", "file"), "remove\n");
  return {
    clangPath: join(directory, "bin", clangName(platform)),
    lldPath: join(directory, "bin", lldName(platform)),
  };
}

function statusParams({ markerPath, clangPath, lldPath }) {
  return {
    markerPath,
    clangPath,
    lldPath,
    version: fixtureMarker.version,
    platform: fixtureMarker.platform,
    sha256: fixtureMarker.sha256,
  };
}

// GitHub Actionsのtoolchain cacheはprune後のtreeを保存する。復元先でも
// cacheStatus()がvalidを返さないと全ジョブがLLVMを再downloadする回帰になる。
test("pruned and restored LLVM toolchain stays a valid cache", async () => {
  const directory = await temporaryDirectory();
  try {
    for (const platform of ["darwin", "linux", "win32"]) {
      const source = join(directory, `source-${platform}`);
      const restored = join(directory, `restored-${platform}`);
      const { clangPath, lldPath } = await writeFixtureToolchain(source, platform);
      await prune(source, platform);
      await cp(source, restored, { recursive: true });
      const status = await cacheStatus(statusParams({
        markerPath: join(restored, markerName),
        clangPath: clangPath.replace(source, restored),
        lldPath: lldPath.replace(source, restored),
      }));
      assert.deepEqual(status, { valid: true, reason: "valid" });
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("cacheStatus classifies every invalid reason", async () => {
  const directory = await temporaryDirectory();
  try {
    const { clangPath, lldPath } = await writeFixtureToolchain(directory, "linux");
    const markerPath = join(directory, markerName);
    const params = statusParams({ markerPath, clangPath, lldPath });
    assert.deepEqual(await cacheStatus(params), { valid: true, reason: "valid" });

    await rm(markerPath);
    assert.equal((await cacheStatus(params)).reason, "marker-missing");

    await writeFile(markerPath, "not json\n");
    assert.equal((await cacheStatus(params)).reason, "marker-invalid");

    await writeFile(markerPath, `${JSON.stringify(fixtureMarker)}\n`);
    await rm(clangPath);
    const clangStatus = await cacheStatus(params);
    assert.equal(clangStatus.reason, "clang-missing");
    assert.match(clangStatus.detail, /missing=/);

    await writeFile(clangPath, "clang\n");
    await rm(lldPath);
    assert.equal((await cacheStatus(params)).reason, "lld-missing");

    await writeFile(lldPath, "lld\n");
    for (const [key, value, reason] of [
      ["version", "0.0.0", "version-mismatch"],
      ["platform", "linux-aarch64", "platform-mismatch"],
      ["sha256", "b".repeat(64), "sha256-mismatch"],
    ]) {
      await writeFile(markerPath, `${JSON.stringify({ ...fixtureMarker, [key]: value })}\n`);
      const status = await cacheStatus(params);
      assert.equal(status.reason, reason);
      assert.match(status.detail, /expected=.+ actual=/);
    }

    await writeFile(markerPath, `${JSON.stringify(fixtureMarker)}\n`);
    assert.equal((await cacheStatus(params)).reason, "valid");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
