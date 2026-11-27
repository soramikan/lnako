//! 取り込み展開順位と構文モード伝搬の補助処理。

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const token_mod = @import("../frontend/token.zig");
const module_graph = @import("module_graph.zig");

const LoadedModule = module_graph.LoadedModule;
const Expansion = module_graph.Expansion;

pub const ModeState = enum { unvisited, visiting, done };

pub fn orMode(a: token_mod.Mode, b: token_mod.Mode) token_mod.Mode {
    return .{
        .dncl = a.dncl or b.dncl,
        .dncl2 = a.dncl2 or b.dncl2,
        .indent = a.indent or b.indent,
    };
}

pub fn modeEql(a: token_mod.Mode, b: token_mod.Mode) bool {
    return a.dncl == b.dncl and a.dncl2 == b.dncl2 and a.indent == b.indent;
}

/// aのモードbitが全てbに含まれるか
pub fn modeSubset(a: token_mod.Mode, b: token_mod.Mode) bool {
    return (!a.dncl or b.dncl) and (!a.dncl2 or b.dncl2) and (!a.indent or b.indent);
}

/// 結合ストリーム上の文順位をDFSで構築する。公式の取り込みは先勝ちの
/// include guard付きトークン置換なので、各モジュールの内容は最初の実効
/// 取り込み辺の位置に一度だけ展開される。文内部の取り込み文はその文の
/// 位置に展開されるものとして近似する。
pub fn buildExpansion(allocator: std.mem.Allocator, modules: []*LoadedModule, entry: u32) !Expansion {
    const stmt_ranks = try allocator.alloc([]usize, modules.len);
    const marker_ranks = try allocator.alloc(usize, modules.len);
    const visited = try allocator.alloc(bool, modules.len);
    @memset(visited, false);
    @memset(marker_ranks, std.math.maxInt(usize));
    for (modules, 0..) |module, index| {
        const count: usize = if (module.kind == .nako3 and module.parsed != null and module.parsed.?.root != null)
            module.parsed.?.root.?.children.len
        else
            0;
        stmt_ranks[index] = try allocator.alloc(usize, count);
        @memset(stmt_ranks[index], std.math.maxInt(usize));
    }
    var rank: usize = 0;
    try expandModule(allocator, modules, entry, visited, stmt_ranks, marker_ranks, &rank);
    return .{ .stmt_ranks = stmt_ranks, .marker_ranks = marker_ranks };
}

pub fn expandModule(allocator: std.mem.Allocator, modules: []*LoadedModule, index: u32, visited: []bool, stmt_ranks: []const []usize, marker_ranks: []usize, rank: *usize) !void {
    if (visited[index]) return;
    visited[index] = true;
    // 公式は展開先頭にプラグイン名設定マーカーを挿し、modListはその出現順に並ぶ
    marker_ranks[index] = rank.*;
    const module = modules[index];
    if (module.kind != .nako3 or module.parsed == null or module.parsed.?.root == null) return;
    for (module.parsed.?.root.?.children, 0..) |child, k| {
        if (effectiveImportTarget(module, child.span.start)) |target| {
            try expandModule(allocator, modules, target, visited, stmt_ranks, marker_ranks, rank);
            continue;
        }
        stmt_ranks[index][k] = rank.*;
        rank.* += 1;
        // 文内部の取り込み文は、その文の直後へ展開されるものとして扱う
        var nested: std.ArrayList(*ast.Node) = .empty;
        try collectImports(child, &nested, allocator);
        for (nested.items) |node| {
            if (effectiveImportTarget(module, node.span.start)) |target| {
                try expandModule(allocator, modules, target, visited, stmt_ranks, marker_ranks, rank);
            }
        }
    }
}

/// 指定位置の取り込み文が実効辺なら取り込み先モジュールのindexを返す。
pub fn effectiveImportTarget(module: *LoadedModule, position: usize) ?u32 {
    for (module.imports) |item| {
        if (item.span.start == position and item.effective and item.target != null) return item.target;
    }
    return null;
}

pub fn isNativeBuiltinPlugin(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    const names = [_][]const u8{
        "plugin_httpserver.mjs",
        "plugin_httpserver.js",
        "plugin_markup.mjs",
        "plugin_markup.js",
        "plugin_csv.mjs",
        "plugin_csv.js",
        "plugin_toml.mjs",
        "plugin_toml.js",
        "plugin_caniuse.mjs",
        "plugin_caniuse.js",
        "plugin_kansuji.mjs",
        "plugin_kansuji.js",
        "plugin_datetime.mjs",
        "plugin_datetime.js",
    };
    for (names) |name| if (std.ascii.eqlIgnoreCase(basename, name)) return true;
    return false;
}

pub fn collectImports(node: *ast.Node, output: *std.ArrayList(*ast.Node), allocator: std.mem.Allocator) !void {
    if (node.kind == .import) try output.append(allocator, node);
    for (node.children) |child| try collectImports(child, output, allocator);
}
