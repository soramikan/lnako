const std = @import("std");
const state = @import("state.zig");

const Runtime = state.Runtime;
const Value = state.Value;
const Object = state.Object;
const ByteBuffer = state.ByteBuffer;
const Tag = state.Tag;
const BigInt = state.BigInt;
const RootFrame = state.RootFrame;
const isAotHttpResponse = state.isAotHttpResponse;
const shared = @import("shared.zig");
const string_mod = shared.string_mod;
const numberString = state.numberString;
const staticUtf8 = state.staticUtf8;
const valueUtf16Alloc = state.valueUtf16Alloc;
const sameKey = state.sameKey;
const dictionaryProperty = state.dictionaryProperty;
const runtimeUtf8String = state.runtimeUtf8String;
const numberValue = state.numberValue;

const JsonAotPath = union(enum) {
    array_index: usize,
    property: Value,
};

const JsonAotActive = struct {
    object: *Object,
    constructor: []const u8,
    path: ?JsonAotPath,
};

const JsonAotEntry = struct {
    key: Value,
    value: Value,
    insertion_index: usize,
    array_index: ?u32,
};

/// Pure AOT implementation of the JSON.stringify-backed command family.
/// Keep this serializer independent from QuickJS: the generated executable
/// must retain the same ECMAScript JSON boundary without a JavaScript engine.
pub fn jsonEncodeBuiltin(runtime: *Runtime, value: Value, pretty: bool) !Value {
    if (value.tag == @intFromEnum(Tag.undefined) or value.tag == @intFromEnum(Tag.function)) return .{};
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    var active_objects: std.ArrayList(JsonAotActive) = .empty;
    defer active_objects.deinit(runtime.allocator);
    try jsonWriteValue(runtime, &output.writer, value, pretty, 0, &active_objects, false, null);
    return runtime.ownString(try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, output.written()));
}

pub fn jsonWriteValue(
    runtime: *Runtime,
    writer: *std.Io.Writer,
    value: Value,
    pretty: bool,
    depth: usize,
    active_objects: *std.ArrayList(JsonAotActive),
    in_array: bool,
    path: ?JsonAotPath,
) !void {
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined, .function => if (in_array) try writer.writeAll("null") else return,
        .null_value => try writer.writeAll("null"),
        .boolean => try writer.writeAll(if (value.payload != 0) "true" else "false"),
        .number => {
            const number: f64 = @bitCast(value.payload);
            if (!std.math.isFinite(number)) return writer.writeAll("null");
            const text = try numberString(runtime.allocator, number);
            defer runtime.allocator.free(text);
            try writer.writeAll(text);
        },
        .bigint => return error.CannotSerializeBigInt,
        .static_utf8_string => {
            const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, staticUtf8(value));
            defer runtime.allocator.free(units);
            try jsonWriteQuotedString(writer, units);
        },
        .utf16_string => try jsonWriteQuotedString(writer, value.object().?.payload.utf16_string),
        .byte_buffer => try jsonWriteByteBuffer(writer, value.object().?.payload.byte_buffer, pretty, depth),
        .iterator, .promise => try writer.writeAll("{}"),
        .binding_cell => unreachable,
        .array => {
            const object = value.object().?;
            if (jsonActiveIndex(active_objects.items, object)) |cycle_start| {
                try jsonSetCircularFailureMessage(runtime, active_objects.items, cycle_start, path);
                return error.CircularCloneValue;
            }
            try active_objects.append(runtime.allocator, .{ .object = object, .constructor = "Array", .path = path });
            defer _ = active_objects.pop();
            const items = object.payload.array.items;
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try jsonWriteIndent(writer, depth + 1);
                }
                try jsonWriteValue(runtime, writer, item, pretty, depth + 1, active_objects, true, .{ .array_index = index });
            }
            if (pretty and items.len > 0) {
                try writer.writeByte('\n');
                try jsonWriteIndent(writer, depth);
            }
            try writer.writeByte(']');
        },
        .dictionary => {
            if (isAotHttpResponse(value)) return writer.writeAll("{}");
            const object = value.object().?;
            if (object.toml_temporal) |temporal| {
                try writer.writeByte('"');
                try writer.writeAll(temporal.json_text);
                return writer.writeByte('"');
            }
            if (jsonActiveIndex(active_objects.items, object)) |cycle_start| {
                try jsonSetCircularFailureMessage(runtime, active_objects.items, cycle_start, path);
                return error.CircularCloneValue;
            }
            try active_objects.append(runtime.allocator, .{ .object = object, .constructor = "Object", .path = path });
            defer _ = active_objects.pop();
            const dictionary_length = object.payload.dictionary.items.len;
            const key_roots = try runtime.allocator.alloc(Value, dictionary_length);
            defer runtime.allocator.free(key_roots);
            @memset(key_roots, .{});
            var key_frame = RootFrame{};
            runtime.pushRoots(&key_frame, if (dictionary_length > 0) key_roots.ptr else null, dictionary_length);
            defer runtime.popRoots(&key_frame);
            var entries: std.ArrayList(JsonAotEntry) = .empty;
            defer entries.deinit(runtime.allocator);
            for (object.payload.dictionary.items, 0..) |entry, insertion_index| {
                const normalized_key = try jsonAotPropertyKey(runtime, entry.key);
                key_roots[insertion_index] = normalized_key;
                var replaced = false;
                for (entries.items) |*existing| if (sameKey(existing.key, normalized_key)) {
                    // JavaScript property assignment keeps the first insertion
                    // position while a later numeric/string spelling wins.
                    existing.value = entry.value;
                    replaced = true;
                    break;
                };
                if (!replaced) try entries.append(runtime.allocator, .{
                    .key = normalized_key,
                    .value = entry.value,
                    .insertion_index = insertion_index,
                    .array_index = jsonAotArrayIndex(runtime, normalized_key),
                });
            }
            std.sort.pdq(JsonAotEntry, entries.items, {}, lessJsonAotEntry);
            try writer.writeByte('{');
            var emitted: usize = 0;
            for (entries.items) |entry| {
                if (entry.value.tag == @intFromEnum(Tag.undefined) or entry.value.tag == @intFromEnum(Tag.function)) continue;
                if (emitted > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try jsonWriteIndent(writer, depth + 1);
                }
                try jsonWriteKey(runtime, writer, entry.key);
                try writer.writeAll(if (pretty) ": " else ":");
                try jsonWriteValue(runtime, writer, entry.value, pretty, depth + 1, active_objects, false, .{ .property = entry.key });
                emitted += 1;
            }
            if (pretty and emitted > 0) {
                try writer.writeByte('\n');
                try jsonWriteIndent(writer, depth);
            }
            try writer.writeByte('}');
        },
    }
}

