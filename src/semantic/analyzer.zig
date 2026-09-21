const std = @import("std");
const ast = @import("../frontend/ast.zig");
const diagnostic = @import("../frontend/diagnostic.zig");
const builtin_catalog = @import("builtin_catalog.zig");
const builtin_josi = @import("builtin_josi.zig");
const argument_completion = @import("argument_completion.zig");
const parser_helpers = @import("../frontend/parser/helpers.zig");
const system_constant = @import("../runtime/system_constant.zig");
const low_level_foundation = @import("../runtime/low_level_foundation.zig");

pub const ScopeId = u32;
pub const SymbolId = u32;

pub const ScopeKind = enum { module, function, anonymous_function };
pub const SymbolKind = enum { variable, constant, function, test_function, parameter, loop_variable };
pub const BindingKind = enum { declaration, reference, call, builtin };

/// 実効取り込み文1件に対応する呼び出し先モジュールのエントリ名。
/// 公式は取り込み文位置へ取り込み先トークンを展開するため、実行時にも
/// その位置で取り込み先のトップレベルが動く必要がある。
pub const ImportEntry = struct {
    position: usize,
    entry_name: []const u8,
    /// 展開順序モデル。公式は取り込み文を取り込み先トークンのコピーで
    /// 置き換えるため、copy-of-M 内の取り込み文は M の展開時に include
    /// guard 済みだったモジュールへのもの（order ≤ order(M)）が除去済み。
    /// 実行時は copy-of-M の内部でのみ到達し得る取り込み呼び出しを
    /// callee_order <= site_order で静的に特定し、サイト側モジュールの
    /// コピー実行中のみ抑止する。
    site_module: u32,
    site_order: u32,
    callee_module: u32,
    callee_order: u32,
    /// サイトが関数本体内にあり、取り込み先トップレベル文が呼び出し元
    /// 関数のローカルスコープへインライン展開される（ast.Node.expansion）。
    /// 循環再展開コピーが文脈別パースを使う場合の、対象モジュール
    /// variants 内のindex（Issue #73）。
    callee_variant: ?u32 = null,
    /// 取り込み文がモジュール直下（関数本体外）にあれば真。直下の文は
    /// ベース/コピーのどちらかのストリームにのみ存在し得るため実行時に
    /// ストリーム判定で抑止する。関数本体内の文は公式では関数本体へ
    /// トークンがインラインされるため到達するたびに常に実行する。
    site_toplevel: bool = false,
};

pub const ModuleInput = struct {
    name: []const u8,
    path: []const u8,
    root: *ast.Node,
    allows_dynamic_commands: bool = false,
    /// root.children と同じ長さの、結合ストリーム上の文順位。
    /// 空ならモジュール内位置をファイル内のspan順で比較する。
    stmt_ranks: []const usize = &.{},
    /// 結合ストリーム上でこのモジュールの展開が始まる順位
    /// （公式のプラグイン名設定マーカー位置）。modList順の名前解決に使う。
    marker_rank: usize = std.math.maxInt(usize),
    /// 実効取り込み文の位置→呼び出し先エントリ名。実行順を公式の
    /// トークン展開に合わせるための情報。
    import_entries: []const ImportEntry = &.{},
    /// このモジュールの実効取り込みサイトが関数本体内にある場合真。
    /// 公式では取り込み先の変数宣言が関数ローカルになるため、
    /// このモジュールの変数系モジュールシンボルはグローバルに存在しない。
    expands_in_function: bool = false,
    /// 循環再展開の文脈別パース（Issue #73）。同じモジュールスコープで
    /// 解析され、変数・関数シンボルは本体と共有される。
    variants: []const VariantInput = &.{},
};

/// 循環再展開コピーの解析対象。本体側と同じモジュールindex・
/// モジュールスコープでresolveBlockへ渡す。
pub const VariantInput = struct {
    root: *ast.Node,
    import_entries: []const ImportEntry,
};

pub const Module = struct {
    name: []const u8,
    path: []const u8,
    scope: ScopeId,
    strict: bool,
};

pub const Scope = struct {
    id: ScopeId,
    parent: ?ScopeId,
    module_index: u32,
    kind: ScopeKind,
};

pub const Symbol = struct {
    id: SymbolId,
    scope: ScopeId,
    module_index: u32,
    kind: SymbolKind,
    name: []const u8,
    qualified_name: []const u8,
    span: ast.Span,
    is_export: bool,
    is_mutable: bool,
    argument_count: usize = 0,
    /// 仮引数の助詞（宣言順）。公式`yCallFunc`と同じ助詞補完で、
    /// どのスロットへ引数を割り当てるかの判定に使う。
    parameter_josi: []const []const u8 = &.{},
    /// 宣言文が他モジュールのシンボルへ解決され、実質的に
    /// 作られなかった暗黙宣言。公式は単一パスで名前を確定するため
    /// 解決済みの参照からも見えない。
    shadowed: bool = false,
};

pub const Binding = struct {
    node: *ast.Node,
    kind: BindingKind,
    name: []const u8,
    resolved_name: []const u8,
    symbol: ?SymbolId,
    /// A command supplied by a native/plugin module rather than the fixed
    /// language builtin catalog. Such calls remain dynamic and must not be
    /// assigned a static compiler dispatch site.
    dynamic_builtin: bool = false,
    /// 実効取り込み文から生成されたモジュールエントリ呼び出しの展開順序情報。
    import_entry: ?ImportEntry = null,
};

pub const FunctionScope = struct {
    node: *ast.Node,
    scope: ScopeId,
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    modules: []Module,
    scopes: []Scope,
    symbols: []Symbol,
    bindings: []Binding,
    function_scopes: []FunctionScope,
    diagnostics: []diagnostic.Diagnostic,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn succeeded(self: Program) bool {
        for (self.diagnostics) |item| if (item.severity == .error_severity) return false;
        return true;
    }

    pub fn findSymbol(self: Program, qualified_name: []const u8) ?Symbol {
        for (self.symbols) |symbol| if (std.mem.eql(u8, symbol.qualified_name, qualified_name)) return symbol;
        return null;
    }
};

pub fn analyze(backing_allocator: std.mem.Allocator, root: *ast.Node, filename: []const u8) !Program {
    const name = try moduleName(backing_allocator, filename);
    defer backing_allocator.free(name);
    return analyzeModules(backing_allocator, &.{.{ .name = name, .path = filename, .root = root }});
}

pub fn analyzeModules(backing_allocator: std.mem.Allocator, inputs: []const ModuleInput) !Program {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    var analyzer = Analyzer{ .allocator = arena.allocator(), .inputs = inputs };
    try analyzer.run();
    // arenaを返却値へコピーする前に確保を済ませる。リテラル内で呼ぶと
    // コピー後のarena状態へ確保が記録されずリークする。
    const modules = try analyzer.modules.toOwnedSlice(analyzer.allocator);
    const scopes = try analyzer.scopes.toOwnedSlice(analyzer.allocator);
    const symbols = try analyzer.symbols.toOwnedSlice(analyzer.allocator);
    const bindings = try analyzer.bindings.toOwnedSlice(analyzer.allocator);
    const function_scopes = try analyzer.function_scopes.toOwnedSlice(analyzer.allocator);
    const diagnostics = try analyzer.diagnostics.toOwnedSlice(analyzer.allocator);
    return .{
        .arena = arena,
        .modules = modules,
        .scopes = scopes,
        .symbols = symbols,
        .bindings = bindings,
        .function_scopes = function_scopes,
        .diagnostics = diagnostics,
    };
}

