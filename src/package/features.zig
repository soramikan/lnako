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
/// マップのバッファは `allocator` 所有だが、キーは文字列を複製せず
/// `definitions`/`dependency_aliases` に保持された正規キーを指す。
/// そのため結果は両入力より先に解放しなければならない。
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

    for (requested) |name| {
        if (definitions.contains(name)) {
            try visit(allocator, definitions, dependency_aliases, &expanded, offender, name);
        } else if (dependency_aliases.getKey(name)) |key| {
            // `requested` のスライスではなく alias 集合の正規キーを保持する
            // （要求文字列が結果より先に解放されても参照が有効なままになる）。
            try expanded.dependency_aliases.put(key, {});
        } else {
            if (offender) |out| out.* = name;
            return error.UnknownFeature;
        }
    }
    if (use_default and definitions.contains("default")) {
        try visit(allocator, definitions, dependency_aliases, &expanded, offender, "default");
    }
    return expanded;
}

const VisitFrame = struct { definition: *const Definition, next: usize };

/// feature を反復 DFS で展開する。深い非循環連鎖でもネイティブスタックを
/// 消費しないよう、探索経路はヒープ上の明示スタックで保持する。
/// `visiting` は現在の探索経路（循環検出用）を表す。
fn visit(
    allocator: std.mem.Allocator,
    definitions: *const Definitions,
    dependency_aliases: *const std.StringHashMap(void),
    expanded: *Expanded,
    offender: ?*?[]const u8,
    name: []const u8,
) Error!void {
    var visiting = std.StringHashMap(void).init(allocator);
    defer visiting.deinit();
    var stack: std.ArrayList(VisitFrame) = .empty;
    defer stack.deinit(allocator);
    try pushVisit(allocator, definitions, expanded, &visiting, &stack, offender, name);
    while (stack.items.len > 0) {
        const frame = &stack.items[stack.items.len - 1];
        if (frame.next < frame.definition.items.len) {
            const item = frame.definition.items[frame.next];
            frame.next += 1;
            if (definitions.contains(item)) {
                try pushVisit(allocator, definitions, expanded, &visiting, &stack, offender, item);
            } else if (dependency_aliases.getKey(item)) |key| {
                try expanded.dependency_aliases.put(key, {});
            } else {
                if (offender) |out| out.* = item;
                return error.UnknownFeature;
            }
        } else {
            // 全子を処理し終えた時点で経路から外し、結果へ登録する。
            _ = visiting.remove(frame.definition.name);
            try expanded.features.put(frame.definition.name, {});
            _ = stack.pop();
        }
    }
}

fn pushVisit(
    allocator: std.mem.Allocator,
    definitions: *const Definitions,
    expanded: *Expanded,
    visiting: *std.StringHashMap(void),
    stack: *std.ArrayList(VisitFrame),
    offender: ?*?[]const u8,
    name: []const u8,
) Error!void {
    const definition = definitions.getPtr(name).?;
    if (expanded.features.contains(definition.name)) return;
    const gop = try visiting.getOrPut(definition.name);
    if (gop.found_existing) {
        if (offender) |out| out.* = name;
        return error.FeatureCycle;
    }
    try stack.append(allocator, .{ .definition = definition, .next = 0 });
}

/// 定義一覧に循環がないか検査する。循環があれば循環に含まれる feature 名を返す。
pub fn checkCycles(
    allocator: std.mem.Allocator,
    definitions: *const Definitions,
) error{OutOfMemory}!?[]const u8 {
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();
    var in_stack = std.StringHashMap(void).init(allocator);
    defer in_stack.deinit();

    var iterator = definitions.keyIterator();
    while (iterator.next()) |key| {
        if (try checkCyclesVisit(allocator, definitions, key.*, &visited, &in_stack)) |cycle| {
            return cycle;
        }
    }
    return null;
}

/// `checkCyclesVisit` の反復 DFS フレーム。
const CycleFrame = struct { definition: *const Definition, next: usize };

