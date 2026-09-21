import { readdirSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { join, dirname, basename, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { parseRange, jointSetsIntersect } from "./semver_range.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const projectRoot = join(__dirname, "..", "..", "..");
const schemaDir = join(projectRoot, "tools", "package-system", "schema");

const knownManifestSchemaVersions = new Set([1]);
const knownLockSchemaVersions = new Set([1]);
const knownArtifactKinds = new Set(["source", "native", "ESM"]);
const knownProfileRuntime = new Set(["lnako", "cnako", "any", "common"]);
const knownPackageRuntime = new Set(["lnako", "cnako"]);
const knownProfileOs = new Set(["macos", "linux", "windows"]);
const knownProfileCpu = new Set(["aarch64", "x86_64", "arm", "wasm32"]);
const knownProfileAbi = new Set(["gnu", "msvc", "musl", "none"]);

export class DiagnosticError extends Error {
  constructor(code, message, path = "") {
    super(message);
    this.code = code;
    this.message = message;
    this.path = path;
    this.name = "DiagnosticError";
  }
}

function fail(code, message, path = "") {
  throw new DiagnosticError(code, message, path);
}

function loadSchemas() {
  const byFile = new Map();
  const byId = new Map();
  for (const file of readdirSync(schemaDir)) {
    if (!file.endsWith(".schema.json")) continue;
    const text = readFileSync(join(schemaDir, file), "utf8");
    const schema = JSON.parse(text);
    byFile.set(file, schema);
    if (schema.$id) byId.set(schema.$id, file);
  }
  return { byFile, byId };
}

const schemaCache = loadSchemas();
const resolvedRefCache = new Map();
const resolvingRefs = new Set();
const semverPattern = new RegExp(schemaCache.byFile.get("common.schema.json").$defs.semver.pattern);

// `format: "uri"` を検証する。RFC 3986 の絶対 URI の部分集合で、
// scheme `[a-zA-Z][a-zA-Z0-9+.-]*:` と、空白・制御文字を含まない
// 非空の残部を要求する（残部の文字構成までは検査しない）。
// Zig 側 manifest.zig の `isUri` と同一の判定。
function isUri(text) {
  const colon = text.indexOf(":");
  if (colon <= 0) return false;
  if (!/^[a-zA-Z][a-zA-Z0-9+.-]*$/.test(text.slice(0, colon))) return false;
  const rest = text.slice(colon + 1);
  if (rest.length === 0) return false;
  return !/[\x00-\x20\x7f]/.test(rest);
}

// SPDX license expression の構文（識別子・`+` 接尾・`WITH` 例外・
// `AND`/`OR` 結合・括弧）のみ検査する。識別子が SPDX 公式一覧に
// 登録済みかは検査しない。`UNLICENSED`/`Proprietary` も識別子として
// 構文上受理される。Zig 側 `isLicenseExpression` と同一の判定。
const maxLicenseDepth = 32;

function isLicenseExpression(text) {
  const pos = { i: 0 };
  if (!licenseExpr(text, pos, 0)) return false;
  licenseSkipWs(text, pos);
  return pos.i === text.length;
}

function licenseSkipWs(text, pos) {
  while (pos.i < text.length && (text[pos.i] === " " || text[pos.i] === "\t")) pos.i++;
}

function licenseToken(text, pos) {
  licenseSkipWs(text, pos);
  const start = pos.i;
  while (pos.i < text.length && !" \t()".includes(text[pos.i])) pos.i++;
  return pos.i === start ? null : text.slice(start, pos.i);
}

function isLicenseId(token, allowPlus) {
  let t = token;
  const hadPlus = t.endsWith("+");
  if (allowPlus && hadPlus) t = t.slice(0, -1);
  if (t.length === 0) return false;
  const colon = t.indexOf(":");
  if (colon >= 0) {
    // コロンは `DocumentRef-<id>:LicenseRef-<id>` 複合形の区切り専用で、
    // Ref 形には `+` 接尾を付けられない。
    if (hadPlus) return false;
    const doc = t.slice(0, colon);
    const ref = t.slice(colon + 1);
    return doc.startsWith("DocumentRef-") && ref.startsWith("LicenseRef-") &&
      isLicenseIdPart(doc.slice("DocumentRef-".length)) &&
      isLicenseIdPart(ref.slice("LicenseRef-".length));
  }
  if (!isLicenseIdPart(t)) return false;
  if (t.startsWith("LicenseRef-")) {
    // LicenseRef 単体は非空の idstring が必要で、`+` 接尾も付けられない。
    if (hadPlus || t.length === "LicenseRef-".length) return false;
  }
  // `DocumentRef-` 接頭辞は複合形でのみ意味を持つため、単体でも
  // 空 idstring は受理しない（非空なら通常識別子として扱う）。
  if (t === "DocumentRef-") return false;
  return t !== "AND" && t !== "OR" && t !== "WITH";
}

// 識別子の構成要素（`[A-Za-z0-9.-]+`、非空）。
function isLicenseIdPart(t) {
  return /^[A-Za-z0-9.-]+$/.test(t);
}

function licenseTerm(text, pos, depth) {
  licenseSkipWs(text, pos);
  if (pos.i < text.length && text[pos.i] === "(") {
    if (depth >= maxLicenseDepth) return false;
    pos.i++;
    if (!licenseExpr(text, pos, depth + 1)) return false;
    licenseSkipWs(text, pos);
    if (pos.i >= text.length || text[pos.i] !== ")") return false;
    pos.i++;
    return true;
  }
  const id = licenseToken(text, pos);
  if (id === null || !isLicenseId(id, true)) return false;
  const save = pos.i;
  if (licenseToken(text, pos) === "WITH") {
    const exception = licenseToken(text, pos);
    // 例外識別子は `+` 接尾・`:`（DocumentRef 複合形）を許容しない。
    return exception !== null && isLicenseId(exception, false) && !exception.includes(":");
  }
  pos.i = save;
  return true;
}

function licenseExpr(text, pos, depth) {
  if (!licenseTerm(text, pos, depth)) return false;
  while (true) {
    const save = pos.i;
    const op = licenseToken(text, pos);
    if (op !== "AND" && op !== "OR") {
      pos.i = save;
      return true;
    }
    if (!licenseTerm(text, pos, depth)) return false;
  }
}

function parseRef(ref, baseFile) {
  if (typeof ref !== "string") return { file: baseFile, fragment: "/" };
  const hashIdx = ref.indexOf("#");
  let filePart;
  let fragment;
  if (hashIdx < 0) {
    filePart = ref;
    fragment = "/";
  } else {
    filePart = ref.slice(0, hashIdx);
    fragment = ref.slice(hashIdx + 1) || "/";
  }
  if (!filePart) {
    filePart = baseFile;
  } else if (schemaCache.byId.has(filePart)) {
    filePart = schemaCache.byId.get(filePart);
  } else if (!schemaCache.byFile.has(filePart)) {
    fail("SCHEMA_ERROR", `unknown $ref file: ${ref}`, `schema ${baseFile}`);
  }
  return { file: filePart, fragment };
}

function getRawSchema(file, fragment) {
  const root = schemaCache.byFile.get(file);
  if (!root) fail("SCHEMA_ERROR", `schema file not found: ${file}`, file);
  if (!fragment || fragment === "/") return root;
  if (fragment.startsWith("/$defs/")) {
    const name = fragment.slice("/$defs/".length);
    if (root.$defs && name in root.$defs) return root.$defs[name];
    fail("SCHEMA_ERROR", `unknown $def ${fragment} in ${file}`, file);
  }
  fail("SCHEMA_ERROR", `unknown $ref fragment: ${fragment}`, file);
}

function resolveAndDeref(ref, baseFile) {
  const { file, fragment } = parseRef(ref, baseFile);
  const key = `${file}#${fragment}`;
  if (resolvedRefCache.has(key)) return resolvedRefCache.get(key);
  if (resolvingRefs.has(key)) fail("SCHEMA_ERROR", `circular $ref: ${ref}`, `schema ${baseFile}`);
  resolvingRefs.add(key);
  try {
    const raw = getRawSchema(file, fragment);
    const out = dereference(raw, file);
    resolvedRefCache.set(key, out);
    return out;
  } finally {
    resolvingRefs.delete(key);
  }
}

function dereference(schema, baseFile) {
  if (schema === null || typeof schema !== "object") return schema;
  if (Array.isArray(schema)) {
    return schema.map((s) => dereference(s, baseFile));
  }
  if (schema.$ref) {
    return resolveAndDeref(schema.$ref, baseFile);
  }
  const out = {};
  for (const [k, v] of Object.entries(schema)) {
    out[k] = dereference(v, baseFile);
  }
  return out;
}

export function validateBySchemaFile(value, fileName, path = "") {
  const root = schemaCache.byFile.get(fileName);
  if (!root) fail("SCHEMA_ERROR", `schema file not found: ${fileName}`);
  const dereffed = dereference(root, fileName);
  validateSchema(value, dereffed, path);
}

function validateSchema(value, schema, path) {
  if (schema === true) return;
  if (schema === false) fail("E023_INVALID_TYPE", `value not allowed at ${path}`, path);

  if (schema.type) {
    const actual = Array.isArray(value) ? "array" : value === null ? "null" : typeof value;
    const allowed = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (schema.type === "integer" && typeof value === "number" && Number.isInteger(value)) {
      // ok
    } else if (schema.type === "object" && actual === "object" && value !== null) {
      // ok
    } else if (!allowed.includes(actual)) {
      fail("E023_INVALID_TYPE", `expected ${schema.type}, got ${actual} at ${path}`, path);
    }
  }

  if (schema.enum && !schema.enum.includes(value)) {
    fail("E029_INVALID_VALUE", `expected one of ${schema.enum.join(", ")}, got ${JSON.stringify(value)} at ${path}`, path);
  }

  if ("const" in schema && value !== schema.const) {
    fail("E029_INVALID_VALUE", `expected ${JSON.stringify(schema.const)}, got ${JSON.stringify(value)} at ${path}`, path);
  }

  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) {
      fail("E029_INVALID_VALUE", `${value} < minimum ${schema.minimum} at ${path}`, path);
    }
    if (schema.maximum !== undefined && value > schema.maximum) {
      fail("E029_INVALID_VALUE", `${value} > maximum ${schema.maximum} at ${path}`, path);
    }
    if (schema.exclusiveMinimum !== undefined && value <= schema.exclusiveMinimum) {
      fail("E029_INVALID_VALUE", `${value} <= exclusiveMinimum at ${path}`, path);
    }
    if (schema.exclusiveMaximum !== undefined && value >= schema.exclusiveMaximum) {
      fail("E029_INVALID_VALUE", `${value} >= exclusiveMaximum at ${path}`, path);
    }
  }

  if (typeof value === "string") {
    if (schema.pattern) {
      // マッチが入力全体を消費することを要求する。現行 schema の
      // pattern は全て `^...$` アンカー済みで `.test` と同じ結果に
      // なるが、pattern 定義に依存せず厳密な全文一致を保証する
      // （Zig 側の厳密な解析と揃える）。
      const m = new RegExp(schema.pattern).exec(value);
      if (m === null || m.index !== 0 || m[0].length !== value.length) {
        fail("E029_INVALID_VALUE", `value "${value}" does not match pattern ${schema.pattern} at ${path}`, path);
      }
    }
    if (schema.format === "uri" && !isUri(value)) {
      fail("E029_INVALID_VALUE", `invalid uri "${value}" at ${path}`, path);
    }
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      fail("E029_INVALID_VALUE", `string at ${path} is too short`, path);
    }
    if (schema.maxLength !== undefined && value.length > schema.maxLength) {
      fail("E029_INVALID_VALUE", `string at ${path} is too long`, path);
    }
  }

  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      fail("E029_INVALID_VALUE", `array at ${path} has too few items`, path);
    }
    if (schema.maxItems !== undefined && value.length > schema.maxItems) {
      fail("E029_INVALID_VALUE", `array at ${path} has too many items`, path);
    }
    if (schema.uniqueItems) {
      const seen = new Set();
      for (const item of value) {
        const key = JSON.stringify(item);
        if (seen.has(key)) fail("E029_INVALID_VALUE", `duplicate array item at ${path}`, path);
        seen.add(key);
      }
    }
    if (schema.items) {
      for (let i = 0; i < value.length; i++) {
        validateSchema(value[i], schema.items, `${path}[${i}]`);
      }
    }
  }

  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    const keys = Object.keys(value);

    if (schema.propertyNames) {
      for (const key of keys) {
        validateSchema(key, schema.propertyNames, `${path} property name "${key}"`);
      }
    }

    if (schema.required) {
      for (const key of schema.required) {
        if (!(key in value)) {
          fail("E019_REQUIRED_FIELD_MISSING", `missing required property "${key}" at ${path}`, path);
        }
      }
    }

    if (schema.minProperties !== undefined && keys.length < schema.minProperties) {
      fail("E029_INVALID_VALUE", `object at ${path} has too few properties`, path);
    }

    if (schema.additionalProperties === false) {
      const allowed = new Set(Object.keys(schema.properties || {}));
      for (const key of keys) {
        if (!allowed.has(key)) {
          fail("E022_UNKNOWN_FIELD", `additional property "${key}" not allowed at ${path}`, path);
        }
      }
    } else if (typeof schema.additionalProperties === "object") {
      const known = new Set(Object.keys(schema.properties || {}));
      for (const key of keys) {
        if (!known.has(key)) {
          validateSchema(value[key], schema.additionalProperties, `${path}.${key}`);
        }
      }
    }

    if (schema.properties) {
      for (const [key, sub] of Object.entries(schema.properties)) {
        if (key in value) {
          validateSchema(value[key], sub, `${path}.${key}`);
        }
      }
    }

    if (schema.patternProperties) {
      for (const [pattern, sub] of Object.entries(schema.patternProperties)) {
        const re = new RegExp(pattern);
        for (const key of keys) {
          if (re.test(key)) {
            validateSchema(value[key], sub, `${path}.${key}`);
          }
        }
      }
    }
  }

  if (schema.oneOf) {
    // 全枝が `type` を宣言する場合、値の型に適合する枝だけを評価して
    // 枝内の診断コード（E019/E022 等）をそのまま報告する。
    const actual = Array.isArray(value) ? "array" : value === null ? "null" : typeof value;
    const typed = schema.oneOf.every((sub) => sub && sub.type);
    const typeMatches = (sub) => {
      const allowed = Array.isArray(sub.type) ? sub.type : [sub.type];
      return allowed.includes(actual) || (actual === "number" && allowed.includes("integer") && Number.isInteger(value));
    };
    if (typed) {
      const candidates = schema.oneOf.filter(typeMatches);
      if (candidates.length === 1) {
        validateSchema(value, candidates[0], path);
      } else if (candidates.length === 0) {
        fail("E023_INVALID_TYPE", `expected one of ${schema.oneOf.length} schemas at ${path}`, path);
      } else {
        let matched = 0;
        for (const sub of candidates) {
          try {
            validateSchema(value, sub, path);
            matched++;
          } catch (e) {
            // continue
          }
        }
        if (matched !== 1) {
          fail("E023_INVALID_TYPE", `expected exactly one of ${schema.oneOf.length} schemas at ${path} (matched ${matched})`, path);
        }
      }
    } else {
      let matched = 0;
      for (const sub of schema.oneOf) {
        try {
          validateSchema(value, sub, path);
          matched++;
        } catch (e) {
          // continue
        }
      }
      if (matched !== 1) {
        fail("E023_INVALID_TYPE", `expected exactly one of ${schema.oneOf.length} schemas at ${path} (matched ${matched})`, path);
      }
    }
  }

  if (schema.anyOf) {
    let matched = false;
    for (const sub of schema.anyOf) {
      try {
        validateSchema(value, sub, path);
        matched = true;
        break;
      } catch (e) {
        // continue
      }
    }
    if (!matched) fail("E023_INVALID_TYPE", `expected one of anyOf schemas at ${path}`, path);
  }

  if (schema.allOf) {
    for (const sub of schema.allOf) {
      validateSchema(value, sub, path);
    }
  }
}

