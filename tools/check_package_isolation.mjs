#!/usr/bin/env node
// build.zig.zon の .paths 収録内容だけで通常buildと最小consumerが成立するか、
// 作業checkoutの追跡ファイルから一時snapshot tarballを作り、実際に zig fetch
// して選別後packageを独立したroot/cacheで検証する。リポジトリ直下での
// zig fetch . は行わない（.git・cacheの巨大なコピーを避けるため）。
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createHash } from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import zlib from "node:zlib";

const execFileAsync = promisify(execFile);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function fail(message) {
  throw new Error(`package分離検査: ${message}`);
}

async function run(command, args, options = {}) {
  const result = await execFileAsync(command, args, {
    cwd: options.cwd ?? repoRoot,
    env: { ...process.env, ...options.env },
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: 900_000,
  });
  return options.stderr ? `${result.stdout}\n${result.stderr}` : result.stdout;
}

// gitの追跡・非無視ファイル一覧から作業tree状態のsnapshotを作る。
async function trackedFiles() {
  const out = await run("git", ["ls-files", "-c", "-o", "--exclude-standard", "-z"]);
  return out.split("\0").filter((name) => name.length > 0);
}

// ustar形式の最小packer。外部tarコマンドへ依存せずWindowsでも同一動作にする。
function octal(value, length) {
  return Buffer.concat([Buffer.from(value.toString(8).padStart(length - 1, "0"), "ascii"), Buffer.from([0])]);
}

function tarHeader(name, size, type) {
  const header = Buffer.alloc(512, 0);
  const nameBuffer = Buffer.from(name, "utf8");
  if (nameBuffer.length > 100) fail(`tar entry名が長すぎます: ${name}`);
  nameBuffer.copy(header, 0);
  octal(0o644, 8).copy(header, 100);
  octal(0, 8).copy(header, 108);
  octal(0, 8).copy(header, 116);
  octal(size, 12).copy(header, 124);
  octal(0, 12).copy(header, 136);
  header[156] = type.charCodeAt(0);
  Buffer.from("ustar\0", "ascii").copy(header, 257);
  Buffer.from("00", "ascii").copy(header, 263);
  header.fill(0x20, 148, 156);
  let sum = 0;
  for (let index = 0; index < 512; index += 1) sum += header[index];
  octal(sum, 8).copy(header, 148);
  return header;
}

function buildTarball(snapshotDir, files) {
  const chunks = [];
  const directories = new Set();
  for (const relative of files.sort()) {
    let directory = path.posix.dirname(relative);
    while (directory !== "." && !directories.has(directory)) {
      directories.add(directory);
      chunks.push(tarHeader(`${directory}/`, 0, "5"));
      directory = path.posix.dirname(directory);
    }
    const body = fs.readFileSync(path.join(snapshotDir, relative));
    chunks.push(tarHeader(relative, body.length, "0"), body);
    const padding = (512 - (body.length % 512)) % 512;
    if (padding > 0) chunks.push(Buffer.alloc(padding, 0));
  }
  chunks.push(Buffer.alloc(1024, 0));
  return Buffer.concat(chunks);
}

// fetchされたpackage（.paths選別済み）の内容を検査する。
function verifyPackageContent(packageDir) {
  const zon = fs.readFileSync(path.join(packageDir, "build.zig.zon"), "utf8");
  const pathEntries = [...zon.matchAll(/^\s*"([^"]+)",?$/gm)].map((match) => match[1]);
  if (pathEntries.length === 0) fail("build.zig.zonの.pathsを読み取れません");
  const present = new Set();
  const generated = new Set([".zig-cache", "zig-cache", "zig-out", "zig-pkg"]);
  const walk = (relative) => {
    for (const entry of fs.readdirSync(path.join(packageDir, relative), { withFileTypes: true })) {
      const child = path.posix.join(relative, entry.name);
      if (entry.isDirectory()) {
        if (!generated.has(entry.name)) walk(child);
      } else present.add(child);
    }
  };
  walk("");
  const prefixes = new Set();
  for (const entry of pathEntries) {
    prefixes.add(entry);
    prefixes.add(`${entry}/`);
  }
  for (const file of present) {
    const covered = [...prefixes].some((prefix) => file === prefix || file.startsWith(prefix));
    if (!covered) fail(`.paths外のファイルがfetch packageに残っています: ${file}`);
  }
  for (const required of ["compat/v3.7.24/summary.json", "include/lnako_plugin_v1.h", "tests/native_plugin/fixture.c", "src/main.zig", "tools/lexer_probe.zig"]) {
    if (!present.has(required)) fail(`fetch packageに必要ファイルがありません: ${required}`);
  }
  for (const forbidden of [".github", "docs", "compat/v3.7.24/evidence.json", "tests/oracle"]) {
    if (fs.existsSync(path.join(packageDir, forbidden))) fail(`.paths外の内容がfetch packageに残っています: ${forbidden}`);
  }
}

