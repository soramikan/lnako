const std = @import("std");
const diag = @import("diagnostics.zig");
const fetch = @import("fetch.zig");
const lock = @import("lock.zig");
const lock_model = @import("lock_model.zig");
const resolver = @import("resolver.zig");
const semver = @import("semver.zig");

const Allocator = std.mem.Allocator;

const Error = fetch.Error;
const Session = fetch.Session;

/// schema v1 静的 registry（PS01）の取得 provider。
///
/// レイアウト（SPECIFICATION.md §5.1）:
///   `<base>/index.json`                  package index
///   `<base>/<owner>/<name>.json`         package record
///   `<base>/<owner>/<name>/<version>.json` version record
///   artifact は record 内 `url` の静的配布
///
/// index の package record が versions を内包していればそれを使い、
/// 空なら package record を別途取得する。artifact の hash 照合・
/// 別 source への暗黙切替禁止・offline 制約は `fetch.Session` が担う。
pub const StaticRegistry = struct {
    session: *Session,
    /// 末尾 `/` を除いた registry base URL。
    base_url: []const u8,
    /// 解決対象の環境条件。`versionMeta` の artifact 可否判定に使う。
    target: resolver.Target = .{},
    /// 既存 lock の選択候補。`lockedVersion` の委譲先。null なら候補なし。
    locked: ?*const lock.LockedIndex = null,

    index: ?Index = null,
    /// `<owner>/<name>.json` の遅延取得 cache。同一 package を繰り返し
    /// 取得しない。キーは `owner/name`。値は session arena 確保のため
    /// map の成長で無効化されない。
    package_docs: std.StringHashMapUnmanaged(*const PackageDoc) = .empty,

    pub fn init(session: *Session, base_url: []const u8, target: resolver.Target) !StaticRegistry {
        const normalized = std.mem.trimEnd(u8, base_url, "/");
        if (normalized.len == 0) {
            return session.fail(.invalid_source, .index, base_url, "registry base url is empty", .{});
        }
        return .{
            .session = session,
            .base_url = try session.allocator().dupe(u8, normalized),
            .target = target,
        };
    }

    /// `package_docs` の map 領域を解放する。キー・値が指す内容は
    /// session arena が所有するため `session.deinit` で一括解放される。
    pub fn deinit(self: *StaticRegistry) void {
        self.package_docs.deinit(self.session.gpa);
    }

    /// `resolver.resolve` へ渡す provider。`id.pkg` は Public ID
    /// （`pkg:<hex>`）・`@owner/name`・`owner/name`・bare name のいずれか。
    pub fn provider(self: *StaticRegistry) resolver.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .listVersions = listVersions,
                .versionMeta = versionMeta,
                .lockedVersion = lockedVersion,
            },
        };
    }

    /// `lock.build`/`buildMulti` の `DetailsSource`。
    pub fn detailsSource(self: *StaticRegistry) lock.DetailsSource {
        return .{ .context = self, .getFn = getDetails };
    }

    // ---------------------------------------------------------------------
    // registry document
    // ---------------------------------------------------------------------

    fn loadIndex(self: *StaticRegistry) Error!*const Index {
        if (self.index) |*index| return index;
        const url = try std.fmt.allocPrint(self.session.allocator(), "{s}/index.json", .{self.base_url});
        const bytes = try fetch.fetchBytes(self.session, url, .index);
        const parsed = parseIndex(self.session, bytes, url) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidMetadata => return error.InvalidMetadata,
            else => return err,
        };
        self.index = parsed;
        return &self.index.?;
    }

    /// package の version 一覧を返す。index の record に versions が内包
    /// されていればそれを使い、空なら `<owner>/<name>.json` を取得する。
    /// 返すポインタは session arena が所有する。
    fn loadPackageDoc(self: *StaticRegistry, package: *const PackageRecord) Error!*const PackageDoc {
        const gpa = self.session.allocator();
        // index 内包 versions は取得不要なので cache せず arena に複製する。
        if (package.versions.len > 0) {
            const embedded = try gpa.create(PackageDoc);
            embedded.* = .{ .record = package.*, .versions = package.versions };
            return embedded;
        }

        const key = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ package.owner, package.name });
        if (self.package_docs.get(key)) |doc| return doc;
        const url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}.json", .{ self.base_url, package.owner, package.name });
        const bytes = try fetch.fetchBytes(self.session, url, .package);
        const doc = try gpa.create(PackageDoc);
        doc.* = try parsePackageDoc(self.session, bytes, url);
        // package record は index entry の静的 metadata（id・name・owner・
        // humanId）と一致しなければならない。ID だけ一致させて別名や別 owner
        // の record を混在させない。
        const record_matches = std.mem.eql(u8, doc.record.id, package.id) and
            std.mem.eql(u8, doc.record.name, package.name) and
            std.mem.eql(u8, doc.record.owner, package.owner) and
            optEqlOpt(doc.record.human_id, package.human_id);
        if (!record_matches) {
            return self.session.failCode(.invalid_metadata, .package, url, diag.E010_REGISTRY_RECORD_MISMATCH, "package record \"{s}\" does not match index entry {s} ({s}/{s})", .{ url, package.id, package.owner, package.name });
        }
        try self.package_docs.put(self.session.gpa, key, doc);
        return doc;
    }

    fn findPackage(self: *StaticRegistry, name: []const u8) Error!*const PackageRecord {
        const index = try self.loadIndex();
        var found: ?*const PackageRecord = null;
        for (index.packages.items) |*package| {
            const matches = std.mem.eql(u8, package.id, name) or
                optEql(package.human_id, name) or
                std.mem.eql(u8, package.name, name) or
                (std.mem.indexOfScalar(u8, name, '/') != null and
                    std.mem.eql(u8, try std.fmt.allocPrint(self.session.allocator(), "{s}/{s}", .{ package.owner, package.name }), name));
            if (!matches) continue;
            if (found != null and !std.mem.eql(u8, found.?.id, package.id)) {
                return self.session.fail(.invalid_metadata, .index, name, "package name \"{s}\" is ambiguous across registry entries", .{name});
            }
            found = package;
        }
        return found orelse self.session.fail(.not_found, .package, name, "package \"{s}\" is not in the registry index", .{name});
    }

    /// `version` の record を返す。package record の versions に無い場合は
    /// PS01 layout の個別 version record `<owner>/<name>/<version>.json` を
    /// 参照する（offline では取得できないため not_found）。
    /// 返すポインタは session arena が所有する。
    fn findVersion(self: *StaticRegistry, package: *const PackageRecord, version: resolver.Version) Error!*const VersionRecord {
        const doc = try self.loadPackageDoc(package);
        var text_buffer: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&text_buffer);
        version.format(&writer) catch return error.InvalidMetadata;
        const text = writer.buffered();
        for (doc.versions) |*record| {
            if (std.mem.eql(u8, record.version, text)) return record;
        }
        if (self.session.policy.offline) {
            return self.session.fail(.not_found, .version, text, "version {s} of \"{s}\" is not in the registry", .{ text, package.name });
        }
        const gpa = self.session.allocator();
        const url = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}.json", .{ self.base_url, package.owner, package.name, text });
        const bytes = try fetch.fetchBytes(self.session, url, .version);
        var parser = JsonParser{ .session = self.session, .url = url, .resource = .version };
        const record = try gpa.create(VersionRecord);
        record.* = try parseVersionRecord(&parser, try parseJson(self.session, bytes, url, .version));
        if (!std.mem.eql(u8, record.version, text)) {
            return self.session.failCode(.invalid_metadata, .version, url, diag.E010_REGISTRY_RECORD_MISMATCH, "version record \"{s}\" declares version {s}, expected {s}", .{ url, record.version, text });
        }
        return record;
    }

    // ---------------------------------------------------------------------
    // resolver.Provider 実装
    // ---------------------------------------------------------------------

    fn listVersions(ptr: *anyopaque, gpa: Allocator, id: resolver.PackageId) anyerror![]const resolver.Version {
        const self: *StaticRegistry = @ptrCast(@alignCast(ptr));
        const name = switch (id) {
            .pkg => |pkg| pkg,
            .npm => return error.PackageNotFound,
        };
        const package = self.findPackage(name) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            error.NotFound => return error.PackageNotFound,
            // offline・timeout・破損などの取得失敗は「存在しない」ではなく
            // 原因付きの失敗として呼出側へ伝播させる。
            else => return err,
        };
        const doc = self.loadPackageDoc(package) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            error.NotFound => return error.PackageNotFound,
            else => return err,
        };
        var versions: std.ArrayList(resolver.Version) = .empty;
        for (doc.versions) |*record| {
            const version = resolver.Version.parse(record.version) catch continue;
            try versions.append(gpa, version);
        }
        return versions.items;
    }

    fn versionMeta(ptr: *anyopaque, gpa: Allocator, id: resolver.PackageId, version: resolver.Version) anyerror!resolver.VersionMeta {
        const self: *StaticRegistry = @ptrCast(@alignCast(ptr));
        const name = switch (id) {
            .pkg => |pkg| pkg,
            .npm => return .{ .unavailable_reason = "npm dependencies are not served by the static registry provider" },
        };
        const package = self.findPackage(name) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            error.NotFound => return .{ .unavailable_reason = "package is not in the registry" },
            else => return err,
        };
        const record = self.findVersion(package, version) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            error.NotFound => return .{ .unavailable_reason = "version is not in the registry" },
            else => return err,
        };

        var deps: std.ArrayList(resolver.Dependency) = .empty;
        for (record.dependencies) |dep_id| {
            try deps.append(gpa, .{
                .id = .{ .pkg = dep_id },
                .constraint = .any,
            });
        }
        var features: std.ArrayList(resolver.FeatureDefinition) = .empty;
        for (record.features) |name_text| {
            try features.append(gpa, .{ .name = name_text, .items = &.{} });
        }

        var meta = resolver.VersionMeta{
            .dependencies = deps.items,
            .features = features.items,
        };
        for (record.artifacts) |artifact| {
            if (std.mem.eql(u8, artifact.kind, "source")) meta.has_source = true;
            if (std.mem.eql(u8, artifact.kind, "native")) meta.has_native = true;
            if (std.mem.eql(u8, artifact.kind, "ESM")) meta.has_esm = true;
        }
        if (record.yanked) {
            meta.unavailable_reason = "version is yanked";
        } else if (resolver.chooseImplementation(meta, self.target, false) == .none) {
            meta.unavailable_reason = "package has no implementation for the requested runtime";
        }
        return meta;
    }

    fn lockedVersion(ptr: *anyopaque, id: resolver.PackageId) ?resolver.Version {
        const self: *StaticRegistry = @ptrCast(@alignCast(ptr));
        const index = self.locked orelse return null;
        return index.get(id);
    }

    // ---------------------------------------------------------------------
    // lock.DetailsSource 実装
    // ---------------------------------------------------------------------

    fn getDetails(context: *anyopaque, gpa: Allocator, id: []const u8, version: []const u8) anyerror!?lock.PackageDetails {
        const self: *StaticRegistry = @ptrCast(@alignCast(context));
        _ = gpa;
        const package = self.findPackage(id) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            error.NotFound => return null,
            else => return err,
        };
        const parsed = resolver.Version.parse(version) catch return null;
        const record = self.findVersion(package, parsed) catch |err| switch (err) {
            error.OutOfMemory, error.Canceled => return err,
            error.NotFound => return null,
            else => return err,
        };
        const session_alloc = self.session.allocator();
        const url = try std.fmt.allocPrint(session_alloc, "{s}/{s}/{s}", .{ self.base_url, package.owner, package.name });
        const source = lock_model.Source{ .kind = .static, .url = url };

        var artifacts: std.ArrayList(lock_model.Artifact) = .empty;
        for (record.artifacts) |artifact| {
            try artifacts.append(session_alloc, .{
                .key = try session_alloc.dupe(u8, artifact.key),
                .kind = artifact.kind,
                .type = artifact.type,
                .sha256 = artifact.sha256,
                .url = artifact.url,
            });
        }
        return lock.PackageDetails{
            .public_id = package.id,
            .name = package.name,
            .source = source,
            .resolved_from = source,
            .artifacts = artifacts.items,
        };
    }

    // ---------------------------------------------------------------------
    // artifact 取得
    // ---------------------------------------------------------------------

    /// version の artifact record を取得し、宣言された sha256 と照合して
    /// bytes を返す。戻り値は session arena が所有する。
    pub fn acquireArtifact(self: *StaticRegistry, name: []const u8, version_text: []const u8, key: []const u8) Error!AcquiredArtifact {
        const package = try self.findPackage(name);
        const version = resolver.Version.parse(version_text) catch
            return self.session.fail(.invalid_source, .version, version_text, "invalid version \"{s}\"", .{version_text});
        const record = try self.findVersion(package, version);
        for (record.artifacts) |artifact| {
            if (!std.mem.eql(u8, artifact.key, key)) continue;
            const url = artifact.url orelse
                return self.session.fail(.invalid_metadata, .artifact, key, "artifact \"{s}\" of {s}@{s} has no url", .{ key, name, version_text });
            const bytes = try fetch.fetchBytes(self.session, url, .artifact);
            if (artifact.sha256) |expected| {
                try fetch.verifyHash(self.session, bytes, expected, url, .artifact);
            }
            const actual = try fetch.sha256Hex(self.session.allocator(), bytes);
            return .{
                .key = artifact.key,
                .kind = artifact.kind,
                .type = artifact.type,
                .sha256 = actual,
                .bytes = bytes,
            };
        }
        return self.session.fail(.not_found, .artifact, key, "artifact \"{s}\" of {s}@{s} is not declared", .{ key, name, version_text });
    }
};

