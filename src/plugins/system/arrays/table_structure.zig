const std = @import("std");
const value_mod = @import("../../../runtime/value.zig");
const shared = @import("shared.zig");
const Value = shared.Value;
const Runtime = shared.Runtime;
const Context = shared.Context;
const ByteKind = shared.ByteKind;

const common = @import("../common.zig");
const regexp = @import("../regexp.zig");
const operators = @import("../../../runtime/operators.zig");
const prototype_mod = @import("prototype.zig");
const sort = @import("sort.zig");
const SortCallback = sort.SortCallback;
const V8SortContext = sort.V8SortContext;
const appendArraySlot = shared.appendArraySlot;
const byteBufferAllowsStandardPrototype = prototype_mod.byteBufferAllowsStandardPrototype;
const byteBufferSlice = prototype_mod.byteBufferSlice;
const indexed = shared.indexed;
const isObjectPrototypeKey = prototype_mod.isObjectPrototypeKey;
const safe_array_element_limit = shared.safe_array_element_limit;
const spliceIndex = shared.spliceIndex;
const tableInheritedProperty = prototype_mod.tableInheritedProperty;
const testElementCountFunction = shared.testElementCountFunction;
const v8TimSortCallback = sort.v8TimSortCallback;
const v8_small_callback_sort_limit = sort.v8_small_callback_sort_limit;

pub fn tableColumnCount(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [2]Value{ source, .{ .number = 1 } };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    for (rooted[0].array.items.items) |row| {
        const length = try rowLengthValue(runtime, row);
        if ((try operators.compare(runtime, length, rooted[1])) == .gt) rooted[1] = length;
    }
    return rooted[1];
}

pub fn rowLengthValue(runtime: *Runtime, row: Value) !Value {
    return switch (row) {
        .array => |array| .{ .number = @floatFromInt(array.len()) },
        .string => |string| .{ .number = @floatFromInt(string.len()) },
        .bytes => |buffer| blk: {
            // Buffer/TypedArray length is supplied by the built-in exotic
            // object, but a custom __proto__ can shadow that named lookup.
            // ArrayBuffer has no ordinary length fallback, so retain its
            // undefined result when the custom chain has no value.
            var units = [_]u16{ 'l', 'e', 'n', 'g', 't', 'h' };
            if (try tableInheritedProperty(runtime, row, &units)) |value| break :blk value;
            if (!byteBufferAllowsStandardPrototype(buffer)) break :blk .undefined;
            break :blk if (buffer.kind == .array_buffer) .undefined else .{ .number = @floatFromInt(buffer.bytes.len) };
        },
        .null_value, .undefined => {
            const receiver = if (row == .null_value) "null" else "undefined";
            const message = try std.fmt.allocPrint(runtime.allocator(), "Cannot read properties of {s} (reading 'length')", .{receiver});
            defer runtime.allocator().free(message);
            try runtime.setFailureMessage(message);
            return error.TableRowMissing;
        },
        .dictionary => |dictionary| blk: {
            var units = [_]u16{ 'l', 'e', 'n', 'g', 't', 'h' };
            var key = value_mod.String{ .allocator = dictionary.allocator, .units = &units };
            // `表列数` reads `row.length` directly.  A dictionary's own
            // property wins, but JavaScript then continues through its
            // custom `__proto__` chain before falling back to the ordinary
            // Object prototype.  Keep this path aligned with `indexed` and
            // the AOT row-property implementation instead of limiting it to
            // own keys.
            break :blk dictionary.get(&key) orelse (try tableInheritedProperty(runtime, row, &units)) orelse .undefined;
        },
        // The official compiler wraps Nadesiko functions in a rest-argument
        // closure, whose JavaScript Function.length is always zero.
        .function => .{ .number = 0 },
        else => .undefined,
    };
}

pub fn tableRowCount(source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    return .{ .number = @floatFromInt(source.array.len()) };
}

pub fn transpose(runtime: *Runtime, source: Value, rotate: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [4]Value{ source, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[1] = try tableColumnCount(runtime, rooted[0]);
    const columns = try tableIterationCount(runtime, rooted[1]);
    const cells = std.math.mul(usize, columns, rooted[0].array.len()) catch return error.ArraySizeLimitExceeded;
    if (cells > safe_array_element_limit) return error.ArraySizeLimitExceeded;
    rooted[2] = try runtime.createArray();
    for (0..columns) |column| {
        var row_result = try runtime.createArray();
        try roots.protect(&row_result);
        for (0..rooted[0].array.len()) |offset| {
            const row_index = if (rotate) rooted[0].array.len() - offset - 1 else offset;
            const row = rooted[0].array.get(row_index);
            rooted[3] = try indexed(runtime, row, .{ .number = @floatFromInt(column) });
            if (!rotate and rooted[3] == .undefined) rooted[3] = try runtime.stringUtf8("");
            _ = try row_result.array.push(rooted[3]);
        }
        _ = try rooted[2].array.push(row_result);
    }
    return rooted[2];
}

pub fn tableIterationCount(runtime: *Runtime, value: Value) !usize {
    const number = if (value == .bigint) value.bigint.toF64() else try runtime.valueToNumber(value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > safe_array_element_limit) return error.ArraySizeLimitExceeded;
    return @intFromFloat(@ceil(number));
}