const Analyzer = struct {
    allocator: std.mem.Allocator,
    inputs: []const ModuleInput,
    modules: std.ArrayList(Module) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    function_scopes: std.ArrayList(FunctionScope) = .empty,
    diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty,
    builtins: std.StringHashMapUnmanaged(void) = .empty,
    /// 公式の`func token`に相当する命令名の全一覧（`デスクトップ`など同名
    /// グローバルを持つ命令名も含む）。代入先に現れたら構文エラーにする
    /// （v3.1.21で廃止された代入的呼出し。`check2(['func','eq'])`相当）。
    function_builtins: std.StringHashMapUnmanaged(void) = .empty,
    /// 公式のmodList相当: 結合ストリーム上の展開マーカー位置順に並ぶ
    /// モジュールindexの一覧。エントリは順位0で常に先頭になる。
    mod_list: std.ArrayList(u32) = .empty,
    /// resolveBlock中のルートに対応する取り込み辺一覧。変体ルートや
    /// 関数内展開の入れ子サイトでは対象側の一覧へ切り替わる。
    active_import_entries: []const ImportEntry = &.{},

    fn run(self: *Analyzer) !void {
        try self.loadBuiltins();
        for (self.inputs, 0..) |input, index| {
            const scope = try self.addScope(null, @intCast(index), .module);
            try self.modules.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, input.name),
                .path = try self.allocator.dupe(u8, input.path),
                .scope = scope,
                .strict = hasStrictMode(input.root),
            });
        }
        for (self.inputs, 0..) |_, index| try self.mod_list.append(self.allocator, @intCast(index));
        std.mem.sort(u32, self.mod_list.items, self, markerRankLess);
        for (self.inputs, 0..) |input, index| try self.predeclareBlock(input.root, @intCast(index), self.modules.items[index].scope, true);
        for (self.inputs, 0..) |input, index| {
            self.active_import_entries = input.import_entries;
            try self.resolveBlock(input.root, @intCast(index), self.modules.items[index].scope);
            // 循環再展開コピー（変体）は同じモジュールスコープで解析し、
            // 変数・関数シンボルを本体側と共有する（公式の再パース相当）。
            for (input.variants) |variant| {
                self.active_import_entries = variant.import_entries;
                try self.resolveBlock(variant.root, @intCast(index), self.modules.items[index].scope);
            }
        }
        self.active_import_entries = &.{};
    }

    fn loadBuiltins(self: *Analyzer) !void {
        for (builtin_catalog.names) |name| try self.builtins.put(self.allocator, name, {});
        for (low_level_foundation.extension_command_names) |name| try self.builtins.put(self.allocator, name, {});
        for ([_][]const u8{ "それ", "対象", "対象キー", "回数", "エラー内容" }) |name| try self.builtins.put(self.allocator, name, {});
        for (builtin_catalog.assign_to_function_names) |name| try self.function_builtins.put(self.allocator, name, {});
    }

    /// 公式は文頭の`func token`＋`=`（および`代入`文の代入先）を関数名への
    /// 代入として拒否する。システム変数（`回数`など）は`func token`ではない
    /// ため対象外にする。修飾名（`__`を含む名前）は一覧に一致しないだけで、
    /// `__DEBUG`のような`__`を含む命令名自体は拒否対象になる。
    fn rejectFunctionTarget(self: *Analyzer, span: ast.Span, module_index: u32, name: []const u8) !bool {
        if (name.len == 0) return false;
        if (self.function_builtins.get(name) == null) return false;
        const message = try std.fmt.allocPrint(self.allocator, "関数『{s}』に代入できません。", .{displayQualifiedName(name)});
        try self.addDiagnostic(.assign_to_function, span, self.modules.items[module_index].path, message);
        return true;
    }

    fn predeclareBlock(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId, recurse: bool) anyerror!void {
        try self.predeclareBlockEx(node, module_index, scope, recurse, false);
    }

    /// expansion=true は関数内取り込みのインライン展開子。変数・定数・
    /// 暗黙宣言は呼び出し元関数のローカルへ宣言するが、関数定義は
    /// 取り込み先モジュールの関数として登録済みのため宣言しない
    /// （resolveBlock側で mod__F シンボルへ束縛する）。
    fn predeclareBlockEx(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId, recurse: bool, expansion: bool) anyerror!void {
        if (node.kind == .function_definition or node.kind == .test_definition) {
            if (!expansion) {
                const symbol_id = try self.declare(module_index, scope, node.name, if (node.kind == .test_definition) .test_function else .function, node.span, node.is_export, false, node.arguments.len, false);
                try self.setParameterJosi(symbol_id, node.arguments);
            }
            return;
        }
        if (node.kind == .anonymous_function) return;
        // 公式はモジュール変数を既定で公開（isExportDefault=true）するため、
        // モジュールスコープの変数はis_export=trueとする。
        const exportable = self.scopes.items[scope].kind == .module;
        if (node.kind == .variable_definition) {
            // `{非公開}`属性はモジュール変数の公開を打ち消す（公式isExport相当）。
            _ = try self.declare(module_index, scope, node.name, if (node.is_const) .constant else .variable, node.span, exportable and node.is_export, !node.is_const, 0, true);
        } else if (node.kind == .variable_list_definition) {
            for (node.arguments) |name| {
                _ = try self.rejectFunctionTarget(name.span, module_index, name.name);
                _ = try self.declare(module_index, scope, name.name, if (node.is_const) .constant else .variable, name.span, exportable and node.is_export, !node.is_const, 0, true);
            }
        } else if ((node.kind == .assignment or node.kind == .increment or
            (node.kind == .array_assignment and node.check_array_init)) and self.builtins.get(node.name) == null and
            !(node.check_array_init and system_constant.isConstant(node.name)) and
            (std.mem.indexOf(u8, node.name, "__") == null or self.scopes.items[scope].kind == .module) and
            self.lookupAssignmentTarget(scope, node.name, node.span) == null)
        {
            _ = try self.declare(module_index, scope, node.name, .variable, node.span, true, true, 0, false);
        } else if (node.kind == .for_statement and node.name.len > 0 and self.lookupLexical(scope, node.name) == null) {
            _ = try self.declare(module_index, scope, node.name, .loop_variable, node.span, exportable, true, 0, false);
        }
        if (!recurse and node.kind == .function_definition) return;
        // expansion 状態は子へ引き継ぐ。制御構文の内側にある展開済み関数定義も
        // 呼び出し元スコープへ宣言せず取り込み先モジュールの登録へ委ねる。
        for (node.children) |child| try self.predeclareBlockEx(child, module_index, scope, recurse and node.kind != .function_definition and node.kind != .test_definition and node.kind != .anonymous_function, expansion);
    }

    fn resolveBlock(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId) !void {
        switch (node.kind) {
            .function_definition, .test_definition => {
                // 関数内取り込みでインライン展開された定義は呼び出し元関数の
                // スコープ内に置かれるが、公式では関数は取り込み先モジュールの
                // 名前でグローバル登録される。字句スコープで見つからなければ
                // 定義側モジュールの関数シンボル（mod__F相当）へ束縛する。
                var declared: ?Symbol = null;
                var def_current: ?ScopeId = scope;
                while (def_current) |id| : (def_current = self.scopes.items[id].parent) {
                    if (self.lookupLexical(id, node.name)) |symbol| {
                        // 他モジュールのモジュールスコープへの一致は、展開
                        // された定義が呼び出し元側の同名関数を指さないよう除外
                        if (self.scopes.items[id].kind == .module and symbol.module_index != module_index) continue;
                        declared = symbol;
                        break;
                    }
                }
                declared = declared orelse self.lookupModule(module_index, node.name);
                if (declared) |symbol| try self.bind(node, .declaration, node.name, symbol.qualified_name, symbol.id);
                const function_scope = try self.addScope(scope, module_index, .function);
                try self.function_scopes.append(self.allocator, .{ .node = node, .scope = function_scope });
                for (node.arguments) |argument| _ = try self.declare(module_index, function_scope, argument.name, .parameter, argument.span, false, true, 0, false);
                for (node.children) |child| try self.predeclareBlock(child, module_index, function_scope, false);
                for (node.children) |child| try self.resolveBlock(child, module_index, function_scope);
                return;
            },
            .anonymous_function => {
                const function_scope = try self.addScope(scope, module_index, .anonymous_function);
                try self.function_scopes.append(self.allocator, .{ .node = node, .scope = function_scope });
                for (node.arguments) |argument| _ = try self.declare(module_index, function_scope, argument.name, .parameter, argument.span, false, true, 0, false);
                for (node.children) |child| try self.predeclareBlock(child, module_index, function_scope, false);
                for (node.children) |child| try self.resolveBlock(child, module_index, function_scope);
                return;
            },
            .assignment, .array_assignment, .property_assignment, .increment, .increment_indexed, .variable_definition => try self.resolveDeclaration(node, module_index, scope),
            .variable_list_definition => {
                for (node.arguments) |name| if (self.lookupLexical(scope, name.name)) |symbol| {
                    try self.bind(node, .declaration, name.name, symbol.qualified_name, symbol.id);
                };
            },
            .word => try self.resolveReference(node, module_index, scope, false),
            .function_call => try self.resolveReference(node, module_index, scope, true),
            .for_statement => if (node.name.len > 0) {
                if (self.lookupLexical(scope, node.name)) |symbol| try self.bind(node, .declaration, node.name, symbol.qualified_name, symbol.id);
            },
            // 実効取り込み文は取り込み先エントリへの呼び出しとして束縛する。
            // 公式のトークン展開と同じ位置でトップレベルが実行される。
            .import => for (self.active_import_entries) |entry| {
                if (entry.position == node.span.start) {
                    var bound_entry = entry;
                    bound_entry.site_toplevel = self.enclosingFunctionScope(scope) == null;
                    // entry_nameは入力側の短命アリーナの値なので複製して保持する
                    bound_entry.entry_name = try self.allocator.dupe(u8, entry.entry_name);
                    if (!bound_entry.site_toplevel) {
                        // 関数内取り込み: 公式は取り込み先トークンをこの位置へ
                        // 展開するため、取り込み先の変数宣言・文は呼び出し元
                        // 関数のローカルになる。呼び出し元スコープのまま
                        // 取り込み先モジュール名（modName相当）で名前解決する。
                        const saved_entries = self.active_import_entries;
                        self.active_import_entries = if (entry.callee_variant) |variant_index|
                            self.inputs[entry.callee_module].variants[variant_index].import_entries
                        else
                            self.inputs[entry.callee_module].import_entries;
                        for (node.expansion) |child| try self.predeclareBlockEx(child, entry.callee_module, scope, true, true);
                        for (node.expansion) |child| try self.resolveBlock(child, entry.callee_module, scope);
                        self.active_import_entries = saved_entries;
                    }
                    try self.bind(node, .call, node.name, bound_entry.entry_name, null);
                    self.bindings.items[self.bindings.items.len - 1].import_entry = bound_entry;
                    break;
                }
            },
            else => {},
        }
        for (node.children) |child| try self.resolveBlock(child, module_index, scope);
    }

    fn resolveDeclaration(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId) !void {
        // 公式は組み込み命令名への代入を構文エラーにする（代入的呼出しの廃止）。
        // 同名のユーザー関数がある場合も公式は単一のエラーなので、ここで
        // 診断したらシンボル解決側では再診断しない。
        if (node.kind == .assignment or node.kind == .variable_definition) {
            if (try self.rejectFunctionTarget(node.span, module_index, node.name)) return;
        }
        // 公式の明示宣言（変数/定数）はfindVarを使わず無条件に変数を作る
        // （createVar相当）。事前宣言した自分自身のシンボルにそのまま束縛する。
        if (node.kind == .variable_definition) {
            if (self.lookupDeclSite(module_index, scope, node.name, node.span)) |symbol|
                try self.bind(node, .declaration, node.name, symbol.qualified_name, symbol.id);
            return;
        }
        // 公式findVarの書き込み側解決: ローカル→自身mod__→modList順。
        var resolved: ?Symbol = self.lookupAssignmentTarget(scope, node.name, node.span) orelse
            self.lookupVisibleModule(module_index, scope, node.name, node.span) orelse
            self.resolveQualified(module_index, scope, node.name, node.span) orelse
            self.lookupModList(module_index, scope, node.name, node.span);
        // 公式convLetPropはコード生成順にfindVarするため、モジュールレベルでも
        // 後続文で宣言される変数はプロパティ代入のルートに使えず
        // 『見当たりません』になる（A$b=1 が A=0 より前に現れる場合など）。
        // 関数本体内の位置依存は moduleSymbolVisible が関数定義位置で処理済み。
        if (resolved) |symbol| {
            if (node.kind == .property_assignment and
                self.scopes.items[symbol.scope].kind == .module and
                self.enclosingFunctionScope(scope) == null and
                self.positionAfter(symbol.module_index, symbol.span, module_index, node.span))
            {
                resolved = null;
            }
        }
        // 解決が他のシンボルへ向いた場合、宣言文自身の暗黙シンボルは
        // 公式では作られないため後続の解決からも隠す。未解決なら
        // 暗黙シンボルそのものが宣言先になる。
        const decl_site = self.lookupDeclSite(module_index, scope, node.name, node.span);
        if (resolved) |symbol| {
            if (decl_site != null and decl_site.?.id != symbol.id)
                self.symbols.items[decl_site.?.id].shadowed = true;
        } else {
            resolved = decl_site;
        }
        const symbol = resolved orelse {
            // 公式convLetProp相当: プロパティ代入（A$b=値）のルート変数は
            // 宣言必須で、未解決なら文法エラーになる。モジュールレベルでは
            // 修飾名、関数内ではそのままの名前で報告される。
            if (node.kind == .property_assignment and self.builtins.get(node.name) == null) {
                const display = if (self.enclosingFunctionScope(scope) != null or
                    std.mem.indexOf(u8, node.name, "__") != null)
                    node.name
                else
                    try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ self.modules.items[module_index].name, node.name });
                // 公式は表示時に main__ 接頭辞を省略する（nako_gen #1223）。
                const shown = if (std.mem.startsWith(u8, display, "main__")) display["main__".len..] else display;
                const message = try std.fmt.allocPrint(self.allocator, "変数『{s}』が見当たりません。", .{shown});
                try self.addDiagnostic(.undefined_symbol, node.span, self.modules.items[module_index].path, message);
                return;
            }
            // 関数本体内で修飾名（mod__A）が未解決のまま代入先になる場合、
            // 公式は __vars の関数ローカルとして扱う。import先を含む可視な
            // モジュールシンボルに一致しなければ関数ローカルへ宣言し、
            // 実行時に同名グローバルへ漏れないようにする。
            if (std.mem.indexOf(u8, node.name, "__") != null and self.builtins.get(node.name) == null and !system_constant.isConstant(node.name)) {
                if (self.enclosingFunctionScope(scope)) |function_scope| {
                    const symbol_id = try self.declare(module_index, function_scope, node.name, .variable, node.span, true, true, 0, false);
                    try self.bind(node, .declaration, node.name, self.symbols.items[symbol_id].qualified_name, symbol_id);
                }
            }
            return;
        };
        // 定数への禁止は再束縛のみ。配列要素・プロパティの書き換えは
        // 公式と同様に定数にも許可する（JSのconst要素変更と同じ）。
        // 公式文言: 『定数「名」は既に定義済みなので、値を代入することは
        // できません』（main__ 接頭辞は #1223 で省略）。
        if ((node.kind == .assignment or node.kind == .increment) and !symbol.is_mutable) {
            const shown = displayQualifiedName(symbol.qualified_name);
            // ユーザー定義関数も公式は『関数『名』に代入できません』で拒否する。
            if (symbol.kind == .function or symbol.kind == .test_function) {
                const message = try std.fmt.allocPrint(self.allocator, "関数『{s}』に代入できません。", .{shown});
                try self.addDiagnostic(.assign_to_function, node.span, self.modules.items[module_index].path, message);
            } else {
                const message = try std.fmt.allocPrint(self.allocator, "定数『{s}』は既に定義済みなので、値を代入することはできません。", .{shown});
                try self.addDiagnostic(.assign_to_constant, node.span, self.modules.items[module_index].path, message);
            }
        }
        try self.bind(node, .declaration, node.name, symbol.qualified_name, symbol.id);
    }

    fn resolveReference(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId, callable: bool) !void {
        const name = if (callable) node.name else node.value;
        if (name.len == 0) return;
        if (self.resolveSymbol(module_index, scope, name, node.span)) |symbol| {
            const implicit_call = !callable and node.kind == .word and (symbol.kind == .function or symbol.kind == .test_function);
            // 公式はfunc tokenをカンマ直前では値として受理しないため、
            // 読み取り側の添字で関数に解決される裸の単語は『配列アクセスで指定ミス』
            if (node.bare_index_word and implicit_call) {
                try self.addDiagnostic(.invalid_array_access, node.span, self.modules.items[module_index].path, "配列アクセスで指定ミス");
                return;
            }
            // C風呼出しは公式同様に個数一致を要求する。助詞呼出しは不足分を
            // 変数「それ」で補完し、公式の条件を満たす2個以上の不足だけを
            // 文法エラーにする（`yCallFunc`のnullCount判定）。
            if (callable and (symbol.kind == .function or symbol.kind == .test_function)) {
                if (node.is_c_style_call) {
                    if (node.children.len != symbol.argument_count) {
                        const message = try std.fmt.allocPrint(self.allocator, "関数『{s}』は引数{d}個を必要としますが、{d}個が指定されました", .{ name, symbol.argument_count, node.children.len });
                        try self.addDiagnostic(.invalid_argument_count, node.span, self.modules.items[module_index].path, message);
                    }
                } else if (symbol.parameter_josi.len > 0) {
                    try self.checkParticleArgumentCount(module_index, node, try argument_completion.parameterSlots(self.allocator, symbol.parameter_josi), false, symbol.qualified_name);
                }
            }
            if (implicit_call and symbol.parameter_josi.len > 0) {
                try self.checkParticleArgumentCount(module_index, node, try argument_completion.parameterSlots(self.allocator, symbol.parameter_josi), false, symbol.qualified_name);
            }
            // 厳格モード: 結合ストリーム上で参照位置より後に宣言される同一
            // モジュールの変数系シンボルは、公式の単一パスでは参照時点で
            // 未定義のため警告対象にする（`Xを表示`→`X=1`の順の場合など）。
            // 束縛は既存シンボルのまま維持する。関数本体内のモジュール変数は
            // moduleSymbolVisible が関数定義位置で不可視判定済みのため、
            // ここに残るのは同一関数ローカルやトップレベルの前方参照だけ。
            if (!callable and self.modules.items[module_index].strict and
                symbol.kind != .function and symbol.kind != .test_function and
                symbol.module_index == module_index and
                self.positionAfter(symbol.module_index, symbol.span, module_index, node.span))
            {
                const message = try std.fmt.allocPrint(self.allocator, "未定義の変数『{s}』です", .{name});
                try self.addWarning(.undefined_symbol, node.span, self.modules.items[module_index].path, message);
            }
            try self.bind(node, if (callable or implicit_call) .call else .reference, name, symbol.qualified_name, symbol.id);
            return;
        }
        if (self.builtins.get(name) != null) {
            // 組み込み命令も公式のfunc token相当のため同じ規則を適用する
            // （『改行』など命令表に無い名前は変数なので対象外）
            if (node.bare_index_word and !callable and builtin_catalog.findArity(name) != null) {
                try self.addDiagnostic(.invalid_array_access, node.span, self.modules.items[module_index].path, "配列アクセスで指定ミス");
                return;
            }
            if (node.is_c_style_call) {
                if (builtin_catalog.findArity(name)) |spec| {
                    if (!spec.is_variable and node.children.len != spec.count) {
                        const message = try std.fmt.allocPrint(
                            self.allocator,
                            "関数『{s}』で引数{d}個が指定されましたが、{d}個の引数を指定してください。",
                            .{ name, node.children.len, spec.count },
                        );
                        try self.addDiagnostic(.invalid_argument_count, node.span, self.modules.items[module_index].path, message);
                    }
                } else if (low_level_foundation.commandArity(name)) |spec| {
                    if (node.children.len < spec.min or node.children.len > spec.max) {
                        const message = if (spec.min == spec.max)
                            try std.fmt.allocPrint(
                                self.allocator,
                                "関数『{s}』で引数{d}個が指定されましたが、{d}個の引数を指定してください。",
                                .{ name, node.children.len, spec.min },
                            )
                        else
                            try std.fmt.allocPrint(
                                self.allocator,
                                "関数『{s}』で引数{d}個が指定されましたが、{d}個以上{d}個以下の引数を指定してください。",
                                .{ name, node.children.len, spec.min, spec.max },
                            );
                        try self.addDiagnostic(.invalid_argument_count, node.span, self.modules.items[module_index].path, message);
                    }
                }
            } else if (callable) {
                // 助詞呼出しの組み込み命令は、公式同様に不足引数を「それ」で
                // 補完し、2個以上不足するときだけ文法エラーにする。
                if (builtin_josi.findJosi(name)) |spec| {
                    try self.checkParticleArgumentCount(module_index, node, try argument_completion.builtinSlots(self.allocator, spec), spec.is_variable, name);
                }
            }
            try self.bind(node, .builtin, name, name, null);
            return;
        }
        if (callable and self.inputs[module_index].allows_dynamic_commands) {
            try self.bind(node, .builtin, name, name, null);
            self.bindings.items[self.bindings.items.len - 1].dynamic_builtin = true;
            return;
        }
        if (self.modules.items[module_index].strict) {
            const message = try std.fmt.allocPrint(self.allocator, "未定義の{s}『{s}』です", .{ if (callable) "命令" else "変数", name });
            // 公式`!厳しくチェック`は未定義の変数を`logger.warn`で警告するだけで
            // 実行を継続する（`warnUndefinedVar`）。未定義の命令呼出しは公式も
            // 文法エラー（`関数『X』が見当たりません`）なのでエラーのままにする。
            if (callable) {
                try self.addDiagnostic(.undefined_symbol, node.span, self.modules.items[module_index].path, message);
                return;
            }
            try self.addWarning(.undefined_symbol, node.span, self.modules.items[module_index].path, message);
        }
        // 関数本体内の未解決名は公式同様に関数ローカル（__vars）へ宣言する。
        // システム定数名は常にグローバルの定数値を参照させるため除外する。
        const module_scope = self.modules.items[module_index].scope;
        const declare_scope = if (system_constant.isConstant(name))
            module_scope
        else
            self.enclosingFunctionScope(scope) orelse module_scope;
        const symbol_id = try self.declare(module_index, declare_scope, name, .variable, node.span, true, true, 0, false);
        const symbol = self.symbols.items[symbol_id];
        try self.bind(node, if (callable) .call else .reference, name, symbol.qualified_name, symbol.id);
    }

    /// 関数内取り込みで展開されるモジュールの変数系モジュールシンボルは、
    /// 公式ではグローバル（__varslist[2]/funclist）に生成されない
    /// （宣言が呼び出し元関数のローカルになる）ため、全ての名前解決
    /// 経路から隠す。関数・テスト関数はグローバル登録されるため対象外。
    fn hiddenModuleVar(self: *Analyzer, symbol: Symbol) bool {
        return self.scopes.items[symbol.scope].kind == .module and
            (symbol.kind == .variable or symbol.kind == .constant or symbol.kind == .loop_variable) and
            symbol.module_index < self.inputs.len and
            self.inputs[symbol.module_index].expands_in_function;
    }

    fn resolveSymbol(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, use_span: ast.Span) ?Symbol {
        var current: ?ScopeId = scope;
        while (current) |id| : (current = self.scopes.items[id].parent) {
            if (self.lookupLexical(id, name)) |symbol| {
                if (self.scopes.items[id].kind == .module and
                    (!self.moduleSymbolVisible(scope, symbol) or self.hiddenModuleVar(symbol))) continue;
                if (self.isDeclSiteSymbol(symbol, module_index, use_span)) continue;
                return symbol;
            }
        }
        // 修飾名（mod__A）は取り込み・公開設定に関わらず全モジュールの
        // モジュール変数に一致する（公式は __varslist[2] を修飾名キーで
        // 共有する）。関数スコープの修飾名シンボルは上の字句探索で
        // 祖先スコープのものだけが解決済みのため、ここでは対象外とする。
        // 公式findVarは `__` 名を funclist 完全一致でのみ検索し、
        // modList 検索には進まない。
        if (std.mem.indexOf(u8, name, "__") != null) {
            for (self.symbols.items) |symbol| {
                if (self.scopes.items[symbol.scope].kind != .module or symbol.shadowed or self.hiddenModuleVar(symbol)) continue;
                if (!std.mem.eql(u8, symbol.qualified_name, name)) continue;
                if (!self.moduleSymbolVisible(scope, symbol)) continue;
                if (self.isDeclSiteSymbol(symbol, module_index, use_span)) continue;
                return symbol;
            }
            return null;
        }
        return self.lookupModList(module_index, scope, name, use_span);
    }

    /// 公式findVarのmodList検索: 結合ストリームの展開マーカー順に各
    /// モジュールの「mod__name」を検索し、export許可かつ使用位置で可視の
    /// 最初の一致を返す（先勝ちで曖昧さエラーは無い）。
    fn lookupModList(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, use_span: ast.Span) ?Symbol {
        if (std.mem.indexOf(u8, name, "__") != null) return null;
        for (self.mod_list.items) |mod_index| {
            if (mod_index == module_index) continue;
            if (self.lookupModule(mod_index, name)) |symbol| {
                if (!symbol.is_export) continue;
                if (!self.moduleSymbolVisibleAt(module_index, use_span, scope, symbol)) continue;
                return symbol;
            }
        }
        return null;
    }

    fn declare(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, kind: SymbolKind, span: ast.Span, is_export: bool, is_mutable: bool, argument_count: usize, explicit_def: bool) !SymbolId {
        if (self.lookupLexical(scope, name)) |existing| {
            // 代入や反復による暗黙宣言は既存変数を再利用するが、
            // 変数/定数の明示定義は同名の再利用も公式同様に二重定義とする。
            if (!explicit_def and existing.kind == kind and (kind == .variable or kind == .loop_variable)) return existing.id;
            const message = try std.fmt.allocPrint(self.allocator, "『{s}』は同じスコープで既に定義されています", .{name});
            try self.addDiagnostic(.duplicate_symbol, span, self.modules.items[module_index].path, message);
            return existing.id;
        }
        const id: SymbolId = @intCast(self.symbols.items.len);
        // 修飾名（mod__A）を直接書いた変数は二重修飾しない。
        // 公式は __varslist[2] のキーをそのままの名前で持つため、
        // 修飾名はそれ自体がグローバルキーになる。
        const qualified = if (self.scopes.items[scope].kind == .module and std.mem.indexOf(u8, name, "__") == null)
            try std.fmt.allocPrint(self.allocator, "{s}__{s}", .{ self.modules.items[module_index].name, name })
        else
            try self.allocator.dupe(u8, name);
        try self.symbols.append(self.allocator, .{
            .id = id,
            .scope = scope,
            .module_index = module_index,
            .kind = kind,
            .name = try self.allocator.dupe(u8, name),
            .qualified_name = qualified,
            .span = span,
            .is_export = is_export,
            .is_mutable = is_mutable,
            .argument_count = argument_count,
        });
        return id;
    }

    /// 公式`yCallFunc`と同じ規則で、助詞呼出しの不足引数を検査する。
    /// 2個以上不足し、かつ公式のエラー条件（引数が1つ以上ある・命令の助詞が
    /// 無い・連文助詞が付く）を満たすときだけ文法エラーにする。
    fn checkParticleArgumentCount(self: *Analyzer, module_index: u32, node: *ast.Node, slots: []const argument_completion.Slot, variable_final: bool, shown_name: []const u8) !void {
        if (slots.len == 0) return;
        const plan = try argument_completion.plan(self.allocator, slots, node.children, variable_final) orelse return;
        if (plan.missing < 2) return;
        if (!(plan.provided > 0 or node.josi.len == 0 or parser_helpers.isSequenceJosi(node.josi))) return;
        const message = try std.fmt.allocPrint(self.allocator, "関数『{s}』の引数が不足しています。", .{displayQualifiedName(shown_name)});
        try self.addDiagnostic(.invalid_argument_count, node.span, self.modules.items[module_index].path, message);
    }

    /// 公式は`main__`接頭辞を診断文言から省略する（#1223）。
    fn displayQualifiedName(qualified_name: []const u8) []const u8 {
        return if (std.mem.startsWith(u8, qualified_name, "main__")) qualified_name["main__".len..] else qualified_name;
    }

    /// 仮引数の助詞（宣言順）をシンボルへ記録する。公式`yCallFunc`の助詞補完で、
    /// 助詞呼出しの引数をどのスロットへ割り当てるかの判定に使う。
    fn setParameterJosi(self: *Analyzer, symbol_id: SymbolId, arguments: []const ast.Argument) !void {
        if (arguments.len == 0) return;
        const symbol = &self.symbols.items[symbol_id];
        if (symbol.kind != .function and symbol.kind != .test_function) return;
        const josi = try self.allocator.alloc([]const u8, arguments.len);
        for (arguments, 0..) |argument, index| josi[index] = argument.josi;
        symbol.parameter_josi = josi;
    }

    fn lookupLexical(self: *Analyzer, scope: ScopeId, name: []const u8) ?Symbol {
        const scope_kind = self.scopes.items[scope].kind;
        var index = self.symbols.items.len;
        while (index > 0) {
            index -= 1;
            const symbol = self.symbols.items[index];
            if (symbol.scope != scope or symbol.shadowed) continue;
            if (scope_kind == .module) {
                // モジュールスコープの変数キーは修飾名（公式の __varslist[2] と同じ）。
                // 「A」と「mod__A」は同じ変数なので qualified_name で一致させる。
                if (std.mem.eql(u8, symbol.qualified_name, name)) return symbol;
                if (std.mem.indexOf(u8, name, "__") == null and
                    self.moduleQualifiedEql(symbol.module_index, symbol.qualified_name, name)) return symbol;
            } else if (std.mem.eql(u8, symbol.name, name)) return symbol;
        }
        return null;
    }

    /// qualified が「{module}__{name}」の形かをアロケーション無しで判定する。
    fn moduleQualifiedEql(self: *Analyzer, module_index: u32, qualified: []const u8, name: []const u8) bool {
        const module_name = self.modules.items[module_index].name;
        return qualified.len == module_name.len + 2 + name.len and
            std.mem.startsWith(u8, qualified, module_name) and
            std.mem.eql(u8, qualified[module_name.len .. module_name.len + 2], "__") and
            std.mem.endsWith(u8, qualified, name);
    }

    /// 宣言文のパース時点では、その文が宣言する変数はまだ存在しない
    /// （公式findVarは単一パスで名前を確定する）。したがって宣言文の
    /// 位置に含まれる使用・代入からは自分自身の宣言シンボルが見えない。
    /// 変数・定数の宣言シンボルのみ対象（関数・引数・ループ変数は除く）。
    fn isDeclSiteSymbol(self: *Analyzer, symbol: Symbol, module_index: u32, use_span: ast.Span) bool {
        _ = self;
        return symbol.module_index == module_index and
            (symbol.kind == .variable or symbol.kind == .constant) and
            symbol.span.start <= use_span.start and use_span.end <= symbol.span.end;
    }

    /// この文自身が暗黙・明示に宣言するシンボルを返す。
    fn lookupDeclSite(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, decl_span: ast.Span) ?Symbol {
        var current: ?ScopeId = scope;
        while (current) |id| : (current = self.scopes.items[id].parent) {
            if (self.lookupLexical(id, name)) |symbol| {
                if (self.isDeclSiteSymbol(symbol, module_index, decl_span)) return symbol;
            }
        }
        return null;
    }

    /// 代入先の探索は公式scopeVar同様に外側スコープまで遡る。
    /// 名前付き関数内でもモジュール変数への代入はグローバルを更新する。
    /// ただし『それ』等のbuiltin名は関数ごとのローカルなので遡らない。
    fn lookupAssignmentTarget(self: *Analyzer, scope: ScopeId, name: []const u8, use_span: ast.Span) ?Symbol {
        const use_module = self.scopes.items[scope].module_index;
        if (self.lookupLexical(scope, name)) |symbol| {
            if (!self.isDeclSiteSymbol(symbol, use_module, use_span)) return symbol;
        }
        if (self.builtins.get(name) != null) return null;
        var current = self.scopes.items[scope].parent;
        while (current) |parent| : (current = self.scopes.items[parent].parent) {
            if (self.lookupLexical(parent, name)) |symbol| {
                if (self.scopes.items[parent].kind == .module and
                    (!self.moduleSymbolVisible(scope, symbol) or self.hiddenModuleVar(symbol))) continue;
                if (self.isDeclSiteSymbol(symbol, use_module, use_span)) continue;
                return symbol;
            }
        }
        return null;
    }

    /// 最も内側の関数スコープ（名前付き・無名）を返す。
    fn enclosingFunctionScope(self: *Analyzer, scope: ScopeId) ?ScopeId {
        var current: ?ScopeId = scope;
        while (current) |id| {
            const kind = self.scopes.items[id].kind;
            if (kind == .function or kind == .anonymous_function) return id;
            current = self.scopes.items[id].parent;
        }
        return null;
    }

    /// modList検索での可視性。公式は単一パスで名前解決するため、
    /// 結合ストリーム上で使用位置より後に宣言されたモジュール変数は
    /// 見えない。関数本体内では関数定義位置が使用位置になる
    /// （関数本体のパース時点で登録済みのシンボルのみが対象）。
    fn moduleSymbolVisibleAt(self: *Analyzer, module_index: u32, use_span: ast.Span, scope: ScopeId, symbol: Symbol) bool {
        if (symbol.kind == .function or symbol.kind == .test_function) return true;
        if (self.enclosingFunctionScope(scope) != null) return self.moduleSymbolVisible(scope, symbol);
        return !self.positionAfter(symbol.module_index, symbol.span, module_index, use_span);
    }

    /// 関数本体内からモジュールスコープの変数へ解決する場合の可視性。
    /// 公式は取り込み先を結合した単一トークン列を単一パスで生成するため、
    /// 結合ストリーム上で関数定義より前に現れたモジュール変数のみを
    /// 修飾名（mod__N）として拾い、後のモジュール変数は関数内から見えない
    /// （同名は関数ローカルの __vars になる）。関数名は __varslist[1] への
    /// 動的解決なので位置に依らない。
    fn moduleSymbolVisible(self: *Analyzer, scope: ScopeId, symbol: Symbol) bool {
        if (symbol.kind == .function or symbol.kind == .test_function) return true;
        const function_scope = self.enclosingFunctionScope(scope) orelse return true;
        for (self.function_scopes.items) |entry| {
            if (entry.scope == function_scope) {
                const function_module = self.scopes.items[function_scope].module_index;
                return !self.positionAfter(symbol.module_index, symbol.span, function_module, entry.node.span);
            }
        }
        return true;
    }

    /// 結合ストリーム上で a が b より後に現れるか。公式は単一パスの
    /// コード生成なので、同一トップレベル文内（順位が同じ場合）でも
    /// ソース位置で先後を区別する必要がある。
    fn positionAfter(self: *Analyzer, a_module: u32, a_span: ast.Span, b_module: u32, b_span: ast.Span) bool {
        const a_rank = self.expansionRank(a_module, a_span);
        const b_rank = self.expansionRank(b_module, b_span);
        if (a_rank != b_rank) return a_rank > b_rank;
        return a_span.start > b_span.start;
    }

    /// spanを含むトップレベル文の結合ストリーム順位を返す。
    /// stmt_ranks が無い入力（単一モジュール解析）ではファイル内位置を返す。
    fn expansionRank(self: *Analyzer, module_index: u32, span: ast.Span) usize {
        const input = self.inputs[module_index];
        const children = input.root.children;
        if (input.stmt_ranks.len == 0 or children.len == 0) return span.start;
        var index: usize = 0;
        while (index + 1 < children.len and children[index + 1].span.start <= span.start) index += 1;
        return input.stmt_ranks[index];
    }

    /// 修飾名（mod__A）で直接書かれた代入先の解決。公式は修飾名そのものを
    /// __varslist のキーとして検索するため、非修飾名の宣言（A=...）が作る
    /// モジュールシンボルにも修飾名で一致し得る。可視性は resolveSymbol の
    /// 位置規則に従う。
    fn resolveQualified(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, use_span: ast.Span) ?Symbol {
        if (std.mem.indexOf(u8, name, "__") == null) return null;
        return self.resolveSymbol(module_index, scope, name, use_span);
    }

    /// lookupModule と同じだが、関数本体内では定義位置より後の
    /// モジュール変数を除外し、宣言文自身のシンボルも除外する。
    fn lookupVisibleModule(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, use_span: ast.Span) ?Symbol {
        const symbol = self.lookupModule(module_index, name) orelse return null;
        if (self.isDeclSiteSymbol(symbol, module_index, use_span)) return null;
        return if (self.moduleSymbolVisible(scope, symbol)) symbol else null;
    }

    fn lookupModule(self: *Analyzer, module_index: u32, name: []const u8) ?Symbol {
        const symbol = self.lookupLexical(self.modules.items[module_index].scope, name) orelse return null;
        return if (self.hiddenModuleVar(symbol)) null else symbol;
    }

    /// mod_list を marker_rank 昇順（同順位は入力順）に並べる比較関数。
    fn markerRankLess(self: *Analyzer, a: u32, b: u32) bool {
        const rank_a = self.inputs[a].marker_rank;
        const rank_b = self.inputs[b].marker_rank;
        if (rank_a != rank_b) return rank_a < rank_b;
        return a < b;
    }

    fn addScope(self: *Analyzer, parent: ?ScopeId, module_index: u32, kind: ScopeKind) !ScopeId {
        const id: ScopeId = @intCast(self.scopes.items.len);
        try self.scopes.append(self.allocator, .{ .id = id, .parent = parent, .module_index = module_index, .kind = kind });
        return id;
    }

    fn bind(self: *Analyzer, node: *ast.Node, kind: BindingKind, name: []const u8, resolved_name: []const u8, symbol: ?SymbolId) !void {
        try self.bindings.append(self.allocator, .{
            .node = node,
            .kind = kind,
            .name = name,
            .resolved_name = resolved_name,
            .symbol = symbol,
        });
    }

    fn addDiagnostic(self: *Analyzer, code: diagnostic.Code, span: ast.Span, file: []const u8, message: []const u8) !void {
        try self.addDiagnosticWithSeverity(code, span, file, message, .error_severity);
    }

    /// 公式`logger.warn`相当の診断。`Program.succeeded()`は真のままなので
    /// コンパイルを止めず、実行を継続する（cnako3の既定logLevelはerrorのため
    /// 警告自体は表示されない）。
    fn addWarning(self: *Analyzer, code: diagnostic.Code, span: ast.Span, file: []const u8, message: []const u8) !void {
        try self.addDiagnosticWithSeverity(code, span, file, message, .warning);
    }

    fn addDiagnosticWithSeverity(self: *Analyzer, code: diagnostic.Code, span: ast.Span, file: []const u8, message: []const u8, severity: diagnostic.Severity) !void {
        try self.diagnostics.append(self.allocator, .{ .severity = severity, .code = code, .span = span, .file = file, .message = message });
    }
};

