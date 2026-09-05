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

pub const TableSortPrimitiveContext = struct {
    values: [3]Value = undefined,
    log: [32]u8 = undefined,
    count: usize = 0,

    pub fn invoke(raw: *anyopaque, _: *Runtime, value: Value, hint: value_mod.PrimitiveHint) anyerror!?Value {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (hint != .number) return null;
        for (self.values, 0..) |known, index| {
            if (!Value.strictEqual(value, known)) continue;
            if (self.count < self.log.len) {
                self.log[self.count] = @intCast('A' + index);
                self.count += 1;
            }
            return .{ .number = @floatFromInt(index + 1) };
        }
        return null;
    }
};

pub fn tableSort(runtime: *Runtime, source: Value, column: Value, numeric: bool) !Value {
    if (source != .array) return error.ArrayExpected;
    var rooted_source = source;
    var rooted_column = column;
    var row: Value = .undefined;
    var left_cell: Value = .undefined;
    var right_cell: Value = .undefined;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    try roots.protect(&rooted_column);
    try roots.protect(&row);
    try roots.protect(&left_cell);
    try roots.protect(&right_cell);
    try rooted_source.array.normalizePresence();
    const original_length = rooted_source.array.len();
    // Array.prototype.sort collects the indexed rows before it invokes the
    // comparator. Keep both merge buffers detached so a cell's
    // valueOf/toString side effect cannot invalidate the values that the
    // official sort already collected.
    const temporary = try runtime.allocator().dupe(Value, rooted_source.array.items.items);
    defer runtime.allocator().free(temporary);
    const temporary_second = try runtime.allocator().dupe(Value, temporary);
    defer runtime.allocator().free(temporary_second);
    const temporary_presence = try runtime.allocator().dupe(bool, rooted_source.array.presence.items);
    defer runtime.allocator().free(temporary_presence);
    const temporary_second_presence = try runtime.allocator().dupe(bool, temporary_presence);
    defer runtime.allocator().free(temporary_second_presence);
    for (temporary) |*item| try roots.protect(item);
    for (temporary_second) |*item| try roots.protect(item);
    var context = V8SortContext{ .table = .{
        .column = &rooted_column,
        .numeric = numeric,
        .left_cell = &left_cell,
        .right_cell = &right_cell,
        .compareFn = &compareTableRows,
    } };
    if (original_length < v8_small_callback_sort_limit) {
        try v8SmallTableSort(
            runtime,
            temporary,
            temporary_presence,
            rooted_column,
            numeric,
            &row,
            &left_cell,
            &right_cell,
        );
    } else {
        try v8TimSortCallback(runtime, temporary, temporary_presence, temporary_second, temporary_second_presence, &context);
    }

    if (rooted_source.array.len() < original_length) {
        const old_length = rooted_source.array.len();
        try rooted_source.array.items.resize(runtime.allocator(), original_length);
        @memset(rooted_source.array.items.items[old_length..], .undefined);
        try rooted_source.array.presence.resize(runtime.allocator(), original_length);
        @memset(rooted_source.array.presence.items[old_length..], false);
    }
    std.mem.copyForwards(Value, rooted_source.array.items.items[0..original_length], temporary);
    std.mem.copyForwards(bool, rooted_source.array.presence.items[0..original_length], temporary_presence);
    return rooted_source;
}

pub fn v8SmallTableSort(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    column: Value,
    numeric: bool,
    pivot: *Value,
    left_cell: *Value,
    right_cell: *Value,
) !void {
    // V8 uses CountAndMakeRun followed by BinaryInsertionSort for arrays
    // shorter than 64 elements. Table sort delegates to Array.sort too, so
    // the observable property conversion order follows the same path.
    if (items.len < 2) return;

    var run_length: usize = 2;
    const first_order = try compareTableRows(
        runtime,
        items[1],
        presence[1],
        items[0],
        presence[0],
        column,
        numeric,
        left_cell,
        right_cell,
    );
    if (first_order == .lt) {
        while (run_length < items.len) : (run_length += 1) {
            const order = try compareTableRows(
                runtime,
                items[run_length],
                presence[run_length],
                items[run_length - 1],
                presence[run_length - 1],
                column,
                numeric,
                left_cell,
                right_cell,
            );
            if (order != .lt) break;
        }
        var left: usize = 0;
        var right: usize = run_length - 1;
        while (left < right) : ({
            left += 1;
            right -= 1;
        }) {
            std.mem.swap(Value, &items[left], &items[right]);
            std.mem.swap(bool, &presence[left], &presence[right]);
        }
    } else {
        while (run_length < items.len) : (run_length += 1) {
            const order = try compareTableRows(
                runtime,
                items[run_length],
                presence[run_length],
                items[run_length - 1],
                presence[run_length - 1],
                column,
                numeric,
                left_cell,
                right_cell,
            );
            if (order == .lt) break;
        }
    }

    var start = run_length;
    while (start < items.len) : (start += 1) {
        pivot.* = items[start];
        const pivot_presence = presence[start];
        var left: usize = 0;
        var right: usize = start;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const order = try compareTableRows(
                runtime,
                pivot.*,
                pivot_presence,
                items[middle],
                presence[middle],
                column,
                numeric,
                left_cell,
                right_cell,
            );
            if (order == .lt) right = middle else left = middle + 1;
        }
        var cursor = start;
        while (cursor > left) : (cursor -= 1) {
            items[cursor] = items[cursor - 1];
            presence[cursor] = presence[cursor - 1];
        }
        items[left] = pivot.*;
        presence[left] = pivot_presence;
    }
}

pub fn compareTableRows(
    runtime: *Runtime,
    left: Value,
    left_present: bool,
    right: Value,
    right_present: bool,
    column: Value,
    numeric: bool,
    left_cell: *Value,
    right_cell: *Value,
) !std.math.Order {
    if (!left_present) return if (!right_present) .eq else .gt;
    if (!right_present) return .lt;
    if (left == .undefined) return if (right == .undefined) .eq else .gt;
    if (right == .undefined) return .lt;
    left_cell.* = try indexed(runtime, left, column);
    right_cell.* = try indexed(runtime, right, column);
    // The official comparator returns before relational conversion when the
    // two selected cells are JavaScript-strictly equal. This is observable
    // for repeated object cells with a custom valueOf/toString method.
    if (!numeric and Value.strictEqual(left_cell.*, right_cell.*)) return .eq;
    if (numeric) {
        // The official comparator is `ns - ms`, not two independent
        // Number conversions.  Keeping the subtraction as a JavaScript-like
        // binary operation preserves BigInt/Number mixing errors and lets the
        // subsequent comparator-result ToNumber reject a BigInt result.
        const difference = try operators.binary(runtime, .subtract, left_cell.*, right_cell.*);
        const number = try runtime.valueToNumber(difference);
        return if (std.math.isNan(number)) .eq else std.math.order(number, 0);
    }
    // The official table comparator is not the abstract-relational boolean
    // used by ordinary comparison operators: after the strict-equality fast
    // path it returns `1` whenever `ns < ms` is false.  That includes NaN and
    // undefined cells, so preserve the non-antisymmetric result instead of
    // collapsing an unordered comparison to equality.
    return (try operators.compare(runtime, left_cell.*, right_cell.*)) orelse .gt;
}
