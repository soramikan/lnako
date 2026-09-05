const std = @import("std");
const ir = @import("../../../../ir/nako_ir.zig");
const ast = @import("../../../../frontend/ast.zig");
const aot_abi = @import("../../../../runtime/aot_abi.zig");
const aot_builtin = @import("../../../../runtime/aot_builtin.zig");
const system_constant = @import("../../../../runtime/system_constant.zig");
const shared = @import("../shared.zig");

const StringConstant = shared.StringConstant;
const DebugPathConstant = shared.DebugPathConstant;
const SystemStringConstant = shared.SystemStringConstant;
const BigIntConstant = shared.BigIntConstant;
const DebugLocation = shared.DebugLocation;
const isDisplayCall = shared.isDisplayCall;
const isNativePluginCall = shared.isNativePluginCall;
const isQualifiedGlobal = shared.isQualifiedGlobal;
const lookupFunction = shared.lookupFunction;
const valueType = shared.valueType;

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    program: ir.Program,
    source_path: []const u8,
    optimized: bool,
    output: std.Io.Writer.Allocating,
    globals: std.ArrayList([]const u8) = .empty,
    strings: std.ArrayList(StringConstant) = .empty,
    debug_paths: std.ArrayList(DebugPathConstant) = .empty,
    system_strings: std.ArrayList(SystemStringConstant) = .empty,
    native_plugin_names: std.ArrayList([]const u8) = .empty,
    system_arrays: std.ArrayList(usize) = .empty,
    system_dictionaries: std.ArrayList(usize) = .empty,
    system_era_data: std.ArrayList(usize) = .empty,
    bigints: std.ArrayList(BigIntConstant) = .empty,
    locations: std.ArrayList(DebugLocation) = .empty,
    next_metadata: usize = 4,

    pub fn deinit(self: *Emitter) void {
        self.globals.deinit(self.allocator);
        for (self.strings.items) |constant| self.allocator.free(constant.units);
        self.strings.deinit(self.allocator);
        self.debug_paths.deinit(self.allocator);
        for (self.system_strings.items) |constant| self.allocator.free(constant.units);
        self.system_strings.deinit(self.allocator);
        self.native_plugin_names.deinit(self.allocator);
        self.system_arrays.deinit(self.allocator);
        self.system_dictionaries.deinit(self.allocator);
        self.system_era_data.deinit(self.allocator);
        self.bigints.deinit(self.allocator);
        self.locations.deinit(self.allocator);
        self.output.deinit();
    }

    pub fn debugSuffix(self: *Emitter, span: ast.Span, scope: usize) !void {
        const id = self.next_metadata;
        self.next_metadata += 1;
        try self.locations.append(self.allocator, .{ .id = id, .line = span.line + 1, .column = @max(@as(usize, 1), span.column), .scope = scope });
        try self.output.writer.print(", !dbg !{d}\n", .{id});
    }

    pub fn localNames(self: *Emitter, function: ir.Function) ![][]const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.allocator);
        for (function.captures) |capture| if (nameIndex(names.items, capture) == null) try names.append(self.allocator, capture);
        for (function.parameters) |parameter| if (nameIndex(names.items, parameter.name) == null) try names.append(self.allocator, parameter.name);
        for (function.blocks) |block| for (block.instructions) |instruction| {
            if ((instruction.opcode == .load_local or instruction.opcode == .store_local) and nameIndex(names.items, instruction.name) == null) {
                try names.append(self.allocator, instruction.name);
            }
            if (instruction.opcode == .destructure_store) for (instruction.names) |name| {
                if (!isQualifiedGlobal(name) and nameIndex(names.items, name) == null) try names.append(self.allocator, name);
            };
            if (instruction.opcode == .increment and !isQualifiedGlobal(instruction.name) and nameIndex(names.items, instruction.name) == null) {
                try names.append(self.allocator, instruction.name);
            }
        };
        return self.allocator.dupe([]const u8, names.items);
    }

    pub fn globalIndex(self: Emitter, name: []const u8) ?usize {
        return nameIndex(self.globals.items, name);
    }

    pub fn nativePluginNameIndex(self: Emitter, name: []const u8) ?usize {
        for (self.native_plugin_names.items, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
        return null;
    }

    pub fn hasBuiltinCall(self: Emitter, command: aot_builtin.Command) bool {
        for (self.program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
            if (instruction.opcode != .call or instruction.direct_callee != null or !instruction.is_builtin_call) continue;
            if (aot_builtin.lookup(instruction.name) == command) return true;
        };
        return false;
    }

    pub fn hasDynamicBuiltin(self: Emitter) bool {
        return self.hasBuiltinCall(.system_nadesiko) or self.hasBuiltinCall(.system_nadesiko_continue);
    }

    pub fn needsNodeMotherPath(self: Emitter) bool {
        return self.globalIndex("母艦パス") != null or self.hasBuiltinCall(.node_mother_path);
    }

    pub fn systemStringValue(self: Emitter, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "名前空間")) return primaryModuleName(self.program);
        if (self.program.http_server_plugin_imported and
            (std.mem.eql(u8, name, "HTTPメソッド") or std.mem.eql(u8, name, "GETデータ") or
                std.mem.eql(u8, name, "POSTデータ") or std.mem.eql(u8, name, "FILESデータ"))) return "";
        return system_constant.lookupString(name);
    }

    pub fn sourcePathForFunction(self: Emitter, function_name: []const u8) []const u8 {
        var best: ?usize = null;
        for (self.program.module_names, 0..) |module_name, index| {
            if (index >= self.program.module_paths.len or !std.mem.startsWith(u8, function_name, module_name)) continue;
            if (function_name.len <= module_name.len + 1 or !std.mem.eql(u8, function_name[module_name.len .. module_name.len + 2], "__")) continue;
            if (best == null or module_name.len > self.program.module_names[best.?].len) best = index;
        }
        return if (best) |index| self.program.module_paths[index] else self.source_path;
    }

    pub fn debugPathIndex(self: Emitter, path: []const u8) ?usize {
        for (self.debug_paths.items, 0..) |constant, index| if (std.mem.eql(u8, constant.path, path)) return index;
        return null;
    }

    pub fn stringConstant(self: Emitter, function_id: ir.FunctionId, value_id: ir.ValueId) ?StringConstant {
        for (self.strings.items) |constant| if (constant.function_id == function_id and constant.value_id == value_id) return constant;
        return null;
    }

    pub fn bigintConstant(self: Emitter, function_id: ir.FunctionId, value_id: ir.ValueId) ?BigIntConstant {
        for (self.bigints.items) |constant| if (constant.function_id == function_id and constant.value_id == value_id) return constant;
        return null;
    }

    pub fn findFunction(self: Emitter, name: []const u8) ?ir.Function {
        return lookupFunction(self.program, name);
    }
};

