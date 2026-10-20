import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createArtifact, sha256Hex, verifyArtifact } from "./release_candidate_artifact.mjs";

const COMMIT = "a".repeat(64);
const RUN_ID = "39272297510";
const env = {
  GITHUB_SHA: COMMIT,
  GITHUB_RUN_ID: RUN_ID,
  GITHUB_WORKFLOW: "CI",
  GITHUB_JOB: "test",
};

function workspace() {
  const directory = mkdtempSync(join(tmpdir(), "lnako-rc-artifact-"));
  mkdirSync(join(directory, "repo"), { recursive: true });
  writeFileSync(join(directory, "repo", "toolchain.lock.json"), JSON.stringify({
    zig: { version: "0.17.0" },
    llvm: { version: "22.1.8" },
    node: { version: "24.15.0" },
  }));
  writeFileSync(join(directory, "repo", "build.zig.zon"), '.name = "lnako"\n.version = "0.2.3"\n');
  writeFileSync(join(directory, "lnako"), "fake-release-compiler");
  writeFileSync(join(directory, "liblnako_runtime.a"), "fake-release-runtime");
  return directory;
}

function create(work, root, outDir, target = "linux-x64") {
  return createArtifact({
    binaryPath: join(work, "lnako"),
    runtimeLibPath: join(work, "liblnako_runtime.a"),
    outDir,
    target,
    root,
    env,
  });
}

test("create→verifyでReleaseSafe+compat-js成果物を復元できる", () => {
  const work = workspace();
  const root = join(work, "repo");
  const outDir = join(work, "artifact");
  const metadata = create(work, root, outDir);
  assert.equal(metadata.schema, "lnako.release-candidate.v1");
  assert.equal(metadata.commit, COMMIT);
  assert.equal(metadata.buildMode, "ReleaseSafe");
  assert.equal(metadata.compatJs, true);
  assert.equal(metadata.target, "linux-x64");
  assert.equal(metadata.ciRunId, RUN_ID);
  assert.equal(metadata.version, "0.2.3");
  assert.equal(metadata.binarySha256, sha256Hex(Buffer.from("fake-release-compiler")));
  const installTo = join(work, "zig-out", "bin");
  const verified = verifyArtifact({
    dir: outDir,
    installTo,
    expectedTarget: "linux-x64",
    expectedRunId: RUN_ID,
    expectedVersion: "0.2.3",
    root,
    env,
  });
  assert.equal(verified.metadata.ciRunId, RUN_ID);
  assert.equal(readFileSync(join(installTo, "lnako"), "utf8"), "fake-release-compiler");
  if (process.platform !== "win32") {
    assert.notEqual(statSync(join(installTo, "lnako")).mode & 0o111, 0);
  }
  assert.equal(readFileSync(join(work, "zig-out", "lib", "liblnako_runtime.a"), "utf8"), "fake-release-runtime");
  rmSync(work, { recursive: true, force: true });
});

test("別CI run・別target・改変binaryを拒否する", () => {
  const work = workspace();
  const root = join(work, "repo");
  const outDir = join(work, "artifact");
  create(work, root, outDir);
  assert.throws(
    () => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), expectedTarget: "linux-x64", expectedRunId: "1", root, env }),
    /CI run IDが不一致/,
  );
  assert.throws(
    () => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), expectedTarget: "windows-x64", expectedRunId: RUN_ID, root, env }),
    /targetが不一致/,
  );
  writeFileSync(join(outDir, "lnako"), "tampered");
  assert.throws(
    () => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), expectedTarget: "linux-x64", expectedRunId: RUN_ID, root, env }),
    /SHA-256が不一致/,
  );
  rmSync(work, { recursive: true, force: true });
});

test("Debug AOT artifact schemaや不正keyを拒否する", () => {
  const work = workspace();
  const root = join(work, "repo");
  const outDir = join(work, "artifact");
  const metadata = create(work, root, outDir);
  writeFileSync(join(outDir, "release-candidate.json"), JSON.stringify({ ...metadata, schema: "lnako.aot-compiler-artifact.v1" }));
  assert.throws(
    () => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), expectedTarget: "linux-x64", expectedRunId: RUN_ID, root, env }),
    /schemaが不正/,
  );
  writeFileSync(join(outDir, "release-candidate.json"), JSON.stringify({ ...metadata, extra: true }));
  assert.throws(
    () => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), expectedTarget: "linux-x64", expectedRunId: RUN_ID, root, env }),
    /key構成が不正/,
  );
  writeFileSync(join(outDir, "release-candidate.json"), JSON.stringify({ ...metadata, buildMode: "Debug" }));
  assert.throws(
    () => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), expectedTarget: "linux-x64", expectedRunId: RUN_ID, root, env }),
    /build構成が不一致/,
  );
  rmSync(work, { recursive: true, force: true });
});
