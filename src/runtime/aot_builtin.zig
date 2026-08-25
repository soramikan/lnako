const std = @import("std");

pub const Command = enum(u16) {
    to_string,
    type_of,
    to_int,
    to_float,
    is_nan,
    is_number_nan,
    radix16,
    radix,
    radix2,
    radix2_display,
};

pub fn lookup(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, "文字列変換") or std.mem.eql(u8, name, "TOSTR")) return .to_string;
    if (std.mem.eql(u8, name, "変数型確認") or std.mem.eql(u8, name, "TYPEOF")) return .type_of;
    if (std.mem.eql(u8, name, "整数変換") or std.mem.eql(u8, name, "TOINT") or std.mem.eql(u8, name, "INT")) return .to_int;
    if (std.mem.eql(u8, name, "実数変換") or std.mem.eql(u8, name, "TOFLOAT") or std.mem.eql(u8, name, "FLOAT")) return .to_float;
    if (std.mem.eql(u8, name, "NAN判定")) return .is_nan;
    if (std.mem.eql(u8, name, "非数判定")) return .is_number_nan;
    if (std.mem.eql(u8, name, "HEX")) return .radix16;
    if (std.mem.eql(u8, name, "進数変換")) return .radix;
    if (std.mem.eql(u8, name, "二進")) return .radix2;
    if (std.mem.eql(u8, name, "二進表示")) return .radix2_display;
    return null;
}

test "AOT標準命令の正式名と別名を同じIDへ解決する" {
    try std.testing.expectEqual(Command.to_string, lookup("文字列変換").?);
    try std.testing.expectEqual(Command.to_string, lookup("TOSTR").?);
    try std.testing.expectEqual(Command.type_of, lookup("変数型確認").?);
    try std.testing.expectEqual(Command.type_of, lookup("TYPEOF").?);
    try std.testing.expectEqual(Command.to_int, lookup("整数変換").?);
    try std.testing.expectEqual(Command.to_int, lookup("TOINT").?);
    try std.testing.expectEqual(Command.to_int, lookup("INT").?);
    try std.testing.expectEqual(Command.to_float, lookup("実数変換").?);
    try std.testing.expectEqual(Command.to_float, lookup("TOFLOAT").?);
    try std.testing.expectEqual(Command.to_float, lookup("FLOAT").?);
    try std.testing.expectEqual(Command.is_nan, lookup("NAN判定").?);
    try std.testing.expectEqual(Command.is_number_nan, lookup("非数判定").?);
    try std.testing.expectEqual(Command.radix16, lookup("HEX").?);
    try std.testing.expectEqual(Command.radix, lookup("進数変換").?);
    try std.testing.expectEqual(Command.radix2, lookup("二進").?);
    try std.testing.expectEqual(Command.radix2_display, lookup("二進表示").?);
    try std.testing.expect(lookup("未対応命令") == null);
}
