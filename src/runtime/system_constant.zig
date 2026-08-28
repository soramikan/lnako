const std = @import("std");

pub const Scalar = union(enum) {
    undefined,
    null_value,
    boolean: bool,
    number: f64,
};

pub const Entry = struct {
    name: []const u8,
    value: Scalar,
};

pub const StringEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const scalar_entries = [_]Entry{
    .{ .name = "はい", .value = .{ .boolean = true } },
    .{ .name = "いいえ", .value = .{ .boolean = false } },
    .{ .name = "真", .value = .{ .boolean = true } },
    .{ .name = "偽", .value = .{ .boolean = false } },
    .{ .name = "永遠", .value = .{ .boolean = true } },
    .{ .name = "オン", .value = .{ .boolean = true } },
    .{ .name = "オフ", .value = .{ .boolean = false } },
    .{ .name = "OK", .value = .{ .boolean = true } },
    .{ .name = "NG", .value = .{ .boolean = false } },
    .{ .name = "TRUE", .value = .{ .boolean = true } },
    .{ .name = "FALSE", .value = .{ .boolean = false } },
    .{ .name = "true", .value = .{ .boolean = true } },
    .{ .name = "false", .value = .{ .boolean = false } },
    .{ .name = "キャンセル", .value = .{ .number = 0 } },
    .{ .name = "PI", .value = .{ .number = std.math.pi } },
    .{ .name = "戻値無", .value = .{ .number = 0 } },
    .{ .name = "戻値有", .value = .{ .number = 1 } },
    .{ .name = "__DEBUG強制待機", .value = .{ .number = 0 } },
    .{ .name = "__DEBUG待機フラグ", .value = .{ .number = 0 } },
    .{ .name = "非数", .value = .{ .number = std.math.nan(f64) } },
    .{ .name = "無限大", .value = .{ .number = std.math.inf(f64) } },
    .{ .name = "NULL", .value = .null_value },
    .{ .name = "undefined", .value = .undefined },
    .{ .name = "未定義", .value = .undefined },
    .{ .name = "HTTPメソッド", .value = .null_value },
    .{ .name = "GETデータ", .value = .null_value },
    .{ .name = "POSTデータ", .value = .null_value },
    .{ .name = "FILESデータ", .value = .null_value },
};

pub const string_entries = [_]StringEntry{
    .{ .name = "ナデシコバージョン", .value = "3.7.24" },
    .{ .name = "ナデシコ言語バージョン", .value = "3.7.24" },
    .{ .name = "ナデシコエンジン", .value = "nadesi.com/v3" },
    .{ .name = "ナデシコ種類", .value = "cnako3" },
    .{ .name = "改行", .value = "\n" },
    .{ .name = "タブ", .value = "\t" },
    .{ .name = "カッコ", .value = "「" },
    .{ .name = "カッコ閉", .value = "」" },
    .{ .name = "波カッコ", .value = "{" },
    .{ .name = "波カッコ閉", .value = "}" },
    .{ .name = "空", .value = "" },
    .{ .name = "エラーメッセージ", .value = "" },
    .{ .name = "対象", .value = "" },
    .{ .name = "対象キー", .value = "" },
    .{ .name = "回数", .value = "" },
    .{ .name = "CR", .value = "\r" },
    .{ .name = "LF", .value = "\n" },
    .{ .name = "全角カナ一覧", .value = "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンァィゥェォャュョッ、。ー「」" },
    .{ .name = "全角カナ濁音一覧", .value = "ガギグゲゴザジズゼゾダヂヅデドバビブベボパピプペポ" },
    .{ .name = "半角カナ一覧", .value = "ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜｦﾝｧｨｩｪｫｬｭｮｯ､｡ｰ｢｣ﾞﾟ" },
    .{ .name = "半角カナ濁音一覧", .value = "ｶﾞｷﾞｸﾞｹﾞｺﾞｻﾞｼﾞｽﾞｾﾞｿﾞﾀﾞﾁﾞﾂﾞﾃﾞﾄﾞﾊﾞﾋﾞﾌﾞﾍﾞﾎﾞﾊﾟﾋﾟﾌﾟﾍﾟﾎﾟ" },
    .{ .name = "表示ログ", .value = "" },
    .{ .name = "AJAXオプション", .value = "" },
    .{ .name = "ファイルコピーデフォルト動作", .value = "上書禁止" },
    .{ .name = "圧縮解凍ツールパス", .value = "7z" },
    .{ .name = "プラグイン名", .value = "メイン" },
    .{ .name = "名前空間", .value = "" },
};

pub const array_names = [_][]const u8{
    "抽出文字列",
    "__DEBUGブレイクポイント一覧",
};

pub const dictionary_names = [_][]const u8{
    "ブラウザ名変換表",
};

pub const era_data_names = [_][]const u8{
    "元号データ",
};

pub fn lookupScalar(name: []const u8) ?Scalar {
    for (scalar_entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.value;
    }
    return null;
}

pub fn lookupString(name: []const u8) ?[]const u8 {
    for (string_entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.value;
    }
    return null;
}

pub fn isArray(name: []const u8) bool {
    for (array_names) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

pub fn isDictionary(name: []const u8) bool {
    for (dictionary_names) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

pub fn isEraData(name: []const u8) bool {
    for (era_data_names) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

test "v3.7.24のスカラーシステム定数を解決する" {
    try std.testing.expect(lookupScalar("true").?.boolean);
    try std.testing.expect(!lookupScalar("FALSE").?.boolean);
    try std.testing.expectEqual(std.math.pi, lookupScalar("PI").?.number);
    try std.testing.expect(std.math.isNan(lookupScalar("非数").?.number));
    try std.testing.expect(lookupScalar("NULL").? == .null_value);
    try std.testing.expect(lookupScalar("未定義").? == .undefined);
    try std.testing.expect(lookupScalar("ナデシコバージョン") == null);
    try std.testing.expectEqualStrings("3.7.24", lookupString("ナデシコバージョン").?);
    try std.testing.expectEqualStrings("\n", lookupString("改行").?);
    try std.testing.expectEqualStrings("", lookupString("AJAXオプション").?);
    try std.testing.expectEqualStrings("上書禁止", lookupString("ファイルコピーデフォルト動作").?);
    try std.testing.expectEqualStrings("7z", lookupString("圧縮解凍ツールパス").?);
    try std.testing.expect(lookupScalar("HTTPメソッド").? == .null_value);
    try std.testing.expect(lookupScalar("GETデータ").? == .null_value);
    try std.testing.expect(lookupScalar("POSTデータ").? == .null_value);
    try std.testing.expect(lookupScalar("FILESデータ").? == .null_value);
    try std.testing.expect(lookupString("PI") == null);
    try std.testing.expect(isArray("抽出文字列"));
    try std.testing.expect(isArray("__DEBUGブレイクポイント一覧"));
    try std.testing.expect(!isArray("空"));
    try std.testing.expect(isDictionary("ブラウザ名変換表"));
    try std.testing.expect(!isDictionary("対応ブラウザ一覧取得"));
    try std.testing.expect(isEraData("元号データ"));
    try std.testing.expect(!isEraData("曜日"));
}
