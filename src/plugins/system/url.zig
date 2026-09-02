const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const common = @import("common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    return callWithSeparator(runtime, name, arguments, std.fs.path.sep_str);
}

pub fn callWithSeparator(runtime: *Runtime, name: []const u8, arguments: []const Value, path_separator: []const u8) !?Value {
    if (eql(name, "ファイル名抽出")) return try extractPathComponent(runtime, arguments, path_separator, false);
    if (eql(name, "パス抽出")) return try extractPathComponent(runtime, arguments, path_separator, true);
    const source = common.argument(arguments, 0);
    if (eql(name, "URLエンコード")) return try encode(runtime, source);
    if (eql(name, "URLデコード")) return try decode(runtime, source);
    if (eql(name, "URLパラメータ解析")) return try parseParameters(runtime, source);
    if (eql(name, "BASE64エンコード")) return try encodeBase64(runtime, source);
    if (eql(name, "BASE64デコード")) return try decodeBase64(runtime, source);
    if (eql(name, "拡張子抽出")) return try extractExtension(runtime, source, path_separator);
    if (eql(name, "拡張子変更")) return try changeExtension(runtime, source, common.argument(arguments, 1), path_separator);
    if (eql(name, "終端パス追加")) return try addTrailingSeparator(runtime, source, path_separator);
    if (eql(name, "終端パス除去") or eql(name, "終端パス削除")) return try removeTrailingSeparator(runtime, source, path_separator);
    return null;
}

