const std = @import("std");
const ir = @import("nako_ir.zig");

pub const Options = struct {
    max_iterations: usize = 8,
    fold_constants: bool = true,
    eliminate_dead_code: bool = true,
};

pub const Stats = struct {
    inferred_values: usize = 0,
    inferred_parameters: usize = 0,
    inferred_returns: usize = 0,
    direct_calls: usize = 0,
    folded_constants: usize = 0,
    simplified_branches: usize = 0,
    removed_instructions: usize = 0,
};

const Constant = union(enum) {
    number: f64,
    boolean: bool,
    null_value,
    undefined,
    string: []const u8,
};

const Evidence = union(enum) {
    none,
    known: ir.Type,
    conflict,

    fn add(self: *Evidence, candidate: ir.Type) void {
        if (candidate == .dynamic or candidate == .void) {
            self.* = .conflict;
            return;
        }
        switch (self.*) {
            .none => self.* = .{ .known = candidate },
            .known => |existing| if (existing != candidate) {
                self.* = .conflict;
            },
            .conflict => {},
        }
    }
};

pub fn optimize(scratch_allocator: std.mem.Allocator, program: *ir.Program, options: Options) !Stats {
    var stats = Stats{};
    markDirectCalls(program, &stats);
    try inferTypes(scratch_allocator, program, options.max_iterations, &stats);
    if (options.fold_constants) try foldConstants(scratch_allocator, program, options.max_iterations, &stats);
    try inferTypes(scratch_allocator, program, options.max_iterations, &stats);
    if (options.eliminate_dead_code) try eliminateDeadCode(scratch_allocator, program, &stats);
    return stats;
}

fn markDirectCalls(program: *ir.Program, stats: *Stats) void {
    for (program.functions) |*function| for (function.blocks) |*block| for (block.instructions) |*instruction| {
        if (instruction.opcode != .call or instruction.direct_callee != null) continue;
        for (program.functions) |callee| if (std.mem.eql(u8, callee.name, instruction.name)) {
            instruction.direct_callee = callee.id;
            stats.direct_calls += 1;
            break;
        };
    };
}

fn inferTypes(allocator: std.mem.Allocator, program: *ir.Program, max_iterations: usize, stats: *Stats) !void {
    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        var changed = false;
        for (program.functions) |*function| {
            if (try inferFunctionValues(allocator, program, function, stats)) changed = true;
        }
        if (try inferReturnTypes(allocator, program, stats)) changed = true;
        if (try inferParameterTypes(allocator, program, stats)) changed = true;
        if (!changed) break;
    }
}

fn inferFunctionValues(allocator: std.mem.Allocator, program: *ir.Program, function: *ir.Function, stats: *Stats) !bool {
    const count = maxValueId(function.*) + 1;
    const types = try allocator.alloc(ir.Type, count);
    defer allocator.free(types);
    @memset(types, .dynamic);
    for (function.parameters) |parameter| types[parameter.value] = parameter.type;
    for (function.blocks) |block| for (block.instructions) |instruction| if (instruction.result) |result| {
        types[result] = instruction.type;
    };

    var changed = false;
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var pass_changed = false;
        for (function.blocks) |*block| for (block.instructions) |*instruction| {
            const result = instruction.result orelse continue;
            if (instruction.type != .dynamic) {
                types[result] = instruction.type;
                continue;
            }
            const inferred = if (instruction.opcode == .load_local)
                inferParameterLoadType(function.*, instruction.*, types)
            else
                instructionType(program.*, instruction.*, types);
            if (inferred == .dynamic or inferred == .void) continue;
            instruction.type = inferred;
            types[result] = inferred;
            stats.inferred_values += 1;
            pass_changed = true;
            changed = true;
        };
        if (!pass_changed) break;
    }
    return changed;
}

fn inferParameterLoadType(function: ir.Function, instruction: ir.Instruction, types: []const ir.Type) ir.Type {
    var evidence: Evidence = .none;
    var parameter_found = false;
    for (function.parameters) |parameter| if (std.mem.eql(u8, parameter.name, instruction.name)) {
        parameter_found = true;
        evidence.add(parameter.type);
    };
    if (!parameter_found) return .dynamic;
    for (function.blocks) |block| for (block.instructions) |candidate| {
        if (candidate.opcode != .store_local or !std.mem.eql(u8, candidate.name, instruction.name) or candidate.operands.len == 0) continue;
        evidence.add(types[candidate.operands[0]]);
    };
    return switch (evidence) {
        .known => |value| value,
        else => .dynamic,
    };
}

