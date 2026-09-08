const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const marker_file_name = ".lnako-toolchain.json";
pub const toolchain_dir_env = "LNAKO_TOOLCHAIN_DIR";
const lock_json = build_options.toolchain_lock_json;
const max_download_bytes = 4 * 1024 * 1024 * 1024;

pub const LockInfo = struct {
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
};

pub const Marker = struct {
    version: []const u8,
    platform: []const u8,
    sha256: ?[]const u8 = null,
    source: []const u8,
};

pub const InstallOptions = struct {
    archive_path: ?[]const u8 = null,
    from_dir: ?[]const u8 = null,
    url_override: ?[]const u8 = null,
    sha256_override: ?[]const u8 = null,
    force: bool = false,
};

pub const InstallResult = struct {
    root: []const u8,
    already_present: bool,
};

/// toolchain.lock.jsonのartifacts key。正式対応OS以外はnullを返す。
pub fn platformKey() ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => if (builtin.cpu.arch == .aarch64) "macos-aarch64" else null,
        .linux => if (builtin.cpu.arch == .x86_64) "linux-x86_64" else null,
        .windows => if (builtin.cpu.arch == .x86_64) "windows-x86_64" else null,
        else => null,
    };
}

/// 埋め込みtoolchain.lock.jsonからLLVMエントリを取り出す。
pub fn llvmLock(allocator: std.mem.Allocator) !LockInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, lock_json, .{});
    defer parsed.deinit();
    const llvm = parsed.value.object.get("llvm") orelse return error.ToolchainLockMissingLlvm;
    const version = llvm.object.get("version") orelse return error.ToolchainLockInvalid;
    const artifacts = llvm.object.get("artifacts") orelse return error.ToolchainLockInvalid;
    const key = platformKey() orelse return error.ToolchainUnsupportedHost;
    const artifact = artifacts.object.get(key) orelse return error.ToolchainLockMissingArtifact;
    const url = artifact.object.get("url") orelse return error.ToolchainLockInvalid;
    const sha256 = artifact.object.get("sha256") orelse return error.ToolchainLockInvalid;
    if (version != .string or url != .string or sha256 != .string) return error.ToolchainLockInvalid;
    if (!isSha256Hex(sha256.string)) return error.ToolchainLockInvalid;
    return .{
        .version = try allocator.dupe(u8, version.string),
        .url = try allocator.dupe(u8, url.string),
        .sha256 = try allocator.dupe(u8, sha256.string),
    };
}

fn freeLock(allocator: std.mem.Allocator, lock: LockInfo) void {
    allocator.free(lock.version);
    allocator.free(lock.url);
    allocator.free(lock.sha256);
}

fn isSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

/// 管理toolchainのルート。LNAKO_TOOLCHAIN_DIRがあればそれを使い、なければ
/// OS標準のキャッシュdir配下（再download可能なためcache扱い。
/// macOS: ~/Library/Caches/lnako、Linux: $XDG_CACHE_HOMEまたは~/.cache/lnako、
/// Windows: %LOCALAPPDATA%\lnako\Cache）。
pub fn toolchainsRoot(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get(toolchain_dir_env)) |override| {
        if (override.len == 0) return error.ToolchainDirEnvEmpty;
        return allocator.dupe(u8, override);
    }
    const base: []const u8 = switch (builtin.os.tag) {
        .macos => blk: {
            const home = environ.get("HOME") orelse return error.HomeDirectoryNotFound;
            break :blk try std.fs.path.join(allocator, &.{ home, "Library", "Caches", "lnako" });
        },
        .windows => blk: {
            if (environ.get("LOCALAPPDATA")) |local| break :blk try std.fs.path.join(allocator, &.{ local, "lnako", "Cache" });
            const profile = environ.get("USERPROFILE") orelse return error.HomeDirectoryNotFound;
            break :blk try std.fs.path.join(allocator, &.{ profile, "AppData", "Local", "lnako", "Cache" });
        },
        else => blk: {
            if (environ.get("XDG_CACHE_HOME")) |xdg| break :blk try std.fmt.allocPrint(allocator, "{s}/lnako", .{xdg});
            const home = environ.get("HOME") orelse return error.HomeDirectoryNotFound;
            break :blk try std.fs.path.join(allocator, &.{ home, ".cache", "lnako" });
        },
    };
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "toolchains" });
}

pub fn managedLlvmRoot(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const lock = try llvmLock(allocator);
    defer freeLock(allocator, lock);
    const root = try toolchainsRoot(allocator, environ);
    defer allocator.free(root);
    const key = platformKey() orelse return error.ToolchainUnsupportedHost;
    const name = try std.fmt.allocPrint(allocator, "llvm-{s}-{s}", .{ lock.version, key });
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ root, name });
}

fn clangFileName() []const u8 {
    return if (builtin.os.tag == .windows) "clang.exe" else "clang";
}

fn lldFileName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "ld64.lld",
        .windows => "lld-link.exe",
        else => "ld.lld",
    };
}

fn fileExists(io: std.Io, root: []const u8, relative: []const u8) bool {
    const path = std.fs.path.join(std.heap.page_allocator, &.{ root, relative }) catch return false;
    defer std.heap.page_allocator.free(path);
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// LLVM C API共有ライブラリ候補（api.zigのrooted候補と対応）。
const llvm_library_candidates: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{ "bin/LLVM-C.dll", "bin/LLVM.dll", "bin/libLLVM.dll" },
    .macos => &.{ "lib/libLLVM-C.dylib", "lib/libLLVM.dylib" },
    else => &.{ "lib/libLLVM-C.so", "lib/libLLVM.so" },
};

