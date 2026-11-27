//! P04 クロスアーティファクト検証の適合性試験（X-01〜04・15・16）。
//!
//! 実 ZIP ではなく `METADATA.toml` と `COMMANDS.json` の合成入力を使う。
//! P03 の `v1_archive` と統合した後も同じ規則を実 ZIP へ適用できるよう、
//! ここでは文書だけを組み立てて `v1_cross` の公開 API に渡す。

const std = @import("std");
const toml = @import("toml.zig");
const v1_cross = @import("v1_cross.zig");

const Allocator = std.mem.Allocator;

const Artifact = struct {
    metadata: toml.Document,
    commands: std.json.Parsed(std.json.Value),

    fn deinit(self: *Artifact) void {
        self.metadata.deinit();
        self.commands.deinit();
    }
};

const Kind = enum {
    universal,
    native_source,
    native_prebuilt,
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
};

fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .universal => "universal",
        .native_source => "native-source",
        .native_prebuilt => "native-prebuilt",
    };
}

fn makeArtifact(allocator: Allocator, kind: Kind, options: Options) !Artifact {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const metadata_source = try buildMetadata(arena, kind, options);
    const commands_source = try buildCommands(arena, options);
    return parseArtifact(allocator, metadata_source, commands_source);
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

    // 中括弧の対応を読み間違えないよう、値の後は文字列連結で閉じる。
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

fn parseArtifact(allocator: Allocator, metadata_source: []const u8, commands_source: []const u8) !Artifact {
    var metadata = switch (try toml.parse(allocator, metadata_source)) {
        .ok => |document| document,
        .err => return error.TestUnexpectedResult,
    };
    errdefer metadata.deinit();

    const commands = std.json.parseFromSlice(std.json.Value, allocator, commands_source, .{}) catch
        return error.TestUnexpectedResult;
    return .{
        .metadata = metadata,
        .commands = commands,
    };
}

fn documentsFor(allocator: Allocator, artifacts: []const *const Artifact) ![]v1_cross.Documents {
    const documents = try allocator.alloc(v1_cross.Documents, artifacts.len);
    for (artifacts, 0..) |artifact, index| {
        documents[index] = .{
            .metadata = &artifact.metadata,
            .commands = &artifact.commands.value,
        };
    }
    return documents;
}

fn checkArtifacts(allocator: Allocator, artifacts: []const *const Artifact) !v1_cross.Report {
    const documents = try documentsFor(allocator, artifacts);
    defer allocator.free(documents);
    return v1_cross.checkDocuments(allocator, documents);
}

fn expectCrossFailure(allocator: Allocator, artifacts: []const *const Artifact) !void {
    const documents = try documentsFor(allocator, artifacts);
    defer allocator.free(documents);
    try std.testing.expectError(
        error.CrossValidationFailed,
        v1_cross.validateDocuments(allocator, documents),
    );
}

fn hasDiagnostic(report: *const v1_cross.Report, code: v1_cross.Code, field: []const u8) bool {
    for (report.diagnostics) |diagnostic| {
        if (diagnostic.code == code and std.mem.eql(u8, diagnostic.field, field)) return true;
    }
    return false;
}

test "X-01 universal と native-prebuilt の共通項目が一致すれば受理する" {
    const allocator = std.testing.allocator;
    var universal = try makeArtifact(allocator, .universal, .{});
    defer universal.deinit();
    var prebuilt = try makeArtifact(allocator, .native_prebuilt, .{});
    defer prebuilt.deinit();

    const artifacts = [_]*const Artifact{ &universal, &prebuilt };
    var report = try checkArtifacts(allocator, &artifacts);
    defer report.deinit();

    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 0), report.global_commands.len);
}

