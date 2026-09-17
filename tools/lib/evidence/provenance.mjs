import { homedir, tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
import { normalizeLineEndings, sha256 } from "../evidence_common.mjs";
import { json } from "./constants.mjs";

// canonical evidence は「純粋な内容クレーム」のみを持つ。生成環境・ソース状態を示す
// provenance.lnako.* と provenance.environment.node は Sigstore attestation 層が
// 束縛するため、tracked evidence からは除去する。

export function canonicalizeEvidenceDocument(document) {
  const canonical = structuredClone(document);
  if (canonical.provenance !== null && typeof canonical.provenance === "object") {
    delete canonical.provenance.lnako;
    if (canonical.provenance.environment !== null && typeof canonical.provenance.environment === "object") {
      delete canonical.provenance.environment.node;
    }
  }
  return canonical;
}

export function stripEnvironmentForComparison(document) {
  const stripped = structuredClone(document);
  if (stripped.provenance !== null && typeof stripped.provenance === "object") {
    delete stripped.provenance.environment;
  }
  return stripped;
}

// 正本と再生成結果（OS が異なり得る coverage merge を含む）を比較するための
// 決定的 byte 列。canonicalize 後に environment を外す。
export function freshnessBytes(document) {
  return json(stripEnvironmentForComparison(canonicalizeEvidenceDocument(document)));
}

export const normalizedManifestSourcePath = "<lnako-normalized-source-path>";

// AOT manifest（compile/global/literal。全て header JSONL 1行目に sourcePath を持つ）
// は compiler が記録する絶対パスで run ごとに揮れる。内容 hash は header の
// sourcePath を固定トークンへ置換してから取る。header.sourcePath と実パスの
// 一致検証は呼び出し側が raw のまま行う。
export function normalizeManifestForHash(text) {
  const newlineIndex = text.indexOf("\n");
  const headerLine = newlineIndex === -1 ? text : text.slice(0, newlineIndex);
  const rest = newlineIndex === -1 ? "" : text.slice(newlineIndex);
  const header = JSON.parse(headerLine);
  if (typeof header.sourcePath === "string") header.sourcePath = normalizedManifestSourcePath;
  return JSON.stringify(header) + rest;
}

export function manifestContentSha256(text) {
  return sha256(normalizeManifestForHash(text));
}

const volatileOutputPatterns = [
  [/\(node:\d+\)/g, "(node:<pid>)"],
  [/Node\.js v\d+\.\d+\.\d+/g, "Node.js <version>"],
  [/ポート番号\(\d+\)/g, "ポート番号(<port>)"],
  [/\b(?:127\.0\.0\.1|localhost):\d{2,5}\b/g, "<addr>:<port>"],
  // 公式 runtime が eval 用に生成する関数名には timestamp+random の funcID が
  // 埋め込まれ、stack trace・生成コメント id 経由で揮れる。
  [/__eval_nako3(sync|async|async_promise)_\d+_\d+__/g, "__eval_nako3$1__"],
  [/(nadesiko3::gen::async id=")\d+_\d+/g, "$1<id>"],
  // eval 生成 JS にソース絶対パスが埋め込まれるため、<anonymous> の列番号が
  // checkout パス長で変わる。行・列は内容クレームではない。
  [/<anonymous>:\d+:\d+/g, "<anonymous>:<pos>"],
];

// fixture/公式 runtime の出力には実行ごとに変わる値が混入し得る:
//   - mkdtemp な作業 directory（cwd 出力・file:// stack trace・生成 .mjs パス）
//   - リポジトリ root / oracle 配下の絶対パス
//   - ephemeral port・PID・Node バージョン行
// context.volatilePaths は絶対パス（file:// 形式と \ / 両方）、
// context.volatileStrings は loopback base のような非パス文字列を指定する。
// context.volatileLines は行全体が一致する値（OS取得の "darwin" など platform
// 依存の単独行）だけを畳む。部分文字列ではなく行一致に限定し、本文中に偶然
// 現れる同文字列を巻き込まない。
// 長いパスから先に置換し、root 配下の oracle のように包含関係があっても正しく畳む。
// processOutputVolatileContext は全 generator 共通の実行環境依存値（ホーム・
// テンポラリ dir・platform/arch の単独行）を追加した context を返す。呼び出し側は
// paths に作業 directory・root・oracleRoot など run 固有のパスを渡す。
export function normalizeVolatileProcessOutput(text, context = {}) {
  const paths = [...(context.volatilePaths ?? [])].sort((left, right) => right.length - left.length);
  let normalized = text;
  for (const volatilePath of paths) {
    if (typeof volatilePath !== "string" || volatilePath.length === 0) continue;
    normalized = normalized.split(pathToFileURL(volatilePath).href).join("<lnako-volatile>");
    normalized = normalized.split(volatilePath).join("<lnako-volatile>");
    const slashed = volatilePath.replaceAll("\\", "/");
    if (slashed !== volatilePath) normalized = normalized.split(slashed).join("<lnako-volatile>");
  }
  for (const literal of context.volatileStrings ?? []) {
    if (typeof literal !== "string" || literal.length === 0) continue;
    normalized = normalized.split(literal).join("<lnako-volatile>");
  }
  const volatileLines = new Set((context.volatileLines ?? []).filter((value) => typeof value === "string" && value.length > 0));
  if (volatileLines.size > 0) {
    normalized = normalized.split("\n").map((line) => volatileLines.has(line) ? "<lnako-volatile>" : line).join("\n");
  }
  for (const [pattern, replacement] of volatileOutputPatterns) {
    normalized = normalized.replace(pattern, replacement);
  }
  return normalized;
}

export function processOutputSha256(text, context = {}) {
  return sha256(normalizeVolatileProcessOutput(normalizeLineEndings(text), context));
}

export function processOutputVolatileContext({ paths = [], strings = [], lines = [] } = {}) {
  return {
    volatilePaths: [...paths, homedir(), tmpdir()],
    volatileStrings: strings,
    volatileLines: [process.platform, process.arch, ...lines],
  };
}
