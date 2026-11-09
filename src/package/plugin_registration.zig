//! plugin 実登録の照合（Issue #52 / PS10）。
//!
//! package 宣言 metadata（`.nako/environment.json` の `commands`）と、
//! plugin を実際にロードして register された command（名前・助詞・arity）
//! を照合する。`lnako check --load-plugins` で opt-in し、plugin の
//! 初期化コードの実行を伴うため既定では動かない。
//!
//! - native plugin（`lnako_plugin_v1`）: dlopen＋`initialize` まで実行し
//!   `registerCommand` された command table を収集する。State.deinit で
//!   deinitialize→library close まで回収する。
//! - ESM plugin: `--compat-js` の QuickJS で module を評価し
//!   `__lnako_commands` の key 一覧を収集する。評価は QuickJS engine 内に
//!   閉じ、Effects の builtin 呼出しは拒否する（plugin の top-level が
//!   なでしこ命令を呼ぶ構成は収集不能＝未検査として記録する）。
//!
//! ロードできない package は不一致にせず `uninspected`（load_failed 等）と
//! して記録する。照合結果は check の本文/JSON へ出す。

const std = @import("std");
const diag = @import("diagnostics.zig");
const npkg_commands = @import("npkg_commands.zig");
const builtin_catalog = @import("../semantic/builtin_catalog.zig");

const Allocator = std.mem.Allocator;

/// 1 package 分の実登録照合結果。
pub const PackageRegistration = struct {
    package_key: []const u8,
    /// plugin artifact をロードして実登録を収集できたか。false は
    /// `status` の理由により未検査（不一致とは扱わない）。
    inspected: bool = false,
    status: Status = .skipped,
    /// 実登録に無い宣言命令。
    declared_only: []const npkg_commands.Command = &.{},
    /// 宣言に無い実登録命令（公開名。namespace 付きは `{ns}__{name}`）。
    registered_only: []const []const u8 = &.{},
    /// 助詞/arity が不一致の宣言命令。
    shape_mismatches: []const ShapeMismatch = &.{},
    /// 宣言・実登録ともに存在し一致した命令数。
    matched_count: usize = 0,

    pub const Status = enum {
        /// `--load-plugins` 未指定等、照合自体を実行していない。
        skipped,
        /// 宣言命令を持たない package（照合対象外）。
        no_commands,
        /// plugin artifact をロードできた。
        matched,
        /// ロードに失敗した（dlopen 失敗・ABI 不一致・初期化エラー等）。
        load_failed,
        /// plugin artifact を持たない宣言 package（source library 等）。
        /// 実登録照合の対象外で、静的検査の範囲。
        not_plugin,
        /// `--compat-js` 未指定で ESM plugin をロードできない。
        compat_js_required,

        pub fn text(self: Status) []const u8 {
            return switch (self) {
                .skipped => "skipped",
                .no_commands => "no_commands",
                .matched => "matched",
                .load_failed => "load_failed",
                .not_plugin => "not_plugin",
                .compat_js_required => "compat_js_required",
            };
        }
    };
};

/// 助詞/arity の不一致1件。
pub const ShapeMismatch = struct {
    name: []const u8,
    kind: Kind,

    pub const Kind = enum {
        arity,
        josi,

        pub fn text(self: Kind) []const u8 {
            return switch (self) {
                .arity => "arity",
                .josi => "josi",
            };
        }
    };
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    packages: []const PackageRegistration = &.{},
    /// plugin をロードして照合を実行したか。false は本文/JSON で
    /// 「未検査」を主張しない。
    inspected: bool = false,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn mismatchCount(self: *const Report) usize {
        var count: usize = 0;
        for (self.packages) |package| {
            count += package.declared_only.len + package.registered_only.len + package.shape_mismatches.len;
        }
        return count;
    }

    pub fn find(self: *const Report, package_key: []const u8) ?*const PackageRegistration {
        for (self.packages) |*package| {
            if (std.mem.eql(u8, package.package_key, package_key)) return package;
        }
        return null;
    }
};

