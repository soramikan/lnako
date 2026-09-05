const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const number_mod = shared.number_mod;
const regexp = shared.regexp;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const Object = aot_state.Object;
const ByteBuffer = aot_state.ByteBuffer;
const BigInt = aot_state.BigInt;
const RootFrame = aot_state.RootFrame;
const AotPrimitiveHint = aot_state.AotPrimitiveHint;
const FunctionCallback = aot_state.FunctionCallback;
const numberValue = aot_state.numberValue;
const valueToNumber = aot_state.valueToNumber;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const valueUtf8LossyAlloc = aot_state.valueUtf8LossyAlloc;
const valueToPrimitive = aot_state.valueToPrimitive;
const runtimeUtf8String = aot_state.runtimeUtf8String;
const runtimeUtf8StringLossy = aot_state.runtimeUtf8StringLossy;
const staticStringValue = aot_state.staticStringValue;
const isString = aot_state.isString;
const abstractEqual = aot_state.abstractEqual;
const strictEqual = aot_state.strictEqual;
const compareValues = aot_state.compareValues;
const jsAdd = aot_state.jsAdd;
const relationalOrder = aot_state.relationalOrder;
const arithmetic = aot_state.arithmetic;
const parseFloatBuiltin = aot_state.parseFloatBuiltin;
const jsonEncodeBuiltin = aot_state.jsonEncodeBuiltin;
const arrayItems = aot_state.arrayItems;
const appendAotArraySlot = aot_state.appendAotArraySlot;
const arrayRange = aot_state.arrayRange;
const SearchElements = aot_state.SearchElements;
const appendSearchElements = aot_state.appendSearchElements;
const joinedSearchElementsEqual = aot_state.joinedSearchElementsEqual;
const codePointCount = aot_state.codePointCount;
const codePointOffsetBuiltin = aot_state.codePointOffsetBuiltin;
const spliceIndexRuntime = aot_state.spliceIndexRuntime;
const sliceIndex = aot_state.sliceIndex;
const safe_array_element_limit = aot_state.safe_array_element_limit;
const v8_small_callback_sort_limit = aot_state.v8_small_callback_sort_limit;
const V8SortContext = aot_state.V8SortContext;
const v8TimSortArrayCallback = aot_state.v8TimSortArrayCallback;
const promiseSentinel = aot_state.promiseSentinel;
const byteBufferUnboundSliceCallback = aot_state.byteBufferUnboundSliceCallback;
const dictionaryPrototypeProperty = aot_state.dictionaryPrototypeProperty;
const aotByteBufferAllowsStandardPrototype = aot_state.aotByteBufferAllowsStandardPrototype;
const utf16FailureMessageUtf8Alloc = aot_state.utf16FailureMessageUtf8Alloc;
const setRegexpCompileFailureMessage = aot_state.setRegexpCompileFailureMessage;
const dictionaryPrototypeBlocksStandard = aot_state.dictionaryPrototypeBlocksStandard;
const dictionaryOwnProperty = aot_state.dictionaryOwnProperty;
const arrayPrototypeProperty = aot_state.arrayPrototypeProperty;
const arrayPrototypeBlocksStandard = aot_state.arrayPrototypeBlocksStandard;
const jsonDecodeBuiltin = aot_state.jsonDecodeBuiltin;

const table_length_key = [_]u16{ 'l', 'e', 'n', 'g', 't', 'h' };

const table_standard_property_cache_object: u8 = 1;
const table_standard_property_cache_function: u8 = 2;
const table_standard_property_cache_array: u8 = 3;
const table_standard_property_cache_string: u8 = 4;
const table_standard_property_cache_constructor: u8 = 5;
const table_standard_property_cache_buffer: u8 = 6;
const table_standard_property_cache_uint8_array: u8 = 7;
const table_standard_property_cache_array_buffer: u8 = 8;
const table_standard_property_cache_number: u8 = 9;
const table_standard_property_cache_boolean: u8 = 10;
const table_standard_property_cache_bigint: u8 = 11;

const table_object_prototype_method_names = [_][]const u8{
    "__defineGetter__",
    "__defineSetter__",
    "hasOwnProperty",
    "__lookupGetter__",
    "__lookupSetter__",
    "isPrototypeOf",
    "propertyIsEnumerable",
    "toLocaleString",
    "toString",
    "valueOf",
};

const table_function_prototype_method_names = [_][]const u8{ "apply", "bind", "call", "toString" };

const table_array_prototype_method_names = [_][]const u8{
    "at",
    "concat",
    "copyWithin",
    "entries",
    "every",
    "fill",
    "filter",
    "find",
    "findIndex",
    "findLast",
    "findLastIndex",
    "flat",
    "flatMap",
    "forEach",
    "includes",
    "indexOf",
    "join",
    "keys",
    "lastIndexOf",
    "map",
    "pop",
    "push",
    "reduce",
    "reduceRight",
    "reverse",
    "shift",
    "slice",
    "some",
    "sort",
    "splice",
    "toLocaleString",
    "toString",
    "unshift",
    "values",
    "with",
};

const table_string_prototype_method_names = [_][]const u8{
    "anchor",
    "at",
    "big",
    "blink",
    "bold",
    "charAt",
    "charCodeAt",
    "codePointAt",
    "concat",
    "endsWith",
    "fixed",
    "fontcolor",
    "fontsize",
    "includes",
    "indexOf",
    "isWellFormed",
    "italics",
    "lastIndexOf",
    "link",
    "localeCompare",
    "match",
    "matchAll",
    "normalize",
    "padEnd",
    "padStart",
    "repeat",
    "replace",
    "replaceAll",
    "search",
    "slice",
    "small",
    "split",
    "startsWith",
    "strike",
    "sub",
    "substr",
    "substring",
    "toLocaleLowerCase",
    "toLocaleUpperCase",
    "toLowerCase",
    "toUpperCase",
    "toWellFormed",
    "toString",
    "valueOf",
    "trim",
    "trimEnd",
    "trimLeft",
    "trimRight",
    "trimStart",
};

const table_number_prototype_method_names = [_][]const u8{
    "toExponential",
    "toFixed",
    "toLocaleString",
    "toPrecision",
    "toString",
    "valueOf",
};

const table_boolean_prototype_method_names = [_][]const u8{ "toString", "valueOf" };

const table_bigint_prototype_method_names = [_][]const u8{ "toLocaleString", "toString", "valueOf" };

const table_byte_buffer_typed_array_method_names = [_][]const u8{
    "at",
    "copyWithin",
    "entries",
    "every",
    "fill",
    "filter",
    "find",
    "findIndex",
    "findLast",
    "findLastIndex",
    "forEach",
    "includes",
    "indexOf",
    "join",
    "keys",
    "lastIndexOf",
    "map",
    "reverse",
    "reduce",
    "reduceRight",
    "set",
    "slice",
    "some",
    "sort",
    "subarray",
    "toReversed",
    "toSorted",
    "values",
    "with",
};

