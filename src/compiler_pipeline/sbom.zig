//! compat AOT 生成物へ同梱した npm/ESM package の license 一覧を SPDX 2.3
//! 形式の JSON として出力する（Issue #56）。
//!
//! `--compat-js --backend aot` の生成物は module source を ESM manifest から
//! 実行するため、project 外 cwd でも `.nako`/cache 無しで動作する。その
//! 同梱物の license を追跡できるよう、build 時に package 単位の記録
//! （`ir.Program.bundled_packages`）から SBOM を生成する。
//!
//! 出力は決定的（並び順を固定し、`created` は配布 SBOM と同じ固定値）で、
//! 同じ入力からは同じ bytes になる。`documentNamespace` は package 一覧の
//!  digest から作るため、内容が変われば namespace も変わる。
const std = @import("std");
const lnako = @import("lnako");
const bundled = @import("bundled.zig");

const unknown_license = bundled.unknown_license;

const max_license_file_bytes: usize = 1024 * 1024;

/// 配布 SBOM（tools/create_distribution.mjs）と同じ固定の creation date。
/// SBOM を再現可能にするため現在時刻を使わない。
const created_at = "1970-01-01T00:00:00Z";

const document_comment =
    \\This SBOM describes the npm/ESM package sources bundled into a compat AOT artifact built with `--compat-js --backend aot`.
    \\Bundled modules are executed from the artifact's ESM manifest, so the artifact does not read the project's `.nako` environment or npm cache at run time.
    \\Packages without a declared license in package.json/nako.toml are reported as NOASSERTION.
;

pub const Checksum = struct { algorithm: []const u8 = "SHA256", checksumValue: []const u8 };

pub const ExternalRef = struct {
    referenceCategory: []const u8 = "PACKAGE-MANAGER",
    referenceType: []const u8 = "purl",
    referenceLocator: []const u8,
};

pub const Package = struct {
    SPDXID: []const u8,
    name: []const u8,
    versionInfo: []const u8,
    downloadLocation: []const u8 = "NOASSERTION",
    filesAnalyzed: bool = false,
    licenseConcluded: []const u8,
    licenseDeclared: []const u8,
    copyrightText: []const u8 = "NOASSERTION",
    /// 宣言 license を SPDX 表現へ正規化した場合の元の値（追跡用）。
    comment: ?[]const u8 = null,
    externalRefs: ?[]const ExternalRef = null,
};

pub const File = struct {
    SPDXID: []const u8,
    fileName: []const u8,
    checksums: []const Checksum,
    licenseConcluded: []const u8 = "NOASSERTION",
    copyrightText: []const u8 = "NOASSERTION",
};

pub const Relationship = struct {
    spdxElementId: []const u8,
    relationshipType: []const u8,
    relatedSpdxElement: []const u8,
};

pub const CreationInfo = struct {
    created: []const u8 = created_at,
    creators: []const []const u8 = &.{"Tool: lnako"},
};

pub const Document = struct {
    spdxVersion: []const u8 = "SPDX-2.3",
    dataLicense: []const u8 = "CC0-1.0",
    SPDXID: []const u8 = "SPDXRef-DOCUMENT",
    name: []const u8,
    documentNamespace: []const u8,
    creationInfo: CreationInfo,
    documentComment: []const u8 = document_comment,
    packages: []const Package,
    files: []const File = &.{},
    relationships: []const Relationship,
};

