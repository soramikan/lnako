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
    pub fn parse(text: []const u8) Error!Version {
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

fn numericPart(text: []const u8) Error!u64 {
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
fn validateIdentifiers(text: []const u8, strict_numeric: bool) Error!void {
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
/// `sets.len == 0` は全バージョンに一致する。
pub const Range = struct {
    sets: []const []const Comparator,
    text: []const u8,

    pub fn deinit(self: *Range, allocator: std.mem.Allocator) void {
        for (self.sets) |set| allocator.free(set);
        allocator.free(self.sets);
        self.* = undefined;
    }

    /// npm(node-semver)互換の範囲構文を解析する。
    /// 対応形式: `*`、`x`、部分バージョン、`^`/`~`、`>`系、`-` ハイフン、`||`。
    /// 構文エラーは `error.InvalidRange` に正規化する。
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Range {
        var sets: std.ArrayList([]const Comparator) = .empty;
        errdefer {
            for (sets.items) |set| allocator.free(set);
            sets.deinit(allocator);
        }
        // 空文字は node-semver と同じく全バージョン一致として扱う。
        if (std.mem.trim(u8, text, " \t").len == 0) {
            try sets.append(allocator, &.{});
            return .{ .sets = try sets.toOwnedSlice(allocator), .text = text };
        }
        // `||` のみが OR 区切り。空の選択肢は node-semver と同じく `*` として扱う。
        var alternatives = std.mem.splitSequence(u8, text, "||");
        while (alternatives.next()) |alternative| {
            if (std.mem.trim(u8, alternative, " \t").len == 0) {
                try sets.append(allocator, &.{});
                continue;
            }
            const set = parseSet(allocator, alternative) catch |err| switch (err) {
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

fn parsePartial(text: []const u8) Error!Partial {
    var rest = text;
    // node-semver は範囲内のバージョン前置 `v` を剥がす（`v1.2.3`）。
    // バージョン位置の `=` は意図的に受理しない。node-semver 7.x の
    // `[v=\s]*` 前置より厳しいが、npm/node-semver#691 で提案される
    // 次期メジャーの `v?` のみ前置と一致する（`=` は演算子としてのみ有効）。
    if (rest.len > 0 and rest[0] == 'v') rest = rest[1..];
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

    var result: Partial = .{ .major = null, .minor = null, .patch = null, .prerelease = prerelease };
    if (isWildcard(major_text)) {
        if (minor_text != null or patch_text != null) return error.InvalidRange;
        return result;
    }
    result.major = try numericPart(major_text);
    if (minor_text) |minor| {
        if (isWildcard(minor)) {
            if (patch_text != null) return error.InvalidRange;
            return result;
        }
        result.minor = try numericPart(minor);
    }
    if (patch_text) |patch| {
        if (isWildcard(patch)) return result;
        result.patch = try numericPart(patch);
    }
    if (prerelease.len > 0 and (result.minor == null or result.patch == null)) return error.InvalidRange;
    return result;
}

fn partialToVersion(partial: Partial) Version {
    return .{
        .major = partial.major orelse 0,
        .minor = partial.minor orelse 0,
        .patch = partial.patch orelse 0,
        .prerelease = partial.prerelease,
    };
}

/// `^1.2.3` 等の上限を返す。左端の非ゼロ要素を保持する。
fn caretUpper(partial: Partial) ?Version {
    const major = partial.major orelse return null;
    if (partial.minor == null) {
        // `^1`/`^0` は `~` と同等ではなく `>=x.0.0 <(x+1).0.0`
        return .{ .major = major + 1, .minor = 0, .patch = 0 };
    }
    const minor = partial.minor.?;
    if (partial.patch == null) {
        if (major > 0) return .{ .major = major + 1, .minor = 0, .patch = 0 };
        return .{ .major = 0, .minor = minor + 1, .patch = 0 };
    }
    const patch = partial.patch.?;
    if (major > 0) return .{ .major = major + 1, .minor = 0, .patch = 0 };
    if (minor > 0) return .{ .major = 0, .minor = minor + 1, .patch = 0 };
    if (patch > 0) return .{ .major = 0, .minor = 0, .patch = patch + 1 };
    return .{ .major = 0, .minor = 0, .patch = 1 };
}

/// `~1.2`/`~1.2.3`/`~1` の上限を返す。
fn tildeUpper(partial: Partial) ?Version {
    const major = partial.major orelse return null;
    if (partial.minor == null) return .{ .major = major + 1, .minor = 0, .patch = 0 };
    return .{ .major = major, .minor = partial.minor.? + 1, .patch = 0 };
}

fn wildcardUpper(partial: Partial) ?Version {
    const major = partial.major orelse return null;
    if (partial.minor == null) return .{ .major = major + 1, .minor = 0, .patch = 0 };
    return .{ .major = major, .minor = partial.minor.? + 1, .patch = 0 };
}

fn appendBound(list: *std.ArrayList(Comparator), allocator: std.mem.Allocator, op: Op, version: Version) Error!void {
    try list.append(allocator, .{ .op = op, .version = version });
}

/// 1つの比較トークン（`^1.2`、`>=1.0.0`、`1.2.x` 等）を AND 比較子列へ展開する。
fn expandToken(allocator: std.mem.Allocator, list: *std.ArrayList(Comparator), token: []const u8) Error!void {
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
    try expandOp(allocator, list, op_text, rest);
}

/// 演算子とバージョン文字列を比較子列へ展開する。`rest` は呼出し側が
/// 所有するテキストのスライスで、比較子はそのスライスを参照してよい。
fn expandOp(allocator: std.mem.Allocator, list: *std.ArrayList(Comparator), op_text: []const u8, rest: []const u8) Error!void {
    const partial = try parsePartial(rest);

    if (std.mem.eql(u8, op_text, "^")) {
        const lower = partialToVersion(partial);
        const upper = caretUpper(partial) orelse return; // `^*` は制約なし
        try appendBound(list, allocator, .gte, lower);
        try appendBound(list, allocator, .lt, upper);
        return;
    }
    if (std.mem.eql(u8, op_text, "~") or std.mem.eql(u8, op_text, "~>")) {
        const lower = partialToVersion(partial);
        const upper = tildeUpper(partial) orelse return;
        try appendBound(list, allocator, .gte, lower);
        try appendBound(list, allocator, .lt, upper);
        return;
    }
    if (std.mem.eql(u8, op_text, ">=") or std.mem.eql(u8, op_text, ">")) {
        const is_gte = op_text.len == 2;
        if (partial.major == null) {
            // node-semver は `>*` を `<0.0.0-0`（空範囲）、`>=*` を `*` に写す。
            if (!is_gte) try appendBound(list, allocator, .lt, .{ .major = 0, .minor = 0, .patch = 0, .prerelease = "0" });
            return;
        }
        if (partial.minor != null and partial.patch != null) {
            try appendBound(list, allocator, if (is_gte) .gte else .gt, partialToVersion(partial));
        } else if (is_gte) {
            // `>=1.2` は `>=1.2.0`
            try appendBound(list, allocator, .gte, partialToVersion(partial));
        } else {
            // `>1.2` は `>=1.3.0`
            try appendBound(list, allocator, .gte, wildcardUpper(partial).?);
        }
        return;
    }
    if (std.mem.eql(u8, op_text, "<=") or std.mem.eql(u8, op_text, "<")) {
        const is_lte = op_text.len == 2;
        if (partial.major == null) {
            // node-semver は `<*` を `<0.0.0-0`（空範囲）、`<=*` を `*` に写す。
            if (!is_lte) try appendBound(list, allocator, .lt, .{ .major = 0, .minor = 0, .patch = 0, .prerelease = "0" });
            return;
        }
        if (partial.minor != null and partial.patch != null) {
            try appendBound(list, allocator, if (is_lte) .lte else .lt, partialToVersion(partial));
        } else if (is_lte) {
            // `<=1.2` は `<1.3.0`
            try appendBound(list, allocator, .lt, wildcardUpper(partial).?);
        } else {
            // `<1.2` は `<1.2.0`
            try appendBound(list, allocator, .lt, partialToVersion(partial));
        }
        return;
    }
    // 演算子なし / `=` / 部分バージョン。
    if (partial.major == null) return; // `*` 相当
    if (partial.minor == null or partial.patch == null) {
        const lower = partialToVersion(partial);
        const upper = wildcardUpper(partial).?;
        try appendBound(list, allocator, .gte, lower);
        try appendBound(list, allocator, .lt, upper);
        return;
    }
    try appendBound(list, allocator, .eq, partialToVersion(partial));
}

/// 1つの OR 選択肢（空白区切りの AND 比較子）を解析する。
fn parseSet(allocator: std.mem.Allocator, alternative: []const u8) Error![]const Comparator {
    var tokens: std.ArrayList([]const u8) = .empty;
    defer tokens.deinit(allocator);
    var iter = std.mem.tokenizeAny(u8, alternative, " \t");
    while (iter.next()) |token| try tokens.append(allocator, token);
    if (tokens.items.len == 0) return error.InvalidRange;

    var list: std.ArrayList(Comparator) = .empty;
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < tokens.items.len) {
        const token = tokens.items[i];
        if (std.mem.eql(u8, token, "-")) return error.InvalidRange;
        if (i + 2 < tokens.items.len and std.mem.eql(u8, tokens.items[i + 1], "-")) {
            try expandHyphen(allocator, &list, token, tokens.items[i + 2]);
            i += 3;
            continue;
        }
        // node-semver は `> 1.2.3` のような演算子とバージョンの空白区切りを許容する。
        // join せず別引数で渡す（比較子が参照するバージョン文字列を
        // 呼出し側テキストのスライスのまま保持するため）。
        if (isLoneOperator(token)) {
            if (i + 1 >= tokens.items.len or std.mem.eql(u8, tokens.items[i + 1], "-")) return error.InvalidRange;
            try expandOp(allocator, &list, token, tokens.items[i + 1]);
            i += 2;
            continue;
        }
        try expandToken(allocator, &list, token);
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
fn expandHyphen(allocator: std.mem.Allocator, list: *std.ArrayList(Comparator), lower_text: []const u8, upper_text: []const u8) Error!void {
    const lower = try parsePartial(lower_text);
    const upper = try parsePartial(upper_text);
    if (lower.major != null) {
        try appendBound(list, allocator, .gte, partialToVersion(lower));
    }
    if (upper.major == null) {
        return;
    } else if (upper.minor == null) {
        try appendBound(list, allocator, .lt, .{ .major = upper.major.? + 1, .minor = 0, .patch = 0 });
    } else if (upper.patch == null) {
        try appendBound(list, allocator, .lt, .{ .major = upper.major.?, .minor = upper.minor.? + 1, .patch = 0 });
    } else {
        try appendBound(list, allocator, .lte, partialToVersion(upper));
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
fn setsIntersect(a: []const Comparator, b: []const Comparator) bool {
    var lower: ?Comparator = null;
    var upper: ?Comparator = null;
    var exact: ?Comparator = null;
    for ([_][]const Comparator{ a, b }) |set| {
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
            // prerelease 版は各集合に同タプルの prerelease 比較子を要求する。
            // `>=1.0.0` ∩ `=2.0.0-alpha` のような衝突を取りこぼさないため。
            for ([_][]const Comparator{ a, b }) |set| {
                var gated = false;
                for (set) |comparator| {
                    const other = comparator.version;
                    if (other.prerelease.len > 0 and other.major == v.major and other.minor == v.minor and other.patch == v.patch) {
                        gated = true;
                        break;
                    }
                }
                if (!gated) return false;
            }
        }
        return true;
    }
    if (lower != null and upper != null) {
        const ord = lower.?.version.order(upper.?.version);
        if (ord == .gt) return false;
        if (ord == .eq) {
            return lower.?.op == .gte and upper.?.op == .lte;
        }
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
