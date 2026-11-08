//! package alias（`パッケージ:` / `pkg:` の alias）の名前空間診断。
//!
//! `.nako/environment.json` の import 依存表（root scope と package scope）を
//! 静的検査し、公開 namespace（`{alias}__{命令}`）を曖昧にする alias を
//! 診断する。既存の alias 解決（`import_resolver` / `module_graph`）は変更
//! せず、診断だけを追加する（Issue #52 の名前空間 check）。
//!
//! - `empty`: alias が空、または正規化後に空（`@` 単体など）。
//! - `duplicate`: 同一 scope で正規化 namespace が同じで別 package
//!   （`my-util` と `my_util` の衝突を含む）。
//! - `invalid_char`: 公開 namespace が alias 表記と変わる文字。定義済みの
//!   変換（`-`→`_`、`/`→`__`、先頭 `@` の除去）は除外し、それ以外の文字と
//!   先頭数字（`@` を除いた後の先頭）を診断する。
//! - `reserved`: なでしこ3 の予約語と同名の alias。
//! - `module_collision`: プロジェクト既存 module（basename）と同じ公開
//!   namespace になる alias。
//!
//! `invalid_char` / `reserved` / `module_collision` は解決可能なため警告、
//! `empty` / `duplicate` は公開 namespace を一意に決められないためエラーと
//! して扱う（呼出し側が `isError` で判定する）。

const std = @import("std");
const builtin = @import("builtin");
const import_resolver = @import("import_resolver.zig");
const lexer = @import("../frontend/lexer.zig");

const Allocator = std.mem.Allocator;

pub const IssueKind = enum {
    empty,
    duplicate,
    invalid_char,
    reserved,
    module_collision,
};

/// 診断の重大度。空・重複は公開 namespace が一意に決まらないため error。
pub fn isError(kind: IssueKind) bool {
    return switch (kind) {
        .empty, .duplicate => true,
        .invalid_char, .reserved, .module_collision => false,
    };
}

pub fn kindText(kind: IssueKind) []const u8 {
    return switch (kind) {
        .empty => "empty",
        .duplicate => "duplicate",
        .invalid_char => "invalid_char",
        .reserved => "reserved",
        .module_collision => "module_collision",
    };
}

/// 診断する import 依存表の1 scope。`name` は "root" または package key。
pub const Scope = struct {
    name: []const u8,
    dependencies: []const Dependency,
};

pub const Dependency = struct {
    alias: []const u8,
    package: []const u8,
};

pub const Issue = struct {
    scope: []const u8,
    alias: []const u8,
    kind: IssueKind,
    /// 人間向けの説明。`analyze` の arena が所有する。
    detail: []const u8,
};

const SortableScope = struct {
    name: []const u8,
    dependencies: []const Dependency,
};

