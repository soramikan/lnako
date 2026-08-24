const std = @import("std");
const ir = @import("../../ir/nako_ir.zig");
const ast = @import("../../frontend/ast.zig");

pub const GeneratedModule = struct {
    text: []u8,

    pub fn deinit(self: *GeneratedModule, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const UnsupportedFeature = struct {
    function_name: []const u8,
    opcode: []const u8,
    detail: []const u8,
    span: ast.Span,
};

pub fn findUnsupported(program: ir.Program) ?UnsupportedFeature {
    for (program.functions) |function| for (function.blocks) |block| {
        for (block.instructions) |instruction| {
            const supported = switch (instruction.opcode) {
                .const_number,
                .const_boolean,
                .const_null,
                .const_undefined,
                .load_global,
                .store_global,
                .load_local,
                .store_local,
                .make_array,
                .make_object,
                .array_get,
                .property_get,
                .array_set,
                .property_set,
                .iterator_next,
                .iterator_has_next,
                .phi,
                .speed_mode_begin,
                .speed_mode_end,
                .performance_monitor_begin,
                .performance_monitor_end,
                => true,
                .destructure_store => destructureSourceSupported(function, instruction),
                .const_string => std.mem.indexOfScalar(u8, instruction.text, 0) == null,
                .binary => arithmeticOpcode(instruction.operator) != null or comparisonPredicate(instruction.operator) != null or
                    std.mem.eql(u8, instruction.operator, "&&") or std.mem.eql(u8, instruction.operator, "and") or
                    std.mem.eql(u8, instruction.operator, "||") or std.mem.eql(u8, instruction.operator, "or"),
                .unary => std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not") or
                    std.mem.eql(u8, instruction.operator, "+") or std.mem.eql(u8, instruction.operator, "-"),
                .call => isDisplayCall(instruction.name) or validDirectCallee(program, instruction) or lookupFunction(program, instruction.name) != null,
                .iterator_begin => iteratorSourceSupported(function, instruction),
                else => false,
            };
            if (!supported) return .{
                .function_name = function.name,
                .opcode = @tagName(instruction.opcode),
                .detail = if (instruction.name.len > 0) instruction.name else if (instruction.operator.len > 0) instruction.operator else @tagName(instruction.opcode),
                .span = instruction.span,
            };
        }
        switch (block.terminator) {
            .branch, .conditional_branch, .return_value, .unreachable_terminator => {},
            else => return .{
                .function_name = function.name,
                .opcode = @tagName(block.terminator),
                .detail = "terminator",
                .span = if (block.instructions.len > 0) block.instructions[block.instructions.len - 1].span else ast.emptySpan(),
            },
        }
    };
    return null;
}

const StringConstant = struct { function_id: ir.FunctionId, value_id: ir.ValueId, text: []const u8, index: usize };
const DebugLocation = struct { id: usize, line: usize, column: usize, scope: usize };

pub fn generate(allocator: std.mem.Allocator, program: ir.Program, source_path: []const u8, optimized: bool) !GeneratedModule {
    var emitter = Emitter{
        .allocator = allocator,
        .program = program,
        .source_path = source_path,
        .optimized = optimized,
        .output = .init(allocator),
    };
    defer emitter.deinit();
    try emitter.run();
    return .{ .text = try emitter.output.toOwnedSlice() };
}

const Emitter = struct {
    allocator: std.mem.Allocator,
    program: ir.Program,
    source_path: []const u8,
    optimized: bool,
    output: std.Io.Writer.Allocating,
    globals: std.ArrayList([]const u8) = .empty,
    strings: std.ArrayList(StringConstant) = .empty,
    locations: std.ArrayList(DebugLocation) = .empty,
    next_metadata: usize = 4,

    fn deinit(self: *Emitter) void {
        self.globals.deinit(self.allocator);
        self.strings.deinit(self.allocator);
        self.locations.deinit(self.allocator);
        self.output.deinit();
    }

    fn run(self: *Emitter) !void {
        try self.collectModuleData();
        self.next_metadata = 4 + self.program.functions.len + 1;
        const writer = &self.output.writer;
        try writer.writeAll(
            "; lnako Nako SSA IR -> LLVM IR\n" ++
                "source_filename = \"lnako\"\n\n" ++
                "%lnako.Value = type { i8, i64 }\n" ++
                "%lnako.RootFrame = type { ptr, ptr, i64 }\n\n" ++
                "declare i32 @lnako_aot_runtime_init()\n" ++
                "declare void @lnako_aot_runtime_deinit()\n" ++
                "declare void @lnako_aot_push_roots(ptr, ptr, i64)\n" ++
                "declare void @lnako_aot_pop_roots(ptr)\n" ++
                "declare void @lnako_aot_array_new(ptr, ptr, i64)\n" ++
                "declare void @lnako_aot_dictionary_new(ptr, ptr, i64)\n" ++
                "declare void @lnako_aot_index_get(ptr, ptr, ptr)\n" ++
                "declare i32 @lnako_aot_index_set(ptr, ptr, ptr)\n" ++
                "declare void @lnako_aot_iterator_new(ptr, ptr, i64, i1, i8)\n" ++
                "declare i32 @lnako_aot_iterator_has_next(ptr)\n" ++
                "declare void @lnako_aot_iterator_next(ptr, ptr, ptr, ptr, ptr, ptr)\n" ++
                "declare i32 @printf(ptr, ...)\n" ++
                "declare i32 @puts(ptr)\n" ++
                "declare double @llvm.pow.f64(double, double)\n\n" ++
                "@.lnako.fmt.number = private unnamed_addr constant [7 x i8] c\"%.17g\\0A\\00\"\n" ++
                "@.lnako.fmt.number.inline = private unnamed_addr constant [6 x i8] c\"%.17g\\00\"\n" ++
                "@.lnako.fmt.text.inline = private unnamed_addr constant [3 x i8] c\"%s\\00\"\n" ++
                "@.lnako.undefined = private unnamed_addr constant [10 x i8] c\"undefined\\00\"\n" ++
                "@.lnako.null = private unnamed_addr constant [5 x i8] c\"null\\00\"\n" ++
                "@.lnako.true = private unnamed_addr constant [5 x i8] c\"true\\00\"\n" ++
                "@.lnako.false = private unnamed_addr constant [6 x i8] c\"false\\00\"\n\n",
        );
        for (self.globals.items, 0..) |_, index| try writer.print("@lnako.global.{d} = internal global %lnako.Value {{ i8 0, i64 0 }}\n", .{index});
        if (self.globals.items.len > 0) try writer.writeByte('\n');
        for (self.strings.items) |constant| {
            try writer.print("@lnako.string.{d} = private unnamed_addr constant [{d} x i8] c\"", .{ constant.index, constant.text.len + 1 });
            try writeLlvmString(writer, constant.text);
            try writer.writeAll("\\00\"\n");
        }
        if (self.strings.items.len > 0) try writer.writeByte('\n');
        try self.writeRuntimeHelpers();
        for (self.program.functions) |function| try self.writeFunction(function);
        try self.writeMain();
        try self.writeDebugMetadata();
    }

    fn collectModuleData(self: *Emitter) !void {
        var string_index: usize = 0;
        for (self.program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
            if ((instruction.opcode == .load_global or instruction.opcode == .store_global) and self.globalIndex(instruction.name) == null) {
                try self.globals.append(self.allocator, instruction.name);
            }
            if (instruction.opcode == .destructure_store) for (instruction.names) |name| {
                if (isQualifiedGlobal(name) and self.globalIndex(name) == null) try self.globals.append(self.allocator, name);
            };
            if (instruction.opcode == .const_string) {
                try self.strings.append(self.allocator, .{
                    .function_id = function.id,
                    .value_id = instruction.result orelse return error.InvalidStringConstant,
                    .text = instruction.text,
                    .index = string_index,
                });
                string_index += 1;
            }
        };
    }

    fn writeRuntimeHelpers(self: *Emitter) !void {
        try self.output.writer.writeAll(
            "define internal double @lnako.to_number(%lnako.Value %value) {\n" ++
                "entry:\n" ++
                "  %tag = extractvalue %lnako.Value %value, 0\n" ++
                "  switch i8 %tag, label %nan [ i8 1, label %zero i8 2, label %boolean i8 3, label %number ]\n" ++
                "zero:\n" ++
                "  ret double 0.000000e+00\n" ++
                "boolean:\n" ++
                "  %bool.bits = extractvalue %lnako.Value %value, 1\n" ++
                "  %bool = icmp ne i64 %bool.bits, 0\n" ++
                "  %bool.number = uitofp i1 %bool to double\n" ++
                "  ret double %bool.number\n" ++
                "number:\n" ++
                "  %number.bits = extractvalue %lnako.Value %value, 1\n" ++
                "  %number.value = bitcast i64 %number.bits to double\n" ++
                "  ret double %number.value\n" ++
                "nan:\n" ++
                "  ret double 0x7FF8000000000000\n" ++
                "}\n\n" ++
                "define internal i1 @lnako.truthy(%lnako.Value %value) {\n" ++
                "entry:\n" ++
                "  %tag = extractvalue %lnako.Value %value, 0\n" ++
                "  switch i8 %tag, label %truthy [ i8 0, label %falsey i8 1, label %falsey i8 2, label %boolean i8 3, label %number ]\n" ++
                "boolean:\n" ++
                "  %bool.bits = extractvalue %lnako.Value %value, 1\n" ++
                "  %bool = icmp ne i64 %bool.bits, 0\n" ++
                "  ret i1 %bool\n" ++
                "number:\n" ++
                "  %number.bits = extractvalue %lnako.Value %value, 1\n" ++
                "  %number.value = bitcast i64 %number.bits to double\n" ++
                "  %number.truthy = fcmp one double %number.value, 0.000000e+00\n" ++
                "  ret i1 %number.truthy\n" ++
                "falsey:\n" ++
                "  ret i1 false\n" ++
                "truthy:\n" ++
                "  ret i1 true\n" ++
                "}\n\n" ++
                "define internal void @lnako.print_text(ptr %text, i1 %newline) {\n" ++
                "entry:\n" ++
                "  br i1 %newline, label %line, label %inline\n" ++
                "line:\n" ++
                "  %line.result = call i32 @puts(ptr %text)\n" ++
                "  ret void\n" ++
                "inline:\n" ++
                "  %inline.result = call i32 (ptr, ...) @printf(ptr @.lnako.fmt.text.inline, ptr %text)\n" ++
                "  ret void\n" ++
                "}\n\n" ++
                "define internal %lnako.Value @lnako.display(%lnako.Value %value, i1 %newline) {\n" ++
                "entry:\n" ++
                "  %tag = extractvalue %lnako.Value %value, 0\n" ++
                "  switch i8 %tag, label %undefined [ i8 1, label %null i8 2, label %boolean i8 3, label %number i8 4, label %string ]\n" ++
                "undefined:\n" ++
                "  call void @lnako.print_text(ptr @.lnako.undefined, i1 %newline)\n" ++
                "  br label %done\n" ++
                "null:\n" ++
                "  call void @lnako.print_text(ptr @.lnako.null, i1 %newline)\n" ++
                "  br label %done\n" ++
                "boolean:\n" ++
                "  %bool.bits = extractvalue %lnako.Value %value, 1\n" ++
                "  %bool = icmp ne i64 %bool.bits, 0\n" ++
                "  %bool.text = select i1 %bool, ptr @.lnako.true, ptr @.lnako.false\n" ++
                "  call void @lnako.print_text(ptr %bool.text, i1 %newline)\n" ++
                "  br label %done\n" ++
                "number:\n" ++
                "  %number.bits = extractvalue %lnako.Value %value, 1\n" ++
                "  %number.value = bitcast i64 %number.bits to double\n" ++
                "  %number.fmt = select i1 %newline, ptr @.lnako.fmt.number, ptr @.lnako.fmt.number.inline\n" ++
                "  %p = call i32 (ptr, ...) @printf(ptr %number.fmt, double %number.value)\n" ++
                "  br label %done\n" ++
                "string:\n" ++
                "  %string.bits = extractvalue %lnako.Value %value, 1\n" ++
                "  %string.ptr = inttoptr i64 %string.bits to ptr\n" ++
                "  call void @lnako.print_text(ptr %string.ptr, i1 %newline)\n" ++
                "  br label %done\n" ++
                "done:\n" ++
                "  ret %lnako.Value %value\n" ++
                "}\n\n",
        );
    }

    fn writeFunction(self: *Emitter, function: ir.Function) !void {
        const scope = 4 + function.id;
        try self.output.writer.print("define internal %lnako.Value @lnako.fn.{d}(", .{function.id});
        for (function.parameters, 0..) |_, index| {
            if (index > 0) try self.output.writer.writeAll(", ");
            try self.output.writer.print("%lnako.Value %arg.{d}", .{index});
        }
        try self.output.writer.print(") !dbg !{d} {{\n", .{scope});
        const locals = try self.localNames(function);
        defer self.allocator.free(locals);
        const root_count = functionValueCount(function);
        const root_storage_count = @max(@as(usize, 1), root_count);
        const aggregate_count = maxAggregateOperandCount(function);
        for (function.blocks) |block| {
            try self.output.writer.print("bb{d}:\n", .{block.id});
            if (block.id == function.entry) {
                try self.output.writer.print("  %root.values = alloca [{d} x %lnako.Value]\n", .{root_storage_count});
                try self.output.writer.writeAll("  %root.frame = alloca %lnako.RootFrame\n");
                try self.output.writer.writeAll("  %runtime.scratch = alloca %lnako.Value\n");
                try self.output.writer.writeAll("  store %lnako.Value { i8 0, i64 0 }, ptr %runtime.scratch\n");
                for (0..root_count) |index| {
                    try self.output.writer.print("  %root.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %root.values, i64 0, i64 {d}\n", .{ index, root_storage_count, index });
                    try self.output.writer.print("  store %lnako.Value {{ i8 0, i64 0 }}, ptr %root.slot.{d}\n", .{index});
                }
                if (root_count > 0) {
                    try self.output.writer.print("  call void @lnako_aot_push_roots(ptr %root.frame, ptr %root.slot.0, i64 {d})\n", .{root_count});
                } else try self.output.writer.writeAll("  call void @lnako_aot_push_roots(ptr %root.frame, ptr null, i64 0)\n");
                if (aggregate_count > 0) try self.output.writer.print("  %aggregate.values = alloca [{d} x %lnako.Value]\n", .{aggregate_count});
                for (locals, 0..) |_, index| {
                    try self.output.writer.print("  %local.{d} = alloca %lnako.Value\n", .{index});
                    try self.output.writer.print("  store %lnako.Value {{ i8 0, i64 0 }}, ptr %local.{d}\n", .{index});
                }
                for (function.parameters, 0..) |parameter, index| if (nameIndex(locals, parameter.name)) |local_index| {
                    try self.output.writer.print("  store %lnako.Value %arg.{d}, ptr %local.{d}\n", .{ index, local_index });
                };
                for (function.parameters, 0..) |parameter, index| {
                    try self.output.writer.print("  store %lnako.Value %arg.{d}, ptr %root.slot.{d}\n", .{ index, parameter.value });
                }
            }
            var phi_count: usize = 0;
            while (phi_count < block.instructions.len and block.instructions[phi_count].opcode == .phi) : (phi_count += 1) {
                try self.writeInstruction(function, locals, block.instructions[phi_count], scope, aggregate_count);
            }
            for (block.instructions[0..phi_count]) |instruction| try self.writeRootStore(instruction);
            for (block.instructions[phi_count..]) |instruction| {
                try self.writeInstruction(function, locals, instruction, scope, aggregate_count);
                try self.writeRootStore(instruction);
            }
            const terminator_span = if (block.instructions.len > 0) block.instructions[block.instructions.len - 1].span else ast.emptySpan();
            try self.writeTerminator(function, block.terminator, terminator_span, scope);
        }
        try self.output.writer.writeAll("}\n\n");
    }

    fn writeInstruction(self: *Emitter, function: ir.Function, locals: []const []const u8, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
        const result = instruction.result;
        switch (instruction.opcode) {
            .const_number => {
                const id = result orelse return error.MissingInstructionResult;
                try self.output.writer.print("  %number.bits.{d} = bitcast double 0x{X:0>16} to i64", .{ id, @as(u64, @bitCast(instruction.number_value orelse 0)) });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 3, i64 0 }}, i64 %number.bits.{d}, 1", .{ id, id });
                try self.debugSuffix(instruction.span, scope);
            },
            .const_boolean => try self.writeBoxConstant(result orelse return error.MissingInstructionResult, 2, @intFromBool(instruction.boolean_value), instruction.span, scope),
            .const_null => try self.writeBoxConstant(result orelse return error.MissingInstructionResult, 1, 0, instruction.span, scope),
            .const_undefined => try self.writeBoxConstant(result orelse return error.MissingInstructionResult, 0, 0, instruction.span, scope),
            .const_string => {
                const id = result orelse return error.MissingInstructionResult;
                const string_index = self.stringIndex(function.id, id) orelse return error.InvalidStringConstant;
                try self.output.writer.print("  %string.bits.{d} = ptrtoint ptr @lnako.string.{d} to i64", .{ id, string_index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 4, i64 0 }}, i64 %string.bits.{d}, 1", .{ id, id });
                try self.debugSuffix(instruction.span, scope);
            },
            .load_global => {
                const index = self.globalIndex(instruction.name) orelse return error.UnknownGlobal;
                try self.output.writer.print("  %v{d} = load %lnako.Value, ptr @lnako.global.{d}", .{ result orelse return error.MissingInstructionResult, index });
                try self.debugSuffix(instruction.span, scope);
            },
            .store_global => {
                const index = self.globalIndex(instruction.name) orelse return error.UnknownGlobal;
                try self.output.writer.print("  store %lnako.Value ", .{});
                try self.writeValueRef(function, instruction.operands[0]);
                try self.output.writer.print(", ptr @lnako.global.{d}", .{index});
                try self.debugSuffix(instruction.span, scope);
            },
            .load_local => {
                const index = nameIndex(locals, instruction.name) orelse return error.UnknownLocal;
                try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %local.{d}", .{ result orelse return error.MissingInstructionResult, index });
                try self.debugSuffix(instruction.span, scope);
            },
            .store_local => {
                const index = nameIndex(locals, instruction.name) orelse return error.UnknownLocal;
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, instruction.operands[0]);
                try self.output.writer.print(", ptr %local.{d}", .{index});
                try self.debugSuffix(instruction.span, scope);
            },
            .destructure_store => try self.writeDestructure(locals, instruction, scope),
            .binary => try self.writeBinary(function, instruction, scope),
            .unary => try self.writeUnary(function, instruction, scope),
            .call => try self.writeCall(function, instruction, scope),
            .make_array => try self.writeAggregate(function, instruction, scope, aggregate_count, "lnako_aot_array_new"),
            .make_object => try self.writeAggregate(function, instruction, scope, aggregate_count, "lnako_aot_dictionary_new"),
            .array_get, .property_get => try self.writeIndexGet(instruction, scope),
            .array_set, .property_set => try self.writeIndexSet(locals, instruction, scope),
            .iterator_begin => try self.writeIteratorBegin(function, instruction, scope, aggregate_count),
            .iterator_has_next => try self.writeIteratorHasNext(instruction, scope),
            .iterator_next => try self.writeIteratorNext(function, locals, instruction, scope),
            .phi => {
                try self.output.writer.print("  %v{d} = phi %lnako.Value ", .{result orelse return error.MissingInstructionResult});
                for (instruction.phi_incoming, 0..) |incoming, index| {
                    if (index > 0) try self.output.writer.writeAll(", ");
                    try self.output.writer.writeAll("[ ");
                    try self.writeValueRef(function, incoming.value);
                    try self.output.writer.print(", %bb{d} ]", .{incoming.predecessor});
                }
                try self.debugSuffix(instruction.span, scope);
            },
            .speed_mode_begin, .speed_mode_end, .performance_monitor_begin, .performance_monitor_end => {},
            else => return error.UnsupportedInstruction,
        }
    }

    fn writeRootStore(self: *Emitter, instruction: ir.Instruction) !void {
        const result = instruction.result orelse return;
        try self.output.writer.print("  store %lnako.Value %v{d}, ptr %root.slot.{d}\n", .{ result, result });
    }

    fn writeDestructure(self: *Emitter, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
        if (instruction.operands.len != 1) return error.InvalidDestructure;
        for (instruction.names, 0..) |name, index| {
            const bits: u64 = @bitCast(@as(f64, @floatFromInt(index)));
            try self.output.writer.print("  store %lnako.Value {{ i8 3, i64 {d} }}, ptr %runtime.scratch", .{bits});
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.writeAll("  call void @lnako_aot_index_get(ptr ");
            try self.writeRequiredNamedPointer(locals, name);
            try self.output.writer.print(", ptr %root.slot.{d}, ptr %runtime.scratch)", .{instruction.operands[0]});
            try self.debugSuffix(instruction.span, scope);
        }
    }

    fn writeAggregate(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize, runtime_name: []const u8) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (instruction.operands.len > aggregate_count) return error.InvalidAggregateScratch;
        for (instruction.operands, 0..) |operand, index| {
            try self.output.writer.print("  %aggregate.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.writeAll("  store %lnako.Value ");
            try self.writeValueRef(function, operand);
            try self.output.writer.print(", ptr %aggregate.{d}.slot.{d}", .{ result, index });
            try self.debugSuffix(instruction.span, scope);
        }
        try self.output.writer.print("  call void @{s}(ptr %root.slot.{d}, ptr ", .{ runtime_name, result });
        if (instruction.operands.len > 0) {
            try self.output.writer.print("%aggregate.{d}.slot.0", .{result});
        } else try self.output.writer.writeAll("null");
        try self.output.writer.print(", i64 {d})", .{instruction.operands.len});
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeIndexGet(self: *Emitter, instruction: ir.Instruction, scope: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (instruction.operands.len < 2) return error.InvalidIndexReference;
        for (instruction.operands[1..], 0..) |key, index| {
            const last = index + 2 == instruction.operands.len;
            try self.output.writer.print("  call void @lnako_aot_index_get(ptr %root.slot.{d}, ptr ", .{result});
            if (index == 0) {
                try self.output.writer.print("%root.slot.{d}", .{instruction.operands[0]});
            } else try self.output.writer.print("%root.slot.{d}", .{result});
            try self.output.writer.print(", ptr %root.slot.{d})", .{key});
            try self.debugSuffix(instruction.span, scope);
            if (!last) continue;
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
        }
    }

    fn writeIndexSet(self: *Emitter, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
        if (instruction.operands.len < 2) return error.InvalidIndexAssignment;
        const temporary = self.next_metadata;
        try self.output.writer.print("  %set.container.{d} = load %lnako.Value, ptr ", .{temporary});
        if (nameIndex(locals, instruction.name)) |index| {
            try self.output.writer.print("%local.{d}", .{index});
        } else if (self.globalIndex(instruction.name)) |index| {
            try self.output.writer.print("@lnako.global.{d}", .{index});
        } else return error.UnknownAssignmentContainer;
        try self.debugSuffix(instruction.span, scope);
        for (instruction.operands[1 .. instruction.operands.len - 1], 0..) |key, index| {
            try self.output.writer.writeAll("  call void @lnako_aot_index_get(ptr %runtime.scratch, ptr ");
            if (index == 0) {
                if (nameIndex(locals, instruction.name)) |local_index| {
                    try self.output.writer.print("%local.{d}", .{local_index});
                } else if (self.globalIndex(instruction.name)) |global_index| {
                    try self.output.writer.print("@lnako.global.{d}", .{global_index});
                } else return error.UnknownAssignmentContainer;
            } else try self.output.writer.writeAll("%runtime.scratch");
            try self.output.writer.print(", ptr %root.slot.{d})", .{key});
            try self.debugSuffix(instruction.span, scope);
        }
        try self.output.writer.print("  %set.status.{d} = call i32 @lnako_aot_index_set(ptr ", .{temporary});
        if (instruction.operands.len == 2) {
            if (nameIndex(locals, instruction.name)) |local_index| {
                try self.output.writer.print("%local.{d}", .{local_index});
            } else if (self.globalIndex(instruction.name)) |global_index| {
                try self.output.writer.print("@lnako.global.{d}", .{global_index});
            } else return error.UnknownAssignmentContainer;
        } else try self.output.writer.writeAll("%runtime.scratch");
        try self.output.writer.print(", ptr %root.slot.{d}, ptr %root.slot.{d})", .{ instruction.operands[instruction.operands.len - 1], instruction.operands[0] });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeIteratorBegin(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (instruction.operands.len == 0 or instruction.operands.len > aggregate_count) return error.InvalidIterator;
        for (instruction.operands, 0..) |operand, index| {
            try self.output.writer.print("  %iterator.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.writeAll("  store %lnako.Value ");
            try self.writeValueRef(function, operand);
            try self.output.writer.print(", ptr %iterator.{d}.slot.{d}", .{ result, index });
            try self.debugSuffix(instruction.span, scope);
        }
        const is_range = instruction.name.len > 0 and instruction.operands.len >= 2;
        const direction: u8 = switch (instruction.loop_direction) {
            .automatic => 0,
            .up => 1,
            .down => 2,
        };
        try self.output.writer.print("  call void @lnako_aot_iterator_new(ptr %root.slot.{d}, ptr %iterator.{d}.slot.0, i64 {d}, i1 {s}, i8 {d})", .{ result, result, instruction.operands.len, if (is_range) "true" else "false", direction });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeIteratorHasNext(self: *Emitter, instruction: ir.Instruction, scope: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (instruction.operands.len != 1) return error.InvalidIterator;
        try self.output.writer.print("  %iterator.has.{d} = call i32 @lnako_aot_iterator_has_next(ptr %root.slot.{d})", .{ result, instruction.operands[0] });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %iterator.bool.{d} = icmp ne i32 %iterator.has.{d}, 0", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %iterator.bits.{d} = zext i1 %iterator.bool.{d} to i64", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 2, i64 0 }}, i64 %iterator.bits.{d}, 1", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeIteratorNext(self: *Emitter, function: ir.Function, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (instruction.operands.len != 1) return error.InvalidIterator;
        const begin = instructionForValue(function, instruction.operands[0]) orelse return error.InvalidIterator;
        if (begin.opcode != .iterator_begin) return error.InvalidIterator;
        try self.output.writer.print("  call void @lnako_aot_iterator_next(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr ", .{ result, instruction.operands[0] });
        try self.writeOptionalNamedPointer(locals, "回数");
        try self.output.writer.writeAll(", ptr ");
        try self.writeOptionalNamedPointer(locals, "対象");
        try self.output.writer.writeAll(", ptr ");
        try self.writeOptionalNamedPointer(locals, "対象キー");
        try self.output.writer.writeAll(", ptr ");
        try self.writeOptionalNamedPointer(locals, begin.name);
        try self.output.writer.writeByte(')');
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeOptionalNamedPointer(self: *Emitter, locals: []const []const u8, name: []const u8) !void {
        if (name.len == 0) return self.output.writer.writeAll("null");
        if (nameIndex(locals, name)) |index| return self.output.writer.print("%local.{d}", .{index});
        if (self.globalIndex(name)) |index| return self.output.writer.print("@lnako.global.{d}", .{index});
        return self.output.writer.writeAll("null");
    }

    fn writeRequiredNamedPointer(self: *Emitter, locals: []const []const u8, name: []const u8) !void {
        if (nameIndex(locals, name)) |index| return self.output.writer.print("%local.{d}", .{index});
        if (self.globalIndex(name)) |index| return self.output.writer.print("@lnako.global.{d}", .{index});
        return error.UnknownAssignmentTarget;
    }

    fn writeBinary(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (std.mem.eql(u8, instruction.operator, "&&") or std.mem.eql(u8, instruction.operator, "and") or
            std.mem.eql(u8, instruction.operator, "||") or std.mem.eql(u8, instruction.operator, "or"))
        {
            const condition_label = try std.fmt.allocPrint(self.allocator, "condition.{d}", .{result});
            defer self.allocator.free(condition_label);
            try self.writeTruthyOperand(function, instruction.operands[0], condition_label, instruction.span, scope);
            try self.output.writer.print("  %v{d} = select i1 %condition.{d}, %lnako.Value ", .{ result, result });
            if (std.mem.eql(u8, instruction.operator, "&&") or std.mem.eql(u8, instruction.operator, "and")) {
                try self.writeValueRef(function, instruction.operands[1]);
                try self.output.writer.writeAll(", %lnako.Value ");
                try self.writeValueRef(function, instruction.operands[0]);
            } else {
                try self.writeValueRef(function, instruction.operands[0]);
                try self.output.writer.writeAll(", %lnako.Value ");
                try self.writeValueRef(function, instruction.operands[1]);
            }
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        const left_label = try std.fmt.allocPrint(self.allocator, "left.number.{d}", .{result});
        defer self.allocator.free(left_label);
        const right_label = try std.fmt.allocPrint(self.allocator, "right.number.{d}", .{result});
        defer self.allocator.free(right_label);
        try self.writeNumberOperand(function, instruction.operands[0], left_label, instruction.span, scope);
        try self.writeNumberOperand(function, instruction.operands[1], right_label, instruction.span, scope);

        const arithmetic = arithmeticOpcode(instruction.operator);
        if (arithmetic) |opcode| {
            if (std.mem.eql(u8, opcode, "pow")) {
                try self.output.writer.print("  %binary.number.{d} = call double @llvm.pow.f64(double %left.number.{d}, double %right.number.{d})", .{ result, result, result });
            } else {
                try self.output.writer.print("  %binary.number.{d} = {s} double %left.number.{d}, %right.number.{d}", .{ result, opcode, result, result });
            }
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %binary.bits.{d} = bitcast double %binary.number.{d} to i64", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 3, i64 0 }}, i64 %binary.bits.{d}, 1", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        const predicate = comparisonPredicate(instruction.operator) orelse return error.UnsupportedBinaryOperator;
        try self.output.writer.print("  %compare.{d} = fcmp {s} double %left.number.{d}, %right.number.{d}", .{ result, predicate, result, result });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %compare.bits.{d} = zext i1 %compare.{d} to i64", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 2, i64 0 }}, i64 %compare.bits.{d}, 1", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeUnary(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not")) {
            const truthy_label = try std.fmt.allocPrint(self.allocator, "truthy.{d}", .{result});
            defer self.allocator.free(truthy_label);
            try self.writeTruthyOperand(function, instruction.operands[0], truthy_label, instruction.span, scope);
            try self.output.writer.print("  %not.{d} = xor i1 %truthy.{d}, true", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %not.bits.{d} = zext i1 %not.{d} to i64", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 2, i64 0 }}, i64 %not.bits.{d}, 1", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        const number_label = try std.fmt.allocPrint(self.allocator, "unary.number.{d}", .{result});
        defer self.allocator.free(number_label);
        try self.writeNumberOperand(function, instruction.operands[0], number_label, instruction.span, scope);
        if (std.mem.eql(u8, instruction.operator, "-")) {
            try self.output.writer.print("  %unary.result.{d} = fneg double %unary.number.{d}", .{ result, result });
        } else if (std.mem.eql(u8, instruction.operator, "+")) {
            try self.output.writer.print("  %unary.result.{d} = fadd double %unary.number.{d}, 0.000000e+00", .{ result, result });
        } else return error.UnsupportedUnaryOperator;
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %unary.bits.{d} = bitcast double %unary.result.{d} to i64", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 3, i64 0 }}, i64 %unary.bits.{d}, 1", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeCall(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (isDisplayCall(instruction.name)) {
            if (instruction.operands.len == 0) return error.InvalidCall;
            try self.output.writer.print("  %v{d} = call %lnako.Value @lnako.display(%lnako.Value ", .{result});
            try self.writeValueRef(function, instruction.operands[instruction.operands.len - 1]);
            try self.output.writer.writeAll(", i1 true)");
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        const callee = if (instruction.direct_callee) |callee_id|
            if (callee_id < self.program.functions.len) self.program.functions[callee_id] else return error.InvalidDirectCallee
        else
            self.findFunction(instruction.name) orelse return error.UnsupportedBuiltinCall;
        try self.output.writer.print("  %v{d} = call %lnako.Value @lnako.fn.{d}(", .{ result, callee.id });
        for (instruction.operands, 0..) |operand, index| {
            if (index > 0) try self.output.writer.writeAll(", ");
            try self.output.writer.writeAll("%lnako.Value ");
            try self.writeValueRef(function, operand);
        }
        try self.output.writer.writeByte(')');
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeTerminator(self: *Emitter, function: ir.Function, terminator: ir.Terminator, span: ast.Span, scope: usize) !void {
        switch (terminator) {
            .branch => |target| {
                try self.output.writer.print("  br label %bb{d}", .{target});
                try self.debugSuffix(span, scope);
            },
            .conditional_branch => |branch| {
                const condition_label = try std.fmt.allocPrint(self.allocator, "branch.condition.bb{d}", .{branch.then_block});
                defer self.allocator.free(condition_label);
                try self.writeTruthyOperand(function, branch.condition, condition_label, span, scope);
                try self.output.writer.print("  br i1 %branch.condition.bb{d}, label %bb{d}, label %bb{d}", .{ branch.then_block, branch.then_block, branch.else_block });
                try self.debugSuffix(span, scope);
            },
            .return_value => |value| {
                try self.output.writer.writeAll("  call void @lnako_aot_pop_roots(ptr %root.frame)\n");
                try self.output.writer.writeAll("  ret %lnako.Value ");
                if (value) |operand| try self.writeValueRef(function, operand) else try self.output.writer.writeAll("{ i8 0, i64 0 }");
                try self.debugSuffix(span, scope);
            },
            .unreachable_terminator => {
                try self.output.writer.writeAll("  unreachable");
                try self.debugSuffix(span, scope);
            },
            else => return error.UnsupportedTerminator,
        }
    }

    fn writeMain(self: *Emitter) !void {
        const scope = 4 + self.program.functions.len;
        try self.output.writer.print("define i32 @main() !dbg !{d} {{\nentry:\n", .{scope});
        try self.output.writer.writeAll("  %runtime.status = call i32 @lnako_aot_runtime_init()\n");
        for (self.globals.items, 0..) |_, global_index| {
            try self.output.writer.print("  %global.root.frame.{d} = alloca %lnako.RootFrame\n", .{global_index});
            try self.output.writer.print("  call void @lnako_aot_push_roots(ptr %global.root.frame.{d}, ptr @lnako.global.{d}, i64 1)\n", .{ global_index, global_index });
        }
        var index = self.program.module_entries.len;
        var call_index: usize = 0;
        while (index > 0) {
            index -= 1;
            try self.output.writer.print("  %entry.result.{d} = call %lnako.Value @lnako.fn.{d}()", .{ call_index, self.program.module_entries[index] });
            try self.debugSuffix(ast.emptySpan(), scope);
            call_index += 1;
        }
        var global_index = self.globals.items.len;
        while (global_index > 0) {
            global_index -= 1;
            try self.output.writer.print("  call void @lnako_aot_pop_roots(ptr %global.root.frame.{d})\n", .{global_index});
        }
        try self.output.writer.writeAll("  call void @lnako_aot_runtime_deinit()\n  ret i32 0");
        try self.debugSuffix(ast.emptySpan(), scope);
        try self.output.writer.writeAll("}\n\n");
    }

    fn writeDebugMetadata(self: *Emitter) !void {
        const writer = &self.output.writer;
        const file_name = std.fs.path.basename(self.source_path);
        const directory = std.fs.path.dirname(self.source_path) orelse ".";
        try writer.writeAll("!llvm.dbg.cu = !{!0}\n");
        const flags_start = self.next_metadata;
        try writer.print("!llvm.module.flags = !{{!{d}, !{d}}}\n", .{ flags_start, flags_start + 1 });
        try writer.print("!llvm.ident = !{{!{d}}}\n\n", .{flags_start + 2});
        try writer.writeAll("!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: \"lnako Zig+LLVM 22.1.8\", isOptimized: ");
        try writer.writeAll(if (self.optimized) "true" else "false");
        try writer.writeAll(", runtimeVersion: 0, emissionKind: FullDebug)\n!1 = !DIFile(filename: \"");
        try writeMetadataString(writer, file_name);
        try writer.writeAll("\", directory: \"");
        try writeMetadataString(writer, directory);
        try writer.writeAll("\")\n!2 = !DISubroutineType(types: !3)\n!3 = !{}\n");
        for (self.program.functions) |function| {
            const scope = 4 + function.id;
            try writer.print("!{d} = distinct !DISubprogram(name: \"", .{scope});
            try writeMetadataString(writer, function.name);
            try writer.print("\", linkageName: \"lnako.fn.{d}\", scope: !1, file: !1, line: 1, type: !2, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !0)\n", .{function.id});
        }
        const main_scope = 4 + self.program.functions.len;
        try writer.print("!{d} = distinct !DISubprogram(name: \"main\", linkageName: \"main\", scope: !1, file: !1, line: 1, type: !2, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !0)\n", .{main_scope});
        for (self.locations.items) |location| try writer.print("!{d} = !DILocation(line: {d}, column: {d}, scope: !{d})\n", .{ location.id, location.line, location.column, location.scope });
        try writer.print("!{d} = !{{i32 2, !\"Dwarf Version\", i32 4}}\n", .{flags_start});
        try writer.print("!{d} = !{{i32 2, !\"Debug Info Version\", i32 3}}\n", .{flags_start + 1});
        try writer.print("!{d} = !{{!\"lnako 0.0.0-dev\"}}\n", .{flags_start + 2});
    }

    fn debugSuffix(self: *Emitter, span: ast.Span, scope: usize) !void {
        const id = self.next_metadata;
        self.next_metadata += 1;
        try self.locations.append(self.allocator, .{ .id = id, .line = span.line + 1, .column = @max(@as(usize, 1), span.column), .scope = scope });
        try self.output.writer.print(", !dbg !{d}\n", .{id});
    }

    fn writeBoxConstant(self: *Emitter, id: ir.ValueId, tag: u8, payload: u64, span: ast.Span, scope: usize) !void {
        try self.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 {d}, i64 0 }}, i64 {d}, 1", .{ id, tag, payload });
        try self.debugSuffix(span, scope);
    }

    fn writeValueRef(self: *Emitter, function: ir.Function, value: ir.ValueId) !void {
        for (function.parameters, 0..) |parameter, index| if (parameter.value == value) {
            try self.output.writer.print("%arg.{d}", .{index});
            return;
        };
        try self.output.writer.print("%v{d}", .{value});
    }

    fn writeNumberOperand(self: *Emitter, function: ir.Function, value: ir.ValueId, label: []const u8, span: ast.Span, scope: usize) !void {
        if (self.optimized and valueType(function, value) == .number) {
            try self.output.writer.print("  %{s}.bits = extractvalue %lnako.Value ", .{label});
            try self.writeValueRef(function, value);
            try self.output.writer.writeAll(", 1");
            try self.debugSuffix(span, scope);
            try self.output.writer.print("  %{s} = bitcast i64 %{s}.bits to double", .{ label, label });
            try self.debugSuffix(span, scope);
            return;
        }
        try self.output.writer.print("  %{s} = call double @lnako.to_number(%lnako.Value ", .{label});
        try self.writeValueRef(function, value);
        try self.output.writer.writeByte(')');
        try self.debugSuffix(span, scope);
    }

    fn writeTruthyOperand(self: *Emitter, function: ir.Function, value: ir.ValueId, label: []const u8, span: ast.Span, scope: usize) !void {
        const value_type = valueType(function, value);
        if (self.optimized and value_type == .boolean) {
            try self.output.writer.print("  %{s}.bits = extractvalue %lnako.Value ", .{label});
            try self.writeValueRef(function, value);
            try self.output.writer.writeAll(", 1");
            try self.debugSuffix(span, scope);
            try self.output.writer.print("  %{s} = trunc i64 %{s}.bits to i1", .{ label, label });
            try self.debugSuffix(span, scope);
            return;
        }
        if (self.optimized and value_type == .number) {
            try self.output.writer.print("  %{s}.bits = extractvalue %lnako.Value ", .{label});
            try self.writeValueRef(function, value);
            try self.output.writer.writeAll(", 1");
            try self.debugSuffix(span, scope);
            try self.output.writer.print("  %{s}.number = bitcast i64 %{s}.bits to double", .{ label, label });
            try self.debugSuffix(span, scope);
            try self.output.writer.print("  %{s} = fcmp one double %{s}.number, 0.000000e+00", .{ label, label });
            try self.debugSuffix(span, scope);
            return;
        }
        try self.output.writer.print("  %{s} = call i1 @lnako.truthy(%lnako.Value ", .{label});
        try self.writeValueRef(function, value);
        try self.output.writer.writeByte(')');
        try self.debugSuffix(span, scope);
    }

    fn localNames(self: *Emitter, function: ir.Function) ![][]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        for (function.parameters) |parameter| if (nameIndex(names.items, parameter.name) == null) try names.append(self.allocator, parameter.name);
        for (function.blocks) |block| for (block.instructions) |instruction| {
            if ((instruction.opcode == .load_local or instruction.opcode == .store_local) and nameIndex(names.items, instruction.name) == null) {
                try names.append(self.allocator, instruction.name);
            }
            if (instruction.opcode == .destructure_store) for (instruction.names) |name| {
                if (!isQualifiedGlobal(name) and nameIndex(names.items, name) == null) try names.append(self.allocator, name);
            };
        };
        return self.allocator.dupe([]const u8, names.items);
    }

    fn globalIndex(self: Emitter, name: []const u8) ?usize {
        return nameIndex(self.globals.items, name);
    }

    fn stringIndex(self: Emitter, function_id: ir.FunctionId, value_id: ir.ValueId) ?usize {
        for (self.strings.items) |constant| if (constant.function_id == function_id and constant.value_id == value_id) return constant.index;
        return null;
    }

    fn findFunction(self: Emitter, name: []const u8) ?ir.Function {
        return lookupFunction(self.program, name);
    }
};

fn lookupFunction(program: ir.Program, name: []const u8) ?ir.Function {
    for (program.functions) |function| if (std.mem.eql(u8, function.name, name)) return function;
    return null;
}

fn validDirectCallee(program: ir.Program, instruction: ir.Instruction) bool {
    return if (instruction.direct_callee) |callee| callee < program.functions.len else false;
}

fn isDisplayCall(name: []const u8) bool {
    return std.mem.eql(u8, name, "表示") or std.mem.eql(u8, name, "表示する") or std.mem.eql(u8, name, "連続表示");
}

fn nameIndex(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
    return null;
}

fn valueType(function: ir.Function, value: ir.ValueId) ir.Type {
    for (function.parameters) |parameter| if (parameter.value == value) return parameter.type;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result) |result| if (result == value) return instruction.type;
    };
    return .dynamic;
}

fn functionValueCount(function: ir.Function) usize {
    var count: usize = 0;
    for (function.parameters) |parameter| count = @max(count, @as(usize, parameter.value) + 1);
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result) |result| count = @max(count, @as(usize, result) + 1);
    };
    return count;
}

fn maxAggregateOperandCount(function: ir.Function) usize {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| switch (instruction.opcode) {
        .make_array, .make_object, .iterator_begin => count = @max(count, instruction.operands.len),
        else => {},
    };
    return count;
}

fn instructionForValue(function: ir.Function, value: ir.ValueId) ?ir.Instruction {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result) |result| if (result == value) return instruction;
    };
    return null;
}

