const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const unicode_case = shared.unicode_case;
const number_mod = shared.number_mod;
const string_mod = shared.string_mod;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const Object = aot_state.Object;
const ByteBuffer = aot_state.ByteBuffer;
const BigInt = aot_state.BigInt;
const RootFrame = aot_state.RootFrame;
const DictionaryEntry = aot_state.DictionaryEntry;
const CloneState = aot_state.CloneState;
const AotPrimitiveHint = aot_state.AotPrimitiveHint;
const numberValue = aot_state.numberValue;
const valueToNumber = aot_state.valueToNumber;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const valueToPrimitive = aot_state.valueToPrimitive;
const isString = aot_state.isString;
const isObject = aot_state.isObject;
const strictEqual = aot_state.strictEqual;
const abstractEqual = aot_state.abstractEqual;
const compareValues = aot_state.compareValues;
const relationalOrder = aot_state.relationalOrder;
const sameKey = aot_state.sameKey;
const staticUtf8 = aot_state.staticUtf8;
const staticUtf8EqualsUtf16 = aot_state.staticUtf8EqualsUtf16;
const staticStringValue = aot_state.staticStringValue;
const runtimeUtf8String = aot_state.runtimeUtf8String;
const runtimeUtf8StringLossy = aot_state.runtimeUtf8StringLossy;
const parseFloatBuiltin = aot_state.parseFloatBuiltin;
const jsAdd = aot_state.jsAdd;
const arithmetic = aot_state.arithmetic;
const codePointCount = aot_state.codePointCount;
const codePointLength = aot_state.codePointLength;
const codePointOffsetBuiltin = aot_state.codePointOffsetBuiltin;
const codePointStringBuiltin = aot_state.codePointStringBuiltin;
const stringCollectionIndex = aot_state.stringCollectionIndex;
const jsonEncodeBuiltin = aot_state.jsonEncodeBuiltin;
const jsonDecodeBuiltin = aot_state.jsonDecodeBuiltin;
const deepCloneBuiltin = aot_state.deepCloneBuiltin;
const deepCloneValue = aot_state.deepCloneValue;
const safe_array_element_limit = aot_state.safe_array_element_limit;
const explicitRangeNumber = aot_state.explicitRangeNumber;
const aotByteBufferAllowsStandardPrototype = aot_state.aotByteBufferAllowsStandardPrototype;
const aotByteBufferScalarProperty = aot_state.aotByteBufferScalarProperty;
const aotByteBufferReadOnlyProperty = aot_state.aotByteBufferReadOnlyProperty;
const utf16FailureMessageUtf8Alloc = aot_state.utf16FailureMessageUtf8Alloc;
const table_byte_buffer_buffer_enumerable_property_names = aot_state.table_byte_buffer_buffer_enumerable_property_names;
const tableInheritedProperty = aot_state.tableInheritedProperty;
const tableRowProperty = aot_state.tableRowProperty;
const stringEqual = aot_state.stringEqual;
const valueTruthy = aot_state.valueTruthy;
const appendUtf8Units = aot_state.appendUtf8Units;
const appendAsciiUnits = aot_state.appendAsciiUnits;
const indexOfUnitsBuiltin = aot_state.indexOfUnitsBuiltin;
const bigIntArithmetic = aot_state.bigIntArithmetic;
const sameValueZero = aot_state.sameValueZero;
const parseIntBuiltin = aot_state.parseIntBuiltin;

const ArrayRange = struct { start: usize, count: usize };

pub fn arrayItems(value: Value) !*std.ArrayList(Value) {
    if (value.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = value.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    return &object.payload.array;
}

/// JavaScript's Array splice uses ToIntegerOrInfinity for the start argument.
/// In particular, strings are converted with Number (not parseInt), NaN and
/// -Infinity become zero, and +Infinity becomes the current array length.
pub fn spliceIndexRuntime(runtime: *Runtime, value: Value, length: usize) !usize {
    return spliceIndexNumber(try valueToNumberRuntime(runtime, value), length);
}

pub fn spliceIndexNumber(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == -std.math.inf(f64)) return 0;
    if (number == std.math.inf(f64)) return length;
    const integer = @trunc(number);
    if (integer < 0) {
        const magnitude = @min(-integer, @as(f64, @floatFromInt(length)));
        return length - @as(usize, @intFromFloat(magnitude));
    }
    if (integer >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(integer);
}

pub fn spliceCountRuntime(runtime: *Runtime, value: Value, maximum: usize) !usize {
    return spliceCountNumber(try valueToNumberRuntime(runtime, value), maximum);
}

pub fn spliceCountNumber(number: f64, maximum: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (number == std.math.inf(f64)) return maximum;
    return @min(@as(usize, @intFromFloat(@min(@floor(number), @as(f64, @floatFromInt(maximum))))), maximum);
}

pub fn dictionaryOwnProperty(value: Value, key: []const u16) ?Value {
    if (value.tag != @intFromEnum(Tag.dictionary)) return null;
    const object = value.object() orelse return null;
    if (object.payload != .dictionary) return null;
    for (object.payload.dictionary.items) |entry| {
        const matches = switch (@as(Tag, @enumFromInt(entry.key.tag))) {
            .static_utf8_string => blk: {
                var units: [64]u16 = undefined;
                const utf8 = staticUtf8(entry.key);
                if (utf8.len > units.len) break :blk false;
                const converted = std.unicode.utf8ToUtf16Le(&units, utf8) catch break :blk false;
                break :blk std.mem.eql(u16, units[0..converted], key);
            },
            .utf16_string => std.mem.eql(u16, entry.key.object().?.payload.utf16_string, key),
            else => false,
        };
        if (matches) return entry.value;
    }
    return null;
}

pub fn dictionaryPrototypeProperty(value: Value, key: []const u16) ?Value {
    const object = value.object() orelse return null;
    if (object.payload != .dictionary) return null;
    var current = object.prototype;
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        if (current.tag == @intFromEnum(Tag.null_value) or current.tag == @intFromEnum(Tag.undefined)) return null;
        if (current.tag != @intFromEnum(Tag.dictionary)) return null;
        const prototype_object = current.object() orelse return null;
        if (prototype_object.payload != .dictionary) return null;
        if (dictionaryOwnProperty(current, key)) |property| return property;
        current = prototype_object.prototype;
    }
    return null;
}

pub fn dictionaryPrototypeBlocksStandard(value: Value) bool {
    const object = value.object() orelse return false;
    if (object.payload != .dictionary) return false;
    var current = object.prototype;
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        if (current.tag == @intFromEnum(Tag.null_value)) return true;
        if (current.tag == @intFromEnum(Tag.undefined)) return false;
        if (current.tag != @intFromEnum(Tag.dictionary)) return false;
        const prototype_object = current.object() orelse return false;
        if (prototype_object.payload != .dictionary) return false;
        current = prototype_object.prototype;
    }
    return true;
}

pub fn arrayPrototypeProperty(value: Value, key: []const u16) ?Value {
    if (value.tag != @intFromEnum(Tag.array)) return null;
    const object = value.object() orelse return null;
    if (object.payload != .array) return null;
    var current = object.prototype;
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        if (current.tag == @intFromEnum(Tag.null_value) or current.tag == @intFromEnum(Tag.undefined)) return null;
        if (current.tag != @intFromEnum(Tag.dictionary)) return null;
        if (dictionaryOwnProperty(current, key)) |property| return property;
        const prototype_object = current.object() orelse return null;
        if (prototype_object.payload != .dictionary) return null;
        current = prototype_object.prototype;
    }
    return null;
}