fn hasStrictMode(root: *ast.Node) bool {
    if (root.kind == .run_mode and std.mem.eql(u8, root.value, "厳しくチェック")) return true;
    for (root.children) |child| if (hasStrictMode(child)) return true;
    return false;
}

pub fn moduleName(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    var basename_start: usize = 0;
    for (filename, 0..) |byte, index| if (byte == '/' or byte == '\\' or byte == ':') {
        basename_start = index + 1;
    };
    const basename = filename[basename_start..];
    // ローダーの拡張子判定（module_graph.loadOne）と同じく大文字小文字を無視する。
    const suffix_length: usize = if (std.ascii.endsWithIgnoreCase(basename, ".nako3"))
        ".nako3".len
    else if (std.ascii.endsWithIgnoreCase(basename, ".dncl2"))
        ".dncl2".len
    else if (std.ascii.endsWithIgnoreCase(basename, ".dncl"))
        ".dncl".len
    else if (std.ascii.endsWithIgnoreCase(basename, ".nako"))
        ".nako".len
    else
        0;
    return allocator.dupe(u8, basename[0 .. basename.len - suffix_length]);
}

test "公式と同じファイル名をモジュール名に保つ" {
    const hyphenated = try moduleName(std.testing.allocator, "dir/system-runtime.nako3");
    defer std.testing.allocator.free(hyphenated);
    try std.testing.expectEqualStrings("system-runtime", hyphenated);

    const windows = try moduleName(std.testing.allocator, "C:\\dir\\a.b.nako");
    defer std.testing.allocator.free(windows);
    try std.testing.expectEqualStrings("a.b", windows);

    const unrelated_extension = try moduleName(std.testing.allocator, "sample.txt");
    defer std.testing.allocator.free(unrelated_extension);
    try std.testing.expectEqualStrings("sample.txt", unrelated_extension);
}

