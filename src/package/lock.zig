const std = @import("std");
const resolver = @import("resolver.zig");
const semver = @import("semver.zig");
const diag = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;

/// `nako.lock` schema version。`SCHEMA_VERSIONS.md` §4 と対応する。
pub const lock_schema_version: u32 = 1;
/// 依存 resolver algorithm version。resolver の決定論的結果が変わると bump する。
pub const resolver_version: u32 = 1;

/// lock が受理する artifact kind。未知 kind は `E007_UNKNOWN_ARTIFACT_KIND`。
pub const known_artifact_kinds = [_][]const u8{ "source", "native", "ESM" };
/// lock の profile が受理する runtime 名。
pub const known_profile_runtimes = [_][]const u8{ "lnako", "cnako", "any", "common" };
/// artifact record の `type` に許容する値。
pub const known_artifact_types = [_][]const u8{ "tar.gz", ".npkg", "raw", "npm-tarball" };
/// package entry の `implementation` に許容する値。
pub const known_implementations = [_][]const u8{ "source", "native", "ESM", "none" };

// ---------------------------------------------------------------------------
// データモデル
// ---------------------------------------------------------------------------

/// `input.target`。OS/CPU/ABI のみを固定し、runtime と compat-js は profile が持つ。
pub const Target = struct {
    os: []const u8,
    cpu: []const u8,
    abi: []const u8,

    pub fn eql(a: Target, b: Target) bool {
        return std.mem.eql(u8, a.os, b.os) and std.mem.eql(u8, a.cpu, b.cpu) and std.mem.eql(u8, a.abi, b.abi);
    }
};

/// lock が記録する profile 条件。`runtime`/`compat-js`/`optimize` は省略可能。
pub const ProfileRecord = struct {
    runtime: ?[]const u8 = null,
    os: []const u8,
    cpu: []const u8,
    abi: []const u8,
    compat_js: ?bool = null,
    optimize: ?[]const u8 = null,

    /// profile 選択時に ESM を許容するか。cnako か compat-js 有効時のみ。
    pub fn allowsEsm(self: ProfileRecord) bool {
        if (self.compat_js) |enabled| {
            if (enabled) return true;
        }
        if (self.runtime) |runtime| return std.mem.eql(u8, runtime, "cnako");
        return false;
    }

    /// runtime の既定は `any`。未指定・未知は呼出し側の診断対象。
    pub fn effectiveRuntime(self: ProfileRecord) []const u8 {
        return self.runtime orelse "any";
    }
};

pub const NamedProfile = struct {
    name: []const u8,
    record: ProfileRecord,
};

pub const SourceKind = enum { registry, static, git, http, path };

/// package の出典。`source`/`resolvedFrom` の両方に使う。
pub const Source = struct {
    kind: SourceKind,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    path: ?[]const u8 = null,
    mutable: ?bool = null,

    pub fn eql(a: Source, b: Source) bool {
        if (a.kind != b.kind) return false;
        return optEql(a.url, b.url) and optEql(a.hash, b.hash) and
            optEql(a.commit, b.commit) and optEql(a.path, b.path) and
            a.mutable == b.mutable;
    }
};

/// artifact record。`key` は map のキー、`kind` は record 自身の `kind`。
pub const Artifact = struct {
    key: []const u8,
    kind: []const u8,
    type: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    url: ?[]const u8 = null,

    pub fn isKnownKind(self: Artifact) bool {
        for (known_artifact_kinds) |kind| {
            if (std.mem.eql(u8, kind, self.kind)) return true;
        }
        return false;
    }
};

pub const PeerDependency = struct {
    name: []const u8,
    requirement: []const u8,
};

pub const NpmInstance = struct {
    key: []const u8,
    name: []const u8,
    version: []const u8,
    context: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    url: ?[]const u8 = null,
    peer_dependencies: []const PeerDependency = &.{},
};

pub const PackageEntry = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    source: ?Source = null,
    resolved_from: ?Source = null,
    dependencies: []const []const u8 = &.{},
    features: []const []const u8 = &.{},
    /// 選択された実装種別（`source`/`native`/`ESM`/`none`）。解決時に
    /// 共通 source 既定・native 明示選択のどちらが選ばれたかを記録する。
    implementation: ?[]const u8 = null,
    artifacts: []const Artifact = &.{},
    npm_instances: []const NpmInstance = &.{},

    pub fn artifact(self: *const PackageEntry, kind: []const u8) ?*const Artifact {
        for (self.artifacts) |*item| {
            if (std.mem.eql(u8, item.kind, kind)) return item;
        }
        return null;
    }

    pub fn hasKind(self: *const PackageEntry, kind: []const u8) bool {
        return self.artifact(kind) != null;
    }
};

pub const Input = struct {
    manifest_sha256: []const u8,
    profile: []const u8,
    features: []const []const u8 = &.{},
    target: Target,

    /// features を集合として比較する（順序・重複を無視）。
    pub fn sameFeatures(a: Input, b: Input) bool {
        if (uniqueCount(a.features) != uniqueCount(b.features)) return false;
        for (a.features) |item| {
            if (!containsString(b.features, item)) return false;
        }
        return true;
    }
};

/// 1 profile 分の解決済 package 集合。複数 profile を一つの lock に収録する。
pub const ProfilePackages = struct {
    profile: []const u8,
    packages: []const PackageEntry,
};

/// 解析・生成済みの lock 文書。全メモリは内蔵 arena が所有する。
pub const Lock = struct {
    arena: std.heap.ArenaAllocator,
    schema_version: u32 = lock_schema_version,
    resolver_version: u32 = resolver_version,
    input: Input,
    /// `input.profile` に対応する選択済み package グラフ。
    packages: []const PackageEntry = &.{},
    /// lock が収録する profile 条件。
    profiles: []const NamedProfile = &.{},
    /// profile ごとの解決済 package グラフ（複数 profile 収録時）。
    profile_packages: []const ProfilePackages = &.{},

    pub fn deinit(self: *Lock) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// 指定 profile の package グラフを返す。`profilePackages` に無い場合、
    /// `input.profile` と一致すれば選択済みの `packages` を返す。それ以外は null。
    pub fn packagesForProfile(self: *const Lock, profile: []const u8) ?[]const PackageEntry {
        for (self.profile_packages) |entry| {
            if (std.mem.eql(u8, entry.profile, profile)) return entry.packages;
        }
        if (std.mem.eql(u8, profile, self.input.profile)) return self.packages;
        return null;
    }

    pub fn profileRecord(self: *const Lock, name: []const u8) ?*const ProfileRecord {
        for (self.profiles) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return &entry.record;
        }
        return null;
    }

    pub fn packageById(self: *const Lock, id: []const u8) ?*const PackageEntry {
        for (self.packages) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// SHA-256 の各表記（SRI `sha256-<base64>=`、`sha256:<hex>`、生 `<hex>`）を
/// 32 バイトへ正規化する。解釈できない場合は false。
fn normalizeSha256(text: []const u8, out: *[32]u8) bool {
    if (text.len == 64) return hexToBytes(text, out);
    if (text.len == "sha256:".len + 64 and std.mem.startsWith(u8, text, "sha256:")) {
        return hexToBytes(text["sha256:".len..], out);
    }
    if (text.len == "sha256-".len + 44 and std.mem.startsWith(u8, text, "sha256-")) {
        const encoded = text["sha256-".len..];
        if (encoded[encoded.len - 1] != '=') return false;
        // 非 32 バイトへ復号される不正な Base64 を未初期化領域の比較に
        // 使わないよう、復号前にサイズを厳密に検査する。
        const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return false;
        if (size != 32) return false;
        std.base64.standard.Decoder.decode(out[0..], encoded) catch return false;
        return true;
    }
    return false;
}

fn hexToBytes(text: []const u8, out: *[32]u8) bool {
    _ = std.fmt.hexToBytes(out[0..], text) catch return false;
    return true;
}

/// 表現の違い（hex/base64）を正規化して SHA-256 を比較する。
fn sha256Eql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    var buf_a: [32]u8 = undefined;
    var buf_b: [32]u8 = undefined;
    if (normalizeSha256(a.?, &buf_a) and normalizeSha256(b.?, &buf_b)) {
        return std.mem.eql(u8, &buf_a, &buf_b);
    }
    return std.mem.eql(u8, a.?, b.?);
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn uniqueCount(items: []const []const u8) usize {
    var count: usize = 0;
    for (items, 0..) |item, index| {
        var seen = false;
        for (items[0..index]) |previous| {
            if (std.mem.eql(u8, previous, item)) {
                seen = true;
                break;
            }
        }
        if (!seen) count += 1;
    }
    return count;
}

const stringLessThan = struct {
    fn lt(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
}.lt;

const packageLessThan = struct {
    fn lt(_: void, a: PackageEntry, b: PackageEntry) bool {
        return std.mem.order(u8, a.id, b.id) == .lt;
    }
}.lt;

const profilePackageLessThan = struct {
    fn lt(_: void, a: ProfilePackages, b: ProfilePackages) bool {
        return std.mem.order(u8, a.profile, b.profile) == .lt;
    }
}.lt;

const namedProfileLessThan = struct {
    fn lt(_: void, a: NamedProfile, b: NamedProfile) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
}.lt;

// ---------------------------------------------------------------------------
// 決定的シリアライズ
// ---------------------------------------------------------------------------

fn writeIndent(writer: *std.Io.Writer, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) try writer.writeAll("  ");
}

fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

fn writeInlineStrings(writer: *std.Io.Writer, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        try writeString(writer, item);
    }
    try writer.writeByte(']');
}

