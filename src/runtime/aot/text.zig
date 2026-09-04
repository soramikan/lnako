const std = @import("std");
const state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const string_mod = shared.string_mod;
const markup = shared.markup;
const courtesy = shared.courtesy;
const toml_temporal = shared.toml_temporal;

const Runtime = state.Runtime;
const Value = state.Value;
const Object = state.Object;
const Tag = state.Tag;
const RootFrame = state.RootFrame;
const DictionaryEntry = state.DictionaryEntry;
const AotCsvState = state.AotCsvState;
const AotCsvDelimiterDefault = state.AotCsvDelimiterDefault;
const AotTomlTemporal = state.AotTomlTemporal;
const BigInt = state.BigInt;
const numberValue = state.numberValue;
const numberString = state.numberString;
const valueToNumber = state.valueToNumber;
const valueToNumberRuntime = state.valueToNumberRuntime;
const valueTruthy = state.valueTruthy;
const valueUtf8LossyAlloc = state.valueUtf8LossyAlloc;
const valueUtf16Alloc = state.valueUtf16Alloc;
const runtimeUtf8String = state.runtimeUtf8String;
const runtimeUtf8StringLossy = state.runtimeUtf8StringLossy;
const arrayAppendBuiltin = state.arrayAppendBuiltin;
const arrayItems = state.arrayItems;
const staticStringValue = state.staticStringValue;
const staticUtf8 = state.staticUtf8;
const isString = state.isString;
const dictionaryProperty = state.dictionaryProperty;
const invokeAotCallback = state.invokeAotCallback;
const resolveAotCallback = state.resolveAotCallback;
const awaitAotPromise = state.awaitAotPromise;

pub fn csvBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    return switch (command) {
        .csv_parse => blk: {
            runtime.csv_state.useDelimiter(runtime.allocator, .comma);
            break :blk try csvParse(runtime, &runtime.csv_state, arguments[0]);
        },
        .tsv_parse => blk: {
            runtime.csv_state.useDelimiter(runtime.allocator, .tab);
            break :blk try csvParse(runtime, &runtime.csv_state, arguments[0]);
        },
        .table_csv_stringify, .csv_stringify => blk: {
            runtime.csv_state.useDelimiter(runtime.allocator, .comma);
            break :blk try csvStringify(runtime, &runtime.csv_state, arguments[0]);
        },
        .table_tsv_stringify, .tsv_stringify => blk: {
            runtime.csv_state.useDelimiter(runtime.allocator, .tab);
            break :blk try csvStringify(runtime, &runtime.csv_state, arguments[0]);
        },
        .csv_options => blk: {
            try csvSetOptions(runtime, &runtime.csv_state, arguments[0]);
            break :blk .{};
        },
        else => error.UnknownCommand,
    };
}

