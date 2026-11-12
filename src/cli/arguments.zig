const std = @import("std");
const builtin = @import("builtin");
const lnako = @import("lnako");

pub const BuildBackend = enum { aot, embedded };

pub const BuildOptions = struct {
    input: []const u8,
    output: []const u8,
    optimization: lnako.backend.llvm.compiler.Optimization = .o0,
    emit: lnako.backend.llvm.compiler.Emit = .executable,
    compat_js: bool = false,
    /// `--compat-js` の実行方式。未指定なら従来の同梱実行ファイル方式
    /// （embedded）。LLVM AOT＋QuickJS runtime は `--backend aot` の明示opt-in。
    backend: ?BuildBackend = null,
    forced_mode: lnako.frontend.token.Mode = .{},
    llvm_dir: ?[]const u8 = null,
    /// `--compat-js --backend aot` 生成物へ同梱した package の license 一覧
    /// （SPDX 2.3 JSON）の出力先。Issue #56。
    sbom: ?[]const u8 = null,
    /// 依存 package を `<out>.deps/` payload へ同梱する。通常 AOT でも
    /// 使用可。`.nako3` 依存（source-only / native plugin 含む）の license
    /// と file 一覧を SBOM へ載せるため、`--sbom` との併用を許す。
    bundle_deps: bool = false,
};

pub fn parseBuildOptions(arguments: []const []const u8) !BuildOptions {
    if (arguments.len == 0) return error.MissingInput;
    var output: ?[]const u8 = null;
    var optimization: lnako.backend.llvm.compiler.Optimization = .o0;
    var emit: lnako.backend.llvm.compiler.Emit = .executable;
    var compat_js = false;
    var backend: ?BuildBackend = null;
    var forced_mode: lnako.frontend.token.Mode = .{};
    var llvm_dir: ?[]const u8 = null;
    var sbom: ?[]const u8 = null;
    var bundle_deps = false;
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "-o")) {
            index += 1;
            if (index >= arguments.len) return error.MissingOutput;
            output = arguments[index];
        } else if (std.mem.eql(u8, argument, "-O0")) {
            optimization = .o0;
        } else if (std.mem.eql(u8, argument, "-O1")) {
            optimization = .o1;
        } else if (std.mem.eql(u8, argument, "-O2")) {
            optimization = .o2;
        } else if (std.mem.eql(u8, argument, "-O3")) {
            optimization = .o3;
        } else if (std.mem.eql(u8, argument, "--compat-js")) {
            compat_js = true;
        } else if (std.mem.eql(u8, argument, "--backend")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBackend;
            backend = if (std.mem.eql(u8, arguments[index], "aot"))
                .aot
            else if (std.mem.eql(u8, arguments[index], "embedded"))
                .embedded
            else
                return error.InvalidBackend;
        } else if (std.mem.eql(u8, argument, "--dncl")) {
            forced_mode.dncl = true;
        } else if (std.mem.eql(u8, argument, "--dncl2")) {
            forced_mode.dncl2 = true;
        } else if (std.mem.eql(u8, argument, "--llvm-dir")) {
            index += 1;
            if (index >= arguments.len) return error.MissingLlvmDir;
            llvm_dir = arguments[index];
        } else if (std.mem.eql(u8, argument, "--sbom")) {
            index += 1;
            if (index >= arguments.len) return error.MissingSbomPath;
            sbom = arguments[index];
        } else if (std.mem.eql(u8, argument, "--bundle-deps")) {
            bundle_deps = true;
        } else if (std.mem.eql(u8, argument, "--emit")) {
            index += 1;
            if (index >= arguments.len) return error.MissingEmitKind;
            emit = if (std.mem.eql(u8, arguments[index], "exe"))
                .executable
            else if (std.mem.eql(u8, arguments[index], "obj"))
                .object
            else if (std.mem.eql(u8, arguments[index], "llvm-ir"))
                .llvm_ir
            else
                return error.InvalidEmitKind;
        } else return error.UnknownBuildOption;
    }
    if (forced_mode.dncl and forced_mode.dncl2) return error.ConflictingDnclModes;
    return .{
        .input = arguments[0],
        .output = output orelse return error.MissingOutput,
        .optimization = optimization,
        .emit = emit,
        .compat_js = compat_js,
        .backend = backend,
        .forced_mode = forced_mode,
        .llvm_dir = llvm_dir,
        .sbom = sbom,
        .bundle_deps = bundle_deps,
    };
}

