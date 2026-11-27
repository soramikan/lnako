const std = @import("std");

pub const Error = error{ InvalidSemver, InvalidRange, OutOfMemory };

/// SemVer 2.0.0 のバージョン。`prerelease`/`build` は入力文字列へのスライスで、
/// 呼出し側がその入力を所有する。
pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    prerelease: []const u8 = "",
    build: []const u8 = "",

    /// `major.minor.patch[-prerelease][+build]` を厳密に解析する。
    /// 確保を行わないため error 集合は InvalidSemver のみ。
    pub fn parse(text: []const u8) error{InvalidSemver}!Version {
        var rest = text;
        var build: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
            build = rest[plus + 1 ..];
            rest = rest[0..plus];
            try validateIdentifiers(build, false);
        }
        var prerelease: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
            prerelease = rest[dash + 1 ..];
            rest = rest[0..dash];
            try validateIdentifiers(prerelease, true);
        }
        var parts = std.mem.splitScalar(u8, rest, '.');
        const major = try numericPart(parts.next() orelse return error.InvalidSemver);
        const minor = try numericPart(parts.next() orelse return error.InvalidSemver);
        const patch = try numericPart(parts.next() orelse return error.InvalidSemver);
        if (parts.next() != null) return error.InvalidSemver;
        return .{ .major = major, .minor = minor, .patch = patch, .prerelease = prerelease, .build = build };
    }

    pub fn hasPrerelease(self: Version) bool {
        return self.prerelease.len > 0;
    }

    /// SemVer の優先順位比較。build メタデータは無視する。
    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.patch != b.patch) return std.math.order(a.patch, b.patch);
        return orderPrerelease(a.prerelease, b.prerelease);
    }

    /// 優先順位比較での等価。build メタデータは比較に含めない。
    pub fn eql(a: Version, b: Version) bool {
        return a.order(b) == .eq;
    }

    /// build を含む完全な等価性。
    pub fn same(a: Version, b: Version) bool {
        return a.eql(b) and std.mem.eql(u8, a.build, b.build);
    }

    pub fn format(self: Version, writer: *std.Io.Writer) !void {
        try writer.print("{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
        if (self.prerelease.len > 0) try writer.print("-{s}", .{self.prerelease});
        if (self.build.len > 0) try writer.print("+{s}", .{self.build});
    }
};

/// node-semver と同じく各数値要素は Number.MAX_SAFE_INTEGER 以下に制限する。
/// 上限を設けることで範囲展開時の `+1` がオーバーフローしないことを保証する。
pub const max_component: u64 = 9007199254740991;

fn numericPart(text: []const u8) error{InvalidSemver}!u64 {
    if (text.len == 0) return error.InvalidSemver;
    if (text.len > 1 and text[0] == '0') return error.InvalidSemver;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidSemver;
    }
    const value = std.fmt.parseInt(u64, text, 10) catch return error.InvalidSemver;
    if (value > max_component) return error.InvalidSemver;
    return value;
}

fn isIdentChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-';
}

/// `strict_numeric` の場合、数字のみの識別子は先頭ゼロを許可しない。
fn validateIdentifiers(text: []const u8, strict_numeric: bool) error{InvalidSemver}!void {
    if (text.len == 0) return error.InvalidSemver;
    var parts = std.mem.splitScalar(u8, text, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidSemver;
        var numeric = true;
        for (part) |byte| {
            if (!isIdentChar(byte)) return error.InvalidSemver;
            if (!std.ascii.isDigit(byte)) numeric = false;
        }
        if (strict_numeric and numeric and part.len > 1 and part[0] == '0') return error.InvalidSemver;
    }
}

fn orderPrerelease(a: []const u8, b: []const u8) std.math.Order {
    if (a.len == 0 and b.len == 0) return .eq;
    if (a.len == 0) return .gt;
    if (b.len == 0) return .lt;
    var a_parts = std.mem.splitScalar(u8, a, '.');
    var b_parts = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const a_part = a_parts.next();
        const b_part = b_parts.next();
        if (a_part == null and b_part == null) return .eq;
        if (a_part == null) return .lt;
        if (b_part == null) return .gt;
        const a_numeric = allDigits(a_part.?);
        const b_numeric = allDigits(b_part.?);
        if (a_numeric and b_numeric) {
            // u64 に収まらない巨大な数値識別子も (長さ, 辞書順) で数値比較する。
            const ord = orderNumericText(a_part.?, b_part.?);
            if (ord != .eq) return ord;
        } else if (a_numeric) {
            return .lt;
        } else if (b_numeric) {
            return .gt;
        } else {
            const ord = std.mem.order(u8, a_part.?, b_part.?);
            if (ord != .eq) return ord;
        }
    }
}

pub const Op = enum {
    lt,
    lte,
    gt,
    gte,
    eq,

    pub fn matches(op: Op, ord: std.math.Order) bool {
        return switch (op) {
            .lt => ord == .lt,
            .lte => ord == .lt or ord == .eq,
            .gt => ord == .gt,
            .gte => ord == .gt or ord == .eq,
            .eq => ord == .eq,
        };
    }
};

pub const Comparator = struct {
    op: Op,
    version: Version,
};

/// npm互換のバージョン範囲。`sets` は `||` で区切られた AND 制約集合の OR。
/// `sets.len == 0` は全バージョンに一致する。`Range.parse` は空の `sets`
/// を生成しないため、この値はバージョン欠落・解析失敗時の合成値のみが
/// 取り得る（バリデータ側では「無制約」として扱う）。
pub const Range = struct {
    sets: []const []const Comparator,
    text: []const u8,

    /// 範囲構文の解釈モード。`legacy` は lnako の既存内部 API が依存する
    /// 厳格な wildcard 規則、`node_semver` は v1 が照合する node-semver
    /// 7.7.4 既定 API の wildcard/qualifier 規則を表す。
    pub const Mode = enum { legacy, node_semver };

    pub fn deinit(self: *Range, allocator: std.mem.Allocator) void {
        for (self.sets) |set| allocator.free(set);
        allocator.free(self.sets);
        self.* = undefined;
    }

    /// npm(node-semver)互換の範囲構文を解析する。
    /// 対応形式: `*`、`x`、部分バージョン、`^`/`~`、`>`系、`-` ハイフン、`||`。
    /// 構文エラーは `error.InvalidRange` に正規化する。
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Range {
        return parseWithMode(allocator, text, .legacy);
    }

    /// v1 の依存・engine 範囲が照合する node-semver 7.7.4 既定 API の
    /// 構文モード。旧内部 API の `parse` は変更しない。
    pub fn parseNodeSemver(allocator: std.mem.Allocator, text: []const u8) Error!Range {
        // ECMAScript 空白走査は UTF-8 のコードポイント単位で進むため、
        // 入口で不正・途中終端の UTF-8 を拒否する。legacy の Range.parse は
        // 従来のバイト単位動作を変えない。
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidRange;
        return parseWithMode(allocator, text, .node_semver);
    }

    fn parseWithMode(allocator: std.mem.Allocator, text: []const u8, mode: Mode) Error!Range {
        var sets: std.ArrayList([]const Comparator) = .empty;
        errdefer {
            for (sets.items) |set| allocator.free(set);
            sets.deinit(allocator);
        }
        // 空文字は node-semver と同じく全バージョン一致として扱う。
        const empty_text = if (mode == .node_semver)
            trimEcmaWhitespace(text).len == 0
        else
            std.mem.trim(u8, text, " \t\n\r").len == 0;
        if (empty_text) {
            try sets.append(allocator, &.{});
            return .{ .sets = try sets.toOwnedSlice(allocator), .text = text };
        }
        // `||` のみが OR 区切り。空の選択肢は node-semver と同じく `*` として扱う。
        var alternatives = std.mem.splitSequence(u8, text, "||");
        while (alternatives.next()) |alternative| {
            const empty_alternative = if (mode == .node_semver)
                trimEcmaWhitespace(alternative).len == 0
            else
                std.mem.trim(u8, alternative, " \t\n\r").len == 0;
            if (empty_alternative) {
                try sets.append(allocator, &.{});
                continue;
            }
            const set = parseSet(allocator, alternative, mode) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidRange,
            };
            errdefer allocator.free(set);
            try sets.append(allocator, set);
        }
        return .{ .sets = try sets.toOwnedSlice(allocator), .text = text };
    }

    /// バージョンがこの範囲に一致するか。node-semver と同じく、
    /// prerelease 付きバージョンは同一 (major,minor,patch) の
    /// prerelease 比較子を含む集合でのみ一致する。
    pub fn satisfies(self: Range, version: Version) bool {
        if (self.sets.len == 0) return true;
        for (self.sets) |set| {
            if (setSatisfies(set, version)) return true;
        }
        return false;
    }

    /// 2つの範囲の積集合が空でないか。厳密な求解ではなく、
    /// 上下限比較に基づく近似的判定。
    pub fn intersects(a: Range, b: Range) bool {
        if (a.sets.len == 0 or b.sets.len == 0) return true;
        for (a.sets) |set_a| {
            for (b.sets) |set_b| {
                if (setsIntersect(set_a, set_b)) return true;
            }
        }
        return false;
    }
};

const Partial = struct {
    major: ?u64,
    minor: ?u64,
    patch: ?u64,
    prerelease: []const u8 = "",
};

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

