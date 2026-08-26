const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const common = @import("common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

const DictionaryEntry = struct {
    key: *value_mod.String,
    value: Value,
    insertion_index: usize,
    array_index: ?u32,
};

const JsonPath = union(enum) {
    array_index: usize,
    property: *value_mod.String,
};

const JsonActive = struct {
    object: union(enum) { array: *value_mod.Array, dictionary: *value_mod.Dictionary },
    constructor: []const u8,
    path: ?JsonPath,
};

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const value = common.argument(arguments, 0);
    if (isCompactEncode(name)) return try encode(runtime, value, false);
    if (isPrettyEncode(name)) return try encode(runtime, value, true);
    if (isDecode(name)) return try decode(runtime, value);
    return null;
}

fn encode(runtime: *Runtime, value: Value, pretty: bool) !Value {
    if (value == .undefined or value == .function) return .undefined;
    var output: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer output.deinit();
    var active_objects: std.ArrayList(JsonActive) = .empty;
    defer active_objects.deinit(runtime.allocator());
    try writeValue(runtime, &output.writer, value, pretty, 0, &active_objects, false, null);
    return runtime.stringUtf8(output.written());
}

fn writeValue(
    runtime: *Runtime,
    writer: *std.Io.Writer,
    value: Value,
    pretty: bool,
    depth: usize,
    active_objects: *std.ArrayList(JsonActive),
    in_array: bool,
    path: ?JsonPath,
) !void {
    switch (value) {
        .undefined, .function => try writer.writeAll(if (in_array) "null" else return error.UnsupportedJsonValue),
        .promise => try writer.writeAll("{}"),
        .null_value => try writer.writeAll("null"),
        .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .number => |number| {
            if (!std.math.isFinite(number)) return writer.writeAll("null");
            const text = try value_mod.numberToStringAlloc(runtime.allocator(), number);
            defer runtime.allocator().free(text);
            try writer.writeAll(text);
        },
        .bigint => return error.CannotSerializeBigInt,
        .string => |string| try writeQuotedString(writer, string.units),
        .bytes => |buffer| {
            if (buffer.kind == .array_buffer) return writer.writeAll("{}");
            if (buffer.kind == .uint8_array) {
                try writer.writeByte('{');
                for (buffer.bytes, 0..) |byte, index| {
                    if (index > 0) try writer.writeByte(',');
                    if (pretty) {
                        try writer.writeByte('\n');
                        try writeIndent(writer, depth + 1);
                    }
                    try writer.print("\"{d}\":", .{index});
                    if (pretty) try writer.writeByte(' ');
                    try writer.print("{d}", .{byte});
                }
                if (pretty and buffer.bytes.len > 0) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, depth);
                }
                try writer.writeByte('}');
                return;
            }
            try writer.writeByte('{');
            if (pretty) {
                try writer.writeByte('\n');
                try writeIndent(writer, depth + 1);
            }
            try writer.writeAll("\"type\":");
            if (pretty) try writer.writeByte(' ');
            try writer.writeAll("\"Buffer\",");
            if (pretty) {
                try writer.writeByte('\n');
                try writeIndent(writer, depth + 1);
            }
            try writer.writeAll("\"data\":");
            if (pretty) try writer.writeByte(' ');
            try writer.writeByte('[');
            for (buffer.bytes, 0..) |byte, index| {
                if (index > 0) try writer.writeByte(',');
                if (pretty and buffer.bytes.len > 0) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, depth + 2);
                }
                try writer.print("{d}", .{byte});
            }
            if (pretty and buffer.bytes.len > 0) {
                try writer.writeByte('\n');
                try writeIndent(writer, depth + 1);
            }
            try writer.writeByte(']');
            if (pretty) {
                try writer.writeByte('\n');
                try writeIndent(writer, depth);
            }
            try writer.writeByte('}');
        },
        .array => |array| {
            if (jsonActiveIndexArray(active_objects.items, array)) |cycle_start| {
                try setCircularFailureMessage(runtime, active_objects.items, cycle_start, path);
                return error.CircularCloneValue;
            }
            try active_objects.append(runtime.allocator(), .{ .object = .{ .array = array }, .constructor = "Array", .path = path });
            defer _ = active_objects.pop();
            try writer.writeByte('[');
            for (array.items.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, depth + 1);
                }
                try writeValue(runtime, writer, item, pretty, depth + 1, active_objects, true, .{ .array_index = index });
            }
            if (pretty and array.items.items.len > 0) {
                try writer.writeByte('\n');
                try writeIndent(writer, depth);
            }
            try writer.writeByte(']');
        },
        .dictionary => |dictionary| {
            if (dictionary.kind == .http_response) return writer.writeAll("{}");
            if (jsonActiveIndexDictionary(active_objects.items, dictionary)) |cycle_start| {
                try setCircularFailureMessage(runtime, active_objects.items, cycle_start, path);
                return error.CircularCloneValue;
            }
            try active_objects.append(runtime.allocator(), .{ .object = .{ .dictionary = dictionary }, .constructor = "Object", .path = path });
            defer _ = active_objects.pop();

            var entries: std.ArrayList(DictionaryEntry) = .empty;
            defer entries.deinit(runtime.allocator());
            for (dictionary.keys(), dictionary.values(), 0..) |key, item, insertion_index| {
                if (item == .undefined or item == .function) continue;
                try entries.append(runtime.allocator(), .{
                    .key = key,
                    .value = item,
                    .insertion_index = insertion_index,
                    .array_index = jsonArrayIndex(key.units),
                });
            }
            std.sort.pdq(DictionaryEntry, entries.items, {}, lessDictionaryEntry);
            try writer.writeByte('{');
            var emitted: usize = 0;
            for (entries.items) |entry| {
                if (emitted > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, depth + 1);
                }
                try writeQuotedString(writer, entry.key.units);
                try writer.writeAll(if (pretty) ": " else ":");
                try writeValue(runtime, writer, entry.value, pretty, depth + 1, active_objects, false, .{ .property = entry.key });
                emitted += 1;
            }
            if (pretty and emitted > 0) {
                try writer.writeByte('\n');
                try writeIndent(writer, depth);
            }
            try writer.writeByte('}');
        },
    }
}