fn iteratorSourceSupported(function: ir.Function, instruction: ir.Instruction) bool {
    if (instruction.operands.len == 0) return false;
    if (instruction.name.len > 0 and instruction.operands.len >= 2) return true;
    return switch (valueType(function, instruction.operands[0])) {
        .number, .array, .object => true,
        else => false,
    };
}

fn destructureSourceSupported(function: ir.Function, instruction: ir.Instruction) bool {
    return instruction.operands.len == 1 and valueType(function, instruction.operands[0]) == .array;
}

fn isQualifiedGlobal(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "__") != null;
}

fn arithmeticOpcode(operator: []const u8) ?[]const u8 {
    const entries = [_]struct { operator: []const u8, opcode: []const u8 }{
        .{ .operator = "+", .opcode = "fadd" },
        .{ .operator = "-", .opcode = "fsub" },
        .{ .operator = "*", .opcode = "fmul" },
        .{ .operator = "/", .opcode = "fdiv" },
        .{ .operator = "÷", .opcode = "fdiv" },
        .{ .operator = "%", .opcode = "frem" },
        .{ .operator = "**", .opcode = "pow" },
    };
    for (entries) |entry| if (std.mem.eql(u8, operator, entry.operator)) return entry.opcode;
    return null;
}

fn comparisonPredicate(operator: []const u8) ?[]const u8 {
    const entries = [_]struct { operator: []const u8, predicate: []const u8 }{
        .{ .operator = "==", .predicate = "oeq" },    .{ .operator = "=", .predicate = "oeq" },   .{ .operator = "eq", .predicate = "oeq" },
        .{ .operator = "===", .predicate = "oeq" },   .{ .operator = "!=", .predicate = "une" },
        .{ .operator = "≠", .predicate = "une" },
        .{ .operator = "noteq", .predicate = "une" }, .{ .operator = "!==", .predicate = "une" }, .{ .operator = "<", .predicate = "olt" },
        .{ .operator = "lt", .predicate = "olt" },    .{ .operator = "<=", .predicate = "ole" },  .{ .operator = "lteq", .predicate = "ole" },
        .{ .operator = ">", .predicate = "ogt" },     .{ .operator = "gt", .predicate = "ogt" },  .{ .operator = ">=", .predicate = "oge" },
        .{ .operator = "gteq", .predicate = "oge" },
    };
    for (entries) |entry| if (std.mem.eql(u8, operator, entry.operator)) return entry.predicate;
    return null;
}