fn instructionType(program: ir.Program, instruction: ir.Instruction, types: []const ir.Type) ir.Type {
    return switch (instruction.opcode) {
        .const_number => .number,
        .const_bigint => .bigint,
        .const_boolean => .boolean,
        .const_null => .null_value,
        .const_string => .string,
        .make_array => .array,
        .make_object => .object,
        .make_closure => .function,
        .iterator_has_next => .boolean,
        .binary => inferBinaryType(instruction, types),
        .unary => inferUnaryType(instruction, types),
        .call => if (instruction.direct_callee) |callee| if (callee < program.functions.len) program.functions[callee].return_type else .dynamic else .dynamic,
        .phi => inferPhiType(instruction, types),
        else => .dynamic,
    };
}

fn inferBinaryType(instruction: ir.Instruction, types: []const ir.Type) ir.Type {
    if (instruction.operands.len < 2) return .dynamic;
    if (isComparison(instruction.operator)) return .boolean;
    const left = types[instruction.operands[0]];
    const right = types[instruction.operands[1]];
    if (isLogical(instruction.operator)) return if (left == right) left else .dynamic;
    if (isNumericArithmetic(instruction.operator) and left == .number and right == .number) return .number;
    return .dynamic;
}

fn inferUnaryType(instruction: ir.Instruction, types: []const ir.Type) ir.Type {
    if (isNot(instruction.operator)) return .boolean;
    if (instruction.operands.len > 0 and types[instruction.operands[0]] == .number and
        (std.mem.eql(u8, instruction.operator, "+") or std.mem.eql(u8, instruction.operator, "-"))) return .number;
    return .dynamic;
}

fn inferPhiType(instruction: ir.Instruction, types: []const ir.Type) ir.Type {
    var evidence: Evidence = .none;
    for (instruction.phi_incoming) |incoming| evidence.add(types[incoming.value]);
    return switch (evidence) {
        .known => |value| value,
        else => .dynamic,
    };
}

fn inferReturnTypes(allocator: std.mem.Allocator, program: *ir.Program, stats: *Stats) !bool {
    var changed = false;
    for (program.functions) |*function| {
        if (function.return_type != .dynamic) continue;
        const types = try valueTypes(allocator, function.*);
        defer allocator.free(types);
        var evidence: Evidence = .none;
        var saw_return = false;
        for (function.blocks) |block| switch (block.terminator) {
            .return_value => |value| {
                saw_return = true;
                if (value) |id| evidence.add(types[id]) else evidence = .conflict;
            },
            else => {},
        };
        if (!saw_return) continue;
        if (evidence == .known) {
            function.return_type = evidence.known;
            stats.inferred_returns += 1;
            changed = true;
        }
    }
    return changed;
}

fn inferParameterTypes(allocator: std.mem.Allocator, program: *ir.Program, stats: *Stats) !bool {
    var changed = false;
    for (program.functions) |*callee| {
        if (callee.parameters.len == 0 or functionEscapes(program.*, callee.*)) continue;
        const evidence = try allocator.alloc(Evidence, callee.parameters.len);
        defer allocator.free(evidence);
        @memset(evidence, .none);
        var call_count: usize = 0;
        for (program.functions) |caller| {
            const types = try valueTypes(allocator, caller);
            defer allocator.free(types);
            for (caller.blocks) |block| for (block.instructions) |instruction| {
                if (instruction.opcode != .call or instruction.direct_callee != callee.id) continue;
                call_count += 1;
                for (callee.parameters, 0..) |_, index| {
                    if (index >= instruction.operands.len) {
                        evidence[index] = .conflict;
                    } else evidence[index].add(types[instruction.operands[index]]);
                }
            };
        }
        if (call_count == 0) continue;
        for (callee.parameters, 0..) |*parameter, index| {
            if (parameter.type != .dynamic or evidence[index] != .known) continue;
            parameter.type = evidence[index].known;
            stats.inferred_parameters += 1;
            changed = true;
        }
    }
    return changed;
}

