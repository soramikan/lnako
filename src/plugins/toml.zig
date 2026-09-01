const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const toml_temporal = @import("../runtime/toml_temporal.zig");
const common = @import("system/common.zig");
const json = @import("system/json.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value) !?Value {
    const source = common.argument(arguments, 0);
    if (std.mem.eql(u8, name, "TOML取得")) return @as(?Value, try parse(runtime, source));
    if (std.mem.eql(u8, name, "TOML変換")) return @as(?Value, try stringify(runtime, source));
    return null;
}

fn parse(runtime: *Runtime, source: Value) !Value {
    var rooted_source = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    var text = try runtime.valueToString(rooted_source);
    try roots.protect(&text);
    const utf8 = try text.string.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(utf8);
    var parser = Parser{ .runtime = runtime, .input = utf8 };
    var result = try parser.document();
    try roots.protect(&result);
    return result;
}

const Parser = struct {
    runtime: *Runtime,
    input: []const u8,
    index: usize = 0,

    fn document(self: *Parser) !Value {
        var result = try self.runtime.createDictionary();
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        var current = result.dictionary;
        while (true) {
            self.skipDocumentSpace();
            if (self.index >= self.input.len) break;
            if (self.input[self.index] == '[') {
                const array_table = self.index + 1 < self.input.len and self.input[self.index + 1] == '[';
                self.index += if (array_table) 2 else 1;
                var path = try self.keyPath(if (array_table) .double_bracket else .bracket);
                defer path.deinit();
                current = try self.table(result.dictionary, path.items.items, array_table);
            } else {
                var path = try self.keyPath(.equal);
                defer path.deinit();
                var parsed_value = try self.value();
                var value_roots = self.runtime.rootFrame();
                defer value_roots.deinit();
                try value_roots.protect(&parsed_value);
                try self.assign(current, path.items.items, parsed_value);
            }
            self.skipHorizontal();
            if (self.index < self.input.len and self.input[self.index] == '#') self.skipComment();
            if (self.index < self.input.len and self.input[self.index] != '\n' and self.input[self.index] != '\r') return error.InvalidTomlDocument;
        }
        return result;
    }

    const Terminator = enum { equal, bracket, double_bracket };
    const KeyPath = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList([]u8) = .empty,

        fn deinit(self: *KeyPath) void {
            for (self.items.items) |item| self.allocator.free(item);
            self.items.deinit(self.allocator);
        }
    };

    fn keyPath(self: *Parser, terminator: Terminator) !KeyPath {
        var result = KeyPath{ .allocator = self.runtime.allocator() };
        errdefer result.deinit();
        while (true) {
            self.skipHorizontal();
            if (self.index >= self.input.len) return error.InvalidTomlKey;
            const key = if (self.input[self.index] == '"' or self.input[self.index] == '\'')
                try self.stringBytes(self.input[self.index], false)
            else blk: {
                const start = self.index;
                while (self.index < self.input.len and isBareKey(self.input[self.index])) self.index += 1;
                if (start == self.index) return error.InvalidTomlKey;
                break :blk try self.runtime.allocator().dupe(u8, self.input[start..self.index]);
            };
            try result.items.append(self.runtime.allocator(), key);
            self.skipHorizontal();
            if (self.index < self.input.len and self.input[self.index] == '.') {
                self.index += 1;
                continue;
            }
            switch (terminator) {
                .equal => {
                    if (!self.consume('=')) return error.InvalidTomlKey;
                },
                .bracket => {
                    if (!self.consume(']')) return error.InvalidTomlTable;
                },
                .double_bracket => {
                    if (!self.consume(']') or !self.consume(']')) return error.InvalidTomlTable;
                },
            }
            if (result.items.items.len == 0) return error.InvalidTomlKey;
            return result;
        }
    }

    fn value(self: *Parser) anyerror!Value {
        self.skipHorizontal();
        if (self.index >= self.input.len) return error.InvalidTomlValue;
        return switch (self.input[self.index]) {
            '"' => self.stringValue('"'),
            '\'' => self.stringValue('\''),
            '[' => self.array(),
            '{' => self.inlineTable(),
            else => self.bareValue(),
        };
    }

    fn stringValue(self: *Parser, quote: u8) !Value {
        const multiline = self.index + 2 < self.input.len and self.input[self.index + 1] == quote and self.input[self.index + 2] == quote;
        const bytes = try self.stringBytes(quote, multiline);
        defer self.runtime.allocator().free(bytes);
        return self.runtime.stringUtf8(bytes);
    }

    fn stringBytes(self: *Parser, quote: u8, multiline: bool) ![]u8 {
        self.index += if (multiline) 3 else 1;
        if (multiline) {
            if (self.consume('\r')) _ = self.consume('\n') else _ = self.consume('\n');
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.runtime.allocator());
        while (self.index < self.input.len) {
            if (multiline) {
                if (self.index + 2 < self.input.len and self.input[self.index] == quote and self.input[self.index + 1] == quote and self.input[self.index + 2] == quote) {
                    self.index += 3;
                    return output.toOwnedSlice(self.runtime.allocator());
                }
            } else if (self.input[self.index] == quote) {
                self.index += 1;
                return output.toOwnedSlice(self.runtime.allocator());
            }
            const byte = self.input[self.index];
            self.index += 1;
            if (!multiline and (byte == '\n' or byte == '\r')) return error.UnterminatedTomlString;
            if (quote == '\'' or byte != '\\') {
                try output.append(self.runtime.allocator(), byte);
                continue;
            }
            if (self.index >= self.input.len) return error.UnterminatedTomlString;
            const escaped = self.input[self.index];
            self.index += 1;
            switch (escaped) {
                'b' => try output.append(self.runtime.allocator(), 0x08),
                't' => try output.append(self.runtime.allocator(), '\t'),
                'n' => try output.append(self.runtime.allocator(), '\n'),
                'f' => try output.append(self.runtime.allocator(), 0x0c),
                'r' => try output.append(self.runtime.allocator(), '\r'),
                '"' => try output.append(self.runtime.allocator(), '"'),
                '\\' => try output.append(self.runtime.allocator(), '\\'),
                'u' => try self.appendUnicode(&output, 4),
                'U' => try self.appendUnicode(&output, 8),
                '\n', '\r' => if (multiline) {
                    if (escaped == '\r') _ = self.consume('\n');
                    while (self.index < self.input.len and (self.input[self.index] == ' ' or self.input[self.index] == '\t' or self.input[self.index] == '\n' or self.input[self.index] == '\r')) self.index += 1;
                } else return error.InvalidTomlEscape,
                else => return error.InvalidTomlEscape,
            }
        }
        return error.UnterminatedTomlString;
    }

    fn appendUnicode(self: *Parser, output: *std.ArrayList(u8), digits: usize) !void {
        if (self.index + digits > self.input.len) return error.InvalidTomlEscape;
        const codepoint = std.fmt.parseInt(u21, self.input[self.index .. self.index + digits], 16) catch return error.InvalidTomlEscape;
        self.index += digits;
        if (!std.unicode.utf8ValidCodepoint(codepoint) or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return error.InvalidTomlEscape;
        var buffer: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(codepoint, &buffer);
        try output.appendSlice(self.runtime.allocator(), buffer[0..length]);
    }

    fn array(self: *Parser) !Value {
        self.index += 1;
        var result = try self.runtime.createArray();
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        self.skipValueSpace();
        if (self.consume(']')) return result;
        while (true) {
            const item = try self.value();
            _ = try result.array.push(item);
            self.skipValueSpace();
            if (self.consume(']')) return result;
            if (!self.consume(',')) return error.InvalidTomlArray;
            self.skipValueSpace();
            if (self.consume(']')) return result;
        }
    }

    fn inlineTable(self: *Parser) !Value {
        self.index += 1;
        var result = try self.runtime.createDictionary();
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&result);
        self.skipHorizontal();
        if (self.consume('}')) return result;
        while (true) {
            var path = try self.keyPath(.equal);
            defer path.deinit();
            var item = try self.value();
            var item_roots = self.runtime.rootFrame();
            defer item_roots.deinit();
            try item_roots.protect(&item);
            try self.assign(result.dictionary, path.items.items, item);
            self.skipHorizontal();
            if (self.consume('}')) return result;
            if (!self.consume(',')) return error.InvalidTomlInlineTable;
            self.skipHorizontal();
        }
    }

    fn bareValue(self: *Parser) !Value {
        const start = self.index;
        while (self.index < self.input.len) {
            const byte = self.input[self.index];
            if (byte == ' ' and self.index == start + 10 and toml_temporal.hasDatePrefix(self.input[start..]) and self.index + 1 < self.input.len and std.ascii.isDigit(self.input[self.index + 1])) {
                self.index += 1;
                continue;
            }
            if (byte == ',' or byte == ']' or byte == '}' or byte == '#' or byte == '\n' or byte == '\r' or byte == ' ' or byte == '\t') break;
            self.index += 1;
        }
        if (start == self.index) return error.InvalidTomlValue;
        const token = self.input[start..self.index];
        if (std.mem.eql(u8, token, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, token, "false")) return .{ .boolean = false };
        if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "+inf")) return .{ .number = std.math.inf(f64) };
        if (std.mem.eql(u8, token, "-inf")) return .{ .number = -std.math.inf(f64) };
        if (std.mem.eql(u8, token, "nan") or std.mem.eql(u8, token, "+nan")) return .{ .number = std.math.nan(f64) };
        if (std.mem.eql(u8, token, "-nan")) return .{ .number = -std.math.nan(f64) };
        if (try toml_temporal.normalize(self.runtime.allocator(), token)) |normalized_value| {
            var normalized = normalized_value;
            defer normalized.deinit();
            return self.runtime.createTomlTemporal(normalized.kind, normalized.text, normalized.text);
        }
        if (toml_temporal.looksLikeTemporal(token)) return self.runtime.stringUtf8(token);
        const normalized = try removeUnderscores(self.runtime.allocator(), token);
        defer self.runtime.allocator().free(normalized);
        if (parseTomlInteger(normalized)) |integer| return .{ .number = integer } else |_| {}
        const number = std.fmt.parseFloat(f64, normalized) catch return error.InvalidTomlValue;
        return .{ .number = number };
    }

    fn table(self: *Parser, root: *value_mod.Dictionary, path: []const []const u8, array_table: bool) !*value_mod.Dictionary {
        var current = root;
        for (path, 0..) |segment, index| {
            const last = index + 1 == path.len;
            const existing = try self.get(current, segment);
            if (last and array_table) {
                var array_value = existing orelse blk: {
                    const created = try self.runtime.createArray();
                    try self.put(current, segment, created);
                    break :blk created;
                };
                if (array_value != .array) return error.InvalidTomlTable;
                var table_value = try self.runtime.createDictionary();
                var roots = self.runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&array_value);
                try roots.protect(&table_value);
                _ = try array_value.array.push(table_value);
                return table_value.dictionary;
            }
            if (existing) |found| {
                if (found == .dictionary and found.dictionary.kind == .ordinary) {
                    current = found.dictionary;
                } else if (found == .array and found.array.len() > 0 and found.array.get(found.array.len() - 1) == .dictionary and found.array.get(found.array.len() - 1).dictionary.kind == .ordinary) {
                    current = found.array.get(found.array.len() - 1).dictionary;
                } else return error.InvalidTomlTable;
            } else {
                var created = try self.runtime.createDictionary();
                var roots = self.runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&created);
                try self.put(current, segment, created);
                current = created.dictionary;
            }
        }
        return current;
    }

    fn assign(self: *Parser, base: *value_mod.Dictionary, path: []const []const u8, assigned_value: Value) !void {
        if (path.len == 0) return error.InvalidTomlKey;
        var current = base;
        for (path[0 .. path.len - 1]) |segment| {
            if (try self.get(current, segment)) |found| {
                if (found != .dictionary or found.dictionary.kind != .ordinary) return error.InvalidTomlKey;
                current = found.dictionary;
            } else {
                var created = try self.runtime.createDictionary();
                var roots = self.runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&created);
                try self.put(current, segment, created);
                current = created.dictionary;
            }
        }
        if (try self.get(current, path[path.len - 1]) != null) return error.DuplicateTomlKey;
        try self.put(current, path[path.len - 1], assigned_value);
    }

    fn get(self: *Parser, dictionary: *value_mod.Dictionary, key: []const u8) !?Value {
        var key_value = try self.runtime.stringUtf8(key);
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&key_value);
        return dictionary.get(key_value.string);
    }

    fn put(self: *Parser, dictionary: *value_mod.Dictionary, key: []const u8, assigned_value: Value) !void {
        var rooted_value = assigned_value;
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&rooted_value);
        var key_value = try self.runtime.stringUtf8(key);
        try roots.protect(&key_value);
        try dictionary.set(key_value.string, rooted_value);
    }

    fn skipDocumentSpace(self: *Parser) void {
        while (self.index < self.input.len) switch (self.input[self.index]) {
            ' ', '\t', '\n', '\r' => self.index += 1,
            '#' => self.skipComment(),
            else => return,
        };
    }

    fn skipValueSpace(self: *Parser) void {
        while (self.index < self.input.len) switch (self.input[self.index]) {
            ' ', '\t', '\n', '\r' => self.index += 1,
            '#' => self.skipComment(),
            else => return,
        };
    }

    fn skipHorizontal(self: *Parser) void {
        while (self.index < self.input.len and (self.input[self.index] == ' ' or self.input[self.index] == '\t')) self.index += 1;
    }

    fn skipComment(self: *Parser) void {
        while (self.index < self.input.len and self.input[self.index] != '\n') self.index += 1;
    }

    fn consume(self: *Parser, byte: u8) bool {
        if (self.index >= self.input.len or self.input[self.index] != byte) return false;
        self.index += 1;
        return true;
    }
};