fn jsonActiveIndexArray(active: []JsonActive, target: *value_mod.Array) ?usize {
    for (active, 0..) |entry, index| if (entry.object == .array and entry.object.array == target) return index;
    return null;
}

fn jsonActiveIndexDictionary(active: []JsonActive, target: *value_mod.Dictionary) ?usize {
    for (active, 0..) |entry, index| if (entry.object == .dictionary and entry.object.dictionary == target) return index;
    return null;
}

fn setCircularFailureMessage(runtime: *Runtime, active: []JsonActive, cycle_start: usize, closing_path: ?JsonPath) !void {
    var output: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer output.deinit();
    const constructor = if (cycle_start < active.len) active[cycle_start].constructor else "Object";
    try output.writer.print("Converting circular structure to JSON\n    --> starting at object with constructor '{s}'\n", .{constructor});
    var index: usize = cycle_start + 1;
    while (index < active.len) : (index += 1) {
        try output.writer.writeAll("    |     ");
        try writeJsonPath(&output.writer, runtime, active[index].path, false);
        try output.writer.print(" -> object with constructor '{s}'\n", .{active[index].constructor});
    }
    try output.writer.writeAll("    --- ");
    try writeJsonPath(&output.writer, runtime, closing_path, true);
    try runtime.setFailureMessage(output.written());
}

fn writeJsonPath(writer: *std.Io.Writer, runtime: *Runtime, path: ?JsonPath, closing: bool) !void {
    if (path) |cycle_path| switch (cycle_path) {
        .array_index => |index| try writer.print("index {d}{s}", .{ index, if (closing) " closes the circle" else "" }),
        .property => |key| {
            const key_utf8 = try key.toUtf8Lossy(runtime.allocator());
            defer runtime.allocator().free(key_utf8);
            try writer.print("property '{s}'{s}", .{ key_utf8, if (closing) " closes the circle" else "" });
        },
    } else if (closing) try writer.writeAll("cycle closes the circle") else try writer.writeAll("cycle");
}

/// ECMAScript JSON.stringify enumerates canonical array-index property names
/// first in ascending order, followed by other string keys in insertion order.
/// Nako dictionaries retain insertion order, so the serializer performs this
/// ordering at the JSON boundary without changing dictionary enumeration.
fn jsonArrayIndex(units: []const u16) ?u32 {
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var value: u64 = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        const digit: u64 = unit - '0';
        if (value > (0xffff_ffff - digit) / 10) return null;
        value = value * 10 + digit;
        if (value >= 0xffff_ffff) return null;
    }
    if (value == 0xffff_ffff) return null;
    if (units.len == 1 and units[0] == '0') return 0;
    return @intCast(value);
}

fn lessDictionaryEntry(_: void, left: DictionaryEntry, right: DictionaryEntry) bool {
    if (left.array_index) |left_index| {
        if (right.array_index) |right_index| return left_index < right_index;
        return true;
    }
    if (right.array_index != null) return false;
    return left.insertion_index < right.insertion_index;
}

fn writeQuotedString(writer: *std.Io.Writer, units: []const u16) !void {
    try writer.writeByte('"');
    var index: usize = 0;
    while (index < units.len) {
        const first = units[index];
        switch (first) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            0x08 => try writer.writeAll("\\b"),
            0x09 => try writer.writeAll("\\t"),
            0x0a => try writer.writeAll("\\n"),
            0x0c => try writer.writeAll("\\f"),
            0x0d => try writer.writeAll("\\r"),
            0x0000...0x0007, 0x000b, 0x000e...0x001f => try writeUnicodeEscape(writer, first),
            0xd800...0xdbff => {
                if (index + 1 < units.len and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) {
                    const codepoint: u21 = @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, units[index + 1]) - 0xdc00));
                    var encoded: [4]u8 = undefined;
                    const length = try std.unicode.utf8Encode(codepoint, &encoded);
                    try writer.writeAll(encoded[0..length]);
                    index += 1;
                } else try writeUnicodeEscape(writer, first);
            },
            0xdc00...0xdfff => try writeUnicodeEscape(writer, first),
            else => {
                const codepoint: u21 = @intCast(first);
                var encoded: [3]u8 = undefined;
                const length = try std.unicode.utf8Encode(codepoint, &encoded);
                try writer.writeAll(encoded[0..length]);
            },
        }
        index += 1;
    }
    try writer.writeByte('"');
}

fn writeUnicodeEscape(writer: *std.Io.Writer, unit: u16) !void {
    const digits = "0123456789abcdef";
    try writer.writeAll("\\u");
    try writer.writeByte(digits[(unit >> 12) & 0xf]);
    try writer.writeByte(digits[(unit >> 8) & 0xf]);
    try writer.writeByte(digits[(unit >> 4) & 0xf]);
    try writer.writeByte(digits[unit & 0xf]);
}

