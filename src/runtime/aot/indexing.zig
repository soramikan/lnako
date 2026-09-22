const std = @import("std");
const aot_state = @import("state.zig");
const runtime_core = @import("runtime_core.zig");

const Tag = aot_state.Tag;
const numberValue = aot_state.numberValue;
const staticStringValue = aot_state.staticStringValue;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const valueIndex = aot_state.valueIndex;
const aotCanonicalArrayIndex = aot_state.aotCanonicalArrayIndex;
const sameKey = aot_state.sameKey;
const isString = aot_state.isString;
const staticUtf8 = aot_state.staticUtf8;
const staticUtf8EqualsUtf16 = aot_state.staticUtf8EqualsUtf16;
const aotByteBufferAllowsStandardPrototype = aot_state.aotByteBufferAllowsStandardPrototype;
const aotByteBufferScalarProperty = aot_state.aotByteBufferScalarProperty;
const aotByteBufferReadOnlyProperty = aot_state.aotByteBufferReadOnlyProperty;
const tableInheritedProperty = aot_state.tableInheritedProperty;
const tablePropertyIndex = aot_state.tablePropertyIndex;
const tableRowProperty = aot_state.tableRowProperty;

const Value = runtime_core.Value;
const Object = runtime_core.Object;
const RootFrame = runtime_core.RootFrame;
const AotDictionary = runtime_core.AotDictionary;
const Runtime = runtime_core.Runtime;

pub fn indexGet(self: *Runtime, container: Value, key: Value) Value {
    if (container.tag == @intFromEnum(Tag.utf16_string)) {
        const index = valueIndex(key) orelse return .{};
        return stringAt(self, container, index);
    }
    // 公式はJavaScriptのまま `undefined[key]` / `null[key]` がTypeErrorになる
    if (container.tag == @intFromEnum(Tag.undefined) or container.tag == @intFromEnum(Tag.null_value)) {
        self.setIndexReadFailure(container, key);
        return .{};
    }
    const object = container.object() orelse return .{};
    return switch (object.payload) {
        .byte_buffer => {
            var rooted = [_]Value{ container, key };
            var frame = RootFrame{};
            self.pushRoots(&frame, &rooted, rooted.len);
            defer self.popRoots(&frame);
            const source = rooted[0];
            const rooted_buffer = source.object().?.payload.byte_buffer;
            const key_units = valueUtf16Alloc(self, rooted[1]) catch |failure| {
                self.setFailure(failure);
                return .{};
            };
            defer self.allocator.free(key_units);
            if (aotObjectOwnPropertyGetUnits(self, source.object().?, key_units)) |value| return value;
            if (tablePropertyIndex(key_units) == null) {
                const inherited = tableInheritedProperty(self, source, .byte_buffer, key_units) catch |failure| {
                    self.setFailure(failure);
                    return .{};
                };
                if (inherited) |value| return value;
            }
            if (!aotByteBufferAllowsStandardPrototype(source)) {
                const index = tablePropertyIndex(key_units) orelse return .{};
                return if (rooted_buffer.kind == .array_buffer or index >= rooted_buffer.bytes.len)
                    .{}
                else
                    numberValue(@floatFromInt(rooted_buffer.bytes[index]));
            }
            if (sameKey(rooted[1], staticStringValue("length"))) {
                return if (rooted_buffer.kind == .array_buffer) .{} else numberValue(@floatFromInt(rooted_buffer.bytes.len));
            }
            if (sameKey(rooted[1], staticStringValue("buffer")) and rooted_buffer.kind != .array_buffer) {
                return self.createByteBufferBackingBuffer(rooted_buffer) catch |failure| {
                    self.setFailure(failure);
                    return .{};
                };
            }
            if (aotByteBufferScalarProperty(rooted_buffer, rooted[1])) |value| return value;
            const index = tablePropertyIndex(key_units) orelse return .{};
            return if (rooted_buffer.kind == .array_buffer or index >= rooted_buffer.bytes.len) .{} else numberValue(@floatFromInt(rooted_buffer.bytes[index]));
        },
        .array => aotArrayPropertyGet(self, object, key),
        .dictionary => blk: {
            var rooted = [_]Value{ container, key, .{} };
            var dictionary_frame = RootFrame{};
            self.pushRoots(&dictionary_frame, &rooted, rooted.len);
            defer self.popRoots(&dictionary_frame);
            const dictionary = &rooted[0].object().?.payload.dictionary;
            // A string key resolves straight through the index without
            // materializing UTF-16 units; other keys keep the text path
            // because the prototype walk needs it either way.
            if (isString(rooted[1])) {
                if (dictionary.findByKey(rooted[1])) |index| break :blk dictionary.entries.items[index].value;
            }
            const key_units = valueUtf16Alloc(self, rooted[1]) catch |failure| {
                self.setFailure(failure);
                break :blk .{};
            };
            defer self.allocator.free(key_units);
            if (!isString(rooted[1])) {
                if (dictionary.findByUnits(key_units)) |index| break :blk dictionary.entries.items[index].value;
            }
            rooted[2] = (tableInheritedProperty(self, rooted[0], .dictionary, key_units) catch |failure| {
                self.setFailure(failure);
                break :blk .{};
            }) orelse .{};
            break :blk rooted[2];
        },
        .function => tableRowProperty(self, container, key) catch |failure| {
            self.setFailure(failure);
            return .{};
        },
        .promise => blk: {
            var rooted = [_]Value{ container, key };
            var promise_frame = RootFrame{};
            self.pushRoots(&promise_frame, &rooted, rooted.len);
            defer self.popRoots(&promise_frame);
            const key_units = valueUtf16Alloc(self, rooted[1]) catch |failure| {
                self.setFailure(failure);
                break :blk .{};
            };
            defer self.allocator.free(key_units);
            break :blk aotObjectOwnPropertyGetUnits(self, rooted[0].object().?, key_units) orelse .{};
        },
        else => .{},
    };
}