pub fn llvmLibraryPresent(io: std.Io, root: []const u8) bool {
    for (llvm_library_candidates) |relative| if (fileExists(io, root, relative)) return true;
    // バージョン付きsoname（libLLVM.so.22.1等）をbinまたはlib配下から探索する。
    const lib_dir = std.fs.path.join(std.heap.page_allocator, &.{ root, if (builtin.os.tag == .windows) "bin" else "lib" }) catch return false;
    defer std.heap.page_allocator.free(lib_dir);
    var directory = std.Io.Dir.cwd().openDir(io, lib_dir, .{ .iterate = true }) catch return false;
    defer directory.close(io);
    var iterator = directory.iterate();
    while (iterator.next(io) catch return false) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (isLlvmLibraryName(entry.name)) return true;
    }
    return false;
}

fn isLlvmLibraryName(name: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.endsWithIgnoreCase(name, ".dll") and std.ascii.indexOfIgnoreCase(name, "llvm") != null;
    if (builtin.os.tag == .macos) return std.mem.startsWith(u8, name, "libLLVM") and std.mem.endsWith(u8, name, ".dylib");
    return std.mem.startsWith(u8, name, "libLLVM") and std.mem.indexOf(u8, name, ".so") != null;
}

pub fn readMarker(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ?Marker {
    const path = std.fs.path.join(allocator, &.{ root, marker_file_name }) catch return null;
    defer allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024)) catch return null;
    defer allocator.free(text);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    const version = object.get("version") orelse return null;
    const platform = object.get("platform") orelse return null;
    const source = object.get("source") orelse return null;
    if (version != .string or platform != .string or source != .string) return null;
    var sha256: ?[]const u8 = null;
    if (object.get("sha256")) |value| {
        switch (value) {
            .string => sha256 = allocator.dupe(u8, value.string) catch return null,
            .null => {},
            else => return null,
        }
    }
    return .{
        .version = allocator.dupe(u8, version.string) catch return null,
        .platform = allocator.dupe(u8, platform.string) catch return null,
        .sha256 = sha256,
        .source = allocator.dupe(u8, source.string) catch return null,
    };
}

pub fn freeMarker(allocator: std.mem.Allocator, marker: Marker) void {
    allocator.free(marker.version);
    allocator.free(marker.platform);
    if (marker.sha256) |value| allocator.free(value);
    allocator.free(marker.source);
}

/// 管理LLVMが導入済みならそのルートを返す。marker・clang・lld・C APIライブラリを検証する。
pub fn findManagedLlvmRoot(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) ?[]u8 {
    const root = managedLlvmRoot(allocator, environ) catch return null;
    errdefer allocator.free(root);
    const marker = readMarker(allocator, io, root) orelse {
        allocator.free(root);
        return null;
    };
    defer freeMarker(allocator, marker);
    const lock = llvmLock(allocator) catch {
        allocator.free(root);
        return null;
    };
    defer freeLock(allocator, lock);
    const key = platformKey() orelse {
        allocator.free(root);
        return null;
    };
    if (!std.mem.eql(u8, marker.version, lock.version) or !std.mem.eql(u8, marker.platform, key)) {
        allocator.free(root);
        return null;
    }
    const clang_rel = std.fmt.allocPrint(std.heap.page_allocator, "bin/{s}", .{clangFileName()}) catch return null;
    defer std.heap.page_allocator.free(clang_rel);
    const lld_rel = std.fmt.allocPrint(std.heap.page_allocator, "bin/{s}", .{lldFileName()}) catch return null;
    defer std.heap.page_allocator.free(lld_rel);
    if (!fileExists(io, root, clang_rel) or !fileExists(io, root, lld_rel) or !llvmLibraryPresent(io, root)) {
        allocator.free(root);
        return null;
    }
    return root;
}

fn packagedLlvmRoot(allocator: std.mem.Allocator, io: std.Io, executable_path: []const u8) ?[]u8 {
    const bin_directory = std.fs.path.dirname(executable_path) orelse return null;
    const root = std.fs.path.join(allocator, &.{ bin_directory, "..", "llvm" }) catch return null;
    errdefer allocator.free(root);
    const clang_rel = std.fmt.allocPrint(std.heap.page_allocator, "bin/{s}", .{clangFileName()}) catch return null;
    defer std.heap.page_allocator.free(clang_rel);
    if (!fileExists(io, root, clang_rel)) {
        allocator.free(root);
        return null;
    }
    return root;
}

