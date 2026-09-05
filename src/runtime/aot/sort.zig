const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const numberValue = aot_state.numberValue;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const stringUtf8Alloc = aot_state.stringUtf8Alloc;
const isString = aot_state.isString;
const valueTruthy = aot_state.valueTruthy;
const parseFloatBuiltin = aot_state.parseFloatBuiltin;
const arrayItems = aot_state.arrayItems;
const nextRandom = aot_state.nextRandom;
const compareTableRowsBuiltin = aot_state.compareTableRowsBuiltin;
const lnako_aot_function_call = aot_state.lnako_aot_function_call;

pub fn arrayOrderingBuiltin(runtime: *Runtime, command: aot_builtin.Command, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    const items = &object.payload.array;
    switch (command) {
        .array_reverse => {
            try runtime.normalizeAotArrayPresence(object);
            std.mem.reverse(Value, items.items);
            std.mem.reverse(bool, object.array_presence.items);
            return source;
        },
        .array_numeric_convert => {
            var source_root = source;
            var roots = RootFrame{};
            runtime.pushRoots(&roots, @ptrCast(&source_root), 1);
            defer runtime.popRoots(&roots);
            try runtime.normalizeAotArrayPresence(object);
            for (items.items, 0..) |*item, index| {
                item.* = numberValue(try parseFloatBuiltin(runtime, item.*));
                // Assignment through every indexed position materializes a
                // hole as the parsed value of undefined (NaN).
                object.array_presence.items[index] = true;
            }
            return source_root;
        },
        .array_sort, .array_numeric_sort => return try stableArraySort(runtime, source, command == .array_numeric_sort),
        .array_shuffle => return try arrayShuffleBuiltin(runtime, source),
        else => unreachable,
    }
}

pub fn arrayShuffleBuiltin(runtime: *Runtime, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    try runtime.normalizeAotArrayPresence(object);
    var index = object.payload.array.items.len;
    while (index > 1) {
        index -= 1;
        const random_index: usize = @intFromFloat(@floor(nextRandom(runtime) * @as(f64, @floatFromInt(index + 1))));
        std.mem.swap(Value, &object.payload.array.items[index], &object.payload.array.items[random_index]);
        // The upstream implementation uses two indexed assignments.  A hole
        // reads as undefined, while both assignment targets become present.
        object.array_presence.items[index] = true;
        object.array_presence.items[random_index] = true;
    }
    return source;
}

pub fn arrayCallbackBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 2) return error.InvalidArgumentCount;
    var roots = [_]Value{ arguments[0], arguments[1], .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try resolveAotCallback(runtime, roots[0]);
    _ = try arrayItems(roots[1]);
    if (command == .array_custom_sort) return try stableArrayCallbackSort(runtime, roots[1], roots[0]);

    roots[2] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[2]);
    var index: usize = 0;
    while (index < (try arrayItems(roots[1])).items.len) : (index += 1) {
        const item = (try arrayItems(roots[1])).items[index];
        roots[3] = item;
        const mapped = try invokeAotCallback(runtime, roots[0], @ptrCast(&roots[3]), 1);
        roots[3] = mapped;
        if (command != .array_filter or valueTruthy(mapped)) try result.append(runtime.allocator, if (command == .array_filter) item else mapped);
    }
    return roots[2];
}

pub fn stableArrayCallbackSort(runtime: *Runtime, source: Value, callable: Value) !Value {
    const items = try arrayItems(source);
    const original_length = items.items.len;
    if (original_length < 2) return source;

    const object = source.object() orelse return error.InvalidArray;
    try runtime.normalizeAotArrayPresence(object);

    const first = try runtime.allocator.dupe(Value, items.items);
    defer runtime.allocator.free(first);
    const second = try runtime.allocator.dupe(Value, first);
    defer runtime.allocator.free(second);
    const first_presence = try runtime.allocator.dupe(bool, object.array_presence.items);
    defer runtime.allocator.free(first_presence);
    const second_presence = try runtime.allocator.dupe(bool, first_presence);
    defer runtime.allocator.free(second_presence);

    const root_count = std.math.add(usize, 4, std.math.mul(usize, original_length, 2) catch return error.ArrayTooLarge) catch return error.ArrayTooLarge;
    const root_values = try runtime.allocator.alloc(Value, root_count);
    defer runtime.allocator.free(root_values);
    root_values[0] = source;
    root_values[1] = callable;
    root_values[2] = .{};
    root_values[3] = .{};
    std.mem.copyForwards(Value, root_values[4 .. 4 + original_length], first);
    std.mem.copyForwards(Value, root_values[4 + original_length ..], second);
    var roots = RootFrame{};
    runtime.pushRoots(&roots, root_values.ptr, root_values.len);
    defer runtime.popRoots(&roots);
    var sort_context = V8SortContext{ .callback = .{
        .callable_root = &root_values[1],
        .result_root = &root_values[2],
    } };

    if (original_length < v8_small_callback_sort_limit) {
        try v8SmallArrayCallbackSort(runtime, first, first_presence, &root_values[1], &root_values[2], &root_values[3]);
    } else {
        try v8TimSortArrayCallback(runtime, first, first_presence, second, second_presence, &sort_context, &root_values[3]);
    }

    if (items.items.len < original_length) {
        const old_length = items.items.len;
        try items.resize(runtime.allocator, original_length);
        @memset(items.items[old_length..], .{});
        try object.array_presence.resize(runtime.allocator, original_length);
        @memset(object.array_presence.items[old_length..], false);
    }
    std.mem.copyForwards(Value, items.items[0..original_length], first);
    std.mem.copyForwards(bool, object.array_presence.items[0..original_length], first_presence);
    return root_values[0];
}

