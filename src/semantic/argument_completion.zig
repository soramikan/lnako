const std = @import("std");
const ast = @import("../frontend/ast.zig");
const builtin_josi = @import("builtin_josi.zig");

/// 助詞呼出しの1スロット分の定義。`josi`は同じスロットで使える助詞の異表記で、
/// 空文字列は助詞なしの末尾値を表す。
pub const Slot = struct {
    josi: []const []const u8,
};

/// 補完後のオペランド1件。
pub const Operand = union(enum) {
    /// 呼出し元が書いた引数の添字。
    provided: usize,
    /// 省略された引数へ補完する変数「それ」。
    implicit_it,
};

pub const Plan = struct {
    operands: []const Operand,
    provided: usize,
    missing: usize,
};

/// 公式`nako_parser3.mts`の`yCallFunc`と同じ順序で助詞引数を解決する。
///
/// 末尾のスロットから順に、助詞が一致する引数をスタック末尾側から取り出し、
/// 見つからないスロットは変数「それ」で補完する。`variable_final`が真のときは
/// 末尾スロットを可変長引数として扱い、助詞が一致する引数を元の並びのまま
/// 全て取り出すが、不足数へは数えず「それ」補完もしない。
/// スロットへ割り当てられない引数が残る場合やスロットが1つも無い場合は、
/// 呼出し元の並びを変更しないため`null`を返す（補完しない）。
pub fn plan(allocator: std.mem.Allocator, slots: []const Slot, arguments: []const *ast.Node, variable_final: bool) !?Plan {
    if (slots.len == 0) return null;
    const assigned = try allocator.alloc(?usize, slots.len);
    errdefer allocator.free(assigned);
    const used = try allocator.alloc(bool, arguments.len);
    errdefer allocator.free(used);
    @memset(assigned, null);
    @memset(used, false);
    var variable_arguments: std.ArrayList(usize) = .empty;
    defer variable_arguments.deinit(allocator);

    var fixed_count = slots.len;
    if (variable_final) {
        // 可変長の末尾スロットは公式と同じく最初に処理し、助詞が一致する引数を
        // 元の並びのまま全て取り出す。
        for (arguments, 0..) |argument, index| {
            if (!matches(slots[slots.len - 1], argument.josi)) continue;
            used[index] = true;
            try variable_arguments.append(allocator, index);
        }
        fixed_count = slots.len - 1;
    }

    var index = fixed_count;
    while (index > 0) {
        index -= 1;
        var candidate = arguments.len;
        while (candidate > 0) {
            candidate -= 1;
            if (used[candidate]) continue;
            if (!matches(slots[index], arguments[candidate].josi)) continue;
            assigned[index] = candidate;
            used[candidate] = true;
            break;
        }
    }
    // 助詞が一致するスロットが無い引数が残っている場合は、公式の並びを
    // 再現できないため補完せずに呼出し元の並びを尊重する。
    for (used) |item| if (!item) {
        allocator.free(assigned);
        allocator.free(used);
        return null;
    };

    var provided: usize = variable_arguments.items.len;
    var missing: usize = 0;
    const operands = try allocator.alloc(Operand, fixed_count + variable_arguments.items.len);
    var position: usize = 0;
    for (assigned[0..fixed_count]) |item| {
        if (item) |argument| {
            operands[position] = .{ .provided = argument };
            provided += 1;
        } else {
            operands[position] = .implicit_it;
            missing += 1;
        }
        position += 1;
    }
    for (variable_arguments.items) |argument| {
        operands[position] = .{ .provided = argument };
        position += 1;
    }
    allocator.free(assigned);
    allocator.free(used);
    return .{ .operands = operands, .provided = provided, .missing = missing };
}

fn matches(slot: Slot, josi: []const u8) bool {
    for (slot.josi) |candidate| if (std.mem.eql(u8, candidate, josi)) return true;
    return false;
}

/// 生成済みの助詞スロット表を`Slot`の並びへ展開する。
pub fn builtinSlots(allocator: std.mem.Allocator, entry: builtin_josi.BuiltinJosi) ![]Slot {
    const slots = try allocator.alloc(Slot, entry.slot_starts.len);
    for (entry.slot_starts, 0..) |start, index| {
        const end = if (index + 1 < entry.slot_starts.len) entry.slot_starts[index + 1] else entry.josi.len;
        slots[index] = .{ .josi = entry.josi[start..end] };
    }
    return slots;
}

