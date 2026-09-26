const std = @import("std");
const ast = @import("../frontend/ast.zig");
const diagnostic = @import("../frontend/diagnostic.zig");
const parser = @import("../frontend/parser.zig");
const token_mod = @import("../frontend/token.zig");
const analyzer = @import("analyzer.zig");
const variants = @import("module_graph_variants.zig");
const builtin_catalog = @import("builtin_catalog.zig");

pub const SourceProvider = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,

    pub fn read(self: SourceProvider, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.readFn(self.context, allocator, path);
    }
};

/// PackageResolver returns all fields allocated from its supplied allocator;
/// the loader retains them in its graph arena.
pub const ResolvedPackageImport = struct {
    path: []u8,
    /// Stable package identity plus canonical export name; independent of disk path.
    canonical_id: []const u8,
    /// Public namespace from the source import alias, independent of canonical ID.
    namespace: []const u8,
};

/// Lock/environment-backed package specifier resolver. The callback returns the
/// selected export path and public namespace; selection policy stays outside the
/// module graph so CLI, tests, and embedded callers share the same loader.
pub const PackageResolver = struct {
    context: *anyopaque,
    resolveFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, importer: []const u8, specifier: []const u8) anyerror!ResolvedPackageImport,

    pub fn resolve(self: PackageResolver, allocator: std.mem.Allocator, importer: []const u8, specifier: []const u8) !ResolvedPackageImport {
        return self.resolveFn(self.context, allocator, importer, specifier);
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

pub const Options = struct {
    compat_js: bool = false,
    /// 同期済み環境に基づく `パッケージ:` / `pkg:` import resolver。
    package_resolver: ?PackageResolver = null,
    /// エントリモジュールへ強制する構文モード（--dncl / --dncl2）。
    forced_mode: token_mod.Mode = .{},
};
pub const ModuleKind = enum { nako3, javascript, native_plugin };
pub const LoadState = enum { loading, loaded };

pub const Import = struct {
    requested: []const u8,
    resolved_path: []const u8,
    canonical_id: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    target: ?u32,
    span: ast.Span,
    cyclic: bool = false,
    /// 結合ストリーム上で実際に内容を持つ辺かどうか。
    /// 公式のinclude guard相当: 同一モジュールへの2回目以降の取り込みや
    /// 循環取り込みは内容を持たず、モード伝搬・可視位置にも効かない。
    effective: bool = false,
    /// propagateModesで確定した取り込み文位置のモード（循環整合診断用）
    site_mode: token_mod.Mode = .{},
    /// この取り込み文の直後へ適用された取り込み先の終端モード。
    /// 循環コピーには取り込み展開が含まれないため、コピーの解析モードが
    /// 本体側と等価か判定するために使う。
    tail_mode: token_mod.Mode = .{},
    /// 循環再展開コピーが文脈モードの別パースを要する場合の、
    /// 対象モジュール variants 内のindex。
    variant: ?u32 = null,
};

/// 循環取り込みの再展開コピー。公式は循環取り込み位置で有効だった
/// モードを初期モードとして対象の変換済みトークンを再解析するため、
/// 本体とは別のパース結果を持つ。シンボル（変数・関数）は同一ソースの
/// 本体側と共有される。
pub const CopyVariant = struct {
    /// 循環取り込み位置で有効だったモードを初期モードとする再パース。
    initial_mode: token_mod.Mode,
    parse: parser.ParseResult,
    /// コピー内の取り込み文の辺。本体のImportを写し、コピー文脈で必要な
    /// 対象変体（nested variant）と有効モードを持つ。
    imports: []Import,
};

pub const LoadedModule = struct {
    index: u32,
    kind: ModuleKind,
    state: LoadState,
    path: []const u8,
    canonical_id: ?[]const u8 = null,
    /// Source-level package namespace alias used in this importer's scope.
    source_namespace: ?[]const u8 = null,
    name: []const u8,
    source: []u8,
    parsed: ?parser.ParseResult,
    imports: []Import = &.{},
    /// 拡張子・CLIで強制される構文モード（取り込み継承とは別系統）
    forced_mode: token_mod.Mode = .{},
    /// 直近のパースに使った取り込み継承モード（再パース要否の判定用）
    parse_initial: token_mod.Mode = .{},
    /// include guardへ登録された展開順位。公式のreplaceRequireStatementsは
    /// 展開中のモジュールをguardへ入れるため、取り込み先のコピー内では
    /// 自分以下の順位を持つモジュールへの取り込み文が除去される。
    /// maxIntは一度もコピーとして展開されなかったことを表す。
    expand_order: u32 = std.math.maxInt(u32),
    /// このモジュールの実効取り込みサイトが関数本体内にある。
    /// 公式では取り込み先の変数宣言が関数ローカルになるため、
    /// モジュール変数シンボル（mod__V相当）はグローバルに存在しない。
    expands_in_function: bool = false,
    /// 循環再展開コピーの文脈別パース一覧（Issue #73）。
    variants: std.ArrayListUnmanaged(CopyVariant) = .empty,
};

/// 全モジュールのトップレベル文が結合ストリーム上で占める順位。
/// 公式は取り込み文を取り込み先トークン列で置き換えて単一パースするため、
/// 実効取り込み辺の先は取り込み文の位置へ展開される。stmt_ranks[i][k] は
/// modules[i] の parsed.root.children[k] の結合順位。取り込み文自身や
/// 展開対象外の文には maxInt が入る。
pub const Expansion = struct {
    stmt_ranks: []const []const usize = &.{},
    /// 各モジュールの展開が始まった結合ストリーム順位。公式では各ファイルの
    /// 展開先頭に「プラグイン名設定」マーカーが挿入され、modList はその
    /// 出現順に並ぶ。未展開のモジュールには maxInt が入る。
    marker_ranks: []const usize = &.{},
};

pub const ModuleGraph = struct {
    backing_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    modules: []*LoadedModule,
    entry: u32,
    diagnostics: []diagnostic.Diagnostic,
    expansion: Expansion = .{},

    pub fn deinit(self: *ModuleGraph) void {
        for (self.modules) |module| {
            if (module.parsed) |*parsed| parsed.deinit();
            for (module.variants.items) |*variant| variant.parse.deinit();
            self.backing_allocator.free(module.source);
            self.backing_allocator.destroy(module);
        }
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn succeeded(self: ModuleGraph) bool {
        for (self.diagnostics) |item| if (item.severity == .error_severity) return false;
        for (self.modules) |module| {
            if (module.parsed) |parsed| {
                if (!parsed.succeeded()) return false;
            }
            for (module.variants.items) |variant| if (!variant.parse.succeeded()) return false;
        }
        return true;
    }

    pub fn analyze(self: ModuleGraph, allocator: std.mem.Allocator) !analyzer.Program {
        var temporary = std.heap.ArenaAllocator.init(allocator);
        defer temporary.deinit();
        const temp = temporary.allocator();
        // 取り込み辺のsite/calleeはローダindexではなく入力indexで保持する。
        // 同名モジュール（d1/lib と d2/lib）が共に "lib__$entry" を名乗る
        // 名前解決の衝突を避け、実行時は module_entries から直接引く。
        const loader_to_input = try temp.alloc(u32, self.modules.len);
        const internal_module_names = try temp.alloc([]const u8, self.modules.len);
        const runtime_module_names = try temp.alloc([]const u8, self.modules.len);
        const internal_name_assigned = try temp.alloc(bool, self.modules.len);
        @memset(internal_name_assigned, false);
        var input_count: u32 = 0;
        for (self.modules) |module| {
            if (module.kind != .nako3 or module.parsed == null or module.parsed.?.root == null) continue;
            loader_to_input[module.index] = input_count;
            input_count += 1;
        }
        for (self.modules) |module| {
            const source_namespace = module.source_namespace;
            if (source_namespace) |namespace| {
                var collision = false;
                for (self.modules) |candidate| {
                    if (candidate == module) continue;
                    if (candidate.canonical_id == null) {
                        if (std.mem.eql(u8, namespace, candidate.name)) {
                            collision = true;
                            break;
                        }
                        continue;
                    }
                    const candidate_namespace = candidate.source_namespace orelse continue;
                    if (std.mem.eql(u8, namespace, candidate_namespace) and
                        !std.mem.eql(u8, module.canonical_id.?, candidate.canonical_id.?))
                    {
                        collision = true;
                        break;
                    }
                }
                runtime_module_names[module.index] = if (collision)
                    try uniqueInternalModuleName(temp, self.modules, runtime_module_names, internal_name_assigned, module.index, namespace, "pkg")
                else
                    namespace;
                internal_module_names[module.index] = try uniqueInternalModuleName(
                    temp,
                    self.modules,
                    internal_module_names,
                    internal_name_assigned,
                    module.index,
                    "package",
                    "pkg",
                );
                internal_name_assigned[module.index] = true;
            } else {
                var collision = false;
                for (self.modules) |candidate| {
                    if (candidate == module or candidate.canonical_id != null) continue;
                    if (std.mem.eql(u8, module.name, candidate.name) and !std.mem.eql(u8, module.path, candidate.path)) {
                        collision = true;
                        break;
                    }
                }
                internal_module_names[module.index] = if (collision)
                    try uniqueInternalModuleName(temp, self.modules, internal_module_names, internal_name_assigned, module.index, module.name, "local")
                else
                    module.name;
                runtime_module_names[module.index] = internal_module_names[module.index];
                internal_name_assigned[module.index] = true;
            }
        }
        var inputs: std.ArrayList(analyzer.ModuleInput) = .empty;
        for (self.modules) |module| {
            if (module.kind != .nako3 or module.parsed == null or module.parsed.?.root == null) continue;
            var import_entries: std.ArrayList(analyzer.ImportEntry) = .empty;
            var allows_dynamic_commands = false;
            for (module.imports) |item| if (item.target) |target| {
                const target_module = self.modules[target];
                if (target_module.kind == .native_plugin) allows_dynamic_commands = true;
                // 実効辺のみ取り込み位置での実行対象になる
                if (item.effective and target_module.kind == .nako3) {
                    try import_entries.append(temp, .{
                        .position = item.span.start,
                        .entry_name = try std.fmt.allocPrint(temp, "{s}__$entry", .{runtime_module_names[target]}),
                        .site_module = loader_to_input[module.index],
                        .site_order = module.expand_order,
                        .callee_module = loader_to_input[target],
                        .callee_order = target_module.expand_order,
                        .callee_variant = item.variant,
                    });
                }
            };
            var variant_inputs: std.ArrayList(analyzer.VariantInput) = .empty;
            for (module.variants.items) |variant| {
                const vroot = variant.parse.root orelse continue;
                var ventries: std.ArrayList(analyzer.ImportEntry) = .empty;
                for (variant.imports) |vitem| if (vitem.target) |target| {
                    const target_module = self.modules[target];
                    if (vitem.effective and target_module.kind == .nako3) {
                        try ventries.append(temp, .{
                            .position = vitem.span.start,
                            .entry_name = try std.fmt.allocPrint(temp, "{s}__$entry", .{runtime_module_names[target]}),
                            .site_module = loader_to_input[module.index],
                            .site_order = module.expand_order,
                            .callee_module = loader_to_input[target],
                            .callee_order = target_module.expand_order,
                            .callee_variant = vitem.variant,
                        });
                    }
                };
                try variant_inputs.append(temp, .{
                    .root = vroot,
                    .import_entries = try ventries.toOwnedSlice(temp),
                });
            }
            var namespace_aliases: std.ArrayList(analyzer.NamespaceAlias) = .empty;
            for (module.imports) |item| if (item.target) |target| {
                const source_namespace = item.namespace orelse continue;
                if (self.modules[target].kind != .nako3) continue;
                const namespace_alias = analyzer.NamespaceAlias{
                    .source_namespace = source_namespace,
                    .internal_namespace = internal_module_names[target],
                    .target_module = loader_to_input[target],
                    .is_explicit = item.canonical_id != null,
                };
                var already_added = false;
                for (namespace_aliases.items, 0..) |existing, index| {
                    if (!std.mem.eql(u8, existing.source_namespace, source_namespace)) continue;
                    // A package alias is explicit and takes precedence over a
                    // relative import's filename-derived namespace on collision.
                    if (namespace_alias.is_explicit and !existing.is_explicit) namespace_aliases.items[index] = namespace_alias;
                    already_added = true;
                    break;
                }
                if (!already_added) try namespace_aliases.append(temp, namespace_alias);
            };
            const owns_scoped_namespace_collision = if (module.canonical_id) |canonical_id| collision: {
                var has_scoped_alias_collision = false;
                for (self.modules) |candidate| {
                    if (candidate == module) continue;
                    if (candidate.canonical_id == null) {
                        if (module.source_namespace) |namespace| {
                            if (std.mem.eql(u8, namespace, candidate.name)) {
                                has_scoped_alias_collision = true;
                                break;
                            }
                        }
                        continue;
                    }
                    const same_namespace_different_export = if (module.source_namespace) |namespace|
                        if (candidate.source_namespace) |candidate_namespace|
                            std.mem.eql(u8, namespace, candidate_namespace) and !std.mem.eql(u8, canonical_id, candidate.canonical_id.?)
                        else
                            false
                    else
                        false;
                    if (same_namespace_different_export) {
                        has_scoped_alias_collision = true;
                        break;
                    }
                }
                break :collision has_scoped_alias_collision;
            } else collision: {
                for (self.modules) |candidate| {
                    if (candidate == module) continue;
                    const candidate_namespace = candidate.source_namespace orelse continue;
                    if (std.mem.eql(u8, module.name, candidate_namespace)) break :collision true;
                }
                break :collision false;
            };
            try inputs.append(temp, .{
                .name = runtime_module_names[module.index],
                .internal_namespace = internal_module_names[module.index],
                .path = module.path,
                .root = module.parsed.?.root.?,
                .normalized_source = module.parsed.?.stream.source.text,
                .allows_dynamic_commands = allows_dynamic_commands,
                .is_package = module.canonical_id != null,
                .expands_in_function = module.expands_in_function,
                .owns_scoped_namespace_collision = owns_scoped_namespace_collision,
                .namespace_aliases = try namespace_aliases.toOwnedSlice(temp),
                .variants = try variant_inputs.toOwnedSlice(temp),
                .stmt_ranks = if (module.index < self.expansion.stmt_ranks.len) self.expansion.stmt_ranks[module.index] else &.{},
                .marker_rank = if (module.index < self.expansion.marker_ranks.len) self.expansion.marker_ranks[module.index] else std.math.maxInt(usize),
                .import_entries = try import_entries.toOwnedSlice(temp),
            });
        }
        return analyzer.analyzeModules(allocator, inputs.items);
    }
};

fn uniqueInternalModuleName(
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
    const entry = try loader.loadOne(normalized_entry, null, null, null, null);
    // 実効辺の決定とモード伝搬は全モジュール読み込み後に行う。
    // 公式のreplaceRequireStatementsは取り込み文を逆順に処理し、filePath単位の
    // include guardで最初に処理された辺だけへ内容を展開する（同一ファイルの
    // 複数取り込みでは最後の取り込み文に内容が載る）。
    try loader.markEffectiveEdges(entry);
    try loader.propagateModes(entry);
    try variants.buildCopyVariants(&loader);
    try variants.attachInlineExpansions(&loader, entry);
    const modules = try loader.modules.toOwnedSlice(loader.allocator);
    errdefer for (modules) |module| {
        if (module.parsed) |*parsed| parsed.deinit();
        for (module.variants.items) |*variant| variant.parse.deinit();
        backing_allocator.free(module.source);
        backing_allocator.destroy(module);
    };
    const diagnostics = try loader.diagnostics.toOwnedSlice(loader.allocator);
    // arenaを返却値へコピーする前に確保を済ませる。リテラル内で呼ぶと
    // コピー後のarena状態へ確保が記録されずリークする。
    const expansion = try buildExpansion(loader.allocator, modules, entry);
    return .{
        .backing_allocator = backing_allocator,
        .arena = arena,
        .modules = modules,
        .entry = entry,
        .diagnostics = diagnostics,
        .expansion = expansion,
    };
}

// 循環コピー変体・関数内展開の構築は module_graph_variants.zig へ分離している
// （サイズガードレール対応）。Loaderの状態を共有するためpubで公開する。
pub const Loader = struct {
    backing_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    provider: SourceProvider,
    options: Options,
    modules: std.ArrayList(*LoadedModule) = .empty,
    diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty,

    fn deinitModules(self: *Loader) void {
        for (self.modules.items) |module| {
            if (module.parsed) |*parsed| parsed.deinit();
            for (module.variants.items) |*variant| variant.parse.deinit();
            self.backing_allocator.free(module.source);
            self.backing_allocator.destroy(module);
        }
    }

    /// `initial` は取り込み文位置で有効だったパーサモード（取り込み元からの継承）。
    /// 字句変換には波及せず、添字・自動初期化の意味づけのみに効く。
    fn loadOne(self: *Loader, path: []const u8, import_node: ?*ast.Node, initial: ?token_mod.Mode, namespace_override: ?[]const u8, canonical_id: ?[]const u8) anyerror!u32 {
        if (canonical_id) |id| {
            if (self.findCanonical(id)) |existing| return existing;
            // A package export may resolve to a file already loaded by a relative
            // import. Reuse that module without changing its established name or
            // identity; the Import edge carries the package alias separately.
            if (self.findLocalPath(path)) |existing| return existing;
        } else if (self.find(path)) |existing| {
            return existing;
        }
        const extension = std.fs.path.extension(path);
        const extension_mode = extensionForcedMode(path);
        const is_dncl = extension_mode.dncl;
        const is_dncl2 = extension_mode.dncl2;
        const kind: ModuleKind = if (std.ascii.eqlIgnoreCase(extension, ".nako3") or is_dncl or is_dncl2)
            .nako3
        else if (std.ascii.eqlIgnoreCase(extension, ".js") or std.ascii.eqlIgnoreCase(extension, ".mjs"))
            .javascript
        else if (isNativePluginExtension(extension))
            .native_plugin
        else {
            try self.importDiagnostic(import_node, path, "取り込めるのは.nako3、.dncl、.dncl2、JavaScript、ネイティブプラグインです");
            return error.UnsupportedImport;
        };
        // .dnclはDNCLモード(v1)、.dncl2はDNCL2を強制する。
        // v1とv2を同時に有効化すると公式と同じく「を実行し、そうでなければ」が
        // v2側の先取り変換で壊れるため、.dnclはv1のみに限定する。
        var forced_mode: token_mod.Mode = .{};
        if (is_dncl) forced_mode.dncl = true;
        if (is_dncl2) forced_mode.dncl2 = true;
        if (self.modules.items.len == 0) {
            // エントリ拡張子とCLI強制フラグが反対側のDNCL方言を要求する組合せは
            // 両方言の同時有効化になるため、--dncl+--dncl2と同じ競合として拒否する。
            if ((is_dncl and self.options.forced_mode.dncl2) or (is_dncl2 and self.options.forced_mode.dncl))
                return error.ConflictingDnclModes;
            forced_mode.dncl = forced_mode.dncl or self.options.forced_mode.dncl;
            forced_mode.dncl2 = forced_mode.dncl2 or self.options.forced_mode.dncl2;
            forced_mode.indent = forced_mode.indent or self.options.forced_mode.indent;
        }
        const native_builtin = kind == .javascript and isNativeBuiltinPlugin(path);
        if (kind == .javascript and !self.options.compat_js and !native_builtin) {
            try self.importDiagnostic(import_node, path, "JavaScriptの取り込みには--compat-jsが必要です");
            return error.JavaScriptCompatibilityRequired;
        }

        const source = if (native_builtin or kind == .native_plugin)
            try self.backing_allocator.alloc(u8, 0)
        else
            self.provider.read(self.backing_allocator, path) catch |err| {
                try self.importDiagnostic(import_node, path, "取り込み先を読み込めません");
                return err;
            };
        var registered = false;
        errdefer if (!registered) self.backing_allocator.free(source);
        const module = try self.backing_allocator.create(LoadedModule);
        errdefer if (!registered) self.backing_allocator.destroy(module);
        const name = if (namespace_override) |namespace|
            try self.allocator.dupe(u8, namespace)
        else
            try analyzer.moduleName(self.allocator, path);
        module.* = .{
            .index = @intCast(self.modules.items.len),
            .kind = kind,
            .state = .loading,
            .path = try self.allocator.dupe(u8, path),
            .canonical_id = if (canonical_id) |id| try self.allocator.dupe(u8, id) else null,
            .source_namespace = if (namespace_override) |namespace| try self.allocator.dupe(u8, namespace) else null,
            .name = name,
            .source = source,
            .parsed = null,
            .forced_mode = forced_mode,
        };
        try self.modules.append(self.allocator, module);
        // The graph owns both allocations from here, including modules whose
        // parsing fails. The outer loader (or returned graph) cleans them up.
        registered = true;

        if (kind == .native_plugin) {
            module.state = .loaded;
            return module.index;
        }

        if (kind == .javascript) {
            var imports: std.ArrayList(Import) = .empty;
            const requested_imports = try collectJavaScriptImports(self.allocator, source);
            for (requested_imports) |requested| {
                if (!std.fs.path.isAbsolute(requested) and !std.mem.startsWith(u8, requested, ".")) continue;
                const resolved = resolveImport(self.allocator, path, requested) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try self.importDiagnostic(import_node, path, "JavaScriptの相対取り込みパスが不正です");
                    continue;
                };
                const imported_extension = std.fs.path.extension(resolved);
                if (!std.ascii.eqlIgnoreCase(imported_extension, ".js") and !std.ascii.eqlIgnoreCase(imported_extension, ".mjs")) continue;
                const existing = self.find(resolved);
                var target: ?u32 = existing;
                var cyclic = false;
                if (existing) |index| {
                    cyclic = self.modules.items[index].state == .loading;
                } else {
                    target = self.loadOne(resolved, import_node, null, null, null) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => null,
                    };
                }
                try imports.append(self.allocator, .{
                    .requested = try self.allocator.dupe(u8, requested),
                    .resolved_path = resolved,
                    .target = target,
                    .span = ast.emptySpan(),
                    .cyclic = cyclic,
                });
            }
            module.imports = try imports.toOwnedSlice(self.allocator);
            module.state = .loaded;
            return module.index;
        }
        // 取り込み元から継承したモード（initial）でパースし、各取り込み文
        // 位置でのモードを得る。実効辺の決定と終端モードの反映は全モジュール
        // 読み込み後の propagateModes が行う。
        module.parsed = parser.parseWithMode(self.backing_allocator, source, path, .{
            .forced = forced_mode,
            .initial = initial,
            .builtin_commands = &builtin_catalog.function_names,
        }) catch |err| {
            try self.importDiagnostic(import_node, path, "取り込み先を字句解析できません");
            return err;
        };
        module.parse_initial = initial orelse .{};
        if (module.parsed.?.root) |root| {
            var import_nodes: std.ArrayList(*ast.Node) = .empty;
            try collectImports(root, &import_nodes, self.allocator);
            var imports: std.ArrayList(Import) = .empty;
            // 先行する取り込み先の終端モードの暫定累積（実効辺未確定のため近似値）
            var cumulative: token_mod.Mode = .{};
            for (import_nodes.items) |node| {
                const resolved_import = resolveRequestedImport(self.allocator, path, node.value, self.options.package_resolver) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    const message = if (isPackageSpecifier(node.value))
                        "パッケージ参照を解決できません（同期済み環境・公開export・aliasを確認してください）"
                    else
                        "相対取り込みパスが不正です";
                    try self.importDiagnostic(node, path, message);
                    continue;
                };
                if (resolved_import.canonical_id) |resolved_canonical_id| {
                    if (resolved_import.namespace) |namespace| {
                        for (imports.items) |previous| {
                            const previous_id = previous.canonical_id orelse continue;
                            const previous_namespace = previous.namespace orelse continue;
                            if (std.mem.eql(u8, namespace, previous_namespace) and
                                !std.mem.eql(u8, resolved_canonical_id, previous_id))
                            {
                                try self.importDiagnostic(node, path, "異なるpackage exportが同じ公開namespaceを使用しています");
                                break;
                            }
                        }
                    }
                }
                var site_mode = cumulative;
                for (module.parsed.?.import_modes) |record| {
                    if (record.position == node.span.start) {
                        site_mode = orMode(site_mode, record.mode);
                        break;
                    }
                }
                const existing = self.findImport(resolved_import.path, resolved_import.canonical_id);
                var target: ?u32 = existing;
                var cyclic = false;
                if (existing) |index| {
                    cyclic = self.modules.items[index].state == .loading;
                } else {
                    target = self.loadOne(resolved_import.path, node, site_mode, resolved_import.namespace, resolved_import.canonical_id) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => null,
                    };
                }
                if (target) |target_index| {
                    const target_module = self.modules.items[target_index];
                    if (target_module.kind == .nako3 and target_module.parsed != null) {
                        cumulative = orMode(cumulative, target_module.parsed.?.final_mode);
                    }
                }
                try imports.append(self.allocator, .{
                    .requested = try self.allocator.dupe(u8, node.value),
                    .resolved_path = resolved_import.path,
                    .canonical_id = resolved_import.canonical_id,
                    .namespace = resolved_import.namespace orelse try analyzer.moduleName(self.allocator, resolved_import.path),
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

    /// 公式のreplaceRequireStatements相当: 各モジュールの取り込み文を逆順に
    /// 処理し、filePath単位のガードで最初に処理された辺のみを実効辺にする。
    /// エントリ自身はガードへ入れないため、循環取り込みでエントリの内容が
    /// 一度だけ再展開される。
    fn markEffectiveEdges(self: *Loader, entry: u32) !void {
        const guarded = try self.allocator.alloc(bool, self.modules.items.len);
        @memset(guarded, false);
        var order_counter: u32 = 0;
        try self.markEffectiveIn(entry, guarded, &order_counter);
    }

    fn markEffectiveIn(self: *Loader, index: u32, guarded: []bool, order_counter: *u32) !void {
        const module = self.modules.items[index];
        var i = module.imports.len;
        while (i > 0) {
            i -= 1;
            const item = &module.imports[i];
            const target = item.target orelse continue;
            const target_module = self.modules.items[target];
            if (target_module.kind != .nako3 or target_module.parsed == null) continue;
            // Namespace aliases point at a shared loaded module. The effective
            // edge guard ensures each canonical export (or local file) is initialized once.
            if (guarded[target]) continue;
            guarded[target] = true;
            target_module.expand_order = order_counter.*;
            order_counter.* += 1;
            item.effective = true;
            try self.markEffectiveIn(target, guarded, order_counter);
        }
    }

    /// 実効辺に沿ってパーサモードを伝搬する。取り込み文位置のモードが
    /// 取り込み先の初期モードになり、取り込み先の終端モードが取り込み文の
    /// 直後へ適用される（tail_modes）。モードは単調に有効化される。
    fn propagateModes(self: *Loader, entry: u32) !void {
        const state = try self.allocator.alloc(ModeState, self.modules.items.len);
        @memset(state, .unvisited);
        try self.propagateInto(entry, .{}, state);
    }

    fn propagateInto(self: *Loader, index: u32, initial: token_mod.Mode, state: []ModeState) !void {
        if (state[index] != .unvisited) return;
        state[index] = .visiting;
        const module = self.modules.items[index];
        defer state[index] = .done;
        if (module.kind != .nako3 or module.parsed == null) return;

        // 正しい初期モードで必要なら再パースし、取り込み文位置のモードを更新する
        if (!modeEql(module.parse_initial, initial)) {
            const reparsed = parser.parseWithMode(self.backing_allocator, module.source, module.path, .{
                .forced = module.forced_mode,
                .initial = initial,
                .builtin_commands = &builtin_catalog.function_names,
            }) catch |err| {
                try self.importDiagnostic(null, module.path, "取り込み先を字句解析できません");
                return err;
            };
            module.parsed.?.deinit();
            module.parsed = reparsed;
            module.parse_initial = initial;
            try self.refreshImportSpans(module);
        }

        var cumulative: token_mod.Mode = .{};
        var tail_modes: std.ArrayList(parser.TailMode) = .empty;
        for (module.imports) |*item| {
            if (!item.effective) continue;
            const target = item.target.?;
            var site_mode = cumulative;
            for (module.parsed.?.import_modes) |record| {
                if (record.position == item.span.start) {
                    site_mode = orMode(site_mode, record.mode);
                    break;
                }
            }
            item.site_mode = site_mode;
            try self.propagateInto(target, site_mode, state);
            const target_module = self.modules.items[target];
            if (target_module.parsed) |target_parsed| {
                cumulative = orMode(cumulative, target_parsed.final_mode);
                item.tail_mode = target_parsed.final_mode;
                try tail_modes.append(self.allocator, .{ .position = item.span.start, .mode = target_parsed.final_mode });
            }
        }
        if (tail_modes.items.len > 0) {
            const reparsed = parser.parseWithMode(self.backing_allocator, module.source, module.path, .{
                .forced = module.forced_mode,
                .initial = initial,
                .tail_modes = tail_modes.items,
                .builtin_commands = &builtin_catalog.function_names,
            }) catch |err| {
                try self.importDiagnostic(null, module.path, "取り込み先を字句解析できません");
                return err;
            };
            module.parsed.?.deinit();
            module.parsed = reparsed;
            try self.refreshImportSpans(module);
        }
    }

    /// 再パースで構文変換が文境界を動かし得るため、取り込み文のspanを
    /// 最終ASTから順序対応で再収集する。個数が変わる構造変化では
    /// 暫定位置との照合が破綻して実効辺が暗黙に無効化されるため、
    /// 黙って維持せず診断を出す。
    fn refreshImportSpans(self: *Loader, module: *LoadedModule) !void {
        const parsed = module.parsed orelse return;
        const root = parsed.root orelse return;
        var import_nodes: std.ArrayList(*ast.Node) = .empty;
        try collectImports(root, &import_nodes, self.allocator);
        if (import_nodes.items.len != module.imports.len) {
            try self.importDiagnostic(null, module.path, "取り込み文の位置を再パース後に特定できません");
            return;
        }
        for (import_nodes.items, 0..) |node, index| module.imports[index].span = node.span;
    }

    fn find(self: *Loader, path: []const u8) ?u32 {
        for (self.modules.items) |module| if (std.mem.eql(u8, module.path, path)) return module.index;
        return null;
    }

    fn findLocalPath(self: *Loader, path: []const u8) ?u32 {
        for (self.modules.items) |module| {
            if (module.canonical_id == null and std.mem.eql(u8, module.path, path)) return module.index;
        }
        return null;
    }

    fn findCanonical(self: *Loader, canonical_id: []const u8) ?u32 {
        for (self.modules.items) |module| {
            const id = module.canonical_id orelse continue;
            if (std.mem.eql(u8, id, canonical_id)) return module.index;
        }
        return null;
    }

    fn findImport(self: *Loader, path: []const u8, canonical_id: ?[]const u8) ?u32 {
        if (canonical_id) |id| {
            return self.findCanonical(id) orelse self.findLocalPath(path);
        }
        return self.find(path);
    }

    fn importDiagnostic(self: *Loader, node: ?*ast.Node, file: []const u8, message: []const u8) !void {
        try self.importDiagnosticAt(if (node) |value| value.span else null, file, message);
    }

    pub fn importDiagnosticAt(self: *Loader, span: ?ast.Span, file: []const u8, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .code = .invalid_import,
            .message = message,
            .file = try self.allocator.dupe(u8, file),
            .span = span orelse ast.emptySpan(),
        });
    }

    /// 取り込み展開を接続した後のAST深さ超過を位置付き診断にする。
    /// ファイル単体の解析時検査（`parser.max_ast_depth`）では、展開子が
    /// 後から接続されるため合成後の深さを測れない。
    pub fn nestingDiagnosticAt(self: *Loader, span: ?ast.Span, file: []const u8, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .code = .nesting_too_deep,
            .message = message,
            .file = try self.allocator.dupe(u8, file),
            .span = span orelse ast.emptySpan(),
        });
    }
};