pub const AcquiredArtifact = struct {
    key: []const u8,
    kind: []const u8,
    type: ?[]const u8,
    /// 実測 SHA-256（64 桁 hex）。
    sha256: []const u8,
    bytes: []const u8,
};

fn optEql(a: ?[]const u8, b: []const u8) bool {
    const value = a orelse return false;
    return std.mem.eql(u8, value, b);
}

fn optEqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    const value_a = a orelse return false;
    const value_b = b orelse return false;
    return std.mem.eql(u8, value_a, value_b);
}

// ---------------------------------------------------------------------------
// schema v1 registry document の解析
// ---------------------------------------------------------------------------

pub const ArtifactRecord = struct {
    key: []const u8,
    kind: []const u8,
    type: ?[]const u8 = null,
    sha256: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const VersionRecord = struct {
    version: []const u8,
    manifest_hash: ?[]const u8 = null,
    yanked: bool = false,
    dependencies: []const []const u8 = &.{},
    features: []const []const u8 = &.{},
    artifacts: []const ArtifactRecord = &.{},
};

pub const PackageRecord = struct {
    id: []const u8,
    name: []const u8,
    owner: []const u8,
    human_id: ?[]const u8 = null,
    versions: []const VersionRecord = &.{},
};

pub const Index = struct {
    packages: std.ArrayList(PackageRecord) = .empty,
};

const PackageDoc = struct {
    record: PackageRecord,
    versions: []const VersionRecord,
};

const JsonParser = struct {
    session: *Session,
    url: []const u8,
    /// 解析中の document 種別（失敗記録の resource として使う）。
    resource: fetch.ResourceKind,

    fn invalid(self: *JsonParser, comptime fmt: []const u8, args: anytype) Error {
        return self.session.fail(.invalid_metadata, self.resource, self.url, fmt, args);
    }

    fn invalidCode(self: *JsonParser, code: []const u8, comptime fmt: []const u8, args: anytype) Error {
        return self.session.failCode(.invalid_metadata, self.resource, self.url, code, fmt, args);
    }

    /// schema の `additionalProperties: false` を適用する。
    fn rejectUnknownFields(self: *JsonParser, object: std.json.ObjectMap, allowed: []const []const u8) Error!void {
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            for (allowed) |field| {
                if (std.mem.eql(u8, key, field)) break;
            } else {
                return self.invalidCode(diag.E022_UNKNOWN_FIELD, "registry field \"{s}\" is not defined by the schema", .{key});
            }
        }
    }

    fn asObject(self: *JsonParser, value: std.json.Value) Error!std.json.ObjectMap {
        return switch (value) {
            .object => |object| object,
            else => self.invalidCode(diag.E023_INVALID_TYPE, "registry document must be an object", .{}),
        };
    }

    fn asString(self: *JsonParser, value: std.json.Value, field: []const u8) Error![]const u8 {
        return switch (value) {
            .string => |text| text,
            else => self.invalidCode(diag.E023_INVALID_TYPE, "registry field \"{s}\" must be a string", .{field}),
        };
    }

    fn requiredString(self: *JsonParser, object: std.json.ObjectMap, field: []const u8) Error![]const u8 {
        const value = object.get(field) orelse
            return self.invalidCode(diag.E019_REQUIRED_FIELD_MISSING, "registry document is missing required field \"{s}\"", .{field});
        return self.asString(value, field);
    }

    fn optionalString(self: *JsonParser, object: std.json.ObjectMap, field: []const u8) Error!?[]const u8 {
        const value = object.get(field) orelse return null;
        if (value == .null) return null;
        return try self.asString(value, field);
    }
};

