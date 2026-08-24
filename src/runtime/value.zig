const std = @import("std");
const string_mod = @import("string.zig");
const bigint_mod = @import("bigint.zig");

pub const String = string_mod.String;
pub const BigInt = bigint_mod.BigInt;

pub const Value = union(enum) {
    undefined,
    null_value,
    boolean: bool,
    number: f64,
    bigint: *BigInt,
    string: *String,

    pub fn tagName(self: Value) []const u8 {
        return @tagName(self);
    }

    pub fn toBoolean(self: Value) bool {
        return switch (self) {
            .undefined, .null_value => false,
            .boolean => |value| value,
            .number => |value| value != 0 and !std.math.isNan(value),
            .bigint => |value| !value.isZero(),
            .string => |value| value.len() != 0,
        };
    }

    pub fn toNumber(self: Value, scratch_allocator: std.mem.Allocator) !f64 {
        return switch (self) {
            .undefined => std.math.nan(f64),
            .null_value => 0,
            .boolean => |value| if (value) 1 else 0,
            .number => |value| value,
            .bigint => error.CannotConvertBigIntToNumber,
            .string => |value| parseNumber(value.*, scratch_allocator),
        };
    }

    pub fn strictEqual(left: Value, right: Value) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .undefined, .null_value => true,
            .boolean => |value| value == right.boolean,
            .number => |value| !std.math.isNan(value) and !std.math.isNan(right.number) and value == right.number,
            .bigint => |value| BigInt.eql(value.*, right.bigint.*),
            .string => |value| String.eql(value.*, right.string.*),
        };
    }

    pub fn sameValue(left: Value, right: Value) bool {
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .number => |value| blk: {
                if (std.math.isNan(value) and std.math.isNan(right.number)) break :blk true;
                break :blk @as(u64, @bitCast(value)) == @as(u64, @bitCast(right.number));
            },
            else => strictEqual(left, right),
        };
    }

    pub fn abstractEqual(left: Value, scratch_allocator: std.mem.Allocator, right: Value) !bool {
        const left_tag = std.meta.activeTag(left);
        const right_tag = std.meta.activeTag(right);
        if (left_tag == right_tag) return strictEqual(left, right);
        if ((left_tag == .undefined and right_tag == .null_value) or (left_tag == .null_value and right_tag == .undefined)) return true;
        return switch (left) {
            .boolean => (Value{ .number = if (left.boolean) 1 else 0 }).abstractEqual(scratch_allocator, right),
            .number => switch (right) {
                .boolean => left.abstractEqual(scratch_allocator, .{ .number = if (right.boolean) 1 else 0 }),
                .string => left.number == try right.toNumber(scratch_allocator),
                .bigint => numberEqualsBigInt(left.number, scratch_allocator, right.bigint.*),
                else => false,
            },
            .string => switch (right) {
                .number => (try left.toNumber(scratch_allocator)) == right.number,
                .boolean => left.abstractEqual(scratch_allocator, .{ .number = if (right.boolean) 1 else 0 }),
                .bigint => stringEqualsBigInt(left.string.*, scratch_allocator, right.bigint.*),
                else => false,
            },
            .bigint => switch (right) {
                .number => numberEqualsBigInt(right.number, scratch_allocator, left.bigint.*),
                .string => stringEqualsBigInt(right.string.*, scratch_allocator, left.bigint.*),
                .boolean => left.abstractEqual(scratch_allocator, .{ .number = if (right.boolean) 1 else 0 }),
                else => false,
            },
            else => false,
        };
    }
};

