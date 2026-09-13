const std = @import("std");
const diagnostics = @import("diagnostics.zig");

pub const Position = diagnostics.Position;

/// `[features]` セクションの1エントリ。`items` は有効化する feature 名または
/// 依存 alias 名の配列（TOMLドキュメントのアリーナを指す）。
pub const Definition = struct {
    name: []const u8,
    items: []const []const u8,
    position: Position,
};

/// 定義済み feature のマップ。キーと値は呼出し側が所有する。
/// unmanaged のため保持している側（manifest のアリーナ等）の allocator を
/// 各操作に明示的に渡す。
pub const Definitions = std.StringHashMapUnmanaged(Definition);

/// 展開結果。`features` は有効化された定義済み feature、
/// `dependency_aliases` は feature 経由で有効化された依存 alias。
/// 両方とも `allocator` 所有。
pub const Expanded = struct {
    features: std.StringHashMap(void),
    dependency_aliases: std.StringHashMap(void),

    pub fn deinit(self: *Expanded) void {
        self.features.deinit();
        self.dependency_aliases.deinit();
        self.* = undefined;
    }

    pub fn contains(self: *const Expanded, name: []const u8) bool {
        return self.features.contains(name);
    }
};

pub const Error = error{ FeatureCycle, UnknownFeature, OutOfMemory };

/// feature を展開する。`requested` に加え、`use_default` が真で
/// `default` が定義されていれば `default` を要求集合に含める。
/// feature 定義の値が定義済み feature 名なら再帰的に展開し、
/// そうでなければ `dependency_aliases`（`dependencies`/`dev-dependencies` の
/// エントリ名）として記録する。循環は `error.FeatureCycle` で報告する。
/// `offender` を渡すと FeatureCycle/UnknownFeature の該当名を返す。
pub fn expand(
    allocator: std.mem.Allocator,
    definitions: *const Definitions,
    requested: []const []const u8,
    use_default: bool,
    dependency_aliases: *const std.StringHashMap(void),
    offender: ?*?[]const u8,
) Error!Expanded {
    var expanded = Expanded{
        .features = std.StringHashMap(void).init(allocator),
        .dependency_aliases = std.StringHashMap(void).init(allocator),
    };
    errdefer expanded.deinit();

    var visiting = std.StringHashMap(void).init(allocator);
    defer visiting.deinit();

    for (requested) |name| {
        if (definitions.contains(name)) {
            try visit(allocator, definitions, dependency_aliases, &expanded, &visiting, offender, name);
        } else if (dependency_aliases.contains(name)) {
            try expanded.dependency_aliases.put(name, {});
        } else {
            if (offender) |out| out.* = name;
            return error.UnknownFeature;
        }
    }
    if (use_default and definitions.contains("default")) {
        try visit(allocator, definitions, dependency_aliases, &expanded, &visiting, offender, "default");
    }
    return expanded;
}

fn visit(
    allocator: std.mem.Allocator,
    definitions: *const Definitions,
    dependency_aliases: *const std.StringHashMap(void),
    expanded: *Expanded,
    visiting: *std.StringHashMap(void),
    offender: ?*?[]const u8,
    name: []const u8,
) Error!void {
    if (expanded.features.contains(name)) return;
    const gop = try visiting.getOrPut(name);
    if (gop.found_existing) {
        if (offender) |out| out.* = name;
        return error.FeatureCycle;
    }
    defer _ = visiting.remove(name);
    const definition = definitions.get(name).?;
    for (definition.items) |item| {
        if (definitions.contains(item)) {
            try visit(allocator, definitions, dependency_aliases, expanded, visiting, offender, item);
        } else if (dependency_aliases.contains(item)) {
            try expanded.dependency_aliases.put(item, {});
        } else {
            if (offender) |out| out.* = item;
            return error.UnknownFeature;
        }
    }
    try expanded.features.put(name, {});
}

