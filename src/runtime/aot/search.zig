const std = @import("std");
const aot_state = @import("state.zig");

const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const numberValue = aot_state.numberValue;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const isString = aot_state.isString;
const staticStringValue = aot_state.staticStringValue;
const dictionaryProperty = aot_state.dictionaryProperty;
const tableInheritedProperty = aot_state.tableInheritedProperty;

pub fn codePointCount(units: []const u16) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < units.len) : (count += 1) index += codePointLength(units, index);
    return count;
}

pub fn codePointLength(units: []const u16, index: usize) usize {
    return if (index + 1 < units.len and units[index] >= 0xd800 and units[index] <= 0xdbff and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) 2 else 1;
}

/// Fast path for the common string/string form of `何文字目`.  Both
/// operands are already strings, so allocating one UTF-16 buffer per value
/// is enough.  The window width is measured in Array.from elements rather
/// than UTF-16 units; this is important for a lone high surrogate not to
/// match the prefix of a supplementary pair.
pub fn codePointFindStringBuiltin(runtime: *Runtime, source: Value, needle: Value) !usize {
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const needle_units = try valueUtf16Alloc(runtime, needle);
    defer runtime.allocator.free(needle_units);
    if (source_units.len == 0) return 0;

    const needle_count = codePointCount(needle_units);
    var end: usize = 0;
    var initial: usize = 0;
    while (initial < needle_count and end < source_units.len) : (initial += 1) end += codePointLength(source_units, end);

    var start: usize = 0;
    var scalar_index: usize = 0;
    while (start < source_units.len) : (scalar_index += 1) {
        if (std.mem.eql(u16, source_units[start..end], needle_units)) return scalar_index + 1;
        start += codePointLength(source_units, start);
        if (end < source_units.len) end += codePointLength(source_units, end);
    }
    return 0;
}

pub const search_element_limit: usize = 1_000_000;

/// `何文字目` uses `Array.from(value)` and then compares joined windows.  A
/// single concatenated string is not sufficient: a match may start only at
/// an Array.from element boundary (for example, `['AB', 'C']` must not match
/// `BC`).  Keep ordinary values as owned UTF-16 while searching, but retain
/// dictionary array-like values as a lazy indexed view so a first match does
/// not eagerly materialize every missing element.
pub const SearchElements = struct {
    runtime: *Runtime,
    items: std.ArrayList([]u16) = .empty,
    dictionary: ?Value = null,
    dictionary_length: usize = 0,
    array_buffer: ?Value = null,
    array_buffer_length: usize = 0,

    pub fn deinit(self: *SearchElements) void {
        for (self.items.items) |units| if (units.len != 0) self.runtime.allocator.free(units);
        self.items.deinit(self.runtime.allocator);
        self.* = undefined;
    }

    pub fn len(self: SearchElements) usize {
        if (self.dictionary != null) return self.dictionary_length;
        if (self.array_buffer != null) return self.array_buffer_length;
        return self.items.items.len;
    }

    pub fn element(self: *const SearchElements, index: usize) !SearchElement {
        if (self.dictionary) |dictionary| {
            var key_buffer: [32]u16 = undefined;
            const key = searchIndexKey(&key_buffer, index);
            return SearchElement.fromValue(self.runtime, dictionaryProperty(dictionary, key));
        }
        if (self.array_buffer) |array_buffer| {
            var key_buffer: [32]u16 = undefined;
            const key = searchIndexKey(&key_buffer, index);
            return SearchElement.fromValue(self.runtime, try byteBufferArrayLikeProperty(self.runtime, array_buffer, key));
        }
        return .{ .units = self.items.items[index] };
    }

    pub fn appendEmpty(self: *SearchElements) !void {
        try self.items.append(self.runtime.allocator, &.{});
    }

    pub fn appendOwned(self: *SearchElements, units: []u16) !void {
        errdefer if (units.len != 0) self.runtime.allocator.free(units);
        try self.items.append(self.runtime.allocator, units);
    }

    pub fn appendValue(self: *SearchElements, value: Value) !void {
        const tag: Tag = @enumFromInt(value.tag);
        switch (tag) {
            .undefined, .null_value => try self.appendEmpty(),
            .binding_cell => try self.appendValue(value.object().?.payload.binding_cell),
            else => try self.appendOwned(try valueUtf16Alloc(self.runtime, value)),
        }
    }
};