fn parseJson(session: *Session, bytes: []const u8, url: []const u8, resource: fetch.ResourceKind) Error!std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, session.allocator(), bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return session.fail(.invalid_metadata, resource, url, "registry document at \"{s}\" is not valid JSON", .{url}),
    };
    return parsed.value;
}

fn checkSchemaVersion(parser: *JsonParser, object: std.json.ObjectMap) Error!void {
    const value = object.get("schemaVersion") orelse
        return parser.invalidCode(diag.E019_REQUIRED_FIELD_MISSING, "registry document is missing required field \"schemaVersion\"", .{});
    const version = switch (value) {
        .integer => |number| number,
        else => return parser.invalidCode(diag.E023_INVALID_TYPE, "registry field \"schemaVersion\" must be an integer", .{}),
    };
    if (version != 1) {
        return parser.invalid("registry schema version {d} is not supported", .{version});
    }
}

/// `pkg:<32桁小文字hex>` の Public ID 形式。
fn isPublicId(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "pkg:")) return false;
    const hex = text[4..];
    if (hex.len != 32) return false;
    for (hex) |byte| {
        if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

/// `^[a-z][a-z0-9-]{0,63}$` の package 名形式。
fn isPackageName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    if (text[0] < 'a' or text[0] > 'z') return false;
    for (text[1..]) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or std.ascii.isDigit(byte) or byte == '-')) return false;
    }
    return true;
}