/// 数字のみの文字列を数値として比較する（先頭ゼロを正規化して長さ→辞書順）。
fn orderNumericText(a: []const u8, b: []const u8) std.math.Order {
    const na = std.mem.trimStart(u8, a, "0");
    const nb = std.mem.trimStart(u8, b, "0");
    if (na.len != nb.len) return std.math.order(na.len, nb.len);
    return std.mem.order(u8, na, nb);
}

fn isWildcard(text: []const u8) bool {
    return std.mem.eql(u8, text, "x") or std.mem.eql(u8, text, "X") or std.mem.eql(u8, text, "*");
}

/// ECMAScript の `\s` / `String.prototype.trim()` が扱う空白。
/// Node の Range は入力を `trim()` して `\s+` を ASCII 空白へ畳むため、
/// v1 モードでは NBSP・BOM・Unicode Zs なども区切りとして扱う。
fn isEcmaWhitespace(codepoint: u21) bool {
    return switch (codepoint) {
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        0x2000...0x200A => true,
        else => false,
    };
}

fn utf8CharLen(text: []const u8, index: usize) usize {
    if (index >= text.len) return 0;
    const first = text[index];
    if (first < 0x80) return 1;
    const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch 1;
    // 入口検証後でも、走査中のスライスが残りバイト数を超えないようにする。
    return @min(sequence_len, text.len - index);
}

fn ecmaWhitespaceLen(text: []const u8, index: usize) usize {
    if (index >= text.len) return 0;
    const first = text[index];
    if (first < 0x80) return if (isEcmaWhitespace(first)) 1 else 0;
    const len = std.unicode.utf8ByteSequenceLength(first) catch return 0;
    if (index + len > text.len) return 0;
    const codepoint = std.unicode.utf8Decode(text[index .. index + len]) catch return 0;
    return if (isEcmaWhitespace(codepoint)) len else 0;
}

fn trimEcmaWhitespace(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len) {
        const len = ecmaWhitespaceLen(text, start);
        if (len == 0) break;
        start += len;
    }
    var end = start;
    var index = start;
    while (index < text.len) {
        const whitespace = ecmaWhitespaceLen(text, index);
        if (whitespace != 0) {
            index += whitespace;
            continue;
        }
        index += utf8CharLen(text, index);
        end = index;
    }
    return text[start..end];
}

fn nextEcmaToken(text: []const u8, index: *usize) ?[]const u8 {
    while (index.* < text.len) {
        const whitespace = ecmaWhitespaceLen(text, index.*);
        if (whitespace == 0) break;
        index.* += whitespace;
    }
    if (index.* >= text.len) return null;
    const start = index.*;
    while (index.* < text.len) {
        const whitespace = ecmaWhitespaceLen(text, index.*);
        if (whitespace != 0) break;
        index.* += utf8CharLen(text, index.*);
    }
    return text[start..index.*];
}

/// node-semver の前置 `[v=\s]*` を、v1 モードでどこまで再現するか。
/// caret/tilde は任意の v/= 前置を許し、それ以外は完全一致する
/// 数値バージョンだけ単一 v を許す（部分版・wildcard は XRANGE 書換えで
/// 任意の v/= 前置を許す）。
const PrefixPolicy = enum { plain, caret_tilde };

const NodePrefix = struct {
    rest: []const u8,
    v_count: usize,
    eq_count: usize,
};

fn stripNodePrefix(text: []const u8) NodePrefix {
    var index: usize = 0;
    var v_count: usize = 0;
    var eq_count: usize = 0;
    while (index < text.len) : (index += 1) {
        switch (text[index]) {
            'v' => v_count += 1,
            '=' => eq_count += 1,
            else => break,
        }
    }
    return .{ .rest = text[index..], .v_count = v_count, .eq_count = eq_count };
}

fn isFullNumericVersion(major: []const u8, minor: ?[]const u8, patch: ?[]const u8) bool {
    const minor_text = minor orelse return false;
    const patch_text = patch orelse return false;
    return !isWildcard(major) and !isWildcard(minor_text) and !isWildcard(patch_text);
}

fn parsePartial(text: []const u8, mode: Range.Mode, policy: PrefixPolicy) Error!Partial {
    var rest = text;
    var node_prefix = NodePrefix{ .rest = text, .v_count = 0, .eq_count = 0 };
    if (mode == .node_semver) {
        // v1 は node-semver 7.7.4 の `[v=\s]*` 前置を再現する。ただし
        // 完全一致する数値バージョンでは XRANGE 書換えが走らないため、
        // caret/tilde 以外は単一 v だけを許す（`>=vv1.2.3` は不正、
        // `>=vv1.2` は部分版なので受理）。
        node_prefix = stripNodePrefix(rest);
        rest = node_prefix.rest;
    } else if (rest.len > 0 and rest[0] == 'v') {
        // 旧内部 API は従来どおり単一 v だけを剥がす。
        rest = rest[1..];
    }
    if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        // range 中の build メタデータは比較に影響しないが、構文としては許容する。
        try validateIdentifiers(rest[plus + 1 ..], false);
        rest = rest[0..plus];
    }
    var prerelease: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        prerelease = rest[dash + 1 ..];
        rest = rest[0..dash];
        try validateIdentifiers(prerelease, true);
    }
    var parts = std.mem.splitScalar(u8, rest, '.');
    const major_text = parts.next() orelse return error.InvalidRange;
    const minor_text = parts.next();
    const patch_text = parts.next();
    if (parts.next() != null) return error.InvalidRange;

    if (mode == .node_semver) {
        if (policy == .plain and isFullNumericVersion(major_text, minor_text, patch_text)) {
            // 完全一致の数値バージョンは Comparator の `v?` 前置だけを許す。
            // `=` 前置や複数の v は node-semver 7.7.4 でも不正。
            if (node_prefix.eq_count > 0 or node_prefix.v_count > 1) return error.InvalidRange;
        }
        return parseNodePartial(major_text, minor_text, patch_text, prerelease);
    }

    var result: Partial = .{ .major = null, .minor = null, .patch = null, .prerelease = prerelease };
    if (isWildcard(major_text)) {
        // 旧内部 API の規則: wildcard の後続位置は wildcard のみ許容し
        // （`*.*`/`x.x.x` は match-all、`*.1`/`*.*.5` は不正）、
        // prerelease は major wildcard では常に不正（`*.*-alpha` も拒否）。
        // build メタデータは任意位置で許容する。
        if (minor_text) |minor| {
            if (!isWildcard(minor)) return error.InvalidRange;
        }
        if (patch_text) |patch| {
            if (!isWildcard(patch)) return error.InvalidRange;
        }
        if (prerelease.len > 0) return error.InvalidRange;
        return result;
    }
    result.major = try numericPart(major_text);
    if (minor_text) |minor| {
        if (isWildcard(minor)) {
            // `1.x.5` は不正だが `1.x.x` は `1.x` と同等に展開する。
            // wildcard patch に付く prerelease は捨てる（`1.x.x-alpha`）。
            if (patch_text) |patch| {
                if (!isWildcard(patch)) return error.InvalidRange;
                result.prerelease = "";
                return result;
            }
            if (prerelease.len > 0) return error.InvalidRange;
            return result;
        }
        result.minor = try numericPart(minor);
    }
    if (patch_text) |patch| {
        // patch 位置が wildcard の場合 node-semver は prerelease を
        // 丸ごと捨てる（`1.2.x-alpha` は `1.2.x` と同等に展開）。
        if (isWildcard(patch)) {
            result.prerelease = "";
            return result;
        }
        result.patch = try numericPart(patch);
    }
    if (prerelease.len > 0 and (result.minor == null or result.patch == null)) return error.InvalidRange;
    return result;
}

/// node-semver 7.7.4 の XRANGE 文法に対応する partial 解析。
/// wildcard の後続位置は数値でもよく、major/minor wildcard の下では
/// 後続値と prerelease を無視する（`1.x.5` → `1.x`、`*.1` → `*`、
/// `*.*.*-alpha` → `*`）。prerelease は第3要素がある場合だけ付く。
fn parseNodePartial(
    major_text: []const u8,
    minor_text: ?[]const u8,
    patch_text: ?[]const u8,
    prerelease: []const u8,
) Error!Partial {
    var result: Partial = .{ .major = null, .minor = null, .patch = null, .prerelease = prerelease };
    if (prerelease.len > 0 and patch_text == null) return error.InvalidRange;

    if (isWildcard(major_text)) {
        if (minor_text) |minor| try validateDiscardedComponent(minor);
        if (patch_text) |patch| try validateDiscardedComponent(patch);
        result.prerelease = "";
        return result;
    }
    result.major = try numericPart(major_text);
    if (minor_text) |minor| {
        if (isWildcard(minor)) {
            if (patch_text) |patch| try validateDiscardedComponent(patch);
            result.prerelease = "";
            return result;
        }
        result.minor = try numericPart(minor);
    }
    if (patch_text) |patch| {
        if (isWildcard(patch)) {
            result.prerelease = "";
            return result;
        }
        result.patch = try numericPart(patch);
    }
    return result;
}