fn stringify(runtime: *Runtime, source: Value) !Value {
    if (source != .dictionary) return error.DictionaryExpected;
    var rooted_source = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator());
    var active_dictionaries: std.AutoHashMapUnmanaged(*value_mod.Dictionary, void) = .empty;
    defer active_dictionaries.deinit(runtime.allocator());
    var active_arrays: std.AutoHashMapUnmanaged(*value_mod.Array, void) = .empty;
    defer active_arrays.deinit(runtime.allocator());
    var path: std.ArrayList(*value_mod.String) = .empty;
    defer path.deinit(runtime.allocator());
    try writeTable(runtime, &output, source.dictionary, &path, false, &active_dictionaries, &active_arrays);
    return runtime.stringUtf8(output.items);
}

fn writeTable(runtime: *Runtime, output: *std.ArrayList(u8), dictionary: *value_mod.Dictionary, path: *std.ArrayList(*value_mod.String), emit_header: bool, active_dictionaries: *std.AutoHashMapUnmanaged(*value_mod.Dictionary, void), active_arrays: *std.AutoHashMapUnmanaged(*value_mod.Array, void)) !void {
    if (active_dictionaries.contains(dictionary)) return error.CircularTomlValue;
    try active_dictionaries.put(runtime.allocator(), dictionary, {});
    defer _ = active_dictionaries.remove(dictionary);
    if (emit_header) {
        try writeHeader(runtime, output, path.items, false);
        try output.append(runtime.allocator(), '\n');
    }
    for (dictionary.keys(), dictionary.values()) |key, value| {
        if (isTableDictionary(value) or isArrayOfDictionaries(value)) continue;
        try writeKey(runtime, output, key);
        try output.appendSlice(runtime.allocator(), " = ");
        try writeValue(runtime, output, value, active_dictionaries, active_arrays);
        try output.append(runtime.allocator(), '\n');
    }
    for (dictionary.keys(), dictionary.values()) |key, value| {
        if (!isTableDictionary(value) and !isArrayOfDictionaries(value)) continue;
        if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') try output.append(runtime.allocator(), '\n');
        if (output.items.len > 0 and !(output.items.len >= 2 and output.items[output.items.len - 2] == '\n')) try output.append(runtime.allocator(), '\n');
        try path.append(runtime.allocator(), key);
        defer _ = path.pop();
        if (isTableDictionary(value)) {
            try writeTable(runtime, output, value.dictionary, path, true, active_dictionaries, active_arrays);
        } else {
            if (active_arrays.contains(value.array)) return error.CircularTomlValue;
            try active_arrays.put(runtime.allocator(), value.array, {});
            defer _ = active_arrays.remove(value.array);
            for (value.array.items.items, 0..) |item, index| {
                if (item != .dictionary or item.dictionary.kind != .ordinary) return error.UnsupportedTomlValue;
                if (index > 0) try output.append(runtime.allocator(), '\n');
                try writeHeader(runtime, output, path.items, true);
                try output.append(runtime.allocator(), '\n');
                try writeTable(runtime, output, item.dictionary, path, false, active_dictionaries, active_arrays);
            }
        }
    }
}

