const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const string_mod = shared.string_mod;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const numberValue = aot_state.numberValue;
const valueToNumber = aot_state.valueToNumber;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const runtimeUtf8String = aot_state.runtimeUtf8String;
const runtimeUtf8StringLossy = aot_state.runtimeUtf8StringLossy;
const isString = aot_state.isString;

pub fn urlBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    return switch (command) {
        .url_encode => urlEncodeBuiltin(runtime, arguments[0]),
        .url_decode => urlDecodeBuiltin(runtime, arguments[0]),
        .url_parameters => urlParametersBuiltin(runtime, arguments[0]),
        .base64_encode => base64EncodeBuiltin(runtime, arguments[0]),
        .base64_decode => base64DecodeBuiltin(runtime, arguments[0]),
        else => error.UnknownCommand,
    };
}

pub fn pathBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const required: usize = if (command == .path_change_extension) 2 else 1;
    if (arguments.len < required) return error.InvalidArgumentCount;
    return switch (command) {
        .path_extract_extension => pathExtractExtensionBuiltin(runtime, arguments[0]),
        .path_change_extension => pathChangeExtensionBuiltin(runtime, arguments[0], arguments[1]),
        .path_add_trailing_separator => pathAddTrailingSeparatorBuiltin(runtime, arguments[0]),
        .path_remove_trailing_separator => pathRemoveTrailingSeparatorBuiltin(runtime, arguments[0]),
        .path_delete_trailing_separator => pathRemoveTrailingSeparatorBuiltin(runtime, arguments[0]),
        else => error.UnknownCommand,
    };
}

pub fn pathExtractExtensionBuiltin(runtime: *Runtime, source: Value) !Value {
    const source_tag: Tag = @enumFromInt(source.tag);
    if (source_tag == .undefined or source_tag == .null_value) return runtimeUtf8String(runtime, "");
    if (!isString(source)) return error.InvalidPathSource;
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    const filename = pathBasenameUnits(units, pathSeparatorUnit());
    const dot = std.mem.lastIndexOfScalar(u16, filename, '.') orelse return runtimeUtf8String(runtime, "");
    if (dot + 1 == filename.len or !pathAllExtensionUnits(filename[dot + 1 ..])) return runtimeUtf8String(runtime, "");
    return runtime.createString(filename[dot..]);
}

pub fn pathChangeExtensionBuiltin(runtime: *Runtime, source: Value, extension: Value) !Value {
    const source_tag: Tag = @enumFromInt(source.tag);
    if (source_tag == .undefined or source_tag == .null_value) return extension;
    if (!isString(source)) return error.InvalidPathSource;
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    if (extension.tag == @intFromEnum(Tag.undefined) or extension.tag == @intFromEnum(Tag.null_value)) {
        return pathChangeExtensionUnits(runtime, source_units, &.{});
    }
    if (!isString(extension)) return error.InvalidPathSource;
    const extension_units = try valueUtf16Alloc(runtime, extension);
    defer runtime.allocator.free(extension_units);
    return pathChangeExtensionUnits(runtime, source_units, extension_units);
}

pub fn pathChangeExtensionUnits(runtime: *Runtime, source: []const u16, extension: []const u16) !Value {
    const raw_extension = string_mod.trimWhitespace(extension);
    const separator = pathSeparatorUnit();
    const last_separator = std.mem.lastIndexOfScalar(u16, source, separator);
    const filename_start = if (last_separator) |index| index + 1 else 0;
    const filename = source[filename_start..];
    var filename_end = filename.len;
    if (std.mem.lastIndexOfScalar(u16, filename, '.')) |dot| {
        if (dot + 1 < filename.len and pathAllExtensionUnits(filename[dot + 1 ..])) filename_end = dot;
    }

    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator);
    if (filename_start > 0) try output.appendSlice(runtime.allocator, source[0..filename_start]);
    try output.appendSlice(runtime.allocator, filename[0..filename_end]);
    if (raw_extension.len > 0) {
        if (raw_extension[0] != '.') try output.append(runtime.allocator, '.');
        try output.appendSlice(runtime.allocator, raw_extension);
    }
    return runtime.createString(output.items);
}

