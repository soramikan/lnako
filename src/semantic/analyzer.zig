const std = @import("std");
const ast = @import("../frontend/ast.zig");
const diagnostic = @import("../frontend/diagnostic.zig");
const builtin_catalog = @import("builtin_catalog.zig");

pub const ScopeId = u32;
pub const SymbolId = u32;

pub const ScopeKind = enum { module, function, anonymous_function };
pub const SymbolKind = enum { variable, constant, function, test_function, parameter, loop_variable };
pub const BindingKind = enum { declaration, reference, call, builtin };

pub const ModuleInput = struct {
    name: []const u8,
    path: []const u8,
    root: *ast.Node,
    imports: []const []const u8 = &.{},
    allows_dynamic_commands: bool = false,
};

pub const Module = struct {
    name: []const u8,
    path: []const u8,
    scope: ScopeId,
    imports: []const []const u8,
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
};

pub const Binding = struct {
    node: *ast.Node,
    kind: BindingKind,
    name: []const u8,
    resolved_name: []const u8,
    symbol: ?SymbolId,
};

pub const Program = struct {
    arena: std.heap.ArenaAllocator,
    modules: []Module,
    scopes: []Scope,
    symbols: []Symbol,
    bindings: []Binding,
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
    return .{
        .arena = arena,
        .modules = try analyzer.modules.toOwnedSlice(analyzer.allocator),
        .scopes = try analyzer.scopes.toOwnedSlice(analyzer.allocator),
        .symbols = try analyzer.symbols.toOwnedSlice(analyzer.allocator),
        .bindings = try analyzer.bindings.toOwnedSlice(analyzer.allocator),
        .diagnostics = try analyzer.diagnostics.toOwnedSlice(analyzer.allocator),
    };
}

