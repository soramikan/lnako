//! v1 クライアント pipeline の E2E テスト（D-01〜D-10 / R 系の接続）。
//!
//! 固定 fixture はテスト内で P03 の pack から作り、実ネットワークを使わない。

const std = @import("std");
const builtin = @import("builtin");

const types = @import("v1_types.zig");
const v1_manifest = @import("v1_manifest.zig");
const v1_archive = @import("v1_archive.zig");
const metadata_manifest = @import("v1_metadata_manifest.zig");
const v1_lock = @import("v1_lock.zig");
const client = @import("v1_client.zig");
const client_lock = @import("v1_client_lock.zig");
const v1_runtime = @import("v1_runtime.zig");
const diag = @import("diagnostics.zig");

const testing = std.testing;

fn writeFile(dir: std.Io.Dir, io: std.Io, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

const DependencySpec = struct { id: []const u8, req: []const u8 };

const PackageSpec = struct {
    id: []const u8,
    version: []const u8,
    dependencies: []const DependencySpec = &.{},
    yanked: bool = false,
    global_commands: []const []const u8 = &.{},
    /// `[exports] "."` の binding。global の命令名を ZIP から導出させる。
    export_binding: []const u8 = "scoped",
    source_text: []const u8 = "# fixture\n",
    kind: types.Kind = .universal,
    /// native-prebuilt の pack 指定。
    native: metadata_manifest.NativeOverrides = .{},
    /// index の artifact 宣言。パッケージ実体の kind と一致させる。
    artifact_kind: []const u8 = "universal",
    artifact_runtimes: []const []const u8 = &.{ "lnako", "cnako", "wnako" },
    artifact_target_json: []const u8 = "null",
};

const Built = struct {
    bytes: []u8,
    sha256: []const u8,
};

/// pack で canonical `.npkg` を作り、sha256 を返す。
fn buildPackage(
    allocator: std.mem.Allocator,
    io: std.Io,
    spec: PackageSpec,
) !Built {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    const export_suffix = if (std.mem.eql(u8, spec.export_binding, "global"))
        ", binding = \"global\""
    else
        "";
    const manifest_text = switch (spec.kind) {
        .universal => try std.fmt.allocPrint(allocator,
            \\schema_version = 1
            \\[package]
            \\id = "{s}"
            \\version = "{s}"
            \\license = "MIT"
            \\description = "fixture"
            \\capabilities = ["pure-nako"]
            \\[exports]
            \\"." = {{ entry = "src/index.nako3"{s} }}
            \\[artifacts.universal]
            \\include = ["src/**"]
            \\
        , .{ spec.id, spec.version, export_suffix }),
        .esm => try std.fmt.allocPrint(allocator,
            \\schema_version = 1
            \\[package]
            \\id = "{s}"
            \\version = "{s}"
            \\license = "MIT"
            \\description = "fixture"
            \\capabilities = ["pure-nako"]
            \\[exports]
            \\"." = {{ entry = "dist/index.js"{s} }}
            \\[artifacts.esm]
            \\runtimes = ["cnako", "wnako"]
            \\entry = "dist/index.js"
            \\include = ["dist/**"]
            \\
        , .{ spec.id, spec.version, export_suffix }),
        .@"native-prebuilt" => try std.fmt.allocPrint(allocator,
            \\schema_version = 1
            \\[package]
            \\id = "{s}"
            \\version = "{s}"
            \\license = "MIT"
            \\description = "fixture"
            \\capabilities = ["native"]
            \\[exports]
            \\"." = {{ entry = "native/libdemo.so"{s} }}
            \\[artifacts.native]
            \\abi_version = {d}
            \\
        , .{ spec.id, spec.version, export_suffix, spec.native.abi_version orelse 1 }),
        .@"native-source" => try std.fmt.allocPrint(allocator,
            \\schema_version = 1
            \\[package]
            \\id = "{s}"
            \\version = "{s}"
            \\license = "MIT"
            \\description = "fixture"
            \\capabilities = ["native"]
            \\[exports]
            \\"." = {{ entry = "src/index.nako3"{s} }}
            \\[artifacts.native]
            \\abi_version = {d}
            \\source_include = ["src/**"]
            \\
        , .{ spec.id, spec.version, export_suffix, spec.native.abi_version orelse 1 }),
    };
    defer allocator.free(manifest_text);
    try writeFile(temporary.dir, io, "nako.toml", manifest_text);
    const entry_path = switch (spec.kind) {
        .universal, .@"native-source" => "src/index.nako3",
        .esm => "dist/index.js",
        .@"native-prebuilt" => "native/libdemo.so",
    };
    try writeFile(temporary.dir, io, entry_path, spec.source_text);

    var manifest = try v1_manifest.parse(allocator, manifest_text, .pack);
    defer manifest.deinit();
    const bytes = try v1_archive.pack(allocator, io, root, &manifest.doc, .{
        .kind = spec.kind,
        .native = spec.native,
    });

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const sha = try std.fmt.allocPrint(allocator, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    return .{ .bytes = bytes, .sha256 = sha };
}

const DependencyJson = struct { id: []const u8, req: []const u8 };

const VersionSpec = struct {
    version: []const u8,
    dependencies: []const DependencySpec = &.{},
    yanked: bool = false,
    global_commands: []const []const u8 = &.{},
    artifact_sha256: []const u8,
    artifact_url: []const u8,
    artifact_size: usize,
    artifact_kind: []const u8 = "universal",
    artifact_runtimes: []const []const u8 = &.{ "lnako", "cnako", "wnako" },
    artifact_target_json: []const u8 = "null",
};

fn writePackageIndex(
    allocator: std.mem.Allocator,
    fixture_dir: std.Io.Dir,
    io: std.Io,
    spec: PackageSpec,
    artifact_sha256: []const u8,
    artifact_url: []const u8,
    artifact_size: usize,
) !void {
    return writePackageIndexMulti(allocator, fixture_dir, io, spec.id, &.{.{
        .version = spec.version,
        .dependencies = spec.dependencies,
        .yanked = spec.yanked,
        .global_commands = spec.global_commands,
        .artifact_sha256 = artifact_sha256,
        .artifact_url = artifact_url,
        .artifact_size = artifact_size,
        .artifact_kind = spec.artifact_kind,
        .artifact_runtimes = spec.artifact_runtimes,
        .artifact_target_json = spec.artifact_target_json,
    }});
}

fn writePackageIndexMulti(
    allocator: std.mem.Allocator,
    fixture_dir: std.Io.Dir,
    io: std.Io,
    id: []const u8,
    versions: []const VersionSpec,
) !void {
    var json: std.Io.Writer.Allocating = .init(allocator);
    defer json.deinit();
    const writer = &json.writer;
    try writer.writeAll("{\"schema_version\":1,\"id\":");
    try std.json.Stringify.value(id, .{}, writer);
    try writer.writeAll(",\"scope_id\":\"01936d2a-8c4f-7b12-9a01-3e4f5a6b7c8d\",\"updated_at\":\"2026-11-27T13:30:00Z\",\"deprecated\":null,\"versions\":[");
    for (versions, 0..) |version, version_index| {
        if (version_index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"version\":");
        try std.json.Stringify.value(version.version, .{}, writer);
        try writer.writeAll(",\"published_at\":\"2026-11-27T13:30:00Z\",\"yanked\":");
        try writer.writeAll(if (version.yanked) "true" else "false");
        try writer.writeAll(if (version.yanked) ",\"yank_reason\":\"security\",\"license\":\"MIT\"" else ",\"yank_reason\":null,\"license\":\"MIT\"");
        try writer.writeAll(",\"capabilities\":[\"pure-nako\"],\"engines\":{\"lnako\":\">=0.2.0\"},\"exports_global_commands\":");
        try writer.writeAll(if (version.global_commands.len > 0) "true" else "false");
        try writer.writeAll(",\"global_commands\":[");
        for (version.global_commands, 0..) |command, index| {
            if (index > 0) try writer.writeAll(",");
            try std.json.Stringify.value(command, .{}, writer);
        }
        try writer.writeAll("],\"features\":{\"default\":[]},\"dependencies\":[");
        for (version.dependencies, 0..) |dependency, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.writeAll("{\"id\":");
            try std.json.Stringify.value(dependency.id, .{}, writer);
            try writer.writeAll(",\"req\":");
            try std.json.Stringify.value(dependency.req, .{}, writer);
            try writer.writeAll(",\"features\":[],\"default_features\":true,\"optional\":false,\"runtimes\":[\"lnako\"]}");
        }
        try writer.writeAll("],\"provenance\":{\"verified\":true},\"artifacts\":[{\"kind\":");
        try std.json.Stringify.value(version.artifact_kind, .{}, writer);
        try writer.writeAll(",\"runtimes\":[");
        for (version.artifact_runtimes, 0..) |runtime, runtime_index| {
            if (runtime_index > 0) try writer.writeAll(",");
            try std.json.Stringify.value(runtime, .{}, writer);
        }
        try writer.writeAll("],\"target\":");
        try writer.writeAll(version.artifact_target_json);
        try writer.writeAll(",\"hosting\":");
        try std.json.Stringify.value(if (std.mem.startsWith(u8, version.artifact_url, "https://cdn.example.invalid/")) "registry" else "external", .{}, writer);
        try writer.writeAll(",\"url\":");
        try std.json.Stringify.value(version.artifact_url, .{}, writer);
        try writer.writeAll(",\"sha256\":");
        try std.json.Stringify.value(version.artifact_sha256, .{}, writer);
        try writer.print(",\"size\":{d}}}],\"advisories\":[]}}", .{version.artifact_size});
    }
    try writer.writeAll("]}");

    const scope_end = std.mem.indexOfScalar(u8, id, '/').?;
    const path = try std.fmt.allocPrint(allocator, "index/v1/packages/{s}/{s}.json", .{
        id[1..scope_end], id[scope_end + 1 ..],
    });
    defer allocator.free(path);
    try writeFile(fixture_dir, io, path, json.written());
}

const Fixture = struct {
    project: std.testing.TmpDir,
    fixture: std.testing.TmpDir,
    project_root: []u8,
    fixture_root: []u8,
    allocator: std.mem.Allocator,
    io: std.Io,

    fn init(allocator: std.mem.Allocator, io: std.Io, root_dependencies: []const DependencyJson) !Fixture {
        var project = testing.tmpDir(.{});
        errdefer project.cleanup();
        var fixture = testing.tmpDir(.{});
        errdefer fixture.cleanup();
        const project_real = try project.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(project_real);
        const project_root = try allocator.dupe(u8, project_real);
        errdefer allocator.free(project_root);
        const fixture_real = try fixture.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(fixture_real);
        const fixture_root = try allocator.dupe(u8, fixture_real);
        errdefer allocator.free(fixture_root);

        var manifest: std.Io.Writer.Allocating = .init(allocator);
        defer manifest.deinit();
        try manifest.writer.writeAll("schema_version = 1\n[package]\nid = \"@acme/app\"\nversion = \"0.1.0\"\nlicense = \"MIT\"\n[dependencies]\n");
        for (root_dependencies) |dependency| {
            try manifest.writer.writeAll("\"");
            try manifest.writer.writeAll(dependency.id);
            try manifest.writer.writeAll("\" = ");
            try std.json.Stringify.value(dependency.req, .{}, &manifest.writer);
            try manifest.writer.writeAll("\n");
        }
        try writeFile(project.dir, io, "nako.toml", manifest.written());
        try writeFile(fixture.dir, io, "index/v1/config.json", config_json);
        return .{
            .project = project,
            .fixture = fixture,
            .project_root = project_root,
            .fixture_root = fixture_root,
            .allocator = allocator,
            .io = io,
        };
    }

    fn deinit(self: *Fixture) void {
        self.allocator.free(self.project_root);
        self.allocator.free(self.fixture_root);
        self.project.cleanup();
        self.fixture.cleanup();
        self.* = undefined;
    }

    fn addPackage(self: *Fixture, spec: PackageSpec, archive_path: []const u8, url: []const u8) !void {
        const built = try buildPackage(self.allocator, self.io, spec);
        defer self.allocator.free(built.bytes);
        defer self.allocator.free(built.sha256);
        try writeFile(self.fixture.dir, self.io, archive_path, built.bytes);
        try writePackageIndex(self.allocator, self.fixture.dir, self.io, spec, built.sha256, url, built.bytes.len);
    }
};

const config_json =
    \\{
    \\  "schema_version": 1,
    \\  "registry_id": "nako-official",
    \\  "api_base_url": "https://api.registry.example.invalid/v1",
    \\  "artifact_base_url": "https://cdn.example.invalid/artifacts",
    \\  "allowed_external_hosts": ["repo.example.invalid"]
    \\}
;

fn runClient(fixture: *Fixture, options: client.Options, diagnostics: *diag.List) !client.Report {
    var opts = options;
    opts.project_root = fixture.project_root;
    // loadProject は渡した handle の所有権を引き継ぐため、fixture が保持する
    // handle とは別に開いた複製を渡す。
    opts.project_dir = try fixture.project.dir.openDir(fixture.io, ".", .{ .follow_symlinks = false });
    opts.fixture_root = fixture.fixture_root;
    opts.registry_url = "https://registry.example.invalid";
    return client.run(fixture.allocator, fixture.io, opts, diagnostics);
}

test "D-01 固定 fixture の index から取得・照合し新 lock と環境を公開する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());

    var report = try runClient(&fixture, .{}, &diagnostics);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.package_count);
    try testing.expect(report.lock_wrote);
    try testing.expect(!report.reused_environment);

    const lock_bytes = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_bytes);
    var lock = try v1_lock.parse(a, lock_bytes);
    defer lock.deinit();
    try testing.expectEqual(@as(usize, 1), lock.profiles.len);
    try testing.expectEqualStrings("default", lock.profiles[0].name);
    try testing.expectEqual(@as(usize, 1), lock.profiles[0].nodes.len);
    try testing.expectEqualStrings("@acme/json", lock.profiles[0].nodes[0].id);

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqualStrings("default", loaded.profile);
    try testing.expectEqual(@as(usize, 1), loaded.packages.len);
    try testing.expectEqualStrings(".", loaded.packages[0].exports[0].subpath);
    try testing.expectEqualStrings("src/index.nako3", loaded.packages[0].exports[0].entry);

    // 再実行は同じ世代を再利用し、lock を書き換えない。
    var second_diagnostics = diag.List.init(arena.allocator());
    var second = try runClient(&fixture, .{}, &second_diagnostics);
    defer second.deinit();
    try testing.expect(!second.lock_wrote);
    try testing.expect(second.reused_environment);
    try testing.expectEqualStrings(report.generation, second.generation);
}