/// `--sbom` の出力先が、生成物・入力 source と同じファイルを指さないかを
/// 判定する。相対 path は cwd 基準で絶対化し、実在する path は実体 path へ
/// 解決する。生成前で file が無い場合も親 directory の実体 path + basename で
/// 比較する（symlink 経由の同一 file を lexical 比較で見逃さない）。
pub fn sameDestination(allocator: std.mem.Allocator, io: std.Io, left: []const u8, right: []const u8) !bool {
    const left_absolute = try absoluteForComparison(allocator, io, left);
    defer allocator.free(left_absolute);
    const right_absolute = try absoluteForComparison(allocator, io, right);
    defer allocator.free(right_absolute);
    if (std.mem.eql(u8, left_absolute, right_absolute)) return true;
    // 既存 file は path に加えてファイル識別子でも比較する。hardlink は
    // 異なる path でも同じ file を指すため、path 比較だけでは --sbom が
    // 入力や生成物を切り詰める指定を見逃す。
    if (sameFileIdentity(io, left_absolute, right_absolute)) return true;
    // case-insensitive な FS（Windows、macOS の既定 APFS）では、まだ存在
    // しない出力先の大小文字違いを実体 path で区別できない。親 directory が
    // 同一で basename だけが大小文字で異なる場合は同じ file とみなす
    // （同一親で case-sensitive な別 file を意図した場合も明示エラーになるが、
    // 生成物の破壊より安全側に倒す）。
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) {
        const left_parent = std.fs.path.dirname(left_absolute) orelse "";
        const right_parent = std.fs.path.dirname(right_absolute) orelse "";
        if (std.mem.eql(u8, left_parent, right_parent)) {
            return std.ascii.eqlIgnoreCase(std.fs.path.basename(left_absolute), std.fs.path.basename(right_absolute));
        }
    }
    return false;
}

/// 2 つの path が同じ file を指すか（hardlink 検出）。file 識別子は
/// `Stat.inode`（POSIX は inode、Windows は FileIndex）を使う。どちらかが
/// 存在しない・stat できない場合は「同一でない」として false を返し、
/// 呼出し側は path 比較の結果を維持する。
fn sameFileIdentity(io: std.Io, left: []const u8, right: []const u8) bool {
    const left_stat = std.Io.Dir.cwd().statFile(io, left, .{}) catch return false;
    const right_stat = std.Io.Dir.cwd().statFile(io, right, .{}) catch return false;
    if (left_stat.kind != .file or right_stat.kind != .file) return false;
    return left_stat.inode == right_stat.inode;
}

/// symlink を辿る上限。循環 link で無限再帰しないための固定値。
const max_symlink_depth: usize = 8;

fn absoluteForComparison(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return absoluteForComparisonDepth(allocator, io, path, 0);
}

fn absoluteForComparisonDepth(allocator: std.mem.Allocator, io: std.Io, path: []const u8, depth: usize) ![]u8 {
    // 実在する file/dir は realpath が symlink を解決する。
    // realPathFileAlloc は sentinel slice を返すため、通常 slice として返すと
    // 解放長が 1 ずれる。dupe してから sentinel 側を解放する。
    if (std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator)) |resolved| {
        defer allocator.free(resolved);
        return allocator.dupe(u8, resolved);
    } else |_| {}
    const normalized = try absoluteLexical(allocator, io, path);
    // 生成前の出力先でも leaf が symlink なら target を解決する（dangling
    // symlink は realPathFileAlloc では解決できない）。
    if (depth < max_symlink_depth) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        if (std.Io.Dir.cwd().readLink(io, normalized, &buffer)) |length| {
            const target = buffer[0..length];
            const target_absolute = if (std.fs.path.isAbsolute(target))
                try allocator.dupe(u8, target)
            else blk: {
                const parent = std.fs.path.dirname(normalized) orelse ".";
                break :blk try std.fs.path.join(allocator, &.{ parent, target });
            };
            defer allocator.free(target_absolute);
            allocator.free(normalized);
            return absoluteForComparisonDepth(allocator, io, target_absolute, depth + 1);
        } else |_| {}
    }
    // 親 directory の実体 path + basename で比較する。basename は
    // normalized への slice なので、join が終わるまで解放しない。
    const parent = std.fs.path.dirname(normalized) orelse return normalized;
    const basename = std.fs.path.basename(normalized);
    const real_parent = std.Io.Dir.cwd().realPathFileAlloc(io, parent, allocator) catch return normalized;
    defer allocator.free(real_parent);
    const combined = try std.fs.path.join(allocator, &.{ real_parent, basename });
    allocator.free(normalized);
    return combined;
}