pub const v8_small_callback_sort_limit: usize = 64;
const v8_timsort_max_pending_runs: usize = 85;
const v8_timsort_min_gallop: usize = 7;

const V8ArraySortRun = struct {
    base: usize,
    length: usize,
};

pub const V8TableSortContext = struct {
    column_root: *Value,
    numeric: bool,
    left_cell_root: *Value,
    right_cell_root: *Value,
};

pub const V8SortContext = union(enum) {
    callback: struct {
        callable_root: *Value,
        result_root: *Value,
    },
    table: V8TableSortContext,
};

pub fn compareV8Sort(
    runtime: *Runtime,
    left: Value,
    left_present: bool,
    right: Value,
    right_present: bool,
    context: *V8SortContext,
) !std.math.Order {
    return switch (context.*) {
        .callback => |callback| compareAotCallback(
            runtime,
            callback.callable_root.*,
            left,
            left_present,
            right,
            right_present,
            callback.result_root,
        ),
        .table => |table| compareTableRowsBuiltin(
            runtime,
            left,
            left_present,
            right,
            right_present,
            table.column_root.*,
            table.numeric,
            table.left_cell_root,
            table.right_cell_root,
        ),
    };
}

pub fn v8SmallArrayCallbackSort(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    callable_root: *Value,
    result_root: *Value,
    pivot_root: *Value,
) !void {
    // V8 uses CountAndMakeRun followed by BinaryInsertionSort when the
    // receiver length is below 64. The collected AOT values stay detached
    // from the live array until stableArrayCallbackSort commits the result.
    if (items.len < 2) return;

    var run_length: usize = 2;
    const first_order = try compareAotCallback(runtime, callable_root.*, items[1], presence[1], items[0], presence[0], result_root);
    if (first_order == .lt) {
        while (run_length < items.len) : (run_length += 1) {
            const order = try compareAotCallback(runtime, callable_root.*, items[run_length], presence[run_length], items[run_length - 1], presence[run_length - 1], result_root);
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
            const order = try compareAotCallback(runtime, callable_root.*, items[run_length], presence[run_length], items[run_length - 1], presence[run_length - 1], result_root);
            if (order == .lt) break;
        }
    }

    var start = run_length;
    while (start < items.len) : (start += 1) {
        pivot_root.* = items[start];
        const pivot_presence = presence[start];
        var left: usize = 0;
        var right: usize = start;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const order = try compareAotCallback(runtime, callable_root.*, pivot_root.*, pivot_presence, items[middle], presence[middle], result_root);
            if (order == .lt) right = middle else left = middle + 1;
        }
        var cursor = start;
        while (cursor > left) : (cursor -= 1) {
            items[cursor] = items[cursor - 1];
            presence[cursor] = presence[cursor - 1];
        }
        items[left] = pivot_root.*;
        presence[left] = pivot_presence;
    }
}

pub fn v8CopyArrayRange(comptime T: type, destination: []T, destination_index: usize, source: []const T, source_index: usize, length: usize) void {
    if (length == 0) return;
    if (@intFromPtr(destination.ptr) == @intFromPtr(source.ptr) and destination_index > source_index) {
        var offset = length;
        while (offset > 0) {
            offset -= 1;
            destination[destination_index + offset] = source[source_index + offset];
        }
    } else {
        std.mem.copyForwards(T, destination[destination_index .. destination_index + length], source[source_index .. source_index + length]);
    }
}

pub fn v8ComputeMinRunLengthArray(length: usize) usize {
    var n = length;
    var remainder: usize = 0;
    while (n >= 64) {
        remainder |= n & 1;
        n >>= 1;
    }
    return n + remainder;
}

