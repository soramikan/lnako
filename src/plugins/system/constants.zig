const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const system_constant = @import("../../runtime/system_constant.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const Installer = struct {
    context: *anyopaque,
    setFn: *const fn (context: *anyopaque, name: []const u8, value: Value) anyerror!void,

    pub fn set(self: Installer, name: []const u8, value: Value) !void {
        try self.setFn(self.context, name, value);
    }
};

const StringConstant = struct { name: []const u8, value: []const u8 };

pub fn install(runtime: *Runtime, installer: Installer) !void {
    for (system_constant.scalar_entries) |constant| try installer.set(constant.name, switch (constant.value) {
        .undefined => .undefined,
        .null_value => .null_value,
        .boolean => |value| .{ .boolean = value },
        .number => |value| .{ .number = value },
    });
    for (string_constants) |constant| try installer.set(constant.name, try runtime.stringUtf8(constant.value));
    try installer.set("抽出文字列", try runtime.createArray());
    try installer.set("__DEBUGブレイクポイント一覧", try runtime.createArray());
}

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
    .{ .name = "プラグイン名", .value = "メイン" },
    .{ .name = "名前空間", .value = "" },
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
    try std.testing.expect(context.values.get("__DEBUGブレイクポイント一覧").? == .array);
    try std.testing.expectEqual(@as(f64, 0), context.values.get("__DEBUG待機フラグ").?.number);
}

fn valueUtf8(allocator: std.mem.Allocator, value: Value) ![]u8 {
    if (value != .string) return error.ExpectedString;
    return value.string.toUtf8Lossy(allocator);
}
