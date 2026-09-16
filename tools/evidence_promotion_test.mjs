import assert from "node:assert/strict";
import { test } from "node:test";
import { deriveVerifiedCatalog, proofKeyForEvidenceDocument } from "./lib/evidence/promotion.mjs";

const unattestedReason = "一意な命令名からcatalog IDを解決した。 明示catalog ID・site IDについて、同一fixtureのInterpreter/AOT trace、compile manifest、公式差分の成功を機械検証した（2 site）。外部attestation未導入のためexecutionEvidenceState=trace-confirmed-unattestedであり、verifiedへは昇格しない。";
const verifiedReason = "一意な命令名からcatalog IDを解決した。 明示catalog ID・site IDについて、同一fixtureのInterpreter/AOT trace、compile manifest、公式差分の成功を機械検証したと外部attestationを機械検証した（2 site）。executionEvidenceState=verified。";

const entry = (id, schema, fixtureId) => ({
  id,
  name: `命令${id}`,
  executionEvidenceState: "trace-confirmed-unattested",
  executionEvidence: {
    proofSchema: schema,
    fixtureId,
    siteIds: ["0x1", "0x2"],
    officialComparison: ["officialSource"],
    state: "trace-confirmed-unattested",
  },
  reason: unattestedReason,
});

const catalog = (entries) => ({
  schemaVersion: 2,
  commandCount: entries.length,
  executionEvidenceStates: { verified: 0, "trace-confirmed-unattested": entries.length, unverified: 0 },
  entries,
});

test("proofKeyForEvidenceDocument は fixture.id を使い、fixture を持たない証拠は合成IDを使う", () => {
  assert.equal(proofKeyForEvidenceDocument({ schema: "lnako.dispatch-evidence.v9", fixture: { id: "native-dispatch-commands" } }), "lnako.dispatch-evidence.v9|native-dispatch-commands");
  assert.equal(proofKeyForEvidenceDocument({ schema: "lnako.dispatch-coverage.v1" }), "lnako.dispatch-coverage.v1|dispatch-coverage");
  assert.equal(proofKeyForEvidenceDocument({ schema: "lnako.compat-js-evidence.v1" }), "lnako.compat-js-evidence.v1|compat-js-evidence");
  assert.equal(proofKeyForEvidenceDocument({ schema: "lnako.static-constant-evidence.v1" }), null);
});

test("deriveVerifiedCatalog は署名digestを持つ証拠のentryのみverifiedへ昇格する", () => {
  const base = catalog([
    entry("c1", "lnako.dispatch-evidence.v9", "native-dispatch-commands"),
    entry("c2", "lnako.static-constant-evidence.v1", "native-static-a"),
    { id: "c3", name: "命令c3", executionEvidenceState: "unverified", executionEvidence: null, reason: "catalog IDに対する実行dispatch接続はまだ追跡していない。" },
  ]);
  const backing = new Map([
    ["lnako.dispatch-evidence.v9|native-dispatch-commands", "aaa"],
    ["lnako.static-constant-evidence.v1|native-static-a", "bbb"],
  ]);
  const derived = deriveVerifiedCatalog(base, new Set(["aaa"]), backing);
  assert.equal(derived.entries[0].executionEvidenceState, "verified");
  assert.equal(derived.entries[0].executionEvidence.state, "verified");
  assert.equal(derived.entries[0].reason, verifiedReason);
  assert.equal(derived.entries[1].executionEvidenceState, "trace-confirmed-unattested");
  assert.equal(derived.entries[1].reason, unattestedReason);
  assert.equal(derived.entries[2].executionEvidenceState, "unverified");
  assert.deepEqual(derived.executionEvidenceStates, { verified: 1, "trace-confirmed-unattested": 1, unverified: 1 });
  assert.equal(base.entries[0].executionEvidenceState, "trace-confirmed-unattested");
});

test("deriveVerifiedCatalog はproof key未知・digest未署名のentryを昇格しない", () => {
  const base = catalog([entry("c1", "lnako.dispatch-evidence.v9", "native-dispatch-commands")]);
  const unknownProof = deriveVerifiedCatalog(base, new Set(["aaa"]), new Map());
  assert.equal(unknownProof.entries[0].executionEvidenceState, "trace-confirmed-unattested");
  const unsigned = deriveVerifiedCatalog(base, new Set(["other"]), new Map([["lnako.dispatch-evidence.v9|native-dispatch-commands", "aaa"]]));
  assert.equal(unsigned.entries[0].executionEvidenceState, "trace-confirmed-unattested");
});

test("deriveVerifiedCatalog は全件昇格時にverified 527相当の集計を再計算する", () => {
  const base = catalog([entry("c1", "lnako.dispatch-evidence.v9", "native-dispatch-commands"), entry("c2", "lnako.dispatch-evidence.v9", "native-dispatch-commands")]);
  const derived = deriveVerifiedCatalog(base, new Set(["aaa"]), new Map([["lnako.dispatch-evidence.v9|native-dispatch-commands", "aaa"]]));
  assert.deepEqual(derived.executionEvidenceStates, { verified: 2, "trace-confirmed-unattested": 0, unverified: 0 });
});

test("deriveVerifiedCatalog は昇格できないreason形式を拒否する", () => {
  const broken = entry("c1", "lnako.dispatch-evidence.v9", "native-dispatch-commands");
  broken.reason = "想定外のreason";
  const backing = new Map([["lnako.dispatch-evidence.v9|native-dispatch-commands", "aaa"]]);
  assert.throws(() => deriveVerifiedCatalog(catalog([broken]), new Set(["aaa"]), backing), /reason変換が不正/);
});