/// 照合対象の package 記録。environment.json から呼出し側が写す。
pub const PackageInput = struct {
    package_key: []const u8,
    /// project root からの相対 path（環境記録の `path`）。
    path: []const u8,
    /// 宣言命令 metadata（null は環境に `commands` が無い＝未検査）。
    declared: ?[]const npkg_commands.Command = null,
    /// plugin artifact の相対 path（export 解決結果）。null は plugin では
    /// ない package（source library）。
    plugin_artifact: ?[]const u8 = null,
    /// ESM plugin か（false は native plugin）。
    esm: bool = false,
    /// package 経由の公開 namespace。空は直接 path import 相当（無修飾）。
    namespace: []const u8 = "",
};

pub const Options = struct {
    /// QuickJS が有効（`-Dcompat-js=true` ビルド）か。false で ESM plugin
    /// は `compat_js_required` として未検査にする。
    compat_js_available: bool = false,
};

/// 宣言 metadata と実登録を照合する。`inputs` の文字列は呼出し側が所有し、
/// 戻り値の Report は内蔵 arena が所有する。
pub fn inspect(
    gpa: Allocator,
    inputs: []const PackageInput,
    options: Options,
) error{OutOfMemory}!Report {
    var report = Report{ .arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer report.deinit();
    const arena = report.arena.allocator();

    report.inspected = true;
    const packages = try arena.alloc(PackageRegistration, inputs.len);
    for (inputs, 0..) |input, index| {
        packages[index] = try inspectPackage(arena, input, options);
    }
    report.packages = packages;
    return report;
}

fn inspectPackage(arena: Allocator, input: PackageInput, options: Options) error{OutOfMemory}!PackageRegistration {
    var result = PackageRegistration{
        .package_key = try arena.dupe(u8, input.package_key),
    };
    if (input.plugin_artifact == null) {
        result.status = .not_plugin;
        return result;
    }
    if (input.esm and !options.compat_js_available) {
        result.status = .compat_js_required;
        return result;
    }
    if (input.declared == null or input.declared.?.len == 0) {
        // 宣言命令が無い package は静的検査側の未検査理由が既にあるため、
        // 実登録照合では `no_commands` として対象外にする。
        result.status = .no_commands;
        return result;
    }

    const registered = collectRegistered(arena, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            // ロード失敗は不一致にしない。誤って宣言のみを「実登録に無い」
            // と診断させないため、未検査として記録する。
            result.status = .load_failed;
            return result;
        },
    };

    result.status = .matched;
    result.inspected = true;
    result.matched_count = registered.matched;
    result.declared_only = registered.declared_only;
    result.registered_only = registered.registered_only;
    result.shape_mismatches = registered.shape_mismatches;
    return result;
}

const RegisteredCommands = struct {
    /// 登録名（公開名。namespace 付きは `{ns}__{name}`）。
    names: []const []const u8,
    /// `names` と対応する助詞列。JS plugin は助詞を持たないため空。
    josi: []const []const []const u8,
    /// 助詞の有無。false の命令は助詞/arity 照合の対象外（名前照合のみ）。
    has_particles: []const bool,
    matched: usize,
    declared_only: []const npkg_commands.Command,
    registered_only: []const []const u8,
    shape_mismatches: []const ShapeMismatch,
};

/// plugin をロードして登録 command を収集する。`error.LoadFailed` 系は
/// 呼出し側で未検査へ落とす。
fn collectRegistered(arena: Allocator, input: PackageInput) (error{ LoadFailed, OutOfMemory })!RegisteredCommands {
    if (input.esm) {
        const names = @import("../compat/plugin_probe.zig").collectEsmCommandNames(
            arena,
            input.plugin_artifact.?,
            input.namespace,
        ) catch return error.LoadFailed;
        return diffNames(arena, input.declared.?, names);
    }
    const registered = collectNativeCommands(arena, input.plugin_artifact.?, input.namespace) catch
        return error.LoadFailed;
    return diffNative(arena, input.declared.?, registered);
}

