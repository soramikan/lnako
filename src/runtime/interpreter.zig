const std = @import("std");
const ir = @import("../ir/nako_ir.zig");
const parser = @import("../frontend/parser.zig");
const semantic = @import("../semantic/analyzer.zig");
const hir = @import("../ir/hir.zig");
const lower_ssa = @import("../ir/lower_ssa.zig");
const verifier = @import("../ir/verifier.zig");
const value_mod = @import("value.zig");
const operators = @import("operators.zig");
const plugin_system = @import("../plugins/system.zig");
const plugin_math = @import("../plugins/math.zig");
const plugin_csv = @import("../plugins/csv.zig");
const plugin_toml = @import("../plugins/toml.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const Host = struct {
    context: *anyopaque,
    writeFn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,
    sleepMillisecondsFn: ?*const fn (context: *anyopaque, milliseconds: u64) anyerror!void = null,
    nowMillisecondsFn: ?*const fn (context: *anyopaque) anyerror!i64 = null,
    monotonicMillisecondsFn: ?*const fn (context: *anyopaque) anyerror!f64 = null,
    randomFn: ?*const fn (context: *anyopaque) anyerror!f64 = null,

    pub fn write(self: Host, bytes: []const u8) !void {
        try self.writeFn(self.context, bytes);
    }

    pub fn sleepMilliseconds(self: Host, milliseconds: u64) !void {
        if (self.sleepMillisecondsFn) |sleepFn| try sleepFn(self.context, milliseconds);
    }

    pub fn nowMilliseconds(self: Host) !i64 {
        return if (self.nowMillisecondsFn) |function| function(self.context) else 0;
    }

    pub fn monotonicMilliseconds(self: Host) !f64 {
        return if (self.monotonicMillisecondsFn) |function| function(self.context) else 0;
    }

    pub fn random(self: Host) !f64 {
        return if (self.randomFn) |function| function(self.context) else error.RandomSourceUnavailable;
    }
};

pub const BufferHost = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,
    elapsed_milliseconds: u64 = 0,
    now_milliseconds: i64 = 1_735_689_845_678,
    random_state: u64 = 0x4d595df4d0f33173,

    pub fn deinit(self: *BufferHost) void {
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn host(self: *BufferHost) Host {
        return .{
            .context = self,
            .writeFn = write,
            .sleepMillisecondsFn = sleepMilliseconds,
            .nowMillisecondsFn = nowMilliseconds,
            .monotonicMillisecondsFn = monotonicMilliseconds,
            .randomFn = random,
        };
    }

    pub fn written(self: BufferHost) []const u8 {
        return self.output.items;
    }

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        try self.output.appendSlice(self.allocator, bytes);
    }

    fn sleepMilliseconds(context: *anyopaque, milliseconds: u64) !void {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        self.elapsed_milliseconds = std.math.add(u64, self.elapsed_milliseconds, milliseconds) catch return error.TimerOverflow;
    }

    fn nowMilliseconds(context: *anyopaque) !i64 {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        return self.now_milliseconds;
    }

    fn monotonicMilliseconds(context: *anyopaque) !f64 {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        return @floatFromInt(self.elapsed_milliseconds);
    }

    fn random(context: *anyopaque) !f64 {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        var value = self.random_state;
        value ^= value >> 12;
        value ^= value << 25;
        value ^= value >> 27;
        self.random_state = value;
        const bits = (value *% 0x2545f4914f6cdd1d) >> 11;
        return @as(f64, @floatFromInt(bits)) / 9007199254740992.0;
    }
};

pub const TestResult = struct { name: []const u8, passed: bool, message: []const u8 = "" };

const IteratorKind = enum { repeat, range, array, string, dictionary };
const IteratorState = struct {
    kind: IteratorKind,
    source: Value = .undefined,
    index: usize = 0,
    count: usize = 0,
    current: f64 = 0,
    end: f64 = 0,
    step: f64 = 1,
    variable_name: []const u8 = "",
};

const Timer = struct {
    id: u64,
    due_milliseconds: u64,
    interval_milliseconds: u64 = 0,
    repeating: bool = false,
    callback: Value,
};

const PromiseResolver = struct {
    promise: *value_mod.Promise,
    rejected: bool,
};

const PromiseAllState = struct {
    promise: *value_mod.Promise,
    results: *value_mod.Array,
    remaining: usize = 0,
};

const PromiseAllHandler = struct {
    state: *PromiseAllState,
    index: usize,
    rejected: bool,
    peer: *value_mod.Function,
};

const PromiseChainKind = enum { success, failure, settled, finally };

const Frame = struct {
    parent: ?*Frame,
    function: *const ir.Function,
    values: []Value,
    locals: std.StringHashMapUnmanaged(Value) = .empty,
    owned_names: std.ArrayList([]u8) = .empty,
    iterators: std.AutoHashMapUnmanaged(ir.ValueId, IteratorState) = .empty,
    handlers: std.ArrayList(ir.BlockId) = .empty,

    fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        self.locals.deinit(allocator);
        for (self.owned_names.items) |name| allocator.free(name);
        self.owned_names.deinit(allocator);
        self.iterators.deinit(allocator);
        self.handlers.deinit(allocator);
        allocator.free(self.values);
        self.* = undefined;
    }
};