pub fn writeStatus(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, executable_path: []const u8, writer: *std.Io.Writer) !void {
    const lock = llvmLock(allocator) catch null;
    defer if (lock) |value| freeLock(allocator, value);
    try writer.print("toolchain root: {s}\n", .{toolchainsRoot(allocator, environ) catch "(解決不可)"});
    try writer.print("pinned LLVM: {s}\n", .{if (lock) |value| value.version else "(lock解析失敗)"});
    if (environ.get("LNAKO_LLVM_DIR")) |env_dir| {
        try writer.print("LNAKO_LLVM_DIR: {s} (最優先)\n", .{env_dir});
    } else {
        try writer.writeAll("LNAKO_LLVM_DIR: (未設定)\n");
    }
    if (packagedLlvmRoot(allocator, io, executable_path)) |packaged| {
        defer allocator.free(packaged);
        try writer.print("同梱llvm/: {s} (full版)\n", .{packaged});
    } else {
        try writer.writeAll("同梱llvm/: (なし)\n");
    }
    if (findManagedLlvmRoot(allocator, io, environ)) |managed| {
        defer allocator.free(managed);
        const marker = readMarker(allocator, io, managed);
        defer if (marker) |value| freeMarker(allocator, value);
        try writer.print("管理toolchain: {s} (LLVM {s} 導入済み)\n", .{ managed, if (marker) |value| value.version else "?" });
    } else {
        const managed = managedLlvmRoot(allocator, environ) catch {
            try writer.writeAll("管理toolchain: (なし)\n");
            return;
        };
        defer allocator.free(managed);
        try writer.print("管理toolchain: {s} (未導入)\n", .{managed});
    }
    try writer.writeAll("解決順: --llvm-dir → LNAKO_LLVM_DIR → 同梱llvm/ → 管理toolchain → システム\n");
    if (builtin.os.tag == .macos) {
        const sdk_output = runProcess(allocator, io, &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }) catch null;
        if (sdk_output) |output| {
            try writer.print("macOS SDK: {s}\n", .{std.mem.trim(u8, output, " \t\r\n")});
        } else {
            try writer.writeAll("macOS SDK: 未検出（AOTリンクには `xcode-select --install` 相当の環境が必要です）\n");
        }
    } else if (builtin.os.tag == .windows) {
        try writer.writeAll("Windows SDK: AOTリンクにはVisual Studio Build Tools / Windows SDKが必要です\n");
    }
}

fn copyTree(allocator: std.mem.Allocator, io: std.Io, source_root: []const u8, destination_root: []const u8) !void {
    var source = try std.Io.Dir.cwd().openDir(io, source_root, .{ .iterate = true });
    defer source.close(io);
    try std.Io.Dir.cwd().createDirPath(io, destination_root);
    var destination = try std.Io.Dir.cwd().openDir(io, destination_root, .{});
    defer destination.close(io);
    try copyTreeInner(allocator, io, source, destination);
}

fn copyTreeInner(allocator: std.mem.Allocator, io: std.Io, source: std.Io.Dir, destination: std.Io.Dir) !void {
    var iterator = source.iterate();
    while (try iterator.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                try destination.createDirPath(io, entry.name);
                var child_source = try source.openDir(io, entry.name, .{ .iterate = true });
                defer child_source.close(io);
                var child_destination = try destination.openDir(io, entry.name, .{});
                defer child_destination.close(io);
                try copyTreeInner(allocator, io, child_source, child_destination);
            },
            .file => {
                var child_source = try source.openFile(io, entry.name, .{});
                defer child_source.close(io);
                const stat = try source.statFile(io, entry.name, .{});
                var child_destination = try destination.createFile(io, entry.name, .{ .truncate = true });
                defer child_destination.close(io);
                var read_buffer: [64 * 1024]u8 = undefined;
                var write_buffer: [64 * 1024]u8 = undefined;
                var reader = child_source.reader(io, &read_buffer);
                var writer = child_destination.writer(io, &write_buffer);
                var chunk: [64 * 1024]u8 = undefined;
                while (true) {
                    const count = try reader.interface.readSliceShort(&chunk);
                    if (count == 0) break;
                    try writer.interface.writeAll(chunk[0..count]);
                }
                try writer.interface.flush();
                if (std.Io.File.Permissions.has_executable_bit and stat.permissions.toMode() & 0o111 != 0) {
                    try child_destination.setPermissions(io, .executable_file);
                }
            },
            .sym_link => {
                var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const length = try source.readLink(io, entry.name, &link_buffer);
                try destination.symLink(io, link_buffer[0..length], entry.name, .{});
            },
            else => {},
        }
    }
}

fn runProcess(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    return runProcessAt(allocator, io, argv, .inherit);
}

fn runProcessAt(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) ![]const u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    return error.ToolchainProcessFailed;
}

fn sha256FileHex(io: std.Io, path: []const u8) ![64]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [256 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        hasher.update(chunk[0..count]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{digest}) catch unreachable;
    return hex;
}

fn download(allocator: std.mem.Allocator, io: std.Io, url: []const u8, destination: []const u8) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var request = try client.request(.GET, uri, .{ .redirect_behavior = @enumFromInt(3) });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.ToolchainDownloadFailed;
    var file = try std.Io.Dir.cwd().createFile(io, destination, .{ .truncate = true });
    defer file.close(io);
    var write_buffer: [64 * 1024]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    var transfer_buffer: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var total: u64 = 0;
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try reader.readSliceShort(&chunk);
        if (count == 0) break;
        total = std.math.add(u64, total, count) catch return error.ToolchainDownloadTooLarge;
        if (total > max_download_bytes) return error.ToolchainDownloadTooLarge;
        try writer.interface.writeAll(chunk[0..count]);
    }
    try writer.interface.flush();
}

/// tarを外部コマンドで展開する。3正式OSはいずれもOS同梱のtar（bsdtar/GNU tar）が
/// .tar.xzを扱える。展開ルートの単一directoryを返す。
fn extractTarball(allocator: std.mem.Allocator, io: std.Io, archive_path: []const u8, staging: []const u8) ![]u8 {
    // WindowsのGNU tarは-fの`D:`等をリモートhost指定と誤解するためbasename+cwdで渡す。
    const archive_dir = std.fs.path.dirname(archive_path) orelse return error.ToolchainSourceInvalid;
    const archive_name = std.fs.path.basename(archive_path);
    _ = try runProcessAt(allocator, io, &.{ "tar", "-xf", archive_name, "-C", staging }, .{ .path = archive_dir });
    var directory = try std.Io.Dir.cwd().openDir(io, staging, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    var found: ?[]u8 = null;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (found != null) return error.ToolchainArchiveRootNotUnique;
        found = try allocator.dupe(u8, entry.name);
    }
    return found orelse error.ToolchainArchiveEmpty;
}

