//! v1 `nako.lock`（プロファイルごとの解決済み依存グラフ）。
//!
//! 仕様 v1 §6.4 は「プロファイルごとに、各ノードの Package ID・版・選択した
//! アーティファクトの SHA-256 を固定し、同じ ID の複数版を区別する」ことだけを
//! 定める。ここではその内容を次の決定的 JSON として具体化する。
//!
//! ```json
//! {
//!   "schema_version": 1,
//!   "profiles": [{
//!     "name": "default",
//!     "runtime": "lnako",
//!     "target_triple": "aarch64-macos-none",
//!     "nodes": [{"key":"@acme/json@1.0.0","id":"@acme/json","version":"1.0.0",
//!                "sha256":"sha256:…","kind":"universal","global":false}],
//!     "root":  [{"to":"…","id":"…","req":"^1.0.0", …}],
//!     "edges": [{"from":"…","to":"…","id":"…","req":"^1.0.0", …}]
//!   }]
//! }
//! ```
//!
//! ノードキーは `{id}@{version}`。同じ ID の複数版を別ノードとして保持し、
//! `root` と `edges` はノードキーで参照する。`root` は直接依存の宣言、`edges`
//! は各依存を宣言したノードからの辺で、どちらも alias・features・
//! `allow_global_commands` を保持する。これは §6.1 の「alias と許可は宣言した
//! パッケージのスコープにだけ適用し、別の依存へ継承しない」を後段の命令登録が
//! 再現できるようにするため。
//!
//! 旧 lock（`schemaVersion` を持つ JSON）は読み替えない。`parse` は
//! `error.LegacyLock` を返し、`legacyMessage()` が再作成の案内を示す。この
//! モジュールはファイルを書き換えない。書き込みは呼出し側が
//! `toBytes`/`write` の結果を使う。

const std = @import("std");
const types = @import("v1_types.zig");
const semver = @import("semver.zig");

const Allocator = std.mem.Allocator;

pub const schema_version: u32 = 1;

pub const Error = error{
    OutOfMemory,
    LegacyLock,
    UnsupportedVersion,
    InvalidLock,
    MissingArtifact,
};

pub const Node = struct {
    key: []const u8,
    id: []const u8,
    version: []const u8,
    sha256: []const u8,
    kind: types.Kind,
    global: bool,
};

pub const Edge = struct {
    /// `null` はルート（直接依存）からの辺。
    from: ?[]const u8 = null,
    to: []const u8,
    id: []const u8,
    req: []const u8,
    alias: ?[]const u8 = null,
    features: []const []const u8 = &.{},
    default_features: bool = true,
    optional: bool = false,
    allow_global_commands: bool = false,
    runtimes: []const types.Runtime = &.{},
};

pub const Profile = struct {
    name: []const u8,
    runtime: types.Runtime,
    target_triple: ?[]const u8 = null,
    nodes: []const Node,
    root: []const Edge,
    edges: []const Edge,
};

pub const Lock = struct {
    arena: std.heap.ArenaAllocator,
    schema_version: u32 = schema_version,
    profiles: []const Profile,

    pub fn deinit(self: *Lock) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findProfile(self: *const Lock, name: []const u8) ?*const Profile {
        for (self.profiles) |*profile| {
            if (std.mem.eql(u8, profile.name, name)) return profile;
        }
        return null;
    }
};

/// 旧 lock を検出したときの診断。実装は読み替えも書き換えもしない。
pub fn legacyMessage() []const u8 {
    return "旧形式の nako.lock です。schema_version = 1 の新しい nako.lock を再作成してください。旧 lock の自動変換は行いません。";
}

// ---------------------------------------------------------------------------
// 構築
// ---------------------------------------------------------------------------

pub const NodeRef = struct {
    id: []const u8,
    version: []const u8,
};

pub const GraphNode = struct {
    id: []const u8,
    version: []const u8,
    sha256: []const u8,
    kind: types.Kind,
    global: bool,
};

pub const GraphEdge = struct {
    from: ?NodeRef = null,
    to: NodeRef,
    id: []const u8,
    req: []const u8,
    alias: ?[]const u8 = null,
    features: []const []const u8 = &.{},
    default_features: bool = true,
    optional: bool = false,
    allow_global_commands: bool = false,
    runtimes: []const types.Runtime = &.{},
};