pub fn csvParse(runtime: *Runtime, csv_state: *const AotCsvState, source: Value) !Value {
    var rooted = [_]Value{ source, .{}, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);

    const source_units = try valueUtf16Alloc(runtime, rooted[0]);
    defer runtime.allocator.free(source_units);
    var normalized: std.ArrayList(u16) = .empty;
    defer normalized.deinit(runtime.allocator);
    var input_index: usize = 0;
    while (input_index < source_units.len) : (input_index += 1) {
        const unit = source_units[input_index];
        if (unit == '\r') {
            if (input_index + 1 < source_units.len and source_units[input_index + 1] == '\n') input_index += 1;
            try normalized.append(runtime.allocator, '\n');
        } else try normalized.append(runtime.allocator, unit);
    }
    while (normalized.items.len > 0 and csvIsWhitespace(normalized.items[normalized.items.len - 1])) _ = normalized.pop();
    try normalized.append(runtime.allocator, '\n');

    rooted[1] = try runtime.createArray(&.{});
    rooted[2] = try runtime.createArray(&.{});
    const delimiter = if (csv_state.delimiter().len > 0) csv_state.delimiter()[0] else ',';
    var cursor: usize = 0;
    while (cursor < normalized.items.len) {
        var current = normalized.items[cursor];
        if (current == delimiter) {
            try csvAppendCell(runtime, &rooted[2].object().?.payload.array, &.{}, csv_state.auto_convert_number);
            cursor += 1;
            continue;
        }
        if (current == '\n') {
            try csvAppendCell(runtime, &rooted[2].object().?.payload.array, &.{}, csv_state.auto_convert_number);
            try rooted[1].object().?.payload.array.append(runtime.allocator, rooted[2]);
            rooted[2] = try runtime.createArray(&.{});
            cursor += 1;
            continue;
        }
        while (cursor < normalized.items.len and csvIsWhitespace(normalized.items[cursor]) and normalized.items[cursor] != '\n') cursor += 1;
        if (cursor >= normalized.items.len) break;
        current = normalized.items[cursor];
        if (current == delimiter) {
            try csvAppendCell(runtime, &rooted[2].object().?.payload.array, &.{}, csv_state.auto_convert_number);
            cursor += 1;
            continue;
        }
        if (current == '=' and cursor + 1 < normalized.items.len and normalized.items[cursor + 1] == '"') {
            cursor += 1;
            current = '"';
        }
        if (current != '"') {
            const start = cursor;
            while (cursor < normalized.items.len and normalized.items[cursor] != delimiter and normalized.items[cursor] != '\n') cursor += 1;
            try csvAppendCell(runtime, &rooted[2].object().?.payload.array, normalized.items[start..cursor], csv_state.auto_convert_number);
            if (cursor < normalized.items.len and normalized.items[cursor] == '\n') {
                try rooted[1].object().?.payload.array.append(runtime.allocator, rooted[2]);
                rooted[2] = try runtime.createArray(&.{});
            }
            cursor += 1;
            continue;
        }
        if (cursor + 1 < normalized.items.len and normalized.items[cursor + 1] == '"') {
            try csvAppendCell(runtime, &rooted[2].object().?.payload.array, &.{}, csv_state.auto_convert_number);
            cursor += 2;
            continue;
        }
        cursor += 1;
        var quoted: std.ArrayList(u16) = .empty;
        defer quoted.deinit(runtime.allocator);
        while (cursor < normalized.items.len) {
            const first = normalized.items[cursor];
            const second = if (cursor + 1 < normalized.items.len) normalized.items[cursor + 1] else 0;
            if (first == '"' and second == '"') {
                try quoted.append(runtime.allocator, '"');
                cursor += 2;
                continue;
            }
            if (first == '"') {
                cursor += 1;
                if (second == delimiter) {
                    cursor += 1;
                    try csvAppendCell(runtime, &rooted[2].object().?.payload.array, quoted.items, csv_state.auto_convert_number);
                    break;
                }
                if (second == '\n') {
                    cursor += 1;
                    try csvAppendCell(runtime, &rooted[2].object().?.payload.array, quoted.items, csv_state.auto_convert_number);
                    try rooted[1].object().?.payload.array.append(runtime.allocator, rooted[2]);
                    rooted[2] = try runtime.createArray(&.{});
                    break;
                }
                if (cursor < normalized.items.len) cursor += 1;
                continue;
            }
            try quoted.append(runtime.allocator, first);
            cursor += 1;
        }
    }
    if (rooted[2].object().?.payload.array.items.len > 0) try rooted[1].object().?.payload.array.append(runtime.allocator, rooted[2]);
    return rooted[1];
}

pub fn csvAppendCell(runtime: *Runtime, row: *std.ArrayList(Value), units: []const u16, auto_convert: bool) !void {
    if (auto_convert and csvIsNumeric(units)) {
        var ascii = try runtime.allocator.alloc(u8, units.len);
        defer runtime.allocator.free(ascii);
        for (units, 0..) |unit, index| ascii[index] = @intCast(unit);
        try row.append(runtime.allocator, numberValue(std.fmt.parseFloat(f64, ascii) catch std.math.nan(f64)));
        return;
    }
    try row.append(runtime.allocator, try runtime.createString(units));
}

pub fn csvStringify(runtime: *Runtime, csv_state: *const AotCsvState, source: Value) !Value {
    if (source.tag == @intFromEnum(Tag.undefined)) return runtime.createString(&.{});
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    var rooted = [_]Value{ source, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);

    var raw: std.ArrayList(u16) = .empty;
    defer raw.deinit(runtime.allocator);
    const delimiter = csv_state.delimiter();
    for (rooted[0].object().?.payload.array.items) |row| {
        if (row.tag == @intFromEnum(Tag.undefined)) {
            try raw.appendSlice(runtime.allocator, csv_state.eol());
            continue;
        }
        if (row.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
        const row_object = row.object().?;
        for (row_object.payload.array.items, 0..) |cell, column| {
            if (column > 0) try raw.appendSlice(runtime.allocator, delimiter);
            rooted[1] = try csvQuoteCell(runtime, cell, delimiter);
            row_object.payload.array.items[column] = rooted[1];
            try raw.appendSlice(runtime.allocator, rooted[1].object().?.payload.utf16_string);
        }
        try raw.appendSlice(runtime.allocator, csv_state.eol());
    }

    var normalized: std.ArrayList(u16) = .empty;
    defer normalized.deinit(runtime.allocator);
    var index: usize = 0;
    while (index < raw.items.len) : (index += 1) {
        if (raw.items[index] == '\r') {
            if (index + 1 < raw.items.len and raw.items[index + 1] == '\n') index += 1;
            try normalized.appendSlice(runtime.allocator, csv_state.eol());
        } else if (raw.items[index] == '\n') {
            try normalized.appendSlice(runtime.allocator, csv_state.eol());
        } else try normalized.append(runtime.allocator, raw.items[index]);
    }
    return runtime.createString(normalized.items);
}

pub fn csvQuoteCell(runtime: *Runtime, source: Value, delimiter: []const u16) !Value {
    const text = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(text);
    const needs_quote = std.mem.indexOfScalar(u16, text, '\n') != null or
        std.mem.indexOfScalar(u16, text, '\r') != null or
        (delimiter.len > 0 and std.mem.indexOf(u16, text, delimiter) != null) or
        std.mem.indexOfScalar(u16, text, '"') != null;
    if (!needs_quote) return runtime.createString(text);
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator);
    try output.append(runtime.allocator, '"');
    for (text) |unit| {
        if (unit == '"') try output.append(runtime.allocator, '"');
        try output.append(runtime.allocator, unit);
    }
    try output.append(runtime.allocator, '"');
    return runtime.createString(output.items);
}