pub fn v8CountAndMakeRunArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    low: usize,
    high: usize,
    context: *V8SortContext,
) !usize {
    if (low + 1 == high) return 1;

    var run_length: usize = 2;
    const first_order = try compareV8Sort(runtime, items[low + 1], presence[low + 1], items[low], presence[low], context);
    const descending = first_order == .lt;
    while (low + run_length < high) : (run_length += 1) {
        const order = try compareV8Sort(
            runtime,
            items[low + run_length],
            presence[low + run_length],
            items[low + run_length - 1],
            presence[low + run_length - 1],
            context,
        );
        if (descending) {
            if (order != .lt) break;
        } else if (order == .lt) {
            break;
        }
    }

    if (descending) {
        var left = low;
        var right = low + run_length - 1;
        while (left < right) : ({
            left += 1;
            right -= 1;
        }) {
            std.mem.swap(Value, &items[left], &items[right]);
            std.mem.swap(bool, &presence[left], &presence[right]);
        }
    }
    return run_length;
}

pub fn v8BinaryInsertionSortArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    low: usize,
    start_argument: usize,
    high: usize,
    context: *V8SortContext,
    pivot_root: *Value,
) !void {
    var start = if (low == start_argument) start_argument + 1 else start_argument;
    while (start < high) : (start += 1) {
        pivot_root.* = items[start];
        const pivot_present = presence[start];
        var left = low;
        var right = start;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const order = try compareV8Sort(runtime, pivot_root.*, pivot_present, items[middle], presence[middle], context);
            if (order == .lt) right = middle else left = middle + 1;
        }
        var cursor = start;
        while (cursor > left) : (cursor -= 1) {
            items[cursor] = items[cursor - 1];
            presence[cursor] = presence[cursor - 1];
        }
        items[left] = pivot_root.*;
        presence[left] = pivot_present;
    }
}

pub fn v8GallopLeftArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    key: *Value,
    key_present: bool,
    base: usize,
    length: usize,
    hint: usize,
    context: *V8SortContext,
) !usize {
    var key_root = key.*;
    var key_frame = RootFrame{};
    runtime.pushRoots(&key_frame, @ptrCast(&key_root), 1);
    defer runtime.popRoots(&key_frame);

    var last_offset: isize = 0;
    var offset: isize = 1;
    const initial_order = try compareV8Sort(runtime, items[base + hint], presence[base + hint], key_root, key_present, context);
    if (initial_order == .lt) {
        const max_offset: isize = @intCast(length - hint);
        while (offset < max_offset) {
            const index: usize = base + hint + @as(usize, @intCast(offset));
            const order = try compareV8Sort(runtime, items[index], presence[index], key_root, key_present, context);
            if (order != .lt) break;
            last_offset = offset;
            offset = (offset << 1) + 1;
        }
        if (offset > max_offset) offset = max_offset;
        last_offset += @intCast(hint);
        offset += @intCast(hint);
    } else {
        const max_offset: isize = @intCast(hint + 1);
        while (offset < max_offset) {
            const index: usize = base + hint - @as(usize, @intCast(offset));
            const order = try compareV8Sort(runtime, items[index], presence[index], key_root, key_present, context);
            if (order == .lt) break;
            last_offset = offset;
            offset = (offset << 1) + 1;
        }
        if (offset > max_offset) offset = max_offset;
        const previous = last_offset;
        last_offset = @as(isize, @intCast(hint)) - offset;
        offset = @as(isize, @intCast(hint)) - previous;
    }

    last_offset += 1;
    while (last_offset < offset) {
        const middle: usize = @intCast(last_offset + @divTrunc(offset - last_offset, 2));
        const index = base + middle;
        const order = try compareV8Sort(runtime, items[index], presence[index], key_root, key_present, context);
        if (order == .lt) last_offset = @intCast(middle + 1) else offset = @intCast(middle);
    }
    return @intCast(offset);
}