fn scopeLessThan(_: void, a: SortableScope, b: SortableScope) bool {
    // root を先頭に、以降は package key のバイト順。
    if (std.mem.eql(u8, a.name, "root") != std.mem.eql(u8, b.name, "root")) {
        return std.mem.eql(u8, a.name, "root");
    }
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn dependencyLessThan(_: void, a: Dependency, b: Dependency) bool {
    const alias_order = std.mem.order(u8, a.alias, b.alias);
    if (alias_order != .eq) return alias_order == .lt;
    return std.mem.order(u8, a.package, b.package) == .lt;
}

const SeenAlias = struct {
    alias: []const u8,
    package: []const u8,
};

/// `scopes` と `module_names`（プロジェクト既存 module の basename）から
/// 決定的な順序の診断一覧を作る。文字列は `arena` が所有する。
pub fn analyze(
    arena: Allocator,
    scopes: []const Scope,
    module_names: []const []const u8,
) error{OutOfMemory}![]const Issue {
    const sorted = try arena.alloc(SortableScope, scopes.len);
    for (scopes, 0..) |scope, index| {
        // `Issue.scope`/`Issue.alias` は結果 arena が所有する。caller の
        // 環境データが先に解放されても JSON 出力が読み出さないようにする。
        const dependencies = try arena.alloc(Dependency, scope.dependencies.len);
        for (scope.dependencies, 0..) |dependency, dep_index| {
            dependencies[dep_index] = .{
                .alias = try arena.dupe(u8, dependency.alias),
                .package = try arena.dupe(u8, dependency.package),
            };
        }
        std.mem.sort(Dependency, dependencies, {}, dependencyLessThan);
        sorted[index] = .{ .name = try arena.dupe(u8, scope.name), .dependencies = dependencies };
    }
    std.mem.sort(SortableScope, sorted, {}, scopeLessThan);

    var issues: std.ArrayList(Issue) = .empty;
    for (sorted) |scope| {
        // 同一 scope の公開 namespace → 最初に現れた (alias, package)。
        var seen: std.StringHashMapUnmanaged(SeenAlias) = .empty;
        defer seen.deinit(arena);
        for (scope.dependencies) |dependency| {
            const alias = dependency.alias;
            const normalized = try import_resolver.namespaceFor(arena, alias, null);
            if (alias.len == 0 or normalized.len == 0) {
                try issues.append(arena, .{
                    .scope = scope.name,
                    .alias = alias,
                    .kind = .empty,
                    .detail = try std.fmt.allocPrint(
                        arena,
                        "alias \"{s}\" の公開 namespace が空です",
                        .{alias},
                    ),
                });
                continue;
            }
            if (invalidChar(alias)) |detail| {
                try issues.append(arena, .{
                    .scope = scope.name,
                    .alias = alias,
                    .kind = .invalid_char,
                    .detail = try std.fmt.allocPrint(
                        arena,
                        "alias \"{s}\" は公開 namespace \"{s}\" へ正規化されます（{s}）",
                        .{ alias, normalized, detail },
                    ),
                });
            }
            if (reservedWord(normalized)) |word| {
                try issues.append(arena, .{
                    .scope = scope.name,
                    .alias = alias,
                    .kind = .reserved,
                    .detail = try std.fmt.allocPrint(
                        arena,
                        "alias \"{s}\" はなでしこ3の予約語 \"{s}\" と同じです",
                        .{ alias, word },
                    ),
                });
            }
            // 既存 module との衝突は project root scope の alias だけを対象に
            // する。package scope の修飾名は package 内の module 空間で解決
            // され、project 直下の入口 module 名とは衝突しない。
            if (std.mem.eql(u8, scope.name, "root")) {
                if (collidingModule(normalized, module_names)) |module_name| {
                    try issues.append(arena, .{
                        .scope = scope.name,
                        .alias = alias,
                        .kind = .module_collision,
                        .detail = try std.fmt.allocPrint(
                            arena,
                            "alias \"{s}\" の公開 namespace \"{s}\" は既存 module \"{s}\" と同じです",
                            .{ alias, normalized, module_name },
                        ),
                    });
                }
            }
            const entry = try seen.getOrPut(arena, normalized);
            if (entry.found_existing) {
                if (!std.mem.eql(u8, entry.value_ptr.package, dependency.package)) {
                    try issues.append(arena, .{
                        .scope = scope.name,
                        .alias = alias,
                        .kind = .duplicate,
                        .detail = try std.fmt.allocPrint(
                            arena,
                            "公開 namespace \"{s}\" が alias \"{s}\"（package \"{s}\"）と alias \"{s}\"（package \"{s}\"）で重複します",
                            .{ normalized, entry.value_ptr.alias, entry.value_ptr.package, alias, dependency.package },
                        ),
                    });
                }
            } else {
                entry.value_ptr.* = .{ .alias = alias, .package = dependency.package };
            }
        }
    }
    return issues.items;
}

/// 正規化で意味が変わる文字を説明する。問題が無ければ null。
fn invalidChar(alias: []const u8) ?[]const u8 {
    // 正規化は先頭の `@` を剥がしてから identifier を組み立てるため、
    // 先頭数字の判定も `@` を剥がした位置で行う（`@1x` → `_1x`）。
    const start: usize = if (alias.len > 0 and alias[0] == '@') 1 else 0;
    for (alias, 0..) |byte, index| {
        if (byte >= 0x80) continue;
        if (std.ascii.isAlphanumeric(byte)) {
            if (index == start and std.ascii.isDigit(byte)) {
                return "先頭が数字なので \"_\" が補われます";
            }
            continue;
        }
        switch (byte) {
            // namespace の区切りとして定義済みの文字。
            '_', '-', '/' => continue,
            '@' => {
                if (index == 0) continue;
                return "\"@\" は先頭だけが意味を持ちます";
            },
            else => return "英数字・\"_\"・\"-\"・\"/\"・先頭\"@\"以外の文字を含みます",
        }
    }
    // 全角スペース等の Unicode 区切りは identifier を分割し、`{alias}__命令`
    // の修飾名として参照できなくなるため警告する。
    if (unicodeSeparator(alias) != null) {
        return "Unicode の区切り文字（全角スペース等）を含みます";
    }
    return null;
}

/// 識別子を分割する Unicode 区切り（空白・行/段落区切り・BOM）を検出する。
fn unicodeSeparator(alias: []const u8) ?u21 {
    const view = std.unicode.Utf8View.init(alias) catch return null;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        switch (codepoint) {
            0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => return codepoint,
            0x2000...0x200A => return codepoint,
            else => {},
        }
    }
    return null;
}