async function main() {
  await run("zig", ["version"]);
  const work = fs.mkdtempSync(path.join(os.tmpdir(), "lnako-package-isolation-"));
  try {
    const snapshotDir = path.join(work, "snapshot");
    const files = await trackedFiles();
    for (const relative of files) {
      const to = path.join(snapshotDir, relative);
      fs.mkdirSync(path.dirname(to), { recursive: true });
      fs.copyFileSync(path.join(repoRoot, relative), to);
    }
    const tarball = zlib.gzipSync(buildTarball(snapshotDir, files));
    const archiveHash = createHash("sha256").update(tarball).digest("hex");
    console.log(`package分離検査: snapshot ${files.length}ファイル / tar+gzip sha256=${archiveHash}`);

    // zig fetchはfile://ではなくHTTP URLで行い、実fetch経路を再現する。
    const server = http.createServer((request, response) => {
      if (request.url !== "/lnako-source.tar.gz") {
        response.statusCode = 404;
        response.end();
        return;
      }
      response.setHeader("content-type", "application/gzip");
      response.end(tarball);
    });
    const port = await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", () => resolve(server.address().port));
    });

    const consumer = path.join(work, "consumer");
    fs.mkdirSync(consumer);
    fs.writeFileSync(path.join(consumer, "build.zig"), `const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("lnako", .{ .target = target, .optimize = optimize });
    b.installArtifact(dep.artifact("lnako"));
    const probe = b.addExecutable(.{
        .name = "consumer-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lnako", .module = dep.module("lnako") }},
        }),
    });
    b.installArtifact(probe);
}
`);
    fs.writeFileSync(path.join(consumer, "main.zig"), `const std = @import("std");
const lnako = @import("lnako");
pub fn main() void {
    std.debug.print("lnako version: {s}\\n", .{lnako.version});
}
`);
    fs.writeFileSync(path.join(consumer, "build.zig.zon"), `.{
    .name = .lnako_consumer_probe,
    .version = "0.0.0",
    .fingerprint = 0x62d261fceddb247e,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{ "build.zig", "build.zig.zon", "main.zig" },
}
`);
    const zigEnv = {
      ZIG_GLOBAL_CACHE_DIR: path.join(work, "zig-global-cache"),
      ZIG_LOCAL_CACHE_DIR: path.join(work, "zig-local-cache"),
    };
    const url = `http://127.0.0.1:${port}/lnako-source.tar.gz`;
    try {
      await run("zig", ["fetch", "--save", url], { cwd: consumer, env: zigEnv });
    } finally {
      server.close();
    }
    const consumerZon = fs.readFileSync(path.join(consumer, "build.zig.zon"), "utf8");
    const hashMatch = consumerZon.match(/\.hash\s*=\s*"([^"]+)"/);
    if (!hashMatch) fail("zig fetchが依存hashを記録しませんでした");
    console.log(`package分離検査: zig fetch成功 ${hashMatch[1]}`);

    await run("zig", ["build"], { cwd: consumer, env: zigEnv });
    const suffix = process.platform === "win32" ? ".exe" : "";
    const lnakoBinary = path.join(consumer, "zig-out", "bin", `lnako${suffix}`);
    if (!fs.existsSync(lnakoBinary)) fail("consumerがlnako実行ファイルをbuildできませんでした");
    const probe = path.join(consumer, "zig-out", "bin", `consumer-probe${suffix}`);
    const probeOut = (await run(probe, [], { cwd: consumer, env: zigEnv, stderr: true })).trim();
    if (!probeOut.includes("lnako version:")) fail(`consumer probeの出力が不正です: ${probeOut}`);
    console.log(`package分離検査: consumer build成功 (${probeOut})`);

    // 選別後packageそのものの通常buildとfixture stepも独立cacheで確認する。
    const zigPkgRoot = path.join(consumer, "zig-pkg");
    const candidates = fs.existsSync(zigPkgRoot)
      ? fs.readdirSync(zigPkgRoot).map((name) => path.join(zigPkgRoot, name))
      : [path.join(zigEnv.ZIG_GLOBAL_CACHE_DIR, "p", hashMatch[1])];
    const packageDir = candidates.find((candidate) => fs.existsSync(path.join(candidate, "build.zig")));
    if (!packageDir) fail("fetch済みpackageの展開先を特定できません");
    verifyPackageContent(packageDir);
    const packageEnv = { ...zigEnv, ZIG_LOCAL_CACHE_DIR: path.join(work, "pkg-local-cache") };
    await run("zig", ["build"], { cwd: packageDir, env: packageEnv });
    await run("zig", ["build", "native-plugin-fixture"], { cwd: packageDir, env: packageEnv });
    console.log("package分離検査: fetch済みpackageの通常buildとnative plugin fixtureに成功");
    console.log("package分離検査: 成功");
  } catch (error) {
    if (error?.stderr) {
      const detail = error.stderr.toString().trim().split("\n").slice(0, 20).join("\n");
      if (detail.length > 0) fail(detail);
    }
    throw error;
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