fn writeLlvmString(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        if (byte >= 0x20 and byte <= 0x7e and byte != '"' and byte != '\\') {
            try writer.writeByte(byte);
        } else try writer.print("\\{X:0>2}", .{byte});
    }
}

fn writeMetadataString(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '"', '\\' => try writer.print("\\{c}", .{byte}),
        '\n', '\r' => try writer.writeByte(' '),
        else => try writer.writeByte(byte),
    };
}

test "Nako SSA IRをデバッグ情報付きLLVM IRへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=1\nB=A+2\nBを表示\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "main.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "define i32 @main()") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call i32 @lnako_aot_runtime_init()") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_runtime_deinit()") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.global.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "!llvm.dbg.cu") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "!DILocation(line: 1") != null);
}

test "配列と辞書をルート付きAOTランタイム呼び出しへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "A=[1,2]\nA[1]=5\nA[1]を表示\nB={\"x\":7}\nB@\"x\"を表示\n変数[C,D]=[8,9]\nCを表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "collections.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "collections.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "collections.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "collections.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_push_roots") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_pop_roots") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_array_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_dictionary_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_index_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_index_set") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_index_get(ptr, ptr, ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "ptr %runtime.scratch") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare %lnako.Value @lnako_aot_") == null);
}

test "回数・範囲・コレクション反復をAOTイテレーターへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "2回\n回数を表示\nここまで\nNを1から2まで繰り返す\nNを表示\nここまで\n[3,4]を反復\n対象を表示\nここまで\n";
    var parsed = try parser.parse(std.testing.allocator, source, "iterators.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "iterators.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "iterators.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "iterators.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_iterator_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_iterator_has_next") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_iterator_next") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "ptr @lnako.global.") != null);
}