fn writeTarget(writer: *std.Io.Writer, target: Target) !void {
    try writer.writeAll("{ \"os\": ");
    try writeString(writer, target.os);
    try writer.writeAll(", \"cpu\": ");
    try writeString(writer, target.cpu);
    try writer.writeAll(", \"abi\": ");
    try writeString(writer, target.abi);
    try writer.writeAll(" }");
}

fn writeProfile(writer: *std.Io.Writer, record: ProfileRecord) !void {
    try writer.writeAll("{ ");
    var first = true;
    if (record.runtime) |runtime| {
        try writer.writeAll("\"runtime\": ");
        try writeString(writer, runtime);
        first = false;
    }
    const fields = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "os", .value = record.os },
        .{ .name = "cpu", .value = record.cpu },
        .{ .name = "abi", .value = record.abi },
    };
    for (fields) |field| {
        if (!first) try writer.writeAll(", ");
        try writer.writeAll("\"");
        try writer.writeAll(field.name);
        try writer.writeAll("\": ");
        try writeString(writer, field.value);
        first = false;
    }
    if (record.compat_js) |compat_js| {
        if (!first) try writer.writeAll(", ");
        try writer.writeAll("\"compat-js\": ");
        try writer.writeAll(if (compat_js) "true" else "false");
        first = false;
    }
    if (record.optimize) |optimize| {
        if (!first) try writer.writeAll(", ");
        try writer.writeAll("\"optimize\": ");
        try writeString(writer, optimize);
    }
    try writer.writeAll(" }");
}

fn writeSource(writer: *std.Io.Writer, source: Source) !void {
    try writer.writeAll("{ \"type\": ");
    try writeString(writer, @tagName(source.kind));
    switch (source.kind) {
        .registry, .static => {
            try writer.writeAll(", \"url\": ");
            try writeString(writer, source.url orelse "");
        },
        .git => {
            try writer.writeAll(", \"url\": ");
            try writeString(writer, source.url orelse "");
            try writer.writeAll(", \"commit\": ");
            try writeString(writer, source.commit orelse "");
            if (source.path) |path| {
                try writer.writeAll(", \"path\": ");
                try writeString(writer, path);
            }
        },
        .http => {
            try writer.writeAll(", \"url\": ");
            try writeString(writer, source.url orelse "");
            try writer.writeAll(", \"hash\": ");
            try writeString(writer, source.hash orelse "");
        },
        .path => {
            try writer.writeAll(", \"path\": ");
            try writeString(writer, source.path orelse "");
            if (source.mutable) |mutable| {
                try writer.writeAll(", \"mutable\": ");
                try writer.writeAll(if (mutable) "true" else "false");
            }
        },
    }
    try writer.writeAll(" }");
}

fn writeArtifact(writer: *std.Io.Writer, level: usize, artifact: Artifact) !void {
    try writer.writeAll("{\n");
    try writeIndent(writer, level + 1);
    try writer.writeAll("\"kind\": ");
    try writeString(writer, artifact.kind);
    if (artifact.type) |artifact_type| {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"type\": ");
        try writeString(writer, artifact_type);
    }
    if (artifact.sha256) |sha256| {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"sha256\": ");
        try writeString(writer, sha256);
    }
    if (artifact.url) |url| {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"url\": ");
        try writeString(writer, url);
    }
    try writer.writeByte('\n');
    try writeIndent(writer, level);
    try writer.writeByte('}');
}

fn writeNpmInstance(writer: *std.Io.Writer, level: usize, instance: NpmInstance) !void {
    try writer.writeAll("{\n");
    try writeIndent(writer, level + 1);
    try writer.writeAll("\"name\": ");
    try writeString(writer, instance.name);
    try writer.writeAll(",\n");
    try writeIndent(writer, level + 1);
    try writer.writeAll("\"version\": ");
    try writeString(writer, instance.version);
    if (instance.context) |context| {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"context\": ");
        try writeString(writer, context);
    }
    if (instance.sha256) |sha256| {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"sha256\": ");
        try writeString(writer, sha256);
    }
    if (instance.url) |url| {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"url\": ");
        try writeString(writer, url);
    }
    if (instance.peer_dependencies.len > 0) {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"peerDependencies\": {\n");
        for (instance.peer_dependencies, 0..) |peer, index| {
            try writeIndent(writer, level + 2);
            try writeString(writer, peer.name);
            try writer.writeAll(": ");
            try writeString(writer, peer.requirement);
            if (index + 1 < instance.peer_dependencies.len) try writer.writeByte(',');
            try writer.writeByte('\n');
        }
        try writeIndent(writer, level + 1);
        try writer.writeByte('}');
    }
    try writer.writeByte('\n');
    try writeIndent(writer, level);
    try writer.writeByte('}');
}

fn writePackageEntry(writer: *std.Io.Writer, level: usize, entry: PackageEntry) !void {
    try writer.writeAll("{\n");
    try writeIndent(writer, level + 1);
    try writer.writeAll("\"id\": ");
    try writeString(writer, entry.id);
    try writer.writeAll(",\n");
    try writeIndent(writer, level + 1);
    try writer.writeAll("\"name\": ");
    try writeString(writer, entry.name);
    try writer.writeAll(",\n");
    try writeIndent(writer, level + 1);
    try writer.writeAll("\"version\": ");
    try writeString(writer, entry.version);
    if (entry.source) |source| {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"source\": ");
        try writeSource(writer, source);
    }
    if (entry.resolved_from) |source| {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"resolvedFrom\": ");
        try writeSource(writer, source);
    }
    try writer.writeAll(",\n");
    try writeIndent(writer, level + 1);
    try writer.writeAll("\"dependencies\": ");
    try writeInlineStrings(writer, entry.dependencies);
    if (entry.features.len > 0) {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"features\": ");
        try writeInlineStrings(writer, entry.features);
    }
    if (entry.implementation) |implementation| {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"implementation\": ");
        try writeString(writer, implementation);
    }
    if (entry.artifacts.len > 0) {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"artifacts\": {\n");
        for (entry.artifacts, 0..) |artifact, index| {
            try writeIndent(writer, level + 2);
            try writeString(writer, artifact.key);
            try writer.writeAll(": ");
            try writeArtifact(writer, level + 2, artifact);
            if (index + 1 < entry.artifacts.len) try writer.writeByte(',');
            try writer.writeByte('\n');
        }
        try writeIndent(writer, level + 1);
        try writer.writeByte('}');
    }
    if (entry.npm_instances.len > 0) {
        try writer.writeAll(",\n");
        try writeIndent(writer, level + 1);
        try writer.writeAll("\"npmInstances\": {\n");
        for (entry.npm_instances, 0..) |instance, index| {
            try writeIndent(writer, level + 2);
            try writeString(writer, instance.key);
            try writer.writeAll(": ");
            try writeNpmInstance(writer, level + 2, instance);
            if (index + 1 < entry.npm_instances.len) try writer.writeByte(',');
            try writer.writeByte('\n');
        }
        try writeIndent(writer, level + 1);
        try writer.writeByte('}');
    }
    try writer.writeByte('\n');
    try writeIndent(writer, level);
    try writer.writeByte('}');
}

