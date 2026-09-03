import { access, lstat, mkdir, mkdtemp, readlink, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import { dirname, join, normalize, relative, resolve, sep } from "node:path";
import { tmpdir } from "node:os";

const root = resolve(import.meta.dirname, "..");
const options = parseArguments(process.argv.slice(2));

if (options.selfTest) {
  await selfTest();
  console.log("LLVM toolchain cache prune self-test: 成功");
} else {
  const llvmRoot = options.root ?? process.env.LNAKO_LLVM_DIR;
  if (!llvmRoot) throw new Error("LLVM rootが指定されていません: --root またはLNAKO_LLVM_DIRが必要です");
  const result = await prune(resolve(llvmRoot), process.platform);
  console.log(`LLVM toolchain cacheを縮小しました: ${result.beforeBytes} -> ${result.afterBytes} bytes / ${result.removedEntries} entries removed`);
}

function parseArguments(argumentsList) {
  const result = { root: null, selfTest: false };
  for (let index = 0; index < argumentsList.length; index += 1) {
    const argument = argumentsList[index];
    if (argument === "--self-test") {
      result.selfTest = true;
    } else if (argument === "--root") {
      result.root = argumentsList[++index];
      if (!result.root) throw new Error("--rootにはLLVM rootを指定してください");
    } else {
      throw new Error(`未知の引数です: ${argument}\n使い方: node tools/prune_llvm_toolchain.mjs [--root /absolute/path] [--self-test]`);
    }
  }
  return result;
}

async function prune(llvmRoot, platform) {
  const keep = await requiredPaths(llvmRoot, platform);
  const beforeBytes = await treeBytes(llvmRoot);
  const beforeEntries = await treeEntries(llvmRoot);
  await pruneDirectory(llvmRoot, "", keep, platform);
  await verifyPrunedRoot(llvmRoot, platform, keep);
  const afterBytes = await treeBytes(llvmRoot);
  const afterEntries = await treeEntries(llvmRoot);
  return {
    beforeBytes,
    afterBytes,
    removedEntries: Math.max(0, beforeEntries - afterEntries),
  };
}

async function requiredPaths(llvmRoot, platform) {
  const binaries = platform === "win32"
    ? ["bin/clang.exe", "bin/lld-link.exe"]
    : ["bin/clang", platform === "darwin" ? "bin/ld64.lld" : "bin/ld.lld"];
  const keep = new Set(binaries);
  for (const binary of binaries) {
    const path = join(llvmRoot, ...binary.split("/"));
    const information = await lstat(path).catch(() => null);
    if (information === null) throw new Error(`AOTに必要なLLVM実行ファイルが見つかりません: ${path}`);
    if (information.isSymbolicLink()) {
      const linkTarget = await readlink(path);
      const target = resolve(dirname(path), linkTarget);
      const relativeTarget = toPosix(relative(llvmRoot, target));
      if (relativeTarget.startsWith("../") || relativeTarget === "..") {
        throw new Error(`LLVM実行ファイルのsymlinkがroot外を参照しています: ${path} -> ${linkTarget}`);
      }
      keep.add(relativeTarget);
    }
  }

  const libraries = await findFiles(llvmRoot, (path) => {
    const name = path.split("/").at(-1) ?? "";
    return /^libLLVM-C\.(?:dylib|so(?:\..*)?)$/i.test(name) || /^LLVM-C\.dll$/i.test(name) ||
      (platform === "darwin" && /^(?:libc\+\+(?:abi)?|libunwind)(?:\.\d+(?:\.\d+)*)?\.dylib$/i.test(name));
  });
  if (libraries.length === 0) throw new Error(`生成済みLLVM C API共有ライブラリが見つかりません: ${llvmRoot}`);
  for (const library of libraries) {
    keep.add(library);
    const information = await lstat(join(llvmRoot, ...library.split("/")));
    if (information.isSymbolicLink()) {
      const linkTarget = await readlink(join(llvmRoot, ...library.split("/")));
      const target = resolve(dirname(join(llvmRoot, ...library.split("/"))), linkTarget);
      const relativeTarget = toPosix(relative(llvmRoot, target));
      if (relativeTarget.startsWith("../") || relativeTarget === "..") {
        throw new Error(`LLVM共有ライブラリのsymlinkがroot外を参照しています: ${library} -> ${linkTarget}`);
      }
      keep.add(relativeTarget);
    }
  }
  keep.add("lib/clang/");
  return keep;
}

async function pruneDirectory(directory, directoryPath, keep, platform) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const entryPath = join(directory, entry.name);
    const relativePath = toPosix(join(directoryPath, entry.name));
    if (entry.isDirectory()) {
      if (relativePath === "bin" || relativePath === "lib" || relativePath === "lib/clang" || relativePath.startsWith("lib/clang/")) {
        await pruneDirectory(entryPath, relativePath, keep, platform);
      } else {
        await rm(entryPath, { recursive: true, force: true });
      }
      continue;
    }
    if (!shouldKeepFile(relativePath, keep, platform)) await rm(entryPath, { force: true });
  }
}