/// 捨てられる wildcard 後続位置は node-semver の XRANGEIDENTIFIER 文法だけを
/// 検査する。値は展開に使わないため MAX_SAFE_INTEGER や u64 の上限を課さない
/// （`1.x.9007199254740992` は有効）。
fn validateDiscardedComponent(text: []const u8) Error!void {
    if (isWildcard(text)) return;
    if (text.len == 0) return error.InvalidRange;
    if (text.len > 1 and text[0] == '0') return error.InvalidRange;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidRange;
    }
}

fn partialToVersion(partial: Partial) Version {
    return .{
        .major = partial.major orelse 0,
        .minor = partial.minor orelse 0,
        .patch = partial.patch orelse 0,
        .prerelease = partial.prerelease,
    };
}

/// node-semver は caret/tilde/wildcard の排他上限を `X.Y.Z-0` にする。
/// これにより上限タプルの prerelease（例: `2.0.0-alpha`）を範囲へ
/// 巻き込まない。`-0` を落とすと ID-07 の
/// `^1.2.3 >=2.0.0-alpha.1` が `2.0.0-alpha.2` を誤って受理する。
fn prereleaseZero(version: Version) Version {
    var out = version;
    out.prerelease = "0";
    out.build = "";
    return out;
}

/// `^1.2.3` 等の上限を返す。左端の非ゼロ要素を保持する。
fn caretUpper(partial: Partial) ?Version {
    const major = partial.major orelse return null;
    if (partial.minor == null) {
        // `^1`/`^0` は `~` と同等ではなく `>=x.0.0 <(x+1).0.0-0`
        return prereleaseZero(.{ .major = major + 1, .minor = 0, .patch = 0 });
    }
    const minor = partial.minor.?;
    if (partial.patch == null) {
        if (major > 0) return prereleaseZero(.{ .major = major + 1, .minor = 0, .patch = 0 });
        return prereleaseZero(.{ .major = 0, .minor = minor + 1, .patch = 0 });
    }
    const patch = partial.patch.?;
    if (major > 0) return prereleaseZero(.{ .major = major + 1, .minor = 0, .patch = 0 });
    if (minor > 0) return prereleaseZero(.{ .major = 0, .minor = minor + 1, .patch = 0 });
    if (patch > 0) return prereleaseZero(.{ .major = 0, .minor = 0, .patch = patch + 1 });
    return prereleaseZero(.{ .major = 0, .minor = 0, .patch = 1 });
}

/// `~1.2`/`~1.2.3`/`~1` の上限を返す。
fn tildeUpper(partial: Partial) ?Version {
    const major = partial.major orelse return null;
    if (partial.minor == null) return prereleaseZero(.{ .major = major + 1, .minor = 0, .patch = 0 });
    return prereleaseZero(.{ .major = major, .minor = partial.minor.? + 1, .patch = 0 });
}

fn wildcardUpper(partial: Partial) ?Version {
    const major = partial.major orelse return null;
    if (partial.minor == null) return prereleaseZero(.{ .major = major + 1, .minor = 0, .patch = 0 });
    return prereleaseZero(.{ .major = major, .minor = partial.minor.? + 1, .patch = 0 });
}

/// `>1.2` の下限 `>=1.3.0` 用。node-semver はこの下限に `-0` を付けない。
fn nextRelease(partial: Partial) ?Version {
    const upper = wildcardUpper(partial) orelse return null;
    var out = upper;
    out.prerelease = "";
    return out;
}

fn appendBound(mode: Range.Mode, list: *std.ArrayList(Comparator), allocator: std.mem.Allocator, op: Op, version: Version) Error!void {
    // node-semver は生成した比較子も SemVer として検証する。caret/tilde/
    // wildcard の +1 が MAX_SAFE_INTEGER を超える場合は範囲全体を拒否する。
    if (mode == .node_semver and
        (version.major > max_component or version.minor > max_component or version.patch > max_component))
    {
        return error.InvalidRange;
    }
    try list.append(allocator, .{ .op = op, .version = version });
}

/// 1つの比較トークン（`^1.2`、`>=1.0.0`、`1.2.x` 等）を AND 比較子列へ展開する。
fn expandToken(allocator: std.mem.Allocator, list: *std.ArrayList(Comparator), token: []const u8, mode: Range.Mode) Error!void {
    if (token.len == 0) return;
    if (isWildcard(token)) return;

    var op_text: []const u8 = "";
    var rest = token;
    for ([_][]const u8{ ">=", "<=", "~>", ">", "<", "=", "~", "^" }) |prefix| {
        if (std.mem.startsWith(u8, rest, prefix)) {
            op_text = prefix;
            rest = rest[prefix.len..];
            break;
        }
    }
    try expandOp(allocator, list, op_text, rest, mode);
}

/// 演算子とバージョン文字列を比較子列へ展開する。`rest` は呼出し側が
/// 所有するテキストのスライスで、比較子はそのスライスを参照してよい。
fn expandOp(allocator: std.mem.Allocator, list: *std.ArrayList(Comparator), op_text: []const u8, rest: []const u8, mode: Range.Mode) Error!void {
    const policy: PrefixPolicy = if (std.mem.eql(u8, op_text, "^") or
        std.mem.eql(u8, op_text, "~") or
        std.mem.eql(u8, op_text, "~>")) .caret_tilde else .plain;
    const partial = try parsePartial(rest, mode, policy);

    if (std.mem.eql(u8, op_text, "^")) {
        const lower = partialToVersion(partial);
        const upper = caretUpper(partial) orelse return; // `^*` は制約なし
        try appendBound(mode, list, allocator, .gte, lower);
        try appendBound(mode, list, allocator, .lt, upper);
        return;
    }
    if (std.mem.eql(u8, op_text, "~") or std.mem.eql(u8, op_text, "~>")) {
        const lower = partialToVersion(partial);
        const upper = tildeUpper(partial) orelse return;
        try appendBound(mode, list, allocator, .gte, lower);
        try appendBound(mode, list, allocator, .lt, upper);
        return;
    }
    if (std.mem.eql(u8, op_text, ">=") or std.mem.eql(u8, op_text, ">")) {
        const is_gte = op_text.len == 2;
        if (partial.major == null) {
            // node-semver は `>*` を `<0.0.0-0`（空範囲）、`>=*` を `*` に写す。
            if (!is_gte) try appendBound(mode, list, allocator, .lt, .{ .major = 0, .minor = 0, .patch = 0, .prerelease = "0" });
            return;
        }
        if (partial.minor != null and partial.patch != null) {
            try appendBound(mode, list, allocator, if (is_gte) .gte else .gt, partialToVersion(partial));
        } else if (is_gte) {
            // `>=1.2` は `>=1.2.0`
            try appendBound(mode, list, allocator, .gte, partialToVersion(partial));
        } else {
            // `>1.2` は `>=1.3.0`（`-0` を付けない）
            try appendBound(mode, list, allocator, .gte, nextRelease(partial).?);
        }
        return;
    }
    if (std.mem.eql(u8, op_text, "<=") or std.mem.eql(u8, op_text, "<")) {
        const is_lte = op_text.len == 2;
        if (partial.major == null) {
            // node-semver は `<*` を `<0.0.0-0`（空範囲）、`<=*` を `*` に写す。
            if (!is_lte) try appendBound(mode, list, allocator, .lt, .{ .major = 0, .minor = 0, .patch = 0, .prerelease = "0" });
            return;
        }
        if (partial.minor != null and partial.patch != null) {
            try appendBound(mode, list, allocator, if (is_lte) .lte else .lt, partialToVersion(partial));
        } else if (is_lte) {
            // `<=1.2` は `<1.3.0`
            try appendBound(mode, list, allocator, .lt, wildcardUpper(partial).?);
        } else {
            // `<1.2` は `<1.2.0-0`
            try appendBound(mode, list, allocator, .lt, prereleaseZero(partialToVersion(partial)));
        }
        return;
    }
    // 演算子なし / `=` / 部分バージョン。
    if (partial.major == null) return; // `*` 相当
    if (partial.minor == null or partial.patch == null) {
        const lower = partialToVersion(partial);
        const upper = wildcardUpper(partial).?;
        try appendBound(mode, list, allocator, .gte, lower);
        try appendBound(mode, list, allocator, .lt, upper);
        return;
    }
    try appendBound(mode, list, allocator, .eq, partialToVersion(partial));
}