pub const table_byte_buffer_buffer_enumerable_property_names = [_][]const u8{
    "readBigUInt64LE",
    "readBigUInt64BE",
    "readBigUint64LE",
    "readBigUint64BE",
    "readBigInt64LE",
    "readBigInt64BE",
    "writeBigUInt64LE",
    "writeBigUInt64BE",
    "writeBigUint64LE",
    "writeBigUint64BE",
    "writeBigInt64LE",
    "writeBigInt64BE",
    "readUIntLE",
    "readUInt32LE",
    "readUInt16LE",
    "readUInt8",
    "readUIntBE",
    "readUInt32BE",
    "readUInt16BE",
    "readUintLE",
    "readUint32LE",
    "readUint16LE",
    "readUint8",
    "readUintBE",
    "readUint32BE",
    "readUint16BE",
    "readIntLE",
    "readInt32LE",
    "readInt16LE",
    "readInt8",
    "readIntBE",
    "readInt32BE",
    "readInt16BE",
    "writeUIntLE",
    "writeUInt32LE",
    "writeUInt16LE",
    "writeUInt8",
    "writeUIntBE",
    "writeUInt32BE",
    "writeUInt16BE",
    "writeUintLE",
    "writeUint32LE",
    "writeUint16LE",
    "writeUint8",
    "writeUintBE",
    "writeUint32BE",
    "writeUint16BE",
    "writeIntLE",
    "writeInt32LE",
    "writeInt16LE",
    "writeInt8",
    "writeIntBE",
    "writeInt32BE",
    "writeInt16BE",
    "readFloatLE",
    "readFloatBE",
    "readDoubleLE",
    "readDoubleBE",
    "writeFloatLE",
    "writeFloatBE",
    "writeDoubleLE",
    "writeDoubleBE",
    "asciiSlice",
    "base64Slice",
    "base64urlSlice",
    "latin1Slice",
    "hexSlice",
    "ucs2Slice",
    "utf8Slice",
    "asciiWrite",
    "base64Write",
    "base64urlWrite",
    "latin1Write",
    "hexWrite",
    "ucs2Write",
    "utf8Write",
    "parent",
    "offset",
    "copy",
    "toString",
    "equals",
    "inspect",
    "compare",
    "indexOf",
    "lastIndexOf",
    "includes",
    "fill",
    "write",
    "toJSON",
    "subarray",
    "slice",
    "swap16",
    "swap32",
    "swap64",
    "toLocaleString",
};

const table_byte_buffer_empty_function_names = [_][]const u8{
    "readUInt32LE",
    "readUInt16LE",
    "readUInt8",
    "readUInt32BE",
    "readUInt16BE",
    "readUint32LE",
    "readUint16LE",
    "readUint8",
    "readUint32BE",
    "readUint16BE",
    "readInt32LE",
    "readInt16LE",
    "readInt8",
    "readInt32BE",
    "readInt16BE",
    "asciiSlice",
    "base64Slice",
    "base64urlSlice",
    "latin1Slice",
    "hexSlice",
    "ucs2Slice",
    "utf8Slice",
    "asciiWrite",
    "base64Write",
    "base64urlWrite",
    "latin1Write",
    "hexWrite",
    "ucs2Write",
    "utf8Write",
};

const table_byte_buffer_array_buffer_method_names = [_][]const u8{
    "slice",
    "resize",
    "transfer",
    "transferToFixedLength",
};

pub fn tableAsciiUnitsEqual(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |unit, byte| if (unit != byte) return false;
    return true;
}

pub fn tableInheritedMethodName(units: []const u16, names: []const []const u8) ?[]const u8 {
    for (names) |name| if (tableAsciiUnitsEqual(units, name)) return name;
    return null;
}

pub fn tableBufferEnumerableFunctionName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "readBigUint64LE")) return "readBigUInt64LE";
    if (std.mem.eql(u8, name, "readBigUint64BE")) return "readBigUInt64BE";
    if (std.mem.eql(u8, name, "writeBigUint64LE")) return "writeBigUInt64LE";
    if (std.mem.eql(u8, name, "writeBigUint64BE")) return "writeBigUInt64BE";
    if (std.mem.eql(u8, name, "readUintLE")) return "readUIntLE";
    if (std.mem.eql(u8, name, "readUint32LE")) return "readUInt32LE";
    if (std.mem.eql(u8, name, "readUint16LE")) return "readUInt16LE";
    if (std.mem.eql(u8, name, "readUint8")) return "readUInt8";
    if (std.mem.eql(u8, name, "readUintBE")) return "readUIntBE";
    if (std.mem.eql(u8, name, "readUint32BE")) return "readUInt32BE";
    if (std.mem.eql(u8, name, "readUint16BE")) return "readUInt16BE";
    if (std.mem.eql(u8, name, "writeUintLE")) return "writeUIntLE";
    if (std.mem.eql(u8, name, "writeUint32LE")) return "writeUInt32LE";
    if (std.mem.eql(u8, name, "writeUint16LE")) return "writeUInt16LE";
    if (std.mem.eql(u8, name, "writeUint8")) return "writeUInt8";
    if (std.mem.eql(u8, name, "writeUintBE")) return "writeUIntBE";
    if (std.mem.eql(u8, name, "writeUint32BE")) return "writeUInt32BE";
    if (std.mem.eql(u8, name, "writeUint16BE")) return "writeUInt16BE";
    if (std.mem.eql(u8, name, "readFloatLE")) return "readFloatForwards";
    if (std.mem.eql(u8, name, "readFloatBE")) return "readFloatBackwards";
    if (std.mem.eql(u8, name, "readDoubleLE")) return "readDoubleForwards";
    if (std.mem.eql(u8, name, "readDoubleBE")) return "readDoubleBackwards";
    if (std.mem.eql(u8, name, "writeFloatLE")) return "writeFloatForwards";
    if (std.mem.eql(u8, name, "writeFloatBE")) return "writeFloatBackwards";
    if (std.mem.eql(u8, name, "writeDoubleLE")) return "writeDoubleForwards";
    if (std.mem.eql(u8, name, "writeDoubleBE")) return "writeDoubleBackwards";
    for (table_byte_buffer_empty_function_names) |empty_name| if (std.mem.eql(u8, name, empty_name)) return "";
    return name;
}

pub fn tableInheritedFunctionWithCallback(
    runtime: *Runtime,
    cache_kind: u8,
    cache_name: []const u8,
    function_name: []const u8,
    callback: FunctionCallback,
) !Value {
    if (runtime.cachedStandardProperty(cache_kind, cache_name)) |value| return value;
    const result = try runtime.createMethodFunction(callback, 0, function_name, &.{});
    try runtime.cacheStandardProperty(cache_kind, cache_name, result);
    return result;
}

pub fn tableInheritedFunction(runtime: *Runtime, cache_kind: u8, name: []const u8) !Value {
    return tableInheritedFunctionWithCallback(runtime, cache_kind, name, name, promiseSentinel);
}

pub fn tableInheritedByteBufferMethod(runtime: *Runtime, receiver: Value, name: []const u8) !Value {
    const cache_kind: u8 = switch (receiver.object().?.payload.byte_buffer.kind) {
        .buffer => table_standard_property_cache_buffer,
        .uint8_array => table_standard_property_cache_uint8_array,
        .array_buffer => table_standard_property_cache_array_buffer,
    };
    if (@as(Tag, @enumFromInt(receiver.tag)) == .byte_buffer and receiver.object().?.payload.byte_buffer.kind == .buffer and std.mem.eql(u8, name, "slice")) {
        return tableInheritedFunctionWithCallback(runtime, cache_kind, name, name, byteBufferUnboundSliceCallback);
    }
    return tableInheritedFunction(runtime, cache_kind, name);
}