/// 宣言と登録名の一覧を照合する（助詞の無い経路: ESM plugin）。
fn diffNames(
    arena: Allocator,
    declared: []const npkg_commands.Command,
    registered_names: []const []const u8,
) error{OutOfMemory}!RegisteredCommands {
    var registered_only: std.ArrayList([]const u8) = .empty;
    var declared_only: std.ArrayList(npkg_commands.Command) = .empty;
    var matched: usize = 0;

    for (registered_names) |name| {
        var found = false;
        for (declared) |command| {
            if (!std.mem.eql(u8, command.name, name)) continue;
            found = true;
            matched += 1;
            break;
        }
        if (!found) try registered_only.append(arena, name);
    }
    for (declared) |command| {
        var found = false;
        for (registered_names) |name| {
            if (std.mem.eql(u8, command.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) try declared_only.append(arena, command);
    }
    return .{
        .names = registered_names,
        .josi = &.{},
        .has_particles = &.{},
        .matched = matched,
        .declared_only = try declared_only.toOwnedSlice(arena),
        .registered_only = try registered_only.toOwnedSlice(arena),
        .shape_mismatches = &.{},
    };
}

/// native plugin の登録 command（公開名・助詞・arity）。
const NativeRegistered = struct {
    /// 公開名。namespace 付き登録は `{ns}__{name}`。
    names: []const []const u8,
    /// `names` と対応する助詞列（生の particles 文字列）。
    particles: []const []const u8,
    minimum_arguments: []const usize,
    maximum_arguments: []const usize,
};

/// native plugin（`lnako_plugin_v1`）をロードして登録 command を収集する。
/// dlopen と `initialize` を実行するため、plugin の初期化コードが動く。
/// 収集後に `deinitialize`→library close まで回収する。
fn collectNativeCommands(
    arena: Allocator,
    artifact_path: []const u8,
    namespace: []const u8,
) (error{ LoadFailed, OutOfMemory })!NativeRegistered {
    const probe = @import("../plugins/native_probe.zig");
    const collected = probe.collect(arena, artifact_path, namespace) catch
        return error.LoadFailed;
    return .{
        .names = collected.names,
        .particles = collected.particles,
        .minimum_arguments = collected.minimum_arguments,
        .maximum_arguments = collected.maximum_arguments,
    };
}

/// 宣言と native 実登録を照合する。名前は公開名（namespace 付きは
/// `{ns}__{name}`）で比較し、双方に存在する命令は助詞/arity を検査する。
fn diffNative(
    arena: Allocator,
    declared: []const npkg_commands.Command,
    registered: NativeRegistered,
) error{OutOfMemory}!RegisteredCommands {
    var registered_only: std.ArrayList([]const u8) = .empty;
    var declared_only: std.ArrayList(npkg_commands.Command) = .empty;
    var shape_mismatches: std.ArrayList(ShapeMismatch) = .empty;
    var matched: usize = 0;

    for (registered.names, 0..) |name, index| {
        var found = false;
        for (declared) |command| {
            if (!std.mem.eql(u8, command.name, name)) continue;
            found = true;
            matched += 1;
            // 助詞/arity 照合。宣言の args/josi と、実登録の particles から
            // 導出したスロット数・助詞列を比較する。
            if (try nativeShapeMismatch(command, registered.particles[index], registered.minimum_arguments[index], registered.maximum_arguments[index], arena)) |kind| {
                try shape_mismatches.append(arena, .{ .name = name, .kind = kind });
            }
            break;
        }
        if (!found) try registered_only.append(arena, name);
    }
    for (declared) |command| {
        var found = false;
        for (registered.names) |name| {
            if (std.mem.eql(u8, command.name, name)) {
                found = true;
                break;
            }
        }
        if (!found) try declared_only.append(arena, command);
    }
    return .{
        .names = registered.names,
        .josi = &.{},
        .has_particles = &.{},
        .matched = matched,
        .declared_only = try declared_only.toOwnedSlice(arena),
        .registered_only = try registered_only.toOwnedSlice(arena),
        .shape_mismatches = try shape_mismatches.toOwnedSlice(arena),
    };
}

/// native 実登録の particles/arity と宣言 metadata の不一致を判定する。
/// 宣言 `args` の個数（=arity）と実登録の `minimum_arguments` を比較し、
/// 助詞は宣言 `josi` と particles から導出したスロット助詞列を比較する。
/// どちらも不一致なら arity を優先して返す（1件1理由の決定的診断）。
fn nativeShapeMismatch(
    command: npkg_commands.Command,
    particles: []const u8,
    minimum_arguments: usize,
    maximum_arguments: usize,
    arena: Allocator,
) error{OutOfMemory}!?ShapeMismatch.Kind {
    var josi_backing: std.ArrayList(u8) = .empty;
    defer josi_backing.deinit(arena);
    var slot_count: std.ArrayList(usize) = .empty;
    defer slot_count.deinit(arena);
    const slots = try particleSlots(arena, &josi_backing, &slot_count, particles);
    const declared_arity = command.args.len;
    // 宣言は「引数名と助詞の対応配列」であり可変長は表現できない。実登録が
    // 可変長（min != max）なら宣言側では固定 arity で表現できていないため
    // 不一致とする。min == max の固定 arity のみを照合対象にする。
    if (minimum_arguments != maximum_arguments) return .arity;
    if (declared_arity != minimum_arguments or slots.len != minimum_arguments) return .arity;
    // 助詞照合。宣言 `josi` と particles 導出助詞を順に比較する。
    // particles から導出できない（プレースホルダ無し）場合は名前照合のみ。
    var differs = false;
    for (command.josi, 0..) |josi, index| {
        if (index >= slots.len) {
            differs = true;
            break;
        }
        if (!std.mem.eql(u8, josi, slots[index][0])) differs = true;
    }
    if (command.josi.len != slots.len) differs = true;
    if (differs) return .josi;
    return null;
}

/// particles 文字列（`AとBを` 形式）からスロット助詞列を導出する。
/// ASCII 大文字で始まる連続はプレースホルダで、直後の助詞（非 ASCII 部分）
/// がスロットの助詞になる。プレースホルダの無い particles（`""`）は空列。
/// E029 系の既存診断と同じく、導出できない形状は空列として名前照合だけ
/// 行わせる（誤って arity 不一致にしないため arity 0 判定は行わない）。
/// `backing` はスロット助詞列の退避先（呼出し側が所有）。
fn particleSlots(gpa: Allocator, backing: *std.ArrayList(u8), slot_count: *std.ArrayList(usize), particles: []const u8) error{OutOfMemory}![]const []const []const u8 {
    var index: usize = 0;
    while (index < particles.len) {
        const character = particles[index];
        if (character >= 'A' and character <= 'Z') {
            // プレースホルダ。連続するプレースホルダ文字を読み飛ばす。
            while (index < particles.len and isPlaceholderChar(particles[index])) index += 1;
            // 直後の助詞（非プレースホルダ部分）を読む。
            const start = index;
            while (index < particles.len and !isPlaceholderStart(particles[index])) index += 1;
            const josi_start = backing.items.len;
            if (index > start) try backing.appendSlice(gpa, particles[start..index]);
            try slot_count.append(gpa, backing.items.len - josi_start);
        } else {
            index += 1;
        }
    }
    // backing の助詞を slot_count 個ずつ区切って返す。
    var out: std.ArrayList([]const []const u8) = .empty;
    var offset: usize = 0;
    for (slot_count.items) |length| {
        const slot = try gpa.alloc([]const u8, 1);
        slot[0] = backing.items[offset .. offset + length];
        offset += length;
        try out.append(gpa, slot);
    }
    return out.items;
}

fn isPlaceholderChar(character: u8) bool {
    return (character >= 'A' and character <= 'Z') or (character >= '0' and character <= '9') or character == '_';
}

fn isPlaceholderStart(character: u8) bool {
    return character >= 'A' and character <= 'Z';
}

// builtin 名との衝突は登録時点で拒否済みのため、宣言側の builtin 重複は
// command_inspect の既存診断に委ねる。
comptime {
    _ = builtin_catalog;
}

/// 照合結果から E029 系診断を生成する。`diagnostics` は呼出し側が所有。
pub fn addDiagnostics(
    report: *const Report,
    diagnostics: *diag.List,
) error{OutOfMemory}!void {
    for (report.packages) |*package| {
        if (!package.inspected) continue;
        for (package.declared_only) |command| {
            try diagnostics.addFmt(
                diag.E029_INVALID_VALUE,
                .err,
                package.package_key,
                .{},
                "declared command \"{s}\" in package \"{s}\" is not registered by the loaded plugin",
                .{ command.name, package.package_key },
            );
        }
        for (package.registered_only) |name| {
            try diagnostics.addFmt(
                diag.E029_INVALID_VALUE,
                .err,
                package.package_key,
                .{},
                "registered command \"{s}\" in package \"{s}\" is missing from declared metadata",
                .{ name, package.package_key },
            );
        }
        for (package.shape_mismatches) |mismatch| {
            try diagnostics.addFmt(
                diag.E029_INVALID_VALUE,
                .err,
                package.package_key,
                .{},
                "command \"{s}\" in package \"{s}\" has a {s} mismatch between declared metadata and plugin registration",
                .{ mismatch.name, package.package_key, mismatch.kind.text() },
            );
        }
    }
}

/// 照合結果を JSON 断片へ書き出す。`commands` object の配下へ差し込む
/// `,\"registration\":...` 形式で返す（空のときは空文字列）。
pub fn summaryJson(gpa: Allocator, report: *const Report) error{OutOfMemory}![]const u8 {
    if (!report.inspected) return "";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try out.appendSlice(gpa, ",\"registration\":{\"packages\":[");
    for (report.packages, 0..) |*package, index| {
        if (index > 0) try out.appendSlice(gpa, ",");
        const package_key = try std.json.Stringify.valueAlloc(gpa, package.package_key, .{});
        defer gpa.free(package_key);
        const header = try std.fmt.allocPrint(
            gpa,
            "{{\"package\":{s},\"status\":\"{s}\",\"inspected\":{},\"matched\":{d}",
            .{ package_key, package.status.text(), package.inspected, package.matched_count },
        );
        defer gpa.free(header);
        try out.appendSlice(gpa, header);

        try out.appendSlice(gpa, ",\"declaredOnly\":[");
        for (package.declared_only, 0..) |command, i| {
            if (i > 0) try out.appendSlice(gpa, ",");
            const name = try std.json.Stringify.valueAlloc(gpa, command.name, .{});
            defer gpa.free(name);
            try out.appendSlice(gpa, name);
        }
        try out.appendSlice(gpa, "],\"registeredOnly\":[");
        for (package.registered_only, 0..) |name, i| {
            if (i > 0) try out.appendSlice(gpa, ",");
            const name_json = try std.json.Stringify.valueAlloc(gpa, name, .{});
            defer gpa.free(name_json);
            try out.appendSlice(gpa, name_json);
        }
        try out.appendSlice(gpa, "],\"shapeMismatches\":[");
        for (package.shape_mismatches, 0..) |mismatch, i| {
            if (i > 0) try out.appendSlice(gpa, ",");
            const name = try std.json.Stringify.valueAlloc(gpa, mismatch.name, .{});
            defer gpa.free(name);
            const item = try std.fmt.allocPrint(
                gpa,
                "{{\"name\":{s},\"kind\":\"{s}\"}}",
                .{ name, mismatch.kind.text() },
            );
            defer gpa.free(item);
            try out.appendSlice(gpa, item);
        }
        try out.appendSlice(gpa, "]}");
    }
    try out.appendSlice(gpa, "]}");
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "diffNames: 一致・宣言のみ・登録のみを分類する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const declared = [_]npkg_commands.Command{
        .{ .name = "加算", .args = &.{ "A", "B" }, .josi = &.{ "と", "を" } },
        .{ .name = "宣言だけ", .args = &.{}, .josi = &.{} },
    };
    const names = [_][]const u8{ "加算", "登録だけ" };

    const result = try diffNames(arena, &declared, &names);
    try testing.expectEqual(@as(usize, 1), result.matched);
    try testing.expectEqual(@as(usize, 1), result.declared_only.len);
    try testing.expectEqualStrings("宣言だけ", result.declared_only[0].name);
    try testing.expectEqual(@as(usize, 1), result.registered_only.len);
    try testing.expectEqualStrings("登録だけ", result.registered_only[0]);
    try testing.expectEqual(@as(usize, 0), result.shape_mismatches.len);
}

test "diffNative: 一致・宣言のみ・登録のみ・助詞不一致を分類する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const declared = [_]npkg_commands.Command{
        .{ .name = "一致命令", .args = &.{ "A", "B" }, .josi = &.{ "と", "を" } },
        .{ .name = "宣言だけ", .args = &.{}, .josi = &.{} },
        .{ .name = "助詞不一致", .args = &.{ "A", "B" }, .josi = &.{ "を", "と" } },
        .{ .name = "arity不一致", .args = &.{"A"}, .josi = &.{"を"} },
    };
    const registered = NativeRegistered{
        .names = &.{ "一致命令", "助詞不一致", "登録だけ" },
        .particles = &.{ "AとBを", "AとBを", "Vを" },
        .minimum_arguments = &.{ 2, 2, 1 },
        .maximum_arguments = &.{ 2, 2, 1 },
    };

    const result = try diffNative(arena, &declared, registered);
    try testing.expectEqual(@as(usize, 2), result.matched);
    try testing.expectEqual(@as(usize, 1), result.declared_only.len);
    try testing.expectEqualStrings("宣言だけ", result.declared_only[0].name);
    try testing.expectEqual(@as(usize, 1), result.declared_only.len);
    try testing.expectEqual(@as(usize, 1), result.registered_only.len);
    try testing.expectEqualStrings("登録だけ", result.registered_only[0]);
    try testing.expectEqual(@as(usize, 2), result.shape_mismatches.len);
    try testing.expectEqual(ShapeMismatch.Kind.josi, result.shape_mismatches[0].kind);
    try testing.expectEqualStrings("助詞不一致", result.shape_mismatches[0].name);
    try testing.expectEqual(ShapeMismatch.Kind.arity, result.shape_mismatches[1].kind);
    try testing.expectEqualStrings("arity不一致", result.shape_mismatches[1].name);
}

