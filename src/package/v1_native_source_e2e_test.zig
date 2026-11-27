//! T-02/T-08/T-09 のクライアント接続（許可済み native-source のビルド）。
//!
//! 固定 fixture の index に universal / native-source / native-prebuilt を
//! 並べ、取得・lock 照合後にだけビルドが走ることを確認する。`zig` は
//! テスト用の固定スクリプトへ差し替え、実ネットワークと実コンパイラに
//! 依存しない。

const std = @import("std");
const builtin = @import("builtin");

const types = @import("v1_types.zig");
const v1_manifest = @import("v1_manifest.zig");
const v1_archive = @import("v1_archive.zig");
const v1_cross = @import("v1_cross.zig");
const zip = @import("v1_zip.zig");
const mfiles = @import("v1_metadata_files.zig");
const metadata_manifest = @import("v1_metadata_manifest.zig");
const v1_lock = @import("v1_lock.zig");
const client = @import("v1_client.zig");
const client_env = @import("v1_client_env.zig");
const native_source = @import("v1_native_source.zig");
const diag = @import("diagnostics.zig");

const testing = std.testing;
const io = testing.io;
const a = testing.allocator;

const id = "@acme/native";
const version = "1.0.0";
const target_triple = "x86_64-linux-gnu";
const host_glibc = "2.30";
const source_build_input = "native/build.zig";
const prebuilt_glibc = "2.31";

const FileSpec = struct { path: []const u8, data: []const u8 };

const Built = struct { bytes: []u8, sha256: []const u8, size: usize };

fn write(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}

/// pack が返したバイト列の所有権を受け取り、index 用の Built にする。
fn ownBuilt(bytes: []u8) !Built {
    errdefer a.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const sha = try std.fmt.allocPrint(a, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    return .{ .bytes = bytes, .sha256 = sha, .size = bytes.len };
}

fn pack(
    manifest_text: []const u8,
    files: []const FileSpec,
    kind: types.Kind,
    native: metadata_manifest.NativeOverrides,
) !Built {
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);

    try write(temporary.dir, "nako.toml", manifest_text);
    for (files) |file| try write(temporary.dir, file.path, file.data);

    var manifest = try v1_manifest.parse(a, manifest_text, .pack);
    defer manifest.deinit();
    const bytes = try v1_archive.pack(a, io, root, &manifest.doc, .{
        .kind = kind,
        .native = native,
    });
    return ownBuilt(bytes);
}

fn universalManifest(package_id: []const u8, package_version: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\schema_version = 1
        \\[package]
        \\id = "{s}"
        \\version = "{s}"
        \\license = "MIT"
        \\[exports]
        \\"." = {{ entry = "src/index.nako3" }}
        \\[artifacts.universal]
        \\include = ["src/**"]
        \\
    , .{ package_id, package_version });
}

/// universal と native-source を同じ入力から pack できるマニフェスト。
/// 共通 exports は `.nako3` のままにし、native-source のビルド入力は
/// `source_include` 内の `native/build.zig` だけにする。
fn sourceManifest(package_id: []const u8, package_version: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\schema_version = 1
        \\[package]
        \\id = "{s}"
        \\version = "{s}"
        \\license = "MIT"
        \\[exports]
        \\"." = {{ entry = "src/index.nako3" }}
        \\[artifacts.universal]
        \\include = ["src/**"]
        \\[artifacts.native]
        \\abi_version = 1
        \\source_include = ["src/**", "native/**"]
        \\
    , .{ package_id, package_version });
}

fn prebuiltManifest(package_id: []const u8, package_version: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\schema_version = 1
        \\[package]
        \\id = "{s}"
        \\version = "{s}"
        \\license = "MIT"
        \\[exports]
        \\"." = {{ entry = "native/libdemo.so" }}
        \\[artifacts.native]
        \\abi_version = 1
        \\
    , .{ package_id, package_version });
}

const ArtifactSpec = struct {
    kind: []const u8,
    target_json: []const u8,
    url: []const u8,
    built: Built,
};

