const std = @import("std");
const number_mod = @import("number.zig");

/// JavaScript's integer-indexed objects (`Buffer`/`Uint8Array`) inspect a
/// string property key before ordinary property creation.  A canonical
/// numeric index string either addresses an element (valid integer index) or
/// is ignored, while a non-canonical numeric-looking string such as "02" is
/// an ordinary own property.
pub const TypedArrayKey = union(enum) {
    index: u64,
    ignored,
    property,
};

const max_safe_integer: u64 = (1 << 53) - 1;

/// Classify a property key for a TypedArray.  `units` must be the UTF-16 key
/// text.  The caller supplies the scratch allocator used to reproduce
/// ECMAScript's ToNumber/ToString round trip for canonical numeric strings.
pub fn classifyAlloc(units: []const u16, scratch_allocator: std.mem.Allocator) !TypedArrayKey {
    if (units.len == 0) return .property;
    const first = units[0];
    if (first >= '0' and first <= '9') {
        // A decimal integer without a leading zero is its own canonical
        // string.  Values above the safe-integer range fall through to the
        // ToNumber/ToString check because binary64 rounding can change the
        // digits (for example "9007199254740993").
        if (units.len > 1 and first == '0' and units[1] >= '0' and units[1] <= '9') return .property;
        var index: u64 = 0;
        var digits_only = true;
        for (units) |unit| {
            if (unit < '0' or unit > '9') {
                digits_only = false;
                break;
            }
            index = std.math.mul(u64, index, 10) catch {
                digits_only = false;
                break;
            };
            index = std.math.add(u64, index, @as(u64, unit - '0')) catch {
                digits_only = false;
                break;
            };
        }
        if (digits_only and index <= max_safe_integer) return .{ .index = index };
    } else if (first == '-') {
        // "-0" is the one canonical numeric string that does not round-trip
        // through Number::toString, and every negative canonical integer is
        // an invalid integer index.  Values outside the safe range still
        // need the general check for the same rounding reason as above.
        if (units.len == 2 and units[1] == '0') return .ignored;
        if (units.len > 1 and units[1] >= '1' and units[1] <= '9') {
            var magnitude: u64 = 0;
            var digits_only = true;
            for (units[1..]) |unit| {
                if (unit < '0' or unit > '9') {
                    digits_only = false;
                    break;
                }
                magnitude = std.math.mul(u64, magnitude, 10) catch {
                    digits_only = false;
                    break;
                };
                magnitude = std.math.add(u64, magnitude, @as(u64, unit - '0')) catch {
                    digits_only = false;
                    break;
                };
            }
            if (digits_only and magnitude <= max_safe_integer) return .ignored;
        }
    } else if (first != 'I' and first != 'N' and first != '+' and first != '.') {
        return .property;
    }

    const text = try scratch_allocator.alloc(u8, units.len);
    defer scratch_allocator.free(text);
    for (units, 0..) |unit, index| {
        if (unit > 0x7f) return .property;
        text[index] = @intCast(unit);
    }
    if (std.mem.eql(u8, text, "-0")) return .ignored;
    const number = parseNumberText(text);
    const canonical = try number_mod.toStringAlloc(scratch_allocator, number);
    defer scratch_allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, text)) return .property;
    return valueKey(number);
}

/// TypedArrayの要素設定（`IntegerIndexedElementSet`）が要素へ格納する
/// ToUint8の結果。NaN・±0・±Infinityは0、それ以外は切り捨てて256で
/// 剰余を取る。呼び出し側は添字の有効性より先にToNumberを済ませる。
pub fn byteFromNumber(number: f64) u8 {
    if (!std.math.isFinite(number) or number == 0) return 0;
    return @intFromFloat(@mod(@trunc(number), 256));
}

