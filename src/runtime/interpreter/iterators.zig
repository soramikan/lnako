const std = @import("std");
const ir = @import("../../ir/nako_ir.zig");
const value_mod = @import("../value.zig");
const shared = @import("shared.zig");
const istate = @import("state.zig");

const Interpreter = istate.Interpreter;
const Frame = shared.Frame;
const IteratorState = shared.IteratorState;
const Value = shared.Value;
const String = value_mod.String;
const repeatCount = shared.repeatCount;

/// for..in互換の列挙順: 整数添字相当のキーを昇順で先に列挙し、
/// それ以外のキーは挿入順を保つ。安定ソートで非整数キーの順序を維持する。
fn orderEnumerableKeys(keys: []*String) void {
    std.mem.sort(*String, keys, {}, struct {
        fn lessThan(_: void, a: *String, b: *String) bool {
            const a_index = shared.interpreterArrayIndex(a.units);
            const b_index = shared.interpreterArrayIndex(b.units);
            if (a_index == null) return false;
            if (b_index == null) return true;
            return a_index.? < b_index.?;
        }
    }.lessThan);
}

/// ownプロパティ名の反復開始時スナップショット。空ならnullを返し、
/// 確保後の失敗は呼出し側のerrdeferで解放する。
fn snapshotOwnPropertyKeys(allocator: std.mem.Allocator, properties: []const value_mod.ArrayProperty) !?[]*String {
    if (properties.len == 0) return null;
    const keys = try allocator.alloc(*String, properties.len);
    for (properties, 0..) |property, index| keys[index] = property.key;
    orderEnumerableKeys(keys);
    return keys;
}

pub fn iteratorBegin(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    const id = instruction.result orelse return error.InvalidIterator;
    var state: IteratorState = undefined;
    if (instruction.name.len > 0 and instruction.operands.len >= 2) {
        const start = try self.runtime.valueToNumber(self.operand(frame, instruction, 0));
        const end = try self.runtime.valueToNumber(self.operand(frame, instruction, 1));
        var step: f64 = if (instruction.operands.len >= 3 and self.operand(frame, instruction, 2) != .undefined)
            try self.runtime.valueToNumber(self.operand(frame, instruction, 2))
        else if (instruction.loop_direction == .down or (instruction.loop_direction == .automatic and start > end)) -1 else 1;
        if (instruction.loop_direction == .down and step > 0) step = -step;
        if (instruction.loop_direction == .up and step < 0) step = -step;
        if (!std.math.isFinite(start) or !std.math.isFinite(end)) return error.InvalidIteratorRange;
        if (step == 0 or !std.math.isFinite(step)) return error.InvalidIteratorStep;
        state = .{ .kind = .range, .current = start, .end = end, .step = step, .variable_name = instruction.name, .variable_local = instruction.local_target };
    } else {
        const source = self.operand(frame, instruction, 0);
        state = switch (source) {
            // 反復構文の対象が数値・非反復値のときは0回実行（公式はfor..inで
            // 列挙可能なプロパティを持たない値を空反復する）。
            .number => |number| .{ .kind = .repeat, .count = if (instruction.is_foreach) 0 else try repeatCount(number) },
            // for..in互換: 配列・bytesは添字領域の後にownプロパティ名を、
            // 関数・Promiseはownプロパティ名のみを列挙する。いずれも開始時の
            // キー列を保持し、削除済みキーはiteratorHasNextで飛ばす。
            .bytes => blk: {
                const keys = try snapshotOwnPropertyKeys(self.allocator, shared.ownPropertyList(source));
                break :blk .{ .kind = .bytes, .source = source, .count = source.bytes.bytes.len, .keys = keys };
            },
            .array => blk: {
                const keys = try snapshotOwnPropertyKeys(self.allocator, shared.ownPropertyList(source));
                break :blk .{ .kind = .array, .source = source, .count = source.array.len(), .keys = keys };
            },
            .function, .promise => blk: {
                const keys = try snapshotOwnPropertyKeys(self.allocator, shared.ownPropertyList(source));
                break :blk .{ .kind = .properties, .source = source, .keys = keys };
            },
            .string => .{ .kind = .string, .source = source, .count = source.string.len() },
            .dictionary => blk: {
                // for..in互換: 反復開始時のキー列を保持し、反復中に削除された
                // キーはiteratorHasNextで飛ばす。開始後に追加されたキーは列挙しない。
                const keys = try self.allocator.dupe(*String, source.dictionary.keys());
                orderEnumerableKeys(keys);
                break :blk .{ .kind = .dictionary, .source = source, .count = keys.len, .keys = keys };
            },
            else => .{ .kind = .repeat, .count = 0 },
        };
    }
    // 反復のキースナップショットはFrameが所有する。同一IDの再開始で
    // 旧スナップショットを置き換える際に解放し、登録失敗時も今回分を解放する。
    errdefer if (state.keys) |keys| self.allocator.free(keys);
    const entry = try frame.iterators.getOrPut(self.allocator, id);
    if (entry.found_existing) if (entry.value_ptr.keys) |keys| self.allocator.free(keys);
    entry.value_ptr.* = state;
    return .{ .number = @floatFromInt(id) };
}