fn writeIndex(fixture: std.Io.Dir, package_id: []const u8, package_version: []const u8, artifacts: []const ArtifactSpec) !void {
    var json: std.Io.Writer.Allocating = .init(a);
    defer json.deinit();
    const writer = &json.writer;
    try writer.writeAll("{\"schema_version\":1,\"id\":");
    try std.json.Stringify.value(package_id, .{}, writer);
    try writer.writeAll(",\"scope_id\":\"01936d2a-8c4f-7b12-9a01-3e4f5a6b7c8d\",\"updated_at\":\"2026-11-27T13:30:00Z\",\"deprecated\":null,\"versions\":[{\"version\":");
    try std.json.Stringify.value(package_version, .{}, writer);
    try writer.writeAll(",\"published_at\":\"2026-11-27T13:30:00Z\",\"yanked\":false,\"yank_reason\":null,\"license\":\"MIT\",\"capabilities\":[\"native\"],\"engines\":{\"lnako\":\">=0.2.0\"},\"exports_global_commands\":false,\"global_commands\":[],\"features\":{\"default\":[]},\"dependencies\":[],\"provenance\":{\"verified\":true},\"artifacts\":[");
    for (artifacts, 0..) |artifact, index| {
        if (index > 0) try writer.writeAll(",");
        try writer.writeAll("{\"kind\":");
        try std.json.Stringify.value(artifact.kind, .{}, writer);
        // universal は 3 runtime すべて、native 系は lnako だけを宣言する。
        if (std.mem.eql(u8, artifact.kind, "universal")) {
            try writer.writeAll(",\"runtimes\":[\"lnako\",\"cnako\",\"wnako\"],\"target\":");
        } else {
            try writer.writeAll(",\"runtimes\":[\"lnako\"],\"target\":");
        }
        try writer.writeAll(artifact.target_json);
        try writer.writeAll(",\"hosting\":\"registry\",\"url\":");
        try std.json.Stringify.value(artifact.url, .{}, writer);
        try writer.writeAll(",\"sha256\":");
        try std.json.Stringify.value(artifact.built.sha256, .{}, writer);
        try writer.print(",\"size\":{d}}}", .{artifact.built.size});
    }
    try writer.writeAll("],\"advisories\":[]}]}");

    const scope_end = std.mem.indexOfScalar(u8, package_id, '/').?;
    const path = try std.fmt.allocPrint(a, "index/v1/packages/{s}/{s}.json", .{
        package_id[1..scope_end], package_id[scope_end + 1 ..],
    });
    defer a.free(path);
    try write(fixture, path, json.written());
}

const Fixture = struct {
    project: testing.TmpDir,
    fixture: testing.TmpDir,
    project_root: []u8,
    fixture_root: []u8,

    fn init(dependency: []const u8) !Fixture {
        var project = testing.tmpDir(.{});
        errdefer project.cleanup();
        var fixture = testing.tmpDir(.{});
        errdefer fixture.cleanup();
        const project_root = try project.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(project_root);
        const fixture_root = try fixture.dir.realPathFileAlloc(io, ".", a);
        errdefer a.free(fixture_root);

        var self = Fixture{
            .project = project,
            .fixture = fixture,
            .project_root = try a.dupe(u8, project_root),
            .fixture_root = try a.dupe(u8, fixture_root),
        };
        a.free(project_root);
        a.free(fixture_root);
        try self.writeManifest(dependency);
        try write(fixture.dir, "index/v1/config.json",
            \\{
            \\  "schema_version": 1,
            \\  "registry_id": "nako-official",
            \\  "api_base_url": "https://api.registry.example.invalid/v1",
            \\  "artifact_base_url": "https://cdn.example.invalid/artifacts",
            \\  "allowed_external_hosts": []
            \\}
        );
        return self;
    }

    fn deinit(self: *Fixture) void {
        a.free(self.project_root);
        a.free(self.fixture_root);
        self.project.cleanup();
        self.fixture.cleanup();
        self.* = undefined;
    }

    fn writeManifest(self: *Fixture, dependency: []const u8) !void {
        const manifest = try std.fmt.allocPrint(a,
            \\schema_version = 1
            \\[package]
            \\id = "@acme/app"
            \\version = "0.1.0"
            \\license = "MIT"
            \\[dependencies]
            \\"{s}" = "^1.0.0"
            \\
        , .{dependency});
        defer a.free(manifest);
        try write(self.project.dir, "nako.toml", manifest);
    }
};

fn artifactUrl(name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "https://cdn.example.invalid/artifacts/{s}.npkg", .{name});
}

fn addArtifact(fixture: *Fixture, name: []const u8, built: Built) ![]const u8 {
    const url = try artifactUrl(name);
    const path = try std.fmt.allocPrint(a, "urls/cdn.example.invalid/artifacts/{s}.npkg", .{name});
    defer a.free(path);
    try write(fixture.fixture.dir, path, built.bytes);
    return url;
}

