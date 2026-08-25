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
};

pub fn lookupScalar(name: []const u8) ?Scalar {
    for (scalar_entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.value;
    }
    return null;
}

test "v3.7.24のスカラーシステム定数を解決する" {
    try std.testing.expect(lookupScalar("true").?.boolean);
    try std.testing.expect(!lookupScalar("FALSE").?.boolean);
    try std.testing.expectEqual(std.math.pi, lookupScalar("PI").?.number);
    try std.testing.expect(std.math.isNan(lookupScalar("非数").?.number));
    try std.testing.expect(lookupScalar("NULL").? == .null_value);
    try std.testing.expect(lookupScalar("未定義").? == .undefined);
    try std.testing.expect(lookupScalar("ナデシコバージョン") == null);
}
