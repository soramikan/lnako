const std = @import("std");
const shared = @import("shared.zig");

const Value = shared.Value;
const Runtime = shared.Runtime;
const Context = shared.Context;
const NetworkAddresses = shared.NetworkAddresses;

pub fn callNetwork(runtime: *Runtime, context: Context, name: []const u8, arguments: []const Value) !?Value {
    _ = arguments;
    if (std.mem.eql(u8, name, "自分IPアドレス取得") or std.mem.eql(u8, name, "自分IPV6アドレス取得")) {
        const function = context.networkAddressesFn orelse return error.NetworkInterfacesUnavailable;
        var addresses = try function(context.context, runtime.allocator(), std.mem.eql(u8, name, "自分IPV6アドレス取得"));
        defer addresses.deinit(runtime.allocator());
        var result = try runtime.createArray();
        var roots = runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        for (addresses.items) |address| _ = try result.array.push(try runtime.stringUtf8(address));
        return @as(?Value, result);
    }
    return null;
}