pub fn destructureGet(_: *Runtime, source: Value, index: usize) Value {
    if (source.tag == @intFromEnum(Tag.array)) {
        const items = source.object().?.payload.array.items;
        return if (index < items.len) items[index] else .{};
    }
    return if (index == 0) source else .{};
}

pub fn indexSet(self: *Runtime, container: Value, key: Value, value: Value) !void {
    const object = container.object() orelse return switch (@as(Tag, @enumFromInt(container.tag))) {
        .undefined, .null_value => error.InvalidContainer,
        else => {},
    };
    switch (object.payload) {
        .array => {
            try aotArrayPropertySet(self, object, key, value);
        },
        .dictionary => |*entries| {
            var rooted = [_]Value{ container, key, value };
            var frame = RootFrame{};
            self.pushRoots(&frame, &rooted, rooted.len);
            defer self.popRoots(&frame);
            rooted[1] = try propertyKey(self, rooted[1]);
            var has_own_prototype_key = false;
            if (sameKey(rooted[1], staticStringValue("__proto__"))) has_own_prototype_key = entries.findByKey(rooted[1]) != null;
            if (!has_own_prototype_key and sameKey(rooted[1], staticStringValue("__proto__"))) {
                if (rooted[2].tag == @intFromEnum(Tag.null_value) or rooted[2].object() != null) {
                    object.prototype = rooted[2];
                }
                return;
            }
            try setDictionary(self, entries, rooted[1], rooted[2]);
        },
        .byte_buffer => |*buffer| {
            if (buffer.kind != .array_buffer) if (valueIndex(key)) |index| {
                const number = try valueToNumberRuntime(self, value);
                const byte: u8 = if (!std.math.isFinite(number) or number == 0)
                    0
                else
                    @intFromFloat(@mod(@trunc(number), 256));
                if (index < buffer.bytes.len) buffer.bytes[index] = byte;
                return;
            };
            const key_units = valueUtf16Alloc(self, key) catch |failure| {
                self.setFailure(failure);
                return failure;
            };
            defer self.allocator.free(key_units);
            if (std.mem.eql(u16, key_units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }) and
                aotObjectOwnPropertyGetUnits(self, object, key_units) == null)
            {
                if (value.tag == @intFromEnum(Tag.null_value) or value.object() != null) object.prototype = value;
                return;
            }
            if (aotByteBufferReadOnlyProperty(buffer.kind, key_units)) return;
            try setAotOwnProperty(self, container, object, key, value);
        },
        .function => try setAotFunctionProperty(self, container, object, key, value),
        .promise => try setAotOwnProperty(self, container, object, key, value),
        .utf16_string, .bigint, .iterator, .binding_cell => {},
    }
}