fn makeUniversal(package_id: []const u8, package_version: []const u8) !Built {
    const manifest = try universalManifest(package_id, package_version);
    defer a.free(manifest);
    return pack(manifest, &.{
        .{ .path = "src/index.nako3", .data = "# universal\n" },
    }, .universal, .{});
}

fn makeNativeSource(package_id: []const u8, package_version: []const u8) !Built {
    const manifest = try sourceManifest(package_id, package_version);
    defer a.free(manifest);
    return pack(manifest, &.{
        .{ .path = "src/index.nako3", .data = "# source\n" },
        .{ .path = source_build_input, .data = "// build\n" },
    }, .@"native-source", .{});
}

const UniversalAndSource = struct { universal: Built, source: Built };

/// 同一のマニフェスト文書から universal と native-source を実際に pack する。
/// 二つの `.npkg` が共通 exports を保ったまま §3.3 の交叉検証を通ることを
/// 確かめる回帰の入力になる。
fn makeUniversalAndSource(package_id: []const u8, package_version: []const u8) !UniversalAndSource {
    const manifest = try sourceManifest(package_id, package_version);
    defer a.free(manifest);

    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try temporary.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try write(temporary.dir, "nako.toml", manifest);
    try write(temporary.dir, "src/index.nako3", "# source\n");
    try write(temporary.dir, source_build_input, "// build\n");

    var parsed = try v1_manifest.parse(a, manifest, .pack);
    defer parsed.deinit();
    const universal_bytes = try v1_archive.pack(a, io, root, &parsed.doc, .{
        .kind = .universal,
    });
    errdefer a.free(universal_bytes);
    const source_bytes = try v1_archive.pack(a, io, root, &parsed.doc, .{
        .kind = .@"native-source",
    });
    errdefer a.free(source_bytes);

    var result = UniversalAndSource{
        .universal = try ownBuilt(universal_bytes),
        .source = undefined,
    };
    errdefer {
        a.free(result.universal.bytes);
        a.free(result.universal.sha256);
    }
    result.source = try ownBuilt(source_bytes);
    return result;
}

fn makeNativePrebuilt(package_id: []const u8, package_version: []const u8) !Built {
    const manifest = try prebuiltManifest(package_id, package_version);
    defer a.free(manifest);
    return pack(manifest, &.{
        .{ .path = "native/libdemo.so", .data = "prebuilt" },
    }, .@"native-prebuilt", .{
        .target_triple = target_triple,
        .abi_version = 1,
        .glibc_min = prebuilt_glibc,
        .library_path = "native/libdemo.so",
    });
}

fn makeNativePrebuiltAt(
    package_id: []const u8,
    package_version: []const u8,
    triple: []const u8,
    glibc_min: []const u8,
) !Built {
    const manifest = try prebuiltManifest(package_id, package_version);
    defer a.free(manifest);
    return pack(manifest, &.{
        .{ .path = "native/libdemo.so", .data = "prebuilt" },
    }, .@"native-prebuilt", .{
        .target_triple = triple,
        .abi_version = 1,
        .glibc_min = glibc_min,
        .library_path = "native/libdemo.so",
    });
}

fn hostGnuTriple(allocator: std.mem.Allocator) ![]u8 {
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return error.SkipZigTest,
    };
    return std.fmt.allocPrint(allocator, "{s}-linux-gnu", .{arch});
}

fn nextMinorVersion(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return error.InvalidVersion;
    const major = text[0..dot];
    const minor = std.fmt.parseInt(u32, text[dot + 1 ..], 10) catch return error.InvalidVersion;
    return std.fmt.allocPrint(allocator, "{s}.{d}", .{ major, minor + 1 });
}

extern "c" fn gnu_get_libc_version() ?[*:0]const u8;

fn runHost(fixture: *Fixture, diagnostics: *diag.List) !client.Report {
    return client.run(a, io, .{
        .project_root = fixture.project_root,
        .project_dir = try fixture.project.dir.openDir(io, ".", .{ .follow_symlinks = false }),
        .fixture_root = fixture.fixture_root,
        .registry_url = "https://registry.example.invalid",
    }, diagnostics);
}

