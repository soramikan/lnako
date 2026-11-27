//! 名前解決処理（シンボル検索・修飾名解決・可視性判定）。
//! `Analyzer` の状態を読むだけで、解析結果の意味は変更しない。

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const builtin_catalog = @import("builtin_catalog.zig");
const builtin_josi = @import("builtin_josi.zig");
const argument_completion = @import("argument_completion.zig");
const unresolved_words = @import("unresolved_words.zig");
const system_constant = @import("../runtime/system_constant.zig");
const dynamic_commands = @import("dynamic_commands.zig");
const low_level_foundation = @import("../runtime/low_level_foundation.zig");
const package_commands = @import("package_commands.zig");
const analyzer_mod = @import("analyzer.zig");

const Analyzer = analyzer_mod.Analyzer;
const ScopeId = analyzer_mod.ScopeId;
const SymbolId = analyzer_mod.SymbolId;
const Symbol = analyzer_mod.Symbol;
const NamespaceAlias = analyzer_mod.NamespaceAlias;

pub fn resolveReference(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId, callable: bool) !void {
    const name = if (callable) node.name else node.value;
    if (name.len == 0) return;
    var pkg_ctx = try package_commands.DeclaredCommandContext.init(self, module_index, node, name, callable);
    if (self.resolveSymbol(module_index, scope, name, node.span)) |symbol| {
        if (try pkg_ctx.checkMatchedSymbol(self, module_index, scope, node, name, callable, symbol)) return;
        // 候補が関数なら実引数付きの呼出しとして従来どおり解決する。
        // 変数・定数など関数以外なら、保留した実引数を診断する。
        if (symbol.kind != .function and symbol.kind != .test_function and
            try self.rejectPendingReturnArguments(node, module_index)) return;
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
        // 演算子由来の疑似呼出し（範囲など`command_call`でもC風呼出しでも
        // ないfunction_call）は助詞呼出しではないため個数検査の対象外。
        // その子は演算子のオペランドであって助詞引数ではない。
        if (!pkg_ctx.gate and callable and (node.command_call or node.is_c_style_call) and (symbol.kind == .function or symbol.kind == .test_function)) {
            if (node.is_c_style_call) {
                if (node.children.len != symbol.argument_count) {
                    const message = try std.fmt.allocPrint(self.allocator, "関数『{s}』は引数{d}個を必要としますが、{d}個が指定されました", .{ name, symbol.argument_count, node.children.len });
                    try self.addDiagnostic(.invalid_argument_count, node.span, self.modules.items[module_index].path, message);
                }
            } else if (symbol.parameter_josi.len > 0) {
                try self.checkParticleArgumentCount(module_index, scope, node, try argument_completion.parameterSlots(self.allocator, symbol.parameter_josi), false, symbol.qualified_name);
            } else {
                // 宣言引数を持たない関数へ助詞引数を渡した場合、公式は
                // 全て未解決の単語として文法エラーにする（Issue #108）。
                try unresolved_words.deferUnresolvedArguments(self, module_index, scope, node, &.{}, false);
            }
        }
        if (!pkg_ctx.gate and implicit_call and symbol.parameter_josi.len > 0) {
            try self.checkParticleArgumentCount(module_index, scope, node, try argument_completion.parameterSlots(self.allocator, symbol.parameter_josi), false, symbol.qualified_name);
        } else if (!pkg_ctx.gate and implicit_call and symbol.parameter_josi.len == 0) {
            try unresolved_words.deferUnresolvedArguments(self, module_index, scope, node, &.{}, false);
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
    try pkg_ctx.checkWithoutSymbol(self, module_index, scope, node, name, callable);
    if (self.builtins.get(name) != null) {
        // システム定数を関数として呼ぶ公式エラーを再現する。
        if (try unresolved_words.rejectNonCallableBuiltin(self, module_index, node, name)) return;
        // 値として解決する組み込み（`改行`・`それ`等）でも、戻る直前に
        // 保留した実引数があれば捨てずに非関数候補と同じ未解決引数へする。
        // 実命令は後段の従来の引数照合へ通し、引数なしの戻りは通す。
        if (!analyzer_mod.builtinIsCallable(name) and
            try self.rejectPendingReturnArguments(node, module_index)) return;
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
        } else if ((callable and (node.command_call or node.is_c_style_call)) or (node.kind == .word and builtin_catalog.findArity(name) != null)) {
            // 助詞呼出し・値位置の裸の組み込み命令は、公式同様に不足引数を
            // 「それ」で補完し、2個以上不足するときだけ文法エラーにする。
            if (builtin_josi.findJosi(name)) |spec| {
                try self.checkParticleArgumentCount(module_index, scope, node, try argument_completion.builtinSlots(self.allocator, spec), spec.is_variable, name);
            } else if (builtin_catalog.findArity(name)) |arity| {
                // 宣言引数を持たない組み込み命令（`空配列`など）への実引数も
                // 公式は未解決の単語にする（Issue #108）。助詞スロット表に
                // 無い独自拡張命令は対象外とし、個数表の arity==0 で判定する。
                if (arity.count == 0 and !arity.is_variable)
                    try unresolved_words.deferUnresolvedArguments(self, module_index, scope, node, &.{}, false);
            }
        }
        try self.bind(node, .builtin, name, name, null);
        return;
    }
    // 静的に読み取れる動的命令（package/ESM pluginのalias）は、`.word`
    // の戻り値候補でも実引数付き呼出しとして従来どおり束縛する。任意名を
    // 受理するcatch-allは読み取れた命令ではないため候補にしない。
    const pending_word_candidate = node.kind == .word and node.pending_return_arguments;
    if (callable or pending_word_candidate) {
        const module_input = self.inputs[module_index];
        // 直接取り込んだ ESM/native plugin は、取り込み位置以降の未知命令を
        // 実行時登録へ委ねる。戻る直前の候補も同じ可視範囲で動的命令へ
        // 束縛し、実引数を既存の call lowering で渡す。取り込み位置より
        // 前・取り込みなしは `binds` が null を返すため従来どおり診断する。
        if (try dynamic_commands.bindsWithFallbacks(self.allocator, module_input.allows_dynamic_commands, module_input.allows_dynamic_commands_from, module_input.dynamic_command_aliases, name, node.span.start)) |resolution| {
            try self.bind(node, .builtin, name, resolution.resolved_name, null);
            const binding = &self.bindings.items[self.bindings.items.len - 1];
            binding.dynamic_builtin = true;
            binding.fallback_names = resolution.fallback_names;
            return;
        }
    }
    if (try pkg_ctx.handleUnresolved(self, module_index, node, name)) return;
    if (callable and !pkg_ctx.isUninspectedCall()) {
        try unresolved_words.rejectUndefinedCommand(self, module_index, node, name);
        return;
    }
    // 未定義名の候補でも、保留した実引数があれば未定義変数ではなく
    // 『戻』文の未解決引数として診断する（両方を混同しない）。
    if (try self.rejectPendingReturnArguments(node, module_index)) return;
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

/// `{関数}名` の関数参照を解決する。公式は字句解析時に funclist で直後の
/// 名前を `func_pointer` へ変換するため、ユーザー定義関数（取り込み
/// モジュール含む）・組み込み命令のいずれにも解決できない名前は
/// 『関数の定義でエラー』相当の診断にする。
/// `{関数}名` の関数参照を解決する。公式は字句解析時に funclist で直後の
/// 名前を `func_pointer` へ変換するため、ユーザー定義関数（取り込み
/// モジュール含む）・組み込み命令のいずれにも解決できない名前は
/// 『関数の定義でエラー』相当の診断にする。
pub fn resolveFunctionPointer(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId) !void {
    const name = node.name;
    if (name.len == 0) return;
    if (self.resolveSymbol(module_index, scope, name, node.span)) |symbol| {
        if (symbol.kind == .function or symbol.kind == .test_function) {
            try self.bind(node, .call, name, symbol.qualified_name, symbol.id);
            return;
        }
    }
    for (builtin_catalog.assign_to_function_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            try self.bind(node, .builtin, name, name, null);
            return;
        }
    }
    const function_input = self.inputs[module_index];
    if (try dynamic_commands.bindsWithFallbacks(self.allocator, function_input.allows_dynamic_commands, function_input.allows_dynamic_commands_from, function_input.dynamic_command_aliases, name, node.span.start)) |resolution| {
        try self.bind(node, .builtin, name, resolution.resolved_name, null);
        const binding = &self.bindings.items[self.bindings.items.len - 1];
        binding.dynamic_builtin = true;
        binding.fallback_names = resolution.fallback_names;
        return;
    }
    const message = try std.fmt.allocPrint(self.allocator, "『{{関数}}』の参照先『{s}』は関数として見つかりません", .{name});
    try self.addDiagnostic(.undefined_symbol, node.span, self.modules.items[module_index].path, message);
}

/// 関数内取り込みで展開されるモジュールの変数系モジュールシンボルは、
/// 公式ではグローバル（__varslist[2]/funclist）に生成されない
/// （宣言が呼び出し元関数のローカルになる）ため、全ての名前解決
/// 経路から隠す。関数・テスト関数はグローバル登録されるため対象外。
/// 関数内取り込みで展開されるモジュールの変数系モジュールシンボルは、
/// 公式ではグローバル（__varslist[2]/funclist）に生成されない
/// （宣言が呼び出し元関数のローカルになる）ため、全ての名前解決
/// 経路から隠す。関数・テスト関数はグローバル登録されるため対象外。
pub fn hiddenModuleVar(self: *Analyzer, symbol: Symbol) bool {
    return self.scopes.items[symbol.scope].kind == .module and
        (symbol.kind == .variable or symbol.kind == .constant or symbol.kind == .loop_variable) and
        symbol.module_index < self.inputs.len and
        self.inputs[symbol.module_index].expands_in_function;
}

pub fn resolveSymbolExcluding(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, use_span: ast.Span, excluded: ?SymbolId) ?Symbol {
    var current: ?ScopeId = scope;
    while (current) |id| : (current = self.scopes.items[id].parent) {
        if (self.lookupLexical(id, name)) |symbol| {
            if (symbol.id == excluded) continue;
            if (module_index < self.modules.items.len and self.scopes.items[id].kind == .module and id == self.modules.items[module_index].scope and
                std.mem.indexOf(u8, name, "__") != null)
            {
                if (resolveScopedNamespaceAlias(self, module_index, scope, name, use_span, true)) |aliased| return aliased;
            }
            if (self.scopes.items[id].kind == .module and
                (!self.moduleSymbolVisible(scope, symbol) or hiddenModuleVar(self, symbol))) continue;
            if (self.isDeclSiteSymbol(symbol, module_index, use_span)) continue;
            if (anonymousShadowedModuleSymbol(self, module_index, scope, id, symbol, name, use_span)) |global| return global;
            return symbol;
        }
    }
    // 明示package aliasは関数・無名関数の字句束縛に譲り、その後に
    // module scopeの同名衝突より優先して解決する。
    if (std.mem.indexOf(u8, name, "__") != null) {
        if (resolveScopedNamespaceAlias(self, module_index, scope, name, use_span, true)) |symbol| return symbol;
        if (resolveScopedNamespaceAlias(self, module_index, scope, name, use_span, false)) |symbol| return symbol;
        for (self.symbols.items) |symbol| {
            if (self.scopes.items[symbol.scope].kind != .module or symbol.shadowed or hiddenModuleVar(self, symbol)) continue;
            if (symbol.module_index < self.inputs.len and self.inputs[symbol.module_index].is_package) continue;
            if (!std.mem.eql(u8, symbol.qualified_name, name)) continue;
            if (!self.moduleSymbolVisibleAt(module_index, use_span, scope, symbol)) continue;
            if (self.isDeclSiteSymbol(symbol, module_index, use_span)) continue;
            return symbol;
        }
        return null;
    }
    // 取り込み位置以降の global 入口命令は、package の実関数へ直接解決する。
    // 修飾名（`__` を含む）は namespace alias / package 解決の規則を優先する。
    if (resolveGlobalCommandAlias(self, module_index, scope, name, use_span)) |symbol| return symbol;
    return lookupModList(self, module_index, scope, name, use_span);
}

pub fn resolveScopedNamespaceAlias(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, use_span: ast.Span, explicit_only: bool) ?Symbol {
    if (module_index >= self.inputs.len) return null;
    var selected: ?NamespaceAlias = null;
    for (self.inputs[module_index].namespace_aliases) |alias| {
        if (explicit_only and !alias.is_explicit) continue;
        if (use_span.start < alias.import_position) continue;
        if (name.len <= alias.source_namespace.len + 2 or
            !std.mem.startsWith(u8, name, alias.source_namespace) or
            !std.mem.startsWith(u8, name[alias.source_namespace.len..], "__")) continue;
        if (selected == null or alias.source_namespace.len > selected.?.source_namespace.len) selected = alias;
    }
    const alias = selected orelse return null;
    const suffix = name[alias.source_namespace.len..];
    for (self.symbols.items) |symbol| {
        if (symbol.module_index != alias.target_module or
            self.scopes.items[symbol.scope].kind != .module or symbol.shadowed or hiddenModuleVar(self, symbol)) continue;
        if (symbol.qualified_name.len != alias.internal_namespace.len + suffix.len or
            !std.mem.startsWith(u8, symbol.qualified_name, alias.internal_namespace) or
            !std.mem.eql(u8, symbol.qualified_name[alias.internal_namespace.len..], suffix)) continue;
        if (!self.moduleSymbolVisibleAt(module_index, use_span, scope, symbol)) continue;
        if (self.isDeclSiteSymbol(symbol, module_index, use_span)) continue;
        return symbol;
    }
    return null;
}

/// `global` 入口が公開するソース関数を、無修飾名から取り込み先 module の
/// 実シンボルへ解決する。動的 builtin にしないため Interpreter と AOT が
/// 同じ関数を直接呼ぶ。取り込み位置より前の参照と、対象 module に実在
/// しない名前は解決しない。
pub fn resolveGlobalCommandAlias(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, use_span: ast.Span) ?Symbol {
    if (module_index >= self.inputs.len) return null;
    // 既定の組み込み命令と同じ名前は、package の global 入口でも上書き
    // しない（言語互換を維持し、取り込み先の追加だけで既存コードの
    // 解決結果を変えない）。
    if (self.builtins.get(name) != null) return null;
    var selected: ?analyzer_mod.GlobalCommandAlias = null;
    for (self.inputs[module_index].global_command_aliases) |alias| {
        if (!std.mem.eql(u8, alias.name, name)) continue;
        if (use_span.start < alias.import_position) continue;
        if (selected == null or alias.import_position >= selected.?.import_position) selected = alias;
    }
    const alias = selected orelse return null;
    for (self.symbols.items) |symbol| {
        if (symbol.module_index != alias.target_module) continue;
        if (self.scopes.items[symbol.scope].kind != .module or symbol.shadowed or hiddenModuleVar(self, symbol)) continue;
        if (symbol.kind != .function and symbol.kind != .test_function) continue;
        if (symbol.qualified_name.len != alias.internal_namespace.len + 2 + name.len) continue;
        if (!std.mem.startsWith(u8, symbol.qualified_name, alias.internal_namespace)) continue;
        if (!std.mem.eql(u8, symbol.qualified_name[alias.internal_namespace.len .. alias.internal_namespace.len + 2], "__")) continue;
        if (!std.mem.eql(u8, symbol.qualified_name[alias.internal_namespace.len + 2 ..], name)) continue;
        if (!self.moduleSymbolVisibleAt(module_index, use_span, scope, symbol)) continue;
        if (self.isDeclSiteSymbol(symbol, module_index, use_span)) continue;
        return symbol;
    }
    return null;
}

/// cnako v3.7.24の無名関数は自身のローカル以外の名前をモジュール変数
/// （__varslist[2]）へ解決するため、外側スコープの明示ローカル・仮引数は
/// 同名の可視モジュール変数に負ける。一致するモジュール変数を返す。
/// cnako v3.7.24の無名関数は自身のローカル以外の名前をモジュール変数
/// （__varslist[2]）へ解決するため、外側スコープの明示ローカル・仮引数は
/// 同名の可視モジュール変数に負ける。一致するモジュール変数を返す。
pub fn anonymousShadowedModuleSymbol(
    self: *Analyzer,
    module_index: u32,
    use_scope: ScopeId,
    binding_scope: ScopeId,
    symbol: Symbol,
    name: []const u8,
    use_span: ast.Span,
) ?Symbol {
    if (!symbol.explicit_definition or
        (symbol.kind != .variable and symbol.kind != .constant and symbol.kind != .parameter) or
        self.scopes.items[binding_scope].kind == .module)
    {
        return null;
    }

    var current: ?ScopeId = use_scope;
    var crossed_anonymous = false;
    while (current) |scope_id| : (current = self.scopes.items[scope_id].parent) {
        if (scope_id == binding_scope) break;
        if (self.scopes.items[scope_id].kind == .anonymous_function) crossed_anonymous = true;
    }
    if (!crossed_anonymous) return null;

    const global = lookupVisibleModule(self, module_index, use_scope, name, use_span) orelse
        lookupModList(self, module_index, use_scope, name, use_span) orelse return null;
    if (global.kind != .variable and global.kind != .constant and global.kind != .loop_variable) return null;
    return global;
}

/// 公式findVarのmodList検索: 結合ストリームの展開マーカー順に各
/// モジュールの「mod__name」を検索し、export許可かつ使用位置で可視の
/// 最初の一致を返す（先勝ちで曖昧さエラーは無い）。
/// 公式findVarのmodList検索: 結合ストリームの展開マーカー順に各
/// モジュールの「mod__name」を検索し、export許可かつ使用位置で可視の
/// 最初の一致を返す（先勝ちで曖昧さエラーは無い）。
pub fn lookupModList(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, use_span: ast.Span) ?Symbol {
    if (std.mem.indexOf(u8, name, "__") != null) return null;
    for (self.mod_list.items) |mod_index| {
        if (mod_index == module_index) continue;
        // package 所有 module の公開命令は alias 修飾（または global 入口の
        // exact alias）でのみ解決する。無修飾名を mod_list から拾うと、
        // scoped package の命令がグローバル空間へ漏れる。
        if (self.inputs[mod_index].is_package) continue;
        if (lookupModule(self, mod_index, name)) |symbol| {
            if (!symbol.is_export) continue;
            if (!self.moduleSymbolVisibleAt(module_index, use_span, scope, symbol)) continue;
            return symbol;
        }
    }
    return null;
}

/// qualified が「{module}__{name}」の形かをアロケーション無しで判定する。
pub fn moduleQualifiedEql(self: *Analyzer, module_index: u32, qualified: []const u8, name: []const u8) bool {
    const module_name = self.inputs[module_index].internal_namespace orelse self.modules.items[module_index].name;
    return qualified.len == module_name.len + 2 + name.len and
        std.mem.startsWith(u8, qualified, module_name) and
        std.mem.eql(u8, qualified[module_name.len .. module_name.len + 2], "__") and
        std.mem.endsWith(u8, qualified, name);
}

/// 宣言文のパース時点では、その文が宣言する変数はまだ存在しない
/// （公式findVarは単一パスで名前を確定する）。したがって宣言文の
/// 位置に含まれる使用・代入からは自分自身の宣言シンボルが見えない。
/// 変数・定数の宣言シンボルのみ対象（関数・引数・ループ変数は除く）。
/// 修飾名（mod__A）で直接書かれた代入先の解決。公式は修飾名そのものを
/// __varslist のキーとして検索するため、非修飾名の宣言（A=...）が作る
/// モジュールシンボルにも修飾名で一致し得る。可視性は resolveSymbol の
/// 位置規則に従う。
pub fn resolveQualified(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, use_span: ast.Span) ?Symbol {
    if (std.mem.indexOf(u8, name, "__") == null) return null;
    return self.resolveSymbol(module_index, scope, name, use_span);
}

/// lookupModule と同じだが、関数本体内では定義位置より後の
/// モジュール変数を除外し、宣言文自身のシンボルも除外する。
/// lookupModule と同じだが、関数本体内では定義位置より後の
/// モジュール変数を除外し、宣言文自身のシンボルも除外する。
pub fn lookupVisibleModule(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, use_span: ast.Span) ?Symbol {
    const symbol = lookupModule(self, module_index, name) orelse return null;
    if (self.isDeclSiteSymbol(symbol, module_index, use_span)) return null;
    return if (self.moduleSymbolVisible(scope, symbol)) symbol else null;
}

pub fn lookupModule(self: *Analyzer, module_index: u32, name: []const u8) ?Symbol {
    const symbol = self.lookupLexical(self.modules.items[module_index].scope, name) orelse return null;
    return if (hiddenModuleVar(self, symbol)) null else symbol;
}

/// mod_list を marker_rank 昇順（同順位は入力順）に並べる比較関数。
/// mod_list を marker_rank 昇順（同順位は入力順）に並べる比較関数。
pub fn markerRankLess(self: *Analyzer, a: u32, b: u32) bool {
    const rank_a = self.inputs[a].marker_rank;
    const rank_b = self.inputs[b].marker_rank;
    if (rank_a != rank_b) return rank_a < rank_b;
    return a < b;
}