fn writeHeader(runtime: *Runtime, output: *std.ArrayList(u8), path: []const *value_mod.String, array_table: bool) !void {
    try output.appendSlice(runtime.allocator(), if (array_table) "[[" else "[");
    for (path, 0..) |key, index| {
        if (index > 0) try output.append(runtime.allocator(), '.');
        try writeKey(runtime, output, key);
    }
    try output.appendSlice(runtime.allocator(), if (array_table) "]]" else "]");
}

fn writeKey(runtime: *Runtime, output: *std.ArrayList(u8), key: *value_mod.String) !void {
    const utf8 = try key.toUtf8Lossy(runtime.allocator());
    defer runtime.allocator().free(utf8);
    var bare = utf8.len > 0;
    for (utf8) |byte| bare = bare and isBareKey(byte);
    if (bare) return output.appendSlice(runtime.allocator(), utf8);
    try writeQuoted(runtime, output, utf8);
}

fn writeValue(runtime: *Runtime, output: *std.ArrayList(u8), value: Value, active_dictionaries: *std.AutoHashMapUnmanaged(*value_mod.Dictionary, void), active_arrays: *std.AutoHashMapUnmanaged(*value_mod.Array, void)) !void {
    switch (value) {
        .boolean => |boolean| try output.appendSlice(runtime.allocator(), if (boolean) "true" else "false"),
        .number => |number| {
            if (std.math.isNan(number)) return output.appendSlice(runtime.allocator(), "nan");
            if (std.math.isInf(number)) return output.appendSlice(runtime.allocator(), if (number < 0) "-inf" else "inf");
            const text = if (std.math.isFinite(number) and @trunc(number) == number and number >= @as(f64, @floatFromInt(std.math.minInt(i64))) and number <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
                try std.fmt.allocPrint(runtime.allocator(), "{d}", .{@as(i64, @intFromFloat(number))})
            else
                try std.fmt.allocPrint(runtime.allocator(), "{d}", .{number});
            defer runtime.allocator().free(text);
            try output.appendSlice(runtime.allocator(), text);
        },
        .string => |string| {
            const utf8 = try string.toUtf8Lossy(runtime.allocator());
            defer runtime.allocator().free(utf8);
            try writeQuoted(runtime, output, utf8);
        },
        .array => |array| {
            if (active_arrays.contains(array)) return error.CircularTomlValue;
            try active_arrays.put(runtime.allocator(), array, {});
            defer _ = active_arrays.remove(array);
            try output.appendSlice(runtime.allocator(), "[ ");
            for (array.items.items, 0..) |item, index| {
                if (index > 0) try output.appendSlice(runtime.allocator(), ", ");
                try writeValue(runtime, output, item, active_dictionaries, active_arrays);
            }
            try output.appendSlice(runtime.allocator(), " ]");
        },
        .dictionary => |dictionary| {
            if (dictionary.kind == .toml_temporal) {
                const temporal = dictionary.toml_temporal orelse return error.UnsupportedTomlValue;
                return output.appendSlice(runtime.allocator(), temporal.toml_text);
            }
            if (active_dictionaries.contains(dictionary)) return error.CircularTomlValue;
            try active_dictionaries.put(runtime.allocator(), dictionary, {});
            defer _ = active_dictionaries.remove(dictionary);
            try output.appendSlice(runtime.allocator(), "{ ");
            for (dictionary.keys(), dictionary.values(), 0..) |key, item, index| {
                if (index > 0) try output.appendSlice(runtime.allocator(), ", ");
                try writeKey(runtime, output, key);
                try output.appendSlice(runtime.allocator(), " = ");
                try writeValue(runtime, output, item, active_dictionaries, active_arrays);
            }
            try output.appendSlice(runtime.allocator(), " }");
        },
        else => return error.UnsupportedTomlValue,
    }
}

fn writeQuoted(runtime: *Runtime, output: *std.ArrayList(u8), bytes: []const u8) !void {
    try output.append(runtime.allocator(), '"');
    for (bytes) |byte| switch (byte) {
        '\n' => try output.appendSlice(runtime.allocator(), "\\n"),
        '\r' => try output.appendSlice(runtime.allocator(), "\\r"),
        '\t' => try output.appendSlice(runtime.allocator(), "\\t"),
        '\\' => try output.appendSlice(runtime.allocator(), "\\\\"),
        '"' => try output.appendSlice(runtime.allocator(), "\\\""),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
            const escaped = try std.fmt.allocPrint(runtime.allocator(), "\\u{X:0>4}", .{byte});
            defer runtime.allocator().free(escaped);
            try output.appendSlice(runtime.allocator(), escaped);
        },
        else => try output.append(runtime.allocator(), byte),
    };
    try output.append(runtime.allocator(), '"');
}