pub fn arrayPrototypeBlocksStandard(value: Value) bool {
    if (value.tag != @intFromEnum(Tag.array)) return false;
    const object = value.object() orelse return false;
    if (object.payload != .array) return false;
    var current = object.prototype;
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        if (current.tag == @intFromEnum(Tag.null_value)) return true;
        if (current.tag == @intFromEnum(Tag.undefined)) return false;
        if (current.tag != @intFromEnum(Tag.dictionary)) return false;
        const prototype_object = current.object() orelse return false;
        if (prototype_object.payload != .dictionary) return false;
        current = prototype_object.prototype;
    }
    return true;
}

pub fn dictionaryProperty(value: Value, key: []const u16) Value {
    return dictionaryOwnProperty(value, key) orelse dictionaryPrototypeProperty(value, key) orelse .{};
}

pub fn aotCanonicalArrayIndex(value: Value) ?usize {
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .number => {
            const number: f64 = @bitCast(value.payload);
            if (!std.math.isFinite(number) or number < 0 or number > 4_294_967_294 or @trunc(number) != number) return null;
            const index: usize = @intFromFloat(number);
            return if (index <= 4_294_967_294) index else null;
        },
        .bigint => {
            const integer = value.object().?.payload.bigint.toI64() catch return null;
            if (integer < 0) return null;
            const index = std.math.cast(usize, integer) orelse return null;
            return if (index <= 4_294_967_294) index else null;
        },
        else => {},
    }
    const units: []const u16 = switch (@as(Tag, @enumFromInt(value.tag))) {
        .static_utf8_string => {
            const text = staticUtf8(value);
            if (text.len == 0 or (text.len > 1 and text[0] == '0')) return null;
            var number: usize = 0;
            for (text) |unit| {
                if (unit < '0' or unit > '9') return null;
                number = std.math.mul(usize, number, 10) catch return null;
                number = std.math.add(usize, number, unit - '0') catch return null;
            }
            return if (number <= 4_294_967_294) number else null;
        },
        .utf16_string => value.object().?.payload.utf16_string,
        else => return null,
    };
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var number: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        number = std.math.mul(usize, number, 10) catch return null;
        number = std.math.add(usize, number, unit - '0') catch return null;
    }
    return if (number <= 4_294_967_294) number else null;
}

pub fn aotDictionaryOrder(runtime: *Runtime, entries: []const DictionaryEntry) ![]usize {
    const order = try runtime.allocator.alloc(usize, entries.len);
    for (order, 0..) |*entry, index| entry.* = index;
    std.sort.pdq(usize, order, entries, aotDictionaryOrderBefore);
    return order;
}

pub fn aotDictionaryOrderBefore(entries: []const DictionaryEntry, left_index: usize, right_index: usize) bool {
    const left = aotCanonicalArrayIndex(entries[left_index].key);
    const right = aotCanonicalArrayIndex(entries[right_index].key);
    return if (left) |left_number| if (right) |right_number| left_number < right_number else true else if (right != null) false else left_index < right_index;
}

const AotEnumerableDictionaryEntry = struct {
    key: Value,
    value: Value,
};

pub fn aotPropertyKeysEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    const left_units = try valueUtf16Alloc(runtime, left);
    defer runtime.allocator.free(left_units);
    const right_units = try valueUtf16Alloc(runtime, right);
    defer runtime.allocator.free(right_units);
    return std.mem.eql(u16, left_units, right_units);
}

pub fn aotEnumerableKeyWasYielded(runtime: *Runtime, yielded: []const Value, key: Value) !bool {
    for (yielded) |candidate| if (try aotPropertyKeysEqual(runtime, candidate, key)) return true;
    return false;
}

/// Collect a dictionary's enumerable own keys and custom prototype keys in
/// ECMAScript `for...in` order.  Standard prototype methods are non-enumerable
/// and are synthesized only by property lookup, not by this command.
pub fn aotEnumerableDictionaryEntries(runtime: *Runtime, source: Value) ![]AotEnumerableDictionaryEntry {
    var entries: std.ArrayList(AotEnumerableDictionaryEntry) = .empty;
    errdefer entries.deinit(runtime.allocator);
    var yielded: std.ArrayList(Value) = .empty;
    defer yielded.deinit(runtime.allocator);

    var current = source;
    var depth: usize = 0;
    while (depth < 256) : (depth += 1) {
        const object = current.object() orelse break;
        if (object.payload != .dictionary) break;
        const dictionary = object.payload.dictionary.items;
        const order = try aotDictionaryOrder(runtime, dictionary);
        defer runtime.allocator.free(order);
        for (order) |index| {
            const entry = dictionary[index];
            if (try aotEnumerableKeyWasYielded(runtime, yielded.items, entry.key)) continue;
            try yielded.append(runtime.allocator, entry.key);
            try entries.append(runtime.allocator, .{ .key = entry.key, .value = entry.value });
        }
        current = object.prototype;
    }
    return entries.toOwnedSlice(runtime.allocator);
}

pub fn aotPropertyKeyEqual(runtime: *Runtime, key: Value, units: []const u16) !bool {
    const key_units = try valueUtf16Alloc(runtime, key);
    defer runtime.allocator.free(key_units);
    return std.mem.eql(u16, key_units, units);
}

pub fn dictionaryKeysBuiltin(runtime: *Runtime, source: Value) !Value {
    var roots = [_]Value{ source, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    const result = &roots[1].object().?.payload.array;
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const entries = try aotEnumerableDictionaryEntries(runtime, roots[0]);
            defer runtime.allocator.free(entries);
            for (entries) |entry| {
                const units = try valueUtf16Alloc(runtime, entry.key);
                defer runtime.allocator.free(units);
                var key = try runtime.createString(units);
                var key_frame = RootFrame{};
                runtime.pushRoots(&key_frame, @ptrCast(&key), 1);
                defer runtime.popRoots(&key_frame);
                try result.append(runtime.allocator, key);
            }
        },
        .array => {
            const object = roots[0].object().?;
            const items = object.payload.array.items;
            for (items, 0..) |_, index| {
                if (!runtime.aotArrayIsPresent(object, index)) continue;
                var text: [32]u8 = undefined;
                const encoded = std.fmt.bufPrint(&text, "{d}", .{index}) catch return error.ArrayTooLarge;
                var units: [32]u16 = undefined;
                const unit_len = std.unicode.utf8ToUtf16Le(&units, encoded) catch return error.ArrayTooLarge;
                const key = try runtime.createString(units[0..unit_len]);
                try result.append(runtime.allocator, key);
            }
            for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.key);
        },
        .byte_buffer => {
            const buffer = roots[0].object().?.payload.byte_buffer;
            if (buffer.kind != .array_buffer) for (0..buffer.bytes.len) |index| {
                var text: [32]u8 = undefined;
                const encoded = std.fmt.bufPrint(&text, "{d}", .{index}) catch return error.ArrayTooLarge;
                var units: [32]u16 = undefined;
                const unit_len = std.unicode.utf8ToUtf16Le(&units, encoded) catch return error.ArrayTooLarge;
                const key = try runtime.createString(units[0..unit_len]);
                try result.append(runtime.allocator, key);
            };
            for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.key);
            if (buffer.kind == .buffer) for (table_byte_buffer_buffer_enumerable_property_names) |name| {
                var units: [128]u16 = undefined;
                const unit_len = std.unicode.utf8ToUtf16Le(&units, name) catch return error.InvalidUtf8;
                var key = try runtime.createString(units[0..unit_len]);
                var key_frame = RootFrame{};
                runtime.pushRoots(&key_frame, @ptrCast(&key), 1);
                defer runtime.popRoots(&key_frame);
                try result.append(runtime.allocator, key);
            };
        },
        .function => for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.key),
        .promise => for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.key),
        else => return error.DictionaryKeysReceiver,
    }
    return roots[1];
}

