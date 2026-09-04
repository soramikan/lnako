const std = @import("std");
const ir = @import("../../ir/nako_ir.zig");
const builtin_catalog = @import("../../semantic/builtin_catalog.zig");
const value_mod = @import("../value.zig");
const plugin_system = @import("../../plugins/system.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;
pub const DispatchTraceWriteFn = *const fn (context: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void;

pub const default_plugin_names = [_][]const u8{
    "plugin_system",
    "plugin_math",
    "plugin_promise",
    "plugin_test",
    "plugin_csv",
    "plugin_toml",
    "plugin_node",
};

pub const DispatchTrace = struct {
    path: ?[]const u8 = null,
    context: ?*anyopaque = null,
    writeFn: ?DispatchTraceWriteFn = null,
    disabled: bool = false,
    sequence: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *DispatchTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *DispatchTrace) void {
        self.locked.store(false, .release);
    }

    pub fn emit(self: *DispatchTrace, name: []const u8, route: []const u8, result: []const u8, site_id: ?u64) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const path = self.path orelse return;
        const writeFn = self.writeFn orelse return;
        const context = self.context orelse return;
        var line: [1024]u8 = undefined;
        const rendered = (if (site_id) |id| std.fmt.bufPrint(
            &line,
            "{{\"schema\":2,\"engine\":\"interpreter\",\"phase\":\"dispatch-result\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"command\":\"{s}\",\"route\":\"{s}\",\"result\":\"{s}\"}}\n",
            .{ self.sequence, id, name, route, result },
        ) else std.fmt.bufPrint(
            &line,
            "{{\"schema\":2,\"engine\":\"interpreter\",\"phase\":\"dispatch-result\",\"seq\":{d},\"siteId\":null,\"command\":\"{s}\",\"route\":\"{s}\",\"result\":\"{s}\"}}\n",
            .{ self.sequence, name, route, result },
        )) catch {
            self.disabled = true;
            return;
        };
        writeFn(context, path, rendered) catch {
            self.disabled = true;
            return;
        };
        self.sequence += 1;
    }

    pub fn finish(self: *DispatchTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const path = self.path orelse return;
        const writeFn = self.writeFn orelse return;
        const context = self.context orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":2,\"engine\":\"interpreter\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        writeFn(context, path, rendered) catch return;
        self.sequence += 1;
        self.disabled = true;
    }

    pub fn finishTerminal(self: *DispatchTrace, reason: []const u8, exit_code: u8) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const path = self.path orelse return;
        const writeFn = self.writeFn orelse return;
        const context = self.context orelse return;
        var line: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":2,\"engine\":\"interpreter\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0,\"terminalReason\":\"{s}\",\"exitCode\":{d},\"signal\":null}}\n",
            .{ self.sequence, reason, exit_code },
        ) catch return;
        writeFn(context, path, rendered) catch return;
        self.sequence += 1;
        self.disabled = true;
    }
};

pub const CompatJsTrace = struct {
    path: ?[]const u8 = null,
    context: ?*anyopaque = null,
    writeFn: ?DispatchTraceWriteFn = null,
    disabled: bool = false,
    sequence: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *CompatJsTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *CompatJsTrace) void {
        self.locked.store(false, .release);
    }

    pub fn emit(self: *CompatJsTrace, command: []const u8, operation: []const u8, phase: []const u8, result: ?[]const u8, site_id: ?u64) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const path = self.path orelse return;
        const writeFn = self.writeFn orelse return;
        const context = self.context orelse return;
        var line: [512]u8 = undefined;
        const rendered = if (site_id) |id|
            if (result) |result_name| std.fmt.bufPrint(
                &line,
                "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"{s}\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"command\":\"{s}\",\"operation\":\"{s}\",\"result\":\"{s}\"}}\n",
                .{ phase, self.sequence, id, command, operation, result_name },
            ) catch {
                self.disabled = true;
                return;
            } else std.fmt.bufPrint(
                &line,
                "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"{s}\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"command\":\"{s}\",\"operation\":\"{s}\"}}\n",
                .{ phase, self.sequence, id, command, operation },
            ) catch {
                self.disabled = true;
                return;
            }
        else if (result) |result_name| std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"{s}\",\"seq\":{d},\"siteId\":null,\"command\":\"{s}\",\"operation\":\"{s}\",\"result\":\"{s}\"}}\n",
            .{ phase, self.sequence, command, operation, result_name },
        ) catch {
            self.disabled = true;
            return;
        } else std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"{s}\",\"seq\":{d},\"siteId\":null,\"command\":\"{s}\",\"operation\":\"{s}\"}}\n",
            .{ phase, self.sequence, command, operation },
        ) catch {
            self.disabled = true;
            return;
        };
        writeFn(context, path, rendered) catch {
            self.disabled = true;
            return;
        };
        self.sequence += 1;
    }

    pub fn finish(self: *CompatJsTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const path = self.path orelse return;
        const writeFn = self.writeFn orelse return;
        const context = self.context orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        writeFn(context, path, rendered) catch return;
        self.sequence += 1;
        self.disabled = true;
    }
};