pub fn jsonWriteByteBuffer(writer: *std.Io.Writer, buffer: ByteBuffer, pretty: bool, depth: usize) !void {
    if (buffer.kind == .array_buffer) return writer.writeAll("{}");
    try writer.writeByte('{');
    if (buffer.kind == .uint8_array) {
        for (buffer.bytes, 0..) |byte, index| {
            if (index > 0) try writer.writeByte(',');
            if (pretty) {
                try writer.writeByte('\n');
                try jsonWriteIndent(writer, depth + 1);
            }
            try writer.print("\"{d}\":", .{index});
            if (pretty) try writer.writeByte(' ');
            try writer.print("{d}", .{byte});
        }
    } else {
        if (pretty) {
            try writer.writeByte('\n');
            try jsonWriteIndent(writer, depth + 1);
        }
        try writer.writeAll("\"type\":");
        if (pretty) try writer.writeByte(' ');
        try writer.writeAll("\"Buffer\",");
        if (pretty) {
            try writer.writeByte('\n');
            try jsonWriteIndent(writer, depth + 1);
        }
        try writer.writeAll("\"data\":");
        if (pretty) try writer.writeByte(' ');
        try writer.writeByte('[');
        for (buffer.bytes, 0..) |byte, index| {
            if (index > 0) try writer.writeByte(',');
            if (pretty and buffer.bytes.len > 0) {
                try writer.writeByte('\n');
                try jsonWriteIndent(writer, depth + 2);
            }
            try writer.print("{d}", .{byte});
        }
        if (pretty and buffer.bytes.len > 0) {
            try writer.writeByte('\n');
            try jsonWriteIndent(writer, depth + 1);
        }
        try writer.writeByte(']');
    }
    if (pretty and buffer.bytes.len > 0) {
        try writer.writeByte('\n');
        try jsonWriteIndent(writer, depth);
    }
    try writer.writeByte('}');
}

