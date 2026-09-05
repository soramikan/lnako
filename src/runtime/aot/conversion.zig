const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const number_mod = shared.number_mod;
const string_mod = shared.string_mod;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const Object = aot_state.Object;
const ByteBuffer = aot_state.ByteBuffer;
const ByteKind = aot_state.ByteKind;
const BigInt = aot_state.BigInt;
const RootFrame = aot_state.RootFrame;
const AotPrimitiveHint = aot_state.AotPrimitiveHint;
const Arithmetic = aot_state.Arithmetic;
const ShiftOperator = aot_state.ShiftOperator;
const Comparison = aot_state.Comparison;
const numberValue = aot_state.numberValue;
const staticStringValue = aot_state.staticStringValue;
const invokeAotCallback = aot_state.invokeAotCallback;
const arrayPrototypeProperty = aot_state.arrayPrototypeProperty;
const arrayPrototypeBlocksStandard = aot_state.arrayPrototypeBlocksStandard;
const dictionaryPrototypeProperty = aot_state.dictionaryPrototypeProperty;
const dictionaryPrototypeBlocksStandard = aot_state.dictionaryPrototypeBlocksStandard;
const dictionaryOwnProperty = aot_state.dictionaryOwnProperty;
const jsonEncodeBuiltin = aot_state.jsonEncodeBuiltin;
const isAotHttpResponse = aot_state.isAotHttpResponse;
const safe_array_element_limit = aot_state.safe_array_element_limit;
const runtimeUtf8String = aot_state.runtimeUtf8String;

pub fn valueIndex(value: Value) ?usize {
    if (value.tag != @intFromEnum(Tag.number)) return null;
    const number: f64 = @bitCast(value.payload);
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number or number > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(number);
}

pub fn aotByteBufferAllowsStandardPrototype(value: Value) bool {
    const object = value.object() orelse return true;
    if (object.payload != .byte_buffer) return true;
    return switch (@as(Tag, @enumFromInt(object.prototype.tag))) {
        .null_value => false,
        .dictionary => !dictionaryPrototypeBlocksStandard(object.prototype),
        else => true,
    };
}

pub fn aotByteBufferScalarProperty(buffer: ByteBuffer, key: Value) ?Value {
    if (sameKey(key, staticStringValue("byteLength"))) return numberValue(@floatFromInt(buffer.bytes.len));
    if (sameKey(key, staticStringValue("byteOffset"))) {
        if (buffer.kind == .array_buffer) return null;
        return numberValue(@floatFromInt(buffer.byte_offset));
    }
    if (sameKey(key, staticStringValue("BYTES_PER_ELEMENT"))) {
        if (buffer.kind == .array_buffer) return null;
        return numberValue(1);
    }
    if (buffer.kind == .array_buffer) {
        if (sameKey(key, staticStringValue("maxByteLength"))) return numberValue(@floatFromInt(buffer.bytes.len));
        if (sameKey(key, staticStringValue("resizable")) or sameKey(key, staticStringValue("detached"))) {
            return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
        }
    }
    return null;
}

pub fn aotByteBufferReadOnlyProperty(kind: ByteKind, units: []const u16) bool {
    return (kind != .array_buffer and std.mem.eql(u16, units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) or
        std.mem.eql(u16, units, &.{ 'b', 'y', 't', 'e', 'L', 'e', 'n', 'g', 't', 'h' }) or
        std.mem.eql(u16, units, &.{ 'b', 'y', 't', 'e', 'O', 'f', 'f', 's', 'e', 't' }) or
        std.mem.eql(u16, units, &.{ 'B', 'Y', 'T', 'E', 'S', '_', 'P', 'E', 'R', '_', 'E', 'L', 'E', 'M', 'E', 'N', 'T' }) or
        std.mem.eql(u16, units, &.{ 'b', 'u', 'f', 'f', 'e', 'r' }) or
        std.mem.eql(u16, units, &.{ 'm', 'a', 'x', 'B', 'y', 't', 'e', 'L', 'e', 'n', 'g', 't', 'h' }) or
        std.mem.eql(u16, units, &.{ 'r', 'e', 's', 'i', 'z', 'a', 'b', 'l', 'e' }) or
        std.mem.eql(u16, units, &.{ 'd', 'e', 't', 'a', 'c', 'h', 'e', 'd' }) or
        std.mem.eql(u16, units, &.{ 'p', 'a', 'r', 'e', 'n', 't' }) or
        std.mem.eql(u16, units, &.{ 'o', 'f', 'f', 's', 'e', 't' });
}

pub fn valueToNumber(value: Value) f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .null_value => 0,
        .boolean => if (value.payload == 0) 0 else 1,
        .number => @bitCast(value.payload),
        else => std.math.nan(f64),
    };
}

