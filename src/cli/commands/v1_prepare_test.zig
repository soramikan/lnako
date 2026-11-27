//! `run`/`build`/`test` の自動準備が v1 入口だけを受理し、旧 manifest・
//! 旧 lock / `.nako` へフォールバックしないことを確認する。

const std = @import("std");
const testing = std.testing;
const project_cmd = @import("project.zig");

const io = std.testing.io;
const generation = "gen-0123456789abcdef";

const local_manifest = "schema_version = 1\n[package]\n";

fn writeMain(dir: std.Io.Dir) !void {
    try dir.writeFile(io, .{ .sub_path = "main.nako3", .data = "「ok」と表示\n" });
}

fn writeManifest(dir: std.Io.Dir, body: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = "nako.toml", .data = body });
}

fn writeV1Environment(allocator: std.mem.Allocator, dir: std.Io.Dir, lock_bytes: []const u8) !void {
    return writeV1EnvironmentForProfile(allocator, dir, lock_bytes, "default");
}

fn writeV1EnvironmentForProfile(allocator: std.mem.Allocator, dir: std.Io.Dir, lock_bytes: []const u8, profile: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = "nako.lock", .data = lock_bytes });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const env = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"generation\":\"{s}\",\"profile\":\"{s}\",\"runtime\":\"lnako\",\"target_triple\":\"aarch64-macos-none\",\"lock_sha256\":\"sha256:{s}\",\"packages\":[]}}", .{ generation, profile, hex[0..] });
    defer allocator.free(env);
    const env_dir = try std.fmt.allocPrint(allocator, ".nako/v1/generations/{s}", .{generation});
    defer allocator.free(env_dir);
    try dir.createDirPath(io, env_dir);
    const env_rel = try std.fmt.allocPrint(allocator, "{s}/environment.json", .{env_dir});
    defer allocator.free(env_rel);
    try dir.writeFile(io, .{ .sub_path = env_rel, .data = env });
    try dir.createDirPath(io, ".nako/v1");
    const pointer = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"generation\":\"{s}\"}}", .{generation});
    defer allocator.free(pointer);
    try dir.writeFile(io, .{ .sub_path = ".nako/v1/environment.json", .data = pointer });
}

fn writeProject(allocator: std.mem.Allocator, dir: std.Io.Dir, lock_bytes: []const u8) ![]u8 {
    try writeManifest(dir, local_manifest);
    try writeMain(dir);
    try writeV1Environment(allocator, dir, lock_bytes);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const length = try dir.realPath(io, &buffer);
    return allocator.dupe(u8, buffer[0..length]);
}

fn emptyLock() []const u8 {
    return "{\"schema_version\":1,\"profiles\":[{\"name\":\"default\",\"runtime\":\"lnako\",\"target_triple\":\"aarch64-macos-none\",\"nodes\":[],\"root\":[],\"edges\":[]}]}";
}

test "prepareForExecution: v1 環境は --no-sync で lock と照合する" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try writeProject(a, tmp.dir, emptyLock());
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);
    var flags = project_cmd.PrepFlags{ .no_sync = true };
    var err_out: std.Io.Writer.Allocating = .init(a);
    defer err_out.deinit();
    try project_cmd.prepareForExecution(a, io, main_path, &flags, null, "run", &err_out.writer);
    try testing.expect(std.mem.indexOf(u8, err_out.written(), "v1 パッケージ環境を確認しました") != null);
}

test "prepareForExecution: v1 lock ハッシュ不一致は旧経路へ落とさず失敗する" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try writeProject(a, tmp.dir, emptyLock());
    defer a.free(root);
    // environment が固定した hash と実 lock を食い違わせる。
    try tmp.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = "{\"schema_version\":1,\"profiles\":[{\"name\":\"default\",\"runtime\":\"lnako\",\"nodes\":[],\"root\":[],\"edges\":[]}]}" });
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);
    var flags = project_cmd.PrepFlags{ .no_sync = true };
    var err_out: std.Io.Writer.Allocating = .init(a);
    defer err_out.deinit();
    try testing.expectError(error.Failed, project_cmd.prepareForExecution(a, io, main_path, &flags, null, "run", &err_out.writer));
}

test "prepareForExecution: 旧 lock は v1 環境から読み替えない" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // 環境の lock_sha256 を旧 lock の実バイト列に合わせ、ハッシュ照合を
    // 通過させた上で v1_lock が LegacyLock として拒否することを確認する。
    try writeManifest(tmp.dir, local_manifest);
    try writeMain(tmp.dir);
    try writeV1Environment(a, tmp.dir, "{\"schemaVersion\":2,\"packages\":{}}");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);
    var flags = project_cmd.PrepFlags{ .no_sync = true };
    var err_out: std.Io.Writer.Allocating = .init(a);
    defer err_out.deinit();
    try testing.expectError(error.Failed, project_cmd.prepareForExecution(a, io, main_path, &flags, null, "run", &err_out.writer));
    try testing.expect(std.mem.indexOf(u8, err_out.written(), "旧形式の nako.lock") != null);
}