pub fn pathAddTrailingSeparatorBuiltin(runtime: *Runtime, source: Value) !Value {
    const source_tag: Tag = @enumFromInt(source.tag);
    if (source_tag == .undefined or source_tag == .null_value) return runtimeUtf8String(runtime, "");
    if (!isString(source)) return error.InvalidPathSource;
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    if (units.len == 0 or units[units.len - 1] == pathSeparatorUnit()) return source;
    var output = try runtime.allocator.alloc(u16, units.len + 1);
    defer runtime.allocator.free(output);
    @memcpy(output[0..units.len], units);
    output[output.len - 1] = pathSeparatorUnit();
    return runtime.createString(output);
}

pub fn pathRemoveTrailingSeparatorBuiltin(runtime: *Runtime, source: Value) !Value {
    const source_tag: Tag = @enumFromInt(source.tag);
    if (source_tag == .undefined or source_tag == .null_value or
        source_tag == .boolean and source.payload == 0 or
        source_tag == .number and (@as(f64, @bitCast(source.payload)) == 0 or std.math.isNan(@as(f64, @bitCast(source.payload)))))
    {
        return runtimeUtf8String(runtime, "");
    }
    if (!isString(source)) return error.InvalidPathSource;
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    if (units.len == 0 or units[units.len - 1] != pathSeparatorUnit()) return source;
    return runtime.createString(units[0 .. units.len - 1]);
}

pub fn pathSeparatorUnit() u16 {
    return if (std.fs.path.sep_str.len > 0) std.fs.path.sep_str[0] else '/';
}

pub fn pathBasenameUnits(path: []const u16, separator: u16) []const u16 {
    const index = std.mem.lastIndexOfScalar(u16, path, separator) orelse return path;
    return path[index + 1 ..];
}

pub fn pathAllExtensionUnits(units: []const u16) bool {
    for (units) |unit| switch (unit) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '+' => {},
        else => return false,
    };
    return true;
}
pub fn urlEncodeBuiltin(runtime: *Runtime, source: Value) !Value {
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);

    var index: usize = 0;
    while (index < units.len) {
        const first = units[index];
        const codepoint: u21 = switch (first) {
            0xd800...0xdbff => blk: {
                if (index + 1 >= units.len) return error.MalformedUriSequence;
                const second = units[index + 1];
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
            if (urlIsComponentByte(byte)) {
                try output.append(runtime.allocator, byte);
            } else {
                try output.appendSlice(runtime.allocator, &.{ '%', urlHexDigit(byte >> 4), urlHexDigit(byte & 0xf) });
            }
        }
        index += 1;
    }
    return runtimeUtf8String(runtime, output.items);
}

pub fn urlDecodeBuiltin(runtime: *Runtime, source: Value) !Value {
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    return urlDecodeUnits(runtime, units);
}