pub fn valueToNumberRuntime(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => std.math.nan(f64),
        .null_value => 0,
        .boolean => if (value.payload == 0) 0 else 1,
        .number => @bitCast(value.payload),
        .static_utf8_string, .utf16_string => parseStringNumber(runtime, value),
        .bigint => error.CannotConvertBigIntToNumber,
        .byte_buffer, .array, .dictionary, .iterator, .function, .promise => valueToNumberRuntime(runtime, try valueToPrimitive(runtime, value, .number)),
        .binding_cell => unreachable,
    };
}

/// `Number(i['末尾'])` 相当。暗黙のBigInt数値変換は他の演算で拒否し、
/// 明示的な範囲終端の変換だけBigInt.toF64を許可する。
pub fn explicitRangeNumber(runtime: *Runtime, value: Value) !f64 {
    if (value.tag == @intFromEnum(Tag.bigint)) return value.object().?.payload.bigint.toF64();
    return valueToNumberRuntime(runtime, value);
}

pub fn valueToParseFloatRuntime(runtime: *Runtime, value: Value) !f64 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => @bitCast(value.payload),
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, value);
            defer runtime.allocator.free(units);
            break :blk string_mod.parseFloatNumber(runtime.allocator, units);
        },
        .bigint => error.CannotConvertBigIntToNumber,
        .byte_buffer, .array, .dictionary, .iterator, .function, .promise => valueToParseFloatRuntime(runtime, try valueToPrimitive(runtime, value, .string)),
        .binding_cell => unreachable,
        .undefined, .null_value, .boolean => std.math.nan(f64),
    };
}

pub fn parseStringNumber(runtime: *Runtime, value: Value) !f64 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const trimmed = string_mod.trimWhitespace(units);
    if (trimmed.len == 0) return 0;
    for (trimmed) |unit| if (unit > 0x7f) return std.math.nan(f64);
    const ascii = try runtime.allocator.alloc(u8, trimmed.len);
    defer runtime.allocator.free(ascii);
    for (trimmed, 0..) |unit, index| ascii[index] = @intCast(unit);
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

pub fn validDecimalNumber(text: []const u8) bool {
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

pub fn incrementNumber(runtime: *Runtime, value: Value) f64 {
    if (value.tag == @intFromEnum(Tag.bigint)) return value.object().?.payload.bigint.toF64();
    if (isString(value)) {
        const utf8 = stringUtf8Alloc(runtime, value) catch return std.math.nan(f64);
        defer runtime.allocator.free(utf8);
        const trimmed = std.mem.trim(u8, utf8, " \t\r\n\x0b\x0c");
        if (trimmed.len == 0) return 0;
        return std.fmt.parseFloat(f64, trimmed) catch std.math.nan(f64);
    }
    return valueToNumber(value);
}

pub fn incrementValue(runtime: *Runtime, old: Value, amount: Value) Value {
    const old_number: f64 = if (old.tag == @intFromEnum(Tag.undefined)) 0 else incrementNumber(runtime, old);
    return numberValue(old_number + incrementNumber(runtime, amount));
}

pub fn isString(value: Value) bool {
    return value.tag == @intFromEnum(Tag.static_utf8_string) or value.tag == @intFromEnum(Tag.utf16_string);
}

pub fn isObject(value: Value) bool {
    return value.tag == @intFromEnum(Tag.byte_buffer) or value.tag == @intFromEnum(Tag.array) or value.tag == @intFromEnum(Tag.dictionary) or
        value.tag == @intFromEnum(Tag.iterator) or value.tag == @intFromEnum(Tag.function) or value.tag == @intFromEnum(Tag.promise);
}

pub fn stringUtf8Alloc(runtime: *Runtime, value: Value) ![]u8 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .static_utf8_string => runtime.allocator.dupe(u8, staticUtf8(value)),
        .utf16_string => (string_mod.String{
            .allocator = runtime.allocator,
            .units = value.object().?.payload.utf16_string,
        }).toUtf8Lossy(runtime.allocator),
        else => error.ExpectedString,
    };
}

pub fn valueUtf16Alloc(runtime: *Runtime, value: Value) anyerror![]u16 {
    if (value.tag == @intFromEnum(Tag.utf16_string)) return runtime.allocator.dupe(u16, value.object().?.payload.utf16_string);
    const utf8 = switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => try runtime.allocator.dupe(u8, "undefined"),
        .null_value => try runtime.allocator.dupe(u8, "null"),
        .boolean => try runtime.allocator.dupe(u8, if (value.payload == 0) "false" else "true"),
        .number => try numberString(runtime.allocator, @bitCast(value.payload)),
        .static_utf8_string => try runtime.allocator.dupe(u8, staticUtf8(value)),
        .utf16_string => unreachable,
        .byte_buffer, .function, .promise => {
            // All object text conversion, including host objects with an own
            // custom `toString`/`valueOf`, goes through the same
            // ToPrimitive path used by arithmetic and comparisons.
            const primitive = try valueToPrimitive(runtime, value, .string);
            return valueUtf16Alloc(runtime, primitive);
        },
        .bigint => try value.object().?.payload.bigint.toString(runtime.allocator, 10),
        .array => {
            // `valueUtf16Alloc` is the AOT String(value) boundary. Resolve an
            // array's own custom ToPrimitive method before the ordinary join.
            const primitive = try valueToPrimitive(runtime, value, .string);
            return valueUtf16Alloc(runtime, primitive);
        },
        .dictionary => {
            // `valueUtf16Alloc` is the AOT String(value) boundary. Resolve a
            // dictionary's custom ToPrimitive result before falling back to
            // the ordinary object tag text.
            const primitive = try valueToPrimitive(runtime, value, .string);
            return valueUtf16Alloc(runtime, primitive);
        },
        .iterator => try runtime.allocator.dupe(u8, "[object Object]"),
        .binding_cell => unreachable,
    };
    defer runtime.allocator.free(utf8);
    return std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, utf8);
}

