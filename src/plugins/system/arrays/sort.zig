const std = @import("std");
const value_mod = @import("../../../runtime/value.zig");
const shared = @import("shared.zig");
const Value = shared.Value;
const Runtime = shared.Runtime;
const Context = shared.Context;
const ByteKind = shared.ByteKind;

const common = @import("../common.zig");
const operators = @import("../../../runtime/operators.zig");
const Range = shared.Range;

pub const TestMutatingSortContext = struct {
    target: *value_mod.Array,
    mutated: bool = false,

    pub fn invoke(raw: *anyopaque, _: Value, arguments: []const Value) anyerror!Value {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (!self.mutated) {
            self.target.items.clearRetainingCapacity();
            self.mutated = true;
        }
        return .{ .number = arguments[0].number - arguments[1].number };
    }
};

pub const TestSortOrderContext = struct {
    pairs: [16][2]f64 = undefined,
    count: usize = 0,

    pub fn invoke(raw: *anyopaque, _: Value, arguments: []const Value) anyerror!Value {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (arguments.len == 2 and self.count < self.pairs.len) {
            self.pairs[self.count] = .{ arguments[0].number, arguments[1].number };
            self.count += 1;
        }
        return .{ .number = arguments[0].number - arguments[1].number };
    }
};

pub const ZeroRandomContext = struct {
    pub fn next(_: *anyopaque) anyerror!f64 {
        return 0;
    }
};

pub fn sortDefault(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    try stableSort(runtime, source, .string, null);
    return source;
}

pub fn sortNumeric(runtime: *Runtime, source: Value) !Value {
    if (source != .array) return error.ArrayExpected;
    try stableSort(runtime, source, .number, null);
    return source;
}

pub fn sortCustom(runtime: *Runtime, function_value: Value, source: Value, context: ?Context) !Value {
    if (source != .array) return error.ArrayExpected;
    var source_root = source;
    var function_root = function_value;
    var callable: Value = .undefined;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source_root);
    try roots.protect(&function_root);
    try roots.protect(&callable);
    callable = try Context.resolve(context, runtime, function_root);
    try stableSort(runtime, source_root, .callback, .{ .context = context, .callable = callable });
    return source_root;
}

pub const SortMode = enum { string, number, relational, callback };
pub const SortCallback = struct { context: ?Context, callable: Value };
pub const v8_small_callback_sort_limit: usize = 64;
pub const v8_timsort_max_pending_runs: usize = 85;
pub const v8_timsort_min_gallop: usize = 7;

pub const V8SortRun = struct {
    base: usize,
    length: usize,
};

pub const V8TableSortContext = struct {
    column: *Value,
    numeric: bool,
    left_cell: *Value,
    right_cell: *Value,
    compareFn: *const fn (runtime: *Runtime, left: Value, left_present: bool, right: Value, right_present: bool, column: Value, numeric: bool, left_cell: *Value, right_cell: *Value) anyerror!std.math.Order,
};

pub const V8SortContext = union(enum) {
    callback: SortCallback,
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
        .callback => |callback| compareForSort(runtime, left, left_present, right, right_present, .callback, callback),
        .table => |table| table.compareFn(
            runtime,
            left,
            left_present,
            right,
            right_present,
            table.column.*,
            table.numeric,
            table.left_cell,
            table.right_cell,
        ),
    };
}