export function validateManifest(manifest, fixturePath) {
  if (typeof manifest !== "object" || manifest === null || Array.isArray(manifest)) {
    fail("E023_INVALID_TYPE", `manifest root must be an object`, fixturePath);
  }
  if (!("package" in manifest)) {
    fail("E019_REQUIRED_FIELD_MISSING", `missing required field "package"`, fixturePath);
  }

  // package.version の semver 不一致は汎用パターン失敗ではなく E024 とする。
  // 防御的にマッチが入力全体を消費したかまで確認する。
  const versionMatch = typeof manifest.package?.version === "string"
    ? semverPattern.exec(manifest.package.version)
    : null;
  if (typeof manifest.package?.version === "string" &&
    (versionMatch === null || versionMatch.index !== 0 || versionMatch[0].length !== manifest.package.version.length)) {
    fail("E024_INVALID_SEMVER", `invalid semver "${manifest.package.version}"`, `${fixturePath}.package.version`);
  }
  // semver 各数値要素は Number.MAX_SAFE_INTEGER 以下（Zig 側 numericPart と同じ上限）。
  if (typeof manifest.package?.version === "string") {
    const core = /^(\d+)\.(\d+)\.(\d+)/.exec(manifest.package.version);
    if (core && core.slice(1).some((part) => Number(part) > Number.MAX_SAFE_INTEGER)) {
      fail("E024_INVALID_SEMVER", `semver component exceeds Number.MAX_SAFE_INTEGER in "${manifest.package.version}"`, `${fixturePath}.package.version`);
    }
  }

  validateBySchemaFile(manifest, "nako.toml.schema.json", fixturePath);

  const pkg = manifest.package;
  if (pkg && "schema-version" in pkg && !knownManifestSchemaVersions.has(pkg["schema-version"])) {
    fail("E001_UNKNOWN_MANIFEST_SCHEMA", `unknown manifest schema version ${pkg["schema-version"]}`, `${fixturePath}.package.schema-version`);
  }

  // package.license は SPDX expression 構文のみ検査する（Zig 側と同じ判定。
  // 識別子が SPDX 公式一覧に登録済みかは問わない）。
  if (typeof manifest.package?.license === "string" && !isLicenseExpression(manifest.package.license)) {
    fail("E029_INVALID_VALUE", `invalid license expression "${manifest.package.license}"`, `${fixturePath}.package.license`);
  }

  // nako-version 系の数値要素は u64 範囲内（Zig 側 parsePlainVersion と同じ上限）。
  for (const key of ["nako-version", "min-nako-version"]) {
    const value = manifest.package?.[key];
    const coreMatch = typeof value === "string" ? /^\d+\.\d+\.\d+$/.exec(value) : null;
    if (coreMatch !== null && coreMatch[0].length === value.length) {
      if (value.split(".").some((part) => BigInt(part) > 18446744073709551615n)) {
        fail("E029_INVALID_VALUE", `${key} component exceeds u64 in "${value}"`, `${fixturePath}.package.${key}`);
      }
    }
  }

  if (manifest.profiles) {
    for (const [name, prof] of Object.entries(manifest.profiles)) {
      if (prof.runtime != null && !knownProfileRuntime.has(prof.runtime)) {
        fail("E014_INVALID_PROFILE", `profile "${name}" has invalid runtime: ${prof.runtime}`, `${fixturePath}.profiles.${name}.runtime`);
      }
      if (!knownProfileOs.has(prof.os) || !knownProfileCpu.has(prof.cpu) || !knownProfileAbi.has(prof.abi)) {
        fail("E014_INVALID_PROFILE", `profile "${name}" has invalid os/cpu/abi: ${prof.os}/${prof.cpu}/${prof.abi}`, `${fixturePath}.profiles.${name}`);
      }
    }
  }

  if (manifest.exports) {
    const names = new Set();
    for (const exp of manifest.exports) {
      if (names.has(exp.name)) {
        fail("E011_DUPLICATE_EXPORT", `duplicate export name "${exp.name}"`, `${fixturePath}.exports`);
      }
      names.add(exp.name);
    }
    const hasCompatJsProfile = Object.values(manifest.profiles ?? {}).some((p) => p["compat-js"] === true);
    const runtimes = manifest.package?.runtimes ?? [];
    // runtimes 未指定は lnako / cnako の両対応を意味するため cnako 対応として扱う。
    // cnako 対応パッケージは ESM を直接利用できる有効な経路を持つ。cnako profile は
    // パッケージが cnako 対応の場合にのみ有効で、runtimes で cnako を否定している
    // 矛盾した宣言では数えない。
    const supportsCnako = runtimes.length === 0 || runtimes.includes("cnako");
    for (const exp of manifest.exports) {
      // lnako 通常モードで ESM が選択されるのは path も native も無い場合のみ
      // （path があれば共通ソース、native があれば native を選択）。cnako 対応
      // または compat-js profile なら受理し、lnako 専用パッケージの通常モードに
      // 限って E006 とする。実行時の拒否は Zig の Export.resolve が報告する。
      if (exp.esm != null && exp.path == null && exp.native == null && !hasCompatJsProfile && !supportsCnako) {
        fail("E006_JS_IN_NORMAL_MODE", `ESM export "${exp.name}" requires compat-js profile`, `${fixturePath}.exports`);
      }
    }
  }

  // semverRange フィールドの構文検証（schema 上は単なる string のためここで診断する）。
  const checkRange = (text, path) => {
    if (typeof text === "string" && parseRange(text) === null) {
      fail("E025_INVALID_RANGE", `invalid version range "${text}" at ${path}`, path);
    }
  };
  if (manifest.package?.engines && typeof manifest.package.engines === "object") {
    for (const [engine, range] of Object.entries(manifest.package.engines)) {
      if (typeof range === "string") {
        checkRange(range, `${fixturePath}.package.engines.${engine}`);
      }
    }
  }
  for (const section of ["dependencies", "dev-dependencies"]) {
    const group = manifest[section];
    if (!group) continue;
    for (const [alias, dep] of Object.entries(group.pkg ?? {})) {
      if (dep && typeof dep === "object") {
        checkRange(dep.version, `${fixturePath}.${section}.pkg.${alias}.version`);
      }
    }
    for (const [alias, dep] of Object.entries(group.npm ?? {})) {
      if (typeof dep === "string") {
        checkRange(dep, `${fixturePath}.${section}.npm.${alias}`);
      } else if (dep && typeof dep === "object") {
        checkRange(dep.version, `${fixturePath}.${section}.npm.${alias}.version`);
        for (const [peer, range] of Object.entries(dep["peer-dependencies"] ?? {})) {
          checkRange(range, `${fixturePath}.${section}.npm.${alias}.peer-dependencies.${peer}`);
        }
      }
    }
  }

  // 二者間の交差だけでは全制約の共通候補の存在を保証しないため
  // （OR 範囲で各ペアが別の選択肢で交差し得る）、public-id 毎に
  // 積集合を保持する。各パスは依存毎に選んだ AND 比較子集合の列で、
  // prerelease ゲートは構成集合毎に評価する必要があるため併合済みの
  // 平坦な集合は保持しない。
  const maxJointPaths = 1024;
  // 開発解決では通常依存と dev-dependencies の両方が同じ public-id に
  // 効くため、積集合はセクションをまたいで共有する。
  const byPublicId = new Map();
  for (const section of ["dependencies", "dev-dependencies"]) {
    const group = manifest[section]?.pkg;
    if (!group) continue;
    for (const [alias, dep] of Object.entries(group)) {
      if (dep["public-id"] == null) continue;
      const publicId = dep["public-id"];
      // version 欠落・不正（E019/E025 で報告済み）は無制約として扱い、
      // 空の外積による誤診を避ける。
      const depRange = dep.version == null ? [] : (parseRange(dep.version) ?? []);
      if (depRange.length === 0) continue;
      const joint = byPublicId.get(publicId);
      // 積集合が空リストのときは新しい制約の集合をそのまま採用する。
      if (joint === undefined || joint.paths.length === 0) {
        byPublicId.set(publicId, {
          paths: depRange.slice(0, maxJointPaths).map((set) => [set]),
          // 上限超過時は以後の絞り込みを行わない。打ち切った積集合は部分
          // 集合しか保持しないため後続の依存で空になり得るが、それは
          // 打ち切りによる偽の衝突であり得る（見逃し方向にのみ影響する）。
          saturated: depRange.length > maxJointPaths,
        });
        continue;
      }
      if (joint.saturated) continue;
      const next = [];
      let capped = false;
      outer: for (const path of joint.paths) {
        for (const set of depRange) {
          const merged = [...path, set];
          if (jointSetsIntersect(merged)) {
            next.push(merged);
            if (next.length >= maxJointPaths) {
              capped = true;
              break outer;
            }
          }
        }
      }
      if (next.length === 0) {
        fail("E003_CONFLICTING_VERSIONS", `conflicting version constraints for ${publicId}: "${dep.version}" leaves no common version`, `${fixturePath}.${section}.pkg.${alias}`);
      }
      if (capped) joint.saturated = true;
      else joint.paths = next;
    }
  }

  // 依存 alias 名前空間の衝突。feature が参照する名前空間は両セクションで
  // 統合されるため、エントリ名（全グループ）と明示的 `alias`（pkg/git/http）
  // をセクションをまたいで同一マップへ登録する。自分自身への alias は許容する。
  const seen = new Map();
  for (const section of ["dependencies", "dev-dependencies"]) {
    const group = manifest[section];
    if (!group) continue;
    const claim = (name, claimInfo) => {
      const existing = seen.get(name);
      if (existing) {
        const selfAlias = claimInfo.kind === "alias" && existing.kind === "entry" &&
          existing.group === claimInfo.group && existing.own === claimInfo.own;
        if (!selfAlias) {
          fail("E012_ALIAS_COLLISION", `dependency name or alias "${name}" is used by multiple dependencies`, `${fixturePath}.${section}`);
        }
        return;
      }
      seen.set(name, claimInfo);
    };
    for (const kind of ["pkg", "npm", "path", "git", "http"]) {
      for (const name of Object.keys(group[kind] ?? {})) {
        claim(name, { kind: "entry", group: kind, own: name });
      }
    }
    for (const kind of ["pkg", "git", "http"]) {
      for (const [name, dep] of Object.entries(group[kind] ?? {})) {
        if (dep && typeof dep === "object" && typeof dep.alias === "string") {
          claim(dep.alias, { kind: "alias", group: kind, own: name });
        }
      }
    }
  }

  // 依存 `profile` 参照は定義済み profile 名でなければならない。
  const profileNames = new Set(Object.keys(manifest.profiles ?? {}));
  for (const section of ["dependencies", "dev-dependencies"]) {
    for (const [alias, dep] of Object.entries(manifest[section]?.pkg ?? {})) {
      if (dep && typeof dep === "object" && dep.profile != null && !profileNames.has(dep.profile)) {
        fail("E030_UNKNOWN_PROFILE", `unknown profile "${dep.profile}"`, `${fixturePath}.${section}.pkg.${alias}.profile`);
      }
    }
  }

  // feature 定義の各項目は定義済み feature か依存 alias を指す。
  const depAliasNames = new Set();
  for (const section of ["dependencies", "dev-dependencies"]) {
    const group = manifest[section];
    if (!group) continue;
    for (const kind of ["pkg", "npm", "path", "git", "http"]) {
      for (const name of Object.keys(group[kind] ?? {})) depAliasNames.add(name);
    }
    for (const kind of ["pkg", "git", "http"]) {
      for (const dep of Object.values(group[kind] ?? {})) {
        if (dep && typeof dep === "object" && typeof dep.alias === "string") depAliasNames.add(dep.alias);
      }
    }
  }
  const featureDefs = manifest.features ?? {};
  for (const [name, items] of Object.entries(featureDefs)) {
    if (!Array.isArray(items)) continue;
    for (const item of items) {
      if (typeof item !== "string") continue;
      if (!Object.hasOwn(featureDefs, item) && !depAliasNames.has(item)) {
        fail("E028_UNKNOWN_FEATURE", `unknown feature "${item}" referenced by "${name}"`, `${fixturePath}.features.${name}`);
      }
    }
  }

  // feature 定義グラフの循環を反復 DFS で検出する（深い非循環連鎖でも
  // スタックを消費しないよう明示フレームスタックを使う。Zig 側
  // checkCyclesVisit と同一の意味論）。
  const visited = new Set();
  const inStack = new Set();
  const visitCycle = (root) => {
    if (visited.has(root)) return null;
    inStack.add(root);
    const frames = [{ name: root, items: Array.isArray(featureDefs[root]) ? featureDefs[root] : [], next: 0 }];
    while (frames.length > 0) {
      const frame = frames[frames.length - 1];
      if (frame.next < frame.items.length) {
        const item = frame.items[frame.next++];
        if (!Object.hasOwn(featureDefs, item)) continue;
        if (visited.has(item)) continue;
        if (inStack.has(item)) return item;
        inStack.add(item);
        frames.push({ name: item, items: Array.isArray(featureDefs[item]) ? featureDefs[item] : [], next: 0 });
      } else {
        frames.pop();
        inStack.delete(frame.name);
        visited.add(frame.name);
      }
    }
    return null;
  };
  for (const name of Object.keys(featureDefs)) {
    const cycle = visitCycle(name);
    if (cycle !== null) {
      fail("E027_FEATURE_CYCLE", `feature cycle involving "${cycle}"`, `${fixturePath}.features.${cycle}`);
    }
  }
}

