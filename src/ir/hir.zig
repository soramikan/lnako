const std = @import("std");
const ast = @import("../frontend/ast.zig");
const semantic = @import("../semantic/analyzer.zig");
const argument_completion = @import("../semantic/argument_completion.zig");
const builtin_catalog = @import("../semantic/builtin_catalog.zig");
const builtin_josi = @import("../semantic/builtin_josi.zig");

pub const NodeId = u32;
pub const FunctionId = u32;

pub const TypeHint = enum { dynamic, number, bigint, boolean, null_value, string, array, object, function, void };

pub const Kind = enum {
    nop,
    block,
    number,
    bigint,
    boolean,
    null_value,
    string,
    string_template,
    load_global,
    load_local,
    store_global,
    store_local,
    destructure_store,
    binary,
    unary,
    call,
    call_value,
    make_array,
    make_object,
    array_get,
    property_get,
    array_set,
    property_set,
    increment,
    increment_indexed,
    if_statement,
    while_statement,
    post_test_loop,
    repeat_times,
    for_statement,
    foreach_statement,
    switch_statement,
    try_except,
    throw_statement,
    return_statement,
    break_statement,
    continue_statement,
    closure,
    dynamic_execute,
    speed_mode,
    performance_monitor,
};

pub const Node = struct {
    id: NodeId,
    kind: Kind,
    type_hint: TypeHint = .dynamic,
    span: ast.Span,
    name: []const u8 = "",
    text: []const u8 = "",
    operator: []const u8 = "",
    names: []const []const u8 = &.{},
    /// destructure_storeの各namesがローカルシンボルへ束縛されたか
    /// （意味解析の束縛結果。namesと同じ長さ）。
    names_local: []const bool = &.{},
    number_value: ?f64 = null,
    boolean_value: bool = false,
    /// True only when semantic analysis resolved this call to the fixed
    /// language builtin catalog. Dynamic plugin commands stay false.
    is_builtin_call: bool = false,
    /// DNCL互換の配列要素代入で、未初期化変数へ30要素の0配列を自動初期化する。
    check_array_init: bool = false,
    /// 代入系ノードの対象名が意味解析でローカルシンボルへ解決された場合に真。
    /// local slotの登録対象判定に使う（修飾名やシステム定数は含まない）。
    local_target: bool = false,
    /// このノードの参照先が関数スコープの暗黙束縛`引数`（実引数配列）なら真。
    /// HIR種別ではなく意味解析の束縛から導出するため、代入・増減・添字代入など
    /// ノード自身が名前を持つ形の追加に追従不要（lower引数の先頭束縛の判定用）。
    uses_implicit_arguments: bool = false,
    /// 実効取り込み文からのモジュールエントリ呼び出しで真。公式は取り込み先
    /// トークンを文位置へ展開するため、制御が到達するたびに実行される。
    is_module_entry: bool = false,
    /// 取り込み文を含むモジュールと取り込み先モジュールの展開順位。
    /// サイト側モジュールのコピー実行中にこの呼び出しへ到達し、かつ
    /// callee_order <= site_order なら、公式で copy 内から除去された
    /// 取り込み文に相当するため呼び出しを抑止する。site_toplevel が
    /// 真のときだけこの抑止判定を行い、関数本体内の取り込み呼び出しは
    /// 公式同様に到達するたび常に実行する。
    site_module: u32 = 0,
    site_order: u32 = 0,
    callee_module: u32 = 0,
    callee_order: u32 = 0,
    site_toplevel: bool = false,
    /// 循環再展開コピーが文脈別パースを使う場合の、対象モジュール
    /// variant_entries 内のindex（Issue #73）。
    callee_variant: ?u32 = null,
    loop_direction: ast.LoopDirection = .automatic,
    children: []NodeId = &.{},
};

pub const Parameter = struct { name: []const u8, symbol: ?semantic.SymbolId };

pub const Function = struct {
    id: FunctionId,
    name: []const u8,
    parameters: []Parameter,
    captures: []const []const u8 = &.{},
    body: NodeId,
    return_type: TypeHint = .dynamic,
    is_async: bool = false,
    is_entry: bool = false,
    is_test: bool = false,
    span: ast.Span,
};

pub const Global = struct {
    symbol: semantic.SymbolId,
    name: []const u8,
    is_mutable: bool,
};