fn parseTomlInteger(token: []const u8) !f64 {
    var sign: f64 = 1;
    var digits = token;
    if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) {
        if (digits[0] == '-') sign = -1;
        digits = digits[1..];
    }
    var radix: u8 = 10;
    if (digits.len > 2 and digits[0] == '0') switch (digits[1]) {
        'x' => radix = 16,
        'o' => radix = 8,
        'b' => radix = 2,
        else => {},
    };
    if (radix != 10) digits = digits[2..];
    if (digits.len == 0 or (radix == 10 and digits.len > 1 and digits[0] == '0')) return error.InvalidTomlInteger;
    const integer = try std.fmt.parseInt(u64, digits, radix);
    if (integer > 9_007_199_254_740_991) return error.TomlIntegerPrecisionLoss;
    return sign * @as(f64, @floatFromInt(integer));
}

fn removeUnderscores(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (token, 0..) |byte, index| {
        if (byte != '_') {
            try output.append(allocator, byte);
            continue;
        }
        if (index == 0 or index + 1 == token.len or !std.ascii.isAlphanumeric(token[index - 1]) or !std.ascii.isAlphanumeric(token[index + 1])) return error.InvalidTomlNumber;
    }
    return output.toOwnedSlice(allocator);
}

fn isArrayOfDictionaries(value: Value) bool {
    return value == .array and value.array.len() > 0 and value.array.get(0) == .dictionary and value.array.get(0).dictionary.kind == .ordinary;
}