/// 1つの OR 選択肢（空白区切りの AND 比較子）を解析する。
fn parseSet(allocator: std.mem.Allocator, alternative: []const u8, mode: Range.Mode) Error![]const Comparator {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(allocator);
    if (mode == .node_semver) {
        var token_index: usize = 0;
        while (nextEcmaToken(alternative, &token_index)) |token| try tokens.append(allocator, token);
    } else {
        var iter = std.mem.tokenizeAny(u8, alternative, " \t\n\r");
        while (iter.next()) |token| try tokens.append(allocator, token);
    }
    if (tokens.items.len == 0) return error.InvalidRange;

    var list: std.ArrayList(Comparator) = .empty;
    errdefer list.deinit(allocator);
    if (mode == .node_semver and tokens.items.len == 3 and std.mem.eql(u8, tokens.items[1], "-")) {
        // node-semver の HYPHENRANGE は選択肢全体に一致する場合だけ展開する。
        // `1.2.3 - 2.0.0 >=1` のような後続比較子付きは不正。
        try expandHyphen(allocator, &list, tokens.items[0], tokens.items[2], mode);
        return list.toOwnedSlice(allocator);
    }
    var i: usize = 0;
    while (i < tokens.items.len) {
        const token = tokens.items[i];
        if (std.mem.eql(u8, token, "-")) return error.InvalidRange;
        if (mode == .legacy and i + 2 < tokens.items.len and std.mem.eql(u8, tokens.items[i + 1], "-")) {
            try expandHyphen(allocator, &list, token, tokens.items[i + 2], mode);
            i += 3;
            continue;
        }
        // node-semver は `> 1.2.3` のような演算子とバージョンの空白区切りを許容する。
        // join せず別引数で渡す（比較子が参照するバージョン文字列を
        // 呼出し側テキストのスライスのまま保持するため）。
        if (isLoneOperator(token)) {
            if (i + 1 >= tokens.items.len or std.mem.eql(u8, tokens.items[i + 1], "-")) return error.InvalidRange;
            const next = tokens.items[i + 1];
            if (mode == .node_semver and
                (std.mem.eql(u8, token, "^") or std.mem.eql(u8, token, "~")) and
                std.mem.eql(u8, next, "=") and i + 2 < tokens.items.len)
            {
                // CARET/TILDE の `^ = 1.2.3` は `^=1.2.3` と同じ。
                if (std.mem.eql(u8, tokens.items[i + 2], "-")) return error.InvalidRange;
                try expandOp(allocator, &list, token, tokens.items[i + 2], mode);
                i += 3;
                continue;
            }
            if (mode == .node_semver and (std.mem.eql(u8, token, ">") or std.mem.eql(u8, token, "<")) and
                next.len > 1 and next[0] == '=')
            {
                // node-semver の COMPARATORTRIM は `> =1.2.3` を `>=1.2.3`、
                // `< =1.2` を `<=1.2` に畳む。
                const combined: []const u8 = if (token[0] == '>') ">=" else "<=";
                try expandOp(allocator, &list, combined, next[1..], mode);
            } else {
                try expandOp(allocator, &list, token, next, mode);
            }
            i += 2;
            continue;
        }
        try expandToken(allocator, &list, token, mode);
        i += 1;
    }
    return list.toOwnedSlice(allocator);
}

/// `>`、`>=`、`~` 等のバージョンを伴わない単独演算子トークンか。
fn isLoneOperator(token: []const u8) bool {
    const ops = [_][]const u8{ ">=", "<=", "~>", ">", "<", "=", "~", "^" };
    for (ops) |op| {
        if (std.mem.eql(u8, token, op)) return true;
    }
    return false;
}

/// `a - b` のハイフン範囲を展開する。
fn expandHyphen(allocator: std.mem.Allocator, list: *std.ArrayList(Comparator), lower_text: []const u8, upper_text: []const u8, mode: Range.Mode) Error!void {
    const lower = try parsePartial(lower_text, mode, .plain);
    const upper = try parsePartial(upper_text, mode, .plain);
    if (lower.major != null) {
        try appendBound(mode, list, allocator, .gte, partialToVersion(lower));
    }
    if (upper.major == null) {
        return;
    } else if (upper.minor == null) {
        try appendBound(mode, list, allocator, .lt, prereleaseZero(.{ .major = upper.major.? + 1, .minor = 0, .patch = 0 }));
    } else if (upper.patch == null) {
        try appendBound(mode, list, allocator, .lt, prereleaseZero(.{ .major = upper.major.?, .minor = upper.minor.? + 1, .patch = 0 }));
    } else {
        try appendBound(mode, list, allocator, .lte, partialToVersion(upper));
    }
}

fn setSatisfies(set: []const Comparator, version: Version) bool {
    for (set) |comparator| {
        if (!comparator.op.matches(version.order(comparator.version))) return false;
    }
    if (version.prerelease.len == 0) return true;
    // prerelease は同一 (major,minor,patch) の prerelease 比較子を要求する。
    for (set) |comparator| {
        const other = comparator.version;
        if (other.prerelease.len > 0 and other.major == version.major and other.minor == version.minor and other.patch == version.patch) {
            return true;
        }
    }
    return false;
}

/// 2つの AND 比較子集合の共通部分が空でないかを上下限から判定する。
/// 厳密な求解ではなく近似的判定（範囲の積集合計算にも利用する）。
pub fn setsIntersect(a: []const Comparator, b: []const Comparator) bool {
    return jointSetsIntersect(&.{ a, b });
}

/// 複数の AND 比較子集合（同一 public-id の各依存が選んだ選択肢の組合せ）の
/// 共通部分が空でないかを上下限から判定する。prerelease ゲートは併合済みの
/// 和集合ではなく構成集合毎に要求する。各構成集合は個別の依存制約に対応し、
/// prerelease 候補は全ての構成集合を個別に満たす必要があるため。
/// 近似の既知の限界: 上下限の一方だけがある集合や、複数タプルにまたがる
/// prerelease 区間は厳密には求解しない。誤検出方向には働かない。
pub fn jointSetsIntersect(sets: []const []const Comparator) bool {
    var lower: ?Comparator = null;
    var upper: ?Comparator = null;
    var exact: ?Comparator = null;
    for (sets) |set| {
        for (set) |comparator| {
            switch (comparator.op) {
                .eq => {
                    if (exact) |previous| {
                        if (!previous.version.eql(comparator.version)) return false;
                    }
                    exact = comparator;
                },
                .gt, .gte => {
                    if (lower == null or isLowerStronger(comparator, lower.?)) lower = comparator;
                },
                .lt, .lte => {
                    if (upper == null or isUpperStronger(comparator, upper.?)) upper = comparator;
                },
            }
        }
    }
    if (exact) |eq| {
        const v = eq.version;
        if (lower) |l| {
            const ord = v.order(l.version);
            if (!l.op.matches(ord)) return false;
        }
        if (upper) |u| {
            const ord = v.order(u.version);
            if (!u.op.matches(ord)) return false;
        }
        if (v.prerelease.len > 0) {
            // prerelease 版は各構成集合に同タプルの prerelease 比較子を要求する。
            // `>=1.0.0` ∩ `=2.0.0-alpha` のような衝突を取りこぼさないため。
            if (!prereleaseGated(sets, v)) return false;
        }
        return true;
    }
    if (lower != null and upper != null) {
        const l = lower.?;
        const u = upper.?;
        const ord = l.version.order(u.version);
        if (ord == .gt) return false;
        if (ord == .eq and !(l.op == .gte and u.op == .lte)) return false;
        // 共通候補がタプル T の prerelease のみに限られる場合
        // （下端が T の prerelease 比較子で、上端が T 自体より下か
        // T の prerelease）、各構成集合は T の prerelease 比較子を含む必要がある。
        // `>=1.0.0-alpha <2.0.0` ∩ `>=1.5.0-alpha <1.5.0` のように
        // 境界だけが重なる非交差を取りこぼさないため。
        const same_tuple = l.version.major == u.version.major and
            l.version.minor == u.version.minor and l.version.patch == u.version.patch;
        const upper_prerelease_only = u.op == .lt or u.version.prerelease.len > 0;
        if (l.version.prerelease.len > 0 and same_tuple and upper_prerelease_only) {
            if (!prereleaseGated(sets, l.version)) return false;
        }
        // 下端が release への `>` で上端が直後のタプル（patch+1）の
        // prerelease 区間のみを残す場合も同様にゲートする。
        // `>1.5.0 <1.5.1` の候補は 1.5.1 の prerelease のみで、
        // release の挟まる区間ではないため。
        const successor_tuple = l.op == .gt and l.version.prerelease.len == 0 and
            u.version.major == l.version.major and u.version.minor == l.version.minor and
            u.version.patch == l.version.patch +| 1;
        if (successor_tuple and upper_prerelease_only) {
            if (!prereleaseGated(sets, u.version)) return false;
        }
    }
    if (lower == null and upper != null) {
        const u = upper.?;
        // 下限なしの上端 `<u` は u 未満の候補を必要とする。最小
        // バージョン 0.0.0-0 以下の上端（`<0.0.0-0` は `>x` や `<x`
        // の展開結果）は空。
        const min_order = u.version.order(.{ .major = 0, .minor = 0, .patch = 0, .prerelease = "0" });
        if (u.op == .lt and min_order != .gt) return false;
        // 上端が (0,0,0) タプルにある場合、候補は (0,0,0) の
        // prerelease のみ（それ未満の release は存在しない）。
        // `<0.0.0` はゲート可能な比較子が必ずこの上端より強いため
        // 常に空、`<=0.0.0-P` や `<0.0.0-P` はゲートを要求する。
        const zero_tuple = u.version.major == 0 and u.version.minor == 0 and u.version.patch == 0;
        if (zero_tuple and (u.version.prerelease.len > 0 or u.op == .lt)) {
            if (!prereleaseGated(sets, u.version)) return false;
        }
    }
    return true;
}

/// 全構成集合がタプル `(v.major, v.minor, v.patch)` の prerelease 比較子を
/// 持つか。`setSatisfies` の prerelease ゲートと同じ条件を集合毎に課す。
fn prereleaseGated(sets: []const []const Comparator, v: Version) bool {
    for (sets) |set| {
        var gated = false;
        for (set) |comparator| {
            const other = comparator.version;
            if (other.prerelease.len > 0 and other.major == v.major and
                other.minor == v.minor and other.patch == v.patch)
            {
                gated = true;
                break;
            }
        }
        if (!gated) return false;
    }
    return true;
}