/// `program.bundled_packages` から SBOM の JSON bytes を生成する。
/// `artifact_path` は `DESCRIBES` 対象の表示名にだけ使う（読み取りはしない）。
pub fn render(allocator: std.mem.Allocator, io: std.Io, program: *const lnako.ir.nako_ir.Program, artifact_path: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();

    const sorted = try temporary.dupe(lnako.ir.nako_ir.BundledPackage, program.bundled_packages);
    std.mem.sort(lnako.ir.nako_ir.BundledPackage, sorted, {}, lessThanBundledPackage);

    var packages: std.ArrayListUnmanaged(Package) = .empty;
    var files: std.ArrayListUnmanaged(File) = .empty;
    var relationships: std.ArrayListUnmanaged(Relationship) = .empty;
    for (sorted, 0..) |item, index| {
        const suffix = try std.fmt.allocPrint(temporary, "{d}", .{index + 1});
        const spdx_id = try std.fmt.allocPrint(temporary, "SPDXRef-Package-{s}-{s}", .{ @tagName(item.kind), suffix });
        const external_refs: ?[]const ExternalRef = if (item.name.len == 0 or item.version.len == 0)
            null
        else
            try temporary.dupe(ExternalRef, &.{.{ .referenceLocator = try purl(temporary, item) }});
        // license file を先に走査し、file record を持つ package だけ
        // `filesAnalyzed=true` にする（SPDX 2.3 で false は file 情報を
        // 含まない意味になる）。
        const file_start = files.items.len;
        try collectLicenseFiles(temporary, io, item, spdx_id, &files, &relationships);
        const license = try spdxLicense(temporary, item.license);
        try packages.append(temporary, .{
            .SPDXID = spdx_id,
            .name = if (item.name.len == 0) "unknown" else item.name,
            .versionInfo = if (item.version.len == 0) "NOASSERTION" else item.version,
            .filesAnalyzed = files.items.len > file_start,
            // 同梱 source の解析は行わないため、宣言値を「確認済みの結論」と
            // して出さない（SPDX 2.3 では NOASSERTION が未解析を表す）。
            .licenseConcluded = unknown_license,
            .licenseDeclared = license.value,
            .comment = license.comment,
            .externalRefs = external_refs,
        });
        try relationships.append(temporary, .{
            .spdxElementId = "SPDXRef-DOCUMENT",
            .relationshipType = "DESCRIBES",
            .relatedSpdxElement = spdx_id,
        });
    }

    // namespace は package と license file の一覧の digest から作る
    // （同じ入力 = 同じ値。license の bytes が変われば namespace も変わる）。
    const artifact_name = std.fs.path.basename(artifact_path);
    var digest: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    // 同じ依存でも出力名（文書名）が違えば別文書なので namespace も変える。
    hasher.update(artifact_name);
    hasher.update("\x00");
    for (sorted) |item| {
        hasher.update(item.name);
        hasher.update("\x00");
        hasher.update(item.version);
        hasher.update("\x00");
        hasher.update(item.license);
        hasher.update("\x00");
        hasher.update(@tagName(item.kind));
        hasher.update("\x00");
        // 同梱 module の集合が違えば namespace も変える。
        for (item.entries) |entry| {
            hasher.update(entry);
            hasher.update("\x00");
        }
        hasher.update("\x01");
    }
    hasher.update("files\x00");
    for (files.items) |item| {
        hasher.update(item.fileName);
        hasher.update("\x00");
        hasher.update(item.checksums[0].checksumValue);
        hasher.update("\x00");
    }
    hasher.final(&digest);
    const digest_hex = std.fmt.bytesToHex(digest, .lower);

    const document = Document{
        .name = try std.fmt.allocPrint(temporary, "compat-aot-bundled-{s}", .{artifact_name}),
        .documentNamespace = try std.fmt.allocPrint(temporary, "https://github.com/soramikan/lnako/spdx/compat-aot/{s}", .{digest_hex}),
        .creationInfo = .{},
        .packages = packages.items,
        .files = files.items,
        .relationships = relationships.items,
    };
    return std.json.Stringify.valueAlloc(allocator, document, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
}

/// 生成した SBOM を `output_path` へ書き出す。親 directory は作らない
/// （CLI の出力同様、存在しない path は失敗させる）。
pub fn write(allocator: std.mem.Allocator, io: std.Io, output_path: []const u8, program: *const lnako.ir.nako_ir.Program, artifact_path: []const u8) !void {
    const bytes = try render(allocator, io, program, artifact_path);
    defer allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = bytes });
}