pub const SearchElement = struct {
    units: []const u16,
    owned: ?[]u16 = null,

    pub fn fromValue(runtime: *Runtime, value: Value) !SearchElement {
        return switch (@as(Tag, @enumFromInt(value.tag))) {
            .undefined, .null_value => .{ .units = &.{} },
            .binding_cell => try fromValue(runtime, value.object().?.payload.binding_cell),
            else => blk: {
                const units = try valueUtf16Alloc(runtime, value);
                break :blk .{ .units = units, .owned = units };
            },
        };
    }

    pub fn deinit(self: *SearchElement, runtime: *Runtime) void {
        if (self.owned) |units| runtime.allocator.free(units);
        self.* = undefined;
    }
};

pub fn searchArrayFromLength(runtime: *Runtime, value: Value) !usize {
    const number = try valueToNumberRuntime(runtime, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(search_element_limit))) return error.ArraySizeLimitExceeded;
    return @intFromFloat(@trunc(number));
}

pub fn appendStringSearchElements(elements: *SearchElements, value: Value) !void {
    const units = try valueUtf16Alloc(elements.runtime, value);
    defer elements.runtime.allocator.free(units);
    var index: usize = 0;
    while (index < units.len) {
        const length = codePointLength(units, index);
        try elements.appendOwned(try elements.runtime.allocator.dupe(u16, units[index .. index + length]));
        index += length;
    }
}

pub fn appendDictionarySearchElements(elements: *SearchElements, value: Value) !void {
    const length = searchArrayFromLength(elements.runtime, dictionaryProperty(value, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) catch |failure| return failure;
    elements.dictionary = value;
    elements.dictionary_length = length;
}

pub fn byteBufferArrayLikeProperty(runtime: *Runtime, value: Value, key_units: []const u16) !Value {
    const object = value.object() orelse return .{};
    if (runtime.aotObjectOwnPropertyGetUnits(object, key_units)) |property| return property;
    return (try tableInheritedProperty(runtime, value, .byte_buffer, key_units)) orelse .{};
}

pub fn appendArrayBufferSearchElements(elements: *SearchElements, value: Value) !void {
    const length = searchArrayFromLength(elements.runtime, elements.runtime.indexGet(value, staticStringValue("length"))) catch |failure| return failure;
    elements.array_buffer = value;
    elements.array_buffer_length = length;
}

pub fn searchIndexKey(buffer: *[32]u16, index: usize) []const u16 {
    var utf8: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&utf8, "{d}", .{index}) catch unreachable;
    const length = std.unicode.utf8ToUtf16Le(buffer, text) catch unreachable;
    return buffer[0..length];
}

pub fn appendSearchElements(runtime: *Runtime, value: Value) !SearchElements {
    const tag: Tag = @enumFromInt(value.tag);
    if (tag == .null_value) {
        runtime.setFailureText("object null is not iterable (cannot read property Symbol(Symbol.iterator))");
        return error.NakoException;
    }
    if (tag == .undefined) {
        runtime.setFailureText("undefined is not iterable (cannot read property Symbol(Symbol.iterator))");
        return error.NakoException;
    }

    var elements = SearchElements{ .runtime = runtime };
    errdefer elements.deinit();
    switch (tag) {
        .static_utf8_string, .utf16_string => try appendStringSearchElements(&elements, value),
        .byte_buffer => {
            const buffer = value.object().?.payload.byte_buffer;
            if (buffer.kind != .array_buffer) for (buffer.bytes) |byte| try elements.appendValue(numberValue(@floatFromInt(byte)));
            if (buffer.kind == .array_buffer) try appendArrayBufferSearchElements(&elements, value);
        },
        .array => for (value.object().?.payload.array.items) |item| try elements.appendValue(item),
        .dictionary => try appendDictionarySearchElements(&elements, value),
        // The official generated function wrapper is not an iterable or
        // array-like value for this command, so Array.from(function) is []
        // regardless of the source function's language-level arity.
        .function => {},
        else => {},
    }
    return elements;
}

