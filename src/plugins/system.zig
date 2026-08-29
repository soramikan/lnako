const std = @import("std");
const value_mod = @import("../runtime/value.zig");

pub const constants = @import("system/constants.zig");
pub const common = @import("system/common.zig");
pub const math = @import("system/math.zig");
pub const types = @import("system/types.zig");
pub const strings = @import("system/strings.zig");
pub const json = @import("system/json.zig");
pub const regexp = @import("system/regexp.zig");
pub const arrays = @import("system/arrays.zig");
pub const dictionaries = @import("system/dictionaries.zig");
pub const url = @import("system/url.zig");
pub const datetime = @import("system/datetime.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const Context = struct {
    arrays: arrays.Context,
    strings: strings.Context,
    datetime: datetime.Context,
    path_separator: []const u8 = std.fs.path.sep_str,
};

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    return callWithContext(runtime, name, arguments, null);
}

pub fn callWithContext(runtime: *Runtime, name: []const u8, arguments: []const Value, context: ?Context) !?Value {
    if (std.mem.eql(u8, name, "空配列")) return try runtime.createArray();
    if (std.mem.eql(u8, name, "空辞書") or std.mem.eql(u8, name, "空ハッシュ") or std.mem.eql(u8, name, "空オブジェクト")) return try runtime.createDictionary();
    if (try math.call(runtime, name, arguments)) |value| return value;
    if (try types.call(runtime, name, arguments)) |value| return value;
    if (try strings.callWithContext(runtime, name, arguments, if (context) |actual| actual.strings else null)) |value| return value;
    if (try json.call(runtime, name, arguments)) |value| return value;
    if (try regexp.call(runtime, name, arguments)) |value| return value;
    if (try arrays.call(runtime, name, arguments, if (context) |actual| actual.arrays else null)) |value| return value;
    if (try dictionaries.call(runtime, name, arguments)) |value| return value;
    if (try url.callWithSeparator(runtime, name, arguments, if (context) |actual| actual.path_separator else std.fs.path.sep_str)) |value| return value;
    if (try datetime.call(runtime, name, arguments, if (context) |actual| actual.datetime else null)) |value| return value;
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
    std.testing.refAllDecls(arrays);
    std.testing.refAllDecls(dictionaries);
    std.testing.refAllDecls(url);
    std.testing.refAllDecls(datetime);
}
