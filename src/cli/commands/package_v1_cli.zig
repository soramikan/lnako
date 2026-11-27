//! `lnako package build|pack|verify` の v1 CLI 入力解釈。
//!
//! 仕様 v1（`nako-registry/docs/specification.md` §3）は、一つの `.npkg` が
//! 単一アーティファクト（kind と runtimes の組）を表すと定める。CLI は
//! kind・runtimes・native の対象情報を明示的に受け取り、ZIP の生成と検証は
//! `lnako.package.v1_archive`（P03）へ委ねる。このモジュールは引数の解釈と
//! 出力名・移行診断の文言だけを持ち、アーカイブのバイト列には触れない。
//!
//! 旧 `package build` は manifest から単一の `.npkg` を作るだけで kind を
//! 指定できなかった。v1 では `--kind` で全 kind を選び、native 系は
//! `--target-triple` / `--glibc-min` で対象を固定する。native-prebuilt の
//! 収録ライブラリは `prebuilt_lib_name` と triple から導出し、
//! `--library-path` が明示された場合はそちらを優先する。指定が欠けた場合は
//! usage エラー（終了コード 2）にし、既定値へ暗黙に落とさない。

const std = @import("std");

/// v1 §3.3 の `artifact.kind`。CLI の語彙として保持し、実際の enum への
/// 変換は接続層（`package.zig`）で行う。
pub const ArtifactKind = enum {
    universal,
    esm,
    native_source,
    native_prebuilt,

    pub fn text(self: ArtifactKind) []const u8 {
        return switch (self) {
            .universal => "universal",
            .esm => "esm",
            .native_source => "native-source",
            .native_prebuilt => "native-prebuilt",
        };
    }

    pub fn parse(value: []const u8) ?ArtifactKind {
        if (std.mem.eql(u8, value, "universal")) return .universal;
        if (std.mem.eql(u8, value, "esm")) return .esm;
        if (std.mem.eql(u8, value, "native-source")) return .native_source;
        if (std.mem.eql(u8, value, "native-prebuilt")) return .native_prebuilt;
        return null;
    }
};

/// 既知の runtime 名（§1.2）。順序は仕様の列挙順に合わせる。
pub const runtime_names = [_][]const u8{ "lnako", "cnako", "wnako" };

pub fn isRuntimeName(value: []const u8) bool {
    for (runtime_names) |name| {
        if (std.mem.eql(u8, name, value)) return true;
    }
    return false;
}

/// 一つのアーティファクトを作るための入力。`runtimes` が空の場合は
/// manifest（`artifacts.*.runtimes`）と kind から pack 側が決める。
pub const BuildArgs = struct {
    root: []const u8 = ".",
    output: ?[]const u8 = null,
    kind: ArtifactKind = .universal,
    runtimes: []const []const u8 = &.{},
    target_triple: ?[]const u8 = null,
    glibc_min: ?[]const u8 = null,
    library_path: ?[]const u8 = null,
    /// 明示入力する v1 COMMANDS.json のホスト側パス。ESM の JS/TS 入口や
    /// native ライブラリの実命令を、コードを実行せずに記述するために使う。
    commands_path: ?[]const u8 = null,
    help: bool = false,
};

/// verify の入力。二つ以上指定した場合は P04 のクロス検証も実行する。
pub const VerifyArgs = struct {
    files: []const []const u8 = &.{},
    help: bool = false,
};

pub const usage_error = error{Usage};

fn fail(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) usage_error {
    writer.print(format, args) catch {};
    return error.Usage;
}

/// 値を取るオプション。直後の引数が無い、または `-` で始まる場合は
/// 値を欠いた usage エラーにする（負数のような例外は v1 では無い）。
fn takeValue(args: []const []const u8, index: *usize, option: []const u8, stderr: *std.Io.Writer) usage_error![]const u8 {
    index.* += 1;
    if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "-")) {
        return fail(stderr, "package {s}: {s} には値が必要です\n", .{ "build", option });
    }
    return args[index.*];
}

/// カンマ区切りの runtime 名を追加する。重複と未知の名前は拒否する。
fn appendRuntimes(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    text: []const u8,
    stderr: *std.Io.Writer,
) !void {
    var iterator = std.mem.splitScalar(u8, text, ',');
    var count: usize = 0;
    while (iterator.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        count += 1;
        if (!isRuntimeName(name)) {
            return fail(stderr, "package build: 不明な runtime です: {s}（lnako|cnako|wnako）\n", .{name});
        }
        for (list.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                return fail(stderr, "package build: runtime が重複しています: {s}\n", .{name});
            }
        }
        try list.append(allocator, name);
    }
    if (count == 0) return fail(stderr, "package build: --runtime に runtime 名がありません\n", .{});
}