// lock の package version は manifest と同じく E024 で報告する。schema の
// pattern より先に検査し、Zig 側 semver.Version.parse と診断コードを揃える。
// Number.MAX_SAFE_INTEGER 超の数値要素も Zig 側と同じく拒否する。
function assertLockSemver(value, path) {
  if (typeof value !== "string") return;
  const match = semverPattern.exec(value);
  if (match === null || match.index !== 0 || match[0].length !== value.length) {
    fail("E024_INVALID_SEMVER", `invalid semver "${value}"`, path);
  }
  for (const part of [match[1], match[2], match[3]]) {
    if (Number(part) > Number.MAX_SAFE_INTEGER) {
      fail("E024_INVALID_SEMVER", `semver component exceeds MAX_SAFE_INTEGER in "${value}"`, path);
    }
  }
}

function assertLockPackageVersions(packages, path) {
  if (typeof packages !== "object" || packages === null || Array.isArray(packages)) return;
  for (const [id, pkg] of Object.entries(packages)) {
    if (typeof pkg === "object" && pkg !== null && !Array.isArray(pkg)) {
      assertLockSemver(pkg.version, `${path}.${id}.version`);
    }
  }
}

export function validateLock(lock, fixturePath) {
  if (typeof lock === "object" && lock !== null && !Array.isArray(lock)) {
    assertLockPackageVersions(lock.packages, `${fixturePath}.packages`);
    for (const [name, packages] of Object.entries(lock.profilePackages ?? {})) {
      assertLockPackageVersions(packages, `${fixturePath}.profilePackages.${name}`);
    }
  }

  validateBySchemaFile(lock, "nako.lock.schema.json", fixturePath);

  if (!knownLockSchemaVersions.has(lock.schemaVersion)) {
    fail("E002_UNKNOWN_LOCK_SCHEMA", `unknown lock schema version ${lock.schemaVersion}`, `${fixturePath}.schemaVersion`);
  }

  // `input.profile` は実行条件を選ぶ参照。対応する profile が存在しない
  // lock は runtime 条件を決定できないため、未知 profile として拒否する。
  if (!Object.hasOwn(lock.profiles ?? {}, lock.input?.profile ?? "")) {
    fail("E030_UNKNOWN_PROFILE", `unknown profile "${lock.input?.profile}"`, `${fixturePath}.input.profile`);
  }

  // 選択された profile の runtime と compat-js を読む。cnako は ESM を
  // 直接扱えるため compat-js を要求せず、lnako などの通常モードのみ
  // E006 の対象とする。未知の runtime・os・cpu・abi は E014 で拒否する
  // （optimize は JSON Schema の enum が E029_INVALID_VALUE で拒否する）。
  if (lock.profiles) {
    for (const [name, prof] of Object.entries(lock.profiles)) {
      if (prof.runtime != null && !knownProfileRuntime.has(prof.runtime)) {
        fail("E014_INVALID_PROFILE", `profile "${name}" has invalid runtime: ${prof.runtime}`, `${fixturePath}.profiles.${name}.runtime`);
      }
      if (typeof prof.os === "string" && !knownProfileOs.has(prof.os)) {
        fail("E014_INVALID_PROFILE", `profile "${name}" has invalid os: ${prof.os}`, `${fixturePath}.profiles.${name}.os`);
      }
      if (typeof prof.cpu === "string" && !knownProfileCpu.has(prof.cpu)) {
        fail("E014_INVALID_PROFILE", `profile "${name}" has invalid cpu: ${prof.cpu}`, `${fixturePath}.profiles.${name}.cpu`);
      }
      if (typeof prof.abi === "string" && !knownProfileAbi.has(prof.abi)) {
        fail("E014_INVALID_PROFILE", `profile "${name}" has invalid abi: ${prof.abi}`, `${fixturePath}.profiles.${name}.abi`);
      }
      // optimize は JSON Schema の enum が E029_INVALID_VALUE で拒否する。
    }
  }
  // input.target も profile と同じ既知値集合で検証する。
  if (lock.input?.target) {
    const target = lock.input.target;
    for (const field of ["os", "cpu", "abi"]) {
      const known = field === "os" ? knownProfileOs : field === "cpu" ? knownProfileCpu : knownProfileAbi;
      if (typeof target[field] === "string" && !known.has(target[field])) {
        fail("E014_INVALID_PROFILE", `input.target has invalid ${field}: ${target[field]}`, `${fixturePath}.input.target.${field}`);
      }
    }
  }
  const selectedProfile = lock.profiles?.[lock.input?.profile];
  // 選択 profile の環境条件は input.target と一致していなければならない。
  if (selectedProfile && lock.input?.target) {
    const target = lock.input.target;
    if (selectedProfile.os !== target.os || selectedProfile.cpu !== target.cpu || selectedProfile.abi !== target.abi) {
      fail("E014_INVALID_PROFILE", `input.target does not match profile "${lock.input.profile}" os/cpu/abi`, `${fixturePath}.input.target`);
    }
  }
  validateLockPackageSet(lock.packages, selectedProfile, fixturePath, `${fixturePath}.packages`);

  // 複数 profile 収録時は profile ごとの package グラフを、その profile の
  // runtime/compat-js 条件で検証する。依存先の存在も同じグラフ内で閉じる。
  for (const [name, packages] of Object.entries(lock.profilePackages ?? {})) {
    if (!Object.hasOwn(lock.profiles ?? {}, name)) {
      fail("E030_UNKNOWN_PROFILE", `unknown profile "${name}"`, `${fixturePath}.profilePackages.${name}`);
    }
    validateLockPackageSet(packages, lock.profiles?.[name], fixturePath, `${fixturePath}.profilePackages.${name}`);
  }

  // `packages` は選択された `input.profile` のグラフの正本であり、
  // profilePackages に同じ profile がある場合は一致を要求する。
  const selectedExtra = (lock.profilePackages ?? {})[lock.input?.profile];
  if (selectedExtra !== undefined && !samePackageMap(selectedExtra, lock.packages)) {
    fail("E029_INVALID_VALUE", `profilePackages.${lock.input?.profile} does not match packages`, `${fixturePath}.profilePackages.${lock.input?.profile}`);
  }

  // 複数 profile 形式では profiles と profilePackages の名前集合が一致する
  // ことを要求する。単一 profile 形式（profilePackages が空）は対象外。
  const profilePackageNames = Object.keys(lock.profilePackages ?? {});
  if (profilePackageNames.length > 0) {
    for (const name of Object.keys(lock.profiles ?? {})) {
      if (!Object.hasOwn(lock.profilePackages, name)) {
        fail("E029_INVALID_VALUE", `profilePackages is missing profile "${name}"`, `${fixturePath}.profilePackages`);
      }
    }
  }

  // lnako/cnako が共用する同一 ID・版の source artifact は同じ hash で参照する。
  const mismatch = sharedArtifactMismatch(lock);
  if (mismatch) {
    fail("E009_HASH_MISMATCH", `source artifact hash differs across profiles for ${mismatch.id}@${mismatch.version}`, `${fixturePath}.profilePackages`);
  }
}

