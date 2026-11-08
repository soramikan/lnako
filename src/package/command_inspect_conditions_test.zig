//! `command_inspect` の OS 条件照合表示と名前空間 alias 診断の統合テスト。
//! plugin の初期化・実行は行わず、`.nako/environment.json` と package
//! manifest だけを入力にする。

const std = @import("std");
const testing = std.testing;
const command_inspect = @import("command_inspect.zig");
const command_conditions = @import("command_conditions.zig");
const diag = @import("diagnostics.zig");
const namespace_check = @import("namespace_check.zig");
const test_sandbox = @import("test_sandbox.zig");

const io = testing.io;

fn writeEnv(dir: std.Io.Dir, body: []const u8) !void {
    try dir.createDirPath(io, ".nako");
    try dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = body });
}

fn writeManifest(dir: std.Io.Dir, sub_path: []const u8, body: []const u8) !void {
    try dir.createDirPath(io, std.fs.path.dirname(sub_path).?);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = body });
}

const macos_target = command_conditions.Target{
    .runtime = "lnako",
    .os = "macos",
    .cpu = "aarch64",
    .abi = "gnu",
};

const windows_target = command_conditions.Target{
    .runtime = "lnako",
    .os = "windows",
    .cpu = "x86_64",
    .abi = "msvc",
};

const os_environment =
    \\{
    \\  "schemaVersion": 1,
    \\  "lockSha256": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    \\  "profile": "default",
    \\  "runtime": "lnako",
    \\  "packages": {
    \\    "pkg:windows-only": {
    \\      "name": "windows-only",
    \\      "version": "1.0.0",
    \\      "path": "winpkg",
    \\      "exports": [{"name": "main", "native": [{"path": "lib/win.dll", "when": "os == 'windows'"}]}],
    \\      "commands": [{"name": "窓命令", "args": [], "josi": []}]
    \\    },
    \\    "pkg:macos-only": {
    \\      "name": "macos-only",
    \\      "version": "1.0.0",
    \\      "path": "macpkg",
    \\      "exports": [{"name": "main", "native": [{"path": "lib/mac.dylib", "when": "os == 'macos'"}]}],
    \\      "commands": [{"name": "果物", "args": [], "josi": []}]
    \\    }
    \\  }
    \\}
;

const windows_manifest =
    \\[package]
    \\name = "windows-only"
    \\version = "1.0.0"
    \\license = "MIT"
    \\[[exports]]
    \\name = "main"
    \\native = { path = "lib/win.dll", when = "os == 'windows'" }
;

const macos_manifest =
    \\[package]
    \\name = "macos-only"
    \\version = "1.0.0"
    \\license = "MIT"
    \\[[exports]]
    \\name = "main"
    \\native = { path = "lib/mac.dylib", when = "os == 'macos'" }
;

test "OS条件: 宣言命令を持つpackageの条件と利用可否を表示し、不一致は未検査にする" {
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir, os_environment);
    try writeManifest(tmp.dir, "winpkg/nako.toml", windows_manifest);
    try writeManifest(tmp.dir, "macpkg/nako.toml", macos_manifest);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{
        .target = macos_target,
    }, &diagnostics);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 2), report.conditions.len);
    try testing.expectEqualStrings("pkg:windows-only", report.conditions[0].package_key);
    try testing.expectEqualStrings("os == 'windows'", report.conditions[0].condition);
    try testing.expectEqual(command_conditions.Availability.unavailable, report.conditions[0].availability);
    try testing.expectEqualStrings("pkg:macos-only", report.conditions[1].package_key);
    try testing.expectEqual(command_conditions.Availability.available, report.conditions[1].availability);

    // 現在の OS で利用できない package は「未検査/利用不可」として記録し、
    // 衝突・不一致の検査対象にもしない。
    try testing.expectEqual(@as(usize, 1), report.uninspected.len);
    try testing.expectEqualStrings("pkg:windows-only", report.uninspected[0].package_key);
    try testing.expectEqual(command_inspect.UninspectedReason.os_unavailable, report.uninspected[0].reason);
    try testing.expectEqual(@as(usize, 1), report.inspected_count);
    try testing.expectEqual(command_inspect.Sharing.partial, report.sharing);
    try testing.expectEqual(@as(usize, 0), diagnostics.errorCount());

    const json = try command_conditions.conditionsJson(a, report.conditions);
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"package\":\"pkg:windows-only\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"condition\":\"os == 'windows'\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"availability\":\"unavailable\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"availability\":\"available\"") != null);
}