pub const Module = struct {
    name: []const u8,
    path: []const u8,
    entry_function: FunctionId,
    /// 循環再展開コピーの文脈別エントリ関数（Issue #73）。
    variant_entries: []FunctionId = &.{},
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    modules: []Module,
    globals: []Global,
    functions: []Function,
    nodes: []Node,

    pub fn deinit(self: *Program) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn node(self: Program, id: NodeId) Node {
        return self.nodes[id];
    }

    pub fn findFunction(self: Program, name: []const u8) ?Function {
        // 同名関数は生成順の後勝ち（循環取り込み変体の定義が本体を置き換える
        // 公式挙動、Issue #73）。
        var found: ?Function = null;
        for (self.functions) |function| if (std.mem.eql(u8, function.name, name)) {
            found = function;
        };
        return found;
    }
};

pub fn lower(backing_allocator: std.mem.Allocator, roots: []const *ast.Node, module_names: []const []const u8, module_paths: []const []const u8, variant_roots: []const []const *ast.Node, analyzed: semantic.Program) !Program {
    if (roots.len != module_names.len or roots.len != module_paths.len or roots.len != variant_roots.len) return error.InvalidModuleInput;
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    var lowerer = Lowerer{ .allocator = arena.allocator(), .semantic_program = analyzed };

    for (analyzed.symbols) |symbol| if (analyzed.scopes[symbol.scope].kind == .module and
        (symbol.kind == .variable or symbol.kind == .constant or symbol.kind == .loop_variable))
    {
        try lowerer.globals.append(lowerer.allocator, .{
            .symbol = symbol.id,
            .name = try lowerer.allocator.dupe(u8, symbol.qualified_name),
            .is_mutable = symbol.is_mutable,
        });
    };

    for (roots, 0..) |root, module_index| {
        try lowerer.collectFunctions(root, @intCast(module_index));
        const body = try lowerer.lowerNode(root, @intCast(module_index));
        const function_id: FunctionId = @intCast(lowerer.functions.items.len);
        const entry_name = try std.fmt.allocPrint(lowerer.allocator, "{s}__$entry", .{module_names[module_index]});
        try lowerer.functions.append(lowerer.allocator, .{
            .id = function_id,
            .name = entry_name,
            .parameters = &.{},
            .body = body,
            .return_type = .void,
            .is_entry = true,
            .span = root.span,
        });
        try lowerer.modules.append(lowerer.allocator, .{
            .name = try lowerer.allocator.dupe(u8, module_names[module_index]),
            .path = try lowerer.allocator.dupe(u8, module_paths[module_index]),
            .entry_function = function_id,
        });
        // 循環再展開コピーの文脈別エントリ（Issue #73）。同じモジュールの
        // 変数・関数シンボルを共有する本体と同内容の別パース。
        var variant_entries = try lowerer.allocator.alloc(FunctionId, variant_roots[module_index].len);
        for (variant_roots[module_index], 0..) |variant_root, variant_index| {
            try lowerer.collectFunctions(variant_root, @intCast(module_index));
            const variant_body = try lowerer.lowerNode(variant_root, @intCast(module_index));
            const variant_id: FunctionId = @intCast(lowerer.functions.items.len);
            try lowerer.functions.append(lowerer.allocator, .{
                .id = variant_id,
                .name = try std.fmt.allocPrint(lowerer.allocator, "{s}__$entry$v{d}", .{ module_names[module_index], variant_index }),
                .parameters = &.{},
                .body = variant_body,
                .return_type = .void,
                .is_entry = true,
                .span = variant_root.span,
            });
            variant_entries[variant_index] = variant_id;
        }
        lowerer.modules.items[module_index].variant_entries = variant_entries;
    }

    // arenaを返却値へコピーする前に確保を済ませる。リテラル内で呼ぶと
    // コピー後のarena状態へ確保が記録されずリークする。
    const modules = try lowerer.modules.toOwnedSlice(lowerer.allocator);
    const globals = try lowerer.globals.toOwnedSlice(lowerer.allocator);
    const functions = try lowerer.functions.toOwnedSlice(lowerer.allocator);
    const nodes = try lowerer.nodes.toOwnedSlice(lowerer.allocator);
    return .{
        .arena = arena,
        .modules = modules,
        .globals = globals,
        .functions = functions,
        .nodes = nodes,
    };
}

pub fn lowerSingle(backing_allocator: std.mem.Allocator, root: *ast.Node, module_name: []const u8, path: []const u8, analyzed: semantic.Program) !Program {
    return lower(backing_allocator, &.{root}, &.{module_name}, &.{path}, &.{&.{}}, analyzed);
}