const ModeState = enum { unvisited, visiting, done };

pub fn orMode(a: token_mod.Mode, b: token_mod.Mode) token_mod.Mode {
    return .{
        .dncl = a.dncl or b.dncl,
        .dncl2 = a.dncl2 or b.dncl2,
        .indent = a.indent or b.indent,
    };
}

pub fn modeEql(a: token_mod.Mode, b: token_mod.Mode) bool {
    return a.dncl == b.dncl and a.dncl2 == b.dncl2 and a.indent == b.indent;
}

/// aのモードbitが全てbに含まれるか
fn modeSubset(a: token_mod.Mode, b: token_mod.Mode) bool {
    return (!a.dncl or b.dncl) and (!a.dncl2 or b.dncl2) and (!a.indent or b.indent);
}

/// 結合ストリーム上の文順位をDFSで構築する。公式の取り込みは先勝ちの
/// include guard付きトークン置換なので、各モジュールの内容は最初の実効
/// 取り込み辺の位置に一度だけ展開される。文内部の取り込み文はその文の
/// 位置に展開されるものとして近似する。
fn buildExpansion(allocator: std.mem.Allocator, modules: []*LoadedModule, entry: u32) !Expansion {
    const stmt_ranks = try allocator.alloc([]usize, modules.len);
    const marker_ranks = try allocator.alloc(usize, modules.len);
    const visited = try allocator.alloc(bool, modules.len);
    @memset(visited, false);
    @memset(marker_ranks, std.math.maxInt(usize));
    for (modules, 0..) |module, index| {
        const count: usize = if (module.kind == .nako3 and module.parsed != null and module.parsed.?.root != null)
            module.parsed.?.root.?.children.len
        else
            0;
        stmt_ranks[index] = try allocator.alloc(usize, count);
        @memset(stmt_ranks[index], std.math.maxInt(usize));
    }
    var rank: usize = 0;
    try expandModule(allocator, modules, entry, visited, stmt_ranks, marker_ranks, &rank);
    return .{ .stmt_ranks = stmt_ranks, .marker_ranks = marker_ranks };
}

