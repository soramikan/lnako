//! v1 の命令登録計画（§6.1 のスコープ分離と global 許可）。
//!
//! 入力は `v1_resolver.Graph`（解決済みの辺・ノード）と、各ノードの
//! `COMMANDS.json` 相当（`PackageCommands`）。出力は実際の登録処理へ渡す
//! `Plan` で、次を明示する。
//!
//! - `namespaces`: `scoped` の入口ごとの名前空間。名前空間は「宣言した
//!   依存の alias（なければ name）を、宣言元の名前空間の下に置く」形で
//!   組み立てる。ルート直下はそのまま、間接依存は `left.local_dsl` のように
//!   宣言元の内側に閉じる。alias と `allow_global_commands` は宣言した辺に
//!   だけ適用し、他の依存へ継承しない。
//! - `globals`: `binding == "global"` の入口から取り込む命令名。取り込みには
//!   宣言元の依存の `allow_global_commands = true` が必要で、ルート以外が
//!   宣言した場合は加えて「ルートが同じ Package ID を直接依存に宣言し、
//!   その依存で許可している」ことが必要（§6.1）。満たさなければ失敗し、
//!   globals は空のまま返す。
//! - 定数は `namespace` に保持するが global 命令名の集合には入れない
//!   （§3.5）。`scoped` の命令・定数を global 空間へ混ぜない。
//!
//! 実行経路（plugin_registration・project・CLI）への接続は統合作業に委ねる。

const std = @import("std");
const types = @import("v1_types.zig");
const resolver = @import("v1_resolver.zig");

const Allocator = std.mem.Allocator;

pub const Arg = struct {
    name: []const u8,
    josi: []const []const u8 = &.{},
    type_name: ?[]const u8 = null,
};

pub const Command = struct {
    name: []const u8,
    kind: []const u8 = "function",
    args: []const Arg = &.{},
    return_type: ?[]const u8 = null,
    is_async: bool = false,
    doc: ?[]const u8 = null,
};

pub const Export = struct {
    subpath: []const u8,
    binding: types.Binding,
    commands: []const Command = &.{},
    constants: []const []const u8 = &.{},
};

pub const PackageCommands = struct {
    id: []const u8,
    version: []const u8,
    exports: []const Export = &.{},
    /// COMMANDS.json の `exports_global_commands`。実際の global 入口の有無と
    /// 一致しなければ `invalid_commands`。
    exports_global_commands: bool = false,
};

pub const FailureKind = enum {
    missing_commands,
    invalid_commands,
    global_not_allowed,
    global_command_conflict,
    namespace_conflict,
};

pub const Failure = struct {
    kind: FailureKind,
    id: []const u8 = "",
    version: []const u8 = "",
    name: []const u8 = "",
    detail: []const u8 = "",
};

pub const Namespace = struct {
    /// ドット区切りの登録名（例: `left.local_dsl`）。
    path: []const u8,
    node_key: []const u8,
    id: []const u8,
    version: []const u8,
    subpath: []const u8,
    commands: []const Command,
    constants: []const []const u8,
};

pub const GlobalCommand = struct {
    name: []const u8,
    id: []const u8,
    version: []const u8,
    subpath: []const u8,
    command: *const Command,
};

/// `global` 入口の定数。§3.5 により global 命令名の集合には含めないが、
/// 登録側が扱えるように別枠で渡す。
pub const GlobalConstant = struct {
    name: []const u8,
    id: []const u8,
    version: []const u8,
    subpath: []const u8,
};

/// 実際にコードから取り込む入口。`planWithRequests` で使う。
pub const Request = struct {
    node_key: []const u8,
    subpath: []const u8,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    namespaces: []const Namespace,
    globals: []const GlobalCommand,
    global_constants: []const GlobalConstant,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findNamespace(self: *const Plan, path: []const u8) ?*const Namespace {
        for (self.namespaces) |*namespace| {
            if (std.mem.eql(u8, namespace.path, path)) return namespace;
        }
        return null;
    }
};

pub const Outcome = union(enum) {
    planned: Plan,
    failed: Failure,
};

/// 登録計画を作る。グラフと `commands` は Plan より長生きする必要がある
/// （Plan は名前・命令データを借用し、名前空間のパスだけを自前で確保する）。
/// この入口は全 export を「取り込む」前提の保守的な計画で、未許可の global
/// 入口があれば失敗する。実際に使うサブパスだけを対象にする場合は
/// `planWithRequests` を使う。
pub fn plan(parent: Allocator, graph: *const resolver.Graph, commands: []const PackageCommands) !Outcome {
    return planWithRequests(parent, graph, commands, &.{});
}