pub fn stableSort(runtime: *Runtime, source: Value, mode: SortMode, callback: ?SortCallback) !void {
    const array = source.array;
    if (array.items.items.len < 2) return;
    if (mode == .callback) return stableCallbackSort(runtime, array, callback.?);

    try array.normalizePresence();

    // Allocate initialized scratch storage before sorting. This avoids O(n^2)
    // behavior and prevents OOM from exposing an uninitialized array slot.
    var source_root = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source_root);
    const temporary = try runtime.allocator().dupe(Value, array.items.items);
    defer runtime.allocator().free(temporary);
    const temporary_presence = try runtime.allocator().dupe(bool, array.presence.items);
    defer runtime.allocator().free(temporary_presence);
    for (temporary) |*item| try roots.protect(item);

    var width: usize = 1;
    var from_source = true;
    while (width < array.items.items.len) : (width = std.math.mul(usize, width, 2) catch array.items.items.len) {
        const input = if (from_source) array.items.items else temporary;
        const output = if (from_source) temporary else array.items.items;
        const input_presence = if (from_source) array.presence.items else temporary_presence;
        const output_presence = if (from_source) temporary_presence else array.presence.items;
        var start: usize = 0;
        while (start < input.len) {
            const middle = @min(std.math.add(usize, start, width) catch input.len, input.len);
            const end = @min(std.math.add(usize, middle, width) catch input.len, input.len);
            var left = start;
            var right = middle;
            var destination = start;
            while (left < middle and right < end) {
                const order = try compareForSort(runtime, input[left], input_presence[left], input[right], input_presence[right], mode, callback);
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
        std.mem.copyForwards(Value, array.items.items, temporary);
        std.mem.copyForwards(bool, array.presence.items, temporary_presence);
    }
}

pub fn stableCallbackSort(runtime: *Runtime, array: *value_mod.Array, callback: SortCallback) !void {
    // ECMAScript collects the indexed values before invoking the comparator.
    // Keep both merge buffers detached from the live array so a callback may
    // resize or reallocate that array without invalidating an active slice.
    const original_length = array.len();
    try array.normalizePresence();
    const first = try runtime.allocator().dupe(Value, array.items.items);
    defer runtime.allocator().free(first);
    const second = try runtime.allocator().dupe(Value, first);
    defer runtime.allocator().free(second);
    const first_presence = try runtime.allocator().dupe(bool, array.presence.items);
    defer runtime.allocator().free(first_presence);
    const second_presence = try runtime.allocator().dupe(bool, first_presence);
    defer runtime.allocator().free(second_presence);
    var roots = runtime.rootFrame();
    defer roots.deinit();
    for (first) |*item| try roots.protect(item);
    for (second) |*item| try roots.protect(item);
    var sort_context = V8SortContext{ .callback = callback };

    if (original_length < v8_small_callback_sort_limit) {
        try v8SmallCallbackSort(runtime, first, first_presence, callback, &roots);
    } else {
        try v8TimSortCallback(runtime, first, first_presence, second, second_presence, &sort_context);
    }

    if (array.len() < original_length) {
        const old_length = array.len();
        try array.items.resize(runtime.allocator(), original_length);
        @memset(array.items.items[old_length..], .undefined);
        try array.presence.resize(runtime.allocator(), original_length);
        @memset(array.presence.items[old_length..], false);
    }
    std.mem.copyForwards(Value, array.items.items[0..original_length], first);
    std.mem.copyForwards(bool, array.presence.items[0..original_length], first_presence);
}

pub fn v8SmallCallbackSort(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    callback: SortCallback,
    _: *value_mod.RootFrame,
) !void {
    // V8 uses CountAndMakeRun followed by BinaryInsertionSort when the
    // receiver length is below 64. Keeping this path detached from the live
    // array preserves the collection-before-callback and resize guarantees
    // of stableCallbackSort while matching the observable callback order.
    if (items.len < 2) return;

    var pivot: Value = .undefined;
    var pivot_roots = runtime.rootFrame();
    defer pivot_roots.deinit();
    try pivot_roots.protect(&pivot);

    var run_length: usize = 2;
    const first_order = try compareForSort(runtime, items[1], presence[1], items[0], presence[0], .callback, callback);
    if (first_order == .lt) {
        while (run_length < items.len) : (run_length += 1) {
            const order = try compareForSort(runtime, items[run_length], presence[run_length], items[run_length - 1], presence[run_length - 1], .callback, callback);
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
            const order = try compareForSort(runtime, items[run_length], presence[run_length], items[run_length - 1], presence[run_length - 1], .callback, callback);
            if (order == .lt) break;
        }
    }

    var start = run_length;
    while (start < items.len) : (start += 1) {
        pivot = items[start];
        const pivot_presence = presence[start];
        var left: usize = 0;
        var right: usize = start;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const order = try compareForSort(runtime, pivot, pivot_presence, items[middle], presence[middle], .callback, callback);
            if (order == .lt) right = middle else left = middle + 1;
        }
        var cursor = start;
        while (cursor > left) : (cursor -= 1) {
            items[cursor] = items[cursor - 1];
            presence[cursor] = presence[cursor - 1];
        }
        items[left] = pivot;
        presence[left] = pivot_presence;
    }
}