/// 定義一覧に循環がないか検査する。循環があれば循環に含まれる feature 名を返す。
pub fn checkCycles(
    allocator: std.mem.Allocator,
    definitions: *const Definitions,
) error{OutOfMemory}!?[]const u8 {
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    var stack: std.ArrayList([]const u8) = .empty;
    defer stack.deinit(allocator);
    var in_stack = std.StringHashMap(usize).init(allocator);
    defer in_stack.deinit();

    var iterator = definitions.keyIterator();
    while (iterator.next()) |key| {
        if (try checkCyclesVisit(allocator, definitions, key.*, &visited, &stack, &in_stack)) |cycle| {
            return cycle;
        }
    }
    return null;
}

fn checkCyclesVisit(
    allocator: std.mem.Allocator,
    definitions: *const Definitions,
    name: []const u8,
    visited: *std.StringHashMap(void),
    stack: *std.ArrayList([]const u8),
    in_stack: *std.StringHashMap(usize),
) error{OutOfMemory}!?[]const u8 {
    if (visited.contains(name)) return null;
    if (in_stack.contains(name)) return name;
    try in_stack.put(name, stack.items.len);
    try stack.append(allocator, name);
    defer {
        _ = stack.pop();
        _ = in_stack.remove(name);
    }
    const definition = definitions.get(name).?;
    for (definition.items) |item| {
        if (!definitions.contains(item)) continue;
        if (try checkCyclesVisit(allocator, definitions, item, visited, stack, in_stack)) |cycle| {
            return cycle;
        }
    }
    try visited.put(name, {});
    return null;
}

test "featureを展開する" {
    const allocator = std.testing.allocator;
    var definitions: Definitions = .empty;
    defer definitions.deinit(allocator);
    const empty: []const []const u8 = &.{};
    try definitions.put(allocator, "default", .{ .name = "default", .items = &.{"native"}, .position = .{} });
    try definitions.put(allocator, "native", .{ .name = "native", .items = empty, .position = .{} });
    try definitions.put(allocator, "http", .{ .name = "http", .items = &.{ "native", "req" }, .position = .{} });
    var aliases = std.StringHashMap(void).init(allocator);
    defer aliases.deinit();
    try aliases.put("req", {});

    var expanded = try expand(allocator, &definitions, &.{}, true, &aliases, null);
    defer expanded.deinit();
    try std.testing.expect(expanded.contains("default"));
    try std.testing.expect(expanded.contains("native"));
    try std.testing.expect(!expanded.dependency_aliases.contains("req"));

    var expanded2 = try expand(allocator, &definitions, &.{"http"}, false, &aliases, null);
    defer expanded2.deinit();
    try std.testing.expect(expanded2.contains("http"));
    try std.testing.expect(expanded2.contains("native"));
    try std.testing.expect(!expanded2.contains("default"));
    try std.testing.expect(expanded2.dependency_aliases.contains("req"));
}

test "feature循環を検出する" {
    const allocator = std.testing.allocator;
    var definitions: Definitions = .empty;
    defer definitions.deinit(allocator);
    try definitions.put(allocator, "a", .{ .name = "a", .items = &.{"b"}, .position = .{} });
    try definitions.put(allocator, "b", .{ .name = "b", .items = &.{"a"}, .position = .{} });
    var aliases = std.StringHashMap(void).init(allocator);
    defer aliases.deinit();

    var offender: ?[]const u8 = null;
    try std.testing.expectError(error.FeatureCycle, expand(allocator, &definitions, &.{"a"}, false, &aliases, &offender));
    try std.testing.expect(std.mem.eql(u8, offender.?, "a") or std.mem.eql(u8, offender.?, "b"));
    const cycle = (try checkCycles(allocator, &definitions)).?;
    try std.testing.expect(std.mem.eql(u8, cycle, "a") or std.mem.eql(u8, cycle, "b"));
}

test "未知のfeatureを拒否する" {
    const allocator = std.testing.allocator;
    var definitions: Definitions = .empty;
    defer definitions.deinit(allocator);
    var aliases = std.StringHashMap(void).init(allocator);
    defer aliases.deinit();
    var offender: ?[]const u8 = null;
    try std.testing.expectError(error.UnknownFeature, expand(allocator, &definitions, &.{"unknown"}, false, &aliases, &offender));
    try std.testing.expectEqualStrings("unknown", offender.?);
}