test ".dncl/.dncl2拡張子をモジュール名から除去する" {
    const dncl = try moduleName(std.testing.allocator, "dir/main.dncl");
    defer std.testing.allocator.free(dncl);
    try std.testing.expectEqualStrings("main", dncl);

    const dncl2 = try moduleName(std.testing.allocator, "dir/main.dncl2");
    defer std.testing.allocator.free(dncl2);
    try std.testing.expectEqualStrings("main", dncl2);

    const upper = try moduleName(std.testing.allocator, "dir/LIB.DNCL");
    defer std.testing.allocator.free(upper);
    try std.testing.expectEqualStrings("LIB", upper);
}

test "グローバル・引数・組み込み命令を解決する" {
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=1\n●(Bを)Fとは\nA+Bを表示\nここまで\nF(2)\n", "main.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(program.findSymbol("main__A") != null);
    try std.testing.expect(program.findSymbol("main__F") != null);
    try std.testing.expect(program.findSymbol("main__B") == null);
    var found_builtin = false;
    for (program.bindings) |binding| if (binding.kind == .builtin and std.mem.eql(u8, binding.name, "表示")) {
        found_builtin = true;
    };
    try std.testing.expect(found_builtin);
}

test "無名関数の代入は外側の可変束縛を解決する" {
    const parser = @import("../frontend/parser.zig");
    const source = "●(Aを)作るとは\nF=関数()\nA=A+1\nここまで\nFで戻る\nここまで\n";
    var parsed = try parser.parse(std.testing.allocator, source, "closure.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "closure.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expectEqual(@as(usize, 2), program.function_scopes.len);
    var non_module_a: usize = 0;
    for (program.symbols) |symbol| {
        if (!std.mem.eql(u8, symbol.name, "A")) continue;
        if (program.scopes[symbol.scope].kind == .module) continue;
        non_module_a += 1;
        try std.testing.expectEqual(SymbolKind.parameter, symbol.kind);
    }
    try std.testing.expectEqual(@as(usize, 1), non_module_a);
}

test "静的に解決したユーザー関数の引数個数差を拒否する" {
    const parser = @import("../frontend/parser.zig");
    const source = "●(AとBを)Fとは\nA+Bで戻る\nここまで\nF(1)\nF(1,2,3)\n";
    var parsed = try parser.parse(std.testing.allocator, source, "arity.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "arity.nako3");
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    var count: usize = 0;
    for (program.diagnostics) |item| {
        if (item.code == .invalid_argument_count) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "標準組み込み命令のC形式引数個数を診断し可変引数と助詞構文を許可する" {
    const parser = @import("../frontend/parser.zig");
    const source = "切取(\"a\")\n切取(\"a\",\"b\")\n切取(\"a\",\"b\",\"c\")\n今(1)\n連結()\n連結(1,2)\nCSVオプション設定({})\nAを配列結合\n";
    var parsed = try parser.parse(std.testing.allocator, source, "builtin-arity.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "builtin-arity.nako3");
    defer program.deinit();

    var messages: [3][]const u8 = undefined;
    var count: usize = 0;
    for (program.diagnostics) |item| if (item.code == .invalid_argument_count) {
        try std.testing.expect(count < messages.len);
        messages[count] = item.message;
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, messages.len), count);
    try std.testing.expectEqualStrings("関数『切取』で引数1個が指定されましたが、2個の引数を指定してください。", messages[0]);
    try std.testing.expectEqualStrings("関数『切取』で引数3個が指定されましたが、2個の引数を指定してください。", messages[1]);
    try std.testing.expectEqualStrings("関数『今』で引数1個が指定されましたが、0個の引数を指定してください。", messages[2]);
}

test "低レイヤー命令のC形式引数個数を診断する" {
    const parser = @import("../frontend/parser.zig");
    const source = "ファイル閉(1,2)\nファイル開(\"a\",\"r\",\"x\")\n";
    var parsed = try parser.parse(std.testing.allocator, source, "low-level-arity.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "low-level-arity.nako3");
    defer program.deinit();
    var count: usize = 0;
    for (program.diagnostics) |item| {
        if (item.code == .invalid_argument_count) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "裸の名前付き関数は1引数以下だけ暗黙呼び出しとして解決する" {
    const parser = @import("../frontend/parser.zig");
    const source = "●(Aを)Fとは\nAで戻る\nここまで\n●(AとBを)Gとは\nA+Bで戻る\nここまで\nTYPEOF(F)を表示\nTYPEOF(G)を表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "implicit-call.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "implicit-call.nako3");
    defer program.deinit();
    var implicit_f = false;
    var invalid_count: usize = 0;
    for (program.bindings) |binding| {
        if (binding.kind == .call and std.mem.eql(u8, binding.resolved_name, "implicit-call__F")) implicit_f = true;
    }
    for (program.diagnostics) |item| if (item.code == .invalid_argument_count) {
        invalid_count += 1;
    };
    try std.testing.expect(implicit_f);
    try std.testing.expectEqual(@as(usize, 1), invalid_count);
}

test "未定義変数への増減を暗黙のモジュール変数宣言として解決する" {
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "Aを1増\nAを表示\n", "increment.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "increment.nako3");
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(program.findSymbol("increment__A") != null);
    var declaration_bound = false;
    for (program.bindings) |binding| if (binding.kind == .declaration and std.mem.eql(u8, binding.name, "A") and std.mem.eql(u8, binding.resolved_name, "increment__A")) {
        declaration_bound = true;
    };
    try std.testing.expect(declaration_bound);
}

test "同名の公開シンボルはmodList先勝ちで解決する" {
    // 公式findVarはmodList（エントリ→展開順）で先に一致したモジュールを
    // 選び、曖昧さエラーにはならない。修飾名は常にfunclist完全一致。
    const parser = @import("../frontend/parser.zig");
    var main = try parser.parse(std.testing.allocator, "F\na__F\n", "main.nako3");
    defer main.deinit();
    var first = try parser.parse(std.testing.allocator, "●Fとは\n1で戻る\nここまで\n", "a.nako3");
    defer first.deinit();
    var second = try parser.parse(std.testing.allocator, "●Fとは\n2で戻る\nここまで\n", "b.nako3");
    defer second.deinit();
    var program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "main", .path = "main.nako3", .root = main.root.?, .marker_rank = 0 },
        .{ .name = "a", .path = "a.nako3", .root = first.root.?, .marker_rank = 1 },
        .{ .name = "b", .path = "b.nako3", .root = second.root.?, .marker_rank = 2 },
    });
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var qualified_count: usize = 0;
    for (program.bindings) |binding| if (binding.kind == .call and std.mem.eql(u8, binding.resolved_name, "a__F")) {
        qualified_count += 1;
    };
    // 裸名の F はmodList先勝ちで a__F に、修飾名 a__F も a__F に解決される
    try std.testing.expectEqual(@as(usize, 2), qualified_count);
}

test "取り込んだ公開関数を非修飾名と修飾名で解決する" {
    const parser = @import("../frontend/parser.zig");
    var library = try parser.parse(std.testing.allocator, "●(Aを)二倍とは\nA*2で戻る\nここまで\n", "lib.nako3");
    defer library.deinit();
    var main = try parser.parse(std.testing.allocator, "3を二倍して表示\nlib__二倍(4)を表示\n", "main.nako3");
    defer main.deinit();
    var program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "lib", .path = "lib.nako3", .root = library.root.? },
        .{ .name = "main", .path = "main.nako3", .root = main.root.?, .marker_rank = 1 },
    });
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(program.findSymbol("lib__二倍") != null);
    var imported_calls: usize = 0;
    for (program.bindings) |binding| if (binding.kind == .call and std.mem.eql(u8, binding.resolved_name, "lib__二倍")) {
        imported_calls += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), imported_calls);
}