pub fn byteBufferUtf16Alloc(runtime: *Runtime, buffer: ByteBuffer) ![]u16 {
    return switch (buffer.kind) {
        .buffer => blk: {
            var string = try string_mod.String.fromUtf8Lossy(runtime.allocator, buffer.bytes);
            defer string.deinit();
            break :blk runtime.allocator.dupe(u16, string.units);
        },
        .uint8_array => blk: {
            var output: std.ArrayList(u8) = .empty;
            defer output.deinit(runtime.allocator);
            for (buffer.bytes, 0..) |byte, index| {
                if (index > 0) try output.append(runtime.allocator, ',');
                var number: [3]u8 = undefined;
                const rendered = std.fmt.bufPrint(&number, "{d}", .{byte}) catch unreachable;
                try output.appendSlice(runtime.allocator, rendered);
            }
            break :blk std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, output.items);
        },
        .array_buffer => std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "[object ArrayBuffer]"),
    };
}

pub fn functionStringUtf16Alloc(runtime: *Runtime, name: []const u8) ![]u16 {
    const utf8 = try std.fmt.allocPrint(runtime.allocator, "function {s}() {{ [native code] }}", .{name});
    defer runtime.allocator.free(utf8);
    return std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, utf8);
}

pub fn arrayUtf16Alloc(runtime: *Runtime, object: *Object) anyerror![]u16 {
    for (runtime.stringifying_arrays.items) |active| if (active == object) return runtime.allocator.alloc(u16, 0);
    try runtime.stringifying_arrays.append(runtime.allocator, object);
    defer _ = runtime.stringifying_arrays.pop();
    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    for (object.payload.array.items, 0..) |item, index| {
        if (index > 0) try output.append(runtime.allocator, ',');
        if (item.tag == @intFromEnum(Tag.undefined) or item.tag == @intFromEnum(Tag.null_value)) continue;
        const units = try valueUtf16Alloc(runtime, item);
        defer runtime.allocator.free(units);
        try output.appendSlice(runtime.allocator, units);
    }
    return output.toOwnedSlice(runtime.allocator);
}

pub fn isAotObjectValue(value: Value) bool {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .byte_buffer, .array, .dictionary, .iterator, .function, .promise => true,
        else => false,
    };
}

pub fn valueToPrimitive(runtime: *Runtime, value: Value, hint: AotPrimitiveHint) !Value {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .byte_buffer, .function, .promise => try hostObjectToPrimitive(runtime, value, hint),
        .array => try arrayToPrimitive(runtime, value, hint),
        .dictionary => try dictionaryToPrimitive(runtime, value, hint),
        .iterator => staticStringValue("[object Object]"),
        else => value,
    };
}

