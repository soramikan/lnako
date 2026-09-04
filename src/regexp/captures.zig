const std = @import("std");
const types = @import("types.zig");

pub fn resolveDecimalEscapes(expression: *types.Expression, capture_count: usize) anyerror!void {
    for (@constCast(expression.alternatives)) |*alternative| {
        for (@constCast(alternative.pieces)) |*piece| try resolveDecimalEscapesInAtom(&piece.atom, capture_count);
    }
}

fn resolveDecimalEscapesInAtom(atom: *types.Atom, capture_count: usize) anyerror!void {
    switch (atom.*) {
        .group => |group| try resolveDecimalEscapes(group.expression, capture_count),
        .assertion => |assertion| try resolveDecimalEscapes(assertion.expression, capture_count),
        .legacy_decimal_escape => |digits| {
            var decimal_value: usize = 0;
            for (digits) |digit| decimal_value = decimal_value * 10 + (digit - '0');
            if (decimal_value > 0 and decimal_value <= capture_count) {
                atom.* = .{ .backreference = decimal_value - 1 };
                return;
            }

            const octal_length = legacyOctalLength(digits);
            const code_unit = if (digits[0] > '7') digits[0] else blk: {
                var value: u16 = 0;
                for (digits[0..octal_length]) |digit| value = value * 8 + (digit - '0');
                break :blk value;
            };
            atom.* = .{ .legacy_octal_escape = .{ .code_unit = code_unit, .trailing = digits[octal_length..] } };
        },
        .unicode_decimal_escape => |digits| {
            var decimal_value: usize = 0;
            for (digits) |digit| decimal_value = decimal_value * 10 + (digit - '0');
            if (decimal_value == 0 or decimal_value > capture_count) return error.InvalidBackreference;
            atom.* = .{ .backreference = decimal_value - 1 };
        },
        else => {},
    }
}

fn legacyOctalLength(digits: []const u16) usize {
    const maximum = if (digits[0] <= '3') @min(digits.len, 3) else @min(digits.len, 2);
    var length: usize = 1;
    while (length < maximum and digits[length] >= '0' and digits[length] <= '7') : (length += 1) {}
    return length;
}

pub fn resolveNamedBackreferences(expression: *types.Expression, names: []const ?[]const u16) anyerror!void {
    for (@constCast(expression.alternatives)) |*alternative| {
        for (@constCast(alternative.pieces)) |*piece| try resolveNamedBackreferencesInAtom(&piece.atom, names);
    }
}

fn resolveNamedBackreferencesInAtom(atom: *types.Atom, names: []const ?[]const u16) anyerror!void {
    switch (atom.*) {
        .group => |group| try resolveNamedBackreferences(group.expression, names),
        .assertion => |assertion| try resolveNamedBackreferences(assertion.expression, names),
        .named_backreference => |name| {
            var resolved: ?usize = null;
            for (names, 0..) |candidate, index| if (candidate) |actual| {
                if (std.mem.eql(u16, actual, name)) {
                    resolved = index;
                    break;
                }
            };
            atom.* = .{ .backreference = resolved orelse return error.InvalidNamedBackreference };
        },
        else => {},
    }
}

pub fn namedCaptureIndex(compiled: *const types.Compiled, name: []const u16) ?usize {
    for (compiled.capture_names[0..compiled.capture_count], 0..) |candidate, index| if (candidate) |actual| {
        if (std.mem.eql(u16, actual, name)) return index;
    };
    return null;
}

pub fn isValidNamedCapture(name: []const u16) bool {
    if (name.len == 0) return false;
    var ascii = true;
    for (name) |unit| if (unit > 0x7f) {
        ascii = false;
        break;
    };
    if (!ascii) return true;
    const first = name[0];
    if (!((first >= 'A' and first <= 'Z') or (first >= 'a' and first <= 'z') or first == '_' or first == '$')) return false;
    for (name[1..]) |unit| {
        if (!((unit >= 'A' and unit <= 'Z') or (unit >= 'a' and unit <= 'z') or (unit >= '0' and unit <= '9') or unit == '_' or unit == '$')) return false;
    }
    return true;
}