fn encodeBase64(runtime: *Runtime, source: Value) !Value {
    var bytes: []u8 = undefined;
    var owned = false;
    switch (source) {
        .string => {
            bytes = try source.string.toUtf8Lossy(runtime.allocator());
            owned = true;
        },
        .bytes => bytes = source.bytes.bytes,
        .array => {
            bytes = try runtime.allocator().alloc(u8, source.array.items.items.len);
            owned = true;
            for (source.array.items.items, bytes) |item, *byte| {
                const number = try runtime.valueToNumber(item);
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
    defer if (owned) runtime.allocator().free(bytes);
    const encoded = try runtime.allocator().alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    defer runtime.allocator().free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return runtime.stringUtf8(encoded);
}

fn decodeBase64(runtime: *Runtime, source: Value) !Value {
    if (source != .string) return error.InvalidBase64Source;
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(runtime.allocator());
    var group: [4]u8 = undefined;
    var length: usize = 0;
    for (source.string.units) |unit| {
        if (unit == '=') break;
        const value = base64Digit(unit) orelse continue;
        group[length] = value;
        length += 1;
        if (length == 4) {
            try decoded.appendSlice(runtime.allocator(), &.{
                group[0] << 2 | group[1] >> 4,
                group[1] << 4 | group[2] >> 2,
                group[2] << 6 | group[3],
            });
            length = 0;
        }
    }
    if (length >= 2) try decoded.append(runtime.allocator(), group[0] << 2 | group[1] >> 4);
    if (length >= 3) try decoded.append(runtime.allocator(), group[1] << 4 | group[2] >> 2);
    return runtime.stringUtf8Lossy(decoded.items);
}

fn extractExtension(runtime: *Runtime, source: Value, path_separator: []const u8) !Value {
    var rooted_source = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    if (rooted_source == .null_value or rooted_source == .undefined) return runtime.stringUtf8("");
    if (rooted_source != .string) return error.InvalidPathSource;
    const separator = separatorUnit(path_separator);
    const filename = basenameUnits(rooted_source.string.units, separator);
    const dot = std.mem.lastIndexOfScalar(u16, filename, '.') orelse return runtime.stringUtf8("");
    if (dot + 1 == filename.len or !allExtensionUnits(filename[dot + 1 ..])) return runtime.stringUtf8("");
    return runtime.stringCodeUnits(filename[dot..]);
}

fn changeExtension(runtime: *Runtime, source: Value, extension: Value, path_separator: []const u8) !Value {
    var rooted_source = source;
    var rooted_extension = extension;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    try roots.protect(&rooted_extension);
    if (rooted_source == .null_value or rooted_source == .undefined) return rooted_extension;
    if (rooted_source != .string) return error.InvalidPathSource;
    const raw_extension = if (rooted_extension == .null_value or rooted_extension == .undefined)
        &.{}
    else if (rooted_extension == .string)
        common.trimEcma(rooted_extension.string.units)
    else
        return error.InvalidPathSource;
    const separator = separatorUnit(path_separator);
    const last_separator = std.mem.lastIndexOfScalar(u16, rooted_source.string.units, separator);
    const filename_start = if (last_separator) |index| index + 1 else 0;
    const filename = rooted_source.string.units[filename_start..];
    var filename_end = filename.len;
    if (std.mem.lastIndexOfScalar(u16, filename, '.')) |dot| {
        if (dot + 1 < filename.len and allExtensionUnits(filename[dot + 1 ..])) filename_end = dot;
    }
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    if (filename_start > 0) try output.appendSlice(runtime.allocator(), rooted_source.string.units[0..filename_start]);
    try output.appendSlice(runtime.allocator(), filename[0..filename_end]);
    if (raw_extension.len > 0) {
        if (raw_extension[0] != '.') try output.append(runtime.allocator(), '.');
        try output.appendSlice(runtime.allocator(), raw_extension);
    }
    return runtime.stringCodeUnits(output.items);
}

fn addTrailingSeparator(runtime: *Runtime, source: Value, path_separator: []const u8) !Value {
    var text = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&text);
    if (text == .null_value or text == .undefined) return runtime.stringUtf8("");
    if (text != .string) return error.InvalidPathSource;
    if (text.string.units.len == 0 or text.string.units[text.string.units.len - 1] == separatorUnit(path_separator)) return text;
    var output = try runtime.allocator().alloc(u16, text.string.units.len + 1);
    defer runtime.allocator().free(output);
    @memcpy(output[0..text.string.units.len], text.string.units);
    output[output.len - 1] = separatorUnit(path_separator);
    return runtime.stringCodeUnits(output);
}

fn removeTrailingSeparator(runtime: *Runtime, source: Value, path_separator: []const u8) !Value {
    var text = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&text);
    if (text == .null_value or text == .undefined or text == .boolean and !text.boolean or text == .number and (text.number == 0 or std.math.isNan(text.number))) return runtime.stringUtf8("");
    if (text != .string) return error.InvalidPathSource;
    const units = text.string.units;
    if (units.len == 0) return text;
    return runtime.stringCodeUnits(if (units[units.len - 1] == separatorUnit(path_separator)) units[0 .. units.len - 1] else units);
}

fn extractPathComponent(runtime: *Runtime, arguments: []const Value, path_separator: []const u8, dirname: bool) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const source = arguments[0];
    if (source != .string) return error.InvalidPathSource;
    const separator = separatorUnit(path_separator);
    const component = if (dirname) dirnameUnits(source.string.units, separator) else basenameUnits(source.string.units, separator);
    return runtime.stringCodeUnits(component);
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

fn base64Digit(unit: u16) ?u8 {
    return switch (unit) {
        'A'...'Z' => @intCast(unit - 'A'),
        'a'...'z' => @intCast(unit - 'a' + 26),
        '0'...'9' => @intCast(unit - '0' + 52),
        '+', '-' => 62,
        '/', '_' => 63,
        else => null,
    };
}

fn separatorUnit(separator: []const u8) u16 {
    return if (separator.len > 0) separator[0] else '/';
}

fn basenameUnits(path: []const u16, separator: u16) []const u16 {
    const index = std.mem.lastIndexOfScalar(u16, path, separator) orelse return path;
    return path[index + 1 ..];
}

fn dirnameUnits(path: []const u16, separator: u16) []const u16 {
    const index = std.mem.lastIndexOfScalar(u16, path, separator) orelse return &.{};
    return path[0..index];
}

fn allExtensionUnits(units: []const u16) bool {
    for (units) |unit| switch (unit) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '+' => {},
        else => return false,
    };
    return true;
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

test "BASE64のNode互換境界とUTF-8置換を再現する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var encoded = (try call(&runtime, "BASE64エンコード", &.{try runtime.stringUtf8("こんにちは")})).?;
    try roots.protect(&encoded);
    try expectUtf8(encoded, "44GT44KT44Gr44Gh44Gv");
    var decoded = (try call(&runtime, "BASE64デコード", &.{encoded})).?;
    try roots.protect(&decoded);
    try expectUtf8(decoded, "こんにちは");
    var url_safe = (try call(&runtime, "BASE64デコード", &.{try runtime.stringUtf8("8J-YgA")})).?;
    try roots.protect(&url_safe);
    try expectUtf8(url_safe, "😀");
    var invalid_utf8 = (try call(&runtime, "BASE64デコード", &.{try runtime.stringUtf8("/w==")})).?;
    try roots.protect(&invalid_utf8);
    try expectUtf8(invalid_utf8, "�");

    var array = try runtime.createArray();
    try roots.protect(&array);
    _ = try array.array.push(.{ .number = 65 });
    _ = try array.array.push(.{ .number = 300 });
    _ = try array.array.push(.{ .number = -1 });
    var array_encoded = (try call(&runtime, "BASE64エンコード", &.{array})).?;
    try roots.protect(&array_encoded);
    try expectUtf8(array_encoded, "QSz/");
}

