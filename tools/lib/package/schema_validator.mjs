import { readdirSync, readFileSync } from "node:fs";
import { join, dirname, basename, relative } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const projectRoot = join(__dirname, "..", "..", "..");
const schemaDir = join(projectRoot, "tools", "package-system", "schema");

const knownManifestSchemaVersions = new Set([1]);
const knownLockSchemaVersions = new Set([1]);
const knownArtifactKinds = new Set(["source", "native", "ESM"]);
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
  if (schema === false) fail("SCHEMA_ERROR", `value not allowed at ${path}`, path);

  if (schema.$ref) {
    // already dereferenced, but just in case
    validateSchema(value, resolveRef(schema.$ref, schema.__baseFile ?? "common.schema.json"), path);
    return;
  }

  if (schema.type) {
    const actual = Array.isArray(value) ? "array" : value === null ? "null" : typeof value;
    const allowed = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (schema.type === "integer" && typeof value === "number" && Number.isInteger(value)) {
      // ok
    } else if (schema.type === "object" && actual === "object" && value !== null) {
      // ok
    } else if (!allowed.includes(actual)) {
      fail("SCHEMA_ERROR", `expected ${schema.type}, got ${actual} at ${path}`, path);
    }
  }

  if (schema.enum && !schema.enum.includes(value)) {
    fail("SCHEMA_ERROR", `expected one of ${schema.enum.join(", ")}, got ${JSON.stringify(value)} at ${path}`, path);
  }

  if ("const" in schema && value !== schema.const) {
    fail("SCHEMA_ERROR", `expected ${JSON.stringify(schema.const)}, got ${JSON.stringify(value)} at ${path}`, path);
  }

  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) {
      fail("SCHEMA_ERROR", `${value} < minimum ${schema.minimum} at ${path}`, path);
    }
    if (schema.maximum !== undefined && value > schema.maximum) {
      fail("SCHEMA_ERROR", `${value} > maximum ${schema.maximum} at ${path}`, path);
    }
    if (schema.exclusiveMinimum !== undefined && value <= schema.exclusiveMinimum) {
      fail("SCHEMA_ERROR", `${value} <= exclusiveMinimum at ${path}`, path);
    }
    if (schema.exclusiveMaximum !== undefined && value >= schema.exclusiveMaximum) {
      fail("SCHEMA_ERROR", `${value} >= exclusiveMaximum at ${path}`, path);
    }
  }

  if (typeof value === "string") {
    if (schema.pattern) {
      const re = new RegExp(schema.pattern);
      if (!re.test(value)) {
        fail("SCHEMA_ERROR", `value "${value}" does not match pattern ${schema.pattern} at ${path}`, path);
      }
    }
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      fail("SCHEMA_ERROR", `string at ${path} is too short`, path);
    }
    if (schema.maxLength !== undefined && value.length > schema.maxLength) {
      fail("SCHEMA_ERROR", `string at ${path} is too long`, path);
    }
  }

  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      fail("SCHEMA_ERROR", `array at ${path} has too few items`, path);
    }
    if (schema.maxItems !== undefined && value.length > schema.maxItems) {
      fail("SCHEMA_ERROR", `array at ${path} has too many items`, path);
    }
    if (schema.uniqueItems) {
      const seen = new Set();
      for (const item of value) {
        const key = JSON.stringify(item);
        if (seen.has(key)) fail("SCHEMA_ERROR", `duplicate array item at ${path}`, path);
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
          fail("SCHEMA_ERROR", `missing required property "${key}" at ${path}`, path);
        }
      }
    }

    if (schema.minProperties !== undefined && keys.length < schema.minProperties) {
      fail("SCHEMA_ERROR", `object at ${path} has too few properties`, path);
    }

    if (schema.additionalProperties === false) {
      const allowed = new Set(Object.keys(schema.properties || {}));
      for (const key of keys) {
        if (!allowed.has(key)) {
          fail("SCHEMA_ERROR", `additional property "${key}" not allowed at ${path}`, path);
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
    let matched = 0;
    let lastError = null;
    for (const sub of schema.oneOf) {
      try {
        validateSchema(value, sub, path);
        matched++;
      } catch (e) {
        lastError = e;
      }
    }
    if (matched !== 1) {
      fail("SCHEMA_ERROR", `expected exactly one of ${schema.oneOf.length} schemas at ${path} (matched ${matched})`, path);
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
    if (!matched) fail("SCHEMA_ERROR", `expected one of anyOf schemas at ${path}`, path);
  }

  if (schema.allOf) {
    for (const sub of schema.allOf) {
      validateSchema(value, sub, path);
    }
  }
}

export function validateManifest(manifest, fixturePath) {
  if (!manifest.package) {
    fail("E019_REQUIRED_FIELD_MISSING", `missing required field "package"`, fixturePath);
  }

  validateBySchemaFile(manifest, "nako.toml.schema.json", fixturePath);

  const pkg = manifest.package;
  if (pkg && "schema-version" in pkg && !knownManifestSchemaVersions.has(pkg["schema-version"])) {
    fail("E001_UNKNOWN_MANIFEST_SCHEMA", `unknown manifest schema version ${pkg["schema-version"]}`, `${fixturePath}.package.schema-version`);
  }

  if (manifest.profiles) {
    for (const [name, prof] of Object.entries(manifest.profiles)) {
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
    for (const exp of manifest.exports) {
      if (exp.esm && !hasCompatJsProfile) {
        fail("E006_JS_IN_NORMAL_MODE", `ESM export "${exp.name}" requires compat-js profile`, `${fixturePath}.exports`);
      }
    }
  }

  if (manifest.dependencies?.pkg) {
    const byPublicId = new Map();
    for (const [alias, dep] of Object.entries(manifest.dependencies.pkg)) {
      if (dep["public-id"]) {
        const existing = byPublicId.get(dep["public-id"]);
        if (existing && existing.version !== dep.version) {
          fail("E003_CONFLICTING_VERSIONS", `conflicting version constraints for ${dep["public-id"]}: ${existing.version} vs ${dep.version}`, `${fixturePath}.dependencies.pkg`);
        }
        byPublicId.set(dep["public-id"], dep);
      }
    }
  }
}

export function validateLock(lock, fixturePath) {
  validateBySchemaFile(lock, "nako.lock.schema.json", fixturePath);

  if (!knownLockSchemaVersions.has(lock.schemaVersion)) {
    fail("E002_UNKNOWN_LOCK_SCHEMA", `unknown lock schema version ${lock.schemaVersion}`, `${fixturePath}.schemaVersion`);
  }

  const target = lock.input?.target;
  const targetCompatJs = target && lock.profiles?.[lock.input.profile]?.["compat-js"] === true;

  for (const [id, pkg] of Object.entries(lock.packages)) {
    if (!pkg.artifacts || Object.keys(pkg.artifacts).length === 0) {
      fail("E008_MISSING_ARTIFACT", `package ${id} has no artifacts`, `${fixturePath}.packages.${id}.artifacts`);
    }
    for (const [kind, artifact] of Object.entries(pkg.artifacts)) {
      if (!knownArtifactKinds.has(artifact.kind)) {
        fail("E007_UNKNOWN_ARTIFACT_KIND", `unknown artifact kind "${artifact.kind}" at ${fixturePath}.packages.${id}.artifacts.${kind}`, `${fixturePath}.packages.${id}.artifacts.${kind}`);
      }
      if (artifact.kind === "ESM" && !targetCompatJs) {
        fail("E006_JS_IN_NORMAL_MODE", `ESM artifact selected without compat-js profile`, `${fixturePath}.packages.${id}.artifacts.${kind}`);
      }
    }
    for (const dep of pkg.dependencies) {
      if (!(dep in lock.packages)) {
        fail("E013_MISSING_PACKAGE", `dependency ${dep} not found in lock packages`, `${fixturePath}.packages.${id}.dependencies`);
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
