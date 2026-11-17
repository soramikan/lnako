//! package の宣言命令 metadata に基づく呼出し検査と未検査 alias の記録。
//! `Analyzer` の参照解決から呼び出され、package alias 単位の整合確認・
//! 診断・未検査警告を担う。

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const argument_completion = @import("argument_completion.zig");
const declared_commands = @import("declared_commands.zig");
const analyzer_mod = @import("analyzer.zig");

const Analyzer = analyzer_mod.Analyzer;
const ScopeId = analyzer_mod.ScopeId;
const Symbol = analyzer_mod.Symbol;
const SymbolKind = analyzer_mod.SymbolKind;
const DeclaredCommand = declared_commands.DeclaredCommand;
const PackageCommandAlias = declared_commands.PackageCommandAlias;

/// 1回の参照解決における package 宣言命令の検査状態。
pub const DeclaredCommandContext = struct {
    alias: ?PackageCommandAlias = null,
    available: bool = false,
    command: ?DeclaredCommand = null,
    malformed: bool = false,
    gate: bool = false,
    shape_reported: bool = false,

    /// package の宣言命令 metadata（あれば）を対応付ける。宣言は呼出しの
    /// 形（名前・助詞・arity）の正本だが、索引は公開命令だけを含むため、
    /// alias で解決できる非公開シンボルを妨げない（名前不一致の判定は
    /// シンボル/動的解決に失敗した後で行う）。
    pub fn init(analyzer: *Analyzer, module_index: u32, node: *ast.Node, name: []const u8, callable: bool) !DeclaredCommandContext {
        var ctx = DeclaredCommandContext{
            .alias = if (callable or node.kind == .word)
                packageCommandAlias(analyzer, module_index, name, node.span.start)
            else
                null,
        };
        if (ctx.alias) |alias| {
            if (alias.declared) |declared| {
                if (declared.available) {
                    ctx.available = true;
                    ctx.command = declared.find(name[alias.source_namespace.len + 2 ..]);
                }
            }
            // 索引が無い、または索引の被覆外（非公開シンボル）の使用は
            // 「検査済み」にしない。
            if (!ctx.available or ctx.command == null) {
                try noteUninspectedPackageCommand(analyzer, module_index, alias, name, node.span, false);
            }
        }
        // 宣言索引でスロットを構成できない metadata は未検査へ戻す。名前自体は
        // 索引にあるため、後段で「宣言がありません」と自己矛盾しないよう
        // malformed として区別する。
        if (ctx.command) |command| {
            const malformed = if (command.variable)
                command.args.len != 0 or command.josi.len != 0
            else
                command.josi.len != command.args.len;
            if (malformed) {
                ctx.command = null;
                ctx.malformed = true;
                try noteUninspectedPackageCommand(analyzer, module_index, ctx.alias.?, name, node.span, false);
            }
        }
        return ctx;
    }

    /// ソース上でシンボル解決できた場合に、package 宣言との種別・シグネチャ・
    /// 引数の形の一致を検査する。診断を出して解決を打ち切る場合は `true` を返す。
    pub fn checkMatchedSymbol(
        self: *DeclaredCommandContext,
        analyzer: *Analyzer,
        module_index: u32,
        scope: ScopeId,
        node: *ast.Node,
        name: []const u8,
        callable: bool,
        symbol: Symbol,
    ) !bool {
        const command = self.command orelse return false;
        const package_symbol = self.alias.?.target_module == symbol.module_index;
        if (package_symbol and declaredKindMismatch(command, symbol.kind)) {
            const declared_kind = if (command.variable) "変数" else "関数";
            const message = try std.fmt.allocPrint(
                analyzer.allocator,
                "パッケージ『{s}』の『{s}』は{s}として宣言されていますが、取り込んだソースでは{s}として定義されています",
                .{ self.alias.?.source_namespace, name, declared_kind, symbolKindLabel(symbol.kind) },
            );
            try analyzer.addDiagnostic(.declared_command_kind_mismatch, node.span, analyzer.modules.items[module_index].path, message);
            return true;
        }
        // 宣言 metadata とソースの引数定義（個数・助詞列）を照合する。
        // 一致しないままソースへ束縛すると、実行時の引数順が metadata
        // と逆になる呼出しを診断なしに通してしまう。
        if (package_symbol and !command.variable and
            (symbol.argument_count != command.args.len or
                !josiSequenceEqual(symbol.parameter_josi, command.josi)))
        {
            const declared_josi = try josiListText(analyzer, command.josi);
            const actual_josi = try josiListText(analyzer, symbol.parameter_josi);
            const message = try std.fmt.allocPrint(
                analyzer.allocator,
                "パッケージ『{s}』の『{s}』は引数{d}個（助詞: {s}）として宣言されていますが、取り込んだソースでは引数{d}個（助詞: {s}）です",
                .{ self.alias.?.source_namespace, name, command.args.len, declared_josi, symbol.argument_count, actual_josi },
            );
            try analyzer.addDiagnostic(.declared_command_signature_mismatch, node.span, analyzer.modules.items[module_index].path, message);
            return true;
        }
        if (package_symbol) {
            self.shape_reported = try checkDeclaredCommandShape(analyzer, module_index, scope, node, name, command, callable);
            self.gate = true;
        }
        return false;
    }

    /// ソースシンボルが無い package 命令（native/ESM や未解決）について、
    /// 宣言 metadata を正本として形を検査する。
    pub fn checkWithoutSymbol(
        self: *DeclaredCommandContext,
        analyzer: *Analyzer,
        module_index: u32,
        scope: ScopeId,
        node: *ast.Node,
        name: []const u8,
        callable: bool,
    ) !void {
        const command = self.command orelse return;
        self.shape_reported = try checkDeclaredCommandShape(analyzer, module_index, scope, node, name, command, callable);
        self.gate = true;
    }

    /// package alias 経由の呼出しが解決できなかった場合の決定的な診断。
    /// 宣言索引があるのに名前が無ければ宣言不一致、宣言はあるのに解決
    /// できなければ metadata とソース/登録の齟齬として報告する。索引の
    /// 無い alias は「検査できなかった」ことを警告として明示する。
    /// 診断や引数形エラーで解決を打ち切る場合は `true` を返す。
    pub fn handleUnresolved(
        self: DeclaredCommandContext,
        analyzer: *Analyzer,
        module_index: u32,
        node: *ast.Node,
        name: []const u8,
    ) !bool {
        const alias = self.alias orelse return false;
        if (self.available) {
            const command_name = name[alias.source_namespace.len + 2 ..];
            if (self.command == null) {
                if (self.malformed) {
                    // 宣言はあるがスロットを構成できない metadata。未検査
                    // 警告に留め、既存の未解決処理（strict/暗黙宣言）へ戻す。
                    try noteUninspectedPackageCommand(analyzer, module_index, alias, name, node.span, true);
                } else {
                    const message = try std.fmt.allocPrint(
                        analyzer.allocator,
                        "パッケージ『{s}』に『{s}』の宣言がありません（宣言済み: {s}）",
                        .{ alias.source_namespace, command_name, try declaredCommandNames(analyzer, alias.declared.?.commands) },
                    );
                    try analyzer.addDiagnostic(.undefined_symbol, node.span, analyzer.modules.items[module_index].path, message);
                    return true;
                }
            } else if (self.shape_reported) {
                // 引数の形は既に invalid_argument_count で報告済み。
                return true;
            } else if (alias.target_module == std.math.maxInt(u32)) {
                // native/ESM package はソースから解決できないのが正常で、
                // 実行時登録の可能性もあるためハードエラーにしない。
                try noteUninspectedPackageCommand(analyzer, module_index, alias, name, node.span, true);
            } else {
                const message = try std.fmt.allocPrint(
                    analyzer.allocator,
                    "パッケージ『{s}』の『{s}』は宣言されていますが、取り込んだソースから解決できません",
                    .{ alias.source_namespace, command_name },
                );
                try analyzer.addDiagnostic(.undefined_symbol, node.span, analyzer.modules.items[module_index].path, message);
                return true;
            }
        } else {
            try noteUninspectedPackageCommand(analyzer, module_index, alias, name, node.span, true);
        }
        return false;
    }

    pub fn isUninspectedCall(self: DeclaredCommandContext) bool {
        return if (self.alias) |alias|
            !self.available or self.command == null or alias.target_module == std.math.maxInt(u32)
        else
            false;
    }
};

