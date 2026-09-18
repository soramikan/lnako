const std = @import("std");
const value_mod = @import("../value.zig");
const foundation = @import("../low_level_foundation.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

/// Interpreterが保持する低レイヤー命令の状態。Handle値は不透明オブジェクト
/// （辞書）であり、その同一性だけをhandle tableの `HandleId` へ結びつける。
/// 同じ形の辞書を手作りしてもこの対応表に載らないため無効になる。
///
/// AOTのdynamic bridgeは埋め込みInterpreterのこの表を参照する。プラグイン層へ
/// 逆依存しないよう、Value依存だが共通基盤層（runtime/low_level）が所有する。
pub const State = struct {
    allocator: ?std.mem.Allocator = null,
    handle_ids: std.AutoHashMapUnmanaged(usize, foundation.HandleId) = .empty,
    handle_by_id: std.AutoHashMapUnmanaged(u64, Value) = .empty,
    handle_values: std.ArrayList(Value) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        const actual = self.allocator orelse allocator;
        self.handle_ids.deinit(actual);
        self.handle_by_id.deinit(actual);
        self.handle_values.deinit(actual);
        self.* = undefined;
    }

    fn memory(self: *State, allocator: std.mem.Allocator) std.mem.Allocator {
        if (self.allocator) |existing| return existing;
        self.allocator = allocator;
        return allocator;
    }

    pub fn trace(self: *State, runtime: *Runtime) !void {
        for (self.handle_values.items) |value| try runtime.traceExternal(value);
    }
};

pub fn lookupHandle(state: *State, value: Value) ?foundation.HandleId {
    if (value != .dictionary) return null;
    return state.handle_ids.get(@intFromPtr(value.dictionary));
}

pub fn handleForId(state: *State, id: foundation.HandleId) ?Value {
    return state.handle_by_id.get(id.raw());
}

pub fn rememberHandle(state: *State, allocator: std.mem.Allocator, value: Value, id: foundation.HandleId) !void {
    if (value != .dictionary) return error.InvalidHandle;
    const memory = state.memory(allocator);
    try state.handle_ids.put(memory, @intFromPtr(value.dictionary), id);
    errdefer _ = state.handle_ids.remove(@intFromPtr(value.dictionary));
    try state.handle_by_id.put(memory, id.raw(), value);
    errdefer _ = state.handle_by_id.remove(id.raw());
    try state.handle_values.append(memory, value);
}

pub fn forgetHandle(state: *State, value: Value) void {
    if (lookupHandle(state, value)) |id| forgetHandleId(state, id);
}

pub fn forgetHandleId(state: *State, id: foundation.HandleId) void {
    _ = state.handle_by_id.remove(id.raw());
    var index: usize = 0;
    while (index < state.handle_values.items.len) {
        const candidate = state.handle_values.items[index];
        if (candidate == .dictionary) {
            if (state.handle_ids.get(@intFromPtr(candidate.dictionary))) |mapped| {
                if (mapped.index == id.index and mapped.generation == id.generation) {
                    _ = state.handle_ids.remove(@intFromPtr(candidate.dictionary));
                    _ = state.handle_values.swapRemove(index);
                    continue;
                }
            }
        }
        index += 1;
    }
}

test "Stateはhandle値の同一性だけを対応表へ載せる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);

    var first = try runtime.createDictionary();
    var second = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&first);
    try roots.protect(&second);
    try state.handle_ids.put(state.memory(std.testing.allocator), @intFromPtr(first.dictionary), .{ .index = 1, .generation = 1 });
    try state.handle_values.append(state.memory(std.testing.allocator), first);

    try std.testing.expect(lookupHandle(&state, first) != null);
    try std.testing.expect(lookupHandle(&state, second) == null);
    try std.testing.expect(lookupHandle(&state, .{ .number = 1 }) == null);

    forgetHandle(&state, first);
    try std.testing.expect(lookupHandle(&state, first) == null);
    try std.testing.expectEqual(@as(usize, 0), state.handle_values.items.len);
}

test "Stateは最初に使ったallocatorで解放する" {
    var state = State{};
    try state.handle_ids.put(state.memory(std.testing.allocator), 1, .{ .index = 1, .generation = 1 });
    try state.handle_values.append(state.memory(std.testing.allocator), .undefined);
    state.deinit(std.heap.page_allocator);
}