fn expandModule(allocator: std.mem.Allocator, modules: []*LoadedModule, index: u32, visited: []bool, stmt_ranks: []const []usize, marker_ranks: []usize, rank: *usize) !void {
    if (visited[index]) return;
    visited[index] = true;
    // 公式は展開先頭にプラグイン名設定マーカーを挿し、modListはその出現順に並ぶ
    marker_ranks[index] = rank.*;
    const module = modules[index];
    if (module.kind != .nako3 or module.parsed == null or module.parsed.?.root == null) return;
    for (module.parsed.?.root.?.children, 0..) |child, k| {
        if (effectiveImportTarget(module, child.span.start)) |target| {
            try expandModule(allocator, modules, target, visited, stmt_ranks, marker_ranks, rank);
            continue;
        }
        stmt_ranks[index][k] = rank.*;
        rank.* += 1;
        // 文内部の取り込み文は、その文の直後へ展開されるものとして扱う
        var nested: std.ArrayList(*ast.Node) = .empty;
        try collectImports(child, &nested, allocator);
        for (nested.items) |node| {
            if (effectiveImportTarget(module, node.span.start)) |target| {
                try expandModule(allocator, modules, target, visited, stmt_ranks, marker_ranks, rank);
            }
        }
    }
}

/// 指定位置の取り込み文が実効辺なら取り込み先モジュールのindexを返す。
fn effectiveImportTarget(module: *LoadedModule, position: usize) ?u32 {
    for (module.imports) |item| {
        if (item.span.start == position and item.effective and item.target != null) return item.target;
    }
    return null;
}

