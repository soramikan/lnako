const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../../ir/nako_ir.zig");
const ast = @import("../../frontend/ast.zig");
const parser = @import("../../frontend/parser.zig");
const lexer = @import("../../frontend/lexer.zig");
const josi = @import("../../frontend/josi.zig");
const semantic = @import("../../semantic/analyzer.zig");
const builtin_catalog = @import("../../semantic/builtin_catalog.zig");
const hir = @import("../../ir/hir.zig");
const lower_ssa = @import("../../ir/lower_ssa.zig");
const verifier = @import("../../ir/verifier.zig");
const error_message = @import("../error_message.zig");
const value_mod = @import("../value.zig");
const operators = @import("../operators.zig");
const plugin_system = @import("../../plugins/system.zig");
const plugin_math = @import("../../plugins/math.zig");
const plugin_csv = @import("../../plugins/csv.zig");
const plugin_toml = @import("../../plugins/toml.zig");
const plugin_node = @import("../../plugins/node.zig");
const plugin_encoding = @import("../../plugins/encoding.zig");
const plugin_http_server = @import("../../plugins/http_server.zig");
const plugin_markup = @import("../../plugins/markup.zig");
const plugin_caniuse = @import("../../plugins/caniuse.zig");
const plugin_kansuji = @import("../../plugins/kansuji.zig");
const plugin_native = @import("../../plugins/native.zig");
const quickjs = @import("../../compat/quickjs.zig");
const environment = @import("../environment.zig");
const istate = @import("state.zig");
const shared = @import("shared.zig");
const prepared = @import("prepared.zig");

const Interpreter = istate.Interpreter;
const TestResult = shared.TestResult;
const Value = shared.Value;
const Runtime = shared.Runtime;
const DynamicPreparationFn = istate.DynamicPreparationFn;
const Frame = shared.Frame;
const IteratorKind = shared.IteratorKind;
const IteratorState = shared.IteratorState;
const Timer = shared.Timer;
const PromiseResolver = shared.PromiseResolver;
const PromiseAllState = shared.PromiseAllState;
const PromiseAllHandler = shared.PromiseAllHandler;
const PromiseChainKind = shared.PromiseChainKind;
const NamespaceFrame = shared.NamespaceFrame;
const HatenaCallback = shared.HatenaCallback;
const DispatchTraceWriteFn = shared.DispatchTraceWriteFn;
const DispatchTrace = shared.DispatchTrace;
const CompatJsTrace = shared.CompatJsTrace;
const GlobalTrace = shared.GlobalTrace;
const LiteralTrace = shared.LiteralTrace;
const default_plugin_names = shared.default_plugin_names;
const traceBuiltinName = shared.traceBuiltinName;
const compatJsOperation = shared.compatJsOperation;
const interpreterArrayIndex = shared.interpreterArrayIndex;
const repeatCount = shared.repeatCount;
const valueIndex = shared.valueIndex;
const getArrayProperty = shared.getArrayProperty;
const isPrototypeObject = shared.isPrototypeObject;
const interpreterByteBufferReadOnlyProperty = shared.interpreterByteBufferReadOnlyProperty;
const ownProperty = shared.ownProperty;
const setOwnProperty = shared.setOwnProperty;
const objectPrimitiveMethod = shared.objectPrimitiveMethod;
const preservesResultVariable = shared.preservesResultVariable;
const promiseResolverSentinel = shared.promiseResolverSentinel;
const promiseAllSentinel = shared.promiseAllSentinel;
const localValue = shared.localValue;
const localCell = shared.localCell;
const localSlotCell = shared.localSlotCell;
const localSlotValue = shared.localSlotValue;
const localSlotKnown = shared.localSlotKnown;
const traceRoots = istate.traceRoots;

fn interruptSafepoint(self: *Interpreter) !void {
    self.interrupt_safepoint_count += 1;
    self.interrupt_budget_remaining = self.interrupt_budget_limit;
    try self.handleNodeInterrupt();
}

fn interruptBudgetTick(self: *Interpreter) !bool {
    if (self.interrupt_budget_remaining <= 1) {
        try interruptSafepoint(self);
        return true;
    }
    self.interrupt_budget_remaining -= 1;
    return false;
}

pub fn run(self: *Interpreter) !Value {
    self.ensurePrimitiveHook();
    try self.runtime.registerRootProvider(.{ .context = self, .traceFn = traceRoots });
    defer self.runtime.unregisterRootProvider(self);
    try self.initializeSystem();
    const result = try self.runEntries();
    try self.drainEventLoop();
    return result;
}

pub fn runTests(self: *Interpreter) ![]const TestResult {
    self.ensurePrimitiveHook();
    try self.runtime.registerRootProvider(.{ .context = self, .traceFn = traceRoots });
    defer self.runtime.unregisterRootProvider(self);
    try self.initializeSystem();
    for (self.program.functions) |*function| {
        if (!function.is_test) continue;
        // A test is an independent execution boundary.  A previous test (or
        // an event callback drained by it) may have left a pending exception
        // value or a diagnostic in the runtime; neither belongs to this test.
        self.exception_value = .undefined;
        self.runtime.clearFailureMessage();
        defer {
            self.exception_value = .undefined;
            self.runtime.clearFailureMessage();
        }
        const result = self.executeFunction(function, &.{}, null, self.currentProgramOwner());
        if (result) |_| {
            try self.drainEventLoop();
            try self.test_results.append(self.allocator, .{ .name = try self.allocator.dupe(u8, function.name), .passed = true });
        } else |failure| {
            const message = self.runtime.failureMessage() orelse @errorName(failure);
            try self.test_results.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, function.name),
                .passed = false,
                .message = try self.allocator.dupe(u8, message),
            });
            self.runtime.clearFailureMessage();
        }
    }
    return self.test_results.items;
}

pub fn runDynamicSource(
    self: *Interpreter,
    source: []const u8,
    prepare: ?DynamicPreparationFn,
    context: ?*anyopaque,
) !Value {
    self.ensurePrimitiveHook();
    try self.runtime.registerRootProvider(.{ .context = self, .traceFn = traceRoots });
    defer self.runtime.unregisterRootProvider(self);
    try self.initializeSystem();
    if (prepare) |hook| try hook(context orelse return error.MissingDynamicPreparationContext, self);
    return self.executeDynamicValue(try self.runtime.stringUtf8(source));
}