pub fn setAotOwnProperty(self: *Runtime, container: Value, object: *Object, key: Value, value: Value) !void {
    var rooted = [_]Value{ container, key, value, .{} };
    var frame = RootFrame{};
    self.pushRoots(&frame, &rooted, rooted.len);
    defer self.popRoots(&frame);
    rooted[3] = try propertyKey(self, rooted[1]);
    try setDictionary(self, &object.array_properties, rooted[3], rooted[2]);
}

pub fn setAotFunctionProperty(self: *Runtime, container: Value, object: *Object, key: Value, value: Value) !void {
    var rooted = [_]Value{ container, key, value, .{} };
    var frame = RootFrame{};
    self.pushRoots(&frame, &rooted, rooted.len);
    defer self.popRoots(&frame);
    rooted[3] = try propertyKey(self, rooted[1]);
    // Function.prototype's length and name are non-writable own properties.
    // Keep writes ignored in AOT just as the interpreter does, rather than
    // allowing an own-property shadow to change the built-in value.
    if (sameKey(rooted[3], staticStringValue("length")) or sameKey(rooted[3], staticStringValue("name"))) return;
    try setDictionary(self, &object.array_properties, rooted[3], rooted[2]);
}

pub fn aotArrayPropertyGet(self: *Runtime, object: *const Object, key: Value) Value {
    // Canonical index keys resolve without materializing the property
    // name: numeric keys keep `key` as a plain Value and numeric strings
    // are scanned in place instead of being re-encoded for the lookup.
    if (aotCanonicalArrayIndex(key)) |index| {
        if (index < object.payload.array.items.len) return object.payload.array.items[index];
        // Out-of-range indices still consult the prototype chain, which
        // needs the textual key.  Fall through to the general path.
    }
    var rooted = [_]Value{
        .{ .tag = @intFromEnum(Tag.array), .payload = @intFromPtr(object) },
        key,
    };
    var frame = RootFrame{};
    self.pushRoots(&frame, &rooted, rooted.len);
    defer self.popRoots(&frame);
    const key_units = valueUtf16Alloc(self, rooted[1]) catch return .{};
    defer self.allocator.free(key_units);
    return aotArrayPropertyGetUnits(self, rooted[0].object().?, key_units);
}

pub fn aotArrayIsPresent(_: *Runtime, object: *const Object, index: usize) bool {
    if (object.payload.array.items.len <= index) return false;
    return if (index < object.array_presence.items.len) object.array_presence.items[index] else true;
}

pub fn normalizeAotArrayPresence(self: *Runtime, object: *Object) !void {
    if (object.array_presence.items.len >= object.payload.array.items.len) return;
    const previous_len = object.array_presence.items.len;
    try object.array_presence.resize(self.allocator, object.payload.array.items.len);
    // Low-level append sites predate presence tracking; existing slots are
    // dense values when the metadata is first synchronized.
    @memset(object.array_presence.items[previous_len..], true);
}

