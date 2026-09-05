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

pub fn emitPreamble(emitter: *Emitter) !void {
    const writer = &emitter.output.writer;
    try writer.writeAll(
        "; lnako Nako SSA IR -> LLVM IR\n" ++
            "source_filename = \"lnako\"\n\n" ++
            "%lnako.Value = type { i8, i64 }\n" ++
            "%lnako.RootFrame = type { ptr, ptr, i64 }\n\n" ++
            "declare i32 @lnako_aot_runtime_init()\n" ++
            "declare void @lnako_aot_node_constants_init(ptr, ptr, ptr, i32, ptr)\n" ++
            "declare void @lnako_aot_node_constants_init_wide(ptr, ptr, ptr, i32, ptr)\n" ++
            "declare void @lnako_aot_node_directory_constants_init(ptr, ptr, ptr)\n" ++
            "declare void @lnako_aot_node_mother_path_init(ptr, ptr, i64)\n" ++
            "declare void @lnako_aot_runtime_deinit()\n" ++
            "declare void @lnako_aot_runtime_drain_events()\n" ++
            "declare void @lnako_aot_push_roots(ptr, ptr, i64)\n" ++
            "declare void @lnako_aot_pop_roots(ptr)\n" ++
            "declare void @lnako_aot_exception_set(ptr)\n" ++
            "declare void @lnako_aot_exception_set_error_message(ptr)\n" ++
            "declare void @lnako_aot_throw_site(i64)\n" ++
            "declare i32 @lnako_aot_exception_pending()\n" ++
            "declare void @lnako_aot_exception_take(ptr)\n" ++
            "declare void @lnako_aot_exception_abort()\n" ++
            "declare void @lnako_aot_string_new(ptr, ptr, i64)\n" ++
            "declare void @lnako_aot_print_number(ptr, i1)\n" ++
            "declare void @lnako_aot_print_utf16(ptr, i1)\n" ++
            "declare void @lnako_aot_bigint_new(ptr, ptr, i64)\n" ++
            "declare void @lnako_aot_print_bigint(ptr, i1)\n" ++
            "declare void @lnako_aot_print_collection(ptr, i1)\n" ++
            "declare void @lnako_aot_display_value(ptr, i1, ptr)\n" ++
            "declare void @lnako_aot_display_many(ptr, i64, ptr)\n" ++
            "declare void @lnako_aot_debug_display(ptr, ptr, i64, ptr, i64, ptr, i64)\n" ++
            "declare void @lnako_aot_debug_breakpoint_wait_call(ptr, ptr, ptr, ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_stdio_call(ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_plugin_management_call(ptr, ptr, i64, i16, ptr, ptr, i64)\n" ++
            "declare void @lnako_aot_archive_tool_path_set(ptr, ptr, i64, ptr, i64)\n" ++
            "declare void @lnako_aot_archive_call(ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_node_process_call(ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_ajax_options_set(ptr, ptr, i64, ptr, i64)\n" ++
            "declare void @lnako_aot_ajax_onerror_set(ptr, ptr, i64, ptr, i64)\n" ++
            "declare void @lnako_aot_node_http_call(ptr, ptr, ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_file_operation_call(ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_node_file_callback_call(ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_http_server_init(ptr, ptr, ptr, ptr)\n" ++
            "declare void @lnako_aot_http_server_call(ptr, ptr, ptr, ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare i32 @lnako_aot_bigint_truthy(ptr)\n" ++
            "declare i32 @lnako_aot_truthy(ptr)\n" ++
            "declare void @lnako_aot_unary(ptr, ptr, i8)\n" ++
            "declare void @lnako_aot_arithmetic(ptr, ptr, ptr, i8)\n" ++
            "declare void @lnako_aot_compare(ptr, ptr, ptr, i8)\n" ++
            "declare void @lnako_aot_shift(ptr, ptr, ptr, i8)\n" ++
            "declare void @lnako_aot_concat(ptr, ptr, ptr)\n" ++
            "declare void @lnako_aot_increment(ptr, ptr)\n" ++
            "declare void @lnako_aot_array_new(ptr, ptr, i64)\n" ++
            "declare void @lnako_aot_dictionary_new(ptr, ptr, i64)\n" ++
            "declare void @lnako_aot_caniuse_agents_new(ptr)\n" ++
            "declare void @lnako_aot_era_data_new(ptr)\n" ++
            "declare void @lnako_aot_index_get(ptr, ptr, ptr)\n" ++
            "declare i32 @lnako_aot_index_set(ptr, ptr, ptr)\n" ++
            "declare void @lnako_aot_destructure_get(ptr, ptr, i64)\n" ++
            "declare void @lnako_aot_iterator_new(ptr, ptr, i64, i1, i8)\n" ++
            "declare i32 @lnako_aot_iterator_has_next(ptr)\n" ++
            "declare void @lnako_aot_iterator_next(ptr, ptr, ptr, ptr, ptr, ptr)\n" ++
            "declare void @lnako_aot_binding_cell_new(ptr, ptr)\n" ++
            "declare ptr @lnako_aot_binding_cell_value(ptr)\n" ++
            "declare void @lnako_aot_function_new(ptr, ptr, i64, ptr, i64)\n" ++
            "declare void @lnako_aot_function_new_named(ptr, ptr, i64, ptr, i64, ptr, i64)\n" ++
            "declare void @lnako_aot_function_capture(ptr, ptr, i64)\n" ++
            "declare void @lnako_aot_function_call(ptr, ptr, ptr, i64)\n" ++
            "declare void @lnako_aot_cut(ptr, ptr, ptr, i64, i8)\n" ++
            "declare void @lnako_aot_cut_site(ptr, ptr, ptr, i64, i8, i64)\n" ++
            "declare void @lnako_aot_builtin_call(ptr, ptr, i64, i16)\n" ++
            "declare void @lnako_aot_builtin_call_site(ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_node_stdin_callback_call(ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_timer_call_site(ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_promise_call_site(ptr, ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_regexp_call(ptr, ptr, ptr, i64, i16)\n" ++
            "declare void @lnako_aot_regexp_call_site(ptr, ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_hatena_execute(ptr, ptr, i64, ptr, i64, ptr, i64)\n" ++
            "declare void @lnako_aot_dynamic_global_register(ptr, i64, ptr)\n" ++
            "declare void @lnako_aot_dynamic_call(ptr, ptr, i64, i16, i64)\n" ++
            "declare void @lnako_aot_native_plugin_register(ptr, i64)\n" ++
            "declare void @lnako_aot_native_plugin_call(ptr, ptr, i64, ptr, i64, i64)\n" ++
            "declare i64 @lnako_aot_dispatch_display_begin(i64)\n" ++
            "declare i64 @lnako_aot_dispatch_display_begin_with_epoch(i64, ptr)\n" ++
            "declare void @lnako_aot_dispatch_result(i64, i64, i64)\n" ++
            "declare void @lnako_aot_global_read_site(i64)\n" ++
            "declare void @lnako_aot_global_write_site(i64)\n" ++
            "declare void @lnako_aot_literal_site(i64)\n" ++
            "declare i32 @printf(ptr, ...)\n" ++
            "declare i32 @puts(ptr)\n" ++
            "declare double @llvm.pow.f64(double, double)\n" ++
            "declare double @llvm.floor.f64(double)\n\n" ++
            "@.lnako.fmt.text.inline = private unnamed_addr constant [3 x i8] c\"%s\\00\"\n" ++
            "@.lnako.undefined = private unnamed_addr constant [10 x i8] c\"undefined\\00\"\n" ++
            "@.lnako.null = private unnamed_addr constant [5 x i8] c\"null\\00\"\n" ++
            "@.lnako.true = private unnamed_addr constant [5 x i8] c\"true\\00\"\n" ++
            "@.lnako.false = private unnamed_addr constant [6 x i8] c\"false\\00\"\n\n",
    );
}