pub fn objectToPrimitive(self: *Interpreter, value: Value, hint: value_mod.PrimitiveHint) anyerror!?Value {
    switch (value) {
        .bytes, .array, .dictionary, .function, .promise => {},
        else => return null,
    }

    var rooted_value = value;
    var roots = self.runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&rooted_value);
    const array_standard_blocked = switch (rooted_value) {
        .array => |array| value_mod.arrayPrototypeBlocksStandard(array),
        else => false,
    };

    const to_string_name: []const u16 = &.{ 't', 'o', 'S', 't', 'r', 'i', 'n', 'g' };
    const value_of_name: []const u16 = &.{ 'v', 'a', 'l', 'u', 'e', 'O', 'f' };
    const first = if (hint == .string) to_string_name else value_of_name;
    const second = if (hint == .string) value_of_name else to_string_name;
    var custom_method_seen = false;

    for ([_][]const u16{ first, second }) |name| {
        if (objectPrimitiveMethod(rooted_value, name)) |method| {
            custom_method_seen = true;
            if (method == .undefined or method == .null_value) continue;
            if (method != .function) return error.NotCallable;
            var rooted_method = method;
            try roots.protect(&rooted_method);
            var result = try self.callFunctionValue(rooted_method.function, &.{});
            try roots.protect(&result);
            if (!value_mod.isObjectValue(result)) return result;
            continue;
        }

        // A missing toString method represents the standard
        // Object.prototype.toString. A missing valueOf method represents
        // the standard object-returning Object.prototype.valueOf.
        if (std.mem.eql(u16, name, to_string_name) and !array_standard_blocked) {
            return @as(?Value, try self.runtime.valueToStringDefault(rooted_value));
        }
    }
    if (custom_method_seen) return error.CannotConvertObjectToPrimitive;
    return null;
}

pub fn runEntries(self: *Interpreter) !Value {
    var result: Value = .undefined;
    var index = self.program.module_entries.len;
    while (index > 0) {
        index -= 1;
        result = try self.executeFunction(&self.program.functions[self.program.module_entries[index]], &.{}, null, self.currentProgramOwner());
    }
    return result;
}