/// `^@[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$` の人間向け ID 形式。
fn isHumanId(text: []const u8) bool {
    if (text.len < 3 or text[0] != '@') return false;
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return false;
    const owner = text[1..slash];
    const name = text[slash + 1 ..];
    if (owner.len == 0 or name.len == 0) return false;
    for (owner) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '-')) return false;
    }
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '-')) return false;
    }
    return true;
}

/// `^[a-z][a-z0-9-]+$` の feature 名形式。
fn isFeatureName(text: []const u8) bool {
    if (text.len < 2) return false;
    if (text[0] < 'a' or text[0] > 'z') return false;
    for (text[1..]) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or std.ascii.isDigit(byte) or byte == '-')) return false;
    }
    return true;
}

/// `hash` 定義の表現形式（sha256/sha512 の `<alg>-<base64>`・`<alg>:<hex>`）。
/// raw 64hex は registry schema 側では `sha256Hash` 用で artifact/manifest
/// hash には許可しない。
fn isHashFormat(text: []const u8) bool {
    const is_hex = struct {
        fn check(hex: []const u8) bool {
            for (hex) |byte| {
                if (!(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'))) return false;
            }
            return true;
        }
    }.check;
    const is_b64 = struct {
        /// schema regex の `[A-Za-z0-9+/]{43}=` / `{86}=` 形に合わせ、`=` は
        /// 末尾1文字のみ許可する（途中の `=` を含む文字列は受理しない）。
        fn check(encoded: []const u8) bool {
            if (encoded.len == 0 or encoded[encoded.len - 1] != '=') return false;
            for (encoded[0 .. encoded.len - 1]) |byte| {
                if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '/')) return false;
            }
            return true;
        }
    }.check;
    if (std.mem.startsWith(u8, text, "sha256:")) return text.len == 7 + 64 and is_hex(text[7..]);
    if (std.mem.startsWith(u8, text, "sha512:")) return text.len == 7 + 128 and is_hex(text[7..]);
    if (std.mem.startsWith(u8, text, "sha256-")) return text.len == 7 + 44 and is_b64(text[7..]);
    if (std.mem.startsWith(u8, text, "sha512-")) return text.len == 7 + 88 and is_b64(text[7..]);
    return false;
}

