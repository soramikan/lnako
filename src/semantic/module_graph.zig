const std = @import("std");
const ast = @import("../frontend/ast.zig");
const diagnostic = @import("../frontend/diagnostic.zig");
const parser = @import("../frontend/parser.zig");
const token_mod = @import("../frontend/token.zig");
const analyzer = @import("analyzer.zig");
const dynamic_commands = @import("dynamic_commands.zig");
const js_scanner = @import("js_scanner.zig");
const effective = @import("module_graph_effective.zig");
const variants = @import("module_graph_variants.zig");
const builtin_catalog = @import("builtin_catalog.zig");

const graph_js = @import("module_graph_js.zig");
const graph_paths = @import("module_graph_paths.zig");
const graph_expansion = @import("module_graph_expansion.zig");
const graph_naming = @import("module_graph_naming.zig");

// 分割先の実装を同じ名前で参照できるようにする（呼出し側の意味は変えない）。
const JavaScriptScan = graph_js.JavaScriptScan;
const collectJavaScriptImports = graph_js.collectJavaScriptImports;
const normalizePath = graph_paths.normalizePath;
const isNativePluginExtension = graph_paths.isNativePluginExtension;
const isPackageSpecifier = graph_paths.isPackageSpecifier;
const ResolvedImport = graph_paths.ResolvedImport;
const resolveRequestedImport = graph_paths.resolveRequestedImport;
const pathWithinRoot = graph_paths.pathWithinRoot;
const moduleIsPackageContent = graph_paths.moduleIsPackageContent;
const descendantInheritance = graph_paths.descendantInheritance;
const resolveImport = graph_paths.resolveImport;
const ModeState = graph_expansion.ModeState;
pub const orMode = graph_expansion.orMode;
pub const modeEql = graph_expansion.modeEql;
const modeSubset = graph_expansion.modeSubset;
const buildExpansion = graph_expansion.buildExpansion;
const expandModule = graph_expansion.expandModule;
const effectiveImportTarget = graph_expansion.effectiveImportTarget;
const isNativeBuiltinPlugin = graph_expansion.isNativeBuiltinPlugin;
const collectImports = graph_expansion.collectImports;
const uniqueInternalModuleName = graph_naming.uniqueInternalModuleName;
pub const extensionForcedMode = graph_naming.extensionForcedMode;
const rangeFunctionExported = graph_naming.rangeFunctionExported;

pub const SourceProvider = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8,
    /// Optional: resolve `path` to its canonical (symlink-free) filesystem path.
    /// Real-filesystem providers should implement this so package containment
    /// checks cannot be bypassed by in-root symlinks. `null` result means the
    /// path could not be canonicalized and callers fall back to the lexical form.
    canonicalizeFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8 = null,

    pub fn read(self: SourceProvider, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.readFn(self.context, allocator, path);
    }

    pub fn canonicalize(self: SourceProvider, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
        const canonicalize_fn = self.canonicalizeFn orelse return null;
        return canonicalize_fn(self.context, allocator, path);
    }
};

const declared_types = @import("declared_commands.zig");
/// 環境 snapshot の宣言命令 metadata。analyzer が検査の正本として使う。
pub const DeclaredCommand = declared_types.DeclaredCommand;
pub const DeclaredCommands = declared_types.DeclaredCommands;
const PackageCommandAlias = declared_types.PackageCommandAlias;

/// `global` 入口の命令を無修飾名で解決するための alias。
/// runtime の登録名は loader が取り込み先 module の実効名から組み立てる
/// （source package は衝突回避後の公開 module 名、plugin は dispatch 名）。
pub const GlobalCommand = struct {
    name: []const u8,
};

/// PackageResolver returns all fields allocated from its supplied allocator;
/// the loader retains them in its graph arena.
pub const ResolvedPackageImport = struct {
    path: []u8,
    /// Stable package identity plus canonical export name; independent of disk path.
    canonical_id: []const u8,
    /// Public namespace from the source import alias, independent of canonical ID.
    namespace: []const u8,
    /// Runtime dispatch namespace used to register/lookup plugin commands.
    /// Null means "same as `namespace`". Package-scoped transitive imports are
    /// scope-qualified so the same alias in different dependency scopes gets a
    /// distinct dispatch key.
    dispatch_namespace: ?[]const u8 = null,
    /// Canonical real path of the package root. Relative descendants inside it
    /// keep the package's opaque ownership instead of becoming global modules.
    /// Null disables ownership propagation for that export.
    package_root: ?[]u8 = null,
    /// Environment package key that owns the resolved export. Carried
    /// explicitly because it cannot be recovered from `canonical_id` —
    /// export names may contain `/` (`pkg:x` export `api/v1` would be
    /// misattributed to `pkg:x/api` by trailing-slash parsing).
    package_owner: ?[]const u8 = null,
    /// Resolver が選んだ公開サブパス。入口別宣言索引の選択に使う。
    export_subpath: ?[]const u8 = null,
    /// `global` binding の入口が公開する命令。空は scoped のみ。
    /// 呼出し側 allocator 所有で、loader は graph arena に保持する。
    global_commands: []const GlobalCommand = &.{},
};