fn writeIndent(writer: *std.Io.Writer, depth: usize) !void {
    for (0..depth * 2) |_| try writer.writeByte(' ');
}

fn decode(runtime: *Runtime, source: Value) !Value {
    const text_value = try runtime.valueToString(source);
    var text_root = text_value;
    var text_frame = runtime.rootFrame();
    defer text_frame.deinit();
    try text_frame.protect(&text_root);
    var parser = JsonParser{ .runtime = runtime, .units = text_root.string.units };
    return parser.parse();
}

const JsonFrameKind = enum { array, object };
const JsonFrameState = enum {
    array_value_or_end,
    array_value_after_comma,
    array_delimiter,
    object_key_or_end,
    object_key_after_comma,
    object_colon,
    object_value,
    object_delimiter,
};

const JsonFrame = struct {
    container: Value,
    kind: JsonFrameKind,
    state: JsonFrameState,
    pending_key: Value = .undefined,
};

/// JSON.parse-compatible UTF-16 parser for the interpreter runtime.
///
/// The parser deliberately keeps the input as UTF-16 code units. Converting
/// the source to UTF-8 first would replace lone surrogates, which JSON.parse
/// preserves. Containers are processed by an explicit stack so deeply nested
/// JSON does not consume the C call stack.
const JsonParser = struct {
    runtime: *Runtime,
    units: []const u16,
    index: usize = 0,
    frames: std.ArrayList(JsonFrame) = .empty,
    root: Value = .undefined,
    has_root: bool = false,

    fn parse(self: *JsonParser) !Value {
        defer self.frames.deinit(self.runtime.allocator());
        try self.runtime.registerRootProvider(.{ .context = self, .traceFn = traceRoots });
        defer self.runtime.unregisterRootProvider(self);

        if (jsonAsciiEquals(self.units, "undefined") or
            jsonAsciiEquals(self.units, "Infinity") or
            jsonAsciiEquals(self.units, "NaN") or
            jsonAsciiEquals(self.units, "[object Object]"))
        {
            return self.failWholeSourceInvalid();
        }

        self.skipWhitespace();
        while (true) {
            if (self.frames.items.len == 0) {
                if (!self.has_root) {
                    const value = try self.readValue();
                    if (value) |parsed| {
                        self.root = parsed;
                        self.has_root = true;
                    }
                    continue;
                }
                self.skipWhitespace();
                if (self.index != self.units.len) return self.failTrailing();
                return self.root;
            }

            const frame_index = self.frames.items.len - 1;
            switch (self.frames.items[frame_index].state) {
                .array_value_or_end => {
                    self.skipWhitespace();
                    if (self.consume(']')) {
                        const completed = self.frames.pop().?.container;
                        try self.deliver(completed);
                    } else if (self.index >= self.units.len) {
                        return self.failEnd();
                    } else {
                        self.frames.items[frame_index].state = .array_delimiter;
                        if (try self.readValue()) |value| try self.deliver(value);
                    }
                },
                .array_value_after_comma => {
                    self.skipWhitespace();
                    if (self.index >= self.units.len) return self.failEnd();
                    if (self.units[self.index] == ']') return self.failToken(self.index);
                    self.frames.items[frame_index].state = .array_delimiter;
                    if (try self.readValue()) |value| try self.deliver(value);
                },
                .array_delimiter => {
                    self.skipWhitespace();
                    if (self.consume(']')) {
                        const completed = self.frames.pop().?.container;
                        try self.deliver(completed);
                    } else if (self.consume(',')) {
                        self.frames.items[frame_index].state = .array_value_after_comma;
                    } else if (self.index >= self.units.len) {
                        return self.failJsonMessage("Expected ',' or ']' after array element");
                    } else {
                        return self.failToken(self.index);
                    }
                },
                .object_key_or_end => {
                    self.skipWhitespace();
                    if (self.consume('}')) {
                        const completed = self.frames.pop().?.container;
                        try self.deliver(completed);
                    } else if (self.index >= self.units.len) {
                        return self.failJsonMessage("Expected property name or '}'");
                    } else if (self.units[self.index] != '"') {
                        return self.failJsonMessage("Expected property name or '}'");
                    } else {
                        self.frames.items[frame_index].pending_key = try self.parseStringValue();
                        self.frames.items[frame_index].state = .object_colon;
                    }
                },
                .object_key_after_comma => {
                    self.skipWhitespace();
                    if (self.index >= self.units.len) return self.failJsonMessage("Expected double-quoted property name");
                    if (self.units[self.index] != '"') return self.failJsonMessage("Expected double-quoted property name");
                    self.frames.items[frame_index].pending_key = try self.parseStringValue();
                    self.frames.items[frame_index].state = .object_colon;
                },
                .object_colon => {
                    self.skipWhitespace();
                    if (!self.consume(':')) return self.failJsonMessage("Expected ':' after property name");
                    self.frames.items[frame_index].state = .object_value;
                },
                .object_value => {
                    self.skipWhitespace();
                    if (self.index >= self.units.len) return self.failEnd();
                    self.frames.items[frame_index].state = .object_delimiter;
                    if (try self.readValue()) |value| try self.deliver(value);
                },
                .object_delimiter => {
                    self.skipWhitespace();
                    if (self.consume('}')) {
                        const completed = self.frames.pop().?.container;
                        try self.deliver(completed);
                    } else if (self.consume(',')) {
                        self.frames.items[frame_index].state = .object_key_after_comma;
                    } else if (self.index >= self.units.len) {
                        return self.failJsonMessage("Expected ',' or '}' after property value");
                    } else {
                        return self.failToken(self.index);
                    }
                },
            }
        }
    }

    fn traceRoots(context: *anyopaque, runtime: *Runtime) !void {
        const self: *JsonParser = @ptrCast(@alignCast(context));
        for (self.frames.items) |frame| {
            try runtime.traceExternal(frame.container);
            try runtime.traceExternal(frame.pending_key);
        }
    }

    fn readValue(self: *JsonParser) !?Value {
        if (self.index >= self.units.len) {
            _ = self.failEnd() catch |failure| return failure;
            unreachable;
        }
        return switch (self.units[self.index]) {
            'n' => try self.parseLiteral("null", .null_value),
            't' => try self.parseLiteral("true", .{ .boolean = true }),
            'f' => try self.parseLiteral("false", .{ .boolean = false }),
            '"' => try self.parseStringValue(),
            '[' => blk: {
                self.index += 1;
                const container = try self.runtime.createArray();
                try self.frames.append(self.runtime.allocator(), .{
                    .container = container,
                    .kind = .array,
                    .state = .array_value_or_end,
                });
                break :blk null;
            },
            '{' => blk: {
                self.index += 1;
                const container = try self.runtime.createDictionary();
                try self.frames.append(self.runtime.allocator(), .{
                    .container = container,
                    .kind = .object,
                    .state = .object_key_or_end,
                });
                break :blk null;
            },
            '-', '0'...'9' => try self.parseNumber(),
            else => {
                _ = self.failToken(self.index) catch |failure| return failure;
                unreachable;
            },
        };
    }

    fn deliver(self: *JsonParser, value: Value) !void {
        if (self.frames.items.len == 0) {
            self.root = value;
            self.has_root = true;
            return;
        }
        const frame = &self.frames.items[self.frames.items.len - 1];
        switch (frame.kind) {
            .array => _ = try frame.container.array.push(value),
            .object => {
                try frame.container.dictionary.set(frame.pending_key.string, value);
                frame.pending_key = .undefined;
            },
        }
    }

    fn parseLiteral(self: *JsonParser, comptime literal: []const u8, value: Value) !?Value {
        if (self.index + literal.len > self.units.len) {
            _ = self.failEnd() catch |failure| return failure;
            unreachable;
        }
        for (literal, 0..) |byte, offset| {
            if (self.units[self.index + offset] != byte) {
                _ = self.failToken(self.index + offset) catch |failure| return failure;
                unreachable;
            }
        }
        self.index += literal.len;
        return value;
    }

    fn parseStringValue(self: *JsonParser) !Value {
        const units = try self.parseStringUnits();
        defer self.runtime.allocator().free(units);
        return self.runtime.stringCodeUnits(units);
    }

    fn parseStringUnits(self: *JsonParser) ![]u16 {
        if (self.index >= self.units.len or self.units[self.index] != '"') {
            _ = self.failToken(self.index) catch |failure| return failure;
            unreachable;
        }
        self.index += 1;
        var result: std.ArrayList(u16) = .empty;
        errdefer result.deinit(self.runtime.allocator());
        while (self.index < self.units.len) {
            const unit = self.units[self.index];
            self.index += 1;
            switch (unit) {
                '"' => return result.toOwnedSlice(self.runtime.allocator()),
                '\\' => {
                    if (self.index >= self.units.len) {
                        _ = self.failEnd() catch |failure| return failure;
                        unreachable;
                    }
                    const escaped = self.units[self.index];
                    self.index += 1;
                    switch (escaped) {
                        '"', '\\', '/' => try result.append(self.runtime.allocator(), escaped),
                        'b' => try result.append(self.runtime.allocator(), 0x08),
                        'f' => try result.append(self.runtime.allocator(), 0x0c),
                        'n' => try result.append(self.runtime.allocator(), 0x0a),
                        'r' => try result.append(self.runtime.allocator(), 0x0d),
                        't' => try result.append(self.runtime.allocator(), 0x09),
                        'u' => {
                            if (self.index + 4 > self.units.len) {
                                _ = self.failJsonMessageAt(
                                    "Bad Unicode escape",
                                    if (self.units.len > 0 and self.units[self.units.len - 1] == '"') self.units.len - 1 else self.units.len,
                                ) catch |failure| return failure;
                                unreachable;
                            }
                            var code_unit: u16 = 0;
                            for (self.units[self.index .. self.index + 4], 0..) |digit, offset| {
                                const value = jsonHexDigit(digit) orelse {
                                    _ = self.failJsonMessageAt("Bad Unicode escape", self.index + offset) catch |failure| return failure;
                                    unreachable;
                                };
                                code_unit = (code_unit << 4) | value;
                            }
                            self.index += 4;
                            try result.append(self.runtime.allocator(), code_unit);
                        },
                        else => {
                            _ = self.failJsonMessageAt("Bad escaped character", self.index - 1) catch |failure| return failure;
                            unreachable;
                        },
                    }
                },
                0...0x1f => {
                    _ = self.failJsonMessageAt("Bad control character in string literal", self.index - 1) catch |failure| return failure;
                    unreachable;
                },
                else => try result.append(self.runtime.allocator(), unit),
            }
        }
        _ = self.failJsonMessage("Unterminated string") catch |failure| return failure;
        unreachable;
    }

    fn parseNumber(self: *JsonParser) !?Value {
        const start = self.index;
        if (self.consume('-') and (self.index >= self.units.len or !isJsonDigit(self.units[self.index]))) {
            _ = self.failJsonMessage("No number after minus sign") catch |failure| return failure;
            unreachable;
        }
        if (self.consume('0')) {
            if (self.index < self.units.len and isJsonDigit(self.units[self.index])) {
                _ = self.failJsonMessage("Unexpected number") catch |failure| return failure;
                unreachable;
            }
        } else {
            if (self.index >= self.units.len or self.units[self.index] < '1' or self.units[self.index] > '9') {
                _ = self.failToken(self.index) catch |failure| return failure;
                unreachable;
            }
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        if (self.consume('.')) {
            if (self.index >= self.units.len or !isJsonDigit(self.units[self.index])) {
                _ = self.failJsonMessage("Unterminated fractional number") catch |failure| return failure;
                unreachable;
            }
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        if (self.index < self.units.len and (self.units[self.index] == 'e' or self.units[self.index] == 'E')) {
            self.index += 1;
            _ = self.consume('+') or self.consume('-');
            if (self.index >= self.units.len or !isJsonDigit(self.units[self.index])) {
                _ = self.failJsonMessage("Exponent part is missing a number") catch |failure| return failure;
                unreachable;
            }
            while (self.index < self.units.len and isJsonDigit(self.units[self.index])) self.index += 1;
        }
        const number_units = self.units[start..self.index];
        const ascii = try self.runtime.allocator().alloc(u8, number_units.len);
        defer self.runtime.allocator().free(ascii);
        for (number_units, 0..) |unit, offset| ascii[offset] = @intCast(unit);
        const number = std.fmt.parseFloat(f64, ascii) catch jsonParseDecimal(number_units);
        return .{ .number = number };
    }

    fn consume(self: *JsonParser, expected: u16) bool {
        if (self.index < self.units.len and self.units[self.index] == expected) {
            self.index += 1;
            return true;
        }
        return false;
    }

    fn skipWhitespace(self: *JsonParser) void {
        while (self.index < self.units.len) switch (self.units[self.index]) {
            ' ', '\n', '\r', '\t' => self.index += 1,
            else => return,
        };
    }

    fn failEnd(self: *JsonParser) !Value {
        try self.runtime.setFailureMessage("Unexpected end of JSON input");
        return error.InvalidJsonCloneValue;
    }

    fn failJsonMessage(self: *JsonParser, prefix: []const u8) !Value {
        return self.failJsonMessageAt(prefix, self.index);
    }

    fn failJsonMessageAt(self: *JsonParser, prefix: []const u8, position: usize) !Value {
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
            } else if (unit == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        const message = try std.fmt.allocPrint(
            self.runtime.allocator(),
            "{s} in JSON at position {d} (line {d} column {d})",
            .{ prefix, bounded, line, column },
        );
        defer self.runtime.allocator().free(message);
        try self.runtime.setFailureMessage(message);
        return error.InvalidJsonCloneValue;
    }

    fn failToken(self: *JsonParser, position: usize) !Value {
        if (position >= self.units.len) return self.failEnd();
        var message: std.ArrayList(u16) = .empty;
        errdefer message.deinit(self.runtime.allocator());
        try appendAscii(&message, self.runtime.allocator(), "Unexpected token '");
        try message.append(self.runtime.allocator(), self.units[position]);
        try appendAscii(&message, self.runtime.allocator(), "', ");
        try self.appendJsonErrorSourceUnits(&message, true, position);
        try appendAscii(&message, self.runtime.allocator(), " is not valid JSON");
        try self.runtime.setFailureMessageUnits(message.items);
        return error.InvalidJsonCloneValue;
    }

    fn failWholeSourceInvalid(self: *JsonParser) !Value {
        var message: std.ArrayList(u16) = .empty;
        errdefer message.deinit(self.runtime.allocator());
        try self.appendJsonErrorSourceUnits(&message, false, 0);
        try appendAscii(&message, self.runtime.allocator(), " is not valid JSON");
        try self.runtime.setFailureMessageUnits(message.items);
        return error.InvalidJsonCloneValue;
    }

    /// V8's invalid-token diagnostic shows at most ten UTF-16 code units on
    /// either side of the offending token.  The ellipses are outside the
    /// quoted source, and the source itself is deliberately not escaped:
    /// quotes, backslashes, and control units appear literally in Node 24's
    /// error message.  This is a diagnostic formatter, not JSON serialization.
    fn appendJsonErrorSourceUnits(self: *JsonParser, output: *std.ArrayList(u16), truncate: bool, position: usize) !void {
        const bounded = @min(position, self.units.len);
        const should_truncate = truncate and self.units.len > 20;
        const start = if (should_truncate and bounded > 10) bounded - 10 else 0;
        const end = if (should_truncate) @min(self.units.len, bounded + 10) else self.units.len;
        const leading_ellipsis = should_truncate and (start > 0 or bounded >= 10);
        if (leading_ellipsis) try appendAscii(output, self.runtime.allocator(), "...");
        try output.append(self.runtime.allocator(), '"');
        try output.appendSlice(self.runtime.allocator(), self.units[start..end]);
        try output.append(self.runtime.allocator(), '"');
        if (should_truncate and end < self.units.len) try appendAscii(output, self.runtime.allocator(), "...");
    }

    fn failTrailing(self: *JsonParser) !Value {
        var line: usize = 1;
        var column: usize = 1;
        const bounded = @min(self.index, self.units.len);
        var offset: usize = 0;
        while (offset < bounded) : (offset += 1) {
            const unit = self.units[offset];
            if (unit == '\r') {
                if (offset + 1 < bounded and self.units[offset + 1] == '\n') offset += 1;
                line += 1;
                column = 1;
            } else if (unit == '\n') {
                line += 1;
                column = 1;
            } else column += 1;
        }
        const message = try std.fmt.allocPrint(
            self.runtime.allocator(),
            "Unexpected non-whitespace character after JSON at position {d} (line {d} column {d})",
            .{ bounded, line, column },
        );
        defer self.runtime.allocator().free(message);
        try self.runtime.setFailureMessage(message);
        return error.InvalidJsonCloneValue;
    }
};

fn appendAscii(output: *std.ArrayList(u16), allocator: std.mem.Allocator, ascii: []const u8) !void {
    for (ascii) |byte| try output.append(allocator, byte);
}

fn jsonHexDigit(unit: u16) ?u16 {
    return if (unit >= '0' and unit <= '9') unit - '0' else if (unit >= 'a' and unit <= 'f') unit - 'a' + 10 else if (unit >= 'A' and unit <= 'F') unit - 'A' + 10 else null;
}

fn isJsonDigit(unit: u16) bool {
    return unit >= '0' and unit <= '9';
}

fn jsonAsciiEquals(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |unit, byte| if (unit != byte) return false;
    return true;
}

fn jsonParseDecimal(units: []const u16) f64 {
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

fn isCompactEncode(name: []const u8) bool {
    return eql(name, "JSON変換") or eql(name, "JSONエンコード") or eql(name, "JSON_E");
}

fn isPrettyEncode(name: []const u8) bool {
    return eql(name, "JSONエンコード整形") or eql(name, "JSON_ES");
}

fn isDecode(name: []const u8) bool {
    return eql(name, "JSON取得") or eql(name, "JSONデコード") or eql(name, "JSON_D");
}

fn eql(actual: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, actual, expected);
}

test "JSONのエンコードとデコードをJS互換規則で処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var dictionary = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "文字", try runtime.stringUtf8("A😀\n"));
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "非数", .{ .number = std.math.nan(f64) });
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "除外", .undefined);
    const encoded = (try call(&runtime, "JSON変換", &.{dictionary})).?;
    const encoded_utf8 = try encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(encoded_utf8);
    try std.testing.expectEqualStrings("{\"文字\":\"A😀\\n\",\"非数\":null}", encoded_utf8);
    var decoded = (try call(&runtime, "JSON取得", &.{encoded})).?;
    try roots.protect(&decoded);
    try std.testing.expect(decoded == .dictionary);
    try std.testing.expectEqual(@as(usize, 2), decoded.dictionary.len());
}