pub fn hostObjectToPrimitive(runtime: *Runtime, value: Value, hint: AotPrimitiveHint) !Value {
    const to_string_name: []const u16 = &.{ 't', 'o', 'S', 't', 'r', 'i', 'n', 'g' };
    const value_of_name: []const u16 = &.{ 'v', 'a', 'l', 'u', 'e', 'O', 'f' };
    const first = if (hint == .string) to_string_name else value_of_name;
    const second = if (hint == .string) value_of_name else to_string_name;

    var roots = [_]Value{ value, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const object = roots[0].object().?;

    for ([_][]const u16{ first, second }) |name| {
        const method = runtime.aotObjectOwnPropertyGetUnits(object, name) orelse aotCustomObjectPrototypeProperty(roots[0], name);
        if (method) |callable| {
            if (callable.tag == @intFromEnum(Tag.undefined) or callable.tag == @intFromEnum(Tag.null_value)) continue;
            if (callable.tag != @intFromEnum(Tag.function)) return error.NotCallable;
            roots[1] = try invokeAotCallback(runtime, callable, null, 0);
            if (!isAotObjectValue(roots[1])) return roots[1];
            continue;
        }
        // The host object's ordinary inherited toString is represented by
        // the existing default conversion.  It is selected only when no own
        // property shadows it, matching OrdinaryToPrimitive's method lookup.
        if (std.mem.eql(u16, name, to_string_name)) {
            return switch (@as(Tag, @enumFromInt(roots[0].tag))) {
                .byte_buffer => blk: {
                    const units = try byteBufferUtf16Alloc(runtime, object.payload.byte_buffer);
                    defer runtime.allocator.free(units);
                    break :blk try runtime.createString(units);
                },
                .function => blk: {
                    const units = try functionStringUtf16Alloc(runtime, object.payload.function.name);
                    defer runtime.allocator.free(units);
                    break :blk try runtime.createString(units);
                },
                .promise => staticStringValue("[object Promise]"),
                else => error.CannotConvertObjectToPrimitive,
            };
        }
    }
    return error.CannotConvertObjectToPrimitive;
}

/// Return only properties supplied by an explicitly assigned object
/// prototype.  The synthesized standard Buffer/TypedArray/ArrayBuffer
/// methods are deliberately excluded: hostObjectToPrimitive handles their
/// built-in conversion itself when no custom override exists.
pub fn aotCustomObjectPrototypeProperty(value: Value, key: []const u16) ?Value {
    const object = value.object() orelse return null;
    if (object.prototype.tag != @intFromEnum(Tag.dictionary)) return null;
    return dictionaryOwnProperty(object.prototype, key) orelse dictionaryPrototypeProperty(object.prototype, key);
}

pub fn arrayToPrimitive(runtime: *Runtime, value: Value, hint: AotPrimitiveHint) !Value {
    const to_string_name: []const u16 = &.{ 't', 'o', 'S', 't', 'r', 'i', 'n', 'g' };
    const value_of_name: []const u16 = &.{ 'v', 'a', 'l', 'u', 'e', 'O', 'f' };
    const first = if (hint == .string) to_string_name else value_of_name;
    const second = if (hint == .string) value_of_name else to_string_name;

    var roots = [_]Value{ value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    for ([_][]const u16{ first, second }) |name| {
        const method = runtime.aotArrayOwnPropertyGetUnits(roots[0].object().?, name) orelse arrayPrototypeProperty(roots[0], name);
        if (method) |callable| {
            if (callable.tag == @intFromEnum(Tag.undefined) or callable.tag == @intFromEnum(Tag.null_value)) continue;
            if (callable.tag != @intFromEnum(Tag.function)) return error.NotCallable;
            roots[1] = try invokeAotCallback(runtime, callable, null, 0);
            if (!isAotObjectValue(roots[1])) return roots[1];
            continue;
        }
        if (std.mem.eql(u16, name, to_string_name) and !arrayPrototypeBlocksStandard(roots[0])) {
            const units = try arrayUtf16Alloc(runtime, roots[0].object().?);
            defer runtime.allocator.free(units);
            return runtime.createString(units);
        }
    }
    return error.CannotConvertObjectToPrimitive;
}

pub fn dictionaryToPrimitive(runtime: *Runtime, value: Value, hint: AotPrimitiveHint) !Value {
    const to_string_name: []const u16 = &.{ 't', 'o', 'S', 't', 'r', 'i', 'n', 'g' };
    const value_of_name: []const u16 = &.{ 'v', 'a', 'l', 'u', 'e', 'O', 'f' };
    const first = if (hint == .string) to_string_name else value_of_name;
    const second = if (hint == .string) value_of_name else to_string_name;

    var roots = [_]Value{ value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    for ([_][]const u16{ first, second }) |name| {
        const method = dictionaryOwnProperty(roots[0], name) orelse dictionaryPrototypeProperty(roots[0], name);
        if (method) |callable| {
            if (callable.tag == @intFromEnum(Tag.undefined) or callable.tag == @intFromEnum(Tag.null_value)) continue;
            if (callable.tag != @intFromEnum(Tag.function)) return error.NotCallable;
            roots[1] = try invokeAotCallback(runtime, callable, null, 0);
            if (!isAotObjectValue(roots[1])) return roots[1];
            continue;
        }
        if (std.mem.eql(u16, name, to_string_name)) {
            return if (isAotHttpResponse(roots[0])) staticStringValue("[object Response]") else staticStringValue("[object Object]");
        }
    }
    return error.CannotConvertObjectToPrimitive;
}

pub fn stringEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    return std.mem.eql(u16, left_units, right_units);
}

pub fn stringOrder(runtime: *Runtime, left: Value, right: Value) !std.math.Order {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    return std.mem.order(u16, left_units, right_units);
}

pub fn strictEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    if (isString(left) and isString(right)) return stringEqual(runtime, left, right);
    if (left.tag != right.tag) return false;
    return switch (@as(Tag, @enumFromInt(left.tag))) {
        .undefined, .null_value => true,
        .boolean => (left.payload != 0) == (right.payload != 0),
        .number => blk: {
            const left_number: f64 = @bitCast(left.payload);
            const right_number: f64 = @bitCast(right.payload);
            break :blk !std.math.isNan(left_number) and !std.math.isNan(right_number) and left_number == right_number;
        },
        .bigint => BigInt.eql(left.object().?.payload.bigint, right.object().?.payload.bigint),
        .static_utf8_string, .utf16_string => unreachable,
        .byte_buffer => left.payload == right.payload,
        .array, .dictionary, .iterator, .function, .promise => left.payload == right.payload,
        .binding_cell => unreachable,
    };
}

/// Node's `assert.strictEqual` uses SameValue semantics rather than the
/// language `===` operator: NaN compares equal to NaN and signed zeroes stay
/// distinct. Objects retain reference identity just like strictEqual.
pub fn sameValue(runtime: *Runtime, left: Value, right: Value) !bool {
    if (isString(left) and isString(right)) return stringEqual(runtime, left, right);
    if (left.tag != right.tag) return false;
    if (@as(Tag, @enumFromInt(left.tag)) == .number) {
        const left_number: f64 = @bitCast(left.payload);
        const right_number: f64 = @bitCast(right.payload);
        if (std.math.isNan(left_number) and std.math.isNan(right_number)) return true;
        return @as(u64, @bitCast(left_number)) == @as(u64, @bitCast(right_number));
    }
    return strictEqual(runtime, left, right);
}

/// Array.prototype.includes uses SameValueZero: NaN matches NaN and signed
/// zeroes compare equal, while objects retain reference identity.
pub fn sameValueZero(runtime: *Runtime, left: Value, right: Value) !bool {
    if (isString(left) and isString(right)) return stringEqual(runtime, left, right);
    if (left.tag != right.tag) return false;
    return switch (@as(Tag, @enumFromInt(left.tag))) {
        .number => blk: {
            const left_number: f64 = @bitCast(left.payload);
            const right_number: f64 = @bitCast(right.payload);
            break :blk (std.math.isNan(left_number) and std.math.isNan(right_number)) or left_number == right_number;
        },
        else => strictEqual(runtime, left, right),
    };
}

pub fn abstractEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    if ((isString(left) and isString(right)) or left.tag == right.tag) return strictEqual(runtime, left, right);
    const left_tag: Tag = @enumFromInt(left.tag);
    const right_tag: Tag = @enumFromInt(right.tag);
    if ((left_tag == .undefined and right_tag == .null_value) or (left_tag == .null_value and right_tag == .undefined)) return true;
    if (isObject(left) and isObject(right)) return false;
    if (left_tag == .boolean) return abstractEqual(runtime, numberValue(if (left.payload == 0) 0 else 1), right);
    if (right_tag == .boolean) return abstractEqual(runtime, left, numberValue(if (right.payload == 0) 0 else 1));
    if (left_tag == .byte_buffer or left_tag == .array or left_tag == .dictionary or left_tag == .iterator or left_tag == .function or left_tag == .promise) return abstractEqual(runtime, try valueToPrimitive(runtime, left, .number), right);
    if (right_tag == .byte_buffer or right_tag == .array or right_tag == .dictionary or right_tag == .iterator or right_tag == .function or right_tag == .promise) return abstractEqual(runtime, left, try valueToPrimitive(runtime, right, .number));
    if (left_tag == .number and isString(right)) return @as(f64, @bitCast(left.payload)) == try valueToNumberRuntime(runtime, right);
    if (isString(left) and right_tag == .number) return try valueToNumberRuntime(runtime, left) == @as(f64, @bitCast(right.payload));
    if (left_tag == .bigint and isString(right)) return bigIntEqualsString(runtime, left.object().?.payload.bigint, right);
    if (isString(left) and right_tag == .bigint) return bigIntEqualsString(runtime, right.object().?.payload.bigint, left);
    if (left_tag == .bigint and right_tag == .number) return bigIntEqualsNumber(runtime, left.object().?.payload.bigint, @bitCast(right.payload));
    if (left_tag == .number and right_tag == .bigint) return bigIntEqualsNumber(runtime, right.object().?.payload.bigint, @bitCast(left.payload));
    return false;
}