/// アーカイブ内の相対パス（§3.2 の制約を CLI 側で先に見る）。
pub fn validArchivePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return false;
    if (path.len >= 2 and path[1] == ':') return false;
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    for (path) |byte| {
        if (byte == '\\' or byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

fn hasAllRuntimes(runtimes: []const []const u8) bool {
    if (runtimes.len != runtime_names.len) return false;
    for (runtime_names) |name| {
        var found = false;
        for (runtimes) |runtime| {
            if (std.mem.eql(u8, runtime, name)) found = true;
        }
        if (!found) return false;
    }
    return true;
}

fn validTargetTriple(triple: []const u8) bool {
    // `{arch}-{os}-{abi}` の三要素。厳密な集合の判定は P02 の
    // `v1_types.validTargetTriple` が担い、ここでは CLI の早期診断だけを行う。
    var segments: usize = 1;
    for (triple) |byte| {
        if (byte == '-') segments += 1;
        if (byte == ' ' or byte == '/' or byte == '\\' or byte < 0x20) return false;
    }
    return segments == 3;
}

fn validGlibc(text: []const u8) bool {
    var pieces = std.mem.splitScalar(u8, text, '.');
    var count: usize = 0;
    while (pieces.next()) |piece| {
        if (piece.len == 0) return false;
        for (piece) |byte| {
            if (!std.ascii.isDigit(byte)) return false;
        }
        count += 1;
    }
    return count == 2;
}

/// GNU Linux の triple か（`*-linux-gnu`）。`glibc_min` の必須判定に使う。
pub fn isGnuLinux(triple: []const u8) bool {
    return std.mem.endsWith(u8, triple, "-linux-gnu");
}

/// `package build` / `package pack` の引数を解釈する。`args` はサブコマンド
/// 名の後ろ。`stdout` は使わず、usage エラーだけ `stderr` に書く。
pub fn parseBuildArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stderr: *std.Io.Writer,
) !BuildArgs {
    var result = BuildArgs{};
    var root_set = false;
    var runtimes: std.ArrayList([]const u8) = .empty;

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--help")) {
            result.help = true;
            continue;
        }
        if (std.mem.eql(u8, argument, "-o") or std.mem.eql(u8, argument, "--output")) {
            result.output = try takeValue(args, &index, argument, stderr);
            continue;
        }
        if (std.mem.eql(u8, argument, "--kind")) {
            const value = try takeValue(args, &index, argument, stderr);
            result.kind = ArtifactKind.parse(value) orelse
                return fail(stderr, "package build: --kind は universal|esm|native-source|native-prebuilt のいずれかです: {s}\n", .{value});
            continue;
        }
        if (std.mem.eql(u8, argument, "--runtime")) {
            const value = try takeValue(args, &index, argument, stderr);
            try appendRuntimes(allocator, &runtimes, value, stderr);
            continue;
        }
        if (std.mem.eql(u8, argument, "--target-triple")) {
            const value = try takeValue(args, &index, argument, stderr);
            if (!validTargetTriple(value)) {
                return fail(stderr, "package build: --target-triple は {{arch}}-{{os}}-{{abi}} 形式です: {s}\n", .{value});
            }
            result.target_triple = value;
            continue;
        }
        if (std.mem.eql(u8, argument, "--glibc-min")) {
            const value = try takeValue(args, &index, argument, stderr);
            if (!validGlibc(value)) {
                return fail(stderr, "package build: --glibc-min は MAJOR.MINOR 形式です: {s}\n", .{value});
            }
            result.glibc_min = value;
            continue;
        }
        if (std.mem.eql(u8, argument, "--library-path")) {
            const value = try takeValue(args, &index, argument, stderr);
            if (!validArchivePath(value)) {
                return fail(stderr, "package build: --library-path が不正です: {s}\n", .{value});
            }
            result.library_path = value;
            continue;
        }
        if (std.mem.eql(u8, argument, "--commands")) {
            result.commands_path = try takeValue(args, &index, argument, stderr);
            continue;
        }
        if (std.mem.startsWith(u8, argument, "-")) {
            return fail(stderr, "package build: 不明なオプションです: {s}\n", .{argument});
        }
        if (root_set) {
            return fail(stderr, "package build: 不明な引数です: {s}\n", .{argument});
        }
        result.root = argument;
        root_set = true;
    }

    result.runtimes = runtimes.items;
    if (result.help) return result;
    try validateBuild(&result, stderr);
    return result;
}