const llvm_api_symbols_x86 = [_][]const u8{
    "LLVMGetVersion",                            "LLVMContextCreate",           "LLVMContextDispose",
    "LLVMCreateMemoryBufferWithMemoryRangeCopy", "LLVMParseIRInContext",        "LLVMDisposeModule",
    "LLVMVerifyModule",                          "LLVMPrintModuleToString",     "LLVMDisposeMessage",
    "LLVMSetTarget",                             "LLVMSetDataLayout",           "LLVMInitializeX86TargetInfo",
    "LLVMInitializeX86Target",                   "LLVMInitializeX86TargetMC",   "LLVMInitializeX86AsmPrinter",
    "LLVMGetDefaultTargetTriple",                "LLVMGetTargetFromTriple",     "LLVMCreateTargetMachine",
    "LLVMDisposeTargetMachine",                  "LLVMCreateTargetDataLayout",  "LLVMCopyStringRepOfTargetData",
    "LLVMDisposeTargetData",                     "LLVMTargetMachineEmitToFile", "LLVMCreatePassBuilderOptions",
    "LLVMPassBuilderOptionsSetVerifyEach",       "LLVMRunPasses",               "LLVMDisposePassBuilderOptions",
    "LLVMGetErrorMessage",                       "LLVMDisposeErrorMessage",
};
const llvm_api_symbols_aarch64 = [_][]const u8{
    "LLVMGetVersion",                            "LLVMContextCreate",             "LLVMContextDispose",
    "LLVMCreateMemoryBufferWithMemoryRangeCopy", "LLVMParseIRInContext",          "LLVMDisposeModule",
    "LLVMVerifyModule",                          "LLVMPrintModuleToString",       "LLVMDisposeMessage",
    "LLVMSetTarget",                             "LLVMSetDataLayout",             "LLVMInitializeAArch64TargetInfo",
    "LLVMInitializeAArch64Target",               "LLVMInitializeAArch64TargetMC", "LLVMInitializeAArch64AsmPrinter",
    "LLVMGetDefaultTargetTriple",                "LLVMGetTargetFromTriple",       "LLVMCreateTargetMachine",
    "LLVMDisposeTargetMachine",                  "LLVMCreateTargetDataLayout",    "LLVMCopyStringRepOfTargetData",
    "LLVMDisposeTargetData",                     "LLVMTargetMachineEmitToFile",   "LLVMCreatePassBuilderOptions",
    "LLVMPassBuilderOptionsSetVerifyEach",       "LLVMRunPasses",                 "LLVMDisposePassBuilderOptions",
    "LLVMGetErrorMessage",                       "LLVMDisposeErrorMessage",
};

fn requiredSymbols() []const []const u8 {
    return if (builtin.cpu.arch == .aarch64) &llvm_api_symbols_aarch64 else &llvm_api_symbols_x86;
}