pub fn tableInheritedProperty(runtime: *Runtime, row: Value, row_tag: Tag, units: []const u16) !?Value {
    if (row_tag == .dictionary and row.object().?.prototype.tag != @intFromEnum(Tag.undefined)) {
        if (tableAsciiUnitsEqual(units, "__proto__")) return row.object().?.prototype;
        if (dictionaryPrototypeProperty(row, units)) |value| return value;
        if (dictionaryPrototypeBlocksStandard(row)) return null;
    }
    if (row_tag == .array and row.object().?.prototype.tag != @intFromEnum(Tag.undefined)) {
        if (tableAsciiUnitsEqual(units, "__proto__")) return if (row.object().?.prototype.tag == @intFromEnum(Tag.null_value)) .{} else row.object().?.prototype;
        if (arrayPrototypeProperty(row, units)) |value| return value;
        if (arrayPrototypeBlocksStandard(row)) return null;
    }
    if (row_tag == .byte_buffer and row.object().?.prototype.tag != @intFromEnum(Tag.undefined)) {
        if (tableAsciiUnitsEqual(units, "__proto__")) return if (row.object().?.prototype.tag == @intFromEnum(Tag.null_value)) null else row.object().?.prototype;
        if (row.object().?.prototype.tag == @intFromEnum(Tag.dictionary)) {
            if (dictionaryOwnProperty(row.object().?.prototype, units)) |value| return value;
            if (dictionaryPrototypeProperty(row.object().?.prototype, units)) |value| return value;
            if (dictionaryPrototypeBlocksStandard(row.object().?.prototype)) return null;
        }
        if (row.object().?.prototype.tag == @intFromEnum(Tag.null_value)) return null;
    }

    if (tableAsciiUnitsEqual(units, "__proto__")) {
        return switch (row_tag) {
            .dictionary => blk: {
                if (runtime.cachedStandardProperty(table_standard_property_cache_object, "__proto__")) |value| break :blk @as(?Value, value);
                const value = try runtime.createDictionary(&.{});
                try runtime.cacheStandardProperty(table_standard_property_cache_object, "__proto__", value);
                break :blk @as(?Value, value);
            },
            .array => blk: {
                if (runtime.cachedStandardProperty(table_standard_property_cache_array, "__proto__")) |value| break :blk @as(?Value, value);
                const value = try runtime.createArray(&.{});
                try runtime.cacheStandardProperty(table_standard_property_cache_array, "__proto__", value);
                break :blk @as(?Value, value);
            },
            .static_utf8_string, .utf16_string => blk: {
                if (runtime.cachedStandardProperty(table_standard_property_cache_string, "__proto__")) |value| break :blk @as(?Value, value);
                const value = try runtime.createString(&.{});
                try runtime.cacheStandardProperty(table_standard_property_cache_string, "__proto__", value);
                break :blk @as(?Value, value);
            },
            .function => @as(?Value, try tableInheritedFunctionWithCallback(runtime, table_standard_property_cache_function, "__proto__", "", promiseSentinel)),
            else => null,
        };
    }

    if (tableAsciiUnitsEqual(units, "prototype") and row_tag == .function) {
        if (row.object().?.payload.function.prototype.tag != @intFromEnum(Tag.undefined)) return @as(?Value, row.object().?.payload.function.prototype);
        const prototype = try runtime.createDictionary(&.{ staticStringValue("constructor"), row });
        row.object().?.payload.function.prototype = prototype;
        return @as(?Value, prototype);
    }

    const constructor_name: ?[]const u8 = switch (row_tag) {
        .dictionary => "Object",
        .array => "Array",
        .static_utf8_string, .utf16_string => "String",
        .function => "Function",
        .number => "Number",
        .boolean => "Boolean",
        .bigint => "BigInt",
        .byte_buffer => switch (row.object().?.payload.byte_buffer.kind) {
            .buffer => "Buffer",
            .uint8_array => "Uint8Array",
            .array_buffer => "ArrayBuffer",
        },
        else => null,
    };
    if (constructor_name) |name| if (tableAsciiUnitsEqual(units, "constructor")) return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_constructor, name));

    if (row_tag == .byte_buffer) {
        const buffer = row.object().?.payload.byte_buffer;
        if (tableAsciiUnitsEqual(units, "byteLength")) return @as(?Value, numberValue(@floatFromInt(buffer.bytes.len)));
        if (tableAsciiUnitsEqual(units, "byteOffset")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, numberValue(@floatFromInt(buffer.byte_offset)));
        }
        if (tableAsciiUnitsEqual(units, "BYTES_PER_ELEMENT")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, numberValue(1));
        }
        if (tableAsciiUnitsEqual(units, "buffer")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, try runtime.createByteBufferBackingBuffer(buffer));
        }
        if (buffer.kind == .array_buffer) {
            if (tableAsciiUnitsEqual(units, "maxByteLength")) return @as(?Value, numberValue(@floatFromInt(buffer.bytes.len)));
            if (tableAsciiUnitsEqual(units, "resizable") or tableAsciiUnitsEqual(units, "detached")) {
                return @as(?Value, .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 });
            }
            if (tableInheritedMethodName(units, &table_byte_buffer_array_buffer_method_names)) |name| return @as(?Value, try tableInheritedByteBufferMethod(runtime, row, name));
        } else {
            if (buffer.kind == .buffer and tableAsciiUnitsEqual(units, "parent")) {
                return @as(?Value, try runtime.createByteBufferBackingBuffer(buffer));
            }
            if (buffer.kind == .buffer and tableAsciiUnitsEqual(units, "offset")) {
                return @as(?Value, numberValue(@floatFromInt(buffer.byte_offset)));
            }
            if (buffer.kind == .buffer and tableAsciiUnitsEqual(units, "toLocaleString")) {
                return @as(?Value, try tableInheritedByteBufferMethod(runtime, row, "toString"));
            }
            if (tableInheritedMethodName(units, &table_byte_buffer_typed_array_method_names)) |name| return @as(?Value, try tableInheritedByteBufferMethod(runtime, row, name));
            if (buffer.kind == .buffer) {
                if (tableInheritedMethodName(units, &table_byte_buffer_buffer_enumerable_property_names)) |name| {
                    if (!tableAsciiUnitsEqual(units, "parent") and !tableAsciiUnitsEqual(units, "offset")) {
                        return @as(?Value, try tableInheritedByteBufferMethod(runtime, row, tableBufferEnumerableFunctionName(name)));
                    }
                }
            }
        }
    }

    const supports_object_prototype = row_tag == .dictionary or row_tag == .array or row_tag == .static_utf8_string or
        row_tag == .utf16_string or row_tag == .function or row_tag == .number or row_tag == .boolean or row_tag == .bigint or row_tag == .byte_buffer;
    if (row_tag == .array) {
        if (tableInheritedMethodName(units, &table_array_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_array, name));
    }
    if (row_tag == .static_utf8_string or row_tag == .utf16_string) {
        if (tableInheritedMethodName(units, &table_string_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_string, name));
    }
    if (row_tag == .function) {
        if (tableInheritedMethodName(units, &table_function_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_function, name));
    }
    if (row_tag == .number) {
        if (tableInheritedMethodName(units, &table_number_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_number, name));
    }
    if (row_tag == .boolean) {
        if (tableInheritedMethodName(units, &table_boolean_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_boolean, name));
    }
    if (row_tag == .bigint) {
        if (tableInheritedMethodName(units, &table_bigint_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_bigint, name));
    }
    if (supports_object_prototype) {
        if (tableInheritedMethodName(units, &table_object_prototype_method_names)) |name| return @as(?Value, try tableInheritedFunction(runtime, table_standard_property_cache_object, name));
    }
    return null;
}