pub fn aotArraySetIndex(self: *Runtime, object: *Object, index: usize, value: Value) !void {
    try normalizeAotArrayPresence(self, object);
    if (index >= object.payload.array.items.len) {
        const previous_capacity = object.payload.array.capacity;
        const previous_len = object.payload.array.items.len;
        try object.payload.array.resize(self.allocator, index + 1);
        if (object.payload.array.capacity > previous_capacity) {
            self.counters.array_grows +|= 1;
            self.counters.array_copied_bytes +|= previous_len * @sizeOf(Value);
        }
        @memset(object.payload.array.items[previous_len..], .{});
        try object.array_presence.resize(self.allocator, index + 1);
        @memset(object.array_presence.items[previous_len..], false);
    }
    object.payload.array.items[index] = value;
    object.array_presence.items[index] = true;
}

pub fn aotArrayDeleteIndex(self: *Runtime, object: *Object, index: usize) !bool {
    if (index >= object.payload.array.items.len) return false;
    try normalizeAotArrayPresence(self, object);
    object.payload.array.items[index] = .{};
    object.array_presence.items[index] = false;
    return true;
}

pub fn aotArrayAppend(self: *Runtime, object: *Object, value: Value) !void {
    try normalizeAotArrayPresence(self, object);
    const previous_capacity = object.payload.array.capacity;
    const previous_len = object.payload.array.items.len;
    try object.payload.array.append(self.allocator, value);
    self.counters.array_appends +|= 1;
    if (object.payload.array.capacity > previous_capacity) {
        self.counters.array_grows +|= 1;
        self.counters.array_copied_bytes +|= previous_len * @sizeOf(Value);
    }
    errdefer _ = object.payload.array.pop();
    try object.array_presence.append(self.allocator, true);
}

pub fn aotArrayPropertySet(self: *Runtime, object: *Object, key: Value, value: Value) !void {
    // Canonical index keys skip property-name materialization entirely:
    // a number Value already carries its index, and numeric strings are
    // scanned without re-encoding.  The `length` and `__proto__` special
    // cases below can never be produced by a canonical index.
    if (aotCanonicalArrayIndex(key)) |index| return aotArraySetIndex(self, object, index, value);
    var rooted = [_]Value{
        .{ .tag = @intFromEnum(Tag.array), .payload = @intFromPtr(object) },
        key,
        value,
    };
    var frame = RootFrame{};
    self.pushRoots(&frame, &rooted, rooted.len);
    defer self.popRoots(&frame);
    const key_units = try valueUtf16Alloc(self, rooted[1]);
    defer self.allocator.free(key_units);
    if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthAssignment;
    if (aotCanonicalArrayIndexUnits(self, key_units)) |index| {
        try aotArraySetIndex(self, rooted[0].object().?, index, rooted[2]);
        return;
    }
    const normalized = try propertyKey(self, rooted[1]);
    if (std.mem.eql(u16, key_units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }) and
        aotArrayOwnPropertyGetUnits(self, rooted[0].object().?, key_units) == null)
    {
        if (rooted[2].tag == @intFromEnum(Tag.null_value) or rooted[2].object() != null) rooted[0].object().?.prototype = rooted[2];
        return;
    }
    try setDictionary(self, &rooted[0].object().?.array_properties, normalized, rooted[2]);
}

pub fn aotArrayPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) Value {
    if (std.mem.eql(u16, key_units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return numberValue(@floatFromInt(object.payload.array.items.len));
    if (aotArrayOwnPropertyGetUnits(self, object, key_units)) |value| return value;
    const source = Value{ .tag = @intFromEnum(Tag.array), .payload = @intFromPtr(object) };
    return (tableInheritedProperty(self, source, .array, key_units) catch |failure| {
        self.setFailure(failure);
        return .{};
    }) orelse .{};
}

pub fn aotArrayOwnPropertyGetUnits(self: *Runtime, object: *const Object, key_units: []const u16) ?Value {
    if (aotCanonicalArrayIndexUnits(self, key_units)) |index| return if (index < object.payload.array.items.len) object.payload.array.items[index] else null;
    return aotObjectOwnPropertyGetUnits(self, object, key_units);
}

/// Resolve an own named property shared by all extensible AOT objects.
/// Array indices remain handled by `aotArrayOwnPropertyGetUnits` before
/// reaching this helper.
pub fn aotObjectOwnPropertyGetUnits(_: *Runtime, object: *const Object, key_units: []const u16) ?Value {
    // Counter updates are diagnostics, not logical mutation; callers
    // only ever supply live objects, so the const is a signature detail.
    const properties = @constCast(&object.array_properties);
    const index = properties.findByUnits(key_units) orelse return null;
    return properties.entries.items[index].value;
}

pub fn aotPropertyKeyMatchesUnits(_: *Runtime, key: Value, units: []const u16) bool {
    return switch (@as(Tag, @enumFromInt(key.tag))) {
        .static_utf8_string => staticUtf8EqualsUtf16(staticUtf8(key), units),
        .utf16_string => std.mem.eql(u16, key.object().?.payload.utf16_string, units),
        else => false,
    };
}

pub fn aotCanonicalArrayIndexUnits(_: *Runtime, units: []const u16) ?usize {
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var result: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, unit - '0') catch return null;
    }
    return if (result <= 4_294_967_294) result else null;
}