test "particleSlots: プレースホルダからスロット助詞を導出する" {
    var backing: std.ArrayList(u8) = .empty;
    defer backing.deinit(std.testing.allocator);
    var slot_count: std.ArrayList(usize) = .empty;
    defer slot_count.deinit(std.testing.allocator);

    // AとBを → ["と", "を"]
    const slots = try particleSlots(std.testing.allocator, &backing, &slot_count, "AとBを");
    try testing.expectEqual(@as(usize, 2), slots.len);
    try testing.expectEqualStrings("と", slots[0][0]);
    try testing.expectEqualStrings("を", slots[1][0]);

    // 助詞なし引数は空助詞スロット。
    const no_josi = try particleSlots(std.testing.allocator, &backing, &slot_count, "AB");
    try testing.expectEqual(@as(usize, 2), no_josi.len);
    try testing.expectEqualStrings("", no_josi[0][0]);
    try testing.expectEqualStrings("", no_josi[1][0]);

    // プレースホルダ無しは空列（名前照合のみ）。
    const empty = try particleSlots(std.testing.allocator, &backing, &slot_count, "");
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "nativeShapeMismatch: 可変長登録はarity不一致と判定する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    const command = npkg_commands.Command{
        .name = "連続加算",
        .args = &.{ "A", "B" },
        .josi = &.{ "と", "を" },
    };
    try testing.expectEqual(
        ShapeMismatch.Kind.arity,
        (try nativeShapeMismatch(command, "AとBを", 2, 5, arena)).?,
    );
    try testing.expectEqual(
        @as(?ShapeMismatch.Kind, null),
        try nativeShapeMismatch(command, "AとBを", 2, 2, arena),
    );
}