pub const Interpreter = struct {
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    program: ir.Program,
    host: Host,
    globals: std.StringHashMapUnmanaged(Value) = .empty,
    global_names: std.ArrayList([]u8) = .empty,
    active_frame: ?*Frame = null,
    exception_value: Value = .undefined,
    call_depth: usize = 0,
    max_call_depth: usize = 4096,
    dynamic_depth: usize = 0,
    max_dynamic_depth: usize = 64,
    test_results: std.ArrayList(TestResult) = .empty,
    output_captures: std.ArrayList(*std.ArrayList(u8)) = .empty,
    print_pool: std.ArrayList(u8) = .empty,
    csv_state: plugin_csv.State,
    timers: std.ArrayList(Timer) = .empty,
    promise_resolvers: std.AutoHashMapUnmanaged(*value_mod.Function, PromiseResolver) = .empty,
    promise_all_handlers: std.AutoHashMapUnmanaged(*value_mod.Function, PromiseAllHandler) = .empty,
    promise_all_states: std.ArrayList(*PromiseAllState) = .empty,
    elapsed_milliseconds: u64 = 0,
    next_timer_id: u64 = 1,
    event_count: usize = 0,
    max_event_count: usize = 100_000,
    system_initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, runtime: *Runtime, program: ir.Program, host: Host) Interpreter {
        return .{ .allocator = allocator, .runtime = runtime, .program = program, .host = host, .csv_state = plugin_csv.State.init(allocator) };
    }

    pub fn deinit(self: *Interpreter) void {
        self.globals.deinit(self.allocator);
        for (self.global_names.items) |name| self.allocator.free(name);
        self.global_names.deinit(self.allocator);
        for (self.test_results.items) |result| {
            self.allocator.free(result.name);
            if (result.message.len > 0) self.allocator.free(result.message);
        }
        self.test_results.deinit(self.allocator);
        self.output_captures.deinit(self.allocator);
        self.print_pool.deinit(self.allocator);
        self.csv_state.deinit();
        self.timers.deinit(self.allocator);
        self.promise_resolvers.deinit(self.allocator);
        self.promise_all_handlers.deinit(self.allocator);
        for (self.promise_all_states.items) |state| self.allocator.destroy(state);
        self.promise_all_states.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn run(self: *Interpreter) !Value {
        try self.runtime.registerRootProvider(.{ .context = self, .traceFn = traceRoots });
        defer self.runtime.unregisterRootProvider(self);
        try self.initializeSystem();
        const result = try self.runEntries();
        try self.drainEventLoop();
        return result;
    }

    pub fn runTests(self: *Interpreter) ![]const TestResult {
        try self.runtime.registerRootProvider(.{ .context = self, .traceFn = traceRoots });
        defer self.runtime.unregisterRootProvider(self);
        try self.initializeSystem();
        for (self.program.functions) |*function| {
            if (!function.is_test) continue;
            const result = self.executeFunction(function, &.{}, null);
            if (result) |_| {
                try self.drainEventLoop();
                try self.test_results.append(self.allocator, .{ .name = try self.allocator.dupe(u8, function.name), .passed = true });
            } else |failure| {
                try self.test_results.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, function.name),
                    .passed = false,
                    .message = try self.allocator.dupe(u8, @errorName(failure)),
                });
            }
        }
        return self.test_results.items;
    }

    pub fn getGlobal(self: Interpreter, name: []const u8) ?Value {
        return self.globals.get(name);
    }

    fn runEntries(self: *Interpreter) !Value {
        var result: Value = .undefined;
        var index = self.program.module_entries.len;
        while (index > 0) {
            index -= 1;
            result = try self.executeFunction(&self.program.functions[self.program.module_entries[index]], &.{}, null);
        }
        return result;
    }

    fn executeFunction(self: *Interpreter, function: *const ir.Function, arguments: []const Value, closure: ?*value_mod.Function) anyerror!Value {
        if (self.call_depth >= self.max_call_depth) return error.CallStackLimitExceeded;
        self.call_depth += 1;
        defer self.call_depth -= 1;
        const value_count = maxValueId(function.*) + 1;
        const values = try self.allocator.alloc(Value, value_count);
        @memset(values, .undefined);
        var frame = Frame{ .parent = self.active_frame, .function = function, .values = values };
        defer frame.deinit(self.allocator);
        self.active_frame = &frame;
        defer self.active_frame = frame.parent;

        if (closure) |function_value| for (function_value.captures) |capture| {
            const name = try capture.name.toUtf8Lossy(self.allocator);
            try frame.owned_names.append(self.allocator, name);
            try frame.locals.put(self.allocator, name, capture.value);
        };
        for (function.parameters, 0..) |parameter, index| {
            const argument = if (index < arguments.len) arguments[index] else Value.undefined;
            frame.values[parameter.value] = argument;
            try frame.locals.put(self.allocator, parameter.name, argument);
        }

        var current_block = function.entry;
        var predecessor: ?ir.BlockId = null;
        execution: while (true) {
            if (current_block >= function.blocks.len) return error.InvalidBranchTarget;
            const block = function.blocks[current_block];
            var exceptional_target: ?ir.BlockId = null;
            for (block.instructions) |instruction| {
                self.executeInstruction(&frame, instruction, predecessor) catch |failure| {
                    if (frame.handlers.pop()) |handler| {
                        if (self.exception_value == .undefined) self.exception_value = self.runtime.stringUtf8(@errorName(failure)) catch return failure;
                        try self.setGlobal("エラーメッセージ", self.exception_value);
                        exceptional_target = handler;
                        break;
                    }
                    return failure;
                };
            }
            if (exceptional_target) |handler| {
                predecessor = current_block;
                current_block = handler;
                continue :execution;
            }
            switch (block.terminator) {
                .none => return error.MissingTerminator,
                .branch => |target| {
                    predecessor = current_block;
                    current_block = target;
                },
                .conditional_branch => |branch| {
                    predecessor = current_block;
                    current_block = if (frame.values[branch.condition].toBoolean()) branch.then_block else branch.else_block;
                },
                .return_value => |value| return if (value) |id| frame.values[id] else self.globals.get("それ") orelse .undefined,
                .throw_value => |value| {
                    self.exception_value = frame.values[value];
                    if (frame.handlers.pop()) |handler| {
                        try self.setGlobal("エラーメッセージ", self.exception_value);
                        predecessor = current_block;
                        current_block = handler;
                    } else return error.NakoException;
                },
                .unreachable_terminator => return error.ReachedUnreachable,
            }
        }
    }

    fn executeInstruction(self: *Interpreter, frame: *Frame, instruction: ir.Instruction, predecessor: ?ir.BlockId) anyerror!void {
        var result: ?Value = null;
        switch (instruction.opcode) {
            .const_number => result = .{ .number = instruction.number_value orelse 0 },
            .const_bigint => result = try self.runtime.bigIntLiteral(instruction.text),
            .const_boolean => result = .{ .boolean = instruction.boolean_value },
            .const_null => result = .null_value,
            .const_string => result = try self.runtime.stringUtf8(instruction.text),
            .const_undefined => result = .undefined,
            .load_global => result = self.globals.get(instruction.name) orelse .undefined,
            .load_local => result = frame.locals.get(instruction.name) orelse self.globals.get(instruction.name) orelse .undefined,
            .store_global => try self.setGlobal(instruction.name, self.operand(frame, instruction, 0)),
            .store_local => try frame.locals.put(self.allocator, instruction.name, self.operand(frame, instruction, 0)),
            .destructure_store => try self.executeDestructure(frame, instruction),
            .binary => result = try self.executeBinary(frame, instruction),
            .unary => result = try self.executeUnary(frame, instruction),
            .call => result = try self.executeCall(frame, instruction),
            .call_value => result = try self.executeCallValue(frame, instruction),
            .make_array => result = try self.makeArray(frame, instruction),
            .make_object => result = try self.makeDictionary(frame, instruction),
            .array_get, .property_get => result = try self.getIndexed(frame, instruction),
            .array_set, .property_set => try self.setIndexed(frame, instruction),
            .increment => try self.increment(frame, instruction),
            .make_closure => result = try self.makeClosure(frame, instruction),
            .iterator_begin => result = try self.iteratorBegin(frame, instruction),
            .iterator_has_next => result = .{ .boolean = try self.iteratorHasNext(frame, instruction) },
            .iterator_next => result = try self.iteratorNext(frame, instruction),
            .try_begin => try frame.handlers.append(self.allocator, instruction.exception_target orelse return error.MissingExceptionTarget),
            .try_end => _ = frame.handlers.pop(),
            .dynamic_execute => result = try self.executeDynamicValue(self.operand(frame, instruction, 0)),
            .phi => {
                const source = predecessor orelse return error.InvalidPhiPredecessor;
                for (instruction.phi_incoming) |incoming| if (incoming.predecessor == source) {
                    result = frame.values[incoming.value];
                    break;
                };
                if (result == null) return error.InvalidPhiPredecessor;
            },
            .speed_mode_begin, .speed_mode_end, .performance_monitor_begin, .performance_monitor_end => {},
        }
        if (instruction.result) |id| frame.values[id] = result orelse return error.MissingInstructionResult;
    }

    fn operand(self: Interpreter, frame: *Frame, instruction: ir.Instruction, index: usize) Value {
        _ = self;
        return frame.values[instruction.operands[index]];
    }

    fn executeDestructure(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
        const source = self.operand(frame, instruction, 0);
        for (instruction.names, 0..) |name, index| {
            const value = if (source == .array) source.array.get(index) else .undefined;
            if (std.mem.indexOf(u8, name, "__") != null) {
                try self.setGlobal(name, value);
            } else try frame.locals.put(self.allocator, name, value);
        }
    }

    fn executeBinary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        const left = self.operand(frame, instruction, 0);
        const right = self.operand(frame, instruction, 1);
        if (std.mem.eql(u8, instruction.operator, "+")) return operators.binary(self.runtime, .add, left, right);
        if (std.mem.eql(u8, instruction.operator, "-")) return operators.binary(self.runtime, .subtract, left, right);
        if (std.mem.eql(u8, instruction.operator, "*")) return operators.binary(self.runtime, .multiply, left, right);
        if (std.mem.eql(u8, instruction.operator, "/") or std.mem.eql(u8, instruction.operator, "÷")) return operators.binary(self.runtime, .divide, left, right);
        if (std.mem.eql(u8, instruction.operator, "÷÷")) {
            const quotient = try operators.binary(self.runtime, .divide, left, right);
            if (quotient == .number) return .{ .number = @trunc(quotient.number) };
            return quotient;
        }
        if (std.mem.eql(u8, instruction.operator, "%")) return operators.binary(self.runtime, .remainder, left, right);
        if (std.mem.eql(u8, instruction.operator, "**")) return operators.binary(self.runtime, .power, left, right);
        if (std.mem.eql(u8, instruction.operator, "&")) {
            const left_string = (try self.runtime.valueToString(left)).string;
            const right_string = (try self.runtime.valueToString(right)).string;
            return self.runtime.concatStrings(left_string, right_string);
        }
        if (std.mem.eql(u8, instruction.operator, "|")) return operators.binary(self.runtime, .bit_or, left, right);
        if (std.mem.eql(u8, instruction.operator, "^")) return operators.binary(self.runtime, .bit_xor, left, right);
        if (std.mem.eql(u8, instruction.operator, "shift_l")) return operators.binary(self.runtime, .shift_left, left, right);
        if (std.mem.eql(u8, instruction.operator, "shift_r")) return operators.binary(self.runtime, .shift_right, left, right);
        if (std.mem.eql(u8, instruction.operator, "shift_r0")) return operators.binary(self.runtime, .shift_right_unsigned, left, right);
        if (std.mem.eql(u8, instruction.operator, "&&") or std.mem.eql(u8, instruction.operator, "and")) return if (left.toBoolean()) right else left;
        if (std.mem.eql(u8, instruction.operator, "||") or std.mem.eql(u8, instruction.operator, "or")) return if (left.toBoolean()) left else right;
        if (std.mem.eql(u8, instruction.operator, "==") or std.mem.eql(u8, instruction.operator, "=") or std.mem.eql(u8, instruction.operator, "eq")) return .{ .boolean = try self.runtime.abstractEqual(left, right) };
        if (std.mem.eql(u8, instruction.operator, "===")) return .{ .boolean = Value.strictEqual(left, right) };
        if (std.mem.eql(u8, instruction.operator, "!=") or std.mem.eql(u8, instruction.operator, "≠") or std.mem.eql(u8, instruction.operator, "noteq")) return .{ .boolean = !(try self.runtime.abstractEqual(left, right)) };
        if (std.mem.eql(u8, instruction.operator, "!==")) return .{ .boolean = !Value.strictEqual(left, right) };
        const order = try operators.compare(self.runtime, left, right);
        if (std.mem.eql(u8, instruction.operator, "<") or std.mem.eql(u8, instruction.operator, "lt")) return .{ .boolean = order != null and order.? == .lt };
        if (std.mem.eql(u8, instruction.operator, "<=") or std.mem.eql(u8, instruction.operator, "lteq")) return .{ .boolean = order != null and order.? != .gt };
        if (std.mem.eql(u8, instruction.operator, ">") or std.mem.eql(u8, instruction.operator, "gt")) return .{ .boolean = order != null and order.? == .gt };
        if (std.mem.eql(u8, instruction.operator, ">=") or std.mem.eql(u8, instruction.operator, "gteq")) return .{ .boolean = order != null and order.? != .lt };
        return error.UnsupportedBinaryOperator;
    }

    fn executeUnary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        const value = self.operand(frame, instruction, 0);
        if (std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not")) return .{ .boolean = !value.toBoolean() };
        if (std.mem.eql(u8, instruction.operator, "-")) return operators.unaryMinus(self.runtime, value);
        if (std.mem.eql(u8, instruction.operator, "+")) return operators.unaryPlus(self.runtime, value);
        if (std.mem.eql(u8, instruction.operator, "~")) return operators.bitNot(self.runtime, value);
        return error.UnsupportedUnaryOperator;
    }

    fn executeCall(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        var arguments = try self.allocator.alloc(Value, instruction.operands.len);
        defer self.allocator.free(arguments);
        for (instruction.operands, 0..) |operand_id, index| arguments[index] = frame.values[operand_id];
        const result = if (self.findFunction(instruction.name)) |function|
            try self.executeFunction(function, arguments, null)
        else if (frame.locals.get(instruction.name)) |callable|
            if (callable == .function) try self.callFunctionValue(callable.function, arguments) else return error.NotCallable
        else if (self.globals.get(instruction.name)) |callable|
            if (callable == .function) try self.callFunctionValue(callable.function, arguments) else return error.NotCallable
        else
            try self.callBuiltin(instruction.name, arguments);
        try self.setGlobal("それ", result);
        return result;
    }

    fn executeCallValue(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        if (instruction.operands.len == 0) return error.NotCallable;
        const callable = frame.values[instruction.operands[0]];
        var arguments = try self.allocator.alloc(Value, instruction.operands.len - 1);
        defer self.allocator.free(arguments);
        for (instruction.operands[1..], 0..) |operand_id, index| arguments[index] = frame.values[operand_id];
        if (callable != .function) return error.NotCallable;
        return self.callFunctionValue(callable.function, arguments);
    }

    fn callFunctionValue(self: *Interpreter, function: *value_mod.Function, arguments: []const Value) !Value {
        if (self.promise_resolvers.get(function)) |resolver| {
            const settled = if (arguments.len > 0) arguments[0] else Value.undefined;
            if (resolver.rejected) {
                try self.runtime.rejectPromise(resolver.promise, settled);
            } else try self.runtime.resolvePromise(resolver.promise, settled);
            try self.removePromiseResolvers(resolver.promise);
            return .undefined;
        }
        if (self.promise_all_handlers.get(function)) |handler| return self.handlePromiseAll(function, handler, arguments);
        return switch (function.kind) {
            .native => self.runtime.call(.{ .function = function }, arguments),
            .ir => |function_id| self.executeFunction(&self.program.functions[function_id], arguments, function),
        };
    }

    fn callBuiltin(self: *Interpreter, name: []const u8, arguments: []const Value) !Value {
        if (std.mem.eql(u8, name, "表示") or std.mem.eql(u8, name, "表示する")) return self.display(arguments);
        if (std.mem.eql(u8, name, "継続表示")) return self.continueDisplay(arguments);
        if (std.mem.eql(u8, name, "連続表示")) return self.displayMany(arguments);
        if (std.mem.eql(u8, name, "連続無改行表示")) return self.continueDisplayMany(arguments);
        if (std.mem.eql(u8, name, "表示ログクリア")) {
            try self.setGlobal("表示ログ", try self.runtime.stringUtf8(""));
            return .undefined;
        }
        if (std.mem.eql(u8, name, "言")) {
            try self.writeValues(arguments, false);
            try self.writeOutput("\n");
            return .undefined;
        }
        if (std.mem.eql(u8, name, "コンソール表示")) {
            try self.writeValues(arguments, false);
            try self.writeOutput("\n");
            return .undefined;
        }
        if (std.mem.eql(u8, name, "エラー発生")) {
            self.exception_value = if (arguments.len > 0) arguments[arguments.len - 1] else try self.runtime.stringUtf8("エラー");
            return error.NakoException;
        }
        if (std.mem.eql(u8, name, "ナデシコ") or std.mem.eql(u8, name, "ナデシコ続")) {
            if (arguments.len == 0) return .undefined;
            return self.executeDynamicValue(arguments[arguments.len - 1]);
        }
        if (std.mem.eql(u8, name, "ASSERT") or std.mem.eql(u8, name, "確認")) {
            if (arguments.len == 0 or !arguments[arguments.len - 1].toBoolean()) return error.AssertionFailed;
            return arguments[arguments.len - 1];
        }
        if (std.mem.eql(u8, name, "ASSERT等") or std.mem.eql(u8, name, "テスト実行") or std.mem.eql(u8, name, "テスト等")) {
            if (arguments.len < 2 or !Value.strictEqual(arguments[0], arguments[1])) return error.AssertionFailed;
            return .{ .boolean = true };
        }
        if (std.mem.eql(u8, name, "秒待") or std.mem.eql(u8, name, "秒待機") or std.mem.eql(u8, name, "秒逐次待機")) {
            const milliseconds = try self.delayMilliseconds(if (arguments.len > 0) arguments[arguments.len - 1] else .undefined);
            try self.waitMilliseconds(milliseconds);
            return .undefined;
        }
        if (std.mem.eql(u8, name, "秒後")) return self.scheduleTimer(arguments, false);
        if (std.mem.eql(u8, name, "秒毎") or std.mem.eql(u8, name, "秒タイマー開始時")) return self.scheduleTimer(arguments, true);
        if (std.mem.eql(u8, name, "タイマー停止")) {
            if (arguments.len == 0 or arguments[arguments.len - 1] != .number) return .{ .boolean = false };
            const number = arguments[arguments.len - 1].number;
            if (!std.math.isFinite(number) or number < 0 or number > @as(f64, @floatFromInt(std.math.maxInt(u64)))) return .{ .boolean = false };
            return .{ .boolean = self.stopTimer(@intFromFloat(@trunc(number))) };
        }
        if (std.mem.eql(u8, name, "全タイマー停止")) {
            self.timers.clearRetainingCapacity();
            return .undefined;
        }
        if (std.mem.eql(u8, name, "動時")) return self.createPromiseWithExecutor(arguments);
        if (std.mem.eql(u8, name, "成功時")) return self.chainPromise(arguments, .success);
        if (std.mem.eql(u8, name, "失敗時")) return self.chainPromise(arguments, .failure);
        if (std.mem.eql(u8, name, "処理時")) return self.chainPromise(arguments, .settled);
        if (std.mem.eql(u8, name, "終了時")) return self.chainPromise(arguments, .finally);
        if (std.mem.eql(u8, name, "束")) return self.bundlePromises(arguments);
        if (std.mem.eql(u8, name, "二進表示")) {
            const text = (try plugin_system.types.call(self.runtime, "二進", arguments)).?;
            const utf8 = try text.string.toUtf8Lossy(self.allocator);
            defer self.allocator.free(utf8);
            try self.writeOutput(utf8);
            try self.writeOutput("\n");
            return .undefined;
        }
        if (std.mem.eql(u8, name, "切取")) {
            const result = try plugin_system.strings.cut(self.runtime, if (arguments.len > 0) arguments[0] else .undefined, if (arguments.len > 1) arguments[1] else .undefined);
            try self.setGlobal("対象", result.remainder);
            return result.result;
        }
        if (std.mem.eql(u8, name, "範囲切取")) {
            const result = try plugin_system.strings.cutRange(self.runtime, if (arguments.len > 0) arguments[0] else .undefined, if (arguments.len > 1) arguments[1] else .undefined, if (arguments.len > 2) arguments[2] else .undefined);
            try self.setGlobal("対象", result.remainder);
            return result.result;
        }
        if (std.mem.eql(u8, name, "正規表現マッチ") or std.mem.eql(u8, name, "正規表現抽出")) {
            const result = (try plugin_system.regexp.callWithEffects(self.runtime, name, arguments)).?;
            if (result.captures) |captures| try self.setGlobal("抽出文字列", captures);
            return result.value;
        }
        const plugin_context = try self.pluginContext();
        if (try plugin_math.call(self.runtime, name, arguments, .{
            .context = self,
            .randomFn = pluginRandom,
        })) |value| return value;
        if (try plugin_csv.call(self.runtime, &self.csv_state, name, arguments)) |value| return value;
        if (try plugin_toml.call(self.runtime, name, arguments)) |value| return value;
        if (try plugin_system.callWithContext(self.runtime, name, arguments, plugin_context)) |value| return value;
        return error.UnknownCommand;
    }

    fn initializeSystem(self: *Interpreter) !void {
        if (self.system_initialized) return;
        try plugin_system.constants.install(self.runtime, .{ .context = self, .setFn = installSystemConstant });
        try plugin_system.datetime.install(self.runtime, .{ .context = self, .setFn = installSystemConstant });
        self.system_initialized = true;
    }

    fn display(self: *Interpreter, arguments: []const Value) !Value {
        const value = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
        const text = try self.runtime.valueToString(value);
        const utf8 = try text.string.toUtf8Lossy(self.allocator);
        defer self.allocator.free(utf8);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try output.appendSlice(self.allocator, self.print_pool.items);
        try output.appendSlice(self.allocator, utf8);
        self.print_pool.clearRetainingCapacity();
        try self.writeOutput(output.items);
        try self.writeOutput("\n");
        try self.appendDisplayLog(output.items);
        return .undefined;
    }

    fn continueDisplay(self: *Interpreter, arguments: []const Value) !Value {
        const value = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
        const text = try self.runtime.valueToString(value);
        const utf8 = try text.string.toUtf8Lossy(self.allocator);
        defer self.allocator.free(utf8);
        try self.print_pool.appendSlice(self.allocator, utf8);
        return .undefined;
    }

    fn displayMany(self: *Interpreter, arguments: []const Value) !Value {
        var text = try self.joinValues(arguments);
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&text);
        return self.display(&.{text});
    }

    fn continueDisplayMany(self: *Interpreter, arguments: []const Value) !Value {
        var text = try self.joinValues(arguments);
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&text);
        return self.continueDisplay(&.{text});
    }

    fn joinValues(self: *Interpreter, arguments: []const Value) !Value {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        for (arguments) |value| {
            const text = try self.runtime.valueToString(value);
            const utf8 = try text.string.toUtf8Lossy(self.allocator);
            defer self.allocator.free(utf8);
            try output.appendSlice(self.allocator, utf8);
        }
        return self.runtime.stringUtf8(output.items);
    }

    fn writeValues(self: *Interpreter, arguments: []const Value, all: bool) !void {
        const values = if (all) arguments else if (arguments.len > 0) arguments[arguments.len - 1 ..] else &.{};
        for (values) |value| {
            const text = try self.runtime.valueToString(value);
            const utf8 = try text.string.toUtf8Lossy(self.allocator);
            defer self.allocator.free(utf8);
            try self.writeOutput(utf8);
        }
    }

    fn appendDisplayLog(self: *Interpreter, line: []const u8) !void {
        const current = self.globals.get("表示ログ") orelse try self.runtime.stringUtf8("");
        const current_text = try self.runtime.valueToString(current);
        const current_utf8 = try current_text.string.toUtf8Lossy(self.allocator);
        defer self.allocator.free(current_utf8);
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(self.allocator);
        try output.appendSlice(self.allocator, current_utf8);
        try output.appendSlice(self.allocator, line);
        try output.append(self.allocator, '\n');
        try self.setGlobal("表示ログ", try self.runtime.stringUtf8(output.items));
    }

    fn pluginContext(self: *Interpreter) !plugin_system.Context {
        return .{
            .arrays = .{
                .context = self,
                .randomFn = pluginRandom,
                .callFn = pluginCall,
                .resolveFn = pluginResolve,
            },
            .datetime = .{
                .now_milliseconds = try self.host.nowMilliseconds(),
                .monotonic_milliseconds = try self.host.monotonicMilliseconds(),
            },
        };
    }

    fn pluginRandom(context: *anyopaque) !f64 {
        const self: *Interpreter = @ptrCast(@alignCast(context));
        return self.host.random();
    }

    fn pluginCall(context: *anyopaque, callable: Value, arguments: []const Value) !Value {
        const self: *Interpreter = @ptrCast(@alignCast(context));
        if (callable != .function) return error.NotCallable;
        return self.callFunctionValue(callable.function, arguments);
    }

    fn pluginResolve(context: *anyopaque, name: []const u8) !Value {
        const self: *Interpreter = @ptrCast(@alignCast(context));
        var name_value = try self.runtime.stringUtf8(name);
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&name_value);
        return self.resolveCallback(name_value);
    }

    fn installSystemConstant(context: *anyopaque, name: []const u8, value: Value) !void {
        const self: *Interpreter = @ptrCast(@alignCast(context));
        try self.setGlobal(name, value);
    }

    fn delayMilliseconds(self: *Interpreter, value: Value) !u64 {
        const seconds = try self.runtime.valueToNumber(value);
        if (!std.math.isFinite(seconds) or seconds <= 0) return 0;
        const milliseconds = @floor(seconds * 1000);
        if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return error.TimerOverflow;
        return @intFromFloat(milliseconds);
    }

    fn scheduleTimer(self: *Interpreter, arguments: []const Value, repeating: bool) !Value {
        if (arguments.len < 2) return error.InvalidTimerArguments;
        var callback = try self.resolveCallback(arguments[0]);
        var root = self.runtime.rootFrame();
        defer root.deinit();
        try root.protect(&callback);
        const delay = try self.delayMilliseconds(arguments[1]);
        const timer_id = self.next_timer_id;
        self.next_timer_id = std.math.add(u64, self.next_timer_id, 1) catch return error.TimerOverflow;
        const due = std.math.add(u64, self.elapsed_milliseconds, delay) catch return error.TimerOverflow;
        try self.timers.append(self.allocator, .{
            .id = timer_id,
            .due_milliseconds = due,
            .interval_milliseconds = if (repeating) delay else 0,
            .repeating = repeating,
            .callback = callback,
        });
        const result = Value{ .number = @floatFromInt(timer_id) };
        try self.setGlobal("対象", result);
        return result;
    }

    fn resolveCallback(self: *Interpreter, callback: Value) !Value {
        if (callback == .function) return callback;
        if (callback != .string) return error.NotCallable;
        const name = try callback.string.toUtf8Lossy(self.allocator);
        defer self.allocator.free(name);
        if (self.globals.get(name)) |candidate| {
            if (candidate == .function) return candidate;
        }
        const function = self.findFunction(name) orelse return error.UnknownFunction;
        var name_value = try self.runtime.stringUtf8(function.name);
        var root = self.runtime.rootFrame();
        defer root.deinit();
        try root.protect(&name_value);
        return self.runtime.createIrFunction(name_value.string, function.parameters.len, function.id, &.{});
    }

    fn stopTimer(self: *Interpreter, timer_id: u64) bool {
        for (self.timers.items, 0..) |timer, index| {
            if (timer.id != timer_id) continue;
            _ = self.timers.orderedRemove(index);
            return true;
        }
        return false;
    }

    fn createPromiseWithExecutor(self: *Interpreter, arguments: []const Value) !Value {
        if (arguments.len == 0 or arguments[0] != .function) return error.NotCallable;
        var promise = try self.runtime.createPromise();
        var root = self.runtime.rootFrame();
        defer root.deinit();
        try root.protect(&promise);
        var resolve = try self.createPromiseResolver(promise.promise, false);
        try root.protect(&resolve);
        var reject = try self.createPromiseResolver(promise.promise, true);
        try root.protect(&reject);
        _ = self.callFunctionValue(arguments[0].function, &.{ resolve, reject }) catch |failure| {
            const reason = try self.runtime.stringUtf8(@errorName(failure));
            try self.runtime.rejectPromise(promise.promise, reason);
        };
        if (promise.promise.state != .pending) try self.removePromiseResolvers(promise.promise);
        try self.setGlobal("そ", promise);
        return promise;
    }

    fn createPromiseResolver(self: *Interpreter, promise: *value_mod.Promise, rejected: bool) !Value {
        var promise_root = Value{ .promise = promise };
        var root = self.runtime.rootFrame();
        defer root.deinit();
        try root.protect(&promise_root);
        var name = try self.runtime.stringUtf8(if (rejected) "reject" else "resolve");
        try root.protect(&name);
        const resolver = try self.runtime.createNativeFunction(name.string, 1, promiseResolverSentinel, &.{});
        try self.promise_resolvers.put(self.allocator, resolver.function, .{ .promise = promise, .rejected = rejected });
        return resolver;
    }

    fn removePromiseResolvers(self: *Interpreter, promise: *value_mod.Promise) !void {
        var keys: std.ArrayList(*value_mod.Function) = .empty;
        defer keys.deinit(self.allocator);
        var iterator = self.promise_resolvers.iterator();
        while (iterator.next()) |entry| if (entry.value_ptr.promise == promise) try keys.append(self.allocator, entry.key_ptr.*);
        for (keys.items) |key| _ = self.promise_resolvers.remove(key);
    }

    fn chainPromise(self: *Interpreter, arguments: []const Value, kind: PromiseChainKind) !Value {
        if (arguments.len < 2 or arguments[0] != .function or arguments[1] != .promise) return error.InvalidPromiseArguments;
        const callback = arguments[0];
        const source = arguments[1].promise;
        const result = switch (kind) {
            .success => try self.runtime.promiseThen(source, callback, .undefined),
            .failure => try self.runtime.promiseThen(source, .undefined, callback),
            .settled => try self.runtime.promiseThenMode(source, callback, callback, .settled_pair),
            .finally => try self.runtime.promiseThenMode(source, callback, callback, .finally),
        };
        try self.setGlobal("そ", result);
        return result;
    }

    fn bundlePromises(self: *Interpreter, arguments: []const Value) !Value {
        var promise = try self.runtime.createPromise();
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&promise);
        var results = try self.runtime.createArray();
        try roots.protect(&results);
        for (arguments) |_| _ = try results.array.push(.undefined);

        const state = try self.allocator.create(PromiseAllState);
        errdefer self.allocator.destroy(state);
        state.* = .{ .promise = promise.promise, .results = results.array };
        try self.promise_all_states.append(self.allocator, state);
        errdefer _ = self.promise_all_states.pop();

        for (arguments, 0..) |argument, index| {
            if (argument != .promise) {
                try results.array.set(index, argument);
                continue;
            }
            state.remaining += 1;
            var handler_roots = self.runtime.rootFrame();
            defer handler_roots.deinit();
            var fulfilled_name = try self.runtime.stringUtf8("Promise.all fulfilled");
            try handler_roots.protect(&fulfilled_name);
            var fulfilled = try self.runtime.createNativeFunction(fulfilled_name.string, 1, promiseAllSentinel, &.{});
            try handler_roots.protect(&fulfilled);
            var rejected_name = try self.runtime.stringUtf8("Promise.all rejected");
            try handler_roots.protect(&rejected_name);
            var rejected = try self.runtime.createNativeFunction(rejected_name.string, 1, promiseAllSentinel, &.{});
            try handler_roots.protect(&rejected);
            try self.promise_all_handlers.put(self.allocator, fulfilled.function, .{ .state = state, .index = index, .rejected = false, .peer = rejected.function });
            errdefer _ = self.promise_all_handlers.remove(fulfilled.function);
            try self.promise_all_handlers.put(self.allocator, rejected.function, .{ .state = state, .index = index, .rejected = true, .peer = fulfilled.function });
            errdefer _ = self.promise_all_handlers.remove(rejected.function);
            _ = try self.runtime.promiseThen(argument.promise, fulfilled, rejected);
        }
        if (state.remaining == 0) {
            if (promise.promise.state == .pending) try self.runtime.resolvePromise(promise.promise, results);
            self.destroyPromiseAllState(state);
        }
        try self.setGlobal("そ", promise);
        return promise;
    }

    fn handlePromiseAll(self: *Interpreter, function: *value_mod.Function, handler: PromiseAllHandler, arguments: []const Value) !Value {
        _ = self.promise_all_handlers.remove(function);
        _ = self.promise_all_handlers.remove(handler.peer);
        const settled = if (arguments.len > 0) arguments[0] else Value.undefined;
        if (handler.rejected) {
            try self.runtime.rejectPromise(handler.state.promise, settled);
        } else try handler.state.results.set(handler.index, settled);
        std.debug.assert(handler.state.remaining > 0);
        handler.state.remaining -= 1;
        if (handler.state.remaining == 0) {
            if (handler.state.promise.state == .pending) try self.runtime.resolvePromise(handler.state.promise, .{ .array = handler.state.results });
            self.destroyPromiseAllState(handler.state);
        }
        return .undefined;
    }

    fn destroyPromiseAllState(self: *Interpreter, state: *PromiseAllState) void {
        for (self.promise_all_states.items, 0..) |candidate, index| {
            if (candidate != state) continue;
            _ = self.promise_all_states.orderedRemove(index);
            self.allocator.destroy(state);
            return;
        }
        unreachable;
    }

    fn drainEventLoop(self: *Interpreter) !void {
        while (true) {
            try self.drainPromiseTasks();
            if (self.timers.items.len == 0) return;
            try self.executeTimer(self.earliestTimerIndex().?);
        }
    }

    fn waitMilliseconds(self: *Interpreter, milliseconds: u64) !void {
        const target = std.math.add(u64, self.elapsed_milliseconds, milliseconds) catch return error.TimerOverflow;
        while (true) {
            try self.drainPromiseTasks();
            const earliest = self.earliestTimerIndex() orelse break;
            if (self.timers.items[earliest].due_milliseconds > target) break;
            try self.executeTimer(earliest);
        }
        try self.sleepUntil(target);
    }

    fn drainPromiseTasks(self: *Interpreter) !void {
        while (self.runtime.takePromiseTask()) |task| {
            try self.countEvent();
            try self.executePromiseTask(task);
        }
    }

    fn earliestTimerIndex(self: Interpreter) ?usize {
        if (self.timers.items.len == 0) return null;
        var earliest: usize = 0;
        for (self.timers.items[1..], 1..) |timer, index| {
            if (timer.due_milliseconds < self.timers.items[earliest].due_milliseconds) earliest = index;
        }
        return earliest;
    }

    fn executeTimer(self: *Interpreter, index: usize) !void {
        try self.countEvent();
        const timer = self.timers.orderedRemove(index);
        var callback = timer.callback;
        var root = self.runtime.rootFrame();
        defer root.deinit();
        try root.protect(&callback);
        try self.sleepUntil(timer.due_milliseconds);
        if (timer.repeating) {
            var next = timer;
            next.due_milliseconds = std.math.add(u64, self.elapsed_milliseconds, timer.interval_milliseconds) catch return error.TimerOverflow;
            try self.timers.append(self.allocator, next);
        }
        const id = Value{ .number = @floatFromInt(timer.id) };
        _ = self.callFunctionValue(callback.function, &.{id}) catch |failure| {
            self.exception_value = try self.runtime.stringUtf8(@errorName(failure));
        };
    }

    fn sleepUntil(self: *Interpreter, target: u64) !void {
        if (target <= self.elapsed_milliseconds) return;
        try self.host.sleepMilliseconds(target - self.elapsed_milliseconds);
        self.elapsed_milliseconds = target;
    }

    fn executePromiseTask(self: *Interpreter, task: value_mod.PromiseTask) !void {
        var callback = task.callback;
        var settled = task.settled_value;
        var next = Value{ .promise = task.next };
        var root = self.runtime.rootFrame();
        defer root.deinit();
        try root.protect(&callback);
        try root.protect(&settled);
        try root.protect(&next);
        if (callback == .undefined) return self.runtime.forwardPromiseTask(task);
        if (callback != .function) {
            const reason = try self.runtime.stringUtf8("NotCallable");
            return self.runtime.rejectPromise(task.next, reason);
        }
        if (task.mode != .finally) try self.setGlobal("対象", settled);
        const result = switch (task.mode) {
            .standard => self.callFunctionValue(callback.function, &.{settled}),
            .settled_pair => self.callFunctionValue(callback.function, &.{ .{ .boolean = !task.rejected }, settled }),
            .finally => self.callFunctionValue(callback.function, &.{}),
        } catch |failure| {
            const reason = if (self.exception_value != .undefined) blk: {
                const captured = self.exception_value;
                self.exception_value = .undefined;
                break :blk captured;
            } else try self.runtime.stringUtf8(@errorName(failure));
            return self.runtime.rejectPromise(task.next, reason);
        };
        if (task.mode == .finally) {
            if (task.rejected) return self.runtime.rejectPromise(task.next, task.settled_value);
            return self.runtime.resolvePromise(task.next, task.settled_value);
        }
        return self.runtime.resolvePromise(task.next, result);
    }

    fn countEvent(self: *Interpreter) !void {
        if (self.event_count >= self.max_event_count) return error.EventLoopLimitExceeded;
        self.event_count += 1;
    }

    fn makeArray(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        var result = try self.runtime.createArray();
        var root = self.runtime.rootFrame();
        defer root.deinit();
        try root.protect(&result);
        for (instruction.operands) |operand_id| _ = try result.array.push(frame.values[operand_id]);
        return result;
    }

    fn makeDictionary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        var result = try self.runtime.createDictionary();
        var root = self.runtime.rootFrame();
        defer root.deinit();
        try root.protect(&result);
        var index: usize = 0;
        while (index + 1 < instruction.operands.len) : (index += 2) {
            const key = try self.runtime.valueToString(frame.values[instruction.operands[index]]);
            try result.dictionary.set(key.string, frame.values[instruction.operands[index + 1]]);
        }
        return result;
    }

    fn getIndexed(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        var current = self.operand(frame, instruction, 0);
        for (instruction.operands[1..]) |operand_id| current = try self.getOne(current, frame.values[operand_id]);
        return current;
    }

    fn getOne(self: *Interpreter, container: Value, key: Value) !Value {
        if (container == .array) return container.array.get(try valueIndex(self.runtime, key));
        if (container == .dictionary) {
            const text = try self.runtime.valueToString(key);
            return container.dictionary.get(text.string) orelse .undefined;
        }
        if (container == .string) {
            const unit = container.string.codeUnitAt(try valueIndex(self.runtime, key)) orelse return .undefined;
            return self.runtime.stringCodeUnits(&.{unit});
        }
        return .undefined;
    }

    fn setIndexed(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
        if (instruction.operands.len < 2) return error.InvalidAssignment;
        var container = frame.locals.get(instruction.name) orelse self.globals.get(instruction.name) orelse return error.InvalidAssignment;
        const value = self.operand(frame, instruction, 0);
        const keys = instruction.operands[1..];
        var index: usize = 0;
        while (index + 1 < keys.len) : (index += 1) container = try self.getOne(container, frame.values[keys[index]]);
        const key = frame.values[keys[keys.len - 1]];
        if (container == .array) return container.array.set(try valueIndex(self.runtime, key), value);
        if (container == .dictionary) {
            const text = try self.runtime.valueToString(key);
            return container.dictionary.set(text.string, value);
        }
        return error.InvalidAssignment;
    }

    fn increment(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
        const old = frame.locals.get(instruction.name) orelse self.globals.get(instruction.name) orelse Value{ .number = 0 };
        const updated = try operators.binary(self.runtime, .add, old, self.operand(frame, instruction, 0));
        if (frame.locals.contains(instruction.name)) {
            try frame.locals.put(self.allocator, instruction.name, updated);
        } else try self.setGlobal(instruction.name, updated);
    }

    fn makeClosure(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
        const function = self.findFunction(instruction.name) orelse return error.UnknownFunction;
        const name = try self.runtime.stringUtf8(instruction.name);
        var name_root = name;
        var root = self.runtime.rootFrame();
        defer root.deinit();
        try root.protect(&name_root);
        const count = frame.locals.count();
        const captures = try self.allocator.alloc(value_mod.Capture, count);
        defer self.allocator.free(captures);
        const capture_roots = try self.allocator.alloc(Value, count);
        defer self.allocator.free(capture_roots);
        var iterator = frame.locals.iterator();
        var index: usize = 0;
        while (iterator.next()) |entry| : (index += 1) {
            capture_roots[index] = try self.runtime.stringUtf8(entry.key_ptr.*);
            try root.protect(&capture_roots[index]);
            captures[index] = .{ .name = capture_roots[index].string, .value = entry.value_ptr.* };
        }
        return self.runtime.createIrFunction(name.string, function.parameters.len, function.id, captures);
    }

    fn iteratorBegin(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
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
            state = .{ .kind = .range, .current = start, .end = end, .step = step, .variable_name = instruction.name };
        } else {
            const source = self.operand(frame, instruction, 0);
            state = switch (source) {
                .number => |number| .{ .kind = .repeat, .count = try repeatCount(number) },
                .array => .{ .kind = .array, .source = source, .count = source.array.len() },
                .string => .{ .kind = .string, .source = source, .count = source.string.len() },
                .dictionary => .{ .kind = .dictionary, .source = source, .count = source.dictionary.len() },
                else => return error.NotIterable,
            };
        }
        try frame.iterators.put(self.allocator, id, state);
        return .{ .number = @floatFromInt(id) };
    }

    fn iteratorHasNext(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !bool {
        _ = self;
        const id = instruction.operands[0];
        const state = frame.iterators.get(id) orelse return error.InvalidIterator;
        return switch (state.kind) {
            .range => if (state.step > 0) state.current <= state.end else state.current >= state.end,
            else => state.index < state.count,
        };
    }

    fn iteratorNext(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
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
                if (frame.locals.contains(state.variable_name)) {
                    try frame.locals.put(self.allocator, state.variable_name, result);
                } else try self.setGlobal(state.variable_name, result);
            },
            .array => {
                result = state.source.array.get(state.index);
                try self.setGlobal("対象キー", .{ .number = @floatFromInt(state.index) });
                state.index += 1;
                try self.setGlobal("対象", result);
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
                try self.setGlobal("対象", result);
            },
            .dictionary => {
                result = state.source.dictionary.values()[state.index];
                try self.setGlobal("対象キー", .{ .string = state.source.dictionary.keys()[state.index] });
                state.index += 1;
                try self.setGlobal("対象", result);
            },
        }
        return result;
    }

    fn executeDynamicValue(self: *Interpreter, source_value: Value) !Value {
        if (self.dynamic_depth >= self.max_dynamic_depth) return error.DynamicExecutionLimitExceeded;
        const source_text = try self.runtime.valueToString(source_value);
        const source = try source_text.string.toUtf8Lossy(self.allocator);
        defer self.allocator.free(source);
        self.dynamic_depth += 1;
        defer self.dynamic_depth -= 1;
        var parsed = try parser.parse(self.allocator, source, "<dynamic>.nako3");
        defer parsed.deinit();
        if (!parsed.succeeded()) return error.DynamicParseFailed;
        // 公式cnako3は動的コードを常にmain名前空間としてコンパイルする。
        const module_name = "main";
        var analyzed = try semantic.analyzeModules(self.allocator, &.{.{
            .name = module_name,
            .path = "<dynamic>.nako3",
            .root = parsed.root.?,
        }});
        defer analyzed.deinit();
        if (!analyzed.succeeded()) return error.DynamicSemanticFailed;
        var hir_program = try hir.lowerSingle(self.allocator, parsed.root.?, module_name, "<dynamic>.nako3", analyzed);
        defer hir_program.deinit();
        var dynamic_program = try lower_ssa.lower(self.allocator, hir_program);
        defer dynamic_program.deinit();
        var report = try verifier.verify(self.allocator, dynamic_program);
        defer report.deinit();
        if (!report.succeeded()) return error.DynamicIrFailed;
        const saved_program = self.program;
        self.program = dynamic_program;
        defer self.program = saved_program;
        var capture: std.ArrayList(u8) = .empty;
        defer capture.deinit(self.allocator);
        try self.output_captures.append(self.allocator, &capture);
        defer _ = self.output_captures.pop();
        _ = try self.runEntries();
        try self.drainEventLoop();
        return self.runtime.stringUtf8(capture.items);
    }

    fn writeOutput(self: *Interpreter, bytes: []const u8) !void {
        try self.host.write(bytes);
        for (self.output_captures.items) |capture| try capture.appendSlice(self.allocator, bytes);
    }

    fn setGlobal(self: *Interpreter, name: []const u8, value: Value) !void {
        if (self.globals.getPtr(name)) |existing| {
            existing.* = value;
            return;
        }
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        try self.globals.put(self.allocator, owned_name, value);
        errdefer _ = self.globals.remove(owned_name);
        try self.global_names.append(self.allocator, owned_name);
    }

    fn findFunction(self: Interpreter, name: []const u8) ?*const ir.Function {
        for (self.program.functions) |*function| if (std.mem.eql(u8, function.name, name)) return function;

        // The semantic analyzer qualifies module-level declarations as
        // `module__name`, while Nadesiko callback-taking commands receive the
        // source spelling as a string (for example, `"二倍"`).  Accept an
        // unqualified spelling only when it identifies exactly one function.
        var match: ?*const ir.Function = null;
        for (self.program.functions) |*function| {
            const separator = std.mem.lastIndexOf(u8, function.name, "__") orelse continue;
            if (!std.mem.eql(u8, function.name[separator + 2 ..], name)) continue;
            if (match != null) return null;
            match = function;
        }
        return match;
    }

    fn traceRoots(context: *anyopaque, runtime: *Runtime) !void {
        const self: *Interpreter = @ptrCast(@alignCast(context));
        var globals = self.globals.valueIterator();
        while (globals.next()) |value| try runtime.traceExternal(value.*);
        try runtime.traceExternal(self.exception_value);
        var frame = self.active_frame;
        while (frame) |active| : (frame = active.parent) {
            for (active.values) |value| try runtime.traceExternal(value);
            var locals = active.locals.valueIterator();
            while (locals.next()) |value| try runtime.traceExternal(value.*);
            var iterators = active.iterators.valueIterator();
            while (iterators.next()) |iterator| try runtime.traceExternal(iterator.source);
        }
        for (self.timers.items) |timer| try runtime.traceExternal(timer.callback);
        var resolvers = self.promise_resolvers.iterator();
        while (resolvers.next()) |entry| {
            try runtime.traceExternal(.{ .function = entry.key_ptr.* });
            try runtime.traceExternal(.{ .promise = entry.value_ptr.promise });
        }
        var promise_all_handlers = self.promise_all_handlers.iterator();
        while (promise_all_handlers.next()) |entry| try runtime.traceExternal(.{ .function = entry.key_ptr.* });
        for (self.promise_all_states.items) |state| {
            try runtime.traceExternal(.{ .promise = state.promise });
            try runtime.traceExternal(.{ .array = state.results });
        }
    }
};