/// `format: "uri"` の最低限の検証。絶対 URI（scheme 必須）で空白・
/// 制御文字を含まないこと（SPECIFICATION.md §3.4.4）。
fn isUri(text: []const u8) bool {
    if (text.len == 0) return false;
    const uri = std.Uri.parse(text) catch return false;
    if (uri.scheme.len == 0) return false;
    for (text) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return false;
    }
    return true;
}

const index_fields = [_][]const u8{ "schemaVersion", "packages" };
const package_fields = [_][]const u8{ "schemaVersion", "id", "name", "owner", "humanId", "description", "license", "repository", "homepage", "versions" };
const version_fields = [_][]const u8{ "schemaVersion", "version", "manifestHash", "yanked", "dependencies", "features", "artifacts" };
const artifact_fields = [_][]const u8{ "kind", "type", "sha256", "url" };
const artifact_types = [_][]const u8{ "tar.gz", ".npkg", "raw", "npm-tarball" };

fn parseVersionRecord(parser: *JsonParser, value: std.json.Value) Error!VersionRecord {
    const object = try parser.asObject(value);
    try parser.rejectUnknownFields(object, &version_fields);
    try checkSchemaVersion(parser, object);
    const version_text = try parser.requiredString(object, "version");
    _ = semver.Version.parse(version_text) catch
        return parser.invalidCode(diag.E024_INVALID_SEMVER, "registry version \"{s}\" is not valid semver", .{version_text});
    const manifest_hash = try parser.requiredString(object, "manifestHash");
    if (!isHashFormat(manifest_hash)) {
        return parser.invalid("registry manifestHash \"{s}\" is not a supported hash notation", .{manifest_hash});
    }

    var dependencies: std.ArrayList([]const u8) = .empty;
    if (object.get("dependencies")) |deps_value| {
        const array = switch (deps_value) {
            .array => |items| items,
            else => return parser.invalidCode(diag.E023_INVALID_TYPE, "registry field \"dependencies\" must be an array", .{}),
        };
        for (array.items) |item| {
            const dep = try parser.asString(item, "dependencies");
            if (!isPublicId(dep)) {
                return parser.invalid("registry dependency \"{s}\" is not a public id", .{dep});
            }
            try dependencies.append(parser.session.allocator(), dep);
        }
    }

    var features: std.ArrayList([]const u8) = .empty;
    if (object.get("features")) |features_value| {
        const array = switch (features_value) {
            .array => |items| items,
            else => return parser.invalidCode(diag.E023_INVALID_TYPE, "registry field \"features\" must be an array", .{}),
        };
        for (array.items) |item| {
            const feature = try parser.asString(item, "features");
            if (!isFeatureName(feature)) {
                return parser.invalid("registry feature \"{s}\" is not a valid feature name", .{feature});
            }
            try features.append(parser.session.allocator(), feature);
        }
    }

    var artifacts: std.ArrayList(ArtifactRecord) = .empty;
    if (object.get("artifacts")) |artifacts_value| {
        const map = switch (artifacts_value) {
            .object => |items| items,
            else => return parser.invalidCode(diag.E023_INVALID_TYPE, "registry field \"artifacts\" must be an object", .{}),
        };
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            const artifact_object = try parser.asObject(entry.value_ptr.*);
            try parser.rejectUnknownFields(artifact_object, &artifact_fields);
            const kind = try parser.requiredString(artifact_object, "kind");
            const artifact_type = try parser.optionalString(artifact_object, "type");
            if (artifact_type) |type_text| {
                var known = false;
                for (artifact_types) |allowed| {
                    if (std.mem.eql(u8, type_text, allowed)) known = true;
                }
                if (!known) {
                    return parser.invalid("registry artifact type \"{s}\" is not a known type", .{type_text});
                }
            }
            const artifact_hash = try parser.optionalString(artifact_object, "sha256");
            if (artifact_hash) |hash| {
                if (!isHashFormat(hash)) {
                    return parser.invalid("registry artifact sha256 \"{s}\" is not a supported hash notation", .{hash});
                }
            }
            const artifact_url = try parser.optionalString(artifact_object, "url");
            if (artifact_url) |artifact_uri| {
                if (!isUri(artifact_uri)) {
                    return parser.invalid("registry artifact url \"{s}\" is not an absolute uri", .{artifact_uri});
                }
                // artifact 取得は HTTP(S) のみ。file:・gopher: 等の scheme へ
                // registry metadata から誘導されないよう限定する。
                const parsed_uri = std.Uri.parse(artifact_uri) catch unreachable;
                if (!std.mem.eql(u8, parsed_uri.scheme, "http") and !std.mem.eql(u8, parsed_uri.scheme, "https")) {
                    return parser.invalid("registry artifact url \"{s}\" must use http or https", .{artifact_uri});
                }
            }
            try artifacts.append(parser.session.allocator(), .{
                .key = entry.key_ptr.*,
                .kind = kind,
                .type = artifact_type,
                .sha256 = artifact_hash,
                .url = artifact_url,
            });
        }
    }

    var yanked = false;
    if (object.get("yanked")) |yanked_value| {
        yanked = switch (yanked_value) {
            .bool => |flag| flag,
            else => return parser.invalidCode(diag.E023_INVALID_TYPE, "registry field \"yanked\" must be a boolean", .{}),
        };
    }

    return .{
        .version = version_text,
        .manifest_hash = manifest_hash,
        .yanked = yanked,
        .dependencies = dependencies.items,
        .features = features.items,
        .artifacts = artifacts.items,
    };
}