fn reservedWord(normalized: []const u8) ?[]const u8 {
    for (lexer.exported_reserved_words) |word| {
        if (std.mem.eql(u8, word, normalized)) return word;
    }
    return null;
}

fn collidingModule(normalized: []const u8, module_names: []const []const u8) ?[]const u8 {
    for (module_names) |name| {
        if (std.mem.eql(u8, name, normalized)) return name;
    }
    return null;
}

const test_sandbox = @import("test_sandbox.zig");
const testing = std.testing;

fn analyzeFixture(arena: Allocator, dependencies: []const Dependency, module_names: []const []const u8) ![]const Issue {
    const scopes = [_]Scope{.{ .name = "root", .dependencies = dependencies }};
    return analyze(arena, &scopes, module_names);
}

fn countKind(issues: []const Issue, kind: IssueKind) usize {
    var count: usize = 0;
    for (issues) |issue| {
        if (issue.kind == kind) count += 1;
    }
    return count;
}

test "namespace: 正常なaliasは診断しない" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const issues = try analyzeFixture(arena.allocator(), &.{
        .{ .alias = "demo", .package = "pkg:demo" },
        .{ .alias = "http/server", .package = "pkg:http" },
    }, &.{"main"});
    try testing.expectEqual(@as(usize, 0), issues.len);
}

test "namespace: 空aliasと正規化後空aliasをemptyとして診断する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const issues = try analyzeFixture(arena.allocator(), &.{
        .{ .alias = "", .package = "pkg:a" },
        .{ .alias = "@", .package = "pkg:b" },
    }, &.{});
    try testing.expectEqual(@as(usize, 2), countKind(issues, .empty));
    for (issues) |issue| try testing.expect(isError(issue.kind));
    try testing.expectEqualStrings("", issues[0].alias);
}

test "namespace: 正規化後に同じnamespaceへ落ちる別packageのaliasを重複として診断する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const issues = try analyzeFixture(arena.allocator(), &.{
        .{ .alias = "my-util", .package = "pkg:a" },
        .{ .alias = "my_util", .package = "pkg:b" },
    }, &.{});
    try testing.expectEqual(@as(usize, 1), countKind(issues, .duplicate));
    try testing.expect(std.mem.indexOf(u8, issues[0].detail, "my_util") != null);
    try testing.expect(isError(issues[0].kind));
}

test "namespace: 同じpackageを指す正規化衝突は重複にしない" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const issues = try analyzeFixture(arena.allocator(), &.{
        .{ .alias = "my-util", .package = "pkg:a" },
        .{ .alias = "my_util", .package = "pkg:a" },
    }, &.{});
    try testing.expectEqual(@as(usize, 0), countKind(issues, .duplicate));
}