fn collectLicenseFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    item: lnako.ir.nako_ir.BundledPackage,
    package_spdx_id: []const u8,
    files: *std.ArrayListUnmanaged(File),
    relationships: *std.ArrayListUnmanaged(Relationship),
) !void {
    // license file の走査は best-effort。root が無い/読めない場合は
    // package を package.json の宣言だけで記録する（SBOM 生成は止めない）。
    var directory = std.Io.Dir.cwd().openDir(io, item.root, .{ .iterate = true, .follow_symlinks = true }) catch return;
    defer directory.close(io);
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer allocator.free(names.items);
    var iterator = directory.iterate();
    // license file の走査は best-effort（読めない directory/entry は SBOM 生成を
    // 止めず、package を宣言 license だけで記録する）。
    while (true) {
        const maybe_entry = iterator.next(io) catch break;
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;
        if (!isLicenseFileName(entry.name)) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    defer for (names.items) |name| allocator.free(name);
    std.mem.sort([]const u8, names.items, {}, lessThanString);
    var license_index: usize = 0;
    for (names.items) |name| {
        const bytes = directory.readFileAlloc(io, name, allocator, .limited(max_license_file_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer allocator.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const checksum_hex = std.fmt.bytesToHex(digest, .lower);
        const checksum = try allocator.dupe(u8, &checksum_hex);
        license_index += 1;
        // SPDX ID は `[A-Za-z0-9.-]+` のみ。file 名を連結せず連番にする
        // （`LICENSE (MIT)` のような名前でも ID を壊さない）。
        const file_spdx_id = try std.fmt.allocPrint(allocator, "{s}-file-{d}", .{ package_spdx_id, license_index });
        const file_name = try std.fmt.allocPrint(allocator, "{s}@{s}/{s}", .{
            if (item.name.len == 0) "unknown" else item.name,
            if (item.version.len == 0) "unknown" else item.version,
            name,
        });
        try files.append(allocator, .{
            .SPDXID = file_spdx_id,
            .fileName = file_name,
            .checksums = try allocator.dupe(Checksum, &.{.{ .checksumValue = checksum }}),
        });
        try relationships.append(allocator, .{
            .spdxElementId = package_spdx_id,
            .relationshipType = "CONTAINS",
            .relatedSpdxElement = file_spdx_id,
        });
    }
}

/// package の purl。scoped npm 名の `@` は purl 仕様に合わせて `%40` にする
/// （`pkg:npm/%40scope/name@1.0.0`）。
fn purl(allocator: std.mem.Allocator, item: lnako.ir.nako_ir.BundledPackage) ![]u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buffer.deinit(allocator);
    try buffer.appendSlice(allocator, "pkg:");
    try buffer.appendSlice(allocator, @tagName(item.kind));
    try buffer.append(allocator, '/');
    // name は `/` 区切りの component ごとに percent-encode する
    // （scoped npm の `@scope/name` は `%40scope/name` になる）。
    var name_it = std.mem.splitScalar(u8, item.name, '/');
    var first = true;
    while (name_it.next()) |component| {
        if (!first) try buffer.append(allocator, '/');
        first = false;
        try appendPercentEncoded(allocator, &buffer, component);
    }
    try buffer.append(allocator, '@');
    try appendPercentEncoded(allocator, &buffer, item.version);
    return buffer.toOwnedSlice(allocator);
}

/// purl の unreserved 以外を `%XX` へ encode する。
fn appendPercentEncoded(allocator: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (text) |byte| {
        const unreserved = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~';
        if (unreserved) {
            try buffer.append(allocator, byte);
            continue;
        }
        try buffer.append(allocator, '%');
        try buffer.append(allocator, hex[byte >> 4]);
        try buffer.append(allocator, hex[byte & 0x0f]);
    }
}

/// 宣言 license を SPDX 2.3 の license expression として使える形へ正規化する。
/// SPDX は有効な式 / `NONE` / `NOASSERTION` / `LicenseRef-...` しか許さないため、
/// npm 慣用の `UNLICENSED` や `MIT/X11`、`(MIT)` のような表記はそのまま出さない。
/// 正規化した場合は元の宣言を `comment` に残す（追跡性を落とさない）。
const LicenseField = struct { value: []const u8, comment: ?[]const u8 };

/// 宣言 license を SPDX 2.3 の `licenseDeclared` に使える形へ正規化する。
/// 解析は行わないため、SPDX の式として解釈できない宣言は推測せず
/// `NOASSERTION` にし、元の宣言を `comment` に残す（`LicenseRef-...` は
/// 対応する抽出ライセンス情報が必須なので、定義を出せないここでは使わない）。
fn spdxLicense(allocator: std.mem.Allocator, declared: []const u8) !LicenseField {
    if (declared.len == 0) return .{ .value = unknown_license, .comment = null };
    if (std.ascii.eqlIgnoreCase(declared, "NOASSERTION")) return .{ .value = unknown_license, .comment = null };
    if (std.ascii.eqlIgnoreCase(declared, "NONE")) return .{ .value = "NONE", .comment = null };
    // npm の `UNLICENSED` は「ライセンスを付与しない」宣言なので NONE が対応する。
    if (std.ascii.eqlIgnoreCase(declared, "UNLICENSED")) {
        return .{ .value = "NONE", .comment = try commentFor(allocator, declared) };
    }
    if (isSpdxExpression(declared)) return .{ .value = declared, .comment = null };
    return .{ .value = unknown_license, .comment = try commentFor(allocator, declared) };
}

fn commentFor(allocator: std.mem.Allocator, declared: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "declared license: {s}", .{declared});
}

/// SPDX license expression の判定。Annex D の文法に沿って
/// `primary (AND|OR primary)*`、`primary = "(" expr ")" | id ["+"] ["WITH" id]`
/// を再帰下降で検査する。ライセンス ID 一覧との照合は行わない（宣言値の
/// 構文妥当性だけを見る）。
fn isSpdxExpression(declared: []const u8) bool {
    var tokens: [64][]const u8 = undefined;
    var count: usize = 0;
    var index: usize = 0;
    while (index < declared.len) {
        const byte = declared[index];
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') {
            index += 1;
            continue;
        }
        if (count >= tokens.len) return false;
        if (byte == '(' or byte == ')') {
            tokens[count] = declared[index .. index + 1];
            count += 1;
            index += 1;
            continue;
        }
        const start = index;
        while (index < declared.len) : (index += 1) {
            const current = declared[index];
            if (current == ' ' or current == '\t' or current == '\r' or current == '\n' or current == '(' or current == ')') break;
        }
        tokens[count] = declared[start..index];
        count += 1;
    }
    if (count == 0) return false;
    var parser = ExpressionParser{ .tokens = tokens[0..count] };
    return parser.parseExpression() and parser.index == count;
}

