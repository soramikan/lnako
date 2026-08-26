const std = @import("std");
const ast = @import("../frontend/ast.zig");
const semantic = @import("../semantic/analyzer.zig");

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
    number_value: ?f64 = null,
    boolean_value: bool = false,
    /// True only when semantic analysis resolved this call to the fixed
    /// language builtin catalog. Dynamic plugin commands stay false.
    is_builtin_call: bool = false,
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
        for (self.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
        return null;
    }
};

pub fn lower(backing_allocator: std.mem.Allocator, roots: []const *ast.Node, module_names: []const []const u8, module_paths: []const []const u8, analyzed: semantic.Program) !Program {
    if (roots.len != module_names.len or roots.len != module_paths.len) return error.InvalidModuleInput;
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
    }

    return .{
        .arena = arena,
        .modules = try lowerer.modules.toOwnedSlice(lowerer.allocator),
        .globals = try lowerer.globals.toOwnedSlice(lowerer.allocator),
        .functions = try lowerer.functions.toOwnedSlice(lowerer.allocator),
        .nodes = try lowerer.nodes.toOwnedSlice(lowerer.allocator),
    };
}

pub fn lowerSingle(backing_allocator: std.mem.Allocator, root: *ast.Node, module_name: []const u8, path: []const u8, analyzed: semantic.Program) !Program {
    return lower(backing_allocator, &.{root}, &.{module_name}, &.{path}, analyzed);
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
        if (node.kind == .function_definition or node.kind == .test_definition or node.kind == .anonymous_function) {
            for (node.children) |child| try self.collectFunctions(child, module_index);
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
        for (node.children) |child| try self.collectFunctions(child, module_index);
    }

    fn lowerNode(self: *Lowerer, node: *ast.Node, module_index: u32) !NodeId {
        const implicit_function = self.implicitFunction(node);
        var child_ids = if (implicit_function) |function|
            try self.allocator.alloc(NodeId, function.argument_count)
        else
            try self.allocator.alloc(NodeId, node.children.len);
        if (implicit_function) |function| {
            if (function.argument_count > 1) return error.InvalidImplicitFunctionArity;
            if (function.argument_count == 1) {
                child_ids[0] = try self.addNode(.load_global, node.span, &.{});
                const argument = &self.nodes.items[child_ids[0]];
                argument.name = try self.allocator.dupe(u8, "それ");
                argument.text = try self.allocator.dupe(u8, "それ");
            }
        } else for (node.children, 0..) |child, index| child_ids[index] = try self.lowerNode(child, module_index);
        const kind: Kind = switch (node.kind) {
            .nop, .eol, .import, .run_mode, .function_definition, .test_definition => .nop,
            .speed_mode => .speed_mode,
            .performance_monitor => .performance_monitor,
            .block, .sequence => .block,
            .number => .number,
            .bigint => .bigint,
            .boolean => .boolean,
            .null_value => .null_value,
            .string => .string,
            .string_template => .string_template,
            .word => if (implicit_function != null) .call else if (self.bindingIsLocal(node)) .load_local else .load_global,
            .assignment, .variable_definition => if (self.bindingIsLocal(node)) .store_local else .store_global,
            .variable_list_definition => .destructure_store,
            .array_assignment => .array_set,
            .property_assignment => .property_set,
            .increment => .increment,
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
        if (node.arguments.len > 0) result.names = try self.resolvedArgumentNames(node);
        result.number_value = node.number_value;
        result.boolean_value = node.number_value != null and node.number_value.? != 0;
        result.is_builtin_call = node.kind == .function_call and self.bindingIsBuiltin(node);
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

    fn bindingIsBuiltin(self: Lowerer, node: *ast.Node) bool {
        for (self.semantic_program.bindings) |binding| if (binding.node == node) return binding.kind == .builtin and !binding.dynamic_builtin;
        return false;
    }

    fn implicitFunction(self: Lowerer, node: *ast.Node) ?semantic.Symbol {
        if (node.kind != .word) return null;
        for (self.semantic_program.bindings) |binding| if (binding.node == node and binding.kind == .call) {
            const symbol_id = binding.symbol orelse return null;
            const symbol = self.semantic_program.symbols[symbol_id];
            if (symbol.kind == .function or symbol.kind == .test_function) return symbol;
        };
        return null;
    }

    fn resolvedArgumentNames(self: *Lowerer, node: *ast.Node) ![]const []const u8 {
        var names = try self.allocator.alloc([]const u8, node.arguments.len);
        for (node.arguments, 0..) |argument, index| {
            names[index] = try self.allocator.dupe(u8, argument.name);
            for (self.semantic_program.bindings) |binding| {
                if (binding.node == node and std.mem.eql(u8, binding.name, argument.name)) {
                    names[index] = try self.allocator.dupe(u8, binding.resolved_name);
                    break;
                }
            }
        }
        return names;
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