/// 同じバージョンなら `>` は `>=` より強い。
fn isLowerStronger(candidate: Comparator, current: Comparator) bool {
    const ord = candidate.version.order(current.version);
    return ord == .gt or (ord == .eq and candidate.op == .gt and current.op == .gte);
}

fn isUpperStronger(candidate: Comparator, current: Comparator) bool {
    const ord = candidate.version.order(current.version);
    return ord == .lt or (ord == .eq and candidate.op == .lt and current.op == .lte);
}

test "SemVerを解析して比較する" {
    const a = try Version.parse("1.2.3");
    try std.testing.expectEqual(@as(u64, 1), a.major);
    try std.testing.expectEqual(@as(u64, 2), a.minor);
    try std.testing.expectEqual(@as(u64, 3), a.patch);

    const b = try Version.parse("1.2.3-alpha.1+build.5");
    try std.testing.expectEqualStrings("alpha.1", b.prerelease);
    try std.testing.expectEqualStrings("build.5", b.build);

    try std.testing.expect(b.order(a) == .lt);
    const c = try Version.parse("1.2.3-alpha");
    try std.testing.expect(b.order(c) == .gt); // alpha.1 > alpha（識別子が長い方が大きい）

    try std.testing.expectError(error.InvalidSemver, Version.parse("1.2"));
    try std.testing.expectError(error.InvalidSemver, Version.parse("1.02.3"));
    try std.testing.expectError(error.InvalidSemver, Version.parse("1.2.3-"));
    try std.testing.expectError(error.InvalidSemver, Version.parse("1.2.3-01"));
    try std.testing.expectError(error.InvalidSemver, Version.parse("1.2.3+"));
}

test "範囲を解析して一致判定する" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        range: []const u8,
        matching: []const []const u8,
        non_matching: []const []const u8,
    }{
        .{ .range = "*", .matching = &.{"0.0.0"}, .non_matching = &.{} },
        .{ .range = "1.2.3", .matching = &.{"1.2.3"}, .non_matching = &.{ "1.2.4", "1.2.3-alpha" } },
        .{ .range = "^1.2.3", .matching = &.{ "1.2.3", "1.9.0" }, .non_matching = &.{ "2.0.0", "1.2.2" } },
        .{ .range = "^0.2.3", .matching = &.{ "0.2.3", "0.2.9" }, .non_matching = &.{ "0.3.0", "1.0.0" } },
        .{ .range = "^0.0.3", .matching = &.{"0.0.3"}, .non_matching = &.{"0.0.4"} },
        .{ .range = "~1.2.3", .matching = &.{ "1.2.3", "1.2.9" }, .non_matching = &.{"1.3.0"} },
        .{ .range = "~1.2", .matching = &.{ "1.2.0", "1.2.9" }, .non_matching = &.{"1.3.0"} },
        .{ .range = "1.2.x", .matching = &.{ "1.2.0", "1.2.99" }, .non_matching = &.{"1.3.0"} },
        .{ .range = "1.x", .matching = &.{ "1.0.0", "1.9.9" }, .non_matching = &.{"2.0.0"} },
        .{ .range = ">=1.0.0 <2.0.0", .matching = &.{"1.5.0"}, .non_matching = &.{ "0.9.9", "2.0.0" } },
        .{ .range = "1.2.3 - 2.0.0", .matching = &.{ "1.2.3", "2.0.0" }, .non_matching = &.{ "2.0.1", "1.2.2" } },
        .{ .range = "1.2.3 - 2.3", .matching = &.{ "1.2.3", "2.3.9" }, .non_matching = &.{"2.4.0"} },
        .{ .range = ">=1.0.0 <1.2.0 || >=2.0.0", .matching = &.{ "1.0.0", "2.5.0" }, .non_matching = &.{"1.5.0"} },
    };
    for (cases) |case| {
        var range = try Range.parse(allocator, case.range);
        defer range.deinit(allocator);
        for (case.matching) |version_text| {
            const version = try Version.parse(version_text);
            try std.testing.expect(range.satisfies(version));
        }
        for (case.non_matching) |version_text| {
            const version = try Version.parse(version_text);
            try std.testing.expect(!range.satisfies(version));
        }
    }
}

test "prereleaseの範囲一致は同一tupleの比較子を要求する" {
    const allocator = std.testing.allocator;
    var range = try Range.parse(allocator, ">=1.0.0 <2.0.0");
    defer range.deinit(allocator);
    try std.testing.expect(!range.satisfies(try Version.parse("1.5.0-alpha")));
    try std.testing.expect(range.satisfies(try Version.parse("1.5.0")));

    var range2 = try Range.parse(allocator, ">=1.0.0-alpha <2.0.0");
    defer range2.deinit(allocator);
    try std.testing.expect(range2.satisfies(try Version.parse("1.0.0-beta")));
    try std.testing.expect(!range2.satisfies(try Version.parse("1.5.0-alpha")));
}

test "範囲の交差を判定する" {
    const allocator = std.testing.allocator;
    var a = try Range.parse(allocator, "^1.0.0");
    defer a.deinit(allocator);
    var b = try Range.parse(allocator, "^2.0.0");
    defer b.deinit(allocator);
    try std.testing.expect(!a.intersects(b));

    var c = try Range.parse(allocator, ">=1.0.0 <3.0.0");
    defer c.deinit(allocator);
    try std.testing.expect(a.intersects(c));

    var exact = try Range.parse(allocator, "1.5.0");
    defer exact.deinit(allocator);
    try std.testing.expect(a.intersects(exact));

    var exact_out = try Range.parse(allocator, "0.9.0");
    defer exact_out.deinit(allocator);
    try std.testing.expect(!a.intersects(exact_out));
}

test "無効な範囲を拒否する" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, "1.2.3.4"));
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, "1.2.3 -"));
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, ">="));
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, "1.x.2"));
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, "^01.2.3"));
    // 上限を超える数値要素は範囲展開時のオーバーフローを防ぐため拒否する。
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, "^9007199254740992"));
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, "1.0.0 - 18446744073709551615"));
    try std.testing.expectError(error.InvalidSemver, Version.parse("9007199254740992.0.0"));
}

test "node-semverの前置と空白区切り演算子を受理する" {
    const allocator = std.testing.allocator;
    var range = try Range.parse(allocator, "v1.2.3");
    defer range.deinit(allocator);
    try std.testing.expect(range.satisfies(try Version.parse("1.2.3")));

    var spaced = try Range.parse(allocator, "> 1.2.3 <= 2.0.0");
    defer spaced.deinit(allocator);
    try std.testing.expect(spaced.satisfies(try Version.parse("1.5.0")));
    try std.testing.expect(!spaced.satisfies(try Version.parse("1.2.3")));

    var equals = try Range.parse(allocator, "= 1.2.3");
    defer equals.deinit(allocator);
    try std.testing.expect(equals.satisfies(try Version.parse("1.2.3")));

    // バージョン位置の `=` は拒否する（node-semver 7.x より意図的に厳しい。
    // npm/node-semver#691 の次期メジャー提案 `v?` のみ前置と一致）。
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, "==1.2.3"));
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, "> =1.2.3"));
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, "1.2.3 - =2.0.0"));
    var equals_v = try Range.parse(allocator, "=v1.2.3");
    defer equals_v.deinit(allocator);
    try std.testing.expect(equals_v.satisfies(try Version.parse("1.2.3")));

    // 空の `||` 選択肢は `*` として扱う。
    var or_empty = try Range.parse(allocator, "2.0.0 ||");
    defer or_empty.deinit(allocator);
    try std.testing.expect(or_empty.satisfies(try Version.parse("9.9.9")));

    var tilde_spaced = try Range.parse(allocator, "~ 1.2");
    defer tilde_spaced.deinit(allocator);
    try std.testing.expect(tilde_spaced.satisfies(try Version.parse("1.2.9")));
}

test "空白区切り演算子のprerelease参照が有効なまま残る" {
    const allocator = std.testing.allocator;
    // 比較子の prerelease は呼出し側テキストのスライスを指す。
    // join バッファを参照すると解放済みメモリを読む（回帰）。
    var range = try Range.parse(allocator, "> 1.2.3-alpha");
    defer range.deinit(allocator);
    try std.testing.expect(range.satisfies(try Version.parse("1.2.3-beta")));
    try std.testing.expect(range.satisfies(try Version.parse("1.2.3")));
    try std.testing.expect(range.satisfies(try Version.parse("2.0.0")));
    try std.testing.expect(!range.satisfies(try Version.parse("1.2.3-alpha")));
    // 異なる tuple の prerelease はゲートで除外される。
    try std.testing.expect(!range.satisfies(try Version.parse("2.0.0-alpha")));
}

test "u64を超えるprerelease数値識別子を比較する" {
    const huge = try Version.parse("1.0.0-99999999999999999999");
    const small = try Version.parse("1.0.0-100");
    try std.testing.expect(huge.order(small) == .gt);
    const alpha = try Version.parse("1.0.0-alpha");
    try std.testing.expect(alpha.order(huge) == .gt); // 数値 < 英字
}

