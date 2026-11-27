//! P04 の実 `.npkg` クロス検証（X-01〜04・15・16）。
//!
//! P03 の `v1_zip.build` で Canonical ZIP を組み、`v1_archive.verify` が
//! 返した `archive.Verified` をそのまま `v1_cross` へ渡す。`FILES.json` の
//! 長さ・SHA-256 と ZIP の CRC は `verify` が実バイト列と照合するため、
//! ここでは各アーカイブが個別検証を通ることも毎回確かめる。
//!
//! このファイルは P03 の `v1_archive.zig` と同時にだけコンパイルできる。
//! P03 の `npkg_commands_gen` が `../frontend` を使うため、モジュールルートを
//! `src` にする `zig build test` から実行する。P04 単独の合成入力試験は
//! `v1_cross_test.zig` が担う。

const std = @import("std");
const archive = @import("v1_archive.zig");
const zip = @import("v1_zip.zig");
const mfiles = @import("v1_metadata_files.zig");
const v1_cross = @import("v1_cross.zig");

const Allocator = std.mem.Allocator;

const Kind = enum {
    universal,
    native_source,
    native_prebuilt,
};

const Payload = struct {
    path: []const u8,
    data: []const u8,
};

const Fixture = struct {
    metadata: []const u8,
    commands: []const u8,
    payload: []const Payload,
};

const Options = struct {
    capabilities: []const u8 = "[\"pure-nako\"]",
    /// null は kind ごとの既定の runtimes。
    runtimes: ?[]const u8 = null,
    /// null は METADATA の binding 省略（既定は scoped）。
    metadata_binding: ?[]const u8 = "scoped",
    commands_binding: []const u8 = "scoped",
    extra_export: bool = false,
    dependency_req: []const u8 = "^1.0.0",
    /// null は runtimes 省略（全ランタイム共通）。
    dependency_runtimes: ?[]const u8 = null,
    /// false は features/default_features/optional を省略する。
    dependency_defaults: bool = true,
    /// null は allow_global_commands を省略する。
    dependency_allow_global: ?bool = null,
    extra_dependency: bool = false,
    reverse_dependencies: bool = false,
    global_command: ?[]const u8 = null,
    constants: []const u8 = "[]",
    engines: []const u8 = "",
    features: []const u8 = "",
    /// native-prebuilt のライブラリ内容。X-04 でバイト列だけ変える。
    library_data: []const u8 = "native library fixture\n",
};

fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .universal => "universal",
        .native_source => "native-source",
        .native_prebuilt => "native-prebuilt",
    };
}

fn makeFixture(arena: Allocator, kind: Kind, options: Options) !Fixture {
    const metadata = try buildMetadata(arena, kind, options);
    const commands = try buildCommands(arena, options);

    const payload_count: usize = if (kind == .native_prebuilt) 2 else 1;
    const payload = try arena.alloc(Payload, payload_count);
    payload[0] = .{ .path = "src/main.nako3", .data = "# fixture\n" };
    if (kind == .native_prebuilt) {
        payload[1] = .{ .path = "native/libdemo.so", .data = options.library_data };
    }

    return .{
        .metadata = metadata,
        .commands = commands,
        .payload = payload,
    };
}

fn buildMetadata(arena: Allocator, kind: Kind, options: Options) ![]const u8 {
    const runtimes = if (options.runtimes) |text| text else switch (kind) {
        .universal => "[\"lnako\", \"cnako\", \"wnako\"]",
        .native_source, .native_prebuilt => "[\"lnako\"]",
    };
    const native = switch (kind) {
        .universal => "",
        .native_source =>
        \\[artifact.native]
        \\abi_version = 1
        ,
        .native_prebuilt =>
        \\[artifact.native]
        \\target_triple = "x86_64-linux-gnu"
        \\abi_version = 1
        \\glibc_min = "2.31"
        \\library_path = "native/libdemo.so"
        ,
    };
    const binding = if (options.metadata_binding) |text|
        try std.fmt.allocPrint(arena, ", binding = \"{s}\"", .{text})
    else
        "";
    const extra_export = if (options.extra_export)
        " \"./extra\" = { entry = \"src/main.nako3\", binding = \"scoped\" }"
    else
        "";
    const exports_section = try std.fmt.allocPrint(
        arena,
        "[exports]\n\".\" = {{ entry = \"src/main.nako3\"{s} }}\n{s}\n",
        .{ binding, extra_export },
    );

    const base_dependency = try buildDependency(arena, "@example/base", options);
    const extra_dependency = if (options.extra_dependency)
        try buildDependency(arena, "@example/extra", .{
            .dependency_req = "^1.0.0",
            .dependency_runtimes = options.dependency_runtimes,
            .dependency_defaults = options.dependency_defaults,
            .dependency_allow_global = options.dependency_allow_global,
        })
    else
        "";
    const dependencies = if (options.reverse_dependencies)
        try std.mem.concat(arena, u8, &.{ extra_dependency, base_dependency })
    else
        try std.mem.concat(arena, u8, &.{ base_dependency, extra_dependency });

    return std.fmt.allocPrint(
        arena,
        "schema_version = 1\n\n[package]\nid = \"@example/demo\"\nversion = \"1.0.0\"\n" ++
            "license = \"MIT\"\ncapabilities = {s}\n\n[artifact]\nkind = \"{s}\"\n" ++
            "runtimes = {s}\n\n{s}\n{s}\n{s}\n{s}\n{s}\n",
        .{
            options.capabilities,
            kindName(kind),
            runtimes,
            native,
            options.engines,
            exports_section,
            options.features,
            dependencies,
        },
    );
}