pub fn relationalOrder(runtime: *Runtime, left: Value, right: Value) !?std.math.Order {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try valueToPrimitive(runtime, roots[0], .number);
    roots[3] = try valueToPrimitive(runtime, roots[1], .number);
    const left_primitive = roots[2];
    const right_primitive = roots[3];
    if (isString(left_primitive) and isString(right_primitive)) return @as(?std.math.Order, try stringOrder(runtime, left_primitive, right_primitive));
    const left_tag: Tag = @enumFromInt(left_primitive.tag);
    const right_tag: Tag = @enumFromInt(right_primitive.tag);
    if (left_tag == .bigint and right_tag == .bigint) return @as(?std.math.Order, BigInt.order(left_primitive.object().?.payload.bigint, right_primitive.object().?.payload.bigint));
    if (left_tag == .bigint and isString(right_primitive)) return compareBigIntString(runtime, left_primitive.object().?.payload.bigint, right_primitive);
    if (isString(left_primitive) and right_tag == .bigint) {
        const order = (try compareBigIntString(runtime, right_primitive.object().?.payload.bigint, left_primitive)) orelse return null;
        return invertOrder(order);
    }
    if (left_tag == .bigint) return compareBigIntNumber(runtime, left_primitive.object().?.payload.bigint, try valueToNumberRuntime(runtime, right_primitive));
    if (right_tag == .bigint) {
        const order = (try compareBigIntNumber(runtime, right_primitive.object().?.payload.bigint, try valueToNumberRuntime(runtime, left_primitive))) orelse return null;
        return invertOrder(order);
    }
    const left_number = try valueToNumberRuntime(runtime, left_primitive);
    const right_number = try valueToNumberRuntime(runtime, right_primitive);
    if (std.math.isNan(left_number) or std.math.isNan(right_number)) return null;
    return std.math.order(left_number, right_number);
}