pub const GlobalTrace = struct {
    path: ?[]const u8 = null,
    context: ?*anyopaque = null,
    writeFn: ?DispatchTraceWriteFn = null,
    disabled: bool = false,
    sequence: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *GlobalTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *GlobalTrace) void {
        self.locked.store(false, .release);
    }

    pub fn emit(self: *GlobalTrace, name: []const u8, found: bool, site_id: ?u64) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const path = self.path orelse return;
        const writeFn = self.writeFn orelse return;
        const context = self.context orelse return;
        var line: [1024]u8 = undefined;
        const rendered = (if (site_id) |id| std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"global-read\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"name\":\"{s}\",\"found\":{}}}\n",
            .{ self.sequence, id, name, found },
        ) else std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"global-read\",\"seq\":{d},\"siteId\":null,\"name\":\"{s}\",\"found\":{}}}\n",
            .{ self.sequence, name, found },
        )) catch {
            self.disabled = true;
            return;
        };
        writeFn(context, path, rendered) catch {
            self.disabled = true;
            return;
        };
        self.sequence += 1;
    }

    pub fn emitWrite(self: *GlobalTrace, name: []const u8, site_id: ?u64) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const path = self.path orelse return;
        const writeFn = self.writeFn orelse return;
        const context = self.context orelse return;
        var line: [1024]u8 = undefined;
        const rendered = (if (site_id) |id| std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"global-write\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"name\":\"{s}\"}}\n",
            .{ self.sequence, id, name },
        ) else std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"global-write\",\"seq\":{d},\"siteId\":null,\"name\":\"{s}\"}}\n",
            .{ self.sequence, name },
        )) catch {
            self.disabled = true;
            return;
        };
        writeFn(context, path, rendered) catch {
            self.disabled = true;
            return;
        };
        self.sequence += 1;
    }

    pub fn finish(self: *GlobalTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const path = self.path orelse return;
        const writeFn = self.writeFn orelse return;
        const context = self.context orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        writeFn(context, path, rendered) catch return;
        self.sequence += 1;
        self.disabled = true;
    }
};

pub const LiteralTrace = struct {
    path: ?[]const u8 = null,
    context: ?*anyopaque = null,
    writeFn: ?DispatchTraceWriteFn = null,
    disabled: bool = false,
    sequence: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *LiteralTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *LiteralTrace) void {
        self.locked.store(false, .release);
    }

    pub fn emit(self: *LiteralTrace, name: []const u8, site_id: ?u64) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const path = self.path orelse return;
        const writeFn = self.writeFn orelse return;
        const context = self.context orelse return;
        var line: [1024]u8 = undefined;
        const rendered = (if (site_id) |id| std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"literal\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"name\":\"{s}\"}}\n",
            .{ self.sequence, id, name },
        ) else std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"literal\",\"seq\":{d},\"siteId\":null,\"name\":\"{s}\"}}\n",
            .{ self.sequence, name },
        )) catch {
            self.disabled = true;
            return;
        };
        writeFn(context, path, rendered) catch {
            self.disabled = true;
            return;
        };
        self.sequence += 1;
    }

    pub fn finish(self: *LiteralTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const path = self.path orelse return;
        const writeFn = self.writeFn orelse return;
        const context = self.context orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"interpreter\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        writeFn(context, path, rendered) catch return;
        self.sequence += 1;
        self.disabled = true;
    }
};

pub const TestResult = struct { name: []const u8, passed: bool, message: []const u8 = "" };

pub const IteratorKind = enum { repeat, range, bytes, array, string, dictionary };

