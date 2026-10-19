//! ソース命令 metadata の静的検査（Issue #52 / PS10）。
//!
//! `lnako check` から呼び、package の初期化・native/JS plugin のロードを
//! 一切行わずに次を行う:
//! - environment に snapshot された `commands` を索引化する
//! - source export がある package は AST から再生成し snapshot と照合する
//! - 標準命令・他 package との命令名衝突を決定的に診断する
//! - metadata 不足・native/JS のみ等の未検査範囲を列挙する
//! - 厳格共用検査（`--strict-sharing`）では未検査が残れば E033
//!
//! 共用「保証済み」は静的に完全検査できた場合のみ。未検査があれば
//! `partial`、衝突/不一致/厳格失敗は `failed`。

const std = @import("std");
const diag = @import("diagnostics.zig");
const environment_mod = @import("environment.zig");
const npkg_commands = @import("npkg_commands.zig");
const npkg_commands_gen = @import("npkg_commands_gen.zig");
const npkg_files = @import("npkg_files.zig");
const builtin_commands = @import("../frontend/builtin_commands.zig");

const Allocator = std.mem.Allocator;

pub const Sharing = enum {
    /// 環境が無く命令検査をスキップした。
    skipped,
    /// 静的に検査可能な範囲をすべて検査し、衝突・不一致・未検査が無い。
    guaranteed,
    /// 未検査範囲がある（通常 check では失敗にしない）。
    partial,
    /// 衝突・不一致、または厳格共用検査での未検査。
    failed,
};

pub const UninspectedReason = enum {
    missing_metadata,
    native_without_metadata,
    js_without_metadata,
};

pub const Uninspected = struct {
    package_key: []const u8,
    reason: UninspectedReason,

    pub fn reasonText(self: Uninspected) []const u8 {
        return switch (self.reason) {
            .missing_metadata => "missing_metadata",
            .native_without_metadata => "native_without_metadata",
            .js_without_metadata => "js_without_metadata",
        };
    }
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    sharing: Sharing = .skipped,
    inspected_count: usize = 0,
    uninspected: []const Uninspected = &.{},
    collision_count: usize = 0,
    mismatch_count: usize = 0,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn uninspectedCount(self: *const Report) usize {
        return self.uninspected.len;
    }
};

const Owner = struct {
    package_key: []const u8,
    variable: bool,
    args_len: usize,
    josi_len: usize,
};

