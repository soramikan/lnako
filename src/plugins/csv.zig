const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const common = @import("system/common.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

const comma = [_]u16{','};
const tab = [_]u16{'\t'};
const crlf = [_]u16{ '\r', '\n' };
const DelimiterDefault = enum { comma, tab };

pub const State = struct {
    allocator: std.mem.Allocator,
    custom_delimiter: ?[]u16 = null,
    custom_eol: ?[]u16 = null,
    delimiter_default: DelimiterDefault = .comma,
    auto_convert_number: bool = true,

    pub fn init(allocator: std.mem.Allocator) State {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *State) void {
        if (self.custom_delimiter) |value| self.allocator.free(value);
        if (self.custom_eol) |value| self.allocator.free(value);
        self.* = undefined;
    }

    fn delimiter(self: State) []const u16 {
        return self.custom_delimiter orelse switch (self.delimiter_default) {
            .comma => &comma,
            .tab => &tab,
        };
    }

    fn eol(self: State) []const u16 {
        return self.custom_eol orelse &crlf;
    }

    fn useDelimiter(self: *State, value: DelimiterDefault) void {
        if (self.custom_delimiter) |owned| self.allocator.free(owned);
        self.custom_delimiter = null;
        self.delimiter_default = value;
    }

    fn setDelimiter(self: *State, value: []const u16) !void {
        const owned = try self.allocator.dupe(u16, value);
        if (self.custom_delimiter) |old| self.allocator.free(old);
        self.custom_delimiter = owned;
    }

    fn setEol(self: *State, value: []const u16) !void {
        const owned = try self.allocator.dupe(u16, value);
        if (self.custom_eol) |old| self.allocator.free(old);
        self.custom_eol = owned;
    }
};

pub fn call(runtime: *Runtime, state: *State, name: []const u8, arguments: []const Value) !?Value {
    const source = common.argument(arguments, 0);
    if (eql(name, "CSV取得")) {
        state.useDelimiter(.comma);
        return try parse(runtime, state.*, source);
    }
    if (eql(name, "TSV取得")) {
        state.useDelimiter(.tab);
        return try parse(runtime, state.*, source);
    }
    if (isAny(name, &.{ "表CSV変換", "CSV変換" })) {
        state.useDelimiter(.comma);
        return try stringify(runtime, state.*, source);
    }
    if (isAny(name, &.{ "表TSV変換", "TSV変換" })) {
        state.useDelimiter(.tab);
        return try stringify(runtime, state.*, source);
    }
    if (eql(name, "CSVオプション設定")) {
        try setOptions(runtime, state, source);
        return .undefined;
    }
    return null;
}

fn parse(runtime: *Runtime, state: State, source: Value) !Value {
    var rooted_source = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    var text = try runtime.valueToString(rooted_source);
    try roots.protect(&text);
    var normalized: std.ArrayList(u16) = .empty;
    defer normalized.deinit(runtime.allocator());
    var input_index: usize = 0;
    while (input_index < text.string.units.len) : (input_index += 1) {
        const unit = text.string.units[input_index];
        if (unit == '\r') {
            if (input_index + 1 < text.string.units.len and text.string.units[input_index + 1] == '\n') input_index += 1;
            try normalized.append(runtime.allocator(), '\n');
        } else try normalized.append(runtime.allocator(), unit);
    }
    while (normalized.items.len > 0 and isWhitespace(normalized.items[normalized.items.len - 1])) _ = normalized.pop();
    try normalized.append(runtime.allocator(), '\n');

    var result = try runtime.createArray();
    try roots.protect(&result);
    var row = try runtime.createArray();
    try roots.protect(&row);
    const delimiter = if (state.delimiter().len > 0) state.delimiter()[0] else ',';
    var cursor: usize = 0;
    while (cursor < normalized.items.len) {
        var current = normalized.items[cursor];
        if (current == delimiter) {
            try appendCell(runtime, row.array, &.{}, state.auto_convert_number);
            cursor += 1;
            continue;
        }
        if (current == '\n') {
            try appendCell(runtime, row.array, &.{}, state.auto_convert_number);
            _ = try result.array.push(row);
            row = try runtime.createArray();
            cursor += 1;
            continue;
        }
        while (cursor < normalized.items.len and isWhitespace(normalized.items[cursor]) and normalized.items[cursor] != '\n') cursor += 1;
        if (cursor >= normalized.items.len) break;
        current = normalized.items[cursor];
        if (current == delimiter) {
            try appendCell(runtime, row.array, &.{}, state.auto_convert_number);
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
            try appendCell(runtime, row.array, normalized.items[start..cursor], state.auto_convert_number);
            if (cursor < normalized.items.len and normalized.items[cursor] == '\n') {
                _ = try result.array.push(row);
                row = try runtime.createArray();
            }
            cursor += 1;
            continue;
        }
        if (cursor + 1 < normalized.items.len and normalized.items[cursor + 1] == '"') {
            try appendCell(runtime, row.array, &.{}, state.auto_convert_number);
            cursor += 2;
            continue;
        }
        cursor += 1;
        var quoted: std.ArrayList(u16) = .empty;
        defer quoted.deinit(runtime.allocator());
        while (cursor < normalized.items.len) {
            const first = normalized.items[cursor];
            const second = if (cursor + 1 < normalized.items.len) normalized.items[cursor + 1] else 0;
            if (first == '"' and second == '"') {
                try quoted.append(runtime.allocator(), '"');
                cursor += 2;
                continue;
            }
            if (first == '"') {
                cursor += 1;
                if (second == delimiter) {
                    cursor += 1;
                    try appendCell(runtime, row.array, quoted.items, state.auto_convert_number);
                    break;
                }
                if (second == '\n') {
                    cursor += 1;
                    try appendCell(runtime, row.array, quoted.items, state.auto_convert_number);
                    _ = try result.array.push(row);
                    row = try runtime.createArray();
                    break;
                }
                if (cursor < normalized.items.len) cursor += 1;
                continue;
            }
            try quoted.append(runtime.allocator(), first);
            cursor += 1;
        }
    }
    if (row.array.len() > 0) _ = try result.array.push(row);
    return result;
}

fn appendCell(runtime: *Runtime, row: *value_mod.Array, units: []const u16, auto_convert: bool) !void {
    if (auto_convert and isNumeric(units)) {
        var ascii = try runtime.allocator().alloc(u8, units.len);
        defer runtime.allocator().free(ascii);
        for (units, 0..) |unit, index| ascii[index] = @intCast(unit);
        _ = try row.push(.{ .number = std.fmt.parseFloat(f64, ascii) catch std.math.nan(f64) });
        return;
    }
    _ = try row.push(try runtime.stringCodeUnits(units));
}

fn stringify(runtime: *Runtime, state: State, source: Value) !Value {
    if (source == .undefined) return runtime.stringUtf8("");
    if (source != .array) return error.ArrayExpected;
    var rooted_source = source;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_source);
    var raw: std.ArrayList(u16) = .empty;
    defer raw.deinit(runtime.allocator());
    const delimiter = state.delimiter();
    for (source.array.items.items) |row| {
        if (row == .undefined) {
            try raw.appendSlice(runtime.allocator(), state.eol());
            continue;
        }
        if (row != .array) return error.ArrayExpected;
        for (row.array.items.items, 0..) |cell, column| {
            var cell_roots = runtime.rootFrame();
            defer cell_roots.deinit();
            if (column > 0) try raw.appendSlice(runtime.allocator(), delimiter);
            var converted = try quoteCell(runtime, cell, delimiter);
            try cell_roots.protect(&converted);
            try row.array.set(column, converted);
            try raw.appendSlice(runtime.allocator(), converted.string.units);
        }
        try raw.appendSlice(runtime.allocator(), state.eol());
    }
    var normalized: std.ArrayList(u16) = .empty;
    defer normalized.deinit(runtime.allocator());
    var index: usize = 0;
    while (index < raw.items.len) : (index += 1) {
        if (raw.items[index] == '\r') {
            if (index + 1 < raw.items.len and raw.items[index + 1] == '\n') index += 1;
            try normalized.appendSlice(runtime.allocator(), state.eol());
        } else if (raw.items[index] == '\n') {
            try normalized.appendSlice(runtime.allocator(), state.eol());
        } else try normalized.append(runtime.allocator(), raw.items[index]);
    }
    return runtime.stringCodeUnits(normalized.items);
}