/// kind と native 指定の整合を検査する。manifest と突き合わせる検査は
/// `v1_archive.pack` が行う（`artifact.native.abi_version` 等）。
pub fn validateBuild(result: *const BuildArgs, stderr: *std.Io.Writer) usage_error!void {
    switch (result.kind) {
        .universal => {
            if (result.target_triple != null or
                result.glibc_min != null or result.library_path != null)
            {
                return fail(stderr, "package build: universal に native 用オプションは指定できません\n", .{});
            }
            // universal は全ランタイム共通なので、部分集合の指定は黙って
            // 捨てずに usage エラーにする。
            if (result.runtimes.len != 0 and !hasAllRuntimes(result.runtimes)) {
                return fail(stderr, "package build: universal の runtime は lnako,cnako,wnako のすべてです\n", .{});
            }
        },
        .esm => {
            if (result.target_triple != null or
                result.glibc_min != null or result.library_path != null)
            {
                return fail(stderr, "package build: esm に native 用オプションは指定できません\n", .{});
            }
            for (result.runtimes) |runtime| {
                if (std.mem.eql(u8, runtime, "lnako")) {
                    return fail(stderr, "package build: esm の runtime は cnako と wnako です\n", .{});
                }
            }
        },
        .native_source => {
            if (result.target_triple != null or result.glibc_min != null or result.library_path != null) {
                return fail(stderr, "package build: native-source に target-triple/glibc-min/library-path は指定できません\n", .{});
            }
            for (result.runtimes) |runtime| {
                if (!std.mem.eql(u8, runtime, "lnako")) {
                    return fail(stderr, "package build: native-source の runtime は lnako だけです\n", .{});
                }
            }
        },
        .native_prebuilt => {
            const triple = result.target_triple orelse
                return fail(stderr, "package build: native-prebuilt には --target-triple が必要です\n", .{});
            // ライブラリの収録パスは manifest の prebuilt_lib_name から導出できる。
            // 解決は pack が行い、導出できない場合だけ --library-path を要求する。
            if (isGnuLinux(triple)) {
                _ = result.glibc_min orelse
                    return fail(stderr, "package build: GNU Linux の native-prebuilt には --glibc-min が必要です\n", .{});
            } else if (result.glibc_min != null) {
                return fail(stderr, "package build: --glibc-min は GNU Linux のときだけ指定できます: {s}\n", .{triple});
            }
            for (result.runtimes) |runtime| {
                if (!std.mem.eql(u8, runtime, "lnako")) {
                    return fail(stderr, "package build: native-prebuilt の runtime は lnako だけです\n", .{});
                }
            }
        },
    }
}

/// `package verify <FILE>...` の引数を解釈する。v1 の verify は §3 の
/// 構造検証だけを行うため、旧 CLI の対象選択フラグは受け付けない。
pub fn parseVerifyArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stderr: *std.Io.Writer,
) !VerifyArgs {
    var result = VerifyArgs{};
    var files: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "-h") or std.mem.eql(u8, argument, "--help")) {
            result.help = true;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "-")) {
            return fail(
                stderr,
                "package verify: v1 の verify は §3 の構造検証だけを行うため {s} は使いません（対象選択は別途）\n",
                .{argument},
            );
        }
        try files.append(allocator, argument);
    }
    if (result.help) return result;
    if (files.items.len == 0) {
        return fail(stderr, "package verify: 検証する .npkg を一つ以上指定してください\n", .{});
    }
    result.files = files.items;
    return result;
}