fn foldConstants(allocator: std.mem.Allocator, program: *ir.Program, max_iterations: usize, stats: *Stats) !void {
    var iteration: usize = 0;
    while (iteration < max_iterations) : (iteration += 1) {
        var changed = false;
        for (program.functions) |*function| {
            const facts = try constantFacts(allocator, function.*);
            defer allocator.free(facts);
            for (function.blocks) |*block| for (block.instructions) |*instruction| {
                if (isConstantOpcode(instruction.opcode)) continue;
                const folded = foldInstruction(instruction.*, facts) orelse continue;
                replaceWithConstant(instruction, folded);
                stats.folded_constants += 1;
                changed = true;
            };
            const refreshed = try constantFacts(allocator, function.*);
            defer allocator.free(refreshed);
            for (function.blocks) |*block| switch (block.terminator) {
                .conditional_branch => |branch| if (refreshed[branch.condition]) |constant| {
                    const selected = if (truthy(constant)) branch.then_block else branch.else_block;
                    const discarded = if (truthy(constant)) branch.else_block else branch.then_block;
                    if (!canSimplifyBranch(function.*, block.id, selected, discarded)) continue;
                    block.terminator = .{ .branch = selected };
                    if (selected != discarded) try removePhiIncoming(program, function, discarded, block.id);
                    stats.simplified_branches += 1;
                    changed = true;
                },
                else => {},
            };
        }
        if (!changed) break;
    }
}

fn constantFacts(allocator: std.mem.Allocator, function: ir.Function) ![]?Constant {
    const facts = try allocator.alloc(?Constant, maxValueId(function) + 1);
    @memset(facts, null);
    var pass: usize = 0;
    while (pass < 8) : (pass += 1) {
        var changed = false;
        for (function.blocks) |block| for (block.instructions) |instruction| {
            const result = instruction.result orelse continue;
            const constant = constantInstruction(instruction) orelse if (instruction.opcode == .phi) constantPhi(instruction, facts) else null;
            if (constant == null or constantsEqual(facts[result], constant)) continue;
            facts[result] = constant;
            changed = true;
        };
        if (!changed) break;
    }
    return facts;
}

fn foldInstruction(instruction: ir.Instruction, facts: []const ?Constant) ?Constant {
    return switch (instruction.opcode) {
        .binary => if (instruction.operands.len >= 2) foldBinary(instruction.operator, facts[instruction.operands[0]] orelse return null, facts[instruction.operands[1]] orelse return null) else null,
        .unary => if (instruction.operands.len >= 1) foldUnary(instruction.operator, facts[instruction.operands[0]] orelse return null) else null,
        .phi => constantPhi(instruction, facts),
        else => null,
    };
}

fn foldBinary(operator: []const u8, left: Constant, right: Constant) ?Constant {
    if (isLogical(operator)) return if (std.mem.eql(u8, operator, "&&") or std.mem.eql(u8, operator, "and"))
        if (truthy(left)) right else left
    else if (truthy(left)) left else right;
    if (left == .number and right == .number) {
        const a = left.number;
        const b = right.number;
        if (std.mem.eql(u8, operator, "+")) return .{ .number = a + b };
        if (std.mem.eql(u8, operator, "-")) return .{ .number = a - b };
        if (std.mem.eql(u8, operator, "*")) return .{ .number = a * b };
        if (std.mem.eql(u8, operator, "/") or std.mem.eql(u8, operator, "÷")) return .{ .number = a / b };
        if (std.mem.eql(u8, operator, "%")) return .{ .number = jsRemainder(a, b) };
        if (std.mem.eql(u8, operator, "**")) return if (std.math.isFinite(a) and std.math.isFinite(b)) .{ .number = std.math.pow(f64, a, b) } else null;
        if (isEqual(operator)) return .{ .boolean = a == b };
        if (isNotEqual(operator)) return .{ .boolean = a != b };
        if (std.mem.eql(u8, operator, "<") or std.mem.eql(u8, operator, "lt")) return .{ .boolean = a < b };
        if (std.mem.eql(u8, operator, "<=") or std.mem.eql(u8, operator, "lteq")) return .{ .boolean = a <= b };
        if (std.mem.eql(u8, operator, ">") or std.mem.eql(u8, operator, "gt")) return .{ .boolean = a > b };
        if (std.mem.eql(u8, operator, ">=") or std.mem.eql(u8, operator, "gteq")) return .{ .boolean = a >= b };
    }
    if (isEqual(operator) or isNotEqual(operator)) {
        const equal = constantEqualForOperator(left, right, !std.mem.eql(u8, operator, "===") and !std.mem.eql(u8, operator, "!==")) orelse return null;
        return .{ .boolean = if (isNotEqual(operator)) !equal else equal };
    }
    return null;
}