pub fn v8GallopRightArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    key: *Value,
    key_present: bool,
    base: usize,
    length: usize,
    hint: usize,
    context: *V8SortContext,
) !usize {
    var key_root = key.*;
    var key_frame = RootFrame{};
    runtime.pushRoots(&key_frame, @ptrCast(&key_root), 1);
    defer runtime.popRoots(&key_frame);

    var last_offset: isize = 0;
    var offset: isize = 1;
    const initial_order = try compareV8Sort(runtime, key_root, key_present, items[base + hint], presence[base + hint], context);
    if (initial_order == .lt) {
        const max_offset: isize = @intCast(hint + 1);
        while (offset < max_offset) {
            const index: usize = base + hint - @as(usize, @intCast(offset));
            const order = try compareV8Sort(runtime, key_root, key_present, items[index], presence[index], context);
            if (order != .lt) break;
            last_offset = offset;
            offset = (offset << 1) + 1;
        }
        if (offset > max_offset) offset = max_offset;
        const previous = last_offset;
        last_offset = @as(isize, @intCast(hint)) - offset;
        offset = @as(isize, @intCast(hint)) - previous;
    } else {
        const max_offset: isize = @intCast(length - hint);
        while (offset < max_offset) {
            const index: usize = base + hint + @as(usize, @intCast(offset));
            const order = try compareV8Sort(runtime, key_root, key_present, items[index], presence[index], context);
            if (order == .lt) break;
            last_offset = offset;
            offset = (offset << 1) + 1;
        }
        if (offset > max_offset) offset = max_offset;
        last_offset += @intCast(hint);
        offset += @intCast(hint);
    }

    last_offset += 1;
    while (last_offset < offset) {
        const middle: usize = @intCast(last_offset + @divTrunc(offset - last_offset, 2));
        const index = base + middle;
        const order = try compareV8Sort(runtime, key_root, key_present, items[index], presence[index], context);
        if (order == .lt) offset = @intCast(middle) else last_offset = @intCast(middle + 1);
    }
    return @intCast(offset);
}

pub fn v8MergeLowArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    base_a: usize,
    length_a_argument: usize,
    base_b: usize,
    length_b_argument: usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    var length_a = length_a_argument;
    var length_b = length_b_argument;
    v8CopyArrayRange(Value, temp, 0, items, base_a, length_a);
    v8CopyArrayRange(bool, temp_presence, 0, presence, base_a, length_a);

    var destination = base_a;
    var cursor_temp: usize = 0;
    var cursor_b = base_b;
    items[destination] = items[cursor_b];
    presence[destination] = presence[cursor_b];
    destination += 1;
    cursor_b += 1;
    length_b -= 1;
    if (length_b == 0) {
        v8CopyArrayRange(Value, items, destination, temp, cursor_temp, length_a);
        v8CopyArrayRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
        return;
    }
    if (length_a == 1) {
        v8CopyArrayRange(Value, items, destination, items, cursor_b, length_b);
        v8CopyArrayRange(bool, presence, destination, presence, cursor_b, length_b);
        items[destination + length_b] = temp[cursor_temp];
        presence[destination + length_b] = temp_presence[cursor_temp];
        return;
    }

    var min_gallop = min_gallop_state.*;
    while (true) {
        var wins_a: usize = 0;
        var wins_b: usize = 0;
        while (true) {
            const order = try compareV8Sort(runtime, items[cursor_b], presence[cursor_b], temp[cursor_temp], temp_presence[cursor_temp], context);
            if (order == .lt) {
                items[destination] = items[cursor_b];
                presence[destination] = presence[cursor_b];
                destination += 1;
                cursor_b += 1;
                length_b -= 1;
                wins_b += 1;
                wins_a = 0;
                if (length_b == 0) {
                    v8CopyArrayRange(Value, items, destination, temp, cursor_temp, length_a);
                    v8CopyArrayRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
                    min_gallop_state.* = min_gallop;
                    return;
                }
                if (wins_b >= min_gallop) break;
            } else {
                items[destination] = temp[cursor_temp];
                presence[destination] = temp_presence[cursor_temp];
                destination += 1;
                cursor_temp += 1;
                length_a -= 1;
                wins_a += 1;
                wins_b = 0;
                if (length_a == 1) {
                    v8CopyArrayRange(Value, items, destination, items, cursor_b, length_b);
                    v8CopyArrayRange(bool, presence, destination, presence, cursor_b, length_b);
                    items[destination + length_b] = temp[cursor_temp];
                    presence[destination + length_b] = temp_presence[cursor_temp];
                    min_gallop_state.* = min_gallop;
                    return;
                }
                if (wins_a >= min_gallop) break;
            }
        }

        min_gallop += 1;
        var first_iteration = true;
        while (wins_a >= v8_timsort_min_gallop or wins_b >= v8_timsort_min_gallop or first_iteration) {
            first_iteration = false;
            min_gallop = @max(@as(usize, 1), min_gallop -| 1);
            min_gallop_state.* = min_gallop;
            wins_a = try v8GallopRightArrayCallback(
                runtime,
                temp,
                temp_presence,
                &items[cursor_b],
                presence[cursor_b],
                cursor_temp,
                length_a,
                0,
                context,
            );
            if (wins_a > 0) {
                v8CopyArrayRange(Value, items, destination, temp, cursor_temp, wins_a);
                v8CopyArrayRange(bool, presence, destination, temp_presence, cursor_temp, wins_a);
                destination += wins_a;
                cursor_temp += wins_a;
                length_a -= wins_a;
                if (length_a == 1) {
                    v8CopyArrayRange(Value, items, destination, items, cursor_b, length_b);
                    v8CopyArrayRange(bool, presence, destination, presence, cursor_b, length_b);
                    items[destination + length_b] = temp[cursor_temp];
                    presence[destination + length_b] = temp_presence[cursor_temp];
                    return;
                }
                if (length_a == 0) return;
            }
            items[destination] = items[cursor_b];
            presence[destination] = presence[cursor_b];
            destination += 1;
            cursor_b += 1;
            length_b -= 1;
            if (length_b == 0) {
                v8CopyArrayRange(Value, items, destination, temp, cursor_temp, length_a);
                v8CopyArrayRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
                return;
            }

            wins_b = try v8GallopLeftArrayCallback(
                runtime,
                items,
                presence,
                &temp[cursor_temp],
                temp_presence[cursor_temp],
                cursor_b,
                length_b,
                0,
                context,
            );
            if (wins_b > 0) {
                v8CopyArrayRange(Value, items, destination, items, cursor_b, wins_b);
                v8CopyArrayRange(bool, presence, destination, presence, cursor_b, wins_b);
                destination += wins_b;
                cursor_b += wins_b;
                length_b -= wins_b;
                if (length_b == 0) {
                    v8CopyArrayRange(Value, items, destination, temp, cursor_temp, length_a);
                    v8CopyArrayRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
                    return;
                }
            }
            items[destination] = temp[cursor_temp];
            presence[destination] = temp_presence[cursor_temp];
            destination += 1;
            cursor_temp += 1;
            length_a -= 1;
            if (length_a == 1) {
                v8CopyArrayRange(Value, items, destination, items, cursor_b, length_b);
                v8CopyArrayRange(bool, presence, destination, presence, cursor_b, length_b);
                items[destination + length_b] = temp[cursor_temp];
                presence[destination + length_b] = temp_presence[cursor_temp];
                return;
            }
        }
        min_gallop += 1;
        min_gallop_state.* = min_gallop;
    }
}