fn writePackageMap(writer: *std.Io.Writer, level: usize, packages: []const PackageEntry) !void {
    try writer.writeAll("{\n");
    for (packages, 0..) |entry, index| {
        try writeIndent(writer, level + 1);
        try writeString(writer, entry.id);
        try writer.writeAll(": ");
        try writePackageEntry(writer, level + 1, entry);
        if (index + 1 < packages.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writeIndent(writer, level);
    try writer.writeByte('}');
}

/// lock を決定的な JSON へ書き出す。同一モデルからは常に同一バイト列になる。
pub fn serialize(lock: *const Lock, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\n");
    try writeIndent(writer, 1);
    try writer.print("\"schemaVersion\": {d},\n", .{lock.schema_version});
    try writeIndent(writer, 1);
    try writer.print("\"resolverVersion\": {d},\n", .{lock.resolver_version});
    try writeIndent(writer, 1);
    try writer.writeAll("\"input\": {\n");
    try writeIndent(writer, 2);
    try writer.writeAll("\"manifestSha256\": ");
    try writeString(writer, lock.input.manifest_sha256);
    try writer.writeAll(",\n");
    try writeIndent(writer, 2);
    try writer.writeAll("\"profile\": ");
    try writeString(writer, lock.input.profile);
    try writer.writeAll(",\n");
    try writeIndent(writer, 2);
    try writer.writeAll("\"features\": ");
    try writeInlineStrings(writer, lock.input.features);
    try writer.writeAll(",\n");
    try writeIndent(writer, 2);
    try writer.writeAll("\"target\": ");
    try writeTarget(writer, lock.input.target);
    try writer.writeByte('\n');
    try writeIndent(writer, 1);
    try writer.writeAll("},\n");
    try writeIndent(writer, 1);
    try writer.writeAll("\"packages\": ");
    try writePackageMap(writer, 1, lock.packages);
    try writer.writeByte('\n');
    if (lock.profiles.len > 0) {
        try writer.writeAll(",\n");
        try writeIndent(writer, 1);
        try writer.writeAll("\"profiles\": {\n");
        for (lock.profiles, 0..) |profile, index| {
            try writeIndent(writer, 2);
            try writeString(writer, profile.name);
            try writer.writeAll(": ");
            try writeProfile(writer, profile.record);
            if (index + 1 < lock.profiles.len) try writer.writeByte(',');
            try writer.writeByte('\n');
        }
        try writeIndent(writer, 1);
        try writer.writeByte('}');
        try writer.writeByte('\n');
    }
    if (lock.profile_packages.len > 0) {
        try writer.writeAll(",\n");
        try writeIndent(writer, 1);
        try writer.writeAll("\"profilePackages\": {\n");
        for (lock.profile_packages, 0..) |profile, index| {
            try writeIndent(writer, 2);
            try writeString(writer, profile.profile);
            try writer.writeAll(": ");
            try writePackageMap(writer, 2, profile.packages);
            if (index + 1 < lock.profile_packages.len) try writer.writeByte(',');
            try writer.writeByte('\n');
        }
        try writeIndent(writer, 1);
        try writer.writeByte('}');
        try writer.writeByte('\n');
    }
    try writer.writeAll("}\n");
}

/// `serialize` の結果を新規確保したバイト列で返す。呼出し側が `free` する。
pub fn toBytes(lock: *const Lock, gpa: Allocator) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    errdefer output.deinit();
    try serialize(lock, &output.writer);
    return output.toOwnedSlice();
}

/// `serialize` の結果の SHA-256 を小文字 hex で返す。呼出し側が `free` する。
pub fn sha256Hex(lock: *const Lock, gpa: Allocator) ![]u8 {
    const bytes = try toBytes(lock, gpa);
    defer gpa.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = try gpa.alloc(u8, 64);
    _ = std.fmt.bufPrint(hex, "{x}", .{digest}) catch unreachable;
    return hex;
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

pub const ParseError = error{ OutOfMemory, InvalidJson, InvalidLock };

const Parser = struct {
    arena: Allocator,
    diagnostics: *diag.List,

    fn report(self: *Parser, code: []const u8, path: []const u8, comptime format: []const u8, args: anytype) !void {
        try self.diagnostics.addFmt(code, .err, path, .{}, format, args);
    }

    fn asObject(self: *Parser, value: std.json.Value, path: []const u8) !?std.json.ObjectMap {
        return switch (value) {
            .object => |object| object,
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected object", .{});
                break :blk null;
            },
        };
    }

    fn asArray(self: *Parser, value: std.json.Value, path: []const u8) !?std.json.Array {
        return switch (value) {
            .array => |array| array,
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected array", .{});
                break :blk null;
            },
        };
    }

    fn asString(self: *Parser, value: std.json.Value, path: []const u8) !?[]const u8 {
        return switch (value) {
            .string => |text| text,
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected string", .{});
                break :blk null;
            },
        };
    }

    fn asBool(self: *Parser, value: std.json.Value, path: []const u8) !?bool {
        return switch (value) {
            .bool => |flag| flag,
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected boolean", .{});
                break :blk null;
            },
        };
    }

    fn asU32(self: *Parser, value: std.json.Value, path: []const u8) !?u32 {
        return switch (value) {
            .integer => |number| if (number >= 0 and number <= std.math.maxInt(u32)) @intCast(number) else blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected unsigned integer", .{});
                break :blk null;
            },
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected integer", .{});
                break :blk null;
            },
        };
    }

    fn duplicate(self: *Parser, text: []const u8) ![]const u8 {
        return self.arena.dupe(u8, text);
    }

    /// `additionalProperties: false` 相当。未知フィールドを E022 で報告する。
    fn rejectUnknown(self: *Parser, object: std.json.ObjectMap, allowed: []const []const u8, path: []const u8) !void {
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            if (containsString(allowed, entry.key_ptr.*)) continue;
            const field_path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, entry.key_ptr.* });
            try self.report(diag.E022_UNKNOWN_FIELD, field_path, "unknown field \"{s}\"", .{entry.key_ptr.*});
        }
    }

    /// 必須 string フィールドを読む。欠落は E019。
    fn requiredString(self: *Parser, object: std.json.ObjectMap, name: []const u8, path: []const u8) !?[]const u8 {
        const value = object.get(name) orelse {
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"{s}\"", .{name});
            return null;
        };
        return self.asString(value, path);
    }
};

fn parseFeatureList(parser: *Parser, value: std.json.Value, path: []const u8) !?[]const []const u8 {
    const array = (try parser.asArray(value, path)) orelse return null;
    var items: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        const text = (try parser.asString(item, path)) orelse continue;
        try items.append(parser.arena, try parser.duplicate(text));
    }
    return items.items;
}

fn parseStringList(parser: *Parser, value: std.json.Value, path: []const u8) !?[]const []const u8 {
    const array = (try parser.asArray(value, path)) orelse return null;
    var items: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        const text = (try parser.asString(item, path)) orelse continue;
        try items.append(parser.arena, try parser.duplicate(text));
    }
    return items.items;
}

fn parseSource(parser: *Parser, value: std.json.Value, path: []const u8) !?Source {
    const object = (try parser.asObject(value, path)) orelse return null;
    const type_value = object.get("type") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"type\"", .{});
        return null;
    };
    const type_text = (try parser.asString(type_value, path)) orelse return null;

    var source = Source{ .kind = .registry };
    if (std.mem.eql(u8, type_text, "registry")) {
        source.kind = .registry;
    } else if (std.mem.eql(u8, type_text, "static")) {
        source.kind = .static;
    } else if (std.mem.eql(u8, type_text, "git")) {
        source.kind = .git;
    } else if (std.mem.eql(u8, type_text, "http")) {
        source.kind = .http;
    } else if (std.mem.eql(u8, type_text, "path")) {
        source.kind = .path;
    } else {
        try parser.report(diag.E029_INVALID_VALUE, path, "unknown source type \"{s}\"", .{type_text});
        return null;
    }

    const allowed: []const []const u8 = switch (source.kind) {
        .registry, .static => &.{ "type", "url" },
        .git => &.{ "type", "url", "commit", "path" },
        .http => &.{ "type", "url", "hash" },
        .path => &.{ "type", "path", "mutable" },
    };
    try parser.rejectUnknown(object, allowed, path);

    // source 種別ごとの必須フィールド。
    switch (source.kind) {
        .registry, .static => {
            if (try parser.requiredString(object, "url", path)) |url| source.url = try parser.duplicate(url);
        },
        .git => {
            if (try parser.requiredString(object, "url", path)) |url| source.url = try parser.duplicate(url);
            if (try parser.requiredString(object, "commit", path)) |commit| source.commit = try parser.duplicate(commit);
        },
        .http => {
            if (try parser.requiredString(object, "url", path)) |url| source.url = try parser.duplicate(url);
            if (try parser.requiredString(object, "hash", path)) |hash| source.hash = try parser.duplicate(hash);
        },
        .path => {
            if (try parser.requiredString(object, "path", path)) |dep_path| source.path = try parser.duplicate(dep_path);
        },
    }

    if (source.kind == .git) {
        if (object.get("path")) |dep_path_value| {
            if (try parser.asString(dep_path_value, path)) |dep_path| source.path = try parser.duplicate(dep_path);
        }
    }
    if (source.kind == .path) {
        if (object.get("mutable")) |mutable_value| {
            if (try parser.asBool(mutable_value, path)) |mutable| source.mutable = mutable;
        }
        // path 依存は可変参照が既定。
        if (source.mutable == null) source.mutable = true;
    }
    return source;
}

fn parseArtifact(parser: *Parser, key: []const u8, value: std.json.Value, path: []const u8) !?Artifact {
    const object = (try parser.asObject(value, path)) orelse return null;
    try parser.rejectUnknown(object, &.{ "kind", "type", "sha256", "url" }, path);
    const kind_text = (try parser.requiredString(object, "kind", path)) orelse return null;
    var artifact = Artifact{ .key = try parser.duplicate(key), .kind = try parser.duplicate(kind_text) };
    if (object.get("type")) |type_value| {
        if (try parser.asString(type_value, path)) |artifact_type| artifact.type = try parser.duplicate(artifact_type);
    }
    if (object.get("sha256")) |sha_value| {
        if (try parser.asString(sha_value, path)) |sha256| artifact.sha256 = try parser.duplicate(sha256);
    }
    if (object.get("url")) |url_value| {
        if (try parser.asString(url_value, path)) |url| artifact.url = try parser.duplicate(url);
    }
    return artifact;
}

