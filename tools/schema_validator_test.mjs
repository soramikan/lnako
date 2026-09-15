import assert from "node:assert/strict";
import { test } from "node:test";

import { DiagnosticError, validateManifest, validateEnvironmentReference } from "./lib/package/schema_validator.mjs";
import { createHash } from "node:crypto";

// 深い feature 連鎖を含む manifest を構築する（feature 名は
// ^[a-z][a-z0-9-]+$ に合わせる）。cycle=true のとき末尾を先頭へ戻す。
function deepChainManifest(depth, cycle = false) {
  const features = {};
  for (let index = 0; index < depth; index += 1) {
    const name = `f-${index}`;
    features[name] = index + 1 < depth ? [`f-${index + 1}`] : (cycle ? ["f-0"] : []);
  }
  return { package: { name: "deep", version: "1.0.0", license: "MIT" }, features };
}

test("深いfeature連鎖を反復DFSで検査する", () => {
  // 再帰実装だとネイティブスタックを枯渇させる深さでも受理されること。
  validateManifest(deepChainManifest(20000), "deep-chain.toml");
});

test("深いfeature連鎖の末尾循環を検出する", () => {
  assert.throws(
    () => validateManifest(deepChainManifest(20000, true), "deep-cycle.toml"),
    (error) => error instanceof DiagnosticError && error.code === "E027_FEATURE_CYCLE",
  );
});

// コロンを含む license 識別子は DocumentRef-<id>:LicenseRef-<id> 複合形のみ
// 許容する（Zig 側 isLicenseId と同一判定）。
function licenseManifest(license) {
  return { package: { name: "a", version: "1.0.0", license } };
}

test("license識別子のコロンはDocumentRef複合形のみ許容する", () => {
  for (const license of [
    "MIT",
    "MIT OR Apache-2.0",
    "(MIT OR Apache-2.0) AND GPL-3.0-only",
    "GPL-2.0+",
    "GPL-3.0-only WITH Classpath-exception-2.0",
    "LicenseRef-FOO",
    "DocumentRef-doc:LicenseRef-FOO",
    "DocumentRef-x",
    "UNLICENSED",
    "Proprietary",
  ]) {
    validateManifest(licenseManifest(license), "ok.toml");
  }
  for (const license of [
    "MIT:Foo",
    "a:b:c",
    "DocumentRef-:LicenseRef-x",
    "DocumentRef-a:LicenseRef-",
    "DocumentRef-a:MIT",
    "Foo:LicenseRef-x",
    "DocumentRef-a:LicenseRef-b:c",
    "LicenseRef-x+",
    "LicenseRef-",
    "DocumentRef-",
    "DocumentRef-a:LicenseRef-b+",
    "+",
    "+X",
    "AND+",
    "WITH+",
    "MIT WITH A:B",
    "MIT WITH Foo+",
    "MIT WITH DocumentRef-a:LicenseRef-b",
  ]) {
    assert.throws(
      () => validateManifest(licenseManifest(license), "bad.toml"),
      (error) => error instanceof DiagnosticError && error.code === "E029_INVALID_VALUE",
      `license "${license}" must be rejected`,
    );
  }
});

// 環境参照の lockSha256 は SRI / `sha256:` hex / 生 hex の各表記を
// 正規化して実 lock のダイジェストと比較する。
function environmentReferenceFixture(digestText) {
  return {
    schemaVersion: 1,
    lockSha256: digestText,
    profile: "default",
    runtime: "cnako",
    packages: {},
  };
}

test("環境参照のlockSha256を各表記で一致検証する", () => {
  const lockBytes = Buffer.from('{"schemaVersion":1}\n', "utf8");
  const hex = createHash("sha256").update(lockBytes).digest("hex");
  const sri = `sha256-${createHash("sha256").update(lockBytes).digest("base64")}`;
  for (const digestText of [hex, `sha256:${hex}`, sri]) {
    validateEnvironmentReference(environmentReferenceFixture(digestText), lockBytes, "environment.json");
  }
});

test("環境参照のlockSha256不一致をE034で拒否する", () => {
  const lockBytes = Buffer.from('{"schemaVersion":1}\n', "utf8");
  assert.throws(
    () => validateEnvironmentReference(environmentReferenceFixture("0".repeat(64)), lockBytes, "environment.json"),
    (error) => error instanceof DiagnosticError && error.code === "E034_INVALID_ENVIRONMENT_REFERENCE",
  );
});

test("環境参照のlockSha256がSHA-512ならE034で拒否する", () => {
  const lockBytes = Buffer.from('{"schemaVersion":1}\n', "utf8");
  const sha512 = `sha512-${createHash("sha512").update(lockBytes).digest("base64")}`;
  assert.throws(
    () => validateEnvironmentReference(environmentReferenceFixture(sha512), lockBytes, "environment.json"),
    (error) => error instanceof DiagnosticError && error.code === "E034_INVALID_ENVIRONMENT_REFERENCE",
  );
});