pub fn dictionaryValuesBuiltin(runtime: *Runtime, source: Value) !Value {
    var roots = [_]Value{ source, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try runtime.createArray(&.{});
    const result = &roots[1].object().?.payload.array;
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const entries = try aotEnumerableDictionaryEntries(runtime, roots[0]);
            defer runtime.allocator.free(entries);
            for (entries) |entry| try result.append(runtime.allocator, entry.value);
        },
        .array => {
            const object = roots[0].object().?;
            for (object.payload.array.items, 0..) |item, index| {
                if (runtime.aotArrayIsPresent(object, index)) try result.append(runtime.allocator, item);
            }
            for (object.array_properties.items) |property| try result.append(runtime.allocator, property.value);
        },
        .byte_buffer => {
            const buffer = roots[0].object().?.payload.byte_buffer;
            if (buffer.kind != .array_buffer) for (buffer.bytes) |byte| try result.append(runtime.allocator, numberValue(@floatFromInt(byte)));
            for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.value);
            if (buffer.kind == .buffer) for (table_byte_buffer_buffer_enumerable_property_names) |name| {
                var property: Value = undefined;
                if (std.mem.eql(u8, name, "parent")) {
                    property = try runtime.createByteBufferBackingBuffer(buffer);
                } else if (std.mem.eql(u8, name, "offset")) {
                    property = numberValue(@floatFromInt(buffer.byte_offset));
                } else {
                    var units: [128]u16 = undefined;
                    const unit_len = std.unicode.utf8ToUtf16Le(&units, name) catch return error.InvalidUtf8;
                    property = (try tableInheritedProperty(runtime, roots[0], .byte_buffer, units[0..unit_len])) orelse .{};
                }
                var property_frame = RootFrame{};
                runtime.pushRoots(&property_frame, @ptrCast(&property), 1);
                defer runtime.popRoots(&property_frame);
                try result.append(runtime.allocator, property);
            };
        },
        .function => for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.value),
        .promise => for (roots[0].object().?.array_properties.items) |property| try result.append(runtime.allocator, property.value),
        else => return error.DictionaryValuesReceiver,
    }
    return roots[1];
}

pub fn dictionaryRemoveBuiltin(runtime: *Runtime, source: Value, key: Value) !Value {
    var roots = [_]Value{ source, key };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const entries = &roots[0].object().?.payload.dictionary;
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            for (entries.items, 0..) |entry, index| if (try aotPropertyKeyEqual(runtime, entry.key, key_units)) {
                _ = entries.orderedRemove(index);
                break;
            };
            return roots[0];
        },
        .array => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthDelete;
            if (runtime.aotCanonicalArrayIndexUnits(key_units)) |index| {
                _ = try runtime.aotArrayDeleteIndex(roots[0].object().?, index);
            } else {
                const properties = &roots[0].object().?.array_properties;
                for (properties.items, 0..) |property, index| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) {
                    _ = properties.orderedRemove(index);
                    break;
                };
            }
            return roots[0];
        },
        .byte_buffer => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            const buffer = roots[0].object().?.payload.byte_buffer;
            if (buffer.kind != .array_buffer) if (runtime.aotCanonicalArrayIndexUnits(key_units)) |index| {
                if (index < buffer.bytes.len) {
                    try byteBufferIndexDeleteFailure(runtime, key_units);
                    return error.ByteBufferIndexDelete;
                }
            };
            const properties = &roots[0].object().?.array_properties;
            for (properties.items, 0..) |property, index| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) {
                _ = properties.orderedRemove(index);
                break;
            };
            return roots[0];
        },
        .function => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or std.mem.eql(u16, key_units, &.{ 'n', 'a', 'm', 'e' })) return roots[0];
            const properties = &roots[0].object().?.array_properties;
            for (properties.items, 0..) |property, index| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) {
                _ = properties.orderedRemove(index);
                break;
            };
            return roots[0];
        },
        .promise => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            const properties = &roots[0].object().?.array_properties;
            for (properties.items, 0..) |property, index| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) {
                _ = properties.orderedRemove(index);
                break;
            };
            return roots[0];
        },
        else => return error.DictionaryRemoveReceiver,
    }
}

pub fn byteBufferIndexDeleteFailure(runtime: *Runtime, key_units: []const u16) !void {
    const key_utf8 = try utf16FailureMessageUtf8Alloc(runtime.allocator, key_units);
    defer runtime.allocator.free(key_utf8);
    const message = try std.fmt.allocPrint(runtime.allocator, "Cannot delete property '{s}' of [object Uint8Array]", .{key_utf8});
    defer runtime.allocator.free(message);
    runtime.setFailureText(message);
}

pub fn dictionaryHasBuiltin(runtime: *Runtime, source: Value, key: Value) !bool {
    var roots = [_]Value{ source, key };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    switch (@as(Tag, @enumFromInt(roots[0].tag))) {
        .dictionary => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            for (roots[0].object().?.payload.dictionary.items) |entry| if (try aotPropertyKeyEqual(runtime, entry.key, key_units)) return true;
            return (try tableInheritedProperty(runtime, roots[0], .dictionary, key_units)) != null;
        },
        .array => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return true;
            if (runtime.aotCanonicalArrayIndexUnits(key_units)) |index| {
                return runtime.aotArrayIsPresent(roots[0].object().?, index);
            }
            for (roots[0].object().?.array_properties.items) |property| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) return true;
            return (try tableInheritedProperty(runtime, roots[0], .array, key_units)) != null;
        },
        .function => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            for (roots[0].object().?.array_properties.items) |property| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) return true;
            if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or std.mem.eql(u16, key_units, &.{ 'n', 'a', 'm', 'e' })) return true;
            return (try tableInheritedProperty(runtime, roots[0], .function, key_units)) != null;
        },
        .byte_buffer => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            const object = roots[0].object() orelse return error.InvalidByteBuffer;
            const buffer = object.payload.byte_buffer;
            for (object.array_properties.items) |property| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) return true;
            if (buffer.kind != .array_buffer) {
                if (aotByteBufferAllowsStandardPrototype(roots[0]) and std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return true;
                if (runtime.aotCanonicalArrayIndexUnits(key_units)) |index| return index < buffer.bytes.len;
            }
            return (try tableInheritedProperty(runtime, roots[0], .byte_buffer, key_units)) != null;
        },
        .promise => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            for (roots[0].object().?.array_properties.items) |property| if (runtime.aotPropertyKeyMatchesUnits(property.key, key_units)) return true;
            return false;
        },
        else => {
            const key_units = try valueUtf16Alloc(runtime, roots[1]);
            defer runtime.allocator.free(key_units);
            const receiver_units = try valueUtf16Alloc(runtime, roots[0]);
            defer runtime.allocator.free(receiver_units);
            const key_utf8 = try utf16FailureMessageUtf8Alloc(runtime.allocator, key_units);
            defer runtime.allocator.free(key_utf8);
            const receiver_utf8 = try utf16FailureMessageUtf8Alloc(runtime.allocator, receiver_units);
            defer runtime.allocator.free(receiver_utf8);
            const message = try std.fmt.allocPrint(runtime.allocator, "Cannot use 'in' operator to search for '{s}' in {s}", .{ key_utf8, receiver_utf8 });
            defer runtime.allocator.free(message);
            runtime.setFailureText(message);
            return error.DictionaryHasReceiver;
        },
    }
}

pub fn stringValuesEqual(runtime: *Runtime, left: Value, right: Value) !bool {
    if (!isString(left) or !isString(right)) return false;
    return stringEqual(runtime, left, right);
}

