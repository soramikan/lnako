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

const v8 = @import("sort_v8.zig");
const V8SortContext = v8.V8SortContext;
const SortMode = v8.SortMode;
const SortCallback = v8.SortCallback;
const v8_small_callback_sort_limit = v8.v8_small_callback_sort_limit;
const v8SmallCallbackSort = v8.v8SmallCallbackSort;
const v8TimSortCallback = v8.v8TimSortCallback;

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