fn valueKey(number: f64) TypedArrayKey {
    if (!std.math.isFinite(number)) return .ignored;
    if (number == 0) return if (std.math.signbit(number)) .ignored else .{ .index = 0 };
    if (number < 0 or @trunc(number) != number) return .ignored;
    if (number > @as(f64, @floatFromInt(max_safe_integer))) return .ignored;
    return .{ .index = @intFromFloat(number) };
}

/// The subset of ECMAScript ToNumber needed to compare a string with
/// Number::toString.  Hexadecimal and other non-decimal forms never match
/// the canonical decimal output, so treating them as NaN keeps them on the
/// ordinary-property path.
fn parseNumberText(text: []const u8) f64 {
    if (std.mem.eql(u8, text, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, text, "-Infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, text, "NaN")) return std.math.nan(f64);
    if (!validDecimalNumber(text)) return std.math.nan(f64);
    return std.fmt.parseFloat(f64, text) catch std.math.nan(f64);
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

test "TypedArrayの数値文字列キーを正準数値インデックスとして分類する" {
    const cases = [_]struct { text: []const u8, expected: TypedArrayKey }{
        .{ .text = "0", .expected = .{ .index = 0 } },
        .{ .text = "2", .expected = .{ .index = 2 } },
        .{ .text = "4294967294", .expected = .{ .index = 4294967294 } },
        .{ .text = "9007199254740991", .expected = .{ .index = 9007199254740991 } },
        .{ .text = "9007199254740992", .expected = .ignored },
        .{ .text = "4294967295", .expected = .{ .index = 4294967295 } },
        .{ .text = "100000000000000000000", .expected = .ignored },
        .{ .text = "99999999999999999999", .expected = .property },
        .{ .text = "02", .expected = .property },
        .{ .text = "00", .expected = .property },
        .{ .text = "2.0", .expected = .property },
        .{ .text = "1.5", .expected = .ignored },
        .{ .text = "0.5", .expected = .ignored },
        .{ .text = "1e-7", .expected = .ignored },
        .{ .text = "1e-6", .expected = .property },
        .{ .text = "1e3", .expected = .property },
        .{ .text = "1e+21", .expected = .ignored },
        .{ .text = "1e21", .expected = .property },
        .{ .text = "-1", .expected = .ignored },
        .{ .text = "-0", .expected = .ignored },
        .{ .text = "-0.0", .expected = .property },
        .{ .text = "-1.5", .expected = .ignored },
        .{ .text = "-Infinity", .expected = .ignored },
        .{ .text = "Infinity", .expected = .ignored },
        .{ .text = "NaN", .expected = .ignored },
        .{ .text = "+Infinity", .expected = .property },
        .{ .text = "0x2", .expected = .property },
        .{ .text = "", .expected = .property },
        .{ .text = "foo", .expected = .property },
        .{ .text = " 2", .expected = .property },
    };
    var units_buffer: [64]u16 = undefined;
    for (cases) |case| {
        std.debug.assert(case.text.len <= units_buffer.len);
        for (case.text, 0..) |character, index| units_buffer[index] = character;
        const actual = try classifyAlloc(units_buffer[0..case.text.len], std.testing.allocator);
        try std.testing.expect(std.meta.eql(actual, case.expected));
    }
}

test "TypedArray要素へ格納するToUint8" {
    try std.testing.expectEqual(@as(u8, 0), byteFromNumber(std.math.nan(f64)));
    try std.testing.expectEqual(@as(u8, 0), byteFromNumber(std.math.inf(f64)));
    try std.testing.expectEqual(@as(u8, 0), byteFromNumber(-std.math.inf(f64)));
    try std.testing.expectEqual(@as(u8, 0), byteFromNumber(0));
    try std.testing.expectEqual(@as(u8, 0), byteFromNumber(-0.0));
    try std.testing.expectEqual(@as(u8, 7), byteFromNumber(7));
    try std.testing.expectEqual(@as(u8, 44), byteFromNumber(300));
    try std.testing.expectEqual(@as(u8, 255), byteFromNumber(-1));
    try std.testing.expectEqual(@as(u8, 255), byteFromNumber(255.9));
}