test "受理可能な空白を含む lock は sync --locked で生バイトのまま実行時照合に通る" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var first_diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, .{}, &first_diagnostics);
    defer first.deinit();
    try testing.expect(first.lock_wrote);

    const canonical = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(canonical);
    // JSON として受理される非正規表現（末尾の空白）を足す。コメントは
    // 正本パーサが受理しないため使わない。
    const raw_lock = try std.fmt.allocPrint(a, "{s}\n \t \n", .{canonical});
    defer a.free(raw_lock);
    try testing.expect(!std.mem.eql(u8, canonical, raw_lock));
    var parsed_raw = try v1_lock.parse(a, raw_lock);
    defer parsed_raw.deinit();
    try fixture.project.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = raw_lock });

    var diagnostics = diag.List.init(arena.allocator());
    var second = try runClient(&fixture, .{ .locked = true }, &diagnostics);
    defer second.deinit();
    try testing.expect(!second.lock_wrote);
    // 生バイトの digest は canonical 列と異なるため、既存世代は再利用せず
    // 正しい digest を持つ世代を作り直す。
    try testing.expect(!second.reused_environment);
    try testing.expect(!std.mem.eql(u8, first.generation, second.generation));

    // 環境の digest は canonical 列ではなく、ディスク上に残した生バイト列。
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(raw_lock, &digest, .{});
    const expected_digest = try std.fmt.allocPrint(a, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer a.free(expected_digest);
    try testing.expectEqualStrings(expected_digest, second.lock_sha256);

    // lock は一切書き換えない。
    const after_lock = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(after_lock);
    try testing.expectEqualStrings(raw_lock, after_lock);

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqualStrings(second.generation, loaded.generation);
    try testing.expectEqualStrings(expected_digest, loaded.lock_sha256);

    // `run --no-sync` と同じ実行時検証。生 lock の digest で環境と照合する。
    var runtime_environment = (try v1_runtime.load(a, io, fixture.project_root, .{})) orelse
        return error.TestUnexpectedResult;
    defer runtime_environment.deinit();
    try testing.expectEqualStrings(second.generation, runtime_environment.generation);
    try testing.expectEqualStrings(expected_digest, runtime_environment.lockSha256());
}