pub fn executeFunction(self: *Interpreter, function: *const ir.Function, arguments: []const Value, closure: ?*value_mod.Function, owner_program: *const ir.Program) anyerror!Value {
    if (self.call_depth >= self.max_call_depth) return error.CallStackLimitExceeded;
    self.call_depth += 1;
    defer self.call_depth -= 1;
    const prepared_program = try self.prepareProgram(owner_program);
    const prepared_function = prepared_program.functionAt(function) orelse return error.InvalidFunction;
    const value_count = prepared_function.value_count;
    const values = try self.acquireValueBuffer(value_count);
    var frame = Frame{ .parent = self.active_frame, .function = function, .owner_program = owner_program, .values = values[0..value_count], .values_buffer = values, .prepared_function = prepared_function };
    defer {
        const buffer = frame.values_buffer;
        frame.values_buffer = null;
        frame.values = &.{};
        frame.deinit(self.allocator);
        if (buffer) |allocation| self.releaseValueBuffer(allocation);
    }
    try frame.initLocalValues(self.allocator, prepared_function.local_count);
    try frame.initLocalCells(self.allocator, prepared_function.local_count);
    self.active_frame = &frame;
    defer self.active_frame = frame.parent;
    const previous_source_path = self.current_source_path;
    self.current_source_path = self.sourcePathForFunction(owner_program, function.name);
    defer self.current_source_path = previous_source_path;

    if (closure) |function_value| for (function_value.captures) |capture| {
        const name = try capture.name.toUtf8Lossy(self.allocator);
        try frame.owned_names.append(self.allocator, name);
        const cell = capture.cell orelse try self.runtime.createBindingCell(capture.value);
        try self.attachLocal(&frame, name, cell);
    };
    for (function.parameters, 0..) |parameter, index| {
        const argument = if (index < arguments.len) arguments[index] else Value.undefined;
        frame.values[parameter.value] = argument;
        try self.bindLocal(&frame, parameter.name, argument);
    }

    var current_block = function.entry;
    var predecessor: ?ir.BlockId = null;
    execution: while (true) {
        if (current_block >= function.blocks.len) return error.InvalidBranchTarget;
        try interruptSafepoint(self);
        const block = function.blocks[current_block];
        const prepared_block = prepared_function.blocks[current_block];
        var exceptional_target: ?ir.BlockId = null;
        for (prepared_block.instructions) |*prepared_instruction| {
            const budget_polled = try interruptBudgetTick(self);
            if (prepared_instruction.interrupt_safepoint and !budget_polled) try interruptSafepoint(self);
            self.executePreparedInstruction(&frame, prepared_instruction, predecessor) catch |failure| {
                if (frame.handlers.pop()) |handler| {
                    if (self.exception_value == .undefined) {
                        if (self.runtime.failureMessageValue() catch return failure) |message| {
                            self.exception_value = message;
                        } else {
                            self.exception_value = self.runtime.stringUtf8(error_message.forFailure(failure)) catch return failure;
                        }
                    }
                    self.runtime.clearFailureMessage();
                    try self.setGlobal("エラーメッセージ", self.exception_value);
                    self.exception_value = .undefined;
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
            .return_value => |value| return if (value) |id| frame.values[id] else .undefined,
            .throw_value => |throw_value| {
                self.dispatch_trace.emit(traceBuiltinName("エラー発生"), "throw", "failure", throw_value.site_id);
                const thrown = frame.values[throw_value.value];
                self.exception_value = if (throw_value.coerce_to_error_message) try self.errorMessageValue(thrown) else thrown;
                if (frame.handlers.pop() orelse throw_value.target) |handler| {
                    try self.setGlobal("エラーメッセージ", self.exception_value);
                    self.exception_value = .undefined;
                    predecessor = current_block;
                    current_block = handler;
                } else return error.NakoException;
            },
            .propagate_exception => return error.NakoException,
            .unreachable_terminator => return error.ReachedUnreachable,
        }
    }
}

pub fn errorMessageValue(self: *Interpreter, value: Value) !Value {
    // JavaScript's Error(undefined).message is the empty string.  All
    // other values use their ordinary String(value) representation.
    if (value == .undefined) return self.runtime.stringUtf8("");
    return self.runtime.valueToString(value);
}

pub fn executeInstruction(self: *Interpreter, frame: *Frame, instruction: ir.Instruction, predecessor: ?ir.BlockId) anyerror!void {
    return executeInstructionResolved(self, frame, &instruction, null, predecessor);
}

pub fn executePreparedInstruction(self: *Interpreter, frame: *Frame, prepared_instruction: *const prepared.PreparedInstruction, predecessor: ?ir.BlockId) anyerror!void {
    return executeInstructionResolved(self, frame, prepared_instruction.ir_instruction, prepared_instruction, predecessor);
}

fn executeInstructionResolved(
    self: *Interpreter,
    frame: *Frame,
    instruction_ptr: *const ir.Instruction,
    prepared_instruction: ?*const prepared.PreparedInstruction,
    predecessor: ?ir.BlockId,
) anyerror!void {
    const instruction = instruction_ptr.*;
    const previous_span = self.current_span;
    self.current_span = instruction.span;
    defer self.current_span = previous_span;
    var result: ?Value = null;
    switch (instruction.opcode) {
        .const_number => result = .{ .number = instruction.number_value orelse 0 },
        .const_bigint => result = try self.runtime.bigIntLiteral(instruction.text),
        .const_boolean => {
            result = .{ .boolean = instruction.boolean_value };
            if (instruction.literal_site_id) |site_id| {
                self.literal_trace.emit(instruction.text, if (frame.owner_program == &self.root_program) site_id else null);
            }
        },
        .const_null => {
            result = .null_value;
            if (instruction.literal_site_id) |site_id| {
                self.literal_trace.emit(instruction.text, if (frame.owner_program == &self.root_program) site_id else null);
            }
        },
        .const_string => result = try self.runtime.stringUtf8(instruction.text),
        .const_undefined => result = .undefined,
        .load_global => {
            const slot = if (prepared_instruction) |prepared_entry| prepared_entry.global_slot else prepared.no_global_slot;
            result = if (slot != prepared.no_global_slot) self.globalSlotValue(slot) orelse .undefined else self.globals.get(instruction.name) orelse .undefined;
            const found = if (slot != prepared.no_global_slot) self.globalSlotValue(slot) != null else self.globals.contains(instruction.name);
            if (instruction.global_site_id != null) {
                const site_id = if (frame.owner_program == &self.root_program) instruction.global_site_id else null;
                self.global_trace.emit(traceBuiltinName(instruction.name), found, site_id);
            }
        },
        .load_local => {
            if (prepared_instruction) |prepared_entry| {
                if (localSlotValue(frame, prepared_entry.local_slot)) |value| result = value;
                if (result == null) {
                    if (localSlotCell(frame, prepared_entry.local_slot)) |cell| result = cell.value;
                }
                if (result == null) result = localValue(frame, instruction.name);
                if (result == null) result = if (prepared_entry.global_slot != prepared.no_global_slot) self.globalSlotValue(prepared_entry.global_slot) else self.globals.get(instruction.name);
            } else result = localValue(frame, instruction.name) orelse self.globals.get(instruction.name);
            if (result == null) result = .undefined;
        },
        .store_global => {
            const value = self.operand(frame, instruction, 0);
            if (prepared_instruction) |prepared_entry| if (prepared_entry.global_slot != prepared.no_global_slot)
                try self.setGlobalSlot(prepared_entry.global_slot, instruction.name, value)
            else
                try self.setGlobal(instruction.name, value) else try self.setGlobal(instruction.name, value);
            if (instruction.global_site_id != null) {
                const site_id = if (frame.owner_program == &self.root_program) instruction.global_site_id else null;
                self.global_trace.emitWrite(traceBuiltinName(instruction.name), site_id);
            }
        },
        .store_local => if (prepared_instruction) |prepared_entry|
            try self.storeLocalSlot(frame, prepared_entry.local_slot, instruction.name, self.operand(frame, instruction, 0))
        else
            try self.storeLocal(frame, instruction.name, self.operand(frame, instruction, 0)),
        .destructure_store => if (prepared_instruction) |prepared_entry|
            try executeDestructureResolved(self, frame, instruction, prepared_entry)
        else
            try self.executeDestructure(frame, instruction),
        .binary => result = if (prepared_instruction) |prepared_entry|
            try executeBinaryResolved(self, frame, instruction, prepared_entry.binary_operator)
        else
            try self.executeBinary(frame, instruction),
        .unary => result = if (prepared_instruction) |prepared_entry|
            try executeUnaryResolved(self, frame, instruction, prepared_entry.unary_operator)
        else
            try self.executeUnary(frame, instruction),
        .call => result = if (prepared_instruction) |prepared_entry|
            try executeCallResolved(self, frame, instruction, prepared_entry.call_target, prepared_entry.global_slot, prepared_entry.omit_result_store)
        else
            try self.executeCall(frame, instruction),
        .call_value => result = try self.executeCallValue(frame, instruction),
        .make_array => result = try self.makeArray(frame, instruction),
        .make_object => result = try self.makeDictionary(frame, instruction),
        .array_get, .property_get => result = try self.getIndexed(frame, instruction),
        .array_set, .property_set => if (prepared_instruction) |prepared_entry|
            try setIndexedResolved(self, frame, instruction, prepared_entry.local_slot, prepared_entry.global_slot)
        else
            try self.setIndexed(frame, instruction),
        .increment => if (prepared_instruction) |prepared_entry|
            try incrementResolved(self, frame, instruction, prepared_entry.local_slot, prepared_entry.global_slot)
        else
            try self.increment(frame, instruction),
        .make_closure => result = if (prepared_instruction) |prepared_entry|
            try makeClosureResolved(self, frame, instruction, prepared_entry.closure_target)
        else
            try self.makeClosure(frame, instruction),
        .iterator_begin => result = try self.iteratorBegin(frame, instruction),
        .iterator_has_next => result = .{ .boolean = try self.iteratorHasNext(frame, instruction) },
        .iterator_next => result = try self.iteratorNext(frame, instruction),
        .try_begin => try frame.handlers.append(self.allocator, instruction.exception_target orelse return error.MissingExceptionTarget),
        .try_end => _ = frame.handlers.pop(),
        .exception_pending => result = .{ .boolean = false },
        .exception_take => {},
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

pub fn operand(self: Interpreter, frame: *Frame, instruction: ir.Instruction, index: usize) Value {
    _ = self;
    return frame.values[instruction.operands[index]];
}

pub fn bindLocal(self: *Interpreter, frame: *Frame, name: []const u8, value: Value) !void {
    if (frame.prepared_function) |prepared_function| if (prepared_function.localSlot(name)) |slot| {
        if (prepared_function.storageClass(slot)) |storage| if (storage == .value) {
            return self.storeLocalSlot(frame, slot, name, value);
        };
    };
    const cell = try self.runtime.createBindingCell(value);
    try self.attachLocal(frame, name, cell);
}

pub fn attachLocal(self: *Interpreter, frame: *Frame, name: []const u8, cell: *value_mod.BindingCell) !void {
    try frame.locals.put(self.allocator, name, cell);
    if (frame.prepared_function) |prepared_function| if (prepared_function.localSlot(name)) |slot| {
        if (prepared_function.storageClass(slot)) |storage| {
            if (storage == .value) {
                if (slot < frame.local_values.len) {
                    frame.local_values[slot] = cell.value;
                    frame.local_values_initialized[slot] = true;
                }
            } else if (slot < frame.local_cells.len) frame.local_cells[slot] = cell;
        }
    };
}

pub fn storeLocal(self: *Interpreter, frame: *Frame, name: []const u8, value: Value) !void {
    if (frame.prepared_function) |prepared_function| if (prepared_function.localSlot(name)) |slot| {
        return self.storeLocalSlot(frame, slot, name, value);
    };
    if (frame.locals.get(name)) |cell| {
        cell.value = value;
        return;
    }
    try self.bindLocal(frame, name, value);
}

pub fn storeLocalSlot(self: *Interpreter, frame: *Frame, slot: prepared.LocalSlot, name: []const u8, value: Value) !void {
    if (frame.prepared_function) |prepared_function| if (prepared_function.storageClass(slot)) |storage| switch (storage) {
        .value => {
            if (slot >= frame.local_values.len) return error.InvalidLocalSlot;
            frame.local_values[slot] = value;
            frame.local_values_initialized[slot] = true;
            return;
        },
        .cell => {},
    };
    if (localSlotCell(frame, slot)) |cell| {
        cell.value = value;
        return;
    }
    const cell = try self.runtime.createBindingCell(value);
    try frame.locals.put(self.allocator, name, cell);
    if (slot != prepared.no_local_slot and slot < frame.local_cells.len) frame.local_cells[slot] = cell;
}

pub fn executeDestructure(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
    return executeDestructureResolved(self, frame, instruction, null);
}

fn executeDestructureResolved(
    self: *Interpreter,
    frame: *Frame,
    instruction: ir.Instruction,
    prepared_instruction: ?*const prepared.PreparedInstruction,
) !void {
    const source = self.operand(frame, instruction, 0);
    for (instruction.names, 0..) |name, index| {
        const value = if (source == .array) source.array.get(index) else if (index == 0) source else .undefined;
        const local_slot = if (prepared_instruction) |entry| entry.destructure_local_slots[index] else prepared.no_local_slot;
        const global_slot = if (prepared_instruction) |entry| entry.destructure_global_slots[index] else prepared.no_global_slot;
        if (global_slot != prepared.no_global_slot) {
            try self.setGlobalSlot(global_slot, name, value);
        } else if (local_slot != prepared.no_local_slot) {
            try self.storeLocalSlot(frame, local_slot, name, value);
        } else if (std.mem.indexOf(u8, name, "__") != null) {
            try self.setGlobal(name, value);
        } else try self.storeLocal(frame, name, value);
    }
}

const BinaryOperator = enum {
    add,
    subtract,
    multiply,
    divide,
    integer_divide,
    remainder,
    power,
    concat,
    bit_or,
    bit_xor,
    shift_left,
    shift_right,
    shift_right_unsigned,
    logical_and,
    logical_or,
    abstract_equal,
    strict_equal,
    abstract_not_equal,
    strict_not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
};

/// Operator spellings resolve once per instruction through this map instead
/// of the previous chain of sequential `std.mem.eql` comparisons.
const binary_operators = std.StaticStringMap(BinaryOperator).initComptime(.{
    .{ "+", .add },
    .{ "-", .subtract },
    .{ "*", .multiply },
    .{ "/", .divide },
    .{ "÷", .divide },
    .{ "÷÷", .integer_divide },
    .{ "%", .remainder },
    .{ "**", .power },
    .{ "&", .concat },
    .{ "|", .bit_or },
    .{ "^", .bit_xor },
    .{ "shift_l", .shift_left },
    .{ "shift_r", .shift_right },
    .{ "shift_r0", .shift_right_unsigned },
    .{ "&&", .logical_and },
    .{ "and", .logical_and },
    .{ "||", .logical_or },
    .{ "or", .logical_or },
    .{ "==", .abstract_equal },
    .{ "=", .abstract_equal },
    .{ "eq", .abstract_equal },
    .{ "===", .strict_equal },
    .{ "!=", .abstract_not_equal },
    .{ "≠", .abstract_not_equal },
    .{ "noteq", .abstract_not_equal },
    .{ "!==", .strict_not_equal },
    .{ "<", .less },
    .{ "lt", .less },
    .{ "<=", .less_equal },
    .{ "lteq", .less_equal },
    .{ ">", .greater },
    .{ "gt", .greater },
    .{ ">=", .greater_equal },
    .{ "gteq", .greater_equal },
});

const UnaryOperator = enum { logical_not, minus, plus, bit_not };

const unary_operators = std.StaticStringMap(UnaryOperator).initComptime(.{
    .{ "!", .logical_not },
    .{ "not", .logical_not },
    .{ "-", .minus },
    .{ "+", .plus },
    .{ "~", .bit_not },
});

pub fn executeBinary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    const operator = binary_operators.get(instruction.operator) orelse return error.UnsupportedBinaryOperator;
    return executeBinaryWithOperator(self, frame, instruction, operator);
}

fn executeBinaryResolved(self: *Interpreter, frame: *Frame, instruction: ir.Instruction, operator: ?prepared.BinaryOperator) !Value {
    const resolved = operator orelse return error.UnsupportedBinaryOperator;
    // The prepared enum intentionally mirrors the legacy private enum.  Keep
    // the conversion in this adapter so the public unprepared entry point
    // and all existing tests continue to share one implementation.
    return executeBinaryWithOperator(self, frame, instruction, @enumFromInt(@intFromEnum(resolved)));
}

fn executeBinaryWithOperator(self: *Interpreter, frame: *Frame, instruction: ir.Instruction, operator: BinaryOperator) !Value {
    const left = self.operand(frame, instruction, 0);
    const right = self.operand(frame, instruction, 1);
    switch (operator) {
        .add => return operators.nadesikoAdd(self.runtime, left, right),
        .subtract => return operators.binary(self.runtime, .subtract, left, right),
        .multiply => return operators.binary(self.runtime, .multiply, left, right),
        .divide => return operators.binary(self.runtime, .divide, left, right),
        .integer_divide => {
            const quotient = try operators.binary(self.runtime, .divide, left, right);
            if (quotient == .number) return .{ .number = @floor(quotient.number) };
            return error.CannotConvertBigIntToNumber;
        },
        .remainder => return operators.binary(self.runtime, .remainder, left, right),
        .power => return operators.binary(self.runtime, .power, left, right),
        .concat => {
            const left_string = (try self.runtime.valueToString(left)).string;
            const right_string = (try self.runtime.valueToString(right)).string;
            return self.runtime.concatStrings(left_string, right_string);
        },
        .bit_or => return operators.binary(self.runtime, .bit_or, left, right),
        .bit_xor => return operators.binary(self.runtime, .bit_xor, left, right),
        .shift_left => return operators.binary(self.runtime, .shift_left, left, right),
        .shift_right => return operators.binary(self.runtime, .shift_right, left, right),
        .shift_right_unsigned => return operators.binary(self.runtime, .shift_right_unsigned, left, right),
        .logical_and => return if (left.toBoolean()) right else left,
        .logical_or => return if (left.toBoolean()) left else right,
        .abstract_equal => return .{ .boolean = try self.runtime.abstractEqual(left, right) },
        .strict_equal => return .{ .boolean = Value.strictEqual(left, right) },
        .abstract_not_equal => return .{ .boolean = !(try self.runtime.abstractEqual(left, right)) },
        .strict_not_equal => return .{ .boolean = !Value.strictEqual(left, right) },
        .less, .less_equal, .greater, .greater_equal => {
            const order = try operators.compare(self.runtime, left, right);
            return .{ .boolean = switch (operator) {
                .less => order != null and order.? == .lt,
                .less_equal => order != null and order.? != .gt,
                .greater => order != null and order.? == .gt,
                else => order != null and order.? != .lt,
            } };
        },
    }
}

pub fn executeUnary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    const value = self.operand(frame, instruction, 0);
    return switch (unary_operators.get(instruction.operator) orelse return error.UnsupportedUnaryOperator) {
        .logical_not => .{ .boolean = !value.toBoolean() },
        .minus => try operators.unaryMinus(self.runtime, value),
        .plus => try operators.unaryPlus(self.runtime, value),
        .bit_not => try operators.bitNot(self.runtime, value),
    };
}

fn executeUnaryResolved(self: *Interpreter, frame: *Frame, instruction: ir.Instruction, operator: ?prepared.UnaryOperator) !Value {
    const value = self.operand(frame, instruction, 0);
    const resolved = operator orelse return error.UnsupportedUnaryOperator;
    return switch (resolved) {
        .logical_not => .{ .boolean = !value.toBoolean() },
        .minus => try operators.unaryMinus(self.runtime, value),
        .plus => try operators.unaryPlus(self.runtime, value),
        .bit_not => try operators.bitNot(self.runtime, value),
    };
}

/// Calls with up to this many arguments build their argument list on the
/// stack; longer calls fall back to a heap allocation.
const stack_argument_capacity = 8;

pub fn executeCall(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    return executeCallResolved(self, frame, instruction, null, prepared.no_global_slot, false);
}

fn executeCallResolved(
    self: *Interpreter,
    frame: *Frame,
    instruction: ir.Instruction,
    prepared_target: ?prepared.CallTarget,
    prepared_global_slot: prepared.GlobalSlot,
    omit_result_store: bool,
) !Value {
    var stack_arguments: [stack_argument_capacity]Value = undefined;
    const heap_arguments = instruction.operands.len > stack_argument_capacity;
    const arguments = if (heap_arguments) args: {
        self.heap_argument_allocs += 1;
        break :args try self.allocator.alloc(Value, instruction.operands.len);
    } else stack_arguments[0..instruction.operands.len];
    defer if (heap_arguments) self.allocator.free(arguments);
    for (instruction.operands, 0..) |operand_id, index| arguments[index] = frame.values[operand_id];
    var writes_result = false;
    const result = if (prepared_target) |target| switch (target) {
        .direct_ir => |callee_id| blk: {
            if (callee_id >= frame.owner_program.functions.len) return error.InvalidDirectCallee;
            writes_result = true;
            break :blk try self.executeFunction(&frame.owner_program.functions[callee_id], arguments, null, frame.owner_program);
        },
        .local_slot => |slot| if (localSlotValue(frame, slot)) |callable| blk: {
            if (callable != .function) return error.NotCallable;
            writes_result = callable.function.kind == .ir;
            break :blk try self.callFunctionValue(callable.function, arguments);
        } else try executeCallFallback(self, frame, instruction, arguments, &writes_result, prepared_global_slot, null),
        .global_or_builtin => |builtin_target| try executeCallFallback(self, frame, instruction, arguments, &writes_result, builtin_target.global_slot, builtin_target.id),
    } else if (instruction.direct_callee) |callee_id| blk: {
        if (callee_id >= frame.owner_program.functions.len) return error.InvalidDirectCallee;
        writes_result = true;
        break :blk try self.executeFunction(&frame.owner_program.functions[callee_id], arguments, null, frame.owner_program);
    } else if (self.findFunction(frame.owner_program, instruction.name)) |function| blk: {
        writes_result = true;
        break :blk try self.executeFunction(function, arguments, null, frame.owner_program);
    } else if (localValue(frame, instruction.name)) |callable| blk: {
        if (callable != .function) return error.NotCallable;
        writes_result = callable.function.kind == .ir;
        break :blk try self.callFunctionValue(callable.function, arguments);
    } else try executeCallFallback(self, frame, instruction, arguments, &writes_result, prepared.no_global_slot, null);
    if (writes_result and !resultStoreCanBeOmitted(self, omit_result_store)) try self.setGlobal("それ", result);
    return result;
}

fn resultStoreCanBeOmitted(self: *const Interpreter, proven_dead: bool) bool {
    if (!proven_dead) return false;
    // Global tracing is an explicit observation surface.  Keep the legacy
    // write whenever the trace is active, even if the static proof says the
    // language value is dead.
    if (!(self.global_trace.path == null or self.global_trace.context == null or
        self.global_trace.writeFn == null or self.global_trace.disabled.load(.acquire))) return false;
    // An interrupt callback runs at the same safepoints used by prepared
    // calls and allocations.  It can read `それ` between this call and the
    // proven overwrite, so the proof is disabled while one is registered.
    if (self.node_state.interrupt_callback != .undefined) return false;
    // Timers are drained after synchronous execution today, but retaining the
    // store while one is pending keeps the optimization safe if a future
    // safepoint drains event work inline.
    if (self.timers.items.len != 0) return false;
    return true;
}

fn executeCallFallback(
    self: *Interpreter,
    frame: *Frame,
    instruction: ir.Instruction,
    arguments: []const Value,
    writes_result: *bool,
    global_slot: prepared.GlobalSlot,
    builtin_id: ?prepared.BuiltinId,
) !Value {
    const global = if (global_slot != prepared.no_global_slot) self.globalSlotValue(global_slot) else self.globals.get(instruction.name);
    if (global) |callable| {
        if (callable != .function) return error.NotCallable;
        writes_result.* = callable.function.kind == .ir;
        return self.callFunctionValue(callable.function, arguments);
    }
    writes_result.* = !preservesResultVariable(instruction.name);
    const site_id = if (frame.owner_program == &self.root_program) instruction.site_id else null;
    return self.callBuiltinResolved(builtin_id, instruction.name, arguments, site_id);
}

pub fn executeCallValue(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    if (instruction.operands.len == 0) return error.NotCallable;
    const callable = frame.values[instruction.operands[0]];
    var stack_arguments: [stack_argument_capacity]Value = undefined;
    const heap_arguments = instruction.operands.len - 1 > stack_argument_capacity;
    const arguments = if (heap_arguments) args: {
        self.heap_argument_allocs += 1;
        break :args try self.allocator.alloc(Value, instruction.operands.len - 1);
    } else stack_arguments[0 .. instruction.operands.len - 1];
    defer if (heap_arguments) self.allocator.free(arguments);
    for (instruction.operands[1..], 0..) |operand_id, index| arguments[index] = frame.values[operand_id];
    if (callable != .function) return error.NotCallable;
    return self.callFunctionValue(callable.function, arguments);
}

pub fn callFunctionValue(self: *Interpreter, function: *value_mod.Function, arguments: []const Value) !Value {
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
        .native, .external => self.runtime.call(.{ .function = function }, arguments),
        .ir => |function_id| self.callIrFunctionValue(function_id, function, arguments),
    };
}

pub fn callIrFunctionValue(self: *Interpreter, function_id: ir.FunctionId, function: *value_mod.Function, arguments: []const Value) !Value {
    const owner_program: *const ir.Program = if (function.ir_program) |pointer| @ptrCast(@alignCast(pointer)) else &self.program;
    if (function_id >= owner_program.functions.len) return error.InvalidIrFunction;
    const target = &owner_program.functions[function_id];
    const arity = target.parameters.len;
    if (arguments.len >= arity) return self.executeFunction(target, arguments, function, owner_program);
    const padded = try self.allocator.alloc(Value, arity);
    defer self.allocator.free(padded);
    @memcpy(padded[0..arguments.len], arguments);
    padded[arguments.len] = try self.systemContext();
    @memset(padded[arguments.len + 1 ..], .undefined);
    return self.executeFunction(target, padded, function, owner_program);
}

pub fn makeArray(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    var result = try self.runtime.createArray();
    var root = self.runtime.rootFrame();
    defer root.deinit();
    try root.protect(&result);
    for (instruction.operands) |operand_id| _ = try result.array.push(frame.values[operand_id]);
    return result;
}

pub fn makeDictionary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    var result = try self.runtime.createDictionary();
    var root = self.runtime.rootFrame();
    defer root.deinit();
    try root.protect(&result);
    var index: usize = 0;
    while (index + 1 < instruction.operands.len) : (index += 2) {
        const key = try self.runtime.valueToString(frame.values[instruction.operands[index]]);
        const value = frame.values[instruction.operands[index + 1]];
        if (std.mem.eql(u16, key.string.units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' })) {
            if (value == .null_value or isPrototypeObject(value)) result.dictionary.prototype = value;
        } else try result.dictionary.set(key.string, value);
    }
    return result;
}

pub fn getIndexed(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    var current = self.operand(frame, instruction, 0);
    for (instruction.operands[1..]) |operand_id| current = try self.getOne(current, frame.values[operand_id]);
    return current;
}

pub fn getOne(self: *Interpreter, container: Value, key: Value) !Value {
    if (container == .bytes) {
        var rooted = [2]Value{ container, key };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&rooted[0]);
        try roots.protect(&rooted[1]);
        const container_root = rooted[0];
        var key_text = try self.runtime.valueToString(rooted[1]);
        try roots.protect(&key_text);
        if (ownProperty(container_root.bytes.properties.items, key_text.string.units)) |value| return value;
        if (interpreterArrayIndex(key_text.string.units) == null) {
            if (try plugin_system.arrays.standardInheritedProperty(self.runtime, container_root, key_text.string.units)) |value| return value;
        }
        if (!plugin_system.arrays.byteBufferAllowsStandardPrototype(container_root.bytes)) {
            if (container_root.bytes.kind == .array_buffer) return .undefined;
            const position = interpreterArrayIndex(key_text.string.units) orelse return .undefined;
            return container_root.bytes.get(position);
        }
        if (std.mem.eql(u16, key_text.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) {
            return if (container_root.bytes.kind == .array_buffer) .undefined else .{ .number = @floatFromInt(container_root.bytes.bytes.len) };
        }
        if (std.mem.eql(u16, key_text.string.units, &.{ 'b', 'u', 'f', 'f', 'e', 'r' })) {
            if (container_root.bytes.kind != .array_buffer) return self.runtime.createByteBufferBackingBuffer(container_root.bytes);
            return .undefined;
        }
        if (std.mem.eql(u16, key_text.string.units, &.{ 'b', 'y', 't', 'e', 'L', 'e', 'n', 'g', 't', 'h' })) return .{ .number = @floatFromInt(container_root.bytes.bytes.len) };
        if (std.mem.eql(u16, key_text.string.units, &.{ 'b', 'y', 't', 'e', 'O', 'f', 'f', 's', 'e', 't' })) {
            if (container_root.bytes.kind == .array_buffer) return .undefined;
            return .{ .number = @floatFromInt(container_root.bytes.byte_offset) };
        }
        if (std.mem.eql(u16, key_text.string.units, &.{ 'B', 'Y', 'T', 'E', 'S', '_', 'P', 'E', 'R', '_', 'E', 'L', 'E', 'M', 'E', 'N', 'T' })) {
            return if (container_root.bytes.kind == .array_buffer) .undefined else .{ .number = 1 };
        }
        if (container_root.bytes.kind == .array_buffer) return .undefined;
        const position = interpreterArrayIndex(key_text.string.units) orelse return .undefined;
        return container_root.bytes.get(position);
    }
    if (container == .array) return try getArrayProperty(self.runtime, container.array, key);
    if (container == .dictionary) {
        var rooted = [_]Value{ container, key, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&rooted[0]);
        try roots.protect(&rooted[1]);
        rooted[2] = try self.runtime.valueToString(rooted[1]);
        try roots.protect(&rooted[2]);
        if (rooted[0].dictionary.get(rooted[2].string)) |value| return value;
        if (try plugin_system.arrays.standardInheritedProperty(self.runtime, rooted[0], rooted[2].string.units)) |value| return value;
        return .undefined;
    }
    if (container == .function) {
        var rooted = [_]Value{ container, key, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&rooted[0]);
        try roots.protect(&rooted[1]);
        rooted[2] = try self.runtime.valueToString(rooted[1]);
        try roots.protect(&rooted[2]);
        if (ownProperty(rooted[0].function.properties.items, rooted[2].string.units)) |value| return value;
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return .{ .number = 0 };
        if (std.mem.eql(u16, rooted[2].string.units, &.{ 'n', 'a', 'm', 'e' })) {
            const lambda_marker = [_]u16{ '_', '_', 'l', 'a', 'm', 'b', 'd', 'a', '$' };
            const name = if (std.mem.indexOf(u16, rooted[0].function.name.units, &lambda_marker) != null)
                &.{}
            else
                rooted[0].function.name.units;
            return self.runtime.stringCodeUnits(name);
        }
        if (try plugin_system.arrays.standardInheritedProperty(self.runtime, rooted[0], rooted[2].string.units)) |value| return value;
        return .undefined;
    }
    if (container == .promise) {
        var rooted = [_]Value{ container, key, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        try roots.protect(&rooted[0]);
        try roots.protect(&rooted[1]);
        rooted[2] = try self.runtime.valueToString(rooted[1]);
        try roots.protect(&rooted[2]);
        return ownProperty(rooted[0].promise.properties.items, rooted[2].string.units) orelse .undefined;
    }
    if (container == .string) {
        const unit = container.string.codeUnitAt(try valueIndex(self.runtime, key)) orelse return .undefined;
        return self.runtime.stringCodeUnits(&.{unit});
    }
    return .undefined;
}

pub fn setIndexed(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
    return setIndexedResolved(self, frame, instruction, prepared.no_local_slot, prepared.no_global_slot);
}

fn setIndexedResolved(
    self: *Interpreter,
    frame: *Frame,
    instruction: ir.Instruction,
    local_slot: prepared.LocalSlot,
    global_slot: prepared.GlobalSlot,
) !void {
    if (instruction.operands.len < 2) return error.InvalidAssignment;
    var container = localSlotValue(frame, local_slot) orelse if (localCell(frame, instruction.name)) |cell|
        cell.value
    else if (global_slot != prepared.no_global_slot)
        self.globalSlotValue(global_slot) orelse return error.InvalidAssignment
    else
        self.globals.get(instruction.name) orelse return error.InvalidAssignment;
    const value = self.operand(frame, instruction, 0);
    const keys = instruction.operands[1..];
    var index: usize = 0;
    while (index + 1 < keys.len) : (index += 1) container = try self.getOne(container, frame.values[keys[index]]);
    const key = frame.values[keys[keys.len - 1]];
    if (container == .bytes) {
        var rooted = [_]Value{ container, key, value, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        for (&rooted) |*root| try roots.protect(root);
        rooted[3] = try self.runtime.valueToString(rooted[1]);
        const key_units = rooted[3].string.units;
        if (rooted[0].bytes.kind != .array_buffer) if (interpreterArrayIndex(key_units)) |position| {
            const number = try self.runtime.valueToNumber(rooted[2]);
            const byte: u8 = if (!std.math.isFinite(number) or number == 0)
                0
            else
                @intFromFloat(@mod(@trunc(number), 256));
            rooted[0].bytes.set(position, byte);
            return;
        };
        if (std.mem.eql(u16, key_units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }) and
            ownProperty(rooted[0].bytes.properties.items, key_units) == null)
        {
            if (rooted[2] == .null_value or isPrototypeObject(rooted[2])) rooted[0].bytes.prototype = rooted[2];
            return;
        }
        if (interpreterByteBufferReadOnlyProperty(rooted[0].bytes.kind, key_units)) return;
        try setOwnProperty(&rooted[0].bytes.properties, self.allocator, rooted[3].string, rooted[2]);
        return;
    }
    if (container == .array) {
        const key_text = try self.runtime.valueToString(key);
        if (std.mem.eql(u16, key_text.string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' })) return error.ArrayLengthAssignment;
        if (interpreterArrayIndex(key_text.string.units)) |position| return container.array.set(position, value);
        if (std.mem.eql(u16, key_text.string.units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }) and
            !container.array.hasProperty(key_text.string))
        {
            if (value == .null_value or isPrototypeObject(value)) container.array.prototype = value;
            return;
        }
        return container.array.setProperty(key_text.string, value);
    }
    if (container == .dictionary) {
        const text = try self.runtime.valueToString(key);
        if (container.dictionary.get(text.string) != null or
            !std.mem.eql(u16, text.string.units, &.{ '_', '_', 'p', 'r', 'o', 't', 'o', '_', '_' }))
        {
            return container.dictionary.set(text.string, value);
        }
        if (value == .null_value or isPrototypeObject(value)) container.dictionary.prototype = value;
        return;
    }
    if (container == .function) {
        var rooted = [_]Value{ container, key, value, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        for (&rooted) |*root| try roots.protect(root);
        rooted[3] = try self.runtime.valueToString(rooted[1]);
        if (std.mem.eql(u16, rooted[3].string.units, &.{ 'l', 'e', 'n', 'g', 't', 'h' }) or
            std.mem.eql(u16, rooted[3].string.units, &.{ 'n', 'a', 'm', 'e' })) return;
        try setOwnProperty(&rooted[0].function.properties, self.allocator, rooted[3].string, rooted[2]);
        return;
    }
    if (container == .promise) {
        var rooted = [_]Value{ container, key, value, .undefined };
        var roots = self.runtime.rootFrame();
        defer roots.deinit();
        for (&rooted) |*root| try roots.protect(root);
        rooted[3] = try self.runtime.valueToString(rooted[1]);
        try setOwnProperty(&rooted[0].promise.properties, self.allocator, rooted[3].string, rooted[2]);
        return;
    }
    switch (container) {
        .undefined, .null_value => {
            const key_text = try self.runtime.valueToString(key);
            const key_utf8 = try key_text.string.toUtf8Lossy(self.allocator);
            defer self.allocator.free(key_utf8);
            const container_name: []const u8 = if (container == .null_value) "null" else "undefined";
            const message = try std.fmt.allocPrint(self.allocator, "Cannot set properties of {s} (setting '{s}')", .{ container_name, key_utf8 });
            defer self.allocator.free(message);
            self.exception_value = try self.runtime.stringUtf8(message);
            return error.NakoException;
        },
        else => return,
    }
}

pub fn increment(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
    return incrementResolved(self, frame, instruction, prepared.no_local_slot, prepared.no_global_slot);
}

fn incrementResolved(
    self: *Interpreter,
    frame: *Frame,
    instruction: ir.Instruction,
    local_slot: prepared.LocalSlot,
    global_slot: prepared.GlobalSlot,
) !void {
    const local_cell = localSlotCell(frame, local_slot) orelse localCell(frame, instruction.name);
    const local_value = localSlotValue(frame, local_slot) orelse if (local_cell) |cell| cell.value else null;
    const old = local_value orelse
        (if (global_slot != prepared.no_global_slot) self.globalSlotValue(global_slot) else self.globals.get(instruction.name)) orelse
        Value{ .number = 0 };
    const updated = try operators.increment(self.runtime, old, self.operand(frame, instruction, 0));
    if (local_cell) |cell| {
        cell.value = updated;
    } else if (local_value != null or localSlotKnown(frame, local_slot)) {
        try self.storeLocalSlot(frame, local_slot, instruction.name, updated);
    } else if (global_slot != prepared.no_global_slot) try self.setGlobalSlot(global_slot, instruction.name, updated) else try self.setGlobal(instruction.name, updated);
}

pub fn makeClosure(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    return makeClosureResolved(self, frame, instruction, null);
}

fn makeClosureResolved(self: *Interpreter, frame: *Frame, instruction: ir.Instruction, prepared_target: ?ir.FunctionId) !Value {
    const function = if (prepared_target) |target| blk: {
        if (target >= frame.owner_program.functions.len) return error.UnknownFunction;
        break :blk &frame.owner_program.functions[target];
    } else self.findFunction(frame.owner_program, instruction.name) orelse return error.UnknownFunction;
    const name = try self.runtime.stringUtf8(instruction.name);
    var name_root = name;
    var root = self.runtime.rootFrame();
    defer root.deinit();
    try root.protect(&name_root);
    const count = function.captures.len;
    const captures = try self.allocator.alloc(value_mod.Capture, count);
    defer self.allocator.free(captures);
    const capture_roots = try self.allocator.alloc(Value, count);
    defer self.allocator.free(capture_roots);
    for (function.captures, 0..) |capture_name, index| {
        const cell = localCell(frame, capture_name) orelse return error.MissingClosureCapture;
        capture_roots[index] = try self.runtime.stringUtf8(capture_name);
        try root.protect(&capture_roots[index]);
        captures[index] = .{ .name = capture_roots[index].string, .cell = cell };
    }
    const result = try self.runtime.createIrFunction(name.string, function.parameters.len, function.id, captures);
    result.function.ir_program = @ptrCast(self.currentProgramOwner());
    return result;
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
        state = .{ .kind = .range, .current = start, .end = end, .step = step, .variable_name = instruction.name };
    } else {
        const source = self.operand(frame, instruction, 0);
        state = switch (source) {
            .number => |number| .{ .kind = .repeat, .count = try repeatCount(number) },
            .bytes => .{ .kind = .bytes, .source = source, .count = source.bytes.bytes.len },
            .array => .{ .kind = .array, .source = source, .count = source.array.len() },
            .string => .{ .kind = .string, .source = source, .count = source.string.len() },
            .dictionary => .{ .kind = .dictionary, .source = source, .count = source.dictionary.len() },
            else => .{ .kind = .repeat, .count = 0 },
        };
    }
    try frame.iterators.put(self.allocator, id, state);
    return .{ .number = @floatFromInt(id) };
}

pub fn iteratorHasNext(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !bool {
    _ = self;
    const id = instruction.operands[0];
    const state = frame.iterators.get(id) orelse return error.InvalidIterator;
    return switch (state.kind) {
        .range => if (state.step > 0) state.current <= state.end else state.current >= state.end,
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
            if (localCell(frame, state.variable_name) != null or
                (frame.prepared_function != null and frame.prepared_function.?.localSlot(state.variable_name) != null))
            {
                try self.storeLocal(frame, state.variable_name, result);
            } else try self.setGlobal(state.variable_name, result);
        },
        .bytes => {
            result = state.source.bytes.get(state.index);
            try self.setGlobal("対象キー", .{ .number = @floatFromInt(state.index) });
            state.index += 1;
            try self.setGlobal("対象", result);
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

pub fn executeDynamicValue(self: *Interpreter, source_value: Value) !Value {
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
    const dynamic_program = try lower_ssa.lower(self.allocator, hir_program);
    var report = try verifier.verify(self.allocator, dynamic_program);
    defer report.deinit();
    if (!report.succeeded()) return error.DynamicIrFailed;
    const owned_program = try self.allocator.create(ir.Program);
    owned_program.* = dynamic_program;
    errdefer {
        owned_program.deinit();
        self.allocator.destroy(owned_program);
    }
    try self.dynamic_programs.append(self.allocator, owned_program);
    const saved_program = self.program;
    const saved_program_owner = self.active_program_owner;
    self.program = owned_program.*;
    self.active_program_owner = owned_program;
    defer {
        self.program = saved_program;
        self.active_program_owner = saved_program_owner;
    }
    var capture: std.ArrayList(u8) = .empty;
    defer capture.deinit(self.allocator);
    try self.output_captures.append(self.allocator, &capture);
    defer _ = self.output_captures.pop();
    _ = try self.runEntries();
    try self.drainEventLoop();
    return self.runtime.stringUtf8(capture.items);
}
