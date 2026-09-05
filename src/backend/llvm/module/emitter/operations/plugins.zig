const std = @import("std");
const target_builtin = @import("builtin");
const ir = @import("../../../../../ir/nako_ir.zig");
const ast = @import("../../../../../frontend/ast.zig");
const aot_abi = @import("../../../../../runtime/aot_abi.zig");
const aot_builtin = @import("../../../../../runtime/aot_builtin.zig");
const system_constant = @import("../../../../../runtime/system_constant.zig");
const shared = @import("../../shared.zig");
const context = @import("../context.zig");
const Emitter = context.Emitter;
const StringConstant = shared.StringConstant;
const DebugPathConstant = shared.DebugPathConstant;
const SystemStringConstant = shared.SystemStringConstant;
const BigIntConstant = shared.BigIntConstant;
const DebugLocation = shared.DebugLocation;
const arithmeticOpcode = shared.arithmeticOpcode;
const isDisplayCall = shared.isDisplayCall;
const isNativePluginCall = shared.isNativePluginCall;
const isQualifiedGlobal = shared.isQualifiedGlobal;
const lookupFunction = shared.lookupFunction;
const shiftOpcode = shared.shiftOpcode;
const valueType = shared.valueType;
const constants_mod = @import("constants.zig");
const collections_mod = @import("collections.zig");
const variables_mod = @import("variables.zig");
const control_mod = @import("control.zig");
const arithmetic_mod = @import("arithmetic.zig");
const calls_mod = @import("calls.zig");
const plugins_mod = @import("plugins.zig");
const instruction_router_mod = @import("../instruction_router.zig");
const terminators_mod = @import("../terminators.zig");
const functions_mod = @import("../functions.zig");
const preamble_mod = @import("../preamble.zig");
const declarations_mod = @import("../declarations.zig");