pub fn jsonActiveIndex(objects: []JsonAotActive, object: *Object) ?usize {
    for (objects, 0..) |active, index| if (active.object == object) return index;
    return null;
}

pub fn jsonAotArrayIndex(runtime: *Runtime, key: Value) ?u32 {
    const units = jsonAotKeyUnits(runtime, key) catch return null;
    defer runtime.allocator.free(units);
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var number: u64 = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        const digit: u64 = unit - '0';
        if (number > (0xffff_ffff - digit) / 10) return null;
        number = number * 10 + digit;
        if (number >= 0xffff_ffff) return null;
    }
    if (units.len == 1 and units[0] == '0') return 0;
    return @intCast(number);
}

pub fn jsonAotKeyUnits(runtime: *Runtime, key: Value) ![]u16 {
    return switch (@as(Tag, @enumFromInt(key.tag))) {
        .static_utf8_string => std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, staticUtf8(key)),
        .utf16_string => runtime.allocator.dupe(u16, key.object().?.payload.utf16_string),
        else => std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "undefined"),
    };
}

pub fn jsonAotPropertyKey(runtime: *Runtime, key: Value) !Value {
    return runtime.ownString(try valueUtf16Alloc(runtime, key));
}

pub fn lessJsonAotEntry(_: void, left: JsonAotEntry, right: JsonAotEntry) bool {
    if (left.array_index) |left_index| {
        if (right.array_index) |right_index| return left_index < right_index;
        return true;
    }
    if (right.array_index != null) return false;
    return left.insertion_index < right.insertion_index;
}

pub fn jsonWriteKey(runtime: *Runtime, writer: *std.Io.Writer, key: Value) !void {
    const units = try jsonAotKeyUnits(runtime, key);
    defer runtime.allocator.free(units);
    try jsonWriteQuotedString(writer, units);
}

pub fn jsonWriteQuotedString(writer: *std.Io.Writer, units: []const u16) !void {
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        switch (unit) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x09 => try writer.writeAll("\\t"),
            0x0a => try writer.writeAll("\\n"),
            0x0c => try writer.writeAll("\\f"),
            0x0d => try writer.writeAll("\\r"),
            0x0000...0x0007, 0x000b, 0x000e...0x001f => try jsonWriteUnicodeEscape(writer, unit),
            0xd800...0xdbff => {
                if (index + 1 < units.len and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) {
                    const codepoint: u21 = @intCast(0x10000 + ((@as(u32, unit) - 0xd800) << 10) + (@as(u32, units[index + 1]) - 0xdc00));
                    var encoded: [4]u8 = undefined;
                    const length = try std.unicode.utf8Encode(codepoint, &encoded);
                    try writer.writeAll(encoded[0..length]);
                    index += 1;
                } else try jsonWriteUnicodeEscape(writer, unit);
            },
            0xdc00...0xdfff => try jsonWriteUnicodeEscape(writer, unit),
            else => {
                var encoded: [3]u8 = undefined;
                const length = try std.unicode.utf8Encode(@intCast(unit), &encoded);
                try writer.writeAll(encoded[0..length]);
            },
        }
        index += 1;
    }
    try writer.writeByte('"');
}

pub fn jsonWriteUnicodeEscape(writer: *std.Io.Writer, unit: u16) !void {
    const digits = "0123456789abcdef";
    try writer.writeAll("\\u");
    try writer.writeByte(digits[(unit >> 12) & 0xf]);
    try writer.writeByte(digits[(unit >> 8) & 0xf]);
    try writer.writeByte(digits[(unit >> 4) & 0xf]);
    try writer.writeByte(digits[unit & 0xf]);
}

pub fn jsonWriteIndent(writer: *std.Io.Writer, depth: usize) !void {
    var index: usize = 0;
    while (index < depth) : (index += 1) try writer.writeAll("  ");
}

pub fn jsonSetCircularFailureMessage(runtime: *Runtime, active: []JsonAotActive, cycle_start: usize, closing_path: ?JsonAotPath) !void {
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    const start_constructor = if (cycle_start < active.len) active[cycle_start].constructor else "Object";
    try output.writer.print("Converting circular structure to JSON\n    --> starting at object with constructor '{s}'\n", .{start_constructor});
    // Every active entry after the root is an edge on the current path. V8
    // prints those edges before the final edge that closes the cycle.
    var index: usize = cycle_start + 1;
    while (index < active.len) : (index += 1) {
        try output.writer.writeAll("    |     ");
        try jsonWritePath(&output.writer, runtime, active[index].path, false);
        try output.writer.print(" -> object with constructor '{s}'\n", .{active[index].constructor});
    }
    try output.writer.writeAll("    --- ");
    try jsonWritePath(&output.writer, runtime, closing_path, true);
    runtime.setFailureText(output.written());
}

