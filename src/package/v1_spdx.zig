//! SPDX ライセンス式（SPDX Specification 2.3.1 の Annex D 文法）の検証。
//!
//! ライセンス ID と例外 ID は `v1_spdx_data.zig` の固定版
//! （SPDX License List 3.27.0）だけを正本とし、SPDX 2.3.1 Annex D.2 に従って
//! 大文字小文字を区別せず照合する。演算子 `AND`/`OR`/`WITH` は大文字だけを
//! 受理する。`LicenseRef-` / `DocumentRef-...:LicenseRef-...` は構文上有効な
//! 参照として受理し、`WITH` の左辺（simple-expression）にも使える。
//! 参照先の本文が `.npkg` に収録されているかは、このモジュールの
//! 責務ではない（仕様 §2・§3 の pack/公開時の検査で扱う）。
//!
//! 意味論（ライセンス同士の互換性や `+` の適用可否）は検証しない。

const std = @import("std");
const data = @import("v1_spdx_data.zig");

pub const Error = error{InvalidLicenseExpression};

/// 固定した SPDX License List の版。
pub const license_list_version = data.license_list_version;

/// SPDX ライセンス式として構文と ID の両方が有効なら true。
pub fn isValid(text: []const u8) bool {
    var parser = Parser{ .text = text };
    parser.parseExpression() catch return false;
    parser.skipSpace();
    return parser.index == text.len;
}

/// 単一の licenseId（`+`・`WITH`・`AND`/`OR` を含まない）として有効なら true。
/// 固定一覧の canonical ID と大文字小文字を区別せず照合する（Annex D.2）。
pub fn isKnownLicenseId(text: []const u8) bool {
    return containsId(&data.license_ids, text);
}

/// 単一の licenseExceptionId として有効なら true。
/// 固定一覧の canonical ID と大文字小文字を区別せず照合する（Annex D.2）。
pub fn isKnownExceptionId(text: []const u8) bool {
    return containsId(&data.exception_ids, text);
}

/// `LicenseRef-...` 単体として有効なら true。`DocumentRef-...` は含まない。
pub fn isLicenseRef(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "LicenseRef-")) return false;
    return validIdString(text["LicenseRef-".len..]);
}

/// 式のどこかに `LicenseRef-` 参照を含むなら true。
/// 本文同梱の要否判定（仕様 §2）で使う。
pub fn referencesLicenseRef(expression: []const u8) bool {
    return std.mem.indexOf(u8, expression, "LicenseRef-") != null;
}

/// `DocumentRef-...:LicenseRef-...` 単体として有効なら true。
pub fn isDocumentRef(text: []const u8) bool {
    const rest = parseDocumentRef(text) orelse return false;
    if (!std.mem.startsWith(u8, rest, "LicenseRef-")) return false;
    return validIdString(rest["LicenseRef-".len..]);
}

fn containsId(ids: []const []const u8, text: []const u8) bool {
    if (text.len == 0) return false;
    // SPDX 2.3.1 Annex D.2: license-id / license-exception-id は
    // 大文字小文字を区別せず照合する。固定一覧は ASCII 順で並んでおり
    // 大小無視順ではないため、二分探索ではなく線形照合にする。
    for (ids) |id| {
        if (std.ascii.eqlIgnoreCase(id, text)) return true;
    }
    return false;
}

fn validIdString(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') return false;
    }
    return true;
}

/// `DocumentRef-x:LicenseRef-y` の `:` 以降（`LicenseRef-y`）を返す。
/// 形式が違えば null。
fn parseDocumentRef(text: []const u8) ?[]const u8 {
    const prefix = "DocumentRef-";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
    const document = text[prefix.len..colon];
    if (!validIdString(document)) return null;
    return text[colon + 1 ..];
}

