//! `NAKO-PKG/commands.json` の静的生成。
//!
//! 公開 `.nako3` ソースを AST のみから走査し、公開トップレベル関数
//! （`{ name, args, josi }`）と公開変数（`{ name, variable: true }`）を
//! 収集する。取り込み文は文字列リテラルのみ静的に解決し、パッケージ内
//! `.nako3`/`.dncl`/`.dncl2` ソースの import 閉包を辿る。初期化コードは
//! 一切実行しない。JavaScript・ネイティブ plugin の取り込み先は索引対象外
//! （それらは関数定義を持たない別 artifact）。
//!
//! `fn`/`async`/`return` 相当の情報は静的に確定できないため出力しない
//! （SPECIFICATION §6.4）。

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const parser = @import("../frontend/parser.zig");
const token_mod = @import("../frontend/token.zig");
const diag = @import("diagnostics.zig");
const npkg_commands = @import("npkg_commands.zig");

const Allocator = std.mem.Allocator;
pub const Command = npkg_commands.Command;

/// ソース取得の抽象化。パッケージルート相対の posix path を受け取り、
/// 内容を返す。見つからない場合は null。返却メモリは `allocator` が所有する。
pub const SourceProvider = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, allocator: Allocator, path: []const u8) anyerror!?[]u8,

    pub fn read(self: SourceProvider, allocator: Allocator, path: []const u8) !?[]u8 {
        return self.readFn(self.context, allocator, path);
    }
};

/// 生成結果。全メモリは内蔵 arena が所有する。
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    commands: []Command,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// 拡張子で強制される構文モード（module_graph.extensionForcedMode と同一規則）。
fn extensionForcedMode(path: []const u8) token_mod.Mode {
    const extension = std.fs.path.extension(path);
    return .{
        .dncl = std.ascii.eqlIgnoreCase(extension, ".dncl"),
        .dncl2 = std.ascii.eqlIgnoreCase(extension, ".dncl2"),
    };
}

fn isNakoSource(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".nako3") or
        std.ascii.eqlIgnoreCase(extension, ".dncl") or
        std.ascii.eqlIgnoreCase(extension, ".dncl2");
}

/// `base`（取り込み元のパッケージ相対 path）から `rel`（取り込み指定）を
/// パッケージ相対の規範 path へ解決する。ルート外への脱出は null。
/// `allocator` への割当は呼出し側のメモリ管理に従う。
pub fn resolveImport(allocator: Allocator, base: []const u8, rel: []const u8) !?[]const u8 {
    // 絶対パス・バックスラッシュ・空成分を含む指定は package 相対の
    // 規範形式ではないため拒否する（絶対 import が importer 配下の別
    // ファイルへ誤変換されるのを防ぐ）。
    if (rel.len == 0 or rel[0] == '/' or rel[rel.len - 1] == '/') return null;
    if (std.mem.indexOfScalar(u8, rel, '\\') != null) return null;
    var segments: std.ArrayList([]const u8) = .empty;
    defer segments.deinit(allocator);
    // base のディレクトリ部を起点にする
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |slash| {
        var it = std.mem.splitScalar(u8, base[0..slash], '/');
        while (it.next()) |part| {
            if (part.len != 0) try segments.append(allocator, part);
        }
    }
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |part| {
        if (part.len == 0) return null;
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (segments.items.len == 0) return null;
            _ = segments.pop();
            continue;
        }
        try segments.append(allocator, part);
    }
    if (segments.items.len == 0) return null;
    return try std.mem.join(allocator, "/", segments.items);
}

/// 取り込み閉包走査の再帰上限。異常に深い連鎖でスタックを使い切らないための
/// 安全弁であり、通常のパッケージ構造では到達しない。
const max_import_depth = 256;

/// 命令索引化のために保持するソースの累計上限。各ファイルの AST・トークンは
/// 収集した name/args/josi が参照するため generate 完了まで解放できず、
/// 閉包が無制限に読み込むとメモリを使い切るため、ソース合計で束縛する。
const max_index_source_bytes = 64 * 1024 * 1024;