test "namespace: 正規化で畳まれる文字をinvalid_charとして診断する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const issues = try analyzeFixture(arena.allocator(), &.{
        .{ .alias = "my util", .package = "pkg:a" },
        .{ .alias = "1lib", .package = "pkg:b" },
    }, &.{});
    try testing.expectEqual(@as(usize, 2), countKind(issues, .invalid_char));
    for (issues) |issue| try testing.expect(!isError(issue.kind));
    try testing.expect(std.mem.indexOf(u8, issues[1].detail, "my_util") != null);
}

test "namespace: Unicodeの区切り文字を含むaliasをinvalid_charとして診断する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 全角スペース (U+3000) を含む alias。字句上は識別子が分割される。
    const issues = try analyzeFixture(arena.allocator(), &.{
        .{ .alias = "my　util", .package = "pkg:a" },
    }, &.{});
    try testing.expectEqual(@as(usize, 1), countKind(issues, .invalid_char));
    try testing.expect(std.mem.indexOf(u8, issues[0].detail, "Unicode") != null);
}

test "namespace: 予約語aliasをreservedとして診断する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const issues = try analyzeFixture(arena.allocator(), &.{
        .{ .alias = "もし", .package = "pkg:a" },
    }, &.{});
    try testing.expectEqual(@as(usize, 1), countKind(issues, .reserved));
    try testing.expect(std.mem.indexOf(u8, issues[0].detail, "もし") != null);
}

test "namespace: 既存moduleと同じnamespaceをcollisionとして診断する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const issues = try analyzeFixture(arena.allocator(), &.{
        .{ .alias = "util", .package = "pkg:a" },
        .{ .alias = "other", .package = "pkg:b" },
    }, &.{ "util", "main" });
    try testing.expectEqual(@as(usize, 1), countKind(issues, .module_collision));
    try testing.expectEqualStrings("util", issues[0].alias);
}

test "namespace: 先頭@を除いた直後の数字をinvalid_charとして診断する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const issues = try analyzeFixture(arena.allocator(), &.{
        .{ .alias = "@1lib", .package = "pkg:a" },
    }, &.{});
    try testing.expectEqual(@as(usize, 1), countKind(issues, .invalid_char));
    try testing.expect(std.mem.indexOf(u8, issues[0].detail, "_1lib") != null);
}

test "namespace: package scopeのaliasはproject rootのmodule名と衝突扱いにしない" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scopes = [_]Scope{
        .{ .name = "root", .dependencies = &.{} },
        .{ .name = "pkg:a", .dependencies = &.{
            .{ .alias = "util", .package = "pkg:b" },
        } },
    };
    const issues = try analyze(arena.allocator(), &scopes, &.{"util"});
    try testing.expectEqual(@as(usize, 0), countKind(issues, .module_collision));
}

test "namespace: package scopeも診断し順序を固定する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const scopes = [_]Scope{
        .{ .name = "pkg:z", .dependencies = &.{
            .{ .alias = "もし", .package = "pkg:c" },
        } },
        .{ .name = "root", .dependencies = &.{
            .{ .alias = "my-util", .package = "pkg:a" },
            .{ .alias = "my_util", .package = "pkg:b" },
        } },
    };
    const issues = try analyze(arena.allocator(), &scopes, &.{});
    try testing.expectEqual(@as(usize, 2), issues.len);
    // root scope が先頭、その中は alias のバイト順で安定する。
    try testing.expectEqualStrings("root", issues[0].scope);
    try testing.expectEqualStrings("my_util", issues[0].alias);
    try testing.expectEqualStrings("pkg:z", issues[1].scope);
}

pub const ModuleScan = struct {
    names: []const []const u8 = &.{},
    /// 512 件上限や I/O エラーで衝突検査が不完全か。
    complete: bool = true,
    reason: ?[]const u8 = null,
};

