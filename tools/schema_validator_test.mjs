import assert from "node:assert/strict";
import { test } from "node:test";

import { DiagnosticError, validateManifest } from "./lib/package/schema_validator.mjs";

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