pub fn v8MergeHighArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    base_a: usize,
    length_a_argument: usize,
    base_b: usize,
    length_b_argument: usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    var length_a = length_a_argument;
    var length_b = length_b_argument;
    v8CopyArrayRange(Value, temp, 0, items, base_b, length_b);
    v8CopyArrayRange(bool, temp_presence, 0, presence, base_b, length_b);

    var destination = base_b + length_b - 1;
    var cursor_temp = length_b - 1;
    var cursor_a = base_a + length_a - 1;
    items[destination] = items[cursor_a];
    presence[destination] = presence[cursor_a];
    destination -= 1;
    cursor_a -= 1;
    length_a -= 1;
    if (length_a == 0) {
        v8CopyArrayRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
        v8CopyArrayRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
        return;
    }
    if (length_b == 1) {
        destination -= length_a;
        const source_a = cursor_a - (length_a - 1);
        v8CopyArrayRange(Value, items, destination + 1, items, source_a, length_a);
        v8CopyArrayRange(bool, presence, destination + 1, presence, source_a, length_a);
        items[destination] = temp[cursor_temp];
        presence[destination] = temp_presence[cursor_temp];
        return;
    }

    var min_gallop = min_gallop_state.*;
    while (true) {
        var wins_a: usize = 0;
        var wins_b: usize = 0;
        while (true) {
            const order = try compareV8Sort(runtime, temp[cursor_temp], temp_presence[cursor_temp], items[cursor_a], presence[cursor_a], context);
            if (order == .lt) {
                items[destination] = items[cursor_a];
                presence[destination] = presence[cursor_a];
                destination -= 1;
                length_a -= 1;
                wins_a += 1;
                wins_b = 0;
                if (length_a == 0) {
                    v8CopyArrayRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                    v8CopyArrayRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
                    min_gallop_state.* = min_gallop;
                    return;
                }
                cursor_a -= 1;
                if (wins_a >= min_gallop) break;
            } else {
                items[destination] = temp[cursor_temp];
                presence[destination] = temp_presence[cursor_temp];
                destination -= 1;
                cursor_temp -= 1;
                length_b -= 1;
                wins_b += 1;
                wins_a = 0;
                if (length_b == 1) {
                    destination -= length_a;
                    const source_a = cursor_a - (length_a - 1);
                    v8CopyArrayRange(Value, items, destination + 1, items, source_a, length_a);
                    v8CopyArrayRange(bool, presence, destination + 1, presence, source_a, length_a);
                    items[destination] = temp[cursor_temp];
                    presence[destination] = temp_presence[cursor_temp];
                    min_gallop_state.* = min_gallop;
                    return;
                }
                if (wins_b >= min_gallop) break;
            }
        }

        min_gallop += 1;
        var first_iteration = true;
        while (wins_a >= v8_timsort_min_gallop or wins_b >= v8_timsort_min_gallop or first_iteration) {
            first_iteration = false;
            min_gallop = @max(@as(usize, 1), min_gallop -| 1);
            min_gallop_state.* = min_gallop;
            const gallop_index = try v8GallopRightArrayCallback(
                runtime,
                items,
                presence,
                &temp[cursor_temp],
                temp_presence[cursor_temp],
                base_a,
                length_a,
                length_a - 1,
                context,
            );
            wins_a = length_a - gallop_index;
            if (wins_a > 0) {
                if (wins_a == length_a) {
                    destination -= length_a;
                    const source_a = cursor_a - (length_a - 1);
                    v8CopyArrayRange(Value, items, destination + 1, items, source_a, length_a);
                    v8CopyArrayRange(bool, presence, destination + 1, presence, source_a, length_a);
                    v8CopyArrayRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                    v8CopyArrayRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
                    return;
                }
                destination -= wins_a;
                cursor_a -= wins_a;
                v8CopyArrayRange(Value, items, destination + 1, items, cursor_a + 1, wins_a);
                v8CopyArrayRange(bool, presence, destination + 1, presence, cursor_a + 1, wins_a);
                length_a -= wins_a;
                if (length_a == 0) {
                    v8CopyArrayRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                    v8CopyArrayRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
                    return;
                }
            }
            items[destination] = temp[cursor_temp];
            presence[destination] = temp_presence[cursor_temp];
            destination -= 1;
            cursor_temp -= 1;
            length_b -= 1;
            if (length_b == 1) {
                destination -= length_a;
                const source_a = cursor_a - (length_a - 1);
                v8CopyArrayRange(Value, items, destination + 1, items, source_a, length_a);
                v8CopyArrayRange(bool, presence, destination + 1, presence, source_a, length_a);
                items[destination] = temp[cursor_temp];
                presence[destination] = temp_presence[cursor_temp];
                return;
            }

            const gallop_left = try v8GallopLeftArrayCallback(
                runtime,
                temp,
                temp_presence,
                &items[cursor_a],
                presence[cursor_a],
                0,
                length_b,
                length_b - 1,
                context,
            );
            wins_b = length_b - gallop_left;
            if (wins_b > 0) {
                if (wins_b == length_b) {
                    destination -= length_b;
                    v8CopyArrayRange(Value, items, destination + 1, temp, 0, length_b);
                    v8CopyArrayRange(bool, presence, destination + 1, temp_presence, 0, length_b);
                    return;
                }
                destination -= wins_b;
                cursor_temp -= wins_b;
                v8CopyArrayRange(Value, items, destination + 1, temp, cursor_temp + 1, wins_b);
                v8CopyArrayRange(bool, presence, destination + 1, temp_presence, cursor_temp + 1, wins_b);
                length_b -= wins_b;
                if (length_b == 1) {
                    destination -= length_a;
                    const source_a = cursor_a - (length_a - 1);
                    v8CopyArrayRange(Value, items, destination + 1, items, source_a, length_a);
                    v8CopyArrayRange(bool, presence, destination + 1, presence, source_a, length_a);
                    items[destination] = temp[cursor_temp];
                    presence[destination] = temp_presence[cursor_temp];
                    return;
                }
                if (length_b == 0) {
                    return;
                }
            }
            items[destination] = items[cursor_a];
            presence[destination] = presence[cursor_a];
            destination -= 1;
            length_a -= 1;
            if (length_a == 0) {
                v8CopyArrayRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                v8CopyArrayRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
                return;
            }
            cursor_a -= 1;
        }
        min_gallop += 1;
        min_gallop_state.* = min_gallop;
    }
}