fn parseNpmInstance(parser: *Parser, key: []const u8, value: std.json.Value, path: []const u8) !?NpmInstance {
    const object = (try parser.asObject(value, path)) orelse return null;
    try parser.rejectUnknown(object, &.{ "name", "version", "context", "sha256", "url", "peerDependencies" }, path);
    const name_text = (try parser.requiredString(object, "name", path)) orelse return null;
    const version_text = (try parser.requiredString(object, "version", path)) orelse return null;
    var instance = NpmInstance{
        .key = try parser.duplicate(key),
        .name = try parser.duplicate(name_text),
        .version = try parser.duplicate(version_text),
    };
    if (object.get("context")) |context_value| {
        if (try parser.asString(context_value, path)) |context| instance.context = try parser.duplicate(context);
    }
    if (object.get("sha256")) |sha_value| {
        if (try parser.asString(sha_value, path)) |sha256| instance.sha256 = try parser.duplicate(sha256);
    }
    if (object.get("url")) |url_value| {
        if (try parser.asString(url_value, path)) |url| instance.url = try parser.duplicate(url);
    }
    if (object.get("peerDependencies")) |peers_value| {
        if (try parser.asObject(peers_value, path)) |peers| {
            var list: std.ArrayList(PeerDependency) = .empty;
            var iterator = peers.iterator();
            while (iterator.next()) |entry| {
                const requirement = (try parser.asString(entry.value_ptr.*, path)) orelse continue;
                try list.append(parser.arena, .{
                    .name = try parser.duplicate(entry.key_ptr.*),
                    .requirement = try parser.duplicate(requirement),
                });
            }
            std.mem.sort(PeerDependency, list.items, {}, struct {
                fn lt(_: void, a: PeerDependency, b: PeerDependency) bool {
                    return std.mem.order(u8, a.name, b.name) == .lt;
                }
            }.lt);
            instance.peer_dependencies = list.items;
        }
    }
    return instance;
}

fn parsePackageEntry(parser: *Parser, id: []const u8, value: std.json.Value, path: []const u8) !?PackageEntry {
    const object = (try parser.asObject(value, path)) orelse return null;
    const known = [_][]const u8{ "id", "name", "version", "source", "resolvedFrom", "dependencies", "features", "implementation", "artifacts", "npmInstances" };
    var key_iterator = object.iterator();
    while (key_iterator.next()) |entry| {
        if (!containsString(&known, entry.key_ptr.*)) {
            const field_path = try std.fmt.allocPrint(parser.arena, "{s}.{s}", .{ path, entry.key_ptr.* });
            try parser.report(diag.E022_UNKNOWN_FIELD, field_path, "unknown field \"{s}\"", .{entry.key_ptr.*});
        }
    }

    const name_value = object.get("name") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"name\"", .{});
        return null;
    };
    const version_value = object.get("version") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"version\"", .{});
        return null;
    };
    var entry = PackageEntry{
        .id = try parser.duplicate(id),
        .name = try parser.duplicate((try parser.asString(name_value, path)) orelse return null),
        .version = try parser.duplicate((try parser.asString(version_value, path)) orelse return null),
    };
    const explicit_id = (try parser.requiredString(object, "id", path)) orelse return null;
    if (!std.mem.eql(u8, explicit_id, id)) {
        try parser.report(diag.E029_INVALID_VALUE, path, "package id \"{s}\" does not match map key \"{s}\"", .{ explicit_id, id });
    }
    entry.id = try parser.duplicate(explicit_id);
    const dependencies_value = object.get("dependencies") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"dependencies\"", .{});
        return null;
    };
    if (object.get("source")) |source_value| {
        entry.source = try parseSource(parser, source_value, path);
    }
    if (object.get("resolvedFrom")) |source_value| {
        entry.resolved_from = try parseSource(parser, source_value, path);
    }
    entry.dependencies = (try parseStringList(parser, dependencies_value, path)) orelse &.{};
    if (object.get("features")) |features_value| {
        entry.features = (try parseFeatureList(parser, features_value, path)) orelse &.{};
    }
    if (object.get("implementation")) |implementation_value| {
        if (try parser.asString(implementation_value, path)) |implementation| {
            if (!containsString(&known_implementations, implementation)) {
                try parser.report(diag.E029_INVALID_VALUE, path, "unknown implementation \"{s}\"", .{implementation});
            }
            entry.implementation = try parser.duplicate(implementation);
        }
    }
    if (object.get("artifacts")) |artifacts_value| {
        if (try parser.asObject(artifacts_value, path)) |artifacts| {
            var list: std.ArrayList(Artifact) = .empty;
            var iterator = artifacts.iterator();
            while (iterator.next()) |artifact_entry| {
                if (try parseArtifact(parser, artifact_entry.key_ptr.*, artifact_entry.value_ptr.*, path)) |artifact| {
                    try list.append(parser.arena, artifact);
                }
            }
            std.mem.sort(Artifact, list.items, {}, struct {
                fn lt(_: void, a: Artifact, b: Artifact) bool {
                    return std.mem.order(u8, a.key, b.key) == .lt;
                }
            }.lt);
            entry.artifacts = list.items;
        }
    }
    if (object.get("npmInstances")) |npm_value| {
        if (try parser.asObject(npm_value, path)) |instances| {
            var list: std.ArrayList(NpmInstance) = .empty;
            var iterator = instances.iterator();
            while (iterator.next()) |instance_entry| {
                if (try parseNpmInstance(parser, instance_entry.key_ptr.*, instance_entry.value_ptr.*, path)) |instance| {
                    try list.append(parser.arena, instance);
                }
            }
            std.mem.sort(NpmInstance, list.items, {}, struct {
                fn lt(_: void, a: NpmInstance, b: NpmInstance) bool {
                    return std.mem.order(u8, a.key, b.key) == .lt;
                }
            }.lt);
            entry.npm_instances = list.items;
        }
    }
    return entry;
}

fn parsePackageMap(parser: *Parser, value: std.json.Value, path: []const u8) !?[]const PackageEntry {
    const object = (try parser.asObject(value, path)) orelse return null;
    var list: std.ArrayList(PackageEntry) = .empty;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const field_path = try std.fmt.allocPrint(parser.arena, "{s}.{s}", .{ path, entry.key_ptr.* });
        if (try parsePackageEntry(parser, entry.key_ptr.*, entry.value_ptr.*, field_path)) |package| {
            try list.append(parser.arena, package);
        }
    }
    std.mem.sort(PackageEntry, list.items, {}, packageLessThan);
    return list.items;
}

fn parseProfile(parser: *Parser, value: std.json.Value, path: []const u8) !?ProfileRecord {
    const object = (try parser.asObject(value, path)) orelse return null;
    const known = [_][]const u8{ "runtime", "os", "cpu", "abi", "compat-js", "optimize" };
    var key_iterator = object.iterator();
    while (key_iterator.next()) |entry| {
        if (!containsString(&known, entry.key_ptr.*)) {
            const field_path = try std.fmt.allocPrint(parser.arena, "{s}.{s}", .{ path, entry.key_ptr.* });
            try parser.report(diag.E022_UNKNOWN_FIELD, field_path, "unknown field \"{s}\"", .{entry.key_ptr.*});
        }
    }
    const os_value = object.get("os") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"os\"", .{});
        return null;
    };
    const cpu_value = object.get("cpu") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"cpu\"", .{});
        return null;
    };
    const abi_value = object.get("abi") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"abi\"", .{});
        return null;
    };
    var profile = ProfileRecord{
        .os = try parser.duplicate((try parser.asString(os_value, path)) orelse return null),
        .cpu = try parser.duplicate((try parser.asString(cpu_value, path)) orelse return null),
        .abi = try parser.duplicate((try parser.asString(abi_value, path)) orelse return null),
    };
    if (object.get("runtime")) |runtime_value| {
        if (try parser.asString(runtime_value, path)) |runtime| profile.runtime = try parser.duplicate(runtime);
    }
    if (object.get("compat-js")) |compat_value| {
        profile.compat_js = try parser.asBool(compat_value, path);
    }
    if (object.get("optimize")) |optimize_value| {
        if (try parser.asString(optimize_value, path)) |optimize| profile.optimize = try parser.duplicate(optimize);
    }
    return profile;
}

fn parseInput(parser: *Parser, value: std.json.Value, path: []const u8) !?Input {
    const object = (try parser.asObject(value, path)) orelse return null;
    try parser.rejectUnknown(object, &.{ "manifestSha256", "profile", "features", "target" }, path);
    const manifest_value = object.get("manifestSha256") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"manifestSha256\"", .{});
        return null;
    };
    const profile_value = object.get("profile") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"profile\"", .{});
        return null;
    };
    const features_value = object.get("features") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"features\"", .{});
        return null;
    };
    const target_value = object.get("target") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"target\"", .{});
        return null;
    };
    const target_object = (try parser.asObject(target_value, path)) orelse return null;
    try parser.rejectUnknown(target_object, &.{ "os", "cpu", "abi" }, path);
    const os_value = target_object.get("os") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"target.os\"", .{});
        return null;
    };
    const cpu_value = target_object.get("cpu") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"target.cpu\"", .{});
        return null;
    };
    const abi_value = target_object.get("abi") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"target.abi\"", .{});
        return null;
    };
    return Input{
        .manifest_sha256 = try parser.duplicate((try parser.asString(manifest_value, path)) orelse return null),
        .profile = try parser.duplicate((try parser.asString(profile_value, path)) orelse return null),
        .features = (try parseFeatureList(parser, features_value, path)) orelse &.{},
        .target = .{
            .os = try parser.duplicate((try parser.asString(os_value, path)) orelse return null),
            .cpu = try parser.duplicate((try parser.asString(cpu_value, path)) orelse return null),
            .abi = try parser.duplicate((try parser.asString(abi_value, path)) orelse return null),
        },
    };
}