test "JSONの循環参照とBigIntを拒否する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const array = try runtime.createArray();
    _ = try array.array.push(array);
    try std.testing.expectError(error.CircularCloneValue, call(&runtime, "JSON変換", &.{array}));
    try std.testing.expectEqualStrings(
        "Converting circular structure to JSON\n    --> starting at object with constructor 'Array'\n    --- index 0 closes the circle",
        runtime.failureMessage().?,
    );
    runtime.clearFailureMessage();
    const bigint = try runtime.bigIntLiteral("1n");
    try std.testing.expectError(error.CannotSerializeBigInt, call(&runtime, "JSON変換", &.{bigint}));
}

test "JSONの辞書キーをECMAScriptの列挙順で整形する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var dictionary = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&dictionary);
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "2", try runtime.stringUtf8("b"));
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "1", try runtime.stringUtf8("a"));
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "x", try runtime.stringUtf8("c"));
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "01", try runtime.stringUtf8("d"));
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "4294967295", try runtime.stringUtf8("e"));
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "4294967294", try runtime.stringUtf8("f"));
    try common.dictionarySetUtf8(&runtime, dictionary.dictionary, "0", try runtime.stringUtf8("z"));
    const encoded = (try call(&runtime, "JSON変換", &.{dictionary})).?;
    const encoded_utf8 = try encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(encoded_utf8);
    try std.testing.expectEqualStrings(
        "{\"0\":\"z\",\"1\":\"a\",\"2\":\"b\",\"4294967294\":\"f\",\"x\":\"c\",\"01\":\"d\",\"4294967295\":\"e\"}",
        encoded_utf8,
    );
}