/// Read a row property using the same useful subset of JavaScript's
/// `row[column]` semantics used by the official table commands.  In
/// particular, strings expose UTF-16 code units and dictionaries only expose
/// own properties.  Accessing a missing row is deliberately an error: the
/// upstream implementation evaluates `a[i][col]`, so null/undefined rows do
/// not silently produce undefined.
pub fn tableRowProperty(runtime: *Runtime, row: Value, column: Value) !Value {
    const row_tag: Tag = @enumFromInt(row.tag);
    if (row_tag == .undefined or row_tag == .null_value) {
        try setTableRowPropertyFailure(runtime, row, column);
        return error.TableRowMissing;
    }
    const key_units = try valueUtf16Alloc(runtime, column);
    defer runtime.allocator.free(key_units);
    if (row_tag == .array) {
        const object = row.object() orelse return error.InvalidArray;
        if (object.payload != .array) return error.InvalidArray;
        if (std.mem.eql(u16, key_units, &table_length_key)) return numberValue(@floatFromInt(object.payload.array.items.len));
        if (runtime.aotArrayOwnPropertyGetUnits(object, key_units)) |value| return value;
        if (try tableInheritedProperty(runtime, row, row_tag, key_units)) |value| return value;
        return .{};
    }
    if (row_tag == .dictionary) {
        const object = row.object() orelse return error.InvalidDictionary;
        if (object.payload != .dictionary) return error.InvalidDictionary;
        for (object.payload.dictionary.items) |entry| {
            if (try tablePropertyKeyEqual(runtime, entry.key, key_units)) return entry.value;
        }
        if (try tableInheritedProperty(runtime, row, row_tag, key_units)) |value| return value;
        return .{};
    }
    if (row_tag == .byte_buffer) {
        const object = row.object() orelse return error.InvalidByteBuffer;
        if (object.payload != .byte_buffer) return error.InvalidByteBuffer;
        const allows_standard_prototype = aotByteBufferAllowsStandardPrototype(row);
        if (runtime.aotObjectOwnPropertyGetUnits(object, key_units)) |value| return value;
        if (tablePropertyIndex(key_units) == null) {
            if (try tableInheritedProperty(runtime, row, row_tag, key_units)) |value| return value;
        }
        if (allows_standard_prototype and std.mem.eql(u16, key_units, &table_length_key)) {
            return if (object.payload.byte_buffer.kind == .array_buffer)
                .{}
            else
                numberValue(@floatFromInt(object.payload.byte_buffer.bytes.len));
        }
        if (object.payload.byte_buffer.kind != .array_buffer) if (tablePropertyIndex(key_units)) |index| {
            return if (index < object.payload.byte_buffer.bytes.len)
                numberValue(@floatFromInt(object.payload.byte_buffer.bytes[index]))
            else
                .{};
        };
        return .{};
    }
    if (isString(row)) {
        const units = try valueUtf16Alloc(runtime, row);
        defer runtime.allocator.free(units);
        if (std.mem.eql(u16, key_units, &table_length_key)) return numberValue(@floatFromInt(units.len));
        const index = tablePropertyIndex(key_units) orelse {
            if (try tableInheritedProperty(runtime, row, row_tag, key_units)) |value| return value;
            return .{};
        };
        if (index >= units.len) return .{};
        return try runtime.createString(&.{units[index]});
    }
    if (row_tag == .function) {
        const object = row.object() orelse return error.InvalidFunction;
        if (object.payload != .function) return error.InvalidFunction;
        if (runtime.aotObjectOwnPropertyGetUnits(object, key_units)) |value| return value;
        if (std.mem.eql(u16, key_units, &table_length_key)) {
            // The official compiler exposes Nadesiko functions through a
            // rest-argument wrapper, so Function.length is zero regardless of
            // the language-level arity used by lnako's call dispatcher.
            return numberValue(0);
        }
        if (std.mem.eql(u16, key_units, &.{ 'n', 'a', 'm', 'e' })) {
            // Lowering gives anonymous functions an internal __lambda$ name,
            // while JavaScript Function.name remains the empty string.
            const name = if (std.mem.indexOf(u8, object.payload.function.name, "__lambda$") != null)
                &.{}
            else
                object.payload.function.name;
            const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, name);
            defer runtime.allocator.free(units);
            return runtime.createString(units);
        }
    }
    if (row_tag == .promise) {
        const object = row.object() orelse return error.InvalidContainer;
        if (object.payload != .promise) return error.InvalidContainer;
        if (runtime.aotObjectOwnPropertyGetUnits(object, key_units)) |value| return value;
        return .{};
    }
    if (try tableInheritedProperty(runtime, row, row_tag, key_units)) |value| return value;
    // Number, boolean, bigint, etc. have no relevant own indexed properties
    // in this runtime; JavaScript returns undefined here.
    return .{};
}

pub fn setTableRowPropertyFailure(runtime: *Runtime, row: Value, column: Value) !void {
    var rooted = [_]Value{ row, column };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    const column_units = try valueUtf16Alloc(runtime, rooted[1]);
    defer runtime.allocator.free(column_units);
    const column_utf8 = try utf16FailureMessageUtf8Alloc(runtime.allocator, column_units);
    defer runtime.allocator.free(column_utf8);
    const receiver = if (rooted[0].tag == @intFromEnum(Tag.null_value)) "null" else "undefined";
    const message = try std.fmt.allocPrint(runtime.allocator, "Cannot read properties of {s} (reading '{s}')", .{ receiver, column_utf8 });
    defer runtime.allocator.free(message);
    runtime.setFailureText(message);
}

pub fn tablePropertyKeyEqual(runtime: *Runtime, key: Value, units: []const u16) !bool {
    const key_units = try valueUtf16Alloc(runtime, key);
    defer runtime.allocator.free(key_units);
    return std.mem.eql(u16, key_units, units);
}

/// Parse only canonical array-index property names.  Number("01") is 1, but
/// JavaScript's property key "01" is not an array index, so using Number here
/// would incorrectly read row[1].
pub fn tablePropertyIndex(units: []const u16) ?usize {
    if (units.len == 0) return null;
    if (units.len > 1 and units[0] == '0') return null;
    var result: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        const digit: usize = unit - '0';
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, digit) catch return null;
    }
    // Keep the ECMAScript array-index boundary exact: 2^32 - 1 is not an
    // array index (it is distinct from the length property).
    const max_array_index: usize = @as(usize, std.math.maxInt(u32)) - 1;
    if (result > max_array_index) return null;
    return result;
}

pub fn tableColumnCountBuiltin(runtime: *Runtime, source: Value) !Value {
    var roots = [_]Value{ source, numberValue(1) };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    for (rows.items) |row| {
        const length = try tableRowProperty(runtime, row, staticStringValue("length"));
        if (try compareValues(runtime, .greater, length, roots[1])) roots[1] = length;
    }
    return roots[1];
}

pub fn tableSearchBuiltin(runtime: *Runtime, source: Value, column: Value, row_value: Value, needle: Value) !Value {
    var roots = [_]Value{ source, column, row_value, needle, row_value, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    while (try compareValues(runtime, .less, roots[4], numberValue(@floatFromInt(rows.items.len)))) {
        roots[5] = try tableRowProperty(runtime, roots[0], roots[4]);
        const cell = try tableRowProperty(runtime, roots[5], roots[1]);
        if (try strictEqual(runtime, cell, roots[3])) return roots[4];
        roots[4] = try incrementTableSearchRow(runtime, roots[4]);
    }
    return numberValue(-1);
}

pub fn tableColumnIterationCount(runtime: *Runtime, value: Value) !usize {
    const number = if (value.tag == @intFromEnum(Tag.bigint))
        value.object().?.payload.bigint.toF64()
    else
        try valueToNumberRuntime(runtime, value);
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number > @as(f64, @floatFromInt(safe_array_element_limit))) return error.ArraySizeLimitExceeded;
    return @intFromFloat(@ceil(number));
}