const ExpressionParser = struct {
    tokens: []const []const u8,
    index: usize = 0,

    fn peek(self: *const ExpressionParser) ?[]const u8 {
        return if (self.index < self.tokens.len) self.tokens[self.index] else null;
    }

    fn parseExpression(self: *ExpressionParser) bool {
        if (!self.parsePrimary()) return false;
        while (self.peek()) |token| {
            if (!isBinaryOperator(token)) break;
            self.index += 1;
            if (!self.parsePrimary()) return false;
        }
        return true;
    }

    fn parsePrimary(self: *ExpressionParser) bool {
        const token = self.peek() orelse return false;
        if (std.mem.eql(u8, token, "(")) {
            self.index += 1;
            if (!self.parseExpression()) return false;
            const closing = self.peek() orelse return false;
            if (!std.mem.eql(u8, closing, ")")) return false;
            self.index += 1;
            return true;
        }
        if (!isSpdxIdentifier(token)) return false;
        self.index += 1;
        if (self.peek()) |next| {
            if (std.mem.eql(u8, next, "WITH")) {
                self.index += 1;
                const exception = self.peek() orelse return false;
                if (!isSpdxIdentifier(exception)) return false;
                self.index += 1;
            }
        }
        return true;
    }
};

fn isBinaryOperator(token: []const u8) bool {
    return std.mem.eql(u8, token, "AND") or std.mem.eql(u8, token, "OR");
}