pub fn collectModuleData(emitter: *Emitter) !void {
    var string_index: usize = 0;
    var bigint_index: usize = 0;
    try emitter.globals.append(emitter.allocator, "それ");
    for (emitter.program.functions) |function| {
        if (!context.isNamedGlobalFunction(function.name) or emitter.globalIndex(function.name) != null) continue;
        try emitter.globals.append(emitter.allocator, function.name);
    }
    for (emitter.program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if ((instruction.opcode == .load_global or instruction.opcode == .store_global) and emitter.globalIndex(instruction.name) == null) {
            try emitter.globals.append(emitter.allocator, instruction.name);
        }
        if (instruction.opcode == .destructure_store) for (instruction.names) |name| {
            if (isQualifiedGlobal(name) and emitter.globalIndex(name) == null) try emitter.globals.append(emitter.allocator, name);
        };
        if (instruction.opcode == .increment and isQualifiedGlobal(instruction.name) and emitter.globalIndex(instruction.name) == null) {
            try emitter.globals.append(emitter.allocator, instruction.name);
        }
        if (instruction.opcode == .exception_take and emitter.globalIndex("エラーメッセージ") == null) {
            try emitter.globals.append(emitter.allocator, "エラーメッセージ");
        }
        if (instruction.opcode == .call and instruction.direct_callee == null) {
            if (isNativePluginCall(emitter.program, function, instruction) and emitter.nativePluginNameIndex(instruction.name) == null) {
                try emitter.native_plugin_names.append(emitter.allocator, instruction.name);
            }
            if (instruction.is_builtin_call and context.requiresDisplayLog(instruction.name) and emitter.globalIndex("表示ログ") == null) {
                try emitter.globals.append(emitter.allocator, "表示ログ");
            }
            if (instruction.is_builtin_call) if (aot_builtin.lookup(instruction.name)) |command| if (command == .system_debug_display or command == .system_hatena_execute) {
                const path = emitter.sourcePathForFunction(function.name);
                if (emitter.debugPathIndex(path) == null) try emitter.debug_paths.append(emitter.allocator, .{ .path = path });
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (command == .system_debug_breakpoint_wait) {
                for ([_][]const u8{ "__DEBUGブレイクポイント一覧", "__DEBUG強制待機", "__DEBUG待機フラグ", "プラグイン名" }) |name| {
                    if (emitter.globalIndex(name) == null) try emitter.globals.append(emitter.allocator, name);
                }
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (command == .cut or command == .cut_range) {
                if (emitter.globalIndex("対象") == null) try emitter.globals.append(emitter.allocator, "対象");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (context.isTimerCommand(command)) {
                if (emitter.globalIndex("対象") == null) try emitter.globals.append(emitter.allocator, "対象");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (command == .node_stdin_callback) {
                if (emitter.globalIndex("対象") == null) try emitter.globals.append(emitter.allocator, "対象");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (context.isNodeFileCallbackCommand(command)) {
                if (emitter.globalIndex("対象") == null) try emitter.globals.append(emitter.allocator, "対象");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (context.isPromiseCommand(command)) {
                if (emitter.globalIndex("そ") == null) try emitter.globals.append(emitter.allocator, "そ");
                if (emitter.globalIndex("対象") == null) try emitter.globals.append(emitter.allocator, "対象");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (command == .regexp_match or command == .regexp_extract) {
                if (emitter.globalIndex("抽出文字列") == null) try emitter.globals.append(emitter.allocator, "抽出文字列");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (context.isPluginManagementCommand(command)) {
                if (emitter.globalIndex("プラグイン名") == null) try emitter.globals.append(emitter.allocator, "プラグイン名");
                if (emitter.globalIndex("名前空間") == null) try emitter.globals.append(emitter.allocator, "名前空間");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (command == .node_archive_tool_path_set) {
                if (emitter.globalIndex("圧縮解凍ツールパス") == null) try emitter.globals.append(emitter.allocator, "圧縮解凍ツールパス");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (context.isArchiveCommand(command)) {
                if (emitter.globalIndex("圧縮解凍ツールパス") == null) try emitter.globals.append(emitter.allocator, "圧縮解凍ツールパス");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (command == .node_ajax_options_set) {
                if (emitter.globalIndex("AJAXオプション") == null) try emitter.globals.append(emitter.allocator, "AJAXオプション");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (command == .node_ajax_onerror_set) {
                if (emitter.globalIndex("AJAX:ONERROR") == null) try emitter.globals.append(emitter.allocator, "AJAX:ONERROR");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (context.isNodeHttpCommand(command)) {
                for ([_][]const u8{ "AJAXオプション", "AJAX:ONERROR", "対象" }) |name| {
                    if (emitter.globalIndex(name) == null) try emitter.globals.append(emitter.allocator, name);
                }
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (context.isNodeFileOperationCommand(command)) {
                if (emitter.globalIndex("ファイルコピーデフォルト動作") == null) try emitter.globals.append(emitter.allocator, "ファイルコピーデフォルト動作");
            };
            if (aot_builtin.lookup(instruction.name)) |command| if (context.isHttpServerCommand(command)) {
                for ([_][]const u8{ "HTTPメソッド", "GETデータ", "POSTデータ", "FILESデータ" }) |name| {
                    if (emitter.globalIndex(name) == null) try emitter.globals.append(emitter.allocator, name);
                }
            };
        }
        if (instruction.opcode == .const_string) {
            const value_id = instruction.result orelse return error.InvalidStringConstant;
            const units = try std.unicode.utf8ToUtf16LeAlloc(emitter.allocator, instruction.text);
            emitter.strings.append(emitter.allocator, .{
                .function_id = function.id,
                .value_id = value_id,
                .units = units,
                .index = string_index,
            }) catch |failure| {
                emitter.allocator.free(units);
                return failure;
            };
            string_index += 1;
        }
        if (instruction.opcode == .const_bigint) {
            try emitter.bigints.append(emitter.allocator, .{
                .function_id = function.id,
                .value_id = instruction.result orelse return error.InvalidBigIntConstant,
                .text = instruction.text,
                .index = bigint_index,
            });
            bigint_index += 1;
        }
    };
    for (emitter.globals.items, 0..) |name, global_index| if (emitter.systemStringValue(name)) |value| {
        const units = try std.unicode.utf8ToUtf16LeAlloc(emitter.allocator, value);
        emitter.system_strings.append(emitter.allocator, .{ .global_index = global_index, .units = units }) catch |failure| {
            emitter.allocator.free(units);
            return failure;
        };
    };
    for (emitter.globals.items, 0..) |name, global_index| {
        if (system_constant.isArray(name)) try emitter.system_arrays.append(emitter.allocator, global_index);
        if (system_constant.isDictionary(name)) try emitter.system_dictionaries.append(emitter.allocator, global_index);
        if (system_constant.isEraData(name)) try emitter.system_era_data.append(emitter.allocator, global_index);
    }
}

pub fn emitDeclarations(emitter: *Emitter) !void {
    const writer = &emitter.output.writer;
    for (emitter.globals.items, 0..) |name, index| {
        try writer.print("@lnako.global.{d} = internal global %lnako.Value ", .{index});
        try context.writeScalarInitializer(writer, system_constant.lookupScalar(name));
        try writer.writeByte('\n');
    }
    if (emitter.globals.items.len > 0) try writer.writeByte('\n');
    if (emitter.hasDynamicBuiltin()) for (emitter.globals.items, 0..) |name, index| {
        try writer.print("@lnako.global.name.{d} = private unnamed_addr constant [{d} x i8] ", .{ index, name.len });
        if (name.len == 0) {
            try writer.writeAll("zeroinitializer\n");
        } else {
            try writer.writeByte('[');
            for (name, 0..) |byte, byte_index| {
                if (byte_index > 0) try writer.writeAll(", ");
                try writer.print("i8 {d}", .{byte});
            }
            try writer.writeAll("]\n");
        }
    };
    if (emitter.hasDynamicBuiltin() and emitter.globals.items.len > 0) try writer.writeByte('\n');
    for (emitter.native_plugin_names.items, 0..) |name, index| {
        try writer.print("@lnako.native.plugin.name.{d} = private unnamed_addr constant [{d} x i8] ", .{ index, name.len });
        if (name.len == 0) {
            try writer.writeAll("zeroinitializer\n");
        } else {
            try writer.writeByte('[');
            for (name, 0..) |byte, byte_index| {
                if (byte_index > 0) try writer.writeAll(", ");
                try writer.print("i8 {d}", .{byte});
            }
            try writer.writeAll("]\n");
        }
    }
    for (emitter.program.native_plugin_paths, 0..) |path, index| {
        try writer.print("@lnako.native.plugin.path.{d} = private unnamed_addr constant [{d} x i8] ", .{ index, path.len });
        if (path.len == 0) {
            try writer.writeAll("zeroinitializer\n");
        } else {
            try writer.writeByte('[');
            for (path, 0..) |byte, byte_index| {
                if (byte_index > 0) try writer.writeAll(", ");
                try writer.print("i8 {d}", .{byte});
            }
            try writer.writeAll("]\n");
        }
    }
    if (emitter.native_plugin_names.items.len > 0 or emitter.program.native_plugin_paths.len > 0) try writer.writeByte('\n');
    for (emitter.strings.items) |constant| {
        try writer.print("@lnako.string.{d} = private unnamed_addr constant [{d} x i16] ", .{ constant.index, constant.units.len });
        if (constant.units.len == 0) {
            try writer.writeAll("zeroinitializer\n");
        } else {
            try writer.writeByte('[');
            for (constant.units, 0..) |unit, index| {
                if (index > 0) try writer.writeAll(", ");
                try writer.print("i16 {d}", .{unit});
            }
            try writer.writeAll("]\n");
        }
    }
    if (emitter.strings.items.len > 0) try writer.writeByte('\n');
    for (emitter.debug_paths.items, 0..) |constant, index| {
        try writer.print("@lnako.debug.path.{d} = private unnamed_addr constant [{d} x i8] ", .{ index, constant.path.len });
        if (constant.path.len == 0) {
            try writer.writeAll("zeroinitializer\n");
        } else {
            try writer.writeByte('[');
            for (constant.path, 0..) |byte, byte_index| {
                if (byte_index > 0) try writer.writeAll(", ");
                try writer.print("i8 {d}", .{byte});
            }
            try writer.writeAll("]\n");
        }
    }
    if (emitter.debug_paths.items.len > 0) try writer.writeByte('\n');
    for (emitter.program.functions) |function| {
        try writer.print("@lnako.function.name.{d} = private unnamed_addr constant [{d} x i8] ", .{ function.id, function.name.len });
        if (function.name.len == 0) {
            try writer.writeAll("zeroinitializer\n");
        } else {
            try writer.writeByte('[');
            for (function.name, 0..) |byte, index| {
                if (index > 0) try writer.writeAll(", ");
                try writer.print("i8 {d}", .{byte});
            }
            try writer.writeAll("]\n");
        }
    }
    if (emitter.program.functions.len > 0) try writer.writeByte('\n');
    for (emitter.system_strings.items, 0..) |constant, index| {
        try writer.print("@lnako.system.string.{d} = private unnamed_addr constant [{d} x i16] ", .{ index, constant.units.len });
        if (constant.units.len == 0) {
            try writer.writeAll("zeroinitializer\n");
        } else {
            try writer.writeByte('[');
            for (constant.units, 0..) |unit, unit_index| {
                if (unit_index > 0) try writer.writeAll(", ");
                try writer.print("i16 {d}", .{unit});
            }
            try writer.writeAll("]\n");
        }
    }
    if (emitter.system_strings.items.len > 0) try writer.writeByte('\n');
    if (emitter.needsNodeMotherPath()) {
        try writer.print("@lnako.node.source.path = private unnamed_addr constant [{d} x i8] ", .{emitter.source_path.len});
        if (emitter.source_path.len == 0) {
            try writer.writeAll("zeroinitializer\n");
        } else {
            try writer.writeByte('[');
            for (emitter.source_path, 0..) |byte, index| {
                if (index > 0) try writer.writeAll(", ");
                try writer.print("i8 {d}", .{byte});
            }
            try writer.writeAll("]\n");
        }
        try writer.writeByte('\n');
    }
    for (emitter.bigints.items) |constant| {
        try writer.print("@lnako.bigint.{d} = private unnamed_addr constant [{d} x i8] ", .{ constant.index, constant.text.len });
        if (constant.text.len == 0) {
            try writer.writeAll("zeroinitializer\n");
        } else {
            try writer.writeByte('[');
            for (constant.text, 0..) |byte, index| {
                if (index > 0) try writer.writeAll(", ");
                try writer.print("i8 {d}", .{byte});
            }
            try writer.writeAll("]\n");
        }
    }
    if (emitter.bigints.items.len > 0) try writer.writeByte('\n');
}