/// GC導入前の値生成コンテキスト。オブジェクトのアドレスは安定しており、次段で同じAPIをGCヒープへ接続する。
pub const Runtime = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(backing_allocator: std.mem.Allocator) Runtime {
        return .{ .arena = .init(backing_allocator) };
    }

    pub fn deinit(self: *Runtime) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Runtime) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn stringUtf8(self: *Runtime, utf8: []const u8) !Value {
        const result = try self.allocator().create(String);
        result.* = try String.fromUtf8(self.allocator(), utf8);
        return .{ .string = result };
    }

    pub fn stringCodeUnits(self: *Runtime, units: []const u16) !Value {
        const result = try self.allocator().create(String);
        result.* = try String.fromCodeUnits(self.allocator(), units);
        return .{ .string = result };
    }

    pub fn bigIntLiteral(self: *Runtime, source: []const u8) !Value {
        const result = try self.allocator().create(BigInt);
        result.* = try BigInt.parseLiteral(self.allocator(), source);
        return .{ .bigint = result };
    }

    pub fn bigIntString(self: *Runtime, source: String) !Value {
        const trimmed = string_mod.trimWhitespace(source.units);
        var temporary = try String.fromCodeUnits(self.allocator(), trimmed);
        const utf8 = try temporary.toUtf8Lossy(self.allocator());
        const result = try self.allocator().create(BigInt);
        result.* = try BigInt.parseString(self.allocator(), utf8);
        return .{ .bigint = result };
    }

    pub fn ownBigInt(self: *Runtime, value: BigInt) !Value {
        const result = try self.allocator().create(BigInt);
        result.* = value;
        return .{ .bigint = result };
    }

    pub fn concatStrings(self: *Runtime, left: String, right: String) !Value {
        const result = try self.allocator().create(String);
        result.* = try left.concat(self.allocator(), right);
        return .{ .string = result };
    }

    pub fn valueToString(self: *Runtime, value: Value) !Value {
        return switch (value) {
            .undefined => self.stringUtf8("undefined"),
            .null_value => self.stringUtf8("null"),
            .boolean => |boolean| self.stringUtf8(if (boolean) "true" else "false"),
            .number => |number| blk: {
                const utf8 = try numberToStringAlloc(self.allocator(), number);
                break :blk self.stringUtf8(utf8);
            },
            .bigint => |bigint| blk: {
                const utf8 = try bigint.toString(self.allocator(), 10);
                break :blk self.stringUtf8(utf8);
            },
            .string => value,
        };
    }
};

pub fn parseNumber(value: String, scratch_allocator: std.mem.Allocator) !f64 {
    const trimmed_units = string_mod.trimWhitespace(value.units);
    if (trimmed_units.len == 0) return 0;
    for (trimmed_units) |unit| if (unit > 0x7f) return std.math.nan(f64);
    var ascii = try scratch_allocator.alloc(u8, trimmed_units.len);
    defer scratch_allocator.free(ascii);
    for (trimmed_units, 0..) |unit, index| ascii[index] = @intCast(unit);
    if (std.mem.eql(u8, ascii, "Infinity") or std.mem.eql(u8, ascii, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, ascii, "-Infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, ascii, "NaN")) return std.math.nan(f64);
    if (ascii.len >= 2 and ascii[0] == '0') {
        const prefix = std.ascii.toLower(ascii[1]);
        if (prefix == 'x' or prefix == 'o' or prefix == 'b') {
            const base: u8 = if (prefix == 'x') 16 else if (prefix == 'o') 8 else 2;
            if (ascii.len == 2) return std.math.nan(f64);
            var result: f64 = 0;
            for (ascii[2..]) |character| {
                const digit = std.fmt.charToDigit(character, base) catch return std.math.nan(f64);
                result = result * @as(f64, @floatFromInt(base)) + @as(f64, @floatFromInt(digit));
            }
            return result;
        }
    }
    if (!validDecimalNumber(ascii)) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, ascii) catch std.math.nan(f64);
}

pub fn numberToStringAlloc(allocator: std.mem.Allocator, value: f64) ![]u8 {
    if (std.math.isNan(value)) return allocator.dupe(u8, "NaN");
    if (value == std.math.inf(f64)) return allocator.dupe(u8, "Infinity");
    if (value == -std.math.inf(f64)) return allocator.dupe(u8, "-Infinity");
    if (value == 0) return allocator.dupe(u8, "0");
    var fixed_output: std.Io.Writer.Allocating = .init(allocator);
    defer fixed_output.deinit();
    try fixed_output.writer.print("{d}", .{value});
    const magnitude = @abs(value);
    if (magnitude >= 1e21 or magnitude < 1e-6) return fixedToScientific(allocator, fixed_output.written());
    return allocator.dupe(u8, fixed_output.written());
}

fn fixedToScientific(allocator: std.mem.Allocator, fixed: []const u8) ![]u8 {
    const negative = fixed.len > 0 and fixed[0] == '-';
    const digits_start: usize = @intFromBool(negative);
    const dot = std.mem.indexOfScalarPos(u8, fixed, digits_start, '.') orelse fixed.len;
    var first_nonzero = digits_start;
    while (first_nonzero < fixed.len and (fixed[first_nonzero] == '0' or fixed[first_nonzero] == '.')) first_nonzero += 1;
    if (first_nonzero == fixed.len) return allocator.dupe(u8, "0");
    const exponent: i64 = if (dot < first_nonzero)
        -@as(i64, @intCast(first_nonzero - dot))
    else
        @as(i64, @intCast(dot - first_nonzero - 1));
    var significant = try allocator.alloc(u8, fixed.len - first_nonzero);
    defer allocator.free(significant);
    var length: usize = 0;
    for (fixed[first_nonzero..]) |character| if (character != '.') {
        significant[length] = character;
        length += 1;
    };
    while (length > 1 and significant[length - 1] == '0') length -= 1;
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (negative) try output.writer.writeByte('-');
    try output.writer.writeByte(significant[0]);
    if (length > 1) {
        try output.writer.writeByte('.');
        try output.writer.writeAll(significant[1..length]);
    }
    try output.writer.writeByte('e');
    if (exponent >= 0) try output.writer.writeByte('+');
    try output.writer.print("{d}", .{exponent});
    return output.toOwnedSlice();
}

fn validDecimalNumber(text: []const u8) bool {
    var index: usize = 0;
    if (index < text.len and (text[index] == '+' or text[index] == '-')) index += 1;
    var digits: usize = 0;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) digits += 1;
    if (index < text.len and text[index] == '.') {
        index += 1;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) digits += 1;
    }
    if (digits == 0) return false;
    if (index < text.len and (text[index] == 'e' or text[index] == 'E')) {
        index += 1;
        if (index < text.len and (text[index] == '+' or text[index] == '-')) index += 1;
        const exponent_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        if (index == exponent_start) return false;
    }
    return index == text.len;
}