test "厳チェックの未定義名を警告にし、定数再代入はエラーにする" {
    // 公式`!厳しくチェック`は未定義参照を`logger.warn`で警告するだけで
    // 実行を継続する（終了0・`undefined`表示）。定数再代入はエラーのまま。
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "!厳チェック\n定数 A=1\nA=2\n未宣言値を表示\n", "strict.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "strict.nako3");
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    var undefined_count: usize = 0;
    var const_count: usize = 0;
    for (program.diagnostics) |item| {
        if (item.code == .undefined_symbol) {
            undefined_count += 1;
            try std.testing.expectEqual(diagnostic.Severity.warning, item.severity);
        }
        if (item.code == .assign_to_constant) const_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), undefined_count);
    try std.testing.expectEqual(@as(usize, 1), const_count);

    // 未定義参照だけなら警告に留まり、コンパイルは成功する。
    var warnings_only = try parser.parse(std.testing.allocator, "!厳しくチェック\n「{X}」を表示。\n", "strict-warn.nako3");
    defer warnings_only.deinit();
    var warning_program = try analyze(std.testing.allocator, warnings_only.root.?, "strict-warn.nako3");
    defer warning_program.deinit();
    try std.testing.expect(warning_program.succeeded());
    try std.testing.expectEqual(diagnostic.Severity.warning, warning_program.diagnostics[0].severity);
    try std.testing.expectEqual(diagnostic.Code.undefined_symbol, warning_program.diagnostics[0].code);

    // 未定義名は暗黙宣言され、実行時に`undefined`として読める。
    var bound = false;
    for (warning_program.bindings) |binding| {
        if (binding.kind == .reference and std.mem.eql(u8, binding.name, "X")) bound = std.mem.eql(u8, binding.resolved_name, "strict-warn__X");
    }
    try std.testing.expect(bound);

    // 参照位置より後の代入が作るシンボルへの前方参照も、公式の単一パスでは
    // 参照時点で未定義のため警告する（束縛は後続代入のシンボルのまま）。
    var fwd_parsed = try parser.parse(std.testing.allocator, "!厳チェック\nXを表示\nX=1\nXを表示\n", "strict-fwd.nako3");
    defer fwd_parsed.deinit();
    var fwd_program = try analyze(std.testing.allocator, fwd_parsed.root.?, "strict-fwd.nako3");
    defer fwd_program.deinit();
    try std.testing.expect(fwd_program.succeeded());
    var fwd_warnings: usize = 0;
    for (fwd_program.diagnostics) |item| {
        if (item.code == .undefined_symbol) {
            fwd_warnings += 1;
            try std.testing.expectEqual(diagnostic.Severity.warning, item.severity);
            try std.testing.expectEqual(@as(u32, 1), item.span.line);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fwd_warnings);
    var fwd_bound = false;
    for (fwd_program.bindings) |binding| {
        if (binding.kind == .reference and std.mem.eql(u8, binding.name, "X")) fwd_bound = std.mem.eql(u8, binding.resolved_name, "strict-fwd__X");
    }
    try std.testing.expect(fwd_bound);

    // 未定義の命令呼出しは公式も文法エラー（`関数『X』が見当たりません`）
    // なので、厳格モードでもエラーのままにする。
    var call_parsed = try parser.parse(std.testing.allocator, "!厳しくチェック\n未知命令()\n", "strict-call.nako3");
    defer call_parsed.deinit();
    var call_program = try analyze(std.testing.allocator, call_parsed.root.?, "strict-call.nako3");
    defer call_program.deinit();
    try std.testing.expect(!call_program.succeeded());
    try std.testing.expectEqual(diagnostic.Code.undefined_symbol, call_program.diagnostics[0].code);
    try std.testing.expectEqual(diagnostic.Severity.error_severity, call_program.diagnostics[0].severity);
}

