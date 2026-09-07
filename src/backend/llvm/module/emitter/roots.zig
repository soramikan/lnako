const std = @import("std");
const liveness = @import("../../../../ir/root_liveness.zig");
const Emitter = @import("context.zig").Emitter;

/// Preserve logical root.slot.ValueId names used by runtime call emitters,
/// while mapping them onto colored physical storage. Primitive ABI scratch
/// is not registered with the collector. Locals retain dedicated root slots.
pub fn writeStorage(emitter: *Emitter, plan: liveness.Plan, local_count: usize) !void {
    const count = plan.root_count + local_count;
    const storage = @max(@as(usize, 1), count);
    const scratch = @max(@as(usize, 1), plan.scratch_count);
    const w = &emitter.output.writer;
    try w.print("  %root.values = alloca [{d} x %lnako.Value]\n", .{storage});
    try w.print("  %primitive.values = alloca [{d} x %lnako.Value]\n", .{scratch});
    try w.writeAll("  %root.frame = alloca %lnako.RootFrame\n");
    for (0..count) |slot| {
        try w.print("  %gc.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %root.values, i64 0, i64 {d}\n", .{ slot, storage, slot });
        try w.print("  store %lnako.Value {{ i8 0, i64 0 }}, ptr %gc.slot.{d}\n", .{slot});
    }
    for (plan.slots, 0..) |slot, value| {
        try w.print("  %root.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %{s}.values, i64 0, i64 {d}\n", .{ value, if (plan.managed[value]) storage else scratch, if (plan.managed[value]) @as([]const u8, "root") else "primitive", slot });
    }
    for (0..local_count) |local| {
        try w.print("  %root.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %root.values, i64 0, i64 {d}\n", .{ plan.slots.len + local, storage, plan.root_count + local });
    }
    if (count > 0) {
        try w.print("  call void @lnako_aot_push_roots(ptr %root.frame, ptr %gc.slot.0, i64 {d})\n", .{count});
    } else try w.writeAll("  call void @lnako_aot_push_roots(ptr %root.frame, ptr null, i64 0)\n");
}

/// Dead references from a prior block/loop iteration must not be retained at
/// a safepoint. A live occupant of a colored slot always wins over dead ones.
pub fn writeSafepoint(emitter: *Emitter, plan: liveness.Plan, live: []const bool) !void {
    if (!plan.precise) return;
    @memset(plan.active, false);
    for (live, 0..) |used, value| {
        if (used and plan.managed[value]) plan.active[plan.slots[value]] = true;
    }
    for (plan.active, 0..) |used, slot| {
        if (!used) try emitter.output.writer.print("  store %lnako.Value {{ i8 0, i64 0 }}, ptr %gc.slot.{d}\n", .{slot});
    }
}
