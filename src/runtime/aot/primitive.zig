const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const number_mod = shared.number_mod;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const BigInt = aot_state.BigInt;
const AotPrimitiveHint = aot_state.AotPrimitiveHint;
const numberValue = aot_state.numberValue;
const valueToNumber = aot_state.valueToNumber;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const valueToPrimitive = aot_state.valueToPrimitive;
const isString = aot_state.isString;
const strictEqual = aot_state.strictEqual;
const concat = aot_state.concat;
const bigIntArithmetic = aot_state.bigIntArithmetic;
const bigIntFromString = aot_state.bigIntFromString;
const codePointCount = aot_state.codePointCount;
const codePointLength = aot_state.codePointLength;
const parseFloatBuiltin = aot_state.parseFloatBuiltin;
const arrayItems = aot_state.arrayItems;
const safe_array_element_limit = aot_state.safe_array_element_limit;
const runtimeUtf8String = aot_state.runtimeUtf8String;
const staticUtf8 = aot_state.staticUtf8;
const indexOfUnitsBuiltin = aot_state.indexOfUnitsBuiltin;

pub fn addParsedBuiltin(runtime: *Runtime, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.bigint) and roots[1].tag != @intFromEnum(Tag.bigint)) {
        return numberValue(try parseFloatBuiltin(runtime, roots[0]) + try parseFloatBuiltin(runtime, roots[1]));
    }
    roots[2] = try toBigIntBuiltin(runtime, roots[0]);
    roots[3] = try toBigIntBuiltin(runtime, roots[1]);
    return bigIntArithmetic(runtime, .add, roots[2], roots[3]);
}

pub fn sumParsedBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len > 0 and arguments[0].tag == @intFromEnum(Tag.array)) {
        var total: f64 = 0;
        for (arguments[0].object().?.payload.array.items) |item| {
            const number = try parseFloatBuiltin(runtime, item);
            if (!std.math.isNan(number)) total += number;
        }
        return numberValue(total);
    }
    var has_bigint = false;
    for (arguments) |argument| if (argument.tag == @intFromEnum(Tag.bigint)) {
        has_bigint = true;
        break;
    };
    if (!has_bigint) {
        var total: f64 = 0;
        for (arguments) |argument| total += try parseFloatBuiltin(runtime, argument);
        return numberValue(total);
    }
    var roots = [_]Value{ try runtime.createBigInt("0n"), .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    for (arguments) |argument| {
        roots[1] = try toBigIntBuiltin(runtime, argument);
        roots[0] = try bigIntArithmetic(runtime, .add, roots[0], roots[1]);
    }
    return roots[0];
}

pub fn toBigIntBuiltin(runtime: *Runtime, value: Value) !Value {
    var roots = [_]Value{ value, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try valueToPrimitive(runtime, roots[0], .number);
    const primitive = roots[1];
    return switch (@as(Tag, @enumFromInt(primitive.tag))) {
        .bigint => primitive,
        .number => runtime.ownBigInt(try BigInt.fromF64(runtime.allocator, @bitCast(primitive.payload))),
        .static_utf8_string, .utf16_string => blk: {
            const converted = try bigIntFromString(runtime, primitive);
            break :blk try runtime.ownBigInt(converted);
        },
        .boolean => runtime.ownBigInt(try BigInt.init(runtime.allocator, @as(u1, @intCast(primitive.payload)))),
        .null_value => error.CannotConvertNullToBigInt,
        .undefined => error.CannotConvertUndefinedToBigInt,
        else => error.InvalidBigIntConversion,
    };
}

pub fn jsAdd(runtime: *Runtime, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try valueToPrimitive(runtime, roots[0], .number);
    roots[3] = try valueToPrimitive(runtime, roots[1], .number);
    if (isString(roots[2]) or isString(roots[3])) return concat(runtime, roots[2], roots[3]);
    if (roots[2].tag == @intFromEnum(Tag.bigint) or roots[3].tag == @intFromEnum(Tag.bigint)) return bigIntArithmetic(runtime, .add, roots[2], roots[3]);
    return numberValue(try valueToNumberRuntime(runtime, roots[2]) + try valueToNumberRuntime(runtime, roots[3]));
}

pub const CutResult = struct { result: Value, remainder: Value };

/// `切取` and `範囲切取` deliberately use two different lengths for a
/// delimiter: `indexOf` stringifies the argument, but the following
/// `substring(index + delimiter.length)` reads the original value's property.
/// Keep this helper in the AOT runtime so the generated executable does not
/// need a JavaScript compatibility layer.
pub fn cutLengthProperty(runtime: *Runtime, value: Value) !Value {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => error.CutUndefinedDelimiterLength,
        .null_value => error.CutNullDelimiterLength,
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk numberValue(@floatFromInt(units.len));
        },
        .array => numberValue(@floatFromInt(value.object().?.payload.array.items.len)),
        .byte_buffer => if (value.object().?.payload.byte_buffer.kind == .array_buffer) .{} else numberValue(@floatFromInt(value.object().?.payload.byte_buffer.bytes.len)),
        .function => numberValue(@floatFromInt(value.object().?.payload.function.arity)),
        .dictionary => dictionaryLengthValue(value),
        else => .{},
    };
}