/// §3.1 の推奨ファイル名。`id` は検証済みの `@scope/name`。
/// `example__demo-1.0.0-universal.npkg` のように scope と name を `__` で
/// つなぐ。`/` や `@` はファイル名に残さない。
pub fn defaultOutputName(
    allocator: std.mem.Allocator,
    id: []const u8,
    version: []const u8,
    kind: ArtifactKind,
    runtimes: []const []const u8,
    target_triple: ?[]const u8,
    abi_version: ?u32,
) ![]u8 {
    const slash = std.mem.indexOfScalar(u8, id, '/') orelse return error.InvalidPackageId;
    const scope = if (id.len > 0 and id[0] == '@') id[1..slash] else id[0..slash];
    const name = id[slash + 1 ..];
    const prefix = try std.fmt.allocPrint(allocator, "{s}__{s}-{s}", .{ scope, name, version });
    return switch (kind) {
        .universal => std.fmt.allocPrint(allocator, "{s}-universal.npkg", .{prefix}),
        .esm => blk: {
            const tag = try runtimeTag(allocator, runtimes);
            break :blk try std.fmt.allocPrint(allocator, "{s}-esm-{s}.npkg", .{ prefix, tag });
        },
        .native_source => std.fmt.allocPrint(allocator, "{s}-native-source.npkg", .{prefix}),
        .native_prebuilt => std.fmt.allocPrint(allocator, "{s}-native-{s}-abi{d}.npkg", .{
            prefix,
            target_triple orelse "unknown",
            abi_version orelse 0,
        }),
    };
}

/// ESM の runtime タグ。`cnako+wnako` のように `+` でつなぐ。順序は
/// `lnako`→`cnako`→`wnako` の仕様順に固定し、同じ入力から同じ名前を出す。
fn runtimeTag(allocator: std.mem.Allocator, runtimes: []const []const u8) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    for (runtime_names) |candidate| {
        for (runtimes) |runtime| {
            if (!std.mem.eql(u8, candidate, runtime)) continue;
            if (buffer.items.len != 0) try buffer.append(allocator, '+');
            try buffer.appendSlice(allocator, candidate);
            break;
        }
    }
    if (buffer.items.len == 0) {
        // manifest が runtimes を決める場合の予備。pack 側の決定と一致しない
        // ときは呼出し元が `--output` を要求する。
        try buffer.appendSlice(allocator, "unknown");
    }
    return buffer.toOwnedSlice(allocator);
}

/// 旧 manifest を検出したときの移行診断。暗黙変換はしない（§2、Q12）。
pub const legacy_manifest_message =
    \\package build: 旧形式の nako.toml を検出しました。v1 では先頭の `schema_version = 1` と
    \\  [package] の id（@scope/name）・version・license、マップ形式の [exports] が必要です。
    \\  旧 `name` / `[[exports]]` は読み替えず、nako.toml を v1 形式で再作成してください。
    \\
;

/// 旧アーカイブを検出したときの移行診断。
pub const legacy_archive_message =
    \\package verify: 旧制御ファイル（NAKO-PKG/FILES.toml または NAKO-PKG/commands.json）を
    \\  検出しました。v1 の .npkg は METADATA.toml・FILES.json・COMMANDS.json を必要とし、
    \\  名前を読み替えた展開は行いません。v1 の `lnako package build` で再作成してください。
    \\
;

test "v1 CLI: kind の表記と解析" {
    try std.testing.expectEqual(ArtifactKind.universal, ArtifactKind.parse("universal").?);
    try std.testing.expectEqual(ArtifactKind.esm, ArtifactKind.parse("esm").?);
    try std.testing.expectEqual(ArtifactKind.native_source, ArtifactKind.parse("native-source").?);
    try std.testing.expectEqual(ArtifactKind.native_prebuilt, ArtifactKind.parse("native-prebuilt").?);
    try std.testing.expect(ArtifactKind.parse("native") == null);
    try std.testing.expect(ArtifactKind.parse("") == null);
    try std.testing.expectEqualStrings("native-prebuilt", ArtifactKind.native_prebuilt.text());
}

test "v1 CLI: build の既定は universal、root と output を解釈する" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var err = std.Io.Writer.Allocating.init(a);
    const args = try parseBuildArgs(a, &.{ "pkg", "-o", "out.npkg" }, &err.writer);
    try std.testing.expectEqualStrings("pkg", args.root);
    try std.testing.expectEqualStrings("out.npkg", args.output.?);
    try std.testing.expectEqual(ArtifactKind.universal, args.kind);
}

test "v1 CLI: esm は runtimes を受け付け、lnako を拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var err = std.Io.Writer.Allocating.init(a);
    const args = try parseBuildArgs(a, &.{
        "--kind", "esm", "--runtime", "cnako,wnako",
    }, &err.writer);
    try std.testing.expectEqual(ArtifactKind.esm, args.kind);
    try std.testing.expectEqual(@as(usize, 2), args.runtimes.len);
    try std.testing.expectEqualStrings("cnako", args.runtimes[0]);

    var err2 = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{
        "--kind", "esm", "--runtime", "lnako",
    }, &err2.writer));
    try std.testing.expect(std.mem.indexOf(u8, err2.written(), "cnako と wnako") != null);
}