pub fn csvSetOptions(runtime: *Runtime, csv_state: *AotCsvState, source: Value) !void {
    if (source.tag != @intFromEnum(Tag.dictionary)) return;
    for (source.object().?.payload.dictionary.items) |entry| {
        const key_units = try valueUtf16Alloc(runtime, entry.key);
        defer runtime.allocator.free(key_units);
        const key = try std.unicode.utf16LeToUtf8Alloc(runtime.allocator, key_units);
        defer runtime.allocator.free(key);
        if (std.mem.eql(u8, key, "delimiter") or std.mem.eql(u8, key, "区切文字")) {
            const value_units = try valueUtf16Alloc(runtime, entry.value);
            defer runtime.allocator.free(value_units);
            try csv_state.setDelimiter(runtime.allocator, value_units);
        } else if (std.mem.eql(u8, key, "eol")) {
            const value_units = try valueUtf16Alloc(runtime, entry.value);
            defer runtime.allocator.free(value_units);
            try csv_state.setEol(runtime.allocator, value_units);
        } else if (std.mem.eql(u8, key, "auto_convert_number")) csv_state.auto_convert_number = valueTruthy(entry.value);
    }
}

pub fn csvIsNumeric(units: []const u16) bool {
    if (units.len == 0) return false;
    var index: usize = 0;
    if (units[index] == '-') index += 1;
    const integer_start = index;
    while (index < units.len and units[index] >= '0' and units[index] <= '9') index += 1;
    if (index == integer_start) return false;
    if (index < units.len and units[index] == '.') {
        index += 1;
        const fraction_start = index;
        while (index < units.len and units[index] >= '0' and units[index] <= '9') index += 1;
        if (index == fraction_start) return false;
    }
    if (index < units.len and (units[index] == 'e' or units[index] == 'E')) {
        index += 1;
        if (index < units.len and (units[index] == '-' or units[index] == '+')) index += 1;
        const exponent_start = index;
        while (index < units.len and units[index] >= '0' and units[index] <= '9') index += 1;
        if (index == exponent_start) return false;
    }
    return index == units.len;
}

pub fn csvIsWhitespace(unit: u16) bool {
    return switch (unit) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x00a0, 0x3000 => true,
        else => false,
    };
}

pub fn tomlBuiltin(runtime: *Runtime, command: aot_builtin.Command, value: Value) !Value {
    return switch (command) {
        .toml_parse => tomlParse(runtime, value),
        .toml_stringify => tomlStringify(runtime, value),
        else => error.UnknownCommand,
    };
}

pub fn tomlParse(runtime: *Runtime, source: Value) !Value {
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    const input = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
    defer runtime.allocator.free(input);
    var parser = TomlAotParser{ .runtime = runtime, .input = input };
    return parser.document();
}

const TomlAotTerminator = enum { equal, bracket, double_bracket };

const TomlAotKeyPath = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *TomlAotKeyPath) void {
        for (self.items.items) |item| self.allocator.free(item);
        self.items.deinit(self.allocator);
    }
};