/// llvm-config + clang++ でlibLLVM-C共有ライブラリを構築する（setup_llvm.mjsと同等）。
fn buildLlvmCLibrary(allocator: std.mem.Allocator, io: std.Io, root: []const u8, stderr: *std.Io.Writer) !void {
    const llvm_config = try std.fs.path.join(allocator, &.{ root, "bin", "llvm-config" });
    defer allocator.free(llvm_config);
    const clangxx = try std.fs.path.join(allocator, &.{ root, "bin", "clang++" });
    defer allocator.free(clangxx);
    const components = [_][]const u8{ "core", "irreader", "analysis", "target", "passes", "nativecodegen" };
    var libfiles_argv: std.ArrayList([]const u8) = .empty;
    defer libfiles_argv.deinit(allocator);
    try libfiles_argv.append(allocator, llvm_config);
    try libfiles_argv.append(allocator, "--link-static");
    try libfiles_argv.append(allocator, "--libfiles");
    try libfiles_argv.appendSlice(allocator, &components);
    const libfiles_out = try runProcess(allocator, io, libfiles_argv.items);
    var syslibs_argv: std.ArrayList([]const u8) = .empty;
    defer syslibs_argv.deinit(allocator);
    try syslibs_argv.append(allocator, llvm_config);
    try syslibs_argv.append(allocator, "--link-static");
    try syslibs_argv.append(allocator, "--system-libs");
    try syslibs_argv.appendSlice(allocator, &components);
    const syslibs_out = try runProcess(allocator, io, syslibs_argv.items);

    var libraries: std.ArrayList([]const u8) = .empty;
    defer libraries.deinit(allocator);
    var tokens = std.mem.tokenizeAny(u8, libfiles_out, " \t\r\n");
    while (tokens.next()) |token| try libraries.append(allocator, token);
    var system_libraries: std.ArrayList([]const u8) = .empty;
    defer system_libraries.deinit(allocator);
    var sys_tokens = std.mem.tokenizeAny(u8, syslibs_out, " \t\r\n");
    while (sys_tokens.next()) |token| {
        // Linuxでは共有システムライブラリを優先する（libX.a絶対pathは-lXへ変換）。
        if (builtin.os.tag == .linux and std.mem.endsWith(u8, token, ".a")) {
            const base = std.fs.path.basename(token);
            if (std.mem.startsWith(u8, base, "lib") and base.len > 5) {
                const converted = try std.fmt.allocPrint(allocator, "-l{s}", .{base[3 .. base.len - 2]});
                try system_libraries.append(allocator, converted);
                continue;
            }
        }
        try system_libraries.append(allocator, token);
    }
    if (libraries.items.len == 0) return error.ToolchainLlvmConfigFailed;

    const lib_dir = try std.fs.path.join(allocator, &.{ root, "lib" });
    defer allocator.free(lib_dir);
    const output = try std.fs.path.join(allocator, &.{ lib_dir, if (builtin.os.tag == .macos) "libLLVM-C.dylib" else "libLLVM-C.so" });
    defer allocator.free(output);

    var link_argv: std.ArrayList([]const u8) = .empty;
    defer link_argv.deinit(allocator);
    try link_argv.append(allocator, clangxx);
    if (builtin.os.tag == .macos) {
        const sdk_output = try runProcess(allocator, io, &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" });
        const sdk = std.mem.trim(u8, sdk_output, " \t\r\n");
        try link_argv.append(allocator, "-dynamiclib");
        try link_argv.append(allocator, "-isysroot");
        try link_argv.append(allocator, sdk);
        try link_argv.append(allocator, "-Wl,-install_name,@rpath/libLLVM-C.dylib");
        try link_argv.append(allocator, "-Wl,-rpath,@loader_path");
        for (requiredSymbols()) |symbol| {
            try link_argv.append(allocator, try std.fmt.allocPrint(allocator, "-Wl,-u,_{s}", .{symbol}));
        }
        try link_argv.appendSlice(allocator, libraries.items);
        try link_argv.append(allocator, try std.fmt.allocPrint(allocator, "-L{s}", .{lib_dir}));
        try link_argv.appendSlice(allocator, system_libraries.items);
        try link_argv.append(allocator, "-lc++");
        try link_argv.append(allocator, "-lc++abi");
    } else {
        try link_argv.append(allocator, "-shared");
        for (requiredSymbols()) |symbol| {
            try link_argv.append(allocator, try std.fmt.allocPrint(allocator, "-Wl,--undefined={s}", .{symbol}));
        }
        try link_argv.append(allocator, "-Wl,--start-group");
        try link_argv.appendSlice(allocator, libraries.items);
        try link_argv.append(allocator, "-Wl,--end-group");
        try link_argv.appendSlice(allocator, system_libraries.items);
    }
    try link_argv.append(allocator, "-o");
    try link_argv.append(allocator, output);
    _ = runProcess(allocator, io, link_argv.items) catch {
        try stderr.writeAll("toolchain: libLLVM-C共有ライブラリの構築に失敗しました\n");
        return error.ToolchainLlvmLibraryBuildFailed;
    };
    try stderr.print("toolchain: libLLVM-C共有ライブラリを構築しました: {s}\n", .{output});
}

/// LLVM C API共有ライブラリがなければ構築する（posixのみ。Windows artifactはbin/LLVM-C.dll同梱）。
fn ensureLlvmCLibrary(allocator: std.mem.Allocator, io: std.Io, root: []const u8, stderr: *std.Io.Writer) !void {
    if (llvmLibraryPresent(io, root)) return;
    if (builtin.os.tag == .windows) return error.ToolchainLlvmLibraryMissing;
    if (!fileExists(io, root, "bin/llvm-config") or !fileExists(io, root, "bin/clang++")) return error.ToolchainLlvmLibraryMissing;
    try buildLlvmCLibrary(allocator, io, root, stderr);
    if (!llvmLibraryPresent(io, root)) return error.ToolchainLlvmLibraryMissing;
}

/// prune_llvm_toolchain.mjsと同等のkeep-listで、展開済みLLVM treeをAOT最小構成へ縮小する。
/// download/archive導入のみ対象（--from-dirは呼出し側のtreeをそのまま複製する）。
fn pruneLlvmTree(allocator: std.mem.Allocator, io: std.Io, root: []const u8) !void {
    // keep-keyはarenaへ確保して一括解放する。
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const keys = arena.allocator();
    var keep: std.StringHashMap(void) = .init(allocator);
    defer keep.deinit();
    const clang_rel = try std.fmt.allocPrint(allocator, "bin/{s}", .{clangFileName()});
    defer allocator.free(clang_rel);
    const lld_rel = try std.fmt.allocPrint(allocator, "bin/{s}", .{lldFileName()});
    defer allocator.free(lld_rel);
    const tool_names = [_][]const u8{ clang_rel, lld_rel };
    for (tool_names) |relative| {
        if (!fileExists(io, root, relative)) return error.ToolchainSourceInvalid;
        try keep.put(try keys.dupe(u8, relative), {});
        try keepSymlinkTargets(allocator, keys, io, root, relative, &keep);
    }
    // 数値profileの検証補助。存在する場合だけ保持する。
    for ([_][]const u8{ "llvm-readobj", "llvm-objdump" }) |tool| {
        const relative = try std.fmt.allocPrint(allocator, "bin/{s}{s}", .{ tool, if (builtin.os.tag == .windows) ".exe" else "" });
        defer allocator.free(relative);
        if (fileExists(io, root, relative)) {
            try keep.put(try keys.dupe(u8, relative), {});
            try keepSymlinkTargets(allocator, keys, io, root, relative, &keep);
        }
    }
    // LLVM C API共有ライブラリとmacOS runtime依存をtree全体から収集する。
    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);
    try collectLibraryPaths(allocator, keys, io, root_dir, root, "", &keep);

    var walker_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer walker_dir.close(io);
    try pruneDirectory(allocator, io, walker_dir, "", &keep);
}