fn writeFakeZig(allocator: std.mem.Allocator, marker: []const u8, exit_code: u8, install: bool) ![:0]u8 {
    // Write alongside the marker so the executable outlives this function.
    const directory = std.fs.path.dirname(marker) orelse ".";
    const extension = try native_source.libraryExtension(builtin.os.tag);
    const args_path = try std.fmt.allocPrint(allocator, "{s}.args", .{marker});
    defer allocator.free(args_path);
    const script = if (install)
        try std.fmt.allocPrint(allocator,
            \\#!/bin/sh
            \\set -eu
            \\printf ran > "{s}"
            \\printf '%s\\n' "$@" > "{s}"
            \\prefix=
            \\while [ "$#" -gt 0 ]; do
            \\  case "$1" in
            \\    --prefix) shift; prefix="$1" ;;
            \\  esac
            \\  shift
            \\done
            \\mkdir -p "$prefix/lib"
            \\printf built > "$prefix/lib/libfixture{s}"
            \\exit {d}
            \\
        , .{ marker, args_path, extension, exit_code })
    else
        try std.fmt.allocPrint(allocator,
            \\#!/bin/sh
            \\set -eu
            \\printf ran > "{s}"
            \\printf '%s\\n' "$@" > "{s}"
            \\exit {d}
            \\
        , .{ marker, args_path, exit_code });
    defer allocator.free(script);

    const path = try std.fs.path.join(allocator, &.{ directory, "fake-zig" });
    defer allocator.free(path);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, script);
    try file.setPermissions(io, .executable_file);
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
}

fn run(fixture: *Fixture, permissions: []const client.SourcePermission, zig: []const u8, diagnostics: *diag.List) !client.Report {
    return client.run(a, io, .{
        .project_root = fixture.project_root,
        .project_dir = try fixture.project.dir.openDir(io, ".", .{ .follow_symlinks = false }),
        .fixture_root = fixture.fixture_root,
        .registry_url = "https://registry.example.invalid",
        .target_triple = target_triple,
        .glibc = host_glibc,
        .source_permissions = permissions,
        .native_source = .{ .zig_executable = zig },
    }, diagnostics);
}

fn expectNoBuild(marker: []const u8) !void {
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(io, marker, .{}));
}

fn readFile(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024));
}

const RawFile = struct { path: []const u8, data: []const u8 };

/// `pack` を通さず、`artifact.entries` を含む METADATA.toml と
/// COMMANDS.json を持つ Canonical ZIP を組み立てる。クライアントの
/// verify・materialize・sync 経路へ、パッカーがまだ出力しない表を渡す。
fn packRaw(files: []const RawFile) !Built {
    const metadata =
        \\schema_version = 1
        \\
        \\[package]
        \\id = "@acme/native"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[artifact]
        \\kind = "native-source"
        \\runtimes = ["lnako"]
        \\
        \\[artifact.native]
        \\abi_version = 1
        \\
        \\[artifact.entries]
        \\"." = "native/build.zig"
        \\
        \\[exports]
        \\"." = { entry = "src/index.nako3", binding = "scoped" }
        \\
    ;
    const commands =
        \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[],"constants":[]}}}
        \\
    ;

    var entries: std.ArrayList(zip.SourceEntry) = .empty;
    defer entries.deinit(a);
    var file_entries: std.ArrayList(mfiles.Entry) = .empty;
    defer file_entries.deinit(a);

    for (files) |file| {
        try entries.append(a, .{ .path = file.path, .data = file.data });
        try file_entries.append(a, mfiles.entryFor(file.path, file.data));
    }
    try entries.append(a, .{ .path = v1_archive.metadata_path, .data = metadata });
    try file_entries.append(a, mfiles.entryFor(v1_archive.metadata_path, metadata));
    try entries.append(a, .{ .path = v1_archive.commands_path, .data = commands });
    try file_entries.append(a, mfiles.entryFor(v1_archive.commands_path, commands));

    const files_bytes = try mfiles.emit(a, file_entries.items);
    defer a.free(files_bytes);
    try entries.append(a, .{ .path = v1_archive.files_path, .data = files_bytes });

    const bytes = try zip.build(a, entries.items, .{});
    errdefer a.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const sha = try std.fmt.allocPrint(a, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    return .{ .bytes = bytes, .sha256 = sha, .size = bytes.len };
}