fn isNativeBuiltinPlugin(path: []const u8) bool {
    const basename = std.fs.path.basename(path);
    const names = [_][]const u8{
        "plugin_httpserver.mjs",
        "plugin_httpserver.js",
        "plugin_markup.mjs",
        "plugin_markup.js",
        "plugin_csv.mjs",
        "plugin_csv.js",
        "plugin_toml.mjs",
        "plugin_toml.js",
        "plugin_caniuse.mjs",
        "plugin_caniuse.js",
        "plugin_kansuji.mjs",
        "plugin_kansuji.js",
        "plugin_datetime.mjs",
        "plugin_datetime.js",
    };
    for (names) |name| if (std.ascii.eqlIgnoreCase(basename, name)) return true;
    return false;
}

fn collectImports(node: *ast.Node, output: *std.ArrayList(*ast.Node), allocator: std.mem.Allocator) !void {
    if (node.kind == .import) try output.append(allocator, node);
    for (node.children) |child| try collectImports(child, output, allocator);
}

const JavaScriptTokenKind = enum { identifier, string, punctuation };
const JavaScriptToken = struct { kind: JavaScriptTokenKind, text: []const u8 };

fn collectJavaScriptImports(allocator: std.mem.Allocator, source: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (nextJavaScriptToken(source, &index)) |token| {
        if (token.kind != .identifier) continue;
        const is_import = std.mem.eql(u8, token.text, "import");
        const is_export = std.mem.eql(u8, token.text, "export");
        if (!is_import and !is_export) continue;
        var saw_from = false;
        var scanned: usize = 0;
        while (scanned < 256) : (scanned += 1) {
            const candidate = nextJavaScriptToken(source, &index) orelse break;
            if (candidate.kind == .punctuation and (std.mem.eql(u8, candidate.text, ";") or std.mem.eql(u8, candidate.text, "("))) break;
            if (candidate.kind == .identifier and std.mem.eql(u8, candidate.text, "from")) {
                saw_from = true;
                continue;
            }
            if (candidate.kind != .string) continue;
            if (std.mem.indexOfScalar(u8, candidate.text, '\\') != null) return error.UnsupportedJavaScriptImportEscape;
            if ((is_import and (saw_from or scanned == 0)) or (is_export and saw_from)) try result.append(allocator, try allocator.dupe(u8, candidate.text));
            break;
        }
    }
    return result.toOwnedSlice(allocator);
}

