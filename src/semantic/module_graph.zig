const std = @import("std");
const ast = @import("../frontend/ast.zig");
const diagnostic = @import("../frontend/diagnostic.zig");
const parser = @import("../frontend/parser.zig");
const analyzer = @import("analyzer.zig");

pub const SourceProvider = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,

    pub fn read(self: SourceProvider, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.readFn(self.context, allocator, path);
    }
};

pub const FileProvider = struct {
    io: std.Io,
    max_bytes: usize = 128 * 1024 * 1024,

    pub fn sourceProvider(self: *FileProvider) SourceProvider {
        return .{ .context = self, .readFn = read };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *FileProvider = @ptrCast(@alignCast(context));
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(self.max_bytes));
    }
};

pub const Options = struct { compat_js: bool = false };
pub const ModuleKind = enum { nako3, javascript };
pub const LoadState = enum { loading, loaded };

pub const Import = struct {
    requested: []const u8,
    resolved_path: []const u8,
    target: ?u32,
    span: ast.Span,
    cyclic: bool = false,
};

pub const LoadedModule = struct {
    index: u32,
    kind: ModuleKind,
    state: LoadState,
    path: []const u8,
    name: []const u8,
    source: []u8,
    parsed: ?parser.ParseResult,
    imports: []Import = &.{},
};

pub const ModuleGraph = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    modules: []*LoadedModule,
    entry: u32,
    diagnostics: []diagnostic.Diagnostic,

    pub fn deinit(self: *ModuleGraph) void {
        for (self.modules) |module| {
            if (module.parsed) |*parsed| parsed.deinit();
            self.backing_allocator.free(module.source);
            self.backing_allocator.destroy(module);
        }
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn succeeded(self: ModuleGraph) bool {
        for (self.diagnostics) |item| if (item.severity == .error_severity) return false;
        for (self.modules) |module| if (module.parsed) |parsed| {
            if (!parsed.succeeded()) return false;
        };
        return true;
    }

    pub fn analyze(self: ModuleGraph, allocator: std.mem.Allocator) !analyzer.Program {
        var temporary = std.heap.ArenaAllocator.init(allocator);
        defer temporary.deinit();
        const temp = temporary.allocator();
        var inputs: std.ArrayList(analyzer.ModuleInput) = .empty;
        for (self.modules) |module| {
            if (module.kind != .nako3 or module.parsed == null or module.parsed.?.root == null) continue;
            var imports: std.ArrayList([]const u8) = .empty;
            for (module.imports) |item| if (item.target) |target| {
                const target_module = self.modules[target];
                if (target_module.kind == .nako3) try imports.append(temp, target_module.name);
            };
            try inputs.append(temp, .{
                .name = module.name,
                .path = module.path,
                .root = module.parsed.?.root.?,
                .imports = try imports.toOwnedSlice(temp),
            });
        }
        return analyzer.analyzeModules(allocator, inputs.items);
    }
};

pub fn load(backing_allocator: std.mem.Allocator, entry_path: []const u8, provider: SourceProvider, options: Options) !ModuleGraph {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    var loader = Loader{
        .backing_allocator = backing_allocator,
        .allocator = arena.allocator(),
        .provider = provider,
        .options = options,
    };
    errdefer loader.deinitModules();
    const normalized_entry = try normalizePath(loader.allocator, entry_path);
    const entry = try loader.loadOne(normalized_entry, null);
    return .{
        .backing_allocator = backing_allocator,
        .arena = arena,
        .modules = try loader.modules.toOwnedSlice(loader.allocator),
        .entry = entry,
        .diagnostics = try loader.diagnostics.toOwnedSlice(loader.allocator),
    };
}