const Lowerer = struct {
    allocator: std.mem.Allocator,
    semantic_program: semantic.Program,
    modules: std.ArrayList(Module) = .empty,
    globals: std.ArrayList(Global) = .empty,
    functions: std.ArrayList(Function) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    lambda_index: usize = 0,
    anonymous_names: std.AutoHashMapUnmanaged(*ast.Node, []const u8) = .empty,

    fn collectFunctions(self: *Lowerer, node: *ast.Node, module_index: u32) !void {
        try self.collectFunctionsEx(node, module_index, false);
    }

    fn collectFunctionsEx(self: *Lowerer, node: *ast.Node, module_index: u32, in_expansion: bool) !void {
        // 関数内取り込みのインライン展開: 展開子内の関数定義は取り込み先
        // モジュールの文脈（mod__F名）で登録する（公式のグローバル登録相当）。
        if (node.kind == .import and node.expansion.len > 0) {
            if (self.importCallee(node)) |callee|
                for (node.expansion) |child| try self.collectFunctionsEx(child, callee, true);
            return;
        }
        // 関数内展開内の関数定義は生成しない。公式でも関数本体内へ展開
        // されたコピーのdefはグローバル登録を上書きせず、対象モジュール
        // 本体側の同名関数が呼ばれる（循環では本体側が再帰する）。
        if (in_expansion and (node.kind == .function_definition or node.kind == .test_definition)) return;
        if (node.kind == .function_definition or node.kind == .test_definition or node.kind == .anonymous_function) {
            for (node.children) |child| try self.collectFunctionsEx(child, module_index, in_expansion);
            const function_name = if (node.kind == .anonymous_function) blk: {
                const name = try std.fmt.allocPrint(self.allocator, "{s}__lambda${d}", .{ self.semantic_program.modules[module_index].name, self.lambda_index });
                self.lambda_index += 1;
                try self.anonymous_names.put(self.allocator, node, name);
                break :blk name;
            } else try self.resolvedName(node, node.name);
            const body = if (node.children.len > 0) try self.lowerNode(node.children[0], module_index) else try self.addNode(.nop, node.span, &.{});
            const function_id: FunctionId = @intCast(self.functions.items.len);
            var parameters = try self.allocator.alloc(Parameter, node.arguments.len);
            for (node.arguments, 0..) |argument, index| parameters[index] = .{
                .name = try self.allocator.dupe(u8, argument.name),
                .symbol = self.findArgumentSymbol(module_index, argument),
            };
            const function_scope = self.functionScope(node) orelse return error.MissingFunctionScope;
            try self.functions.append(self.allocator, .{
                .id = function_id,
                .name = function_name,
                .parameters = parameters,
                .captures = try self.captureNames(node, function_scope),
                .body = body,
                .is_async = node.is_async,
                .is_test = node.kind == .test_definition,
                .span = node.span,
            });
            return;
        }
        for (node.children) |child| try self.collectFunctionsEx(child, module_index, in_expansion);
    }

    /// 取り込み文の束縛から対象モジュールのindexを返す。
    fn importCallee(self: *Lowerer, node: *ast.Node) ?u32 {
        for (self.semantic_program.bindings) |binding| {
            if (binding.node == node and binding.kind == .call) {
                if (binding.import_entry) |entry| return entry.callee_module;
            }
        }
        return null;
    }

    fn lowerNode(self: *Lowerer, node: *ast.Node, module_index: u32) !NodeId {
        // 実効取り込み文は取り込み先モジュールのエントリ呼び出しに置き換える。
        // 公式が取り込み文位置へ取り込み先トークンを展開するのと同じ順序で
        // トップレベルが実行される。パス式の子は評価しない。
        if (node.kind == .import) {
            for (self.semantic_program.bindings) |binding| if (binding.node == node and binding.kind == .call) {
                const entry = binding.import_entry orelse break;
                if (!entry.site_toplevel) {
                    // 関数内取り込み: 取り込み先トップレベル文を呼び出し元
                    // スコープのまま取り込み先モジュールの文脈でloweringする
                    // （公式のトークン展開相当）。実行位置は取り込み文の位置。
                    const child_ids = try self.allocator.alloc(NodeId, node.expansion.len);
                    for (node.expansion, 0..) |child, index| child_ids[index] = try self.lowerNode(child, entry.callee_module);
                    return self.addNode(.block, node.span, child_ids);
                }
                const id = try self.addNode(.call, node.span, &.{});
                const result = &self.nodes.items[id];
                result.name = try self.allocator.dupe(u8, binding.resolved_name);
                result.is_module_entry = true;
                result.site_module = entry.site_module;
                result.site_order = entry.site_order;
                result.callee_module = entry.callee_module;
                result.callee_order = entry.callee_order;
                result.site_toplevel = entry.site_toplevel;
                result.callee_variant = entry.callee_variant;
                return id;
            };
            return self.addNode(.nop, node.span, &.{});
        }
        const implicit_function = self.implicitFunction(node);
        const completion = try self.argumentCompletionPlan(node);
        var child_ids: []NodeId = undefined;
        if (completion) |plan| {
            // 公式`yCallFunc`と同じ助詞補完。省略された引数は変数「それ」を渡す。
            child_ids = try self.allocator.alloc(NodeId, plan.operands.len);
            for (plan.operands, 0..) |operand, index| {
                child_ids[index] = switch (operand) {
                    .provided => |argument| try self.lowerNode(node.children[argument], module_index),
                    .implicit_it => try self.implicitItNode(node.span),
                };
            }
        } else {
            child_ids = try self.allocator.alloc(NodeId, if (implicit_function != null) 0 else node.children.len);
            for (node.children, 0..) |child, index| child_ids[index] = try self.lowerNode(child, module_index);
        }
        const kind: Kind = switch (node.kind) {
            // .import はこの関数の先頭でcall/nopに変換済みのためここへは来ない
            .import, .nop, .eol, .run_mode, .function_definition, .test_definition => .nop,
            .speed_mode => .speed_mode,
            .performance_monitor => .performance_monitor,
            .block, .sequence => .block,
            .number => .number,
            .bigint => .bigint,
            .boolean => .boolean,
            .null_value => .null_value,
            .string => .string,
            .string_template => .string_template,
            .word => if (implicit_function != null) .call else if (self.bindingIsBuiltinCommand(node)) (if (std.mem.eql(u8, node.value, "エラー発生")) .throw_statement else .call) else if (self.bindingIsLocal(node)) .load_local else .load_global,
            .assignment, .variable_definition => if (self.bindingIsLocal(node)) .store_local else .store_global,
            .variable_list_definition => .destructure_store,
            .array_assignment => .array_set,
            .property_assignment => .property_set,
            .increment => .increment,
            .increment_indexed => .increment_indexed,
            .array_literal => .make_array,
            .object_literal => .make_object,
            .binary_operator => .binary,
            .unary_operator => .unary,
            .function_call => if (std.mem.eql(u8, node.name, "エラー発生") and self.bindingIsBuiltin(node)) .throw_statement else .call,
            .call_value => .call_value,
            .array_reference, .array_value_reference => .array_get,
            .property_reference => .property_get,
            .if_statement => .if_statement,
            .while_statement => .while_statement,
            .post_test_loop => .post_test_loop,
            .for_statement => .for_statement,
            .foreach_statement => .foreach_statement,
            .repeat_times => .repeat_times,
            .switch_statement => .switch_statement,
            .try_except => .try_except,
            .return_statement => .return_statement,
            .break_statement => .break_statement,
            .continue_statement => .continue_statement,
            .anonymous_function => .closure,
            .dynamic_execute => .dynamic_execute,
            .function_pointer => .closure,
        };
        const id = try self.addNode(kind, node.span, child_ids);
        var result = &self.nodes.items[id];
        result.type_hint = typeHint(node.kind);
        const fallback_name = if (node.kind == .word) node.value else node.name;
        result.name = try self.resolvedName(node, fallback_name);
        result.text = try self.allocator.dupe(u8, node.value);
        result.operator = try self.allocator.dupe(u8, node.operator);
        if (node.arguments.len > 0) try self.resolveArgumentTargets(node, result);
        result.number_value = node.number_value;
        result.boolean_value = node.number_value != null and node.number_value.? != 0;
        result.is_builtin_call = switch (node.kind) {
            .function_call => self.bindingIsBuiltin(node),
            .word => self.bindingIsBuiltinCommand(node),
            else => false,
        };
        result.check_array_init = node.check_array_init;
        result.local_target = self.bindingIsLocal(node);
        result.uses_implicit_arguments = self.bindsImplicitArguments(node);
        result.loop_direction = node.loop_direction;
        if (node.kind == .anonymous_function) {
            result.name = try self.allocator.dupe(u8, self.anonymous_names.get(node) orelse return error.MissingAnonymousFunction);
        }
        return id;
    }

    fn addNode(self: *Lowerer, kind: Kind, span: ast.Span, children: []NodeId) !NodeId {
        const id: NodeId = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .id = id, .kind = kind, .span = span, .children = children });
        return id;
    }

    fn resolvedName(self: *Lowerer, node: *ast.Node, fallback: []const u8) ![]const u8 {
        for (self.semantic_program.bindings) |binding| if (binding.node == node and binding.resolved_name.len > 0) {
            return self.allocator.dupe(u8, binding.resolved_name);
        };
        return self.allocator.dupe(u8, fallback);
    }

    fn bindingIsLocal(self: *Lowerer, node: *ast.Node) bool {
        for (self.semantic_program.bindings) |binding| if (binding.node == node) {
            if (binding.symbol) |symbol_id| {
                const symbol = self.semantic_program.symbols[symbol_id];
                return self.semantic_program.scopes[symbol.scope].kind != .module;
            }
        };
        return false;
    }

    /// このノードの参照先が関数スコープの暗黙束縛`引数`かを返す。
    /// `引数`への読み出し・代入・増減・添字代入は、どのHIR種別でも同じ
    /// シンボルへ束縛されるため、種別を列挙せず束縛から判定する。
    fn bindsImplicitArguments(self: *Lowerer, node: *ast.Node) bool {
        for (self.semantic_program.bindings) |binding| if (binding.node == node) {
            const symbol_id = binding.symbol orelse continue;
            return self.semantic_program.symbols[symbol_id].implicit_arguments;
        };
        return false;
    }

    fn bindingIsBuiltin(self: Lowerer, node: *ast.Node) bool {
        for (self.semantic_program.bindings) |binding| if (binding.node == node) return binding.kind == .builtin and !binding.dynamic_builtin;
        return false;
    }

    /// 組み込み命令へ束縛された`.word`ノードを暗黙呼出しにするか判定する。
    /// 「それ」「対象」など組み込み名の変数はarity表に無いため呼出しへ変換しない。
    fn bindingIsBuiltinCommand(self: Lowerer, node: *ast.Node) bool {
        if (!self.bindingIsBuiltin(node)) return false;
        return builtin_catalog.findArity(node.value) != null;
    }

    fn implicitFunction(self: *Lowerer, node: *ast.Node) ?semantic.Symbol {
        if (node.kind != .word) return null;
        return self.callableSymbol(node);
    }

    /// 呼出し先がユーザー定義関数へ解決されたノードのシンボルを返す。
    fn callableSymbol(self: *Lowerer, node: *ast.Node) ?semantic.Symbol {
        for (self.semantic_program.bindings) |binding| if (binding.node == node and binding.kind == .call) {
            const symbol_id = binding.symbol orelse return null;
            return self.semantic_program.symbols[symbol_id];
        };
        return null;
    }

    /// 公式`nako_parser3.mts`の`yCallFunc`と同じ助詞補完の計画を返す。
    /// C風呼出し・可変長引数・助詞スロットが無い命令は補完対象外として`null`を返す。
    fn argumentCompletionPlan(self: *Lowerer, node: *ast.Node) !?argument_completion.Plan {
        if (node.is_c_style_call) return null;
        switch (node.kind) {
            .function_call => {
                if (self.bindingIsBuiltin(node)) {
                    const spec = builtin_josi.findJosi(node.name) orelse return null;
                    const slots = try argument_completion.builtinSlots(self.allocator, spec);
                    return argument_completion.plan(self.allocator, slots, node.children, spec.is_variable);
                }
                const symbol = self.callableSymbol(node) orelse return null;
                if (symbol.kind != .function and symbol.kind != .test_function) return null;
                const slots = try argument_completion.parameterSlots(self.allocator, symbol.parameter_josi);
                if (slots.len == 0) return null;
                return argument_completion.plan(self.allocator, slots, node.children, false);
            },
            .word => {
                if (self.bindingIsBuiltinCommand(node)) {
                    const spec = builtin_josi.findJosi(node.value) orelse return null;
                    const slots = try argument_completion.builtinSlots(self.allocator, spec);
                    return argument_completion.plan(self.allocator, slots, node.children, spec.is_variable);
                }
                const symbol = self.callableSymbol(node) orelse return null;
                const slots = try argument_completion.parameterSlots(self.allocator, symbol.parameter_josi);
                if (slots.len == 0) return null;
                return argument_completion.plan(self.allocator, slots, node.children, false);
            },
            else => return null,
        }
    }

    /// 省略引数へ補完する変数「それ」の読み出しノードを作る。
    fn implicitItNode(self: *Lowerer, span: ast.Span) !NodeId {
        const id = try self.addNode(.load_global, span, &.{});
        const node = &self.nodes.items[id];
        node.name = try self.allocator.dupe(u8, "それ");
        node.text = try self.allocator.dupe(u8, "それ");
        return id;
    }

    /// 分解代入の各ターゲット名を解決済み名とローカル束縛フラグで埋める。
    /// フラグは束縛シンボルのスコープ種別で決め、修飾名の有無では推測しない。
    fn resolveArgumentTargets(self: *Lowerer, node: *ast.Node, result: *Node) !void {
        const names = try self.allocator.alloc([]const u8, node.arguments.len);
        const locals = try self.allocator.alloc(bool, node.arguments.len);
        for (node.arguments, 0..) |argument, index| {
            names[index] = try self.allocator.dupe(u8, argument.name);
            locals[index] = false;
            for (self.semantic_program.bindings) |binding| {
                if (binding.node == node and std.mem.eql(u8, binding.name, argument.name)) {
                    names[index] = try self.allocator.dupe(u8, binding.resolved_name);
                    if (binding.symbol) |symbol_id| {
                        const symbol = self.semantic_program.symbols[symbol_id];
                        locals[index] = self.semantic_program.scopes[symbol.scope].kind != .module;
                    }
                    break;
                }
            }
        }
        result.names = names;
        result.names_local = locals;
    }

    fn findArgumentSymbol(self: *Lowerer, module_index: u32, argument: ast.Argument) ?semantic.SymbolId {
        for (self.semantic_program.symbols) |symbol| if (symbol.module_index == module_index and
            symbol.kind == .parameter and std.mem.eql(u8, symbol.name, argument.name) and spanEqual(symbol.span, argument.span)) return symbol.id;
        return null;
    }

    fn functionScope(self: Lowerer, node: *ast.Node) ?semantic.ScopeId {
        for (self.semantic_program.function_scopes) |owner| if (owner.node == node) return owner.scope;
        return null;
    }

    fn captureNames(self: *Lowerer, node: *ast.Node, function_scope: semantic.ScopeId) ![]const []const u8 {
        var captures: std.ArrayList([]const u8) = .empty;
        defer captures.deinit(self.allocator);
        for (self.semantic_program.bindings) |binding| {
            const symbol_id = binding.symbol orelse continue;
            const symbol = self.semantic_program.symbols[symbol_id];
            if (self.semantic_program.scopes[symbol.scope].kind == .module) continue;
            if (!self.scopeIsAncestor(symbol.scope, function_scope)) continue;
            if (!nodeContains(node, binding.node)) continue;
            if (nameIndex(captures.items, symbol.qualified_name) != null) continue;
            try captures.append(self.allocator, try self.allocator.dupe(u8, symbol.qualified_name));
        }
        return captures.toOwnedSlice(self.allocator);
    }

    fn scopeIsAncestor(self: Lowerer, ancestor: semantic.ScopeId, descendant: semantic.ScopeId) bool {
        var current = self.semantic_program.scopes[descendant].parent;
        while (current) |scope| : (current = self.semantic_program.scopes[scope].parent) {
            if (scope == ancestor) return true;
        }
        return false;
    }
};