test "JSONのトップレベルundefinedと関数はundefinedを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const top_undefined = (try call(&runtime, "JSON変換", &.{.undefined})).?;
    try std.testing.expect(top_undefined == .undefined);

    const name = try runtime.stringUtf8("json-test-function");
    const function = try runtime.createNativeFunction(name.string, 0, jsonTestFunction, &.{});
    const top_function = (try call(&runtime, "JSON変換", &.{function})).?;
    try std.testing.expect(top_function == .undefined);

    const array = try runtime.createArray();
    _ = try array.array.push(.undefined);
    _ = try array.array.push(function);
    const encoded = (try call(&runtime, "JSON変換", &.{array})).?;
    const encoded_utf8 = try encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(encoded_utf8);
    try std.testing.expectEqualStrings("[null,null]", encoded_utf8);
}

test "JSONの実行時エラー文言を公式互換にする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const bigint = try runtime.bigIntLiteral("1n");
    try std.testing.expectError(error.CannotSerializeBigInt, call(&runtime, "JSON変換", &.{bigint}));
    try std.testing.expectEqualStrings("Do not know how to serialize a BigInt", @import("../../runtime/error_message.zig").forFailure(error.CannotSerializeBigInt));
    const invalid = try runtime.stringUtf8("x");
    try std.testing.expectError(error.InvalidJsonCloneValue, call(&runtime, "JSON取得", &.{invalid}));
    try std.testing.expectEqualStrings("Unexpected token 'x', \"x\" is not valid JSON", runtime.failureMessage().?);
    runtime.clearFailureMessage();
    const empty = try runtime.stringUtf8("");
    try std.testing.expectError(error.InvalidJsonCloneValue, call(&runtime, "JSON取得", &.{empty}));
    try std.testing.expectEqualStrings("Unexpected end of JSON input", runtime.failureMessage().?);
}