fn keepSymlinkTargets(allocator: std.mem.Allocator, keys: std.mem.Allocator, io: std.Io, root: []const u8, relative: []const u8, keep: *std.StringHashMap(void)) !void {
    const path = try std.fs.path.join(allocator, &.{ root, relative });
    defer allocator.free(path);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = std.Io.Dir.cwd().readLink(io, path, &buffer) catch return;
    const target = buffer[0..length];
    if (std.fs.path.isAbsolute(target)) return error.ToolchainSourceInvalid;
    const parent_rel = std.fs.path.dirname(relative) orelse "";
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_rel, target });
    defer allocator.free(joined);
    const normalized = try normalizeRelativePosix(allocator, joined);
    defer allocator.free(normalized);
    try keep.put(try keys.dupe(u8, normalized), {});
}

/// root内相対pathを字句正規化する。root外（..）への脱出はエラー。
fn normalizeRelativePosix(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    const unix = try std.mem.replaceOwned(u8, allocator, path, "\\", "/");
    defer allocator.free(unix);
    var iterator = std.mem.tokenizeScalar(u8, unix, '/');
    while (iterator.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.ToolchainSourceInvalid;
            _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }
    return std.mem.join(allocator, "/", parts.items);
}

fn isPruneLibraryName(name: []const u8) bool {
    if (std.ascii.startsWithIgnoreCase(name, "libLLVM-C.")) return true;
    if (std.ascii.eqlIgnoreCase(name, "LLVM-C.dll")) return true;
    if (builtin.os.tag == .macos) {
        for ([_][]const u8{ "libc++", "libc++abi", "libunwind" }) |prefix| {
            if (std.mem.startsWith(u8, name, prefix) and std.mem.endsWith(u8, name, ".dylib")) return true;
        }
    }
    return false;
}

fn collectLibraryPaths(allocator: std.mem.Allocator, keys: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, root: []const u8, relative_base: []const u8, keep: *std.StringHashMap(void)) !void {
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const relative = try std.fmt.allocPrint(allocator, "{s}{s}", .{ relative_base, entry.name });
        defer allocator.free(relative);
        switch (entry.kind) {
            .directory => {
                var child = try directory.openDir(io, entry.name, .{ .iterate = true });
                defer child.close(io);
                const child_base = try std.fmt.allocPrint(allocator, "{s}/", .{relative});
                defer allocator.free(child_base);
                try collectLibraryPaths(allocator, keys, io, child, root, child_base, keep);
            },
            .file, .sym_link => {
                if (!isPruneLibraryName(entry.name)) continue;
                try keep.put(try keys.dupe(u8, relative), {});
                try keepSymlinkTargets(allocator, keys, io, root, relative, keep);
            },
            else => {},
        }
    }
}

fn pruneDirectory(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir, relative_base: []const u8, keep: *const std.StringHashMap(void)) !void {
    // 削除しながらiterateするとentryをskipし得るため、先に一覧を確定する。
    const Entry = struct { name: []const u8, kind: std.Io.File.Kind };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        try entries.append(allocator, .{ .name = try allocator.dupe(u8, entry.name), .kind = entry.kind });
    }
    defer for (entries.items) |entry| allocator.free(entry.name);
    for (entries.items) |entry| {
        const relative = try std.fmt.allocPrint(allocator, "{s}{s}", .{ relative_base, entry.name });
        defer allocator.free(relative);
        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, relative, "bin") or std.mem.eql(u8, relative, "lib") or
                    std.mem.eql(u8, relative, "lib/clang") or std.mem.startsWith(u8, relative, "lib/clang/"))
                {
                    var child = try directory.openDir(io, entry.name, .{ .iterate = true });
                    defer child.close(io);
                    const child_base = try std.fmt.allocPrint(allocator, "{s}/", .{relative});
                    defer allocator.free(child_base);
                    try pruneDirectory(allocator, io, child, child_base, keep);
                } else {
                    directory.deleteTree(io, entry.name) catch {};
                }
            },
            .file, .sym_link => {
                if (keep.contains(relative) or std.mem.eql(u8, relative, marker_file_name) or
                    std.mem.startsWith(u8, relative, "lib/clang/")) continue;
                directory.deleteFile(io, entry.name) catch directory.deleteTree(io, entry.name) catch {};
            },
            else => {},
        }
    }
}