pub fn primaryModuleName(program: ir.Program) []const u8 {
    if (program.module_entries.len == 0) return "";
    const function_id = program.module_entries[0];
    if (function_id >= program.functions.len) return "";
    const name = program.functions[function_id].name;
    const suffix = "__$entry";
    if (!std.mem.endsWith(u8, name, suffix)) return "";
    return name[0 .. name.len - suffix.len];
}

pub fn parameterIndex(function: ir.Function, name: []const u8) ?usize {
    for (function.parameters, 0..) |parameter, index| if (std.mem.eql(u8, parameter.name, name)) return index;
    return null;
}

pub fn maxClosureCaptureCount(program: ir.Program, function: ir.Function) usize {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .make_closure) continue;
        const closure = lookupFunction(program, instruction.name) orelse continue;
        count = @max(count, closure.captures.len);
    };
    return count;
}

pub fn isStdioCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .stdio_continue_display, .stdio_continue_display_many, .stdio_clear_log, .stdio_write_all => true,
        else => false,
    };
}

pub fn isTimerCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .timer_after, .timer_every, .timer_stop, .timer_stop_all => true,
        else => false,
    };
}

pub fn isPromiseCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .promise_create, .promise_success, .promise_settled, .promise_failure, .promise_finally, .promise_all => true,
        else => false,
    };
}

pub fn isHttpServerCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .http_server_start, .http_server_static, .http_server_receive, .http_server_output, .http_server_headers, .http_server_redirect => true,
        else => false,
    };
}

pub fn isArchiveCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_archive_extract, .node_archive_extract_callback, .node_archive_create, .node_archive_create_callback => true,
        else => false,
    };
}

pub fn isNodeProcessCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_process_run_wait, .node_process_run, .node_process_start, .node_process_run_wait_output, .node_process_start_callback, .node_open_external_browser, .node_open_external_explorer => true,
        else => false,
    };
}

pub fn isNodeFileCallbackCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_file_process_callback, .node_file_process_stop, .node_file_copy_callback, .node_file_move_callback, .node_file_delete_callback => true,
        else => false,
    };
}

pub fn isNodeHttpCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_ajax_send_callback, .node_ajax_receive_callback, .node_get_send_callback, .node_post_send_callback, .node_post_form_send_callback, .node_ajax_response_promise, .node_http_response_promise, .node_get_response_promise, .node_post_response_promise, .node_post_form_response_promise, .node_ajax_content_get, .node_ajax_receive, .node_post_send, .node_post_form_send, .node_ajax_text_get, .node_ajax_json_get, .node_ajax_binary_get, .node_discord_send, .node_discord_file_send => true,
        else => false,
    };
}