pub fn dictionaryLengthValue(value: Value) Value {
    const entries = value.object().?.payload.dictionary.items;
    for (entries) |entry| {
        const is_length = switch (@as(Tag, @enumFromInt(entry.key.tag))) {
            .static_utf8_string => std.mem.eql(u8, staticUtf8(entry.key), "length"),
            .utf16_string => std.mem.eql(u16, entry.key.object().?.payload.utf16_string, &.{ 'l', 'e', 'n', 'g', 't', 'h' }),
            else => false,
        };
        if (is_length) return entry.value;
    }
    return .{};
}

pub fn cutEndIndex(runtime: *Runtime, match_index: usize, delimiter: Value, source_length: usize) !usize {
    const length = try cutLengthProperty(runtime, delimiter);
    const sum = try jsAdd(runtime, numberValue(@floatFromInt(match_index)), length);
    const number = try valueToNumberRuntime(runtime, sum);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(source_length))) return source_length;
    return @intFromFloat(@trunc(number));
}

pub fn cutBuiltin(runtime: *Runtime, source: Value, first: Value, last: ?Value, range: bool) !CutResult {
    var roots = [_]Value{ source, first, last orelse .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const source_units = try valueUtf16Alloc(runtime, roots[0]);
    defer runtime.allocator.free(source_units);
    const first_units = try valueUtf16Alloc(runtime, roots[1]);
    defer runtime.allocator.free(first_units);
    const first_index = indexOfUnitsBuiltin(source_units, first_units, 0);
    if (first_index == null) {
        if (range) {
            roots[3] = try runtime.createString(&.{});
            roots[4] = try runtime.createString(source_units);
        } else {
            roots[3] = try runtime.createString(source_units);
            roots[4] = try runtime.createString(&.{});
        }
        return .{ .result = roots[3], .remainder = roots[4] };
    }
    const first_start = first_index.?;
    const middle_start = try cutEndIndex(runtime, first_start, roots[1], source_units.len);
    if (!range) {
        roots[3] = try runtime.createString(source_units[0..first_start]);
        roots[4] = try runtime.createString(source_units[middle_start..]);
        return .{ .result = roots[3], .remainder = roots[4] };
    }

    // Delimiter B is converted only after A matched.  In particular, a null
    // or undefined B is harmless when A is absent, matching String#indexOf.
    const last_value = roots[2];
    const last_units = try valueUtf16Alloc(runtime, last_value);
    defer runtime.allocator.free(last_units);
    const prefix = source_units[0..first_start];
    const relative_last = indexOfUnitsBuiltin(source_units[middle_start..], last_units, 0);
    if (relative_last == null) {
        roots[3] = try runtime.createString(source_units[middle_start..]);
        roots[4] = try runtime.createString(prefix);
        return .{ .result = roots[3], .remainder = roots[4] };
    }
    const last_relative = relative_last.?;
    const last_end = middle_start + try cutEndIndex(runtime, last_relative, last_value, source_units.len - middle_start);
    roots[3] = try runtime.createString(source_units[middle_start .. middle_start + last_relative]);
    roots[4] = try runtime.createString(prefix);
    if (last_end < source_units.len) {
        const combined_len = std.math.add(usize, prefix.len, source_units.len - last_end) catch return error.StringTooLarge;
        const combined = try runtime.allocator.alloc(u16, combined_len);
        @memcpy(combined[0..prefix.len], prefix);
        @memcpy(combined[prefix.len..], source_units[last_end..]);
        roots[4] = try runtime.ownString(combined);
    }
    return .{ .result = roots[3], .remainder = roots[4] };
}

pub fn sequentialAddBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len == 0) return runtime.systemContext();
    if (arguments.len == 1) return arguments[0];
    var roots = [_]Value{ arguments[1], .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    for (arguments[2..]) |argument| roots[0] = try jsAdd(runtime, roots[0], argument);
    roots[1] = try jsAdd(runtime, roots[0], arguments[0]);
    return roots[1];
}