pub fn writeDisplayCall(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    const site_id = instruction.site_id orelse return error.MissingDispatchSiteId;
    const display_log_index = emitter.globalIndex("表示ログ") orelse return error.MissingDisplayLogGlobal;
    if (std.mem.eql(u8, instruction.name, "連続表示")) {
        if (instruction.operands.len > aggregate_count) return error.InvalidCallScratch;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %display.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %display.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  %v{d} = call %lnako.Value @lnako.display_many(ptr ", .{result});
        if (instruction.operands.len > 0) try emitter.output.writer.print("%display.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i64 {d}, ptr @lnako.global.{d})", .{ instruction.operands.len, site_id, display_log_index });
    } else {
        if (instruction.operands.len == 0) return error.InvalidCall;
        try emitter.output.writer.print("  %v{d} = call %lnako.Value @lnako.display(%lnako.Value ", .{result});
        try constants_mod.writeValueRef(emitter, function, instruction.operands[instruction.operands.len - 1]);
        try emitter.output.writer.print(", i1 true, i64 {d}, ptr @lnako.global.{d})", .{ site_id, display_log_index });
    }
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeBuiltinCall(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize, command: aot_builtin.Command) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    const site_id = instruction.site_id orelse return error.MissingDispatchSiteId;
    if (instruction.operands.len > aggregate_count) return error.InvalidCallScratch;
    if (command == .system_nadesiko or command == .system_nadesiko_continue) {
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %dynamic.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %dynamic.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_dynamic_call(ptr %root.slot.{d}, ptr ", .{result});
        if (instruction.operands.len > 0) {
            try emitter.output.writer.print("%dynamic.{d}.slot.0", .{result});
        } else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (command == .system_debug_display or command == .system_hatena_execute) {
        const display_log_index = emitter.globalIndex("表示ログ") orelse return error.MissingDisplayLogGlobal;
        const source_path = emitter.sourcePathForFunction(function.name);
        const path_index = emitter.debugPathIndex(source_path) orelse return error.MissingDebugSourcePath;
        const runtime_name = if (command == .system_hatena_execute) "lnako_aot_hatena_execute" else "lnako_aot_debug_display";
        if (instruction.operands.len > 0) {
            try emitter.output.writer.print("  %debug-display.{d}.slot.0 = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 0", .{ result, aggregate_count });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, instruction.operands[instruction.operands.len - 1]);
            try emitter.output.writer.print(", ptr %debug-display.{d}.slot.0", .{result});
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @{s}(ptr %root.slot.{d}, ptr ", .{ runtime_name, result });
        if (instruction.operands.len > 0) {
            try emitter.output.writer.print("%debug-display.{d}.slot.0", .{result});
        } else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, ptr @lnako.debug.path.{d}, i64 {d}, ptr @lnako.global.{d}, i64 {d})", .{
            instruction.span.line + 1,
            path_index,
            source_path.len,
            display_log_index,
            site_id,
        });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (command == .system_debug_breakpoint_wait) {
        const breakpoints_index = emitter.globalIndex("__DEBUGブレイクポイント一覧") orelse return error.MissingDebugBreakpointsGlobal;
        const force_wait_index = emitter.globalIndex("__DEBUG強制待機") orelse return error.MissingDebugForceWaitGlobal;
        const wait_flag_index = emitter.globalIndex("__DEBUG待機フラグ") orelse return error.MissingDebugWaitFlagGlobal;
        const plugin_name_index = emitter.globalIndex("プラグイン名") orelse return error.MissingPluginNameGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %debug-breakpoint-wait.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %debug-breakpoint-wait.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_debug_breakpoint_wait_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr ", .{ result, breakpoints_index, force_wait_index, wait_flag_index, plugin_name_index });
        if (instruction.operands.len > 0) try emitter.output.writer.print("%debug-breakpoint-wait.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (context.isTimerCommand(command)) {
        const target_index = emitter.globalIndex("対象") orelse return error.MissingTargetGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %timer.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %timer.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_timer_call_site(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, target_index });
        if (instruction.operands.len > 0) {
            try emitter.output.writer.print("%timer.{d}.slot.0", .{result});
        } else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (command == .node_stdin_callback) {
        const target_index = emitter.globalIndex("対象") orelse return error.MissingTargetGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %node-stdin-callback.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %node-stdin-callback.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_node_stdin_callback_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, target_index });
        if (instruction.operands.len > 0) {
            try emitter.output.writer.print("%node-stdin-callback.{d}.slot.0", .{result});
        } else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (context.isHttpServerCommand(command)) {
        const method_index = emitter.globalIndex("HTTPメソッド") orelse return error.MissingHttpMethodGlobal;
        const get_index = emitter.globalIndex("GETデータ") orelse return error.MissingGetDataGlobal;
        const post_index = emitter.globalIndex("POSTデータ") orelse return error.MissingPostDataGlobal;
        const files_index = emitter.globalIndex("FILESデータ") orelse return error.MissingFilesDataGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %http-server.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %http-server.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_http_server_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr ", .{ result, method_index, get_index, post_index, files_index });
        if (instruction.operands.len > 0) try emitter.output.writer.print("%http-server.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (context.isPromiseCommand(command)) {
        const last_promise_index = emitter.globalIndex("そ") orelse return error.MissingLastPromiseGlobal;
        const target_index = emitter.globalIndex("対象") orelse return error.MissingTargetGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %promise.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %promise.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_promise_call_site(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr ", .{ result, last_promise_index, target_index });
        if (instruction.operands.len > 0) {
            try emitter.output.writer.print("%promise.{d}.slot.0", .{result});
        } else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (context.isPluginManagementCommand(command)) {
        const plugin_name_index = emitter.globalIndex("プラグイン名") orelse return error.MissingPluginNameGlobal;
        const namespace_index = emitter.globalIndex("名前空間") orelse return error.MissingNamespaceGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %plugin-management.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %plugin-management.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_plugin_management_call(ptr %root.slot.{d}, ptr ", .{result});
        if (instruction.operands.len > 0) try emitter.output.writer.print("%plugin-management.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, i64 {d})", .{
            instruction.operands.len,
            @intFromEnum(command),
            plugin_name_index,
            namespace_index,
            site_id,
        });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (command == .node_archive_tool_path_set) {
        const archive_tool_path_index = emitter.globalIndex("圧縮解凍ツールパス") orelse return error.MissingArchiveToolPathGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %archive-tool-path.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %archive-tool-path.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_archive_tool_path_set(ptr %root.slot.{d}, ptr ", .{result});
        if (instruction.operands.len > 0) try emitter.output.writer.print("%archive-tool-path.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, ptr @lnako.global.{d}, i64 {d})", .{ instruction.operands.len, archive_tool_path_index, site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (context.isArchiveCommand(command)) {
        const archive_tool_path_index = emitter.globalIndex("圧縮解凍ツールパス") orelse return error.MissingArchiveToolPathGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %node-archive.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %node-archive.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_archive_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, archive_tool_path_index });
        if (instruction.operands.len > 0) try emitter.output.writer.print("%node-archive.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (context.isNodeProcessCommand(command)) {
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %node-process.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %node-process.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_node_process_call(ptr %root.slot.{d}, ptr ", .{result});
        if (instruction.operands.len > 0) try emitter.output.writer.print("%node-process.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (command == .node_ajax_options_set) {
        const ajax_options_index = emitter.globalIndex("AJAXオプション") orelse return error.MissingAjaxOptionsGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %ajax-options.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %ajax-options.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_ajax_options_set(ptr %root.slot.{d}, ptr ", .{result});
        if (instruction.operands.len > 0) try emitter.output.writer.print("%ajax-options.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, ptr @lnako.global.{d}, i64 {d})", .{ instruction.operands.len, ajax_options_index, site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (command == .node_ajax_onerror_set) {
        const ajax_onerror_index = emitter.globalIndex("AJAX:ONERROR") orelse return error.MissingAjaxOnerrorGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %ajax-onerror.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %ajax-onerror.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_ajax_onerror_set(ptr %root.slot.{d}, ptr ", .{result});
        if (instruction.operands.len > 0) try emitter.output.writer.print("%ajax-onerror.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, ptr @lnako.global.{d}, i64 {d})", .{ instruction.operands.len, ajax_onerror_index, site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (context.isNodeHttpCommand(command)) {
        const ajax_options_index = emitter.globalIndex("AJAXオプション") orelse return error.MissingAjaxOptionsGlobal;
        const ajax_onerror_index = emitter.globalIndex("AJAX:ONERROR") orelse return error.MissingAjaxOnerrorGlobal;
        const target_index = emitter.globalIndex("対象") orelse return error.MissingTargetGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %node-http.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %node-http.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_node_http_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr ", .{ result, ajax_options_index, ajax_onerror_index, target_index });
        if (instruction.operands.len > 0) {
            try emitter.output.writer.print("%node-http.{d}.slot.0", .{result});
        } else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (context.isNodeFileOperationCommand(command)) {
        const copy_default_index = emitter.globalIndex("ファイルコピーデフォルト動作") orelse return error.MissingFileCopyDefaultGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %file-operation.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %file-operation.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_file_operation_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, copy_default_index });
        if (instruction.operands.len > 0) try emitter.output.writer.print("%file-operation.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (context.isNodeFileCallbackCommand(command)) {
        const target_index = emitter.globalIndex("対象") orelse return error.MissingTargetGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %file-callback.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %file-callback.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_node_file_callback_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, target_index });
        if (instruction.operands.len > 0) try emitter.output.writer.print("%file-callback.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    if (context.isStdioCommand(command)) {
        const display_log_index = emitter.globalIndex("表示ログ") orelse return error.MissingDisplayLogGlobal;
        for (instruction.operands, 0..) |argument, index| {
            try emitter.output.writer.print("  %stdio.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try emitter.debugSuffix(instruction.span, scope);
            try emitter.output.writer.writeAll("  store %lnako.Value ");
            try constants_mod.writeValueRef(emitter, function, argument);
            try emitter.output.writer.print(", ptr %stdio.{d}.slot.{d}", .{ result, index });
            try emitter.debugSuffix(instruction.span, scope);
        }
        try emitter.output.writer.print("  call void @lnako_aot_stdio_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, display_log_index });
        if (instruction.operands.len > 0) try emitter.output.writer.print("%stdio.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try emitter.debugSuffix(instruction.span, scope);
        return;
    }
    for (instruction.operands, 0..) |argument, index| {
        try emitter.output.writer.print("  %builtin.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.writeAll("  store %lnako.Value ");
        try constants_mod.writeValueRef(emitter, function, argument);
        try emitter.output.writer.print(", ptr %builtin.{d}.slot.{d}", .{ result, index });
        try emitter.debugSuffix(instruction.span, scope);
    }
    if (command == .cut or command == .cut_range) {
        const target_index = emitter.globalIndex("対象") orelse return error.MissingTargetGlobal;
        const mode: u8 = if (command == .cut) 0 else 1;
        try emitter.output.writer.print("  call void @lnako_aot_cut_site(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, target_index });
        if (instruction.operands.len > 0) {
            try emitter.output.writer.print("%builtin.{d}.slot.0", .{result});
        } else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i8 {d}, i64 {d})", .{ instruction.operands.len, mode, site_id });
    } else {
        try emitter.output.writer.print("  call void @lnako_aot_builtin_call_site(ptr %root.slot.{d}, ptr ", .{result});
        if (instruction.operands.len > 0) {
            try emitter.output.writer.print("%builtin.{d}.slot.0", .{result});
        } else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
    }
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

pub fn writeRegexpCall(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize, command: aot_builtin.Command) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    const site_id = instruction.site_id orelse return error.MissingDispatchSiteId;
    if (instruction.operands.len > aggregate_count) return error.InvalidCallScratch;
    for (instruction.operands, 0..) |argument, index| {
        try emitter.output.writer.print("  %regexp.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.writeAll("  store %lnako.Value ");
        try constants_mod.writeValueRef(emitter, function, argument);
        try emitter.output.writer.print(", ptr %regexp.{d}.slot.{d}", .{ result, index });
        try emitter.debugSuffix(instruction.span, scope);
    }
    try emitter.output.writer.print("  call void @lnako_aot_regexp_call_site(ptr %root.slot.{d}, ptr ", .{result});
    if (command == .regexp_match or command == .regexp_extract) {
        const captures_index = emitter.globalIndex("抽出文字列") orelse return error.MissingCaptureGlobal;
        try emitter.output.writer.print("@lnako.global.{d}", .{captures_index});
    } else try emitter.output.writer.writeAll("null");
    try emitter.output.writer.writeAll(", ptr ");
    if (instruction.operands.len > 0) try emitter.output.writer.print("%regexp.{d}.slot.0", .{result}) else try emitter.output.writer.writeAll("null");
    try emitter.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}

const DynamicCallTarget = union(enum) { name: []const u8, value: ir.ValueId };

pub fn writeNativePluginCall(emitter: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
    const result = instruction.result orelse return error.MissingInstructionResult;
    const name_index = emitter.nativePluginNameIndex(instruction.name) orelse return error.MissingNativePluginName;
    const site_id = instruction.site_id orelse 0;
    if (instruction.operands.len > aggregate_count) return error.InvalidCallScratch;
    for (instruction.operands, 0..) |argument, index| {
        try emitter.output.writer.print("  %native-plugin.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
        try emitter.debugSuffix(instruction.span, scope);
        try emitter.output.writer.writeAll("  store %lnako.Value ");
        try constants_mod.writeValueRef(emitter, function, argument);
        try emitter.output.writer.print(", ptr %native-plugin.{d}.slot.{d}", .{ result, index });
        try emitter.debugSuffix(instruction.span, scope);
    }
    try emitter.output.writer.print("  call void @lnako_aot_native_plugin_call(ptr %root.slot.{d}, ptr ", .{result});
    if (instruction.operands.len > 0) {
        try emitter.output.writer.print("%native-plugin.{d}.slot.0", .{result});
    } else try emitter.output.writer.writeAll("null");
    try emitter.output.writer.print(", i64 {d}, ptr @lnako.native.plugin.name.{d}, i64 {d}, i64 {d})", .{ instruction.operands.len, name_index, instruction.name.len, site_id });
    try emitter.debugSuffix(instruction.span, scope);
    try emitter.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
    try emitter.debugSuffix(instruction.span, scope);
}