/// `nako.lock` バイト列を解析して `Lock` を構築する。構造エラーは診断へ記録し
/// `error.InvalidLock` を返す。未知 schema version は構文上有効なので解析は成功し、
/// `validate` が `E002_UNKNOWN_LOCK_SCHEMA` を報告する。
pub fn parse(gpa: Allocator, bytes: []const u8, diagnostics: *diag.List) ParseError!Lock {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    const initial_errors = diagnostics.errorCount();
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var parser = Parser{ .arena = arena.allocator(), .diagnostics = diagnostics };

    const root = (try parser.asObject(parsed.value, "nako.lock")) orelse return error.InvalidLock;
    const known_root = [_][]const u8{ "schemaVersion", "resolverVersion", "input", "packages", "profiles", "profilePackages" };
    var key_iterator = root.iterator();
    while (key_iterator.next()) |entry| {
        if (!containsString(&known_root, entry.key_ptr.*)) {
            const field_path = try std.fmt.allocPrint(parser.arena, "nako.lock.{s}", .{entry.key_ptr.*});
            try parser.report(diag.E022_UNKNOWN_FIELD, field_path, "unknown field \"{s}\"", .{entry.key_ptr.*});
        }
    }

    const schema_value = root.get("schemaVersion") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, "nako.lock", "missing required field \"schemaVersion\"", .{});
        return error.InvalidLock;
    };
    const schema_version = (try parser.asU32(schema_value, "nako.lock.schemaVersion")) orelse return error.InvalidLock;

    const resolver_value = root.get("resolverVersion") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, "nako.lock", "missing required field \"resolverVersion\"", .{});
        return error.InvalidLock;
    };
    const resolver_version_value = (try parser.asU32(resolver_value, "nako.lock.resolverVersion")) orelse return error.InvalidLock;

    const input_value = root.get("input") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, "nako.lock", "missing required field \"input\"", .{});
        return error.InvalidLock;
    };
    const input = (try parseInput(&parser, input_value, "nako.lock.input")) orelse return error.InvalidLock;

    const packages_value = root.get("packages") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, "nako.lock", "missing required field \"packages\"", .{});
        return error.InvalidLock;
    };
    const packages = (try parsePackageMap(&parser, packages_value, "nako.lock.packages")) orelse return error.InvalidLock;

    var profiles: std.ArrayList(NamedProfile) = .empty;
    if (root.get("profiles")) |profiles_value| {
        if (try parser.asObject(profiles_value, "nako.lock.profiles")) |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const field_path = try std.fmt.allocPrint(parser.arena, "nako.lock.profiles.{s}", .{entry.key_ptr.*});
                if (try parseProfile(&parser, entry.value_ptr.*, field_path)) |record| {
                    try profiles.append(parser.arena, .{
                        .name = try parser.duplicate(entry.key_ptr.*),
                        .record = record,
                    });
                }
            }
        }
    }
    std.mem.sort(NamedProfile, profiles.items, {}, namedProfileLessThan);

    var profile_packages: std.ArrayList(ProfilePackages) = .empty;
    if (root.get("profilePackages")) |value| {
        if (try parser.asObject(value, "nako.lock.profilePackages")) |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const field_path = try std.fmt.allocPrint(parser.arena, "nako.lock.profilePackages.{s}", .{entry.key_ptr.*});
                if (try parsePackageMap(&parser, entry.value_ptr.*, field_path)) |profile_package_list| {
                    try profile_packages.append(parser.arena, .{
                        .profile = try parser.duplicate(entry.key_ptr.*),
                        .packages = profile_package_list,
                    });
                }
            }
        }
    }
    std.mem.sort(ProfilePackages, profile_packages.items, {}, profilePackageLessThan);

    if (diagnostics.errorCount() > initial_errors) return error.InvalidLock;

    return .{
        .arena = arena,
        .schema_version = schema_version,
        .resolver_version = resolver_version_value,
        .input = input,
        .packages = packages,
        .profiles = profiles.items,
        .profile_packages = profile_packages.items,
    };
}

// ---------------------------------------------------------------------------
// 意味検証
// ---------------------------------------------------------------------------

fn validatePackageSet(packages: []const PackageEntry, exists: *const std.StringHashMapUnmanaged(void), profile: ?ProfileRecord, path: []const u8, diagnostics: *diag.List) !void {
    const esm_allowed = if (profile) |record| record.allowsEsm() else false;
    for (packages) |package| {
        const package_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.{s}", .{ path, package.id });
        defer diagnostics.allocator.free(package_path);
        const artifacts_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.artifacts", .{package_path});
        defer diagnostics.allocator.free(artifacts_path);
        _ = semver.Version.parse(package.version) catch {
            try diagnostics.addFmt(diag.E024_INVALID_SEMVER, .err, package_path, .{}, "invalid package version \"{s}\" (not semver)", .{package.version});
        };
        if (package.artifacts.len == 0) {
            try diagnostics.addFmt(diag.E008_MISSING_ARTIFACT, .err, artifacts_path, .{}, "package {s} has no artifacts", .{package.id});
        }
        var has_esm = false;
        for (package.artifacts) |artifact| {
            if (!artifact.isKnownKind()) {
                const artifact_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.artifacts.{s}", .{ package_path, artifact.key });
                defer diagnostics.allocator.free(artifact_path);
                try diagnostics.addFmt(diag.E007_UNKNOWN_ARTIFACT_KIND, .err, artifact_path, .{}, "unknown artifact kind \"{s}\" at {s}.artifacts.{s}", .{ artifact.kind, package_path, artifact.key });
            }
            if (std.mem.eql(u8, artifact.kind, "ESM")) has_esm = true;
            if (artifact.type) |artifact_type| {
                if (!containsString(&known_artifact_types, artifact_type)) {
                    const artifact_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.artifacts.{s}", .{ package_path, artifact.key });
                    defer diagnostics.allocator.free(artifact_path);
                    try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, artifact_path, .{}, "unknown artifact type \"{s}\"", .{artifact_type});
                }
            }
        }
        if (has_esm and !esm_allowed) {
            try diagnostics.addFmt(diag.E006_JS_IN_NORMAL_MODE, .err, artifacts_path, .{}, "ESM artifact selected without compat-js profile", .{});
        }
        for (package.dependencies) |dependency| {
            if (!exists.contains(dependency)) {
                const dependencies_path = try std.fmt.allocPrint(diagnostics.allocator, "{s}.dependencies", .{package_path});
                defer diagnostics.allocator.free(dependencies_path);
                try diagnostics.addFmt(diag.E013_MISSING_PACKAGE, .err, dependencies_path, .{}, "dependency {s} not found in lock packages", .{dependency});
            }
        }
    }
}

fn buildIdSet(gpa: Allocator, packages: []const PackageEntry) !std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    for (packages) |package| {
        try set.put(gpa, package.id, {});
    }
    return set;
}

fn stringListEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |item, index| {
        if (!std.mem.eql(u8, item, b[index])) return false;
    }
    return true;
}

fn sourceOptEql(a: ?Source, b: ?Source) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return Source.eql(a.?, b.?);
}

fn artifactEql(a: Artifact, b: Artifact) bool {
    return std.mem.eql(u8, a.key, b.key) and
        std.mem.eql(u8, a.kind, b.kind) and
        optEql(a.type, b.type) and
        optEql(a.sha256, b.sha256) and
        optEql(a.url, b.url);
}

fn peerDependencyEql(a: PeerDependency, b: PeerDependency) bool {
    return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.requirement, b.requirement);
}

fn npmInstanceEql(a: NpmInstance, b: NpmInstance) bool {
    if (!(std.mem.eql(u8, a.key, b.key) and
        std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.version, b.version) and
        optEql(a.context, b.context) and
        optEql(a.sha256, b.sha256) and
        optEql(a.url, b.url))) return false;
    if (a.peer_dependencies.len != b.peer_dependencies.len) return false;
    for (a.peer_dependencies, 0..) |peer, index| {
        if (!peerDependencyEql(peer, b.peer_dependencies[index])) return false;
    }
    return true;
}