pub fn chrBuiltin(runtime: *Runtime, value: Value) !Value {
    if (value.tag != @intFromEnum(Tag.array)) return codePointStringBuiltin(runtime, try valueToNumberRuntime(runtime, value));
    var roots = [_]Value{ value, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    for (roots[0].object().?.payload.array.items) |item| {
        roots[2] = try codePointStringBuiltin(runtime, try valueToNumberRuntime(runtime, item));
        try roots[1].object().?.payload.array.append(runtime.allocator, roots[2]);
    }
    return roots[1];
}

pub fn codePointStringBuiltin(runtime: *Runtime, number: f64) !Value {
    if (!std.math.isFinite(number) or @trunc(number) != number or number < 0 or number > 0x10ffff) {
        const number_text = try number_mod.toStringAlloc(runtime.allocator, number);
        defer runtime.allocator.free(number_text);
        const message = try std.fmt.allocPrint(runtime.allocator, "Invalid code point {s}", .{number_text});
        defer runtime.allocator.free(message);
        runtime.setFailureText(message);
        return error.NakoException;
    }
    const codepoint: u21 = @intFromFloat(number);
    if (codepoint <= 0xffff) return runtime.createString(&.{@intCast(codepoint)});
    const offset: u32 = codepoint - 0x10000;
    return runtime.createString(&.{ @intCast(0xd800 + (offset >> 10)), @intCast(0xdc00 + (offset & 0x3ff)) });
}

pub fn ascBuiltin(runtime: *Runtime, value: Value) !Value {
    if (value.tag != @intFromEnum(Tag.array)) return numberValue(@floatFromInt(try firstCodePointBuiltin(runtime, value)));
    var roots = [_]Value{ value, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    for (roots[0].object().?.payload.array.items) |item| {
        try roots[1].object().?.payload.array.append(runtime.allocator, numberValue(@floatFromInt(try firstCodePointBuiltin(runtime, item))));
    }
    return roots[1];
}

pub fn firstCodePointBuiltin(runtime: *Runtime, value: Value) !u21 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    if (units.len == 0) return 0;
    if (units[0] >= 0xd800 and units[0] <= 0xdbff and units.len > 1 and units[1] >= 0xdc00 and units[1] <= 0xdfff) {
        return @intCast(0x10000 + ((@as(u32, units[0]) - 0xd800) << 10) + (@as(u32, units[1]) - 0xdc00));
    }
    return @intCast(units[0]);
}

pub fn stringInsertBuiltin(runtime: *Runtime, source_value: Value, position_value: Value, addition_value: Value) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const addition = try valueUtf16Alloc(runtime, addition_value);
    defer runtime.allocator.free(addition);
    var position = try valueToNumberRuntime(runtime, position_value);
    if (position <= 0) position = 1;
    const scalar_index = stringCollectionIndex(position - 1, codePointCount(source));
    const unit_index = codePointOffsetBuiltin(source, scalar_index);
    const output = try runtime.allocator.alloc(u16, source.len + addition.len);
    @memcpy(output[0..unit_index], source[0..unit_index]);
    @memcpy(output[unit_index .. unit_index + addition.len], addition);
    @memcpy(output[unit_index + addition.len ..], source[unit_index..]);
    return runtime.ownString(output);
}

pub fn stringSearchBuiltin(runtime: *Runtime, source_value: Value, start_value: Value, needle_value: Value) !f64 {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const needle = try valueUtf16Alloc(runtime, needle_value);
    defer runtime.allocator.free(needle);
    var start = try valueToNumberRuntime(runtime, start_value);
    if (start <= 0) start = 1;
    var index = start - 1;
    const source_count = codePointCount(source);
    const needle_count = codePointCount(needle);
    while (index < @as(f64, @floatFromInt(source_count))) : (index += 1) {
        const scalar_index = stringCollectionIndex(index, source_count);
        const unit_start = codePointOffsetBuiltin(source, scalar_index);
        const unit_end = codePointOffsetBuiltin(source, @min(source_count, scalar_index +| needle_count));
        if (std.mem.eql(u16, source[unit_start..unit_end], needle)) return index + 1;
    }
    return 0;
}