const Analyzer = struct {
    allocator: std.mem.Allocator,
    inputs: []const ModuleInput,
    modules: std.ArrayList(Module) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,
    bindings: std.ArrayList(Binding) = .empty,
    diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty,
    builtins: std.StringHashMapUnmanaged(void) = .empty,
    resolution_ambiguous: bool = false,

    fn run(self: *Analyzer) !void {
        try self.loadBuiltins();
        for (self.inputs, 0..) |input, index| {
            const scope = try self.addScope(null, @intCast(index), .module);
            try self.modules.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, input.name),
                .path = try self.allocator.dupe(u8, input.path),
                .scope = scope,
                .imports = try dupeStrings(self.allocator, input.imports),
                .strict = hasStrictMode(input.root),
            });
        }
        for (self.inputs, 0..) |input, index| try self.predeclareBlock(input.root, @intCast(index), self.modules.items[index].scope, true);
        for (self.inputs, 0..) |input, index| try self.resolveBlock(input.root, @intCast(index), self.modules.items[index].scope);
    }

    fn loadBuiltins(self: *Analyzer) !void {
        for (builtin_catalog.names) |name| try self.builtins.put(self.allocator, name, {});
        for ([_][]const u8{ "それ", "対象", "対象キー", "回数", "エラー内容" }) |name| try self.builtins.put(self.allocator, name, {});
    }

    fn predeclareBlock(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId, recurse: bool) !void {
        if (node.kind == .function_definition or node.kind == .test_definition) {
            _ = try self.declare(module_index, scope, node.name, if (node.kind == .test_definition) .test_function else .function, node.span, node.is_export, false, node.arguments.len);
            return;
        }
        if (node.kind == .anonymous_function) return;
        if (node.kind == .variable_definition) {
            _ = try self.declare(module_index, scope, node.name, if (node.is_const) .constant else .variable, node.span, node.is_export, !node.is_const, 0);
        } else if (node.kind == .variable_list_definition) {
            for (node.arguments) |name| _ = try self.declare(module_index, scope, name.name, if (node.is_const) .constant else .variable, name.span, node.is_export, !node.is_const, 0);
        } else if ((node.kind == .assignment or node.kind == .increment) and self.builtins.get(node.name) == null and self.lookupLexical(scope, node.name) == null) {
            _ = try self.declare(module_index, scope, node.name, .variable, node.span, true, true, 0);
        } else if (node.kind == .for_statement and node.name.len > 0 and self.lookupLexical(scope, node.name) == null) {
            _ = try self.declare(module_index, scope, node.name, .loop_variable, node.span, false, true, 0);
        }
        if (!recurse and node.kind == .function_definition) return;
        for (node.children) |child| try self.predeclareBlock(child, module_index, scope, recurse and node.kind != .function_definition and node.kind != .test_definition and node.kind != .anonymous_function);
    }

    fn resolveBlock(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId) !void {
        switch (node.kind) {
            .function_definition, .test_definition => {
                if (self.lookupLexical(scope, node.name)) |symbol| try self.bind(node, .declaration, node.name, symbol.qualified_name, symbol.id);
                const function_scope = try self.addScope(scope, module_index, .function);
                for (node.arguments) |argument| _ = try self.declare(module_index, function_scope, argument.name, .parameter, argument.span, false, true, 0);
                for (node.children) |child| try self.predeclareBlock(child, module_index, function_scope, false);
                for (node.children) |child| try self.resolveBlock(child, module_index, function_scope);
                return;
            },
            .anonymous_function => {
                const function_scope = try self.addScope(scope, module_index, .anonymous_function);
                for (node.arguments) |argument| _ = try self.declare(module_index, function_scope, argument.name, .parameter, argument.span, false, true, 0);
                for (node.children) |child| try self.predeclareBlock(child, module_index, function_scope, false);
                for (node.children) |child| try self.resolveBlock(child, module_index, function_scope);
                return;
            },
            .assignment, .array_assignment, .property_assignment, .increment, .variable_definition => try self.resolveDeclaration(node, module_index, scope),
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
            else => {},
        }
        for (node.children) |child| try self.resolveBlock(child, module_index, scope);
    }

    fn resolveDeclaration(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId) !void {
        const symbol = self.lookupLexical(scope, node.name) orelse self.lookupModule(module_index, node.name) orelse return;
        if ((node.kind == .assignment or node.kind == .array_assignment or node.kind == .property_assignment or node.kind == .increment) and !symbol.is_mutable) {
            try self.addDiagnostic(.assign_to_constant, node.span, self.modules.items[module_index].path, "定数へ再代入できません");
        }
        try self.bind(node, .declaration, node.name, symbol.qualified_name, symbol.id);
    }

    fn resolveReference(self: *Analyzer, node: *ast.Node, module_index: u32, scope: ScopeId, callable: bool) !void {
        const name = if (callable) node.name else node.value;
        if (name.len == 0) return;
        self.resolution_ambiguous = false;
        if (self.resolveSymbol(module_index, scope, name)) |symbol| {
            try self.bind(node, if (callable) .call else .reference, name, symbol.qualified_name, symbol.id);
            return;
        }
        if (self.resolution_ambiguous) {
            const message = try std.fmt.allocPrint(self.allocator, "取り込んだ複数モジュールで『{s}』が定義されています。名前空間で修飾してください", .{name});
            try self.addDiagnostic(.ambiguous_import, node.span, self.modules.items[module_index].path, message);
            return;
        }
        if (self.builtins.get(name) != null) {
            try self.bind(node, .builtin, name, name, null);
            return;
        }
        if (callable and self.inputs[module_index].allows_dynamic_commands) {
            try self.bind(node, .builtin, name, name, null);
            return;
        }
        if (self.modules.items[module_index].strict) {
            const message = try std.fmt.allocPrint(self.allocator, "未定義の{s}『{s}』です", .{ if (callable) "命令" else "変数", name });
            try self.addDiagnostic(.undefined_symbol, node.span, self.modules.items[module_index].path, message);
            return;
        }
        const module_scope = self.modules.items[module_index].scope;
        const symbol_id = try self.declare(module_index, module_scope, name, .variable, node.span, true, true, 0);
        const symbol = self.symbols.items[symbol_id];
        try self.bind(node, if (callable) .call else .reference, name, symbol.qualified_name, symbol.id);
    }

    fn resolveSymbol(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8) ?Symbol {
        if (std.mem.indexOf(u8, name, "__") != null) {
            for (self.symbols.items) |symbol| if (std.mem.eql(u8, symbol.qualified_name, name)) return symbol;
        }
        var current: ?ScopeId = scope;
        while (current) |id| {
            if (self.lookupLexical(id, name)) |symbol| return symbol;
            current = self.scopes.items[id].parent;
        }
        var found: ?Symbol = null;
        for (self.modules.items[module_index].imports) |import_name| {
            const imported_index = self.findModule(import_name) orelse continue;
            if (self.lookupModule(imported_index, name)) |symbol| {
                if (!symbol.is_export) continue;
                if (found != null and found.?.id != symbol.id) {
                    self.resolution_ambiguous = true;
                    return null;
                }
                found = symbol;
            }
        }
        return found;
    }

    fn declare(self: *Analyzer, module_index: u32, scope: ScopeId, name: []const u8, kind: SymbolKind, span: ast.Span, is_export: bool, is_mutable: bool, argument_count: usize) !SymbolId {
        if (self.lookupLexical(scope, name)) |existing| {
            if (existing.kind == kind and (kind == .variable or kind == .loop_variable)) return existing.id;
            const message = try std.fmt.allocPrint(self.allocator, "『{s}』は同じスコープで既に定義されています", .{name});
            try self.addDiagnostic(.duplicate_symbol, span, self.modules.items[module_index].path, message);
            return existing.id;
        }
        const id: SymbolId = @intCast(self.symbols.items.len);
        const qualified = if (self.scopes.items[scope].kind == .module)
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

    fn lookupLexical(self: *Analyzer, scope: ScopeId, name: []const u8) ?Symbol {
        var index = self.symbols.items.len;
        while (index > 0) {
            index -= 1;
            const symbol = self.symbols.items[index];
            if (symbol.scope == scope and std.mem.eql(u8, symbol.name, name)) return symbol;
        }
        return null;
    }

    fn lookupModule(self: *Analyzer, module_index: u32, name: []const u8) ?Symbol {
        return self.lookupLexical(self.modules.items[module_index].scope, name);
    }

    fn findModule(self: *Analyzer, name: []const u8) ?u32 {
        for (self.modules.items, 0..) |module, index| if (std.mem.eql(u8, module.name, name)) return @intCast(index);
        return null;
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
        try self.diagnostics.append(self.allocator, .{ .code = code, .span = span, .file = file, .message = message });
    }
};