test "v1 CLI: native-prebuilt は triple と GNU の glibc を要求し、ライブラリは導出できる" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    var missing = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{
        "--kind", "native-prebuilt",
    }, &missing.writer));
    try std.testing.expect(std.mem.indexOf(u8, missing.written(), "--target-triple") != null);

    var gnu = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{
        "--kind",         "native-prebuilt",   "--target-triple", "x86_64-linux-gnu",
        "--library-path", "native/libdemo.so",
    }, &gnu.writer));
    try std.testing.expect(std.mem.indexOf(u8, gnu.written(), "--glibc-min") != null);

    // --library-path を省略しても usage エラーにはせず、pack が manifest の
    // prebuilt_lib_name から導出する。
    var derived = std.Io.Writer.Allocating.init(a);
    const derived_args = try parseBuildArgs(a, &.{
        "--kind", "native-prebuilt", "--target-triple", "x86_64-linux-gnu", "--glibc-min", "2.31",
    }, &derived.writer);
    try std.testing.expect(derived_args.library_path == null);

    var ok = std.Io.Writer.Allocating.init(a);
    const args = try parseBuildArgs(a, &.{
        "--kind",      "native-prebuilt", "--target-triple", "x86_64-linux-gnu",
        "--glibc-min", "2.31",            "--library-path",  "native/libdemo.so",
        "--runtime",   "lnako",
    }, &ok.writer);
    try std.testing.expectEqualStrings("2.31", args.glibc_min.?);
    try std.testing.expectEqualStrings("native/libdemo.so", args.library_path.?);

    // musl では glibc_min を拒否する。
    var musl = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{
        "--kind",      "native-prebuilt", "--target-triple", "x86_64-linux-musl",
        "--glibc-min", "2.31",            "--library-path",  "native/libdemo.so",
    }, &musl.writer));
    try std.testing.expect(std.mem.indexOf(u8, musl.written(), "GNU Linux") != null);
}

test "v1 CLI: native-source は manifest の abi を使い、native の誤用を拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    var err = std.Io.Writer.Allocating.init(a);
    const args = try parseBuildArgs(a, &.{
        "--kind", "native-source", "--runtime", "lnako",
    }, &err.writer);
    try std.testing.expectEqual(ArtifactKind.native_source, args.kind);

    var bad = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{
        "--kind", "universal", "--target-triple", "x86_64-linux-gnu",
    }, &bad.writer));
    try std.testing.expect(std.mem.indexOf(u8, bad.written(), "native 用オプション") != null);

    var partial = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{
        "--kind", "universal", "--runtime", "cnako",
    }, &partial.writer));
    try std.testing.expect(std.mem.indexOf(u8, partial.written(), "すべて") != null);

    var all = std.Io.Writer.Allocating.init(a);
    _ = try parseBuildArgs(a, &.{
        "--kind", "universal", "--runtime", "lnako,cnako,wnako",
    }, &all.writer);
}

test "v1 CLI: --commands は明示入力する COMMANDS.json のパスを受け取る" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    var err = std.Io.Writer.Allocating.init(a);
    const args = try parseBuildArgs(a, &.{
        "--kind", "esm", "--commands", "dist/COMMANDS.json",
    }, &err.writer);
    try std.testing.expectEqualStrings("dist/COMMANDS.json", args.commands_path.?);

    var missing = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{ "--kind", "esm", "--commands" }, &missing.writer));
    try std.testing.expect(std.mem.indexOf(u8, missing.written(), "--commands") != null);
}

test "v1 CLI: 未知の kind・runtime・オプションを拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    var kind = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{ "--kind", "wasm" }, &kind.writer));
    try std.testing.expect(std.mem.indexOf(u8, kind.written(), "universal|esm|native-source|native-prebuilt") != null);

    var runtime = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{ "--runtime", "node" }, &runtime.writer));
    try std.testing.expect(std.mem.indexOf(u8, runtime.written(), "不明な runtime") != null);

    var dup = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{ "--runtime", "cnako,cnako" }, &dup.writer));
    try std.testing.expect(std.mem.indexOf(u8, dup.written(), "重複") != null);

    var unknown = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseBuildArgs(a, &.{"--wat"}, &unknown.writer));
    try std.testing.expect(std.mem.indexOf(u8, unknown.written(), "不明なオプション") != null);
}