fn foldUnary(operator: []const u8, value: Constant) ?Constant {
    if (isNot(operator)) return .{ .boolean = !truthy(value) };
    if (value == .number and std.mem.eql(u8, operator, "+")) return value;
    if (value == .number and std.mem.eql(u8, operator, "-")) return .{ .number = -value.number };
    return null;
}

fn constantPhi(instruction: ir.Instruction, facts: []const ?Constant) ?Constant {
    var result: ?Constant = null;
    for (instruction.phi_incoming) |incoming| {
        const candidate = facts[incoming.value] orelse return null;
        if (result) |existing| {
            if (!constantValueEqual(existing, candidate)) return null;
        } else result = candidate;
    }
    return result;
}

fn constantInstruction(instruction: ir.Instruction) ?Constant {
    return switch (instruction.opcode) {
        .const_number => .{ .number = instruction.number_value orelse 0 },
        .const_boolean => .{ .boolean = instruction.boolean_value },
        .const_null => .null_value,
        .const_undefined => .undefined,
        .const_string => .{ .string = instruction.text },
        else => null,
    };
}

fn replaceWithConstant(instruction: *ir.Instruction, constant: Constant) void {
    instruction.operands = &.{};
    instruction.phi_incoming = &.{};
    instruction.site_id = null;
    instruction.name = "";
    instruction.operator = "";
    instruction.names = &.{};
    instruction.number_value = null;
    instruction.boolean_value = false;
    instruction.direct_callee = null;
    instruction.exception_target = null;
    switch (constant) {
        .number => |value| {
            instruction.opcode = .const_number;
            instruction.type = .number;
            instruction.number_value = value;
            instruction.text = "";
        },
        .boolean => |value| {
            instruction.opcode = .const_boolean;
            instruction.type = .boolean;
            instruction.boolean_value = value;
            instruction.text = "";
        },
        .null_value => {
            instruction.opcode = .const_null;
            instruction.type = .null_value;
            instruction.text = "";
        },
        .undefined => {
            instruction.opcode = .const_undefined;
            instruction.type = .dynamic;
            instruction.text = "";
        },
        .string => |value| {
            instruction.opcode = .const_string;
            instruction.type = .string;
            instruction.text = value;
        },
    }
}

fn removePhiIncoming(program: *ir.Program, function: *ir.Function, target: ir.BlockId, predecessor: ir.BlockId) !void {
    if (target >= function.blocks.len) return;
    const allocator = program.arena.allocator();
    for (function.blocks[target].instructions) |*instruction| {
        if (instruction.opcode != .phi) break;
        var incoming: std.ArrayList(ir.PhiIncoming) = .empty;
        for (instruction.phi_incoming) |item| if (item.predecessor != predecessor) try incoming.append(allocator, item);
        instruction.phi_incoming = try incoming.toOwnedSlice(allocator);
    }
}

fn canSimplifyBranch(function: ir.Function, predecessor: ir.BlockId, selected: ir.BlockId, discarded: ir.BlockId) bool {
    if (selected == discarded or discarded >= function.blocks.len) return selected < function.blocks.len;
    for (function.blocks[discarded].instructions) |instruction| {
        if (instruction.opcode != .phi) break;
        for (instruction.phi_incoming) |incoming| if (incoming.predecessor == predecessor and instruction.phi_incoming.len == 1) return false;
    }
    return true;
}

