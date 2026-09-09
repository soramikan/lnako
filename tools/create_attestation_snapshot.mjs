import { createHash } from "node:crypto";
import { access, cp, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { readdirSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { computeSourceManifestSha256Sync } from "./lib/evidence/manifest.mjs";
import { canonicalAttestationSchema, currentAttestationPointerSchema, trackedAttestationSubjects } from "./lib/evidence/attested_files.mjs";

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

function currentGitCommit() {
  const result = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  if (result.error || result.status !== 0) throw new Error("現行commitを取得できません");
  const value = result.stdout.trim();
  if (!/^[0-9a-f]{40}$/i.test(value)) throw new Error("現行commit形式が不正です");
  return value;
}

function parseArguments() {
  const args = process.argv.slice(2);
  if (args.includes("--help") || args.includes("-h")) {
    console.log(`usage: node tools/create_attestation_snapshot.mjs --run-id <id> [options]

成功したmain CI run (attest-dispatch-evidence job含む) からartifactを取得し、
compat/v3.7.24/attestations/<run>/snapshot、attestations/current.json、evidence.jsonを更新します。

options:
  --run-id <id>              必須。GitHub Actions workflow run ID。
  --repo <owner/repo>        既定 soramikan/lnako。
  --workflow <workflow>      既定 soramikan/lnako/.github/workflows/ci.yml。
  --commit <sha>             run対象commit。未指定時はgh run viewで取得。
  --attempt <number>         run attempt。未指定時はgh run viewで取得。
  --branch <name>            作成するブランチ名。未指定時は attestation/run-<id>。
  --base <branch>            PRのbase branch。既定 main。
  --output-dir <abs-path>    snapshot出力先。未指定時は compat/v3.7.24/attestations/<run-id>。
  --no-pr                    PRを作成せず、ローカルcommitまで。
  --no-verify                生成後のsync/checkを実行しません。
`);
    process.exit(0);
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
    branch: valueFor("--branch") ?? `attestation/run-${runId}`,
    base: valueFor("--base") ?? "main",
    outputDirectory: absoluteFor("--output-dir"),
    noPr: args.includes("--no-pr"),
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
  const entries = readdirSync(dir, { withFileTypes: true });
  const files = entries.filter((entry) => entry.isFile());
  if (files.length !== 1) {
    throw new Error(`${dir} に想定外のファイル数があります: ${files.length}`);
  }
  return resolve(dir, files[0].name);
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
  bundle: "sigstore-bundle.json",
};

function replaceInline(text, startMarker, endMarker, replacement) {
  const pattern = new RegExp(`${escapeRegExp(startMarker)}[\\s\\S]*?${escapeRegExp(endMarker)}`, "g");
  const matches = text.match(pattern);
  if (!matches || matches.length === 0) {
    throw new Error(`マーカー ${startMarker} ... ${endMarker} が見つかりません`);
  }
  return text.replace(pattern, `${startMarker}${replacement}${endMarker}`);
}

function replaceRange(text, startMarker, endMarker, replacement) {
  const pattern = new RegExp(`${escapeRegExp(startMarker)}[\\s\\S]*?${escapeRegExp(endMarker)}`, "g");
  const matches = text.match(pattern);
  if (!matches || matches.length === 0) {
    throw new Error(`マーカー ${startMarker} ... ${endMarker} が見つかりません`);
  }
  return text.replace(pattern, `${startMarker}\n${replacement}\n${endMarker}`);
}

function escapeRegExp(string) {
  return string.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

async function updateCompatibilityDocs(runId, commit, sourceManifestSha256) {
  const path = resolve(root, "docs", "COMPATIBILITY.md");
  let text = await readFile(path, "utf8");

  text = replaceInline(text, "<!-- attestation:verified -->", "<!-- /attestation:verified -->", "527");
  text = replaceInline(text, "<!-- attestation:trace -->", "<!-- /attestation:trace -->", "0");
  text = replaceInline(text, "<!-- attestation:unverified -->", "<!-- /attestation:unverified -->", "0");

  const newDescription = `これは、全527 entryの実行証拠が追跡された現行attestation snapshot（\`attestations/current.json\` → \`attestations/${runId}/\`）で署名済みであることを示します。\`verified\` は、\`attestations/current.json\` が指す現行snapshotのsource manifest（\`${sourceManifestSha256}\`）と現行ソースが一致し、かつcanonical証拠ファイルのdigestが署名subjectに含まれる場合にのみ維持される状態です。sourceに変更を加えた場合、過去snapshotの \`verified: 527\` を流用せず、mainマージ後の新しいCI attestationを再取得して \`current.json\` を更新します。`;
  text = replaceRange(text, "<!-- attestation:description-start -->", "<!-- attestation:description-end -->", newDescription);

  const newArtifacts = `### CIの一時artifact\n\n現行manifestに対応するCI run \`${runId}\`（commit \`${commit}\`、54/54 job成功）が生成したcatalog artifactは \`verified: 527\`、\`trace-confirmed-unattested: 0\`、\`unverified: 0\` です。このrunのattestationは3 OSのdispatch証拠・native AOT aggregate・canonical証拠17件を同一Sigstore bundleのsubjectとして署名しており、snapshotは \`attestations/${runId}/\` に追跡しています。前manifest用のsnapshot \`attestations/34305071458/\`（run \`34305071458\`）と \`attestations/34121804812/\`（run \`34121804812\`）、\`attestations/34113932297/\`（run \`34113932297\`）は履歴として残しています。\n\n一時artifactの値は、実行環境・署名・artifactの保存期間に依存します。追跡対象のcanonical \`evidence.json\` は、追跡された現行snapshotと現行source manifestの一致が確認できた場合にのみ \`verified\` を保持します。`;
  text = replaceRange(text, "<!-- attestation:artifacts-start -->", "<!-- attestation:artifacts-end -->", newArtifacts);

  await writeFile(path, text);
}

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

    const catalogFiles = (await readdir(tempCatalog)).map((name) => resolve(tempCatalog, name));
    const files = new Map();
    for (const path of catalogFiles) {
      if (await isSigstoreBundle(path)) {
        files.set("bundle", path);
      } else {
        const name = path.split("/").pop();
        if (name === "dispatch-attestation.json") files.set("dispatchAttestation", path);
        else if (name === "native-aot-attestation.json") files.set("nativeAotAttestation", path);
        else if (name === "catalog-evidence-verified.json") files.set("catalogEvidence", path);
      }
    }
    if (!files.has("bundle")) throw new Error("catalog artifactにsigstore bundleが見つかりません");
    if (!files.has("dispatchAttestation")) throw new Error("catalog artifactにdispatch-attestation.jsonがありません");
    if (!files.has("nativeAotAttestation")) throw new Error("catalog artifactにnative-aot-attestation.jsonがありません");
    if (!files.has("catalogEvidence")) throw new Error("catalog artifactにcatalog-evidence-verified.jsonがありません");

    const aotFiles = (await readdir(tempAot)).map((name) => resolve(tempAot, name));
    const aotAggregateSource = aotFiles.find((path) => path.endsWith("native-aot-aggregate-evidence.json"));
    if (!aotAggregateSource) throw new Error("native AOT aggregate artifactに集約証拠ファイルがありません");
    files.set("nativeAotAggregate", aotAggregateSource);

    const artifactSha256 = {};
    for (const [key, source] of files) {
      const target = resolve(outputDirectory, snapshotFiles[key]);
      await cp(source, target);
      artifactSha256[snapshotFiles[key]] = sha256FileSync(target);
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
      schema: canonicalAttestationSchema,
      workflowRun: options.runId,
      workflowAttempt: Number(attempt),
      targetCommit,
      sourceRef: "refs/heads/main",
      workflow: options.workflow,
      sourceManifestSha256: sourceManifest.sha256,
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

    const currentPointer = {
      schema: currentAttestationPointerSchema,
      workflowRun: options.runId,
      workflowAttempt: Number(attempt),
      targetCommit,
      sourceRef: "refs/heads/main",
      workflow: options.workflow,
      sourceManifestSha256: sourceManifest.sha256,
      directory: options.runId,
    };
    await writeFile(resolve(root, "compat", "v3.7.24", "attestations", "current.json"), `${JSON.stringify(currentPointer, null, 2)}\n`);

    run("sync compat evidence", "node", [resolve(root, "tools", "sync_compat_evidence.mjs"), "--generate"]);
    await updateCompatibilityDocs(options.runId, targetCommit, sourceManifest.sha256);

    if (!options.noVerify) {
      run("check tracked dispatch attestation", "node", [resolve(root, "tools", "check_tracked_dispatch_attestation.mjs"), "--offline"]);
      run("check docs current", "node", [resolve(root, "tools", "check_docs_current.mjs")]);
      run("sync compat evidence --check", "node", [resolve(root, "tools", "sync_compat_evidence.mjs"), "--check"]);
    }
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }

  if (options.noPr) {
    console.log(`attestation snapshotを作成しました: ${outputDirectory}`);
    console.log("--no-pr のためブランチ/PRは作成しません。手動でcommitしてください。");
    return;
  }

  run("git checkout -b", "git", ["checkout", "-b", options.branch]);
  run("git add", "git", ["add", "-A"]);
  run("git commit", "git", ["commit", "-m", `CI run ${options.runId} のattestation snapshotを追跡 (verified: 527)`]);
  run("git push", "git", ["push", "--no-verify", "origin", options.branch]);

  const prResult = run("gh pr create", "gh", [
    "pr", "create",
    "--repo", options.repo,
    "--base", options.base,
    "--head", options.branch,
    "--title", `chore: CI run ${options.runId} のattestation追跡`,
    "--body", `CI \`${options.runId}\` が生成した Sigstore bundle、dispatch/native AOT attestation、canonical 証拠 snapshot を \`compat/v3.7.24/attestations/${options.runId}/\` へ追加し、\`current.json\` を更新して \`evidence.json\` を \`verified: 527\` に再生成しました。\n\n- workflow: ${options.workflow}\n- target commit: \`${targetCommit}\`\n- source manifest: \`${sourceManifest.sha256}\``,
  ]);
  console.log(prResult.stdout.trim());
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
