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
const maxValueId = shared.maxValueId;
const isPrototypeObject = shared.isPrototypeObject;
const interpreterByteBufferReadOnlyProperty = shared.interpreterByteBufferReadOnlyProperty;
const ownProperty = shared.ownProperty;
const setOwnProperty = shared.setOwnProperty;
const objectPrimitiveMethod = shared.objectPrimitiveMethod;
const preservesResultVariable = shared.preservesResultVariable;
const promiseResolverSentinel = shared.promiseResolverSentinel;
const promiseAllSentinel = shared.promiseAllSentinel;
const localValue = shared.localValue;
const traceRoots = istate.traceRoots;

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
    const value_count = maxValueId(function.*) + 1;
    const values = try self.allocator.alloc(Value, value_count);
    @memset(values, .undefined);
    var frame = Frame{ .parent = self.active_frame, .function = function, .owner_program = owner_program, .values = values };
    defer frame.deinit(self.allocator);
    self.active_frame = &frame;
    defer self.active_frame = frame.parent;
    const previous_source_path = self.current_source_path;
    self.current_source_path = self.sourcePathForFunction(owner_program, function.name);
    defer self.current_source_path = previous_source_path;

    if (closure) |function_value| for (function_value.captures) |capture| {
        const name = try capture.name.toUtf8Lossy(self.allocator);
        try frame.owned_names.append(self.allocator, name);
        const cell = capture.cell orelse try self.runtime.createBindingCell(capture.value);
        try frame.locals.put(self.allocator, name, cell);
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
        const block = function.blocks[current_block];
        var exceptional_target: ?ir.BlockId = null;
        for (block.instructions) |instruction| {
            try self.handleNodeInterrupt();
            self.executeInstruction(&frame, instruction, predecessor) catch |failure| {
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
            const found = self.globals.getPtr(instruction.name) != null;
            result = self.globals.get(instruction.name) orelse .undefined;
            if (instruction.global_site_id != null) {
                const site_id = if (frame.owner_program == &self.root_program) instruction.global_site_id else null;
                self.global_trace.emit(traceBuiltinName(instruction.name), found, site_id);
            }
        },
        .load_local => result = localValue(frame, instruction.name) orelse self.globals.get(instruction.name) orelse .undefined,
        .store_global => {
            try self.setGlobal(instruction.name, self.operand(frame, instruction, 0));
            if (instruction.global_site_id != null) {
                const site_id = if (frame.owner_program == &self.root_program) instruction.global_site_id else null;
                self.global_trace.emitWrite(traceBuiltinName(instruction.name), site_id);
            }
        },
        .store_local => try self.storeLocal(frame, instruction.name, self.operand(frame, instruction, 0)),
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
    const cell = try self.runtime.createBindingCell(value);
    try frame.locals.put(self.allocator, name, cell);
}

pub fn storeLocal(self: *Interpreter, frame: *Frame, name: []const u8, value: Value) !void {
    if (frame.locals.get(name)) |cell| {
        cell.value = value;
        return;
    }
    try self.bindLocal(frame, name, value);
}

pub fn executeDestructure(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !void {
    const source = self.operand(frame, instruction, 0);
    for (instruction.names, 0..) |name, index| {
        const value = if (source == .array) source.array.get(index) else if (index == 0) source else .undefined;
        if (std.mem.indexOf(u8, name, "__") != null) {
            try self.setGlobal(name, value);
        } else try self.storeLocal(frame, name, value);
    }
}

pub fn executeBinary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    const left = self.operand(frame, instruction, 0);
    const right = self.operand(frame, instruction, 1);
    if (std.mem.eql(u8, instruction.operator, "+")) return operators.nadesikoAdd(self.runtime, left, right);
    if (std.mem.eql(u8, instruction.operator, "-")) return operators.binary(self.runtime, .subtract, left, right);
    if (std.mem.eql(u8, instruction.operator, "*")) return operators.binary(self.runtime, .multiply, left, right);
    if (std.mem.eql(u8, instruction.operator, "/") or std.mem.eql(u8, instruction.operator, "÷")) return operators.binary(self.runtime, .divide, left, right);
    if (std.mem.eql(u8, instruction.operator, "÷÷")) {
        const quotient = try operators.binary(self.runtime, .divide, left, right);
        if (quotient == .number) return .{ .number = @floor(quotient.number) };
        return error.CannotConvertBigIntToNumber;
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

pub fn executeUnary(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    const value = self.operand(frame, instruction, 0);
    if (std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not")) return .{ .boolean = !value.toBoolean() };
    if (std.mem.eql(u8, instruction.operator, "-")) return operators.unaryMinus(self.runtime, value);
    if (std.mem.eql(u8, instruction.operator, "+")) return operators.unaryPlus(self.runtime, value);
    if (std.mem.eql(u8, instruction.operator, "~")) return operators.bitNot(self.runtime, value);
    return error.UnsupportedUnaryOperator;
}

pub fn executeCall(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    var arguments = try self.allocator.alloc(Value, instruction.operands.len);
    defer self.allocator.free(arguments);
    for (instruction.operands, 0..) |operand_id, index| arguments[index] = frame.values[operand_id];
    var writes_result = false;
    const result = if (instruction.direct_callee) |callee_id| blk: {
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
    } else if (self.globals.get(instruction.name)) |callable| blk: {
        if (callable != .function) return error.NotCallable;
        writes_result = callable.function.kind == .ir;
        break :blk try self.callFunctionValue(callable.function, arguments);
    } else blk: {
        writes_result = !preservesResultVariable(instruction.name);
        const site_id = if (frame.owner_program == &self.root_program) instruction.site_id else null;
        break :blk try self.callBuiltin(instruction.name, arguments, site_id);
    };
    if (writes_result) try self.setGlobal("それ", result);
    return result;
}

pub fn executeCallValue(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    if (instruction.operands.len == 0) return error.NotCallable;
    const callable = frame.values[instruction.operands[0]];
    var arguments = try self.allocator.alloc(Value, instruction.operands.len - 1);
    defer self.allocator.free(arguments);
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
    if (instruction.operands.len < 2) return error.InvalidAssignment;
    var container = localValue(frame, instruction.name) orelse self.globals.get(instruction.name) orelse return error.InvalidAssignment;
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
    const old = localValue(frame, instruction.name) orelse self.globals.get(instruction.name) orelse Value{ .number = 0 };
    const updated = try operators.increment(self.runtime, old, self.operand(frame, instruction, 0));
    if (frame.locals.contains(instruction.name)) {
        try self.storeLocal(frame, instruction.name, updated);
    } else try self.setGlobal(instruction.name, updated);
}

pub fn makeClosure(self: *Interpreter, frame: *Frame, instruction: ir.Instruction) !Value {
    const function = self.findFunction(frame.owner_program, instruction.name) orelse return error.UnknownFunction;
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
        const cell = frame.locals.get(capture_name) orelse return error.MissingClosureCapture;
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
            if (frame.locals.contains(state.variable_name)) {
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
