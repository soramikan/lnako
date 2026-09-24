const std = @import("std");

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
/// profile / target が受理する OS。`manifest.zig` の検証集合と揃える。
pub const known_profile_os = [_][]const u8{ "macos", "linux", "windows" };
/// profile / target が受理する CPU。
pub const known_profile_cpu = [_][]const u8{ "aarch64", "x86_64", "arm", "wasm32" };
/// profile / target が受理する ABI。
pub const known_profile_abi = [_][]const u8{ "gnu", "msvc", "musl", "none" };
/// profile が受理する最適化レベル。
pub const known_optimize = [_][]const u8{ "O0", "O1", "O2", "O3" };

// ---------------------------------------------------------------------------
// データモデル
// ---------------------------------------------------------------------------

/// `input.target`。OS/CPU/ABI と、実装選択を変え得る `--compat-js` の
/// 有効状態を固定する。profile 宣言の `compat-js` は profile record が持つ。
pub const Target = struct {
    os: []const u8,
    cpu: []const u8,
    abi: []const u8,
    /// `--compat-js` / profile の `compat-js` で ESM 実装を許容したか。
    /// 実装選択を変え得るため鮮度鍵に含める。false は省略して記録する
    /// （旧 lock は欠落 → false と同等）。
    compat_js: bool = false,

    pub fn eql(a: Target, b: Target) bool {
        return std.mem.eql(u8, a.os, b.os) and std.mem.eql(u8, a.cpu, b.cpu) and std.mem.eql(u8, a.abi, b.abi) and
            a.compat_js == b.compat_js;
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

/// `mutable = true` path 依存の内容 digest。mutable は宣言 dir を生参照
/// する契約のため、manifest だけでなく exports・commands・推移的宣言を
/// 含む内容変更を鮮度入力として記録する。pin（`mutable = false`）と違い
/// 変更自体は許容するが、変更時の lock・環境再生成を駆動する。
pub const MutablePath = struct {
    /// lock `source.path`（project 相対または絶対 path、正規化済み）。
    path: []const u8,
    /// 依存 dir の tree digest（`sha256:<hex>`、`.nako`/`.git` 除外）。
    sha256: []const u8,
};

pub const Input = struct {
    manifest_sha256: []const u8,
    profile: []const u8,
    features: []const []const u8 = &.{},
    target: Target,
    /// 解決に使った runtime と engines 照合 version。`--runtime` の
    /// 切替やコンパイラ更新は package 選択を変え得るため鮮度鍵に
    /// 含める。これらを記録しない旧 lock は欠落（null）となり、
    /// 比較で不一致 → 再解決される。
    runtime: ?[]const u8 = null,
    nako_version: ?[]const u8 = null,
    cnako_version: ?[]const u8 = null,
    lnako_version: ?[]const u8 = null,
    /// mutable path 依存の内容 digest（path 昇順）。`mutable` が無い
    /// lock では空。
    mutable_paths: []const MutablePath = &.{},

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

pub fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// SHA-256 の各表記（SRI `sha256-<base64>=`、`sha256:<hex>`、生 `<hex>`）を
/// 32 バイトへ正規化する。解釈できない場合は false。
pub fn normalizeSha256(text: []const u8, out: *[32]u8) bool {
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

pub fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

pub fn uniqueCount(items: []const []const u8) usize {
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

pub const stringLessThan = struct {
    fn lt(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }
}.lt;

pub const packageLessThan = struct {
    fn lt(_: void, a: PackageEntry, b: PackageEntry) bool {
        return std.mem.order(u8, a.id, b.id) == .lt;
    }
}.lt;

pub const profilePackageLessThan = struct {
    fn lt(_: void, a: ProfilePackages, b: ProfilePackages) bool {
        return std.mem.order(u8, a.profile, b.profile) == .lt;
    }
}.lt;

pub const namedProfileLessThan = struct {
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
    if (target.compat_js) try writer.writeAll(", \"compatJs\": true");
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
///
/// 決定性の保証範囲は「同じ入力から `build`/`buildPackages` が生成した
/// モデル」である。これらは package マップ・profile・features・依存辺・
/// artifact をソートして保持する。`Lock` を直接構築または外部 parser で
/// 組み立てた場合、`serialize` はモデルのスライス順をそのまま出力するため、
/// 意味的に同じでもスライス順が異なれば SHA-256 も異なり得る。手動構築時は
/// スライスを正規化するか、`build` 経由で生成すること。
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
    const version_fields = [_]struct { key: []const u8, value: ?[]const u8 }{
        .{ .key = "runtime", .value = lock.input.runtime },
        .{ .key = "nakoVersion", .value = lock.input.nako_version },
        .{ .key = "cnakoVersion", .value = lock.input.cnako_version },
        .{ .key = "lnakoVersion", .value = lock.input.lnako_version },
    };
    for (version_fields) |field| {
        if (field.value) |value| {
            try writer.writeAll(",\n");
            try writeIndent(writer, 2);
            try writer.print("\"{s}\": ", .{field.key});
            try writeString(writer, value);
        }
    }
    if (lock.input.mutable_paths.len > 0) {
        try writer.writeAll(",\n");
        try writeIndent(writer, 2);
        try writer.writeAll("\"mutablePaths\": [");
        for (lock.input.mutable_paths, 0..) |mutable, index| {
            if (index > 0) try writer.writeAll(", ");
            try writer.writeAll("{\"path\": ");
            try writeString(writer, mutable.path);
            try writer.writeAll(", \"sha256\": ");
            try writeString(writer, mutable.sha256);
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
    }
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

fn stringListEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |item, index| {
        if (!std.mem.eql(u8, item, b[index])) return false;
    }
    return true;
}

pub fn sourceOptEql(a: ?Source, b: ?Source) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return Source.eql(a.?, b.?);
}

pub fn artifactEql(a: Artifact, b: Artifact) bool {
    return std.mem.eql(u8, a.key, b.key) and
        std.mem.eql(u8, a.kind, b.kind) and
        optEql(a.type, b.type) and
        optEql(a.sha256, b.sha256) and
        optEql(a.url, b.url);
}

pub fn peerDependencyEql(a: PeerDependency, b: PeerDependency) bool {
    return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.requirement, b.requirement);
}

pub fn npmInstanceEql(a: NpmInstance, b: NpmInstance) bool {
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

pub fn packageEntryEql(a: PackageEntry, b: PackageEntry) bool {
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
pub fn packageMapsEql(a: []const PackageEntry, b: []const PackageEntry) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.id, b[index].id)) return false;
        if (!packageEntryEql(entry, b[index])) return false;
    }
    return true;
}

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