test "lock を書き換える場合は実際に書いた canonical 列をハッシュする" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "~1.0.0" },
    });
    defer fixture.deinit();
    try addTwoVersions(&fixture);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var first_diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, .{}, &first_diagnostics);
    defer first.deinit();

    const canonical = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(canonical);
    const old_raw = try std.fmt.allocPrint(a, "{s}\n \t", .{canonical});
    defer a.free(old_raw);
    try fixture.project.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = old_raw });

    try changeManifestToLatest(&fixture);
    var diagnostics = diag.List.init(arena.allocator());
    var second = try runClient(&fixture, .{}, &diagnostics);
    defer second.deinit();
    try testing.expect(second.lock_wrote);

    const written = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(written);
    try testing.expect(!std.mem.eql(u8, old_raw, written));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(written, &digest, .{});
    const expected_digest = try std.fmt.allocPrint(a, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer a.free(expected_digest);
    try testing.expectEqualStrings(expected_digest, second.lock_sha256);

    var runtime_environment = (try v1_runtime.load(a, io, fixture.project_root, .{})) orelse
        return error.TestUnexpectedResult;
    defer runtime_environment.deinit();
    try testing.expectEqualStrings(expected_digest, runtime_environment.lockSha256());
}

test "D-04 実バイト列のハッシュ不一致は lock も環境も変更しない" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );
    try writeFile(fixture.fixture.dir, io, "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg", "abd");

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(error.HashMismatch, runClient(&fixture, .{}, &diagnostics));

    try testing.expectError(error.FileNotFound, fixture.project.dir.access(io, "nako.lock", .{}));
    try testing.expectError(error.FileNotFound, fixture.project.dir.access(io, ".nako/v1/environment.json", .{}));
}

