// `tools/lib/package/cnako_package_loader.mjs` の単体テスト。
// fixture ハーネス（tools/compare_package_import_oracle.mjs）は同期済み環境の
// 主要経路をCIで担保するが、既定exportのフォールバック・alias衝突・規範path・
// 拡張子・`--no-sync` のlock照合など、fixtureから到達しない境界をここで固定する。
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createHash } from "node:crypto";
import test from "node:test";

import {
  PackageLoaderError,
  createResolver,
  normalizeExportPath,
  selectExportEntry,
  validateEnvironmentLock,
} from "./lib/package/cnako_package_loader.mjs";

function errorCode(callback) {
  try {
    callback();
  } catch (error) {
    assert.ok(error instanceof PackageLoaderError, `PackageLoaderError ではありません: ${error}`);
    return error.code;
  }
  assert.fail("エラーが発生しませんでした");
}

function makeTree(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cnako-loader-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function makePackage(root, directory, exports, dependencies) {
  const absolute = path.join(root, directory);
  fs.mkdirSync(path.join(absolute, "src"), { recursive: true });
  for (const entry of exports) {
    if (typeof entry?.path === "string") fs.writeFileSync(path.join(absolute, entry.path), "「module」と表示\n");
  }
  return { name: path.basename(directory), version: "1.0.0", path: directory, exports, dependencies };
}

function makeEnvironment(packages, dependencies = []) {
  return { schemaVersion: 1, lockSha256: `sha256:${"0".repeat(64)}`, profile: "default", runtime: "lnako", packages, dependencies };
}

test("既定exportはmain/index名→basename main.nako3/index.nako3→単一exportの順で選ぶ", () => {
  const byName = [{ name: "main", path: "src/main.nako3" }, { name: "other", path: "src/other.nako3" }];
  assert.equal(selectExportEntry(byName, null, "パッケージ:x").path, "src/main.nako3");

  const byBasename = [{ name: "alpha", path: "src/main.nako3" }, { name: "beta", path: "src/beta.nako3" }];
  assert.equal(selectExportEntry(byBasename, null, "パッケージ:x").path, "src/main.nako3");

  const single = [{ name: "alpha", path: "src/alpha.nako3" }];
  assert.equal(selectExportEntry(single, null, "パッケージ:x").path, "src/alpha.nako3");

  const ambiguous = [{ name: "main", path: "src/a.nako3" }, { name: "index", path: "src/b.nako3" }];
  assert.equal(errorCode(() => selectExportEntry(ambiguous, null, "パッケージ:x")), "E005_AMBIGUOUS_SELECTION");

  assert.equal(errorCode(() => selectExportEntry([], null, "パッケージ:x")), "E013_MISSING_PACKAGE");
});

test("subpathはexportのnameとaliasの両方で選び、非公開・重複を拒否する", () => {
  const exports = [
    { name: "main", path: "src/main.nako3" },
    { name: "extra", alias: "preview", path: "src/preview.nako3" },
    { name: "dup", path: "src/dup1.nako3" },
    { name: "dup", path: "src/dup2.nako3" },
  ];
  assert.equal(selectExportEntry(exports, "extra", "パッケージ:x/extra").path, "src/preview.nako3");
  assert.equal(selectExportEntry(exports, "preview", "パッケージ:x/preview").path, "src/preview.nako3");
  assert.equal(errorCode(() => selectExportEntry(exports, "private", "パッケージ:x/private")), "E013_MISSING_PACKAGE");
  assert.equal(errorCode(() => selectExportEntry(exports, "dup", "パッケージ:x/dup")), "E005_AMBIGUOUS_SELECTION");
});

test("export pathは規範pathとsource拡張子だけを受理する", () => {
  assert.equal(normalizeExportPath({ path: "src/main.nako3" }, "pkg:x"), "src/main.nako3");
  assert.equal(normalizeExportPath({ path: "src/main.NAKO3" }, "pkg:x"), "src/main.NAKO3");
  assert.equal(errorCode(() => normalizeExportPath({ path: "src/main.nako" }, "pkg:x")), "E031_UNSUPPORTED_RUNTIME");
  for (const invalid of ["../outside.nako3", "/abs/main.nako3", "src//main.nako3", "src/./main.nako3", "src\\main.nako3", "src/main.nako3/", "src/\u0001bad.nako3"]) {
    assert.equal(errorCode(() => normalizeExportPath({ path: invalid }, "pkg:x")), "E029_INVALID_VALUE", invalid);
  }
  assert.equal(errorCode(() => normalizeExportPath({ path: "src/main.js" }, "pkg:x")), "E031_UNSUPPORTED_RUNTIME");
  assert.equal(errorCode(() => normalizeExportPath({}, "pkg:x")), "E031_UNSUPPORTED_RUNTIME");
});

test("aliasは取り込み元のscopeで解決し、package scopeはroot aliasを継承しない", (t) => {
  const root = makeTree(t);
  const demo = makePackage(root, "env/demo", [{ name: "main", path: "src/main.nako3" }], [
    { alias: "util", package: "pkg:util" },
  ]);
  const util = makePackage(root, "env/util", [{ name: "main", path: "src/main.nako3" }], []);
  const environment = makeEnvironment(
    { "pkg:demo": demo, "pkg:util": util },
    [{ alias: "demo", package: "pkg:demo" }, { alias: "greet", package: "pkg:util" }],
  );
  const resolve = createResolver(environment, root);
  const demoEntry = path.join(root, "main.nako3");
  const demoSource = path.join(root, "env/demo/src/main.nako3");
  const utilSource = path.join(root, "env/util/src/main.nako3");

  assert.equal(resolve(demoEntry, "パッケージ:demo"), demoSource);
  assert.equal(resolve(demoEntry, "pkg:demo"), demoSource);
  assert.equal(resolve(demoEntry, "パッケージ:greet"), utilSource);
  // package scopeのdemoからroot aliasのgreetは見えない。
  assert.equal(errorCode(() => resolve(demoSource, "パッケージ:greet")), "E013_MISSING_PACKAGE");
  // demo自身のscopeはutilを解決できる。
  assert.equal(resolve(demoSource, "パッケージ:util"), utilSource);
  // package指定子でない取り込み（相対path等）は公式loaderへ委譲する（null）。
  assert.equal(resolve(utilSource, "./helper.nako3"), null);
});

test("最長aliasを選び、version指定・空namespace・alias衝突を環境不正として拒否する", (t) => {
  const root = makeTree(t);
  const lib = makePackage(root, "env/lib", [{ name: "main", path: "src/main.nako3" }], []);
  const scoped = makePackage(root, "env/scoped", [{ name: "main", path: "src/main.nako3" }], []);
  const environment = makeEnvironment(
    { "pkg:lib": lib, "pkg:scoped": scoped },
    [{ alias: "lib", package: "pkg:lib" }, { alias: "@scope/lib", package: "pkg:scoped" }],
  );
  const resolve = createResolver(environment, root);
  const entry = path.join(root, "main.nako3");
  assert.equal(resolve(entry, "パッケージ:@scope/lib"), path.join(root, "env", "scoped", "src", "main.nako3"));
  assert.equal(resolve(entry, "パッケージ:lib"), path.join(root, "env", "lib", "src", "main.nako3"));
  assert.equal(errorCode(() => resolve(entry, "パッケージ:lib@1.0.0")), "E013_MISSING_PACKAGE");
  // subpathは規範path（空成分・`.`・末尾`/`等を拒否）だけを受理する。
  assert.equal(errorCode(() => resolve(entry, "パッケージ:lib/")), "E013_MISSING_PACKAGE");
  assert.equal(errorCode(() => resolve(entry, "パッケージ:lib/a//b")), "E013_MISSING_PACKAGE");
  assert.equal(errorCode(() => resolve(entry, "パッケージ:lib/./a")), "E013_MISSING_PACKAGE");

  assert.equal(errorCode(() => createResolver(makeEnvironment({}, [{ alias: "", package: "pkg:lib" }]), root)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.equal(errorCode(() => createResolver(makeEnvironment({}, [{ alias: "@", package: "pkg:lib" }]), root)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  // 同一aliasが別packageを指す環境は不正。
  assert.equal(
    errorCode(() => createResolver(makeEnvironment({}, [{ alias: "lib", package: "pkg:lib" }, { alias: "lib", package: "pkg:other" }]), root)),
    "E034_INVALID_ENVIRONMENT_REFERENCE",
  );
  // 正規化後に同じ公開namespaceへ落ちる別aliasも不正。
  assert.equal(
    errorCode(() => createResolver(makeEnvironment({}, [{ alias: "my-util", package: "pkg:lib" }, { alias: "my_util", package: "pkg:scoped" }]), root)),
    "E034_INVALID_ENVIRONMENT_REFERENCE",
  );
  // 型不正なrecordはfail closed。
  assert.equal(errorCode(() => createResolver(makeEnvironment({}, [{ alias: 1, package: "pkg:lib" }]), root)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  // lnako はUTF-8バイト単位で非ASCIIを保持するため、astralとBMPの別aliasは
  // 正規化後も衝突しない（過剰拒否しない）。
  assert.doesNotThrow(() => createResolver(
    makeEnvironment({ "pkg:lib": lib, "pkg:scoped": scoped }, [
      { alias: "😀", package: "pkg:lib" },
      { alias: "あ", package: "pkg:scoped" },
    ]),
    root,
  ));
});

test("--no-syncの未信頼環境はroot外pathを許容し、managed pathのsymlink成分を拒否する", (t) => {
  const base = makeTree(t);
  const root = path.join(base, "project");
  fs.mkdirSync(root, { recursive: true });
  // root外（../outside）の宣言pathはlnakoが許容するため拒否しない。
  const outside = makePackage(base, "outside", [{ name: "main", path: "src/main.nako3" }], []);
  const outsideEnvironment = makeEnvironment({ "pkg:outside": { ...outside, path: "../outside" } }, [{ alias: "outside", package: "pkg:outside" }]);
  assert.doesNotThrow(() => createResolver(outsideEnvironment, root, { untrusted: true }));

  // 中間成分がsymlinkの環境は管理外（§7.3）として拒否する。
  const realEnv = makePackage(base, "real-env/demo", [{ name: "main", path: "src/main.nako3" }], []);
  try {
    fs.symlinkSync(path.join(base, "real-env"), path.join(root, "env-link"), "dir");
  } catch (error) {
    t.skip(`symlinkを作成できません: ${error.code}`);
    return;
  }
  const linkedEnvironment = makeEnvironment(
    { "pkg:linked": { ...realEnv, path: "env-link/demo" } },
    [{ alias: "linked", package: "pkg:linked" }],
  );
  assert.equal(errorCode(() => createResolver(linkedEnvironment, root, { untrusted: true })), "E034_INVALID_ENVIRONMENT_REFERENCE");
  // sync経路（信頼済み環境）ではlnakoの生成結果をそのまま使う。
  assert.doesNotThrow(() => createResolver(linkedEnvironment, root, { untrusted: false }));
});

test("environmentがobjectでpackagesを持つことを検証する", (t) => {
  const root = makeTree(t);
  assert.equal(errorCode(() => createResolver(null, root)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.equal(errorCode(() => createResolver({ ...makeEnvironment({}, []), packages: [] }, root)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.equal(errorCode(() => createResolver({ ...makeEnvironment({}, []), packages: null }, root)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.doesNotThrow(() => createResolver(makeEnvironment({}, []), root));
});

test("環境recordのexports形状を検証する", (t) => {
  const root = makeTree(t);
  const pkg = makePackage(root, "env/demo", [{ name: "main", path: "src/main.nako3" }], []);
  const resolveWith = (exports) => createResolver(
    makeEnvironment({ "pkg:demo": { ...pkg, exports } }, [{ alias: "demo", package: "pkg:demo" }]),
    root,
  );
  assert.equal(errorCode(() => resolveWith("not-array")), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.equal(errorCode(() => resolveWith([{ path: "src/main.nako3" }])), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.equal(errorCode(() => resolveWith([{ name: "main", alias: 1, path: "src/main.nako3" }])), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.equal(errorCode(() => resolveWith([{ name: "main", path: 1 }])), "E034_INVALID_ENVIRONMENT_REFERENCE");
});

test("symlinkでpackage境界の外を指すexportを拒否する", (t) => {
  const base = makeTree(t);
  const root = path.join(base, "project");
  const pkg = makePackage(root, "env/demo", [{ name: "main", path: "src/link.nako3" }], []);
  fs.writeFileSync(path.join(base, "secret.nako3"), "「SECRET」と表示\n");
  const link = path.join(root, "env/demo/src/link.nako3");
  fs.rmSync(link, { force: true });
  try {
    fs.symlinkSync("../../../../secret.nako3", link, "file");
  } catch (error) {
    t.skip(`symlinkを作成できません: ${error.code}`);
    return;
  }
  const resolve = createResolver(makeEnvironment({ "pkg:demo": pkg }, [{ alias: "demo", package: "pkg:demo" }]), root);
  assert.equal(errorCode(() => resolve(path.join(root, "main.nako3"), "パッケージ:demo")), "E029_INVALID_VALUE");
});

test("--no-syncのlockSha256照合と環境形状を検証する", (t) => {
  const root = makeTree(t);
  const lockPath = path.join(root, "nako.lock");
  const lockText = "{}\n";
  fs.writeFileSync(lockPath, lockText);
  const digest = createHash("sha256").update(Buffer.from(lockText)).digest("hex");
  const valid = { schemaVersion: 1, lockSha256: `sha256:${digest}`, profile: "default", runtime: "lnako", packages: {}, dependencies: [] };
  assert.doesNotThrow(() => validateEnvironmentLock(valid, lockPath));
  assert.equal(errorCode(() => validateEnvironmentLock({ ...valid, lockSha256: `sha256:${"0".repeat(64)}` }, lockPath)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.equal(errorCode(() => validateEnvironmentLock({ ...valid, schemaVersion: 2 }, lockPath)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.equal(errorCode(() => validateEnvironmentLock({ ...valid, profile: undefined }, lockPath)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.equal(errorCode(() => validateEnvironmentLock({ ...valid, runtime: undefined }, lockPath)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  assert.equal(errorCode(() => validateEnvironmentLock({ ...valid, runtime: "cnako" }, lockPath)), "E034_INVALID_ENVIRONMENT_REFERENCE");
  // §7.3 の3形式（raw hex / SRI）も受理する。
  assert.doesNotThrow(() => validateEnvironmentLock({ ...valid, lockSha256: digest }, lockPath));
  assert.doesNotThrow(() => validateEnvironmentLock({ ...valid, lockSha256: `sha256-${Buffer.from(digest, "hex").toString("base64")}` }, lockPath));
  assert.equal(errorCode(() => validateEnvironmentLock(valid, path.join(root, "missing.lock"))), "E034_INVALID_ENVIRONMENT_REFERENCE");
});
