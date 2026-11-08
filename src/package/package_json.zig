//! `package.json` のパースと Node 互換のフィールド検証（#53）。
//!
//! Node 24.21.0 / 26.13.0 の package.json リーダ（C++ の
//! `modulesBinding.readPackageJSON`）を実際の ESM import で実測した結果に
//! 合わせる。
//!
//! - 先頭の UTF-8 BOM は受理する（BOM 付き package.json を Node は解決できる）。
//! - JSON として不正、または root が object 以外なら `PackageJsonInvalid`。
//! - 重複キーは JS の `JSON.parse` と同じく後勝ち。キー順は最初の出現位置を
//!   保つため、`exports` の条件オブジェクトを挿入順で評価する規則とも一致する。
//! - `name` と `type` は「存在するなら string」でなければ
//!   `ERR_INVALID_PACKAGE_CONFIG`（= `PackageJsonInvalid`）。空文字は受理。
//! - `version` / `main` / `module` は型検証されない。文字列のときだけ保持し、
//!   それ以外は未指定として扱う（`main` が非文字列なら Node は index.js へ落ちる）。
//! - `exports` が string / array / object 以外（`null`・数値・真偽値）なら
//!   exports 無し扱い（Node 実測）。`exports` の意味解釈は `npm_esm` が行う。
//!
//! ここで保持する文字列と値はこの `Manifest` の arena が所有する。呼び出し側は
//! 入力バイト列を `parse` 後すぐに解放してよい。

const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;

pub const Error = error{
    PackageJsonInvalid,
    OutOfMemory,
};

const Value = std.json.Value;

/// パース済み `package.json`。`deinit` までフィールドの slice は有効。
pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    /// `name`（string のみ）。非文字列は `parse` が `PackageJsonInvalid` にする。
    name: ?[]const u8 = null,
    /// `version`（string のみ）。非文字列は保持しない（Node も型検証しない）。
    version: ?[]const u8 = null,
    /// `type`（string のみ）。非文字列は `parse` が `PackageJsonInvalid` にする。
    type: ?[]const u8 = null,
    /// `main`（string のみ）。非文字列は未指定扱い。
    main: ?[]const u8 = null,
    /// `module`（string のみ）。Node は読まない lnako の ESM 入口候補。
    module: ?[]const u8 = null,
    /// `exports` が string / array / object のときだけ設定する。
    /// `null` / 数値 / 真偽値は Node と同じく「exports 無し」。
    exports: ?Value = null,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// 先頭の UTF-8 BOM を除去する。Node は package.json の BOM を受理する
/// （Node 24.21.0 / 26.13.0 実測）。
fn stripBom(bytes: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
}

