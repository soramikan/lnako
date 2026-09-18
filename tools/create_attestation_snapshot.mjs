import { createHash } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { readdirSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { computeSourceManifestSha256Sync } from "./lib/evidence/manifest.mjs";
import { canonicalAttestationSchemaV2, dispatchAttestationSchemaV3, trackedAttestationSubjects } from "./lib/evidence/attested_files.mjs";
import { sourceManifestDeclarationBasename, validateSourceManifestDeclarationBytes } from "./lib/evidence/source_manifest.mjs";

const root = resolve(fileURLToPath(import.meta.url), "..", "..");

function sha256(input) {
  return createHash("sha256").update(input).digest("hex");
}

function sha256FileSync(path) {
  return sha256(readFileSync(path));
}

function run(label, command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: root, encoding: "utf8", ...options });
  if (result.error) throw new Error(`${label} の起動に失敗しました: ${result.error.message}`);
  if (result.status !== 0) {
    const signal = result.signal === null ? "" : ` signal=${result.signal}`;
    throw new Error(`${label} が失敗しました: status=${result.status}${signal}\n${result.stderr ?? ""}`);
  }
  return result;
}

export function snapshotManifestGitPath(runId) {
  return `compat/v3.7.24/attestations/${runId}/manifest.json`;
}

function currentGitCommit() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  if (result.error || result.status !== 0) throw new Error("現行commitを取得できません");
  const value = result.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(value)) throw new Error("現行commit形式が不正です");
  return value;
}

export function parseArguments(args = process.argv.slice(2)) {
  if (args.includes("--help") || args.includes("-h")) {
    console.log(`usage: node tools/create_attestation_snapshot.mjs --run-id <id> [options]

成功したmain CI run (attest-dispatch-evidence job含む) からartifactを取得し、
compat/v3.7.24/attestations/<run>/ へオフライン検査用のsnapshotをローカル生成します。
git commit / ブランチpush / PR作成はしません。現行のverified判定はGitHub Attestationsです。

options:
  --run-id <id>              必須。GitHub Actions workflow run ID。
  --repo <owner/repo>        既定 soramikan/lnako。
  --workflow <workflow>      既定 soramikan/lnako/.github/workflows/ci.yml。
  --commit <sha>             run対象commit。未指定時はgh run viewで取得。
  --attempt <number>         run attempt。未指定時はgh run viewで取得。
  --output-dir <abs-path>    snapshot出力先。未指定時は compat/v3.7.24/attestations/<run-id>。
  --no-verify                生成後のsync/checkを実行しません。
`);
    process.exit(0);
  }
  if (args.includes("--no-pr") || args.includes("--no-push") || args.includes("--branch") || args.includes("--ref")) {
    throw new Error("git commit / ブランチpush / PR作成は廃止しました。このtoolはローカル生成のみです");
  }

  function valueFor(name) {
    const index = args.indexOf(name);
    if (index < 0) return null;
    const value = args[index + 1];
    if (value === undefined || value.startsWith("--")) throw new Error(`${name}の値がありません`);
    return value;
  }

  function absoluteFor(name) {
    const value = valueFor(name);
    if (value === null) return null;
    if (!isAbsolute(value)) throw new Error(`${name}には絶対パスを指定してください`);
    return resolve(value);
  }

  const runId = valueFor("--run-id");
  if (!runId || !/^\d+$/.test(runId)) throw new Error("--run-idは数値workflow run IDを指定してください");

  return {
    runId,
    repo: valueFor("--repo") ?? "soramikan/lnako",
    workflow: valueFor("--workflow") ?? "soramikan/lnako/.github/workflows/ci.yml",
    commit: valueFor("--commit"),
    attempt: valueFor("--attempt"),
    outputDirectory: absoluteFor("--output-dir"),
    noVerify: args.includes("--no-verify"),
  };
}

async function fetchRunMetadata(runId, repo) {
  const result = run("gh run view", "gh", [
    "run", "view", runId,
    "--repo", repo,
    "--json", "headSha,attempt,conclusion,headBranch,workflowName",
  ]);
  const info = JSON.parse(result.stdout);
  if (info.conclusion !== "success") {
    throw new Error(`run ${runId} は成功していません: ${info.conclusion}`);
  }
  if (info.headBranch !== "main") {
    throw new Error(`run ${runId} は main branch のものではありません: ${info.headBranch}`);
  }
  if (info.workflowName !== "CI") {
    throw new Error(`run ${runId} は CI workflow ではありません: ${info.workflowName}`);
  }
  return {
    commit: info.headSha,
    attempt: String(info.attempt),
  };
}

