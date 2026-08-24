const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const common = @import("common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

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
    var active_arrays: std.ArrayList(*value_mod.Array) = .empty;
    defer active_arrays.deinit(runtime.allocator());
    var active_dictionaries: std.ArrayList(*value_mod.Dictionary) = .empty;
    defer active_dictionaries.deinit(runtime.allocator());
    try writeValue(runtime, &output.writer, value, pretty, 0, &active_arrays, &active_dictionaries, false);
    return runtime.stringUtf8(output.written());
}

fn writeValue(
    runtime: *Runtime,
    writer: *std.Io.Writer,
    value: Value,
    pretty: bool,
    depth: usize,
    active_arrays: *std.ArrayList(*value_mod.Array),
    active_dictionaries: *std.ArrayList(*value_mod.Dictionary),
    in_array: bool,
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
        .bigint => return error.BigIntCannotBeSerialized,
        .string => |string| try writeQuotedString(writer, string.units),
        .bytes => |buffer| {
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
            if (containsPointer(value_mod.Array, active_arrays.items, array)) return error.CircularJsonValue;
            try active_arrays.append(runtime.allocator(), array);
            defer _ = active_arrays.pop();
            try writer.writeByte('[');
            for (array.items.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, depth + 1);
                }
                try writeValue(runtime, writer, item, pretty, depth + 1, active_arrays, active_dictionaries, true);
            }
            if (pretty and array.items.items.len > 0) {
                try writer.writeByte('\n');
                try writeIndent(writer, depth);
            }
            try writer.writeByte(']');
        },
        .dictionary => |dictionary| {
            if (containsPointer(value_mod.Dictionary, active_dictionaries.items, dictionary)) return error.CircularJsonValue;
            try active_dictionaries.append(runtime.allocator(), dictionary);
            defer _ = active_dictionaries.pop();
            try writer.writeByte('{');
            var emitted: usize = 0;
            for (dictionary.keys(), dictionary.values()) |key, item| {
                if (item == .undefined or item == .function) continue;
                if (emitted > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, depth + 1);
                }
                try writeQuotedString(writer, key.units);
                try writer.writeAll(if (pretty) ": " else ":");
                try writeValue(runtime, writer, item, pretty, depth + 1, active_arrays, active_dictionaries, false);
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
    const utf8 = try text_value.string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(utf8);
    const parsed = try std.json.parseFromSlice(std.json.Value, runtime.allocator(), utf8, .{ .duplicate_field_behavior = .use_last });
    defer parsed.deinit();
    return fromJson(runtime, parsed.value);
}

fn fromJson(runtime: *Runtime, source: std.json.Value) !Value {
    return switch (source) {
        .null => .null_value,
        .bool => |boolean| .{ .boolean = boolean },
        .integer => |integer| .{ .number = @floatFromInt(integer) },
        .float => |float| .{ .number = float },
        .number_string => |number| .{ .number = try std.fmt.parseFloat(f64, number) },
        .string => |string| runtime.stringUtf8(string),
        .array => |array| blk: {
            var result = try runtime.createArray();
            var roots = runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&result);
            for (array.items) |item| {
                var converted = try fromJson(runtime, item);
                var item_roots = runtime.rootFrame();
                defer item_roots.deinit();
                try item_roots.protect(&converted);
                _ = try result.array.push(converted);
            }
            break :blk result;
        },
        .object => |object| blk: {
            var result = try runtime.createDictionary();
            var roots = runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&result);
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                var converted = try fromJson(runtime, entry.value_ptr.*);
                var item_roots = runtime.rootFrame();
                defer item_roots.deinit();
                try item_roots.protect(&converted);
                var key = try runtime.stringUtf8(entry.key_ptr.*);
                try item_roots.protect(&key);
                try result.dictionary.set(key.string, converted);
            }
            break :blk result;
        },
    };
}

fn containsPointer(comptime T: type, values: []const *T, needle: *T) bool {
    for (values) |value| if (value == needle) return true;
    return false;
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
    try std.testing.expectError(error.CircularJsonValue, call(&runtime, "JSON変換", &.{array}));
    const bigint = try runtime.bigIntLiteral("1n");
    try std.testing.expectError(error.BigIntCannotBeSerialized, call(&runtime, "JSON変換", &.{bigint}));
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