// キー順に依存しない JSON 等価判定。フィールド順の差で不一致としない。
function canonicalJson(value) {
  if (Array.isArray(value)) return value.map(canonicalJson);
  if (value && typeof value === "object") {
    const out = {};
    for (const key of Object.keys(value).sort()) out[key] = canonicalJson(value[key]);
    return out;
  }
  return value;
}

// 省略された任意 collection を空として正規化する。Zig 側 `packageEntryEql`
// は parse 時に省略を `[]`/`{}` にするため、JSON 表現の有無で不一致にしない。
function normalizePackageEntry(entry) {
  const out = { ...entry };
  if (!("features" in out)) out.features = [];
  if (!("artifacts" in out)) out.artifacts = {};
  if (!("npmInstances" in out)) out.npmInstances = {};
  return out;
}

function samePackageMap(a, b) {
  const normalize = (map) => {
    const out = {};
    for (const [id, entry] of Object.entries(map)) out[id] = normalizePackageEntry(entry);
    return out;
  };
  return JSON.stringify(canonicalJson(normalize(a))) === JSON.stringify(canonicalJson(normalize(b)));
}

// artifact map のキーではなく record の kind で source artifact を探す。
// Zig 側 `PackageEntry.artifact("source")` と同一の判定。
function sourceArtifact(pkg) {
  for (const artifact of Object.values(pkg.artifacts ?? {})) {
    if (artifact && artifact.kind === "source") return artifact;
  }
  return null;
}

