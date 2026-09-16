//! 循環取り込みの文脈別コピー変体と関数内取り込みのインライン展開を構築する。
//! module_graph.zig の Loader と状態を共有するため、ここでは Loader を
//! 引数に取る自由関数として実装する（Issue #73 / #74）。

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const parser = @import("../frontend/parser.zig");
const token_mod = @import("../frontend/token.zig");
const module_graph = @import("module_graph.zig");

const Loader = module_graph.Loader;
const Import = module_graph.Import;
const LoadedModule = module_graph.LoadedModule;
const orMode = module_graph.orMode;
const modeEql = module_graph.modeEql;

/// 循環取り込みの再展開コピーに文脈別のエントリ変体を構築する。
/// 公式は循環取り込み位置で有効だったモードを初期モードとして対象の
/// 変換済みトークンを再解析する。コピー内で実行される入れ子の実効辺
/// （対象がコピー元より後に展開される辺）でも同じずれが起き得るため、
/// （モジュール, 初期モード）単位の変体として再帰的に用意する。
/// 変数・関数シンボルは本体側と同一モジュールスコープで共有される。
pub fn buildCopyVariants(loader: *Loader) !void {
    for (loader.modules.items) |module| {
        for (module.imports) |*item| {
            if (!item.effective or !item.cyclic) continue;
            item.variant = try variantForSite(loader, item.target.?, item.site_mode, module.path, item.span);
        }
    }
}

/// コピーの解析開始モード（取り込み文位置のモード）が対象の本体側
/// 解析開始モード（初期＋強制）と異なる場合、またはコピー内で除去
/// される実効辺が本体側の解析へtailモードを残していた場合に変体を
/// 構築し、対象モジュール variants 内のindexを返す。共有本体の
/// 解析結果がコピーと一致する場合は null を返す。
fn variantForSite(loader: *Loader, target: u32, ambient: token_mod.Mode, site_path: []const u8, site_span: ast.Span) anyerror!?u32 {
    const target_module = loader.modules.items[target];
    const target_start = orMode(target_module.parse_initial, target_module.forced_mode);
    // 拡張子由来の強制モードはファイルの属性なのでコピー側でも有効。
    // 共有判定は文脈モードへ強制分を重ねた実効開始モードで比較する。
    const effective_initial = orMode(ambient, target_module.forced_mode);
    var shareable = modeEql(effective_initial, target_start);
    if (shareable) {
        // コピーでは、コピー元より先に展開済みのモジュールへの取り込み
        // 文が除去される。その辺が本体側の解析で後続文へ残したtail
        // モードがコピーの初期モードに未包含なら、コピーの途中モードは
        // 本体と異なる。モードは単調に有効化されるため、包含されてい
        // るtailの除去は後続へ影響しない。
        for (target_module.imports) |item| {
            if (!item.effective) continue;
            const nested = loader.modules.items[item.target.?];
            if (nested.expand_order > target_module.expand_order) continue;
            if ((item.tail_mode.dncl and !effective_initial.dncl) or
                (item.tail_mode.dncl2 and !effective_initial.dncl2) or
                (item.tail_mode.indent and !effective_initial.indent))
            {
                shareable = false;
                break;
            }
        }
    }
    if (shareable) return null;
    for (target_module.variants.items, 0..) |variant, index| {
        if (modeEql(variant.initial_mode, effective_initial)) return @intCast(index);
    }
    // 第1パスは初期モードのみで、取り込み文位置と文由来モードを得る。
    // コピー内で実行される入れ子辺の終端モードは位置へ適用し直す。
    const probe = parser.parseWithMode(loader.backing_allocator, target_module.source, target_module.path, .{
        .forced = target_module.forced_mode,
        .initial = effective_initial,
    }) catch |err| {
        try loader.importDiagnosticAt(site_span, site_path, "循環取り込みの再展開コピーを文脈の構文モードで解析できません");
        return err;
    };
    // 文を持たない対象はコピーしても同じ結果になるため共有本体を使う。
    if (probe.root == null) {
        var probe_mut = probe;
        probe_mut.deinit();
        return null;
    }
    const variant_index: u32 = @intCast(target_module.variants.items.len);
    // 循環で自分自身へ戻る辺があっても終了するよう、解析前に登録する。
    try target_module.variants.append(loader.allocator, .{
        .initial_mode = effective_initial,
        .parse = probe,
        .imports = try loader.allocator.dupe(Import, target_module.imports),
    });
    var tail_modes: std.ArrayList(parser.TailMode) = .empty;
    var cumulative: token_mod.Mode = .{};
    for (target_module.variants.items[variant_index].imports) |*vitem| {
        if (!vitem.effective) continue;
        const nested = loader.modules.items[vitem.target.?];
        // ベース側の辺（対象がコピー元より先に展開済み）はコピー内で
        // 除去されるため、コピーの解析モードへも実行にも寄与しない。
        if (nested.expand_order <= target_module.expand_order) continue;
        var site_mode = cumulative;
        for (probe.import_modes) |record| {
            if (record.position == vitem.span.start) {
                site_mode = orMode(site_mode, record.own_mode);
                break;
            }
        }
        vitem.site_mode = site_mode;
        vitem.variant = try variantForSite(loader, vitem.target.?, site_mode, target_module.path, vitem.span);
        const tail = if (vitem.variant) |nested_index|
            nested.variants.items[nested_index].parse.final_mode
        else if (nested.parsed) |nested_parsed|
            nested_parsed.final_mode
        else
            token_mod.Mode{};
        cumulative = orMode(cumulative, tail);
        vitem.tail_mode = tail;
        try tail_modes.append(loader.allocator, .{ .position = vitem.span.start, .mode = tail });
    }
    if (tail_modes.items.len > 0) {
        const reparsed = parser.parseWithMode(loader.backing_allocator, target_module.source, target_module.path, .{
            .forced = target_module.forced_mode,
            .initial = ambient,
            .tail_modes = tail_modes.items,
        }) catch |err| {
            try loader.importDiagnosticAt(site_span, site_path, "循環取り込みの再展開コピーを文脈の構文モードで解析できません");
            return err;
        };
        target_module.variants.items[variant_index].parse.deinit();
        target_module.variants.items[variant_index].parse = reparsed;
    }
    return variant_index;
}