pub fn arrayRange(runtime: *Runtime, index: Value, length: usize) !?ArrayRange {
    // The official implementation checks `typeof i === 'object'` before
    // reading i['先頭'].  Accessing a null value therefore throws, while an
    // array or dictionary without a numeric 先頭 simply falls through to the
    // null return value.
    if (index.tag == @intFromEnum(Tag.null_value)) return error.ArrayCutNullIndex;
    const tag: Tag = @enumFromInt(index.tag);
    if (tag != .array and tag != .dictionary) return null;
    const first_value = dictionaryProperty(index, &.{ 0x5148, 0x982d });
    if (first_value.tag != @intFromEnum(Tag.number)) return null;
    const first_number: f64 = @bitCast(first_value.payload);
    const last_value = dictionaryProperty(index, &.{ 0x672b, 0x5c3e });
    // `last - first + 1` is a JavaScript subtraction expression.  A BigInt
    // on either side would throw instead of silently converting to f64.
    if (last_value.tag == @intFromEnum(Tag.bigint)) return error.CannotMixBigIntAndNumber;
    const last_number = try valueToNumberRuntime(runtime, last_value);
    const count_number = last_number - first_number + 1;
    return .{
        .start = spliceIndexNumber(first_number, length),
        .count = spliceCountNumber(count_number, length - spliceIndexNumber(first_number, length)),
    };
}

pub fn spliceArrayBuiltin(runtime: *Runtime, source: Value, start: usize, count: usize) !Value {
    var roots = [_]Value{ source, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const items = try arrayItems(roots[0]);
    const source_object = roots[0].object() orelse return error.InvalidArray;
    try runtime.normalizeAotArrayPresence(source_object);
    const old_length = items.items.len;
    const actual = @min(count, old_length - start);
    roots[1] = try runtime.createArray(&.{});
    const result_object = roots[1].object() orelse return error.InvalidArray;
    const removed = try arrayItems(roots[1]);
    try removed.ensureTotalCapacity(runtime.allocator, actual);
    removed.items.len = actual;
    try result_object.array_presence.ensureTotalCapacity(runtime.allocator, actual);
    result_object.array_presence.items.len = actual;
    if (actual > 0) {
        @memcpy(removed.items, items.items[start .. start + actual]);
        @memcpy(result_object.array_presence.items, source_object.array_presence.items[start .. start + actual]);
    }
    if (actual > 0) {
        @memmove(items.items[start .. old_length - actual], items.items[start + actual .. old_length]);
        @memmove(source_object.array_presence.items[start .. old_length - actual], source_object.array_presence.items[start + actual .. old_length]);
        items.items.len = old_length - actual;
        source_object.array_presence.items.len = old_length - actual;
    }
    return roots[1];
}

pub fn insertValuesAssumeCapacity(items: *std.ArrayList(Value), start: usize, values: []const Value) void {
    const old_length = items.items.len;
    _ = items.addManyAtAssumeCapacity(start, values.len);
    @memcpy(items.items[start .. start + values.len], values);
    // Keep this assertion next to the low-level mutation: all callers reserve
    // capacity before entering this function, so OOM cannot leave a partial
    // array update behind.
    std.debug.assert(items.items.len == old_length + values.len);
}

pub fn insertPresenceAssumeCapacity(presence: *std.ArrayList(bool), start: usize, count: usize) void {
    const old_length = presence.items.len;
    _ = presence.addManyAtAssumeCapacity(start, count);
    @memset(presence.items[start .. start + count], true);
    std.debug.assert(presence.items.len == old_length + count);
}

pub fn arrayInsertBuiltin(runtime: *Runtime, source: Value, index: Value, item: Value) !Value {
    var roots = [_]Value{ source, index, item, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return error.ArrayInsertReceiver;
    const object = roots[0].object() orelse return error.InvalidArray;
    try runtime.normalizeAotArrayPresence(object);
    const items = try arrayItems(roots[0]);
    const start = try spliceIndexRuntime(runtime, roots[1], items.items.len);
    roots[3] = try runtime.createArray(&.{});
    const old_length = items.items.len;
    try items.ensureTotalCapacity(runtime.allocator, std.math.add(usize, old_length, 1) catch return error.ArrayTooLarge);
    try object.array_presence.ensureTotalCapacity(runtime.allocator, std.math.add(usize, old_length, 1) catch return error.ArrayTooLarge);
    insertValuesAssumeCapacity(items, start, roots[2..3]);
    insertPresenceAssumeCapacity(&object.array_presence, start, 1);
    return roots[3];
}

pub fn arrayInsertManyBuiltin(runtime: *Runtime, source: Value, index: Value, values: Value) !Value {
    var roots = [_]Value{ source, index, values, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array) or roots[2].tag != @intFromEnum(Tag.array)) return error.ArrayInsertManyReceiver;
    const target_object = roots[0].object() orelse return error.InvalidArray;
    try runtime.normalizeAotArrayPresence(target_object);
    const target = try arrayItems(roots[0]);
    const insertion = try arrayItems(roots[2]);
    // The official loop reads b[j] while mutating a.  Copying first is
    // intentional here: for a === b the upstream loop grows forever.  AOT
    // keeps the useful, finite value semantics and documents this safety
    // boundary in COMPATIBILITY_QUIRKS.md.
    const copy = try runtime.allocator.dupe(Value, insertion.items);
    defer runtime.allocator.free(copy);
    const positions = try runtime.allocator.alloc(usize, copy.len);
    defer runtime.allocator.free(positions);
    const old_length = target.items.len;
    for (copy, 0..) |_, offset| {
        // `i + j` is evaluated before splice.  This deliberately preserves
        // JavaScript's string concatenation and BigInt mixed-type errors.
        roots[3] = try jsAdd(runtime, roots[1], numberValue(@floatFromInt(offset)));
        positions[offset] = try spliceIndexRuntime(runtime, roots[3], std.math.add(usize, old_length, offset) catch return error.ArrayTooLarge);
    }
    const final_length = std.math.add(usize, old_length, copy.len) catch return error.ArrayTooLarge;
    try target.ensureTotalCapacity(runtime.allocator, final_length);
    try target_object.array_presence.ensureTotalCapacity(runtime.allocator, final_length);
    for (positions, 0..) |start, offset| {
        insertValuesAssumeCapacity(target, start, copy[offset .. offset + 1]);
        insertPresenceAssumeCapacity(&target_object.array_presence, start, 1);
    }
    return roots[0];
}

pub fn arrayCutBuiltin(runtime: *Runtime, source: Value, index: Value) !Value {
    var roots = [_]Value{ source, index, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag == @intFromEnum(Tag.array)) {
        const items = try arrayItems(roots[0]);
        if (roots[1].tag == @intFromEnum(Tag.number)) {
            const start = try spliceIndexRuntime(runtime, roots[1], items.items.len);
            roots[2] = try spliceArrayBuiltin(runtime, roots[0], start, 1);
            const removed = try arrayItems(roots[2]);
            return if (removed.items.len == 0) .{} else removed.items[0];
        }
        if (try arrayRange(runtime, roots[1], items.items.len)) |range| {
            return spliceArrayBuiltin(runtime, roots[0], range.start, range.count);
        }
        return .{ .tag = @intFromEnum(Tag.null_value) };
    }
    if (roots[0].tag == @intFromEnum(Tag.dictionary) and isString(roots[1])) {
        const object = roots[0].object() orelse return error.InvalidDictionary;
        if (object.payload != .dictionary) return error.InvalidDictionary;
        const key_units = try valueUtf16Alloc(runtime, roots[1]);
        defer runtime.allocator.free(key_units);
        const entries = &object.payload.dictionary;
        var own_index: ?usize = null;
        for (entries.items, 0..) |entry, entry_index| {
            if (try aotPropertyKeyEqual(runtime, entry.key, key_units)) {
                own_index = entry_index;
                break;
            }
        }
        if (own_index) |entry_index| {
            const old = entries.items[entry_index].value;
            if (!valueTruthy(old)) return .{};
            const removed = entries.orderedRemove(entry_index);
            return removed.value;
        }
        roots[2] = (try tableInheritedProperty(runtime, roots[0], .dictionary, key_units)) orelse return .{};
        if (!valueTruthy(roots[2])) return .{};
        return roots[2];
    }
    return error.ArrayCutReceiver;
}

pub fn arrayTakeBuiltin(runtime: *Runtime, source: Value, index: Value, count: Value) !Value {
    var roots = [_]Value{ source, index, count };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return error.ArrayTakeReceiver;
    const items = try arrayItems(roots[0]);
    const start = try spliceIndexRuntime(runtime, roots[1], items.items.len);
    const delete_count = try spliceCountRuntime(runtime, roots[2], items.items.len - start);
    return spliceArrayBuiltin(runtime, roots[0], start, delete_count);
}

pub fn arrayPopBuiltin(_: *Runtime, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayPopReceiver;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    const length = object.payload.array.items.len;
    if (length == 0) return .{};
    const result = object.payload.array.items[length - 1];
    _ = object.payload.array.pop();
    if (object.array_presence.items.len >= length) _ = object.array_presence.pop();
    return result;
}

pub fn arrayPushBuiltin(runtime: *Runtime, source: Value, item: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayPushReceiver;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    try runtime.aotArrayAppend(object, item);
    return source;
}

pub fn arrayMutationBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const source: Value = if (arguments.len > 0) arguments[0] else .{};
    const index: Value = if (arguments.len > 1) arguments[1] else .{};
    const item: Value = if (arguments.len > 2) arguments[2] else .{};
    return switch (command) {
        .array_insert => arrayInsertBuiltin(runtime, source, index, item),
        .array_insert_many => arrayInsertManyBuiltin(runtime, source, index, item),
        .array_cut => arrayCutBuiltin(runtime, source, index),
        .array_take => arrayTakeBuiltin(runtime, source, index, if (arguments.len > 2) arguments[2] else .{}),
        .array_pop => arrayPopBuiltin(runtime, source),
        .array_push => arrayPushBuiltin(runtime, source, index),
        .array_clone => deepCloneBuiltin(runtime, source),
        .array_range_copy => arrayRangeCopyBuiltin(runtime, source, index),
        .reference => referenceBuiltin(runtime, source, index),
        .array_add => arrayAddBuiltin(runtime, source, index),
        .array_maximum => arrayExtremumBuiltin(runtime, source, true),
        .array_minimum => arrayExtremumBuiltin(runtime, source, false),
        .array_sum => arraySumBuiltin(runtime, source),
        .array_swap => arraySwapBuiltin(runtime, source, index, item),
        .array_sequence => arraySequenceBuiltin(runtime, source, index),
        .array_fill => arrayFillBuiltin(runtime, source, index),
        else => error.UnknownCommand,
    };
}