/// 相対 path は cwd 基準で絶対化し、`.`/`..` を正規化する（symlink は見ない）。
fn absoluteLexical(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    // 絶対 path は cwd に依存しないため取得しない。
    if (std.fs.path.isAbsolute(path)) return std.fs.path.resolve(allocator, &.{path});
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const joined = try std.fs.path.join(allocator, &.{ cwd, path });
    defer allocator.free(joined);
    return std.fs.path.resolve(allocator, &.{joined});
}

/// `--dncl`/`--dncl2` フラグから強制する構文モードを得る。
/// 両方の指定は異なる方言の同時強制になるためエラーにする。
pub fn dnclModeFromArguments(arguments: []const []const u8) error{ConflictingDnclModes}!lnako.frontend.token.Mode {
    var mode: lnako.frontend.token.Mode = .{};
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "--dncl")) mode.dncl = true;
        if (std.mem.eql(u8, argument, "--dncl2")) mode.dncl2 = true;
    }
    if (mode.dncl and mode.dncl2) return error.ConflictingDnclModes;
    return mode;
}

/// lnako側オプションのうち許可リストに無い最初の引数を返す。
/// `--dncl`のtypo（--dncll等）や余分な位置引数が黙って無視されないよう、
/// 受理するオプションをコマンドごとに限定する。全て許可済みならnull。
pub fn findUnknownOption(arguments: []const []const u8, allowed: []const []const u8) ?[]const u8 {
    for (arguments) |argument| {
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, argument, name)) {
                known = true;
                break;
            }
        }
        if (!known) return argument;
    }
    return null;
}

/// `-`で始まる不明なオプションのみを検出する。位置引数は対象外。
/// `run`では`--`を省略した位置引数が事実上プログラム引数として
/// `process_args`経由で参照される既存契約があるため、位置引数は拒否せず
/// `--dncll`のようなオプション記法の誤りだけを診断する。
pub fn findUnknownFlag(arguments: []const []const u8, allowed: []const []const u8) ?[]const u8 {
    for (arguments) |argument| {
        if (!std.mem.startsWith(u8, argument, "-")) continue;
        var known = false;
        for (allowed) |name| {
            if (std.mem.eql(u8, argument, name)) {
                known = true;
                break;
            }
        }
        if (!known) return argument;
    }
    return null;
}

pub fn hasArgument(arguments: []const []const u8, expected: []const u8) bool {
    for (arguments) |argument| if (std.mem.eql(u8, argument, expected)) return true;
    return false;
}

pub fn splitRunArguments(arguments: []const []const u8) struct { lnako: []const []const u8, program: []const []const u8 } {
    for (arguments, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, "--")) {
            return .{ .lnako = arguments[0..index], .program = arguments[index + 1 ..] };
        }
    }
    return .{ .lnako = arguments, .program = &[_][]const u8{} };
}

pub fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