pub const IteratorState = struct {
    kind: IteratorKind,
    source: Value = .undefined,
    index: usize = 0,
    count: usize = 0,
    current: f64 = 0,
    end: f64 = 0,
    step: f64 = 1,
    variable_name: []const u8 = "",
};

pub const Timer = struct {
    id: u64,
    due_milliseconds: u64,
    interval_milliseconds: u64 = 0,
    repeating: bool = false,
    callback: Value,
};

pub const PromiseResolver = struct {
    promise: *value_mod.Promise,
    rejected: bool,
};

pub const PromiseAllState = struct {
    promise: *value_mod.Promise,
    results: *value_mod.Array,
    remaining: usize = 0,
};

pub const PromiseAllHandler = struct {
    state: *PromiseAllState,
    index: usize,
    rejected: bool,
    peer: *value_mod.Function,
};

pub const PromiseChainKind = enum { success, failure, settled, finally };

pub const NamespaceFrame = struct {
    namespace: Value,
    plugin_name: Value,
};

pub const HatenaCallback = union(enum) {
    function: Value,
    name: Value,
};

pub const Frame = struct {
    parent: ?*Frame,
    function: *const ir.Function,
    owner_program: *const ir.Program,
    values: []Value,
    locals: std.StringHashMapUnmanaged(*value_mod.BindingCell) = .empty,
    owned_names: std.ArrayList([]u8) = .empty,
    iterators: std.AutoHashMapUnmanaged(ir.ValueId, IteratorState) = .empty,
    handlers: std.ArrayList(ir.BlockId) = .empty,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        self.locals.deinit(allocator);
        for (self.owned_names.items) |name| allocator.free(name);
        self.owned_names.deinit(allocator);
        self.iterators.deinit(allocator);
        self.handlers.deinit(allocator);
        allocator.free(self.values);
        self.* = undefined;
    }
};

pub fn compatJsOperation(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "JS実行")) return "eval";
    if (std.mem.eql(u8, name, "JSオブジェクト取得")) return "lookup";
    if (std.mem.eql(u8, name, "JS関数実行")) return "call";
    if (std.mem.eql(u8, name, "JSメソッド実行")) return "method-call";
    return null;
}

pub fn traceBuiltinName(name: []const u8) []const u8 {
    for (builtin_catalog.names) |known| {
        if (std.mem.eql(u8, known, name)) return name;
    }
    // Unknown names are still represented without copying arbitrary source
    // text into a trace file.
    return "<non-catalog>";
}

pub fn localValue(frame: *const Frame, name: []const u8) ?Value {
    const cell = frame.locals.get(name) orelse return null;
    return cell.value;
}

pub fn preservesResultVariable(name: []const u8) bool {
    return std.mem.eql(u8, name, "表示") or
        std.mem.eql(u8, name, "表示する") or
        std.mem.eql(u8, name, "継続表示") or
        std.mem.eql(u8, name, "連続表示") or
        std.mem.eql(u8, name, "連続無改行表示") or
        std.mem.eql(u8, name, "表示ログクリア") or
        std.mem.eql(u8, name, "言") or
        std.mem.eql(u8, name, "コンソール表示") or
        std.mem.eql(u8, name, "デバッグ表示") or
        std.mem.eql(u8, name, "二進表示");
}

pub fn promiseResolverSentinel(_: *Runtime, _: []const Value) anyerror!Value {
    return .undefined;
}

pub fn promiseAllSentinel(_: *Runtime, _: []const Value) anyerror!Value {
    return .undefined;
}

pub fn maxValueId(function: ir.Function) usize {
    var maximum: usize = if (function.parameters.len == 0) 0 else function.parameters.len - 1;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.result) |result| maximum = @max(maximum, result);
        }
    }
    return maximum;
}