fn jsonTestFunction(_: *Runtime, _: []const Value) anyerror!Value {
    return .undefined;
}

test "JSONは重複キーの末尾値とPromiseの空オブジェクトを使う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var decoded = (try call(&runtime, "JSON取得", &.{try runtime.stringUtf8("{\"a\":1,\"a\":2}")})).?;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&decoded);
    const encoded = (try call(&runtime, "JSON変換", &.{decoded})).?;
    const encoded_utf8 = try encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(encoded_utf8);
    try std.testing.expectEqualStrings("{\"a\":2}", encoded_utf8);
    const promise = try runtime.createPromise();
    const promise_json = (try call(&runtime, "JSON変換", &.{promise})).?;
    const promise_utf8 = try promise_json.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(promise_utf8);
    try std.testing.expectEqualStrings("{}", promise_utf8);
}

test "BufferをNode互換のJSONオブジェクトへ変換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var buffer = try runtime.createBytes(&.{ 0x93, 0xfa, 0x41 });
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&buffer);
    const encoded = (try call(&runtime, "JSON変換", &.{buffer})).?;
    const utf8 = try encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("{\"type\":\"Buffer\",\"data\":[147,250,65]}", utf8);

    const pretty = (try call(&runtime, "JSONエンコード整形", &.{buffer})).?;
    const pretty_utf8 = try pretty.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(pretty_utf8);
    try std.testing.expectEqualStrings(
        "{\n  \"type\": \"Buffer\",\n  \"data\": [\n    147,\n    250,\n    65\n  ]\n}",
        pretty_utf8,
    );
}