/// プロジェクト root dir 配下の `.nako/environment.json` を読み、
/// 命令 metadata を静的検査する。ファイルが無い・読めない場合は
/// `sharing = skipped` の空 Report（lock/env 整合は `inspectForCheck` 側）。
pub fn inspectEnvironmentDir(
    gpa: Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    strict_sharing: bool,
    diagnostics: *diag.List,
) error{OutOfMemory}!Report {
    var report = Report{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer report.deinit();
    const arena = report.arena.allocator();

    const env_rel = ".nako/" ++ environment_mod.environment_file;
    const bytes = root_dir.readFileAlloc(io, env_rel, gpa, .limited(environment_mod.max_environment_bytes)) catch {
        return report;
    };
    defer gpa.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{ .allocate = .alloc_always }) catch {
        try diagnostics.addFmt(
            diag.E034_INVALID_ENVIRONMENT_REFERENCE,
            .err,
            environment_mod.environment_file,
            .{},
            "environment.json is not valid JSON",
            .{},
        );
        report.sharing = .failed;
        return report;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        try diagnostics.addFmt(
            diag.E034_INVALID_ENVIRONMENT_REFERENCE,
            .err,
            environment_mod.environment_file,
            .{},
            "environment.json root must be an object",
            .{},
        );
        report.sharing = .failed;
        return report;
    }
    const packages_value = parsed.value.object.get("packages") orelse {
        report.sharing = .guaranteed;
        return report;
    };
    if (packages_value != .object) {
        try diagnostics.addFmt(
            diag.E034_INVALID_ENVIRONMENT_REFERENCE,
            .err,
            "packages",
            .{},
            "environment.json packages must be an object",
            .{},
        );
        report.sharing = .failed;
        return report;
    }

    var owners: std.StringHashMapUnmanaged(Owner) = .empty;
    defer {
        var free_it = owners.iterator();
        while (free_it.next()) |item| gpa.free(item.key_ptr.*);
        owners.deinit(gpa);
    }

    var uninspected_list: std.ArrayList(Uninspected) = .empty;

    var package_it = packages_value.object.iterator();
    while (package_it.next()) |entry| {
        const package_key = try arena.dupe(u8, entry.key_ptr.*);
        if (entry.value_ptr.* != .object) continue;
        const record = entry.value_ptr.*.object;

        const path_value = record.get("path") orelse continue;
        if (path_value != .string) continue;
        const rel_path = path_value.string;

        var commands = try parseCommands(arena, record.get("commands"));
        const export_flags = exportFlags(record.get("exports"));

        if (export_flags.has_source) {
            if (try regenerateCommands(gpa, io, root_dir, rel_path, record.get("exports"), diagnostics)) |regenerated_ptr| {
                var regenerated = regenerated_ptr;
                defer regenerated.deinit();
                const cmp = compareCommandLists(commands, regenerated.commands);
                if (commands.len != 0 and !cmp.equal) {
                    report.mismatch_count += 1;
                    try diagnostics.addFmt(
                        diag.E029_INVALID_VALUE,
                        .err,
                        package_key,
                        .{},
                        "commands metadata does not match source exports for package \"{s}\" ({s})",
                        .{ package_key, cmp.detail },
                    );
                }
                // snapshot が空でも source から索引できる
                if (commands.len == 0 and regenerated.commands.len != 0) {
                    commands = try cloneCommands(arena, regenerated.commands);
                }
            }
        }

        if (commands.len == 0) {
            if (export_flags.has_native and !export_flags.has_source and !export_flags.has_js) {
                try uninspected_list.append(arena, .{
                    .package_key = package_key,
                    .reason = .native_without_metadata,
                });
            } else if (export_flags.has_js and !export_flags.has_source) {
                try uninspected_list.append(arena, .{
                    .package_key = package_key,
                    .reason = .js_without_metadata,
                });
            } else if (export_flags.has_source) {
                try uninspected_list.append(arena, .{
                    .package_key = package_key,
                    .reason = .missing_metadata,
                });
            }
            continue;
        }

        for (commands) |command| {
            report.inspected_count += 1;
            const name = command.name;
            if (isBuiltinCommand(name)) {
                report.collision_count += 1;
                try diagnostics.addFmt(
                    diag.E029_INVALID_VALUE,
                    .err,
                    package_key,
                    .{},
                    "command \"{s}\" in package \"{s}\" collides with a standard builtin command",
                    .{ name, package_key },
                );
                continue;
            }
            const gop = try owners.getOrPut(gpa, name);
            if (!gop.found_existing) {
                gop.key_ptr.* = try gpa.dupe(u8, name);
                gop.value_ptr.* = .{
                    .package_key = package_key,
                    .variable = command.variable,
                    .args_len = command.args.len,
                    .josi_len = command.josi.len,
                };
            } else {
                const existing = gop.value_ptr.*;
                if (!std.mem.eql(u8, existing.package_key, package_key)) {
                    report.collision_count += 1;
                    try diagnostics.addFmt(
                        diag.E029_INVALID_VALUE,
                        .err,
                        package_key,
                        .{},
                        "command \"{s}\" collides between packages \"{s}\" and \"{s}\"",
                        .{ name, existing.package_key, package_key },
                    );
                } else if (existing.variable != command.variable or
                    existing.args_len != command.args.len or
                    existing.josi_len != command.josi.len)
                {
                    report.mismatch_count += 1;
                    try diagnostics.addFmt(
                        diag.E029_INVALID_VALUE,
                        .err,
                        package_key,
                        .{},
                        "command \"{s}\" has conflicting declarations within package \"{s}\"",
                        .{ name, package_key },
                    );
                }
            }
        }
    }

    report.uninspected = try arena.dupe(Uninspected, uninspected_list.items);

    if (report.collision_count > 0 or report.mismatch_count > 0) {
        report.sharing = .failed;
    } else if (report.uninspected.len > 0) {
        report.sharing = .partial;
        if (strict_sharing) {
            report.sharing = .failed;
            for (report.uninspected) |item| {
                try diagnostics.addFmt(
                    diag.E033_STRICT_SHARING_FAILED,
                    .err,
                    item.package_key,
                    .{},
                    "strict sharing check failed: package \"{s}\" has uninspected range ({s})",
                    .{ item.package_key, item.reasonText() },
                );
            }
        }
    } else {
        report.sharing = .guaranteed;
    }
    return report;
}