const Collector = struct {
    allocator: Allocator,
    provider: SourceProvider,
    diagnostics: *diag.List,
    visited: std.StringHashMapUnmanaged(void),
    commands: std.ArrayList(Command),
    command_names: std.StringHashMapUnmanaged(void),
    depth: usize = 0,
    source_bytes: usize = 0,

    fn report(self: *Collector, code: []const u8, path: []const u8, comptime format: []const u8, args: anytype) !void {
        try self.diagnostics.addFmt(code, .err, path, .{}, format, args);
    }

    /// パッケージ相対 path のソースを読み・解析して公開定義を収集する。
    fn process(self: *Collector, path: []const u8) anyerror!void {
        if (self.depth >= max_import_depth) {
            try self.report(diag.E029_INVALID_VALUE, path, "import chain exceeds depth limit {d}", .{max_import_depth});
            return;
        }
        const key = try self.allocator.dupe(u8, path);
        if ((try self.visited.getOrPut(self.allocator, key)).found_existing) {
            self.allocator.free(key);
            return;
        }
        const source = (try self.provider.read(self.allocator, path)) orelse {
            try self.report(diag.E036_NPKG_MISSING_ENTRY, path, "command index source \"{s}\" is not readable", .{path});
            return;
        };
        self.source_bytes += source.len;
        if (self.source_bytes > max_index_source_bytes) {
            try self.report(diag.E029_INVALID_VALUE, path, "command index sources exceed the total size limit {d} bytes", .{max_index_source_bytes});
            return;
        }

        // AST・トークン文字列はパース結果の arena に乗るが、それは Result の
        // arena を親に持つため、あえて deinit せず Result.deinit で一括解放する
        // （収集した name/args/josi が AST 文字列を参照するため）。
        const parsed = try parser.parseWithMode(self.allocator, source, path, .{ .forced = extensionForcedMode(path) });
        if (!parsed.succeeded()) {
            try self.report(diag.E029_INVALID_VALUE, path, "source \"{s}\" could not be parsed for command index", .{path});
            return;
        }
        const root = parsed.root orelse return;
        const statements = if (root.kind == .block) root.children else &.{root};
        for (statements) |node| try self.collect(node, path);
    }

    fn collect(self: *Collector, node: *ast.Node, path: []const u8) anyerror!void {
        switch (node.kind) {
            .function_definition => {
                if (node.is_export) {
                    var args: std.ArrayList([]const u8) = .empty;
                    var josi: std.ArrayList([]const u8) = .empty;
                    for (node.arguments) |argument| {
                        try args.append(self.allocator, argument.name);
                        try josi.append(self.allocator, argument.josi);
                    }
                    try self.addCommand(.{
                        .name = node.name,
                        .args = args.items,
                        .josi = josi.items,
                    });
                }
            },
            .variable_definition => {
                if (node.is_export) {
                    try self.addCommand(.{ .name = node.name, .variable = true });
                }
            },
            .variable_list_definition => {
                if (node.is_export) {
                    for (node.arguments) |argument| {
                        try self.addCommand(.{ .name = argument.name, .variable = true });
                    }
                }
            },
            .import => return self.followImport(node, path),
            else => {},
        }
        // 公開定義の収集はトップレベル文のみだが、取り込みは module_graph と
        // 同様に文の子孫まで辿る（条件分岐や関数内の静的取り込みも実行時の
        // 依存辺になるため、索引閉包から欠落させない）。
        try self.collectImports(node, path);
    }

    /// 文の子孫から `.import` ノードを再帰探索する。
    fn collectImports(self: *Collector, node: *ast.Node, path: []const u8) anyerror!void {
        for (node.children) |child| {
            if (child.kind == .import) {
                try self.followImport(child, path);
            } else {
                try self.collectImports(child, path);
            }
        }
    }

    fn followImport(self: *Collector, node: *ast.Node, path: []const u8) anyerror!void {
        // 動的な取り込み式（node.value が空）は静的に解決しない。
        if (node.value.len == 0) return;
        const resolved = (try resolveImport(self.allocator, path, node.value)) orelse {
            try self.report(diag.E039_NPKG_UNDISTRIBUTABLE_DEPENDENCY, path, "import \"{s}\" escapes the package root", .{node.value});
            return;
        };
        if (!isNakoSource(resolved)) return;
        self.depth += 1;
        defer self.depth -= 1;
        try self.process(resolved);
    }

    /// 同名命令は先勝ちで索引化する（index は識別子参照のため重複を持たない）。
    fn addCommand(self: *Collector, command: Command) !void {
        const result = try self.command_names.getOrPut(self.allocator, command.name);
        if (result.found_existing) return;
        try self.commands.append(self.allocator, command);
    }
};

/// `entry_paths`（パッケージ相対の公開ソース path 群）とその import 閉包から
/// 公開命令一覧を生成する。全メモリは返却 `Result` の arena が所有する。
/// 失敗時は diagnostics へ記録して `error.InvalidCommands` を返す。
pub fn generate(
    backing_allocator: Allocator,
    provider: SourceProvider,
    entry_paths: []const []const u8,
    diagnostics: *diag.List,
) !Result {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    var collector = Collector{
        .allocator = allocator,
        .provider = provider,
        .diagnostics = diagnostics,
        .visited = .empty,
        .commands = .empty,
        .command_names = .empty,
    };
    const prior_errors = diagnostics.errorCount();
    for (entry_paths) |path| try collector.process(path);
    if (diagnostics.errorCount() > prior_errors) return error.InvalidCommands;
    // 全割当が完了した後に arena を移す。
    return .{ .arena = arena, .commands = collector.commands.items };
}