test "artifact.entries が指す native/build.zig を共通 entry より優先して起動する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(id);
    defer fixture.deinit();

    const source = try packRaw(&.{
        .{ .path = "src/index.nako3", .data = "# not the build input\n" },
        .{ .path = source_build_input, .data = "// build\n" },
    });
    defer a.free(source.bytes);
    defer a.free(source.sha256);
    const source_url = try addArtifact(&fixture, "native-source-entries", source);
    defer a.free(source_url);

    try writeIndex(fixture.fixture.dir, id, version, &.{
        .{ .kind = "native-source", .target_json = "{\"abi_version\":1}", .url = source_url, .built = source },
    });

    const marker = try std.fs.path.join(a, &.{ fixture.fixture_root, "entries-zig-ran" });
    defer a.free(marker);
    const zig = try writeFakeZig(a, marker, 0, true);
    defer a.free(zig);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try run(&fixture, &.{.{ .id = id, .sha256 = source.sha256 }}, zig, &diagnostics);
    defer report.deinit();

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqual(types.Kind.@"native-source", loaded.packages[0].kind);
    try testing.expect(std.mem.startsWith(u8, loaded.packages[0].exports[0].entry, "native-build/"));
    try testing.expect(std.mem.indexOf(u8, loaded.packages[0].exports[0].entry, "/out/lib/libfixture") != null);

    const args_path = try std.fmt.allocPrint(a, "{s}.args", .{marker});
    defer a.free(args_path);
    const args = try readFile(args_path);
    defer a.free(args);
    try testing.expect(std.mem.indexOf(u8, args, source_build_input) != null);
    try testing.expect(std.mem.indexOf(u8, args, "src/index.nako3") == null);
}

test "T-02 許可済み native-source を選び、staging 内の zig build 出力へ差し替える" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(id);
    defer fixture.deinit();

    // 同一の nako.toml から universal と native-source を実際に pack し、
    // 共通 exports を保ったまま交叉検証を通す。
    const pair = try makeUniversalAndSource(id, version);
    const universal = pair.universal;
    const source = pair.source;
    defer a.free(universal.bytes);
    defer a.free(universal.sha256);
    defer a.free(source.bytes);
    defer a.free(source.sha256);

    var universal_verified = try v1_archive.verify(a, universal.bytes);
    defer universal_verified.deinit();
    var source_verified = try v1_archive.verify(a, source.bytes);
    defer source_verified.deinit();
    var verified_pair = [_]*v1_archive.Verified{ &universal_verified, &source_verified };
    try v1_cross.validate(a, &verified_pair);
    try testing.expectEqualStrings("src/index.nako3", universal_verified.metadata_model.selectedEntry(".").?);
    try testing.expectEqualStrings("# source\n", try universal_verified.selectedEntry("."));
    try testing.expectEqualStrings("src/index.nako3", source_verified.exports()[0].entry);
    try testing.expectEqualStrings(source_build_input, source_verified.metadata_model.selectedEntry(".").?);
    try testing.expectEqualStrings("// build\n", try source_verified.selectedEntry("."));

    const prebuilt = try makeNativePrebuilt(id, version);
    defer a.free(prebuilt.bytes);
    defer a.free(prebuilt.sha256);

    const universal_url = try addArtifact(&fixture, "universal", universal);
    defer a.free(universal_url);
    const source_url = try addArtifact(&fixture, "native-source", source);
    defer a.free(source_url);
    const prebuilt_url = try addArtifact(&fixture, "native-prebuilt", prebuilt);
    defer a.free(prebuilt_url);

    try writeIndex(fixture.fixture.dir, id, version, &.{
        .{ .kind = "universal", .target_json = "null", .url = universal_url, .built = universal },
        .{ .kind = "native-source", .target_json = "{\"abi_version\":1}", .url = source_url, .built = source },
        .{ .kind = "native-prebuilt", .target_json = "{\"target_triple\":\"x86_64-linux-gnu\",\"abi_version\":1,\"glibc_min\":\"2.31\"}", .url = prebuilt_url, .built = prebuilt },
    });

    const marker = try std.fs.path.join(a, &.{ fixture.fixture_root, "zig-ran" });
    defer a.free(marker);
    const zig = try writeFakeZig(a, marker, 0, true);
    defer a.free(zig);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try run(&fixture, &.{.{ .id = id, .sha256 = source.sha256 }}, zig, &diagnostics);
    defer report.deinit();

    try testing.expect(report.lock_wrote);
    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.packages.len);
    try testing.expectEqual(types.Kind.@"native-source", loaded.packages[0].kind);
    try testing.expectEqualStrings(".", loaded.packages[0].exports[0].subpath);
    try testing.expect(std.mem.startsWith(u8, loaded.packages[0].exports[0].entry, "native-build/"));
    try testing.expect(std.mem.indexOf(u8, loaded.packages[0].exports[0].entry, "/out/lib/libfixture") != null);

    const env_path = try std.fs.path.join(a, &.{
        fixture.project_root,    ".nako/v1/generations",              loaded.generation,
        loaded.packages[0].root, loaded.packages[0].exports[0].entry,
    });
    defer a.free(env_path);
    const built = try readFile(env_path);
    defer a.free(built);
    try testing.expectEqualStrings("built", built);

    const ran = try readFile(marker);
    defer a.free(ran);
    // fake zig が実際に起動したこと（＝ビルド工程が走ったこと）を確認する。
    try testing.expectEqualStrings("ran", ran);

    // 共通 entry（.nako3）ではなく、artifact.entries が指す build.zig が
    // --build-file として渡る。
    const args_path = try std.fmt.allocPrint(a, "{s}.args", .{marker});
    defer a.free(args_path);
    const args = try readFile(args_path);
    defer a.free(args);
    try testing.expect(std.mem.indexOf(u8, args, "--build-file") != null);
    try testing.expect(std.mem.indexOf(u8, args, source_build_input) != null);
    try testing.expect(std.mem.indexOf(u8, args, "src/index.nako3") == null);
    try testing.expect(std.mem.indexOf(u8, args, "--global-cache") == null);
}

