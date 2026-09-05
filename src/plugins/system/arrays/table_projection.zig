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

pub fn tableColumn(runtime: *Runtime, source: Value, column: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [3]Value{ source, column, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[2] = try runtime.createArray();
    try rooted[0].array.normalizePresence();
    for (rooted[0].array.items.items, 0..) |row, index| {
        if (rooted[0].array.isPresent(index)) {
            _ = try rooted[2].array.push(try indexed(runtime, row, rooted[1]));
        } else {
            try appendArraySlot(rooted[2].array, .undefined, false);
        }
    }
    return rooted[2];
}

pub fn tableInsertColumn(runtime: *Runtime, source: Value, column_value: Value, values: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [6]Value{ source, column_value, values, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[3] = try runtime.createArray();
    if (rooted[0].array.len() == 0) return rooted[3];
    try rooted[0].array.normalizePresence();
    const positive_order = try operators.compare(runtime, rooted[1], .{ .number = 0 });
    const positive = positive_order != null and positive_order.? == .gt;
    for (rooted[0].array.items.items, 0..) |row, index| {
        // Array.prototype.forEach skips holes in the outer table.  An
        // explicit undefined row remains observable and therefore follows
        // the existing row-type error path below.
        if (!rooted[0].array.isPresent(index)) continue;
        rooted[4] = try runtime.createArray();
        if (row == .array) {
            try row.array.normalizePresence();
            if (positive) {
                const prefix = spliceIndex(try runtime.valueToNumber(rooted[1]), row.array.len());
                for (row.array.items.items[0..prefix], 0..) |item, row_index| try appendArraySlot(rooted[4].array, item, row.array.isPresent(row_index));
            }
            rooted[5] = if (rooted[2] == .array) rooted[2].array.get(index) else try indexed(runtime, rooted[2], .{ .number = @floatFromInt(index) });
            _ = try rooted[4].array.push(rooted[5]);
            const suffix = spliceIndex(try runtime.valueToNumber(rooted[1]), row.array.len());
            for (row.array.items.items[suffix..], suffix..) |item, row_index| try appendArraySlot(rooted[4].array, item, row.array.isPresent(row_index));
        } else if (row == .string) {
            if (positive) {
                const prefix = spliceIndex(try runtime.valueToNumber(rooted[1]), row.string.len());
                rooted[5] = try runtime.stringCodeUnits(row.string.units[0..prefix]);
                _ = try rooted[4].array.push(rooted[5]);
            }
            rooted[5] = if (rooted[2] == .array) rooted[2].array.get(index) else try indexed(runtime, rooted[2], .{ .number = @floatFromInt(index) });
            _ = try rooted[4].array.push(rooted[5]);
            const suffix = spliceIndex(try runtime.valueToNumber(rooted[1]), row.string.len());
            rooted[5] = try runtime.stringCodeUnits(row.string.units[suffix..]);
            _ = try rooted[4].array.push(rooted[5]);
        } else if (row == .bytes) {
            const length = row.bytes.bytes.len;
            if (positive) {
                const prefix = spliceIndex(try runtime.valueToNumber(rooted[1]), length);
                rooted[5] = try byteBufferSlice(runtime, row.bytes, 0, prefix);
                _ = try rooted[4].array.push(rooted[5]);
            }
            rooted[5] = if (rooted[2] == .array) rooted[2].array.get(index) else try indexed(runtime, rooted[2], .{ .number = @floatFromInt(index) });
            _ = try rooted[4].array.push(rooted[5]);
            const suffix = spliceIndex(try runtime.valueToNumber(rooted[1]), length);
            rooted[5] = try byteBufferSlice(runtime, row.bytes, suffix, length);
            _ = try rooted[4].array.push(rooted[5]);
        } else return error.ArrayExpected;
        _ = try rooted[3].array.push(rooted[4]);
    }
    return rooted[3];
}

pub fn tableDeleteColumn(runtime: *Runtime, source: Value, column_value: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [4]Value{ source, column_value, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[2] = try runtime.createArray();
    try rooted[0].array.normalizePresence();
    for (rooted[0].array.items.items, 0..) |row, row_index| {
        if (!rooted[0].array.isPresent(row_index)) continue;
        if (row != .array) return error.ArrayExpected;
        rooted[3] = try runtime.createArray();
        try row.array.normalizePresence();
        const column = spliceIndex(try runtime.valueToNumber(rooted[1]), row.array.len());
        for (row.array.items.items, 0..) |item, index| {
            if (index != column) try appendArraySlot(rooted[3].array, item, row.array.isPresent(index));
        }
        _ = try rooted[2].array.push(rooted[3]);
    }
    return rooted[2];
}

pub fn tableColumnSum(runtime: *Runtime, source: Value, column: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [4]Value{ source, column, .{ .number = 0 }, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    try rooted[0].array.normalizePresence();
    for (rooted[0].array.items.items, 0..) |row, index| {
        if (!rooted[0].array.isPresent(index)) continue;
        rooted[3] = try indexed(runtime, row, rooted[1]);
        rooted[2] = try operators.binary(runtime, .add, rooted[2], rooted[3]);
    }
    return rooted[2];
}