/// `requests` が空なら全 export、空でなければ指定した (node_key, subpath) だけを
/// 登録対象にする。global 許可の検査は実際に対象となった入口にだけ行う。
pub fn planWithRequests(
    parent: Allocator,
    graph: *const resolver.Graph,
    commands: []const PackageCommands,
    requests: []const Request,
) !Outcome {
    var arena = std.heap.ArenaAllocator.init(parent);
    var keep_arena = false;
    defer if (!keep_arena) arena.deinit();
    const allocator = arena.allocator();

    var builder = Builder{
        .allocator = allocator,
        .graph = graph,
        .commands = commands,
        .requests = requests,
        .namespaces = .empty,
        .globals = .empty,
        .global_constants = .empty,
        .visited = std.StringHashMap(void).init(allocator),
        .providers = std.StringHashMap(Provider).init(allocator),
    };

    for (graph.rootEdges()) |root_edge| {
        const base = try allocator.alloc([]const u8, 1);
        base[0] = localName(root_edge);
        if (!try builder.emitNode(root_edge.to, base, root_edge)) {
            return .{ .failed = builder.failure.? };
        }
    }

    const plan_value = Plan{
        .arena = arena,
        .namespaces = try builder.namespaces.toOwnedSlice(allocator),
        .globals = try builder.globals.toOwnedSlice(allocator),
        .global_constants = try builder.global_constants.toOwnedSlice(allocator),
    };
    keep_arena = true;
    return .{ .planned = plan_value };
}

const Provider = struct {
    id: []const u8,
    version: []const u8,
};