fn packageEntryEql(a: PackageEntry, b: PackageEntry) bool {
    if (!(std.mem.eql(u8, a.id, b.id) and
        std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.version, b.version) and
        optEql(a.implementation, b.implementation))) return false;
    if (!sourceOptEql(a.source, b.source) or !sourceOptEql(a.resolved_from, b.resolved_from)) return false;
    if (!stringListEql(a.dependencies, b.dependencies) or !stringListEql(a.features, b.features)) return false;
    if (a.artifacts.len != b.artifacts.len) return false;
    for (a.artifacts, 0..) |artifact, index| {
        if (!artifactEql(artifact, b.artifacts[index])) return false;
    }
    if (a.npm_instances.len != b.npm_instances.len) return false;
    for (a.npm_instances, 0..) |instance, index| {
        if (!npmInstanceEql(instance, b.npm_instances[index])) return false;
    }
    return true;
}

/// 双方 id 昇順に整列済みの package マップを比較する。
fn packageMapsEql(a: []const PackageEntry, b: []const PackageEntry) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.id, b[index].id)) return false;
        if (!packageEntryEql(entry, b[index])) return false;
    }
    return true;
}

/// lock の意味的な整合性を検証する。既知の診断は SPECIFICATION.md §8 と対応する。
pub fn validate(lock: *const Lock, diagnostics: *diag.List) !void {
    if (lock.schema_version != lock_schema_version) {
        try diagnostics.addFmt(diag.E002_UNKNOWN_LOCK_SCHEMA, .err, "nako.lock.schemaVersion", .{}, "unknown lock schema version {d}", .{lock.schema_version});
    }

    for (lock.profiles) |profile| {
        if (profile.record.runtime) |runtime| {
            if (!containsString(&known_profile_runtimes, runtime)) {
                const path = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.profiles.{s}.runtime", .{profile.name});
                defer diagnostics.allocator.free(path);
                try diagnostics.addFmt(diag.E014_INVALID_PROFILE, .err, path, .{}, "profile \"{s}\" has invalid runtime: {s}", .{ profile.name, runtime });
            }
        }
    }

    var id_set = try buildIdSet(diagnostics.allocator, lock.packages);
    defer id_set.deinit(diagnostics.allocator);

    if (lock.profileRecord(lock.input.profile) == null) {
        try diagnostics.addFmt(diag.E030_UNKNOWN_PROFILE, .err, "nako.lock.input.profile", .{}, "unknown profile \"{s}\"", .{lock.input.profile});
    }
    const selected = lock.profileRecord(lock.input.profile);
    try validatePackageSet(lock.packages, &id_set, if (selected) |record| record.* else null, "nako.lock.packages", diagnostics);

    for (lock.profile_packages) |profile| {
        var profile_id_set = try buildIdSet(diagnostics.allocator, profile.packages);
        defer profile_id_set.deinit(diagnostics.allocator);
        const profile_path = try std.fmt.allocPrint(diagnostics.allocator, "nako.lock.profilePackages.{s}", .{profile.profile});
        defer diagnostics.allocator.free(profile_path);
        const record = lock.profileRecord(profile.profile);
        if (record == null) {
            try diagnostics.addFmt(diag.E030_UNKNOWN_PROFILE, .err, profile_path, .{}, "unknown profile \"{s}\"", .{profile.profile});
        }
        // `packages` は選択された `input.profile` のグラフの正本である。
        // profilePackages に同じ profile がある場合は一致を要求する。
        if (record != null and std.mem.eql(u8, profile.profile, lock.input.profile) and !packageMapsEql(lock.packages, profile.packages)) {
            try diagnostics.addFmt(diag.E029_INVALID_VALUE, .err, profile_path, .{}, "profilePackages.{s} does not match packages", .{profile.profile});
        }
        try validatePackageSet(profile.packages, &profile_id_set, if (record) |value| value.* else null, profile_path, diagnostics);
    }

    // lnako/cnako が共用する同一 ID・版の source artifact は同じ hash で
    // 参照しなければならない。
    if (sharedArtifactMismatch(lock)) |mismatch| {
        try diagnostics.addFmt(diag.E009_HASH_MISMATCH, .err, "nako.lock.profilePackages", .{}, "source artifact hash differs across profiles for {s}@{s}", .{ mismatch.id, mismatch.version });
    }
}

// ---------------------------------------------------------------------------
// 鮮度判定・resolver 互換性
// ---------------------------------------------------------------------------

pub const Freshness = enum {
    fresh,
    missing,
    stale_schema,
    stale_resolver,
    stale_manifest,
    stale_profile,
    stale_features,
    stale_target,
};

/// 既存 lock と現在の入力条件を比較し、再解決が必要かを判定する。
/// manifest 変更は依存宣言変更を含むため再解決契機となる。path ソース本文の
/// 編集は root manifest の SHA-256 を変えないため、ここでは stale にならない。
pub fn checkFreshness(existing: ?*const Lock, current: Input) Freshness {
    const lock = existing orelse return .missing;
    if (lock.schema_version != lock_schema_version) return .stale_schema;
    if (lock.resolver_version != resolver_version) return .stale_resolver;
    if (!std.mem.eql(u8, lock.input.manifest_sha256, current.manifest_sha256)) return .stale_manifest;
    if (!std.mem.eql(u8, lock.input.profile, current.profile)) return .stale_profile;
    if (!Input.sameFeatures(lock.input, current)) return .stale_features;
    if (!Target.eql(lock.input.target, current.target)) return .stale_target;
    return .fresh;
}

/// `--locked` 時の契約。lock 不足・未知 schema・resolver 不一致・陳腐化は
/// 無変更で失敗させる（`error.LockedNotSatisfied`）。
pub const LockedError = error{LockedNotSatisfied};

pub fn requireFresh(existing: ?*const Lock, current: Input) LockedError!void {
    if (checkFreshness(existing, current) != .fresh) return error.LockedNotSatisfied;
}

// ---------------------------------------------------------------------------
// 既存版優先・部分更新
// ---------------------------------------------------------------------------

/// 既存 lock の版優先インデックス。`update_targets` に一致した package だけ
/// 優先固定を解除し、それ以外は既存版を候補として固定する。
pub const LockedIndex = struct {
    arena: std.heap.ArenaAllocator,
    versions: std.StringHashMapUnmanaged(resolver.Version) = .empty,
    unlocked: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *LockedIndex) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// resolver の `Provider.lockedVersion` から呼ぶ。`id.pkg` のみ対象。
    pub fn get(self: *const LockedIndex, id: resolver.PackageId) ?resolver.Version {
        const name = switch (id) {
            .pkg => |value| value,
            .npm => return null,
        };
        return self.versions.get(name);
    }

    pub fn isUnlocked(self: *const LockedIndex, name: []const u8) bool {
        return self.unlocked.contains(name);
    }
};

/// 更新対象名（package id または name）が `targets` に含まれるか。
fn isUpdateTarget(entry: PackageEntry, targets: []const []const u8) bool {
    for (targets) |target| {
        if (std.mem.eql(u8, target, entry.id) or std.mem.eql(u8, target, entry.name)) return true;
    }
    return false;
}

/// 既存 lock の package 版を優先固定するインデックスを作る。`update_targets`
/// が空なら全 package を固定し、指定があれば一致した package だけ解除する。
/// 解決対象 profile のグラフを使い、`id` と `name` の両方で引けるようにする
/// （resolver は manifest 上の package 名で `lockedVersion` を問い合わせる）。
pub fn buildLockedIndex(gpa: Allocator, existing: ?*const Lock, profile: []const u8, update_targets: []const []const u8) !LockedIndex {
    var index = LockedIndex{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer index.arena.deinit();
    // allocator は index.arena 自身を指す。ローカル arena の snapshot を
    // 先に取ると deinit が確保分を解放できないため、必ず index.arena から作る。
    const allocator = index.arena.allocator();
    const lock = existing orelse return index;
    // profilePackages に無い profile へは他 profile の版を流用しない。
    const packages = lock.packagesForProfile(profile) orelse return index;

    for (packages) |entry| {
        if (isUpdateTarget(entry, update_targets)) {
            try index.unlocked.put(allocator, try allocator.dupe(u8, entry.id), {});
            try index.unlocked.put(allocator, try allocator.dupe(u8, entry.name), {});
            continue;
        }
        // semver.Version は prerelease/build を入力文字列から借用するため、
        // index の arena に複製した文字列を解析して所有権を index に閉じる。
        const version_text = try allocator.dupe(u8, entry.version);
        const version = resolver.Version.parse(version_text) catch return error.InvalidLockVersion;
        try index.versions.put(allocator, try allocator.dupe(u8, entry.id), version);
        if (!std.mem.eql(u8, entry.name, entry.id)) {
            try index.versions.put(allocator, try allocator.dupe(u8, entry.name), version);
        }
    }
    return index;
}

// ---------------------------------------------------------------------------
// 部分更新の差分と理由
// ---------------------------------------------------------------------------

pub const ChangeReason = enum {
    unchanged,
    added,
    removed,
    updated_direct,
    updated_indirect,
};

pub const Change = struct {
    id: []const u8,
    name: []const u8,
    reason: ChangeReason,
    from_version: ?[]const u8 = null,
    to_version: ?[]const u8 = null,
    /// この変更を必要とした変更元 package id（昇順）。空なら直接対象または新規。
    caused_by: []const []const u8 = &.{},

    pub fn isChanged(self: Change) bool {
        return self.reason != .unchanged;
    }
};

pub const UpdateReport = struct {
    arena: std.heap.ArenaAllocator,
    changes: []const Change = &.{},

    pub fn deinit(self: *UpdateReport) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn significantCount(self: *const UpdateReport) usize {
        var count: usize = 0;
        for (self.changes) |change| {
            if (change.isChanged()) count += 1;
        }
        return count;
    }

    pub fn find(self: *const UpdateReport, id: []const u8) ?*const Change {
        for (self.changes) |*change| {
            if (std.mem.eql(u8, change.id, id)) return change;
        }
        return null;
    }

    /// 決定的な日本語説明を書き出す。
    pub fn explain(self: *const UpdateReport, writer: *std.Io.Writer) !void {
        for (self.changes) |change| {
            if (!change.isChanged()) continue;
            switch (change.reason) {
                .unchanged => {},
                .added => try writer.print("追加 {s} {s}\n", .{ change.name, change.to_version orelse "" }),
                .removed => try writer.print("削除 {s} {s}\n", .{ change.name, change.from_version orelse "" }),
                .updated_direct => try writer.print("更新(直接指定) {s} {s} -> {s}\n", .{ change.name, change.from_version orelse "", change.to_version orelse "" }),
                .updated_indirect => try writer.print("更新(間接) {s} {s} -> {s}", .{ change.name, change.from_version orelse "", change.to_version orelse "" }),
            }
            if (change.reason == .updated_indirect) {
                try writer.writeAll(" from [");
                for (change.caused_by, 0..) |cause, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try writer.writeAll(cause);
                }
                try writer.writeAll("]");
                try writer.writeByte('\n');
            }
        }
    }
};

