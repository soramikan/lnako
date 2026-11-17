//! Interpreterの索引・要素代入。`execute.zig`から切り出した凝集単位で、
//! 読み出し（getIndexed/getOne）と書き込み（elementSet/setOne）を対で保つ。
//! 挙動は切り出し前と同一で、Issue #233のbyte bufferの要素規則もここで扱う。

const std = @import("std");
const ir = @import("../../ir/nako_ir.zig");
const typed_array_key = @import("../typed_array_key.zig");
const plugin_system = @import("../../plugins/system.zig");
const system_constant = @import("../system_constant.zig");
const istate = @import("state.zig");
const shared = @import("shared.zig");
const prepared = @import("prepared.zig");

const Interpreter = istate.Interpreter;
const Value = shared.Value;
const Frame = shared.Frame;
const interpreterArrayIndex = shared.interpreterArrayIndex;
const valueIndex = shared.valueIndex;
const getArrayProperty = shared.getArrayProperty;
const isPrototypeObject = shared.isPrototypeObject;
const interpreterByteBufferReadOnlyProperty = shared.interpreterByteBufferReadOnlyProperty;
const ownProperty = shared.ownProperty;
const setOwnProperty = shared.setOwnProperty;
const localValue = shared.localValue;
const localCell = shared.localCell;
const localSlotCell = shared.localSlotCell;
const localSlotValue = shared.localSlotValue;

pub fn getIndexed(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    var current = self.operand(frame, instruction, 0);
    for (instruction.operands[1..]) |operand_id| current = try getOne(self, current, frame.values[operand_id]);
    return current;
}

pub fn getOne(self: *Interpreter, container: Value, key: Value) !Value {
    if (container == .undefined or container == .null_value) {
        // 公式はJavaScriptのまま `undefined[key]` / `null[key]` がTypeErrorになる
        try indexReadFailure(self, container, key);
        unreachable;
    }
    if (container == .bytes) {
        var rooted = [2]Value{ container, key };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&rooted[0]);
        try roots.protect(&rooted[1]);
        const container_root = rooted[0];
        var key_text = try self.runtime.valueToString(rooted[1]);
        try roots.protect(&key_text);
        if (ownProperty(container_root.bytes.properties.items, key_text.string.units)) |value| return value;
        if (interpreterArrayIndex(key_text.string.units) == null) {
            if (try plugin_system.arrays.standardInheritedProperty(self.runtime, container_root, key_text.string.units)) |value| return value;
        }
        if (!plugin_system.arrays.byteBufferAllowsStandardPrototype(container_root.bytes)) {
            if (container_root.bytes.kind == .array_buffer) return .undefined;
            const position = interpreterArrayIndex(key_text.string.units) orelse return .undefined;
            return container_root.bytes.get(position);
        }
        if (std.mem.eql(u16, key_text.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) {
            return if (container_root.bytes.kind == .array_buffer) .undefined else .{ .number = @floatFromInt(container_root.bytes.bytes.len) };
        }
        if (std.mem.eql(u16, key_text.string.units, &.{ 'b', 'u', 'f', 'f', 'e', 'r' })) {
            if (container_root.bytes.kind != .array_buffer) return self.runtime.createByteBufferBackingBuffer(container_root.bytes);
            return .undefined;
        }
        if (std.mem.eql(u16, key_text.string.units, &.{ 'b', 'y', 't', 'e', 'L', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(container_root.bytes.bytes.len) };
        if (std.mem.eql(u16, key_text.string.units, &.{ 'b', 'y', 't', 'e', 'O', 'f', 'f', 's', 'e', 't' })) {
            if (container_root.bytes.kind == .array_buffer) return .undefined;
            return .{ .number = @floatFromInt(container_root.bytes.byte_offset) };
        }
        if (std.mem.eql(u16, key_text.string.units, &.{ 'B', 'Y', 'T', 'E', 'S', '_', 'P', 'E', 'R', '_', 'E', 'L', 'E', 'M', 'E', 'N', 'T' })) {
            return if (container_root.bytes.kind == .array_buffer) .undefined else .{ .number = 1 };
        }
        if (container_root.bytes.kind == .array_buffer) return .undefined;
        const position = interpreterArrayIndex(key_text.string.units) orelse return .undefined;
        return container_root.bytes.get(position);
    }
    if (container == .array) return try getArrayProperty(self.runtime, container.array, key);
    if (container == .dictionary) {
        var rooted = [_]Value{ container, key, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&rooted[0]);
        try roots.protect(&rooted[1]);
        rooted[2] = try self.runtime.valueToString(rooted[1]);
        try roots.protect(&rooted[2]);
        if (rooted[0].dictionary.get(rooted[2].string)) |value| return value;
        if (try plugin_system.arrays.standardInheritedProperty(self.runtime, rooted[0], rooted[2].string.units)) |value| return value;
        return .undefined;
    }
    if (container == .function) {
        var rooted = [_]Value{ container, key, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&rooted[0]);
        try roots.protect(&rooted[1]);
        rooted[2] = try self.runtime.valueToString(rooted[1]);
        try roots.protect(&rooted[2]);
        if (ownProperty(rooted[0].function.properties.items, rooted[2].string.units)) |value| return value;
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = 0 };
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'n', 'a', 'm', 'e' })) {
            const lambda_marker = [_]u16{ '_', '_', 'l', 'a', 'm', 'b', 'd', 'a', '$' };
            const name = if (std.mem.indexOf(u16, rooted[0].function.name.units, &lambda_marker) != null)
                &.{}
            else
                rooted[0].function.name.units;
            return self.runtime.stringCodeUnits(name);
        }
        if (try plugin_system.arrays.standardInheritedProperty(self.runtime, rooted[0], rooted[2].string.units)) |value| return value;
        return .undefined;
    }
    if (container == .promise) {
        var rooted = [_]Value{ container, key, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&rooted[0]);
        try roots.protect(&rooted[1]);
        rooted[2] = try self.runtime.valueToString(rooted[1]);
        try roots.protect(&rooted[2]);
        return ownProperty(rooted[0].promise.properties.items, rooted[2].string.units) orelse .undefined;
    }
    if (container == .string) {
        const unit = container.string.codeUnitAt(try valueIndex(self.runtime, key)) orelse return .undefined;
        return self.runtime.stringCodeUnits(&.{unit});
    }
    return .undefined;
}