pub fn isPluginManagementCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .plugin_name_set, .namespace_set, .namespace_pop => true,
        else => false,
    };
}

pub fn isNodeFileOperationCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_file_list, .node_file_list_all, .node_folder_create, .node_file_copy, .node_file_copy_overwrite, .node_file_move, .node_file_move_overwrite, .node_file_delete => true,
        else => false,
    };
}

pub fn requiresDisplayLog(name: []const u8) bool {
    if (isDisplayCall(name)) return true;
    return if (aot_builtin.lookup(name)) |command| isStdioCommand(command) or command == .system_debug_display or command == .system_hatena_execute else false;
}

pub fn nameIndex(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
    return null;
}

pub fn functionValueCount(function: ir.Function) usize {
    var count: usize = 0;
    for (function.parameters) |parameter| count = @max(count, @as(usize, parameter.value) + 1);
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result) |result| count = @max(count, @as(usize, result) + 1);
    };
    return count;
}

pub fn maxAggregateOperandCount(function: ir.Function) usize {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| switch (instruction.opcode) {
        .make_array, .make_object, .iterator_begin, .call => count = @max(count, instruction.operands.len),
        .call_value => if (instruction.operands.len > 0) {
            count = @max(count, instruction.operands.len - 1);
        },
        else => {},
    };
    return count;
}

pub fn instructionForValue(function: ir.Function, value: ir.ValueId) ?ir.Instruction {
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.result) |result| if (result == value) return instruction;
    };
    return null;
}

pub const DynamicCallTarget = union(enum) { name: []const u8, value: ir.ValueId };

pub fn isNamedGlobalFunction(name: []const u8) bool {
    return !std.mem.endsWith(u8, name, "__$entry") and std.mem.indexOf(u8, name, "__lambda$") == null;
}

pub fn runtimeArithmeticOpcode(operator: []const u8) ?u8 {
    const entries = [_]struct { operator: []const u8, opcode: u8 }{
        .{ .operator = "+", .opcode = 0 },
        .{ .operator = "-", .opcode = 1 },
        .{ .operator = "*", .opcode = 2 },
        .{ .operator = "/", .opcode = 3 },
        .{ .operator = "÷", .opcode = 3 },
        .{ .operator = "÷÷", .opcode = 6 },
        .{ .operator = "%", .opcode = 4 },
        .{ .operator = "**", .opcode = 5 },
    };
    for (entries) |entry| if (std.mem.eql(u8, operator, entry.operator)) return entry.opcode;
    return null;
}

pub fn comparisonOpcode(operator: []const u8) ?u8 {
    const entries = [_]struct { operator: []const u8, opcode: u8 }{
        .{ .operator = "==", .opcode = 0 },
        .{ .operator = "=", .opcode = 0 },
        .{ .operator = "eq", .opcode = 0 },
        .{ .operator = "===", .opcode = 1 },
        .{ .operator = "!=", .opcode = 2 },
        .{ .operator = "≠", .opcode = 2 },
        .{ .operator = "noteq", .opcode = 2 },
        .{ .operator = "!==", .opcode = 3 },
        .{ .operator = "<", .opcode = 4 },
        .{ .operator = "lt", .opcode = 4 },
        .{ .operator = "<=", .opcode = 5 },
        .{ .operator = "lteq", .opcode = 5 },
        .{ .operator = ">", .opcode = 6 },
        .{ .operator = "gt", .opcode = 6 },
        .{ .operator = ">=", .opcode = 7 },
        .{ .operator = "gteq", .opcode = 7 },
    };
    for (entries) |entry| if (std.mem.eql(u8, operator, entry.operator)) return entry.opcode;
    return null;
}

pub fn writeMetadataString(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '"', '\\' => try writer.print("\\{c}", .{byte}),
        '\n', '\r' => try writer.writeByte(' '),
        else => try writer.writeByte(byte),
    };
}

pub fn writeScalarInitializer(writer: *std.Io.Writer, scalar: ?system_constant.Scalar) !void {
    const value = scalar orelse return writer.writeAll("{ i8 0, i64 0 }");
    switch (value) {
        .undefined => try writer.print("{{ i8 {d}, i64 0 }}", .{@intFromEnum(aot_abi.Tag.undefined)}),
        .null_value => try writer.print("{{ i8 {d}, i64 0 }}", .{@intFromEnum(aot_abi.Tag.null_value)}),
        .boolean => |boolean| try writer.print("{{ i8 {d}, i64 {d} }}", .{ @intFromEnum(aot_abi.Tag.boolean), @intFromBool(boolean) }),
        .number => |number| try writer.print("{{ i8 {d}, i64 {d} }}", .{ @intFromEnum(aot_abi.Tag.number), @as(u64, @bitCast(number)) }),
    }
}