test "未実装の文字列反復をAOT対応として扱わない" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "「ab」を反復\n対象を表示\nここまで\n", "string-iterator.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "string-iterator.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "string-iterator.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const unsupported = findUnsupported(program) orelse return error.ExpectedUnsupportedIterator;
    try std.testing.expectEqualStrings("iterator_begin", unsupported.opcode);
}

test "O1では証明済み数値と真偽判定をアンボックスしO0のIRを変更しない" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const optimizer = @import("../../ir/optimizer.zig");
    const source = "●(Aを)Fとは\nB=A+1\nもしAならば\nBで戻る\n違えば\n0で戻る\nここまで\nここまで\nX=F(2)\nXを表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "optimized.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "optimized.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "optimized.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var optimized_program = try program.clone(std.testing.allocator);
    defer optimized_program.deinit();

    _ = try optimizer.optimize(std.testing.allocator, &optimized_program, .{});
    try std.testing.expectEqual(ir.Type.dynamic, program.findFunction("optimized__F").?.parameters[0].type);
    try std.testing.expectEqual(ir.Type.number, optimized_program.findFunction("optimized__F").?.parameters[0].type);

    var unoptimized_module = try generate(std.testing.allocator, program, "optimized.nako3", false);
    defer unoptimized_module.deinit(std.testing.allocator);
    var optimized_module = try generate(std.testing.allocator, optimized_program, "optimized.nako3", true);
    defer optimized_module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, unoptimized_module.text, "call double @lnako.to_number") != null);
    try std.testing.expect(std.mem.indexOf(u8, unoptimized_module.text, "call i1 @lnako.truthy") != null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, "call double @lnako.to_number") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, "call i1 @lnako.truthy") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, ".bits = extractvalue %lnako.Value") != null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, ".number = bitcast i64") != null);
}