fn nextJavaScriptToken(source: []const u8, index: *usize) ?JavaScriptToken {
    while (index.* < source.len) {
        const character = source[index.*];
        if (std.ascii.isWhitespace(character)) {
            index.* += 1;
            continue;
        }
        if (character == '/' and index.* + 1 < source.len and source[index.* + 1] == '/') {
            index.* += 2;
            while (index.* < source.len and source[index.*] != '\n') index.* += 1;
            continue;
        }
        if (character == '/' and index.* + 1 < source.len and source[index.* + 1] == '*') {
            index.* += 2;
            while (index.* + 1 < source.len and !(source[index.*] == '*' and source[index.* + 1] == '/')) index.* += 1;
            index.* = @min(source.len, index.* + 2);
            continue;
        }
        if (character == '`') {
            index.* += 1;
            while (index.* < source.len) : (index.* += 1) {
                if (source[index.*] == '\\') {
                    index.* = @min(source.len, index.* + 1);
                } else if (source[index.*] == '`') {
                    index.* += 1;
                    break;
                }
            }
            continue;
        }
        if (character == '\'' or character == '"') {
            const quote = character;
            const start = index.* + 1;
            index.* = start;
            while (index.* < source.len) : (index.* += 1) {
                if (source[index.*] == '\\') {
                    index.* = @min(source.len, index.* + 1);
                    continue;
                }
                if (source[index.*] == quote) {
                    const text = source[start..index.*];
                    index.* += 1;
                    return .{ .kind = .string, .text = text };
                }
            }
            return null;
        }
        if (std.ascii.isAlphabetic(character) or character == '_' or character == '$') {
            const start = index.*;
            index.* += 1;
            while (index.* < source.len and (std.ascii.isAlphanumeric(source[index.*]) or source[index.*] == '_' or source[index.*] == '$')) index.* += 1;
            return .{ .kind = .identifier, .text = source[start..index.*] };
        }
        index.* += 1;
        return .{ .kind = .punctuation, .text = source[index.* - 1 .. index.*] };
    }
    return null;
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.path.resolve(allocator, &.{path});
}

fn isNativePluginExtension(extension: []const u8) bool {
    return std.ascii.eqlIgnoreCase(extension, ".dylib") or
        std.ascii.eqlIgnoreCase(extension, ".so") or
        std.ascii.eqlIgnoreCase(extension, ".dll");
}

fn isPackageSpecifier(requested: []const u8) bool {
    return std.mem.startsWith(u8, requested, "パッケージ:") or std.mem.startsWith(u8, requested, "pkg:");
}

const ResolvedImport = struct {
    path: []u8,
    canonical_id: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
};

fn resolveRequestedImport(allocator: std.mem.Allocator, importer: []const u8, requested: []const u8, package_resolver: ?PackageResolver) !ResolvedImport {
    if (!isPackageSpecifier(requested)) return .{ .path = try resolveImport(allocator, importer, requested) };
    const resolver = package_resolver orelse return error.PackageResolverUnavailable;
    const selected = try resolver.resolve(allocator, importer, requested);
    return .{ .path = try normalizePath(allocator, selected.path), .canonical_id = selected.canonical_id, .namespace = selected.namespace };
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
        for (self.files) |file| if (pathHasSuffix(path, file.suffix)) return allocator.dupe(u8, file.source);
        return error.FileNotFound;
    }
};

fn pathHasSuffix(path: []const u8, suffix: []const u8) bool {
    if (suffix.len > path.len) return false;
    const start = path.len - suffix.len;
    if (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') return false;
    for (suffix, 0..) |char, index| {
        const path_char = path[start + index];
        const normalized_path_char: u8 = if (path_char == '\\') '/' else path_char;
        const normalized_suffix_char: u8 = if (char == '\\') '/' else char;
        if (normalized_path_char != normalized_suffix_char) return false;
    }
    return true;
}

const PackageTestResolver = struct {
    fn resolver(self: *PackageTestResolver) PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, specifier: []const u8) !ResolvedPackageImport {
        const reference = if (std.mem.startsWith(u8, specifier, "パッケージ:"))
            specifier["パッケージ:".len..]
        else if (std.mem.startsWith(u8, specifier, "pkg:"))
            specifier["pkg:".len..]
        else
            return error.InvalidPackageSpecifier;
        const path = if (std.mem.eql(u8, reference, "math") or std.mem.eql(u8, reference, "math-alt"))
            "packages/math/index.nako3"
        else if (std.mem.eql(u8, reference, "util"))
            "packages/util/index.nako3"
        else if (std.mem.eql(u8, reference, "math/vector"))
            "packages/math/vector.nako3"
        else if (std.mem.eql(u8, reference, "geometry"))
            "packages/geometry/index.nako3"
        else
            return error.PackageNotFound;
        const namespace = if (std.mem.eql(u8, reference, "math"))
            "math"
        else if (std.mem.eql(u8, reference, "math-alt"))
            "math_alt"
        else if (std.mem.eql(u8, reference, "util"))
            "util"
        else if (std.mem.eql(u8, reference, "math/vector"))
            "math__vector"
        else
            "geometry";
        const canonical_id = if (std.mem.eql(u8, reference, "math") or std.mem.eql(u8, reference, "math-alt"))
            "pkg:math-id/main"
        else if (std.mem.eql(u8, reference, "util"))
            "pkg:util-id/main"
        else if (std.mem.eql(u8, reference, "math/vector"))
            "pkg:math-id/vector"
        else
            "pkg:geometry-id/main";
        return .{
            .path = try std.fs.path.resolve(allocator, &.{path}),
            .canonical_id = try allocator.dupe(u8, canonical_id),
            .namespace = namespace,
        };
    }
};

const NamespaceCollisionPackageResolver = struct {
    fn resolver(self: *NamespaceCollisionPackageResolver) PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, specifier: []const u8) !ResolvedPackageImport {
        const path = if (std.mem.eql(u8, specifier, "pkg:scoped"))
            "packages/scoped/main.nako3"
        else if (std.mem.eql(u8, specifier, "pkg:flat"))
            "packages/flat/main.nako3"
        else
            return error.PackageNotFound;
        const canonical_id = if (std.mem.eql(u8, specifier, "pkg:scoped")) "pkg:scoped/main" else "pkg:flat/main";
        return .{
            .path = try std.fs.path.resolve(allocator, &.{path}),
            .canonical_id = try allocator.dupe(u8, canonical_id),
            .namespace = try allocator.dupe(u8, "alice__tool"),
        };
    }
};

