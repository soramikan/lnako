import { createHash } from "node:crypto";
import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const source = resolve(root, "compat/v3.7.24/attestations/32983175945");
const temporary = await mkdtemp(join(tmpdir(), "lnako-tracked-attestation-"));
try {
  await cp(source, temporary, { recursive: true });
  const manifestPath = join(temporary, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.targetCommit = "0".repeat(40);
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  const result = spawnSync(process.execPath, [resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "--directory", temporary], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes("target commitが不正です")) {
    throw new Error(`対象commitの改変を拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  console.log("追跡dispatch attestation安全性検査: manifestの対象commit改変を拒否");
} finally {
  await rm(temporary, { recursive: true, force: true });
}

const catalogTemporary = await mkdtemp(join(tmpdir(), "lnako-tracked-catalog-"));
try {
  await cp(source, catalogTemporary, { recursive: true });
  const catalogPath = join(catalogTemporary, "catalog-evidence-verified.json");
  const catalog = JSON.parse(await readFile(catalogPath, "utf8"));
  catalog.entries[0].reason = "改変されたcatalog evidence";
  const catalogBytes = `${JSON.stringify(catalog, null, 2)}\n`;
  await writeFile(catalogPath, catalogBytes);
  const manifestPath = join(catalogTemporary, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.artifactSha256["catalog-evidence-verified.json"] = createHash("sha256").update(catalogBytes).digest("hex");
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  const result = spawnSync(process.execPath, [resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "--directory", catalogTemporary, "--offline"], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes("historical catalog evidenceがbase catalogと署名dispatchから導出できません")) {
    throw new Error(`catalog entryの改変を拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  console.log("追跡dispatch attestation安全性検査: catalog entry改変を拒否");
} finally {
  await rm(catalogTemporary, { recursive: true, force: true });
}

const bundleTemporary = await mkdtemp(join(tmpdir(), "lnako-tracked-bundle-"));
try {
  await cp(source, bundleTemporary, { recursive: true });
  const bundlePath = join(bundleTemporary, "sigstore-bundle.json");
  const bundle = JSON.parse(await readFile(bundlePath, "utf8"));
  bundle.dsseEnvelope.signatures[0].sig = Buffer.from("forged-signature").toString("base64");
  const bundleBytes = `${JSON.stringify(bundle, null, 2)}\n`;
  await writeFile(bundlePath, bundleBytes);
  const attestationPath = join(bundleTemporary, "dispatch-attestation.json");
  const attestation = JSON.parse(await readFile(attestationPath, "utf8"));
  attestation.bundleSha256 = createHash("sha256").update(bundleBytes).digest("hex");
  const attestationBytes = `${JSON.stringify(attestation, null, 2)}\n`;
  await writeFile(attestationPath, attestationBytes);
  const manifestPath = join(bundleTemporary, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.artifactSha256["sigstore-bundle.json"] = attestation.bundleSha256;
  manifest.artifactSha256["dispatch-attestation.json"] = createHash("sha256").update(attestationBytes).digest("hex");
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  const result = spawnSync(process.execPath, [resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "--directory", bundleTemporary], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes("公式gh attestation verifyに失敗しました")) {
    throw new Error(`署名改変bundleを拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  console.log("追跡dispatch attestation安全性検査: bundle改変後に公式gh検証が非成功になることを確認");
} finally {
  await rm(bundleTemporary, { recursive: true, force: true });
}

const stateTemporary = await mkdtemp(join(tmpdir(), "lnako-tracked-state-"));
try {
  await cp(source, stateTemporary, { recursive: true });
  const basePath = join(stateTemporary, "catalog-evidence-unattested.json");
  const base = JSON.parse(await readFile(basePath, "utf8"));
  base.entries[0].executionEvidenceState = "trace-confirmed-unattested";
  const baseDisplaced = base.entries.find((entry) => entry.id === "command-0141");
  baseDisplaced.executionEvidenceState = "unverified";
  baseDisplaced.executionEvidence = null;
  base.executionEvidenceStates = { verified: 0, "trace-confirmed-unattested": 4, unverified: 523 };
  const baseBytes = `${JSON.stringify(base, null, 2)}\n`;
  await writeFile(basePath, baseBytes);
  const historicalPath = join(stateTemporary, "catalog-evidence-verified.json");
  const historical = JSON.parse(await readFile(historicalPath, "utf8"));
  historical.entries[0].executionEvidenceState = "verified";
  historical.entries[0].executionEvidence = null;
  const displaced = historical.entries.find((entry) => entry.id === "command-0141");
  displaced.executionEvidenceState = "unverified";
  displaced.executionEvidence = null;
  const historicalBytes = `${JSON.stringify(historical, null, 2)}\n`;
  await writeFile(historicalPath, historicalBytes);
  const manifestPath = join(stateTemporary, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.artifactSha256["catalog-evidence-unattested.json"] = createHash("sha256").update(baseBytes).digest("hex");
  manifest.artifactSha256["catalog-evidence-verified.json"] = createHash("sha256").update(historicalBytes).digest("hex");
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  const result = spawnSync(process.execPath, [resolve(root, "tools/check_tracked_dispatch_attestation.mjs"), "--directory", stateTemporary, "--offline"], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes("base catalogのdispatch stateが不一致です")) {
    throw new Error(`非dispatch entryのstate改変を拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  console.log("追跡dispatch attestation安全性検査: 非dispatch entryのverified改変を拒否");
} finally {
  await rm(stateTemporary, { recursive: true, force: true });
}

const historicalTemporary = await mkdtemp(join(tmpdir(), "lnako-historical-commit-"));
try {
  const dispatchPath = resolve(source, "dispatch/dispatch-evidence-macos-15.json");
  const missingOutput = spawnSync(process.execPath, [
    resolve(root, "tools/sync_compat_evidence.mjs"),
    "--generate",
    "--dispatch-evidence", dispatchPath,
    "--historical-commit", "1ee47232d34711abaddb28038218258232ac3800",
  ], { cwd: root, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 });
  if (missingOutput.status === 0 || !`${missingOutput.stdout}\n${missingOutput.stderr}`.includes("--historical-commitでは--dispatch-evidenceと明示的な非canonical --outputが必須です")) {
    throw new Error(`historical modeのoutput省略を拒否しませんでした: ${JSON.stringify({ status: missingOutput.status, stdout: missingOutput.stdout, stderr: missingOutput.stderr })}`);
  }
  const canonicalOutput = spawnSync(process.execPath, [
    resolve(root, "tools/sync_compat_evidence.mjs"),
    "--generate",
    "--dispatch-evidence", dispatchPath,
    "--historical-commit", "1ee47232d34711abaddb28038218258232ac3800",
    "--output", resolve(root, "compat/v3.7.24/evidence.json"),
  ], { cwd: root, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 });
  if (canonicalOutput.status === 0 || !`${canonicalOutput.stdout}\n${canonicalOutput.stderr}`.includes("--historical-commitでは--dispatch-evidenceと明示的な非canonical --outputが必須です")) {
    throw new Error(`historical modeのcanonical outputを拒否しませんでした: ${JSON.stringify({ status: canonicalOutput.status, stdout: canonicalOutput.stdout, stderr: canonicalOutput.stderr })}`);
  }
  const outputPath = join(historicalTemporary, "evidence.json");
  const result = spawnSync(process.execPath, [
    resolve(root, "tools/sync_compat_evidence.mjs"),
    "--generate",
    "--dispatch-evidence", dispatchPath,
    "--historical-commit", "0".repeat(40),
    "--output", outputPath,
  ], { cwd: root, encoding: "utf8", maxBuffer: 2 * 1024 * 1024 });
  if (result.status === 0 || !`${result.stdout}\n${result.stderr}`.includes("--historical-commitとdispatch証拠のcommitが一致しません")) {
    throw new Error(`誤ったhistorical commitを拒否しませんでした: ${JSON.stringify({ status: result.status, stdout: result.stdout, stderr: result.stderr })}`);
  }
  console.log("tracked dispatch attestation安全性検査: 誤ったhistorical commitを拒否");
} finally {
  await rm(historicalTemporary, { recursive: true, force: true });
}