/// pinned LLVMを管理dirへ導入する。source順: --from-dir > --archive > download。
/// download・--archiveは埋め込みlockのSHA-256で必ず検証する。
pub fn installLlvm(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, options: InstallOptions, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !InstallResult {
    const lock = try llvmLock(allocator);
    defer freeLock(allocator, lock);
    const target = try managedLlvmRoot(allocator, environ);
    errdefer allocator.free(target);
    if (findManagedLlvmRoot(allocator, io, environ)) |existing| {
        defer allocator.free(existing);
        if (!options.force and std.mem.eql(u8, existing, target)) {
            try stdout.print("toolchain: LLVM {s} は既に導入済みです: {s}\n", .{ lock.version, existing });
            return .{ .root = target, .already_present = true };
        }
    }
    const root = try toolchainsRoot(allocator, environ);
    defer allocator.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);
    const staging = try std.fmt.allocPrint(allocator, "{s}/.llvm-staging-{d}", .{ root, std.Io.Clock.real.now(io).nanoseconds });
    defer allocator.free(staging);
    std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, staging) catch {};
    try std.Io.Dir.cwd().createDirPath(io, staging);
    const staging_inner = try std.fmt.allocPrint(allocator, "{s}/extract", .{staging});
    defer allocator.free(staging_inner);
    try std.Io.Dir.cwd().createDirPath(io, staging_inner);

    var marker_source: []const u8 = "download";
    var marker_sha256: ?[]const u8 = null;
    defer if (marker_sha256) |value| allocator.free(value);
    if (options.from_dir) |source_dir| {
        marker_source = "directory";
        try stdout.print("toolchain: LLVMを複製しています: {s}\n", .{source_dir});
        const clang_rel = try std.fmt.allocPrint(allocator, "bin/{s}", .{clangFileName()});
        defer allocator.free(clang_rel);
        if (!fileExists(io, source_dir, clang_rel)) return error.ToolchainSourceInvalid;
        std.Io.Dir.cwd().deleteTree(io, target) catch {};
        try copyTree(allocator, io, source_dir, target);
    } else {
        const archive_path: []const u8 = if (options.archive_path) |path| blk: {
            marker_source = "archive";
            break :blk try allocator.dupe(u8, path);
        } else blk: {
            const url = options.url_override orelse lock.url;
            const destination = try std.fmt.allocPrint(allocator, "{s}/llvm-archive", .{staging});
            try stderr.print("toolchain: LLVM {s} をダウンロードしています: {s}\n", .{ lock.version, url });
            try download(allocator, io, url, destination);
            break :blk destination;
        };
        defer allocator.free(archive_path);
        const expected_sha = options.sha256_override orelse lock.sha256;
        const actual = try sha256FileHex(io, archive_path);
        if (!std.ascii.eqlIgnoreCase(&actual, expected_sha)) {
            try stderr.print("toolchain: SHA-256不一致 expected={s} actual={s}\n", .{ expected_sha, actual });
            return error.ToolchainChecksumMismatch;
        }
        marker_sha256 = try allocator.dupe(u8, &actual);
        try stdout.print("toolchain: アーカイブを展開しています\n", .{});
        const inner_root_name = try extractTarball(allocator, io, archive_path, staging_inner);
        defer allocator.free(inner_root_name);
        const extracted = try std.fs.path.join(allocator, &.{ staging_inner, inner_root_name });
        defer allocator.free(extracted);
        std.Io.Dir.cwd().deleteTree(io, target) catch {};
        try std.Io.Dir.renameAbsolute(extracted, target, io);
    }

    try ensureLlvmCLibrary(allocator, io, target, stderr);

    // libLLVM-C構築後にAOT最小構成へ縮小する（llvm-config/clang++/静的libはここで削除）。
    if (options.from_dir == null) {
        try stdout.print("toolchain: AOT最小構成へ縮小しています\n", .{});
        try pruneLlvmTree(allocator, io, target);
    }

    const sha_field: []const u8 = if (marker_sha256) |value| blk: {
        const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{value});
        break :blk quoted;
    } else try allocator.dupe(u8, "null");
    defer allocator.free(sha_field);
    const marker_json = try std.fmt.allocPrint(allocator, "{{\"version\":\"{s}\",\"platform\":\"{s}\",\"sha256\":{s},\"source\":\"{s}\"}}\n", .{
        lock.version,
        platformKey().?,
        sha_field,
        marker_source,
    });
    defer allocator.free(marker_json);
    const marker_path = try std.fs.path.join(allocator, &.{ target, marker_file_name });
    defer allocator.free(marker_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = marker_path, .data = marker_json });
    try stdout.print("toolchain: LLVM {s} を導入しました: {s}\n", .{ lock.version, target });
    return .{ .root = target, .already_present = false };
}

pub fn removeLlvm(allocator: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, stdout: *std.Io.Writer) !void {
    const target = try managedLlvmRoot(allocator, environ);
    defer allocator.free(target);
    if (!fileExists(io, target, ".") and !dirExists(io, target)) {
        try stdout.print("toolchain: 管理LLVMは導入されていません: {s}\n", .{target});
        return;
    }
    try std.Io.Dir.cwd().deleteTree(io, target);
    try stdout.print("toolchain: 管理LLVMを削除しました: {s}\n", .{target});
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    directory.close(io);
    return true;
}

test "normalizeRelativePosixがroot外脱出を拒否する" {
    const resolved = try normalizeRelativePosix(std.testing.allocator, "bin/../lib/x.so");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("lib/x.so", resolved);
    try std.testing.expectError(error.ToolchainSourceInvalid, normalizeRelativePosix(std.testing.allocator, "../escape"));
    try std.testing.expectError(error.ToolchainSourceInvalid, normalizeRelativePosix(std.testing.allocator, "bin/../../escape"));
}

test "pruneLlvmTreeがkeep-listのみ残す" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const clang_rel = try std.fmt.allocPrint(std.testing.allocator, "bin/{s}", .{clangFileName()});
    defer std.testing.allocator.free(clang_rel);
    const lld_rel = try std.fmt.allocPrint(std.testing.allocator, "bin/{s}", .{lldFileName()});
    defer std.testing.allocator.free(lld_rel);
    const writes = [_][]const u8{
        clang_rel,                       lld_rel,
        "bin/unused-tool",               llvm_library_candidates[0],
        "lib/clang/22/include/stddef.h", "lib/libunused.a",
        "include/unused.h",              "share/unused/file",
        marker_file_name,
    };
    for (writes) |relative| {
        const path = try std.fs.path.join(std.testing.allocator, &.{ base, relative });
        defer std.testing.allocator.free(path);
        if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "fake" });
    }
    try pruneLlvmTree(std.testing.allocator, std.testing.io, base);
    for ([_][]const u8{ clang_rel, lld_rel, llvm_library_candidates[0], "lib/clang/22/include/stddef.h", marker_file_name }) |relative| {
        try std.testing.expect(fileExists(std.testing.io, base, relative));
    }
    for ([_][]const u8{ "bin/unused-tool", "lib/libunused.a", "include", "share" }) |relative| {
        try std.testing.expect(!fileExists(std.testing.io, base, relative) and !dirExistsAt(base, relative));
    }
}