pub fn iteratorHasNext(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !bool {
    _ = self;
    const id = instruction.operands[0];
    const state = frame.iterators.getPtr(id) orelse return error.InvalidIterator;
    // for..in互換: 反復開始時の添字・キー集合を上限とし、配列の穴や反復中に
    // 削除された添字・キーは到達時点で飛ばす。開始後の追加要素は列挙しない。
    switch (state.kind) {
        .array, .bytes, .properties => {
            const keys: []const *String = state.keys orelse &.{};
            const total = state.count + keys.len;
            while (state.index < total) {
                if (state.index < state.count) {
                    // 添字領域は配列のみ穴・削除があり得る。bytesの添字と
                    // properties種別（count==0）は存在チェックを要しない。
                    if (state.kind != .array or state.source.array.isPresent(state.index)) break;
                } else {
                    const key = keys[state.index - state.count];
                    if (shared.ownProperty(shared.ownPropertyList(state.source), key.units) != null) break;
                }
                state.index += 1;
            }
        },
        .dictionary => {
            while (state.index < state.count and !state.source.dictionary.has(state.keys.?[state.index])) state.index += 1;
        },
        else => {},
    }
    return switch (state.kind) {
        .range => if (state.step > 0) state.current <= state.end else state.current >= state.end,
        .array, .bytes, .properties => blk: {
            const keys: []const *String = state.keys orelse &.{};
            break :blk state.index < state.count + keys.len;
        },
        else => state.index < state.count,
    };
}

pub fn iteratorNext(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    const id = instruction.operands[0];
    const state = frame.iterators.getPtr(id) orelse return error.InvalidIterator;
    var result: Value = .undefined;
    switch (state.kind) {
        .repeat => {
            state.index += 1;
            result = .{ .number = @floatFromInt(state.index) };
            try self.setGlobal("回数", result);
        },
        .range => {
            result = .{ .number = state.current };
            state.current += state.step;
            // 繰り返し変数は意味解析の束縛結果（iterator_begin時に保持）で
            // ローカル・グローバルを分ける。同名ローカルの有無で推測しない。
            if (state.variable_local) {
                try self.storeLocal(frame, state.variable_name, result);
            } else try self.setGlobal(state.variable_name, result);
        },
        .bytes, .array => {
            if (state.index < state.count) {
                result = if (state.kind == .bytes) state.source.bytes.get(state.index) else state.source.array.get(state.index);
                try self.setGlobal("対象キー", .{ .number = @floatFromInt(state.index) });
            } else {
                // ownプロパティ領域。キー名を「対象キー」へ、値を要素として返す。
                const key = state.keys.?[state.index - state.count];
                result = shared.ownProperty(shared.ownPropertyList(state.source), key.units) orelse .undefined;
                try self.setGlobal("対象キー", .{ .string = key });
            }
            state.index += 1;
            try bindForeachValue(self, frame, instruction, result);
        },
        .properties => {
            const key = state.keys.?[state.index - state.count];
            result = shared.ownProperty(shared.ownPropertyList(state.source), key.units) orelse .undefined;
            try self.setGlobal("対象キー", .{ .string = key });
            state.index += 1;
            try bindForeachValue(self, frame, instruction, result);
        },
        .string => {
            const owned = (try state.source.string.at(self.allocator, state.index)).?;
            defer {
                var temporary = owned;
                temporary.deinit();
            }
            result = try self.runtime.stringCodeUnits(owned.units);
            try self.setGlobal("対象キー", .{ .number = @floatFromInt(state.index) });
            state.index += 1;
            try bindForeachValue(self, frame, instruction, result);
        },
        .dictionary => {
            const key = state.keys.?[state.index];
            result = state.source.dictionary.get(key) orelse .undefined;
            try self.setGlobal("対象キー", .{ .string = key });
            state.index += 1;
            try bindForeachValue(self, frame, instruction, result);
        },
    }
    return result;
}

/// 反復構文の要素束縛。公式convForeachは要素を「それ」へ束縛し、
/// `AをBで反復`の指定変数があればその変数へ、無ければ「対象」へ書き込む。
/// 範囲繰り返しのコレクション反復は従来どおり「対象」のみ更新する。
fn bindForeachValue(self: *Interpreter, frame: *Frame, instruction: ir.Instruction, element: Value) !void {
    if (!instruction.is_foreach) return self.setGlobal("対象", element);
    try self.setGlobal("それ", element);
    if (instruction.name.len == 0) return self.setGlobal("対象", element);
    if (instruction.local_target) return self.storeLocal(frame, instruction.name, element);
    return self.setGlobal(instruction.name, element);
}