fn collectParentMap(gpa: Allocator, packages: []const PackageEntry, map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8))) !void {
    for (packages) |package| {
        for (package.dependencies) |dependency| {
            const gop = try map.getOrPut(gpa, dependency);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            var found = false;
            for (gop.value_ptr.items) |existing| {
                if (std.mem.eql(u8, existing, package.id)) {
                    found = true;
                    break;
                }
            }
            if (!found) try gop.value_ptr.append(gpa, package.id);
        }
    }
}

fn parentListContains(list: []const []const u8, id: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, id)) return true;
    }
    return false;
}

fn packagesOrEmpty(lock: ?*const Lock, profile: []const u8) []const PackageEntry {
    const value = lock orelse return &.{};
    return value.packagesForProfile(profile) orelse &.{};
}

/// 指定 profile の 2 つの lock の差分を取り、部分更新で必要になった変更理由を
/// 説明できる `UpdateReport` を返す。複数 profile を収録した lock では profile
/// ごとに呼び出す。`update_targets` は直接指定された更新対象。
pub fn diff(gpa: Allocator, previous: ?*const Lock, next: *const Lock, profile: []const u8, update_targets: []const []const u8) !UpdateReport {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const previous_packages = packagesOrEmpty(previous, profile);
    const next_packages = next.packagesForProfile(profile) orelse &.{};

    var previous_by_id: std.StringHashMapUnmanaged(PackageEntry) = .empty;
    for (previous_packages) |entry| try previous_by_id.put(allocator, entry.id, entry);
    var next_by_id: std.StringHashMapUnmanaged(PackageEntry) = .empty;
    for (next_packages) |entry| try next_by_id.put(allocator, entry.id, entry);

    var ids: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (next_packages) |entry| {
        if (seen.contains(entry.id)) continue;
        try seen.put(allocator, entry.id, {});
        try ids.append(allocator, entry.id);
    }
    for (previous_packages) |entry| {
        if (seen.contains(entry.id)) continue;
        try seen.put(allocator, entry.id, {});
        try ids.append(allocator, entry.id);
    }
    std.mem.sort([]const u8, ids.items, {}, stringLessThan);

    var parents: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
    try collectParentMap(allocator, previous_packages, &parents);
    try collectParentMap(allocator, next_packages, &parents);

    var changes: std.ArrayList(Change) = .empty;
    var change_index: std.StringHashMapUnmanaged(usize) = .empty;
    for (ids.items) |id| {
        const old_entry = previous_by_id.get(id);
        const new_entry = next_by_id.get(id);
        if (old_entry == null and new_entry == null) continue;

        var reason: ChangeReason = .unchanged;
        if (old_entry == null) {
            reason = .added;
        } else if (new_entry == null) {
            reason = .removed;
        } else if (!packageEntryEql(old_entry.?, new_entry.?)) {
            // version だけでなく feature 統合・implementation・artifact・依存辺の
            // 変化も lock の内容変化として報告対象にする。
            const direct = isUpdateTarget(old_entry.?, update_targets) or isUpdateTarget(new_entry.?, update_targets);
            reason = if (direct) .updated_direct else .updated_indirect;
        }

        const name = if (new_entry) |entry| entry.name else if (old_entry) |entry| entry.name else id;
        const owned_id = try allocator.dupe(u8, id);
        try change_index.put(allocator, owned_id, changes.items.len);
        try changes.append(allocator, .{
            .id = owned_id,
            .name = try allocator.dupe(u8, name),
            .reason = reason,
            .from_version = if (old_entry) |entry| try allocator.dupe(u8, entry.version) else null,
            .to_version = if (new_entry) |entry| try allocator.dupe(u8, entry.version) else null,
        });
    }

    // レポートは lock の arena に依存せず単独で使えるよう、参照文字列も複製する。
    for (changes.items) |*change| {
        if (change.reason == .unchanged or change.reason == .updated_direct) continue;
        var causes: std.ArrayList([]const u8) = .empty;
        if (parents.get(change.id)) |list| {
            for (list.items) |parent| {
                if (std.mem.eql(u8, parent, change.id)) continue;
                const index = change_index.get(parent) orelse continue;
                if (changes.items[index].reason == .unchanged) continue;
                if (!parentListContains(causes.items, parent)) try causes.append(allocator, try allocator.dupe(u8, parent));
            }
        }
        std.mem.sort([]const u8, causes.items, {}, stringLessThan);
        change.caused_by = causes.items;
    }

    return .{ .arena = arena, .changes = changes.items };
}

// ---------------------------------------------------------------------------
// resolver 解決結果からの lock 生成
// ---------------------------------------------------------------------------

pub const PackageDetails = struct {
    public_id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    source: ?Source = null,
    resolved_from: ?Source = null,
    artifacts: []const Artifact = &.{},
    npm_instances: []const NpmInstance = &.{},
};

/// lock 生成に必要な source/artifact metadata を返す契約。取得 provider (#47)
/// が実装し、lock 層は解決 core から分離する。排他的 profile では同じ Public
/// ID に異なる版を許すため、artifact 選択は `id` だけでなく `version` でも引く。
pub const DetailsSource = struct {
    context: *anyopaque,
    getFn: *const fn (context: *anyopaque, gpa: Allocator, id: []const u8, version: []const u8) anyerror!?PackageDetails,

    pub fn get(self: DetailsSource, gpa: Allocator, id: []const u8, version: []const u8) anyerror!?PackageDetails {
        return self.getFn(self.context, gpa, id, version);
    }
};

fn formatPackageId(allocator: Allocator, id: resolver.PackageId) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{id});
}

/// 解決済 node 群から package entry 群を構築する。entry の `id` と
/// `dependencies` は Public ID へ解決して記録する（resolver id と
/// `DetailsSource.public_id` が異なる場合も依存辺を Public ID へ張り替える）。
pub fn buildPackages(allocator: Allocator, nodes: []const resolver.PackageNode, details: DetailsSource) ![]const PackageEntry {
    // 先に resolver id → Public ID の対応と version ごとの details を確定する。
    const Info = struct {
        node: *const resolver.PackageNode,
        id_text: []const u8,
        version_text: []const u8,
        detail: ?PackageDetails,
    };
    var infos: std.ArrayList(Info) = .empty;
    var public_ids: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (nodes) |*node| {
        const id_text = try formatPackageId(allocator, node.id);
        const version_text = try std.fmt.allocPrint(allocator, "{f}", .{node.version});
        const detail = try details.get(allocator, id_text, version_text);
        const public_id = if (detail) |value| if (value.public_id) |value_id| try allocator.dupe(u8, value_id) else id_text else id_text;
        try public_ids.put(allocator, id_text, public_id);
        try infos.append(allocator, .{
            .node = node,
            .id_text = id_text,
            .version_text = version_text,
            .detail = detail,
        });
    }

    var list: std.ArrayList(PackageEntry) = .empty;
    for (infos.items) |info| {
        var dependencies: std.ArrayList([]const u8) = .empty;
        for (info.node.dependencies) |dependency| {
            const dep_text = try formatPackageId(allocator, dependency);
            try dependencies.append(allocator, public_ids.get(dep_text) orelse dep_text);
        }
        std.mem.sort([]const u8, dependencies.items, {}, stringLessThan);

        const public_id = public_ids.get(info.id_text).?;
        var entry = PackageEntry{
            .id = public_id,
            .name = if (info.detail) |value| if (value.name) |name| try allocator.dupe(u8, name) else public_id else public_id,
            .version = info.version_text,
            .dependencies = dependencies.items,
            .features = try canonicalFeatures(allocator, info.node.features),
            .implementation = implementationName(info.node.implementation),
        };
        if (info.detail) |value| {
            entry.source = if (value.source) |source| try dupSourceOwned(allocator, source) else null;
            entry.resolved_from = if (value.resolved_from) |source| try dupSourceOwned(allocator, source) else null;
            entry.artifacts = try sortedArtifacts(allocator, value.artifacts);
            entry.npm_instances = try sortedNpmInstances(allocator, value.npm_instances);
        }
        try list.append(allocator, entry);
    }
    std.mem.sort(PackageEntry, list.items, {}, packageLessThan);
    return list.items;
}

