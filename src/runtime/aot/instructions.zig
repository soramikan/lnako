const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared.zig");
const state = @import("state.zig");

pub export fn lnako_aot_bigint_truthy(value: *const state.Value) callconv(.c) c_int {
    const object = value.object() orelse return 0;
    if (object.payload != .bigint) return 0;
    return @intFromBool(!object.payload.bigint.isZero());
}

pub export fn lnako_aot_truthy(value: *const state.Value) callconv(.c) c_int {
    return @intFromBool(state.valueTruthy(value.*));
}

pub export fn lnako_aot_unary(out: *state.Value, value: *const state.Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(state.UnaryOperator, opcode) orelse {
        runtime.setFailure(error.InvalidUnaryOperator);
        return;
    };
    out.* = state.unary(runtime, operator, value.*) catch |failure| {
        // A callback used by ToPrimitive may already have installed the
        // original exception.  Keep that value so caught AOT errors observe
        // the callback's message instead of the internal bridge error.
        if (!runtime.has_pending_exception) runtime.setFailure(failure);
        return;
    };
}

/// ECMAScript `**`の特例を含む純粋f64の累乗ABI。数値確定のLLVM生成経路が
/// `llvm.pow.f64`ではなくこれを呼び、指数NaN・±0・底NaN・|底|==1の無限指数を
/// generic演算と同一に処理する。
pub export fn lnako_aot_pow_f64(base: f64, exponent: f64) callconv(.c) f64 {
    return shared.number_mod.pow(base, exponent);
}