fn numberEqualsBigInt(number: f64, allocator: std.mem.Allocator, bigint: BigInt) !bool {
    var converted = BigInt.fromF64(allocator, number) catch return false;
    defer converted.deinit();
    return BigInt.eql(converted, bigint);
}

fn stringEqualsBigInt(string: String, allocator: std.mem.Allocator, bigint: BigInt) !bool {
    var trimmed = try String.fromCodeUnits(allocator, string_mod.trimWhitespace(string.units));
    defer trimmed.deinit();
    const utf8 = try trimmed.toUtf8Lossy(allocator);
    defer allocator.free(utf8);
    var converted = BigInt.parseString(allocator, utf8) catch return false;
    defer converted.deinit();
    return BigInt.eql(converted, bigint);
}

test "動的値の真偽変換と同値性をJS規則で扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const empty = try runtime.stringUtf8("");
    const zero_bigint = try runtime.bigIntLiteral("0n");
    try std.testing.expect(!Value.undefined.toBoolean());
    try std.testing.expect(!empty.toBoolean());
    try std.testing.expect(!zero_bigint.toBoolean());
    try std.testing.expect(!Value.strictEqual(.{ .number = std.math.nan(f64) }, .{ .number = std.math.nan(f64) }));
    try std.testing.expect(Value.sameValue(.{ .number = std.math.nan(f64) }, .{ .number = std.math.nan(f64) }));
    try std.testing.expect(!Value.sameValue(.{ .number = 0.0 }, .{ .number = -0.0 }));
}

test "文字列数値変換と抽象等価をJS規則で扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    const hex = try runtime.stringUtf8(" 0x10 ");
    const fullwidth_space = try runtime.stringUtf8("　42　");
    const invalid = try runtime.stringUtf8("12x");
    try std.testing.expectEqual(@as(f64, 16), try hex.toNumber(std.testing.allocator));
    try std.testing.expectEqual(@as(f64, 42), try fullwidth_space.toNumber(std.testing.allocator));
    try std.testing.expect(std.math.isNan(try invalid.toNumber(std.testing.allocator)));
    try std.testing.expect(try Value.abstractEqual(.{ .number = 16 }, std.testing.allocator, hex));
    const bigint = try runtime.bigIntLiteral("9007199254740993n");
    const bigint_string = try runtime.stringUtf8("9007199254740993");
    try std.testing.expect(try bigint.abstractEqual(std.testing.allocator, bigint_string));
}

test "数値文字列化の固定小数と指数表記境界をJSへ合わせる" {
    const cases = [_]struct { value: f64, expected: []const u8 }{
        .{ .value = -0.0, .expected = "0" },
        .{ .value = 0.000001, .expected = "0.000001" },
        .{ .value = 0.0000001, .expected = "1e-7" },
        .{ .value = 1e20, .expected = "100000000000000000000" },
        .{ .value = 1e21, .expected = "1e+21" },
    };
    for (cases) |case| {
        const actual = try numberToStringAlloc(std.testing.allocator, case.value);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}