pub fn tableTransposeBuiltin(runtime: *Runtime, source: Value, rotate: bool) !Value {
    var roots = [_]Value{ source, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[1] = try tableColumnCountBuiltin(runtime, roots[0]);
    const columns = try tableColumnIterationCount(runtime, roots[1]);
    const cells = std.math.mul(usize, columns, rows.items.len) catch return error.ArraySizeLimitExceeded;
    if (cells > safe_array_element_limit) return error.ArraySizeLimitExceeded;
    roots[2] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[2]);
    try result.ensureTotalCapacity(runtime.allocator, columns);
    for (0..columns) |column| {
        roots[3] = try runtime.createArray(&.{});
        const row_result = try arrayItems(roots[3]);
        try row_result.ensureTotalCapacity(runtime.allocator, rows.items.len);
        for (0..rows.items.len) |offset| {
            const row_index = if (rotate) rows.items.len - offset - 1 else offset;
            roots[4] = try tableRowProperty(runtime, rows.items[row_index], numberValue(@floatFromInt(column)));
            if (!rotate and roots[4].tag == @intFromEnum(Tag.undefined)) roots[4] = staticStringValue("");
            try row_result.append(runtime.allocator, roots[4]);
        }
        try result.append(runtime.allocator, roots[3]);
    }
    return roots[2];
}

pub fn tableDictionaryHasKey(runtime: *Runtime, dictionary: Value, key: Value) !bool {
    const entries = &dictionary.object().?.payload.dictionary;
    for (entries.items) |entry| if (try strictEqual(runtime, entry.key, key)) return true;
    return false;
}

pub fn tableIsObjectPrototypeKey(units: []const u16) bool {
    const keys = [_][]const u8{
        "constructor",
        "__defineGetter__",
        "__defineSetter__",
        "hasOwnProperty",
        "__lookupGetter__",
        "__lookupSetter__",
        "isPrototypeOf",
        "propertyIsEnumerable",
        "toString",
        "valueOf",
        "__proto__",
        "toLocaleString",
    };
    for (keys) |key| {
        if (units.len != key.len) continue;
        var matches = true;
        for (units, key) |unit, byte| if (unit != byte) {
            matches = false;
            break;
        };
        if (matches) return true;
    }
    return false;
}