const ExportFlags = struct {
    has_source: bool = false,
    has_native: bool = false,
    has_js: bool = false,
};

fn exportFlags(exports_value: ?std.json.Value) ExportFlags {
    var flags = ExportFlags{};
    const exports = exports_value orelse return flags;
    if (exports != .array) return flags;
    for (exports.array.items) |item| {
        if (item != .object) continue;
        if (item.object.get("path")) |path| {
            if (path == .string and isNakoSource(path.string)) flags.has_source = true;
            if (path == .string and npkg_commands_gen.isNativePluginArtifact(path.string)) flags.has_native = true;
            if (path == .string and isJsArtifact(path.string)) flags.has_js = true;
        }
        if (item.object.get("native") != null) flags.has_native = true;
        if (item.object.get("esm") != null) flags.has_js = true;
    }
    return flags;
}

fn isNakoSource(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".nako3") or
        std.ascii.eqlIgnoreCase(extension, ".dncl") or
        std.ascii.eqlIgnoreCase(extension, ".dncl2");
}

fn isJsArtifact(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".js") or
        std.ascii.eqlIgnoreCase(extension, ".mjs") or
        std.ascii.eqlIgnoreCase(extension, ".cjs");
}

fn isBuiltinCommand(name: []const u8) bool {
    for (builtin_commands.function_names) |builtin| {
        if (std.mem.eql(u8, builtin, name)) return true;
    }
    return false;
}

fn parseCommands(arena: Allocator, commands_value: ?std.json.Value) ![]npkg_commands.Command {
    const value = commands_value orelse return &.{};
    if (value != .array) return &.{};
    var list: std.ArrayList(npkg_commands.Command) = .empty;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const name_v = item.object.get("name") orelse continue;
        if (name_v != .string) continue;
        var command = npkg_commands.Command{
            .name = try arena.dupe(u8, name_v.string),
        };
        if (item.object.get("variable")) |variable| {
            if (variable == .bool) command.variable = variable.bool;
        }
        if (item.object.get("args")) |args| {
            if (args == .array) {
                const slice = try arena.alloc([]const u8, args.array.items.len);
                for (args.array.items, 0..) |arg, i| {
                    slice[i] = if (arg == .string) try arena.dupe(u8, arg.string) else "";
                }
                command.args = slice;
            }
        }
        if (item.object.get("josi")) |josi| {
            if (josi == .array) {
                const slice = try arena.alloc([]const u8, josi.array.items.len);
                for (josi.array.items, 0..) |arg, i| {
                    slice[i] = if (arg == .string) try arena.dupe(u8, arg.string) else "";
                }
                command.josi = slice;
            }
        }
        try list.append(arena, command);
    }
    return try list.toOwnedSlice(arena);
}

fn cloneCommands(arena: Allocator, commands: []const npkg_commands.Command) ![]npkg_commands.Command {
    const out = try arena.alloc(npkg_commands.Command, commands.len);
    for (commands, 0..) |command, i| {
        out[i] = .{
            .name = try arena.dupe(u8, command.name),
            .variable = command.variable,
            .args = try cloneStringSlice(arena, command.args),
            .josi = try cloneStringSlice(arena, command.josi),
        };
    }
    return out;
}

fn cloneStringSlice(arena: Allocator, items: []const []const u8) ![]const []const u8 {
    if (items.len == 0) return &.{};
    const out = try arena.alloc([]const u8, items.len);
    for (items, 0..) |item, i| out[i] = try arena.dupe(u8, item);
    return out;
}

const CompareResult = struct {
    equal: bool,
    detail: []const u8,
};