test "ワイルドカード比較は空範囲になる" {
    const allocator = std.testing.allocator;
    // node-semver は `>*`/`<x` を `<0.0.0-0`（空範囲）に写す。
    var empty_gt = try Range.parse(allocator, ">x");
    defer empty_gt.deinit(allocator);
    try std.testing.expect(!empty_gt.satisfies(try Version.parse("0.0.0")));
    try std.testing.expect(!empty_gt.satisfies(try Version.parse("99.0.0")));
    var empty_lt = try Range.parse(allocator, "<*");
    defer empty_lt.deinit(allocator);
    try std.testing.expect(!empty_lt.satisfies(try Version.parse("0.0.0")));
    // `>=*`/`<=*` は制約なしのまま。
    var any_ge = try Range.parse(allocator, ">=*");
    defer any_ge.deinit(allocator);
    try std.testing.expect(any_ge.satisfies(try Version.parse("0.0.0")));
    var any_le = try Range.parse(allocator, "<=x");
    defer any_le.deinit(allocator);
    try std.testing.expect(any_le.satisfies(try Version.parse("99.0.0")));
}

test "tilde-greater演算子を受理する" {
    const allocator = std.testing.allocator;
    // node-semver は `~>` を `~` と同等に扱う。
    var range = try Range.parse(allocator, "~>1.2.3");
    defer range.deinit(allocator);
    try std.testing.expect(range.satisfies(try Version.parse("1.2.9")));
    try std.testing.expect(!range.satisfies(try Version.parse("1.3.0")));
    var spaced = try Range.parse(allocator, "~> 1.2");
    defer spaced.deinit(allocator);
    try std.testing.expect(spaced.satisfies(try Version.parse("1.2.0")));
}

test "prerelease版の交差判定はゲートを要求する" {
    const allocator = std.testing.allocator;
    // `>=1.0.0` ∩ `=2.0.0-alpha`: 2.0.0-alpha は first set のゲートを通らないため非交差。
    var bound = try Range.parse(allocator, ">=1.0.0");
    defer bound.deinit(allocator);
    var exact_pre = try Range.parse(allocator, "2.0.0-alpha");
    defer exact_pre.deinit(allocator);
    try std.testing.expect(!bound.intersects(exact_pre));
    // 両方が 2.0.0 の prerelease 比較子を持つなら交差する。
    var gated = try Range.parse(allocator, ">=2.0.0-alpha");
    defer gated.deinit(allocator);
    try std.testing.expect(gated.intersects(exact_pre));
}

test "prerelease専用の共通範囲は同タプルの比較子を要求する" {
    const allocator = std.testing.allocator;
    // `>=1.5.0-alpha <1.5.0` の候補は 1.5.0 の prerelease のみ。
    // `>=1.0.0-alpha <2.0.0` は同タプルの prerelease 比較子を持たないため非交差。
    var wide = try Range.parse(allocator, ">=1.0.0-alpha <2.0.0");
    defer wide.deinit(allocator);
    var pre_only = try Range.parse(allocator, ">=1.5.0-alpha <1.5.0");
    defer pre_only.deinit(allocator);
    try std.testing.expect(!wide.intersects(pre_only));

    // 片方が同タプルの prerelease 比較子を持たない場合も非交差。
    var plain = try Range.parse(allocator, ">=1.0.0 <2.0.0");
    defer plain.deinit(allocator);
    try std.testing.expect(!plain.intersects(pre_only));

    // 両方が 1.5.0 の prerelease 比較子を持つなら交差する。
    var pre_overlap = try Range.parse(allocator, ">=1.5.0-beta <1.5.0");
    defer pre_overlap.deinit(allocator);
    try std.testing.expect(pre_only.intersects(pre_overlap));

    // 共通部分に release が残るならゲートは不要。
    var releases = try Range.parse(allocator, ">=1.5.0 <2.0.0");
    defer releases.deinit(allocator);
    try std.testing.expect(wide.intersects(releases));

    // 3集合の組合せでは、1つの集合が持つ prerelease 比較子が他の集合の
    // ゲートを代行しない。`>=1.0.0 <1.9.0` は 1.5.0 の prerelease 比較子を
    // 持たないため `>=1.5.0-beta <1.5.0` の候補を受理できない。
    var a_set = try Range.parse(allocator, ">=1.5.0-alpha <2.0.0");
    defer a_set.deinit(allocator);
    var b_set = try Range.parse(allocator, ">=1.0.0 <1.9.0");
    defer b_set.deinit(allocator);
    var c_set = try Range.parse(allocator, ">=1.5.0-beta <1.5.0");
    defer c_set.deinit(allocator);
    try std.testing.expect(!jointSetsIntersect(&.{ a_set.sets[0], b_set.sets[0], c_set.sets[0] }));
    // match-all（空集合）も prerelease 比較子を持たないためゲートを通らない。
    var any_set = try Range.parse(allocator, "");
    defer any_set.deinit(allocator);
    try std.testing.expect(!jointSetsIntersect(&.{ any_set.sets[0], c_set.sets[0] }));
}

test "隣接タプル間のprerelease専用区間もゲートを要求する" {
    const allocator = std.testing.allocator;
    // `>1.5.0 <1.5.1` の候補は 1.5.1 の prerelease のみ。同タプルの
    // prerelease 比較子を持たない集合とは交差しない。
    var succ = try Range.parse(allocator, ">1.5.0 <1.5.1");
    defer succ.deinit(allocator);
    var plain = try Range.parse(allocator, ">=1.0.0");
    defer plain.deinit(allocator);
    try std.testing.expect(!succ.intersects(plain));

    // 自身の集合がゲート用の比較子を持たないため、相手が同タプルの
    // prerelease 比較子を持っても非交差のまま。
    var gated = try Range.parse(allocator, ">=1.5.1-alpha");
    defer gated.deinit(allocator);
    try std.testing.expect(!succ.intersects(gated));

    // 両方が 1.5.1 の prerelease 比較子を持つなら交差する。
    var succ_pre = try Range.parse(allocator, ">1.5.0 <1.5.1-alpha");
    defer succ_pre.deinit(allocator);
    var other_pre = try Range.parse(allocator, ">=1.5.1-0 <1.5.1");
    defer other_pre.deinit(allocator);
    try std.testing.expect(succ_pre.intersects(other_pre));

    // 上端に release が含まれるならゲートは不要。
    var release_upper = try Range.parse(allocator, ">1.5.0 <=1.5.1");
    defer release_upper.deinit(allocator);
    try std.testing.expect(release_upper.intersects(plain));

    // 隣接タプルでなければ release が区間内に存在しゲートは不要。
    var wide = try Range.parse(allocator, ">1.5.0 <1.5.3");
    defer wide.deinit(allocator);
    try std.testing.expect(wide.intersects(plain));
}

test "下限なしの上端のみの空範囲は非交差と判定する" {
    const allocator = std.testing.allocator;
    var any = try Range.parse(allocator, "*");
    defer any.deinit(allocator);
    // `>x` は `<0.0.0-0`（空範囲）に展開されるため `*` とも交差しない。
    var empty_gt = try Range.parse(allocator, ">x");
    defer empty_gt.deinit(allocator);
    try std.testing.expect(!empty_gt.intersects(any));
    var empty_lt = try Range.parse(allocator, "<x");
    defer empty_lt.deinit(allocator);
    try std.testing.expect(!empty_lt.intersects(any));
    // `<0.0.0` の候補は (0,0,0) の prerelease のみで、ゲート可能な
    // 比較子は必ずこの上端より強いため常に空。
    var below_zero = try Range.parse(allocator, "<0.0.0");
    defer below_zero.deinit(allocator);
    try std.testing.expect(!below_zero.intersects(any));
    // `<=0.0.0-0` の候補は 0.0.0-0 のみで、`*` は prerelease を
    // 受理しないため非交差。同タプルのゲートを持つ集合とは交差する。
    var floor = try Range.parse(allocator, "<=0.0.0-0");
    defer floor.deinit(allocator);
    try std.testing.expect(!floor.intersects(any));
    var gated = try Range.parse(allocator, ">=0.0.0-0");
    defer gated.deinit(allocator);
    try std.testing.expect(floor.intersects(gated));
    // release が候補に残る上端は非空。
    var low_release = try Range.parse(allocator, "<1.0.0");
    defer low_release.deinit(allocator);
    try std.testing.expect(low_release.intersects(any));
    var zero_release = try Range.parse(allocator, "<=0.0.0");
    defer zero_release.deinit(allocator);
    try std.testing.expect(zero_release.intersects(any));
}

test "改行区切りの比較子を受理する" {
    const allocator = std.testing.allocator;
    // TOML 複数行文字列では範囲内に改行を含められる。
    var range = try Range.parse(allocator, ">=1.0.0\n<2.0.0");
    defer range.deinit(allocator);
    try std.testing.expect(range.satisfies(try Version.parse("1.5.0")));
    try std.testing.expect(!range.satisfies(try Version.parse("2.0.0")));
    // 前後の改行はトリムされる。
    var padded = try Range.parse(allocator, "\n>=1.0.0\r\n");
    defer padded.deinit(allocator);
    try std.testing.expect(padded.satisfies(try Version.parse("9.9.9")));
    // 改行のみの選択肢は `*` として扱う。
    var empty_alt = try Range.parse(allocator, "1.0.0 || \n");
    defer empty_alt.deinit(allocator);
    try std.testing.expect(empty_alt.satisfies(try Version.parse("99.0.0")));
}