test "inspect: plugin無し・宣言無し・ESM非compatのpackageは未検査扱い" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();

    const declared = [_]npkg_commands.Command{
        .{ .name = "加算", .args = &.{ "A", "B" }, .josi = &.{ "と", "を" } },
    };
    const inputs = [_]PackageInput{
        .{ .package_key = "pkg:source", .path = "lib", .plugin_artifact = null, .declared = &declared },
        .{ .package_key = "pkg:nocommands", .path = "lib", .plugin_artifact = "lib/plugin.so", .declared = null },
        .{
            .package_key = "pkg:esm",
            .path = "lib",
            .plugin_artifact = "lib/plugin.mjs",
            .esm = true,
            .declared = &declared,
            .namespace = "esm",
        },
    };
    var report = try inspect(testing.allocator, &inputs, .{});
    defer report.deinit();

    try testing.expect(report.inspected);
    try testing.expectEqual(@as(usize, 3), report.packages.len);
    try testing.expectEqual(PackageRegistration.Status.not_plugin, report.packages[0].status);
    try testing.expect(!report.packages[0].inspected);
    try testing.expectEqual(PackageRegistration.Status.no_commands, report.packages[1].status);
    try testing.expectEqual(PackageRegistration.Status.compat_js_required, report.packages[2].status);
    try testing.expectEqual(@as(usize, 0), report.mismatchCount());
}