const Parser = struct {
    text: []const u8,
    index: usize = 0,

    fn skipSpace(self: *Parser) void {
        while (self.index < self.text.len and std.ascii.isWhitespace(self.text[self.index])) {
            self.index += 1;
        }
    }

    /// 現在位置がキーワードで、前後に空白があるなら消費する。
    /// SPDX 2.3.1 の文法は `AND`/`OR`/`WITH` の前後に 1 文字以上の空白を要求する。
    fn matchKeyword(self: *Parser, keyword: []const u8) bool {
        const start = self.index;
        self.skipSpace();
        if (self.index == start) return false;
        const rest = self.text[self.index..];
        if (!std.mem.startsWith(u8, rest, keyword)) {
            self.index = start;
            return false;
        }
        if (rest.len == keyword.len) {
            self.index = start;
            return false;
        }
        const next = rest[keyword.len];
        if (!std.ascii.isWhitespace(next)) {
            self.index = start;
            return false;
        }
        self.index += keyword.len;
        return true;
    }

    fn parseExpression(self: *Parser) Error!void {
        try self.parseOr();
    }

    fn parseOr(self: *Parser) Error!void {
        try self.parseAnd();
        while (self.matchKeyword("OR")) try self.parseAnd();
    }

    fn parseAnd(self: *Parser) Error!void {
        try self.parseWith();
        while (self.matchKeyword("AND")) try self.parseWith();
    }

    fn parseWith(self: *Parser) Error!void {
        const simple = try self.parsePrimary();
        if (self.matchKeyword("WITH")) {
            if (!simple) return error.InvalidLicenseExpression;
            try self.parseException();
        }
    }

    /// 戻り値は「裸の simple-expression か」。括弧式なら false。
    fn parsePrimary(self: *Parser) Error!bool {
        self.skipSpace();
        if (self.index >= self.text.len) return error.InvalidLicenseExpression;
        if (self.text[self.index] == '(') {
            self.index += 1;
            try self.parseOr();
            self.skipSpace();
            if (self.index >= self.text.len or self.text[self.index] != ')') return error.InvalidLicenseExpression;
            self.index += 1;
            return false;
        }
        try self.parseLicenseTerm();
        return true;
    }

    fn parseLicenseTerm(self: *Parser) Error!void {
        self.skipSpace();
        const start = self.index;
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.' and byte != ':') break;
            self.index += 1;
        }
        if (self.index == start) return error.InvalidLicenseExpression;
        const token = self.text[start..self.index];

        var has_plus = false;
        if (self.index < self.text.len and self.text[self.index] == '+') {
            has_plus = true;
            self.index += 1;
        }

        if (std.mem.startsWith(u8, token, "DocumentRef-")) {
            if (has_plus) return error.InvalidLicenseExpression;
            const rest = parseDocumentRef(token) orelse return error.InvalidLicenseExpression;
            if (!std.mem.startsWith(u8, rest, "LicenseRef-")) return error.InvalidLicenseExpression;
            if (!validIdString(rest["LicenseRef-".len..])) return error.InvalidLicenseExpression;
            return;
        }
        if (std.mem.startsWith(u8, token, "LicenseRef-")) {
            if (has_plus) return error.InvalidLicenseExpression;
            if (!validIdString(token["LicenseRef-".len..])) return error.InvalidLicenseExpression;
            return;
        }
        if (!isKnownLicenseId(token)) return error.InvalidLicenseExpression;
    }

    fn parseException(self: *Parser) Error!void {
        self.skipSpace();
        const start = self.index;
        while (self.index < self.text.len) {
            const byte = self.text[self.index];
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.') break;
            self.index += 1;
        }
        if (self.index == start) return error.InvalidLicenseExpression;
        if (!isKnownExceptionId(self.text[start..self.index])) return error.InvalidLicenseExpression;
        if (self.index < self.text.len and self.text[self.index] == '+') return error.InvalidLicenseExpression;
    }
};