/// SPDX の `idstring`（LicenseRef を含む）。`+` は末尾の 1 個だけ許可する。
/// 演算子や未対応の表記（空白区切りの語、全角、`/` 等）は識別子ではない。
fn isSpdxIdentifier(token: []const u8) bool {
    if (std.mem.eql(u8, token, "AND") or std.mem.eql(u8, token, "OR") or std.mem.eql(u8, token, "WITH")) return false;
    var core = token;
    if (std.mem.endsWith(u8, core, "+")) {
        core = core[0 .. core.len - 1];
        if (std.mem.endsWith(u8, core, "+")) return false;
    }
    if (core.len == 0 or !std.ascii.isAlphanumeric(core[0])) return false;
    for (core[1..]) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-') continue;
        return false;
    }
    return true;
}

/// `LICENSE` / `LICENSE-MIT` / `COPYING` / `NOTICE` 等を license 関連 file と
/// みなす（大文字小文字を無視。拡張子は問わない）。
fn isLicenseFileName(name: []const u8) bool {
    const prefixes = [_][]const u8{ "license", "licence", "copying", "notice", "unlicense" };
    const code_extensions = [_][]const u8{
        "js", "mjs", "cjs", "ts", "tsx", "jsx", "json", "py", "rb", "go", "rs", "zig", "c", "h", "cpp", "hpp", "java", "sh", "yml", "yaml", "toml",
    };
    for (prefixes) |prefix| {
        if (name.len < prefix.len) continue;
        var matches = true;
        for (prefix, name[0..prefix.len]) |expected, actual| {
            if (std.ascii.toLower(expected) != std.ascii.toLower(actual)) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        if (name.len == prefix.len) return true;
        const separator = name[prefix.len];
        // `LICENSE.txt` / `LICENSE-MIT` / `COPYING.LESSER` / `LICENSE-MIT.md` は
        // 採り、`LICENSE.json` や `license-checker.js` のような code file は
        // 採らない（拡張子の blocklist で判定する）。
        if (separator != '.' and separator != '-') continue;
        const suffix = name[prefix.len + 1 ..];
        if (suffix.len == 0) continue;
        if (isBlockedExtension(suffix, &code_extensions)) continue;
        const extension = std.fs.path.extension(suffix);
        if (extension.len >= 2 and isBlockedExtension(extension[1..], &code_extensions)) continue;
        return true;
    }
    return false;
}

fn isBlockedExtension(candidate: []const u8, blocked: []const []const u8) bool {
    for (blocked) |extension| if (std.ascii.eqlIgnoreCase(candidate, extension)) return true;
    return false;
}

fn lessThanBundledPackage(_: void, left: lnako.ir.nako_ir.BundledPackage, right: lnako.ir.nako_ir.BundledPackage) bool {
    if (!std.mem.eql(u8, left.name, right.name)) return std.mem.lessThan(u8, left.name, right.name);
    if (!std.mem.eql(u8, left.version, right.version)) return std.mem.lessThan(u8, left.version, right.version);
    if (!std.mem.eql(u8, left.root, right.root)) return std.mem.lessThan(u8, left.root, right.root);
    return left.kind == .npm and right.kind == .nako;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

test "同梱packageのlicenseとLICENSEファイルをSPDX 2.3で出力する" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "npm_left-pad");
    try temporary.dir.writeFile(io, .{
        .sub_path = "npm_left-pad/LICENSE",
        .data = "MIT License\n\nPermission is hereby granted...\n",
    });
    try temporary.dir.createDirPath(io, "packages/leftpad");
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "npm_left-pad" });
    defer allocator.free(package_root);
    const nako_root = try std.fs.path.join(allocator, &.{ root, "packages", "leftpad" });
    defer allocator.free(nako_root);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.bundled_packages = try program.arena.allocator().dupe(lnako.ir.nako_ir.BundledPackage, &.{
        .{ .name = "left-pad", .version = "1.0.0", .license = "MIT", .root = package_root, .kind = .npm, .entries = &.{"index.js"} },
        .{ .name = "leftpad", .version = "1.2.3", .license = "Apache-2.0", .root = nako_root, .kind = .nako },
    });

    const bytes = try render(allocator, io, &program, "/tmp/out/lnako-aot");
    defer allocator.free(bytes);
    const text = bytes;
    try std.testing.expect(std.mem.indexOf(u8, text, "\"spdxVersion\": \"SPDX-2.3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\": \"left-pad\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"licenseDeclared\": \"MIT\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"licenseDeclared\": \"Apache-2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pkg:npm/left-pad@1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pkg:nako/leftpad@1.2.3") != null);
    // LICENSE ファイルは file record + CONTAINS として出る。
    try std.testing.expect(std.mem.indexOf(u8, text, "\"fileName\": \"left-pad@1.0.0/LICENSE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"relationshipType\": \"CONTAINS\"") != null);
    // scoped package 名などで SPDX 2.3 の required field が欠けない。
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    const document = parsed.value.object;
    try std.testing.expect(document.get("packages").?.array.items.len == 2);
    try std.testing.expect(document.get("files").?.array.items.len == 1);
    try std.testing.expect(document.get("documentNamespace").?.string.len != 0);
}