test "prepareForExecution: 依存なし v1 は環境なしで local 実行を受理する" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir, local_manifest);
    try writeMain(tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);

    for ([_][]const u8{ "run", "build", "test" }) |verb| {
        var flags = project_cmd.PrepFlags{};
        var err_out: std.Io.Writer.Allocating = .init(a);
        defer err_out.deinit();
        try project_cmd.prepareForExecution(a, io, main_path, &flags, null, verb, &err_out.writer);
        // 旧形式の lock/env を生成しない。
        try testing.expect(!dirEntryExists(tmp.dir, "nako.lock"));
        try testing.expect(!dirEntryExists(tmp.dir, ".nako/v1/environment.json"));
        try testing.expect(!dirEntryExists(tmp.dir, ".nako/environment.json"));
    }
}

test "prepareForExecution: 依存ありで v1 環境が無ければ fixture 指定の sync を案内する" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/json" = "^1.0.0"
        \\
    );
    try writeMain(tmp.dir);
    // 旧 lock と旧環境があっても v1 の代替にしない。
    try tmp.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = "{\"schemaVersion\":2,\"packages\":{}}" });
    try tmp.dir.createDirPath(io, ".nako");
    try tmp.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = "{\"schemaVersion\":1,\"profile\":\"default\"}" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);

    var flags = project_cmd.PrepFlags{};
    var err_out: std.Io.Writer.Allocating = .init(a);
    defer err_out.deinit();
    try testing.expectError(error.Failed, project_cmd.prepareForExecution(a, io, main_path, &flags, null, "run", &err_out.writer));
    try testing.expect(std.mem.indexOf(u8, err_out.written(), "--v1-fixture") != null);
    try testing.expect(std.mem.indexOf(u8, err_out.written(), "フォールバックしません") != null);
}

test "prepareForExecution: 旧 manifest は再作成を案内して拒否する" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir,
        \\[package]
        \\name = "app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\
    );
    try writeMain(tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);

    var flags = project_cmd.PrepFlags{};
    var err_out: std.Io.Writer.Allocating = .init(a);
    defer err_out.deinit();
    try testing.expectError(error.Failed, project_cmd.prepareForExecution(a, io, main_path, &flags, null, "run", &err_out.writer));
    try testing.expect(std.mem.indexOf(u8, err_out.written(), "旧形式") != null);
    try testing.expect(std.mem.indexOf(u8, err_out.written(), "再作成") != null);
}

test "prepareForExecution: v1 として不正な manifest も旧経路へ落とさない" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // schema_version はあるが [package] が無い。
    try writeManifest(tmp.dir, "schema_version = 1\n");
    try writeMain(tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);

    var flags = project_cmd.PrepFlags{};
    var err_out: std.Io.Writer.Allocating = .init(a);
    defer err_out.deinit();
    try testing.expectError(error.Failed, project_cmd.prepareForExecution(a, io, main_path, &flags, null, "run", &err_out.writer));
    try testing.expect(std.mem.indexOf(u8, err_out.written(), "v1 形式として不正") != null);
    try testing.expect(std.mem.indexOf(u8, err_out.written(), "[package]") != null);
}

fn dirEntryExists(dir: std.Io.Dir, sub_path: []const u8) bool {
    dir.access(io, sub_path, .{}) catch return false;
    return true;
}

test "prepareForExecution: manifest と lock root の不一致は --no-sync/--locked で書き換えない" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // 空の lock に対して manifest だけが直接依存を宣言している。
    try writeManifest(tmp.dir,
        \\schema_version = 1
        \\[package]
        \\[dependencies]
        \\"@acme/json" = "^1.0.0"
        \\
    );
    try writeMain(tmp.dir);
    try writeV1Environment(a, tmp.dir, emptyLock());
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);

    const lock_before = try tmp.dir.readFileAlloc(io, "nako.lock", a, .limited(1 << 20));
    defer a.free(lock_before);
    const pointer_before = try tmp.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1 << 20));
    defer a.free(pointer_before);

    const cases = [_]project_cmd.PrepFlags{
        .{ .no_sync = true },
        .{ .locked = true },
    };
    for (cases) |flags_value| {
        var flags = flags_value;
        var err_out: std.Io.Writer.Allocating = .init(a);
        defer err_out.deinit();
        try testing.expectError(error.Failed, project_cmd.prepareForExecution(a, io, main_path, &flags, null, "run", &err_out.writer));
        try testing.expect(std.mem.indexOf(u8, err_out.written(), "一致しません") != null);

        const lock_after = try tmp.dir.readFileAlloc(io, "nako.lock", a, .limited(1 << 20));
        defer a.free(lock_after);
        try testing.expectEqualStrings(lock_before, lock_after);
        const pointer_after = try tmp.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1 << 20));
        defer a.free(pointer_after);
        try testing.expectEqualStrings(pointer_before, pointer_after);
    }
}