pub fn iteratorHasNext(self: *Runtime, value: Value) bool {
    const object = value.object() orelse return false;
    if (object.payload != .iterator) return false;
    const iterator = &object.payload.iterator;
    // for..in互換: 反復開始時の添字・キー集合を上限とし、配列の穴や反復中に
    // 削除された添字・キーは到達時点で飛ばす。開始後の追加要素は列挙しない。
    switch (iterator.kind) {
        .array, .bytes, .properties => {
            const keys_len = if (iterator.keys.object()) |keys| keys.payload.array.items.len else 0;
            const total = iterator.count + keys_len;
            while (iterator.index < total) {
                if (iterator.index < iterator.count) {
                    // 添字領域は配列のみ穴・削除があり得る。bytesの添字と
                    // properties種別（count==0）は存在チェックを要しない。
                    if (iterator.kind != .array or aotArrayIsPresent(self, iterator.source.object().?, iterator.index)) break;
                } else {
                    const key = iterator.keys.object().?.payload.array.items[iterator.index - iterator.count];
                    if (iterator.source.object().?.array_properties.findByKey(key) != null) break;
                }
                iterator.index += 1;
            }
        },
        .dictionary => {
            while (iterator.index < iterator.count and iterator.source.object().?.payload.dictionary.findByKey(iterator.keys.object().?.payload.array.items[iterator.index]) == null) iterator.index += 1;
        },
        else => {},
    }
    return switch (iterator.kind) {
        .range => if (iterator.step > 0) iterator.current <= iterator.end else iterator.current >= iterator.end,
        .array, .bytes, .properties => blk: {
            const keys_len = if (iterator.keys.object()) |keys| keys.payload.array.items.len else 0;
            break :blk iterator.index < iterator.count + keys_len;
        },
        else => iterator.index < iterator.count,
    };
}

/// コレクション反復の要素束縛。公式convForeachは要素を「それ」へ束縛し、
/// `AをBで反復`の指定変数があればその変数へ（variable_target）、無ければ
/// 「対象」へ（value_target）書き込む。いずれのポインタもnullなら書き戻さない。
fn bindForeachElement(result: Value, sore_target: ?*Value, value_target: ?*Value, variable_target: ?*Value) void {
    if (sore_target) |target| target.* = result;
    if (variable_target) |target| {
        target.* = result;
    } else if (value_target) |target| {
        target.* = result;
    }
}