test "SBOMは入力が同じなら決定的で、license無しはNOASSERTIONになる" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.bundled_packages = try program.arena.allocator().dupe(lnako.ir.nako_ir.BundledPackage, &.{
        .{ .name = "nolicense", .version = "2.0.0", .license = "NOASSERTION", .root = "/nonexistent/npm_nolicense", .kind = .npm },
    });
    const first = try render(allocator, io, &program, "/tmp/out/app");
    defer allocator.free(first);
    const second = try render(allocator, io, &program, "/tmp/out/app");
    defer allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"licenseDeclared\": \"NOASSERTION\"") != null);
    // 存在しない root でも SBOM 生成は失敗しない（license file は省略）。
    try std.testing.expect(std.mem.indexOf(u8, first, "\"files\": []") != null);
}

test "scoped npm packageのpurlは@を%40へencodeする" {
    const allocator = std.testing.allocator;
    const scoped = try purl(allocator, .{ .name = "@scope/name", .version = "1.0.0", .license = "MIT", .root = "/x", .kind = .npm });
    defer allocator.free(scoped);
    try std.testing.expectEqualStrings("pkg:npm/%40scope/name@1.0.0", scoped);
    const build_version = try purl(allocator, .{ .name = "pkg", .version = "1.0.0+build.5", .license = "MIT", .root = "/x", .kind = .npm });
    defer allocator.free(build_version);
    try std.testing.expectEqualStrings("pkg:npm/pkg@1.0.0%2Bbuild.5", build_version);
    const plain = try purl(allocator, .{ .name = "left-pad", .version = "1.0.0", .license = "MIT", .root = "/x", .kind = .npm });
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("pkg:npm/left-pad@1.0.0", plain);
    const nako = try purl(allocator, .{ .name = "leftpad", .version = "1.2.3", .license = "MIT", .root = "/x", .kind = .nako });
    defer allocator.free(nako);
    try std.testing.expectEqualStrings("pkg:nako/leftpad@1.2.3", nako);
}