const SliceRange = struct { start: usize, end: usize };

pub fn sliceIndex(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == 0) return 0;
    if (number == std.math.inf(f64)) return length;
    if (number == -std.math.inf(f64)) return 0;
    const integer = @trunc(number);
    if (integer < 0) {
        const magnitude = @min(-integer, @as(f64, @floatFromInt(length)));
        return length - @as(usize, @intFromFloat(magnitude));
    }
    if (integer >= @as(f64, @floatFromInt(length))) return length;
    return @intFromFloat(integer);
}

pub fn directIndex(number: f64) ?usize {
    if (!std.math.isFinite(number) or number < 0 or @trunc(number) != number) return null;
    if (number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return null;
    return @intFromFloat(number);
}

pub fn bigIntPropertyIndex(value: BigInt, length: usize) ?usize {
    const integer = value.toI64() catch return null;
    if (integer < 0) return null;
    const index = std.math.cast(usize, integer) orelse return null;
    return if (index < length) index else null;
}

pub fn charAtIndex(number: f64, length: usize) ?usize {
    if (std.math.isNan(number) or number == 0) return if (length > 0) 0 else null;
    if (!std.math.isFinite(number)) return null;
    const integer = @trunc(number);
    if (integer < 0 or integer >= @as(f64, @floatFromInt(length))) return null;
    return @intFromFloat(integer);
}

pub fn sliceRange(runtime: *Runtime, index: Value, length: usize) !?SliceRange {
    if (index.tag == @intFromEnum(Tag.null_value)) return error.ArrayCutNullIndex;
    if (index.tag != @intFromEnum(Tag.dictionary) and index.tag != @intFromEnum(Tag.array)) return null;
    const first = dictionaryProperty(index, &.{ 0x5148, 0x982d });
    if (first.tag != @intFromEnum(Tag.number)) return null;
    const last = dictionaryProperty(index, &.{ 0x672b, 0x5c3e });
    const start = sliceIndex(@bitCast(first.payload), length);
    const end_number = try explicitRangeNumber(runtime, last);
    const end = sliceIndex(end_number + 1, length);
    return .{ .start = start, .end = end };
}

pub fn substringRange(runtime: *Runtime, index: Value, length: usize) !?SliceRange {
    if (index.tag == @intFromEnum(Tag.null_value)) return error.ArrayCutNullIndex;
    if (index.tag != @intFromEnum(Tag.dictionary) and index.tag != @intFromEnum(Tag.array)) return null;
    const first = dictionaryProperty(index, &.{ 0x5148, 0x982d });
    if (first.tag != @intFromEnum(Tag.number)) return null;
    const last = dictionaryProperty(index, &.{ 0x672b, 0x5c3e });
    const first_number: f64 = @bitCast(first.payload);
    const last_number = try explicitRangeNumber(runtime, last) + 1;
    const normalize = struct {
        pub fn apply(number: f64, size: usize) usize {
            if (std.math.isNan(number) or number <= 0 or number == -std.math.inf(f64)) return 0;
            if (number == std.math.inf(f64)) return size;
            if (number >= @as(f64, @floatFromInt(size))) return size;
            return @intFromFloat(@trunc(number));
        }
    }.apply;
    var start = normalize(first_number, length);
    var end = normalize(last_number, length);
    if (start > end) std.mem.swap(usize, &start, &end);
    return .{ .start = start, .end = end };
}

pub fn arrayRangeCopyBuiltin(runtime: *Runtime, source: Value, index: Value) !Value {
    var rooted = [_]Value{ source, index, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    if (rooted[0].tag != @intFromEnum(Tag.array)) return error.ArrayRangeCopyReceiver;
    const items = try arrayItems(rooted[0]);
    if (rooted[1].tag == @intFromEnum(Tag.number)) {
        const position = directIndex(@bitCast(rooted[1].payload)) orelse return .{};
        if (position >= items.items.len) return .{};
        const item = items.items[position];
        return switch (@as(Tag, @enumFromInt(item.tag))) {
            .array, .dictionary, .iterator, .null_value => deepCloneBuiltin(runtime, item),
            else => item,
        };
    }
    const range = (try sliceRange(runtime, rooted[1], items.items.len)) orelse return .{};
    if (range.end <= range.start) return runtime.createArray(&.{});
    rooted[2] = try runtime.createArray(&.{});
    const values = items.items[range.start..range.end];
    try rooted[2].object().?.payload.array.ensureTotalCapacity(runtime.allocator, values.len);
    var state: CloneState = .{};
    defer state.deinit(runtime.allocator);
    for (values) |item| {
        var cloned = try deepCloneValue(runtime, item, &state);
        if (cloned.tag == @intFromEnum(Tag.undefined) or cloned.tag == @intFromEnum(Tag.function)) cloned = .{ .tag = @intFromEnum(Tag.null_value) };
        try appendAotArraySlot(runtime, rooted[2].object().?, cloned, true);
    }
    return rooted[2];
}

pub fn referenceBuiltin(runtime: *Runtime, source: Value, index: Value) !Value {
    var rooted = [_]Value{ source, index, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    if (isString(rooted[0])) {
        const units = try valueUtf16Alloc(runtime, rooted[0]);
        defer runtime.allocator.free(units);
        if (rooted[1].tag == @intFromEnum(Tag.number)) {
            const position = charAtIndex(@bitCast(rooted[1].payload), units.len) orelse return runtime.createString(&.{});
            return runtime.createString(units[position .. position + 1]);
        }
        const range = (try substringRange(runtime, rooted[1], units.len)) orelse return invalidStringRangeBuiltin(runtime, rooted[1]);
        const start = @min(range.start, units.len);
        const end = @min(range.end, units.len);
        return runtime.createString(units[start..end]);
    }
    if (rooted[0].tag == @intFromEnum(Tag.array)) {
        const items = try arrayItems(rooted[0]);
        if (rooted[1].tag == @intFromEnum(Tag.number)) {
            const position = directIndex(@bitCast(rooted[1].payload)) orelse return runtime.aotArrayPropertyGet(rooted[0].object().?, rooted[1]);
            return if (position <= 4_294_967_294 and position < items.items.len) items.items[position] else runtime.aotArrayPropertyGet(rooted[0].object().?, rooted[1]);
        }
        if (rooted[1].tag == @intFromEnum(Tag.bigint)) {
            const position = bigIntPropertyIndex(rooted[1].object().?.payload.bigint, items.items.len) orelse return runtime.aotArrayPropertyGet(rooted[0].object().?, rooted[1]);
            return items.items[position];
        }
        if (isString(rooted[1])) return tableRowProperty(runtime, rooted[0], rooted[1]);
        const range = (try sliceRange(runtime, rooted[1], items.items.len)) orelse return .{};
        const start = @min(range.start, items.items.len);
        const end = @min(@max(range.end, start), items.items.len);
        const source_object = rooted[0].object().?;
        try runtime.normalizeAotArrayPresence(source_object);
        rooted[2] = try runtime.createArray(&.{});
        const result_object = rooted[2].object().?;
        try result_object.payload.array.ensureTotalCapacity(runtime.allocator, end - start);
        try result_object.array_presence.ensureTotalCapacity(runtime.allocator, end - start);
        for (items.items[start..end], start..) |item, source_index| {
            try appendAotArraySlot(runtime, result_object, item, runtime.aotArrayIsPresent(source_object, source_index));
        }
        return rooted[2];
    }
    if (rooted[0].tag == @intFromEnum(Tag.byte_buffer)) return tableRowProperty(runtime, rooted[0], rooted[1]);
    if (rooted[0].tag == @intFromEnum(Tag.dictionary)) {
        const key = try valueUtf16Alloc(runtime, rooted[1]);
        defer runtime.allocator.free(key);
        if (dictionaryOwnProperty(rooted[0], key)) |value| return value;
        if (try tableInheritedProperty(runtime, rooted[0], .dictionary, key)) |value| return value;
        return .{};
    }
    return error.IndexableValueExpected;
}

pub fn invalidStringRangeBuiltin(runtime: *Runtime, index: Value) !Value {
    const encoded = try jsonEncodeBuiltin(runtime, index, false);
    var roots = [_]Value{encoded};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    var message: std.ArrayList(u16) = .empty;
    errdefer message.deinit(runtime.allocator);
    try appendUtf8Units(&message, runtime.allocator, "『参照』で文字列型の範囲指定(");
    if (roots[0].tag == @intFromEnum(Tag.undefined)) {
        try appendAsciiUnits(&message, runtime.allocator, "undefined");
    } else {
        try message.appendSlice(runtime.allocator, roots[0].object().?.payload.utf16_string);
    }
    try appendUtf8Units(&message, runtime.allocator, ")が不正です。");
    runtime.setFailureUnits(message.items);
    return error.InvalidStringRange;
}

pub fn appendAotArraySlot(runtime: *Runtime, object: *Object, value: Value, present: bool) !void {
    const index = object.payload.array.items.len;
    try runtime.aotArrayAppend(object, value);
    if (!present) object.array_presence.items[index] = false;
}

pub fn arrayAddBuiltin(runtime: *Runtime, source: Value, other: Value) !Value {
    var roots = [_]Value{ source, other, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return deepCloneBuiltin(runtime, roots[0]);
    roots[2] = try runtime.createArray(&.{});
    const source_object = roots[0].object().?;
    try runtime.normalizeAotArrayPresence(source_object);
    const source_items = &source_object.payload.array;
    const other_is_array = roots[1].tag == @intFromEnum(Tag.array);
    const other_object = if (other_is_array) roots[1].object().? else null;
    if (other_object) |object| try runtime.normalizeAotArrayPresence(object);
    const extra: usize = if (roots[1].tag == @intFromEnum(Tag.array)) (try arrayItems(roots[1])).items.len else 1;
    const final_length = std.math.add(usize, source_items.items.len, extra) catch return error.ArrayTooLarge;
    const result_object = roots[2].object().?;
    const result = &result_object.payload.array;
    try result.ensureTotalCapacity(runtime.allocator, final_length);
    try result_object.array_presence.ensureTotalCapacity(runtime.allocator, final_length);
    for (source_items.items, 0..) |item, source_index| {
        try appendAotArraySlot(runtime, result_object, item, runtime.aotArrayIsPresent(source_object, source_index));
    }
    if (other_is_array) {
        const other_array = other_object.?;
        for (other_array.payload.array.items, 0..) |item, other_index| {
            try appendAotArraySlot(runtime, result_object, item, runtime.aotArrayIsPresent(other_array, other_index));
        }
    } else {
        try appendAotArraySlot(runtime, result_object, roots[1], true);
    }
    return roots[2];
}

pub fn arrayExtremumBuiltin(runtime: *Runtime, source: Value, maximum: bool) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    const items = object.payload.array.items;
    var first_index: ?usize = null;
    for (items, 0..) |_, index| if (runtime.aotArrayIsPresent(object, index)) {
        first_index = index;
        break;
    };
    const first = first_index orelse return error.NonEmptyArrayExpected;
    var present_count: usize = 0;
    for (items, 0..) |_, index| {
        if (runtime.aotArrayIsPresent(object, index)) present_count += 1;
    }
    if (present_count == 1) return items[first];
    var result = try valueToNumberRuntime(runtime, items[first]);
    for (items[first + 1 ..], 0..) |item, offset| {
        if (!runtime.aotArrayIsPresent(object, first + 1 + offset)) continue;
        const number = try valueToNumberRuntime(runtime, item);
        if (std.math.isNan(number) or std.math.isNan(result)) {
            result = std.math.nan(f64);
        } else if ((maximum and (number > result or (number == result and isNegativeZero(result)))) or
            (!maximum and (number < result or (number == result and isNegativeZero(number)))))
        {
            result = number;
        }
    }
    return numberValue(result);
}

pub fn isNegativeZero(number: f64) bool {
    return number == 0 and (@as(u64, @bitCast(number)) >> 63) != 0;
}

pub fn arraySumBuiltin(runtime: *Runtime, source: Value) !Value {
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const object = source.object() orelse return error.InvalidArray;
    if (object.payload != .array) return error.InvalidArray;
    var total: f64 = 0;
    for (object.payload.array.items, 0..) |item, index| {
        if (!runtime.aotArrayIsPresent(object, index)) continue;
        const number = try parseFloatBuiltin(runtime, item);
        if (!std.math.isNan(number)) total += number;
    }
    return numberValue(total);
}

pub fn arraySwapBuiltin(runtime: *Runtime, source: Value, first_value: Value, second_value: Value) !Value {
    var roots = [_]Value{ source, first_value, second_value };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[0].tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    const first_units = try valueUtf16Alloc(runtime, roots[1]);
    defer runtime.allocator.free(first_units);
    const second_units = try valueUtf16Alloc(runtime, roots[2]);
    defer runtime.allocator.free(second_units);
    if (std.mem.eql(u16, first_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or
        std.mem.eql(u16, second_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthAssignment;
    const first = runtime.aotCanonicalArrayIndexUnits(first_units);
    const second = runtime.aotCanonicalArrayIndexUnits(second_units);
    const largest_index = if (first) |first_index| if (second) |second_index| @max(first_index, second_index) else first_index else second;
    if (largest_index) |index| {
        const required_length = std.math.add(usize, index, 1) catch return error.ArraySparseLengthLimit;
        const items = &roots[0].object().?.payload.array.items;
        if (required_length > items.len and required_length > safe_array_element_limit) return error.ArraySparseLengthLimit;
    }
    const array = roots[0].object().?;
    const first_item = runtime.aotArrayPropertyGet(array, roots[1]);
    const second_item = runtime.aotArrayPropertyGet(array, roots[2]);
    try runtime.aotArrayPropertySet(array, roots[1], second_item);
    try runtime.aotArrayPropertySet(array, roots[2], first_item);
    return roots[0];
}

pub fn fillArrayLength(number: f64, maximum: usize) !usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(maximum))) return error.ArrayFillSizeLimit;
    return @intFromFloat(@floor(number));
}

pub fn arraySequenceBuiltin(runtime: *Runtime, first_value: Value, last_value: Value) !Value {
    var roots = [_]Value{ first_value, last_value, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try runtime.createArray(&.{});
    roots[3] = try runtime.createBigInt("1n");
    const result_items = try arrayItems(roots[2]);
    var count: usize = 0;
    const lessEqual = struct {
        pub fn check(rt: *Runtime, left: Value, right: Value) !bool {
            if (left.tag == @intFromEnum(Tag.bigint) and right.tag == @intFromEnum(Tag.bigint)) {
                return BigInt.order(left.object().?.payload.bigint, right.object().?.payload.bigint) != .gt;
            }
            return compareValues(rt, .less_equal, left, right);
        }
    }.check;
    while (try lessEqual(runtime, roots[0], roots[1])) {
        if (count >= safe_array_element_limit) return error.ArraySequenceSizeLimit;
        if (roots[1].tag != @intFromEnum(Tag.bigint) and try valueToNumberRuntime(runtime, roots[1]) == std.math.inf(f64)) return error.ArraySequenceSizeLimit;
        try result_items.append(runtime.allocator, roots[0]);
        if (roots[0].tag == @intFromEnum(Tag.bigint)) {
            roots[0] = try bigIntArithmetic(runtime, .add, roots[0], roots[3]);
        } else {
            const current_number = try valueToNumberRuntime(runtime, roots[0]);
            const next = numberValue(current_number + 1);
            if (@as(f64, @bitCast(next.payload)) == current_number and try lessEqual(runtime, next, roots[1])) return error.ArraySequenceSizeLimit;
            roots[0] = next;
        }
        count += 1;
    }
    return roots[2];
}

pub fn arrayFillBuiltin(runtime: *Runtime, value: Value, shape: Value) !Value {
    var roots = [_]Value{ value, shape };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (roots[1].tag == @intFromEnum(Tag.array)) try validateFillDimensions(runtime, roots[1]);
    return arrayFillAtDepth(runtime, roots[0], roots[1], 0);
}

pub fn validateFillDimensions(runtime: *Runtime, shape: Value) !void {
    const dimensions = try arrayItems(shape);
    var product: usize = 1;
    var total: usize = 0;
    for (dimensions.items) |dimension| {
        const count = try fillArrayLength(try valueToNumberRuntime(runtime, dimension), safe_array_element_limit);
        product = std.math.mul(usize, product, count) catch return error.ArrayFillSizeLimit;
        total = std.math.add(usize, total, product) catch return error.ArrayFillSizeLimit;
        if (total > safe_array_element_limit) return error.ArrayFillSizeLimit;
        if (product == 0) break;
    }
}

pub fn cloneFillValue(runtime: *Runtime, value: Value) !Value {
    if (value.tag != @intFromEnum(Tag.array)) return switch (@as(Tag, @enumFromInt(value.tag))) {
        .dictionary, .byte_buffer, .iterator, .promise => deepCloneBuiltin(runtime, value),
        else => value,
    };
    const source = try arrayItems(value);
    const result = try runtime.createArray(&.{});
    var roots = [_]Value{ value, result };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const destination = try arrayItems(roots[1]);
    try runtime.normalizeAotArrayPresence(roots[0].object().?);
    try destination.ensureTotalCapacity(runtime.allocator, source.items.len);
    for (source.items, 0..) |item, index| {
        try appendAotArraySlot(runtime, roots[1].object().?, try cloneFillValue(runtime, item), runtime.aotArrayIsPresent(roots[0].object().?, index));
    }
    return roots[1];
}

pub fn arrayFillAtDepth(runtime: *Runtime, value: Value, shape: Value, depth: usize) !Value {
    if (shape.tag != @intFromEnum(Tag.array)) {
        const count = try fillArrayLength(try valueToNumberRuntime(runtime, shape), safe_array_element_limit - 1);
        const result = try runtime.createArray(&.{});
        var roots = [_]Value{ value, result };
        var frame: RootFrame = .{};
        runtime.pushRoots(&frame, &roots, roots.len);
        defer runtime.popRoots(&frame);
        const items = try arrayItems(roots[1]);
        try items.ensureTotalCapacity(runtime.allocator, count);
        for (0..count) |_| try items.append(runtime.allocator, try cloneFillValue(runtime, roots[0]));
        return roots[1];
    }
    const dimensions = try arrayItems(shape);
    if (dimensions.items.len == 0 and depth == 0) return runtime.createArray(&.{});
    if (depth >= dimensions.items.len) return cloneFillValue(runtime, value);
    const count = try fillArrayLength(try valueToNumberRuntime(runtime, dimensions.items[depth]), safe_array_element_limit);
    const result = try runtime.createArray(&.{});
    var roots = [_]Value{ value, shape, result };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const items = try arrayItems(roots[2]);
    try items.ensureTotalCapacity(runtime.allocator, count);
    for (0..count) |_| try items.append(runtime.allocator, try arrayFillAtDepth(runtime, roots[0], roots[1], depth + 1));
    return roots[2];
}

pub fn explodeBuiltin(runtime: *Runtime, value: Value) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createArray(&.{});
    var index: usize = 0;
    while (index < units.len) {
        const length = codePointLength(units, index);
        roots[1] = try runtime.createString(units[index .. index + length]);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
        index += length;
    }
    return roots[0];
}

pub fn refrainBuiltin(runtime: *Runtime, value: Value, count_value: Value) !Value {
    const count_number = try valueToNumberRuntime(runtime, count_value);
    if (std.math.isNan(count_number) or count_number <= 0) return runtime.createString(&.{});
    if (!std.math.isFinite(count_number) or count_number > @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.RepetitionTooLarge;
    const count: usize = @intFromFloat(@ceil(count_number));
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    const length = std.math.mul(usize, units.len, count) catch return error.RepetitionTooLarge;
    const output = try runtime.allocator.alloc(u16, length);
    for (0..count) |index| @memcpy(output[index * units.len ..][0..units.len], units);
    return runtime.ownString(output);
}

pub fn occurrenceBuiltin(runtime: *Runtime, source: Value, needle: Value) !bool {
    if (source.tag == @intFromEnum(Tag.array)) {
        for (source.object().?.payload.array.items) |item| {
            if (try sameValueZero(runtime, item, needle)) return true;
        }
        return false;
    }
    const source_units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(source_units);
    const needle_units = try valueUtf16Alloc(runtime, needle);
    defer runtime.allocator.free(needle_units);
    return indexOfUnitsBuiltin(source_units, needle_units, 0) != null;
}

pub fn occurrenceCountBuiltin(runtime: *Runtime, source_value: Value, needle_value: Value) !i64 {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const needle = try valueUtf16Alloc(runtime, needle_value);
    defer runtime.allocator.free(needle);
    if (needle.len == 0) return @as(i64, @intCast(source.len)) - 1;
    var count: i64 = 0;
    var start: usize = 0;
    while (std.mem.indexOfPos(u16, source, start, needle)) |found| {
        count += 1;
        start = found + needle.len;
    }
    return count;
}

pub fn substringBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const source = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(source);
    const length = codePointCount(source);
    var start: usize = 0;
    var end: usize = length;
    switch (command) {
        .substring_mid => {
            var start_number = try substringNumberBuiltin(runtime, arguments[1]);
            const count_number = try substringNumberBuiltin(runtime, arguments[2]);
            if (count_number <= 0) return runtime.createString(&.{});
            if (start_number < 0) {
                start_number = @as(f64, @floatFromInt(length)) + start_number + 1;
                if (start_number < 0) start_number = 1;
            }
            start = sliceIndexBuiltin(start_number - 1, length);
            end = sliceIndexBuiltin(start_number + count_number - 1, length);
            if (end <= start) return runtime.createString(&.{});
        },
        .substring_left => end = sliceIndexBuiltin(try valueToNumberRuntime(runtime, arguments[1]), length),
        .substring_right => {
            var index_number = @as(f64, @floatFromInt(length)) - try valueToNumberRuntime(runtime, arguments[1]);
            if (index_number < 0) index_number = 0;
            start = sliceIndexBuiltin(index_number, length);
        },
        else => unreachable,
    }
    return runtime.createString(source[codePointOffsetBuiltin(source, start)..codePointOffsetBuiltin(source, end)]);
}

pub fn substringNumberBuiltin(runtime: *Runtime, value: Value) !f64 {
    return if (isString(value)) parseIntBuiltin(runtime, value) else valueToNumberRuntime(runtime, value);
}

pub fn sliceIndexBuiltin(number: f64, length: usize) usize {
    if (std.math.isNan(number) or number == 0) return 0;
    const length_number: f64 = @floatFromInt(length);
    if (number >= length_number) return length;
    if (number <= -length_number) return 0;
    if (number < 0) return length - @as(usize, @intFromFloat(-@trunc(number)));
    return @intFromFloat(@trunc(number));
}

pub fn splitBuiltin(runtime: *Runtime, source_value: Value, delimiter_value: Value, first_only: bool) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const delimiter = try valueUtf16Alloc(runtime, delimiter_value);
    defer runtime.allocator.free(delimiter);
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createArray(&.{});
    if (first_only) {
        if (std.mem.indexOf(u16, source, delimiter)) |found| {
            try appendStringPart(runtime, &roots, source[0..found]);
            try appendStringPart(runtime, &roots, source[found + delimiter.len ..]);
        } else try appendStringPart(runtime, &roots, source);
        return roots[0];
    }
    if (delimiter.len == 0) {
        for (source) |unit| try appendStringPart(runtime, &roots, &.{unit});
        return roots[0];
    }
    var start: usize = 0;
    while (std.mem.indexOfPos(u16, source, start, delimiter)) |found| {
        try appendStringPart(runtime, &roots, source[start..found]);
        start = found + delimiter.len;
    }
    try appendStringPart(runtime, &roots, source[start..]);
    return roots[0];
}

pub fn appendStringPart(runtime: *Runtime, roots: *[2]Value, units: []const u16) !void {
    roots[1] = try runtime.createString(units);
    try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
}

pub fn stringRemoveBuiltin(runtime: *Runtime, source_value: Value, start_value: Value, count_value: Value) !Value {
    const source = try valueUtf16Alloc(runtime, source_value);
    defer runtime.allocator.free(source);
    const length = codePointCount(source);
    const start = sliceIndexBuiltin(try valueToNumberRuntime(runtime, start_value) - 1, length);
    const count = spliceDeleteCountBuiltin(try valueToNumberRuntime(runtime, count_value), length - start);
    const unit_start = codePointOffsetBuiltin(source, start);
    const unit_end = codePointOffsetBuiltin(source, start + count);
    const output = try runtime.allocator.alloc(u16, source.len - (unit_end - unit_start));
    @memcpy(output[0..unit_start], source[0..unit_start]);
    @memcpy(output[unit_start..], source[unit_end..]);
    return runtime.ownString(output);
}

pub fn spliceDeleteCountBuiltin(number: f64, remaining: usize) usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(remaining))) return remaining;
    return @intFromFloat(@trunc(number));
}