test "D-03 基底パス外の URL を取得前に拒否する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    // index の URL は基底パス外。実体は置かない（取得要求を送らないこと）。
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts-old/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts-old/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(error.OutsideBasePath, runClient(&fixture, .{}, &diagnostics));
}

test "D-06 lock のハッシュ不一致は --locked で拒否し、lock を書き換えない" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var first_diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, .{}, &first_diagnostics);
    first.deinit();

    const lock_bytes = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_bytes);
    const tampered = try a.dupe(u8, lock_bytes);
    defer a.free(tampered);
    const hash_position = std.mem.indexOf(u8, tampered, "sha256:").?;
    tampered[hash_position + 7] = if (tampered[hash_position + 7] == 'b') 'c' else 'b';
    tampered[hash_position + 8] = if (tampered[hash_position + 8] == 'b') 'c' else 'b';
    try fixture.project.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = tampered });

    var diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(error.LockedNotSatisfied, runClient(&fixture, .{ .locked = true }, &diagnostics));

    const unchanged = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(unchanged);
    try testing.expectEqualStrings(tampered, unchanged);
    // 既存環境は変更しない（新しい世代を公開しない）。
    const pointer_before = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(pointer_before);
    try testing.expect(std.mem.indexOf(u8, pointer_before, "gen-") != null);
}

test "D-07 許可外ホストへの redirect は追跡せず拒否する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );
    try writeFile(
        fixture.fixture.dir,
        io,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg.status",
        "302\nhttps://other.example.invalid/demo.npkg\n",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(error.RedirectNotAllowed, runClient(&fixture, .{}, &diagnostics));
    try testing.expectError(error.FileNotFound, fixture.project.dir.access(io, "nako.lock", .{}));
    try testing.expectError(error.FileNotFound, fixture.project.dir.access(io, ".nako/v1/environment.json", .{}));
}

test "D-08 同じハッシュなら基底パス配下の URL 変更を受理する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var first_diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, .{}, &first_diagnostics);
    const first_generation = try a.dupe(u8, first.generation);
    defer a.free(first_generation);
    first.deinit();

    // 同じ内容を別 path に置き、index の URL だけを変える。
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/moved/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/moved/json-1.1.0.npkg",
    );
    // 環境だけを消し、lock は保持する（lock と URL が独立であること）。
    try fixture.project.dir.deleteTree(io, ".nako");

    var diagnostics = diag.List.init(arena.allocator());
    var second = try runClient(&fixture, .{}, &diagnostics);
    defer second.deinit();
    try testing.expect(!second.lock_wrote);
    try testing.expectEqualStrings(first_generation, second.generation);
}

test "既存 lock の他 profile を保持し、選択 profile だけを置換する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var first_diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, .{}, &first_diagnostics);
    first.deinit();

    const lock_bytes = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_bytes);
    const needle = "\"profiles\": [";
    const position = std.mem.indexOf(u8, lock_bytes, needle).? + needle.len;
    const injected = try std.fmt.allocPrint(a, "{s}\n    {{\"name\":\"windows\",\"runtime\":\"lnako\",\"nodes\":[],\"root\":[],\"edges\":[]}},{s}", .{
        lock_bytes[0..position], lock_bytes[position..],
    });
    defer a.free(injected);
    try fixture.project.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = injected });
    // 要求範囲を変えて default profile を実際に置換させる。
    try fixture.project.dir.writeFile(io, .{
        .sub_path = "nako.toml",
        .data = "schema_version = 1\n[package]\nid = \"@acme/app\"\nversion = \"0.1.0\"\nlicense = \"MIT\"\n[dependencies]\n\"@acme/json\" = \"^1.1.0\"\n",
    });

    var diagnostics = diag.List.init(arena.allocator());
    var second = try runClient(&fixture, .{}, &diagnostics);
    defer second.deinit();
    try testing.expect(second.lock_wrote);

    const rewritten = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(rewritten);
    var lock = try v1_lock.parse(a, rewritten);
    defer lock.deinit();
    try testing.expectEqual(@as(usize, 2), lock.profiles.len);
    try testing.expectEqualStrings("default", lock.profiles[0].name);
    try testing.expectEqualStrings("windows", lock.profiles[1].name);
    try testing.expectEqual(@as(usize, 1), lock.profiles[0].nodes.len);
}