fn nodeContains(root: *ast.Node, candidate: *ast.Node) bool {
    if (root == candidate) return true;
    for (root.children) |child| if (nodeContains(child, candidate)) return true;
    return false;
}

fn nameIndex(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
    return null;
}

fn spanEqual(left: ast.Span, right: ast.Span) bool {
    return left.source_start == right.source_start and left.source_end == right.source_end and left.line == right.line and left.column == right.column;
}

fn typeHint(kind: ast.Kind) TypeHint {
    return switch (kind) {
        .number => .number,
        .bigint => .bigint,
        .boolean => .boolean,
        .null_value => .null_value,
        .string, .string_template => .string,
        .array_literal => .array,
        .object_literal => .object,
        .function_definition, .anonymous_function, .function_pointer => .function,
        .eol, .nop, .break_statement, .continue_statement => .void,
        else => .dynamic,
    };
}

test "名前解決済みASTをHIRへ下げる" {
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=1\n●(Bを)Fとは\nA+Bで戻る\nここまで\nF(2)を表示\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var program = try lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer program.deinit();
    try std.testing.expect(program.findFunction("main__F") != null);
    try std.testing.expect(program.findFunction("main__$entry") != null);
    try std.testing.expectEqual(@as(usize, 1), program.globals.len);
    try std.testing.expectEqualStrings("main__A", program.globals[0].name);
    const function = program.findFunction("main__F").?;
    try std.testing.expect(function.parameters[0].symbol != null);
    try std.testing.expectEqualStrings("B", analyzed.symbols[function.parameters[0].symbol.?].name);
}

