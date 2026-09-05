const std = @import("std");
const target_builtin = @import("builtin");
const ir = @import("../../../../ir/nako_ir.zig");
const ast = @import("../../../../frontend/ast.zig");
const aot_abi = @import("../../../../runtime/aot_abi.zig");
const aot_builtin = @import("../../../../runtime/aot_builtin.zig");
const system_constant = @import("../../../../runtime/system_constant.zig");
const shared = @import("../shared.zig");
const context = @import("context.zig");
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
const constants_mod = @import("operations/constants.zig");
const collections_mod = @import("operations/collections.zig");
const variables_mod = @import("operations/variables.zig");
const control_mod = @import("operations/control.zig");
const arithmetic_mod = @import("operations/arithmetic.zig");
const calls_mod = @import("operations/calls.zig");
const plugins_mod = @import("operations/plugins.zig");
const instruction_router_mod = @import("instruction_router.zig");
const terminators_mod = @import("terminators.zig");
const functions_mod = @import("functions.zig");
const preamble_mod = @import("preamble.zig");
const declarations_mod = @import("declarations.zig");

pub fn writeFunction(emitter: *Emitter, function: ir.Function) !void {
    const scope = 4 + function.id;
    try emitter.output.writer.print("define internal %lnako.Value @lnako.fn.{d}(ptr %context", .{function.id});
    for (function.parameters, 0..) |_, index| {
        try emitter.output.writer.print(", %lnako.Value %arg.{d}", .{index});
    }
    try emitter.output.writer.print(") !dbg !{d} {{\n", .{scope});
    const locals = try emitter.localNames(function);
    defer emitter.allocator.free(locals);
    const value_root_count = context.functionValueCount(function);
    const root_count = value_root_count + locals.len;
    const root_storage_count = @max(@as(usize, 1), root_count);
    const aggregate_count = @max(context.maxAggregateOperandCount(function), context.maxClosureCaptureCount(emitter.program, function));
    for (function.blocks) |block| {
        try emitter.output.writer.print("bb{d}:\n", .{block.id});
        if (block.id == function.entry) {
            try emitter.output.writer.print("  %root.values = alloca [{d} x %lnako.Value]\n", .{root_storage_count});
            try emitter.output.writer.writeAll("  %root.frame = alloca %lnako.RootFrame\n");
            try emitter.output.writer.writeAll("  %runtime.scratch = alloca %lnako.Value\n");
            try emitter.output.writer.writeAll("  store %lnako.Value { i8 0, i64 0 }, ptr %runtime.scratch\n");
            for (0..root_count) |index| {
                try emitter.output.writer.print("  %root.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %root.values, i64 0, i64 {d}\n", .{ index, root_storage_count, index });
                try emitter.output.writer.print("  store %lnako.Value {{ i8 0, i64 0 }}, ptr %root.slot.{d}\n", .{index});
            }
            if (root_count > 0) {
                try emitter.output.writer.print("  call void @lnako_aot_push_roots(ptr %root.frame, ptr %root.slot.0, i64 {d})\n", .{root_count});
            } else try emitter.output.writer.writeAll("  call void @lnako_aot_push_roots(ptr %root.frame, ptr null, i64 0)\n");
            if (aggregate_count > 0) try emitter.output.writer.print("  %aggregate.values = alloca [{d} x %lnako.Value]\n", .{aggregate_count});
            for (function.parameters, 0..) |parameter, index| {
                try emitter.output.writer.print("  store %lnako.Value %arg.{d}, ptr %root.slot.{d}\n", .{ index, parameter.value });
            }
            for (locals, 0..) |name, index| {
                const cell_root = value_root_count + index;
                if (context.nameIndex(function.captures, name)) |capture_index| {
                    try emitter.output.writer.print("  call void @lnako_aot_function_capture(ptr %root.slot.{d}, ptr %context, i64 {d})\n", .{ cell_root, capture_index });
                } else {
                    try emitter.output.writer.print("  call void @lnako_aot_binding_cell_new(ptr %root.slot.{d}, ptr ", .{cell_root});
                    if (context.parameterIndex(function, name)) |parameter_index| {
                        try emitter.output.writer.print("%root.slot.{d}", .{function.parameters[parameter_index].value});
                    } else try emitter.output.writer.writeAll("null");
                    try emitter.output.writer.writeAll(")\n");
                }
                try emitter.output.writer.print("  %local.{d} = call ptr @lnako_aot_binding_cell_value(ptr %root.slot.{d})\n", .{ index, cell_root });
            }
        }
        var phi_count: usize = 0;
        while (phi_count < block.instructions.len and block.instructions[phi_count].opcode == .phi) : (phi_count += 1) {
            try instruction_router_mod.writeInstruction(emitter, function, locals, block.instructions[phi_count], scope, aggregate_count);
        }
        for (block.instructions[0..phi_count]) |instruction| try collections_mod.writeRootStore(emitter, instruction);
        for (block.instructions[phi_count..]) |instruction| {
            try instruction_router_mod.writeInstruction(emitter, function, locals, instruction, scope, aggregate_count);
            try collections_mod.writeRootStore(emitter, instruction);
        }
        const terminator_span = if (block.instructions.len > 0) block.instructions[block.instructions.len - 1].span else ast.emptySpan();
        try terminators_mod.writeTerminator(emitter, function, block.terminator, terminator_span, scope);
    }
    try emitter.output.writer.writeAll("}\n\n");
}