test "不明なオプションを検出する" {
    const dncl_options: []const []const u8 = &.{ "--dncl", "--dncl2" };
    // --dncl のtypoは検出される
    try std.testing.expectEqualStrings("--dncll", findUnknownOption(&.{"--dncll"}, dncl_options).?);
    try std.testing.expectEqualStrings("--strict", findUnknownOption(&.{ "--dncl", "--strict" }, dncl_options).?);
    // 余分な位置引数も検出される
    try std.testing.expectEqualStrings("extra.nako3", findUnknownOption(&.{"extra.nako3"}, dncl_options).?);
    // 許可済みオプションはnull
    try std.testing.expectEqual(@as(?[]const u8, null), findUnknownOption(&.{ "--dncl", "--dncl2" }, dncl_options));
    try std.testing.expectEqual(@as(?[]const u8, null), findUnknownOption(&.{}, dncl_options));
    // run用の許可リストでは--compat-jsも受理される
    const run_options: []const []const u8 = &.{ "--compat-js", "--dncl", "--dncl2" };
    try std.testing.expectEqual(@as(?[]const u8, null), findUnknownOption(&.{ "--compat-js", "--dncl" }, run_options));
    try std.testing.expectEqualStrings("--dncll", findUnknownOption(&.{"--dncll"}, run_options).?);
    // findUnknownFlagは位置引数をプログラム引数として許容し、`-`始まりの
    // 未知オプションのみ検出する（runの`--`省略形の既存契約）
    try std.testing.expectEqual(@as(?[]const u8, null), findUnknownFlag(&.{ "12345", "--compat-js" }, run_options));
    try std.testing.expectEqual(@as(?[]const u8, null), findUnknownFlag(&.{"benchmark-input.txt"}, run_options));
    try std.testing.expectEqualStrings("--dncll", findUnknownFlag(&.{"--dncll"}, run_options).?);
}

test "buildの出力形式と最適化レベルを解析する" {
    const options = try parseBuildOptions(&.{ "main.nako3", "-o", "main", "-O3", "--emit", "obj" });
    try std.testing.expectEqualStrings("main.nako3", options.input);
    try std.testing.expectEqualStrings("main", options.output);
    try std.testing.expectEqual(lnako.backend.llvm.compiler.Optimization.o3, options.optimization);
    try std.testing.expectEqual(lnako.backend.llvm.compiler.Emit.object, options.emit);
    try std.testing.expectError(error.MissingOutput, parseBuildOptions(&.{"main.nako3"}));
    try std.testing.expectError(error.InvalidEmitKind, parseBuildOptions(&.{ "main.nako3", "-o", "main", "--emit", "asm" }));
}