const Builder = struct {
    allocator: Allocator,
    graph: *const resolver.Graph,
    commands: []const PackageCommands,
    requests: []const Request,
    namespaces: std.ArrayList(Namespace),
    globals: std.ArrayList(GlobalCommand),
    global_constants: std.ArrayList(GlobalConstant),
    visited: std.StringHashMap(void),
    providers: std.StringHashMap(Provider),
    failure: ?Failure = null,

    fn emitNode(self: *Builder, node_index: usize, base: []const []const u8, incoming: resolver.Edge) !bool {
        const node = self.graph.nodes[node_index];
        const key = try self.nodeKey(node_index);
        const path = try joinPath(self.allocator, base);
        const visit_key = try std.fmt.allocPrint(self.allocator, "{s}\x00{s}\x00{d}\x00{d}", .{
            key,
            path,
            @intFromBool(incoming.from == null),
            @intFromBool(incoming.allow_global_commands),
        });
        if (self.visited.contains(visit_key)) return true;
        try self.visited.put(visit_key, {});

        const package = self.findCommands(node.id, node.version) orelse {
            self.fail(.{ .kind = .missing_commands, .id = node.id, .version = node.version });
            return false;
        };

        var actual_global = false;
        for (package.exports) |entry| {
            if (entry.binding == .global) actual_global = true;
        }
        if (actual_global != package.exports_global_commands) {
            self.fail(.{ .kind = .invalid_commands, .id = node.id, .version = node.version, .detail = "exports_global_commands" });
            return false;
        }
        if (!try self.checkGlobalNames(node, package)) return false;

        for (package.exports) |entry| {
            if (!self.requested(key, entry.subpath)) continue;
            const subpath_segments = splitSubpath(self.allocator, entry.subpath) catch {
                self.fail(.{ .kind = .invalid_commands, .id = node.id, .version = node.version, .name = entry.subpath });
                return false;
            };
            switch (entry.binding) {
                .scoped => {
                    if (!try self.addNamespace(base, subpath_segments, key, node, entry)) return false;
                },
                .global => {
                    if (!self.globalAllowed(incoming, node.id)) {
                        self.fail(.{
                            .kind = .global_not_allowed,
                            .id = node.id,
                            .version = node.version,
                            .name = entry.subpath,
                            .detail = "allow_global_commands",
                        });
                        return false;
                    }
                    if (!try self.addGlobals(node, entry)) return false;
                },
            }
        }

        for (self.graph.nodeEdges()) |edge| {
            if (edge.from != node_index) continue;
            var child_base: std.ArrayList([]const u8) = .empty;
            for (base) |segment| try child_base.append(self.allocator, segment);
            try child_base.append(self.allocator, localName(edge));
            if (!try self.emitNode(edge.to, child_base.items, edge)) return false;
        }
        return true;
    }

    fn checkGlobalNames(self: *Builder, node: resolver.Node, package: *const PackageCommands) !bool {
        var expected: std.ArrayList([]const u8) = .empty;
        for (package.exports) |entry| {
            if (entry.binding != .global) continue;
            for (entry.commands) |command| try expected.append(self.allocator, command.name);
        }
        if (expected.items.len != node.release.global_commands.len) {
            self.fail(.{ .kind = .invalid_commands, .id = node.id, .version = node.version, .detail = "global_commands" });
            return false;
        }
        for (node.release.global_commands) |name| {
            if (!contains(expected.items, name)) {
                self.fail(.{ .kind = .invalid_commands, .id = node.id, .version = node.version, .detail = "global_commands" });
                return false;
            }
        }
        return true;
    }

    fn addNamespace(
        self: *Builder,
        base: []const []const u8,
        subpath: []const []const u8,
        key: []const u8,
        node: resolver.Node,
        entry: Export,
    ) !bool {
        var segments: std.ArrayList([]const u8) = .empty;
        for (base) |segment| try segments.append(self.allocator, segment);
        for (subpath) |segment| try segments.append(self.allocator, segment);
        const path = try joinPath(self.allocator, segments.items);

        for (self.namespaces.items) |existing| {
            if (!std.mem.eql(u8, existing.path, path)) continue;
            if (std.mem.eql(u8, existing.node_key, key) and std.mem.eql(u8, existing.subpath, entry.subpath)) return true;
            self.fail(.{ .kind = .namespace_conflict, .id = node.id, .version = node.version, .name = path });
            return false;
        }
        try self.namespaces.append(self.allocator, .{
            .path = path,
            .node_key = key,
            .id = node.id,
            .version = node.version,
            .subpath = entry.subpath,
            .commands = entry.commands,
            .constants = entry.constants,
        });
        return true;
    }

    fn addGlobals(self: *Builder, node: resolver.Node, entry: Export) !bool {
        for (entry.commands) |*command| {
            if (self.providers.get(command.name)) |existing| {
                if (!std.mem.eql(u8, existing.id, node.id) or !std.mem.eql(u8, existing.version, node.version)) {
                    self.fail(.{ .kind = .global_command_conflict, .id = node.id, .version = node.version, .name = command.name });
                    return false;
                }
            } else {
                try self.providers.put(command.name, .{ .id = node.id, .version = node.version });
            }
            var duplicate = false;
            for (self.globals.items) |global| {
                if (std.mem.eql(u8, global.name, command.name) and std.mem.eql(u8, global.id, node.id) and std.mem.eql(u8, global.version, node.version)) duplicate = true;
            }
            if (duplicate) continue;
            try self.globals.append(self.allocator, .{
                .name = command.name,
                .id = node.id,
                .version = node.version,
                .subpath = entry.subpath,
                .command = command,
            });
        }
        for (entry.constants) |constant| {
            var duplicate = false;
            for (self.global_constants.items) |existing| {
                if (std.mem.eql(u8, existing.name, constant) and std.mem.eql(u8, existing.id, node.id) and std.mem.eql(u8, existing.version, node.version)) duplicate = true;
            }
            if (duplicate) continue;
            try self.global_constants.append(self.allocator, .{
                .name = constant,
                .id = node.id,
                .version = node.version,
                .subpath = entry.subpath,
            });
        }
        return true;
    }

    fn globalAllowed(self: *Builder, incoming: resolver.Edge, id: []const u8) bool {
        if (!incoming.allow_global_commands) return false;
        if (incoming.from == null) return true;
        for (self.graph.rootEdges()) |root_edge| {
            if (!std.mem.eql(u8, root_edge.id, id)) continue;
            if (root_edge.allow_global_commands) return true;
        }
        return false;
    }

    fn requested(self: *Builder, key: []const u8, subpath: []const u8) bool {
        if (self.requests.len == 0) return true;
        for (self.requests) |request| {
            if (std.mem.eql(u8, request.node_key, key) and std.mem.eql(u8, request.subpath, subpath)) return true;
        }
        return false;
    }

    fn findCommands(self: *Builder, id: []const u8, version: []const u8) ?*const PackageCommands {
        for (self.commands) |*package| {
            if (std.mem.eql(u8, package.id, id) and std.mem.eql(u8, package.version, version)) return package;
        }
        return null;
    }

    fn nodeKey(self: *Builder, node_index: usize) ![]const u8 {
        const node = self.graph.nodes[node_index];
        return std.fmt.allocPrint(self.allocator, "{s}@{s}", .{ node.id, node.version });
    }

    fn fail(self: *Builder, failure: Failure) void {
        self.failure = failure;
    }
};

fn localName(edge: resolver.Edge) []const u8 {
    if (edge.alias) |alias| return alias;
    return packageName(edge.id);
}

fn packageName(id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, id, '/')) |slash| return id[slash + 1 ..];
    return id;
}

fn contains(items: []const []const u8, name: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn joinPath(allocator: Allocator, segments: []const []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (segments, 0..) |segment, index| {
        if (index > 0) try result.append(allocator, '.');
        try result.appendSlice(allocator, segment);
    }
    return result.toOwnedSlice(allocator);
}

fn splitSubpath(allocator: Allocator, subpath: []const u8) ![]const []const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, subpath, ".")) return segments.toOwnedSlice(allocator);
    if (!std.mem.startsWith(u8, subpath, "./")) return error.InvalidSubpath;
    var iterator = std.mem.splitScalar(u8, subpath[2..], '/');
    while (iterator.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidSubpath;
        try segments.append(allocator, segment);
    }
    return segments.toOwnedSlice(allocator);
}