pub fn v8MergeAtArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    runs: []V8ArraySortRun,
    run_count: *usize,
    index: usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    const stack_size = run_count.*;
    var base_a = runs[index].base;
    var length_a = runs[index].length;
    const base_b = runs[index + 1].base;
    var length_b = runs[index + 1].length;
    runs[index].length = length_a + length_b;
    if (stack_size >= 3 and index == stack_size - 3) runs[index + 1] = runs[index + 2];
    run_count.* = stack_size - 1;

    const key_right = try v8GallopRightArrayCallback(
        runtime,
        items,
        presence,
        &items[base_b],
        presence[base_b],
        base_a,
        length_a,
        0,
        context,
    );
    base_a += key_right;
    length_a -= key_right;
    if (length_a == 0) return;
    length_b = try v8GallopLeftArrayCallback(
        runtime,
        items,
        presence,
        &items[base_a + length_a - 1],
        presence[base_a + length_a - 1],
        base_b,
        length_b,
        length_b - 1,
        context,
    );
    if (length_b == 0) return;
    if (length_a <= length_b) {
        try v8MergeLowArrayCallback(runtime, items, presence, temp, temp_presence, base_a, length_a, base_b, length_b, context, min_gallop_state);
    } else {
        try v8MergeHighArrayCallback(runtime, items, presence, temp, temp_presence, base_a, length_a, base_b, length_b, context, min_gallop_state);
    }
}