pub const GraphInput = struct {
    profile: []const u8,
    runtime: types.Runtime,
    target_triple: ?[]const u8 = null,
    nodes: []const GraphNode,
    root: []const GraphEdge,
    edges: []const GraphEdge,
};

fn nodeKey(allocator: Allocator, id: []const u8, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}@{s}", .{ id, version });
}

/// `GraphInput` から新しい lock を一度だけ構築する。ノードと辺はキー順に
/// 正規化する。ハッシュが空、または ID・版・ハッシュが不正なら
/// `error.MissingArtifact`/`error.InvalidLock` を返す。
pub fn fromGraph(parent: Allocator, input: GraphInput) Error!Lock {
    const inputs = [_]GraphInput{input};
    return fromGraphs(parent, &inputs);
}

/// 複数プロファイル分の `GraphInput` を一つの lock にまとめる。プロファイルは
/// 名前順に正規化する。同じ名前のプロファイルが二つあれば拒否する。
pub fn fromGraphs(parent: Allocator, inputs: []const GraphInput) Error!Lock {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    if (inputs.len == 0) return error.InvalidLock;

    var profiles: std.ArrayList(Profile) = .empty;
    for (inputs) |input| {
        try profiles.append(allocator, try buildProfile(allocator, input));
    }
    std.mem.sort(Profile, profiles.items, {}, profileLessThan);
    try requireUniqueProfiles(profiles.items);
    return .{ .arena = arena, .profiles = try profiles.toOwnedSlice(allocator) };
}

fn buildProfile(allocator: Allocator, input: GraphInput) Error!Profile {
    if (input.profile.len == 0) return error.InvalidLock;
    if (input.target_triple) |triple| {
        if (!types.validTargetTriple(triple)) return error.InvalidLock;
    }

    var nodes: std.ArrayList(Node) = .empty;
    for (input.nodes) |node| {
        if (!types.validId(node.id)) return error.InvalidLock;
        if (!types.validPublicVersion(node.version)) return error.InvalidLock;
        if (!types.validHash(node.sha256)) return error.MissingArtifact;
        const key = try nodeKey(allocator, node.id, node.version);
        try nodes.append(allocator, .{
            .key = key,
            .id = try allocator.dupe(u8, node.id),
            .version = try allocator.dupe(u8, node.version),
            .sha256 = try allocator.dupe(u8, node.sha256),
            .kind = node.kind,
            .global = node.global,
        });
    }
    std.mem.sort(Node, nodes.items, {}, nodeLessThan);
    try requireUniqueNodes(nodes.items);

    var root: std.ArrayList(Edge) = .empty;
    for (input.root) |edge| {
        try root.append(allocator, try copyEdge(allocator, edge, null));
    }
    std.mem.sort(Edge, root.items, {}, edgeLessThan);

    var edges: std.ArrayList(Edge) = .empty;
    for (input.edges) |edge| {
        const from = edge.from orelse return error.InvalidLock;
        const from_key = try nodeKey(allocator, from.id, from.version);
        try edges.append(allocator, try copyEdge(allocator, edge, from_key));
    }
    std.mem.sort(Edge, edges.items, {}, edgeLessThan);
    try validateRefs(nodes.items, root.items, edges.items, allocator);

    return .{
        .name = try allocator.dupe(u8, input.profile),
        .runtime = input.runtime,
        .target_triple = if (input.target_triple) |triple| try allocator.dupe(u8, triple) else null,
        .nodes = try nodes.toOwnedSlice(allocator),
        .root = try root.toOwnedSlice(allocator),
        .edges = try edges.toOwnedSlice(allocator),
    };
}

fn copyEdge(allocator: Allocator, edge: GraphEdge, from: ?[]const u8) !Edge {
    var features: std.ArrayList([]const u8) = .empty;
    for (edge.features) |feature| try features.append(allocator, try allocator.dupe(u8, feature));
    const runtimes = try allocator.dupe(types.Runtime, edge.runtimes);
    const to_key = try nodeKey(allocator, edge.to.id, edge.to.version);
    return .{
        .from = if (from) |value| try allocator.dupe(u8, value) else null,
        .to = to_key,
        .id = try allocator.dupe(u8, edge.id),
        .req = try allocator.dupe(u8, edge.req),
        .alias = if (edge.alias) |value| try allocator.dupe(u8, value) else null,
        .features = try features.toOwnedSlice(allocator),
        .default_features = edge.default_features,
        .optional = edge.optional,
        .allow_global_commands = edge.allow_global_commands,
        .runtimes = runtimes,
    };
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

pub fn detectLegacy(source: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), source, .{}) catch return false;
    defer parsed.deinit();
    return switch (parsed.value) {
        .object => |object| object.get("schema_version") == null and object.get("schemaVersion") != null,
        else => false,
    };
}