fn eliminateDeadCode(scratch_allocator: std.mem.Allocator, program: *ir.Program, stats: *Stats) !void {
    for (program.functions) |*function| {
        const allocator = program.arena.allocator();
        const count = maxValueId(function.*) + 1;
        const uses = try scratch_allocator.alloc(usize, count);
        defer scratch_allocator.free(uses);
        const definitions = try scratch_allocator.alloc(?ir.Instruction, count);
        defer scratch_allocator.free(definitions);
        const dead = try scratch_allocator.alloc(bool, count);
        defer scratch_allocator.free(dead);
        @memset(uses, 0);
        @memset(definitions, null);
        @memset(dead, false);
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.result) |result| definitions[result] = instruction;
                for (instruction.operands) |operand| uses[operand] += 1;
                for (instruction.phi_incoming) |incoming| uses[incoming.value] += 1;
            }
            switch (block.terminator) {
                .conditional_branch => |branch| uses[branch.condition] += 1,
                .return_value => |value| if (value) |id| {
                    uses[id] += 1;
                },
                .throw_value => |throw_value| uses[throw_value.value] += 1,
                else => {},
            }
        }
        const types = try valueTypes(scratch_allocator, function.*);
        defer scratch_allocator.free(types);
        var worklist: std.ArrayList(ir.ValueId) = .empty;
        defer worklist.deinit(scratch_allocator);
        for (definitions, 0..) |definition, value| if (definition) |instruction| {
            if (uses[value] == 0 and removable(instruction, types)) try worklist.append(scratch_allocator, @intCast(value));
        };
        while (worklist.pop()) |value| {
            if (dead[value] or uses[value] != 0) continue;
            const instruction = definitions[value] orelse continue;
            if (!removable(instruction, types)) continue;
            dead[value] = true;
            stats.removed_instructions += 1;
            for (instruction.operands) |operand| {
                std.debug.assert(uses[operand] > 0);
                uses[operand] -= 1;
                if (uses[operand] == 0) try worklist.append(scratch_allocator, operand);
            }
            for (instruction.phi_incoming) |incoming| {
                std.debug.assert(uses[incoming.value] > 0);
                uses[incoming.value] -= 1;
                if (uses[incoming.value] == 0) try worklist.append(scratch_allocator, incoming.value);
            }
        }
        for (function.blocks) |*block| {
            var retained: std.ArrayList(ir.Instruction) = .empty;
            for (block.instructions) |instruction| {
                if (instruction.result) |result| {
                    if (dead[result]) continue;
                }
                try retained.append(allocator, instruction);
            }
            block.instructions = try retained.toOwnedSlice(allocator);
        }
    }
}

fn removable(instruction: ir.Instruction, types: []const ir.Type) bool {
    return switch (instruction.opcode) {
        .const_number, .const_bigint, .const_boolean, .const_null, .const_string, .const_undefined, .load_global, .load_local, .phi => true,
        .binary, .unary => blk: {
            for (instruction.operands) |operand| if (types[operand] == .dynamic) break :blk false;
            break :blk instruction.type != .dynamic;
        },
        else => false,
    };
}

fn valueTypes(allocator: std.mem.Allocator, function: ir.Function) ![]ir.Type {
    const types = try allocator.alloc(ir.Type, maxValueId(function) + 1);
    @memset(types, .dynamic);
    for (function.parameters) |parameter| types[parameter.value] = parameter.type;
    for (function.blocks) |block| for (block.instructions) |instruction| if (instruction.result) |result| {
        types[result] = instruction.type;
    };
    return types;
}

fn maxValueId(function: ir.Function) usize {
    var maximum: usize = 0;
    for (function.parameters) |parameter| maximum = @max(maximum, parameter.value);
    for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            if (instruction.result) |result| maximum = @max(maximum, result);
            for (instruction.operands) |operand| maximum = @max(maximum, operand);
            for (instruction.phi_incoming) |incoming| maximum = @max(maximum, incoming.value);
        }
        switch (block.terminator) {
            .conditional_branch => |branch| maximum = @max(maximum, branch.condition),
            .return_value => |value| if (value) |id| {
                maximum = @max(maximum, id);
            },
            .throw_value => |throw_value| maximum = @max(maximum, throw_value.value),
            else => {},
        }
    }
    return maximum;
}

fn truthy(constant: Constant) bool {
    return switch (constant) {
        .number => |value| value != 0 and !std.math.isNan(value),
        .boolean => |value| value,
        .null_value, .undefined => false,
        .string => |value| value.len != 0,
    };
}

fn constantEqualForOperator(left: Constant, right: Constant, abstract: bool) ?bool {
    if (left == .null_value and right == .null_value or left == .undefined and right == .undefined) return true;
    if (abstract and (left == .null_value and right == .undefined or left == .undefined and right == .null_value)) return true;
    if (@intFromEnum(left) != @intFromEnum(right)) return if (abstract) null else false;
    return constantValueEqual(left, right);
}