test "wildcard位置へのqualifier規則はnode-semverと一致する" {
    const allocator = std.testing.allocator;
    // prerelease は major が数値かつ patch 位置まで記述された partial にのみ
    // 付けられる。
    for ([_][]const u8{ "*-alpha", "*.*-alpha", "x-alpha", "1-alpha", "1.2-alpha", "1.x-alpha" }) |text| {
        try std.testing.expectError(error.InvalidRange, Range.parse(allocator, text));
    }
    // patch 位置が wildcard の prerelease は捨てて評価する。
    var dropped = try Range.parse(allocator, "1.2.x-alpha");
    defer dropped.deinit(allocator);
    var plain = try Range.parse(allocator, "1.2.x");
    defer plain.deinit(allocator);
    try std.testing.expectEqual(dropped.sets.len, plain.sets.len);
    try std.testing.expect(dropped.satisfies(try Version.parse("1.2.5")));
    try std.testing.expect(!dropped.satisfies(try Version.parse("1.3.0")));
    // wildcard の後続位置も wildcard でなければならない。
    for ([_][]const u8{ "*.1", "*.*.5", "1.x.5", "x.2.3" }) |text| {
        try std.testing.expectError(error.InvalidRange, Range.parse(allocator, text));
    }
    var star_dot = try Range.parse(allocator, "*.*");
    defer star_dot.deinit(allocator);
    try std.testing.expect(star_dot.satisfies(try Version.parse("7.8.9")));
    var x3 = try Range.parse(allocator, "1.x.x");
    defer x3.deinit(allocator);
    try std.testing.expect(x3.satisfies(try Version.parse("1.9.9")));
    try std.testing.expect(!x3.satisfies(try Version.parse("2.0.0")));
    // build メタデータは任意位置で許容する。
    for ([_][]const u8{ "1+build", "1.2+build", "*+build", "1.x+build" }) |text| {
        var range = try Range.parse(allocator, text);
        defer range.deinit(allocator);
    }
}

test "ID-07 caret上端は-prerelease 0で排他する" {
    const allocator = std.testing.allocator;
    var range = try Range.parse(allocator, "^1.2.3 >=2.0.0-alpha.1");
    defer range.deinit(allocator);
    // `^1.2.3` の `<2.0.0-0` が `2.0.0-alpha.2` を除外する。
    try std.testing.expect(!range.satisfies(try Version.parse("2.0.0-alpha.2")));
    var caret = try Range.parse(allocator, "^1.2.3");
    defer caret.deinit(allocator);
    try std.testing.expect(caret.satisfies(try Version.parse("1.9.0")));
}

fn renderNodeRange(allocator: std.mem.Allocator, range: Range) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const writer = &aw.writer;
    for (range.sets, 0..) |set, set_index| {
        if (set_index > 0) try writer.writeAll(" || ");
        if (set.len == 0) {
            try writer.writeAll("*");
            continue;
        }
        for (set, 0..) |comparator, index| {
            if (index > 0) try writer.writeByte(' ');
            switch (comparator.op) {
                .lt => try writer.writeAll("<"),
                .lte => try writer.writeAll("<="),
                .gt => try writer.writeAll(">"),
                .gte => try writer.writeAll(">="),
                .eq => {},
            }
            try writer.print("{d}.{d}.{d}", .{
                comparator.version.major,
                comparator.version.minor,
                comparator.version.patch,
            });
            if (comparator.version.prerelease.len > 0) {
                try writer.print("-{s}", .{comparator.version.prerelease});
            }
        }
    }
    return allocator.dupe(u8, aw.written());
}