fn compareCommandLists(a: []const npkg_commands.Command, b: []const npkg_commands.Command) CompareResult {
    if (a.len != b.len) return .{ .equal = false, .detail = "command count differs" };
    for (a) |left| {
        var found = false;
        for (b) |right| {
            if (!std.mem.eql(u8, left.name, right.name)) continue;
            if (left.variable != right.variable) return .{ .equal = false, .detail = "variable flag differs" };
            if (left.args.len != right.args.len or left.josi.len != right.josi.len)
                return .{ .equal = false, .detail = "arity or josi count differs" };
            for (left.args, 0..) |arg, i| {
                if (!std.mem.eql(u8, arg, right.args[i])) return .{ .equal = false, .detail = "args differ" };
            }
            for (left.josi, 0..) |josi, i| {
                if (!std.mem.eql(u8, josi, right.josi[i])) return .{ .equal = false, .detail = "josi differ" };
            }
            found = true;
            break;
        }
        if (!found) return .{ .equal = false, .detail = "command missing from regenerated index" };
    }
    return .{ .equal = true, .detail = "" };
}

fn regenerateCommands(
    gpa: Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    rel_package_path: []const u8,
    exports_value: ?std.json.Value,
    diagnostics: *diag.List,
) error{OutOfMemory}!?npkg_commands_gen.Result {
    if (!npkg_files.isCanonicalPath(rel_package_path) and
        (std.mem.indexOfScalar(u8, rel_package_path, 0) != null or rel_package_path.len == 0))
        return null;
    // path 依存は相対。バックスラッシュや `..` 脱出は open 失敗で null。
    if (std.mem.indexOf(u8, rel_package_path, "..") != null) return null;

    var package_dir = root_dir.openDir(io, rel_package_path, .{ .follow_symlinks = false }) catch return null;
    defer package_dir.close(io);

    var real_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const real_len = package_dir.realPath(io, &real_buf) catch return null;
    const real_root = real_buf[0..real_len];

    var provider_state = npkg_commands_gen.DirSourceProvider.init(gpa, io, real_root) catch return null;
    defer gpa.free(provider_state.real_root);

    var entries: std.ArrayList([]const u8) = .empty;
    defer {
        for (entries.items) |path| gpa.free(path);
        entries.deinit(gpa);
    }
    const exports = exports_value orelse return null;
    if (exports != .array) return null;
    for (exports.array.items) |item| {
        if (item != .object) continue;
        const path_v = item.object.get("path") orelse continue;
        if (path_v != .string) continue;
        if (!isNakoSource(path_v.string)) continue;
        if (!npkg_files.isCanonicalPath(path_v.string)) continue;
        try entries.append(gpa, try gpa.dupe(u8, path_v.string));
    }
    if (entries.items.len == 0) return null;

    var local = diag.List.init(gpa);
    defer local.deinit();
    const result = npkg_commands_gen.generate(gpa, provider_state.provider(), entries.items, &local) catch {
        for (local.items.items) |item| {
            diagnostics.add(item.code, item.severity, item.message, item.path, item.position) catch {};
        }
        return null;
    };
    return result;
}

pub fn sharingText(sharing: Sharing) []const u8 {
    return switch (sharing) {
        .skipped => "skipped",
        .guaranteed => "guaranteed",
        .partial => "partial",
        .failed => "failed",
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const test_sandbox = @import("test_sandbox.zig");

fn writeEnv(dir: std.Io.Dir, body: []const u8) !void {
    const io = testing.io;
    try dir.createDirPath(io, ".nako");
    try dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = body });
}