pub fn parse(parent: Allocator, source: []const u8) Error!Lock {
    var arena = std.heap.ArenaAllocator.init(parent);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch return error.InvalidLock;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidLock,
    };

    if (root.get("schemaVersion") != null) return error.LegacyLock;
    const version_value = root.get("schema_version") orelse return error.InvalidLock;
    const version_number = switch (version_value) {
        .integer => |number| number,
        else => return error.InvalidLock,
    };
    if (version_number != schema_version) return error.UnsupportedVersion;
    try rejectUnknown(root, &.{ "schema_version", "profiles" });

    const profiles_value = root.get("profiles") orelse return error.InvalidLock;
    const profiles_array = switch (profiles_value) {
        .array => |array| array,
        else => return error.InvalidLock,
    };
    if (profiles_array.items.len == 0) return error.InvalidLock;

    var profiles: std.ArrayList(Profile) = .empty;
    for (profiles_array.items) |profile_value| {
        const profile_object = switch (profile_value) {
            .object => |object| object,
            else => return error.InvalidLock,
        };
        try rejectUnknown(profile_object, &.{ "name", "runtime", "target_triple", "nodes", "root", "edges" });
        const name = try requiredString(allocator, profile_object, "name");
        if (name.len == 0) return error.InvalidLock;
        const runtime = try parseRuntime(try requiredString(allocator, profile_object, "runtime"));
        const target_triple = if (profile_object.get("target_triple")) |value| blk: {
            const triple = try allocator.dupe(u8, try asString(value));
            if (!types.validTargetTriple(triple)) return error.InvalidLock;
            break :blk triple;
        } else null;

        var nodes: std.ArrayList(Node) = .empty;
        const nodes_array = try requiredArray(profile_object, "nodes");
        for (nodes_array.items) |node_value| {
            const node_object = switch (node_value) {
                .object => |object| object,
                else => return error.InvalidLock,
            };
            try rejectUnknown(node_object, &.{ "key", "id", "version", "sha256", "kind", "global" });
            const id = try requiredString(allocator, node_object, "id");
            const node_version = try requiredString(allocator, node_object, "version");
            const key = try requiredString(allocator, node_object, "key");
            const expected_key = try nodeKey(allocator, id, node_version);
            if (!std.mem.eql(u8, key, expected_key)) return error.InvalidLock;
            if (!types.validId(id) or !types.validPublicVersion(node_version)) return error.InvalidLock;
            const hash = try requiredString(allocator, node_object, "sha256");
            if (!types.validHash(hash)) return error.InvalidLock;
            const kind = try parseKind(try requiredString(allocator, node_object, "kind"));
            const global = try requiredBool(node_object, "global");
            try nodes.append(allocator, .{
                .key = key,
                .id = id,
                .version = node_version,
                .sha256 = hash,
                .kind = kind,
                .global = global,
            });
        }
        std.mem.sort(Node, nodes.items, {}, nodeLessThan);
        try requireUniqueNodes(nodes.items);

        var root_edges: std.ArrayList(Edge) = .empty;
        const root_array = try requiredArray(profile_object, "root");
        for (root_array.items) |edge_value| {
            try root_edges.append(allocator, try parseEdge(allocator, edge_value, false));
        }
        std.mem.sort(Edge, root_edges.items, {}, edgeLessThan);

        var edges: std.ArrayList(Edge) = .empty;
        const edges_array = try requiredArray(profile_object, "edges");
        for (edges_array.items) |edge_value| {
            try edges.append(allocator, try parseEdge(allocator, edge_value, true));
        }
        std.mem.sort(Edge, edges.items, {}, edgeLessThan);

        try validateRefs(nodes.items, root_edges.items, edges.items, allocator);

        try profiles.append(allocator, .{
            .name = name,
            .runtime = runtime,
            .target_triple = target_triple,
            .nodes = try nodes.toOwnedSlice(allocator),
            .root = try root_edges.toOwnedSlice(allocator),
            .edges = try edges.toOwnedSlice(allocator),
        });
    }
    std.mem.sort(Profile, profiles.items, {}, profileLessThan);
    try requireUniqueProfiles(profiles.items);

    return .{ .arena = arena, .profiles = try profiles.toOwnedSlice(allocator) };
}