test "summaryJson: 照合結果をJSON断片として出す" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const declared = [_]npkg_commands.Command{
        .{ .name = "加算", .args = &.{ "A", "B" }, .josi = &.{ "と", "を" } },
        .{ .name = "宣言だけ", .args = &.{}, .josi = &.{} },
    };
    const registered = NativeRegistered{
        .names = &.{ "加算", "登録だけ" },
        .particles = &.{ "AとBを", "Vを" },
        .minimum_arguments = &.{ 2, 1 },
        .maximum_arguments = &.{ 2, 1 },
    };
    const result = try diffNative(arena, &declared, registered);

    const packages = [_]PackageRegistration{
        .{
            .package_key = "pkg:aaa",
            .inspected = true,
            .status = .matched,
            .matched_count = result.matched,
            .declared_only = result.declared_only,
            .registered_only = result.registered_only,
            .shape_mismatches = result.shape_mismatches,
        },
    };
    const report = Report{
        .arena = arena_impl,
        .packages = &packages,
        .inspected = true,
    };

    const json = try summaryJson(testing.allocator, &report);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, ",\"registration\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"package\":\"pkg:aaa\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"status\":\"matched\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"declaredOnly\":[\"宣言だけ\"]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"registeredOnly\":[\"登録だけ\"]") != null);
}