test "license file名の判定はLICENSE系だけを採りcode fileを除外する" {
    try std.testing.expect(isLicenseFileName("LICENSE"));
    try std.testing.expect(isLicenseFileName("license"));
    try std.testing.expect(isLicenseFileName("LICENSE-MIT"));
    try std.testing.expect(isLicenseFileName("LICENSE.txt"));
    try std.testing.expect(isLicenseFileName("COPYING"));
    try std.testing.expect(isLicenseFileName("NOTICE.md"));
    // code file や無関係な名前は採らない。
    try std.testing.expect(!isLicenseFileName("license-checker.js"));
    try std.testing.expect(!isLicenseFileName("LICENSE.json"));
    try std.testing.expect(!isLicenseFileName("main.js"));
    try std.testing.expect(!isLicenseFileName("licenses.txt"));
}

test "license fileを持つpackageはfilesAnalyzed=trueになる" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "npm_withfile");
    try temporary.dir.writeFile(io, .{ .sub_path = "npm_withfile/COPYING", .data = "MIT\n" });
    try temporary.dir.createDirPath(io, "npm_withoutfile");
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const with_file = try std.fs.path.join(allocator, &.{ root, "npm_withfile" });
    defer allocator.free(with_file);
    const without_file = try std.fs.path.join(allocator, &.{ root, "npm_withoutfile" });
    defer allocator.free(without_file);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.bundled_packages = try program.arena.allocator().dupe(lnako.ir.nako_ir.BundledPackage, &.{
        .{ .name = "withfile", .version = "1.0.0", .license = "MIT", .root = with_file, .kind = .npm },
        .{ .name = "withoutfile", .version = "1.0.0", .license = "", .root = without_file, .kind = .npm },
    });

    const bytes = try render(allocator, io, &program, "/tmp/out/app");
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const packages = parsed.value.object.get("packages").?.array.items;
    try std.testing.expectEqual(true, packages[0].object.get("filesAnalyzed").?.bool);
    try std.testing.expectEqual(false, packages[1].object.get("filesAnalyzed").?.bool);
    // 空文字の license 宣言は NOASSERTION へ正規化する。
    try std.testing.expectEqualStrings("NOASSERTION", packages[1].object.get("licenseDeclared").?.string);
    // file record の SPDXID は file 名ではなく連番（空白入り名前でも壊れない）。
    const file = parsed.value.object.get("files").?.array.items[0];
    try std.testing.expect(std.mem.startsWith(u8, file.object.get("SPDXID").?.string, "SPDXRef-Package-npm-1-file-"));
}

test "宣言licenseをSPDXのlicense expressionへ正規化する" {
    const allocator = std.testing.allocator;
    const valid = [_][]const u8{ "MIT", "Apache-2.0", "BSD-3-Clause", "MIT OR Apache-2.0", "GPL-2.0-only WITH Classpath-exception-2.0", "(MIT OR Apache-2.0) AND BSD-3-Clause", "GPL-2.0+", "(MIT)" };
    for (valid) |declared| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const field = try spdxLicense(arena.allocator(), declared);
        try std.testing.expectEqualStrings(declared, field.value);
        try std.testing.expect(field.comment == null);
    }
    // 解析しないため、SPDX 式として解釈できない宣言は結論せず NOASSERTION にし、
    // 元の宣言を comment に残す（未定義の LicenseRef は出力しない）。
    const invalid = [_][]const u8{ "MIT/X11", "(MIT", "MIT ()", "AND MIT", "MIT AND", "MIT AND OR BSD", "MIT WITH", "独自ライセンス", "MIT and Apache-2.0", "GPL-2.0++", "MIT/Terms" };
    for (invalid) |declared| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const field = try spdxLicense(arena.allocator(), declared);
        try std.testing.expectEqualStrings("NOASSERTION", field.value);
        try std.testing.expect(field.comment != null);
    }
    var npm_arena = std.heap.ArenaAllocator.init(allocator);
    defer npm_arena.deinit();
    // npm の UNLICENSED は「付与しない」なので NONE。
    const unlicensed = try spdxLicense(npm_arena.allocator(), "UNLICENSED");
    try std.testing.expectEqualStrings("NONE", unlicensed.value);
    try std.testing.expect(unlicensed.comment != null);
    const unlicensed_case = try spdxLicense(npm_arena.allocator(), "unlicensed");
    try std.testing.expectEqualStrings("NONE", unlicensed_case.value);
    // 宣言なし/空文字は NOASSERTION。
    const empty = try spdxLicense(npm_arena.allocator(), "");
    try std.testing.expectEqualStrings("NOASSERTION", empty.value);
    try std.testing.expect(empty.comment == null);
}