fn constantValueEqual(left: Constant, right: Constant) bool {
    if (@intFromEnum(left) != @intFromEnum(right)) return false;
    return switch (left) {
        .number => |value| @as(u64, @bitCast(value)) == @as(u64, @bitCast(right.number)),
        .boolean => |value| value == right.boolean,
        .null_value, .undefined => true,
        .string => |value| std.mem.eql(u8, value, right.string),
    };
}

fn jsRemainder(left: f64, right: f64) f64 {
    if (std.math.isNan(left) or std.math.isNan(right) or std.math.isInf(left) or right == 0) return std.math.nan(f64);
    if (std.math.isInf(right) or left == 0) return left;
    return @rem(left, right);
}

fn functionEscapes(program: ir.Program, function: ir.Function) bool {
    for (program.functions) |candidate| for (candidate.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode == .make_closure and std.mem.eql(u8, instruction.name, function.name)) return true;
    };
    return false;
}

fn constantsEqual(left: ?Constant, right: ?Constant) bool {
    if (left == null or right == null) return left == null and right == null;
    return constantValueEqual(left.?, right.?);
}

fn isConstantOpcode(opcode: ir.Opcode) bool {
    return switch (opcode) {
        .const_number, .const_bigint, .const_boolean, .const_null, .const_string, .const_undefined => true,
        else => false,
    };
}

fn isNumericArithmetic(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "+") or std.mem.eql(u8, operator, "-") or std.mem.eql(u8, operator, "*") or
        std.mem.eql(u8, operator, "/") or std.mem.eql(u8, operator, "÷") or std.mem.eql(u8, operator, "%") or std.mem.eql(u8, operator, "**");
}

fn isLogical(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "&&") or std.mem.eql(u8, operator, "and") or std.mem.eql(u8, operator, "||") or std.mem.eql(u8, operator, "or");
}

fn isNot(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "!") or std.mem.eql(u8, operator, "not");
}

fn isEqual(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "==") or std.mem.eql(u8, operator, "=") or std.mem.eql(u8, operator, "eq") or std.mem.eql(u8, operator, "===");
}

fn isNotEqual(operator: []const u8) bool {
    return std.mem.eql(u8, operator, "!=") or std.mem.eql(u8, operator, "≠") or std.mem.eql(u8, operator, "noteq") or std.mem.eql(u8, operator, "!==");
}

fn isComparison(operator: []const u8) bool {
    return isEqual(operator) or isNotEqual(operator) or std.mem.eql(u8, operator, "<") or std.mem.eql(u8, operator, "lt") or
        std.mem.eql(u8, operator, "<=") or std.mem.eql(u8, operator, "lteq") or std.mem.eql(u8, operator, ">") or
        std.mem.eql(u8, operator, "gt") or std.mem.eql(u8, operator, ">=") or std.mem.eql(u8, operator, "gteq");
}

test "型推論・定数伝播・直接呼び出し・DCEを適用する" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const hir = @import("hir.zig");
    const lower_ssa = @import("lower_ssa.zig");
    const verifier = @import("verifier.zig");
    const source = "●(Aを)Fとは\nA+1で戻る\nここまで\nX=F(2)\nY=(10+20)*2\nもし真ならば\nZ=1\n違えば\nZ=2\nここまで\nYを表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "main.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const stats = try optimize(std.testing.allocator, &program, .{});
    try std.testing.expect(stats.direct_calls >= 1);
    try std.testing.expect(stats.inferred_parameters >= 1);
    try std.testing.expect(stats.folded_constants >= 2);
    try std.testing.expect(stats.simplified_branches >= 1);
    try std.testing.expect(stats.removed_instructions >= 1);
    const function = program.findFunction("main__F").?;
    try std.testing.expectEqual(ir.Type.number, function.parameters[0].type);
    try std.testing.expectEqual(ir.Type.number, function.return_type);
    try std.testing.expect(stats.inferred_returns >= 1);
    var report = try verifier.verify(std.testing.allocator, program);
    defer report.deinit();
    try std.testing.expect(report.succeeded());
}