pub fn v8CopyRange(comptime T: type, destination: []T, destination_index: usize, source: []const T, source_index: usize, length: usize) void {
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

pub fn v8ComputeMinRunLength(length: usize) usize {
    var n = length;
    var remainder: usize = 0;
    while (n >= 64) {
        remainder |= n & 1;
        n >>= 1;
    }
    return n + remainder;
}

pub fn v8CountAndMakeRunCallback(
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

pub fn v8BinaryInsertionSortCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    low: usize,
    start_argument: usize,
    high: usize,
    context: *V8SortContext,
) !void {
    var start = if (low == start_argument) start_argument + 1 else start_argument;
    var pivot: Value = .undefined;
    var pivot_roots = runtime.rootFrame();
    defer pivot_roots.deinit();
    try pivot_roots.protect(&pivot);
    while (start < high) : (start += 1) {
        pivot = items[start];
        const pivot_present = presence[start];
        var left = low;
        var right = start;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const order = try compareV8Sort(runtime, pivot, pivot_present, items[middle], presence[middle], context);
            if (order == .lt) right = middle else left = middle + 1;
        }
        var cursor = start;
        while (cursor > left) : (cursor -= 1) {
            items[cursor] = items[cursor - 1];
            presence[cursor] = presence[cursor - 1];
        }
        items[left] = pivot;
        presence[left] = pivot_present;
    }
}