test "正規化後に同じnamespaceとなる別package importを診断する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:scoped」を取り込む\n!「pkg:flat」を取り込む\n" },
        .{ .suffix = "packages/scoped/main.nako3", .source = "値=1\n" },
        .{ .suffix = "packages/flat/main.nako3", .source = "値=2\n" },
    } };
    var package_resolver = NamespaceCollisionPackageResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    var reported_namespace_collision = false;
    for (graph.diagnostics) |item| {
        if (std.mem.indexOf(u8, item.message, "同じ公開namespace") != null) reported_namespace_collision = true;
    }
    try std.testing.expect(reported_namespace_collision);
}

test "日本語パッケージ:とpkg:を注入resolverでsource exportへ解決する" {
    const cases = [_]struct { specifier: []const u8, suffix: []const u8 }{
        .{ .specifier = "パッケージ:math", .suffix = "packages/math/index.nako3" },
        .{ .specifier = "パッケージ:math/vector", .suffix = "packages/math/vector.nako3" },
        .{ .specifier = "pkg:math", .suffix = "packages/math/index.nako3" },
    };
    for (cases) |case| {
        const source = try std.fmt.allocPrint(std.testing.allocator, "!「{s}」を取り込む\n", .{case.specifier});
        defer std.testing.allocator.free(source);
        var memory = MemoryProvider{ .files = &.{
            .{ .suffix = "main.nako3", .source = source },
            .{ .suffix = case.suffix, .source = "A=1\n" },
        } };
        var package_resolver = PackageTestResolver{};
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
        defer graph.deinit();
        try std.testing.expect(graph.succeeded());
        try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
        try std.testing.expect(pathHasSuffix(graph.modules[1].path, case.suffix));
        const expected_namespace = if (std.mem.eql(u8, case.specifier, "パッケージ:math/vector")) "math__vector" else "math";
        try std.testing.expectEqualStrings(expected_namespace, graph.modules[1].name);
        const expected_id = if (std.mem.eql(u8, case.specifier, "パッケージ:math/vector")) "pkg:math-id/vector" else "pkg:math-id/main";
        try std.testing.expectEqualStrings(expected_id, graph.modules[1].canonical_id.?);
    }
}

test "package resolver未設定ではpackage specifierを拒否する" {
    var memory = MemoryProvider{ .files = &.{.{ .suffix = "main.nako3", .source = "!「パッケージ:missing」を取り込む\n" }} };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.len);
    try std.testing.expect(std.mem.indexOf(u8, graph.diagnostics[0].message, "パッケージ参照") != null);
}

const TestLocalPackageResolver = struct {
    fn resolver(self: *TestLocalPackageResolver) PackageResolver {
        return .{ .context = self, .resolveFn = resolve };
    }

    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, specifier: []const u8) !ResolvedPackageImport {
        if (!std.mem.eql(u8, specifier, "パッケージ:lib")) return error.PackageNotFound;
        return .{
            .path = try std.fs.path.resolve(allocator, &.{"lib/index.nako3"}),
            .canonical_id = try allocator.dupe(u8, "pkg:lib/main"),
            .namespace = "lib",
        };
    }
};

test "package namespace aliasは取り込み順に関係なく同名local moduleより優先する" {
    const import_orders = [_][]const u8{
        "!「lib/util.nako3」を取り込む\n!「pkg:util」を取り込む\nutil__値を表示\n",
        "!「pkg:util」を取り込む\n!「lib/util.nako3」を取り込む\nutil__値を表示\n",
    };
    for (import_orders) |main_source| {
        var memory = MemoryProvider{ .files = &.{
            .{ .suffix = "main.nako3", .source = main_source },
            .{ .suffix = "lib/util.nako3", .source = "値=1\n" },
            .{ .suffix = "packages/util/index.nako3", .source = "値=2\n" },
        } };
        var package_resolver = PackageTestResolver{};
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
        defer graph.deinit();
        try std.testing.expect(graph.succeeded());
        const package_module = if (std.mem.eql(u8, graph.modules[1].canonical_id orelse "", "pkg:util-id/main")) graph.modules[1] else graph.modules[2];
        var program = try graph.analyze(std.testing.allocator);
        defer program.deinit();
        try std.testing.expect(program.succeeded());
        var found_package_binding = false;
        for (program.bindings) |binding| {
            if (!std.mem.eql(u8, binding.name, "util__値")) continue;
            const symbol_id = binding.symbol orelse continue;
            found_package_binding = program.symbols[symbol_id].module_index == package_module.index;
            break;
        }
        try std.testing.expect(found_package_binding);
    }
}

test "canonical package exportは複数aliasから同じmoduleと状態を共有する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「pkg:math」を取り込む\n!「pkg:math-alt」を取り込む\nmath__値を表示\nmath_alt__値を表示\n" },
        .{ .suffix = "packages/math/index.nako3", .source = "値=1\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(graph.modules[0].imports[0].target, graph.modules[0].imports[1].target);
    try std.testing.expect(graph.modules[0].imports[0].effective != graph.modules[0].imports[1].effective);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var math_resolved: ?[]const u8 = null;
    var math_alt_resolved: ?[]const u8 = null;
    for (program.bindings) |binding| {
        if (std.mem.eql(u8, binding.name, "math__値")) math_resolved = binding.resolved_name;
        if (std.mem.eql(u8, binding.name, "math_alt__値")) math_alt_resolved = binding.resolved_name;
    }
    try std.testing.expect(math_resolved != null and math_alt_resolved != null);
    try std.testing.expectEqualStrings(math_resolved.?, math_alt_resolved.?);
}

test "package importは相対取り込み済みmoduleの名前を変えずloading中の循環辺を認識する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「other/index.nako3」を取り込む\n!「lib/index.nako3」を取り込む\n!「パッケージ:lib」を取り込む\nlib__値を表示。\n" },
        .{ .suffix = "other/index.nako3", .source = "値=20\n" },
        .{ .suffix = "lib/index.nako3", .source = "!「パッケージ:lib」を取り込む\n値=7\n" },
    } };
    var package_resolver = TestLocalPackageResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    const other_module = graph.modules[1];
    const local_module = graph.modules[2];
    try std.testing.expectEqualStrings("index", other_module.name);
    try std.testing.expectEqualStrings("index", local_module.name);
    try std.testing.expect(local_module.canonical_id == null);
    try std.testing.expectEqual(@as(usize, 1), local_module.imports.len);
    try std.testing.expect(local_module.imports[0].cyclic);
    try std.testing.expectEqual(@as(u32, local_module.index), local_module.imports[0].target.?);
    try std.testing.expectEqual(@as(u32, local_module.index), graph.modules[0].imports[2].target.?);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var resolved_local_alias = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "lib__値")) continue;
        const symbol_id = binding.symbol orelse continue;
        const symbol = program.symbols[symbol_id];
        if (std.mem.startsWith(u8, binding.resolved_name, "index__lnako_local_") and
            std.mem.endsWith(u8, binding.resolved_name, "__値") and symbol.module_index == local_module.index) resolved_local_alias = true;
    }
    try std.testing.expect(resolved_local_alias);
}

test "package import後の相対importはファイル名namespaceを維持する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「パッケージ:lib」を取り込む\n!「lib/index.nako3」を取り込む\nindex__値を表示。\n" },
        .{ .suffix = "lib/index.nako3", .source = "値=7\n" },
    } };
    var package_resolver = TestLocalPackageResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    const package_module = graph.modules[1];
    try std.testing.expectEqualStrings("lib", package_module.name);
    try std.testing.expectEqual(@as(usize, 2), graph.modules[0].imports.len);
    try std.testing.expectEqualStrings("lib", graph.modules[0].imports[0].namespace.?);
    try std.testing.expectEqualStrings("index", graph.modules[0].imports[1].namespace.?);
    try std.testing.expectEqual(@as(u32, package_module.index), graph.modules[0].imports[1].target.?);

    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var found_binding = false;
    for (program.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "index__値")) continue;
        const symbol_id = binding.symbol orelse continue;
        const symbol = program.symbols[symbol_id];
        found_binding = std.mem.eql(u8, binding.resolved_name, symbol.qualified_name) and
            std.mem.startsWith(u8, symbol.qualified_name, "package__") and symbol.module_index == package_module.index;
    }
    try std.testing.expect(found_binding);
}

test "合成されたlocal module名は自然なbasenameとも衝突しない" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「one/lib.nako3」を取り込む\n!「two/lib.nako3」を取り込む\n!「lib__lnako_local_1.nako3」を取り込む\n" },
        .{ .suffix = "one/lib.nako3", .source = "値=1\n" },
        .{ .suffix = "two/lib.nako3", .source = "値=2\n" },
        .{ .suffix = "lib__lnako_local_1.nako3", .source = "値=3\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    for (program.modules, 0..) |module, index| {
        for (program.modules[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, module.name, other.name));
        }
    }
}