fn parseEdge(allocator: Allocator, value: std.json.Value, require_from: bool) Error!Edge {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidLock,
    };
    try rejectUnknown(object, &.{ "from", "to", "id", "req", "alias", "features", "default_features", "optional", "allow_global_commands", "runtimes" });
    const from = if (object.get("from")) |from_value| try allocator.dupe(u8, try asString(from_value)) else null;
    if (require_from and from == null) return error.InvalidLock;
    if (!require_from and from != null) return error.InvalidLock;
    const to = try requiredString(allocator, object, "to");
    const id = try requiredString(allocator, object, "id");
    const req = try requiredString(allocator, object, "req");
    const alias = if (object.get("alias")) |alias_value| try allocator.dupe(u8, try asString(alias_value)) else null;
    const features = try parseStringArray(allocator, object, "features");
    const default_features = if (object.get("default_features")) |_| try requiredBool(object, "default_features") else true;
    const optional = if (object.get("optional")) |_| try requiredBool(object, "optional") else false;
    const allow_global_commands = if (object.get("allow_global_commands")) |_| try requiredBool(object, "allow_global_commands") else false;
    const runtimes = try parseRuntimes(allocator, object, "runtimes");
    return .{
        .from = from,
        .to = to,
        .id = id,
        .req = req,
        .alias = alias,
        .features = features,
        .default_features = default_features,
        .optional = optional,
        .allow_global_commands = allow_global_commands,
        .runtimes = runtimes,
    };
}

fn validateRefs(nodes: []const Node, root: []const Edge, edges: []const Edge, allocator: Allocator) Error!void {
    for (root) |edge| try validateEdge(nodes, edge, allocator);
    for (edges) |edge| {
        if (findNode(nodes, edge.from.?) == null) return error.InvalidLock;
        try validateEdge(nodes, edge, allocator);
    }
}

fn validateEdge(nodes: []const Node, edge: Edge, allocator: Allocator) Error!void {
    const target = findNode(nodes, edge.to) orelse return error.InvalidLock;
    if (!std.mem.eql(u8, edge.id, target.id)) return error.InvalidLock;
    const version = semver.Version.parse(target.version) catch return error.InvalidLock;
    var range = types.parseRange(allocator, edge.req) catch return error.InvalidLock;
    defer range.deinit(allocator);
    if (!range.satisfies(version)) return error.InvalidLock;
}

fn findNode(nodes: []const Node, key: []const u8) ?*const Node {
    for (nodes) |*node| {
        if (std.mem.eql(u8, node.key, key)) return node;
    }
    return null;
}

fn requireUniqueNodes(nodes: []const Node) Error!void {
    if (nodes.len < 2) return;
    var index: usize = 1;
    while (index < nodes.len) : (index += 1) {
        if (std.mem.eql(u8, nodes[index - 1].key, nodes[index].key)) return error.InvalidLock;
    }
}

fn requireUniqueProfiles(profiles: []const Profile) Error!void {
    if (profiles.len < 2) return;
    var index: usize = 1;
    while (index < profiles.len) : (index += 1) {
        if (std.mem.eql(u8, profiles[index - 1].name, profiles[index].name)) return error.InvalidLock;
    }
}

// ---------------------------------------------------------------------------
// 決定的シリアライズ
// ---------------------------------------------------------------------------

