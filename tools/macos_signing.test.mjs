import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { codeIdentifier, identifier, machoFiles, signPayload, submitNotarization } from "./macos_signing.mjs";

async function fixture(callback) {
  const directory = await mkdtemp(join(tmpdir(), "lnako-signing-test-"));
  try {
    for (const path of ["bin/lnako", "llvm/bin/clang", "llvm/lib/libLLVM-C.dylib"]) {
      await mkdir(join(directory, path, ".."), { recursive: true });
      await writeFile(join(directory, path), Buffer.from("cffaedfe00000000", "hex"));
    }
    await mkdir(join(directory, "lib"));
    await writeFile(join(directory, "lib/runtime.a"), "!<arch>\n");
    await callback(directory);
  } finally { await rm(directory, { recursive: true, force: true }); }
}

test("sign every Mach-O dependency before lnako; only lnako gets the plugin entitlement", async () => {
  await fixture(async (directory) => {
    const calls = [];
    const plist = await readFile(new URL("../packaging/macos/lnako.entitlements", import.meta.url), "utf8");
    const execute = (command, args) => {
      calls.push(args);
      const path = relative(directory, args.at(-1)).replaceAll("\\", "/");
      if (args.includes("--entitlements") && args.includes("--display")) return path === "bin/lnako" ? plist : "";
      if (args.includes("--display")) return `Identifier=${codeIdentifier(path)}\nAuthority=Developer ID Application: Fixture\nTimestamp=Today\nflags=0x10000(runtime)\n`;
      return "";
    };
    await signPayload(directory, { identity: "fixture", keychain: "temporary", execute, platform: "darwin" });
    const signing = calls.filter((args) => args.includes("--sign"));
    assert.deepEqual(signing.map((args) => relative(directory, args.at(-1)).replaceAll("\\", "/")), ["llvm/lib/libLLVM-C.dylib", "llvm/bin/clang", "bin/lnako"]);
    // codesignへ--keychainを渡すとidentity解決に失敗するため渡さない。
    // 一時keychainはsetup側でuser search listへ登録済みという前提で検査する。
    assert(signing.every((args) => args.includes("--timestamp") && !args.includes("--keychain") && !args.includes("--deep")));
    assert(!signing[0].includes("--options"));
    assert(signing[1].includes("runtime"));
    assert(!signing[1].includes("--entitlements"));
    assert(signing[2].includes("--entitlements"));
    assert(signing[2].includes(identifier));
    assert.equal((await machoFiles(directory)).length, 3);
  });
});

test("missing credentials, wrong platform, malformed payload and signature failures stop signing", async () => {
  await fixture(async (directory) => {
    await assert.rejects(signPayload(directory, { platform: "linux" }), /requires macOS/);
    await assert.rejects(signPayload(directory, { platform: "darwin" }), /required/);
    await assert.rejects(signPayload(directory, { identity: "x", keychain: "x", platform: "darwin", execute() { throw new Error("codesign failed"); } }), /codesign failed/);
    await assert.rejects(signPayload(directory, { identity: "x", keychain: "x", platform: "darwin", execute() { return "Signature=adhoc"; } }), /Invalid Developer ID/);
    await writeFile(join(directory, "bin/lnako"), "not a binary");
    await assert.rejects(signPayload(directory, { identity: "x", keychain: "x", platform: "darwin" }), /must be Mach-O/);
  });
});

test("notary logs are fetched for Accepted and Invalid; only Accepted can proceed", async () => {
  for (const status of ["Accepted", "Invalid", "In Progress"]) {
    const calls = [];
    const execute = (command, args) => {
      calls.push(args);
      return args[1] === "submit" ? JSON.stringify({ id: "12345678-1234-1234-1234-123456789012", status }) : "";
    };
    const promise = submitNotarization("payload.zip", ["--key", "fixture.p8"], "log.json", { execute });
    if (status === "Accepted") await promise;
    else await assert.rejects(promise, /not Accepted/);
    assert(calls[0].includes("--wait"));
    assert(calls[0].includes("--timeout"));
    assert.equal(calls[1][1], "log");
  }
  await assert.rejects(submitNotarization("x", [], "log", { execute() { return "{}"; } }), /submission ID/);
});