pub fn joinedSearchElementsEqual(runtime: *Runtime, source: SearchElements, start: usize, count: usize, needle: SearchElements) !bool {
    const source_end = start + count;
    var source_index = start;
    var source_offset: usize = 0;
    var needle_index: usize = 0;
    var needle_offset: usize = 0;
    var source_element = SearchElement{ .units = &.{} };
    var source_loaded = false;
    defer if (source_loaded) source_element.deinit(runtime);
    var needle_element = SearchElement{ .units = &.{} };
    var needle_loaded = false;
    defer if (needle_loaded) needle_element.deinit(runtime);

    while (true) {
        while (source_index < source_end and (!source_loaded or source_offset == source_element.units.len)) {
            if (source_loaded) {
                source_element.deinit(runtime);
                source_loaded = false;
            }
            source_element = try source.element(source_index);
            source_loaded = true;
            source_offset = 0;
            source_index += 1;
        }
        while (needle_index < needle.len() and (!needle_loaded or needle_offset == needle_element.units.len)) {
            if (needle_loaded) {
                needle_element.deinit(runtime);
                needle_loaded = false;
            }
            needle_element = try needle.element(needle_index);
            needle_loaded = true;
            needle_offset = 0;
            needle_index += 1;
        }
        const source_done = !source_loaded or (source_index == source_end and source_offset == source_element.units.len);
        const needle_done = !needle_loaded or (needle_index == needle.len() and needle_offset == needle_element.units.len);
        if (source_done or needle_done) return source_done and needle_done;
        if (source_element.units[source_offset] != needle_element.units[needle_offset]) return false;
        source_offset += 1;
        needle_offset += 1;
    }
}

pub fn codePointFindBuiltin(runtime: *Runtime, source: Value, needle: Value) !usize {
    var roots = [_]Value{ source, needle };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    if (isString(roots[0]) and isString(roots[1])) return codePointFindStringBuiltin(runtime, roots[0], roots[1]);

    var source_elements = try appendSearchElements(runtime, roots[0]);
    defer source_elements.deinit();
    var needle_elements = try appendSearchElements(runtime, roots[1]);
    defer needle_elements.deinit();
    const source_length = source_elements.len();
    const needle_length = needle_elements.len();
    var index: usize = 0;
    while (index < source_length) : (index += 1) {
        const count = @min(needle_length, source_length - index);
        if (try joinedSearchElementsEqual(runtime, source_elements, index, count, needle_elements)) return index + 1;
    }
    return 0;
}

pub fn stringBoundaryBuiltin(runtime: *Runtime, source: Value, needle: Value, starts: bool) !Value {
    try requireStringReceiver(source, starts);
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const needle_units = try valueUtf16Alloc(runtime, needle);
    defer runtime.allocator.free(needle_units);
    const matches = if (starts)
        source_units.len >= needle_units.len and std.mem.eql(u16, source_units[0..needle_units.len], needle_units)
    else
        source_units.len >= needle_units.len and std.mem.eql(u16, source_units[source_units.len - needle_units.len ..], needle_units);
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(matches) };
}

pub fn requireStringReceiver(value: Value, starts: bool) !void {
    if (isString(value)) return;
    const tag: Tag = @enumFromInt(value.tag);
    if (starts) return switch (tag) {
        .null_value => error.StartsWithNullReceiver,
        .undefined => error.StartsWithUndefinedReceiver,
        else => error.StartsWithReceiverExpected,
    };
    return switch (tag) {
        .null_value => error.EndsWithNullReceiver,
        .undefined => error.EndsWithUndefinedReceiver,
        else => error.EndsWithReceiverExpected,
    };
}

pub fn elementCountBuiltin(runtime: *Runtime, value: Value) !usize {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .byte_buffer => value.object().?.payload.byte_buffer.bytes.len,
        .array => value.object().?.payload.array.items.len,
        .dictionary => value.object().?.payload.dictionary.items.len,
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk units.len;
        },
        .function, .iterator, .promise => 0,
        .binding_cell => elementCountBuiltin(runtime, value.object().?.payload.binding_cell),
        else => 1,
    };
}