/// 代入先の変数を読み出し経路（load_local/load_global）と同じ優先順位で
/// 解決する。未解決なら null を返す。
fn resolveAssignmentContainer(
    self: *Interpreter,
    frame: *Frame,
    instruction: ir.Instruction,
    local_slot: prepared.LocalSlot,
    global_slot: prepared.GlobalSlot,
) ?Value {
    // local_targetは意味解析の束縛結果をそのまま使う。ローカル束縛
    // （関数内の __vars 相当）はload_localと同じくスロット値→スロット
    // セル→名前付きテーブルの順で探し、グローバルへフォールバックしない。
    if (instruction.local_target) {
        if (localSlotValue(frame, local_slot)) |value| return value;
        if (localSlotCell(frame, local_slot)) |cell| return cell.value;
        if (localValue(frame, instruction.name)) |value| return value;
        return null;
    }
    if (global_slot != prepared.no_global_slot) return self.globalSlotValue(global_slot);
    return self.globals.get(instruction.name);
}

/// 解決済みコンテナへの要素代入（公式convLet/convLetArrayの最終代入部相当）。
/// ルート変数の束縛と中間レベルの走査はlowering側でload/array_getとして
/// 先行emitされるため、ここでは container[key] = value のみを行う。
/// nullishなコンテナへの書き込みはsetOneの公式相当TypeErrorになる。
pub fn elementSet(
    self: *Interpreter,
    frame: *Frame,
    instruction: ir.Instruction,
) !void {
    if (instruction.operands.len != 3) return error.InvalidAssignment;
    const container = frame.values[instruction.operands[0]];
    const key = frame.values[instruction.operands[1]];
    const value = frame.values[instruction.operands[2]];
    try setOne(self, container, key, value);
}

/// DNCL互換: 未宣言・非配列の代入先へ30要素の0配列を自動初期化する
/// （公式convLetArrayのcheckInit相当）。
/// システム定数名（NULL・PI等）は公式同様リテラル相当に留まるため初期化しない。
pub fn ensureArrayVar(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
    return ensureArrayVarResolved(self, frame, instruction, prepared.no_local_slot, prepared.no_global_slot);
}