pub fn write(lock: *const Lock, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\n  \"schema_version\": 1,\n  \"profiles\": [");
    for (lock.profiles, 0..) |profile, profile_index| {
        if (profile_index > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {\n");
        try writer.writeAll("      \"name\": ");
        try writeString(writer, profile.name);
        try writer.writeAll(",\n      \"runtime\": ");
        try writeString(writer, @tagName(profile.runtime));
        if (profile.target_triple) |triple| {
            try writer.writeAll(",\n      \"target_triple\": ");
            try writeString(writer, triple);
        }
        try writer.writeAll(",\n      \"nodes\": [");
        for (profile.nodes, 0..) |node, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.writeAll("\n        {\"key\": ");
            try writeString(writer, node.key);
            try writer.writeAll(", \"id\": ");
            try writeString(writer, node.id);
            try writer.writeAll(", \"version\": ");
            try writeString(writer, node.version);
            try writer.writeAll(", \"sha256\": ");
            try writeString(writer, node.sha256);
            try writer.writeAll(", \"kind\": ");
            try writeString(writer, @tagName(node.kind));
            try writer.writeAll(", \"global\": ");
            try writer.writeAll(if (node.global) "true" else "false");
            try writer.writeAll("}");
        }
        try writer.writeAll("\n      ],\n      \"root\": [");
        for (profile.root, 0..) |edge, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.writeAll("\n        ");
            try writeEdge(writer, edge);
        }
        try writer.writeAll("\n      ],\n      \"edges\": [");
        for (profile.edges, 0..) |edge, index| {
            if (index > 0) try writer.writeAll(",");
            try writer.writeAll("\n        ");
            try writeEdge(writer, edge);
        }
        try writer.writeAll("\n      ]\n    }");
    }
    try writer.writeAll("\n  ]\n}\n");
}

fn writeEdge(writer: *std.Io.Writer, edge: Edge) !void {
    try writer.writeByte('{');
    var first = true;
    if (edge.from) |from| {
        try writer.writeAll("\"from\": ");
        try writeString(writer, from);
        first = false;
    }
    if (!first) try writer.writeAll(", ");
    try writer.writeAll("\"to\": ");
    try writeString(writer, edge.to);
    try writer.writeAll(", \"id\": ");
    try writeString(writer, edge.id);
    try writer.writeAll(", \"req\": ");
    try writeString(writer, edge.req);
    if (edge.alias) |alias| {
        try writer.writeAll(", \"alias\": ");
        try writeString(writer, alias);
    }
    try writer.writeAll(", \"features\": [");
    for (edge.features, 0..) |feature, index| {
        if (index > 0) try writer.writeAll(", ");
        try writeString(writer, feature);
    }
    try writer.writeAll("], \"default_features\": ");
    try writer.writeAll(if (edge.default_features) "true" else "false");
    try writer.writeAll(", \"optional\": ");
    try writer.writeAll(if (edge.optional) "true" else "false");
    try writer.writeAll(", \"allow_global_commands\": ");
    try writer.writeAll(if (edge.allow_global_commands) "true" else "false");
    try writer.writeAll(", \"runtimes\": [");
    for (edge.runtimes, 0..) |runtime, index| {
        if (index > 0) try writer.writeAll(", ");
        try writeString(writer, @tagName(runtime));
    }
    try writer.writeAll("]}");
}