fn dirExistsAt(root: []const u8, relative: []const u8) bool {
    const path = std.fs.path.join(std.heap.page_allocator, &.{ root, relative }) catch return false;
    defer std.heap.page_allocator.free(path);
    var directory = std.Io.Dir.cwd().openDir(std.testing.io, path, .{}) catch return false;
    directory.close(std.testing.io);
    return true;
}

test "platformKeyが正式対応OSを返す" {
    try std.testing.expect(platformKey() != null);
}

test "toolchainsRootがLNAKO_TOOLCHAIN_DIRを優先する" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("LNAKO_TOOLCHAIN_DIR", "/custom/toolchains");
    const root = try toolchainsRoot(std.testing.allocator, &map);
    defer std.testing.allocator.free(root);
    try std.testing.expectEqualStrings("/custom/toolchains", root);
}

test "toolchainsRootがOS標準dirへ解決する" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    switch (builtin.os.tag) {
        .macos => try map.put("HOME", "/Users/test"),
        .windows => try map.put("LOCALAPPDATA", "C:\\Users\\test\\AppData\\Local"),
        else => try map.put("HOME", "/home/test"),
    }
    const root = try toolchainsRoot(std.testing.allocator, &map);
    defer std.testing.allocator.free(root);
    switch (builtin.os.tag) {
        .macos => try std.testing.expectEqualStrings("/Users/test/Library/Caches/lnako/toolchains", root),
        .windows => try std.testing.expectEqualStrings("C:\\Users\\test\\AppData\\Local\\lnako\\Cache\\toolchains", root),
        else => try std.testing.expectEqualStrings("/home/test/.cache/lnako/toolchains", root),
    }
}

test "llvmLockがpin済みartifactを返す" {
    const lock = try llvmLock(std.testing.allocator);
    defer freeLock(std.testing.allocator, lock);
    try std.testing.expectEqualStrings("22.1.8", lock.version);
    try std.testing.expect(lock.url.len > 0);
    try std.testing.expectEqual(@as(usize, 64), lock.sha256.len);
}

test "install --from-dirが管理LLVMを登録しfindManagedLlvmRootが解決する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const base = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    const toolchains = try std.fs.path.join(std.testing.allocator, &.{ base, "managed" });
    defer std.testing.allocator.free(toolchains);
    try map.put("LNAKO_TOOLCHAIN_DIR", toolchains);
    const source = try std.fs.path.join(std.testing.allocator, &.{ base, "source-llvm" });
    defer std.testing.allocator.free(source);
    const bin_dir = try std.fs.path.join(std.testing.allocator, &.{ source, "bin" });
    defer std.testing.allocator.free(bin_dir);
    const lib_dir = try std.fs.path.join(std.testing.allocator, &.{ source, "lib" });
    defer std.testing.allocator.free(lib_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, bin_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, lib_dir);
    const clang_rel = try std.fmt.allocPrint(std.testing.allocator, "bin/{s}", .{clangFileName()});
    defer std.testing.allocator.free(clang_rel);
    const lld_rel = try std.fmt.allocPrint(std.testing.allocator, "bin/{s}", .{lldFileName()});
    defer std.testing.allocator.free(lld_rel);
    const clang_path = try std.fs.path.join(std.testing.allocator, &.{ source, clang_rel });
    defer std.testing.allocator.free(clang_path);
    const lld_path = try std.fs.path.join(std.testing.allocator, &.{ source, lld_rel });
    defer std.testing.allocator.free(lld_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = clang_path, .data = "fake" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = lld_path, .data = "fake" });
    const lib_rel = llvm_library_candidates[0];
    const lib_path = try std.fs.path.join(std.testing.allocator, &.{ source, lib_rel });
    defer std.testing.allocator.free(lib_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = lib_path, .data = "fake" });

    try std.testing.expect(findManagedLlvmRoot(std.testing.allocator, std.testing.io, &map) == null);
    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.Writer.fixed(&out_buffer);
    var err_buffer: [1024]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&err_buffer);
    const result = try installLlvm(std.testing.allocator, std.testing.io, &map, .{ .from_dir = source }, &stdout, &stderr);
    defer std.testing.allocator.free(result.root);
    try std.testing.expect(!result.already_present);
    const managed = findManagedLlvmRoot(std.testing.allocator, std.testing.io, &map);
    defer if (managed) |value| std.testing.allocator.free(value);
    try std.testing.expect(managed != null);
    const marker = readMarker(std.testing.allocator, std.testing.io, result.root);
    defer if (marker) |value| freeMarker(std.testing.allocator, value);
    try std.testing.expect(marker != null);
    try std.testing.expectEqualStrings("22.1.8", marker.?.version);
    try std.testing.expectEqualStrings("directory", marker.?.source);
    var remove_out: [1024]u8 = undefined;
    var remove_writer = std.Io.Writer.fixed(&remove_out);
    try removeLlvm(std.testing.allocator, std.testing.io, &map, &remove_writer);
    try std.testing.expect(findManagedLlvmRoot(std.testing.allocator, std.testing.io, &map) == null);
}