test "組み込み命令名と関数名への代入を診断する" {
    // 公式は`func token`＋`=`を代入的呼出しの名残として構文エラーにする。
    const parser = @import("../frontend/parser.zig");
    const sources = [_][]const u8{
        "INT=3.5\n", // 代入
        "INTに2を代入\n", // 代入文
        "変数 INT=1\n", // 変数宣言
        "今とは定数=1\n", // とは宣言
        "変数 [INT,A]=[1,2]\n", // 変数一覧宣言
        "デスクトップ=1\n", // 同名グローバルを持つ命令名（連鎖呼出し一覧からは除外されるが`func token`）
        "__DEBUG=1\n", // `__`を含む命令名
    };
    for (sources) |source| {
        var parsed = try parser.parse(std.testing.allocator, source, "function-target.nako3");
        defer parsed.deinit();
        var program = try analyze(std.testing.allocator, parsed.root.?, "function-target.nako3");
        defer program.deinit();
        try std.testing.expect(!program.succeeded());
        try std.testing.expectEqual(diagnostic.Code.assign_to_function, program.diagnostics[0].code);
        try std.testing.expectEqual(@as(u32, 1), program.diagnostics[0].span.line + 1);
    }

    // システム変数（`func token`ではない）と通常の変数は代入できる。
    const allowed = [_][]const u8{ "回数=1\n", "A=1\nA=2\n" };
    for (allowed) |source| {
        var parsed = try parser.parse(std.testing.allocator, source, "function-target-ok.nako3");
        defer parsed.deinit();
        var program = try analyze(std.testing.allocator, parsed.root.?, "function-target-ok.nako3");
        defer program.deinit();
        try std.testing.expect(program.succeeded());
    }

    // ユーザー定義関数への代入も公式と同じく関数として報告する。
    var parsed = try parser.parse(std.testing.allocator, "●Fとは\n1で戻る\nここまで\nF=1\n", "user-function-target.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "user-function-target.nako3");
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    try std.testing.expectEqual(diagnostic.Code.assign_to_function, program.diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 4), program.diagnostics[0].span.line + 1);

    // 組み込み名と同名のユーザー関数への代入は、公式の単一エラーと同じく
    // 診断を1件だけ出す（命令名とシンボルの両経路で重複させない）。
    {
        var dup_parsed = try parser.parse(std.testing.allocator, "●INTとは\n1で戻る\nここまで\nINT=1\n", "dup-function-target.nako3");
        defer dup_parsed.deinit();
        var dup_program = try analyze(std.testing.allocator, dup_parsed.root.?, "dup-function-target.nako3");
        defer dup_program.deinit();
        try std.testing.expect(!dup_program.succeeded());
        try std.testing.expectEqual(diagnostic.Code.assign_to_function, dup_program.diagnostics[0].code);
        try std.testing.expectEqual(@as(usize, 1), dup_program.diagnostics.len);
    }
}