test "定数畳み込みでNaNと符号付きゼロを区別する" {
    const positive_zero: f64 = 0.0;
    const negative_zero: f64 = -0.0;
    try std.testing.expect(!constantValueEqual(.{ .number = positive_zero }, .{ .number = negative_zero }));

    const remainder = foldBinary("%", .{ .number = 1 }, .{ .number = 0 }).?;
    try std.testing.expect(std.math.isNan(remainder.number));
    const infinite_division = foldBinary("/", .{ .number = 1 }, .{ .number = 0 }).?;
    try std.testing.expect(std.math.isPositiveInf(infinite_division.number));
    const negative_remainder = foldBinary("%", .{ .number = negative_zero }, .{ .number = 3 }).?;
    try std.testing.expectEqual(@as(u64, @bitCast(negative_zero)), @as(u64, @bitCast(negative_remainder.number)));

    const nan_bits: u64 = 0x7ff8_0000_0000_0042;
    const nan_value: f64 = @bitCast(nan_bits);
    try std.testing.expect(constantValueEqual(.{ .number = nan_value }, .{ .number = nan_value }));
}

test "関数値として外部へ渡る関数の引数型を狭めない" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const hir = @import("hir.zig");
    const lower_ssa = @import("lower_ssa.zig");
    const source = "●(Aを)Fとは\nAで戻る\nここまで\nX=F(1)\nXを表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "escape.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "escape.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "escape.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();

    var escaped = try program.clone(std.testing.allocator);
    defer escaped.deinit();
    const entry = &escaped.functions[escaped.module_entries[0]];
    const block = &entry.blocks[entry.entry];
    var instructions: std.ArrayList(ir.Instruction) = .empty;
    try instructions.appendSlice(escaped.arena.allocator(), block.instructions);
    try instructions.append(escaped.arena.allocator(), .{
        .result = @intCast(maxValueId(entry.*) + 1),
        .opcode = .make_closure,
        .type = .function,
        .name = "escape__F",
        .span = @import("../frontend/ast.zig").emptySpan(),
    });
    block.instructions = try instructions.toOwnedSlice(escaped.arena.allocator());

    _ = try optimize(std.testing.allocator, &program, .{});
    try std.testing.expectEqual(ir.Type.number, program.findFunction("escape__F").?.parameters[0].type);
    _ = try optimize(std.testing.allocator, &escaped, .{});
    try std.testing.expectEqual(ir.Type.dynamic, escaped.findFunction("escape__F").?.parameters[0].type);
}

test "異なる型を渡す再帰呼び出しでは引数型を狭めない" {
    const parser = @import("../frontend/parser.zig");
    const semantic = @import("../semantic/analyzer.zig");
    const hir = @import("hir.zig");
    const lower_ssa = @import("lower_ssa.zig");
    const source = "●(Aを)Fとは\nもしAならば\nF(\"文字\")で戻る\n違えば\n0で戻る\nここまで\nここまで\nX=F(1)\nXを表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "recursive.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "recursive.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "recursive.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower_ssa.lower(std.testing.allocator, hir_program);
    defer program.deinit();

    _ = try optimize(std.testing.allocator, &program, .{});
    try std.testing.expectEqual(ir.Type.dynamic, program.findFunction("recursive__F").?.parameters[0].type);
}

test "唯一の入力を持つphiへの定数分岐は保守的に維持する" {
    const span = @import("../frontend/ast.zig").emptySpan();
    const incoming = [_]ir.PhiIncoming{.{ .predecessor = 0, .value = 0 }};
    const target_instructions = [_]ir.Instruction{.{
        .result = 1,
        .opcode = .phi,
        .type = .boolean,
        .phi_incoming = @constCast(&incoming),
        .span = span,
    }};
    const blocks = [_]ir.BasicBlock{
        .{ .id = 0, .name = "entry", .instructions = &.{}, .terminator = .{ .conditional_branch = .{ .condition = 0, .then_block = 1, .else_block = 2 } } },
        .{ .id = 1, .name = "then", .instructions = &.{}, .terminator = .{ .return_value = null } },
        .{ .id = 2, .name = "else", .instructions = @constCast(&target_instructions), .terminator = .{ .return_value = 1 } },
    };
    const function = ir.Function{
        .id = 0,
        .name = "phi",
        .parameters = &.{},
        .blocks = @constCast(&blocks),
        .entry = 0,
        .return_type = .dynamic,
        .is_async = false,
        .is_test = false,
    };
    try std.testing.expect(!canSimplifyBranch(function, 0, 1, 2));
    try std.testing.expect(canSimplifyBranch(function, 0, 1, 1));
}
