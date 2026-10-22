//! 実効辺（公式のreplaceRequireStatements相当）の決定を担う。
//! module_graph.zig の Loader と状態を共有するため、Loader を引数に取る
//! 自由関数として実装する。

const std = @import("std");
const module_graph = @import("module_graph.zig");

const Loader = module_graph.Loader;

/// 公式のreplaceRequireStatements相当: 各モジュールの取り込み文を逆順に
/// 処理し、filePath単位のガードで最初に処理された辺のみを実効辺にする。
/// エントリ自身はガードへ入れないため、循環取り込みでエントリの内容が
/// 一度だけ再展開される。
pub fn markEffectiveEdges(loader: *Loader, entry: u32) !void {
    const guarded = try loader.allocator.alloc(bool, loader.modules.items.len);
    @memset(guarded, false);
    var order_counter: u32 = 0;
    try markEffectiveIn(loader, entry, guarded, &order_counter);
}

/// `markEffectiveIn`の走査位置。`module.imports`を末尾から先頭へ辿る。
const EffectiveFrame = struct { module: u32, cursor: usize };

/// 実効辺の探索は取り込みの深さだけ深くなる。`loadOne`の深さ上限は
/// 読み込み時に効くが、読み込み済みモジュールを再利用する辺（兄弟が先行を
/// 順に取り込む形）では`loadOne`が浅いままここだけ深くなるため、同じ上限で
/// 明示スタックにしてプロセススタックの枯渇を防ぐ。
fn markEffectiveIn(loader: *Loader, index: u32, guarded: []bool, order_counter: *u32) !void {
    var frames: std.ArrayList(EffectiveFrame) = .empty;
    defer frames.deinit(loader.allocator);
    try frames.append(loader.allocator, .{ .module = index, .cursor = loader.modules.items[index].imports.len });
    while (frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        if (frame.cursor == 0) {
            _ = frames.pop();
            continue;
        }
        frame.cursor -= 1;
        const module = loader.modules.items[frame.module];
        const item = &module.imports[frame.cursor];
        const target = item.target orelse continue;
        const target_module = loader.modules.items[target];
        if (target_module.kind != .nako3 or target_module.parsed == null) continue;
        // Namespace aliases point at a shared loaded module. The effective
        // edge guard ensures each canonical export (or local file) is initialized once.
        if (guarded[target]) continue;
        guarded[target] = true;
        target_module.expand_order = order_counter.*;
        order_counter.* += 1;
        item.effective = true;
        if (frames.items.len >= module_graph.max_import_depth) {
            // 深さ超過はグラフの読み込み失敗として扱う。診断が残るので
            // `succeeded()`が偽になり、呼び出し側が位置付きで表示する。
            try loader.importDiagnosticAt(item.span, module.path, "取り込みの入れ子が深すぎます");
            return;
        }
        try frames.append(loader.allocator, .{ .module = target, .cursor = target_module.imports.len });
    }
}