pub fn v8RunInvariantEstablishedArray(runs: []const V8ArraySortRun, index: usize) bool {
    if (index < 2) return true;
    if (runs[index - 2].length <= runs[index - 1].length) return false;
    return runs[index - 2].length - runs[index - 1].length > runs[index].length;
}

pub fn v8MergeCollapseArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    runs: []V8ArraySortRun,
    run_count: *usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    while (run_count.* > 1) {
        var index = run_count.* - 2;
        if (!v8RunInvariantEstablishedArray(runs, index + 1) or !v8RunInvariantEstablishedArray(runs, index)) {
            if (index > 0 and runs[index - 1].length < runs[index + 1].length) index -= 1;
            try v8MergeAtArrayCallback(runtime, items, presence, temp, temp_presence, runs, run_count, index, context, min_gallop_state);
        } else if (runs[index].length <= runs[index + 1].length) {
            try v8MergeAtArrayCallback(runtime, items, presence, temp, temp_presence, runs, run_count, index, context, min_gallop_state);
        } else {
            break;
        }
    }
}

pub fn v8MergeForceCollapseArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    runs: []V8ArraySortRun,
    run_count: *usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    while (run_count.* > 1) {
        var index = run_count.* - 2;
        if (index > 0 and runs[index - 1].length < runs[index + 1].length) index -= 1;
        try v8MergeAtArrayCallback(runtime, items, presence, temp, temp_presence, runs, run_count, index, context, min_gallop_state);
    }
}

pub fn v8TimSortArrayCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    context: *V8SortContext,
    pivot_root: *Value,
) !void {
    if (items.len < 2) return;
    const min_run_length = v8ComputeMinRunLengthArray(items.len);
    var runs: [v8_timsort_max_pending_runs]V8ArraySortRun = undefined;
    var run_count: usize = 0;
    var low: usize = 0;
    var remaining = items.len;
    var min_gallop = v8_timsort_min_gallop;
    while (remaining != 0) {
        var current_run_length = try v8CountAndMakeRunArrayCallback(runtime, items, presence, low, low + remaining, context);
        if (current_run_length < min_run_length) {
            const forced_run_length = @min(min_run_length, remaining);
            try v8BinaryInsertionSortArrayCallback(runtime, items, presence, low, low + current_run_length, low + forced_run_length, context, pivot_root);
            current_run_length = forced_run_length;
        }
        if (run_count == runs.len) return error.ArrayTooLarge;
        runs[run_count] = .{ .base = low, .length = current_run_length };
        run_count += 1;
        try v8MergeCollapseArrayCallback(runtime, items, presence, temp, temp_presence, &runs, &run_count, context, &min_gallop);
        low += current_run_length;
        remaining -= current_run_length;
    }
    try v8MergeForceCollapseArrayCallback(runtime, items, presence, temp, temp_presence, &runs, &run_count, context, &min_gallop);
}

pub fn compareAotCallback(runtime: *Runtime, callable: Value, left: Value, left_present: bool, right: Value, right_present: bool, result_root: *Value) !std.math.Order {
    if (!left_present) return if (!right_present) .eq else .gt;
    if (!right_present) return .lt;
    if (left.tag == @intFromEnum(Tag.undefined)) return if (right.tag == @intFromEnum(Tag.undefined)) .eq else .gt;
    if (right.tag == @intFromEnum(Tag.undefined)) return .lt;
    var callback_values = [_]Value{ callable, left, right };
    var callback_frame = RootFrame{};
    runtime.pushRoots(&callback_frame, callback_values[0..].ptr, callback_values.len);
    defer runtime.popRoots(&callback_frame);
    result_root.* = try invokeAotCallback(runtime, callback_values[0], @ptrCast(&callback_values[1]), 2);
    const number = try valueToNumberRuntime(runtime, result_root.*);
    if (std.math.isNan(number) or number == 0) return .eq;
    return if (number < 0) .lt else .gt;
}

pub fn invokeAotCallback(runtime: *Runtime, callable: Value, arguments: ?[*]const Value, len: usize) !Value {
    if (callable.tag != @intFromEnum(Tag.function)) return error.NotCallable;
    const object = callable.object() orelse return error.NotCallable;
    if (object.payload != .function) return error.NotCallable;
    var result: Value = .{};
    const start_epoch = runtime.failure_epoch;
    lnako_aot_function_call(&result, &callable, arguments, len);
    if (runtime.has_pending_exception and runtime.failure_epoch != start_epoch) return error.CallbackExecutionFailed;
    return result;
}