test "T-08 未許可の native-source を飛ばして universal を選び、ビルドしない" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(id);
    defer fixture.deinit();

    const universal = try makeUniversal(id, version);
    defer a.free(universal.bytes);
    defer a.free(universal.sha256);
    const source = try makeNativeSource(id, version);
    defer a.free(source.bytes);
    defer a.free(source.sha256);
    const prebuilt = try makeNativePrebuilt(id, version);
    defer a.free(prebuilt.bytes);
    defer a.free(prebuilt.sha256);

    const universal_url = try addArtifact(&fixture, "universal", universal);
    defer a.free(universal_url);
    const source_url = try addArtifact(&fixture, "native-source", source);
    defer a.free(source_url);
    const prebuilt_url = try addArtifact(&fixture, "native-prebuilt", prebuilt);
    defer a.free(prebuilt_url);

    try writeIndex(fixture.fixture.dir, id, version, &.{
        .{ .kind = "universal", .target_json = "null", .url = universal_url, .built = universal },
        .{ .kind = "native-source", .target_json = "{\"abi_version\":1}", .url = source_url, .built = source },
        .{ .kind = "native-prebuilt", .target_json = "{\"target_triple\":\"x86_64-linux-gnu\",\"abi_version\":1,\"glibc_min\":\"2.31\"}", .url = prebuilt_url, .built = prebuilt },
    });

    const marker = try std.fs.path.join(a, &.{ fixture.fixture_root, "zig-ran" });
    defer a.free(marker);
    const zig = try writeFakeZig(a, marker, 0, true);
    defer a.free(zig);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try run(&fixture, &.{}, zig, &diagnostics);
    defer report.deinit();

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqual(types.Kind.universal, loaded.packages[0].kind);
    try expectNoBuild(marker);
}

test "T-08 index の SHA-256 と許可が違えば universal を選ぶ" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(id);
    defer fixture.deinit();

    const universal = try makeUniversal(id, version);
    defer a.free(universal.bytes);
    defer a.free(universal.sha256);
    const source = try makeNativeSource(id, version);
    defer a.free(source.bytes);
    defer a.free(source.sha256);

    const universal_url = try addArtifact(&fixture, "universal", universal);
    defer a.free(universal_url);
    const source_url = try addArtifact(&fixture, "native-source", source);
    defer a.free(source_url);

    try writeIndex(fixture.fixture.dir, id, version, &.{
        .{ .kind = "universal", .target_json = "null", .url = universal_url, .built = universal },
        .{ .kind = "native-source", .target_json = "{\"abi_version\":1}", .url = source_url, .built = source },
    });

    const marker = try std.fs.path.join(a, &.{ fixture.fixture_root, "zig-ran" });
    defer a.free(marker);
    const zig = try writeFakeZig(a, marker, 0, true);
    defer a.free(zig);

    const wrong = [_]client.SourcePermission{.{
        .id = id,
        .sha256 = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    }};

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try run(&fixture, &wrong, zig, &diagnostics);
    defer report.deinit();

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqual(types.Kind.universal, loaded.packages[0].kind);
    try expectNoBuild(marker);
}