pub export fn lnako_aot_arithmetic(out: *state.Value, left: *const state.Value, right: *const state.Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(state.Arithmetic, opcode) orelse {
        runtime.setFailure(error.InvalidArithmeticOperator);
        return;
    };
    out.* = state.arithmetic(runtime, operator, left.*, right.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_compare(out: *state.Value, left: *const state.Value, right: *const state.Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(state.Comparison, opcode) orelse {
        runtime.setFailure(error.InvalidComparison);
        return;
    };
    out.* = .{
        .tag = @intFromEnum(shared.Tag.boolean),
        .payload = @intFromBool(state.compareValues(runtime, operator, left.*, right.*) catch |failure| {
            runtime.setFailure(failure);
            return;
        }),
    };
}

pub export fn lnako_aot_shift(out: *state.Value, left: *const state.Value, right: *const state.Value, opcode: u8) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const operator = std.enums.fromInt(state.ShiftOperator, opcode) orelse {
        runtime.setFailure(error.InvalidShiftOperator);
        return;
    };
    out.* = state.shift(runtime, operator, left.*, right.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_concat(out: *state.Value, left: *const state.Value, right: *const state.Value) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    out.* = state.concat(runtime, left.*, right.*) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

/// 増減文の分解命令（公式convInc相当）。
/// `typeof v === 'undefined'` の判定。純粋なタグ比較で例外は発生させない。
pub export fn lnako_aot_is_undefined(value: *const state.Value) callconv(.c) c_int {
    return if (value.tag == @intFromEnum(shared.Tag.undefined)) 1 else 0;
}

/// `v0 = 0` 相当: undefinedなら0、それ以外はそのまま返す。
pub export fn lnako_aot_coalesce_or_zero(out: *state.Value, value: *const state.Value) callconv(.c) void {
    out.* = if (value.tag == @intFromEnum(shared.Tag.undefined)) state.numberValue(0) else value.*;
}

/// `Number(v0) + Number(incValue)` 相当の数値強制つき加算。
/// 呼び出し側は読み出し・undefined初期化・量の評価を済ませてから呼ぶ。
pub export fn lnako_aot_increment_values(out: *state.Value, old: *const state.Value, amount: *const state.Value) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else {
        out.* = .{};
        return;
    };
    var rooted = [_]state.Value{ old.*, amount.* };
    var frame = state.RootFrame{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    out.* = state.incrementValue(runtime, rooted[0], rooted[1]) catch |failure| {
        // ToPrimitive callbackが元の例外を設定済みの場合はそちらを保持する。
        if (!runtime.has_pending_exception) runtime.setFailure(failure);
        out.* = .{};
        return;
    };
}

pub export fn lnako_aot_index_get(out: *state.Value, container: *const state.Value, key: *const state.Value) callconv(.c) void {
    const container_value = container.*;
    const key_value = key.*;
    const runtime = if (state.active_runtime) |*active| active else {
        out.* = .{};
        return;
    };
    // 同一命令内の先行する失敗（公式では先に投げられたTypeError）を上書きしない
    if (runtime.has_pending_exception) {
        out.* = .{};
        return;
    }
    const start_epoch = runtime.failure_epoch;
    out.* = runtime.indexGet(container_value, key_value);
    runtime.recordAotEntry(&runtime.counters.aot_index_get, runtime.failure_epoch == start_epoch);
}

pub export fn lnako_aot_index_set(container: *const state.Value, key: *const state.Value, value: *const state.Value) callconv(.c) c_int {
    const runtime = if (state.active_runtime) |*active| active else return -1;
    // 先行する中間読出しの失敗を最終書込みの失敗で上書きしない
    if (runtime.has_pending_exception) return -1;
    const start_epoch = runtime.failure_epoch;
    if (container.tag == @intFromEnum(shared.Tag.undefined) or container.tag == @intFromEnum(shared.Tag.null_value)) {
        runtime.setIndexAssignmentFailure(container.*, key.*);
        runtime.recordAotEntry(&runtime.counters.aot_index_set, false);
        return -1;
    }
    runtime.indexSet(container.*, key.*, value.*) catch |failure| {
        // ArrayLengthAssignment等の失敗はpending例外として報告する。
        // 既にpendingな例外がある場合は先の失敗を上書きしない。
        if (!runtime.has_pending_exception) runtime.setFailure(failure);
        runtime.recordAotEntry(&runtime.counters.aot_index_set, false);
        return -1;
    };
    runtime.recordAotEntry(&runtime.counters.aot_index_set, runtime.failure_epoch == start_epoch);
    return 0;
}

/// DNCL互換の配列自動初期化（公式convLetArrayのcheckInit相当）。
/// 変数スロットの値が配列でなければ30要素の0配列で置き換える。
pub export fn lnako_aot_ensure_array_var(slot: *state.Value) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    // 先行する中間読出し等の失敗を保持する
    if (runtime.has_pending_exception) return;
    if (slot.tag == @intFromEnum(shared.Tag.array)) return;
    slot.* = createDnclArray(runtime) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

/// DNCLの配列自動初期化で使う30要素の0配列を生成する。
fn createDnclArray(runtime: *state.Runtime) !state.Value {
    const zeros: [30]state.Value = @splat(state.numberValue(0));
    return runtime.createArray(&zeros);
}

/// DNCL自動初期化のcheck式（公式 `tmp[..] instanceof Array` 相当）。
/// 値のタグが配列なら1、それ以外は0を返す。例外は発生しない。
pub export fn lnako_aot_is_array(value: *const state.Value) callconv(.c) i32 {
    return if (value.tag == @intFromEnum(shared.Tag.array)) 1 else 0;
}

/// DNCL自動初期化のwrite-back式（公式 `tmp[..] = arrayDefCode` 相当）。
/// container[key]へ無条件に30要素の0配列を書き込む。
/// containerがundefined/nullならindexSet経由で公式同様
/// 『Cannot set properties of …』で失敗する。
pub export fn lnako_aot_init_array_index(container: *state.Value, key: *const state.Value) callconv(.c) void {
    const runtime = if (state.active_runtime) |*active| active else return;
    if (runtime.has_pending_exception) return;
    if (container.tag == @intFromEnum(shared.Tag.undefined) or container.tag == @intFromEnum(shared.Tag.null_value)) {
        runtime.setIndexAssignmentFailure(container.*, key.*);
        return;
    }
    var rooted = [_]state.Value{ container.*, key.*, .{} };
    var frame = state.RootFrame{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);
    rooted[2] = createDnclArray(runtime) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    runtime.indexSet(rooted[0], rooted[1], rooted[2]) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_destructure_get(out: *state.Value, source: *const state.Value, index: usize) callconv(.c) void {
    out.* = if (state.active_runtime) |*runtime| runtime.destructureGet(source.*, index) else .{};
}

pub export fn lnako_aot_iterator_new(out: *state.Value, values: ?[*]const state.Value, len: usize, is_range: bool, direction: u8, is_foreach: bool) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    const source = if (values) |pointer| pointer[0..len] else if (len == 0) &.{} else return;
    out.* = runtime.createIterator(source, is_range, direction, is_foreach) catch |failure| state.runtimeFailure(failure);
}

pub export fn lnako_aot_iterator_has_next(iterator: *const state.Value) callconv(.c) c_int {
    const runtime = if (state.active_runtime) |*value| value else return 0;
    return @intFromBool(runtime.iteratorHasNext(iterator.*) catch |failure| {
        // コールバック（カスタムvalueOf等）が投げた例外はpendingのまま
        // 残っているため、汎用失敗で上書きしない。
        if (!runtime.has_pending_exception) runtime.setFailure(failure);
        return 0;
    });
}

pub export fn lnako_aot_iterator_next(out: *state.Value, iterator: *const state.Value, repeat_target: ?*state.Value, value_target: ?*state.Value, key_target: ?*state.Value, range_target: ?*state.Value, sore_target: ?*state.Value) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    out.* = runtime.iteratorNext(iterator.*, repeat_target, value_target, key_target, range_target, sore_target) catch |failure| {
        if (!runtime.has_pending_exception) runtime.setFailure(failure);
        return;
    };
}

pub export fn lnako_aot_binding_cell_new(out: *state.Value, initial: ?*const state.Value) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*value| value else return;
    out.* = runtime.createBindingCell(if (initial) |value| value.* else .{}) catch |failure| state.runtimeFailure(failure);
}

pub export fn lnako_aot_binding_cell_value(cell: *state.Value) callconv(.c) *state.Value {
    if (cell.tag != @intFromEnum(shared.Tag.binding_cell)) state.runtimeFailure(error.InvalidBindingCell);
    const object = cell.object() orelse state.runtimeFailure(error.InvalidBindingCell);
    if (object.payload != .binding_cell) state.runtimeFailure(error.InvalidBindingCell);
    return &object.payload.binding_cell;
}

/// Dedicated ABI for the two commands that update the system `対象` value.
/// The target is explicit so a local variable named 対象 can never shadow the
/// command's side effect in generated LLVM.
pub export fn lnako_aot_cut(out: *state.Value, target: *state.Value, arguments: ?[*]const state.Value, len: usize, mode: u8) callconv(.c) void {
    lnako_aot_cut_site(out, target, arguments, len, mode, 0);
}

pub export fn lnako_aot_cut_site(out: *state.Value, target: *state.Value, arguments: ?[*]const state.Value, len: usize, mode: u8, site_id: u64) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const start_epoch = runtime.failure_epoch;
    const command: state.aot_builtin.Command = if (mode == 0) .cut else .cut_range;
    const opcode = @intFromEnum(command);
    const command_name = state.aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "cut", site_id);
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "cut", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const required: usize = if (mode == 0) 2 else if (mode == 1) 3 else 0;
    if (required == 0 or len < required) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const values = arguments.?;
    const result = state.cutBuiltin(runtime, values[0], values[1], if (mode == 1) values[2] else null, mode == 1) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    // state.cutBuiltin roots both values until this point; assign only after both
    // allocations and all delayed property accesses have succeeded.
    out.* = result.result;
    target.* = result.remainder;
    success = runtime.failure_epoch == start_epoch;
}