test "Uint8ArrayをNode互換の添字JSONオブジェクトへ変換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var bytes = try runtime.createUint8Array(&.{ 9, 2 });
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&bytes);

    const encoded = (try call(&runtime, "JSON変換", &.{bytes})).?;
    const utf8 = try encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("{\"0\":9,\"1\":2}", utf8);

    const pretty = (try call(&runtime, "JSONエンコード整形", &.{bytes})).?;
    const pretty_utf8 = try pretty.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(pretty_utf8);
    try std.testing.expectEqualStrings("{\n  \"0\": 9,\n  \"1\": 2\n}", pretty_utf8);
}

test "JSONデコードはUTF-16サロゲート・空白・数値境界を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);

    var escaped = try runtime.stringCodeUnits(&.{ '"', '\\', 'u', 'd', '8', '0', '0', '"' });
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&escaped);
    var decoded = (try call(&runtime, "JSON取得", &.{escaped})).?;
    try roots.protect(&decoded);
    try std.testing.expectEqualSlices(u16, &.{0xd800}, decoded.string.units);

    var raw = try runtime.stringCodeUnits(&.{ '"', 0xdfff, '"' });
    try roots.protect(&raw);
    const raw_decoded = (try call(&runtime, "JSONデコード", &.{raw})).?;
    var raw_root = raw_decoded;
    try roots.protect(&raw_root);
    try std.testing.expectEqualSlices(u16, &.{0xdfff}, raw_decoded.string.units);

    var pair = try runtime.stringCodeUnits(&.{ '"', '\\', 'u', 'd', '8', '3', 'd', '\\', 'u', 'd', 'e', '0', '0', '"' });
    try roots.protect(&pair);
    const pair_decoded = (try call(&runtime, "JSON_D", &.{pair})).?;
    var pair_root = pair_decoded;
    try roots.protect(&pair_root);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, pair_decoded.string.units);

    var spaced = try runtime.stringUtf8(" \t\r\n [ -0,1e400,1e-4000,9007199254740993 ] ");
    try roots.protect(&spaced);
    const spaced_decoded = (try call(&runtime, "JSON取得", &.{spaced})).?;
    var spaced_root = spaced_decoded;
    try roots.protect(&spaced_root);
    const encoded = (try call(&runtime, "JSON変換", &.{spaced_decoded})).?;
    var encoded_root = encoded;
    try roots.protect(&encoded_root);
    const encoded_utf8 = try encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(encoded_utf8);
    try std.testing.expectEqualStrings("[0,null,0,9007199254740992]", encoded_utf8);

    var duplicate = try runtime.stringUtf8("{\"a\":1,\"a\":2}");
    try roots.protect(&duplicate);
    const duplicate_decoded = (try call(&runtime, "JSON取得", &.{duplicate})).?;
    var duplicate_root = duplicate_decoded;
    try roots.protect(&duplicate_root);
    const duplicate_encoded = (try call(&runtime, "JSON変換", &.{duplicate_decoded})).?;
    var duplicate_encoded_root = duplicate_encoded;
    try roots.protect(&duplicate_encoded_root);
    const duplicate_utf8 = try duplicate_encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(duplicate_utf8);
    try std.testing.expectEqualStrings("{\"a\":2}", duplicate_utf8);

    var nbsp = try runtime.stringCodeUnits(&.{ 0x00a0, '1' });
    try roots.protect(&nbsp);
    try std.testing.expectError(error.InvalidJsonCloneValue, call(&runtime, "JSON取得", &.{nbsp}));
    try std.testing.expectEqualStrings("Unexpected token ' ', \" 1\" is not valid JSON", runtime.failureMessage().?);
}