test "T-09 universal がなく未許可なら明示許可を診断し、ビルドも lock も開始しない" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fixture = try Fixture.init(id);
    defer fixture.deinit();

    const source = try makeNativeSource(id, version);
    defer a.free(source.bytes);
    defer a.free(source.sha256);
    const source_url = try addArtifact(&fixture, "native-source", source);
    defer a.free(source_url);

    try writeIndex(fixture.fixture.dir, id, version, &.{
        .{ .kind = "native-source", .target_json = "{\"abi_version\":1}", .url = source_url, .built = source },
    });

    const marker = try std.fs.path.join(a, &.{ fixture.fixture_root, "zig-ran" });
    defer a.free(marker);
    const zig = try writeFakeZig(a, marker, 0, true);
    defer a.free(zig);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    try testing.expectError(error.ResolveFailed, run(&fixture, &.{}, zig, &diagnostics));

    try expectNoBuild(marker);
    try testing.expectError(error.FileNotFound, fixture.project.dir.statFile(io, "nako.lock", .{}));
    try testing.expectError(error.FileNotFound, fixture.project.dir.statFile(io, ".nako/v1/environment.json", .{}));
    var rendered: std.Io.Writer.Allocating = .init(a);
    defer rendered.deinit();
    try diagnostics.render(&rendered.writer, fixture.project_root);
    try testing.expect(std.mem.indexOf(u8, rendered.written(), "native-source") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.written(), "explicit permission") != null);
}

test "ビルド失敗時は既存 lock と環境ポインタを変更せず staging も残さない" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const base = "@acme/base";
    var fixture = try Fixture.init(base);
    defer fixture.deinit();

    // 1. 既存の universal 環境を作る。
    const base_version = "1.0.0";
    const universal = try makeUniversal(base, base_version);
    defer a.free(universal.bytes);
    defer a.free(universal.sha256);
    const universal_url = try addArtifact(&fixture, "universal", universal);
    defer a.free(universal_url);
    try writeIndex(fixture.fixture.dir, base, base_version, &.{
        .{ .kind = "universal", .target_json = "null", .url = universal_url, .built = universal },
    });

    const marker = try std.fs.path.join(a, &.{ fixture.fixture_root, "zig-ran" });
    defer a.free(marker);
    const ok_zig = try writeFakeZig(a, marker, 0, true);
    defer a.free(ok_zig);

    var first_diagnostics = diag.List.init(a);
    defer first_diagnostics.deinit();
    var first = try run(&fixture, &.{}, ok_zig, &first_diagnostics);
    defer first.deinit();

    const lock_path = try std.fs.path.join(a, &.{ fixture.project_root, "nako.lock" });
    defer a.free(lock_path);
    const old_lock = try readFile(lock_path);
    defer a.free(old_lock);
    const pointer_path = try std.fs.path.join(a, &.{ fixture.project_root, ".nako/v1/environment.json" });
    defer a.free(pointer_path);
    const old_pointer = try readFile(pointer_path);
    defer a.free(old_pointer);

    // 2. 依存先を native-source へ変え、ビルドを失敗させる。
    try fixture.writeManifest(id);
    const source = try makeNativeSource(id, version);
    defer a.free(source.bytes);
    defer a.free(source.sha256);
    const source_url = try addArtifact(&fixture, "native-source", source);
    defer a.free(source_url);
    try writeIndex(fixture.fixture.dir, id, version, &.{
        .{ .kind = "native-source", .target_json = "{\"abi_version\":1}", .url = source_url, .built = source },
    });

    const fail_marker = try std.fs.path.join(a, &.{ fixture.fixture_root, "fail-zig-ran" });
    defer a.free(fail_marker);
    const fail_zig = try writeFakeZig(a, fail_marker, 7, false);
    defer a.free(fail_zig);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    try testing.expectError(error.BuildFailed, run(
        &fixture,
        &.{.{ .id = id, .sha256 = source.sha256 }},
        fail_zig,
        &diagnostics,
    ));

    const fail_ran = try readFile(fail_marker);
    defer a.free(fail_ran);
    try testing.expectEqualStrings("ran", fail_ran);

    const now_lock = try readFile(lock_path);
    defer a.free(now_lock);
    const now_pointer = try readFile(pointer_path);
    defer a.free(now_pointer);
    try testing.expectEqualSlices(u8, old_lock, now_lock);
    try testing.expectEqualSlices(u8, old_pointer, now_pointer);

    // 失敗した staging が残っていないこと。
    var v1 = try fixture.project.dir.openDir(io, ".nako/v1", .{ .iterate = true, .follow_symlinks = false });
    defer v1.close(io);
    var iterator = v1.iterate();
    while (try iterator.next(io)) |entry| {
        try testing.expect(!std.mem.startsWith(u8, entry.name, ".staging-"));
    }
}