pub fn resolveAotCallback(runtime: *Runtime, value: Value) !Value {
    if (value.tag == @intFromEnum(Tag.function)) return value;
    if (!isString(value)) return error.NotCallable;
    const name = try stringUtf8Alloc(runtime, value);
    defer runtime.allocator.free(name);

    var match: ?Value = null;
    for (runtime.named_functions.items) |registered| {
        if (!registeredFunctionMatches(registered.name, name)) continue;
        if (match != null) return error.UnknownFunction;
        match = .{ .tag = @intFromEnum(Tag.function), .payload = @intFromPtr(registered.object) };
    }
    return match orelse error.UnknownFunction;
}

pub fn registeredFunctionMatches(registered_name: []const u8, requested_name: []const u8) bool {
    if (std.mem.eql(u8, registered_name, requested_name)) return true;
    const separator = std.mem.lastIndexOf(u8, registered_name, "__") orelse return false;
    return std.mem.eql(u8, registered_name[separator + 2 ..], requested_name);
}

pub fn stableArraySort(runtime: *Runtime, source: Value, numeric: bool) !Value {
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    const items = &object.payload.array;
    if (items.items.len < 2) return source;

    try runtime.normalizeAotArrayPresence(object);

    // Keep the live array unchanged until the merge completes. The contiguous
    // root storage protects both the source object and every temporary value
    // while ToString/parseFloat allocate and may trigger collection.
    const allocator = runtime.allocator;
    const root_count = std.math.add(usize, items.items.len, 1) catch return error.ArrayTooLarge;
    const root_values = try allocator.alloc(Value, root_count);
    defer allocator.free(root_values);
    root_values[0] = source;
    std.mem.copyForwards(Value, root_values[1..], items.items);
    const temporary_presence = try allocator.dupe(bool, object.array_presence.items);
    defer allocator.free(temporary_presence);
    var roots = RootFrame{};
    runtime.pushRoots(&roots, root_values.ptr, root_values.len);
    defer runtime.popRoots(&roots);
    const temporary = root_values[1..];

    var width: usize = 1;
    var from_source = true;
    while (width < items.items.len) : (width = std.math.mul(usize, width, 2) catch items.items.len) {
        const input = if (from_source) items.items else temporary;
        const output = if (from_source) temporary else items.items;
        const input_presence = if (from_source) object.array_presence.items else temporary_presence;
        const output_presence = if (from_source) temporary_presence else object.array_presence.items;
        var start: usize = 0;
        while (start < input.len) {
            const middle = @min(std.math.add(usize, start, width) catch input.len, input.len);
            const end = @min(std.math.add(usize, middle, width) catch input.len, input.len);
            var left = start;
            var right = middle;
            var destination = start;
            while (left < middle and right < end) {
                const order = try compareArraySortValues(runtime, input[left], input_presence[left], input[right], input_presence[right], numeric);
                if (order == .gt) {
                    output[destination] = input[right];
                    output_presence[destination] = input_presence[right];
                    right += 1;
                } else {
                    output[destination] = input[left];
                    output_presence[destination] = input_presence[left];
                    left += 1;
                }
                destination += 1;
            }
            while (left < middle) : ({
                left += 1;
                destination += 1;
            }) {
                output[destination] = input[left];
                output_presence[destination] = input_presence[left];
            }
            while (right < end) : ({
                right += 1;
                destination += 1;
            }) {
                output[destination] = input[right];
                output_presence[destination] = input_presence[right];
            }
            start = end;
        }
        from_source = !from_source;
    }
    if (!from_source) {
        std.mem.copyForwards(Value, items.items, temporary);
        std.mem.copyForwards(bool, object.array_presence.items, temporary_presence);
    }
    return source;
}

pub fn compareArraySortValues(runtime: *Runtime, left: Value, left_present: bool, right: Value, right_present: bool, numeric: bool) !std.math.Order {
    if (!left_present) return if (!right_present) .eq else .gt;
    if (!right_present) return .lt;
    if (left.tag == @intFromEnum(Tag.undefined)) return if (right.tag == @intFromEnum(Tag.undefined)) .eq else .gt;
    if (right.tag == @intFromEnum(Tag.undefined)) return .lt;
    if (numeric) {
        const left_number = try parseFloatBuiltin(runtime, left);
        const right_number = try parseFloatBuiltin(runtime, right);
        if (std.math.isNan(left_number) or std.math.isNan(right_number)) return .eq;
        return std.math.order(left_number, right_number);
    }

    const left_text = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_text);
    const right_text = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_text);
    return utf16Order(left_text, right_text);
}

pub fn utf16Order(left: []const u16, right: []const u16) std.math.Order {
    return std.mem.order(u16, left, right);
}
