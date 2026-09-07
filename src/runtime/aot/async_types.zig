const std = @import("std");

pub fn Timer(comptime Value: type) type {
    return struct {
        id: u64,
        due_milliseconds: u64,
        interval_milliseconds: u64,
        repeating: bool,
        callback: Value,
    };
}

pub const IteratorKind = enum { repeat, range, bytes, string, array, dictionary };

pub fn Iterator(comptime Value: type) type {
    return struct {
        kind: IteratorKind,
        source: Value = .{},
        index: usize = 0,
        count: usize = 0,
        current: f64 = 0,
        end: f64 = 0,
        step: f64 = 1,
    };
}

pub const PromiseState = enum { pending, fulfilled, rejected };
pub const PromiseReactionMode = enum { standard, settled_pair, finally };

pub fn PromiseReaction(comptime Value: type, comptime Object: type) type {
    return struct {
        on_fulfilled: Value = .{},
        on_rejected: Value = .{},
        next: *Object,
        mode: PromiseReactionMode = .standard,
        target_global: ?*Value = null,
    };
}

pub fn Promise(comptime Value: type, comptime Object: type) type {
    return struct {
        state: PromiseState = .pending,
        result: Value = .{},
        reactions: std.ArrayList(PromiseReaction(Value, Object)) = .empty,
    };
}

pub fn PromiseTask(comptime Value: type, comptime Object: type) type {
    return struct {
        callback: Value,
        settled_value: Value,
        rejected: bool,
        next: *Object,
        mode: PromiseReactionMode,
        target_global: ?*Value,
    };
}

pub fn PromiseAllState(comptime Value: type, comptime Object: type) type {
    return struct {
        promise: *Object,
        results: Value,
        remaining: usize = 0,
    };
}

pub fn PromiseResolver(comptime Object: type) type {
    return struct {
        promise: *Object,
        rejected: bool,
    };
}

pub fn PromiseAllHandler(comptime AllState: type) type {
    return struct {
        state: *AllState,
        index: usize,
        rejected: bool,
    };
}