test "SPDX式の演算子・括弧・WITHを検証する" {
    const valid = [_][]const u8{
        "MIT",
        "Mit",
        "mIt",
        "mit",
        "Apache-2.0",
        "apache-2.0",
        "BSD-3-Clause",
        "MIT OR Apache-2.0",
        "(MIT OR Apache-2.0) AND BSD-3-Clause",
        "Apache-2.0 WITH LLVM-exception",
        "GPL-2.0-only WITH llvm-exception",
        "GPL-2.0+",
        "LicenseRef-Demo",
        "LicenseRef-Demo WITH LLVM-exception",
        "LicenseRef-Demo WITH llvm-exception",
        "DocumentRef-release:LicenseRef-Demo",
        "DocumentRef-release:LicenseRef-Demo WITH LLVM-exception",
        "MIT AND (BSD-3-Clause OR ISC)",
    };
    for (valid) |text| {
        try std.testing.expect(isValid(text));
    }

    const invalid = [_][]const u8{
        "",
        " ",
        "MIT AND",
        "AND MIT",
        "MIT OR OR Apache-2.0",
        "MIT WITH",
        "MIT WITH NotAnException",
        "(MIT OR Apache-2.0",
        "MIT)",
        "()",
        "MIT +",
        "LicenseRef-",
        "LicenseRef-Demo+",
        "DocumentRef-x",
        "DocumentRef-:LicenseRef-x",
        "DocumentRef-x:LicenseRef-",
        "NotALicense",
        "MIT WITH LLVM-exception+",
        "(MIT) WITH LLVM-exception",
        "(LicenseRef-Demo) WITH LLVM-exception",
        "MIT OR",
        "MIT AND (Apache-2.0 OR)",
        // 演算子は大文字だけを受理する（Annex D.2）。
        "MIT and Apache-2.0",
        "MIT or Apache-2.0",
        "MIT with LLVM-exception",
        "MIT And Apache-2.0",
        "MIT oR Apache-2.0",
    };
    for (invalid) |text| {
        try std.testing.expect(!isValid(text));
    }
}

test "SPDX IDの照合は大文字小文字を区別しない" {
    // Annex D.2: MIT / Mit / mIt は同じ識別子として扱う。
    try std.testing.expect(isKnownLicenseId("MIT"));
    try std.testing.expect(isKnownLicenseId("Mit"));
    try std.testing.expect(isKnownLicenseId("mIt"));
    try std.testing.expect(isKnownLicenseId("mit"));
    try std.testing.expect(isKnownLicenseId("aPaChE-2.0"));
    try std.testing.expect(!isKnownLicenseId("NotALicense"));
    try std.testing.expect(!isKnownLicenseId(""));
    try std.testing.expect(isKnownExceptionId("LLVM-exception"));
    try std.testing.expect(isKnownExceptionId("llvm-exception"));
    try std.testing.expect(isKnownExceptionId("LlVm-ExCePtIoN"));
    try std.testing.expect(!isKnownExceptionId("NotAnException"));
    try std.testing.expect(isLicenseRef("LicenseRef-Demo"));
    try std.testing.expect(!isLicenseRef("LicenseRef-"));
    try std.testing.expect(isDocumentRef("DocumentRef-a:LicenseRef-b"));
    try std.testing.expect(referencesLicenseRef("MIT AND LicenseRef-Demo"));
}

test "WITHの左辺はLicenseRefを含むsimple-expressionだけを受理する" {
    // Annex D.4.4: 左辺は simple-expression（license-id / license-id"+" /
    // license-ref）。LicenseRef と DocumentRef 複合形を使える。
    try std.testing.expect(isValid("LicenseRef-Demo WITH LLVM-exception"));
    try std.testing.expect(isValid("DocumentRef-release:LicenseRef-Demo WITH LLVM-exception"));
    try std.testing.expect(isValid("GPL-2.0+ WITH Classpath-exception-2.0"));
    // 括弧式・LicenseRef の `+`・例外の `+` は左辺/右辺の条件を満たさない。
    try std.testing.expect(!isValid("(LicenseRef-Demo) WITH LLVM-exception"));
    try std.testing.expect(!isValid("(GPL-2.0+) WITH Classpath-exception-2.0"));
    try std.testing.expect(!isValid("LicenseRef-Demo+ WITH LLVM-exception"));
}

test "SPDX固定データは辞書順で重複がない" {
    for ([_][]const []const u8{ &data.license_ids, &data.exception_ids }) |ids| {
        for (ids, 0..) |id, index| {
            try std.testing.expect(id.len > 0);
            if (index + 1 < ids.len) {
                try std.testing.expect(std.mem.order(u8, id, ids[index + 1]) == .lt);
            }
        }
    }
    try std.testing.expect(isKnownLicenseId("0BSD"));
    try std.testing.expect(isKnownLicenseId("zlib-acknowledgement"));
    try std.testing.expect(isKnownExceptionId("389-exception"));
}