/// `package.json` の bytes をパースする。エラーは既存の診断カテゴリ
/// `PackageJsonInvalid`（Node の ERR_INVALID_PACKAGE_CONFIG 相当）へ写す。
pub fn parse(gpa: Allocator, bytes: []const u8) Error!Manifest {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const value = std.json.parseFromSliceLeaky(Value, arena.allocator(), stripBom(bytes), .{
        // JS の JSON.parse と同じく後勝ち。キー順は最初の出現位置のままなので
        // 条件オブジェクトの評価順も Node と一致する。
        .duplicate_field_behavior = .use_last,
        // 入力バイト列は呼び出し側が parse 後に解放し得るため、文字列は常に
        // arena へ複製する（alloc_if_needed だと入力 slice を指し得る）。
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PackageJsonInvalid,
    };
    const object = switch (value) {
        .object => |obj| obj,
        else => return error.PackageJsonInvalid,
    };

    // この時点で arena への追加確保は完了している。`errdefer` はローカルの
    // `arena` を解放するため、ここから先で arena に確保を足さないこと
    // （足す場合は copy より前に寄せる）。
    var manifest = Manifest{ .arena = arena };
    // `name` / `type` は存在するなら string 必須（Node 実測: 非 string は
    // ERR_INVALID_PACKAGE_CONFIG）。空文字はどちらも受理される。
    if (object.get("name")) |field| manifest.name = try stringField(field);
    if (object.get("type")) |field| manifest.type = try stringField(field);
    // `version` / `main` / `module` は Node が型検証しない（実測）。
    if (object.get("version")) |field| {
        if (field == .string) manifest.version = field.string;
    }
    if (object.get("main")) |field| {
        if (field == .string) manifest.main = field.string;
    }
    if (object.get("module")) |field| {
        if (field == .string) manifest.module = field.string;
    }
    // Node は `exports` が string / array / object 以外なら exports 無しとして
    // legacy main 解決へ落ちる。
    if (object.get("exports")) |field| {
        switch (field) {
            .string, .array, .object => manifest.exports = field,
            else => {},
        }
    }
    return manifest;
}

fn stringField(field: Value) Error![]const u8 {
    return switch (field) {
        .string => |text| text,
        else => error.PackageJsonInvalid,
    };
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "package_json: name/version/main/module/exports を保持する" {
    const gpa = testing.allocator;
    const json =
        \\{
        \\  "name": "left-pad",
        \\  "version": "1.2.3",
        \\  "type": "module",
        \\  "main": "lib/main.js",
        \\  "module": "lib/main.mjs",
        \\  "exports": { ".": "./dist/index.mjs" }
        \\}
    ;
    var manifest = try parse(gpa, json);
    defer manifest.deinit();
    try testing.expectEqualStrings("left-pad", manifest.name.?);
    try testing.expectEqualStrings("1.2.3", manifest.version.?);
    try testing.expectEqualStrings("module", manifest.type.?);
    try testing.expectEqualStrings("lib/main.js", manifest.main.?);
    try testing.expectEqualStrings("lib/main.mjs", manifest.module.?);
    try testing.expect(manifest.exports.?.object.get(".") != null);
}

test "package_json: 入力 bytes を解放しても保持した文字列が有効" {
    const gpa = testing.allocator;
    const bytes = try gpa.dupe(u8, "{\"name\":\"pkg\",\"main\":\"index.js\"}");
    var manifest = try parse(gpa, bytes);
    defer manifest.deinit();
    gpa.free(bytes);
    // alloc_always で arena へ複製しているため、入力解放後も参照できる。
    try testing.expectEqualStrings("pkg", manifest.name.?);
    try testing.expectEqualStrings("index.js", manifest.main.?);
}

test "package_json: 先頭の UTF-8 BOM を受理する（Node 24/26 実測）" {
    const gpa = testing.allocator;
    var manifest = try parse(gpa, "\xEF\xBB\xBF{\"name\":\"pkg\",\"exports\":\"./index.mjs\"}");
    defer manifest.deinit();
    try testing.expectEqualStrings("pkg", manifest.name.?);
    try testing.expectEqualStrings("./index.mjs", manifest.exports.?.string);
}

test "package_json: BOM だけ・空入力・空白のみは不正" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "", "   \n", "\xEF\xBB\xBF", "\xEF\xBB\xBF  " }) |json| {
        try testing.expectError(error.PackageJsonInvalid, parse(gpa, json));
    }
}

test "package_json: 不正 JSON は PackageJsonInvalid" {
    const gpa = testing.allocator;
    // trailing comma・閉じ忘れ・単一引用符・制御文字は Node の
    // JSON.parse と同じく ERR_INVALID_PACKAGE_CONFIG（Node 24/26 実測）。
    for ([_][]const u8{
        "{\"name\":\"pkg\",}",
        "{\"name\":\"pkg\"",
        "{'name':'pkg'}",
        "{\"name\":\"p\x01kg\"}",
        "{\"name\":\"pkg\"} {\"main\":\"x.js\"}",
    }) |json| {
        try testing.expectError(error.PackageJsonInvalid, parse(gpa, json));
    }
}

test "package_json: root が object 以外は不正" {
    const gpa = testing.allocator;
    // Node 実測: `[]` や `"hi"` の package.json は ERR_INVALID_PACKAGE_CONFIG。
    for ([_][]const u8{ "[]", "\"hi\"", "5", "null", "true" }) |json| {
        try testing.expectError(error.PackageJsonInvalid, parse(gpa, json));
    }
}

test "package_json: 重複キーは後勝ちでキー順は最初の出現位置" {
    const gpa = testing.allocator;
    // Node の JSON.parse（= package.json リーダ）と同じ規則。
    var manifest = try parse(gpa, "{\"name\":\"first\",\"main\":\"a.js\",\"name\":\"last\"}");
    defer manifest.deinit();
    try testing.expectEqualStrings("last", manifest.name.?);
    try testing.expectEqualStrings("a.js", manifest.main.?);

    // exports オブジェクトのキー順は最初の出現位置のまま（条件評価順に影響）。
    var exports_manifest = try parse(
        gpa,
        "{\"exports\":{\"import\":\"./a.mjs\",\"default\":\"./b.js\",\"import\":\"./c.mjs\"}}",
    );
    defer exports_manifest.deinit();
    var it = exports_manifest.exports.?.object.iterator();
    const first = it.next().?;
    try testing.expectEqualStrings("import", first.key_ptr.*);
    try testing.expectEqualStrings("./c.mjs", first.value_ptr.string);
    const second = it.next().?;
    try testing.expectEqualStrings("default", second.key_ptr.*);
    try testing.expectEqualStrings("./b.js", second.value_ptr.string);
    try testing.expect(it.next() == null);
}