pub fn tableUniqueBuiltin(runtime: *Runtime, source: Value, column: Value) !Value {
    var roots = [_]Value{ source, column, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[2] = try runtime.createArray(&.{});
    roots[3] = try runtime.createDictionary(&.{});
    const result = try arrayItems(roots[2]);
    for (rows.items) |row| {
        roots[4] = try tableRowProperty(runtime, row, roots[1]);
        const units = try valueUtf16Alloc(runtime, roots[4]);
        defer runtime.allocator.free(units);
        if (tableIsObjectPrototypeKey(units)) continue;
        roots[5] = try runtime.createString(units);
        if (try tableDictionaryHasKey(runtime, roots[3], roots[5])) continue;
        try roots[3].object().?.payload.dictionary.append(runtime.allocator, .{ .key = roots[5], .value = numberValue(1) });
        try result.append(runtime.allocator, row);
    }
    return roots[2];
}

pub fn tableInsertColumnBuiltin(runtime: *Runtime, source: Value, column: Value, values: Value) !Value {
    var roots = [_]Value{ source, column, values, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[3] = try runtime.createArray(&.{});
    if (rows.items.len == 0) return roots[3];
    const source_object = roots[0].object().?;
    try runtime.normalizeAotArrayPresence(source_object);
    const result = try arrayItems(roots[3]);
    const positive = try compareValues(runtime, .greater, roots[1], numberValue(0));
    for (rows.items, 0..) |row, row_index| {
        // Array.prototype.forEach skips holes in the outer table.
        if (!runtime.aotArrayIsPresent(source_object, row_index)) continue;
        roots[4] = try runtime.createArray(&.{});
        const new_row = try arrayItems(roots[4]);
        const row_tag = @as(Tag, @enumFromInt(row.tag));
        if (row_tag == .array) {
            const row_object = row.object().?;
            try runtime.normalizeAotArrayPresence(row_object);
            const row_items = try arrayItems(row);
            const total = std.math.add(usize, row_items.items.len, 1) catch return error.ArraySizeLimitExceeded;
            if (total > safe_array_element_limit) return error.ArraySizeLimitExceeded;
            try new_row.ensureTotalCapacity(runtime.allocator, total);
            if (positive) {
                const prefix = try spliceIndexRuntime(runtime, roots[1], row_items.items.len);
                for (row_items.items[0..prefix], 0..) |item, index| try appendAotArraySlot(runtime, roots[4].object().?, item, runtime.aotArrayIsPresent(row_object, index));
            }
        } else if (isString(row)) {
            const row_units = try valueUtf16Alloc(runtime, row);
            defer runtime.allocator.free(row_units);
            try new_row.ensureTotalCapacity(runtime.allocator, 3);
            if (positive) {
                const prefix = try spliceIndexRuntime(runtime, roots[1], row_units.len);
                roots[5] = try runtime.createString(row_units[0..prefix]);
                try new_row.append(runtime.allocator, roots[5]);
            }
        } else if (row_tag == .byte_buffer) {
            const buffer = row.object().?.payload.byte_buffer;
            try new_row.ensureTotalCapacity(runtime.allocator, 3);
            if (positive) {
                const prefix = try spliceIndexRuntime(runtime, roots[1], buffer.bytes.len);
                roots[5] = try aotByteBufferSlice(runtime, buffer, 0, prefix);
                try new_row.append(runtime.allocator, roots[5]);
            }
        } else return error.ArrayExpected;
        if (roots[2].tag == @intFromEnum(Tag.array)) {
            const value_items = try arrayItems(roots[2]);
            roots[6] = if (row_index < value_items.items.len) value_items.items[row_index] else .{};
        } else {
            roots[6] = try tableRowProperty(runtime, roots[2], numberValue(@floatFromInt(row_index)));
        }
        try new_row.append(runtime.allocator, roots[6]);
        if (row_tag == .array) {
            const row_items = try arrayItems(row);
            const suffix = try spliceIndexRuntime(runtime, roots[1], row_items.items.len);
            const row_object = row.object().?;
            for (row_items.items[suffix..], suffix..) |item, index| try appendAotArraySlot(runtime, roots[4].object().?, item, runtime.aotArrayIsPresent(row_object, index));
        } else if (isString(row)) {
            const row_units = try valueUtf16Alloc(runtime, row);
            defer runtime.allocator.free(row_units);
            const suffix = try spliceIndexRuntime(runtime, roots[1], row_units.len);
            roots[5] = try runtime.createString(row_units[suffix..]);
            try new_row.append(runtime.allocator, roots[5]);
        } else {
            const buffer = row.object().?.payload.byte_buffer;
            const suffix = try spliceIndexRuntime(runtime, roots[1], buffer.bytes.len);
            roots[5] = try aotByteBufferSlice(runtime, buffer, suffix, buffer.bytes.len);
            try new_row.append(runtime.allocator, roots[5]);
        }
        try result.append(runtime.allocator, roots[4]);
    }
    return roots[3];
}

pub fn aotByteBufferSlice(runtime: *Runtime, buffer: ByteBuffer, start: usize, end: usize) !Value {
    const bytes = buffer.bytes[start..end];
    return switch (buffer.kind) {
        .buffer => runtime.createByteBufferView(buffer, start, end),
        .uint8_array => runtime.createUint8Array(bytes),
        .array_buffer => runtime.createArrayBuffer(bytes),
    };
}

pub fn tableDeleteColumnBuiltin(runtime: *Runtime, source: Value, column: Value) !Value {
    var roots = [_]Value{ source, column, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const rows = try arrayItems(roots[0]);
    roots[2] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[2]);
    const source_object = roots[0].object().?;
    try runtime.normalizeAotArrayPresence(source_object);
    for (rows.items, 0..) |row, row_index| {
        if (!runtime.aotArrayIsPresent(source_object, row_index)) continue;
        const row_items = try arrayItems(row);
        const row_object = row.object().?;
        try runtime.normalizeAotArrayPresence(row_object);
        const index = try spliceIndexRuntime(runtime, roots[1], row_items.items.len);
        roots[3] = try runtime.createArray(&.{});
        const new_row = try arrayItems(roots[3]);
        try new_row.ensureTotalCapacity(runtime.allocator, row_items.items.len - @intFromBool(index < row_items.items.len));
        for (row_items.items, 0..) |item, item_index| if (item_index != index) try appendAotArraySlot(runtime, roots[3].object().?, item, runtime.aotArrayIsPresent(row_object, item_index));
        try result.append(runtime.allocator, roots[3]);
    }
    return roots[2];
}

pub fn tableColumnSumBuiltin(runtime: *Runtime, source: Value, column: Value) !Value {
    var roots = [_]Value{ source, column, numberValue(0), .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const source_object = roots[0].object().?;
    try runtime.normalizeAotArrayPresence(source_object);
    for (source_object.payload.array.items, 0..) |row, index| {
        if (!runtime.aotArrayIsPresent(source_object, index)) continue;
        roots[3] = try tableRowProperty(runtime, row, roots[1]);
        roots[2] = try jsAdd(runtime, roots[2], roots[3]);
    }
    return roots[2];
}

/// The table regex commands use `new RegExp(s)`, unlike the general regexp
/// commands whose `/pattern/flags` notation is part of their public API.
/// Keep this validation outside the row loop so an invalid pattern fails even
/// for an empty table or an already-out-of-range start row.
pub fn tableRegexpPatternUnitsAlloc(runtime: *Runtime, pattern: Value) ![]u16 {
    if (pattern.tag == @intFromEnum(Tag.undefined)) return runtime.allocator.alloc(u16, 0);
    return valueUtf16Alloc(runtime, pattern);
}

pub fn tableRegexpSearchBuiltin(runtime: *Runtime, source: Value, row_value: Value, column: Value, pattern: Value) !Value {
    var roots = [_]Value{ source, column, row_value, pattern, row_value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const pattern_units = try tableRegexpPatternUnitsAlloc(runtime, roots[3]);
    defer runtime.allocator.free(pattern_units);
    var compiled = regexp.RawPattern.init(runtime.allocator, pattern_units, false) catch |failure| {
        try setRegexpCompileFailureMessage(runtime, pattern_units, false, failure);
        return failure;
    };
    defer compiled.deinit();
    const rows = try arrayItems(roots[0]);
    while (try compareValues(runtime, .less, roots[4], numberValue(@floatFromInt(rows.items.len)))) {
        roots[5] = try tableRowProperty(runtime, roots[0], roots[4]);
        roots[6] = try tableRowProperty(runtime, roots[5], roots[1]);
        const source_units = try valueUtf16Alloc(runtime, roots[6]);
        defer runtime.allocator.free(source_units);
        if (try compiled.matches(source_units)) return roots[4];
        roots[4] = try incrementTableSearchRow(runtime, roots[4]);
    }
    return numberValue(-1);
}

pub fn tableRegexpPickupBuiltin(runtime: *Runtime, source: Value, column: Value, pattern: Value) !Value {
    var roots = [_]Value{ source, column, pattern, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const pattern_units = try tableRegexpPatternUnitsAlloc(runtime, roots[2]);
    defer runtime.allocator.free(pattern_units);
    var compiled = regexp.RawPattern.init(runtime.allocator, pattern_units, false) catch |failure| {
        try setRegexpCompileFailureMessage(runtime, pattern_units, false, failure);
        return failure;
    };
    defer compiled.deinit();
    roots[3] = try runtime.createArray(&.{});
    const result = try arrayItems(roots[3]);
    for ((try arrayItems(roots[0])).items) |row| {
        roots[4] = try tableRowProperty(runtime, row, roots[1]);
        const source_units = try valueUtf16Alloc(runtime, roots[4]);
        defer runtime.allocator.free(source_units);
        if (!(try compiled.matches(source_units))) continue;
        // Upstream uses row.slice(0): create a new shallow array and retain
        // each element's identity. String.slice(0) returns the same immutable
        // string value; rows without slice fail only after they match.
        if (row.tag == @intFromEnum(Tag.array)) {
            roots[5] = try runtime.createArray(&.{});
            const copy = try arrayItems(roots[5]);
            const row_object = row.object().?;
            try runtime.normalizeAotArrayPresence(row_object);
            const row_items = try arrayItems(row);
            try copy.ensureTotalCapacity(runtime.allocator, row_items.items.len);
            for (row_items.items, 0..) |item, index| {
                try appendAotArraySlot(runtime, roots[5].object().?, item, runtime.aotArrayIsPresent(row_object, index));
            }
        } else if (isString(row)) {
            roots[5] = row;
        } else if (row.tag == @intFromEnum(Tag.byte_buffer)) {
            const buffer = row.object().?.payload.byte_buffer;
            roots[5] = switch (buffer.kind) {
                .buffer => try runtime.createByteBufferView(buffer, 0, buffer.bytes.len),
                .uint8_array => try runtime.createUint8Array(buffer.bytes),
                .array_buffer => try runtime.createArrayBuffer(buffer.bytes),
            };
        } else return error.ArrayExpected;
        try result.append(runtime.allocator, roots[5]);
    }
    return roots[3];
}

pub fn incrementTableSearchRow(runtime: *Runtime, row: Value) !Value {
    if (row.tag == @intFromEnum(Tag.bigint)) {
        var one = try BigInt.init(runtime.allocator, 1);
        defer one.deinit();
        return runtime.ownBigInt(try row.object().?.payload.bigint.add(runtime.allocator, one));
    }
    return numberValue(try valueToNumberRuntime(runtime, row) + 1);
}

pub fn compareTableRowsBuiltin(
    runtime: *Runtime,
    left: Value,
    left_present: bool,
    right: Value,
    right_present: bool,
    column: Value,
    numeric: bool,
    left_cell: *Value,
    right_cell: *Value,
) !std.math.Order {
    if (!left_present) return if (!right_present) .eq else .gt;
    if (!right_present) return .lt;
    if (left.tag == @intFromEnum(Tag.undefined)) return if (right.tag == @intFromEnum(Tag.undefined)) .eq else .gt;
    if (right.tag == @intFromEnum(Tag.undefined)) return .lt;
    left_cell.* = try tableRowProperty(runtime, left, column);
    right_cell.* = try tableRowProperty(runtime, right, column);
    // The official comparator returns before relational conversion when the
    // two selected cells are JavaScript-strictly equal. This is observable
    // for repeated object cells with a custom valueOf/toString method.
    if (!numeric and try strictEqual(runtime, left_cell.*, right_cell.*)) return .eq;
    if (numeric) {
        // Match the official `ns - ms` comparator.  Arithmetic performs
        // ToNumeric first, so mixed BigInt/Number cells reject with the
        // JavaScript mixing error and a BigInt result is rejected when the
        // sort algorithm converts the comparator result to Number.
        const difference = try arithmetic(runtime, .subtract, left_cell.*, right_cell.*);
        const number = try valueToNumberRuntime(runtime, difference);
        return if (std.math.isNan(number)) .eq else std.math.order(number, 0);
    }
    // The official table comparator returns `1` whenever `ns < ms` is false
    // after its strict-equality fast path.  This includes NaN and undefined
    // cells, whose non-antisymmetric result must not be collapsed to equal.
    return (try relationalOrder(runtime, left_cell.*, right_cell.*)) orelse .gt;
}

pub fn tableSortBuiltin(runtime: *Runtime, source: Value, column: Value, numeric: bool) !Value {
    // The official commands mutate and return the original table.  Keep the
    // current row and both compared cells rooted because property lookup and
    // ToPrimitive/Number conversion may allocate and trigger collection.
    var roots = [_]Value{ source, column, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const object = roots[0].object().?;
    try runtime.normalizeAotArrayPresence(object);
    const rows = &object.payload.array;
    const original_length = rows.items.len;
    if (original_length < v8_small_callback_sort_limit) {
        // Array.prototype.sort collects the indexed rows before it invokes
        // the comparator. Keep the small-table path detached so a cell's
        // valueOf/toString side effect cannot invalidate the values that the
        // official sort already collected.
        const temporary = try runtime.allocator.dupe(Value, rows.items);
        defer runtime.allocator.free(temporary);
        const temporary_presence = try runtime.allocator.dupe(bool, object.array_presence.items);
        defer runtime.allocator.free(temporary_presence);
        const root_count = std.math.add(usize, 5, original_length) catch return error.ArrayTooLarge;
        const root_values = try runtime.allocator.alloc(Value, root_count);
        defer runtime.allocator.free(root_values);
        root_values[0] = source;
        root_values[1] = column;
        root_values[2] = .{};
        root_values[3] = .{};
        root_values[4] = .{};
        std.mem.copyForwards(Value, root_values[5..], temporary);
        var detached_roots = RootFrame{};
        runtime.pushRoots(&detached_roots, root_values.ptr, root_values.len);
        defer runtime.popRoots(&detached_roots);
        try v8SmallTableSortBuiltin(
            runtime,
            temporary,
            temporary_presence,
            &root_values[1],
            numeric,
            &root_values[2],
            &root_values[3],
            &root_values[4],
        );
        if (rows.items.len < original_length) {
            const old_length = rows.items.len;
            try rows.resize(runtime.allocator, original_length);
            @memset(rows.items[old_length..], .{});
            try object.array_presence.resize(runtime.allocator, original_length);
            @memset(object.array_presence.items[old_length..], false);
        }
        std.mem.copyForwards(Value, rows.items[0..original_length], temporary);
        std.mem.copyForwards(bool, object.array_presence.items[0..original_length], temporary_presence);
        return root_values[0];
    }
    // The large path uses the same V8 TimSort as Array.prototype.sort. Keep
    // the collected rows and both merge buffers detached from the live table
    // while property lookup and numeric conversion can allocate or mutate it.
    const temporary = try runtime.allocator.dupe(Value, rows.items);
    defer runtime.allocator.free(temporary);
    const temporary_second = try runtime.allocator.dupe(Value, temporary);
    defer runtime.allocator.free(temporary_second);
    const temporary_presence = try runtime.allocator.dupe(bool, object.array_presence.items);
    defer runtime.allocator.free(temporary_presence);
    const temporary_second_presence = try runtime.allocator.dupe(bool, temporary_presence);
    defer runtime.allocator.free(temporary_second_presence);
    const root_count = std.math.add(usize, 5, std.math.mul(usize, original_length, 2) catch return error.ArrayTooLarge) catch return error.ArrayTooLarge;
    const root_values = try runtime.allocator.alloc(Value, root_count);
    defer runtime.allocator.free(root_values);
    root_values[0] = source;
    root_values[1] = column;
    root_values[2] = .{};
    root_values[3] = .{};
    root_values[4] = .{};
    std.mem.copyForwards(Value, root_values[5 .. 5 + original_length], temporary);
    std.mem.copyForwards(Value, root_values[5 + original_length ..], temporary_second);
    var detached_roots = RootFrame{};
    runtime.pushRoots(&detached_roots, root_values.ptr, root_values.len);
    defer runtime.popRoots(&detached_roots);
    var sort_context = V8SortContext{ .table = .{
        .column_root = &root_values[1],
        .numeric = numeric,
        .left_cell_root = &root_values[3],
        .right_cell_root = &root_values[4],
    } };
    try v8TimSortArrayCallback(
        runtime,
        temporary,
        temporary_presence,
        temporary_second,
        temporary_second_presence,
        &sort_context,
        &root_values[2],
    );
    if (rows.items.len < original_length) {
        const old_length = rows.items.len;
        try rows.resize(runtime.allocator, original_length);
        @memset(rows.items[old_length..], .{});
        try object.array_presence.resize(runtime.allocator, original_length);
        @memset(object.array_presence.items[old_length..], false);
    }
    std.mem.copyForwards(Value, rows.items[0..original_length], temporary);
    std.mem.copyForwards(bool, object.array_presence.items[0..original_length], temporary_presence);
    return root_values[0];
}

pub fn v8SmallTableSortBuiltin(
    runtime: *Runtime,
    items: []Value,
    presence: []bool,
    column_root: *Value,
    numeric: bool,
    pivot_root: *Value,
    left_cell_root: *Value,
    right_cell_root: *Value,
) !void {
    // V8 uses CountAndMakeRun followed by BinaryInsertionSort for arrays
    // shorter than 64 elements. Table sort delegates to Array.sort too, so
    // the observable property conversion order follows the same path.
    if (items.len < 2) return;

    var run_length: usize = 2;
    const first_order = try compareTableRowsBuiltin(
        runtime,
        items[1],
        presence[1],
        items[0],
        presence[0],
        column_root.*,
        numeric,
        left_cell_root,
        right_cell_root,
    );
    if (first_order == .lt) {
        while (run_length < items.len) : (run_length += 1) {
            const order = try compareTableRowsBuiltin(
                runtime,
                items[run_length],
                presence[run_length],
                items[run_length - 1],
                presence[run_length - 1],
                column_root.*,
                numeric,
                left_cell_root,
                right_cell_root,
            );
            if (order != .lt) break;
        }
        var left: usize = 0;
        var right: usize = run_length - 1;
        while (left < right) : ({
            left += 1;
            right -= 1;
        }) {
            std.mem.swap(Value, &items[left], &items[right]);
            std.mem.swap(bool, &presence[left], &presence[right]);
        }
    } else {
        while (run_length < items.len) : (run_length += 1) {
            const order = try compareTableRowsBuiltin(
                runtime,
                items[run_length],
                presence[run_length],
                items[run_length - 1],
                presence[run_length - 1],
                column_root.*,
                numeric,
                left_cell_root,
                right_cell_root,
            );
            if (order == .lt) break;
        }
    }

    var start = run_length;
    while (start < items.len) : (start += 1) {
        pivot_root.* = items[start];
        const pivot_presence = presence[start];
        var left: usize = 0;
        var right: usize = start;
        while (left < right) {
            const middle = left + (right - left) / 2;
            const order = try compareTableRowsBuiltin(
                runtime,
                pivot_root.*,
                pivot_presence,
                items[middle],
                presence[middle],
                column_root.*,
                numeric,
                left_cell_root,
                right_cell_root,
            );
            if (order == .lt) right = middle else left = middle + 1;
        }
        var cursor = start;
        while (cursor > left) : (cursor -= 1) {
            items[cursor] = items[cursor - 1];
            presence[cursor] = presence[cursor - 1];
        }
        items[left] = pivot_root.*;
        presence[left] = pivot_presence;
    }
}

pub fn tableBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const source: Value = if (arguments.len > 0) arguments[0] else .{};
    if (source.tag != @intFromEnum(Tag.array)) return error.ArrayExpected;
    switch (command) {
        .table_sort, .table_numeric_sort => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableSortBuiltin(runtime, source, arguments[1], command == .table_numeric_sort);
        },
        .table_row_count => return numberValue(@floatFromInt((try arrayItems(source)).items.len)),
        .table_column_count => return tableColumnCountBuiltin(runtime, source),
        .table_column => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            var roots = [_]Value{ source, arguments[1], .{}, .{} };
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            roots[2] = try runtime.createArray(&.{});
            const source_object = roots[0].object().?;
            try runtime.normalizeAotArrayPresence(source_object);
            const result_object = roots[2].object().?;
            for (source_object.payload.array.items, 0..) |row, index| {
                if (!runtime.aotArrayIsPresent(source_object, index)) {
                    try appendAotArraySlot(runtime, result_object, .{}, false);
                    continue;
                }
                roots[3] = try tableRowProperty(runtime, row, roots[1]);
                try appendAotArraySlot(runtime, result_object, roots[3], true);
            }
            return roots[2];
        },
        .table_pickup, .table_exact_pickup => {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            var roots = [_]Value{ source, arguments[1], arguments[2], .{}, .{} };
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            roots[3] = try runtime.createArray(&.{});
            const result = try arrayItems(roots[3]);
            const source_object = roots[0].object().?;
            try runtime.normalizeAotArrayPresence(source_object);
            for (source_object.payload.array.items, 0..) |row, index| {
                // Array.prototype.filter skips holes but still invokes its
                // callback for an explicit undefined row.
                if (!runtime.aotArrayIsPresent(source_object, index)) continue;
                roots[4] = try tableRowProperty(runtime, row, roots[1]);
                const matches = if (command == .table_exact_pickup)
                    try strictEqual(runtime, roots[4], roots[2])
                else blk: {
                    const cell_units = try valueUtf16Alloc(runtime, roots[4]);
                    defer runtime.allocator.free(cell_units);
                    const needle_units = try valueUtf16Alloc(runtime, roots[2]);
                    defer runtime.allocator.free(needle_units);
                    break :blk std.mem.indexOf(u16, cell_units, needle_units) != null;
                };
                if (matches) try result.append(runtime.allocator, row);
            }
            return roots[3];
        },
        .table_search => {
            if (arguments.len < 4) return error.InvalidArgumentCount;
            return tableSearchBuiltin(runtime, source, arguments[1], arguments[2], arguments[3]);
        },
        .table_regexp_search => {
            if (arguments.len < 4) return error.InvalidArgumentCount;
            return tableRegexpSearchBuiltin(runtime, source, arguments[1], arguments[2], arguments[3]);
        },
        .table_regexp_pickup => {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            return tableRegexpPickupBuiltin(runtime, source, arguments[1], arguments[2]);
        },
        .table_transpose, .table_rotate => return tableTransposeBuiltin(runtime, source, command == .table_rotate),
        .table_unique => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableUniqueBuiltin(runtime, source, arguments[1]);
        },
        .table_insert_column => {
            if (arguments.len < 3) return error.InvalidArgumentCount;
            return tableInsertColumnBuiltin(runtime, source, arguments[1], arguments[2]);
        },
        .table_delete_column => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableDeleteColumnBuiltin(runtime, source, arguments[1]);
        },
        .table_column_sum => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            return tableColumnSumBuiltin(runtime, source, arguments[1]);
        },
        else => return error.UnknownCommand,
    }
}