pub fn writeFunctionWrapper(emitter: *Emitter, function: ir.Function) !void {
    try emitter.output.writer.print("define internal void @lnako.wrapper.{d}(ptr %result.out, ptr %context, ptr %arguments, i64 %argument.count) {{\nentry:\n", .{function.id});
    for (function.parameters, 0..) |_, index| {
        try emitter.output.writer.print("  %wrapper.argument.pointer.{d} = getelementptr %lnako.Value, ptr %arguments, i64 {d}\n", .{ index, index });
        try emitter.output.writer.print("  %wrapper.argument.{d} = load %lnako.Value, ptr %wrapper.argument.pointer.{d}\n", .{ index, index });
    }
    try emitter.output.writer.print("  %wrapper.result = call %lnako.Value @lnako.fn.{d}(ptr %context", .{function.id});
    for (function.parameters, 0..) |_, index| {
        try emitter.output.writer.print(", %lnako.Value %wrapper.argument.{d}", .{index});
    }
    try emitter.output.writer.writeAll(")\n  store %lnako.Value %wrapper.result, ptr %result.out\n  ret void\n}\n\n");
}

pub fn writeMain(emitter: *Emitter) !void {
    const scope = 4 + emitter.program.functions.len;
    const entry_name = if (target_builtin.os.tag == .windows) "wmain" else "main";
    try emitter.output.writer.print("define i32 @{s}(i32 %argc, ptr %argv) !dbg !{d} {{\nentry:\n", .{ entry_name, scope });
    try emitter.output.writer.writeAll("  %runtime.status = call i32 @lnako_aot_runtime_init()\n");
    for (emitter.program.native_plugin_paths, 0..) |path, index| {
        try emitter.output.writer.print("  call void @lnako_aot_native_plugin_register(ptr @lnako.native.plugin.path.{d}, i64 {d})\n", .{ index, path.len });
    }
    for (emitter.globals.items, 0..) |_, global_index| {
        try emitter.output.writer.print("  %global.root.frame.{d} = alloca %lnako.RootFrame\n", .{global_index});
        try emitter.output.writer.print("  call void @lnako_aot_push_roots(ptr %global.root.frame.{d}, ptr @lnako.global.{d}, i64 1)\n", .{ global_index, global_index });
    }
    if (emitter.hasDynamicBuiltin()) for (emitter.globals.items, 0..) |name, global_index| {
        try emitter.output.writer.print("  call void @lnako_aot_dynamic_global_register(ptr @lnako.global.name.{d}, i64 {d}, ptr @lnako.global.{d})\n", .{ global_index, name.len, global_index });
    };
    for (emitter.system_strings.items, 0..) |constant, index| {
        try emitter.output.writer.print("  call void @lnako_aot_string_new(ptr @lnako.global.{d}, ptr ", .{constant.global_index});
        if (constant.units.len == 0) {
            try emitter.output.writer.writeAll("null");
        } else try emitter.output.writer.print("@lnako.system.string.{d}", .{index});
        try emitter.output.writer.print(", i64 {d})\n", .{constant.units.len});
    }
    for (emitter.system_arrays.items) |global_index| {
        try emitter.output.writer.print("  call void @lnako_aot_array_new(ptr @lnako.global.{d}, ptr null, i64 0)\n", .{global_index});
    }
    for (emitter.system_dictionaries.items) |global_index| {
        try emitter.output.writer.print("  call void @lnako_aot_caniuse_agents_new(ptr @lnako.global.{d})\n", .{global_index});
    }
    for (emitter.system_era_data.items) |global_index| {
        try emitter.output.writer.print("  call void @lnako_aot_era_data_new(ptr @lnako.global.{d})\n", .{global_index});
    }
    if (emitter.globalIndex("コマンドライン") != null or emitter.globalIndex("ナデシコランタイム") != null or emitter.globalIndex("ナデシコランタイムパス") != null) {
        const constants_initializer = if (target_builtin.os.tag == .windows)
            "lnako_aot_node_constants_init_wide"
        else
            "lnako_aot_node_constants_init";
        try emitter.output.writer.print("  call void @{s}(ptr ", .{constants_initializer});
        if (emitter.globalIndex("コマンドライン")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("ナデシコランタイム")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("ナデシコランタイムパス")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", i32 %argc, ptr %argv)\n");
    }
    if (emitter.globalIndex("デスクトップ") != null or emitter.globalIndex("マイドキュメント") != null or emitter.globalIndex("テンポラリフォルダ") != null) {
        try emitter.output.writer.writeAll("  call void @lnako_aot_node_directory_constants_init(ptr ");
        if (emitter.globalIndex("デスクトップ")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("マイドキュメント")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("テンポラリフォルダ")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(")\n");
    }
    if (emitter.needsNodeMotherPath()) {
        try emitter.output.writer.writeAll("  call void @lnako_aot_node_mother_path_init(ptr ");
        if (emitter.globalIndex("母艦パス")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.source_path.len > 0) try emitter.output.writer.writeAll("@lnako.node.source.path") else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.print(", i64 {d})\n", .{emitter.source_path.len});
    }
    for (emitter.program.functions) |function| if (emitter.globalIndex(function.name)) |global_index| {
        try emitter.output.writer.print("  call void @lnako_aot_function_new_named(ptr @lnako.global.{d}, ptr @lnako.wrapper.{d}, i64 {d}, ptr @lnako.function.name.{d}, i64 {d}, ptr null, i64 0)\n", .{ global_index, function.id, function.parameters.len, function.id, function.name.len });
    };
    if (emitter.program.http_server_plugin_imported) {
        try emitter.output.writer.writeAll("  call void @lnako_aot_http_server_init(ptr ");
        if (emitter.globalIndex("HTTPメソッド")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("GETデータ")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("POSTデータ")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(", ptr ");
        if (emitter.globalIndex("FILESデータ")) |global_index| try emitter.output.writer.print("@lnako.global.{d}", .{global_index}) else try emitter.output.writer.writeAll("null");
        try emitter.output.writer.writeAll(")\n");
    }
    var index = emitter.program.module_entries.len;
    var call_index: usize = 0;
    while (index > 0) {
        index -= 1;
        try emitter.output.writer.print("  %entry.result.{d} = call %lnako.Value @lnako.fn.{d}(ptr null)", .{ call_index, emitter.program.module_entries[index] });
        try emitter.debugSuffix(ast.emptySpan(), scope);
        try emitter.output.writer.print("  %entry.exception.pending.{d} = call i32 @lnako_aot_exception_pending()\n", .{call_index});
        try emitter.output.writer.print("  %entry.exception.is-pending.{d} = icmp ne i32 %entry.exception.pending.{d}, 0\n", .{ call_index, call_index });
        try emitter.output.writer.print("  br i1 %entry.exception.is-pending.{d}, label %entry.exception.abort.{d}, label %entry.continue.{d}\n", .{ call_index, call_index, call_index });
        try emitter.output.writer.print("entry.exception.abort.{d}:\n  call void @lnako_aot_exception_abort()\n  unreachable\nentry.continue.{d}:\n", .{ call_index, call_index });
        call_index += 1;
    }
    try emitter.output.writer.writeAll("  call void @lnako_aot_runtime_drain_events()\n");
    try emitter.output.writer.writeAll("  %entry.timer.exception.pending = call i32 @lnako_aot_exception_pending()\n");
    try emitter.output.writer.writeAll("  %entry.timer.exception.is-pending = icmp ne i32 %entry.timer.exception.pending, 0\n");
    try emitter.output.writer.writeAll("  br i1 %entry.timer.exception.is-pending, label %entry.timer.exception.abort, label %entry.timer.continue\n");
    try emitter.output.writer.writeAll("entry.timer.exception.abort:\n  call void @lnako_aot_exception_abort()\n  unreachable\nentry.timer.continue:\n");
    var global_index = emitter.globals.items.len;
    while (global_index > 0) {
        global_index -= 1;
        try emitter.output.writer.print("  call void @lnako_aot_pop_roots(ptr %global.root.frame.{d})\n", .{global_index});
    }
    try emitter.output.writer.writeAll("  call void @lnako_aot_runtime_deinit()\n  ret i32 0");
    try emitter.debugSuffix(ast.emptySpan(), scope);
    try emitter.output.writer.writeAll("}\n\n");
}
