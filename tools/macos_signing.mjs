import { appendFile, chmod, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { basename, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
export const identifier = "io.github.soramikan.lnako";
const entitlements = join(root, "packaging/macos/lnako.entitlements");

// Never include command arguments or child output in errors: security/notarytool
// commands can contain credentials. Notary logs are fetched separately.
export function run(command, args, options = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", maxBuffer: 16 * 1024 * 1024, ...options });
  if (result.error || result.status !== 0) throw new Error(`${basename(command)} failed (status ${result.status})`);
  return `${result.stdout ?? ""}${result.stderr ?? ""}`;
}

export async function machoFiles(directory, prefix = "") {
  const result = [];
  for (const entry of await readdir(join(directory, prefix), { withFileTypes: true })) {
    const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
    if (entry.isDirectory()) result.push(...await machoFiles(directory, relative));
    else if (entry.isFile()) {
      const bytes = await readFile(join(directory, relative));
      const magic = bytes.subarray(0, 4).toString("hex");
      if (["cffaedfe", "feedfacf", "cefaedfe", "feedface", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"].includes(magic)) result.push(relative);
    } else throw new Error(`Unsupported signing payload entry: ${relative}`);
  }
  return result.sort((a, b) => signingRank(a) - signingRank(b) || a.localeCompare(b));
}

function signingRank(path) { return path === "bin/lnako" ? 2 : path.endsWith(".dylib") ? 0 : 1; }
export function codeIdentifier(path) {
  return path === "bin/lnako" ? identifier : `${identifier}.toolchain.${basename(path).replaceAll("+", "p")}`;
}

export async function signPayload(directory, { identity, keychain, execute = run, platform = process.platform } = {}) {
  if (platform !== "darwin") throw new Error("macOS signing requires macOS");
  if (!identity || !keychain) throw new Error("macOS signing identity and keychain are required");
  const paths = await machoFiles(directory);
  if (!paths.includes("bin/lnako")) throw new Error("bin/lnako must be Mach-O");
  for (const path of paths) {
    const args = ["--force", "--timestamp", "--sign", identity, "--keychain", keychain, "--identifier", codeIdentifier(path)];
    if (!path.endsWith(".dylib")) args.push("--options", "runtime");
    if (path === "bin/lnako") args.push("--entitlements", entitlements);
    execute("/usr/bin/codesign", [...args, join(directory, path)]);
  }
  await verifyPayload(directory, { execute });
}

export async function verifyPayload(directory, { execute = run } = {}) {
  const paths = await machoFiles(directory);
  if (!paths.includes("bin/lnako")) throw new Error("bin/lnako must be Mach-O");
  for (const path of paths) {
    const file = join(directory, path);
    execute("/usr/bin/codesign", ["--verify", "--strict", "--verbose=2", file]);
    const details = execute("/usr/bin/codesign", ["--display", "--verbose=4", file]);
    if (!details.includes(`Identifier=${codeIdentifier(path)}\n`) ||
        !details.includes("Authority=Developer ID Application:") || !/^Timestamp=.+$/m.test(details) ||
        (!path.endsWith(".dylib") && !details.includes("runtime"))) {
      throw new Error(`Invalid Developer ID signature: ${path}`);
    }
    const xml = execute("/usr/bin/codesign", ["--display", "--entitlements", ":-", file]);
    const keys = [...xml.matchAll(/<key>([^<]+)<\/key>/g)].map((match) => match[1]);
    if (path === "bin/lnako") {
      if (keys.length !== 1 || keys[0] !== "com.apple.security.cs.disable-library-validation" ||
          !/<key>com.apple.security.cs.disable-library-validation<\/key>\s*<true\s*\/>/.test(xml)) {
        throw new Error("lnako signing entitlements do not match the plugin contract");
      }
    } else if (keys.length) throw new Error(`Unexpected helper entitlements: ${path}`);
  }
  return paths;
}

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Required secret/environment variable is missing: ${name}`);
  return value;
}

async function setup() {
  const names = ["MACOS_CERTIFICATE_P12_BASE64", "MACOS_CERTIFICATE_PASSWORD", "APPLE_NOTARY_KEY_P8_BASE64", "APPLE_NOTARY_KEY_ID", "APPLE_NOTARY_ISSUER_ID"];
  names.forEach(required);
  const temporary = await mkdtemp(join(required("RUNNER_TEMP"), "lnako-signing-"));
  await chmod(temporary, 0o700);
  const keychain = join(temporary, "signing.keychain-db");
  // Persist cleanup paths before import so always() also handles partial setup.
  await appendFile(required("GITHUB_ENV"), `LNAKO_SIGNING_TEMP=${temporary}\nLNAKO_SIGNING_KEYCHAIN=${keychain}\n`);
  const password = randomBytes(32).toString("hex");
  const p12 = join(temporary, "certificate.p12");
  const key = join(temporary, "AuthKey.p8");
  await writeFile(p12, Buffer.from(required(names[0]), "base64"), { mode: 0o600 });
  await writeFile(key, Buffer.from(required(names[2]), "base64"), { mode: 0o600 });
  try {
    run("/usr/bin/security", ["create-keychain", "-p", password, keychain]);
    run("/usr/bin/security", ["set-keychain-settings", "-lut", "21600", keychain]);
    run("/usr/bin/security", ["unlock-keychain", "-p", password, keychain]);
    run("/usr/bin/security", ["import", p12, "-P", required(names[1]), "-k", keychain, "-T", "/usr/bin/codesign"]);
    run("/usr/bin/security", ["set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain]);
    const identities = run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning", keychain]);
    const matches = [...identities.matchAll(/\b([A-Fa-f0-9]{40})\s+"Developer ID Application:[^"]+"/g)];
    if (matches.length !== 1) throw new Error("Exactly one Developer ID Application identity is required");
    await appendFile(required("GITHUB_ENV"), `LNAKO_SIGNING_IDENTITY=${matches[0][1]}\n`);
  } finally { await rm(p12, { force: true }); }
}

async function cleanup() {
  try {
    if (process.env.LNAKO_SIGNING_KEYCHAIN) run("/usr/bin/security", ["delete-keychain", process.env.LNAKO_SIGNING_KEYCHAIN]);
  } finally {
    if (process.env.LNAKO_SIGNING_TEMP) await rm(process.env.LNAKO_SIGNING_TEMP, { recursive: true, force: true });
  }
}

export async function submitNotarization(zip, auth, log, { execute = run } = {}) {
  // notarytool may return nonzero for a rejected submission. Capture its JSON
  // anyway so we can fetch diagnostics, while still rejecting every non-Accepted state.
  const response = execute("/usr/bin/xcrun", ["notarytool", "submit", zip, ...auth, "--wait", "--timeout", "30m", "--output-format", "json"]);
  const submission = JSON.parse(response);
  if (!/^[0-9a-f-]{36}$/i.test(submission.id ?? "")) throw new Error("Missing notary submission ID");
  if (process.env.GITHUB_STEP_SUMMARY) await appendFile(process.env.GITHUB_STEP_SUMMARY, `macOS notarization: ${submission.id} (${submission.status})\n`);
  execute("/usr/bin/xcrun", ["notarytool", "log", submission.id, ...auth, log]);
  if (submission.status !== "Accepted") throw new Error(`Notarization was not Accepted: ${submission.id}`);
  return submission;
}

async function notarize(archive) {
  const temporary = await mkdtemp(join(required("RUNNER_TEMP"), "lnako-notary-"));
  try {
    // Validate before extraction; the existing checker rejects traversal/extra entries.
    run(process.execPath, [join(root, "tools/check_distribution.mjs"), "--archive", archive]);
    run("/usr/bin/tar", ["-xzf", archive, "-C", temporary]);
    const tree = join(temporary, basename(archive).replace(/\.tar\.gz$/, ""));
    const paths = await verifyPayload(tree);
    // Exercise actual signed compiler, including loading foreign/ad-hoc plugins.
    const env = { ...process.env, LNAKO_TEST_EXECUTABLE: join(tree, "bin/lnako") };
    if (basename(archive).endsWith("-full.tar.gz")) {
      delete env.LNAKO_LLVM_DIR;
      delete env.LNAKO_LLVM_LIBRARY;
    }
    run(process.execPath, [join(root, "tools/check_native_plugin_abi.mjs"), "--release-safe"], { env });
    run(join(tree, "bin/lnako"), ["run", join(root, "tests/fixtures/compat-js-basic.nako3"), "--compat-js"], { env });
    const zip = join(temporary, "notarization.zip");
    run("/usr/bin/ditto", ["-c", "-k", "--keepParent", tree, zip]);
    const auth = ["--key", join(required("LNAKO_SIGNING_TEMP"), "AuthKey.p8"), "--key-id", required("APPLE_NOTARY_KEY_ID"), "--issuer", required("APPLE_NOTARY_ISSUER_ID")];
    const log = join(required("RUNNER_TEMP"), `${basename(archive)}.notary-log.json`);
    await submitNotarization(zip, auth, log, { execute(command, args) {
      if (args[1] !== "submit") return run(command, args);
      const result = spawnSync(command, args, { encoding: "utf8", timeout: 32 * 60 * 1000 });
      if (result.error || !result.stdout) throw new Error("notarytool submission failed; no JSON response");
      return result.stdout;
    } });
    // spctl's execute assessment is for apps, not standalone CLI/dylib code.
    // Require Apple's online notarization ticket for every shipped Mach-O.
    for (const path of paths) {
      run("/usr/bin/codesign", ["--verify", "--strict", "--verbose=4", "-R=notarized", "--check-notarization", join(tree, path)]);
    }
  } finally { await rm(temporary, { recursive: true, force: true }); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  if (process.platform !== "darwin") throw new Error("macOS signing requires macOS");
  const [command, ...args] = process.argv.slice(2);
  if (command === "setup") await setup();
  else if (command === "cleanup") await cleanup();
  else if (command === "notarize" && args.length) { for (const archive of args) await notarize(resolve(archive)); }
  else throw new Error("Usage: node tools/macos_signing.mjs setup|cleanup|notarize <archives...>");
}
