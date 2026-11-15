//! Nako→JS callback の host 関数スロット表（Issue #278）。
//!
//! `lnako_qjs_host_function` は同じ host 関数エントリから複数の JS 関数
//! オブジェクトを生成できる。この表は JS 関数インスタンス1個につき
//! `instances` を1つ増やし、QuickJS の finalizer からの解放通知1回につき
//! 1つ減らす。最後のインスタンスが消えたスロットは tombstone として
//! 解放され、保持していた Nako 値を手放す（Nako GC が capture を回収できる）。
//!
//! ID は密な配列 index ではなく「index + 世代」の組で表す。index だけでは
//! 解放後の再利用で古い JS 関数が新しいエントリを呼んでしまうため、
//! `generation` を別の `u64` として ABI に渡す（`uintptr_t` は 32bit 環境で
//! 32bit のため、世代を index へ詰めない）。世代は 0 と `maxInt(u64)` を
//! 使わず単調増加し、尽きたら新規登録を失敗させる（wrap しない）。
//!
//! この表は GC mark 中の trace からも finalizer からも呼ばれる。どの操作も
//! QuickJS API を呼ばず、解放通知はスロットの無効化と free list への連結
//! だけを行う（追加の割当てをしない）。
const std = @import("std");

pub fn Table(comptime Value: type) type {
    return struct {
        const Self = @This();

        pub const Handle = struct {
            index: usize,
            generation: u64,
        };

        const Slot = struct {
            value: Value = undefined,
            generation: u64 = 0,
            instances: usize = 0,
            occupied: bool = false,
            /// 解放済みスロットを繋ぐ侵入型 free list。解放通知中の割当てを
            /// 避けるため `std.ArrayList` ではなく index で連結する。
            free_next: ?usize = null,
        };

        slots: std.ArrayListUnmanaged(Slot) = .empty,
        free_head: ?usize = null,
        /// 次に払い出す世代。deinit 後も保持し、同じ table を再利用しても
        /// 古い世代の通知が新しいスロットに一致しないようにする。
        next_generation: u64 = 1,
        occupied_count: usize = 0,
        active: bool = true,

        pub fn insert(self: *Self, allocator: std.mem.Allocator, value: Value) !Handle {
            const generation = try self.nextGeneration();
            self.active = true;
            if (self.free_head) |index| {
                const slot = &self.slots.items[index];
                self.free_head = slot.free_next;
                slot.* = .{
                    .value = value,
                    .generation = generation,
                    .occupied = true,
                };
                self.occupied_count += 1;
                return .{ .index = index, .generation = generation };
            }
            const index = self.slots.items.len;
            try self.slots.append(allocator, .{
                .value = value,
                .generation = generation,
                .occupied = true,
            });
            self.occupied_count += 1;
            return .{ .index = index, .generation = generation };
        }

        /// `same` が true を返す生存スロットを返す。同じ `*state.Object` を
        /// 複数回 JS へ渡す場合は同じ handle を再利用する。
        pub fn findHandle(self: *Self, value: Value, comptime same: fn (Value, Value) bool) ?Handle {
            if (!self.active) return null;
            for (self.slots.items, 0..) |slot, index| {
                if (!slot.occupied) continue;
                if (same(slot.value, value)) {
                    return .{ .index = index, .generation = slot.generation };
                }
            }
            return null;
        }

        /// 成功した JS 関数インスタンス生成1回分を加算する。飽和加算にして
        /// 呼出し側に失敗経路を作らない（失敗通知の取り違えを防ぐ）。
        pub fn acquire(self: *Self, handle: Handle) void {
            const slot = self.occupiedSlot(handle) orelse return;
            slot.instances +|= 1;
        }

        /// QuickJS finalizer からの解放通知1回分を減算する。最後のインスタンス
        /// ならスロットを無効化して free list へ戻す。未知の index、古い世代、
        /// 二重通知は無視する（誤って別エントリを解放しない）。
        pub fn release(self: *Self, index: usize, generation: u64) void {
            if (!self.active or index >= self.slots.items.len) return;
            const slot = &self.slots.items[index];
            if (!slot.occupied or slot.generation != generation) return;
            if (slot.instances == 0) return;
            slot.instances -= 1;
            if (slot.instances != 0) return;
            self.freeSlot(index);
        }

        pub fn lookup(self: *Self, index: usize, generation: u64) ?Value {
            if (!self.active or index >= self.slots.items.len) return null;
            const slot = &self.slots.items[index];
            if (!slot.occupied or slot.generation != generation) return null;
            return slot.value;
        }

        pub fn handleForValue(self: *Self, value: Value, comptime same: fn (Value, Value) bool) ?Handle {
            return self.findHandle(value, same);
        }

        pub fn instanceCount(self: *Self, handle: Handle) usize {
            const slot = self.occupiedSlot(handle) orelse return 0;
            return slot.instances;
        }

        pub fn occupiedCount(self: *Self) usize {
            return self.occupied_count;
        }

        pub fn forEachOccupied(self: *Self, context: anytype, comptime callback: fn (@TypeOf(context), Value) anyerror!void) !void {
            for (self.slots.items) |slot| {
                if (slot.occupied) try callback(context, slot.value);
            }
        }

        /// GC trace 中に呼ばれる。QuickJS へは触れず、値の mark だけを行う。
        pub fn trace(self: *Self, context: anytype, comptime callback: fn (@TypeOf(context), Value) anyerror!void) !void {
            try self.forEachOccupied(context, callback);
        }

        /// テーブルを破棄する。`next_generation` は意図的に保持する。
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.active = false;
            self.slots.deinit(allocator);
            self.slots = .empty;
            self.free_head = null;
            self.occupied_count = 0;
        }

        /// teardown 済みの表へ stale 通知が来ても触らないようにする。
        pub fn deactivate(self: *Self) void {
            self.active = false;
        }

        fn occupiedSlot(self: *Self, handle: Handle) ?*Slot {
            if (!self.active or handle.index >= self.slots.items.len) return null;
            const slot = &self.slots.items[handle.index];
            if (!slot.occupied or slot.generation != handle.generation) return null;
            return slot;
        }

        fn freeSlot(self: *Self, index: usize) void {
            const slot = &self.slots.items[index];
            slot.occupied = false;
            slot.instances = 0;
            slot.value = undefined;
            slot.free_next = self.free_head;
            self.free_head = index;
            self.occupied_count -= 1;
        }

        fn nextGeneration(self: *Self) !u64 {
            const generation = self.next_generation;
            if (generation == 0 or generation == std.math.maxInt(u64)) {
                return error.HostFunctionGenerationExhausted;
            }
            self.next_generation = generation + 1;
            return generation;
        }
    };
}