pub fn v8GallopLeftCallback(
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
    var last_offset: isize = 0;
    var offset: isize = 1;
    const initial_order = try compareV8Sort(runtime, items[base + hint], presence[base + hint], key.*, key_present, context);
    if (initial_order == .lt) {
        const max_offset: isize = @intCast(length - hint);
        while (offset < max_offset) {
            const index: usize = base + hint + @as(usize, @intCast(offset));
            const order = try compareV8Sort(runtime, items[index], presence[index], key.*, key_present, context);
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
            const order = try compareV8Sort(runtime, items[index], presence[index], key.*, key_present, context);
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
        const order = try compareV8Sort(runtime, items[index], presence[index], key.*, key_present, context);
        if (order == .lt) last_offset = @intCast(middle + 1) else offset = @intCast(middle);
    }
    return @intCast(offset);
}

pub fn v8GallopRightCallback(
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
    var last_offset: isize = 0;
    var offset: isize = 1;
    const initial_order = try compareV8Sort(runtime, key.*, key_present, items[base + hint], presence[base + hint], context);
    if (initial_order == .lt) {
        const max_offset: isize = @intCast(hint + 1);
        while (offset < max_offset) {
            const index: usize = base + hint - @as(usize, @intCast(offset));
            const order = try compareV8Sort(runtime, key.*, key_present, items[index], presence[index], context);
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
            const order = try compareV8Sort(runtime, key.*, key_present, items[index], presence[index], context);
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
        const order = try compareV8Sort(runtime, key.*, key_present, items[index], presence[index], context);
        if (order == .lt) offset = @intCast(middle) else last_offset = @intCast(middle + 1);
    }
    return @intCast(offset);
}

pub fn v8MergeLowCallback(
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
    v8CopyRange(Value, temp, 0, items, base_a, length_a);
    v8CopyRange(bool, temp_presence, 0, presence, base_a, length_a);

    var destination = base_a;
    var cursor_temp: usize = 0;
    var cursor_b = base_b;
    items[destination] = items[cursor_b];
    presence[destination] = presence[cursor_b];
    destination += 1;
    cursor_b += 1;
    length_b -= 1;
    if (length_b == 0) {
        v8CopyRange(Value, items, destination, temp, cursor_temp, length_a);
        v8CopyRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
        return;
    }
    if (length_a == 1) {
        v8CopyRange(Value, items, destination, items, cursor_b, length_b);
        v8CopyRange(bool, presence, destination, presence, cursor_b, length_b);
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
                    v8CopyRange(Value, items, destination, temp, cursor_temp, length_a);
                    v8CopyRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
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
                    v8CopyRange(Value, items, destination, items, cursor_b, length_b);
                    v8CopyRange(bool, presence, destination, presence, cursor_b, length_b);
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

            wins_a = try v8GallopRightCallback(
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
                v8CopyRange(Value, items, destination, temp, cursor_temp, wins_a);
                v8CopyRange(bool, presence, destination, temp_presence, cursor_temp, wins_a);
                destination += wins_a;
                cursor_temp += wins_a;
                length_a -= wins_a;
                if (length_a == 1) {
                    v8CopyRange(Value, items, destination, items, cursor_b, length_b);
                    v8CopyRange(bool, presence, destination, presence, cursor_b, length_b);
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
                v8CopyRange(Value, items, destination, temp, cursor_temp, length_a);
                v8CopyRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
                return;
            }

            wins_b = try v8GallopLeftCallback(
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
                v8CopyRange(Value, items, destination, items, cursor_b, wins_b);
                v8CopyRange(bool, presence, destination, presence, cursor_b, wins_b);
                destination += wins_b;
                cursor_b += wins_b;
                length_b -= wins_b;
                if (length_b == 0) {
                    v8CopyRange(Value, items, destination, temp, cursor_temp, length_a);
                    v8CopyRange(bool, presence, destination, temp_presence, cursor_temp, length_a);
                    return;
                }
            }
            items[destination] = temp[cursor_temp];
            presence[destination] = temp_presence[cursor_temp];
            destination += 1;
            cursor_temp += 1;
            length_a -= 1;
            if (length_a == 1) {
                v8CopyRange(Value, items, destination, items, cursor_b, length_b);
                v8CopyRange(bool, presence, destination, presence, cursor_b, length_b);
                items[destination + length_b] = temp[cursor_temp];
                presence[destination + length_b] = temp_presence[cursor_temp];
                return;
            }
        }
        min_gallop += 1;
        min_gallop_state.* = min_gallop;
    }
}

pub fn v8MergeHighCallback(
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
    v8CopyRange(Value, temp, 0, items, base_b, length_b);
    v8CopyRange(bool, temp_presence, 0, presence, base_b, length_b);

    var destination = base_b + length_b - 1;
    var cursor_temp = length_b - 1;
    var cursor_a = base_a + length_a - 1;
    items[destination] = items[cursor_a];
    presence[destination] = presence[cursor_a];
    destination -= 1;
    cursor_a -= 1;
    length_a -= 1;
    if (length_a == 0) {
        v8CopyRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
        v8CopyRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
        return;
    }
    if (length_b == 1) {
        destination -= length_a;
        const source_a = cursor_a - (length_a - 1);
        v8CopyRange(Value, items, destination + 1, items, source_a, length_a);
        v8CopyRange(bool, presence, destination + 1, presence, source_a, length_a);
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
                    v8CopyRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                    v8CopyRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
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
                    v8CopyRange(Value, items, destination + 1, items, source_a, length_a);
                    v8CopyRange(bool, presence, destination + 1, presence, source_a, length_a);
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

            const gallop_index = try v8GallopRightCallback(
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
                    v8CopyRange(Value, items, destination + 1, items, source_a, length_a);
                    v8CopyRange(bool, presence, destination + 1, presence, source_a, length_a);
                    v8CopyRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                    v8CopyRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
                    return;
                }
                destination -= wins_a;
                cursor_a -= wins_a;
                v8CopyRange(Value, items, destination + 1, items, cursor_a + 1, wins_a);
                v8CopyRange(bool, presence, destination + 1, presence, cursor_a + 1, wins_a);
                length_a -= wins_a;
                if (length_a == 0) {
                    v8CopyRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                    v8CopyRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
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
                v8CopyRange(Value, items, destination + 1, items, source_a, length_a);
                v8CopyRange(bool, presence, destination + 1, presence, source_a, length_a);
                items[destination] = temp[cursor_temp];
                presence[destination] = temp_presence[cursor_temp];
                return;
            }

            const gallop_left = try v8GallopLeftCallback(
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
                    v8CopyRange(Value, items, destination + 1, temp, 0, length_b);
                    v8CopyRange(bool, presence, destination + 1, temp_presence, 0, length_b);
                    return;
                }
                destination -= wins_b;
                cursor_temp -= wins_b;
                v8CopyRange(Value, items, destination + 1, temp, cursor_temp + 1, wins_b);
                v8CopyRange(bool, presence, destination + 1, temp_presence, cursor_temp + 1, wins_b);
                length_b -= wins_b;
                if (length_b == 1) {
                    destination -= length_a;
                    const source_a = cursor_a - (length_a - 1);
                    v8CopyRange(Value, items, destination + 1, items, source_a, length_a);
                    v8CopyRange(bool, presence, destination + 1, presence, source_a, length_a);
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
                v8CopyRange(Value, items, destination - (length_b - 1), temp, 0, length_b);
                v8CopyRange(bool, presence, destination - (length_b - 1), temp_presence, 0, length_b);
                return;
            }
            cursor_a -= 1;
        }
        min_gallop += 1;
        min_gallop_state.* = min_gallop;
    }
}

pub fn v8MergeAtCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    runs: []V8SortRun,
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

    const key_right = try v8GallopRightCallback(
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
    length_b = try v8GallopLeftCallback(
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
        try v8MergeLowCallback(runtime, items, presence, temp, temp_presence, base_a, length_a, base_b, length_b, context, min_gallop_state);
    } else {
        try v8MergeHighCallback(runtime, items, presence, temp, temp_presence, base_a, length_a, base_b, length_b, context, min_gallop_state);
    }
}

pub fn v8RunInvariantEstablished(runs: []const V8SortRun, index: usize) bool {
    if (index < 2) return true;
    if (runs[index - 2].length <= runs[index - 1].length) return false;
    return runs[index - 2].length - runs[index - 1].length > runs[index].length;
}

pub fn v8MergeCollapseCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    runs: []V8SortRun,
    run_count: *usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    while (run_count.* > 1) {
        var index = run_count.* - 2;
        if (!v8RunInvariantEstablished(runs, index + 1) or !v8RunInvariantEstablished(runs, index)) {
            if (index > 0 and runs[index - 1].length < runs[index + 1].length) index -= 1;
            try v8MergeAtCallback(runtime, items, presence, temp, temp_presence, runs, run_count, index, context, min_gallop_state);
        } else if (runs[index].length <= runs[index + 1].length) {
            try v8MergeAtCallback(runtime, items, presence, temp, temp_presence, runs, run_count, index, context, min_gallop_state);
        } else {
            break;
        }
    }
}