test "v1 CLI: verify は複数ファイルを受け付け、旧対象選択フラグを拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    var err = std.Io.Writer.Allocating.init(a);
    const args = try parseVerifyArgs(a, &.{ "a.npkg", "b.npkg" }, &err.writer);
    try std.testing.expectEqual(@as(usize, 2), args.files.len);

    var empty = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseVerifyArgs(a, &.{}, &empty.writer));
    try std.testing.expect(std.mem.indexOf(u8, empty.written(), "一つ以上") != null);

    var old = std.Io.Writer.Allocating.init(a);
    try std.testing.expectError(error.Usage, parseVerifyArgs(a, &.{ "--runtime", "lnako", "a.npkg" }, &old.writer));
    try std.testing.expect(std.mem.indexOf(u8, old.written(), "構造検証") != null);
}

test "v1 CLI: §3.1 の推奨ファイル名を kind ごとに組み立てる" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    try std.testing.expectEqualStrings("example__demo-1.0.0-universal.npkg", try defaultOutputName(
        a,
        "@example/demo",
        "1.0.0",
        .universal,
        &.{},
        null,
        null,
    ));
    try std.testing.expectEqualStrings("example__demo-1.0.0-esm-cnako+wnako.npkg", try defaultOutputName(
        a,
        "@example/demo",
        "1.0.0",
        .esm,
        &.{ "cnako", "wnako" },
        null,
        null,
    ));
    // runtimes の順序が逆でも同じ名前になる。
    try std.testing.expectEqualStrings("example__demo-1.0.0-esm-cnako+wnako.npkg", try defaultOutputName(
        a,
        "@example/demo",
        "1.0.0",
        .esm,
        &.{ "wnako", "cnako" },
        null,
        null,
    ));
    try std.testing.expectEqualStrings("example__demo-1.0.0-native-source.npkg", try defaultOutputName(
        a,
        "@example/demo",
        "1.0.0",
        .native_source,
        &.{},
        null,
        null,
    ));
    try std.testing.expectEqualStrings("example__demo-1.0.0-native-x86_64-linux-gnu-abi1.npkg", try defaultOutputName(
        a,
        "@example/demo",
        "1.0.0",
        .native_prebuilt,
        &.{},
        "x86_64-linux-gnu",
        1,
    ));
}

test "v1 CLI: アーカイブ内パスの検証" {
    try std.testing.expect(validArchivePath("src/main.nako3"));
    try std.testing.expect(validArchivePath("dist/esm/index.js"));
    try std.testing.expect(!validArchivePath("../evil"));
    try std.testing.expect(!validArchivePath("/abs"));
    try std.testing.expect(!validArchivePath("a//b"));
    try std.testing.expect(!validArchivePath("a\\b"));
    try std.testing.expect(!validArchivePath("C:/x"));
    try std.testing.expect(isGnuLinux("x86_64-linux-gnu"));
    try std.testing.expect(!isGnuLinux("x86_64-linux-musl"));
}

/// 旧 static PUT を v1 の公開経路に使わないことの案内（§5・O02）。
pub const publish_out_of_scope_message =
    \\package publish: v1 仕様では旧 static PUT による公開は対象外です。
    \\  公開は P07 の POST /v1/packages/{scope}/{name}/releases（GitHub OIDC 認証）で行います。
    \\  手元では `lnako package build`（全 kind を `--kind` で指定）と
    \\  `lnako package verify <file.npkg>...` で .npkg を検証してください。
    \\
;

test "v1 CLI: help は検証より先に返す" {
    var arena_impl = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    var build_err = std.Io.Writer.Allocating.init(a);
    const build_args = try parseBuildArgs(a, &.{ "--help", "--kind", "native-prebuilt" }, &build_err.writer);
    try std.testing.expect(build_args.help);

    var verify_err = std.Io.Writer.Allocating.init(a);
    const verify_args = try parseVerifyArgs(a, &.{"--help"}, &verify_err.writer);
    try std.testing.expect(verify_args.help);
    try std.testing.expectEqual(@as(usize, 0), verify_args.files.len);
}

test "v1 CLI: 旧 static PUT は対象外として代替手順を示す" {
    try std.testing.expect(std.mem.indexOf(u8, publish_out_of_scope_message, "対象外") != null);
    try std.testing.expect(std.mem.indexOf(u8, publish_out_of_scope_message, "POST /v1/packages/{scope}/{name}/releases") != null);
    try std.testing.expect(std.mem.indexOf(u8, publish_out_of_scope_message, "package verify") != null);
}
