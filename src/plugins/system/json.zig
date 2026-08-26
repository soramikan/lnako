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
    try writeValue(runtime, &output.writer, value, pretty, 0, &active_arrays, &active_dictionaries, false, null);
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
            if (containsPointer(value_mod.Array, active_arrays.items, array)) {
                try setCircularFailureMessage(runtime, .array, path);
                return error.CircularCloneValue;
            }
            try active_arrays.append(runtime.allocator(), array);
            defer _ = active_arrays.pop();
            try writer.writeByte('[');
            for (array.items.items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                if (pretty) {
                    try writer.writeByte('\n');
                    try writeIndent(writer, depth + 1);
                }
                try writeValue(runtime, writer, item, pretty, depth + 1, active_arrays, active_dictionaries, true, .{ .array_index = index });
            }
            if (pretty and array.items.items.len > 0) {
                try writer.writeByte('\n');
                try writeIndent(writer, depth);
            }
            try writer.writeByte(']');
        },
        .dictionary => |dictionary| {
            if (dictionary.kind == .http_response) return writer.writeAll("{}");
            if (containsPointer(value_mod.Dictionary, active_dictionaries.items, dictionary)) {
                try setCircularFailureMessage(runtime, .dictionary, path);
                return error.CircularCloneValue;
            }
            try active_dictionaries.append(runtime.allocator(), dictionary);
            defer _ = active_dictionaries.pop();

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
                try writeValue(runtime, writer, entry.value, pretty, depth + 1, active_arrays, active_dictionaries, false, .{ .property = entry.key });
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

fn setCircularFailureMessage(runtime: *Runtime, constructor: enum { array, dictionary }, path: ?JsonPath) !void {
    var output: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer output.deinit();
    try output.writer.writeAll("Converting circular structure to JSON");
    try output.writer.writeByte('\n');
    try output.writer.writeAll("    --> starting at object with constructor '");
    try output.writer.writeAll(if (constructor == .array) "Array" else "Object");
    try output.writer.writeAll("'\n    --- ");
    if (path) |cycle_path| switch (cycle_path) {
        .array_index => |index| try output.writer.print("index {d} closes the circle", .{index}),
        .property => |key| {
            const key_utf8 = try key.toUtf8Lossy(runtime.allocator());
            defer runtime.allocator().free(key_utf8);
            try output.writer.print("property '{s}' closes the circle", .{key_utf8});
        },
    } else try output.writer.writeAll("cycle closes the circle");
    try runtime.setFailureMessage(output.written());
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
    const utf8 = try text_value.string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(utf8);
    const parsed = std.json.parseFromSlice(std.json.Value, runtime.allocator(), utf8, .{ .duplicate_field_behavior = .use_last }) catch |failure| {
        const message = try jsonParseFailureMessage(runtime.allocator(), utf8, failure);
        defer runtime.allocator().free(message);
        try runtime.setFailureMessage(message);
        return error.InvalidJsonCloneValue;
    };
    defer parsed.deinit();
    return fromJson(runtime, parsed.value);
}

fn jsonParseFailureMessage(allocator: std.mem.Allocator, source: []const u8, failure: anyerror) ![]u8 {
    if (failure == error.UnexpectedEndOfInput) return allocator.dupe(u8, "Unexpected end of JSON input");

    const token = firstNonWhitespace(source) orelse return allocator.dupe(u8, "Unexpected end of JSON input");
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(allocator);
    for (source) |byte| switch (byte) {
        '\\' => try escaped.appendSlice(allocator, "\\\\"),
        '"' => try escaped.appendSlice(allocator, "\\\""),
        '\n' => try escaped.appendSlice(allocator, "\\n"),
        '\r' => try escaped.appendSlice(allocator, "\\r"),
        '\t' => try escaped.appendSlice(allocator, "\\t"),
        0...0x08, 0x0b, 0x0e...0x1f => {
            const digits = "0123456789abcdef";
            try escaped.appendSlice(allocator, "\\u00");
            try escaped.append(allocator, digits[(byte >> 4) & 0xf]);
            try escaped.append(allocator, digits[byte & 0xf]);
        },
        else => try escaped.append(allocator, byte),
    };
    return std.fmt.allocPrint(allocator, "Unexpected token '{c}', \"{s}\" is not valid JSON", .{ token, escaped.items });
}

fn firstNonWhitespace(source: []const u8) ?u8 {
    for (source) |byte| switch (byte) {
        ' ', '\n', '\r', '\t' => {},
        else => return byte,
    };
    return null;
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