test "command inspect: source metadata をロードせず検査し guaranteed になる" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib/src/index.nako3",
        .data =
        \\●(AをBに)加算とは
        \\  A+Bで戻る
        \\ここまで
        \\
        ,
    });
    // 副作用を持つ初期化文。静的検査が実行すると marker が書かれる。
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib/src/side.nako3",
        .data =
        \\「ran」を「SIDE_EFFECT.txt」に保存
        \\
        ,
    });
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:11111111111111111111111111111111": {
        \\      "name": "lib",
        \\      "version": "1.0.0",
        \\      "id": "pkg:11111111111111111111111111111111",
        \\      "path": "lib",
        \\      "exports": [{"name": "lib", "path": "src/index.nako3"}],
        \\      "commands": [{"name": "加算", "args": ["A", "B"], "josi": ["を", "に"]}]
        \\    }
        \\  }
        \\}
    );

    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, false, &list);
    defer report.deinit();

    try testing.expectEqual(Sharing.guaranteed, report.sharing);
    try testing.expectEqual(@as(usize, 1), report.inspected_count);
    try testing.expectEqual(@as(usize, 0), report.uninspectedCount());
    try testing.expect(!list.hasErrors());
    tmp.dir.access(io, "lib/SIDE_EFFECT.txt", .{}) catch |err| {
        try testing.expect(err == error.FileNotFound);
        return;
    };
    try testing.expect(false);
}

test "command inspect: native metadata 不足は partial、strict で E033" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib");
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:22222222222222222222222222222222": {
        \\      "name": "nativepkg",
        \\      "version": "1.0.0",
        \\      "path": "lib",
        \\      "exports": [{"name": "plugin", "native": "plugin.so"}],
        \\      "commands": []
        \\    }
        \\  }
        \\}
    );

    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, false, &list);
    defer report.deinit();
    try testing.expectEqual(Sharing.partial, report.sharing);
    try testing.expectEqual(@as(usize, 1), report.uninspectedCount());
    try testing.expectEqual(UninspectedReason.native_without_metadata, report.uninspected[0].reason);
    try testing.expect(!list.hasErrors());

    var strict_list = diag.List.init(a);
    defer strict_list.deinit();
    var report_strict = try inspectEnvironmentDir(a, io, tmp.dir, true, &strict_list);
    defer report_strict.deinit();
    try testing.expectEqual(Sharing.failed, report_strict.sharing);
    try testing.expect(strict_list.find(diag.E033_STRICT_SHARING_FAILED) != null);
}

test "command inspect: 標準命令との衝突を診断する" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:33333333333333333333333333333333": {
        \\      "name": "bad",
        \\      "version": "1.0.0",
        \\      "path": "lib",
        \\      "exports": [{"name": "bad", "path": "src/index.nako3"}],
        \\      "commands": [{"name": "表示", "args": [], "josi": []}]
        \\    }
        \\  }
        \\}
    );
    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, false, &list);
    defer report.deinit();
    try testing.expectEqual(Sharing.failed, report.sharing);
    try testing.expect(report.collision_count >= 1);
    try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
}

test "command inspect: package 間の命令名衝突を診断する" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": {
        \\      "name": "a",
        \\      "version": "1.0.0",
        \\      "path": "a",
        \\      "commands": [{"name": "共通処理", "args": [], "josi": []}]
        \\    },
        \\    "pkg:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb": {
        \\      "name": "b",
        \\      "version": "1.0.0",
        \\      "path": "b",
        \\      "commands": [{"name": "共通処理", "args": [], "josi": []}]
        \\    }
        \\  }
        \\}
    );
    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, false, &list);
    defer report.deinit();
    try testing.expectEqual(Sharing.failed, report.sharing);
    try testing.expect(report.collision_count >= 1);
}

test "command inspect: snapshot とソース再生成の不一致を診断する" {
    const a = testing.allocator;
    const io = testing.io;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lib/src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "lib/src/index.nako3",
        .data =
        \\●正しいとは
        \\ここまで
        \\
        ,
    });
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee": {
        \\      "name": "lib",
        \\      "version": "1.0.0",
        \\      "path": "lib",
        \\      "exports": [{"name": "lib", "path": "src/index.nako3"}],
        \\      "commands": [{"name": "間違った", "args": [], "josi": []}]
        \\    }
        \\  }
        \\}
    );
    var list = diag.List.init(a);
    defer list.deinit();
    var report = try inspectEnvironmentDir(a, io, tmp.dir, false, &list);
    defer report.deinit();
    try testing.expect(report.mismatch_count >= 1);
    try testing.expectEqual(Sharing.failed, report.sharing);
}
