//! モジュール内部名の生成と拡張子由来モードの判定。

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const token_mod = @import("../frontend/token.zig");
const module_graph = @import("module_graph.zig");

const LoadedModule = module_graph.LoadedModule;

pub fn uniqueInternalModuleName(
    allocator: std.mem.Allocator,
    modules: []*LoadedModule,
    internal_names: []const []const u8,
    assigned: []const bool,
    module_index: u32,
    base_name: []const u8,
    kind: []const u8,
) std.mem.Allocator.Error![]const u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const candidate = if (attempt == 0)
            try std.fmt.allocPrint(allocator, "{s}__lnako_{s}_{d}", .{ base_name, kind, module_index })
        else
            try std.fmt.allocPrint(allocator, "{s}__lnako_{s}_{d}_{d}", .{ base_name, kind, module_index, attempt });
        var collision = false;
        for (modules) |other| {
            if (other.index == module_index) continue;
            if (std.mem.eql(u8, candidate, other.name) or
                (assigned[other.index] and std.mem.eql(u8, candidate, internal_names[other.index])))
            {
                collision = true;
                break;
            }
        }
        if (!collision) return candidate;
    }
}

/// パスの拡張子が強制するDNCL方言モード（.dncl→dncl、.dncl2→dncl2、大小文字無視）。
/// CLI強制フラグとの競合検査（埋め込み実行ファイル生成時の事前検査など）に使う。
pub fn extensionForcedMode(path: []const u8) token_mod.Mode {
    const extension = std.fs.path.extension(path);
    return .{
        .dncl = std.ascii.eqlIgnoreCase(extension, ".dncl"),
        .dncl2 = std.ascii.eqlIgnoreCase(extension, ".dncl2"),
    };
}

// 循環コピー変体・関数内展開の構築は module_graph_variants.zig へ分離している
// （サイズガードレール対応）。Loaderの状態を共有するためpubで公開する。
/// 裸名で取り込める『範囲』の定義を探す。関数の登録はAnalyzerと同じく後勝ち。
pub fn rangeFunctionExported(node: *const ast.Node) ?bool {
    if (node.kind == .import) return null;
    var index = node.children.len;
    while (index > 0) {
        index -= 1;
        if (rangeFunctionExported(node.children[index])) |exported| return exported;
    }
    return if ((node.kind == .function_definition or node.kind == .test_definition) and
        std.mem.eql(u8, node.name, "範囲")) node.is_export else null;
}