test "X-02 共通 dependencies の req が異なれば拒否する" {
    const allocator = std.testing.allocator;
    var universal = try makeArtifact(allocator, .universal, .{});
    defer universal.deinit();
    var prebuilt = try makeArtifact(allocator, .native_prebuilt, .{ .dependency_req = "^2.0.0" });
    defer prebuilt.deinit();

    const artifacts = [_]*const Artifact{ &universal, &prebuilt };
    try expectCrossFailure(allocator, &artifacts);

    var report = try checkArtifacts(allocator, &artifacts);
    defer report.deinit();
    try std.testing.expect(hasDiagnostic(&report, .common_field_mismatch, "dependencies"));
}

test "X-03 アーティファクト固有の exports 追加は共通 exports 不一致として拒否する" {
    const allocator = std.testing.allocator;
    var universal = try makeArtifact(allocator, .universal, .{});
    defer universal.deinit();
    // P 内では METADATA と COMMANDS がそろっているが、共通 exports は U と異なる。
    var prebuilt = try makeArtifact(allocator, .native_prebuilt, .{ .extra_export = true });
    defer prebuilt.deinit();

    const artifacts = [_]*const Artifact{ &universal, &prebuilt };
    try expectCrossFailure(allocator, &artifacts);

    var report = try checkArtifacts(allocator, &artifacts);
    defer report.deinit();
    try std.testing.expect(hasDiagnostic(&report, .common_field_mismatch, "exports"));
}

test "X-04 kind・runtimes・triple・ABI が同じアーティファクトの重複を拒否する" {
    const allocator = std.testing.allocator;
    var first = try makeArtifact(allocator, .native_prebuilt, .{});
    defer first.deinit();
    var second = try makeArtifact(allocator, .native_prebuilt, .{});
    defer second.deinit();

    const artifacts = [_]*const Artifact{ &first, &second };
    try expectCrossFailure(allocator, &artifacts);

    var report = try checkArtifacts(allocator, &artifacts);
    defer report.deinit();
    try std.testing.expect(hasDiagnostic(&report, .duplicate_artifact, "artifact(kind,runtimes,target_triple,abi_version)"));
}

test "X-04 runtimes の並びが違っても集合として同じなら重複とみなす" {
    const allocator = std.testing.allocator;
    var first = try makeArtifact(allocator, .universal, .{});
    defer first.deinit();
    var second = try makeArtifact(allocator, .universal, .{
        .runtimes = "[\"wnako\", \"lnako\", \"cnako\"]",
    });
    defer second.deinit();

    const artifacts = [_]*const Artifact{ &first, &second };
    var report = try checkArtifacts(allocator, &artifacts);
    defer report.deinit();
    try std.testing.expect(hasDiagnostic(&report, .duplicate_artifact, "artifact(kind,runtimes,target_triple,abi_version)"));
}

test "X-04 native-source も runtimes と ABI が同じなら重複とみなす" {
    const allocator = std.testing.allocator;
    var first = try makeArtifact(allocator, .native_source, .{});
    defer first.deinit();
    var second = try makeArtifact(allocator, .native_source, .{});
    defer second.deinit();

    const artifacts = [_]*const Artifact{ &first, &second };
    var report = try checkArtifacts(allocator, &artifacts);
    defer report.deinit();
    try std.testing.expect(hasDiagnostic(&report, .duplicate_artifact, "artifact(kind,runtimes,target_triple,abi_version)"));
}