pub fn trimBuiltin(runtime: *Runtime, value: Value, trim_left: bool, trim_right: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var start: usize = 0;
    var end = units.len;
    if (trim_left) {
        while (start < end and string_mod.isEcmaWhitespace(units[start])) : (start += 1) {}
    }
    if (trim_right) {
        while (end > start and string_mod.isEcmaWhitespace(units[end - 1])) : (end -= 1) {}
    }
    return runtime.createString(units[start..end]);
}

pub fn unicodeCaseBuiltin(runtime: *Runtime, value: Value, uppercase: bool) !Value {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    var codepoints: std.ArrayList(u21) = .empty;
    defer codepoints.deinit(runtime.allocator);
    var unit_index: usize = 0;
    while (unit_index < units.len) {
        const length = codePointLength(units, unit_index);
        const codepoint: u21 = if (length == 2)
            @intCast(0x10000 + ((@as(u32, units[unit_index]) - 0xd800) << 10) + (@as(u32, units[unit_index + 1]) - 0xdc00))
        else
            @intCast(units[unit_index]);
        try codepoints.append(runtime.allocator, codepoint);
        unit_index += length;
    }

    var output: std.ArrayList(u16) = .empty;
    errdefer output.deinit(runtime.allocator);
    for (codepoints.items, 0..) |codepoint, index| {
        if (!uppercase and codepoint == 0x03a3 and isFinalSigmaBuiltin(codepoints.items, index)) {
            try output.append(runtime.allocator, 0x03c2);
            continue;
        }
        const mapped = if (uppercase) unicode_case.upper(codepoint) else unicode_case.lower(codepoint);
        if (mapped) |values| {
            for (values) |mapped_codepoint| try appendCodePointBuiltin(runtime.allocator, &output, mapped_codepoint);
        } else {
            try appendCodePointBuiltin(runtime.allocator, &output, codepoint);
        }
    }
    return runtime.ownString(try output.toOwnedSlice(runtime.allocator));
}

pub fn isFinalSigmaBuiltin(codepoints: []const u21, index: usize) bool {
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

pub fn appendCodePointBuiltin(allocator: std.mem.Allocator, output: *std.ArrayList(u16), codepoint: u21) !void {
    if (codepoint <= 0xffff) return output.append(allocator, @intCast(codepoint));
    const offset: u32 = codepoint - 0x10000;
    try output.append(allocator, @intCast(0xd800 + (offset >> 10)));
    try output.append(allocator, @intCast(0xdc00 + (offset & 0x3ff)));
}