pub fn jsonWritePath(writer: *std.Io.Writer, runtime: *Runtime, path: ?JsonAotPath, closing: bool) !void {
    if (path) |cycle_path| switch (cycle_path) {
        .array_index => |index| try writer.print("index {d}{s}", .{ index, if (closing) " closes the circle" else "" }),
        .property => |key| {
            const units = try jsonAotKeyUnits(runtime, key);
            defer runtime.allocator.free(units);
            const utf8 = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
            defer runtime.allocator.free(utf8);
            try writer.print("property '{s}'{s}", .{ utf8, if (closing) " closes the circle" else "" });
        },
    } else if (closing) try writer.writeAll("cycle closes the circle") else try writer.writeAll("cycle");
}

pub fn expectJsonAotString(runtime: *Runtime, value: Value, pretty: bool, expected: []const u8) !void {
    const encoded = try jsonEncodeBuiltin(runtime, value, pretty);
    const actual_units = try valueUtf16Alloc(runtime, encoded);
    defer runtime.allocator.free(actual_units);
    const expected_units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, expected);
    defer runtime.allocator.free(expected_units);
    try std.testing.expectEqualSlices(u16, expected_units, actual_units);
}

/// JSON.parse-compatible decoder for the native runtime.  The input and
/// output strings are UTF-16 code-unit sequences, so escaped and literal
/// lone surrogates are retained exactly as ECMAScript does.  Using
/// `std.json` here would reject those values before the Nako value layer saw
/// them; this explicit-stack parser deliberately works on u16.
const JsonAotFrameKind = enum { array, dictionary };

const JsonAotFrameState = enum {
    array_open,
    array_need_value,
    array_after_value,
    dictionary_open,
    dictionary_need_key,
    dictionary_need_value,
    dictionary_after_value,
};

const JsonAotFrame = struct {
    kind: JsonAotFrameKind,
    state: JsonAotFrameState,
    result_index: usize,
    root_base: usize,
};