fn parsePackageRecord(parser: *JsonParser, value: std.json.Value) Error!PackageRecord {
    const object = try parser.asObject(value);
    try parser.rejectUnknownFields(object, &package_fields);
    try checkSchemaVersion(parser, object);
    const id = try parser.requiredString(object, "id");
    if (!isPublicId(id)) {
        return parser.invalid("registry package id \"{s}\" is not a public id", .{id});
    }
    const name = try parser.requiredString(object, "name");
    if (!isPackageName(name)) {
        return parser.invalid("registry package name \"{s}\" is not a valid package name", .{name});
    }
    const owner = try parser.requiredString(object, "owner");
    const human_id = try parser.optionalString(object, "humanId");
    if (human_id) |hid| {
        if (!isHumanId(hid)) {
            return parser.invalid("registry humanId \"{s}\" is not a valid human id", .{hid});
        }
    }

    const versions_value = object.get("versions") orelse
        return parser.invalidCode(diag.E019_REQUIRED_FIELD_MISSING, "registry document is missing required field \"versions\"", .{});
    const array = switch (versions_value) {
        .array => |items| items,
        else => return parser.invalidCode(diag.E023_INVALID_TYPE, "registry field \"versions\" must be an array", .{}),
    };
    var versions: std.ArrayList(VersionRecord) = .empty;
    for (array.items) |item| {
        try versions.append(parser.session.allocator(), try parseVersionRecord(parser, item));
    }
    return .{
        .id = id,
        .name = name,
        .owner = owner,
        .human_id = human_id,
        .versions = versions.items,
    };
}