pub fn iteratorNext(self: *Runtime, value: Value, repeat_target: ?*Value, value_target: ?*Value, key_target: ?*Value, range_target: ?*Value, sore_target: ?*Value) Value {
    const object = value.object() orelse return .{};
    if (object.payload != .iterator) return .{};
    const iterator = &object.payload.iterator;
    if (!iteratorHasNext(self, value)) return .{};
    return switch (iterator.kind) {
        .repeat => blk: {
            iterator.index += 1;
            const result = numberValue(@floatFromInt(iterator.index));
            if (repeat_target) |target| target.* = result;
            break :blk result;
        },
        .range => blk: {
            const result = numberValue(iterator.current);
            iterator.current += iterator.step;
            if (range_target) |target| target.* = result;
            break :blk result;
        },
        .bytes => blk: {
            var result: Value = undefined;
            if (iterator.index >= iterator.count) {
                // ownプロパティ領域。キー名をkey_targetへ、値を要素として返す。
                const key = iterator.keys.object().?.payload.array.items[iterator.index - iterator.count];
                const found = iterator.source.object().?.array_properties.findByKey(key);
                result = if (found) |found_index| iterator.source.object().?.array_properties.entries.items[found_index].value else .{};
                if (key_target) |target| target.* = key;
            } else {
                result = numberValue(@floatFromInt(iterator.source.object().?.payload.byte_buffer.bytes[iterator.index]));
                if (key_target) |target| target.* = numberValue(@floatFromInt(iterator.index));
            }
            iterator.index += 1;
            bindForeachElement(result, sore_target, value_target, range_target);
            break :blk result;
        },
        .string => blk: {
            const result = stringAt(self, iterator.source, iterator.index);
            if (key_target) |target| target.* = numberValue(@floatFromInt(iterator.index));
            iterator.index += 1;
            bindForeachElement(result, sore_target, value_target, range_target);
            break :blk result;
        },
        .array => blk: {
            var result: Value = undefined;
            if (iterator.index >= iterator.count) {
                const key = iterator.keys.object().?.payload.array.items[iterator.index - iterator.count];
                const found = iterator.source.object().?.array_properties.findByKey(key);
                result = if (found) |found_index| iterator.source.object().?.array_properties.entries.items[found_index].value else .{};
                if (key_target) |target| target.* = key;
            } else {
                result = iterator.source.object().?.payload.array.items[iterator.index];
                if (key_target) |target| target.* = numberValue(@floatFromInt(iterator.index));
            }
            iterator.index += 1;
            bindForeachElement(result, sore_target, value_target, range_target);
            break :blk result;
        },
        .properties => blk: {
            const key = iterator.keys.object().?.payload.array.items[iterator.index - iterator.count];
            const found = iterator.source.object().?.array_properties.findByKey(key);
            const result: Value = if (found) |found_index| iterator.source.object().?.array_properties.entries.items[found_index].value else .{};
            if (key_target) |target| target.* = key;
            iterator.index += 1;
            bindForeachElement(result, sore_target, value_target, range_target);
            break :blk result;
        },
        .dictionary => blk: {
            const key = iterator.keys.object().?.payload.array.items[iterator.index];
            const found = iterator.source.object().?.payload.dictionary.findByKey(key);
            const result: Value = if (found) |found_index| iterator.source.object().?.payload.dictionary.entries.items[found_index].value else .{};
            if (key_target) |target| target.* = key;
            iterator.index += 1;
            bindForeachElement(result, sore_target, value_target, range_target);
            break :blk result;
        },
    };
}

pub fn stringAt(self: *Runtime, source: Value, index: usize) Value {
    const object = source.object() orelse return .{};
    if (object.payload != .utf16_string) return .{};
    const units = object.payload.utf16_string;
    if (index >= units.len) return .{};
    return self.createString(units[index .. index + 1]) catch .{};
}

/// Single mutation point for ordered key/value storage.  All insert,
/// replace, and delete paths reach `AotDictionary`, which keeps its
/// lookup index consistent and preserves insertion order for
/// enumeration.
pub fn setDictionary(self: *Runtime, entries: *AotDictionary, key: Value, value: Value) !void {
    try entries.set(self.allocator, key, value);
}

pub fn propertyKey(self: *Runtime, key: Value) !Value {
    return switch (@as(Tag, @enumFromInt(key.tag))) {
        .static_utf8_string, .utf16_string => key,
        else => blk: {
            const units = try valueUtf16Alloc(self, key);
            defer self.allocator.free(units);
            break :blk try self.createString(units);
        },
    };
}