const Loader = struct {
    backing_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    provider: SourceProvider,
    options: Options,
    modules: std.ArrayList(*LoadedModule) = .empty,
    diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty,

    fn deinitModules(self: *Loader) void {
        for (self.modules.items) |module| {
            if (module.parsed) |*parsed| parsed.deinit();
            self.backing_allocator.free(module.source);
            self.backing_allocator.destroy(module);
        }
    }

    fn loadOne(self: *Loader, path: []const u8, import_node: ?*ast.Node) anyerror!u32 {
        if (self.find(path)) |existing| return existing;
        const extension = std.fs.path.extension(path);
        const kind: ModuleKind = if (std.ascii.eqlIgnoreCase(extension, ".nako3"))
            .nako3
        else if (std.ascii.eqlIgnoreCase(extension, ".js") or std.ascii.eqlIgnoreCase(extension, ".mjs"))
            .javascript
        else {
            try self.importDiagnostic(import_node, path, "通常モードで取り込めるのは.nako3だけです");
            return error.UnsupportedImport;
        };
        if (kind == .javascript and !self.options.compat_js) {
            try self.importDiagnostic(import_node, path, "JavaScriptの取り込みには--compat-jsが必要です");
            return error.JavaScriptCompatibilityRequired;
        }

        const source = self.provider.read(self.backing_allocator, path) catch |err| {
            try self.importDiagnostic(import_node, path, "取り込み先を読み込めません");
            return err;
        };
        errdefer self.backing_allocator.free(source);
        const module = try self.backing_allocator.create(LoadedModule);
        errdefer self.backing_allocator.destroy(module);
        const name = try analyzer.moduleName(self.allocator, path);
        module.* = .{
            .index = @intCast(self.modules.items.len),
            .kind = kind,
            .state = .loading,
            .path = try self.allocator.dupe(u8, path),
            .name = name,
            .source = source,
            .parsed = null,
        };
        try self.modules.append(self.allocator, module);

        if (kind == .javascript) {
            module.state = .loaded;
            return module.index;
        }
        module.parsed = parser.parse(self.backing_allocator, source, path) catch |err| {
            try self.importDiagnostic(import_node, path, "取り込み先を字句解析できません");
            return err;
        };
        if (module.parsed.?.root) |root| {
            var import_nodes: std.ArrayList(*ast.Node) = .empty;
            try collectImports(root, &import_nodes, self.allocator);
            var imports: std.ArrayList(Import) = .empty;
            for (import_nodes.items) |node| {
                const resolved = resolveImport(self.allocator, path, node.value) catch {
                    try self.importDiagnostic(node, path, "相対取り込みパスが不正です");
                    continue;
                };
                const existing = self.find(resolved);
                var target: ?u32 = existing;
                var cyclic = false;
                if (existing) |index| {
                    cyclic = self.modules.items[index].state == .loading;
                } else {
                    target = self.loadOne(resolved, node) catch null;
                }
                try imports.append(self.allocator, .{
                    .requested = try self.allocator.dupe(u8, node.value),
                    .resolved_path = resolved,
                    .target = target,
                    .span = node.span,
                    .cyclic = cyclic,
                });
            }
            module.imports = try imports.toOwnedSlice(self.allocator);
        }
        module.state = .loaded;
        return module.index;
    }

    fn find(self: *Loader, path: []const u8) ?u32 {
        for (self.modules.items) |module| if (std.mem.eql(u8, module.path, path)) return module.index;
        return null;
    }

    fn importDiagnostic(self: *Loader, node: ?*ast.Node, file: []const u8, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .code = .invalid_import,
            .message = message,
            .file = try self.allocator.dupe(u8, file),
            .span = if (node) |value| value.span else ast.emptySpan(),
        });
    }
};

fn collectImports(node: *ast.Node, output: *std.ArrayList(*ast.Node), allocator: std.mem.Allocator) !void {
    if (node.kind == .import) try output.append(allocator, node);
    for (node.children) |child| try collectImports(child, output, allocator);
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.path.resolve(allocator, &.{path});
}

fn resolveImport(allocator: std.mem.Allocator, importer: []const u8, requested: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, requested, ':') != null and !std.fs.path.isAbsolute(requested)) return error.UnsupportedImport;
    if (std.fs.path.isAbsolute(requested)) return normalizePath(allocator, requested);
    return std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(importer) orelse ".", requested });
}

const MemoryProvider = struct {
    files: []const File,

    const File = struct { suffix: []const u8, source: []const u8 };

    fn sourceProvider(self: *MemoryProvider) SourceProvider {
        return .{ .context = self, .readFn = read };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *MemoryProvider = @ptrCast(@alignCast(context));
        for (self.files) |file| if (std.mem.endsWith(u8, path, file.suffix)) return allocator.dupe(u8, file.source);
        return error.FileNotFound;
    }
};

test "相対取り込みを再帰ロードし重複と循環を抑止する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「./lib.nako3」を取り込む\n!「lib.nako3」を取り込む\n3を二倍して表示\n" },
        .{ .suffix = "lib.nako3", .source = "!「./cycle.nako3」を取り込む\n●(Aを)二倍とは\nA*2で戻る\nここまで\n" },
        .{ .suffix = "cycle.nako3", .source = "!「./lib.nako3」を取り込む\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    try std.testing.expectEqual(graph.modules[0].imports[0].target, graph.modules[0].imports[1].target);
    try std.testing.expect(graph.modules[2].imports[0].cyclic);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(program.findSymbol("lib__二倍") != null);
}

test "JS取り込みは互換モードを必須にする" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「plugin.mjs」を取り込む\n" },
        .{ .suffix = "plugin.mjs", .source = "export default {}" },
    } };
    var rejected = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer rejected.deinit();
    try std.testing.expect(!rejected.succeeded());
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true });
    defer graph.deinit();
    try std.testing.expectEqual(ModuleKind.javascript, graph.modules[1].kind);
}

test "存在しない取り込みを位置付き診断にする" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「missing.nako3」を取り込む\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics[0].span.line);
}