test "licenseConcludedは宣言値を結論にせずNOASSERTIONを出す" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = lnako.package.test_sandbox.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "npm_declared");
    try temporary.dir.writeFile(io, .{ .sub_path = "npm_declared/LICENSE", .data = "MIT\n" });
    const root = try temporary.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const package_root = try std.fs.path.join(allocator, &.{ root, "npm_declared" });
    defer allocator.free(package_root);

    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.bundled_packages = try program.arena.allocator().dupe(lnako.ir.nako_ir.BundledPackage, &.{
        .{ .name = "declared", .version = "1.0.0", .license = "MIT", .root = package_root, .kind = .npm },
    });
    const bytes = try render(allocator, io, &program, "/tmp/out/app");
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const package = parsed.value.object.get("packages").?.array.items[0].object;
    // 宣言は licenseDeclared に残し、未解析の結論は NOASSERTION にする。
    try std.testing.expectEqualStrings("MIT", package.get("licenseDeclared").?.string);
    try std.testing.expectEqualStrings("NOASSERTION", package.get("licenseConcluded").?.string);
}

test "documentNamespaceは出力名と同梱entryで変わる" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var program = lnako.ir.nako_ir.Program{ .arena = std.heap.ArenaAllocator.init(allocator), .functions = &.{}, .module_entries = &.{} };
    defer program.deinit();
    program.bundled_packages = try program.arena.allocator().dupe(lnako.ir.nako_ir.BundledPackage, &.{
        .{ .name = "pkg", .version = "1.0.0", .license = "MIT", .root = "/nonexistent/npm_pkg", .kind = .npm, .entries = &.{"index.js"} },
    });
    const first = try render(allocator, io, &program, "/tmp/out/app");
    defer allocator.free(first);
    const same = try render(allocator, io, &program, "/tmp/out/app");
    defer allocator.free(same);
    try std.testing.expectEqualStrings(first, same);
    const other_name = try render(allocator, io, &program, "/tmp/out/other");
    defer allocator.free(other_name);
    try std.testing.expect(!std.mem.eql(u8, first, other_name));

    program.bundled_packages[0].entries = &.{"index.js"};
    const with_entries = try render(allocator, io, &program, "/tmp/out/app");
    defer allocator.free(with_entries);
    program.bundled_packages[0].entries = &.{};
    const without_entries = try render(allocator, io, &program, "/tmp/out/app");
    defer allocator.free(without_entries);
    try std.testing.expect(!std.mem.eql(u8, with_entries, without_entries));
}

test "license file名はLICENSE系の変種を採りcode fileを除外する" {
    // 変種（大文字小文字・拡張子・サフィックス）を採る。
    try std.testing.expect(isLicenseFileName("COPYING.LESSER"));
    try std.testing.expect(isLicenseFileName("LICENSE-MIT.md"));
    try std.testing.expect(isLicenseFileName("License"));
    try std.testing.expect(isLicenseFileName("NOTICE"));
    // code/データ file は採らない。
    try std.testing.expect(!isLicenseFileName("LICENSE.json"));
    try std.testing.expect(!isLicenseFileName("license-checker.js"));
    try std.testing.expect(!isLicenseFileName("license.toml"));
    try std.testing.expect(!isLicenseFileName("README.md"));
}