/// Lock/environment-backed package specifier resolver. The callback returns the
/// selected export path and public namespace; selection policy stays outside the
/// module graph so CLI, tests, and embedded callers share the same loader.
/// `importer_owner` is the environment package key that owns the importing
/// module (derived from the import edge, not the physical path); when present
/// the resolver must use that package's dependency scope rather than inferring
/// ownership from the importer path — two packages may legitimately share
/// nested roots, where path inference can pick the wrong owner.
pub const PackageResolver = struct {
    context: *anyopaque,
    resolveFn: *const fn (context: *anyopaque, allocator: std.mem.Allocator, importer: []const u8, importer_owner: ?[]const u8, specifier: []const u8) anyerror!ResolvedPackageImport,

    pub fn resolve(self: PackageResolver, allocator: std.mem.Allocator, importer: []const u8, importer_owner: ?[]const u8, specifier: []const u8) !ResolvedPackageImport {
        return self.resolveFn(self.context, allocator, importer, importer_owner, specifier);
    }
};

/// `environment.json` の宣言命令索引を package owner key で引く callback。
/// semantic 層は package 層へ依存しないため、schema の読み出しは package 側の
/// `command_inspect.DeclaredIndex` が行い、module graph は lifecycle だけを持つ。
pub const DeclaredCommandsProvider = struct {
    context: *anyopaque,
    /// package 単位の従来索引。入口解決では `exportLookupFn` を優先する。
    lookupFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, package_owner: []const u8) anyerror!?DeclaredCommands = null,
    /// 選択された入口の索引。返却スライスは `analyzeModules` 中有効。
    exportLookupFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, package_owner: []const u8, export_subpath: ?[]const u8) anyerror!?DeclaredCommands = null,

    pub fn lookup(self: DeclaredCommandsProvider, allocator: std.mem.Allocator, package_owner: []const u8) !?DeclaredCommands {
        const lookup_fn = self.lookupFn orelse return null;
        return lookup_fn(self.context, allocator, package_owner);
    }

    /// 入口別 provider があれば優先し、無い場合だけ package 単位へ戻る。
    pub fn lookupExport(self: DeclaredCommandsProvider, allocator: std.mem.Allocator, package_owner: []const u8, export_subpath: ?[]const u8) !?DeclaredCommands {
        if (self.exportLookupFn) |lookup_fn| return lookup_fn(self.context, allocator, package_owner, export_subpath);
        return self.lookup(allocator, package_owner);
    }
};

/// bare npm specifier（`import "left-pad"`）の解決結果。caller が allocator で
/// free する。実装は package 層（`npm_esm`）に置き、semantic はコールバックのみ。
pub const ResolvedNpmModule = struct {
    path: []u8,
    package_root: []u8,
};

/// package 所有 JS 内の bare specifier を npm instance 入口へ写す。
/// `importer_owner` は nako package key、`importer_package_root` は importer の
/// package root（npm 内相対 import 連鎖の context 復元に使う）。
pub const NpmModuleResolver = struct {
    context: *anyopaque,
    resolveFn: *const fn (
        context: *anyopaque,
        allocator: std.mem.Allocator,
        importer_owner: ?[]const u8,
        importer_package_root: ?[]const u8,
        specifier: []const u8,
    ) anyerror!ResolvedNpmModule,
    /// 解決失敗の instance 単位診断（1 行）。cache 欠落等の「どの name/
    /// version/cache key が欠けたか」を利用者に示す（#54）。未設定は
    /// 診断なし（呼出し側は汎用文言へ倒す）。返却文面は `allocator` 所有。
    failureDetailFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 = null,

    pub fn resolve(
        self: NpmModuleResolver,
        allocator: std.mem.Allocator,
        importer_owner: ?[]const u8,
        importer_package_root: ?[]const u8,
        specifier: []const u8,
    ) !ResolvedNpmModule {
        return self.resolveFn(self.context, allocator, importer_owner, importer_package_root, specifier);
    }

    /// 直近の解決失敗診断（1 行）。provider が公開していなければ null。
    pub fn failureDetail(self: NpmModuleResolver, allocator: std.mem.Allocator) !?[]u8 {
        const failure_detail_fn = self.failureDetailFn orelse return null;
        return failure_detail_fn(self.context, allocator);
    }
};

pub const FileProvider = struct {
    io: std.Io,
    max_bytes: usize = 128 * 1024 * 1024,

    pub fn sourceProvider(self: *FileProvider) SourceProvider {
        return .{ .context = self, .readFn = read, .canonicalizeFn = canonicalize };
    }

    fn read(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *FileProvider = @ptrCast(@alignCast(context));
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(self.max_bytes));
    }

    /// package root の境界検査に供する canonical path。symlink 先や `..` の
    /// 実体を解決できない場合は null を返し、呼出し側は lexical path で
    /// 継続する（読込み自体が失敗する経路は read 側の診断に委ねる）。
    fn canonicalize(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
        const self: *FileProvider = @ptrCast(@alignCast(context));
        const resolved = std.Io.Dir.cwd().realPathFileAlloc(self.io, path, allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        return resolved;
    }
};

pub const Options = struct {
    compat_js: bool = false,
    /// 同期済み環境に基づく `パッケージ:` / `pkg:` import resolver。
    package_resolver: ?PackageResolver = null,
    /// package 所有 JS の bare npm specifier 解決（未設定時は fail-closed）。
    npm_module_resolver: ?NpmModuleResolver = null,
    /// エントリモジュールへ強制する構文モード（--dncl / --dncl2）。
    forced_mode: token_mod.Mode = .{},
    /// package import 時に宣言命令索引を引く provider。未設定なら索引なし
    /// （= semantic は未検査として扱う）。
    declared_commands_provider: ?DeclaredCommandsProvider = null,
};