fn hasStrictMode(root: *ast.Node) bool {
    if (root.kind == .run_mode and std.mem.eql(u8, root.value, "厳しくチェック")) return true;
    for (root.children) |child| if (hasStrictMode(child)) return true;
    return false;
}

fn dupeStrings(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| result[index] = try allocator.dupe(u8, value);
    return result;
}

pub fn moduleName(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    var basename_start: usize = 0;
    for (filename, 0..) |byte, index| if (byte == '/' or byte == '\\' or byte == ':') {
        basename_start = index + 1;
    };
    const basename = filename[basename_start..];
    const suffix_length: usize = if (std.mem.endsWith(u8, basename, ".nako3"))
        ".nako3".len
    else if (std.mem.endsWith(u8, basename, ".nako"))
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

test "同名の公開シンボルは名前空間で曖昧さを解消する" {
    const parser = @import("../frontend/parser.zig");
    var first = try parser.parse(std.testing.allocator, "●Fとは\n1で戻る\nここまで\n", "a.nako3");
    defer first.deinit();
    var second = try parser.parse(std.testing.allocator, "●Fとは\n2で戻る\nここまで\n", "b.nako3");
    defer second.deinit();
    var main = try parser.parse(std.testing.allocator, "F\na__F\n", "main.nako3");
    defer main.deinit();
    var program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "a", .path = "a.nako3", .root = first.root.? },
        .{ .name = "b", .path = "b.nako3", .root = second.root.? },
        .{ .name = "main", .path = "main.nako3", .root = main.root.?, .imports = &.{ "a", "b" } },
    });
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    var ambiguous_count: usize = 0;
    var qualified_count: usize = 0;
    for (program.diagnostics) |item| if (item.code == .ambiguous_import) {
        ambiguous_count += 1;
    };
    for (program.bindings) |binding| if (binding.kind == .call and std.mem.eql(u8, binding.resolved_name, "a__F")) {
        qualified_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), ambiguous_count);
    try std.testing.expectEqual(@as(usize, 1), qualified_count);
}

test "取り込んだ公開関数を非修飾名と修飾名で解決する" {
    const parser = @import("../frontend/parser.zig");
    var library = try parser.parse(std.testing.allocator, "●(Aを)二倍とは\nA*2で戻る\nここまで\n", "lib.nako3");
    defer library.deinit();
    var main = try parser.parse(std.testing.allocator, "3を二倍して表示\nlib__二倍(4)を表示\n", "main.nako3");
    defer main.deinit();
    var program = try analyzeModules(std.testing.allocator, &.{
        .{ .name = "lib", .path = "lib.nako3", .root = library.root.? },
        .{ .name = "main", .path = "main.nako3", .root = main.root.?, .imports = &.{"lib"} },
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

test "厳チェックの未定義名と定数再代入を診断する" {
    const parser = @import("../frontend/parser.zig");
    var parsed = try parser.parse(std.testing.allocator, "!厳チェック\n定数 A=1\nA=2\n未宣言値を表示\n", "strict.nako3");
    defer parsed.deinit();
    var program = try analyze(std.testing.allocator, parsed.root.?, "strict.nako3");
    defer program.deinit();
    try std.testing.expect(!program.succeeded());
    var undefined_count: usize = 0;
    var const_count: usize = 0;
    for (program.diagnostics) |item| {
        if (item.code == .undefined_symbol) undefined_count += 1;
        if (item.code == .assign_to_constant) const_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), undefined_count);
    try std.testing.expectEqual(@as(usize, 1), const_count);
}