test "D-10 旧 lock は新形式の再作成を案内し、その場で書き換えない" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const legacy =
        \\schemaVersion = 2
        \\resolverVersion = 1
        \\[input]
        \\profile = "default"
        \\
    ;
    try fixture.project.dir.writeFile(io, .{ .sub_path = "nako.lock", .data = legacy });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(error.LegacyLock, runClient(&fixture, .{}, &diagnostics));
    const unchanged = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024));
    defer a.free(unchanged);
    try testing.expectEqualStrings(legacy, unchanged);
}

test "D-09 同一 Package ID の二版を別ノードとして解決し、別々の実体へ照合する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/left", .req = "^1.0.0" },
        .{ .id = "@acme/right", .req = "^1.0.0" },
    });
    defer fixture.deinit();

    const json_low = try buildPackage(a, io, .{ .id = "@acme/json", .version = "1.0.1" });
    defer a.free(json_low.bytes);
    defer a.free(json_low.sha256);
    try writeFile(fixture.fixture.dir, io, "urls/cdn.example.invalid/artifacts/acme/json-1.0.1.npkg", json_low.bytes);
    const json_high = try buildPackage(a, io, .{ .id = "@acme/json", .version = "1.2.1" });
    defer a.free(json_high.bytes);
    defer a.free(json_high.sha256);
    try writeFile(fixture.fixture.dir, io, "urls/cdn.example.invalid/artifacts/acme/json-1.2.1.npkg", json_high.bytes);
    try writePackageIndexMulti(a, fixture.fixture.dir, io, "@acme/json", &.{
        .{
            .version = "1.0.1",
            .artifact_sha256 = json_low.sha256,
            .artifact_url = "https://cdn.example.invalid/artifacts/acme/json-1.0.1.npkg",
            .artifact_size = json_low.bytes.len,
        },
        .{
            .version = "1.2.1",
            .artifact_sha256 = json_high.sha256,
            .artifact_url = "https://cdn.example.invalid/artifacts/acme/json-1.2.1.npkg",
            .artifact_size = json_high.bytes.len,
        },
    });
    try fixture.addPackage(
        .{
            .id = "@acme/left",
            .version = "1.0.0",
            .dependencies = &.{.{ .id = "@acme/json", .req = "~1.0.0" }},
        },
        "urls/cdn.example.invalid/artifacts/acme/left-1.0.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/left-1.0.0.npkg",
    );
    try fixture.addPackage(
        .{
            .id = "@acme/right",
            .version = "1.0.0",
            .dependencies = &.{.{ .id = "@acme/json", .req = "~1.2.0" }},
        },
        "urls/cdn.example.invalid/artifacts/acme/right-1.0.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/right-1.0.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    var report = try runClient(&fixture, .{}, &diagnostics);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 4), report.package_count);

    const lock_bytes = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_bytes);
    var lock = try v1_lock.parse(a, lock_bytes);
    defer lock.deinit();
    var json_nodes: usize = 0;
    var roots: std.StringHashMap(void) = .init(a);
    defer roots.deinit();
    for (lock.profiles[0].nodes) |node| {
        if (std.mem.eql(u8, node.id, "@acme/json")) json_nodes += 1;
        try testing.expect(!roots.contains(node.sha256));
        try roots.put(node.sha256, {});
    }
    try testing.expectEqual(@as(usize, 2), json_nodes);
}

test "D-02 許可された外部ホストの固定 URL を受理する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    try fixture.addPackage(
        spec,
        "urls/repo.example.invalid/demo.npkg",
        "https://repo.example.invalid/demo.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    var report = try runClient(&fixture, .{}, &diagnostics);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.package_count);
}

test "依存なしの v1 プロジェクトでも空の lock と環境を公開する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{});
    defer fixture.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    var report = try runClient(&fixture, .{}, &diagnostics);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 0), report.package_count);
    try testing.expect(report.lock_wrote);

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 0), loaded.packages.len);

    var second_diagnostics = diag.List.init(arena.allocator());
    var second = try runClient(&fixture, .{}, &second_diagnostics);
    defer second.deinit();
    try testing.expect(second.reused_environment);
    try testing.expect(!second.lock_wrote);
}

test "R-09 既存 lock の yank 版は hash 一致時に再利用し警告する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();

    const low = try buildPackage(a, io, .{ .id = "@acme/json", .version = "1.0.0" });
    defer a.free(low.bytes);
    defer a.free(low.sha256);
    try writeFile(fixture.fixture.dir, io, "urls/cdn.example.invalid/artifacts/acme/json-1.0.0.npkg", low.bytes);
    const high = try buildPackage(a, io, .{ .id = "@acme/json", .version = "1.1.0" });
    defer a.free(high.bytes);
    defer a.free(high.sha256);
    try writeFile(fixture.fixture.dir, io, "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg", high.bytes);

    var versions = [_]VersionSpec{
        .{
            .version = "1.0.0",
            .artifact_sha256 = low.sha256,
            .artifact_url = "https://cdn.example.invalid/artifacts/acme/json-1.0.0.npkg",
            .artifact_size = low.bytes.len,
        },
        .{
            .version = "1.1.0",
            .artifact_sha256 = high.sha256,
            .artifact_url = "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
            .artifact_size = high.bytes.len,
        },
    };
    try writePackageIndexMulti(a, fixture.fixture.dir, io, "@acme/json", &versions);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var first_diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, .{}, &first_diagnostics);
    first.deinit();

    const lock_before = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_before);
    versions[1].yanked = true;
    try writePackageIndexMulti(a, fixture.fixture.dir, io, "@acme/json", &versions);

    var diagnostics = diag.List.init(arena.allocator());
    var second = try runClient(&fixture, .{}, &diagnostics);
    defer second.deinit();
    try testing.expect(!second.lock_wrote);
    try testing.expect(second.warnings.len > 0);
    try testing.expect(std.mem.indexOf(u8, second.warnings[0], "yanked") != null);

    const lock_after = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_after);
    try testing.expectEqualStrings(lock_before, lock_after);
}