/// resolver の実装選択を lock 表記（artifact kind と揃えた `ESM`）へ変換する。
fn implementationName(implementation: resolver.Impl) []const u8 {
    return switch (implementation) {
        .none => "none",
        .source => "source",
        .native => "native",
        .esm => "ESM",
    };
}

/// `Source` の全文字列を `allocator` へ複製する。path 依存は可変参照が既定
/// のため、`mutable` 未指定なら true を補う。
fn dupSourceOwned(allocator: Allocator, source: Source) !Source {
    return .{
        .kind = source.kind,
        .url = if (source.url) |value| try allocator.dupe(u8, value) else null,
        .hash = if (source.hash) |value| try allocator.dupe(u8, value) else null,
        .commit = if (source.commit) |value| try allocator.dupe(u8, value) else null,
        .path = if (source.path) |value| try allocator.dupe(u8, value) else null,
        .mutable = if (source.kind == .path) source.mutable orelse true else source.mutable,
    };
}

fn dupArtifact(allocator: Allocator, artifact: Artifact) !Artifact {
    return .{
        .key = try allocator.dupe(u8, artifact.key),
        .kind = try allocator.dupe(u8, artifact.kind),
        .type = if (artifact.type) |value| try allocator.dupe(u8, value) else null,
        .sha256 = if (artifact.sha256) |value| try allocator.dupe(u8, value) else null,
        .url = if (artifact.url) |value| try allocator.dupe(u8, value) else null,
    };
}

fn dupPeerDependency(allocator: Allocator, peer: PeerDependency) !PeerDependency {
    return .{
        .name = try allocator.dupe(u8, peer.name),
        .requirement = try allocator.dupe(u8, peer.requirement),
    };
}

fn dupNpmInstance(allocator: Allocator, instance: NpmInstance) !NpmInstance {
    const peers = try allocator.alloc(PeerDependency, instance.peer_dependencies.len);
    for (instance.peer_dependencies, 0..) |peer, index| {
        peers[index] = try dupPeerDependency(allocator, peer);
    }
    std.mem.sort(PeerDependency, peers, {}, struct {
        fn lt(_: void, a: PeerDependency, b: PeerDependency) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    return .{
        .key = try allocator.dupe(u8, instance.key),
        .name = try allocator.dupe(u8, instance.name),
        .version = try allocator.dupe(u8, instance.version),
        .context = if (instance.context) |value| try allocator.dupe(u8, value) else null,
        .sha256 = if (instance.sha256) |value| try allocator.dupe(u8, value) else null,
        .url = if (instance.url) |value| try allocator.dupe(u8, value) else null,
        .peer_dependencies = peers,
    };
}

fn sortedArtifacts(allocator: Allocator, items: []const Artifact) ![]const Artifact {
    const out = try allocator.alloc(Artifact, items.len);
    for (items, 0..) |item, index| out[index] = try dupArtifact(allocator, item);
    std.mem.sort(Artifact, out, {}, struct {
        fn lt(_: void, a: Artifact, b: Artifact) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
    return out;
}

fn sortedNpmInstances(allocator: Allocator, items: []const NpmInstance) ![]const NpmInstance {
    const out = try allocator.alloc(NpmInstance, items.len);
    for (items, 0..) |item, index| out[index] = try dupNpmInstance(allocator, item);
    std.mem.sort(NpmInstance, out, {}, struct {
        fn lt(_: void, a: NpmInstance, b: NpmInstance) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
    return out;
}

/// 単一 profile の lock を構築する。`profiles` は収録する profile 条件。
pub fn build(gpa: Allocator, input: Input, profiles: []const NamedProfile, nodes: []const resolver.PackageNode, details: DetailsSource) !Lock {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const owned_input = Input{
        .manifest_sha256 = try allocator.dupe(u8, input.manifest_sha256),
        .profile = try allocator.dupe(u8, input.profile),
        .features = try canonicalFeatures(allocator, input.features),
        .target = .{
            .os = try allocator.dupe(u8, input.target.os),
            .cpu = try allocator.dupe(u8, input.target.cpu),
            .abi = try allocator.dupe(u8, input.target.abi),
        },
    };

    var owned_profiles: std.ArrayList(NamedProfile) = .empty;
    for (profiles) |profile| {
        try owned_profiles.append(allocator, .{
            .name = try allocator.dupe(u8, profile.name),
            .record = try dupProfile(allocator, profile.record),
        });
    }
    std.mem.sort(NamedProfile, owned_profiles.items, {}, namedProfileLessThan);

    const packages = try buildPackages(allocator, nodes, details);

    return .{
        .arena = arena,
        .input = owned_input,
        .packages = packages,
        .profiles = owned_profiles.items,
    };
}

/// 複数 profile の解決結果を一つの lock に集約する。`primary` は
/// `input.profile` の package グラフ、`per_profile` は全 profile の解決結果。
pub fn buildMulti(
    gpa: Allocator,
    input: Input,
    profiles: []const NamedProfile,
    per_profile: []const ProfileInput,
    details: DetailsSource,
) !Lock {
    var lock = try build(gpa, input, profiles, &.{}, details);
    errdefer lock.deinit();
    const allocator = lock.arena.allocator();

    var profile_packages: std.ArrayList(ProfilePackages) = .empty;
    for (per_profile) |profile_input| {
        const packages = try buildPackages(allocator, profile_input.nodes, details);
        try profile_packages.append(allocator, .{
            .profile = try allocator.dupe(u8, profile_input.profile),
            .packages = packages,
        });
        if (std.mem.eql(u8, profile_input.profile, input.profile)) lock.packages = packages;
    }
    std.mem.sort(ProfilePackages, profile_packages.items, {}, profilePackageLessThan);
    lock.profile_packages = profile_packages.items;
    return lock;
}

pub const ProfileInput = struct {
    profile: []const u8,
    nodes: []const resolver.PackageNode,
};

/// feature 名を複製し、昇順ソートと重複除去を行う。同じ feature 集合から
/// 常に同じ lock バイト列を得るための正規化。
fn canonicalFeatures(allocator: Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| out[index] = try allocator.dupe(u8, item);
    std.mem.sort([]const u8, out, {}, stringLessThan);
    var unique_len: usize = 0;
    for (out) |item| {
        if (unique_len > 0 and std.mem.eql(u8, out[unique_len - 1], item)) continue;
        out[unique_len] = item;
        unique_len += 1;
    }
    return out[0..unique_len];
}

fn dupProfile(allocator: Allocator, record: ProfileRecord) !ProfileRecord {
    return .{
        .runtime = if (record.runtime) |value| try allocator.dupe(u8, value) else null,
        .os = try allocator.dupe(u8, record.os),
        .cpu = try allocator.dupe(u8, record.cpu),
        .abi = try allocator.dupe(u8, record.abi),
        .compat_js = record.compat_js,
        .optimize = if (record.optimize) |value| try allocator.dupe(u8, value) else null,
    };
}

// ---------------------------------------------------------------------------
// 複数 profile の共用 artifact 整合性
// ---------------------------------------------------------------------------

pub const SharedMismatch = struct {
    id: []const u8,
    version: []const u8,
    kind: []const u8,
};

/// 同一 id・同一 version の source artifact が複数 profile で同じ hash を
/// 参照しているかを検証する。lnako/cnako が共用する source は同じ ID・版・
/// hash で参照できなければならない。不一致があれば最初の組を返す。
fn packageSetAt(lock: *const Lock, index: usize) []const PackageEntry {
    if (index == 0) return lock.packages;
    return lock.profile_packages[index - 1].packages;
}

pub fn sharedArtifactMismatch(lock: *const Lock) ?SharedMismatch {
    const total = 1 + lock.profile_packages.len;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        for (packageSetAt(lock, i)) |package| {
            const source = package.artifact("source") orelse continue;
            var j: usize = i + 1;
            while (j < total) : (j += 1) {
                for (packageSetAt(lock, j)) |candidate| {
                    if (!std.mem.eql(u8, candidate.id, package.id)) continue;
                    if (!std.mem.eql(u8, candidate.version, package.version)) continue;
                    const other_source = candidate.artifact("source") orelse continue;
                    if (!sha256Eql(source.sha256, other_source.sha256)) {
                        return .{ .id = package.id, .version = package.version, .kind = "source" };
                    }
                }
            }
        }
    }
    return null;
}

test {
    _ = @import("lock_test.zig");
}