fn buildDependency(arena: Allocator, id: []const u8, options: Options) ![]const u8 {
    const defaults = if (options.dependency_defaults)
        "features = []\ndefault_features = true\noptional = false\n"
    else
        "";
    const runtimes = if (options.dependency_runtimes) |text|
        try std.fmt.allocPrint(arena, "runtimes = {s}\n", .{text})
    else
        "";
    const allow_global = if (options.dependency_allow_global) |value|
        try std.fmt.allocPrint(arena, "allow_global_commands = {s}\n", .{if (value) "true" else "false"})
    else
        "";
    return std.fmt.allocPrint(
        arena,
        "[[dependencies]]\nid = \"{s}\"\nreq = \"{s}\"\n{s}{s}{s}\n",
        .{ id, options.dependency_req, defaults, runtimes, allow_global },
    );
}

fn buildCommands(arena: Allocator, options: Options) ![]const u8 {
    const command = if (options.global_command) |name|
        try std.fmt.allocPrint(arena, "{{\"name\":\"{s}\",\"kind\":\"function\",\"args\":[]}}", .{name})
    else
        "";
    const flag = if (options.global_command != null) "true" else "false";

    const head = try std.fmt.allocPrint(
        arena,
        "{{\"schema_version\":1,\"exports_global_commands\":{s},\"exports\":{{\".\":{{\"binding\":\"{s}\",\"commands\":[{s}],\"constants\":{s}",
        .{ flag, options.commands_binding, command, options.constants },
    );
    const tail = if (options.extra_export)
        ",\"./extra\":{\"binding\":\"scoped\",\"commands\":[],\"constants\":[]}}}"
    else
        "}}";
    return std.mem.concat(arena, u8, &.{ head, "}", tail });
}

/// `FILES.json` のハッシュを実バイト列から計算し、Canonical ZIP を組み立てる。
fn buildZipBytes(allocator: Allocator, fixture: Fixture) ![]u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    var files: std.ArrayList(mfiles.Entry) = .empty;
    try files.append(arena, mfiles.entryFor(archive.metadata_path, fixture.metadata));
    try files.append(arena, mfiles.entryFor(archive.commands_path, fixture.commands));
    for (fixture.payload) |payload| {
        try files.append(arena, mfiles.entryFor(payload.path, payload.data));
    }
    const files_bytes = try mfiles.emit(arena, files.items);

    var inputs: std.ArrayList(zip.SourceEntry) = .empty;
    try inputs.append(arena, .{ .path = archive.metadata_path, .data = fixture.metadata });
    try inputs.append(arena, .{ .path = archive.commands_path, .data = fixture.commands });
    try inputs.append(arena, .{ .path = mfiles.files_path, .data = files_bytes });
    for (fixture.payload) |payload| {
        try inputs.append(arena, .{ .path = payload.path, .data = payload.data });
    }
    return zip.build(allocator, inputs.items, .{});
}

/// `Verified` と、その検証元 ZIP バイト列を一緒に保持する。
/// P03 の `v1_zip.open` は現状エントリ名を入力バイト列への参照として持つため、
/// 入力バイト列を `Verified` より先に解放しない。
const BuiltPair = struct {
    allocator: Allocator,
    bytes: [2][]u8,
    verified: [2]archive.Verified,

    fn deinit(self: *BuiltPair) void {
        for (&self.verified) |*verified| verified.deinit();
        for (self.bytes) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }
};