test "OS条件: 現在のOSに一致する環境では全packageを検査済みにする" {
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir, os_environment);
    try writeManifest(tmp.dir, "winpkg/nako.toml", windows_manifest);
    try writeManifest(tmp.dir, "macpkg/nako.toml", macos_manifest);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{
        .target = windows_target,
    }, &diagnostics);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 1), report.inspected_count);
    try testing.expectEqual(@as(usize, 1), report.uninspected.len);
    try testing.expectEqualStrings("pkg:macos-only", report.uninspected[0].package_key);
    try testing.expectEqual(command_conditions.Availability.available, report.conditions[0].availability);
    try testing.expectEqual(command_conditions.Availability.unavailable, report.conditions[1].availability);
}

test "OS条件: OS不一致だけでは厳格共用検査を失敗にしない" {
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir, os_environment);
    try writeManifest(tmp.dir, "winpkg/nako.toml", windows_manifest);
    try writeManifest(tmp.dir, "macpkg/nako.toml", macos_manifest);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{
        .target = macos_target,
        .strict_sharing = true,
    }, &diagnostics);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
    try testing.expectEqual(command_inspect.Sharing.partial, report.sharing);
}

const namespace_environment =
    \\{
    \\  "schemaVersion": 1,
    \\  "lockSha256": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
    \\  "profile": "default",
    \\  "runtime": "lnako",
    \\  "dependencies": [
    \\    {"alias": "my-util", "package": "pkg:a"},
    \\    {"alias": "my_util", "package": "pkg:b"},
    \\    {"alias": "@", "package": "pkg:a"},
    \\    {"alias": "util", "package": "pkg:a"},
    \\    {"alias": "my util", "package": "pkg:b"}
    \\  ],
    \\  "packages": {
    \\    "pkg:a": {
    \\      "name": "lib-a",
    \\      "version": "1.0.0",
    \\      "path": "pkg-a",
    \\      "exports": [{"name": "main", "path": "src/a.nako3"}],
    \\      "commands": [{"name": "甲", "args": [], "josi": []}]
    \\    },
    \\    "pkg:b": {
    \\      "name": "lib-b",
    \\      "version": "1.0.0",
    \\      "path": "pkg-b",
    \\      "exports": [{"name": "main", "path": "src/b.nako3"}],
    \\      "commands": [{"name": "乙", "args": [], "josi": []}]
    \\    }
    \\  }
    \\}
;

fn writeNamespacePackages(dir: std.Io.Dir) !void {
    // 正しい source を置くと再生成との不一致診断は出ない。
    try dir.createDirPath(io, "pkg-a/src");
    try dir.writeFile(io, .{
        .sub_path = "pkg-a/nako.toml",
        .data =
        \\[package]
        \\name = "lib-a"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\path = "src/a.nako3"
        ,
    });
    try dir.writeFile(io, .{ .sub_path = "pkg-a/src/a.nako3", .data = "●甲とは\nここまで\n" });
    try dir.createDirPath(io, "pkg-b/src");
    try dir.writeFile(io, .{
        .sub_path = "pkg-b/nako.toml",
        .data =
        \\[package]
        \\name = "lib-b"
        \\version = "1.0.0"
        \\license = "MIT"
        \\[[exports]]
        \\name = "main"
        \\path = "src/b.nako3"
        ,
    });
    try dir.writeFile(io, .{ .sub_path = "pkg-b/src/b.nako3", .data = "●乙とは\nここまで\n" });
}

test "名前空間: aliasの空・重複・不正文字・既存module衝突を診断する" {
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir, namespace_environment);
    try writeNamespacePackages(tmp.dir);
    // プロジェクト直下の既存 module 名（`util.nako3`）と alias `util` が衝突する。
    try tmp.dir.writeFile(io, .{ .sub_path = "util.nako3", .data = "●道具とは\nここまで\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.nako3", .data = "「ok」を表示\n" });

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{}, &diagnostics);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 5), report.alias_count);
    // ソート順は "@" → "my util" → "my-util" → "my_util" → "util"。先に
    // my_util を登録した `my util` は不正文字、続く `my-util` が重複になる。
    try testing.expectEqual(@as(usize, 4), report.namespace_issues.len);
    var duplicates: usize = 0;
    var empties: usize = 0;
    var invalid: usize = 0;
    var collisions: usize = 0;
    for (report.namespace_issues) |issue| switch (issue.kind) {
        .duplicate => duplicates += 1,
        .empty => empties += 1,
        .invalid_char => invalid += 1,
        .module_collision => collisions += 1,
        .reserved => {},
    };
    try testing.expectEqual(@as(usize, 1), duplicates);
    try testing.expectEqual(@as(usize, 1), empties);
    try testing.expectEqual(@as(usize, 1), invalid);
    try testing.expectEqual(@as(usize, 1), collisions);

    // 空・重複は公開 namespace を一意に決められないため error 診断にする。
    try testing.expect(diagnostics.errorCount() >= 2);
    var has_alias_collision = false;
    for (diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, diag.E012_ALIAS_COLLISION)) has_alias_collision = true;
    }
    try testing.expect(has_alias_collision);

    const json = try namespace_check.summaryJson(
        a,
        report.alias_count,
        report.namespace_issues,
        report.namespace_scan_complete,
        report.namespace_scan_reason,
    );
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"aliases\":5") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"scan\":\"complete\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"duplicate\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"module_collision\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"severity\":\"error\"") != null);
}

