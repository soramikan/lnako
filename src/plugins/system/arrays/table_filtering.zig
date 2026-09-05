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

pub fn tablePickup(runtime: *Runtime, source: Value, column: Value, needle: Value, exact: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [7]Value{ source, column, needle, .undefined, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[3] = try runtime.createArray();
    if (!exact) rooted[4] = try runtime.valueToString(rooted[2]);
    try rooted[0].array.normalizePresence();
    for (rooted[0].array.items.items, 0..) |row, index| {
        // Array.prototype.filter skips holes but invokes the callback for an
        // explicit undefined row, which then fails during row[index].
        if (!rooted[0].array.isPresent(index)) continue;
        rooted[5] = try indexed(runtime, row, rooted[1]);
        const matches = if (exact) Value.strictEqual(rooted[5], rooted[2]) else blk: {
            rooted[6] = try runtime.valueToString(rooted[5]);
            break :blk std.mem.indexOf(u16, rooted[6].string.units, rooted[4].string.units) != null;
        };
        if (matches) _ = try rooted[3].array.push(row);
    }
    return rooted[3];
}

pub fn tableSearch(runtime: *Runtime, source: Value, column: Value, row_value: Value, needle: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [6]Value{ source, column, row_value, needle, row_value, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    while ((try operators.compare(runtime, rooted[4], .{ .number = @floatFromInt(rooted[0].array.len()) })) == .lt) {
        rooted[5] = try indexed(runtime, rooted[0], rooted[4]);
        const cell = try indexed(runtime, rooted[5], rooted[1]);
        if (Value.strictEqual(cell, rooted[3])) return rooted[4];
        rooted[4] = try incrementTableSearchRow(runtime, rooted[4]);
    }
    return .{ .number = -1 };
}

pub fn incrementTableSearchRow(runtime: *Runtime, row: Value) !Value {
    if (row == .bigint) {
        var one = try value_mod.BigInt.init(runtime.allocator(), 1);
        defer one.deinit();
        return runtime.ownBigInt(try row.bigint.add(runtime.allocator(), one));
    }
    return .{ .number = try runtime.valueToNumber(row) + 1 };
}

pub fn tableUnique(runtime: *Runtime, source: Value, column: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [5]Value{ source, column, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[2] = try runtime.createArray();
    rooted[3] = try runtime.createDictionary();
    for (rooted[0].array.items.items) |row| {
        rooted[4] = try runtime.valueToString(try indexed(runtime, row, rooted[1]));
        if (!isObjectPrototypeKey(rooted[4].string.units) and !rooted[3].dictionary.has(rooted[4].string)) {
            try rooted[3].dictionary.set(rooted[4].string, .{ .boolean = true });
            _ = try rooted[2].array.push(row);
        }
    }
    return rooted[2];
}

pub fn tableRegexpSearch(runtime: *Runtime, source: Value, row_value: Value, column: Value, pattern: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [8]Value{ source, row_value, column, pattern, row_value, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    // The upstream command constructs RegExp before entering the loop.  This
    // makes an invalid pattern fail even when the table is empty or the raw
    // start value is already out of range.
    rooted[7] = if (rooted[3] == .undefined) try runtime.stringCodeUnits(&.{}) else try runtime.valueToString(rooted[3]);
    var compiled = regexp.RawPattern.init(runtime.allocator(), rooted[7].string.units, false) catch |failure| {
        try regexp.setCompileFailureMessage(runtime, rooted[7].string.units, false, failure);
        return failure;
    };
    defer compiled.deinit();
    while ((try operators.compare(runtime, rooted[4], .{ .number = @floatFromInt(rooted[0].array.len()) })) == .lt) {
        rooted[5] = try indexed(runtime, rooted[0], rooted[4]);
        rooted[6] = try indexed(runtime, rooted[5], rooted[2]);
        rooted[6] = try runtime.valueToString(rooted[6]);
        if (try compiled.matches(rooted[6].string.units)) return rooted[4];
        rooted[4] = try incrementTableSearchRow(runtime, rooted[4]);
    }
    return .{ .number = -1 };
}

pub fn tableRegexpPickup(runtime: *Runtime, source: Value, column: Value, pattern: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted = [8]Value{ source, column, pattern, .undefined, .undefined, .undefined, .undefined, .undefined };
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[6] = if (rooted[2] == .undefined) try runtime.stringCodeUnits(&.{}) else try runtime.valueToString(rooted[2]);
    var compiled = regexp.RawPattern.init(runtime.allocator(), rooted[6].string.units, false) catch |failure| {
        try regexp.setCompileFailureMessage(runtime, rooted[6].string.units, false, failure);
        return failure;
    };
    defer compiled.deinit();
    rooted[3] = try runtime.createArray();
    for (rooted[0].array.items.items) |row| {
        rooted[4] = try indexed(runtime, row, rooted[1]);
        rooted[7] = try runtime.valueToString(rooted[4]);
        if (!(try compiled.matches(rooted[7].string.units))) continue;
        rooted[5] = switch (row) {
            .array => blk: {
                const copy = try runtime.createArray();
                rooted[5] = copy;
                try row.array.normalizePresence();
                for (row.array.items.items, 0..) |item, index| {
                    try appendArraySlot(rooted[5].array, item, row.array.isPresent(index));
                }
                break :blk rooted[5];
            },
            .string => row,
            .bytes => |buffer| switch (buffer.kind) {
                .buffer => try runtime.createByteBufferView(buffer, 0, buffer.bytes.len),
                .uint8_array => try runtime.createUint8Array(buffer.bytes),
                .array_buffer => try runtime.createArrayBuffer(buffer.bytes),
            },
            else => return error.ArrayExpected,
        };
        _ = try rooted[3].array.push(rooted[5]);
    }
    return rooted[3];
}