fn buildPair(allocator: Allocator, first: Fixture, second: Fixture) !BuiltPair {
    var result: BuiltPair = undefined;
    result.allocator = allocator;

    result.bytes[0] = try buildZipBytes(allocator, first);
    errdefer allocator.free(result.bytes[0]);
    result.verified[0] = try archive.verify(allocator, result.bytes[0]);
    errdefer result.verified[0].deinit();

    result.bytes[1] = try buildZipBytes(allocator, second);
    errdefer allocator.free(result.bytes[1]);
    result.verified[1] = try archive.verify(allocator, result.bytes[1]);
    return result;
}

fn expectVerifiedFiles(verified: *const archive.Verified, payload: []const Payload) !void {
    // FILES.json 自身を除く索引と通常ファイルが 1 対 1 で対応する。
    try std.testing.expectEqual(payload.len + 2, verified.fileEntries().len);
    try std.testing.expectEqual(payload.len + 3, verified.entryCount());

    // verify が照合済みの値を、テスト側でも実バイト列から再計算して確かめる。
    for (verified.fileEntries()) |entry| {
        const data = verified.entryBytes(entry.path) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(entry.size, data.len);
        const digest = mfiles.hash(data);
        try std.testing.expectEqualSlices(u8, &entry.sha256, &digest);
    }
    for (payload) |item| {
        const data = verified.entryBytes(item.path) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(u8, item.data, data);
    }
}

fn hasDiagnostic(report: *const v1_cross.Report, code: v1_cross.Code, field: []const u8) bool {
    for (report.diagnostics) |diagnostic| {
        if (diagnostic.code == code and std.mem.eql(u8, diagnostic.field, field)) return true;
    }
    return false;
}

fn expectRejected(
    allocator: Allocator,
    verified: []const archive.Verified,
    code: v1_cross.Code,
    field: []const u8,
) !void {
    try std.testing.expectError(error.CrossValidationFailed, v1_cross.validate(allocator, verified));
    var report = try v1_cross.check(allocator, verified);
    defer report.deinit();
    try std.testing.expect(!report.ok());
    try std.testing.expect(hasDiagnostic(&report, code, field));
}

test "X-01 実ZIPのuniversalとnative-prebuiltを共通metadataで受理する" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const universal_fixture = try makeFixture(a, .universal, .{});
    const prebuilt_fixture = try makeFixture(a, .native_prebuilt, .{});
    var pair = try buildPair(allocator, universal_fixture, prebuilt_fixture);
    defer pair.deinit();

    try expectVerifiedFiles(&pair.verified[0], universal_fixture.payload);
    try expectVerifiedFiles(&pair.verified[1], prebuilt_fixture.payload);
    try v1_cross.validate(allocator, pair.verified[0..]);
}

test "X-02 実ZIPの共通dependenciesのreq不一致を拒否する" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const universal_fixture = try makeFixture(a, .universal, .{});
    const prebuilt_fixture = try makeFixture(a, .native_prebuilt, .{ .dependency_req = "^2.0.0" });
    var pair = try buildPair(allocator, universal_fixture, prebuilt_fixture);
    defer pair.deinit();

    try expectVerifiedFiles(&pair.verified[0], universal_fixture.payload);
    try expectVerifiedFiles(&pair.verified[1], prebuilt_fixture.payload);
    try expectRejected(allocator, pair.verified[0..], .common_field_mismatch, "dependencies");
}

test "X-03 実ZIPのアーティファクト固有exports追加を共通exports不一致として拒否する" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const universal_fixture = try makeFixture(a, .universal, .{});
    // P 内の METADATA と COMMANDS はそろっているが、共通 exports は U と異なる。
    const prebuilt_fixture = try makeFixture(a, .native_prebuilt, .{ .extra_export = true });
    var pair = try buildPair(allocator, universal_fixture, prebuilt_fixture);
    defer pair.deinit();

    try expectVerifiedFiles(&pair.verified[0], universal_fixture.payload);
    try expectVerifiedFiles(&pair.verified[1], prebuilt_fixture.payload);
    try expectRejected(allocator, pair.verified[0..], .common_field_mismatch, "exports");
}