/// ユーザー定義関数の仮引数助詞（宣言順）を1スロット1助詞の定義へ変換する。
pub fn parameterSlots(allocator: std.mem.Allocator, parameter_josi: []const []const u8) ![]Slot {
    const slots = try allocator.alloc(Slot, parameter_josi.len);
    for (parameter_josi, 0..) |josi, index| {
        const alternatives = try allocator.alloc([]const u8, 1);
        alternatives[0] = josi;
        slots[index] = .{ .josi = alternatives };
    }
    return slots;
}

test "助詞が一致するスロットへ引数を割り当て不足分を「それ」にする" {
    var nodes = [_]ast.Node{
        .{ .kind = .number, .span = ast.emptySpan(), .end_span = ast.emptySpan(), .josi = "を" },
        .{ .kind = .number, .span = ast.emptySpan(), .end_span = ast.emptySpan(), .josi = "に" },
    };
    const arguments = [_]*ast.Node{ &nodes[0], &nodes[1] };
    const slots = [_]Slot{
        .{ .josi = &.{ "の", "で" } },
        .{ .josi = &.{"を"} },
        .{ .josi = &.{"に"} },
    };
    const result = (try plan(std.testing.allocator, &slots, &arguments, false)).?;
    defer std.testing.allocator.free(result.operands);
    try std.testing.expectEqual(@as(usize, 2), result.provided);
    try std.testing.expectEqual(@as(usize, 1), result.missing);
    try std.testing.expectEqual(Operand.implicit_it, result.operands[0]);
    try std.testing.expectEqual(@as(usize, 0), result.operands[1].provided);
    try std.testing.expectEqual(@as(usize, 1), result.operands[2].provided);
}

test "全引数を省略したスロットを宣言順に「それ」で補完する" {
    const slots = [_]Slot{ .{ .josi = &.{"と"} }, .{ .josi = &.{"を"} } };
    const result = (try plan(std.testing.allocator, &slots, &.{}, false)).?;
    defer std.testing.allocator.free(result.operands);
    try std.testing.expectEqual(@as(usize, 0), result.provided);
    try std.testing.expectEqual(@as(usize, 2), result.missing);
    try std.testing.expectEqual(Operand.implicit_it, result.operands[0]);
    try std.testing.expectEqual(Operand.implicit_it, result.operands[1]);
}

test "助詞がどのスロットにも一致しない引数があれば補完しない" {
    var node = ast.Node{ .kind = .number, .span = ast.emptySpan(), .end_span = ast.emptySpan(), .josi = "が" };
    const arguments = [_]*ast.Node{&node};
    const slots = [_]Slot{.{ .josi = &.{"を"} }};
    const result = try plan(std.testing.allocator, &slots, &arguments, false);
    try std.testing.expect(result == null);
}

test "可変長の末尾スロットは補完せず先行する固定スロットを「それ」にする" {
    var node = ast.Node{ .kind = .number, .span = ast.emptySpan(), .end_span = ast.emptySpan(), .josi = "に" };
    const arguments = [_]*ast.Node{&node};
    const slots = [_]Slot{ .{ .josi = &.{"を"} }, .{ .josi = &.{ "に", "と" } } };
    const result = (try plan(std.testing.allocator, &slots, &arguments, true)).?;
    defer std.testing.allocator.free(result.operands);
    try std.testing.expectEqual(@as(usize, 1), result.provided);
    try std.testing.expectEqual(@as(usize, 1), result.missing);
    // 固定スロットの「それ」が先頭、可変長スロットの引数が末尾に並ぶ。
    try std.testing.expectEqual(Operand.implicit_it, result.operands[0]);
    try std.testing.expectEqual(@as(usize, 0), result.operands[1].provided);
}

test "可変長の末尾スロットだけの命令は引数なしでも「それ」を補完しない" {
    const slots = [_]Slot{.{ .josi = &.{ "と", "を" } }};
    const result = (try plan(std.testing.allocator, &slots, &.{}, true)).?;
    defer std.testing.allocator.free(result.operands);
    try std.testing.expectEqual(@as(usize, 0), result.operands.len);
    try std.testing.expectEqual(@as(usize, 0), result.provided);
    try std.testing.expectEqual(@as(usize, 0), result.missing);
}