test "名前空間: 正常なaliasは診断せず既存のalias解決に影響しない" {
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "dependencies": [{"alias": "lib-a", "package": "pkg:a"}],
        \\  "packages": {
        \\    "pkg:a": {
        \\      "name": "lib-a",
        \\      "version": "1.0.0",
        \\      "path": "pkg-a",
        \\      "exports": [{"name": "main", "path": "src/a.nako3"}],
        \\      "commands": [{"name": "甲", "args": [], "josi": []}],
        \\      "dependencies": [{"alias": "lib-b", "package": "pkg:a"}]
        \\    }
        \\  }
        \\}
    );
    try writeNamespacePackages(tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.nako3", .data = "「ok」を表示\n" });

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{}, &diagnostics);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 2), report.alias_count);
    try testing.expectEqual(@as(usize, 0), report.namespace_issues.len);
    try testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
}

test "OS条件: package宣言命令の索引はOS不一致のpackageを検査済みにしない" {
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir, os_environment);
    try writeManifest(tmp.dir, "winpkg/nako.toml", windows_manifest);
    try writeManifest(tmp.dir, "macpkg/nako.toml", macos_manifest);
    // lock の target を macOS にして loadDeclaredCommands 経由でも判定する。
    try tmp.dir.writeFile(io, .{
        .sub_path = "nako.lock",
        .data =
        \\{"schemaVersion":1,"resolverVersion":1,"input":{"manifestSha256":"sha256:0000000000000000000000000000000000000000000000000000000000000000","profile":"default","features":[],"target":{"os":"macos","cpu":"aarch64","abi":"gnu"},"runtime":"lnako"},"packages":{},"profiles":{"default":{"os":"macos","cpu":"aarch64","abi":"gnu"}}}
        ,
    });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    var index = try command_inspect.loadDeclaredCommands(a, io, root);
    defer index.deinit();

    const windows = index.find("pkg:windows-only").?;
    try testing.expect(!windows.available);
    const macos = index.find("pkg:macos-only").?;
    try testing.expect(macos.available);
}

test "OS条件: commands metadataが無いpackageでもOS条件とos_unavailableを表示する" {
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:windows-only": {
        \\      "name": "windows-only",
        \\      "version": "1.0.0",
        \\      "path": "winpkg",
        \\      "exports": [{"name": "main", "native": [{"path": "lib/win.dll", "when": "os == 'windows'"}]}]
        \\    }
        \\  }
        \\}
    );
    try writeManifest(tmp.dir, "winpkg/nako.toml", windows_manifest);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{
        .target = macos_target,
    }, &diagnostics);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 1), report.conditions.len);
    try testing.expectEqual(command_conditions.Availability.unavailable, report.conditions[0].availability);
    // OS 不一致と metadata 欠落は別理由として併記し、strict sharing が
    // metadata 欠落を見逃さない。
    try testing.expectEqual(@as(usize, 2), report.uninspected.len);
    try testing.expectEqual(command_inspect.UninspectedReason.os_unavailable, report.uninspected[0].reason);
    try testing.expectEqual(command_inspect.UninspectedReason.native_without_metadata, report.uninspected[1].reason);
}