test "JSONデコードのNode 24エラー位置を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const Case = struct { source: []const u8, message: []const u8 };
    const cases = [_]Case{
        .{ .source = "[1", .message = "Expected ',' or ']' after array element in JSON at position 2 (line 1 column 3)" },
        .{ .source = "{", .message = "Expected property name or '}' in JSON at position 1 (line 1 column 2)" },
        .{ .source = "{\"a\":1,}", .message = "Expected double-quoted property name in JSON at position 7 (line 1 column 8)" },
        .{ .source = "{\"a\":1,", .message = "Expected double-quoted property name in JSON at position 7 (line 1 column 8)" },
        .{ .source = "true x", .message = "Unexpected non-whitespace character after JSON at position 5 (line 1 column 6)" },
        .{ .source = "\"\\u12\"", .message = "Bad Unicode escape in JSON at position 5 (line 1 column 6)" },
        .{ .source = "\"\\x00\"", .message = "Bad escaped character in JSON at position 2 (line 1 column 3)" },
        .{ .source = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaax", .message = "Unexpected token 'a', \"aaaaaaaaaa\"... is not valid JSON" },
        .{ .source = "          xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .message = "Unexpected token 'x', ...\"          xbbbbbbbbb\"... is not valid JSON" },
        .{ .source = "           xbbbbbbbb", .message = "Unexpected token 'x', \"           xbbbbbbbb\" is not valid JSON" },
        .{ .source = "          xbbbbbbbbbb", .message = "Unexpected token 'x', ...\"          xbbbbbbbbb\"... is not valid JSON" },
        .{ .source = "         xbbbbbbbbbbb", .message = "Unexpected token 'x', \"         xbbbbbbbbb\"... is not valid JSON" },
        .{ .source = "x\n", .message = "Unexpected token 'x', \"x\n\" is not valid JSON" },
        .{ .source = "x\"q", .message = "Unexpected token 'x', \"x\"q\" is not valid JSON" },
        .{ .source = "x\\q", .message = "Unexpected token 'x', \"x\\q\" is not valid JSON" },
        .{ .source = "😀", .message = "Unexpected token '�', \"😀\" is not valid JSON" },
    };
    for (cases) |case| {
        const source = try runtime.stringUtf8(case.source);
        try std.testing.expectError(error.InvalidJsonCloneValue, call(&runtime, "JSON取得", &.{source}));
        try std.testing.expectEqualStrings(case.message, runtime.failureMessage().?);
        runtime.clearFailureMessage();
    }
}

test "JSONエラー文言は孤立サロゲートをUTF-16で保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var source = try runtime.stringCodeUnits(&.{ 0xd83d, 0xde00 });
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    try std.testing.expectError(error.InvalidJsonCloneValue, call(&runtime, "JSON取得", &.{source}));

    var expected: std.ArrayList(u16) = .empty;
    defer expected.deinit(std.testing.allocator);
    try appendAscii(&expected, std.testing.allocator, "Unexpected token '");
    try expected.append(std.testing.allocator, 0xd83d);
    try appendAscii(&expected, std.testing.allocator, "', \"");
    try expected.appendSlice(std.testing.allocator, &.{ 0xd83d, 0xde00 });
    try appendAscii(&expected, std.testing.allocator, "\" is not valid JSON");

    var message = (try runtime.failureMessageValue()).?;
    try roots.protect(&message);
    try std.testing.expectEqualSlices(u16, expected.items, message.string.units);
}

test "JSONデコードは100000段のネストをCスタックなしで処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.next_collection = std.math.maxInt(usize);
    const depth: usize = 100_000;
    var source_units: std.ArrayList(u16) = .empty;
    defer source_units.deinit(std.testing.allocator);
    try source_units.ensureTotalCapacity(std.testing.allocator, depth * 2 + 1);
    for (0..depth) |_| try source_units.append(std.testing.allocator, '[');
    try source_units.append(std.testing.allocator, '0');
    for (0..depth) |_| try source_units.append(std.testing.allocator, ']');
    var source = try runtime.stringCodeUnits(source_units.items);
    var source_root = runtime.rootFrame();
    defer source_root.deinit();
    try source_root.protect(&source);
    var decoded = (try call(&runtime, "JSON取得", &.{source})).?;
    var decoded_root = runtime.rootFrame();
    defer decoded_root.deinit();
    try decoded_root.protect(&decoded);
    var value = decoded;
    for (0..depth) |_| {
        try std.testing.expect(value == .array);
        try std.testing.expectEqual(@as(usize, 1), value.array.items.items.len);
        value = value.array.items.items[0];
    }
    try std.testing.expectEqual(@as(f64, 0), value.number);
}

fn jsonDecodeAllocationTest(allocator: std.mem.Allocator) !void {
    var runtime = Runtime.init(allocator);
    defer runtime.deinit();
    var source = try runtime.stringUtf8("{\"a\":[1,2,3],\"b\":{\"c\":4}}");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    const decoded = try call(&runtime, "JSON取得", &.{source});
    _ = decoded;
}

test "JSONデコードは割当失敗を握り潰さない" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, jsonDecodeAllocationTest, .{});
}