test "prepareForExecution: 非既定 profile と feature の選択を v1 環境検証へ渡す" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir,
        \\schema_version = 1
        \\[package]
        \\[features]
        \\default = []
        \\extra = []
        \\[profiles.default]
        \\runtime = "lnako"
        \\[profiles.dev]
        \\runtime = "lnako"
        \\
    );
    try writeMain(tmp.dir);
    const dev_lock = "{\"schema_version\":1,\"profiles\":[{\"name\":\"dev\",\"runtime\":\"lnako\",\"target_triple\":\"aarch64-macos-none\",\"nodes\":[],\"root\":[],\"edges\":[]}]}";
    try writeV1EnvironmentForProfile(a, tmp.dir, dev_lock, "dev");
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);

    var flags = project_cmd.PrepFlags{ .no_sync = true, .profile = "dev" };
    defer flags.deinit(a);
    try flags.features.append(a, "extra");
    var err_out: std.Io.Writer.Allocating = .init(a);
    defer err_out.deinit();
    try project_cmd.prepareForExecution(a, io, main_path, &flags, null, "run", &err_out.writer);
    try testing.expect(std.mem.indexOf(u8, err_out.written(), "profile: dev") != null);
}

test "prepareForExecution: 別 runtime だけの依存では旧環境があっても lock を要求しない（M-05 相当）" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir,
        \\schema_version = 1
        \\[package]
        \\[runtime-dependencies.cnako]
        \\"@acme/cnako-only" = "^1.0.0"
        \\
    );
    try writeMain(tmp.dir);
    // 旧環境は読まない。壊れた JSON でも v1 入口の判定へ影響しない。
    try tmp.dir.createDirPath(io, ".nako");
    try tmp.dir.writeFile(io, .{ .sub_path = ".nako/environment.json", .data = "{\"schemaVersion\":" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);

    for ([_][]const u8{ "run", "build", "test" }) |verb| {
        var flags = project_cmd.PrepFlags{};
        defer flags.deinit(a);
        var err_out: std.Io.Writer.Allocating = .init(a);
        defer err_out.deinit();
        try project_cmd.prepareForExecution(a, io, main_path, &flags, null, verb, &err_out.writer);
    }
}

test "prepareForExecution: 未選択 optional 依存では lock を要求せず、選択時だけ要求する" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir,
        \\schema_version = 1
        \\[package]
        \\[features]
        \\default = []
        \\extra = ["dep:json"]
        \\[dependencies]
        \\"@acme/json" = { version = "^1.0.0", optional = true }
        \\
    );
    try writeMain(tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);

    var default_flags = project_cmd.PrepFlags{};
    defer default_flags.deinit(a);
    var default_err: std.Io.Writer.Allocating = .init(a);
    defer default_err.deinit();
    try project_cmd.prepareForExecution(a, io, main_path, &default_flags, null, "run", &default_err.writer);

    var selected_flags = project_cmd.PrepFlags{};
    defer selected_flags.deinit(a);
    try selected_flags.features.append(a, "extra");
    var selected_err: std.Io.Writer.Allocating = .init(a);
    defer selected_err.deinit();
    try testing.expectError(error.Failed, project_cmd.prepareForExecution(a, io, main_path, &selected_flags, null, "run", &selected_err.writer));
    try testing.expect(std.mem.indexOf(u8, selected_err.written(), "--v1-fixture") != null);
}

test "prepareForExecution: dev-dependencies だけでは test も v1 環境を要求しない" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir,
        \\schema_version = 1
        \\[package]
        \\[dev-dependencies]
        \\"@acme/test-kit" = "^1.0.0"
        \\
    );
    try writeMain(tmp.dir);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const main_path = try std.fs.path.join(a, &.{ root, "main.nako3" });
    defer a.free(main_path);

    var flags = project_cmd.PrepFlags{};
    defer flags.deinit(a);
    var err_out: std.Io.Writer.Allocating = .init(a);
    defer err_out.deinit();
    try project_cmd.prepareForExecution(a, io, main_path, &flags, null, "test", &err_out.writer);

    // dev 宣言だけを理由に v1 lock / 環境を作らない。
    try testing.expect(!dirEntryExists(tmp.dir, "nako.lock"));
    try testing.expect(!dirEntryExists(tmp.dir, ".nako/v1/environment.json"));
    try testing.expect(!dirEntryExists(tmp.dir, ".nako/environment.json"));
}