pub fn deepEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    // plugin_system_math uses JSON.stringify only when the left operand is an
    // object. Preserve that asymmetric dispatch and let the shared AOT JSON
    // serializer provide omission, NaN, byte-buffer, and cycle semantics.
    if (isJsonStringifyObject(left)) {
        var roots = [_]Value{ left, right, .{}, .{} };
        var frame = RootFrame{};
        runtime.pushRoots(&frame, &roots, roots.len);
        defer runtime.popRoots(&frame);
        roots[2] = try jsonEncodeBuiltin(runtime, roots[0], false);
        roots[3] = try jsonEncodeBuiltin(runtime, roots[1], false);
        return strictEqual(runtime, roots[2], roots[3]);
    }
    return strictEqual(runtime, left, right);
}

pub fn isJsonStringifyObject(value: Value) bool {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .null_value, .byte_buffer, .array, .dictionary, .iterator, .promise => true,
        else => false,
    };
}

pub fn compareValues(runtime: *Runtime, operator: Comparison, left: Value, right: Value) !bool {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    return switch (operator) {
        .abstract_equal => abstractEqual(runtime, roots[0], roots[1]),
        .strict_equal => strictEqual(runtime, roots[0], roots[1]),
        .abstract_not_equal => !try abstractEqual(runtime, roots[0], roots[1]),
        .strict_not_equal => !try strictEqual(runtime, roots[0], roots[1]),
        .deep_equal => deepEqual(runtime, roots[0], roots[1]),
        .deep_not_equal => !try deepEqual(runtime, roots[0], roots[1]),
        .less, .less_equal, .greater, .greater_equal => blk: {
            const order = (try relationalOrder(runtime, roots[0], roots[1])) orelse break :blk false;
            break :blk switch (operator) {
                .less => order == .lt,
                .less_equal => order != .gt,
                .greater => order == .gt,
                .greater_equal => order != .lt,
                else => unreachable,
            };
        },
    };
}

pub fn numberString(allocator: std.mem.Allocator, number: f64) ![]u8 {
    return number_mod.toStringAlloc(allocator, number);
}

pub fn concat(runtime: *Runtime, left: Value, right: Value) !Value {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    const combined = try runtime.allocator.alloc(u16, left_units.len + right_units.len);
    @memcpy(combined[0..left_units.len], left_units);
    @memcpy(combined[left_units.len..], right_units);
    return runtime.ownString(combined);
}

pub fn bigIntArithmetic(runtime: *Runtime, operator: Arithmetic, left: Value, right: Value) !Value {
    if (left.tag != @intFromEnum(Tag.bigint) or right.tag != @intFromEnum(Tag.bigint)) return error.CannotMixBigIntAndNumber;
    const left_bigint = left.object().?.payload.bigint;
    const right_bigint = right.object().?.payload.bigint;
    const result = switch (operator) {
        .add => try left_bigint.add(runtime.allocator, right_bigint),
        .subtract => try left_bigint.sub(runtime.allocator, right_bigint),
        .multiply => try left_bigint.mul(runtime.allocator, right_bigint),
        .divide => try left_bigint.divTrunc(runtime.allocator, right_bigint),
        .remainder => try left_bigint.rem(runtime.allocator, right_bigint),
        .power => blk: {
            if (right_bigint.isNegative()) return error.NegativeBigIntExponent;
            break :blk try left_bigint.pow(runtime.allocator, right_bigint.toU32() catch return error.BigIntExponentTooLarge);
        },
        .integer_divide => return error.CannotConvertBigIntToNumber,
        .bit_and => try left_bigint.bitAnd(runtime.allocator, right_bigint),
        .bit_or => try left_bigint.bitOr(runtime.allocator, right_bigint),
        .bit_xor => try left_bigint.bitXor(runtime.allocator, right_bigint),
    };
    return runtime.ownBigInt(result);
}