/// 関数本体内の実効取り込み文へ、取り込み先トップレベル文の複製を接続する。
/// 公式は取り込み先トークンをその位置へ展開するため、関数内では
/// 取り込み先の変数宣言・文が呼び出し元関数のローカルになる。
/// 複製内の取り込み文も関数内へ落ちるため再帰的に展開を接続する。
pub fn attachInlineExpansions(loader: *Loader, entry: u32) !void {
    for (loader.modules.items) |module| {
        const parsed = module.parsed orelse continue;
        const root = parsed.root orelse continue;
        try attachSiteExpansions(loader, module.imports, root, false, entry);
        for (module.variants.items) |*variant| {
            const vroot = variant.parse.root orelse continue;
            try attachSiteExpansions(loader, variant.imports, vroot, false, entry);
        }
    }
}

fn attachSiteExpansions(loader: *Loader, imports: []Import, node: *ast.Node, in_function: bool, entry: u32) !void {
    if (node.kind == .import and in_function) {
        for (imports) |*item| {
            if (item.span.start != node.span.start) continue;
            if (item.effective) if (item.target) |target| {
                const target_module = loader.modules.items[target];
                // エントリモジュールは本体側のトップレベル実行で変数が
                // グローバル生成済みのため、コピー内でも隠さない。
                if (target_module.kind == .nako3) {
                    if (target != entry) target_module.expands_in_function = true;
                    const chain = try loader.allocator.alloc(bool, loader.modules.items.len);
                    @memset(chain, false);
                    node.expansion = try copyExpansion(loader, target_module, item.variant, entry, chain);
                }
            };
            break;
        }
    }
    const child_in_function = in_function or node.kind == .function_definition or
        node.kind == .test_definition or node.kind == .anonymous_function;
    for (node.children) |child| try attachSiteExpansions(loader, imports, child, child_in_function, entry);
}

/// 実効取り込みサイト用に、取り込み先トップレベル文を複製する。
/// 複製内の取り込み文は全て関数内へ落ちるため、実効辺には再帰的に
/// 展開を接続する。chain はこの展開系で複製中のモジュールを表し、
/// 公式のfilePathガード相当として系内で既出の対象への辺は
/// 展開しない（取り込み文は残るが展開子は空＝実行時に何もしない）。
fn copyExpansion(loader: *Loader, module: *LoadedModule, variant_index: ?u32, entry: u32, chain: []bool) anyerror![]const *ast.Node {
    if (chain[module.index]) return &.{};
    chain[module.index] = true;
    defer chain[module.index] = false;
    const imports = if (variant_index) |v| module.variants.items[v].imports else module.imports;
    const root = if (variant_index) |v| module.variants.items[v].parse.root else module.parsed.?.root;
    const source_root = root orelse return &.{};
    const children = try loader.allocator.alloc(*ast.Node, source_root.children.len);
    for (source_root.children, 0..) |child, index| children[index] = try copySubtree(loader, child);
    for (children) |child| try attachCopyExpansions(loader, imports, child, entry, chain);
    return children;
}

fn attachCopyExpansions(loader: *Loader, imports: []Import, node: *ast.Node, entry: u32, chain: []bool) !void {
    if (node.kind == .import and node.expansion.len == 0) {
        for (imports) |*item| {
            if (item.span.start != node.span.start) continue;
            if (item.effective) if (item.target) |target| {
                const target_module = loader.modules.items[target];
                if (target_module.kind == .nako3 and !chain[target]) {
                    if (target != entry) target_module.expands_in_function = true;
                    node.expansion = try copyExpansion(loader, target_module, item.variant, entry, chain);
                }
            };
            break;
        }
    }
    // node.expansion は copyExpansion で作成時に対象モジュール自身の辺で
    // 処理済み。ここで外側モジュールのimportsで再走査すると、循環ガードで
    // 空にした取り込み文が位置一致で別対象として再展開され無限再帰する。
    for (node.children) |child| try attachCopyExpansions(loader, imports, child, entry, chain);
}

fn copySubtree(loader: *Loader, node: *ast.Node) anyerror!*ast.Node {
    const copy = try loader.allocator.create(ast.Node);
    copy.* = node.*;
    if (node.children.len > 0) {
        const children = try loader.allocator.alloc(*ast.Node, node.children.len);
        for (node.children, 0..) |child, index| children[index] = try copySubtree(loader, child);
        copy.children = children;
    }
    if (node.arguments.len > 0) copy.arguments = try loader.allocator.dupe(ast.Argument, node.arguments);
    if (node.expansion.len > 0) {
        const expansion = try loader.allocator.alloc(*ast.Node, node.expansion.len);
        for (node.expansion, 0..) |child, index| expansion[index] = try copySubtree(loader, child);
        copy.expansion = expansion;
    }
    return copy;
}