pub fn codePointOffsetBuiltin(units: []const u16, target: usize) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < units.len and count < target) : (count += 1) index += codePointLength(units, index);
    return index;
}

pub fn stringCollectionIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(@trunc(number));
}

pub fn appendBuiltin(runtime: *Runtime, source: Value, addition: Value, newline: bool) !Value {
    if (source.tag == @intFromEnum(Tag.array)) {
        try source.object().?.payload.array.append(runtime.allocator, addition);
        return source;
    }
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const addition_units = try valueUtf16Alloc(runtime, addition);
    defer runtime.allocator.free(addition_units);
    const extra: usize = @intFromBool(newline);
    const base_length = std.math.add(usize, source_units.len, addition_units.len) catch return error.StringTooLarge;
    const length = std.math.add(usize, base_length, extra) catch return error.StringTooLarge;
    const output = try runtime.allocator.alloc(u16, length);
    @memcpy(output[0..source_units.len], source_units);
    @memcpy(output[source_units.len .. source_units.len + addition_units.len], addition_units);
    if (newline) output[output.len - 1] = '\n';
    return runtime.ownString(output);
}

pub fn joinBuiltin(runtime: *Runtime, values: []const Value) !Value {
    var units: std.ArrayList(u16) = .empty;
    errdefer units.deinit(runtime.allocator);
    for (values) |value| switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined, .null_value => {},
        else => {
            const part = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(part);
            try units.appendSlice(runtime.allocator, part);
        },
    };
    return runtime.ownString(try units.toOwnedSlice(runtime.allocator));
}

/// `配列結合` is intentionally separate from `連結`.  The former delegates
/// to JavaScript's Array.join when its first value is an array, while the
/// official plugin also accepts other values by splitting their String form
/// at LF before joining.  `配列只結合` is the same operation with an empty
/// separator.
pub fn arrayJoinBuiltin(runtime: *Runtime, source: Value, separator: Value, only: bool) !Value {
    var separator_units: []const u16 = &.{};
    var allocated_separator: ?[]u16 = null;
    defer if (allocated_separator) |units| runtime.allocator.free(units);
    if (!only) {
        allocated_separator = try valueUtf16Alloc(runtime, separator);
        separator_units = allocated_separator.?;
    }

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    if (source.tag == @intFromEnum(Tag.array)) {
        const object = source.object() orelse return error.InvalidArray;
        if (object.payload != .array) return error.InvalidArray;
        for (object.payload.array.items, 0..) |item, index| {
            if (index > 0) try output.appendSlice(runtime.allocator, separator_units);
            if (item.tag == @intFromEnum(Tag.undefined) or item.tag == @intFromEnum(Tag.null_value)) continue;
            const item_units = try valueUtf16Alloc(runtime, item);
            defer runtime.allocator.free(item_units);
            try output.appendSlice(runtime.allocator, item_units);
        }
    } else {
        const source_units = try valueUtf16Alloc(runtime, source);
        defer runtime.allocator.free(source_units);
        // String(a).split("\n").join(separator) preserves empty pieces at
        // both ends, including the trailing piece after a final LF.
        var start: usize = 0;
        var first = true;
        for (source_units, 0..) |unit, index| {
            if (unit != '\n') continue;
            if (!first) try output.appendSlice(runtime.allocator, separator_units);
            try output.appendSlice(runtime.allocator, source_units[start..index]);
            start = index + 1;
            first = false;
        }
        if (!first) try output.appendSlice(runtime.allocator, separator_units);
        try output.appendSlice(runtime.allocator, source_units[start..]);
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn arraySearchBuiltin(runtime: *Runtime, source: Value, needle: Value) !f64 {
    if (source.tag != @intFromEnum(Tag.array)) return -1;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    for (object.payload.array.items, 0..) |item, index| {
        if (!runtime.aotArrayIsPresent(object, index)) continue;
        if (try strictEqual(runtime, item, needle)) return @floatFromInt(index);
    }
    return -1;
}