async function downloadArtifact(runId, repo, name, directory) {
  await mkdir(directory, { recursive: true });
  run(`download artifact ${name}`, "gh", ["run", "download", runId, "--repo", repo, "--name", name, "--dir", directory]);
}

async function findSingleFile(dir) {
  const allFiles = listFilesSync(dir);
  if (allFiles.length !== 1) {
    throw new Error(`${dir} に想定外のファイル数があります: ${allFiles.length}`);
  }
  return allFiles[0];
}

function listFilesSync(dir) {
  const files = [];
  const walk = (base) => {
    for (const entry of readdirSync(base, { withFileTypes: true })) {
      const full = resolve(base, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile()) files.push(full);
    }
  };
  walk(dir);
  return files;
}

async function isSigstoreBundle(path) {
  try {
    const text = await readFile(path, "utf8");
    const json = JSON.parse(text);
    return typeof json?.mediaType === "string" && json.mediaType.includes("sigstore");
  } catch {
    return false;
  }
}

const dispatchEvidenceMapping = [
  { artifact: "lnako-dispatch-evidence-macos-15", runner: "macos-15", platform: "darwin", arch: "arm64" },
  { artifact: "lnako-dispatch-evidence-ubuntu-24.04", runner: "ubuntu-24.04", platform: "linux", arch: "x64" },
  { artifact: "lnako-dispatch-evidence-windows-2025", runner: "windows-2025", platform: "win32", arch: "x64" },
];

const snapshotFiles = {
  dispatchAttestation: "dispatch-attestation.json",
  nativeAotAttestation: "native-aot-attestation.json",
  catalogEvidence: "catalog-evidence-verified.json",
  nativeAotAggregate: "native-aot-aggregate-evidence.json",
  sourceManifest: "source-manifest.json",
  bundle: "sigstore-bundle.json",
};

