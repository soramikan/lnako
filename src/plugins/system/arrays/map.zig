const std = @import("std");
const value_mod = @import("../../../runtime/value.zig");
const shared = @import("shared.zig");
const Value = shared.Value;
const Runtime = shared.Runtime;
const Context = shared.Context;
const ByteKind = shared.ByteKind;

pub fn map(runtime: *Runtime, function_value: Value, source: Value, context: ?Context, filtering: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    var callable = try Context.resolve(context, runtime, function_value);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&callable);
    var result = try runtime.createArray();
    try roots.protect(&result);
    for (source.array.items.items) |item| {
        const mapped = try Context.invoke(context, callable, &.{item});
        if (!filtering) _ = try result.array.push(mapped) else if (mapped.toBoolean()) _ = try result.array.push(item);
    }
    return result;
}