fn sameTestValue(left: u32, right: u32) bool {
    return left == right;
}

test "hostFunctionsは解放後のスロットを別世代で再利用する" {
    var table: Table(u32) = .{};
    defer table.deinit(std.testing.allocator);
    const first = try table.insert(std.testing.allocator, 7);
    try std.testing.expectEqual(@as(usize, 1), table.occupiedCount());
    table.acquire(first);
    table.acquire(first);
    try std.testing.expectEqual(@as(?u32, 7), table.lookup(first.index, first.generation));

    // 参照が残っている間は解放通知1回で消えない。
    table.release(first.index, first.generation);
    try std.testing.expectEqual(@as(usize, 1), table.occupiedCount());
    table.release(first.index, first.generation);
    try std.testing.expectEqual(@as(usize, 0), table.occupiedCount());

    const second = try table.insert(std.testing.allocator, 9);
    try std.testing.expectEqual(first.index, second.index);
    try std.testing.expect(second.generation > first.generation);
    try std.testing.expectEqual(@as(?u32, null), table.lookup(first.index, first.generation));
    try std.testing.expectEqual(@as(?u32, 9), table.lookup(second.index, second.generation));

    // 古い世代の解放通知は新しいスロットを壊さない。
    table.release(first.index, first.generation);
    try std.testing.expectEqual(@as(?u32, 9), table.lookup(second.index, second.generation));
    try std.testing.expectEqual(@as(usize, 1), table.occupiedCount());
}

test "hostFunctionsは同一値のhandleを再利用しインスタンス数を数える" {
    var table: Table(u32) = .{};
    defer table.deinit(std.testing.allocator);
    const first = try table.insert(std.testing.allocator, 3);
    try std.testing.expectEqual(first, table.findHandle(3, sameTestValue).?);
    table.acquire(first);
    table.acquire(first);
    try std.testing.expectEqual(@as(usize, 2), table.instanceCount(first));
    table.release(first.index, first.generation);
    try std.testing.expectEqual(@as(usize, 1), table.instanceCount(first));
    table.release(first.index, first.generation);
    try std.testing.expectEqual(@as(usize, 0), table.occupiedCount());
}

test "hostFunctionsは先予約acquireのrollbackで既存インスタンスを壊さない" {
    var table: Table(u32) = .{};
    defer table.deinit(std.testing.allocator);
    // 既存インスタンスが1個ある状態で、2個目の生成に先立って予約する。
    const handle = try table.insert(std.testing.allocator, 5);
    table.acquire(handle);
    table.acquire(handle);
    try std.testing.expectEqual(@as(usize, 2), table.instanceCount(handle));
    // 生成失敗時は予約分だけを戻す（既存の1個は残る）。
    table.release(handle.index, handle.generation);
    try std.testing.expectEqual(@as(?u32, 5), table.lookup(handle.index, handle.generation));
    try std.testing.expectEqual(@as(usize, 1), table.instanceCount(handle));

    // 新規スロットの予約は失敗時の release で 1 -> 0 となり即解放される。
    const fresh = try table.insert(std.testing.allocator, 6);
    table.acquire(fresh);
    table.release(fresh.index, fresh.generation);
    try std.testing.expectEqual(@as(usize, 1), table.occupiedCount());
    try std.testing.expectEqual(@as(?u32, null), table.lookup(fresh.index, fresh.generation));

    table.release(handle.index, handle.generation);
    try std.testing.expectEqual(@as(usize, 0), table.occupiedCount());
}

test "hostFunctionsはdeinit後のstale通知を無視する" {
    var table: Table(u32) = .{};
    const handle = try table.insert(std.testing.allocator, 1);
    table.acquire(handle);
    table.deinit(std.testing.allocator);
    table.release(handle.index, handle.generation);
    try std.testing.expectEqual(@as(usize, 0), table.occupiedCount());
    const next = try table.insert(std.testing.allocator, 2);
    defer table.deinit(std.testing.allocator);
    try std.testing.expect(next.generation > handle.generation);
}
