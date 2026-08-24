const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const common = @import("common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const source = common.argument(arguments, 0);
    if (eql(name, "URLエンコード")) return try encode(runtime, source);
    if (eql(name, "URLデコード")) return try decode(runtime, source);
    if (eql(name, "URLパラメータ解析")) return try parseParameters(runtime, source);
    return null;
}

fn encode(runtime: *Runtime, source: Value) !Value {
    const text = try runtime.valueToString(source);
    var output: std.Io.Writer.Allocating = .init(runtime.allocator());
    defer output.deinit();
    var index: usize = 0;
    while (index < text.string.units.len) {
        const first = text.string.units[index];
        const codepoint: u21 = switch (first) {
            0xd800...0xdbff => blk: {
                if (index + 1 >= text.string.units.len) return error.MalformedUriSequence;
                const second = text.string.units[index + 1];
                if (second < 0xdc00 or second > 0xdfff) return error.MalformedUriSequence;
                index += 1;
                break :blk @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
            },
            0xdc00...0xdfff => return error.MalformedUriSequence,
            else => @intCast(first),
        };
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(codepoint, &encoded);
        for (encoded[0..length]) |byte| {
            if (isUriComponentByte(byte)) {
                try output.writer.writeByte(byte);
            } else {
                try output.writer.writeByte('%');
                try output.writer.writeByte(hexDigit(byte >> 4));
                try output.writer.writeByte(hexDigit(byte & 0xf));
            }
        }
        index += 1;
    }
    return runtime.stringUtf8(output.written());
}

fn decode(runtime: *Runtime, source: Value) !Value {
    const text = try runtime.valueToString(source);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator());
    var index: usize = 0;
    while (index < text.string.units.len) {
        const unit = text.string.units[index];
        if (unit == '%') {
            if (index + 2 >= text.string.units.len) return error.MalformedUriSequence;
            const high = hexValue(text.string.units[index + 1]) orelse return error.MalformedUriSequence;
            const low = hexValue(text.string.units[index + 2]) orelse return error.MalformedUriSequence;
            try output.append(runtime.allocator(), high << 4 | low);
            index += 3;
            continue;
        }
        if (unit > 0x7f) {
            const start = index;
            if (unit >= 0xd800 and unit <= 0xdbff) {
                if (index + 1 >= text.string.units.len or text.string.units[index + 1] < 0xdc00 or text.string.units[index + 1] > 0xdfff) return error.MalformedUriSequence;
                index += 2;
            } else if (unit >= 0xdc00 and unit <= 0xdfff) return error.MalformedUriSequence else index += 1;
            const piece = try runtime.stringCodeUnits(text.string.units[start..index]);
            const utf8 = try piece.string.toUtf8Lossy(runtime.allocator());
            defer runtime.allocator().free(utf8);
            try output.appendSlice(runtime.allocator(), utf8);
            continue;
        }
        try output.append(runtime.allocator(), @intCast(unit));
        index += 1;
    }
    if (!std.unicode.utf8ValidateSlice(output.items)) return error.MalformedUriSequence;
    return runtime.stringUtf8(output.items);
}

fn parseParameters(runtime: *Runtime, source: Value) !Value {
    var rooted_source = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    var result = try runtime.createDictionary();
    try roots.protect(&result);
    if (rooted_source != .string) return result;
    const units = rooted_source.string.units;
    const question = std.mem.indexOfScalar(u16, units, '?') orelse return result;
    var cursor = question + 1;
    while (cursor <= units.len) {
        var iteration_roots = runtime.rootFrame();
        defer iteration_roots.deinit();
        const ampersand = std.mem.indexOfScalarPos(u16, units, cursor, '&') orelse units.len;
        const line = units[cursor..ampersand];
        if (line.len > 0) {
            const equal = std.mem.indexOfScalar(u16, line, '=');
            const raw_key = if (equal) |position| line[0..position] else line;
            const raw_value = if (equal) |position| line[position + 1 ..] else &.{};
            var key_source = try runtime.stringCodeUnits(raw_key);
            try iteration_roots.protect(&key_source);
            var value_source = try runtime.stringCodeUnits(raw_value);
            try iteration_roots.protect(&value_source);
            var key = try decode(runtime, key_source);
            try iteration_roots.protect(&key);
            var value = try decode(runtime, value_source);
            try iteration_roots.protect(&value);
            try result.dictionary.set(key.string, value);
        }
        if (ampersand == units.len) break;
        cursor = ampersand + 1;
    }
    return result;
}

fn isUriComponentByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
        else => false,
    };
}

fn hexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + value - 10;
}

fn hexValue(unit: u16) ?u8 {
    if (unit >= '0' and unit <= '9') return @intCast(unit - '0');
    if (unit >= 'a' and unit <= 'f') return @intCast(unit - 'a' + 10);
    if (unit >= 'A' and unit <= 'F') return @intCast(unit - 'A' + 10);
    return null;
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "URLエンコード・デコードと重複パラメータの末尾優先を再現する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var encoded = (try call(&runtime, "URLエンコード", &.{try runtime.stringUtf8("A あ/😀")})).?;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&encoded);
    const encoded_utf8 = try encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(encoded_utf8);
    try std.testing.expectEqualStrings("A%20%E3%81%82%2F%F0%9F%98%80", encoded_utf8);
    const decoded = (try call(&runtime, "URLデコード", &.{encoded})).?;
    const decoded_utf8 = try decoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(decoded_utf8);
    try std.testing.expectEqualStrings("A あ/😀", decoded_utf8);
    var parameters = (try call(&runtime, "URLパラメータ解析", &.{try runtime.stringUtf8("/?a=1&a=2&flag")})).?;
    try roots.protect(&parameters);
    const key = try runtime.stringUtf8("a");
    try std.testing.expect(value_mod.String.eql(parameters.dictionary.get(key.string).?.string.*, (try runtime.stringUtf8("2")).string.*));
}