test "package_json: name 非文字列は PackageJsonInvalid（Node 24/26 実測）" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        "{\"name\":5}",
        "{\"name\":null}",
        "{\"name\":true}",
        "{\"name\":{}}",
        "{\"name\":[]}",
    }) |json| {
        try testing.expectError(error.PackageJsonInvalid, parse(gpa, json));
    }
    // 空文字は Node でも受理される。
    var empty_name = try parse(gpa, "{\"name\":\"\"}");
    defer empty_name.deinit();
    try testing.expectEqualStrings("", empty_name.name.?);
}

test "package_json: type 非文字列は PackageJsonInvalid（Node 24/26 実測）" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "{\"type\":5}", "{\"type\":null}", "{\"type\":[]}", "{\"type\":{}}" }) |json| {
        try testing.expectError(error.PackageJsonInvalid, parse(gpa, json));
    }
    // 文字列なら任意の値・空文字を Node は受理する。
    for ([_][]const u8{ "{\"type\":\"module\"}", "{\"type\":\"commonjs\"}", "{\"type\":\"unknown\"}", "{\"type\":\"\"}" }) |json| {
        var manifest = try parse(gpa, json);
        defer manifest.deinit();
        try testing.expect(manifest.type != null);
    }
}

test "package_json: version 非文字列は保持しない（Node は型検証しない）" {
    const gpa = testing.allocator;
    for ([_][]const u8{ "{\"version\":5}", "{\"version\":null}", "{\"version\":{}}" }) |json| {
        var manifest = try parse(gpa, json);
        defer manifest.deinit();
        try testing.expect(manifest.version == null);
    }
}

test "package_json: main/module 非文字列は未指定扱い（Node 実測で main は index.js へ）" {
    const gpa = testing.allocator;
    var manifest = try parse(gpa, "{\"main\":5,\"module\":false}");
    defer manifest.deinit();
    try testing.expect(manifest.main == null);
    try testing.expect(manifest.module == null);
    // 文字列の空値は Node がそのまま legacy 解決へ渡すため保持する。
    var empty = try parse(gpa, "{\"main\":\"\",\"module\":\"\"}");
    defer empty.deinit();
    try testing.expectEqualStrings("", empty.main.?);
    try testing.expectEqualStrings("", empty.module.?);
}

test "package_json: exports は string/array/object のときだけ保持する（Node 実測）" {
    const gpa = testing.allocator;
    for ([_][]const u8{
        "{\"exports\":null}",
        "{\"exports\":5}",
        "{\"exports\":true}",
        "{\"exports\":false}",
    }) |json| {
        var manifest = try parse(gpa, json);
        defer manifest.deinit();
        try testing.expect(manifest.exports == null);
    }
    // 空配列も「exports あり・root 非公開」なので保持する。
    for ([_][]const u8{
        "{\"exports\":\"./index.mjs\"}",
        "{\"exports\":[]}",
        "{\"exports\":{}}",
        "{\"exports\":{\".\":[{\"import\":null},\"./x.mjs\"]}}",
    }) |json| {
        var manifest = try parse(gpa, json);
        defer manifest.deinit();
        try testing.expect(manifest.exports != null);
    }
}

test "package_json: 重複した exports キーは最後の値が採用される" {
    const gpa = testing.allocator;
    // Node 実測: `{"exports":"./a.mjs","exports":"./b.mjs"}` は b.mjs を解決する。
    var manifest = try parse(gpa, "{\"exports\":\"./a.mjs\",\"exports\":\"./b.mjs\"}");
    defer manifest.deinit();
    try testing.expectEqualStrings("./b.mjs", manifest.exports.?.string);
    // 最後が非対応型なら exports 無し扱い（後勝ちの結果として一貫）。
    var scalar = try parse(gpa, "{\"exports\":\"./a.mjs\",\"exports\":5}");
    defer scalar.deinit();
    try testing.expect(scalar.exports == null);
}

test "package_json: 重複した name は後勝ちの値で型検証する" {
    const gpa = testing.allocator;
    // Node 実測: `{"name":"pkg","name":5}` は ERR_INVALID_PACKAGE_CONFIG。
    try testing.expectError(error.PackageJsonInvalid, parse(gpa, "{\"name\":\"pkg\",\"name\":5}"));
    // 逆順なら最後の文字列が採用される。
    var manifest = try parse(gpa, "{\"name\":5,\"name\":\"pkg\"}");
    defer manifest.deinit();
    try testing.expectEqualStrings("pkg", manifest.name.?);
}