test "破損した世代は失敗にせず staging から作り直す" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var first_diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, .{}, &first_diagnostics);
    const generation = try a.dupe(u8, first.generation);
    defer a.free(generation);
    first.deinit();

    const env_path = try std.fmt.allocPrint(a, ".nako/v1/generations/{s}/environment.json", .{generation});
    defer a.free(env_path);
    try fixture.project.dir.writeFile(io, .{ .sub_path = env_path, .data = "{}" });

    var diagnostics = diag.List.init(arena.allocator());
    var second = try runClient(&fixture, .{}, &diagnostics);
    defer second.deinit();
    try testing.expect(!second.reused_environment);
    try testing.expectEqualStrings(generation, second.generation);

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.packages.len);
}

test "cnako ランタイムでは universal を選び、profile の runtime を記録する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{ .id = "@acme/json", .version = "1.1.0" };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    var report = try runClient(&fixture, .{ .runtime = .cnako }, &diagnostics);
    defer report.deinit();
    try testing.expectEqual(client.Runtime.cnako, report.runtime);

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqual(types.Runtime.cnako, loaded.runtime);
    try testing.expect(loaded.target_triple == null);
}

test "#6 index の global フラグが検証済み ZIP と異なれば公開しない" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    // index は global と言うが、ZIP の export は scoped。
    const spec = PackageSpec{
        .id = "@acme/json",
        .version = "1.1.0",
        .global_commands = &.{"甲"},
    };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(error.GlobalCommandsMismatch, runClient(&fixture, .{}, &diagnostics));
    try testing.expectError(error.FileNotFound, fixture.project.dir.access(io, "nako.lock", .{}));
    try testing.expectError(error.FileNotFound, fixture.project.dir.access(io, ".nako/v1/environment.json", .{}));
}

test "#6 index の global 命令名集合が検証済み ZIP と異なれば公開しない" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    // フラグは同じ global。ZIP の命令名は「甲」、index は「乙」。
    const spec = PackageSpec{
        .id = "@acme/json",
        .version = "1.1.0",
        .export_binding = "global",
        .source_text = "●甲とは\nここまで\n",
        .global_commands = &.{"乙"},
    };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(error.GlobalCommandsMismatch, runClient(&fixture, .{}, &diagnostics));
    try testing.expectError(error.FileNotFound, fixture.project.dir.access(io, "nako.lock", .{}));
    try testing.expectError(error.FileNotFound, fixture.project.dir.access(io, ".nako/v1/environment.json", .{}));
}

test "#6 index と ZIP の global 情報が一致すれば公開する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{
        .id = "@acme/json",
        .version = "1.1.0",
        .export_binding = "global",
        .source_text = "●甲とは\nここまで\n",
        .global_commands = &.{"甲"},
    };
    try fixture.addPackage(
        spec,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
    );

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    var report = try runClient(&fixture, .{}, &diagnostics);
    defer report.deinit();

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expect(loaded.packages[0].exports_global_commands);
    try testing.expectEqual(@as(usize, 1), loaded.packages[0].global_commands.len);
    try testing.expectEqualStrings("甲", loaded.packages[0].global_commands[0]);
}

// ---------------------------------------------------------------------------
// 公開失敗時のロールバック（世代 rename → lock → pointer の順序）
// ---------------------------------------------------------------------------

/// 1.0.0 と 1.1.0 を同じ index に置き、manifest の要求で選ぶ版を変えられる
/// ようにする。lock と世代が変わる公開失敗の検証用。
fn addTwoVersions(fixture: *Fixture) !void {
    const low = try buildPackage(fixture.allocator, fixture.io, .{
        .id = "@acme/json",
        .version = "1.0.0",
    });
    defer fixture.allocator.free(low.bytes);
    defer fixture.allocator.free(low.sha256);
    const high = try buildPackage(fixture.allocator, fixture.io, .{
        .id = "@acme/json",
        .version = "1.1.0",
    });
    defer fixture.allocator.free(high.bytes);
    defer fixture.allocator.free(high.sha256);

    try writeFile(
        fixture.fixture.dir,
        fixture.io,
        "urls/cdn.example.invalid/artifacts/acme/json-1.0.0.npkg",
        low.bytes,
    );
    try writeFile(
        fixture.fixture.dir,
        fixture.io,
        "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
        high.bytes,
    );
    try writePackageIndexMulti(fixture.allocator, fixture.fixture.dir, fixture.io, "@acme/json", &.{
        .{
            .version = "1.0.0",
            .artifact_sha256 = low.sha256,
            .artifact_url = "https://cdn.example.invalid/artifacts/acme/json-1.0.0.npkg",
            .artifact_size = low.bytes.len,
        },
        .{
            .version = "1.1.0",
            .artifact_sha256 = high.sha256,
            .artifact_url = "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg",
            .artifact_size = high.bytes.len,
        },
    });
}

