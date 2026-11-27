//! パッケージ仕様 v1 §6.1（省略名と命令スコープ）のインポート表。
//!
//! 表は「依存元のパッケージが直接宣言した依存」だけで作る。宣言ごとの
//! `alias`、`allow_global_commands`、公開 `exports` をそのまま保持し、
//! 実際の import 指定を解決する時点で曖昧性を検査する。
//!
//! - ローカル名は明示 `alias`、省略時は Package ID の `name` 部分。
//! - 同じローカル名に複数の直接依存が対応していれば `AmbiguousImport`。
//! - `@scope/name` の完全修飾指定は、その依存元の直接依存に限り解決する。
//! - `pkg/subpath` / `@scope/pkg/subpath` の公開サブパスは、宣言された
//!   `exports` のキーと完全一致した場合だけ解決する。推測補完はしない。
//! - 依存元ごとに別の `Table` を作る。別パッケージの alias や許可は継承しない。
//!
//! `Table` は入力スライスを借用し、アロケーションを行わない。

const std = @import("std");
const types = @import("v1_types.zig");

pub const ImportError = error{
    EmptyImport,
    InvalidImportSpec,
    UnknownImport,
    AmbiguousImport,
    UndeclaredSubpath,
};

/// 公開サブパスと、その入口の命令スコープ。
pub const ExportEntry = struct {
    /// `"."` または `"./client"` 形式。仕様 §2 の `exports` キー。
    subpath: []const u8 = ".",
    /// 省略時は `scoped`（§2 MUST）。
    binding: types.Binding = .scoped,
};

/// 依存元パッケージが宣言した直接依存一件。
///
/// `exports` は依存先パッケージの公開 `exports` を渡す。空の場合は仕様の
/// 既定入口 `"."`（scoped）だけを持つものとして扱う。明示 `exports` に
/// `"."` がなければ既定入口は存在しない。
///
/// `alias` はサブパス区切り `"/"` を含まない名前に限る。`/` を含む alias は
/// ローカル指定とサブパスの区別が付かないため、この表ではローカル解決に
/// 使わない（完全修飾 ID では到達できる）。
pub const Declaration = struct {
    id: []const u8,
    alias: ?[]const u8 = null,
    allow_global_commands: bool = false,
    exports: []const ExportEntry = &.{},

    /// `types.Dependency` から、alias と global 許可を落とさずに写す。
    pub fn fromDependency(dependency: types.Dependency, exports: []const ExportEntry) Declaration {
        return .{
            .id = dependency.id,
            .alias = dependency.alias,
            .allow_global_commands = dependency.allow_global_commands,
            .exports = exports,
        };
    }

    /// ローカル解決名。明示 alias がなければ ID の name 部分。
    pub fn localName(self: Declaration) ?[]const u8 {
        if (self.alias) |alias| {
            if (alias.len != 0) return alias;
        }
        return idName(self.id);
    }
};

/// 依存元一つの直接依存表。
///
/// `owner` は診断・登録側が依存元を識別するための値で、`null` はルートを
/// 表す。別の依存元の宣言を混ぜてはならない（alias 非継承、§6.1 MUST NOT）。
pub const Table = struct {
    owner: ?[]const u8 = null,
    declarations: []const Declaration = &.{},

    pub fn init(owner: ?[]const u8, declarations: []const Declaration) Table {
        return .{ .owner = owner, .declarations = declarations };
    }

    /// 実際の import 指定を解決する。
    ///
    /// 受け付ける指定:
    /// - `name` / `name/sub/path`（alias または ID の name 部分）
    /// - `@scope/name` / `@scope/name/sub/path`（完全修飾 ID）
    ///
    /// サブパスは `"/"` 区切りの相対セグメントだけを受け付け、`.`、`..`、
    /// 空セグメント、バックスラッシュを拒否する。宣言済み `exports` の
    /// `"./..."` キーと完全一致したものだけを返す。
    pub fn resolve(self: Table, spec: []const u8) ImportError!Resolved {
        const parsed = try parseImportSpec(spec);
        const declaration_index = if (parsed.qualified)
            try self.findQualified(parsed.base)
        else
            try self.findLocal(parsed.base);

        const declaration = self.declarations[declaration_index];
        const export_entry = try selectExport(declaration, parsed.subpath);
        const local_name = declaration.localName() orelse return error.InvalidImportSpec;

        return .{
            .owner = self.owner,
            .declaration_index = declaration_index,
            .id = declaration.id,
            .alias = declaration.alias,
            .local_name = local_name,
            .subpath = export_entry.subpath,
            .binding = export_entry.binding,
            .allow_global_commands = declaration.allow_global_commands,
        };
    }

    /// 完全修飾 ID の直接依存を一件だけ返す。重複していれば曖昧として拒否する。
    /// ルート側の global 同意（同じ提供元を直接宣言して許可しているか）の
    /// 検査に使える。
    pub fn direct(self: Table, id: []const u8) ImportError!*const Declaration {
        const index = try self.findQualified(id);
        return &self.declarations[index];
    }

    /// `id` を直接宣言していて、かつ `allow_global_commands = true` か。
    /// 重複宣言は曖昧として false。
    pub fn allowsGlobalCommands(self: Table, id: []const u8) bool {
        const declaration = self.direct(id) catch return false;
        return declaration.allow_global_commands;
    }

    fn findQualified(self: Table, id: []const u8) ImportError!usize {
        var found: ?usize = null;
        for (self.declarations, 0..) |declaration, index| {
            if (!std.mem.eql(u8, declaration.id, id)) continue;
            if (found != null) return error.AmbiguousImport;
            found = index;
        }
        return found orelse error.UnknownImport;
    }

    fn findLocal(self: Table, name: []const u8) ImportError!usize {
        var found: ?usize = null;
        for (self.declarations, 0..) |declaration, index| {
            const local_name = declaration.localName() orelse continue;
            if (!std.mem.eql(u8, local_name, name)) continue;
            if (found != null) return error.AmbiguousImport;
            found = index;
        }
        return found orelse error.UnknownImport;
    }
};