/// プロジェクト直下の source module 名（basename）を集める。alias の公開
/// namespace が既存 module と同じになると `{namespace}__{名前}` の解決が
/// 曖昧になるため、その衝突診断にだけ使う。サブディレクトリは辿らない。
/// 上限は module 候補を列挙・ソートした後に適用するため、同一 tree では
/// 常に同じ候補が検査対象になる。
pub fn scanProjectModules(arena: Allocator, io: std.Io, root_dir: std.Io.Dir) error{OutOfMemory}!ModuleScan {
    var dir = root_dir.openDir(io, ".", .{ .iterate = true }) catch {
        return .{ .complete = false, .reason = "project root を列挙できません" };
    };
    defer dir.close(io);
    var candidates: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (true) {
        const maybe_entry = iterator.next(io) catch {
            return .{
                .names = try sortedModuleNames(arena, candidates.items),
                .complete = false,
                .reason = "project root の列挙が途中で失敗しました",
            };
        };
        const entry = maybe_entry orelse break;
        // 通常ファイルと、通常ファイルを指す symlink を対象にする。
        const is_regular = switch (entry.kind) {
            .file => true,
            .sym_link => blk: {
                const stat = dir.statFile(io, entry.name, .{}) catch break :blk false;
                break :blk stat.kind == .file;
            },
            else => false,
        };
        if (!is_regular) continue;
        if (!isNakoSource(entry.name)) continue;
        try candidates.append(arena, try arena.dupe(u8, entry.name));
    }
    const limited = try sortedModuleNames(arena, candidates.items);
    var names: std.ArrayList([]const u8) = .empty;
    for (limited) |name| {
        if (names.items.len >= max_project_modules) {
            return .{
                .names = names.items,
                .complete = false,
                .reason = "project root の module 候補が512件を超えたため一部未検査",
            };
        }
        const extension = std.fs.path.extension(name);
        if (extension.len == 0 or extension.len >= name.len) continue;
        try names.append(arena, name[0 .. name.len - extension.len]);
    }
    return .{ .names = names.items };
}

const max_project_modules: usize = 512;

fn sortedModuleNames(arena: Allocator, names: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const sorted = try arena.dupe([]const u8, names);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return sorted;
}

fn isNakoSource(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".nako3") or
        std.ascii.eqlIgnoreCase(extension, ".dncl") or
        std.ascii.eqlIgnoreCase(extension, ".dncl2");
}

/// `check --json` の `commands.namespaces` を決定的に組み立てる。
pub fn summaryJson(
    gpa: Allocator,
    alias_count: usize,
    issues: []const Issue,
    scan_complete: bool,
    scan_reason: ?[]const u8,
) error{OutOfMemory}![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const header = try std.fmt.allocPrint(
        gpa,
        "{{\"aliases\":{d},\"scan\":\"{s}\"",
        .{ alias_count, if (scan_complete) "complete" else "incomplete" },
    );
    defer gpa.free(header);
    try out.appendSlice(gpa, header);
    if (scan_reason) |reason| {
        const reason_json = try std.json.Stringify.valueAlloc(gpa, reason, .{});
        defer gpa.free(reason_json);
        const field = try std.fmt.allocPrint(gpa, ",\"scanReason\":{s}", .{reason_json});
        defer gpa.free(field);
        try out.appendSlice(gpa, field);
    }
    try out.appendSlice(gpa, ",\"issues\":[");
    for (issues, 0..) |issue, index| {
        if (index > 0) try out.appendSlice(gpa, ",");
        const scope = try std.json.Stringify.valueAlloc(gpa, issue.scope, .{});
        defer gpa.free(scope);
        const alias = try std.json.Stringify.valueAlloc(gpa, issue.alias, .{});
        defer gpa.free(alias);
        const detail = try std.json.Stringify.valueAlloc(gpa, issue.detail, .{});
        defer gpa.free(detail);
        const item = try std.fmt.allocPrint(
            gpa,
            "{{\"scope\":{s},\"alias\":{s},\"kind\":\"{s}\",\"severity\":\"{s}\",\"detail\":{s}}}",
            .{ scope, alias, kindText(issue.kind), if (isError(issue.kind)) "error" else "warning", detail },
        );
        defer gpa.free(item);
        try out.appendSlice(gpa, item);
    }
    try out.appendSlice(gpa, "]}");
    return out.toOwnedSlice(gpa);
}