const TomlAotParser = struct {
    runtime: *Runtime,
    input: []const u8,
    index: usize = 0,

    pub fn document(self: *TomlAotParser) !Value {
        var result = try self.runtime.createDictionary(&.{});
        var roots = RootFrame{};
        self.runtime.pushRoots(&roots, @ptrCast(&result), 1);
        defer self.runtime.popRoots(&roots);
        var current = result;
        while (true) {
            self.skipDocumentSpace();
            if (self.index >= self.input.len) break;
            if (self.input[self.index] == '[') {
                const array_table = self.index + 1 < self.input.len and self.input[self.index + 1] == '[';
                self.index += if (array_table) 2 else 1;
                var path = try self.keyPath(if (array_table) .double_bracket else .bracket);
                defer path.deinit();
                current = try self.table(result, path.items.items, array_table);
            } else {
                var path = try self.keyPath(.equal);
                defer path.deinit();
                var parsed_value = try self.value();
                var value_roots = RootFrame{};
                self.runtime.pushRoots(&value_roots, @ptrCast(&parsed_value), 1);
                defer self.runtime.popRoots(&value_roots);
                try self.assign(current, path.items.items, parsed_value);
            }
            self.skipHorizontal();
            if (self.index < self.input.len and self.input[self.index] == '#') self.skipComment();
            if (self.index < self.input.len and self.input[self.index] != '\n' and self.input[self.index] != '\r') return error.InvalidTomlDocument;
        }
        return result;
    }

    pub fn keyPath(self: *TomlAotParser, terminator: TomlAotTerminator) !TomlAotKeyPath {
        var result = TomlAotKeyPath{ .allocator = self.runtime.allocator };
        errdefer result.deinit();
        while (true) {
            self.skipHorizontal();
            if (self.index >= self.input.len) return error.InvalidTomlKey;
            const key = if (self.input[self.index] == '"' or self.input[self.index] == '\'')
                try self.stringBytes(self.input[self.index], false)
            else blk: {
                const start = self.index;
                while (self.index < self.input.len and tomlAotIsBareKey(self.input[self.index])) self.index += 1;
                if (start == self.index) return error.InvalidTomlKey;
                break :blk try self.runtime.allocator.dupe(u8, self.input[start..self.index]);
            };
            try result.items.append(self.runtime.allocator, key);
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

    pub fn value(self: *TomlAotParser) anyerror!Value {
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

    pub fn stringValue(self: *TomlAotParser, quote: u8) !Value {
        const multiline = self.index + 2 < self.input.len and self.input[self.index + 1] == quote and self.input[self.index + 2] == quote;
        const bytes = try self.stringBytes(quote, multiline);
        defer self.runtime.allocator.free(bytes);
        return runtimeUtf8String(self.runtime, bytes);
    }

    pub fn stringBytes(self: *TomlAotParser, quote: u8, multiline: bool) ![]u8 {
        self.index += if (multiline) 3 else 1;
        if (multiline) {
            if (self.consume('\r')) _ = self.consume('\n') else _ = self.consume('\n');
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.runtime.allocator);
        while (self.index < self.input.len) {
            if (multiline) {
                if (self.index + 2 < self.input.len and self.input[self.index] == quote and self.input[self.index + 1] == quote and self.input[self.index + 2] == quote) {
                    self.index += 3;
                    return output.toOwnedSlice(self.runtime.allocator);
                }
            } else if (self.input[self.index] == quote) {
                self.index += 1;
                return output.toOwnedSlice(self.runtime.allocator);
            }
            const byte = self.input[self.index];
            self.index += 1;
            if (!multiline and (byte == '\n' or byte == '\r')) return error.UnterminatedTomlString;
            if (quote == '\'' or byte != '\\') {
                try output.append(self.runtime.allocator, byte);
                continue;
            }
            if (self.index >= self.input.len) return error.UnterminatedTomlString;
            const escaped = self.input[self.index];
            self.index += 1;
            switch (escaped) {
                'b' => try output.append(self.runtime.allocator, 0x08),
                't' => try output.append(self.runtime.allocator, '\t'),
                'n' => try output.append(self.runtime.allocator, '\n'),
                'f' => try output.append(self.runtime.allocator, 0x0c),
                'r' => try output.append(self.runtime.allocator, '\r'),
                '"' => try output.append(self.runtime.allocator, '"'),
                '\\' => try output.append(self.runtime.allocator, '\\'),
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

    pub fn appendUnicode(self: *TomlAotParser, output: *std.ArrayList(u8), digits: usize) !void {
        if (self.index + digits > self.input.len) return error.InvalidTomlEscape;
        const codepoint = std.fmt.parseInt(u21, self.input[self.index .. self.index + digits], 16) catch return error.InvalidTomlEscape;
        self.index += digits;
        if (!std.unicode.utf8ValidCodepoint(codepoint) or (codepoint >= 0xd800 and codepoint <= 0xdfff)) return error.InvalidTomlEscape;
        var buffer: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(codepoint, &buffer);
        try output.appendSlice(self.runtime.allocator, buffer[0..length]);
    }

    pub fn array(self: *TomlAotParser) !Value {
        self.index += 1;
        var result = try self.runtime.createArray(&.{});
        var roots = RootFrame{};
        self.runtime.pushRoots(&roots, @ptrCast(&result), 1);
        defer self.runtime.popRoots(&roots);
        self.skipValueSpace();
        if (self.consume(']')) return result;
        while (true) {
            const item = try self.value();
            try result.object().?.payload.array.append(self.runtime.allocator, item);
            self.skipValueSpace();
            if (self.consume(']')) return result;
            if (!self.consume(',')) return error.InvalidTomlArray;
            self.skipValueSpace();
            if (self.consume(']')) return result;
        }
    }

    pub fn inlineTable(self: *TomlAotParser) !Value {
        self.index += 1;
        var result = try self.runtime.createDictionary(&.{});
        var roots = RootFrame{};
        self.runtime.pushRoots(&roots, @ptrCast(&result), 1);
        defer self.runtime.popRoots(&roots);
        self.skipHorizontal();
        if (self.consume('}')) return result;
        while (true) {
            var path = try self.keyPath(.equal);
            defer path.deinit();
            var item = try self.value();
            var item_roots = RootFrame{};
            self.runtime.pushRoots(&item_roots, @ptrCast(&item), 1);
            defer self.runtime.popRoots(&item_roots);
            try self.assign(result, path.items.items, item);
            self.skipHorizontal();
            if (self.consume('}')) return result;
            if (!self.consume(',')) return error.InvalidTomlInlineTable;
            self.skipHorizontal();
        }
    }

    pub fn bareValue(self: *TomlAotParser) !Value {
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
        if (std.mem.eql(u8, token, "true")) return .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 };
        if (std.mem.eql(u8, token, "false")) return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
        if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "+inf")) return numberValue(std.math.inf(f64));
        if (std.mem.eql(u8, token, "-inf")) return numberValue(-std.math.inf(f64));
        if (std.mem.eql(u8, token, "nan") or std.mem.eql(u8, token, "+nan")) return numberValue(std.math.nan(f64));
        if (std.mem.eql(u8, token, "-nan")) return numberValue(-std.math.nan(f64));
        if (try toml_temporal.normalize(self.runtime.allocator, token)) |normalized_value| {
            var normalized = normalized_value;
            defer normalized.deinit();
            return self.runtime.createTomlTemporal(normalized.kind, normalized.text, normalized.text);
        }
        if (toml_temporal.looksLikeTemporal(token)) return runtimeUtf8String(self.runtime, token);
        const normalized = try tomlAotRemoveUnderscores(self.runtime.allocator, token);
        defer self.runtime.allocator.free(normalized);
        if (tomlAotParseInteger(normalized)) |integer| return numberValue(integer) else |_| {}
        const number = std.fmt.parseFloat(f64, normalized) catch return error.InvalidTomlValue;
        return numberValue(number);
    }

    pub fn table(self: *TomlAotParser, root: Value, path: []const []const u8, array_table: bool) !Value {
        var current = root;
        for (path, 0..) |segment, index| {
            const last = index + 1 == path.len;
            const existing = try tomlAotDictionaryGet(self.runtime, current.object().?.payload.dictionary.items, segment);
            if (last and array_table) {
                var array_value = existing orelse blk: {
                    const created = try self.runtime.createArray(&.{});
                    try tomlAotPut(self.runtime, current, segment, created);
                    break :blk created;
                };
                if (array_value.tag != @intFromEnum(Tag.array)) return error.InvalidTomlTable;
                const table_value = try self.runtime.createDictionary(&.{});
                var table_roots = [_]Value{ array_value, table_value };
                var roots = RootFrame{};
                self.runtime.pushRoots(&roots, &table_roots, table_roots.len);
                defer self.runtime.popRoots(&roots);
                try array_value.object().?.payload.array.append(self.runtime.allocator, table_value);
                return table_value;
            }
            if (existing) |found| {
                if (tomlAotIsTableDictionary(found)) {
                    current = found;
                } else if (tomlAotLastArrayDictionary(found)) |last_table| {
                    current = last_table;
                } else return error.InvalidTomlTable;
            } else {
                const created = try self.runtime.createDictionary(&.{});
                try tomlAotPut(self.runtime, current, segment, created);
                current = created;
            }
        }
        return current;
    }

    pub fn assign(self: *TomlAotParser, base: Value, path: []const []const u8, assigned_value: Value) !void {
        if (path.len == 0) return error.InvalidTomlKey;
        var current = base;
        for (path[0 .. path.len - 1]) |segment| {
            if (try tomlAotDictionaryGet(self.runtime, current.object().?.payload.dictionary.items, segment)) |found| {
                if (!tomlAotIsTableDictionary(found)) return error.InvalidTomlKey;
                current = found;
            } else {
                const created = try self.runtime.createDictionary(&.{});
                try tomlAotPut(self.runtime, current, segment, created);
                current = created;
            }
        }
        if (try tomlAotDictionaryGet(self.runtime, current.object().?.payload.dictionary.items, path[path.len - 1]) != null) return error.DuplicateTomlKey;
        try tomlAotPut(self.runtime, current, path[path.len - 1], assigned_value);
    }

    pub fn skipDocumentSpace(self: *TomlAotParser) void {
        while (self.index < self.input.len) switch (self.input[self.index]) {
            ' ', '\t', '\n', '\r' => self.index += 1,
            '#' => self.skipComment(),
            else => return,
        };
    }

    pub fn skipValueSpace(self: *TomlAotParser) void {
        while (self.index < self.input.len) switch (self.input[self.index]) {
            ' ', '\t', '\n', '\r' => self.index += 1,
            '#' => self.skipComment(),
            else => return,
        };
    }

    pub fn skipHorizontal(self: *TomlAotParser) void {
        while (self.index < self.input.len and (self.input[self.index] == ' ' or self.input[self.index] == '\t')) self.index += 1;
    }

    pub fn skipComment(self: *TomlAotParser) void {
        while (self.index < self.input.len and self.input[self.index] != '\n') self.index += 1;
    }

    pub fn consume(self: *TomlAotParser, byte: u8) bool {
        if (self.index >= self.input.len or self.input[self.index] != byte) return false;
        self.index += 1;
        return true;
    }
};

pub fn tomlAotDictionaryGet(runtime: *Runtime, entries: []const DictionaryEntry, key: []const u8) !?Value {
    for (entries) |entry| if (try tomlAotKeyEquals(runtime, entry.key, key)) return entry.value;
    return null;
}

pub fn tomlAotKeyEquals(runtime: *Runtime, key: Value, expected: []const u8) !bool {
    const actual = try tomlAotValueUtf8Alloc(runtime, key);
    defer runtime.allocator.free(actual);
    return std.mem.eql(u8, actual, expected);
}

pub fn tomlAotPut(runtime: *Runtime, dictionary: Value, key: []const u8, value: Value) !void {
    var rooted = [_]Value{ value, .{} };
    var roots = RootFrame{};
    runtime.pushRoots(&roots, &rooted, rooted.len);
    defer runtime.popRoots(&roots);
    rooted[1] = try runtimeUtf8String(runtime, key);
    try runtime.setDictionary(&dictionary.object().?.payload.dictionary, rooted[1], rooted[0]);
}

pub fn tomlAotParseInteger(token: []const u8) !f64 {
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

pub fn tomlAotRemoveUnderscores(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
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

pub fn tomlAotIsBareKey(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

pub fn tomlAotLastArrayDictionary(value: Value) ?Value {
    if (value.tag != @intFromEnum(Tag.array)) return null;
    const object = value.object() orelse return null;
    if (object.payload != .array or object.payload.array.items.len == 0) return null;
    const item = object.payload.array.items[object.payload.array.items.len - 1];
    return if (tomlAotIsTableDictionary(item)) item else null;
}

pub fn tomlAotIsTableDictionary(value: Value) bool {
    if (value.tag != @intFromEnum(Tag.dictionary)) return false;
    return value.object().?.toml_temporal == null;
}

pub fn tomlStringify(runtime: *Runtime, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.dictionary)) return error.DictionaryExpected;
    var rooted_source = source;
    var roots = RootFrame{};
    runtime.pushRoots(&roots, @ptrCast(&rooted_source), 1);
    defer runtime.popRoots(&roots);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);
    var active_dictionaries: std.AutoHashMapUnmanaged(*Object, void) = .empty;
    defer active_dictionaries.deinit(runtime.allocator);
    var active_arrays: std.AutoHashMapUnmanaged(*Object, void) = .empty;
    defer active_arrays.deinit(runtime.allocator);
    var path: std.ArrayList(Value) = .empty;
    defer path.deinit(runtime.allocator);
    try tomlAotWriteTable(runtime, &output, rooted_source.object().?, &path, false, &active_dictionaries, &active_arrays);
    return runtimeUtf8String(runtime, output.items);
}

pub fn tomlAotWriteTable(runtime: *Runtime, output: *std.ArrayList(u8), dictionary: *Object, path: *std.ArrayList(Value), emit_header: bool, active_dictionaries: *std.AutoHashMapUnmanaged(*Object, void), active_arrays: *std.AutoHashMapUnmanaged(*Object, void)) !void {
    if (active_dictionaries.contains(dictionary)) return error.CircularTomlValue;
    try active_dictionaries.put(runtime.allocator, dictionary, {});
    defer _ = active_dictionaries.remove(dictionary);
    if (emit_header) {
        try tomlAotWriteHeader(runtime, output, path.items, false);
        try output.append(runtime.allocator, '\n');
    }
    for (dictionary.payload.dictionary.items) |entry| {
        if (tomlAotIsTableDictionary(entry.value) or tomlAotIsArrayOfDictionaries(entry.value)) continue;
        try tomlAotWriteKey(runtime, output, entry.key);
        try output.appendSlice(runtime.allocator, " = ");
        try tomlAotWriteValue(runtime, output, entry.value, active_dictionaries, active_arrays);
        try output.append(runtime.allocator, '\n');
    }
    for (dictionary.payload.dictionary.items) |entry| {
        if (!tomlAotIsTableDictionary(entry.value) and !tomlAotIsArrayOfDictionaries(entry.value)) continue;
        if (output.items.len > 0 and output.items[output.items.len - 1] != '\n') try output.append(runtime.allocator, '\n');
        if (output.items.len > 0 and !(output.items.len >= 2 and output.items[output.items.len - 2] == '\n')) try output.append(runtime.allocator, '\n');
        try path.append(runtime.allocator, entry.key);
        defer _ = path.pop();
        if (tomlAotIsTableDictionary(entry.value)) {
            try tomlAotWriteTable(runtime, output, entry.value.object().?, path, true, active_dictionaries, active_arrays);
        } else {
            const array_object = entry.value.object().?;
            if (active_arrays.contains(array_object)) return error.CircularTomlValue;
            try active_arrays.put(runtime.allocator, array_object, {});
            defer _ = active_arrays.remove(array_object);
            for (array_object.payload.array.items, 0..) |item, index| {
                if (!tomlAotIsTableDictionary(item)) return error.UnsupportedTomlValue;
                if (index > 0) try output.append(runtime.allocator, '\n');
                try tomlAotWriteHeader(runtime, output, path.items, true);
                try output.append(runtime.allocator, '\n');
                try tomlAotWriteTable(runtime, output, item.object().?, path, false, active_dictionaries, active_arrays);
            }
        }
    }
}

pub fn tomlAotWriteHeader(runtime: *Runtime, output: *std.ArrayList(u8), path: []const Value, array_table: bool) !void {
    try output.appendSlice(runtime.allocator, if (array_table) "[[" else "[");
    for (path, 0..) |key, index| {
        if (index > 0) try output.append(runtime.allocator, '.');
        try tomlAotWriteKey(runtime, output, key);
    }
    try output.appendSlice(runtime.allocator, if (array_table) "]]" else "]");
}

pub fn tomlAotValueUtf8Alloc(runtime: *Runtime, value: Value) ![]u8 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
}

pub fn tomlAotWriteKey(runtime: *Runtime, output: *std.ArrayList(u8), key: Value) !void {
    const utf8 = try tomlAotValueUtf8Alloc(runtime, key);
    defer runtime.allocator.free(utf8);
    var bare = utf8.len > 0;
    for (utf8) |byte| bare = bare and tomlAotIsBareKey(byte);
    if (bare) return output.appendSlice(runtime.allocator, utf8);
    try tomlAotWriteQuoted(runtime, output, utf8);
}

pub fn tomlAotWriteValue(runtime: *Runtime, output: *std.ArrayList(u8), value: Value, active_dictionaries: *std.AutoHashMapUnmanaged(*Object, void), active_arrays: *std.AutoHashMapUnmanaged(*Object, void)) !void {
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .boolean => try output.appendSlice(runtime.allocator, if (value.payload != 0) "true" else "false"),
        .number => {
            const number: f64 = @bitCast(value.payload);
            if (std.math.isNan(number)) return output.appendSlice(runtime.allocator, "nan");
            if (std.math.isInf(number)) return output.appendSlice(runtime.allocator, if (number < 0) "-inf" else "inf");
            const text = if (std.math.isFinite(number) and @trunc(number) == number and number >= @as(f64, @floatFromInt(std.math.minInt(i64))) and number <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
                try std.fmt.allocPrint(runtime.allocator, "{d}", .{@as(i64, @intFromFloat(number))})
            else
                try std.fmt.allocPrint(runtime.allocator, "{d}", .{number});
            defer runtime.allocator.free(text);
            try output.appendSlice(runtime.allocator, text);
        },
        .static_utf8_string, .utf16_string => {
            const utf8 = try tomlAotValueUtf8Alloc(runtime, value);
            defer runtime.allocator.free(utf8);
            try tomlAotWriteQuoted(runtime, output, utf8);
        },
        .array => {
            const object = value.object() orelse return error.UnsupportedTomlValue;
            if (active_arrays.contains(object)) return error.CircularTomlValue;
            try active_arrays.put(runtime.allocator, object, {});
            defer _ = active_arrays.remove(object);
            try output.appendSlice(runtime.allocator, "[ ");
            for (object.payload.array.items, 0..) |item, index| {
                if (index > 0) try output.appendSlice(runtime.allocator, ", ");
                try tomlAotWriteValue(runtime, output, item, active_dictionaries, active_arrays);
            }
            try output.appendSlice(runtime.allocator, " ]");
        },
        .dictionary => {
            const object = value.object() orelse return error.UnsupportedTomlValue;
            if (object.toml_temporal) |temporal| return output.appendSlice(runtime.allocator, temporal.toml_text);
            if (active_dictionaries.contains(object)) return error.CircularTomlValue;
            try active_dictionaries.put(runtime.allocator, object, {});
            defer _ = active_dictionaries.remove(object);
            try output.appendSlice(runtime.allocator, "{ ");
            for (object.payload.dictionary.items, 0..) |entry, index| {
                if (index > 0) try output.appendSlice(runtime.allocator, ", ");
                try tomlAotWriteKey(runtime, output, entry.key);
                try output.appendSlice(runtime.allocator, " = ");
                try tomlAotWriteValue(runtime, output, entry.value, active_dictionaries, active_arrays);
            }
            try output.appendSlice(runtime.allocator, " }");
        },
        else => return error.UnsupportedTomlValue,
    }
}

pub fn tomlAotWriteQuoted(runtime: *Runtime, output: *std.ArrayList(u8), bytes: []const u8) !void {
    try output.append(runtime.allocator, '"');
    for (bytes) |byte| switch (byte) {
        '\n' => try output.appendSlice(runtime.allocator, "\\n"),
        '\r' => try output.appendSlice(runtime.allocator, "\\r"),
        '\t' => try output.appendSlice(runtime.allocator, "\\t"),
        '\\' => try output.appendSlice(runtime.allocator, "\\\\"),
        '"' => try output.appendSlice(runtime.allocator, "\\\""),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f, 0x7f => {
            const escaped = try std.fmt.allocPrint(runtime.allocator, "\\u{X:0>4}", .{byte});
            defer runtime.allocator.free(escaped);
            try output.appendSlice(runtime.allocator, escaped);
        },
        else => try output.append(runtime.allocator, byte),
    };
    try output.append(runtime.allocator, '"');
}

pub fn tomlAotIsArrayOfDictionaries(value: Value) bool {
    if (value.tag != @intFromEnum(Tag.array)) return false;
    const object = value.object() orelse return false;
    return switch (object.payload) {
        .array => |items| items.items.len > 0 and tomlAotIsTableDictionary(items.items[0]),
        else => false,
    };
}

pub fn markupBuiltin(runtime: *Runtime, command: aot_builtin.Command, value: Value) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const source = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
    defer runtime.allocator.free(source);
    const output = switch (command) {
        .markdown_to_html => try markup.markdownUtf8(runtime.allocator, source),
        .html_pretty => try markup.prettyHtmlUtf8(runtime.allocator, source),
        else => return error.UnknownCommand,
    };
    defer runtime.allocator.free(output);
    return runtimeUtf8String(runtime, output);
}

pub fn courtesyBuiltin(runtime: *Runtime, command: aot_builtin.Command) Value {
    switch (command) {
        .courtesy_increment => {
            if (!std.math.isFinite(runtime.courtesy_level) or runtime.courtesy_level == 0) runtime.courtesy_level = 0;
            runtime.courtesy_level += 1;
            return .{};
        },
        .courtesy_begin => {
            runtime.courtesy_level = 0;
            return .{};
        },
        .courtesy_end => {
            runtime.courtesy_level += 100;
            return .{};
        },
        .courtesy_level => {
            if (!std.math.isFinite(runtime.courtesy_level) or runtime.courtesy_level == 0) runtime.courtesy_level = 0;
            return numberValue(runtime.courtesy_level);
        },
        else => unreachable,
    }
}

pub fn systemExecutionBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    switch (command) {
        .system_execute => {
            if (arguments.len == 0) return .{};
            const candidate = arguments[arguments.len - 1];
            if (candidate.tag == @intFromEnum(Tag.function)) return invokeAotCallback(runtime, candidate, null, 0);
            if (isString(candidate)) {
                const callable = try resolveAotCallback(runtime, candidate);
                return invokeAotCallback(runtime, callable, null, 0);
            }
            return candidate;
        },
        .system_await_execute => {
            if (arguments.len < 2) return error.InvalidAwaitArguments;
            var roots = [_]Value{ arguments[0], arguments[1], .{} };
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            roots[0] = try resolveAotCallback(runtime, roots[0]);
            if (roots[1].tag == @intFromEnum(Tag.array)) {
                const call_arguments = try arrayItems(roots[1]);
                const pointer = if (call_arguments.items.len > 0) @as(?[*]const Value, call_arguments.items.ptr) else null;
                roots[2] = try invokeAotCallback(runtime, roots[0], pointer, call_arguments.items.len);
            } else roots[2] = try invokeAotCallback(runtime, roots[0], @ptrCast(&roots[1]), 1);
            roots[2] = try awaitAotPromise(runtime, roots[2]);
            return roots[2];
        },
        else => return error.UnknownCommand,
    }
}