pub fn arithmetic(runtime: *Runtime, operator: Arithmetic, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const hint: AotPrimitiveHint = if (operator == .add) .string else .number;
    roots[2] = try valueToPrimitive(runtime, roots[0], hint);
    roots[3] = try valueToPrimitive(runtime, roots[1], hint);
    const left_primitive = roots[2];
    const right_primitive = roots[3];
    if (left_primitive.tag == @intFromEnum(Tag.bigint) or right_primitive.tag == @intFromEnum(Tag.bigint)) {
        return bigIntArithmetic(runtime, operator, left_primitive, right_primitive);
    }
    const left_number = if (operator == .add) try valueToParseFloatRuntime(runtime, left_primitive) else try valueToNumberRuntime(runtime, left_primitive);
    const right_number = if (operator == .add) try valueToParseFloatRuntime(runtime, right_primitive) else try valueToNumberRuntime(runtime, right_primitive);
    const result: f64 = switch (operator) {
        .add => left_number + right_number,
        .subtract => left_number - right_number,
        .multiply => left_number * right_number,
        .divide => left_number / right_number,
        .remainder => @rem(left_number, right_number),
        .power => std.math.pow(f64, left_number, right_number),
        .integer_divide => @floor(left_number / right_number),
        .bit_and => @floatFromInt(toInt32(left_number) & toInt32(right_number)),
        .bit_or => @floatFromInt(toInt32(left_number) | toInt32(right_number)),
        .bit_xor => @floatFromInt(toInt32(left_number) ^ toInt32(right_number)),
    };
    return numberValue(result);
}

pub fn bigIntEqualsString(runtime: *Runtime, bigint: BigInt, string: Value) !bool {
    var converted = bigIntFromString(runtime, string) catch return false;
    defer converted.deinit();
    return BigInt.eql(bigint, converted);
}

pub fn compareBigIntString(runtime: *Runtime, bigint: BigInt, string: Value) !?std.math.Order {
    var converted = bigIntFromString(runtime, string) catch return null;
    defer converted.deinit();
    return BigInt.order(bigint, converted);
}

pub fn bigIntFromString(runtime: *Runtime, string: Value) !BigInt {
    const units = try valueUtf16Alloc(runtime, string);
    defer runtime.allocator.free(units);
    const trimmed = string_mod.trimWhitespace(units);
    const ascii = try runtime.allocator.alloc(u8, trimmed.len);
    defer runtime.allocator.free(ascii);
    for (trimmed, 0..) |unit, index| {
        if (unit > 0x7f) return error.InvalidBigInt;
        ascii[index] = @intCast(unit);
    }
    return BigInt.parseString(runtime.allocator, ascii);
}

pub fn shift(runtime: *Runtime, operator: ShiftOperator, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try valueToPrimitive(runtime, roots[0], .number);
    roots[3] = try valueToPrimitive(runtime, roots[1], .number);
    const left_primitive = roots[2];
    const right_primitive = roots[3];
    const left_is_bigint = left_primitive.tag == @intFromEnum(Tag.bigint);
    const right_is_bigint = right_primitive.tag == @intFromEnum(Tag.bigint);
    if (left_is_bigint or right_is_bigint) {
        if (!left_is_bigint or !right_is_bigint) return error.CannotMixBigIntAndNumber;
        if (operator == .right_unsigned) return error.UnsignedShiftOfBigInt;
        const left_bigint = left_primitive.object().?.payload.bigint;
        const amount = right_primitive.object().?.payload.bigint.toI64() catch return error.BigIntShiftTooLarge;
        const magnitude = if (amount < 0) @as(u64, @intCast(-(amount + 1))) + 1 else @as(u64, @intCast(amount));
        const shift_amount: usize = std.math.cast(usize, magnitude) orelse return error.BigIntShiftTooLarge;
        const shift_left = (operator == .left) != (amount < 0);
        const result = if (shift_left)
            try left_bigint.shiftLeft(runtime.allocator, shift_amount)
        else
            try left_bigint.shiftRight(runtime.allocator, shift_amount);
        return runtime.ownBigInt(result);
    }
    const amount: u5 = @truncate(toUint32(try valueToNumberRuntime(runtime, right_primitive)) & 31);
    const left_number = try valueToNumberRuntime(runtime, left_primitive);
    const shifted: f64 = switch (operator) {
        .left => @floatFromInt(toInt32(left_number) << amount),
        .right => @floatFromInt(toInt32(left_number) >> amount),
        .right_unsigned => @floatFromInt(toUint32(left_number) >> amount),
    };
    return numberValue(shifted);
}

pub fn bitNot(runtime: *Runtime, value: Value) !Value {
    var roots = [_]Value{ value, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try valueToPrimitive(runtime, roots[0], .number);
    const primitive = roots[1];
    if (primitive.tag == @intFromEnum(Tag.bigint)) {
        const result = try primitive.object().?.payload.bigint.bitNot(runtime.allocator);
        return runtime.ownBigInt(result);
    }
    return numberValue(@floatFromInt(~toInt32(try valueToNumberRuntime(runtime, primitive))));
}

pub fn valueTruthy(value: Value) bool {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined, .null_value => false,
        .boolean => value.payload != 0,
        .number => blk: {
            const number: f64 = @bitCast(value.payload);
            break :blk number != 0 and !std.math.isNan(number);
        },
        .static_utf8_string => staticUtf8(value).len != 0,
        .utf16_string => value.object().?.payload.utf16_string.len != 0,
        .bigint => !value.object().?.payload.bigint.isZero(),
        .byte_buffer, .array, .dictionary, .iterator, .function, .promise => true,
        .binding_cell => valueTruthy(value.object().?.payload.binding_cell),
    };
}