test "node-semver 7.7.4 の wildcard と qualifier を差分照合する" {
    const allocator = std.testing.allocator;
    const Case = struct {
        range: []const u8,
        canonical: []const u8,
        matching: []const []const u8 = &.{},
        non_matching: []const []const u8 = &.{},
    };
    // canonical は実 node-semver 7.7.4 の `validRange()` 出力。
    const cases = [_]Case{
        .{ .range = "1.x.5", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{ "1.0.0", "1.9.9" }, .non_matching = &.{ "0.9.9", "2.0.0", "2.0.0-alpha" } },
        .{ .range = "*.1", .canonical = "*", .matching = &.{ "0.0.0", "9.9.9" }, .non_matching = &.{"1.0.0-alpha"} },
        .{ .range = "*.*.*-alpha", .canonical = "*", .matching = &.{ "0.0.0", "9.9.9" }, .non_matching = &.{"1.0.0-alpha"} },
        .{ .range = "1.x.5-alpha", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.5.0"}, .non_matching = &.{"1.5.0-alpha"} },
        .{ .range = "1.x.5+build", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.5.0"} },
        .{ .range = ">1.x.5", .canonical = ">=2.0.0", .matching = &.{"2.0.0"}, .non_matching = &.{ "1.9.9", "2.0.0-alpha" } },
        .{ .range = "<1.x.5", .canonical = "<1.0.0-0", .matching = &.{"0.9.9"}, .non_matching = &.{"1.0.0"} },
        .{ .range = "<=1.x.5", .canonical = "<2.0.0-0", .matching = &.{"1.9.9"}, .non_matching = &.{"2.0.0"} },
        .{ .range = ">=1.x.5", .canonical = ">=1.0.0", .matching = &.{"1.0.0"}, .non_matching = &.{"0.9.9"} },
        .{ .range = "^1.x.5", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.9.9"}, .non_matching = &.{"2.0.0"} },
        .{ .range = "~1.x.5", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.9.9"}, .non_matching = &.{"2.0.0"} },
        .{ .range = "1.x.5 - 2.x.3", .canonical = ">=1.0.0 <3.0.0-0", .matching = &.{"2.9.9"}, .non_matching = &.{"3.0.0"} },
        .{ .range = "1.2.x-alpha", .canonical = ">=1.2.0 <1.3.0-0", .matching = &.{"1.2.5"} },
        .{ .range = "1.x.x-alpha", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.5.0"} },
        .{ .range = "*.*.5", .canonical = "*", .matching = &.{"9.9.9"}, .non_matching = &.{"1.0.0-alpha"} },
        .{ .range = "x.2.3", .canonical = "*", .matching = &.{"9.9.9"}, .non_matching = &.{"1.0.0-alpha"} },
        .{ .range = "*.1+build", .canonical = "*", .matching = &.{"9.9.9"} },
        .{ .range = "1+build", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.9.9"}, .non_matching = &.{"2.0.0"} },
        .{ .range = "1.2+build", .canonical = ">=1.2.0 <1.3.0-0", .matching = &.{"1.2.9"}, .non_matching = &.{"1.3.0"} },
        .{ .range = "1.x+build", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.9.9"}, .non_matching = &.{"2.0.0"} },
        .{ .range = "1.2.x+build", .canonical = ">=1.2.0 <1.3.0-0", .matching = &.{"1.2.9"}, .non_matching = &.{"1.3.0"} },
        .{ .range = "1.x.5-alpha+build", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.5.0"}, .non_matching = &.{"1.5.0-alpha"} },
        .{ .range = "^=1.2.3", .canonical = ">=1.2.3 <2.0.0-0", .matching = &.{"1.2.3"}, .non_matching = &.{"2.0.0"} },
        .{ .range = "~=1.2.3", .canonical = ">=1.2.3 <1.3.0-0", .matching = &.{"1.2.9"}, .non_matching = &.{"1.3.0"} },
        .{ .range = "^=v1.2.3", .canonical = ">=1.2.3 <2.0.0-0", .matching = &.{"1.9.9"}, .non_matching = &.{"2.0.0"} },
        .{ .range = "~>=v1.2.3", .canonical = ">=1.2.3 <1.3.0-0", .matching = &.{"1.2.9"}, .non_matching = &.{"1.3.0"} },
        .{ .range = "^vvv=1.2.3", .canonical = ">=1.2.3 <2.0.0-0", .matching = &.{"1.9.9"}, .non_matching = &.{"2.0.0"} },
        .{ .range = ">=vv1.2", .canonical = ">=1.2.0", .matching = &.{"1.2.0"}, .non_matching = &.{"1.1.9"} },
        .{ .range = ">=v=1.2", .canonical = ">=1.2.0", .matching = &.{"1.2.0"}, .non_matching = &.{"1.1.9"} },
        .{ .range = "v1.2", .canonical = ">=1.2.0 <1.3.0-0", .matching = &.{"1.2.9"}, .non_matching = &.{"1.3.0"} },
        .{ .range = "vv1.2", .canonical = ">=1.2.0 <1.3.0-0", .matching = &.{"1.2.9"}, .non_matching = &.{"1.3.0"} },
        .{ .range = "v=1.2", .canonical = ">=1.2.0 <1.3.0-0", .matching = &.{"1.2.9"}, .non_matching = &.{"1.3.0"} },
        .{ .range = "v1.2.3", .canonical = "1.2.3", .matching = &.{"1.2.3"}, .non_matching = &.{"1.2.4"} },
        .{ .range = ">v1.2.3", .canonical = ">1.2.3", .matching = &.{"1.2.4"}, .non_matching = &.{"1.2.3"} },
        .{ .range = "1.2.3 - 2.0.0", .canonical = ">=1.2.3 <=2.0.0", .matching = &.{"2.0.0"}, .non_matching = &.{"2.0.1"} },
        .{ .range = "v1.2.3 - v2.0.0", .canonical = ">=1.2.3 <=2.0.0", .matching = &.{"1.2.3"}, .non_matching = &.{"1.2.2"} },
        .{ .range = "1.x - 2.0.0", .canonical = ">=1.0.0 <=2.0.0", .matching = &.{"1.9.9"}, .non_matching = &.{"2.0.1"} },
        .{ .range = "1.2.3 - 2.x", .canonical = ">=1.2.3 <3.0.0-0", .matching = &.{"2.9.9"}, .non_matching = &.{"3.0.0"} },
        .{ .range = "1.2.3 - 2.0.0 || 3.0.0", .canonical = ">=1.2.3 <=2.0.0 || 3.0.0", .matching = &.{ "2.0.0", "3.0.0" }, .non_matching = &.{ "2.0.1", "2.9.9" } },
        .{ .range = "1.2 - 2", .canonical = ">=1.2.0 <3.0.0-0", .matching = &.{"2.9.9"}, .non_matching = &.{"3.0.0"} },
        .{ .range = "^ = 1.2.3", .canonical = ">=1.2.3 <2.0.0-0", .matching = &.{"1.9.9"}, .non_matching = &.{"2.0.0"} },
        .{ .range = "~ =v1.2.3", .canonical = ">=1.2.3 <1.3.0-0", .matching = &.{"1.2.9"}, .non_matching = &.{"1.3.0"} },
        .{ .range = "< =1.2", .canonical = "<1.3.0-0", .matching = &.{"1.2.9"}, .non_matching = &.{"1.3.0"} },
        .{ .range = "< =1.2.3", .canonical = "<=1.2.3", .matching = &.{"1.2.3"}, .non_matching = &.{"1.2.4"} },
        .{ .range = "> =1.2", .canonical = ">=1.2.0", .matching = &.{"1.2.0"}, .non_matching = &.{"1.1.9"} },
        .{ .range = "> =v1.2.3", .canonical = ">=1.2.3", .matching = &.{"1.2.3"}, .non_matching = &.{"1.2.2"} },
        .{ .range = "^9007199254740990.0.0", .canonical = ">=9007199254740990.0.0 <9007199254740991.0.0-0", .matching = &.{"9007199254740990.0.0"}, .non_matching = &.{"9007199254740991.0.0"} },
        .{ .range = "~9007199254740991.0.0", .canonical = ">=9007199254740991.0.0 <9007199254740991.1.0-0", .matching = &.{"9007199254740991.0.9"}, .non_matching = &.{"9007199254740991.1.0"} },
        .{ .range = "1.9007199254740990", .canonical = ">=1.9007199254740990.0 <1.9007199254740991.0-0", .matching = &.{"1.9007199254740990.9"}, .non_matching = &.{"1.9007199254740991.0"} },
        .{ .range = "9007199254740990.x", .canonical = ">=9007199254740990.0.0 <9007199254740991.0.0-0", .matching = &.{"9007199254740990.9.9"}, .non_matching = &.{"9007199254740991.0.0"} },
        .{ .range = "1.x.9007199254740992", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.5.0"}, .non_matching = &.{"2.0.0"} },
        .{ .range = "*.1.9007199254740992", .canonical = "*", .matching = &.{"9.9.9"} },
        .{ .range = "1.x.999999999999999999999999", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.5.0"} },
        .{ .range = "1.x.9007199254740992-alpha", .canonical = ">=1.0.0 <2.0.0-0", .matching = &.{"1.5.0"}, .non_matching = &.{"1.5.0-alpha"} },
        .{ .range = "*.1.999999999999999999999999", .canonical = "*", .matching = &.{"9.9.9"} },
        .{ .range = "\u{00A0}^1.2.3\u{00A0}", .canonical = ">=1.2.3 <2.0.0-0", .matching = &.{"1.9.9"}, .non_matching = &.{"2.0.0"} },
        .{ .range = ">= \u{00A0}1.2.3", .canonical = ">=1.2.3", .matching = &.{"1.2.3"}, .non_matching = &.{"1.2.2"} },
        .{ .range = "1.2.3\u{00A0}-\u{00A0}2.0.0", .canonical = ">=1.2.3 <=2.0.0", .matching = &.{"2.0.0"}, .non_matching = &.{"2.0.1"} },
        .{ .range = "^1.2.3\u{00A0}||\u{3000}2.0.0", .canonical = ">=1.2.3 <2.0.0-0 || 2.0.0", .matching = &.{ "1.9.9", "2.0.0" }, .non_matching = &.{"2.0.1"} },
        .{ .range = "\u{FEFF}~1.2.3\u{FEFF}", .canonical = ">=1.2.3 <1.3.0-0", .matching = &.{"1.2.9"}, .non_matching = &.{"1.3.0"} },
    };
    for (cases) |case| {
        var range = try Range.parseNodeSemver(allocator, case.range);
        defer range.deinit(allocator);
        const rendered = try renderNodeRange(allocator, range);
        defer allocator.free(rendered);
        try std.testing.expectEqualStrings(case.canonical, rendered);
        for (case.matching) |text| {
            try std.testing.expect(range.satisfies(try Version.parse(text)));
        }
        for (case.non_matching) |text| {
            try std.testing.expect(!range.satisfies(try Version.parse(text)));
        }
    }

    for ([_][]const u8{
        "1.x.5.6",   "*.1.2.3",   "*.*.5.6",   "*.*.*.*",   "*-alpha",    "*.*-alpha",   "x-alpha",           "1-alpha",          "1.2-alpha",        "1.x-alpha",
        ">=vv1.2.3", ">=v=1.2.3", ">v=1.2.3",  "==v1.2.3",  "v=1.2.3",    "vv1.2.3",     "1.2.3 - 2.0.0 >=1", "1.2.3 - 2.0.0 <3", "<3 1.2.3 - 2.0.0", "1.2.3 - 2.0.0 3.0.0 - 4.0.0",
        "< = 1.2.3", "> = 1.2.3", ">= =1.2.3", "> ==1.2.3", "~> = 1.2.3", "^ v = 1.2.3",
    }) |text| {
        try std.testing.expectError(error.InvalidRange, Range.parseNodeSemver(allocator, text));
    }

    for ([_][]const u8{
        "^9007199254740991.0.0", "^9007199254740991",  "~9007199254740991",        "9007199254740991",
        "1.9007199254740991",    "9007199254740991.x", "1.2.3 - 9007199254740991", "1.x.05",
        "^1.2.3\u{0085}",        "^1.2.3\u{200B}",
    }) |text| {
        try std.testing.expectError(error.InvalidRange, Range.parseNodeSemver(allocator, text));
    }

    // 旧内部 API は既存の厳格な wildcard 規則を保つ。
    for ([_][]const u8{ "1.x.5", "*.1", "*.*.*-alpha", "1.x.5-alpha", ">1.x.5" }) |text| {
        try std.testing.expectError(error.InvalidRange, Range.parse(allocator, text));
    }
}

test "node-semver mode でも ID-07 の caret 上限を維持する" {
    const allocator = std.testing.allocator;
    var range = try Range.parseNodeSemver(allocator, "^1.2.3 >=2.0.0-alpha.1");
    defer range.deinit(allocator);
    try std.testing.expect(!range.satisfies(try Version.parse("2.0.0-alpha.2")));
    var caret = try Range.parseNodeSemver(allocator, "^1.2.3");
    defer caret.deinit(allocator);
    try std.testing.expect(caret.satisfies(try Version.parse("1.9.0")));
    try std.testing.expect(!caret.satisfies(try Version.parse("2.0.0-alpha.0")));
}

test "v1 入口は不正UTF-8を拒否し、有効なUnicode空白と数値境界を維持する" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "\xE3\x81", // 3バイト文字の末尾2バイト
        "\xF0\x9F", // 4バイト文字の末尾2バイト
        "\xFF", // 不正な先頭バイト
        "\x80", // 孤立した継続バイト
        "^1.2.3\xE3\x81", // 有効な範囲 + 末尾途切れ
        "\u{00A0}^1.2.3\xE3\x81", // 有効な空白 + 末尾途切れ
    }) |text| {
        try std.testing.expectError(error.InvalidRange, Range.parseNodeSemver(allocator, text));
    }

    // 有効な ECMAScript 空白は引き続き受理する。
    var spaced = try Range.parseNodeSemver(allocator, "\u{00A0}^1.2.3\u{00A0}");
    defer spaced.deinit(allocator);
    try std.testing.expect(spaced.satisfies(try Version.parse("1.9.9")));
    try std.testing.expect(spaced.satisfies(try Version.parse("1.2.3")));
    try std.testing.expect(!spaced.satisfies(try Version.parse("2.0.0")));

    // MAX_SAFE_INTEGER 前後の上限判定を維持する。
    try std.testing.expectError(error.InvalidRange, Range.parseNodeSemver(allocator, "^9007199254740991.0.0"));
    var max_ok = try Range.parseNodeSemver(allocator, "^9007199254740990.0.0");
    defer max_ok.deinit(allocator);
    try std.testing.expect(max_ok.satisfies(try Version.parse("9007199254740990.0.0")));
    try std.testing.expect(!max_ok.satisfies(try Version.parse("9007199254740991.0.0")));

    // legacy は従来の経路のまま。不正バイトでも panic せず InvalidRange。
    try std.testing.expectError(error.InvalidRange, Range.parse(allocator, "\xE3\x81"));
}