pub fn v8MergeForceCollapseCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    runs: []V8SortRun,
    run_count: *usize,
    context: *V8SortContext,
    min_gallop_state: *usize,
) !void {
    while (run_count.* > 1) {
        var index = run_count.* - 2;
        if (index > 0 and runs[index - 1].length < runs[index + 1].length) index -= 1;
        try v8MergeAtCallback(runtime, items, presence, temp, temp_presence, runs, run_count, index, context, min_gallop_state);
    }
}

pub fn v8TimSortCallback(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    temp: []Value,
    temp_presence: []bool,
    context: *V8SortContext,
) !void {
    if (items.len < 2) return;
    const min_run_length = v8ComputeMinRunLength(items.len);
    var runs: [v8_timsort_max_pending_runs]V8SortRun = undefined;
    var run_count: usize = 0;
    var low: usize = 0;
    var remaining = items.len;
    var min_gallop = v8_timsort_min_gallop;
    while (remaining != 0) {
        var current_run_length = try v8CountAndMakeRunCallback(runtime, items, presence, low, low + remaining, context);
        if (current_run_length < min_run_length) {
            const forced_run_length = @min(min_run_length, remaining);
            try v8BinaryInsertionSortCallback(runtime, items, presence, low, low + current_run_length, low + forced_run_length, context);
            current_run_length = forced_run_length;
        }
        if (run_count == runs.len) return error.ArrayTooLarge;
        runs[run_count] = .{ .base = low, .length = current_run_length };
        run_count += 1;
        try v8MergeCollapseCallback(runtime, items, presence, temp, temp_presence, &runs, &run_count, context, &min_gallop);
        low += current_run_length;
        remaining -= current_run_length;
    }
    try v8MergeForceCollapseCallback(runtime, items, presence, temp, temp_presence, &runs, &run_count, context, &min_gallop);
}