async function main() {
  const options = parseArguments();

  const gitHead = currentGitCommit();
  let targetCommit = options.commit;
  let attempt = options.attempt;

  if (!targetCommit || !attempt) {
    const metadata = await fetchRunMetadata(options.runId, options.repo);
    targetCommit = targetCommit ?? metadata.commit;
    attempt = attempt ?? metadata.attempt;
  }

  if (gitHead !== targetCommit) {
    throw new Error(`現行HEAD ${gitHead} がrun対象commit ${targetCommit} と一致しません。mainの最新commitで実行してください。`);
  }

  const sourceManifest = computeSourceManifestSha256Sync(root);
  const outputDirectory = options.outputDirectory ?? resolve(root, "compat", "v3.7.24", "attestations", options.runId);
  const dispatchDirectory = resolve(outputDirectory, "dispatch");

  await rm(outputDirectory, { recursive: true, force: true });
  await mkdir(dispatchDirectory, { recursive: true });

  const tempRoot = await mkdtemp(join(tmpdir(), "lnako-attestation-"));
  try {
    const tempCatalog = resolve(tempRoot, "catalog");
    const tempAot = resolve(tempRoot, "aot");
    const tempDispatch = resolve(tempRoot, "dispatch");

    await downloadArtifact(options.runId, options.repo, "lnako-catalog-evidence-verified", tempCatalog);
    await downloadArtifact(options.runId, options.repo, "lnako-native-aot-aggregate", tempAot);

    for (const mapping of dispatchEvidenceMapping) {
      const artifactDir = resolve(tempDispatch, mapping.artifact);
      await downloadArtifact(options.runId, options.repo, mapping.artifact, artifactDir);
      const source = await findSingleFile(artifactDir);
      const target = resolve(dispatchDirectory, `dispatch-evidence-${mapping.runner}.json`);
      await cp(source, target);
    }

    const catalogFiles = listFilesSync(tempCatalog);
    const files = new Map();
    for (const path of catalogFiles) {
      if (await isSigstoreBundle(path)) {
        files.set("bundle", path);
      } else {
        const name = path.split("/").pop();
        if (name === "dispatch-attestation.json") files.set("dispatchAttestation", path);
        else if (name === "native-aot-attestation.json") files.set("nativeAotAttestation", path);
        else if (name === "catalog-evidence-verified.json") files.set("catalogEvidence", path);
        else if (name === sourceManifestDeclarationBasename) files.set("sourceManifest", path);
      }
    }
    if (!files.has("bundle")) throw new Error("catalog artifactにsigstore bundleが見つかりません");
    if (!files.has("dispatchAttestation")) throw new Error("catalog artifactにdispatch-attestation.jsonがありません");
    if (!files.has("nativeAotAttestation")) throw new Error("catalog artifactにnative-aot-attestation.jsonがありません");
    if (!files.has("catalogEvidence")) throw new Error("catalog artifactにcatalog-evidence-verified.jsonがありません");
    if (!files.has("sourceManifest")) throw new Error(`catalog artifactに${sourceManifestDeclarationBasename}がありません`);

    const aotFiles = listFilesSync(tempAot);
    const aotAggregateSource = aotFiles.find((path) => path.endsWith("native-aot-aggregate-evidence.json"));
    if (!aotAggregateSource) throw new Error("native AOT aggregate artifactに集約証拠ファイルがありません");
    files.set("nativeAotAggregate", aotAggregateSource);

    const artifactSha256 = {};
    for (const [key, source] of files) {
      const target = resolve(outputDirectory, snapshotFiles[key]);
      await cp(source, target);
      artifactSha256[snapshotFiles[key]] = sha256FileSync(target);
    }

    // source manifest宣言は対象commit・現行manifest値とbyte一致し、そのdigestが
    // dispatch attestation (v3) の記録と一致しなければならない。
    const declarationBytes = await readFile(resolve(outputDirectory, snapshotFiles.sourceManifest));
    validateSourceManifestDeclarationBytes(declarationBytes, targetCommit, sourceManifest.sha256);
    const declarationSha256 = sha256(declarationBytes);
    const dispatchAttestation = JSON.parse(await readFile(resolve(outputDirectory, snapshotFiles.dispatchAttestation), "utf8"));
    if (dispatchAttestation.schema !== dispatchAttestationSchemaV3 ||
        dispatchAttestation.sourceManifest?.name !== sourceManifestDeclarationBasename ||
        dispatchAttestation.sourceManifest?.sha256 !== declarationSha256) {
      throw new Error("dispatch attestationのsource manifest宣言記録がsnapshotの宣言と一致しません");
    }

    const dispatchEvidence = [];
    for (const mapping of dispatchEvidenceMapping) {
      const path = `dispatch/dispatch-evidence-${mapping.runner}.json`;
      const fullPath = resolve(outputDirectory, path);
      const digest = sha256FileSync(fullPath);
      const evidence = JSON.parse(await readFile(fullPath, "utf8"));
      if (evidence.provenance?.environment?.platform !== mapping.platform || evidence.provenance?.environment?.arch !== mapping.arch) {
        throw new Error(`dispatch証拠のplatformが一致しません: ${path}`);
      }
      dispatchEvidence.push({
        platform: mapping.platform,
        arch: mapping.arch,
        runner: mapping.runner,
        path,
        sha256: digest,
      });
    }

    const trackedEvidence = [];
    for (const relativePath of trackedAttestationSubjects) {
      const fullPath = resolve(root, relativePath);
      const digest = sha256FileSync(fullPath);
      trackedEvidence.push({ path: relativePath, sha256: digest });
    }

    const manifest = {
      schema: canonicalAttestationSchemaV2,
      workflowRun: options.runId,
      workflowAttempt: Number(attempt),
      targetCommit,
      sourceRef: "refs/heads/main",
      workflow: options.workflow,
      sourceManifestSha256: sourceManifest.sha256,
      sourceManifest: "source-manifest.json",
      attestation: "dispatch-attestation.json",
      bundle: "sigstore-bundle.json",
      nativeAotAttestation: "native-aot-attestation.json",
      nativeAotAggregate: "native-aot-aggregate-evidence.json",
      catalogEvidence: "catalog-evidence-verified.json",
      dispatchEvidence,
      trackedEvidence,
      artifactSha256,
    };
    await writeFile(resolve(outputDirectory, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);

    run("sync compat evidence", "node", [resolve(root, "tools", "sync_compat_evidence.mjs"), "--generate"]);

    if (!options.noVerify) {
      // カスタム出力先は dirname === workflowRun の走査規則外になり得るため、
      // 作成したディレクトリを直接検証する。docs表は canonical unattested のままにする。
      run("check tracked dispatch attestation", "node", [resolve(root, "tools", "check_tracked_dispatch_attestation.mjs"), "--offline", "--require-current", "--snapshot", outputDirectory]);
      run("sync compat evidence --check", "node", [resolve(root, "tools", "sync_compat_evidence.mjs"), "--check"]);
    }
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }

  console.log(`attestation snapshotをローカル生成しました: ${outputDirectory}`);
  console.log("git commit / ブランチpush / PR作成はしません。現行のverified判定はGitHub Attestationsです。");
}

function isDirectRun() {
  const entry = process.argv[1];
  if (!entry) return false;
  return resolve(fileURLToPath(import.meta.url)) === resolve(entry);
}

if (isDirectRun()) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