fn writeString(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

/// 呼出し側が `free` する。
pub fn toBytes(lock: *const Lock, allocator: Allocator) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try write(lock, &output.writer);
    return output.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// index・実バイト列との照合
// ---------------------------------------------------------------------------

pub const IndexArtifact = struct {
    kind: types.Kind,
    sha256: []const u8,
};

pub const IndexRelease = struct {
    id: []const u8,
    version: []const u8,
    yanked: bool = false,
    exports_global_commands: bool = false,
    artifacts: []const IndexArtifact = &.{},
};

pub const ActualHash = struct {
    key: []const u8,
    sha256: []const u8,
};

pub const VerifyOptions = struct {
    actual_hashes: []const ActualHash = &.{},
    /// 実バイト列のハッシュが渡されていないノードを失敗にする。
    require_actual: bool = false,
};

pub const VerifyWarningKind = enum { yanked_node };

pub const VerifyWarning = struct {
    kind: VerifyWarningKind,
    profile: []const u8,
    key: []const u8,
    id: []const u8,
    version: []const u8,
};

pub const VerifyFailureKind = enum {
    node_not_in_index,
    artifact_hash_mismatch,
    actual_hash_mismatch,
    missing_actual_hash,
    edge_target_missing,
    edge_from_missing,
    edge_id_mismatch,
    edge_requirement_unsatisfied,
    global_flag_mismatch,
    invalid_range,
};

pub const VerifyFailure = struct {
    kind: VerifyFailureKind,
    profile: []const u8 = "",
    key: []const u8 = "",
    id: []const u8 = "",
    version: []const u8 = "",
    detail: []const u8 = "",
};

/// `warnings` は呼出し側が `allocator.free` する。
pub const VerifyReport = struct {
    warnings: []const VerifyWarning,
    failure: ?VerifyFailure = null,
};

/// lock の各ノードを index の版・アーティファクトハッシュへ照合し、さらに
/// 呼出し側が渡した実バイト列の SHA-256（`actual_hashes`）と照合する。
/// yank 済みの版でも lock に記録されハッシュが一致すれば使用できる（§6.2）
/// ため、その場合は失敗ではなく警告を返す。
pub fn verify(
    allocator: Allocator,
    lock: *const Lock,
    index: []const IndexRelease,
    options: VerifyOptions,
) !VerifyReport {
    var warnings: std.ArrayList(VerifyWarning) = .empty;
    errdefer warnings.deinit(allocator);

    for (lock.profiles) |profile| {
        for (profile.nodes) |node| {
            const release = findRelease(index, node.id, node.version) orelse return .{
                .warnings = try warnings.toOwnedSlice(allocator),
                .failure = .{ .kind = .node_not_in_index, .profile = profile.name, .key = node.key, .id = node.id, .version = node.version },
            };
            if (release.exports_global_commands != node.global) return .{
                .warnings = try warnings.toOwnedSlice(allocator),
                .failure = .{ .kind = .global_flag_mismatch, .profile = profile.name, .key = node.key, .id = node.id, .version = node.version },
            };
            if (!artifactMatches(release, node)) return .{
                .warnings = try warnings.toOwnedSlice(allocator),
                .failure = .{ .kind = .artifact_hash_mismatch, .profile = profile.name, .key = node.key, .id = node.id, .version = node.version },
            };
            if (findActual(options.actual_hashes, node.key)) |actual| {
                if (!std.mem.eql(u8, actual, node.sha256)) return .{
                    .warnings = try warnings.toOwnedSlice(allocator),
                    .failure = .{ .kind = .actual_hash_mismatch, .profile = profile.name, .key = node.key, .id = node.id, .version = node.version },
                };
            } else if (options.require_actual) {
                return .{
                    .warnings = try warnings.toOwnedSlice(allocator),
                    .failure = .{ .kind = .missing_actual_hash, .profile = profile.name, .key = node.key, .id = node.id, .version = node.version },
                };
            }
            if (release.yanked) {
                try warnings.append(allocator, .{
                    .kind = .yanked_node,
                    .profile = profile.name,
                    .key = node.key,
                    .id = node.id,
                    .version = node.version,
                });
            }
        }

        for (profile.root) |edge| {
            if (try verifyEdge(allocator, profile, edge, false)) |failure| {
                return .{ .warnings = try warnings.toOwnedSlice(allocator), .failure = failure };
            }
        }
        for (profile.edges) |edge| {
            if (try verifyEdge(allocator, profile, edge, true)) |failure| {
                return .{ .warnings = try warnings.toOwnedSlice(allocator), .failure = failure };
            }
        }
    }

    return .{ .warnings = try warnings.toOwnedSlice(allocator) };
}

fn verifyEdge(
    allocator: Allocator,
    profile: Profile,
    edge: Edge,
    require_from: bool,
) !?VerifyFailure {
    if (require_from != (edge.from != null)) return .{
        .kind = if (edge.from == null) .edge_from_missing else .edge_target_missing,
        .profile = profile.name,
        .key = edge.to,
        .id = edge.id,
    };
    if (edge.from) |from| {
        if (findNode(profile.nodes, from) == null) return .{
            .kind = .edge_from_missing,
            .profile = profile.name,
            .key = from,
            .id = edge.id,
        };
    }
    const target = findNode(profile.nodes, edge.to) orelse return .{
        .kind = .edge_target_missing,
        .profile = profile.name,
        .key = edge.to,
        .id = edge.id,
    };
    if (!std.mem.eql(u8, edge.id, target.id)) return .{
        .kind = .edge_id_mismatch,
        .profile = profile.name,
        .key = target.key,
        .id = edge.id,
        .version = target.version,
    };
    const version = semver.Version.parse(target.version) catch return .{
        .kind = .edge_requirement_unsatisfied,
        .profile = profile.name,
        .key = target.key,
        .id = target.id,
        .version = target.version,
    };
    var range = types.parseRange(allocator, edge.req) catch return .{
        .kind = .invalid_range,
        .profile = profile.name,
        .key = target.key,
        .id = edge.id,
        .version = target.version,
        .detail = edge.req,
    };
    defer range.deinit(allocator);
    if (!range.satisfies(version)) return .{
        .kind = .edge_requirement_unsatisfied,
        .profile = profile.name,
        .key = target.key,
        .id = edge.id,
        .version = target.version,
        .detail = edge.req,
    };
    return null;
}

fn findRelease(index: []const IndexRelease, id: []const u8, version: []const u8) ?*const IndexRelease {
    for (index) |*release| {
        if (std.mem.eql(u8, release.id, id) and std.mem.eql(u8, release.version, version)) return release;
    }
    return null;
}

fn artifactMatches(release: *const IndexRelease, node: Node) bool {
    for (release.artifacts) |artifact| {
        if (artifact.kind != node.kind) continue;
        if (std.mem.eql(u8, artifact.sha256, node.sha256)) return true;
    }
    return false;
}

fn findActual(actual: []const ActualHash, key: []const u8) ?[]const u8 {
    for (actual) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.sha256;
    }
    return null;
}