/// `index.json` を解析する。同一 Public ID の重複は静的 metadata の
/// 衝突（`E012_ALIAS_COLLISION`）として拒否する。
pub fn parseIndex(session: *Session, bytes: []const u8, url: []const u8) Error!Index {
    var parser = JsonParser{ .session = session, .url = url, .resource = .index };
    const root = try parser.asObject(try parseJson(session, bytes, url, .index));
    try parser.rejectUnknownFields(root, &index_fields);
    try checkSchemaVersion(&parser, root);
    const packages_value = root.get("packages") orelse
        return parser.invalidCode(diag.E019_REQUIRED_FIELD_MISSING, "registry index is missing required field \"packages\"", .{});
    const array = switch (packages_value) {
        .array => |items| items,
        else => return parser.invalidCode(diag.E023_INVALID_TYPE, "registry field \"packages\" must be an array", .{}),
    };
    var index = Index{};
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (array.items) |item| {
        const record = try parsePackageRecord(&parser, item);
        const gop = try seen.getOrPut(session.allocator(), record.id);
        if (gop.found_existing) {
            return session.failCode(.invalid_metadata, .index, url, diag.E012_ALIAS_COLLISION, "duplicate package id {s} in registry index", .{record.id});
        }
        try index.packages.append(session.allocator(), record);
    }
    return index;
}

/// `<owner>/<name>.json` を解析する。
pub fn parsePackageDoc(session: *Session, bytes: []const u8, url: []const u8) Error!PackageDoc {
    var parser = JsonParser{ .session = session, .url = url, .resource = .package };
    const record = try parsePackageRecord(&parser, try parseJson(session, bytes, url, .package));
    return .{ .record = record, .versions = record.versions };
}
