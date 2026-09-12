import { readdirSync, readFileSync, existsSync, statSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { join, dirname, basename, extname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { DiagnosticError, validateManifest, validateLock, validateRegistryIndex, validateRegistryPackage, validateRegistryVersion, validateNpkgMetadata, validateNpkgCommands } from "./lib/package/schema_validator.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const projectRoot = resolve(__dirname, "..");
const conformanceDir = join(projectRoot, "tools", "package-system", "conformance");

const results = [];
let passed = 0;
let failed = 0;

const defaultLnakoPath = existsSync(join(projectRoot, "zig-out", "bin", "lnako"))
  ? join(projectRoot, "zig-out", "bin", "lnako")
  : "lnako";

function loadJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function tomlToJson(file, lnakoPath = defaultLnakoPath) {
  const tomlText = readFileSync(file, "utf8");
  const tempDir = mkdtempSync(join(tmpdir(), "lnako-toml-"));
  const tempNako3 = join(tempDir, "convert.nako3");
  if (tomlText.includes("』")) {
    throw new Error(`TOML fixture ${file} contains the full-width close quote 『』 delimiter`);
  }
  const script = `T=『${tomlText}』\nJSON変換(TOML取得(T))を表示\n`;
  writeFileSync(tempNako3, script, "utf8");
  try {
    const result = spawnSync(lnakoPath, ["run", tempNako3], { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
    if (result.status !== 0 || result.stderr) {
      throw new Error(`lnako run failed for ${file}: ${result.stderr || result.stdout || "unknown error"}`);
    }
    const output = result.stdout.trim();
    return JSON.parse(output);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

function primaryFixtureFiles(dir) {
  const files = readdirSync(dir).filter((f) => statSync(join(dir, f)).isFile());
  const candidates = [];
  const parents = dirname(dir);
  const category = basename(parents);
  if (category === "manifest") {
    if (files.includes("manifest.json")) candidates.push("manifest.json");
    if (files.includes("nako.toml")) candidates.push("nako.toml");
  } else if (category === "lock") {
    if (files.includes("nako.lock")) candidates.push("nako.lock");
  } else if (category === "registry") {
    for (const f of ["index.json", "package.json", "version.json"]) {
      if (files.includes(f)) candidates.push(f);
    }
  } else if (category === "npkg") {
    for (const f of ["METADATA.json", "commands.json"]) {
      if (files.includes(f)) candidates.push(f);
    }
  }
  return candidates;
}

function loadFixtureValue(file) {
  if (file.endsWith(".toml")) {
    return tomlToJson(file);
  }
  return loadJson(file);
}

function validateFixtureFile(file) {
  const value = loadFixtureValue(file);
  const category = basename(dirname(dirname(file)));
  switch (category) {
    case "manifest":
      validateManifest(value, file);
      break;
    case "lock":
      validateLock(value, file);
      break;
    case "registry": {
      const name = basename(file);
      if (name === "index.json") validateRegistryIndex(value, file);
      else if (name === "package.json") validateRegistryPackage(value, file);
      else if (name === "version.json") validateRegistryVersion(value, file);
      else throw new Error(`unknown registry fixture: ${file}`);
      break;
    }
    case "npkg": {
      const name = basename(file);
      if (name === "METADATA.json") validateNpkgMetadata(value, file);
      else if (name === "commands.json") validateNpkgCommands(value, file);
      else throw new Error(`unknown npkg fixture: ${file}`);
      break;
    }
    default:
      throw new Error(`unknown fixture category: ${category}`);
  }
}

function checkExpected(file, error) {
  const expectedFile = join(dirname(file), "expected.json");
  if (!existsSync(expectedFile)) {
    if (error) return { ok: false, reason: `unexpected error: ${error.code || error.name}: ${error.message}` };
    return { ok: true };
  }
  const expected = loadJson(expectedFile);
  if (!error) {
    return { ok: false, reason: `expected error ${expected.code} but got success` };
  }
  if (error.code !== expected.code) {
    return { ok: false, reason: `expected code ${expected.code}, got ${error.code}: ${error.message}` };
  }
  const text = `${error.message}`;
  if (expected.messageContains && !text.includes(expected.messageContains)) {
    return { ok: false, reason: `expected message to contain "${expected.messageContains}", got "${text}"` };
  }
  return { ok: true, expected: true };
}

function processFixtureSet(dir, status) {
  const category = basename(dirname(dir));
  const name = relative(conformanceDir, dir);
  const files = primaryFixtureFiles(dir);
  if (files.length === 0) {
    results.push({ name, status, result: "skip", reason: "no primary fixture" });
    return;
  }
  for (const fixture of files) {
    const file = join(dir, fixture);
    let error = null;
    try {
      validateFixtureFile(file);
    } catch (e) {
      error = e;
    }
    const { ok, reason } = checkExpected(file, error);
    if (ok) {
      passed++;
      results.push({ name: `${name}/${fixture}`, status, result: "pass" });
    } else {
      failed++;
      results.push({ name: `${name}/${fixture}`, status, result: "FAIL", reason });
      console.error(`FAIL: ${name}/${fixture}: ${reason}`);
    }
  }
}

function walkFixtures(base) {
  const status = basename(base);
  for (const category of readdirSync(base)) {
    const categoryDir = join(base, category);
    if (!statSync(categoryDir).isDirectory()) continue;
    for (const fixture of readdirSync(categoryDir)) {
      const fixtureDir = join(categoryDir, fixture);
      if (!statSync(fixtureDir).isDirectory()) continue;
      processFixtureSet(fixtureDir, status);
    }
  }
}

walkFixtures(join(conformanceDir, "valid"));
walkFixtures(join(conformanceDir, "invalid"));

console.log(`Package schema conformance: ${passed} passed, ${failed} failed`);

if (failed > 0) {
  process.exit(1);
}