// 選択済み `packages` と全 profilePackages を横断し、同一 ID・版の source
// artifact の hash 不一致を最初の組で返す。
function sharedArtifactMismatch(lock) {
  const sets = [lock.packages, ...Object.values(lock.profilePackages ?? {})];
  for (let i = 0; i < sets.length; i++) {
    for (const pkg of Object.values(sets[i])) {
      const source = sourceArtifact(pkg);
      if (!source) continue;
      for (let j = i + 1; j < sets.length; j++) {
        for (const candidate of Object.values(sets[j])) {
          if (candidate.id !== pkg.id || candidate.version !== pkg.version) continue;
          const other = sourceArtifact(candidate);
          if (!other) continue;
          // hex/base64 表記を正規化して比較する（Zig 側 sha256Eql と同一）。
          const left = normalizeSha256(source.sha256);
          const right = normalizeSha256(other.sha256);
          if (left !== null && right !== null) {
            if (left !== right) return { id: pkg.id, version: pkg.version };
          } else if ((source.sha256 ?? null) !== (other.sha256 ?? null)) {
            return { id: pkg.id, version: pkg.version };
          }
        }
      }
    }
  }
  return null;
}

// 1 つの package グラフを選択 profile の条件で検証する。lock の artifacts は
// package 単位の集合で、各 kind が同じ export の代替実装か別 export かを表さない。
// 選択情報がない以上 ESM が未使用と判断できないため、通常モード
// （compat-js 無効・cnako 非選択）のグラフに ESM が一つでもあれば保守的に
// E006 とする。実際の選択は解決・import 時に manifest の Export.resolve が担う。
function validateLockPackageSet(packages, profile, fixturePath, path) {
  const esmAllowed = profile?.["compat-js"] === true || profile?.runtime === "cnako";
  for (const [id, pkg] of Object.entries(packages)) {
    if (!pkg.artifacts || Object.keys(pkg.artifacts).length === 0) {
      fail("E008_MISSING_ARTIFACT", `package ${id} has no artifacts`, `${path}.${id}.artifacts`);
    }
    const kinds = new Set();
    for (const [kind, artifact] of Object.entries(pkg.artifacts)) {
      if (!knownArtifactKinds.has(artifact.kind)) {
        fail("E007_UNKNOWN_ARTIFACT_KIND", `unknown artifact kind "${artifact.kind}" at ${path}.${id}.artifacts.${kind}`, `${path}.${id}.artifacts.${kind}`);
      }
      kinds.add(artifact.kind);
    }
    if (kinds.has("ESM") && !esmAllowed) {
      fail("E006_JS_IN_NORMAL_MODE", `ESM artifact selected without compat-js profile`, `${path}.${id}.artifacts`);
    }
    // 選択された実装種別に対応する artifact が存在しなければ同期できない。
    if (pkg.implementation != null && pkg.implementation !== "none" && !kinds.has(pkg.implementation)) {
      fail("E008_MISSING_ARTIFACT", `selected implementation "${pkg.implementation}" has no matching artifact`, `${path}.${id}.artifacts`);
    }
    for (const dep of pkg.dependencies) {
      if (!Object.hasOwn(packages, dep)) {
        fail("E013_MISSING_PACKAGE", `dependency ${dep} not found in lock packages`, `${path}.${id}.dependencies`);
      }
    }
  }
}