test "同名index.nako3を持つ2 packageを別moduleとして同時取り込める" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「パッケージ:math」を取り込む\n!「パッケージ:geometry」を取り込む\n" },
        .{ .suffix = "packages/math/index.nako3", .source = "●MathValueとは\n  1で戻る\nここまで\n" },
        .{ .suffix = "packages/geometry/index.nako3", .source = "●GeometryValueとは\n  2で戻る\nここまで\n" },
    } };
    var package_resolver = PackageTestResolver{};
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .package_resolver = package_resolver.resolver() });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    try std.testing.expect(!std.mem.eql(u8, graph.modules[1].path, graph.modules[2].path));
    try std.testing.expect(pathHasSuffix(graph.modules[1].path, "packages/math/index.nako3"));
    try std.testing.expect(pathHasSuffix(graph.modules[2].path, "packages/geometry/index.nako3"));
    try std.testing.expectEqualStrings("math", graph.modules[1].name);
    try std.testing.expectEqualStrings("geometry", graph.modules[2].name);
    try std.testing.expectEqualStrings("pkg:math-id/main", graph.modules[1].canonical_id.?);
    try std.testing.expectEqualStrings("pkg:geometry-id/main", graph.modules[2].canonical_id.?);
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
}

fn checkInvalidModuleCleanup(allocator: std.mem.Allocator, imported: bool) !void {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「invalid.nako3」を取り込む\n!「invalid.nako3」を取り込む\n" },
        .{ .suffix = "invalid.nako3", .source = "\xff\xff\xff" },
    } };
    var graph = load(allocator, if (imported) "main.nako3" else "invalid.nako3", memory.sourceProvider(), .{}) catch |err| {
        if (err == error.InvalidUtf8 and !imported) return;
        return err;
    };
    defer graph.deinit();
    try std.testing.expect(imported);
    try std.testing.expect(!graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expect(graph.modules[1].parsed == null);
}

test "不正UTF8のentryと取り込み先を一度だけ解放する" {
    try checkInvalidModuleCleanup(std.testing.allocator, false);
    try checkInvalidModuleCleanup(std.testing.allocator, true);
}

test "モジュール読込み失敗の全割り当て境界で所有権を保持する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInvalidModuleCleanup, .{false});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkInvalidModuleCleanup, .{true});
}

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

test "JavaScriptの相対依存を再帰ロードする" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「plugin.mjs」を取り込む\n" },
        .{ .suffix = "plugin.mjs", .source = "import { value } from './helper.mjs'; export default { value };" },
        .{ .suffix = "helper.mjs", .source = "export const value = 1;" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .compat_js = true });
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 3), graph.modules.len);
    try std.testing.expectEqual(ModuleKind.javascript, graph.modules[1].kind);
    try std.testing.expectEqual(@as(usize, 1), graph.modules[1].imports.len);
    try std.testing.expectEqual(@as(?u32, 2), graph.modules[1].imports[0].target);
    try std.testing.expectEqualStrings("./helper.mjs", graph.modules[1].imports[0].requested);
}

test "ネイティブプラグインをソース読込なしで登録する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「plugin.so」を取り込む\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
    try std.testing.expectEqual(ModuleKind.native_plugin, graph.modules[1].kind);
    try std.testing.expectEqual(@as(usize, 0), graph.modules[1].source.len);
}

test "ネイティブプラグイン命令を厳格モードでも動的解決する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!厳しくチェック\n!「plugin.so」を取り込む\n外部追加()\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var found = false;
    for (program.bindings) |binding| if (binding.kind == .builtin and std.mem.eql(u8, binding.name, "外部追加")) {
        found = true;
    };
    try std.testing.expect(found);
}

test "ネイティブプラグインを取り込んでも厳格モードの未知変数を警告にする" {
    // 公式`!厳しくチェック`は未知変数を`logger.warn`で警告するだけで、
    // コンパイルと実行を継続する（終了0・`undefined`表示）。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!厳しくチェック\n!「plugin.so」を取り込む\n未知値を表示\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    var found = false;
    for (program.diagnostics) |item| if (item.code == .undefined_symbol) {
        try std.testing.expectEqual(@import("../frontend/diagnostic.zig").Severity.warning, item.severity);
        found = true;
    };
    try std.testing.expect(found);
}

test "ネイティブ化した公式JavaScriptプラグインは通常モードで取り込む" {
    const cases = [_][]const u8{
        "!「plugin_httpserver.mjs」を取り込む\n",
        "!「plugin_markup.js」を取り込む\n",
        "!「plugin_caniuse.mjs」を取り込む\n",
        "!「plugin_kansuji.js」を取り込む\n",
        "!「plugin_datetime.mjs」を取り込む\n",
    };
    for (cases) |source| {
        var memory = MemoryProvider{ .files = &.{.{ .suffix = "main.nako3", .source = source }} };
        var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
        defer graph.deinit();
        try std.testing.expect(graph.succeeded());
        try std.testing.expectEqual(@as(usize, 2), graph.modules.len);
        try std.testing.expectEqual(ModuleKind.javascript, graph.modules[1].kind);
        try std.testing.expectEqual(@as(usize, 0), graph.modules[1].source.len);
    }
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

test "関数内取り込みの展開で合成AST深さが上限を超えたら位置付き診断にする" {
    // `A=1+1+…`（2,044項）は単体では深さ2,046で受理されるが、関数内の
    // 取り込み位置へ展開すると合成深さが `parser.max_ast_depth` を超える。
    var lib_source: std.ArrayList(u8) = .empty;
    defer lib_source.deinit(std.testing.allocator);
    try lib_source.appendSlice(std.testing.allocator, "A=1");
    var index: usize = 0;
    while (index < 2043) : (index += 1) try lib_source.appendSlice(std.testing.allocator, "+1");
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "●(Aを)Fとは\n!「./lib.nako3」を取り込む\nAで戻る\nここまで\nF(1)を表示\n" },
        .{ .suffix = "lib.nako3", .source = lib_source.items },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    try std.testing.expect(graph.diagnostics.len >= 1);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, graph.diagnostics[0].code);
    // 診断は取り込み元ファイル内の関数内取り込み文（2行目）を指す。
    try std.testing.expect(std.mem.endsWith(u8, graph.diagnostics[0].file, "main.nako3"));
    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics[0].span.line);
}

test "関数内取り込みの展開連鎖で合成AST深さが上限を超えたら位置付き診断にする" {
    // main→mid→deep の取り込み連鎖。各ファイル単体は上限内だが、main側の
    // 関数内取り込み位置＋コピー内の取り込み文位置＋deepの深さの合計が
    // `parser.max_ast_depth` を超える。
    var deep_source: std.ArrayList(u8) = .empty;
    defer deep_source.deinit(std.testing.allocator);
    try deep_source.appendSlice(std.testing.allocator, "A=1");
    var index: usize = 0;
    while (index < 2042) : (index += 1) try deep_source.appendSlice(std.testing.allocator, "+1");
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "●(Aを)Fとは\n!「./mid.nako3」を取り込む\nBで戻る\nここまで\nF(1)を表示\n" },
        .{ .suffix = "mid.nako3", .source = "!「./deep.nako3」を取り込む\nB=2\n" },
        .{ .suffix = "deep.nako3", .source = deep_source.items },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(!graph.succeeded());
    try std.testing.expect(graph.diagnostics.len >= 1);
    try std.testing.expectEqual(diagnostic.Code.nesting_too_deep, graph.diagnostics[0].code);
    // 診断はコピー元モジュール（mid）側の取り込み文（1行目）を指す。
    try std.testing.expect(std.mem.endsWith(u8, graph.diagnostics[0].file, "mid.nako3"));
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics[0].span.line);
}

test ".dncl/.dncl2拡張子でDNCL系モードを強制する" {
    var memory = MemoryProvider{
        .files = &.{
            // .dncl は DNCLモード(v1)。「を実行し、そうでなければ」が動くことを確認する
            .{ .suffix = "main.dncl", .source = "A←3\nもしA=3ならば\n|「ok」と表示\nを実行し、そうでなければ\n|「ng」と表示\nを実行する\n" },
            .{ .suffix = "main.dncl2", .source = "B=0\nもし(not 真)ならば:\n　B=1\nそうでなければ:\n　B=2\n" },
            .{ .suffix = "plain.nako3", .source = "A←3\n" },
        },
    };
    var dncl_graph = try load(std.testing.allocator, "main.dncl", memory.sourceProvider(), .{});
    defer dncl_graph.deinit();
    try std.testing.expect(dncl_graph.succeeded());
    var dncl2_graph = try load(std.testing.allocator, "main.dncl2", memory.sourceProvider(), .{});
    defer dncl2_graph.deinit();
    try std.testing.expect(dncl2_graph.succeeded());
    var plain_graph = try load(std.testing.allocator, "plain.nako3", memory.sourceProvider(), .{});
    defer plain_graph.deinit();
    try std.testing.expect(!plain_graph.succeeded());
}