pub fn ensureArrayVarResolved(
    self: *Interpreter,
    frame: *Frame,
    instruction: ir.Instruction,
    local_slot: prepared.LocalSlot,
    global_slot: prepared.GlobalSlot,
) !void {
    // システム定数名はリテラル相当のため初期化しないが、仮引数・ローカル等の
    // ローカル束縛へ解決される同名は公式同様に初期化対象とする。
    // local_targetは意味解析の束縛結果で、実際の読み書き先
    // （resolveAssignmentContainer/dnclStoreArrayVariable）と同じ側を指す。
    if (!instruction.local_target and system_constant.isConstant(instruction.name)) return;
    if (resolveAssignmentContainer(self, frame, instruction, local_slot, global_slot)) |container| {
        if (container == .array) return;
    }
    var rooted = [_]Value{.undefined};
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted[0]);
    rooted[0] = try createDnclArray(self);
    try dnclStoreArrayVariable(self, frame, instruction, local_slot, global_slot, rooted[0]);
}

/// DNCL自動初期化のwrite-back（公式convLetArrayの `tmp[..] = arrayDefCode`
/// 相当）。添字を評価し直した親コンテナへ無条件に30要素の0配列を書き込む。
/// nullishなコンテナへの書き込みはsetOne経由で公式同様の
/// 『Cannot set properties of …』例外になる。
pub fn initArrayIndex(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
    if (instruction.operands.len != 2) return error.InvalidIndexAssignment;
    var rooted = [_]Value{
        frame.values[instruction.operands[0]],
        frame.values[instruction.operands[1]],
        .undefined,
    };
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    for (&rooted) |*root| try roots.protect(root);
    rooted[2] = try createDnclArray(self);
    try setOne(self, rooted[0], rooted[1], rooted[2]);
}