test "summaryJson: 未検査のreportは空文字列を返す" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const report = Report{ .arena = arena_impl, .inspected = false };
    const json = try summaryJson(testing.allocator, &report);
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("", json);
}

test "addDiagnostics: 不一致をE029として報告する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    const packages = [_]PackageRegistration{
        .{
            .package_key = try arena.dupe(u8, "pkg:aaa"),
            .inspected = true,
            .status = .matched,
            .declared_only = try dupeNames(arena, &.{"宣言だけ"}),
            .registered_only = try arena.dupe([]const u8, &.{"登録だけ"}),
            .shape_mismatches = try arena.dupe(ShapeMismatch, &.{.{ .name = "加算", .kind = .josi }}),
        },
        .{
            .package_key = try arena.dupe(u8, "pkg:failed"),
            .status = .load_failed,
        },
    };
    const report = Report{ .arena = arena_impl, .packages = &packages, .inspected = true };

    var list = diag.List.init(testing.allocator);
    defer list.deinit();
    try addDiagnostics(&report, &list);
    try testing.expectEqual(@as(usize, 3), list.items.items.len);
    try testing.expect(list.find(diag.E029_INVALID_VALUE) != null);
}

fn dupeNames(arena: Allocator, names: []const []const u8) ![]const npkg_commands.Command {
    const out = try arena.alloc(npkg_commands.Command, names.len);
    for (names, 0..) |name, index| out[index] = .{ .name = name, .args = &.{}, .josi = &.{} };
    return out;
}