test "エントリ拡張子と反対側のDNCL強制フラグは競合エラーにする" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.dncl", .source = "A←3\n" },
        .{ .suffix = "main.dncl2", .source = "B=0\n" },
    } };
    // .dncl+--dncl2 / .dncl2+--dncl は両方言の同時有効化になるため拒否する
    try std.testing.expectError(error.ConflictingDnclModes, load(std.testing.allocator, "main.dncl", memory.sourceProvider(), .{ .forced_mode = .{ .dncl2 = true } }));
    try std.testing.expectError(error.ConflictingDnclModes, load(std.testing.allocator, "main.dncl2", memory.sourceProvider(), .{ .forced_mode = .{ .dncl = true } }));
    // 同方向の組合せ（拡張子と同じ方言のフラグ）は引き続き受理する
    var same = try load(std.testing.allocator, "main.dncl", memory.sourceProvider(), .{ .forced_mode = .{ .dncl = true } });
    defer same.deinit();
    try std.testing.expect(same.succeeded());
    // 拡張子がないエントリへの強制フラグも従来通り受理する
    var forced = MemoryProvider{ .files = &.{.{ .suffix = "main.nako3", .source = "A←3\n" }} };
    var forced_graph = try load(std.testing.allocator, "main.nako3", forced.sourceProvider(), .{ .forced_mode = .{ .dncl2 = true } });
    defer forced_graph.deinit();
    try std.testing.expect(forced_graph.succeeded());
}

fn variantCount(graph: *const ModuleGraph, path: []const u8) usize {
    for (graph.modules) |module| {
        if (std.mem.endsWith(u8, module.path, path)) return module.variants.items.len;
    }
    return 0;
}

test "循環取り込みの再展開は文脈のモードで別パースした変体を生成する" {
    // モードを含まない通常の循環取り込みはコピーの解析モードが本体と
    // 一致するため変体を作らず共有本体で再展開する
    var matching = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "「M1」と表示\n!「./lib.nako3」を取り込む\n「M2」と表示\n" },
        .{ .suffix = "lib.nako3", .source = "「L1」と表示\n!「./main.nako3」を取り込む\n「L2」と表示\n" },
    } };
    var matching_graph = try load(std.testing.allocator, "main.nako3", matching.sourceProvider(), .{});
    defer matching_graph.deinit();
    try std.testing.expect(matching_graph.succeeded());
    try std.testing.expectEqual(@as(usize, 0), variantCount(&matching_graph, "main.nako3"));

    // 強制モードが開始から有効なエントリ(.dncl)へ、そのモードの位置から
    // 循環取り込みされる場合もコピーと本体の解析モードが一致する
    var dncl = MemoryProvider{ .files = &.{
        .{ .suffix = "main.dncl", .source = "「M1」と表示\n!「./lib.nako3」を取り込む\n「M2」と表示\n" },
        .{ .suffix = "lib.nako3", .source = "「L1」と表示\n!「./main.dncl」を取り込む\n「L2」と表示\n" },
    } };
    var dncl_graph = try load(std.testing.allocator, "main.dncl", dncl.sourceProvider(), .{});
    defer dncl_graph.deinit();
    try std.testing.expect(dncl_graph.succeeded());
    try std.testing.expectEqual(@as(usize, 0), variantCount(&dncl_graph, "main.dncl"));

    // 循環位置より後でモードが有効になる場合、コピーには取り込み展開が
    // 含まれないためtailモードが欠けた解析になる。Issue #73 では共有
    // 本体の代わりに文脈のモードで解析した変体を生成して受理する。
    var mismatching = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "A=[10,20]\n「M1」と表示\n!「./lib.nako3」を取り込む\n「M3:」&A[1]と表示\n" },
        .{ .suffix = "lib.nako3", .source = "「L1」と表示\n!「./main.nako3」を取り込む\n!DNCLモード\n「L2」と表示\n" },
    } };
    var mismatching_graph = try load(std.testing.allocator, "main.nako3", mismatching.sourceProvider(), .{});
    defer mismatching_graph.deinit();
    try std.testing.expect(mismatching_graph.succeeded());
    try std.testing.expectEqual(@as(usize, 1), variantCount(&mismatching_graph, "main.nako3"));

    // 循環取り込み位置のモードがエントリの解析開始モードと異なる場合は
    // コピーの先行文の意味づけが変わる。これも文脈のモードで解析した
    // 変体で表現する（#73）。
    var diverging_initial = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "A=[10,20]\n「M1:」&A[0]と表示\nDNCLモード\n!「./lib.nako3」を取り込む\n「M3:」&A[1]と表示\n" },
        .{ .suffix = "lib.nako3", .source = "「L1」と表示\nDNCLモード\n!「./main.nako3」を取り込む\n「L2」と表示\n" },
    } };
    var diverging_graph = try load(std.testing.allocator, "main.nako3", diverging_initial.sourceProvider(), .{});
    defer diverging_graph.deinit();
    try std.testing.expect(diverging_graph.succeeded());
    try std.testing.expectEqual(@as(usize, 1), variantCount(&diverging_graph, "main.nako3"));
}

test "エントリの.nako3へ--dncl/--dncl2相当のモードを強制する" {
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "A←3\n" },
        .{ .suffix = "main2.nako3", .source = "B=0\nもし(not 真)ならば:\n　B=1\n" },
    } };
    var dncl_graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{ .forced_mode = .{ .dncl = true } });
    defer dncl_graph.deinit();
    try std.testing.expect(dncl_graph.succeeded());
    var dncl2_graph = try load(std.testing.allocator, "main2.nako3", memory.sourceProvider(), .{ .forced_mode = .{ .dncl2 = true } });
    defer dncl2_graph.deinit();
    try std.testing.expect(dncl2_graph.succeeded());
    // 強制モードはエントリのみで、取り込み先の.nako3へは波及しない
    var imported = MemoryProvider{ .files = &.{
        .{ .suffix = "entry.nako3", .source = "!「./lib.nako3」を取り込む\n" },
        .{ .suffix = "lib.nako3", .source = "A←3\n" },
    } };
    var imported_graph = try load(std.testing.allocator, "entry.nako3", imported.sourceProvider(), .{ .forced_mode = .{ .dncl = true } });
    defer imported_graph.deinit();
    try std.testing.expect(!imported_graph.succeeded());
}

test "『{非公開}』属性のモジュール変数を他モジュールの名前解決から隠す" {
    // 公式findVarはmodList検索で `isExport === false` のモジュール変数を
    // 除外する。`{公開}` と無属性は既定どおり公開される。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「lib.nako3」を取り込む\n秘密を表示\n公開値を表示\n既定値を表示\n" },
        .{ .suffix = "lib.nako3", .source = "変数 秘密{非公開}=1\n変数 公開値{公開}=2\n変数 既定値=3\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(!program.findSymbol("lib__秘密").?.is_export);
    try std.testing.expect(program.findSymbol("lib__公開値").?.is_export);
    try std.testing.expect(program.findSymbol("lib__既定値").?.is_export);

    var hidden_resolved = false;
    var public_resolved = false;
    var default_resolved = false;
    for (program.bindings) |binding| {
        if (binding.kind != .reference) continue;
        if (std.mem.eql(u8, binding.name, "秘密")) hidden_resolved = std.mem.eql(u8, binding.resolved_name, "main__秘密");
        if (std.mem.eql(u8, binding.name, "公開値")) public_resolved = std.mem.eql(u8, binding.resolved_name, "lib__公開値");
        if (std.mem.eql(u8, binding.name, "既定値")) default_resolved = std.mem.eql(u8, binding.resolved_name, "lib__既定値");
    }
    try std.testing.expect(hidden_resolved);
    try std.testing.expect(public_resolved);
    try std.testing.expect(default_resolved);
}

test "『!モジュール公開既定値』が取り込み先のモジュール変数の公開を決める" {
    // 公式yExportDefaultはモジュール単位の既定を作り、findVarのmodList検索が
    // `isExport===false` の変数を除外する。属性付きの宣言は常に優先する。
    var memory = MemoryProvider{ .files = &.{
        .{ .suffix = "main.nako3", .source = "!「lib.nako3」を取り込む\n秘密を表示\n公開値を表示\n一覧を表示\n" },
        .{ .suffix = "lib.nako3", .source = "!モジュール公開既定値=「非公開」\n変数 秘密=1\n変数 公開値{公開}=2\n変数 [一覧]=[7]\n" },
    } };
    var graph = try load(std.testing.allocator, "main.nako3", memory.sourceProvider(), .{});
    defer graph.deinit();
    try std.testing.expect(graph.succeeded());
    var program = try graph.analyze(std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.succeeded());
    try std.testing.expect(!program.findSymbol("lib__秘密").?.is_export);
    try std.testing.expect(program.findSymbol("lib__公開値").?.is_export);
    try std.testing.expect(!program.findSymbol("lib__一覧").?.is_export);
    for (program.bindings) |binding| {
        if (binding.kind != .reference) continue;
        if (std.mem.eql(u8, binding.name, "秘密")) try std.testing.expectEqualStrings("main__秘密", binding.resolved_name);
        if (std.mem.eql(u8, binding.name, "公開値")) try std.testing.expectEqualStrings("lib__公開値", binding.resolved_name);
        if (std.mem.eql(u8, binding.name, "一覧")) try std.testing.expectEqualStrings("main__一覧", binding.resolved_name);
    }
}