const JsonAotParser = struct {
    runtime: *Runtime,
    units: []const u16,
    index: usize = 0,

    pub fn parse(self: *JsonAotParser) anyerror!Value {
        if (jsonAsciiEquals(self.units, "undefined") or jsonAsciiEquals(self.units, "Infinity") or jsonAsciiEquals(self.units, "NaN") or jsonAsciiEquals(self.units, "[object Object]")) {
            return self.failWholeSourceInvalid();
        }
        self.skipWhitespace();
        if (self.index >= self.units.len) return self.failEnd();
        // JSON nesting is not bounded by the host call stack.  Allocate all
        // parser frames and roots up front so reallocating either collection
        // can never invalidate the root slice registered with the GC.
        const max_frames = jsonAotContainerCount(self.units);
        const frame_root_count = std.math.mul(usize, max_frames, 3) catch return error.OutOfMemory;
        const root_count = std.math.add(usize, frame_root_count, 1) catch return error.OutOfMemory;
        var roots = try self.runtime.allocator.alloc(Value, root_count);
        defer self.runtime.allocator.free(roots);
        @memset(roots, .{});
        var frames = try self.runtime.allocator.alloc(JsonAotFrame, max_frames);
        defer self.runtime.allocator.free(frames);
        var root_frame = RootFrame{};
        self.runtime.pushRoots(&root_frame, roots.ptr, roots.len);
        defer self.runtime.popRoots(&root_frame);

        var frame_count: usize = 0;
        var root_done = false;
        while (true) {
            if (frame_count == 0) {
                if (root_done) {
                    self.skipWhitespace();
                    if (self.index != self.units.len) return self.failTrailing();
                    return roots[0];
                }
                if (try self.beginValue(roots, frames, &frame_count, 0)) continue;
                roots[0] = try self.parseScalar();
                root_done = true;
                continue;
            }

            const frame_index = frame_count - 1;
            const frame = frames[frame_index];
            const base = frame.root_base;
            switch (frame.state) {
                .array_open, .array_need_value => {
                    self.skipWhitespace();
                    if (frame.state == .array_open and self.consume(']')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                        continue;
                    }
                    if (try self.beginValue(roots, frames, &frame_count, base + 2)) continue;
                    roots[base + 2] = try self.parseScalar();
                    try self.attachValue(roots, frames, frame_count, base + 2);
                },
                .array_after_value => {
                    self.skipWhitespace();
                    if (self.consume(']')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                    } else if (self.consume(',')) {
                        frames[frame_index].state = .array_need_value;
                    } else if (self.index >= self.units.len) {
                        return self.failJsonMessage("Expected ',' or ']' after array element");
                    } else return self.failToken(self.index);
                },
                .dictionary_open, .dictionary_need_key => {
                    self.skipWhitespace();
                    if (frame.state == .dictionary_open and self.consume('}')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                        continue;
                    }
                    if (frame.state == .dictionary_need_key and self.index >= self.units.len) return self.failJsonMessage("Expected double-quoted property name");
                    if (frame.state == .dictionary_need_key and self.units[self.index] != '"') return self.failJsonMessage("Expected double-quoted property name");
                    if (self.index >= self.units.len or self.units[self.index] != '"') return self.failJsonMessage("Expected property name or '}'");
                    roots[base + 1] = try self.parseStringValue();
                    self.skipWhitespace();
                    if (!self.consume(':')) return self.failJsonMessage("Expected ':' after property name");
                    frames[frame_index].state = .dictionary_need_value;
                },
                .dictionary_need_value => {
                    self.skipWhitespace();
                    if (try self.beginValue(roots, frames, &frame_count, base + 2)) continue;
                    roots[base + 2] = try self.parseScalar();
                    try self.attachValue(roots, frames, frame_count, base + 2);
                },
                .dictionary_after_value => {
                    self.skipWhitespace();
                    if (self.consume('}')) {
                        try self.closeFrame(roots, frames, &frame_count);
                        if (frame_count == 0) root_done = true;
                    } else if (self.consume(',')) {
                        frames[frame_index].state = .dictionary_need_key;
                    } else if (self.index >= self.units.len) {
                        return self.failJsonMessage("Expected ',' or '}' after property value");
                    } else return self.failToken(self.index);
                },
            }
        }
    }

    /// Start a scalar or container at `result_index`.  A container gets an
    /// explicit frame; a scalar is left for parseScalar so the caller can
    /// store it in a GC root before any append/set operation.
    pub fn beginValue(self: *JsonAotParser, roots: []Value, frames: []JsonAotFrame, frame_count: *usize, result_index: usize) !bool {
        if (self.index >= self.units.len) return self.failEnd();
        switch (self.units[self.index]) {
            '[' => {
                self.index += 1;
                roots[result_index] = try self.runtime.createArray(&.{});
                frames[frame_count.*] = .{ .kind = .array, .state = .array_open, .result_index = result_index, .root_base = 1 + frame_count.* * 3 };
                frame_count.* += 1;
                return true;
            },
            '{' => {
                self.index += 1;
                roots[result_index] = try self.runtime.createDictionary(&.{});
                frames[frame_count.*] = .{ .kind = .dictionary, .state = .dictionary_open, .result_index = result_index, .root_base = 1 + frame_count.* * 3 };
                frame_count.* += 1;
                return true;
            },
            else => return false,
        }
    }

    pub fn parseScalar(self: *JsonAotParser) anyerror!Value {
        if (self.index >= self.units.len) return self.failEnd();
        return switch (self.units[self.index]) {
            'n' => try self.parseLiteral("null", .{ .tag = @intFromEnum(Tag.null_value) }),
            't' => try self.parseLiteral("true", .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 }),
            'f' => try self.parseLiteral("false", .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 }),
            '"' => try self.parseStringValue(),
            '-', '0'...'9' => try self.parseNumber(),
            else => self.failToken(self.index),
        };
    }

    pub fn attachValue(self: *JsonAotParser, roots: []Value, frames: []JsonAotFrame, frame_count: usize, value_index: usize) !void {
        const parent_index = frame_count - 1;
        const parent = frames[parent_index];
        const parent_base = parent.root_base;
        switch (frames[parent_index].kind) {
            .array => {
                try roots[parent.result_index].object().?.payload.array.append(self.runtime.allocator, roots[value_index]);
                frames[parent_index].state = .array_after_value;
            },
            .dictionary => {
                try self.runtime.setDictionary(&roots[parent.result_index].object().?.payload.dictionary, roots[parent_base + 1], roots[value_index]);
                frames[parent_index].state = .dictionary_after_value;
            },
        }
    }

    pub fn closeFrame(self: *JsonAotParser, roots: []Value, frames: []JsonAotFrame, frame_count: *usize) !void {
        const child_index = frame_count.* - 1;
        const child_base = frames[child_index].result_index;
        frame_count.* -= 1;
        if (frame_count.* == 0) {
            roots[0] = roots[child_base];
            return;
        }
        try self.attachValue(roots, frames, frame_count.*, child_base);
    }

    pub fn parseLiteral(self: *JsonAotParser, comptime literal: []const u8, value: Value) anyerror!Value {
        if (self.index + literal.len > self.units.len) return self.failEnd();
        for (literal, 0..) |byte, offset| if (self.units[self.index + offset] != byte) return self.failToken(self.index + offset);
        self.index += literal.len;
        return value;
    }

    pub fn parseStringValue(self: *JsonAotParser) anyerror!Value {
        const units = try self.parseStringUnits();
        defer self.runtime.allocator.free(units);
        return self.runtime.createString(units);
    }

    pub fn parseStringUnits(self: *JsonAotParser) anyerror![]u16 {
        if (self.index >= self.units.len or self.units[self.index] != '"') return self.failToken(self.index);
        self.index += 1;
        var result: std.ArrayList(u16) = .empty;
        errdefer result.deinit(self.runtime.allocator);
        while (self.index < self.units.len) {
            const unit = self.units[self.index];
            self.index += 1;
            switch (unit) {
                '"' => return result.toOwnedSlice(self.runtime.allocator),
                '\\' => {
                    if (self.index >= self.units.len) return self.failEnd();
                    const escaped = self.units[self.index];
                    self.index += 1;
                    switch (escaped) {
                        '"', '\\', '/' => try result.append(self.runtime.allocator, escaped),
                        'b' => try result.append(self.runtime.allocator, 0x08),
                        'f' => try result.append(self.runtime.allocator, 0x0c),
                        'n' => try result.append(self.runtime.allocator, 0x0a),
                        'r' => try result.append(self.runtime.allocator, 0x0d),
                        't' => try result.append(self.runtime.allocator, 0x09),
                        'u' => {
                            if (self.index + 4 > self.units.len) return self.failJsonMessageAt("Bad Unicode escape", if (self.units.len > 0 and self.units[self.units.len - 1] == '"') self.units.len - 1 else self.units.len);
                            var code_unit: u16 = 0;
                            for (self.units[self.index .. self.index + 4], 0..) |digit, offset| {
                                const value = jsonHexDigit(digit) orelse return self.failJsonMessageAt("Bad Unicode escape", self.index + offset);
                                code_unit = (code_unit << 4) | value;
                            }
                            self.index += 4;
                            // ECMAScript JSON.parse preserves lone surrogates.
                            // A valid pair is also kept as two UTF-16 units.
                            try result.append(self.runtime.allocator, code_unit);
                        },
                        else => return self.failJsonMessageAt("Bad escaped character", self.index - 1),
                    }
                },
                0...0x1f => return self.failJsonMessageAt("Bad control character in string literal", self.index - 1),
                else => try result.append(self.runtime.allocator, unit),
            }
        }
        return self.failJsonMessage("Unterminated string");
    }

    pub fn parseNumber(self: *JsonAotParser) anyerror!Value {
        const start = self.index;
        if (self.consume('-') and (self.index >= self.units.len or !isJsonDigit(self.units[self.index]))) return self.failJsonMessage("No number after minus sign");
        if (self.consume('0')) {
            if (self.index < self.units.len and isJsonDigit(self.units[self.index])) return self.failJsonMessage("Unexpected number");
        } else {
            if (self.index >= self.units.len or self.units[self.index] < '1' or self.units[self.index] > '9') return self.failToken(self.index);
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        if (self.consume('.')) {
            if (self.index >= self.units.len or !isJsonDigit(self.units[self.index])) return self.failJsonMessage("Unterminated fractional number");
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        if (self.index < self.units.len and (self.units[self.index] == 'e' or self.units[self.index] == 'E')) {
            self.index += 1;
            _ = self.consume('+') or self.consume('-');
            if (self.index >= self.units.len or !isJsonDigit(self.units[self.index])) return self.failJsonMessage("Exponent part is missing a number");
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        const number_units = self.units[start..self.index];
        var ascii = try self.runtime.allocator.alloc(u8, number_units.len);
        defer self.runtime.allocator.free(ascii);
        for (number_units, 0..) |unit, offset| ascii[offset] = @intCast(unit);
        const number = std.fmt.parseFloat(f64, ascii) catch jsonParseDecimal(number_units);
        return .{ .tag = @intFromEnum(Tag.number), .payload = @bitCast(number) };
    }

    pub fn consume(self: *JsonAotParser, expected: u16) bool {
        if (self.index < self.units.len and self.units[self.index] == expected) {
            self.index += 1;
            return true;
        }
        return false;
    }

    pub fn skipWhitespace(self: *JsonAotParser) void {
        while (self.index < self.units.len) switch (self.units[self.index]) {
            ' ', '\n', '\r', '\t' => self.index += 1,
            else => return,
        };
    }

    pub fn failEnd(self: *JsonAotParser) anyerror {
        self.runtime.setFailureText("Unexpected end of JSON input");
        return error.InvalidJsonCloneValue;
    }

    pub fn failJsonMessage(self: *JsonAotParser, prefix: []const u8) anyerror {
        return self.failJsonMessageAt(prefix, self.index);
    }

    pub fn failJsonMessageAt(self: *JsonAotParser, prefix: []const u8, position: usize) anyerror {
        var line: usize = 1;
        var column: usize = 1;
        const bounded = @min(position, self.units.len);
        var offset: usize = 0;
        while (offset < bounded) : (offset += 1) {
            const unit = self.units[offset];
            if (unit == '\r') {
                if (offset + 1 < bounded and self.units[offset + 1] == '\n') offset += 1;
                line += 1;
                column = 1;
                continue;
            }
            if (unit == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        const message = std.fmt.allocPrint(self.runtime.allocator, "{s} in JSON at position {d} (line {d} column {d})", .{ prefix, bounded, line, column }) catch return error.InvalidJsonCloneValue;
        defer self.runtime.allocator.free(message);
        self.runtime.setFailureText(message);
        return error.InvalidJsonCloneValue;
    }

    pub fn failToken(self: *JsonAotParser, position: usize) anyerror {
        if (position >= self.units.len) return self.failEnd();
        var message: std.ArrayList(u16) = .empty;
        errdefer message.deinit(self.runtime.allocator);
        try appendAsciiUnits(&message, self.runtime.allocator, "Unexpected token '");
        try message.append(self.runtime.allocator, self.units[position]);
        try appendAsciiUnits(&message, self.runtime.allocator, "', ");
        try self.appendJsonErrorSourceUnits(&message, true, position);
        try appendAsciiUnits(&message, self.runtime.allocator, " is not valid JSON");
        self.runtime.setFailureUnits(message.items);
        return error.InvalidJsonCloneValue;
    }

    pub fn failWholeSourceInvalid(self: *JsonAotParser) anyerror {
        var message: std.ArrayList(u16) = .empty;
        errdefer message.deinit(self.runtime.allocator);
        try self.appendJsonErrorSourceUnits(&message, false, 0);
        try appendAsciiUnits(&message, self.runtime.allocator, " is not valid JSON");
        self.runtime.setFailureUnits(message.items);
        return error.InvalidJsonCloneValue;
    }

    /// V8 shows a UTF-16 window of at most ten code units on either side of
    /// the invalid token.  Diagnostic source text is not JSON-escaped: raw
    /// quotes, backslashes, and control units are retained by Node 24.
    pub fn appendJsonErrorSourceUnits(self: *JsonAotParser, output: *std.ArrayList(u16), truncate: bool, position: usize) !void {
        const bounded = @min(position, self.units.len);
        const should_truncate = truncate and self.units.len > 20;
        const start = if (should_truncate and bounded > 10) bounded - 10 else 0;
        const end = if (should_truncate) @min(self.units.len, bounded + 10) else self.units.len;
        const leading_ellipsis = should_truncate and (start > 0 or bounded >= 10);
        if (leading_ellipsis) try appendAsciiUnits(output, self.runtime.allocator, "...");
        try output.append(self.runtime.allocator, '"');
        try output.appendSlice(self.runtime.allocator, self.units[start..end]);
        try output.append(self.runtime.allocator, '"');
        if (should_truncate and end < self.units.len) try appendAsciiUnits(output, self.runtime.allocator, "...");
    }

    pub fn failTrailing(self: *JsonAotParser) anyerror {
        const position = self.index;
        var line: usize = 1;
        var column: usize = 1;
        var offset: usize = 0;
        while (offset < position) : (offset += 1) {
            const unit = self.units[offset];
            if (unit == '\r') {
                if (offset + 1 < position and self.units[offset + 1] == '\n') offset += 1;
                line += 1;
                column = 1;
            } else if (unit == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        const message = std.fmt.allocPrint(self.runtime.allocator, "Unexpected non-whitespace character after JSON at position {d} (line {d} column {d})", .{ position, line, column }) catch return error.InvalidJsonCloneValue;
        defer self.runtime.allocator.free(message);
        self.runtime.setFailureText(message);
        return error.InvalidJsonCloneValue;
    }
};

pub fn appendAsciiUnits(output: *std.ArrayList(u16), allocator: std.mem.Allocator, ascii: []const u8) !void {
    for (ascii) |byte| try output.append(allocator, byte);
}

pub fn appendUtf8Units(output: *std.ArrayList(u16), allocator: std.mem.Allocator, text: []const u8) !void {
    const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
    defer allocator.free(units);
    try output.appendSlice(allocator, units);
}

pub fn jsonHexDigit(unit: u16) ?u16 {
    return if (unit >= '0' and unit <= '9') unit - '0' else if (unit >= 'a' and unit <= 'f') unit - 'a' + 10 else if (unit >= 'A' and unit <= 'F') unit - 'A' + 10 else null;
}

pub fn isJsonDigit(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

pub fn jsonAsciiEquals(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |unit, byte| if (unit != byte) return false;
    return true;
}

/// Count only container starts outside JSON strings.  This is a sizing scan,
/// not validation: malformed input may still be rejected by the parser, but
/// every opening token the parser could process is counted unless it is inside
/// the same string/escape state that parseStringUnits uses.
pub fn jsonAotContainerCount(units: []const u16) usize {
    var count: usize = 0;
    var in_string = false;
    var escaped = false;
    for (units) |unit| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (unit == '\\') {
                escaped = true;
            } else if (unit == '"') {
                in_string = false;
            }
            continue;
        }
        if (unit == '"') {
            in_string = true;
        } else if (unit == '[' or unit == '{') {
            count = std.math.add(usize, count, 1) catch return std.math.maxInt(usize);
        }
    }
    return @max(count, 1);
}

pub fn jsonParseDecimal(units: []const u16) f64 {
    var index: usize = 0;
    const negative = units.len > 0 and units[0] == '-';
    if (negative) index += 1;
    var value: f64 = 0;
    while (index < units.len and isJsonDigit(units[index])) : (index += 1) value = value * 10 + @as(f64, @floatFromInt(units[index] - '0'));
    if (index < units.len and units[index] == '.') {
        index += 1;
        var scale: f64 = 0.1;
        while (index < units.len and isJsonDigit(units[index])) : (index += 1) {
            value += @as(f64, @floatFromInt(units[index] - '0')) * scale;
            scale *= 0.1;
        }
    }
    var exponent: i32 = 0;
    if (index < units.len and (units[index] == 'e' or units[index] == 'E')) {
        index += 1;
        var exponent_negative = false;
        if (index < units.len and (units[index] == '+' or units[index] == '-')) {
            exponent_negative = units[index] == '-';
            index += 1;
        }
        while (index < units.len and isJsonDigit(units[index])) : (index += 1) exponent = @min(@as(i32, 10000), exponent * 10 + @as(i32, @intCast(units[index] - '0')));
        if (exponent_negative) exponent = -exponent;
    }
    const result = value * std.math.pow(f64, 10, @floatFromInt(exponent));
    return if (negative) -result else result;
}

pub fn jsonDecodeBuiltin(runtime: *Runtime, source: Value) !Value {
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    var parser = JsonAotParser{ .runtime = runtime, .units = units };
    return parser.parse();
}