pub fn urlDecodeUnits(runtime: *Runtime, units: []const u16) !Value {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        if (unit == '%') {
            if (index + 2 >= units.len) return error.MalformedUriSequence;
            const high = urlHexValue(units[index + 1]) orelse return error.MalformedUriSequence;
            const low = urlHexValue(units[index + 2]) orelse return error.MalformedUriSequence;
            try output.append(runtime.allocator, high << 4 | low);
            index += 3;
            continue;
        }
        if (unit > 0x7f) {
            var codepoint: u21 = undefined;
            if (unit >= 0xd800 and unit <= 0xdbff) {
                if (index + 1 >= units.len or units[index + 1] < 0xdc00 or units[index + 1] > 0xdfff) return error.MalformedUriSequence;
                const second = units[index + 1];
                codepoint = @intCast(0x10000 + ((@as(u32, unit) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
                index += 2;
            } else if (unit >= 0xdc00 and unit <= 0xdfff) {
                return error.MalformedUriSequence;
            } else {
                codepoint = @intCast(unit);
                index += 1;
            }
            var encoded: [4]u8 = undefined;
            const length = try std.unicode.utf8Encode(codepoint, &encoded);
            try output.appendSlice(runtime.allocator, encoded[0..length]);
            continue;
        }
        try output.append(runtime.allocator, @intCast(unit));
        index += 1;
    }
    if (!std.unicode.utf8ValidateSlice(output.items)) return error.MalformedUriSequence;
    return runtimeUtf8String(runtime, output.items);
}

pub fn urlParametersBuiltin(runtime: *Runtime, source: Value) !Value {
    var protected = [_]Value{ source, try runtime.createDictionary(&.{}) };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &protected, protected.len);
    defer runtime.popRoots(&frame);
    if (!isString(protected[0])) return protected[1];
    const units = try valueUtf16Alloc(runtime, protected[0]);
    defer runtime.allocator.free(units);
    const question = std.mem.indexOfScalar(u16, units, '?') orelse return protected[1];
    var cursor = question + 1;
    while (cursor <= units.len) {
        const ampersand = std.mem.indexOfScalarPos(u16, units, cursor, '&') orelse units.len;
        const line = units[cursor..ampersand];
        if (line.len > 0) {
            const equal = std.mem.indexOfScalar(u16, line, '=');
            const raw_key = if (equal) |position| line[0..position] else line;
            const raw_value = if (equal) |position| line[position + 1 ..] else &.{};
            var entry = [_]Value{ .{}, .{} };
            var entry_frame = RootFrame{};
            runtime.pushRoots(&entry_frame, &entry, entry.len);
            defer runtime.popRoots(&entry_frame);
            entry[0] = try urlDecodeUnits(runtime, raw_key);
            entry[1] = try urlDecodeUnits(runtime, raw_value);
            try runtime.setDictionary(&protected[1].object().?.payload.dictionary, entry[0], entry[1]);
        }
        if (ampersand == units.len) break;
        cursor = ampersand + 1;
    }
    return protected[1];
}

pub fn base64EncodeBuiltin(runtime: *Runtime, source: Value) !Value {
    var bytes: []u8 = undefined;
    var owned = false;
    switch (@as(Tag, @enumFromInt(source.tag))) {
        .static_utf8_string, .utf16_string => {
            const units = try valueUtf16Alloc(runtime, source);
            defer runtime.allocator.free(units);
            bytes = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
            owned = true;
        },
        .byte_buffer => bytes = source.object().?.payload.byte_buffer.bytes,
        .array => {
            const items = source.object().?.payload.array.items;
            bytes = try runtime.allocator.alloc(u8, items.len);
            owned = true;
            for (items, bytes) |item, *byte| {
                const number = try valueToNumberRuntime(runtime, item);
                if (!std.math.isFinite(number) or number == 0) {
                    byte.* = 0;
                } else {
                    const remainder = @mod(@trunc(number), @as(f64, 256));
                    byte.* = @intFromFloat(if (remainder < 0) remainder + 256 else remainder);
                }
            }
        },
        else => return error.InvalidBase64Source,
    }
    defer if (owned) runtime.allocator.free(bytes);
    const encoded = try runtime.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    defer runtime.allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return runtimeUtf8String(runtime, encoded);
}

pub fn base64DecodeBuiltin(runtime: *Runtime, source: Value) !Value {
    if (!isString(source)) return error.InvalidBase64Source;
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(runtime.allocator);
    var group: [4]u8 = undefined;
    var length: usize = 0;
    for (units) |unit| {
        if (unit == '=') break;
        const value = base64Digit(unit) orelse continue;
        group[length] = value;
        length += 1;
        if (length == 4) {
            try decoded.appendSlice(runtime.allocator, &.{
                group[0] << 2 | group[1] >> 4,
                group[1] << 4 | group[2] >> 2,
                group[2] << 6 | group[3],
            });
            length = 0;
        }
    }
    if (length >= 2) try decoded.append(runtime.allocator, group[0] << 2 | group[1] >> 4);
    if (length >= 3) try decoded.append(runtime.allocator, group[1] << 4 | group[2] >> 2);
    return runtimeUtf8StringLossy(runtime, decoded.items);
}

pub fn urlIsComponentByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '-', '_', '.', '!', '~', '*', '\'', '(', ')' => true,
        else => false,
    };
}

pub fn urlHexDigit(value: u8) u8 {
    return if (value < 10) '0' + value else 'A' + value - 10;
}

pub fn urlHexValue(unit: u16) ?u8 {
    if (unit >= '0' and unit <= '9') return @intCast(unit - '0');
    if (unit >= 'a' and unit <= 'f') return @intCast(unit - 'a' + 10);
    if (unit >= 'A' and unit <= 'F') return @intCast(unit - 'A' + 10);
    return null;
}

pub fn base64Digit(unit: u16) ?u8 {
    return switch (unit) {
        'A'...'Z' => @intCast(unit - 'A'),
        'a'...'z' => @intCast(unit - 'a' + 26),
        '0'...'9' => @intCast(unit - '0' + 52),
        '+', '-' => 62,
        '/', '_' => 63,
        else => null,
    };
}