test "X-04 実ZIPでkind・runtimes・triple・ABIが同じアーティファクトを拒否する" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const first_fixture = try makeFixture(a, .native_prebuilt, .{});
    // P2 は正しい ZIP だが、ライブラリの実バイト列だけが異なる。
    const second_fixture = try makeFixture(a, .native_prebuilt, .{
        .library_data = "different native library bytes\n",
    });
    var pair = try buildPair(allocator, first_fixture, second_fixture);
    defer pair.deinit();

    try expectVerifiedFiles(&pair.verified[0], first_fixture.payload);
    try expectVerifiedFiles(&pair.verified[1], second_fixture.payload);

    const first_library = pair.verified[0].entryBytes("native/libdemo.so") orelse return error.TestUnexpectedResult;
    const second_library = pair.verified[1].entryBytes("native/libdemo.so") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.eql(u8, first_library, second_library));

    try expectRejected(
        allocator,
        pair.verified[0..],
        .duplicate_artifact,
        "artifact(kind,runtimes,target_triple,abi_version)",
    );
}

test "X-15 実ZIPで既定値・集合順を正規化して受理する" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const universal_fixture = try makeFixture(a, .universal, .{
        .capabilities = "[\"native\", \"net\"]",
        .metadata_binding = null,
        .dependency_defaults = false,
        .extra_dependency = true,
        .engines =
        \\[engines]
        \\lnako = "^0.2.0"
        \\cnako = "^0.2.0"
        \\
        ,
        .features =
        \\[features]
        \\default = ["tls", "http3"]
        \\tls = []
        \\http3 = ["tls"]
        \\
        ,
    });
    const prebuilt_fixture = try makeFixture(a, .native_prebuilt, .{
        .capabilities = "[\"net\", \"native\"]",
        .metadata_binding = "scoped",
        .dependency_runtimes = "[\"wnako\", \"cnako\", \"lnako\"]",
        .dependency_allow_global = false,
        .extra_dependency = true,
        .reverse_dependencies = true,
        .engines =
        \\[engines]
        \\cnako = "^0.2.0"
        \\lnako = "^0.2.0"
        \\
        ,
        .features =
        \\[features]
        \\http3 = ["tls"]
        \\default = ["http3", "tls"]
        \\tls = []
        \\
        ,
    });
    var pair = try buildPair(allocator, universal_fixture, prebuilt_fixture);
    defer pair.deinit();

    try expectVerifiedFiles(&pair.verified[0], universal_fixture.payload);
    try expectVerifiedFiles(&pair.verified[1], prebuilt_fixture.payload);

    var report = try v1_cross.check(allocator, pair.verified[0..]);
    defer report.deinit();
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 0), report.global_commands.len);
}

test "X-16 実ZIPでglobal命令名を比較し定数差を無視して受理する" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const universal_fixture = try makeFixture(a, .universal, .{
        .metadata_binding = "global",
        .commands_binding = "global",
        .global_command = "公開取得",
    });
    const prebuilt_fixture = try makeFixture(a, .native_prebuilt, .{
        .metadata_binding = "global",
        .commands_binding = "global",
        .global_command = "公開取得",
        // 定数のみ片方に列挙する。global_commands には含めない。
        .constants = "[\"設定値\"]",
    });
    var pair = try buildPair(allocator, universal_fixture, prebuilt_fixture);
    defer pair.deinit();

    try expectVerifiedFiles(&pair.verified[0], universal_fixture.payload);
    try expectVerifiedFiles(&pair.verified[1], prebuilt_fixture.payload);

    const prebuilt_export = pair.verified[1].commands_model.findExport(".") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), prebuilt_export.constants.len);

    var report = try v1_cross.check(allocator, pair.verified[0..]);
    defer report.deinit();
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.global_commands.len);
    try std.testing.expectEqualStrings("公開取得", report.global_commands[0]);
}

test "X-16 実ZIPでglobal命令名が片方だけ異なる場合を拒否する" {
    const allocator = std.testing.allocator;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const universal_fixture = try makeFixture(a, .universal, .{
        .metadata_binding = "global",
        .commands_binding = "global",
        .global_command = "公開取得",
    });
    const prebuilt_fixture = try makeFixture(a, .native_prebuilt, .{
        .metadata_binding = "global",
        .commands_binding = "global",
        .global_command = "別の取得",
    });
    var pair = try buildPair(allocator, universal_fixture, prebuilt_fixture);
    defer pair.deinit();

    try expectVerifiedFiles(&pair.verified[0], universal_fixture.payload);
    try expectVerifiedFiles(&pair.verified[1], prebuilt_fixture.payload);
    try expectRejected(allocator, pair.verified[0..], .global_commands_mismatch, "COMMANDS.global_commands");
}
