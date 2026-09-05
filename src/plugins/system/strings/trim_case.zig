const std = @import("std");
const value_mod = @import("../../../runtime/value.zig");
const string_mod = @import("../../../runtime/string.zig");
const common = @import("../common.zig");
const operators = @import("../../../runtime/operators.zig");
const unicode_case = @import("unicode_case");
const arrays_plugin = @import("../arrays.zig");
const strings = @import("../strings.zig");
const Value = strings.Value;
const Runtime = strings.Runtime;
const Context = strings.Context;
const CutResult = strings.CutResult;

const cutting_mod = @import("cutting.zig");
const core_mod = @import("core.zig");
const search_replace_mod = @import("search_replace.zig");
const trim_case_mod = @import("trim_case.zig");
const kana_mod = @import("kana.zig");
const format_mod = @import("format.zig");
const units_mod = @import("units.zig");

pub fn trim(runtime: *Runtime, source: Value, left_side: bool, right_side: bool) !Value {
    const units = (try core_mod.text(runtime, source)).units;
    var first: usize = 0;
    var last = units.len;
    if (left_side) {
        while (first < last and string_mod.isEcmaWhitespace(units[first])) : (first += 1) {}
    }
    if (right_side) {
        while (last > first and string_mod.isEcmaWhitespace(units[last - 1])) : (last -= 1) {}
    }
    return runtime.stringCodeUnits(units[first..last]);
}

pub fn unicodeCase(runtime: *Runtime, source: Value, uppercase: bool) !Value {
    const source_string = try core_mod.text(runtime, source);
    const units = source_string.units;
    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(runtime.allocator());
    var unit_index: usize = 0;
    while (unit_index < units.len) {
        const codepoint = source_string.codePointAt(unit_index).?;
        try codepoints.append(runtime.allocator(), codepoint);
        unit_index += if (codepoint > 0xffff) 2 else 1;
    }
    var output: std.ArrayList(u16) = .empty;
    defer output.deinit(runtime.allocator());
    for (codepoints.items, 0..) |codepoint, index| {
        if (!uppercase and codepoint == 0x03a3 and isFinalSigma(codepoints.items, index)) {
            try appendCodePoint(runtime.allocator(), &output, 0x03c2);
            continue;
        }
        const mapped = if (uppercase) unicode_case.upper(codepoint) else unicode_case.lower(codepoint);
        if (mapped) |values| {
            for (values) |value| try appendCodePoint(runtime.allocator(), &output, value);
        } else try appendCodePoint(runtime.allocator(), &output, codepoint);
    }
    return runtime.stringCodeUnits(output.items);
}

pub fn isFinalSigma(codepoints: []const u21, index: usize) bool {
    var before = index;
    var has_cased_before = false;
    while (before > 0) {
        before -= 1;
        if (unicode_case.isCaseIgnorable(codepoints[before])) continue;
        has_cased_before = unicode_case.isCased(codepoints[before]);
        break;
    }
    if (!has_cased_before) return false;
    var after = index + 1;
    while (after < codepoints.len) : (after += 1) {
        if (unicode_case.isCaseIgnorable(codepoints[after])) continue;
        return !unicode_case.isCased(codepoints[after]);
    }
    return true;
}

pub fn appendCodePoint(allocator: std.mem.Allocator, output: *std.ArrayList(u16), codepoint: u21) !void {
    if (codepoint <= 0xffff) return output.append(allocator, @intCast(codepoint));
    const offset: u32 = codepoint - 0x10000;
    try output.append(allocator, @intCast(0xd800 + (offset >> 10)));
    try output.append(allocator, @intCast(0xdc00 + (offset & 0x3ff)));
}

pub fn offsetRange(runtime: *Runtime, source: Value, first: u16, last: u16, offset: i32) !Value {
    const units = (try core_mod.text(runtime, source)).units;
    const output = try runtime.allocator().dupe(u16, units);
    defer runtime.allocator().free(output);
    for (output) |*unit| {
        if (unit.* >= first and unit.* <= last) unit.* = @intCast(@as(i32, unit.*) + offset);
    }
    return runtime.stringCodeUnits(output);
}

pub fn asciiFullWidth(runtime: *Runtime, source: Value, symbols: bool) !Value {
    const units = (try core_mod.text(runtime, source)).units;
    const output = try runtime.allocator().dupe(u16, units);
    defer runtime.allocator().free(output);
    for (output) |*unit| {
        if (symbols and unit.* == 0x20) unit.* = 0x3000 else if ((symbols and unit.* >= 0x21 and unit.* <= 0x7e) or (!symbols and ((unit.* >= 'A' and unit.* <= 'Z') or (unit.* >= 'a' and unit.* <= 'z') or (unit.* >= '0' and unit.* <= '9')))) unit.* += 0xfee0;
    }
    return runtime.stringCodeUnits(output);
}

pub fn fullWidthAscii(runtime: *Runtime, source: Value, symbols: bool) !Value {
    const units = (try core_mod.text(runtime, source)).units;
    const output = try runtime.allocator().dupe(u16, units);
    defer runtime.allocator().free(output);
    for (output) |*unit| {
        if (symbols and unit.* == 0x3000) unit.* = 0x20 else if ((symbols and unit.* >= 0xff00 and unit.* <= 0xff5f) or (!symbols and ((unit.* >= 0xff21 and unit.* <= 0xff3a) or (unit.* >= 0xff41 and unit.* <= 0xff5a) or (unit.* >= 0xff10 and unit.* <= 0xff19)))) unit.* -= 0xfee0;
    }
    return runtime.stringCodeUnits(output);
}

pub fn katakanaFullWidth(runtime: *Runtime, source: Value, context: ?Context) !Value {
    return kana_mod.mapKana(runtime, source, true, context);
}

pub fn katakanaHalfWidth(runtime: *Runtime, source: Value, context: ?Context) !Value {
    return kana_mod.mapKana(runtime, source, false, context);
}