pub fn valueIndex(runtime: *Runtime, value: Value) !usize {
    const number = try runtime.valueToNumber(value);
    if (!std.math.isFinite(number) or number < 0 or number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidIndex;
    return @intFromFloat(@trunc(number));
}

pub fn getArrayProperty(runtime: *Runtime, array: *value_mod.Array, key: Value) !Value {
    var rooted_array = Value{ .array = array };
    var rooted_key = key;
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_array);
    try roots.protect(&rooted_key);
    var key_text = try runtime.valueToString(rooted_key);
    try roots.protect(&key_text);
    if (std.mem.eql(u16, key_text.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(array.len()) };
    if (interpreterArrayIndex(key_text.string.units)) |position| return array.get(position);
    if (array.getProperty(key_text.string)) |value| return value;
    return (try plugin_system.arrays.standardInheritedProperty(runtime, rooted_array, key_text.string.units)) orelse .undefined;
}

pub fn interpreterArrayIndex(units: []const u16) ?usize {
    if (units.len == 0 or (units.len > 1 and units[0] == '0')) return null;
    var result: usize = 0;
    for (units) |unit| {
        if (unit < '0' or unit > '9') return null;
        result = std.math.mul(usize, result, 10) catch return null;
        result = std.math.add(usize, result, unit - '0') catch return null;
    }
    return if (result <= 4_294_967_294) result else null;
}

pub fn repeatCount(number: f64) !usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.IteratorCountTooLarge;
    return @intFromFloat(@trunc(number));
}

pub fn ownProperty(properties: []const value_mod.ArrayProperty, name: []const u16) ?Value {
    for (properties) |property| if (std.mem.eql(u16, property.key.units, name)) return property.value;
    return null;
}

pub fn setOwnProperty(properties: *std.ArrayList(value_mod.ArrayProperty), allocator: std.mem.Allocator, key: *value_mod.String, value: Value) !void {
    for (properties.items) |*property| if (value_mod.String.eql(property.key.*, key.*)) {
        property.value = value;
        return;
    };
    try properties.append(allocator, .{ .key = key, .value = value });
}

pub fn objectPrimitiveMethod(value: Value, name: []const u16) ?Value {
    return switch (value) {
        .dictionary => |dictionary| value_mod.dictionaryPropertyUnits(dictionary, name),
        .array => |array| blk: {
            for (array.properties.items) |property| {
                if (std.mem.eql(u16, property.key.units, name)) break :blk property.value;
            }
            if (value_mod.arrayPrototypePropertyUnits(array, name)) |inherited| break :blk inherited;
            break :blk null;
        },
        .bytes => |bytes| blk: {
            if (ownProperty(bytes.properties.items, name)) |own_value| break :blk own_value;
            // OrdinaryToPrimitive performs a normal property lookup.  A
            // Buffer/TypedArray/ArrayBuffer may therefore inherit a
            // custom toString/valueOf from an object assigned through
            // __proto__.  Do not use standardInheritedProperty here:
            // its synthesized built-in methods are handled by the
            // default conversion below and are not custom overrides.
            if (bytes.prototype == .dictionary) break :blk value_mod.dictionaryPropertyUnits(bytes.prototype.dictionary, name);
            break :blk null;
        },
        .function => |function| ownProperty(function.properties.items, name),
        .promise => |promise| ownProperty(promise.properties.items, name),
        else => null,
    };
}

pub fn isPrototypeObject(value: Value) bool {
    return switch (value) {
        .bytes, .array, .dictionary, .function, .promise => true,
        else => false,
    };
}

pub fn interpreterByteBufferReadOnlyProperty(kind: value_mod.ByteKind, units: []const u16) bool {
    return (kind != .array_buffer and std.mem.eql(u16, units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) or
        std.mem.eql(u16, units, &.{ 'b', 'y', 't', 'e', 'L', 'e', 'n', 'g', 't', 'h' }) or
        std.mem.eql(u16, units, &.{ 'b', 'y', 't', 'e', 'O', 'f', 'f', 's', 'e', 't' }) or
        std.mem.eql(u16, units, &.{ 'B', 'Y', 'T', 'E', 'S', '_', 'P', 'E', 'R', '_', 'E', 'L', 'E', 'M', 'E', 'N', 'T' }) or
        std.mem.eql(u16, units, &.{ 'b', 'u', 'f', 'f', 'e', 'r' }) or
        std.mem.eql(u16, units, &.{ 'm', 'a', 'x', 'B', 'y', 't', 'e', 'L', 'e', 'n', 'g', 't', 'h' }) or
        std.mem.eql(u16, units, &.{ 'r', 'e', 's', 'i', 'z', 'a', 'b', 'l', 'e' }) or
        std.mem.eql(u16, units, &.{ 'd', 'e', 't', 'a', 'c', 'h', 'e', 'd' }) or
        std.mem.eql(u16, units, &.{ 'p', 'a', 'r', 'e', 'n', 't' }) or
        std.mem.eql(u16, units, &.{ 'o', 'f', 'f', 's', 'e', 't' });
}