export function validateRegistryIndex(index, fixturePath) {
  validateBySchemaFile(index, "registry-index.schema.json", fixturePath);
  const ids = new Set();
  for (const pkg of index.packages) {
    if (ids.has(pkg.id)) {
      fail("E012_ALIAS_COLLISION", `duplicate package id "${pkg.id}" in registry index`, `${fixturePath}.packages`);
    }
    ids.add(pkg.id);
  }
}

export function validateRegistryPackage(pkg, fixturePath) {
  validateBySchemaFile(pkg, "registry-package.schema.json", fixturePath);
}

export function validateRegistryVersion(version, fixturePath) {
  validateBySchemaFile(version, "registry-version.schema.json", fixturePath);
}

export function validateNpkgMetadata(meta, fixturePath) {
  validateBySchemaFile(meta, "npkg-metadata.schema.json", fixturePath);
}

export function validateNpkgCommands(commands, fixturePath) {
  validateBySchemaFile(commands, "commands.schema.json", fixturePath);
}

export function validateNpkgFiles(files, fixturePath) {
  validateBySchemaFile(files, "npkg-files.schema.json", fixturePath);
}

export function validateEnvironment(environment, fixturePath) {
  // `.nako/environment.json` は cnako が単独で参照する外部契約であり、
  // 欠落・破損・版不一致・lock 不一致はすべて E034 に正規化する。
  // 内部で汎用 schema/manifest コード（E019/E023/E029 等）が発生しても、
  // 利用側が環境参照エラーとして一貫して扱えるよう変換する。
  try {
    validateEnvironmentContract(environment, fixturePath);
  } catch (error) {
    if (error instanceof DiagnosticError) {
      if (error.code === "E034_INVALID_ENVIRONMENT_REFERENCE") throw error;
      // schema 定義自体の不整合（SCHEMA_ERROR）はツール側の不具合なので
      // 環境参照エラーへ変換せず、そのまま伝播させる。
      if (error.code === "SCHEMA_ERROR") throw error;
      throw new DiagnosticError("E034_INVALID_ENVIRONMENT_REFERENCE", error.message, error.path);
    }
    throw error;
  }
}