/// 取り込みの入れ子の上限。`loadOne`は取り込み先ごとに自己再帰するため、
/// 深い連鎖はプロセススタックを使い切ってSIGSEGVする。1ファイルのAST上限
/// （`parser.max_ast_depth`）と同じく、実用上あり得ない深さで位置付き診断に収束させる。
pub const max_import_depth: usize = 512;
pub const ModuleKind = enum { nako3, javascript, native_plugin };
pub const LoadState = enum { loading, loaded };

/// 生成時に `SourceProvider.canonicalize` が返した lexical→実体pathの対応。
/// 埋め込みpayloadへ保存し、FSを持たない起動時compileでも同じ境界検査と
/// module同一性を再現するために使う。
pub const PathAlias = struct {
    lexical: []const u8,
    canonical: []const u8,
};

pub const Import = struct {
    requested: []const u8,
    resolved_path: []const u8,
    canonical_id: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    /// Runtime dispatch namespace for plugin command registration. Null means
    /// "same as `namespace`".
    dispatch_namespace: ?[]const u8 = null,
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
    /// この取り込み辺で解決した入口の宣言索引。module を共有しても
    /// 辺ごとの入口宣言を混同しない。
    declared_commands: ?DeclaredCommands = null,
    /// この取り込み辺が `global` 入口なら、無修飾で解決する命令 alias。
    global_commands: []const GlobalCommand = &.{},
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
    /// Canonical real path of the owning package root, set for package exports
    /// and the relative descendants they keep inside that root.
    package_root: ?[]const u8 = null,
    /// Opaque identity of the owning package. Helper modules reached by relative
    /// imports inside the root share it so their symbols stay package-internal
    /// instead of leaking through global qualified-name resolution.
    package_owner: ?[]const u8 = null,
    /// この package export が属する package の宣言命令索引（環境 snapshot）。
    /// plugin を初期化せずに読める静的 metadata。
    declared_commands: ?DeclaredCommands = null,
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
    /// `analyze` で確定したモジュールごとのシンボル修飾namespace
    /// （`{namespace}__{name}` の prefix）。`modules` の index と揃える。
    /// package moduleでは公開実行時名と異なるため、エラー位置逆引き用に保持する。
    internal_module_names: []const []const u8 = &.{},
    /// 境界検査でcanonicalizeが実体pathへ解決したlexical pathの対応表。
    /// 埋め込みpayload生成がそのまま写し取る。
    canonical_aliases: []const PathAlias = &.{},

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

    pub fn analyze(self: *ModuleGraph, allocator: std.mem.Allocator) !analyzer.Program {
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
            const package_owned = moduleIsPackageContent(module);
            if (module.source_namespace != null or package_owned) {
                // Package-owned modules (canonical exports and their relative
                // descendants) use the public alias when present, otherwise the
                // file-stem name, only for the runtime module entry name. Their
                // internal symbol namespace always stays opaque so helper
                // module globals cannot be reached by a guessed qualified name.
                const public_name = module.source_namespace orelse module.name;
                var collision = false;
                for (self.modules) |candidate| {
                    if (candidate == module) continue;
                    const candidate_owned = moduleIsPackageContent(candidate);
                    if (!candidate_owned) {
                        if (std.mem.eql(u8, public_name, candidate.name)) {
                            collision = true;
                            break;
                        }
                        continue;
                    }
                    const candidate_public = candidate.source_namespace orelse candidate.name;
                    if (std.mem.eql(u8, public_name, candidate_public)) {
                        collision = true;
                        break;
                    }
                }
                runtime_module_names[module.index] = if (collision)
                    try uniqueInternalModuleName(temp, self.modules, runtime_module_names, internal_name_assigned, module.index, public_name, "pkg")
                else
                    public_name;
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
                    // package所有module（exportとその相対子孫）はopaqueな
                    // package namespace側で命名するため、local名の衝突対象に含めない。
                    if (candidate == module or moduleIsPackageContent(candidate)) continue;
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
            var allows_dynamic_commands_from: usize = std.math.maxInt(usize);
            var dynamic_command_aliases: std.ArrayList(analyzer.DynamicCommandAlias) = .empty;
            var global_command_aliases: std.ArrayList(analyzer.GlobalCommandAlias) = .empty;
            for (module.imports) |item| if (item.target) |target| {
                const target_module = self.modules[target];
                if (target_module.kind == .native_plugin or target_module.kind == .javascript) {
                    // package経由のplugin（native / --compat-jsのESM）はalias
                    // 修飾名のみを公開し、素の命令名は取り込みモジュールへ露出
                    // させない（package namespace契約）。直接path importは
                    // 従来どおり無修飾の動的命令を許可する。
                    if (item.canonical_id != null) {
                        if (item.namespace) |alias| {
                            var listed = false;
                            for (dynamic_command_aliases.items) |existing| {
                                if (!existing.unqualified and
                                    !existing.exact and
                                    std.mem.eql(u8, existing.source_namespace, alias))
                                {
                                    listed = true;
                                    break;
                                }
                            }
                            // package内scopeの依存aliasはimporter固有のdispatch
                            // namespaceへ写像し、別scopeの同名aliasと登録keyが
                            // 衝突しないようにする（`{owner}__{alias}` 修飾）。
                            // import_position はaliasを導入した取り込み文の位置 —
                            // それより前の `alias__命令` はimport未存在として
                            // 束縛しない（NamespaceAliasの位置規則と同じ）。
                            if (!listed) try dynamic_command_aliases.append(temp, .{
                                .source_namespace = alias,
                                .dispatch_namespace = item.dispatch_namespace orelse alias,
                                .import_position = item.span.start,
                            });
                        }
                    } else if (moduleIsPackageContent(module)) {
                        // package所有module内の相対path取り込みpluginは
                        // runtime登録と同じ `{owner}:{namespace}` へ隔離する。
                        // native pluginに加え、`--compat-js` のESM pluginも
                        // 同じowner修飾namespaceで登録される。修飾名
                        // `<filename>__命令` に加え、取り込み位置以降の無修飾
                        // 命令もその dispatch へ写像する（allows_dynamicの
                        // 恒等写像は使わない — 無修飾runtime登録はしない）。
                        if (item.namespace) |source_namespace| {
                            const dispatch = if (module.package_owner) |owner|
                                try std.fmt.allocPrint(temp, "{s}:{s}", .{ owner, source_namespace })
                            else
                                source_namespace;
                            var listed = false;
                            for (dynamic_command_aliases.items) |existing| {
                                if (!existing.unqualified and
                                    !existing.exact and
                                    std.mem.eql(u8, existing.source_namespace, source_namespace) and
                                    std.mem.eql(u8, existing.dispatch_namespace, dispatch))
                                {
                                    listed = true;
                                    break;
                                }
                            }
                            // 重複排除は prefix alias の登録だけに限る。別ディレクトリの同名
                            // plugin（`./one/plugin.mjs` と `./two/plugin.mjs`）は同じ
                            // dispatch namespace へ別の plugin オブジェクトを登録し得るため、
                            // 命令抽出と catch-all 判定は target ごとに必ず実行する。
                            if (!listed) try dynamic_command_aliases.append(temp, .{
                                .source_namespace = source_namespace,
                                .dispatch_namespace = dispatch,
                                .import_position = item.span.start,
                            });
                            // ESM pluginは公開命令を静的抽出して所有plugin単位の
                            // exact alias へ解決する。複数pluginを取り込んでも
                            // 後勝ちcatch-allで先発pluginの命令を誤配送しない。
                            const emit_catch_all = if (target_module.kind == .javascript)
                                !try dynamic_commands.appendJavaScriptPluginAliases(temp, &dynamic_command_aliases, target_module.source, dispatch, item.span.start)
                            else
                                true;
                            if (emit_catch_all) {
                                // 無修飾 catch-all: `外部追加` → `{owner}:{ns}__外部追加`
                                try dynamic_command_aliases.append(temp, .{
                                    .source_namespace = "",
                                    .dispatch_namespace = dispatch,
                                    .import_position = item.span.start,
                                    .unqualified = true,
                                });
                            }
                        }
                    } else {
                        // owner無し（プロジェクトroot側）moduleの直接path
                        // 取り込みは、native/ESM pluginとも無修飾名を実行時
                        // 登録するため、import位置以降の未知命令を動的builtin
                        // として許可する。
                        allows_dynamic_commands = true;
                        allows_dynamic_commands_from = @min(allows_dynamic_commands_from, item.span.start);
                    }
                }
                // `global` binding の入口は命令名を無修飾で解決する。
                // source package の関数は内部 namespace の実シンボルへ直接
                // 束縛する（runtime 登録名は内部 namespace で組み立てられる）。
                // plugin は従来どおり登録 dispatch 名へ exact alias で結び付ける。
                if (item.global_commands.len > 0) {
                    const source_target = item.target != null and target_module.kind == .nako3;
                    const dispatch_prefix = if (source_target)
                        internal_module_names[target]
                    else
                        item.dispatch_namespace orelse item.namespace orelse "";
                    for (item.global_commands) |global| {
                        if (source_target) {
                            const target_input = loader_to_input[target];
                            var listed = false;
                            for (global_command_aliases.items) |existing| {
                                if (existing.target_module == target_input and
                                    std.mem.eql(u8, existing.name, global.name) and
                                    std.mem.eql(u8, existing.internal_namespace, internal_module_names[target]))
                                {
                                    listed = true;
                                    break;
                                }
                            }
                            if (!listed) try global_command_aliases.append(temp, .{
                                .name = try temp.dupe(u8, global.name),
                                .internal_namespace = internal_module_names[target],
                                .target_module = target_input,
                                .import_position = item.span.start,
                            });
                        }
                        const dispatch_name = try std.fmt.allocPrint(temp, "{s}__{s}", .{ dispatch_prefix, global.name });
                        var listed = false;
                        for (dynamic_command_aliases.items) |existing| {
                            if (existing.exact and
                                std.mem.eql(u8, existing.source_namespace, global.name) and
                                std.mem.eql(u8, existing.dispatch_namespace, dispatch_name))
                            {
                                listed = true;
                                break;
                            }
                        }
                        if (!listed) try dynamic_command_aliases.append(temp, .{
                            .source_namespace = try temp.dupe(u8, global.name),
                            .dispatch_namespace = dispatch_name,
                            .import_position = item.span.start,
                            .exact = true,
                        });
                    }
                }
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
            // `pkg:` import の命令 alias。宣言索引は取り込み先 module が
            // 解決時に保持している（plugin は初期化しない）。
            var package_command_aliases: std.ArrayList(PackageCommandAlias) = .empty;
            for (module.imports) |item| {
                if (item.canonical_id == null) continue;
                const source_namespace = item.namespace orelse continue;
                // 読み込みに失敗した pkg: import は alias を登録しない。登録
                // すると全使用が「metadata 無しの未検査」として記録され、実体
                // のない解決失敗を未検査として見せてしまう。
                const target = item.target orelse continue;
                try package_command_aliases.append(temp, .{
                    .source_namespace = source_namespace,
                    .import_position = item.span.start,
                    .declared = item.declared_commands,
                    .target_module = if (self.modules[target].kind == .nako3) blk: {
                        std.debug.assert(target < loader_to_input.len);
                        break :blk loader_to_input[target];
                    } else std.math.maxInt(u32),
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
                    .import_position = item.span.start,
                    .is_explicit = item.canonical_id != null,
                };
                var already_added = false;
                for (namespace_aliases.items) |existing| {
                    if (!std.mem.eql(u8, existing.source_namespace, source_namespace)) continue;
                    // 同一 source namespace・同一 target・同一 explicit 性は
                    // 重複として落とす。異なる target / explicit 性は両方
                    // 残し、解決時に import_position と explicit 優先で選ぶ
                    // （package alias が相対由来 namespace を置換して位置規則
                    // を潰さない）。
                    if (existing.is_explicit == namespace_alias.is_explicit and
                        existing.target_module == namespace_alias.target_module)
                    {
                        already_added = true;
                        break;
                    }
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
                .allows_dynamic_commands_from = if (allows_dynamic_commands_from == std.math.maxInt(usize)) 0 else allows_dynamic_commands_from,
                .dynamic_command_aliases = try dynamic_command_aliases.toOwnedSlice(temp),
                .is_package = moduleIsPackageContent(module),
                .global_command_aliases = try global_command_aliases.toOwnedSlice(temp),
                .package_command_aliases = try package_command_aliases.toOwnedSlice(temp),
                .expands_in_function = module.expands_in_function,
                .owns_scoped_namespace_collision = owns_scoped_namespace_collision,
                .namespace_aliases = try namespace_aliases.toOwnedSlice(temp),
                .variants = try variant_inputs.toOwnedSlice(temp),
                .stmt_ranks = if (module.index < self.expansion.stmt_ranks.len) self.expansion.stmt_ranks[module.index] else &.{},
                .marker_rank = if (module.index < self.expansion.marker_ranks.len) self.expansion.marker_ranks[module.index] else std.math.maxInt(usize),
                .import_entries = try import_entries.toOwnedSlice(temp),
            });
        }
        const graph_allocator = self.arena.allocator();
        const persisted_names = try graph_allocator.alloc([]const u8, internal_module_names.len);
        for (internal_module_names, persisted_names) |name, *slot| slot.* = try graph_allocator.dupe(u8, name);
        self.internal_module_names = persisted_names;
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
    const entry = try loader.loadOne(normalized_entry, null, null, null, null, null, null, null);
    // 実効辺の決定とモード伝搬は全モジュール読み込み後に行う。
    // 公式のreplaceRequireStatementsは取り込み文を逆順に処理し、filePath単位の
    // include guardで最初に処理された辺だけへ内容を展開する（同一ファイルの
    // 複数取り込みでは最後の取り込み文に内容が載る）。
    try loader.markEffectiveEdges(entry);
    loader.has_exported_range_function = for (loader.modules.items) |module| {
        const parsed = module.parsed orelse continue;
        const root = parsed.root orelse continue;
        if (rangeFunctionExported(root) orelse false) break true;
    } else false;
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
        .canonical_aliases = loader.canonical_aliases.items,
    };
}

pub const Loader = struct {
    backing_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    provider: SourceProvider,
    options: Options,
    modules: std.ArrayList(*LoadedModule) = .empty,
    canonical_aliases: std.ArrayList(PathAlias) = .empty,
    diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty,
    /// `loadOne`の現在の再帰の深さ。取り込み1件ごとに1増える。
    /// 上限を超えた入力はプロセススタックを使い切る前に位置付き診断にする。
    load_depth: usize = 0,
    has_exported_range_function: bool = false,

    fn deinitModules(self: *Loader) void {
        for (self.modules.items) |module| {
            if (module.parsed) |*parsed| parsed.deinit();
            for (module.variants.items) |*variant| variant.parse.deinit();
            self.backing_allocator.free(module.source);
            self.backing_allocator.destroy(module);
        }
    }

    /// Package context a resolved import edge carries into the loaded module.
    /// For canonical exports `root` comes from the resolver; for relative
    /// descendants both fields propagate from the importing package module.
    pub const PackageInheritance = struct {
        root: ?[]const u8 = null,
        owner: ?[]const u8 = null,
    };

    /// `initial` は取り込み文位置で有効だったパーサモード（取り込み元からの継承）。
    /// 字句変換には波及せず、添字・自動初期化の意味づけのみに効く。
    /// `import_origin` は取り込み文を持つファイル（取り込み元）。診断の`file`を
    /// `import_node`の`span`と同じファイルに揃えるために使う。
    fn loadOne(self: *Loader, path: []const u8, import_node: ?*ast.Node, import_origin: ?[]const u8, initial: ?token_mod.Mode, namespace_override: ?[]const u8, canonical_id: ?[]const u8, inheritance: ?PackageInheritance, declared_commands: ?DeclaredCommands) anyerror!u32 {
        // 取り込みは`loadOne`の自己再帰で読むため、深い連鎖はプロセススタックを
        // 使い切る。解析前に位置付き診断へ収束させる（`max_ast_depth`と同じ方針）。
        if (self.load_depth >= max_import_depth) {
            try self.importDiagnostic(import_node, import_origin orelse path, "取り込みの入れ子が深すぎます");
            return error.ImportDepthExceeded;
        }
        self.load_depth += 1;
        defer self.load_depth -= 1;
        // owner は import edge が resolver から受け取った独立フィールドを使う。
        // canonical_id 末尾の `/` から逆算すると `api/v1` のような export 名で
        // `pkg:x/api` を誤った owner にしてしまうため、名前からの復元はしない。
        const package_owner: ?[]const u8 = if (inheritance) |inherited| inherited.owner else null;
        const package_root: ?[]const u8 = if (inheritance) |inherited| inherited.root else null;
        // module の共有は (path, owner) が一致する場合に限る。owner が異なる
        // module を共有すると、その module が既に解決済みの `pkg:` 依存edgeが
        // 別scopeのまま残り、import順序で依存解決結果が変わってしまう。
        // 同一ownerの別exportが同じ実体fileを指す場合は共有し、plugin評価や
        // グローバル初期化の多重化を防ぐ。
        if (canonical_id) |id| {
            if (self.findCanonical(id)) |existing| return existing;
            if (self.findOwnedPath(path, inheritance)) |existing| return existing;
        } else if (self.findOwnedPath(path, inheritance)) |existing| {
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
            .package_root = if (package_root) |root| try self.allocator.dupe(u8, root) else null,
            .package_owner = if (package_owner) |owner| try self.allocator.dupe(u8, owner) else null,
            .declared_commands = declared_commands,
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
            const scan = try collectJavaScriptImports(self.allocator, source);
            // escape列を含むspecifierは復号しないと実pathが定まらず、収集を
            // 諦めると実行時のFS fallbackが未検査のpathを読み得る。所有の
            // 有無に関わらず診断する（nested loadのerror黙殺で graph が
            // 診断なしの成功にならないようにする）。
            if (scan.has_unsupported_escape) {
                try self.importDiagnostic(import_node, path, "JavaScriptの取り込み指定にescape列は使えません");
            }
            // package所有moduleで静的に解決できない取り込み指定は、QuickJS側
            // loaderのFS fallbackがpackage root外を読み得るため明示的に拒否
            // する。判定は moduleIsPackageContent — owner/canonical_idのみを
            // 持つmodule（旧payload等）もroot無しで境界検査を迂回させない。
            // 非package module（直接path import）はユーザー自身のfileへの
            // 解決として従来挙動を維持する。
            if (scan.has_opaque_dynamic and moduleIsPackageContent(module)) {
                try self.importDiagnostic(import_node, path, "package内のJavaScriptでは静的に解決できない取り込み指定は使えません");
            }
            for (scan.imports) |requested| {
                // bare specifier（`import "foo"`）は相対 path ではない。package
                // 所有 module では npm_module_resolver で lock 済み instance へ
                // 写し、未設定・未解決は fail-closed（FS fallback で root 外を
                // 読ませない）。直接 path import のユーザー module は従来どおり
                // 収集しない。
                if (!std.fs.path.isAbsolute(requested) and !std.mem.startsWith(u8, requested, ".")) {
                    if (!moduleIsPackageContent(module)) continue;
                    const npm_resolver = self.options.npm_module_resolver orelse {
                        try self.importDiagnostic(import_node, path, "package内のJavaScriptでは静的に解決できない取り込み指定は使えません");
                        continue;
                    };
                    const npm = npm_resolver.resolve(self.allocator, module.package_owner, module.package_root, requested) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        // cache 欠落等の instance 単位失敗は「どの instance が
                        // 欠けたか」を 1 行で示す（#54）。resolver が診断文面
                        // を公開していなければ従来の汎用文言へ倒す。
                        if (self.npmFailureDetail(import_node, path)) continue;
                        try self.importDiagnostic(import_node, path, "package内のJavaScriptでは静的に解決できない取り込み指定は使えません");
                        continue;
                    };
                    defer self.allocator.free(npm.path);
                    defer self.allocator.free(npm.package_root);
                    const npm_ext = std.fs.path.extension(npm.path);
                    if (!std.ascii.eqlIgnoreCase(npm_ext, ".js") and !std.ascii.eqlIgnoreCase(npm_ext, ".mjs")) {
                        try self.importDiagnostic(import_node, path, "package内のJavaScriptでは静的に解決できない取り込み指定は使えません");
                        continue;
                    }
                    // npm library は plugin ではない。owner は package_root を
                    // instance 単位の identity とし、同一 instance の多重初期化を防ぐ。
                    const bare_inheritance: PackageInheritance = .{
                        .root = npm.package_root,
                        .owner = npm.package_root,
                    };
                    const npm_target_path = try containmentTarget(self, npm.path);
                    if (!pathWithinRoot(npm.package_root, npm_target_path)) {
                        try self.importDiagnostic(import_node, path, "package内の取り込み先がpackage rootの外です");
                        continue;
                    }
                    const bare_existing = self.findOwnedPath(npm_target_path, bare_inheritance);
                    var bare_target: ?u32 = bare_existing;
                    var bare_cyclic = false;
                    if (bare_existing) |index| {
                        bare_cyclic = self.modules.items[index].state == .loading;
                    } else {
                        bare_target = self.loadOne(npm_target_path, import_node, module.path, null, null, null, bare_inheritance, null) catch |err| switch (err) {
                            error.OutOfMemory => return err,
                            else => null,
                        };
                    }
                    try imports.append(self.allocator, .{
                        .requested = try self.allocator.dupe(u8, requested),
                        .resolved_path = try self.allocator.dupe(u8, npm_target_path),
                        .target = bare_target,
                        .cyclic = bare_cyclic,
                        .span = ast.emptySpan(),
                    });
                    continue;
                }
                const resolved = resolveImport(self.allocator, path, requested) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    try self.importDiagnostic(import_node, path, "JavaScriptの相対取り込みパスが不正です");
                    continue;
                };
                const imported_extension = std.fs.path.extension(resolved);
                if (!std.ascii.eqlIgnoreCase(imported_extension, ".js") and !std.ascii.eqlIgnoreCase(imported_extension, ".mjs")) continue;
                const target_path = if (module.package_root != null) try containmentTarget(self, resolved) else resolved;
                if (module.package_root != null and !pathWithinRoot(module.package_root.?, target_path)) {
                    try self.importDiagnostic(import_node, path, "package内の取り込み先がpackage rootの外です");
                    continue;
                }
                const descendant_inheritance = descendantInheritance(module, target_path);
                const existing = self.findOwnedPath(target_path, descendant_inheritance);
                var target: ?u32 = existing;
                var cyclic = false;
                if (existing) |index| {
                    cyclic = self.modules.items[index].state == .loading;
                } else {
                    target = self.loadOne(target_path, import_node, module.path, null, null, null, descendant_inheritance, null) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => null,
                    };
                }
                try imports.append(self.allocator, .{
                    .requested = try self.allocator.dupe(u8, requested),
                    .resolved_path = target_path,
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
                const resolved_import = resolveRequestedImport(self.allocator, path, module.package_owner, node.value, self.options.package_resolver) catch |err| {
                    if (err == error.OutOfMemory) return err;
                    const message = if (err == error.GlobalCommandsNotAllowed)
                        "global 命令の許可がありません（宣言元の依存に allow_global_commands = true を指定してください）"
                    else if (isPackageSpecifier(node.value))
                        "パッケージ参照を解決できません（同期済み環境・公開export・aliasを確認してください）"
                    else
                        "相対取り込みパスが不正です";
                    try self.importDiagnostic(node, path, message);
                    continue;
                };
                defer if (resolved_import.package_root) |resolved_package_root| self.allocator.free(resolved_package_root);
                defer if (resolved_import.package_owner) |resolved_owner| self.allocator.free(resolved_owner);
                // package所有moduleからの相対・絶対取り込みがcanonical rootの外へ
                // 逃げる場合は辺を作らない。prebuilt commands.jsonはsource走査を
                // 迂回するため、依存解決を経ない境界外参照を許すと宣言なしで
                // 別packageの非公開fileを読み込めてしまう。
                // 比較はcanonical pathで行う。`./link/x.nako3` のような in-root
                // symlink 経由は lexical では root 内に見えるが、実体は外部を
                // 指し得るため、canonicalize した実 path で境界を検証する。
                const resolved_target = if (module.package_root != null and resolved_import.canonical_id == null)
                    try containmentTarget(self, resolved_import.path)
                else
                    resolved_import.path;
                if (module.package_root != null and resolved_import.canonical_id == null and
                    !pathWithinRoot(module.package_root.?, resolved_target))
                {
                    try self.importDiagnostic(node, path, "package内の取り込み先がpackage rootの外です");
                    continue;
                }
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
                const edge_inheritance: ?PackageInheritance = if (resolved_import.canonical_id != null)
                    .{ .root = resolved_import.package_root, .owner = resolved_import.package_owner }
                else
                    descendantInheritance(module, resolved_target);
                const existing = self.findImport(resolved_target, resolved_import.canonical_id, edge_inheritance);
                const resolved_declared = if (resolved_import.canonical_id != null)
                    try self.declaredCommandsFor(resolved_import)
                else
                    null;
                var target: ?u32 = existing;
                var cyclic = false;
                if (existing) |index| {
                    cyclic = self.modules.items[index].state == .loading;
                    // 相対 import で先に読み込まれた既存 module を canonical
                    // export として再利用する場合も宣言索引を設定する。
                    if (resolved_declared) |declared| {
                        if (self.modules.items[index].declared_commands == null) {
                            self.modules.items[index].declared_commands = declared;
                        }
                    }
                } else {
                    target = self.loadOne(resolved_target, node, module.path, site_mode, resolved_import.namespace, resolved_import.canonical_id, edge_inheritance, resolved_declared) catch |err| switch (err) {
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
                    .resolved_path = resolved_target,
                    .canonical_id = resolved_import.canonical_id,
                    .namespace = resolved_import.namespace orelse try analyzer.moduleName(self.allocator, resolved_target),
                    .dispatch_namespace = resolved_import.dispatch_namespace,
                    .target = target,
                    .span = node.span,
                    .cyclic = cyclic,
                    .declared_commands = resolved_declared,
                    .global_commands = resolved_import.global_commands,
                });
            }
            module.imports = try imports.toOwnedSlice(self.allocator);
        }
        module.state = .loaded;
        return module.index;
    }

    /// 選択された入口の宣言命令索引を provider から引く。
    /// provider 未設定・非 package 取り込みは null（= 未検査）。
    fn declaredCommandsFor(self: *Loader, resolved: ResolvedImport) !?DeclaredCommands {
        const provider = self.options.declared_commands_provider orelse return null;
        const owner = resolved.package_owner orelse return null;
        return provider.lookupExport(self.allocator, owner, resolved.export_subpath);
    }

    /// 公式のreplaceRequireStatements相当の実効辺決定は`module_graph_effective.zig`へ
    /// 分離している（Loaderの状態を共有するためpubで公開する）。
    fn markEffectiveEdges(self: *Loader, entry: u32) !void {
        try effective.markEffectiveEdges(self, entry);
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
        const initial_changed = !modeEql(module.parse_initial, initial);
        if (initial_changed) {
            const reparsed = parser.parseWithMode(self.backing_allocator, module.source, module.path, .{
                .forced = module.forced_mode,
                .initial = initial,
                .builtin_commands = &builtin_catalog.function_names,
                .has_exported_range_function = self.has_exported_range_function,
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
        // 取り込み先の公開関数は読み込み後に判明する。宣言位置に依存せず
        // 解決されるため、取り込み文のない側のモジュールにも適用する。
        if (tail_modes.items.len > 0 or (self.has_exported_range_function and !initial_changed)) {
            const reparsed = parser.parseWithMode(self.backing_allocator, module.source, module.path, .{
                .forced = module.forced_mode,
                .initial = initial,
                .tail_modes = tail_modes.items,
                .builtin_commands = &builtin_catalog.function_names,
                .has_exported_range_function = self.has_exported_range_function,
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

    /// 同じ所有scopeに属し、同じ実体pathを指すmoduleを探す。scope keyは
    /// owner（package key）を優先し、owner未設定ならpackage rootを使う。
    /// local scope（root/owner共に無し）はroot/ownerを持たないmoduleのみに
    /// 一致する — package内moduleをlocal importが共有すると、読み込み順序で
    /// module所有が変わってしまうため。
    fn findOwnedPath(self: *Loader, path: []const u8, inheritance: ?PackageInheritance) ?u32 {
        const owner: ?[]const u8 = if (inheritance) |inherited| inherited.owner else null;
        const root: ?[]const u8 = if (inheritance) |inherited| inherited.root else null;
        for (self.modules.items) |module| {
            if (!std.mem.eql(u8, module.path, path)) continue;
            if (owner) |expected| {
                if (module.package_owner != null and
                    std.mem.eql(u8, module.package_owner.?, expected)) return module.index;
                continue;
            }
            if (module.package_owner != null) continue;
            if (root) |expected_root| {
                if (module.package_root != null and
                    std.mem.eql(u8, module.package_root.?, expected_root)) return module.index;
                continue;
            }
            if (module.package_root == null) return module.index;
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

    fn findImport(self: *Loader, path: []const u8, canonical_id: ?[]const u8, inheritance: ?PackageInheritance) ?u32 {
        if (canonical_id) |id| {
            return self.findCanonical(id) orelse self.findOwnedPath(path, inheritance);
        }
        return self.findOwnedPath(path, inheritance);
    }

    fn importDiagnostic(self: *Loader, node: ?*ast.Node, file: []const u8, message: []const u8) !void {
        try self.importDiagnosticAt(if (node) |value| value.span else null, file, message);
    }

    /// npm resolver が公開する直近の instance 単位失敗診断を位置付きで記録
    /// する。診断文面が無い（resolver が公開していない・instance 単位の失敗
    /// でない）場合は false を返し、呼出し側が汎用文言へ倒す。
    fn npmFailureDetail(self: *Loader, import_node: ?*ast.Node, path: []const u8) bool {
        const npm_resolver = self.options.npm_module_resolver orelse return false;
        const detail = npm_resolver.failureDetail(self.allocator) catch return false;
        const message = detail orelse return false;
        // 診断は message のスライスをそのまま保持する（`importDiagnosticAt` は
        // dupe しない）ため、ここでは解放しない。Loader の arena が寿命を持つ。
        self.importDiagnostic(import_node, path, message) catch {};
        return true;
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

const JavaScriptTokenKind = js_scanner.JavaScriptTokenKind;
const JavaScriptToken = js_scanner.JavaScriptToken;
const JavaScriptScanner = js_scanner.JavaScriptScanner;

/// package 境界検査用の比較対象 path。provider が canonicalize を供給する
/// 環境（実 FS）では in-root symlink が指す実体まで解決してから
/// `pathWithinRoot` と組み合わせる。解決不能（欠落・無い provider 等）なら
/// lexical path を返し、以降の read で個別診断される挙動を維持する。
/// 実体pathと異なるlexical pathはaliasとして記録し、埋め込み実行payloadが
/// 生成時と同じcanonicalizationをFSなしで再現できるようにする。
fn containmentTarget(self: *Loader, lexical: []const u8) ![]const u8 {
    const canonical = self.provider.canonicalize(self.allocator, lexical) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return lexical,
    };
    if (canonical) |resolved| {
        if (!std.mem.eql(u8, resolved, lexical)) {
            var listed = false;
            for (self.canonical_aliases.items) |alias| {
                if (std.mem.eql(u8, alias.lexical, lexical)) {
                    listed = true;
                    break;
                }
            }
            if (!listed) try self.canonical_aliases.append(self.allocator, .{
                .lexical = try self.allocator.dupe(u8, lexical),
                .canonical = resolved,
            });
            return resolved;
        }
    }
    return lexical;
}

test {
    _ = @import("module_graph_test.zig");
}