/// `pkg:` alias の `<alias>__<命令>` 形式から、longest-prefix で一致する
/// 宣言索引付き alias を返す。取り込み文より前の参照は対象外。
fn packageCommandAlias(analyzer: *Analyzer, module_index: u32, name: []const u8, use_position: usize) ?PackageCommandAlias {
    if (module_index >= analyzer.inputs.len) return null;
    if (std.mem.indexOf(u8, name, "__") == null) return null;
    var selected: ?PackageCommandAlias = null;
    for (analyzer.inputs[module_index].package_command_aliases) |alias| {
        if (use_position < alias.import_position) continue;
        if (name.len <= alias.source_namespace.len + 2 or
            !std.mem.startsWith(u8, name, alias.source_namespace) or
            !std.mem.startsWith(u8, name[alias.source_namespace.len..], "__")) continue;
        if (selected == null or alias.source_namespace.len > selected.?.source_namespace.len) selected = alias;
    }
    return selected;
}

/// 宣言 metadata に対する package 命令呼出しの形（変数/arity/助詞）を
/// 検査する。宣言が正本なので、助詞・arity は既存の
/// `argument_completion` / `checkParticleArgumentCount` を再利用する。
fn checkDeclaredCommandShape(analyzer: *Analyzer, module_index: u32, scope: ScopeId, node: *ast.Node, name: []const u8, command: DeclaredCommand, callable: bool) !bool {
    if (command.variable) {
        // 変数は `lib__設定を表示` のような参照（word）が正当。word の
        // josi は後続命令への助詞であり呼出しの引数ではない。一方、
        // 呼出しノード（引数の有無を問わない）は変数へ束縛できない。
        if (callable) {
            const message = try std.fmt.allocPrint(
                analyzer.allocator,
                "パッケージの『{s}』は変数であり、命令として呼び出せません",
                .{name},
            );
            try analyzer.addDiagnostic(.invalid_argument_count, node.span, analyzer.modules.items[module_index].path, message);
            return true;
        }
        return false;
    }
    // 演算子由来の疑似呼出し（範囲など）は助詞引数ではないため、既存の
    // シンボル経路と同じく個数・助詞検査の対象外。
    if (callable and !(node.command_call or node.is_c_style_call)) return false;
    if (node.is_c_style_call) {
        if (node.children.len != command.args.len) {
            const message = try std.fmt.allocPrint(
                analyzer.allocator,
                "命令『{s}』は引数{d}個を必要としますが、{d}個が指定されました",
                .{ name, command.args.len, node.children.len },
            );
            try analyzer.addDiagnostic(.invalid_argument_count, node.span, analyzer.modules.items[module_index].path, message);
            return true;
        }
        return false;
    }
    const slots = try argument_completion.parameterSlots(analyzer.allocator, command.josi);
    try analyzer.checkParticleArgumentCount(module_index, scope, node, slots, false, name);
    return false;
}

