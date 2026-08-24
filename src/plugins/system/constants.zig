const std = @import("std");
const value_mod = @import("../../runtime/value.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const Installer = struct {
    context: *anyopaque,
    setFn: *const fn (context: *anyopaque, name: []const u8, value: Value) anyerror!void,

    pub fn set(self: Installer, name: []const u8, value: Value) !void {
        try self.setFn(self.context, name, value);
    }
};

const BooleanConstant = struct { name: []const u8, value: bool };
const NumberConstant = struct { name: []const u8, value: f64 };
const StringConstant = struct { name: []const u8, value: []const u8 };

pub fn install(runtime: *Runtime, installer: Installer) !void {
    for (boolean_constants) |constant| try installer.set(constant.name, .{ .boolean = constant.value });
    for (number_constants) |constant| try installer.set(constant.name, .{ .number = constant.value });
    try installer.set("非数", .{ .number = std.math.nan(f64) });
    try installer.set("無限大", .{ .number = std.math.inf(f64) });
    try installer.set("NULL", .null_value);
    try installer.set("undefined", .undefined);
    try installer.set("未定義", .undefined);
    for (string_constants) |constant| try installer.set(constant.name, try runtime.stringUtf8(constant.value));
    try installer.set("抽出文字列", try runtime.createArray());
}

const boolean_constants = [_]BooleanConstant{
    .{ .name = "はい", .value = true },
    .{ .name = "いいえ", .value = false },
    .{ .name = "真", .value = true },
    .{ .name = "偽", .value = false },
    .{ .name = "永遠", .value = true },
    .{ .name = "オン", .value = true },
    .{ .name = "オフ", .value = false },
    .{ .name = "OK", .value = true },
    .{ .name = "NG", .value = false },
    .{ .name = "TRUE", .value = true },
    .{ .name = "FALSE", .value = false },
    .{ .name = "true", .value = true },
    .{ .name = "false", .value = false },
};

const number_constants = [_]NumberConstant{
    .{ .name = "キャンセル", .value = 0 },
    .{ .name = "PI", .value = std.math.pi },
    .{ .name = "戻値無", .value = 0 },
    .{ .name = "戻値有", .value = 1 },
};

const string_constants = [_]StringConstant{
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
};

test "v3.7.24のシステム定数を実体化する" {
    const Context = struct {
        values: std.StringHashMapUnmanaged(Value) = .empty,
        fn set(raw: *anyopaque, name: []const u8, value: Value) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try self.values.put(std.testing.allocator, name, value);
        }
    };
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var context = Context{};
    defer context.values.deinit(std.testing.allocator);
    try install(&runtime, .{ .context = &context, .setFn = Context.set });
    try std.testing.expectEqual(@as(f64, std.math.pi), context.values.get("PI").?.number);
    const version = try valueUtf8(std.testing.allocator, context.values.get("ナデシコバージョン").?);
    defer std.testing.allocator.free(version);
    try std.testing.expectEqualStrings("3.7.24", version);
    try std.testing.expect(context.values.get("抽出文字列").? == .array);
}

fn valueUtf8(allocator: std.mem.Allocator, value: Value) ![]u8 {
    if (value != .string) return error.ExpectedString;
    return value.string.toUtf8Lossy(allocator);
}