/// 解決結果。`owner` と各スライスは `Table` の入力を借用する。
///
/// `binding` と `allow_global_commands` は宣言元の事実をそのまま返す。
/// `binding = .global` の命令を登録するには、これに加えてルートが同じ
/// 提供元を直接依存に宣言して `allow_global_commands = true` を明示する
/// 必要がある（§6.1 MUST）。その最終判定と登録は呼び出し側（P10・統合）
/// の責務で、この表は事実の保持までを行う。`owner` をキーに依存元ごとの
/// 表を引き直せるよう、別スコープの表を混ぜない。
pub const Resolved = struct {
    owner: ?[]const u8,
    declaration_index: usize,
    id: []const u8,
    alias: ?[]const u8,
    local_name: []const u8,
    subpath: []const u8,
    binding: types.Binding,
    allow_global_commands: bool,
};

const ParsedSpec = struct {
    base: []const u8,
    subpath: []const u8,
    qualified: bool,
};

fn parseImportSpec(spec: []const u8) ImportError!ParsedSpec {
    if (spec.len == 0) return error.EmptyImport;
    if (std.mem.indexOfScalar(u8, spec, '\\') != null) return error.InvalidImportSpec;

    if (spec[0] == '@') return parseQualifiedSpec(spec);

    const slash = std.mem.indexOfScalar(u8, spec, '/');
    const base = if (slash) |position| spec[0..position] else spec;
    const subpath = if (slash) |position| spec[position + 1 ..] else "";
    if (base.len == 0) return error.InvalidImportSpec;
    // ローカル名に `@` は使わない。完全修飾の取り違えを推測しない。
    if (std.mem.indexOfScalar(u8, base, '@') != null) return error.InvalidImportSpec;
    if (slash != null and subpath.len == 0) return error.InvalidImportSpec;
    try validateSubpath(subpath);
    return .{ .base = base, .subpath = subpath, .qualified = false };
}

fn parseQualifiedSpec(spec: []const u8) ImportError!ParsedSpec {
    const first_slash = std.mem.indexOfScalar(u8, spec, '/') orelse return error.InvalidImportSpec;
    if (first_slash <= 1) return error.InvalidImportSpec;

    const after_scope = spec[first_slash + 1 ..];
    const second_slash_relative = std.mem.indexOfScalar(u8, after_scope, '/');
    const base_end = if (second_slash_relative) |relative| first_slash + 1 + relative else spec.len;
    const base = spec[0..base_end];
    if (base.len <= first_slash + 1) return error.InvalidImportSpec;
    if (std.mem.indexOfScalar(u8, base[1..], '@') != null) return error.InvalidImportSpec;

    const subpath = if (base_end < spec.len) spec[base_end + 1 ..] else "";
    if (second_slash_relative != null and subpath.len == 0) return error.InvalidImportSpec;
    try validateSubpath(subpath);
    return .{ .base = base, .subpath = subpath, .qualified = true };
}

fn validateSubpath(subpath: []const u8) ImportError!void {
    if (subpath.len == 0) return;
    if (subpath[0] == '/') return error.InvalidImportSpec;

    var segments = std.mem.splitScalar(u8, subpath, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidImportSpec;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidImportSpec;
    }
}

fn selectExport(declaration: Declaration, subpath: []const u8) ImportError!ExportEntry {
    // `exports` 省略時の既定入口は `"."` だけ（§2）。明示表がある場合は
    // そこにないサブパスを補完しない。
    if (declaration.exports.len == 0) {
        if (subpath.len != 0) return error.UndeclaredSubpath;
        return .{ .subpath = ".", .binding = .scoped };
    }

    var matched: ?ExportEntry = null;
    for (declaration.exports) |export_entry| {
        if (!subpathMatches(export_entry.subpath, subpath)) continue;
        // 同じサブパスの重複は先勝ちにしない。どちらの binding を採るか
        // 推測できないため、import 時点で曖昧として拒否する。
        if (matched != null) return error.AmbiguousImport;
        matched = export_entry;
    }
    return matched orelse error.UndeclaredSubpath;
}

fn subpathMatches(export_subpath: []const u8, requested: []const u8) bool {
    if (requested.len == 0) return std.mem.eql(u8, export_subpath, ".");
    if (export_subpath.len != requested.len + 2) return false;
    if (!std.mem.startsWith(u8, export_subpath, "./")) return false;
    return std.mem.eql(u8, export_subpath[2..], requested);
}

fn idName(id: []const u8) ?[]const u8 {
    if (id.len < 3 or id[0] != '@') return null;
    const slash = std.mem.indexOfScalar(u8, id, '/') orelse return null;
    if (slash <= 1 or slash + 1 >= id.len) return null;
    const name = id[slash + 1 ..];
    if (std.mem.indexOfScalar(u8, name, '/') != null) return null;
    return name;
}

test {
    _ = @import("v1_imports_test.zig");
}