test "拡張子変更と終端パスをOS区切り文字ごとに再現する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var extension = (try callWithSeparator(&runtime, "拡張子抽出", &.{try runtime.stringUtf8("/a/.b/c.c++")}, "/")).?;
    try roots.protect(&extension);
    try expectUtf8(extension, ".c++");
    var hidden_extension = (try callWithSeparator(&runtime, "拡張子抽出", &.{try runtime.stringUtf8(".bashrc")}, "/")).?;
    try roots.protect(&hidden_extension);
    try expectUtf8(hidden_extension, ".bashrc");
    var change_source = try runtime.stringUtf8("/a/.b/c.txt");
    try roots.protect(&change_source);
    var change_extension = try runtime.stringUtf8(" docx ");
    try roots.protect(&change_extension);
    var changed = (try callWithSeparator(&runtime, "拡張子変更", &.{ change_source, change_extension }, "/")).?;
    try roots.protect(&changed);
    try expectUtf8(changed, "/a/.b/c.docx");
    var remove_source = try runtime.stringUtf8("a.txt");
    try roots.protect(&remove_source);
    var empty_extension = try runtime.stringUtf8("");
    try roots.protect(&empty_extension);
    var removed = (try callWithSeparator(&runtime, "拡張子変更", &.{ remove_source, empty_extension }, "/")).?;
    try roots.protect(&removed);
    try expectUtf8(removed, "a");
    var windows_source = try runtime.stringUtf8("C:\\a\\b.txt");
    try roots.protect(&windows_source);
    var windows_extension = try runtime.stringUtf8("md");
    try roots.protect(&windows_extension);
    var windows = (try callWithSeparator(&runtime, "拡張子変更", &.{ windows_source, windows_extension }, "\\")).?;
    try roots.protect(&windows);
    try expectUtf8(windows, "C:\\a\\b.md");

    var added = (try callWithSeparator(&runtime, "終端パス追加", &.{try runtime.stringUtf8("a/b")}, "/")).?;
    try roots.protect(&added);
    try expectUtf8(added, "a/b/");
    var once = (try callWithSeparator(&runtime, "終端パス除去", &.{try runtime.stringUtf8("a/b//")}, "/")).?;
    try roots.protect(&once);
    try expectUtf8(once, "a/b/");
    var alias = (try callWithSeparator(&runtime, "終端パス削除", &.{try runtime.stringUtf8("C:\\a\\")}, "\\")).?;
    try roots.protect(&alias);
    try expectUtf8(alias, "C:\\a");
}

test "system path aliasはsplitの末尾要素とpop後のpathを保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var basename = (try callWithSeparator(&runtime, "ファイル名抽出", &.{try runtime.stringUtf8("/a/b")}, "/")).?;
    try roots.protect(&basename);
    try expectUtf8(basename, "b");
    var dirname = (try callWithSeparator(&runtime, "パス抽出", &.{try runtime.stringUtf8("/a/b")}, "/")).?;
    try roots.protect(&dirname);
    try expectUtf8(dirname, "/a");
    var trailing_basename = (try callWithSeparator(&runtime, "ファイル名抽出", &.{try runtime.stringUtf8("a/")}, "/")).?;
    try roots.protect(&trailing_basename);
    try expectUtf8(trailing_basename, "");
    var trailing_dirname = (try callWithSeparator(&runtime, "パス抽出", &.{try runtime.stringUtf8("a/")}, "/")).?;
    try roots.protect(&trailing_dirname);
    try expectUtf8(trailing_dirname, "a");
    var repeated_dirname = (try callWithSeparator(&runtime, "パス抽出", &.{try runtime.stringUtf8("a//b//")}, "/")).?;
    try roots.protect(&repeated_dirname);
    try expectUtf8(repeated_dirname, "a//b/");
}

fn expectUtf8(value: Value, expected: []const u8) !void {
    try std.testing.expect(value == .string);
    const actual = try value.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