pub fn compareForSort(runtime: *Runtime, left: Value, left_present: bool, right: Value, right_present: bool, mode: SortMode, callback: ?SortCallback) !std.math.Order {
    // ECMAScript Array#sort places undefined after all defined values without
    // invoking the comparator. Holes are not collected by the spec, so they
    // remain after explicit undefined.
    if (!left_present) return if (!right_present) .eq else .gt;
    if (!right_present) return .lt;
    if (left == .undefined) return if (right == .undefined) .eq else .gt;
    if (right == .undefined) return .lt;
    return switch (mode) {
        .string => blk: {
            var converted = [2]Value{ .undefined, .undefined };
            var roots = runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&converted[0]);
            try roots.protect(&converted[1]);
            converted[0] = try runtime.valueToString(left);
            converted[1] = try runtime.valueToString(right);
            const rooted_left = converted[0];
            const rooted_right = converted[1];
            break :blk value_mod.String.order(rooted_left.string.*, rooted_right.string.*);
        },
        .number => blk: {
            const left_number = try common.parseFloatValue(runtime, left);
            const right_number = try common.parseFloatValue(runtime, right);
            if (std.math.isNan(left_number) or std.math.isNan(right_number)) break :blk .eq;
            break :blk std.math.order(left_number, right_number);
        },
        .relational => (try operators.compare(runtime, left, right)) orelse .eq,
        .callback => blk: {
            const actual = callback.?;
            var callback_arguments = [2]Value{ left, right };
            var callback_result: Value = .undefined;
            var roots = runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&callback_arguments[0]);
            try roots.protect(&callback_arguments[1]);
            try roots.protect(&callback_result);
            callback_result = try Context.invoke(actual.context, actual.callable, &callback_arguments);
            const number = try runtime.valueToNumber(callback_result);
            if (std.math.isNan(number) or number == 0) break :blk .eq;
            break :blk if (number < 0) .lt else .gt;
        },
    };
}

pub fn shuffle(source: Value, context: ?Context) !Value {
    if (source != .array) return error.ArrayExpected;
    try source.array.normalizePresence();
    var index = source.array.len();
    while (index > 1) {
        index -= 1;
        const random_index: usize = @intFromFloat(@floor(try Context.random(context) * @as(f64, @floatFromInt(index + 1))));
        std.mem.swap(Value, &source.array.items.items[index], &source.array.items.items[random_index]);
        // The upstream implementation performs two indexed assignments.
        // Reading a hole yields undefined, but either assignment materializes
        // its target property even when the source side was absent.
        source.array.presence.items[index] = true;
        source.array.presence.items[random_index] = true;
    }
    return source;
}