test "--sbomの出力先が生成物・入力と同じfileかを実体pathで判定する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const absolute_app = try std.fs.path.join(allocator, &.{ cwd, "ghost", "app" });
    defer allocator.free(absolute_app);
    const absolute_other = try std.fs.path.join(allocator, &.{ cwd, "ghost", "other" });
    defer allocator.free(absolute_other);

    // 絶対 path 同士の同一判定。
    try std.testing.expect(try sameDestination(allocator, io, absolute_app, absolute_app));
    // 相対 path は cwd 基準で絶対化し、`.`/`..` を正規化して比較する。
    try std.testing.expect(try sameDestination(allocator, io, absolute_app, "ghost/../ghost/app"));
    // basename だけの比較にしない（別 directory の同名 file は別）。
    try std.testing.expect(!try sameDestination(allocator, io, absolute_app, absolute_other));
    try std.testing.expect(!try sameDestination(allocator, io, absolute_app, "ghost/other"));
    try std.testing.expect(!try sameDestination(allocator, io, absolute_app, "app"));

    // case-insensitive FS では未作成 file の大小文字違いも同一とみなす
    // （macOS/Windows のみ。Linux は別 file として許可する）。
    const case_variant = try sameDestination(allocator, io, absolute_app, "ghost/APP");
    if (builtin.os.tag == .windows or builtin.os.tag == .macos) {
        try std.testing.expect(case_variant);
    } else {
        try std.testing.expect(!case_variant);
    }

    // symlink 経由の同一 file も実体 path で判定する（dangling を含む）。
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "app", .data = "bin" });
    try temporary.dir.symLink(io, "app", "alias", .{});
    try temporary.dir.symLink(io, "future-app", "dangling", .{});
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const real_app = try std.fs.path.join(allocator, &.{ root, "app" });
    defer allocator.free(real_app);
    const real_alias = try std.fs.path.join(allocator, &.{ root, "alias" });
    defer allocator.free(real_alias);
    const real_dangling = try std.fs.path.join(allocator, &.{ root, "dangling" });
    defer allocator.free(real_dangling);
    const future_app = try std.fs.path.join(allocator, &.{ root, "future-app" });
    defer allocator.free(future_app);
    try std.testing.expect(try sameDestination(allocator, io, real_app, real_alias));
    try std.testing.expect(try sameDestination(allocator, io, future_app, real_dangling));

    // 親 directory は実在し対象 file だけが未作成の場合は、親の実体 path と
    // basename で比較する（basename は解放済み buffer を参照しない）。
    const missing_a = try std.fs.path.join(allocator, &.{ root, "future-a" });
    defer allocator.free(missing_a);
    const missing_b = try std.fs.path.join(allocator, &.{ root, "future-b" });
    defer allocator.free(missing_b);
    try std.testing.expect(!try sameDestination(allocator, io, missing_a, missing_b));
    try std.testing.expect(try sameDestination(allocator, io, missing_a, missing_a));
    const missing_dot = try std.fs.path.join(allocator, &.{ root, ".", "future-a" });
    defer allocator.free(missing_dot);
    try std.testing.expect(try sameDestination(allocator, io, missing_a, missing_dot));

    // hardlink は別 path でも同じ file として扱う（--sbom が入力/生成物を
    // 切り詰める指定を拒否する）。Windows の Threaded Io は hardLink を
    // OperationUnsupported で拒否するため、この経路は POSIX でだけ検証する。
    if (builtin.os.tag != .windows) {
        try temporary.dir.writeFile(io, .{ .sub_path = "source.nako3", .data = "値=1\n" });
        try std.Io.Dir.hardLink(temporary.dir, "source.nako3", temporary.dir, "link.nako3", io, .{});
        const source_path = try std.fs.path.join(allocator, &.{ root, "source.nako3" });
        defer allocator.free(source_path);
        const link_path = try std.fs.path.join(allocator, &.{ root, "link.nako3" });
        defer allocator.free(link_path);
        try std.testing.expect(try sameDestination(allocator, io, source_path, link_path));
    }
}

test "buildの--sbom出力先を解析する" {
    const options = try parseBuildOptions(&.{ "main.nako3", "-o", "main", "--compat-js", "--backend", "aot", "--sbom", "main.spdx.json" });
    try std.testing.expectEqualStrings("main.spdx.json", options.sbom.?);
    // --sbom 無指定は null（従来どおり SBOM を作らない）。
    const without = try parseBuildOptions(&.{ "main.nako3", "-o", "main", "--compat-js", "--backend", "aot" });
    try std.testing.expect(without.sbom == null);
    try std.testing.expectError(error.MissingSbomPath, parseBuildOptions(&.{ "main.nako3", "-o", "main", "--compat-js", "--backend", "aot", "--sbom" }));
}

test "buildのcompat-js backendを解析する" {
    // 既定はembedded（従来方式）。AOT+QuickJSは --backend aot の明示opt-in。
    const defaults = try parseBuildOptions(&.{ "main.nako3", "-o", "main", "--compat-js" });
    try std.testing.expect(defaults.compat_js);
    try std.testing.expectEqual(@as(?BuildBackend, null), defaults.backend);
    const aot = try parseBuildOptions(&.{ "main.nako3", "-o", "main", "--compat-js", "--backend", "aot" });
    try std.testing.expectEqual(@as(?BuildBackend, .aot), aot.backend);
    const embedded = try parseBuildOptions(&.{ "main.nako3", "-o", "main", "--compat-js", "--backend", "embedded" });
    try std.testing.expectEqual(@as(?BuildBackend, .embedded), embedded.backend);
    try std.testing.expectError(error.InvalidBackend, parseBuildOptions(&.{ "main.nako3", "-o", "main", "--backend", "vm" }));
    try std.testing.expectError(error.MissingBackend, parseBuildOptions(&.{ "main.nako3", "-o", "main", "--backend" }));
}