/// シンボル種別の診断表示。定数・引数を「変数」と混同しない。
fn symbolKindLabel(kind: SymbolKind) []const u8 {
    return switch (kind) {
        .function, .test_function => "関数",
        .variable => "変数",
        .constant => "定数",
        .parameter => "引数",
        .loop_variable => "ループ変数",
    };
}

/// 宣言命令の種別（変数/関数）と、ソースで解決したシンボル種別の不一致。
fn declaredKindMismatch(command: DeclaredCommand, symbol_kind: SymbolKind) bool {
    const symbol_is_function = symbol_kind == .function or symbol_kind == .test_function;
    return command.variable == symbol_is_function;
}

/// 宣言 metadata の助詞列とソース関数の仮引数助詞列の一致。
fn josiSequenceEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

/// 助詞列の診断表示。空文字は「なし」と表示する。
fn josiListText(analyzer: *Analyzer, josi: []const []const u8) ![]const u8 {
    if (josi.len == 0) return "(なし)";
    var out: std.ArrayList(u8) = .empty;
    for (josi, 0..) |item, index| {
        if (index > 0) try out.appendSlice(analyzer.allocator, ", ");
        if (item.len == 0) {
            try out.appendSlice(analyzer.allocator, "なし");
        } else {
            try out.appendSlice(analyzer.allocator, item);
        }
    }
    return out.items;
}

/// 名前不一致の診断に添える宣言済み命令名（最大8件）。
fn declaredCommandNames(analyzer: *Analyzer, commands: []const DeclaredCommand) ![]const u8 {
    if (commands.len == 0) return "(なし)";
    var out: std.ArrayList(u8) = .empty;
    for (commands, 0..) |command, index| {
        if (index >= 8) {
            try out.appendSlice(analyzer.allocator, ", …");
            break;
        }
        if (index > 0) try out.appendSlice(analyzer.allocator, ", ");
        try out.appendSlice(analyzer.allocator, command.name);
    }
    return out.items;
}

/// 宣言索引の無い package alias 経由の使用を記録する。alias 単位で1件だけ
/// Program へ残し、`warn` 指定時は最初の1回だけ警告を出す。
fn noteUninspectedPackageCommand(analyzer: *Analyzer, module_index: u32, alias: PackageCommandAlias, command_name: []const u8, span: ast.Span, warn: bool) !void {
    const key = try std.fmt.allocPrint(analyzer.allocator, "{d}\x00{s}", .{ module_index, alias.source_namespace });
    const entry = try analyzer.uninspected_alias_state.getOrPut(analyzer.allocator, key);
    if (!entry.found_existing) entry.value_ptr.* = .{};
    if (!entry.value_ptr.recorded) {
        entry.value_ptr.recorded = true;
        try analyzer.uninspected_package_commands.append(analyzer.allocator, .{
            .namespace = try analyzer.allocator.dupe(u8, alias.source_namespace),
            .command_name = try analyzer.allocator.dupe(u8, command_name),
            .file = analyzer.modules.items[module_index].path,
            .span = span,
        });
    }
    if (warn and !entry.value_ptr.warned) {
        entry.value_ptr.warned = true;
        const message = try std.fmt.allocPrint(
            analyzer.allocator,
            "パッケージ『{s}』の命令metadataが無いため『{s}』は静的に検査できません（未検査）",
            .{ alias.source_namespace, command_name },
        );
        try analyzer.addWarning(.uninspected_package_command, span, analyzer.modules.items[module_index].path, message);
    }
}