test "裸の1引数関数をそれ付き暗黙呼び出しへ下げる" {
    const parser = @import("../frontend/parser.zig");
    const source = "●(Aを)Fとは\nAで戻る\nここまで\nそれは4\nTYPEOF(F)を表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "implicit-call.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "implicit-call.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var program = try lowerSingle(std.testing.allocator, parsed.root.?, "implicit-call", "implicit-call.nako3", analyzed);
    defer program.deinit();
    var found = false;
    for (program.nodes) |node| {
        if (node.kind != .call or !std.mem.eql(u8, node.name, "implicit-call__F")) continue;
        try std.testing.expectEqual(@as(usize, 1), node.children.len);
        const argument = program.node(node.children[0]);
        try std.testing.expectEqual(Kind.load_global, argument.kind);
        try std.testing.expectEqualStrings("それ", argument.name);
        found = true;
    }
    try std.testing.expect(found);
}

test "助詞呼出しの省略引数を変数「それ」で補完する" {
    const parser = @import("../frontend/parser.zig");
    const source = "それは「abcabc」\n「a」を「X」に置換\n表示。\n";
    var parsed = try parser.parse(std.testing.allocator, source, "particle.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "particle.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var program = try lowerSingle(std.testing.allocator, parsed.root.?, "particle", "particle.nako3", analyzed);
    defer program.deinit();
    var replace_children: ?[]const NodeId = null;
    var display_children: ?[]const NodeId = null;
    for (program.nodes) |node| {
        if (node.kind != .call) continue;
        if (std.mem.eql(u8, node.name, "置換")) replace_children = node.children;
        if (std.mem.eql(u8, node.name, "表示")) display_children = node.children;
    }
    // 置換は「それ」を先頭引数として補完し、続けて「a」「X」を渡す。
    const replace = replace_children orelse return error.MissingReplaceCall;
    try std.testing.expectEqual(@as(usize, 3), replace.len);
    try std.testing.expectEqualStrings("それ", program.node(replace[0]).name);
    try std.testing.expectEqual(Kind.load_global, program.node(replace[0]).kind);
    try std.testing.expectEqualStrings("a", program.node(replace[1]).text);
    try std.testing.expectEqualStrings("X", program.node(replace[2]).text);
    // 表示は省略引数1個を「それ」で補完する。
    const display = display_children orelse return error.MissingDisplayCall;
    try std.testing.expectEqual(@as(usize, 1), display.len);
    try std.testing.expectEqual(Kind.load_global, program.node(display[0]).kind);
    try std.testing.expectEqualStrings("それ", program.node(display[0]).name);
}

test "複数引数の裸関数呼出しを「それ」で補完する" {
    const parser = @import("../frontend/parser.zig");
    const source = "●(AとBを)二和とは\n(A+B)で戻る\nここまで\nそれは3\n二和を表示。\n";
    var parsed = try parser.parse(std.testing.allocator, source, "fill.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "fill.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var program = try lowerSingle(std.testing.allocator, parsed.root.?, "fill", "fill.nako3", analyzed);
    defer program.deinit();
    var found = false;
    for (program.nodes) |node| {
        if (node.kind != .call or !std.mem.eql(u8, node.name, "fill__二和")) continue;
        try std.testing.expectEqual(@as(usize, 2), node.children.len);
        for (node.children) |child| {
            const argument = program.node(child);
            try std.testing.expectEqual(Kind.load_global, argument.kind);
            try std.testing.expectEqualStrings("それ", argument.name);
        }
        found = true;
    }
    try std.testing.expect(found);
}

test "値位置の組み込み命令語を「それ」補完付きの暗黙呼出しへ下げる" {
    const parser = @import("../frontend/parser.zig");
    const source = "それは「  abc  」\n空白除去して表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "builtin-word.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "builtin-word.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var program = try lowerSingle(std.testing.allocator, parsed.root.?, "builtin-word", "builtin-word.nako3", analyzed);
    defer program.deinit();
    var found = false;
    for (program.nodes) |node| {
        if (node.kind != .call or !std.mem.eql(u8, node.name, "空白除去")) continue;
        try std.testing.expect(node.is_builtin_call);
        try std.testing.expectEqual(@as(usize, 1), node.children.len);
        const argument = program.node(node.children[0]);
        try std.testing.expectEqual(Kind.load_global, argument.kind);
        try std.testing.expectEqualStrings("それ", argument.name);
        found = true;
    }
    try std.testing.expect(found);
}

test "0引数の組み込み命令語を暗黙呼出しへ下げる" {
    const parser = @import("../frontend/parser.zig");
    const source = "礼節レベル取得して表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "builtin-zero.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "builtin-zero.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var program = try lowerSingle(std.testing.allocator, parsed.root.?, "builtin-zero", "builtin-zero.nako3", analyzed);
    defer program.deinit();
    var found = false;
    for (program.nodes) |node| {
        if (node.kind != .call or !std.mem.eql(u8, node.name, "礼節レベル取得")) continue;
        try std.testing.expect(node.is_builtin_call);
        try std.testing.expectEqual(@as(usize, 0), node.children.len);
        found = true;
    }
    try std.testing.expect(found);
}

test "裸の「エラー発生」語をthrow_statementへ下げる" {
    const parser = @import("../frontend/parser.zig");
    const source = "エラー発生して表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "builtin-throw.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "builtin-throw.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var program = try lowerSingle(std.testing.allocator, parsed.root.?, "builtin-throw", "builtin-throw.nako3", analyzed);
    defer program.deinit();
    var found = false;
    for (program.nodes) |node| {
        if (!std.mem.eql(u8, node.name, "エラー発生")) continue;
        // 通常のbuiltin callではなく専用のthrow終端へ下げる（AOTのdispatch対象外命令）
        try std.testing.expectEqual(Kind.throw_statement, node.kind);
        try std.testing.expect(node.is_builtin_call);
        try std.testing.expectEqual(@as(usize, 1), node.children.len);
        found = true;
    }
    try std.testing.expect(found);
}

test "組み込み名の変数は暗黙呼出しへ変換しない" {
    const parser = @import("../frontend/parser.zig");
    const source = "A=[1,2]\nAを反復\n対象を表示\nここまで\nそれを表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "builtin-vars.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "builtin-vars.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var program = try lowerSingle(std.testing.allocator, parsed.root.?, "builtin-vars", "builtin-vars.nako3", analyzed);
    defer program.deinit();
    var saw_target = false;
    var saw_sore = false;
    for (program.nodes) |node| {
        if (std.mem.eql(u8, node.name, "対象")) {
            try std.testing.expectEqual(Kind.load_global, node.kind);
            saw_target = true;
        }
        if (node.kind == .load_global and std.mem.eql(u8, node.name, "それ")) saw_sore = true;
    }
    try std.testing.expect(saw_target);
    try std.testing.expect(saw_sore);
}

test "入れ子の無名関数へ自由変数捕捉を中継する" {
    const parser = @import("../frontend/parser.zig");
    const source = "●(Aを)作るとは\nF=関数()\nG=関数()それはA\nここまで\nGで戻る\nここまで\nFで戻る\nここまで\n";
    var parsed = try parser.parse(std.testing.allocator, source, "closure.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "closure.nako3");
    defer analyzed.deinit();
    var program = try lowerSingle(std.testing.allocator, parsed.root.?, "closure", "closure.nako3", analyzed);
    defer program.deinit();
    var closure_count: usize = 0;
    for (program.functions) |function| {
        if (std.mem.indexOf(u8, function.name, "__lambda$") == null) continue;
        closure_count += 1;
        try std.testing.expectEqual(@as(usize, 1), function.captures.len);
        try std.testing.expectEqualStrings("A", function.captures[0]);
    }
    try std.testing.expectEqual(@as(usize, 2), closure_count);
}

test "分割代入と増減とループ属性をHIRへ保持する" {
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "変数[A,B]=[1,2]\nAを1増\nIを1から3まで1ずつ増やし繰り返す\nA=A+I\nここまで\n", "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var program = try lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer program.deinit();
    var saw_destructure = false;
    var saw_increment = false;
    var saw_up_loop = false;
    for (program.nodes) |node| {
        if (node.kind == .destructure_store) {
            saw_destructure = true;
            try std.testing.expectEqual(@as(usize, 2), node.names.len);
            try std.testing.expectEqualStrings("main__A", node.names[0]);
            try std.testing.expectEqualStrings("main__B", node.names[1]);
        }
        if (node.kind == .increment) saw_increment = true;
        if (node.kind == .for_statement and node.loop_direction == .up) saw_up_loop = true;
    }
    try std.testing.expect(saw_destructure);
    try std.testing.expect(saw_increment);
    try std.testing.expect(saw_up_loop);
}