pub fn toInt32(number: f64) i32 {
    if (!std.math.isFinite(number) or number == 0) return 0;
    var value = @mod(@trunc(number), 4294967296.0);
    if (value < 0) value += 4294967296.0;
    if (value >= 2147483648.0) value -= 4294967296.0;
    return @intFromFloat(value);
}

pub fn toUint32(number: f64) u32 {
    if (!std.math.isFinite(number) or number == 0) return 0;
    var value = @mod(@trunc(number), 4294967296.0);
    if (value < 0) value += 4294967296.0;
    return @intFromFloat(value);
}

pub fn bigIntEqualsNumber(runtime: *Runtime, bigint: BigInt, number: f64) !bool {
    if (!std.math.isFinite(number) or @trunc(number) != number) return false;
    var converted = try BigInt.fromF64(runtime.allocator, number);
    defer converted.deinit();
    return BigInt.eql(bigint, converted);
}

pub fn compareBigIntNumber(runtime: *Runtime, bigint: BigInt, number: f64) !?std.math.Order {
    if (std.math.isNan(number)) return null;
    if (number == std.math.inf(f64)) return .lt;
    if (number == -std.math.inf(f64)) return .gt;
    var integer = try BigInt.fromF64(runtime.allocator, @trunc(number));
    defer integer.deinit();
    const integer_order = BigInt.order(bigint, integer);
    if (integer_order != .eq) return integer_order;
    const fraction = number - @trunc(number);
    if (fraction > 0) return .lt;
    if (fraction < 0) return .gt;
    return .eq;
}

pub fn invertOrder(order: std.math.Order) std.math.Order {
    return switch (order) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

pub fn repeatCount(number: f64) !usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.IteratorCountTooLarge;
    return @intFromFloat(@trunc(number));
}

pub fn sameKey(left: Value, right: Value) bool {
    const left_tag: Tag = @enumFromInt(left.tag);
    const right_tag: Tag = @enumFromInt(right.tag);
    if ((left_tag == .static_utf8_string or left_tag == .utf16_string) and
        (right_tag == .static_utf8_string or right_tag == .utf16_string))
    {
        if (left_tag == .static_utf8_string and right_tag == .static_utf8_string) return std.mem.eql(u8, staticUtf8(left), staticUtf8(right));
        if (left_tag == .static_utf8_string) return staticUtf8EqualsUtf16(staticUtf8(left), right.object().?.payload.utf16_string);
        if (right_tag == .static_utf8_string) return staticUtf8EqualsUtf16(staticUtf8(right), left.object().?.payload.utf16_string);
        return std.mem.eql(u16, left.object().?.payload.utf16_string, right.object().?.payload.utf16_string);
    }
    if (left.tag != right.tag) return false;
    return switch (@as(Tag, @enumFromInt(left.tag))) {
        .undefined, .null_value => true,
        .boolean, .number => left.payload == right.payload,
        .static_utf8_string => std.mem.eql(u8, staticUtf8(left), staticUtf8(right)),
        .utf16_string => std.mem.eql(u16, left.object().?.payload.utf16_string, right.object().?.payload.utf16_string),
        .bigint => BigInt.eql(left.object().?.payload.bigint, right.object().?.payload.bigint),
        .byte_buffer => left.payload == right.payload,
        .array, .dictionary, .iterator, .function, .promise => left.payload == right.payload,
        .binding_cell => unreachable,
    };
}

pub fn staticUtf8EqualsUtf16(text: []const u8, units: []const u16) bool {
    var text_index: usize = 0;
    var unit_index: usize = 0;
    while (text_index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[text_index]) catch return false;
        if (text_index + length > text.len) return false;
        const codepoint = std.unicode.utf8Decode(text[text_index .. text_index + length]) catch return false;
        text_index += length;
        if (codepoint <= 0xffff) {
            if (unit_index >= units.len or units[unit_index] != @as(u16, @intCast(codepoint))) return false;
            unit_index += 1;
        } else {
            if (unit_index + 1 >= units.len) return false;
            const offset = codepoint - 0x10000;
            if (units[unit_index] != @as(u16, @intCast(0xd800 + (offset >> 10))) or
                units[unit_index + 1] != @as(u16, @intCast(0xdc00 + (offset & 0x3ff)))) return false;
            unit_index += 2;
        }
    }
    return unit_index == units.len;
}

pub fn staticUtf8(value: Value) []const u8 {
    const pointer: [*:0]const u8 = @ptrFromInt(value.payload);
    return std.mem.span(pointer);
}
