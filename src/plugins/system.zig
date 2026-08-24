const std = @import("std");
const value_mod = @import("../runtime/value.zig");

pub const constants = @import("system/constants.zig");
pub const common = @import("system/common.zig");
pub const math = @import("system/math.zig");
pub const types = @import("system/types.zig");
pub const strings = @import("system/strings.zig");
pub const json = @import("system/json.zig");
pub const regexp = @import("system/regexp.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    if (std.mem.eql(u8, name, "空配列")) return try runtime.createArray();
    if (std.mem.eql(u8, name, "空辞書") or std.mem.eql(u8, name, "空ハッシュ") or std.mem.eql(u8, name, "空オブジェクト")) return try runtime.createDictionary();
    if (try math.call(runtime, name, arguments)) |value| return value;
    if (try types.call(runtime, name, arguments)) |value| return value;
    if (try strings.call(runtime, name, arguments)) |value| return value;
    if (try json.call(runtime, name, arguments)) |value| return value;
    if (try regexp.call(runtime, name, arguments)) |value| return value;
    return null;
}

test {
    std.testing.refAllDecls(constants);
    std.testing.refAllDecls(common);
    std.testing.refAllDecls(math);
    std.testing.refAllDecls(types);
    std.testing.refAllDecls(strings);
    std.testing.refAllDecls(json);
    std.testing.refAllDecls(regexp);
}
