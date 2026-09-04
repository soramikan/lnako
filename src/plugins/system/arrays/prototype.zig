const std = @import("std");
const value_mod = @import("../../../runtime/value.zig");

const Value = value_mod.Value;
const Runtime = value_mod.Runtime;
const ByteKind = value_mod.ByteKind;

pub fn byteBufferSlice(runtime: *Runtime, buffer: *value_mod.ByteBuffer, start: usize, end: usize) !Value {
    const bytes = buffer.bytes[start..end];
    return switch (buffer.kind) {
        .buffer => runtime.createByteBufferView(buffer, start, end),
        .uint8_array => runtime.createUint8Array(bytes),
        .array_buffer => runtime.createArrayBuffer(bytes),
    };
}

pub fn isObjectPrototypeKey(units: []const u16) bool {
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

pub const standard_property_cache_object: u8 = 1;
pub const standard_property_cache_function: u8 = 2;
pub const standard_property_cache_array: u8 = 3;
pub const standard_property_cache_string: u8 = 4;
pub const standard_property_cache_constructor: u8 = 5;
pub const standard_property_cache_buffer: u8 = 6;
pub const standard_property_cache_uint8_array: u8 = 7;
pub const standard_property_cache_array_buffer: u8 = 8;
pub const standard_property_cache_number: u8 = 9;
pub const standard_property_cache_boolean: u8 = 10;
pub const standard_property_cache_bigint: u8 = 11;

pub const objectPrototypeMethodNames = [_][]const u8{
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

pub const functionPrototypeMethodNames = [_][]const u8{ "apply", "bind", "call", "toString" };

pub const arrayPrototypeMethodNames = [_][]const u8{
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

pub const stringPrototypeMethodNames = [_][]const u8{
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

pub const numberPrototypeMethodNames = [_][]const u8{
    "toExponential",
    "toFixed",
    "toLocaleString",
    "toPrecision",
    "toString",
    "valueOf",
};

pub const booleanPrototypeMethodNames = [_][]const u8{ "toString", "valueOf" };

pub const bigintPrototypeMethodNames = [_][]const u8{ "toLocaleString", "toString", "valueOf" };

pub const byteBufferTypedArrayMethodNames = [_][]const u8{
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

pub const byteBufferBufferEnumerablePropertyNames = [_][]const u8{
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

pub const byteBufferEmptyFunctionNames = [_][]const u8{
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

pub const byteBufferArrayBufferMethodNames = [_][]const u8{
    "slice",
    "resize",
    "transfer",
    "transferToFixedLength",
};

pub fn asciiUnitsEqual(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |unit, byte| if (unit != byte) return false;
    return true;
}

pub fn inheritedMethodName(units: []const u16, names: []const []const u8) ?[]const u8 {
    for (names) |name| if (asciiUnitsEqual(units, name)) return name;
    return null;
}

pub fn bufferEnumerableFunctionName(name: []const u8) []const u8 {
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
    for (byteBufferEmptyFunctionNames) |empty_name| if (std.mem.eql(u8, name, empty_name)) return "";
    return name;
}

pub fn tableInheritedFunctionWithCallback(
    runtime: *Runtime,
    cache_kind: u8,
    cache_name: []const u8,
    function_name: []const u8,
    callback: value_mod.NativeCallback,
) !Value {
    if (runtime.cachedStandardProperty(cache_kind, cache_name)) |value| return value;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var name_value = try runtime.stringUtf8(function_name);
    try roots.protect(&name_value);
    const result = try runtime.createNativeFunction(name_value.string, 0, callback, &.{});
    try runtime.cacheStandardProperty(cache_kind, cache_name, result);
    return result;
}

pub fn tableInheritedFunction(runtime: *Runtime, cache_kind: u8, name: []const u8) !Value {
    return tableInheritedFunctionWithCallback(runtime, cache_kind, name, name, tableInheritedFunctionSentinel);
}

pub fn tableInheritedFunctionSentinel(_: *Runtime, _: []const Value) !Value {
    return .undefined;
}

pub fn byteBufferUnboundSlice(runtime: *Runtime, _: []const Value) !Value {
    try runtime.setFailureMessage("Cannot read properties of undefined (reading 'subarray')");
    return error.NotCallable;
}

pub fn tableInheritedByteBufferMethod(runtime: *Runtime, receiver: Value, name: []const u8) !Value {
    const cache_kind: u8 = switch (receiver.bytes.kind) {
        .buffer => standard_property_cache_buffer,
        .uint8_array => standard_property_cache_uint8_array,
        .array_buffer => standard_property_cache_array_buffer,
    };
    if (receiver == .bytes and receiver.bytes.kind == .buffer and std.mem.eql(u8, name, "slice")) {
        return tableInheritedFunctionWithCallback(runtime, cache_kind, name, name, byteBufferUnboundSlice);
    }
    return tableInheritedFunction(runtime, cache_kind, name);
}

pub fn byteBufferAllowsStandardPrototype(buffer: *const value_mod.ByteBuffer) bool {
    return switch (buffer.prototype) {
        .null_value => false,
        .dictionary => |prototype| !value_mod.dictionaryPrototypeBlocksStandard(prototype),
        else => true,
    };
}

pub fn tableInheritedProperty(runtime: *Runtime, source: Value, units: []const u16) !?Value {
    if (source == .dictionary and source.dictionary.prototype != .undefined) {
        if (asciiUnitsEqual(units, "__proto__")) return source.dictionary.prototype;
        if (value_mod.dictionaryPrototypePropertyUnits(source.dictionary, units)) |value| return value;
        if (value_mod.dictionaryPrototypeBlocksStandard(source.dictionary)) return null;
    }
    if (source == .array and source.array.prototype != .undefined) {
        if (asciiUnitsEqual(units, "__proto__")) return if (source.array.prototype == .null_value) .undefined else source.array.prototype;
        if (value_mod.arrayPrototypePropertyUnits(source.array, units)) |value| return value;
        if (value_mod.arrayPrototypeBlocksStandard(source.array)) return null;
    }
    if (source == .bytes and source.bytes.prototype != .undefined) {
        if (asciiUnitsEqual(units, "__proto__")) return if (source.bytes.prototype == .null_value) null else source.bytes.prototype;
        if (source.bytes.prototype == .dictionary) {
            if (value_mod.dictionaryOwnPropertyUnits(source.bytes.prototype.dictionary, units)) |value| return value;
            if (value_mod.dictionaryPrototypePropertyUnits(source.bytes.prototype.dictionary, units)) |value| return value;
            if (value_mod.dictionaryPrototypeBlocksStandard(source.bytes.prototype.dictionary)) return null;
        }
        if (source.bytes.prototype == .null_value) return null;
    }

    if (asciiUnitsEqual(units, "__proto__")) {
        return switch (source) {
            .dictionary => blk: {
                if (runtime.cachedStandardProperty(standard_property_cache_object, "__proto__")) |value| break :blk @as(?Value, value);
                const value = try runtime.createDictionary();
                try runtime.cacheStandardProperty(standard_property_cache_object, "__proto__", value);
                break :blk @as(?Value, value);
            },
            .array => blk: {
                if (runtime.cachedStandardProperty(standard_property_cache_array, "__proto__")) |value| break :blk @as(?Value, value);
                const value = try runtime.createArray();
                try runtime.cacheStandardProperty(standard_property_cache_array, "__proto__", value);
                break :blk @as(?Value, value);
            },
            .string => blk: {
                if (runtime.cachedStandardProperty(standard_property_cache_string, "__proto__")) |value| break :blk @as(?Value, value);
                const value = try runtime.stringCodeUnits(&.{});
                try runtime.cacheStandardProperty(standard_property_cache_string, "__proto__", value);
                break :blk @as(?Value, value);
            },
            .function => @as(?Value, try tableInheritedFunctionWithCallback(runtime, standard_property_cache_function, "__proto__", "", tableInheritedFunctionSentinel)),
            else => null,
        };
    }

    if (asciiUnitsEqual(units, "prototype") and source == .function) {
        return switch (source.function.kind) {
            .ir => blk: {
                if (source.function.prototype != .undefined) break :blk @as(?Value, source.function.prototype);

                var rooted_source = source;
                var roots = runtime.rootFrame();
                defer roots.deinit();
                try roots.protect(&rooted_source);
                var prototype = try runtime.createDictionary();
                try roots.protect(&prototype);
                var constructor_key = try runtime.stringUtf8("constructor");
                try roots.protect(&constructor_key);
                try prototype.dictionary.set(constructor_key.string, rooted_source);
                rooted_source.function.prototype = prototype;
                break :blk @as(?Value, prototype);
            },
            .native, .external => null,
        };
    }

    const constructor_name: ?[]const u8 = switch (source) {
        .dictionary => "Object",
        .array => "Array",
        .string => "String",
        .function => "Function",
        .number => "Number",
        .boolean => "Boolean",
        .bigint => "BigInt",
        .bytes => switch (source.bytes.kind) {
            .buffer => "Buffer",
            .uint8_array => "Uint8Array",
            .array_buffer => "ArrayBuffer",
        },
        else => null,
    };
    if (constructor_name) |name| if (asciiUnitsEqual(units, "constructor")) return @as(?Value, try tableInheritedFunction(runtime, standard_property_cache_constructor, name));

    if (source == .bytes) {
        const buffer = source.bytes;
        if (asciiUnitsEqual(units, "byteLength")) return @as(?Value, .{ .number = @floatFromInt(buffer.bytes.len) });
        if (asciiUnitsEqual(units, "byteOffset")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, .{ .number = @floatFromInt(buffer.byte_offset) });
        }
        if (asciiUnitsEqual(units, "BYTES_PER_ELEMENT")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, .{ .number = 1 });
        }
        if (asciiUnitsEqual(units, "buffer")) {
            if (buffer.kind == .array_buffer) return null;
            return @as(?Value, try runtime.createByteBufferBackingBuffer(buffer));
        }
        if (buffer.kind == .array_buffer) {
            if (asciiUnitsEqual(units, "maxByteLength")) return @as(?Value, .{ .number = @floatFromInt(buffer.bytes.len) });
            if (asciiUnitsEqual(units, "resizable") or asciiUnitsEqual(units, "detached")) return @as(?Value, .{ .boolean = false });
            if (inheritedMethodName(units, &byteBufferArrayBufferMethodNames)) |name| return @as(?Value, try tableInheritedByteBufferMethod(runtime, source, name));
        } else {
            if (buffer.kind == .buffer and asciiUnitsEqual(units, "parent")) {
                return @as(?Value, try runtime.createByteBufferBackingBuffer(buffer));
            }
            if (buffer.kind == .buffer and asciiUnitsEqual(units, "offset")) {
                return @as(?Value, .{ .number = @floatFromInt(buffer.byte_offset) });
            }
            if (buffer.kind == .buffer and asciiUnitsEqual(units, "toLocaleString")) {
                return @as(?Value, try tableInheritedByteBufferMethod(runtime, source, "toString"));
            }
            if (inheritedMethodName(units, &byteBufferTypedArrayMethodNames)) |name| return @as(?Value, try tableInheritedByteBufferMethod(runtime, source, name));
            if (buffer.kind == .buffer) {
                if (inheritedMethodName(units, &byteBufferBufferEnumerablePropertyNames)) |name| {
                    if (!asciiUnitsEqual(units, "parent") and !asciiUnitsEqual(units, "offset")) {
                        return @as(?Value, try tableInheritedByteBufferMethod(runtime, source, bufferEnumerableFunctionName(name)));
                    }
                }
            }
        }
    }

    if (source == .array) {
        if (inheritedMethodName(units, &arrayPrototypeMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, standard_property_cache_array, name));
    }
    if (source == .string) {
        if (inheritedMethodName(units, &stringPrototypeMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, standard_property_cache_string, name));
    }
    if (source == .function) {
        if (inheritedMethodName(units, &functionPrototypeMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, standard_property_cache_function, name));
    }
    if (source == .number) {
        if (inheritedMethodName(units, &numberPrototypeMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, standard_property_cache_number, name));
    }
    if (source == .boolean) {
        if (inheritedMethodName(units, &booleanPrototypeMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, standard_property_cache_boolean, name));
    }
    if (source == .bigint) {
        if (inheritedMethodName(units, &bigintPrototypeMethodNames)) |name| return @as(?Value, try tableInheritedFunction(runtime, standard_property_cache_bigint, name));
    }
    if (inheritedMethodName(units, &objectPrototypeMethodNames)) |name| {
        if (source == .dictionary or source == .array or source == .string or source == .function or
            source == .number or source == .boolean or source == .bigint or source == .bytes) return @as(?Value, try tableInheritedFunction(runtime, standard_property_cache_object, name));
    }
    return null;
}

pub fn hasStandardInheritedProperty(runtime: *Runtime, source: Value, units: []const u16) !bool {
    return (try tableInheritedProperty(runtime, source, units)) != null;
}

pub fn standardInheritedProperty(runtime: *Runtime, source: Value, units: []const u16) !?Value {
    return try tableInheritedProperty(runtime, source, units);
}