/// コンテナへ1要素を書き込む。配列・辞書・バイト列・関数・Promiseの
/// プロパティ代入規則を集約し、増減文の書き戻しでも共有する。
fn setOne(self: *Interpreter, container: Value, key: Value, value: Value) !void {
    if (container == .bytes) {
        var rooted = [_]Value{ container, key, value, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        for (&rooted) |*root| try roots.protect(root);
        rooted[3] = try self.runtime.valueToString(rooted[1]);
        const key_units = rooted[3].string.units;
        // TypedArray's integer-indexed [[Set]] runs before ordinary own
        // properties: canonical numeric strings address a byte, while
        // negatives, fractions, NaN, Infinity and out-of-range indices are
        // ignored instead of becoming own properties.  Non-canonical names
        // such as "02" still use the ordinary property path below.
        if (rooted[0].bytes.kind != .array_buffer) switch (try typed_array_key.classifyAlloc(key_units, self.allocator)) {
            .index => |index| {
                // ECMAScriptのIntegerIndexedElementSetは添字の有効性より
                // 先に右辺をToNumberする。範囲外でもvalueOfの副作用と
                // BigIntのTypeErrorを観測できる。
                const byte = typed_array_key.byteFromNumber(try self.runtime.valueToNumber(rooted[2]));
                const position = std.math.cast(usize, index) orelse return;
                if (position < rooted[0].bytes.bytes.len) rooted[0].bytes.set(position, byte);
                return;
            },
            .ignored => {
                // 無効添字でもToNumberだけは実行する（副作用の観測）。
                _ = typed_array_key.byteFromNumber(try self.runtime.valueToNumber(rooted[2]));
                return;
            },
            .property => {},
        };
        if (std.mem.eql(u16, key_units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }) and
            ownProperty(rooted[0].bytes.properties.items, key_units) == null)
        {
            if (rooted[2] == .null_value or isPrototypeObject(rooted[2])) rooted[0].bytes.prototype = rooted[2];
            return;
        }
        if (interpreterByteBufferReadOnlyProperty(rooted[0].bytes.kind, key_units)) return;
        try setOwnProperty(&rooted[0].bytes.properties, self.allocator, rooted[3].string, rooted[2]);
        return;
    }
    if (container == .array) {
        var rooted = [_]Value{ container, key, value, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        for (&rooted) |*root| try roots.protect(root);
        rooted[3] = try self.runtime.valueToString(rooted[1]);
        if (std.mem.eql(u16, rooted[3].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthAssignment;
        if (interpreterArrayIndex(rooted[3].string.units)) |position| return rooted[0].array.set(position, rooted[2]);
        if (std.mem.eql(u16, rooted[3].string.units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }) and
            !rooted[0].array.hasProperty(rooted[3].string))
        {
            if (rooted[2] == .null_value or isPrototypeObject(rooted[2])) rooted[0].array.prototype = rooted[2];
            return;
        }
        return rooted[0].array.setProperty(rooted[3].string, rooted[2]);
    }
    if (container == .dictionary) {
        var rooted = [_]Value{ container, key, value, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        for (&rooted) |*root| try roots.protect(root);
        rooted[3] = try self.runtime.valueToString(rooted[1]);
        if (rooted[0].dictionary.get(rooted[3].string) != null or
            !std.mem.eql(u16, rooted[3].string.units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }))
        {
            return rooted[0].dictionary.set(rooted[3].string, rooted[2]);
        }
        if (rooted[2] == .null_value or isPrototypeObject(rooted[2])) rooted[0].dictionary.prototype = rooted[2];
        return;
    }
    if (container == .function) {
        var rooted = [_]Value{ container, key, value, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        for (&rooted) |*root| try roots.protect(root);
        rooted[3] = try self.runtime.valueToString(rooted[1]);
        if (std.mem.eql(u16, rooted[3].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or
            std.mem.eql(u16, rooted[3].string.units, &.{ 'n', 'a', 'm', 'e' })) return;
        try setOwnProperty(&rooted[0].function.properties, self.allocator, rooted[3].string, rooted[2]);
        return;
    }
    if (container == .promise) {
        var rooted = [_]Value{ container, key, value, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        for (&rooted) |*root| try roots.protect(root);
        rooted[3] = try self.runtime.valueToString(rooted[1]);
        try setOwnProperty(&rooted[0].promise.properties, self.allocator, rooted[3].string, rooted[2]);
        return;
    }
    switch (container) {
        .undefined, .null_value => {
            var rooted = [_]Value{.undefined};
            var roots = self.runtime.rootFrame();
            defer roots.deinit();
            try roots.protect(&rooted[0]);
            rooted[0] = try self.runtime.valueToString(key);
            const key_utf8 = try rooted[0].string.toUtf8Lossy(self.allocator);
            defer self.allocator.free(key_utf8);
            const container_name: []const u8 = if (container == .null_value) "null" else "undefined";
            const message = try std.fmt.allocPrint(self.allocator, "Cannot set properties of {s} (setting '{s}')", .{ container_name, key_utf8 });
            defer self.allocator.free(message);
            self.exception_value = try self.runtime.stringUtf8(message);
            try self.runtime.setFailureMessage(message);
            return error.NakoException;
        },
        else => return,
    }
}

/// DNCL互換の自動初期化用に30要素の0配列を生成する（公式convLetArrayのarrayDefCode相当）。
fn createDnclArray(self: *Interpreter) !Value {
    var result = try self.runtime.createArray();
    var root = self.runtime.rootFrame();
    defer root.deinit();
    try root.protect(&result);
    for (0..30) |position| try result.array.set(position, .{ .number = 0 });
    return result;
}

/// DNCL自動初期化で生成した配列を、読み出し経路（resolveAssignmentContainer）
/// と同じ優先順位で変数へ書き戻す。読み出しが見つけた側へ書き戻すため、
/// local_target=falseのときはグローバルのみを対象にする。
fn dnclStoreArrayVariable(
    self: *Interpreter,
    frame: *Frame,
    instruction: ir.Instruction,
    local_slot: prepared.LocalSlot,
    global_slot: prepared.GlobalSlot,
    fresh: Value,
) !void {
    if (instruction.local_target) {
        if (local_slot != prepared.no_local_slot) return self.storeLocalSlot(frame, local_slot, instruction.name, fresh);
        if (localCell(frame, instruction.name)) |cell| {
            cell.value = fresh;
            return;
        }
        // ローカル束縛の変数は同名のグローバルキーへ書き込まない
        // （関数内の修飾名 mod__A 等は __vars ローカル相当）。
        return self.storeLocal(frame, instruction.name, fresh);
    }
    if (global_slot != prepared.no_global_slot) return self.setGlobalSlot(global_slot, instruction.name, fresh);
    return self.setGlobal(instruction.name, fresh);
}

/// 公式TypeError『Cannot read properties of undefined/null (reading '<key>')』相当。
fn indexReadFailure(self: *Interpreter, container: Value, key: Value) !void {
    var rooted = [_]Value{.undefined};
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted[0]);
    rooted[0] = try self.runtime.valueToString(key);
    const key_utf8 = try rooted[0].string.toUtf8Lossy(self.allocator);
    defer self.allocator.free(key_utf8);
    const container_name: []const u8 = if (container == .null_value) "null" else "undefined";
    const message = try std.fmt.allocPrint(self.allocator, "Cannot read properties of {s} (reading '{s}')", .{ container_name, key_utf8 });
    defer self.allocator.free(message);
    self.exception_value = try self.runtime.stringUtf8(message);
    try self.runtime.setFailureMessage(message);
    return error.NakoException;
}