/// `visited`/`in_stack` の意味論は再帰版と同じ:
/// `visited` は探索済み、`in_stack` は現在の探索経路（gray 集合）。
/// 深い非循環連鎖でもネイティブスタックを消費しないよう、
/// 経路はヒープ上の明示フレームスタックで保持する。
fn checkCyclesVisit(
    allocator: std.mem.Allocator,
    definitions: *const Definitions,
    name: []const u8,
    visited: *std.StringHashMap(void),
    in_stack: *std.StringHashMap(void),
) error{OutOfMemory}!?[]const u8 {
    var frames: std.ArrayList(CycleFrame) = .empty;
    defer frames.deinit(allocator);
    const definition = definitions.getPtr(name).?;
    // 再帰版と同じく、探索済みの根では再探索しない。
    if (visited.contains(definition.name)) return null;
    try in_stack.put(definition.name, {});
    try frames.append(allocator, .{ .definition = definition, .next = 0 });
    while (frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        if (frame.next < frame.definition.items.len) {
            const item = frame.definition.items[frame.next];
            frame.next += 1;
            const item_def = definitions.getPtr(item) orelse continue;
            if (visited.contains(item_def.name)) continue;
            if (in_stack.contains(item_def.name)) return item;
            try in_stack.put(item_def.name, {});
            try frames.append(allocator, .{ .definition = item_def, .next = 0 });
        } else {
            _ = in_stack.remove(frame.definition.name);
            try visited.put(frame.definition.name, {});
            _ = frames.pop();
        }
    }
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

test "展開結果は要求文字列ではなく定義側の正規キーを保持する" {
    const allocator = std.testing.allocator;
    var definitions: Definitions = .empty;
    defer definitions.deinit(allocator);
    try definitions.put(allocator, "web", .{ .name = "web", .items = &.{"req"}, .position = .{} });
    var aliases = std.StringHashMap(void).init(allocator);
    defer aliases.deinit();
    try aliases.put("req", {});

    // 要求名を一時バッファへ複製し、展開後に解放しても結果が有効であること。
    const requested = try allocator.dupe(u8, "web");
    var expanded = try expand(allocator, &definitions, &.{requested}, false, &aliases, null);
    allocator.free(requested);
    defer expanded.deinit();
    try std.testing.expect(expanded.contains("web"));
    try std.testing.expect(expanded.dependency_aliases.contains("req"));

    // 格納キーが definitions/aliases 側の正規キーを指すことを確認する。
    const def_key = definitions.getKey("web").?;
    const alias_key = aliases.getKey("req").?;
    try std.testing.expectEqual(def_key.ptr, expanded.features.getKey("web").?.ptr);
    try std.testing.expectEqual(alias_key.ptr, expanded.dependency_aliases.getKey("req").?.ptr);
}

test "深いfeature連鎖を反復DFSで展開する" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const depth = 4096;
    var definitions: Definitions = .empty;
    defer definitions.deinit(allocator);
    var last_name: []const u8 = "";
    for (0..depth) |i| {
        const name = try std.fmt.allocPrint(a, "f{d:0>5}", .{i});
        const items = try a.alloc([]const u8, 1);
        if (i + 1 < depth) {
            items[0] = try std.fmt.allocPrint(a, "f{d:0>5}", .{i + 1});
        } else {
            items[0] = name;
        }
        try definitions.put(allocator, name, .{ .name = name, .items = items[0..@intFromBool(i + 1 < depth)], .position = .{} });
        last_name = name;
    }
    var aliases = std.StringHashMap(void).init(allocator);
    defer aliases.deinit();

    // 深い非循環連鎖はネイティブスタックを消費せず展開できる。
    var expanded = try expand(allocator, &definitions, &.{"f00000"}, false, &aliases, null);
    defer expanded.deinit();
    try std.testing.expectEqual(@as(u32, depth), expanded.features.count());
    try std.testing.expect((try checkCycles(allocator, &definitions)) == null);

    // 末尾を先頭へ戻すと再帰なしで循環を検出する。
    definitions.getPtr(last_name).?.items = &.{"f00000"};
    var offender: ?[]const u8 = null;
    try std.testing.expectError(error.FeatureCycle, expand(allocator, &definitions, &.{"f00000"}, false, &aliases, &offender));
    try std.testing.expect((try checkCycles(allocator, &definitions)) != null);
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