pub const CloneState = struct {
    active: std.ArrayList(*Object) = .empty,

    pub fn deinit(self: *CloneState, allocator: std.mem.Allocator) void {
        self.active.deinit(allocator);
    }
};

/// `配列複製` is the upstream JSON.stringify/JSON.parse operation.  Keep the
/// JSON-specific rules here instead of using the general value copier: NaN and
/// infinities become null, undefined/functions disappear from objects (and
/// become null in arrays), and cycles/BigInt are errors.
pub fn deepCloneBuiltin(runtime: *Runtime, source: Value) !Value {
    if (source.tag == @intFromEnum(Tag.undefined) or source.tag == @intFromEnum(Tag.function)) return error.InvalidJsonCloneValue;
    var state: CloneState = .{};
    defer state.deinit(runtime.allocator);
    return deepCloneValue(runtime, source, &state);
}

pub fn deepCloneValue(runtime: *Runtime, source: Value, state: *CloneState) !Value {
    return switch (@as(Tag, @enumFromInt(source.tag))) {
        .undefined, .function => .{},
        .null_value, .boolean => source,
        .number => blk: {
            const number: f64 = @bitCast(source.payload);
            break :blk if (std.math.isFinite(number)) numberValue(if (number == 0) 0 else number) else .{ .tag = @intFromEnum(Tag.null_value) };
        },
        .bigint => error.CannotSerializeBigInt,
        .byte_buffer => blk: {
            const serialized = try jsonEncodeBuiltin(runtime, source, false);
            var roots = [_]Value{serialized};
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            break :blk try jsonDecodeBuiltin(runtime, roots[0]);
        },
        .static_utf8_string, .utf16_string => blk: {
            const units = try valueUtf16Alloc(runtime, source);
            defer runtime.allocator.free(units);
            break :blk try runtime.createString(units);
        },
        .array => {
            const object = source.object() orelse return error.InvalidArray;
            if (object.payload != .array) return error.InvalidArray;
            for (state.active.items) |active| if (active == object) return error.CircularCloneValue;
            try state.active.append(runtime.allocator, object);
            defer _ = state.active.pop();
            const result = try runtime.createArray(&.{});
            var roots = [_]Value{result};
            var frame: RootFrame = .{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            const values = object.payload.array.items;
            try roots[0].object().?.payload.array.ensureTotalCapacity(runtime.allocator, values.len);
            for (values) |item| {
                var cloned = try deepCloneValue(runtime, item, state);
                if (cloned.tag == @intFromEnum(Tag.undefined) or cloned.tag == @intFromEnum(Tag.function)) cloned = .{ .tag = @intFromEnum(Tag.null_value) };
                try roots[0].object().?.payload.array.append(runtime.allocator, cloned);
            }
            return roots[0];
        },
        .dictionary => {
            const object = source.object() orelse return error.InvalidDictionary;
            if (object.payload != .dictionary) return error.InvalidDictionary;
            for (state.active.items) |active| if (active == object) return error.CircularCloneValue;
            try state.active.append(runtime.allocator, object);
            defer _ = state.active.pop();
            const result = try runtime.createDictionary(&.{});
            var roots = [_]Value{result};
            var frame: RootFrame = .{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            for (object.payload.dictionary.items) |entry| {
                const cloned = try deepCloneValue(runtime, entry.value, state);
                if (cloned.tag == @intFromEnum(Tag.undefined) or cloned.tag == @intFromEnum(Tag.function)) continue;
                try runtime.setDictionary(&roots[0].object().?.payload.dictionary, entry.key, cloned);
            }
            return roots[0];
        },
        .iterator, .promise => runtime.createDictionary(&.{}),
        .binding_cell => unreachable,
    };
}