fn setProjectDirMode(fixture: *Fixture, sub_path: []const u8, mode: u32) !void {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var dir = try fixture.project.dir.openDir(fixture.io, sub_path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer dir.close(fixture.io);
    try dir.setPermissions(fixture.io, @fromBackingInt(@intCast(mode)));
}

fn expectPublishedVersion(
    fixture: *Fixture,
    expected_generation: []const u8,
    expected_version: []const u8,
) !void {
    var loaded = (try client.loadEnvironment(fixture.allocator, fixture.io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqualStrings(expected_generation, loaded.generation);
    try testing.expectEqual(@as(usize, 1), loaded.packages.len);
    try testing.expectEqualStrings(expected_version, loaded.packages[0].version);
}

fn changeManifestToLatest(fixture: *Fixture) !void {
    try writeFile(fixture.project.dir, fixture.io, "nako.toml",
        \\schema_version = 1
        \\[package]
        \\id = "@acme/app"
        \\version = "0.1.0"
        \\license = "MIT"
        \\[dependencies]
        \\"@acme/json" = "=1.1.0"
        \\
    );
}

test "公開の rename 障害では旧 lock と旧環境をそのまま読める" {
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;

    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "~1.0.0" },
    });
    defer fixture.deinit();
    try addTwoVersions(&fixture);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var first_diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, .{}, &first_diagnostics);
    const old_generation = try a.dupe(u8, first.generation);
    defer a.free(old_generation);
    first.deinit();

    const old_lock = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(old_lock);
    const old_pointer = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(old_pointer);

    // 次の公開で 1.1.0 を選ばせ、世代 dir への rename だけを失敗させる。
    try changeManifestToLatest(&fixture);
    try setProjectDirMode(&fixture, ".nako/v1/generations", 0o555);
    var mode_restored = false;
    defer if (!mode_restored) setProjectDirMode(&fixture, ".nako/v1/generations", 0o755) catch {};

    var failure_diagnostics = diag.List.init(arena.allocator());
    var rename_failed = false;
    if (runClient(&fixture, .{}, &failure_diagnostics)) |report_value| {
        var report = report_value;
        report.deinit();
        return error.TestExpectedFailure;
    } else |err| {
        // rename 先の書込み拒否。早期の別要因で失敗したテストにしない。
        rename_failed = err == error.AccessDenied or
            err == error.PermissionDenied or
            err == error.ReadOnlyFileSystem;
    }
    try testing.expect(rename_failed);

    try setProjectDirMode(&fixture, ".nako/v1/generations", 0o755);
    mode_restored = true;

    const lock_after = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_after);
    const pointer_after = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(pointer_after);
    try testing.expectEqualStrings(old_lock, lock_after);
    try testing.expectEqualStrings(old_pointer, pointer_after);
    try expectPublishedVersion(&fixture, old_generation, "1.0.0");

    // 障害要因が消えれば同じ入力で新しい世代を公開できる。
    var recovery_diagnostics = diag.List.init(arena.allocator());
    var recovery = try runClient(&fixture, .{}, &recovery_diagnostics);
    defer recovery.deinit();
    try testing.expect(recovery.lock_wrote);
    try expectPublishedVersion(&fixture, recovery.generation, "1.1.0");
}

test "公開の pointer 障害では新 lock を旧内容へ戻し、旧環境を読める" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "~1.0.0" },
    });
    defer fixture.deinit();
    try addTwoVersions(&fixture);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var first_diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, .{}, &first_diagnostics);
    const old_generation = try a.dupe(u8, first.generation);
    defer a.free(old_generation);
    first.deinit();

    const old_lock = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(old_lock);
    const old_pointer = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(old_pointer);

    try changeManifestToLatest(&fixture);
    var failure_diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(
        error.InjectedPublishFailure,
        runClient(&fixture, .{ .test_fail_pointer = true }, &failure_diagnostics),
    );

    const lock_after = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_after);
    const pointer_after = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(pointer_after);
    try testing.expectEqualStrings(old_lock, lock_after);
    try testing.expectEqualStrings(old_pointer, pointer_after);
    try expectPublishedVersion(&fixture, old_generation, "1.0.0");

    var recovery_diagnostics = diag.List.init(arena.allocator());
    var recovery = try runClient(&fixture, .{}, &recovery_diagnostics);
    defer recovery.deinit();
    try expectPublishedVersion(&fixture, recovery.generation, "1.1.0");
}

test "#6 既存世代の再利用時も index の global 命令名変更を照合する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/json", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{
        .id = "@acme/json",
        .version = "1.1.0",
        .export_binding = "global",
        .source_text = "●甲とは\nここまで\n",
        .global_commands = &.{"甲"},
    };
    const archive_path = "urls/cdn.example.invalid/artifacts/acme/json-1.1.0.npkg";
    const url = "https://cdn.example.invalid/artifacts/acme/json-1.1.0.npkg";
    try fixture.addPackage(spec, archive_path, url);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    var report = try runClient(&fixture, .{}, &diagnostics);
    defer report.deinit();
    const generation = try a.dupe(u8, report.generation);
    defer a.free(generation);

    // lock は同じまま、index の名前集合だけを変える。
    const changed = PackageSpec{
        .id = "@acme/json",
        .version = "1.1.0",
        .export_binding = "global",
        .source_text = "●甲とは\nここまで\n",
        .global_commands = &.{"乙"},
    };
    try fixture.addPackage(changed, archive_path, url);

    var second_diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(error.GlobalCommandsMismatch, runClient(&fixture, .{}, &second_diagnostics));

    // 既存の lock と環境ポインタは変更しない。
    const lock_bytes = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_bytes);
    var lock = try v1_lock.parse(a, lock_bytes);
    defer lock.deinit();
    try testing.expectEqual(@as(usize, 1), lock.profiles.len);
    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqualStrings(generation, loaded.generation);
    try testing.expectEqualStrings("甲", loaded.packages[0].global_commands[0]);
}