fn isTableDictionary(value: Value) bool {
    return value == .dictionary and value.dictionary.kind == .ordinary;
}

fn isBareKey(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

test "TOMLの表・配列・インライン表を相互変換する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var source = try runtime.stringUtf8("title=\"x\"\nn=1_000\na=[1,2]\no={x=1}\n[server]\nport=8080\n");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    var decoded = (try call(&runtime, "TOML取得", &.{source})).?;
    try roots.protect(&decoded);
    try std.testing.expectEqual(@as(f64, 1000), (try dictionaryValue(&runtime, decoded.dictionary, "n")).number);
    const encoded = (try call(&runtime, "TOML変換", &.{decoded})).?;
    const utf8 = try encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expect(std.mem.indexOf(u8, utf8, "[server]\nport = 8080") != null);
}

test "TOML日時は専用値としてJSONとTOMLへ正規化する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var source = try runtime.stringUtf8("d=1979-05-27\nt=07:32\no=1979-05-27T07:32:00Z\nl=1979-05-27 07:32\n");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    var decoded = (try call(&runtime, "TOML取得", &.{source})).?;
    try roots.protect(&decoded);

    for ([_]struct { key: []const u8, kind: value_mod.TomlTemporalKind }{
        .{ .key = "d", .kind = .date },
        .{ .key = "t", .kind = .time },
        .{ .key = "o", .kind = .offset_datetime },
        .{ .key = "l", .kind = .local_datetime },
    }) |case| {
        const item = try dictionaryValue(&runtime, decoded.dictionary, case.key);
        try std.testing.expect(item == .dictionary);
        try std.testing.expectEqual(value_mod.DictionaryKind.toml_temporal, item.dictionary.kind);
        try std.testing.expectEqual(case.kind, item.dictionary.toml_temporal.?.kind);
    }

    const encoded_json = (try json.call(&runtime, "JSON変換", &.{decoded})).?;
    const json_utf8 = try encoded_json.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(json_utf8);
    try std.testing.expectEqualStrings("{\"d\":\"1979-05-27\",\"t\":\"07:32:00.000\",\"o\":\"1979-05-27T07:32:00.000Z\",\"l\":\"1979-05-27T07:32:00.000\"}", json_utf8);

    const encoded_toml = (try call(&runtime, "TOML変換", &.{decoded})).?;
    const toml_utf8 = try encoded_toml.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(toml_utf8);
    try std.testing.expectEqualStrings("d = 1979-05-27\nt = 07:32:00.000\no = 1979-05-27T07:32:00.000Z\nl = 1979-05-27T07:32:00.000\n", toml_utf8);
}

fn dictionaryValue(runtime: *Runtime, dictionary: *value_mod.Dictionary, key: []const u8) !Value {
    const key_value = try runtime.stringUtf8(key);
    return dictionary.get(key_value.string) orelse error.MissingKey;
}