function validateEnvironmentContract(environment, fixturePath) {
  if (typeof environment !== "object" || environment === null || Array.isArray(environment)) {
    fail("E034_INVALID_ENVIRONMENT_REFERENCE", "environment must be an object", fixturePath);
  }
  for (const required of ["schemaVersion", "lockSha256", "profile", "runtime", "packages"]) {
    if (!(required in environment)) {
      fail("E034_INVALID_ENVIRONMENT_REFERENCE", `missing required field "${required}"`, `${fixturePath}.${required}`);
    }
  }
  if (environment.schemaVersion !== 1) {
    fail("E034_INVALID_ENVIRONMENT_REFERENCE", `unsupported environment schemaVersion ${environment.schemaVersion}`, `${fixturePath}.schemaVersion`);
  }
  const hashPattern = /^(sha256-[A-Za-z0-9+/]{43}=|sha256:[0-9a-f]{64}|[0-9a-f]{64})$/;
  if (typeof environment.lockSha256 === "string" && !hashPattern.test(environment.lockSha256)) {
    fail("E034_INVALID_ENVIRONMENT_REFERENCE", `invalid lockSha256 "${environment.lockSha256}"`, `${fixturePath}.lockSha256`);
  }
  if (typeof environment.runtime === "string" && !["lnako", "cnako"].includes(environment.runtime)) {
    fail("E034_INVALID_ENVIRONMENT_REFERENCE", `invalid runtime "${environment.runtime}"`, `${fixturePath}.runtime`);
  }
  if (typeof environment.profile !== "string" || environment.profile.trim().length === 0) {
    fail("E034_INVALID_ENVIRONMENT_REFERENCE", `invalid profile "${environment.profile}"`, `${fixturePath}.profile`);
  }
  if (typeof environment.packages === "object" && environment.packages !== null && !Array.isArray(environment.packages)) {
    for (const [pkgId, pkg] of Object.entries(environment.packages)) {
      if (typeof pkg === "object" && pkg !== null && !Array.isArray(pkg)) {
        if (typeof pkg.path !== "string" || pkg.path.trim().length === 0) {
          fail("E034_INVALID_ENVIRONMENT_REFERENCE", `package "${pkgId}" missing or empty path`, `${fixturePath}.packages.${pkgId}.path`);
        }
      }
    }
  }
  validateBySchemaFile(environment, "environment.schema.json", fixturePath);
}