test "#6 既存世代の再利用時も index の runtime 集合変更を照合する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/esm", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{
        .id = "@acme/esm",
        .version = "1.1.0",
        .kind = .esm,
        .source_text = "export const value = 1;\n",
        .artifact_kind = "esm",
        .artifact_runtimes = &.{ "cnako", "wnako" },
    };
    const archive_path = "urls/cdn.example.invalid/artifacts/acme/esm-1.1.0.npkg";
    const url = "https://cdn.example.invalid/artifacts/acme/esm-1.1.0.npkg";
    try fixture.addPackage(spec, archive_path, url);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, .{ .runtime = .cnako }, &diagnostics);
    const generation = try a.dupe(u8, first.generation);
    defer a.free(generation);
    first.deinit();

    const old_lock = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(old_lock);
    const old_pointer = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(old_pointer);

    // 同じ ZIP（同じ SHA-256）のまま index の runtimes だけを狭める。
    var changed = spec;
    changed.artifact_runtimes = &.{"cnako"};
    try fixture.addPackage(changed, archive_path, url);

    var second_diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(
        error.ArtifactRuntimeMismatch,
        runClient(&fixture, .{ .runtime = .cnako }, &second_diagnostics),
    );

    const lock_after = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_after);
    const pointer_after = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(pointer_after);
    try testing.expectEqualStrings(old_lock, lock_after);
    try testing.expectEqualStrings(old_pointer, pointer_after);
    try expectPublishedVersion(&fixture, generation, "1.1.0");
}

test "#6 既存世代の再利用時も index の native ABI 変更を照合する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/native", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{
        .id = "@acme/native",
        .version = "1.1.0",
        .kind = .@"native-prebuilt",
        .source_text = "DUMMY-ELF",
        .native = .{
            .target_triple = "x86_64-linux-gnu",
            .abi_version = 1,
            .glibc_min = "2.31",
            .library_path = "native/libdemo.so",
        },
        .artifact_kind = "native-prebuilt",
        .artifact_runtimes = &.{"lnako"},
        .artifact_target_json = "{\"target_triple\":\"x86_64-linux-gnu\",\"abi_version\":1,\"glibc_min\":\"2.31\"}",
    };
    const archive_path = "urls/cdn.example.invalid/artifacts/acme/native-1.1.0.npkg";
    const url = "https://cdn.example.invalid/artifacts/acme/native-1.1.0.npkg";
    try fixture.addPackage(spec, archive_path, url);

    const options = client.Options{
        .target_triple = "x86_64-linux-gnu",
        .glibc = "2.39",
        .abi_min = 1,
        .abi_max = 2,
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, options, &diagnostics);
    const generation = try a.dupe(u8, first.generation);
    defer a.free(generation);
    first.deinit();

    const old_lock = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(old_lock);
    const old_pointer = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(old_pointer);

    // 同じ ZIP のまま index の ABI だけを 2 へ変える（選択範囲には含める）。
    var changed = spec;
    changed.artifact_target_json = "{\"target_triple\":\"x86_64-linux-gnu\",\"abi_version\":2,\"glibc_min\":\"2.31\"}";
    try fixture.addPackage(changed, archive_path, url);

    var second_diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(
        error.ArtifactTargetMismatch,
        runClient(&fixture, options, &second_diagnostics),
    );

    const lock_after = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_after);
    const pointer_after = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(pointer_after);
    try testing.expectEqualStrings(old_lock, lock_after);
    try testing.expectEqualStrings(old_pointer, pointer_after);
    try expectPublishedVersion(&fixture, generation, "1.1.0");
}

test "#6 既存世代の再利用時も index の glibc 下限変更を照合する" {
    const a = testing.allocator;
    const io = testing.io;
    var fixture = try Fixture.init(a, io, &.{
        .{ .id = "@acme/native", .req = "^1.0.0" },
    });
    defer fixture.deinit();
    const spec = PackageSpec{
        .id = "@acme/native",
        .version = "1.1.0",
        .kind = .@"native-prebuilt",
        .source_text = "DUMMY-ELF",
        .native = .{
            .target_triple = "x86_64-linux-gnu",
            .abi_version = 1,
            .glibc_min = "2.31",
            .library_path = "native/libdemo.so",
        },
        .artifact_kind = "native-prebuilt",
        .artifact_runtimes = &.{"lnako"},
        .artifact_target_json = "{\"target_triple\":\"x86_64-linux-gnu\",\"abi_version\":1,\"glibc_min\":\"2.31\"}",
    };
    const archive_path = "urls/cdn.example.invalid/artifacts/acme/native-1.1.0.npkg";
    const url = "https://cdn.example.invalid/artifacts/acme/native-1.1.0.npkg";
    try fixture.addPackage(spec, archive_path, url);

    const options = client.Options{
        .target_triple = "x86_64-linux-gnu",
        .glibc = "2.39",
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var diagnostics = diag.List.init(arena.allocator());
    var first = try runClient(&fixture, options, &diagnostics);
    const generation = try a.dupe(u8, first.generation);
    defer a.free(generation);
    first.deinit();

    const old_lock = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(old_lock);
    const old_pointer = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(old_pointer);

    // 同じ ZIP のまま index の glibc 下限だけを下げる（ホストでは選択可能）。
    var changed = spec;
    changed.artifact_target_json = "{\"target_triple\":\"x86_64-linux-gnu\",\"abi_version\":1,\"glibc_min\":\"2.28\"}";
    try fixture.addPackage(changed, archive_path, url);

    var second_diagnostics = diag.List.init(arena.allocator());
    try testing.expectError(
        error.ArtifactTargetMismatch,
        runClient(&fixture, options, &second_diagnostics),
    );

    const lock_after = try fixture.project.dir.readFileAlloc(io, "nako.lock", a, .limited(1024 * 1024));
    defer a.free(lock_after);
    const pointer_after = try fixture.project.dir.readFileAlloc(io, ".nako/v1/environment.json", a, .limited(1024));
    defer a.free(pointer_after);
    try testing.expectEqualStrings(old_lock, lock_after);
    try testing.expectEqualStrings(old_pointer, pointer_after);
    try expectPublishedVersion(&fixture, generation, "1.1.0");
}