fn quoteCell(runtime: *Runtime, source: Value, delimiter: []const u16) !Value {
    const text = try runtime.valueToString(source);
    const needs_quote = std.mem.indexOfScalar(u16, text.string.units, '\n') != null or
        std.mem.indexOfScalar(u16, text.string.units, '\r') != null or
        (delimiter.len > 0 and std.mem.indexOf(u16, text.string.units, delimiter) != null) or
        std.mem.indexOfScalar(u16, text.string.units, '"') != null;
    if (!needs_quote) return text;
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    try output.append(runtime.allocator(), '"');
    for (text.string.units) |unit| {
        if (unit == '"') try output.append(runtime.allocator(), '"');
        try output.append(runtime.allocator(), unit);
    }
    try output.append(runtime.allocator(), '"');
    return runtime.stringCodeUnits(output.items);
}

fn setOptions(runtime: *Runtime, state: *State, source: Value) !void {
    if (source != .dictionary) return;
    for (source.dictionary.keys(), source.dictionary.values()) |key, value| {
        const key_utf8 = try key.toUtf8Lossy(runtime.allocator());
        defer runtime.allocator().free(key_utf8);
        if (eql(key_utf8, "delimiter") or eql(key_utf8, "区切文字")) {
            const text = try runtime.valueToString(value);
            try state.setDelimiter(text.string.units);
        } else if (eql(key_utf8, "eol")) {
            const text = try runtime.valueToString(value);
            try state.setEol(text.string.units);
        } else if (eql(key_utf8, "auto_convert_number")) state.auto_convert_number = value.toBoolean();
    }
}

fn isNumeric(units: []const u16) bool {
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

fn isWhitespace(unit: u16) bool {
    return switch (unit) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x00a0, 0x3000 => true,
        else => false,
    };
}

fn isAny(name: []const u8, options: []const []const u8) bool {
    for (options) |option| if (eql(name, option)) return true;
    return false;
}

fn eql(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "CSVの引用・数値変換・設定とTSVを処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State.init(std.testing.allocator);
    defer state.deinit();
    var source = try runtime.stringUtf8("1,\"a,b\",3\n4,5,6");
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&source);
    var table = (try call(&runtime, &state, "CSV取得", &.{source})).?;
    try roots.protect(&table);
    try std.testing.expectEqual(@as(f64, 1), table.array.get(0).array.get(0).number);
    try std.testing.expectEqual(@as(usize, 3), table.array.get(0).array.len());
    const encoded = (try call(&runtime, &state, "表CSV変換", &.{table})).?;
    const utf8 = try encoded.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("1,\"a,b\",3\r\n4,5,6\r\n", utf8);
}