test "#4 通常 CLI は GNU Linux の実 glibc を候補選択へ渡す" {
    if (comptime builtin.os.tag == .linux and builtin.abi == .gnu) {
        try glibcEqualSelectionTest();
    } else {
        return error.SkipZigTest;
    }
}

fn glibcEqualSelectionTest() !void {
    const host_version = std.mem.span(gnu_get_libc_version() orelse return error.SkipZigTest);
    const triple = try hostGnuTriple(a);
    defer a.free(triple);
    const above_version = try nextMinorVersion(a, host_version);
    defer a.free(above_version);

    var fixture = try Fixture.init(id);
    defer fixture.deinit();

    const universal = try makeUniversal(id, version);
    defer a.free(universal.bytes);
    defer a.free(universal.sha256);
    const equal = try makeNativePrebuiltAt(id, version, triple, host_version);
    defer a.free(equal.bytes);
    defer a.free(equal.sha256);
    const above = try makeNativePrebuiltAt(id, version, triple, above_version);
    defer a.free(above.bytes);
    defer a.free(above.sha256);

    const universal_url = try addArtifact(&fixture, "glibc-universal", universal);
    defer a.free(universal_url);
    const equal_url = try addArtifact(&fixture, "glibc-equal", equal);
    defer a.free(equal_url);
    const above_url = try addArtifact(&fixture, "glibc-above", above);
    defer a.free(above_url);

    // 下限がホストより上（一つ上）の候補を先に置いても、実ホスト版を渡さない
    // 既定経路では選ばず、下限がホストと同じ候補を選ぶ。
    const above_target = try std.fmt.allocPrint(a, "{{\"target_triple\":\"{s}\",\"abi_version\":1,\"glibc_min\":\"{s}\"}}", .{ triple, above_version });
    defer a.free(above_target);
    const equal_target = try std.fmt.allocPrint(a, "{{\"target_triple\":\"{s}\",\"abi_version\":1,\"glibc_min\":\"{s}\"}}", .{ triple, host_version });
    defer a.free(equal_target);

    try writeIndex(fixture.fixture.dir, id, version, &.{
        .{ .kind = "native-prebuilt", .target_json = above_target, .url = above_url, .built = above },
        .{ .kind = "native-prebuilt", .target_json = equal_target, .url = equal_url, .built = equal },
        .{ .kind = "universal", .target_json = "null", .url = universal_url, .built = universal },
    });

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try runHost(&fixture, &diagnostics);
    defer report.deinit();

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqual(types.Kind.@"native-prebuilt", loaded.packages[0].kind);
    try testing.expectEqualStrings(equal.sha256, loaded.packages[0].sha256);
}

test "#4 ホスト glibc が下限より一つ下なら prebuilt を選ばず universal へ戻る" {
    if (comptime builtin.os.tag == .linux and builtin.abi == .gnu) {
        try glibcBelowSelectionTest();
    } else {
        return error.SkipZigTest;
    }
}

fn glibcBelowSelectionTest() !void {
    const host_version = std.mem.span(gnu_get_libc_version() orelse return error.SkipZigTest);
    const triple = try hostGnuTriple(a);
    defer a.free(triple);
    const above_version = try nextMinorVersion(a, host_version);
    defer a.free(above_version);

    var fixture = try Fixture.init(id);
    defer fixture.deinit();

    const universal = try makeUniversal(id, version);
    defer a.free(universal.bytes);
    defer a.free(universal.sha256);
    const above = try makeNativePrebuiltAt(id, version, triple, above_version);
    defer a.free(above.bytes);
    defer a.free(above.sha256);

    const universal_url = try addArtifact(&fixture, "glibc2-universal", universal);
    defer a.free(universal_url);
    const above_url = try addArtifact(&fixture, "glibc2-above", above);
    defer a.free(above_url);
    const above_target = try std.fmt.allocPrint(a, "{{\"target_triple\":\"{s}\",\"abi_version\":1,\"glibc_min\":\"{s}\"}}", .{ triple, above_version });
    defer a.free(above_target);

    try writeIndex(fixture.fixture.dir, id, version, &.{
        .{ .kind = "native-prebuilt", .target_json = above_target, .url = above_url, .built = above },
        .{ .kind = "universal", .target_json = "null", .url = universal_url, .built = universal },
    });

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try runHost(&fixture, &diagnostics);
    defer report.deinit();

    var loaded = (try client.loadEnvironment(a, io, fixture.project.dir)).?;
    defer loaded.deinit();
    try testing.expectEqual(types.Kind.universal, loaded.packages[0].kind);
}