/// SHA-256 の各表記（SRI `sha256-<base64>=`、`sha256:<hex>`、生 `<hex>`）を
/// 小文字 hex へ正規化する。解釈できない場合は null。
function normalizeSha256(text) {
  if (typeof text !== "string") return null;
  if (text.startsWith("sha256:")) {
    const hex = text.slice("sha256:".length);
    return /^[0-9a-f]{64}$/.test(hex) ? hex : null;
  }
  if (text.startsWith("sha256-")) {
    const base64 = text.slice("sha256-".length);
    if (!/^[A-Za-z0-9+/]{43}=$/.test(base64)) return null;
    const bytes = Buffer.from(base64, "base64");
    return bytes.length === 32 ? bytes.toString("hex") : null;
  }
  return /^[0-9a-f]{64}$/.test(text) ? text : null;
}

/// `.nako/environment.json` の `lockSha256` が参照先 `nako.lock` の実ダイジェストと
/// 一致することを検証する。形式・構造検証は `validateEnvironment` に委ね、
/// ここでは lock のバイト列から算出した SHA-256 と比較する。不一致は E034。
export function validateEnvironmentReference(environment, lockBytes, fixturePath) {
  validateEnvironment(environment, fixturePath);
  const expected = createHash("sha256").update(lockBytes).digest("hex");
  const actual = normalizeSha256(environment.lockSha256);
  if (actual === null) {
    fail("E034_INVALID_ENVIRONMENT_REFERENCE", `invalid lockSha256 "${environment.lockSha256}"`, `${fixturePath}.lockSha256`);
  }
  if (actual !== expected) {
    fail("E034_INVALID_ENVIRONMENT_REFERENCE", `lockSha256 mismatch: environment ${actual} != lock ${expected}`, `${fixturePath}.lockSha256`);
  }
}
