const std = @import("std");
const ir = @import("../ir/nako_ir.zig");
const parser = @import("../frontend/parser.zig");
const semantic = @import("../semantic/analyzer.zig");
const hir = @import("../ir/hir.zig");
const lower_ssa = @import("../ir/lower_ssa.zig");
const verifier = @import("../ir/verifier.zig");
const value_mod = @import("value.zig");
const operators = @import("operators.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const Host = struct {
    context: *anyopaque,
    writeFn: *const fn (context: *anyopaque, bytes: []const u8) anyerror!void,

    pub fn write(self: Host, bytes: []const u8) !void {
        try self.writeFn(self.context, bytes);
    }
};

pub const BufferHost = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *BufferHost) void {
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn host(self: *BufferHost) Host {
        return .{ .context = self, .writeFn = write };
    }

    pub fn written(self: BufferHost) []const u8 {
        return self.output.items;
    }

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *BufferHost = @ptrCast(@alignCast(context));
        try self.output.appendSlice(self.allocator, bytes);
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

    pub fn init(allocator: std.mem.Allocator, runtime: *Runtime, program: ir.Program, host: Host) Interpreter {
        return .{ .allocator = allocator, .runtime = runtime, .program = program, .host = host };
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
        self.* = undefined;
    }

    pub fn run(self: *Interpreter) !Value {
        try self.runtime.registerRootProvider(.{ .context = self, .traceFn = traceRoots });
        defer self.runtime.unregisterRootProvider(self);
        return self.runEntries();
    }

    pub fn runTests(self: *Interpreter) ![]const TestResult {
        try self.runtime.registerRootProvider(.{ .context = self, .traceFn = traceRoots });
        defer self.runtime.unregisterRootProvider(self);
        for (self.program.functions) |*function| {
            if (!function.is_test) continue;
            const result = self.executeFunction(function, &.{}, null);
            if (result) |_| {
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
        return switch (function.kind) {
            .native => self.runtime.call(.{ .function = function }, arguments),
            .ir => |function_id| self.executeFunction(&self.program.functions[function_id], arguments, function),
        };
    }

    fn callBuiltin(self: *Interpreter, name: []const u8, arguments: []const Value) !Value {
        if (std.mem.eql(u8, name, "表示") or std.mem.eql(u8, name, "表示する")) {
            const value = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
            const text = try self.runtime.valueToString(value);
            const utf8 = try text.string.toUtf8Lossy(self.allocator);
            defer self.allocator.free(utf8);
            try self.writeOutput(utf8);
            try self.writeOutput("\n");
            return value;
        }
        if (std.mem.eql(u8, name, "連続表示")) {
            const value = if (arguments.len > 0) arguments[arguments.len - 1] else Value.undefined;
            const text = try self.runtime.valueToString(value);
            const utf8 = try text.string.toUtf8Lossy(self.allocator);
            defer self.allocator.free(utf8);
            try self.writeOutput(utf8);
            return value;
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
        return error.UnknownCommand;
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
        return null;
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
    }
};

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