test "名前空間: module候補が512件を超える場合は決定的に打ち切り未検査を表示する" {
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "dependencies": [{"alias": "zzz", "package": "pkg:a"}],
        \\  "packages": {
        \\    "pkg:a": {
        \\      "name": "lib-a",
        \\      "version": "1.0.0",
        \\      "path": "pkg-a",
        \\      "exports": [{"name": "main", "path": "src/a.nako3"}],
        \\      "commands": [{"name": "甲", "args": [], "josi": []}]
        \\    }
        \\  }
        \\}
    );
    try writeNamespacePackages(tmp.dir);
    // ソート後に `zzz.nako3` が 513 件目になり、決定的に検査対象から外れる。
    var index: usize = 0;
    while (index < 512) : (index += 1) {
        const name = try std.fmt.allocPrint(a, "m{d:0>3}.nako3", .{index});
        defer a.free(name);
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "●modとは\nここまで\n" });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "zzz.nako3", .data = "●zzzとは\nここまで\n" });

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var first = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{}, &diagnostics);
    defer first.deinit();
    try testing.expect(!first.namespace_scan_complete);
    try testing.expect(first.namespace_scan_reason != null);
    const first_json = try command_conditions.conditionsJson(a, first.conditions);
    defer a.free(first_json);
    const first_ns = try namespace_check.summaryJson(
        a,
        first.alias_count,
        first.namespace_issues,
        first.namespace_scan_complete,
        first.namespace_scan_reason,
    );
    defer a.free(first_ns);

    var diagnostics2 = diag.List.init(a);
    defer diagnostics2.deinit();
    var second = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{}, &diagnostics2);
    defer second.deinit();
    const second_ns = try namespace_check.summaryJson(
        a,
        second.alias_count,
        second.namespace_issues,
        second.namespace_scan_complete,
        second.namespace_scan_reason,
    );
    defer a.free(second_ns);
    // 同一 tree では列挙順に依存せず同じ診断になる。
    try testing.expectEqualStrings(first_ns, second_ns);
}

test "名前空間: symlinkされたsource moduleも既存module衝突に含める" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "dependencies": [{"alias": "util", "package": "pkg:a"}],
        \\  "packages": {
        \\    "pkg:a": {
        \\      "name": "lib-a",
        \\      "version": "1.0.0",
        \\      "path": "pkg-a",
        \\      "exports": [{"name": "main", "path": "src/a.nako3"}],
        \\      "commands": [{"name": "甲", "args": [], "josi": []}]
        \\    }
        \\  }
        \\}
    );
    try writeNamespacePackages(tmp.dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "real.nako3", .data = "●道具とは\nここまで\n" });
    try tmp.dir.symLink(io, "real.nako3", "util.nako3", .{});

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{}, &diagnostics);
    defer report.deinit();
    var collisions: usize = 0;
    for (report.namespace_issues) |issue| {
        if (issue.kind == .module_collision) collisions += 1;
    }
    try testing.expectEqual(@as(usize, 1), collisions);
}

test "OS条件: checkがtarget_from_lockを無効にすると陳腐lockでもunknownに留める" {
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir, os_environment);
    try writeManifest(tmp.dir, "winpkg/nako.toml", windows_manifest);
    try writeManifest(tmp.dir, "macpkg/nako.toml", macos_manifest);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{
        .target = null,
        .target_from_lock = false,
    }, &diagnostics);
    defer report.deinit();

    try testing.expectEqual(@as(usize, 2), report.conditions.len);
    for (report.conditions) |condition| {
        try testing.expectEqual(command_conditions.Availability.unknown, condition.availability);
    }
    try testing.expectEqual(@as(usize, 0), report.uninspected.len);
}

test "OS条件: OS不一致とmetadata欠落が併存するとstrict-sharingはE033で失敗する" {
    const a = testing.allocator;
    var tmp = test_sandbox.tmpDir(.{});
    defer tmp.cleanup();
    try writeEnv(tmp.dir,
        \\{
        \\  "schemaVersion": 1,
        \\  "lockSha256": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        \\  "profile": "default",
        \\  "runtime": "lnako",
        \\  "packages": {
        \\    "pkg:windows-only": {
        \\      "name": "windows-only",
        \\      "version": "1.0.0",
        \\      "path": "winpkg",
        \\      "exports": [{"name": "main", "native": [{"path": "lib/win.dll", "when": "os == 'windows'"}]}]
        \\    }
        \\  }
        \\}
    );
    try writeManifest(tmp.dir, "winpkg/nako.toml", windows_manifest);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try command_inspect.inspectEnvironmentDir(a, io, tmp.dir, .{
        .target = macos_target,
        .strict_sharing = true,
    }, &diagnostics);
    defer report.deinit();

    try testing.expectEqual(command_inspect.Sharing.failed, report.sharing);
    var strict_errors: usize = 0;
    for (diagnostics.items.items) |item| {
        if (std.mem.eql(u8, item.code, diag.E033_STRICT_SHARING_FAILED)) strict_errors += 1;
    }
    try testing.expectEqual(@as(usize, 1), strict_errors);
}