test "X-15 capabilities の順序・binding 省略・依存既定値と集合順を正規化して受理する" {
    const allocator = std.testing.allocator;
    var universal = try makeArtifact(allocator, .universal, .{
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
    defer universal.deinit();

    var prebuilt = try makeArtifact(allocator, .native_prebuilt, .{
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
    defer prebuilt.deinit();

    const artifacts = [_]*const Artifact{ &universal, &prebuilt };
    var report = try checkArtifacts(allocator, &artifacts);
    defer report.deinit();

    try std.testing.expect(report.ok());
}

test "X-16 両方の global 入口から定数を除いた命令名を比較して受理する" {
    const allocator = std.testing.allocator;
    var universal = try makeArtifact(allocator, .universal, .{
        .metadata_binding = "global",
        .commands_binding = "global",
        .global_command = "公開取得",
    });
    defer universal.deinit();
    var prebuilt = try makeArtifact(allocator, .native_prebuilt, .{
        .metadata_binding = "global",
        .commands_binding = "global",
        .global_command = "公開取得",
        // 定数のみ片方に列挙する。global_commands には含めない。
        .constants = "[\"設定値\"]",
    });
    defer prebuilt.deinit();

    const artifacts = [_]*const Artifact{ &universal, &prebuilt };
    var report = try checkArtifacts(allocator, &artifacts);
    defer report.deinit();

    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.global_commands.len);
    try std.testing.expectEqualStrings("公開取得", report.global_commands[0]);
}

test "X-16 global 命令名が片方だけ異なれば拒否する" {
    const allocator = std.testing.allocator;
    var universal = try makeArtifact(allocator, .universal, .{
        .metadata_binding = "global",
        .commands_binding = "global",
        .global_command = "公開取得",
    });
    defer universal.deinit();
    var prebuilt = try makeArtifact(allocator, .native_prebuilt, .{
        .metadata_binding = "global",
        .commands_binding = "global",
        .global_command = "別の取得",
    });
    defer prebuilt.deinit();

    const artifacts = [_]*const Artifact{ &universal, &prebuilt };
    try expectCrossFailure(allocator, &artifacts);

    var report = try checkArtifacts(allocator, &artifacts);
    defer report.deinit();
    try std.testing.expect(hasDiagnostic(
        &report,
        .global_commands_mismatch,
        "COMMANDS.global_commands",
    ));
}

test "X-01 v1_archive.Verified 形のスライスを validate で受理する" {
    const allocator = std.testing.allocator;
    var universal = try makeArtifact(allocator, .universal, .{});
    defer universal.deinit();
    var prebuilt = try makeArtifact(allocator, .native_prebuilt, .{});
    defer prebuilt.deinit();

    // P03 の Verified が公開する metadata.root（toml.Document）と
    // commands.value（std.json.Value）と同じ形。
    const Verified = struct {
        metadata: struct { root: toml.Document },
        commands: struct { value: std.json.Value },
    };
    const verified = [_]Verified{
        .{
            .metadata = .{ .root = universal.metadata },
            .commands = .{ .value = universal.commands.value },
        },
        .{
            .metadata = .{ .root = prebuilt.metadata },
            .commands = .{ .value = prebuilt.commands.value },
        },
    };

    try v1_cross.validate(allocator, &verified);
}

test "X-01 P03 の Parsed 形（metadata.document / commands.document）も受理する" {
    const allocator = std.testing.allocator;
    var universal = try makeArtifact(allocator, .universal, .{});
    defer universal.deinit();
    var prebuilt = try makeArtifact(allocator, .native_prebuilt, .{});
    defer prebuilt.deinit();

    // v1_metadata.Parsed / v1_metadata_commands.Parsed を包む形。
    const Verified = struct {
        metadata: struct { document: toml.Document },
        commands: struct { document: std.json.Parsed(std.json.Value) },
    };
    const verified = [_]Verified{
        .{
            .metadata = .{ .document = universal.metadata },
            .commands = .{ .document = universal.commands },
        },
        .{
            .metadata = .{ .document = prebuilt.metadata },
            .commands = .{ .document = prebuilt.commands },
        },
    };

    try v1_cross.validate(allocator, &verified);
}

test "cross 空のアーティファクト集合と単独アーティファクトを区別する" {
    const allocator = std.testing.allocator;

    var empty_report = try v1_cross.checkDocuments(allocator, &.{});
    defer empty_report.deinit();
    try std.testing.expect(hasDiagnostic(&empty_report, .empty_artifact_set, ""));

    var universal = try makeArtifact(allocator, .universal, .{});
    defer universal.deinit();
    const artifacts = [_]*const Artifact{&universal};
    var report = try checkArtifacts(allocator, &artifacts);
    defer report.deinit();
    try std.testing.expect(report.ok());
}
