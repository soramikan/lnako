import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createArtifact, sha256Hex, verifyArtifact } from "./aot_compiler_artifact.mjs";

const COMMIT = "a".repeat(64);
const env = { GITHUB_SHA: COMMIT };

function workspace() {
  const directory = mkdtempSync(join(tmpdir(), "lnako-aot-artifact-"));
  mkdirSync(join(directory, "repo"), { recursive: true });
  writeFileSync(join(directory, "repo", "toolchain.lock.json"), JSON.stringify({ zig: { version: "0.16.0" }, llvm: { version: "22.1.8" }, node: { version: "24.15.0" } }));
  writeFileSync(join(directory, "lnako.exe"), "fake-compiler-binary");
  return directory;
}

test("create→verifyでmetadataとbinaryを復元できる", () => {
  const work = workspace();
  const root = join(work, "repo");
  const outDir = join(work, "artifact");
  const metadata = createArtifact({ binaryPath: join(work, "lnako.exe"), outDir, root, env });
  assert.equal(metadata.schema, "lnako.aot-compiler-artifact.v1");
  assert.equal(metadata.commit, COMMIT);
  assert.equal(metadata.zig, "0.16.0");
  assert.equal(metadata.binarySha256, sha256Hex(Buffer.from("fake-compiler-binary")));
  const installTo = join(work, "zig-out", "bin");
  const verified = verifyArtifact({ dir: outDir, installTo, root, env });
  assert.equal(verified.metadata.commit, COMMIT);
  assert.equal(readFileSync(join(installTo, "lnako.exe"), "utf8"), "fake-compiler-binary");
  rmSync(work, { recursive: true, force: true });
});

test("改変されたbinaryはSHA-256不一致で拒否する", () => {
  const work = workspace();
  const root = join(work, "repo");
  const outDir = join(work, "artifact");
  createArtifact({ binaryPath: join(work, "lnako.exe"), outDir, root, env });
  writeFileSync(join(outDir, "lnako.exe"), "tampered");
  assert.throws(() => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), root, env }), /SHA-256が不一致/);
  rmSync(work, { recursive: true, force: true });
});

test("別commit・別platformのartifactを拒否する", () => {
  const work = workspace();
  const root = join(work, "repo");
  const outDir = join(work, "artifact");
  createArtifact({ binaryPath: join(work, "lnako.exe"), outDir, root, env });
  assert.throws(() => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), root, env: { GITHUB_SHA: "b".repeat(64) } }), /commitが不一致/);
  const other = process.platform === "win32" ? "linux" : "win32";
  assert.throws(() => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), root, env, platform: other }), /platformが不一致/);
  rmSync(work, { recursive: true, force: true });
});

test("metadata欠落・余分なkey・binaryName traversalを拒否する", () => {
  const work = workspace();
  const root = join(work, "repo");
  assert.throws(() => verifyArtifact({ dir: join(work, "empty"), installTo: join(work, "bin"), root, env }), /metadataがありません/);
  const outDir = join(work, "artifact");
  const metadata = createArtifact({ binaryPath: join(work, "lnako.exe"), outDir, root, env });
  writeFileSync(join(outDir, "compiler-artifact.json"), JSON.stringify({ ...metadata, extra: true }));
  assert.throws(() => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), root, env }), /key構成が不正/);
  writeFileSync(join(outDir, "compiler-artifact.json"), JSON.stringify({ ...metadata, binaryName: "../evil.exe" }));
  assert.throws(() => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), root, env }), /binaryNameが不正/);
  rmSync(work, { recursive: true, force: true });
});

test("Zig versionとbuild構成の不一致を拒否する", () => {
  const work = workspace();
  const root = join(work, "repo");
  const outDir = join(work, "artifact");
  const metadata = createArtifact({ binaryPath: join(work, "lnako.exe"), outDir, root, env });
  writeFileSync(join(outDir, "compiler-artifact.json"), JSON.stringify({ ...metadata, zig: "0.15.2" }));
  assert.throws(() => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), root, env }), /Zig versionが不一致/);
  writeFileSync(join(outDir, "compiler-artifact.json"), JSON.stringify({ ...metadata, buildMode: "ReleaseSafe" }));
  assert.throws(() => verifyArtifact({ dir: outDir, installTo: join(work, "bin"), root, env }), /build構成が不一致/);
  rmSync(work, { recursive: true, force: true });
});