function shouldKeepFile(path, keep, platform) {
  if (keep.has(path)) return true;
  if (path.startsWith("lib/clang/")) return true;
  if (platform === "win32" && path.toLowerCase().startsWith("lib/clang/")) return true;
  return false;
}

async function verifyPrunedRoot(llvmRoot, platform, keep) {
  for (const path of keep) {
    if (path.endsWith("/")) continue;
    await access(join(llvmRoot, ...path.split("/"))).catch(() => {
      throw new Error(`LLVM toolchain pruneが必要ファイルを削除しました: ${path}`);
    });
  }
  const expectedDirectories = ["bin", "lib", "lib/clang"];
  for (const path of expectedDirectories) {
    const information = await stat(join(llvmRoot, ...path.split("/"))).catch(() => null);
    if (information === null || !information.isDirectory()) throw new Error(`LLVM toolchain prune後のdirectoryがありません: ${path}`);
  }
  if (platform !== "win32" && !keep.has("lib/libLLVM-C.dylib") && ![...keep].some((path) => path.startsWith("lib/libLLVM-C.so"))) {
    throw new Error(`LLVM toolchain prune後のUnix共有ライブラリが不正です: ${llvmRoot}`);
  }
  if (platform === "darwin" && (!keep.has("lib/libc++.1.dylib") || !keep.has("lib/libc++abi.1.dylib") || !keep.has("lib/libunwind.1.dylib"))) {
    throw new Error(`LLVM C API共有ライブラリのmacOS runtime依存が不正です: ${llvmRoot}`);
  }
}

async function findFiles(directory, predicate, directoryPath = "") {
  const result = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    const relativePath = toPosix(join(directoryPath, entry.name));
    if (entry.isDirectory()) {
      result.push(...await findFiles(path, predicate, relativePath));
    } else if (predicate(relativePath)) {
      result.push(relativePath);
    }
  }
  return result;
}

async function treeBytes(directory) {
  let total = 0;
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) total += await treeBytes(path);
    else total += (await lstat(path)).size;
  }
  return total;
}

async function treeEntries(directory) {
  let total = 0;
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    total += 1;
    if (entry.isDirectory()) total += await treeEntries(join(directory, entry.name));
  }
  return total;
}

async function selfTest() {
  const temporary = await mkdtemp(join(tmpdir(), "lnako-prune-llvm-"));
  try {
    for (const platform of ["darwin", "linux", "win32"]) {
      const fixture = join(temporary, platform);
      await mkdir(join(fixture, "bin"), { recursive: true });
      await mkdir(join(fixture, "lib", "clang", "22", "include"), { recursive: true });
      await writeFile(join(fixture, "lib", "clang", "22", "include", "stddef.h"), "fixture\n");
      await writeFile(join(fixture, "bin", platform === "win32" ? "clang.exe" : "clang"), "clang\n");
      await writeFile(join(fixture, "bin", platform === "win32" ? "lld-link.exe" : platform === "darwin" ? "ld64.lld" : "ld.lld"), "lld\n");
      await writeFile(join(fixture, "bin", platform === "win32" ? "LLVM-C.dll" : platform === "darwin" ? "unused" : "unused"), "library\n");
      if (platform !== "win32") await writeFile(join(fixture, "lib", "libLLVM-C." + (platform === "darwin" ? "dylib" : "so")), "library\n");
      if (platform === "darwin") {
        await writeFile(join(fixture, "lib", "libc++.1.dylib"), "c++\n");
        await writeFile(join(fixture, "lib", "libc++abi.1.dylib"), "c++abi\n");
        await writeFile(join(fixture, "lib", "libunwind.1.dylib"), "unwind\n");
      }
      await writeFile(join(fixture, "bin", "unused-tool"), "remove\n");
      await writeFile(join(fixture, "include-unused.h"), "remove\n");
      await mkdir(join(fixture, "share", "unused"), { recursive: true });
      await writeFile(join(fixture, "share", "unused", "file"), "remove\n");
      await prune(fixture, platform);
      await access(join(fixture, "bin", platform === "win32" ? "clang.exe" : "clang"));
      await access(join(fixture, "bin", platform === "win32" ? "lld-link.exe" : platform === "darwin" ? "ld64.lld" : "ld.lld"));
      await access(join(fixture, "lib", "clang", "22", "include", "stddef.h"));
      await access(join(fixture, platform === "win32" ? "bin/LLVM-C.dll" : `lib/libLLVM-C.${platform === "darwin" ? "dylib" : "so"}`));
      if (platform === "darwin") {
        await access(join(fixture, "lib", "libc++.1.dylib"));
        await access(join(fixture, "lib", "libc++abi.1.dylib"));
        await access(join(fixture, "lib", "libunwind.1.dylib"));
      }
      await assertMissing(join(fixture, "bin", "unused-tool"));
      await assertMissing(join(fixture, "include-unused.h"));
      await assertMissing(join(fixture, "share"));
    }
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

async function assertMissing(path) {
  if (await lstat(path).catch(() => null) !== null) throw new Error(`prune self-testで不要ファイルが残りました: ${path}`);
}

function toPosix(path) {
  return normalize(path).split(sep).join("/");
}