fn promiseResolverSentinel(_: *Runtime, _: []const Value) anyerror!Value {
    return .undefined;
}

fn promiseAllSentinel(_: *Runtime, _: []const Value) anyerror!Value {
    return .undefined;
}

fn maxValueId(function: ir.Function) usize {
    var maximum: usize = if (function.parameters.len == 0) 0 else function.parameters.len - 1;
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.result) |result| maximum = @max(maximum, result);
        }
    }
    return maximum;
}

fn valueIndex(runtime: *Runtime, value: Value) !usize {
    const number = try runtime.valueToNumber(value);
    if (!std.math.isFinite(number) or number < 0 or number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.InvalidIndex;
    return @intFromFloat(@trunc(number));
}

fn repeatCount(number: f64) !usize {
    if (std.math.isNan(number) or number <= 0) return 0;
    if (!std.math.isFinite(number) or number >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return error.IteratorCountTooLarge;
    return @intFromFloat(@trunc(number));
}

fn compileForTest(allocator: std.mem.Allocator, source: []const u8) !struct {
    parsed: parser.ParseResult,
    analyzed: semantic.Program,
    hir_program: hir.Program,
    ir_program: ir.Program,
} {
    const parsed = try parser.parse(allocator, source, "main.nako3");
    const analyzed = try semantic.analyze(allocator, parsed.root.?, "main.nako3");
    const hir_program = try hir.lowerSingle(allocator, parsed.root.?, "main", "main.nako3", analyzed);
    const ir_program = try lower_ssa.lower(allocator, hir_program);
    return .{ .parsed = parsed, .analyzed = analyzed, .hir_program = hir_program, .ir_program = ir_program };
}

test "SSA IRで条件・反復・関数・配列辞書を実行する" {
    const source = "●(AとBを)足すとは\nA+Bで戻る\nここまで\n合計=0\nNを1から3まで繰り返す\n合計=合計+N\nここまで\nもし合計=6ならば\n足す(合計,4)を表示\n違えば\n0を表示\nここまで\nA=[1,2]\nA[1]=5\nA[1]を表示\nB={\"x\":7}\nB@\"x\"を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("10\n5\n7\n", host.written());
}

test "連続表示は公式処理系と同じく改行する" {
    var fixture = try compileForTest(std.testing.allocator, "\"100%安全%s\"を連続表示\n\"次\"を表示\n");
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("100%安全%s\n次\n", host.written());
}

test "例外監視と動的ななでしこ実行を処理する" {
    const source = "エラー監視\n\"失敗\"のエラー発生\nエラーならば\nエラーメッセージを表示\nここまで\n\"1+2を表示する。\"をナデシコする。\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("失敗\n3\n", host.written());
}

test "テスト定義を個別に実行して結果を記録する" {
    var fixture = try compileForTest(std.testing.allocator, "●テスト:成功とは\n1と1がASSERT等\nここまで\n●テスト:失敗とは\n0と1がASSERT等\nここまで\n");
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    const results = try interpreter.runTests();
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expect(results[0].passed);
    try std.testing.expect(!results[1].passed);
}

test "抜ける・続ける・反復・条件分岐を実行する" {
    const source = "S=0\nIを1から5まで繰り返す\nもしI=2ならば、続ける\nもしI=4ならば、抜ける\nS=S+I\nここまで\nSを表示\n[3,4]を反復\n対象を表示\nここまで\n2で条件分岐\n1ならば\n\"a\"を表示\nここまで\n2ならば\n\"b\"を表示\nここまで\n違えば\n\"c\"を表示\nここまで\nここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("4\n3\n4\nb\n", host.written());
}

test "無名関数がローカル変数を捕捉する" {
    const source = "●(Aを)加算器作成とは\nF=関数(B)それはA+B\nここまで\nFで戻る\nここまで\nG=加算器作成(10)\nG(5)を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("15\n", host.written());
}

test "Promiseの成功・失敗・処理・終了コールバックを順に実行する" {
    const source =
        "動いた時には(成功,失敗)\n" ++
        "成功(9)\n" ++
        "ここまで\n" ++
        "Pはそれ\n" ++
        "Pの成功した時には\n" ++
        "対象を表示\n" ++
        "ここまで\n" ++
        "動いた時には(成功,失敗)\n" ++
        "失敗(5)\n" ++
        "ここまで\n" ++
        "Qはそれ\n" ++
        "Qの処理した時には(OK,値)\n" ++
        "OKを表示\n" ++
        "値を表示\n" ++
        "ここまで\n" ++
        "その終了した時には\n" ++
        "\"完了\"を表示\n" ++
        "ここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("9\nfalse\n5\n完了\n", host.written());
}

test "GCストレス中もタイマーからPromiseを解決する" {
    const source =
        "動いた時には(成功,失敗)\n" ++
        "0.001秒後には\n" ++
        "成功(7)\n" ++
        "ここまで\n" ++
        "ここまで\n" ++
        "Pはそ\n" ++
        "Pの成功した時には\n" ++
        "対象を表示\n" ++
        "ここまで\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("7\n", host.written());
    try std.testing.expectEqual(@as(u64, 1), host.elapsed_milliseconds);
}

test "決定的時計でタイマーの順序・停止・待機を処理する" {
    const source =
        "0.003秒後には\n" ++
        "\"三\"を表示\n" ++
        "ここまで\n" ++
        "0.001秒後には\n" ++
        "\"一\"を表示\n" ++
        "ここまで\n" ++
        "0.002秒後には\n" ++
        "\"停止失敗\"を表示\n" ++
        "ここまで\n" ++
        "対象のタイマー停止\n" ++
        "0.004秒毎には(TID)\n" ++
        "\"毎\"を表示\n" ++
        "TIDのタイマー停止\n" ++
        "ここまで\n" ++
        "0.005秒待つ\n" ++
        "\"待\"を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("一\n三\n毎\n待\n", host.written());
    try std.testing.expectEqual(@as(u64, 5), host.elapsed_milliseconds);
}

test "GCストレス中も実行フレームと反復対象をルートとして保持する" {
    const source = "A=[\"保持\",\"対象\"]\nAを反復\n対象を表示\nここまで\nB={\"key\":\"value\"}\nB@\"key\"を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("保持\n対象\nvalue\n", host.written());
}

test "継続表示プール・表示ログ・改行なし出力を公式規則で処理する" {
    const source =
        "\"A\"を継続表示\n" ++
        "\"B\"を継続表示\n" ++
        "\"C\"を表示\n" ++
        "表示ログを表示\n" ++
        "表示ログクリア\n" ++
        "\"X\"を言\n" ++
        "\"Y\"をコンソール表示\n" ++
        "連続表示(\"1\",2,3)\n" ++
        "連続無改行表示(\"a\",\"b\")\n" ++
        "\"c\"を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("ABC\nABC\n\nX\nY\n123\nabc\n", host.written());
    const log = interpreter.getGlobal("表示ログ").?;
    const log_utf8 = try log.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(log_utf8);
    try std.testing.expectEqualStrings("123\nabc\n", log_utf8);
}

test "配列コールバックと固定日時・乱数ホストを実行する" {
    const source =
        "●(Aを)二倍とは\nA*2で戻る\nここまで\n" ++
        "●(Aを)偶数判定関数とは\n偶数(A)で戻る\nここまで\n" ++
        "●(AとBを)降順とは\nB-Aで戻る\nここまで\n" ++
        "JSON変換(配列マップ(\"二倍\",[1,2,3]))を表示\n" ++
        "JSON変換(配列フィルタ(\"偶数判定関数\",[1,2,3,4]))を表示\n" ++
        "JSON変換(配列カスタムソート(\"降順\",[1,3,2]))を表示\n" ++
        "今日()を表示\n" ++
        "時間ミリ秒取得()を表示\n" ++
        "JSON変換(配列シャッフル([1,2,3,4]))を表示\n";
    var fixture = try compileForTest(std.testing.allocator, source);
    defer fixture.ir_program.deinit();
    defer fixture.hir_program.deinit();
    defer fixture.analyzed.deinit();
    defer fixture.parsed.deinit();
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var host = BufferHost{ .allocator = std.testing.allocator };
    defer host.deinit();
    var interpreter = Interpreter.init(std.testing.allocator, &runtime, fixture.ir_program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try std.testing.expectEqualStrings("[2,4,6]\n[2,4]\n[3,2,1]\n2025/01/01\n0\n[2,3,1,4]\n", host.written());
}