// ---------------------------------------------------------------------------
// JSON 補助
// ---------------------------------------------------------------------------

fn rejectUnknown(object: std.json.ObjectMap, allowed: []const []const u8) Error!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, name, entry.key_ptr.*)) {
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidLock;
    }
}

fn asString(value: std.json.Value) Error![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidLock,
    };
}

fn requiredString(allocator: Allocator, object: std.json.ObjectMap, name: []const u8) Error![]const u8 {
    const value = object.get(name) orelse return error.InvalidLock;
    return allocator.dupe(u8, try asString(value));
}

fn requiredBool(object: std.json.ObjectMap, name: []const u8) Error!bool {
    const value = object.get(name) orelse return error.InvalidLock;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidLock,
    };
}

fn requiredArray(object: std.json.ObjectMap, name: []const u8) Error!std.json.Array {
    const value = object.get(name) orelse return error.InvalidLock;
    return switch (value) {
        .array => |array| array,
        else => error.InvalidLock,
    };
}

fn parseStringArray(allocator: Allocator, object: std.json.ObjectMap, name: []const u8) Error![]const []const u8 {
    const array = try requiredArray(object, name);
    var items: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        try items.append(allocator, try allocator.dupe(u8, try asString(item)));
    }
    return items.toOwnedSlice(allocator);
}

fn parseRuntimes(allocator: Allocator, object: std.json.ObjectMap, name: []const u8) Error![]const types.Runtime {
    const array = try requiredArray(object, name);
    var items: std.ArrayList(types.Runtime) = .empty;
    for (array.items) |item| {
        try items.append(allocator, try parseRuntime(try asString(item)));
    }
    return items.toOwnedSlice(allocator);
}

fn parseRuntime(text: []const u8) Error!types.Runtime {
    if (std.mem.eql(u8, text, "lnako")) return .lnako;
    if (std.mem.eql(u8, text, "cnako")) return .cnako;
    if (std.mem.eql(u8, text, "wnako")) return .wnako;
    return error.InvalidLock;
}

fn parseKind(text: []const u8) Error!types.Kind {
    if (std.mem.eql(u8, text, "universal")) return .universal;
    if (std.mem.eql(u8, text, "esm")) return .esm;
    if (std.mem.eql(u8, text, "native-source")) return .@"native-source";
    if (std.mem.eql(u8, text, "native-prebuilt")) return .@"native-prebuilt";
    return error.InvalidLock;
}

// ---------------------------------------------------------------------------
// 比較
// ---------------------------------------------------------------------------

fn nodeLessThan(_: void, a: Node, b: Node) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn profileLessThan(_: void, a: Profile, b: Profile) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn edgeLessThan(_: void, a: Edge, b: Edge) bool {
    const a_from = a.from orelse "";
    const b_from = b.from orelse "";
    const from_order = std.mem.order(u8, a_from, b_from);
    if (from_order != .eq) return from_order == .lt;
    const to_order = std.mem.order(u8, a.to, b.to);
    if (to_order != .eq) return to_order == .lt;
    const id_order = std.mem.order(u8, a.id, b.id);
    if (id_order != .eq) return id_order == .lt;
    return std.mem.order(u8, a.req, b.req) == .lt;
}
