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

pub fn writeRuntimeHelpers(emitter: *Emitter) !void {
    try emitter.output.writer.writeAll(
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
            "  %truthy.value = alloca %lnako.Value\n" ++
            "  store %lnako.Value %value, ptr %truthy.value\n" ++
            "  %tag = extractvalue %lnako.Value %value, 0\n" ++
            "  switch i8 %tag, label %truthy [ i8 0, label %falsey i8 1, label %falsey i8 2, label %boolean i8 3, label %number i8 9, label %bigint ]\n" ++
            "boolean:\n" ++
            "  %bool.bits = extractvalue %lnako.Value %value, 1\n" ++
            "  %bool = icmp ne i64 %bool.bits, 0\n" ++
            "  ret i1 %bool\n" ++
            "number:\n" ++
            "  %number.bits = extractvalue %lnako.Value %value, 1\n" ++
            "  %number.value = bitcast i64 %number.bits to double\n" ++
            "  %number.truthy = fcmp one double %number.value, 0.000000e+00\n" ++
            "  ret i1 %number.truthy\n" ++
            "bigint:\n" ++
            "  %bigint.status = call i32 @lnako_aot_bigint_truthy(ptr %truthy.value)\n" ++
            "  %bigint.truthy = icmp ne i32 %bigint.status, 0\n" ++
            "  ret i1 %bigint.truthy\n" ++
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
            "define internal %lnako.Value @lnako.display(%lnako.Value %value, i1 %newline, i64 %site_id, ptr %display_log) {\n" ++
            "entry:\n" ++
            "  %display.failure_epoch = alloca i64\n" ++
            "  %display.call_id = call i64 @lnako_aot_dispatch_display_begin_with_epoch(i64 %site_id, ptr %display.failure_epoch)\n" ++
            "  %display.value = alloca %lnako.Value\n" ++
            "  store %lnako.Value %value, ptr %display.value\n" ++
            "  call void @lnako_aot_display_value(ptr %display.value, i1 %newline, ptr %display_log)\n" ++
            "  %display.start_epoch = load i64, ptr %display.failure_epoch\n" ++
            "  call void @lnako_aot_dispatch_result(i64 %display.call_id, i64 %site_id, i64 %display.start_epoch)\n" ++
            "  ret %lnako.Value { i8 0, i64 0 }\n" ++
            "}\n\n" ++
            "define internal %lnako.Value @lnako.display_many(ptr %arguments, i64 %count, i64 %site_id, ptr %display_log) {\n" ++
            "entry:\n" ++
            "  %display.failure_epoch = alloca i64\n" ++
            "  %display.call_id = call i64 @lnako_aot_dispatch_display_begin_with_epoch(i64 %site_id, ptr %display.failure_epoch)\n" ++
            "  call void @lnako_aot_display_many(ptr %arguments, i64 %count, ptr %display_log)\n" ++
            "  %display.start_epoch = load i64, ptr %display.failure_epoch\n" ++
            "  call void @lnako_aot_dispatch_result(i64 %display.call_id, i64 %site_id, i64 %display.start_epoch)\n" ++
            "  ret %lnako.Value { i8 0, i64 0 }\n" ++
            "}\n\n",
    );
}

pub fn writeDebugMetadata(emitter: *Emitter) !void {
    const writer = &emitter.output.writer;
    const file_name = std.fs.path.basename(emitter.source_path);
    const directory = std.fs.path.dirname(emitter.source_path) orelse ".";
    try writer.writeAll("!llvm.dbg.cu = !{!0}\n");
    const flags_start = emitter.next_metadata;
    try writer.print("!llvm.module.flags = !{{!{d}, !{d}}}\n", .{ flags_start, flags_start + 1 });
    try writer.print("!llvm.ident = !{{!{d}}}\n\n", .{flags_start + 2});
    try writer.writeAll("!0 = distinct !DICompileUnit(language: DW_LANG_C99, file: !1, producer: \"lnako Zig+LLVM\", isOptimized: ");
    try writer.writeAll(if (emitter.optimized) "true" else "false");
    try writer.writeAll(", runtimeVersion: 0, emissionKind: FullDebug)\n!1 = !DIFile(filename: \"");
    try context.writeMetadataString(writer, file_name);
    try writer.writeAll("\", directory: \"");
    try context.writeMetadataString(writer, directory);
    try writer.writeAll("\")\n!2 = !DISubroutineType(types: !3)\n!3 = !{}\n");
    for (emitter.program.functions) |function| {
        const scope = 4 + function.id;
        try writer.print("!{d} = distinct !DISubprogram(name: \"", .{scope});
        try context.writeMetadataString(writer, function.name);
        try writer.print("\", linkageName: \"lnako.fn.{d}\", scope: !1, file: !1, line: 1, type: !2, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !0)\n", .{function.id});
    }
    const main_scope = 4 + emitter.program.functions.len;
    try writer.print("!{d} = distinct !DISubprogram(name: \"main\", linkageName: \"main\", scope: !1, file: !1, line: 1, type: !2, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !0)\n", .{main_scope});
    for (emitter.locations.items) |location| try writer.print("!{d} = !DILocation(line: {d}, column: {d}, scope: !{d})\n", .{ location.id, location.line, location.column, location.scope });
    try writer.print("!{d} = !{{i32 2, !\"Dwarf Version\", i32 4}}\n", .{flags_start});
    try writer.print("!{d} = !{{i32 2, !\"Debug Info Version\", i32 3}}\n", .{flags_start + 1});
    try writer.print("!{d} = !{{!\"lnako 0.0.0-dev\"}}\n", .{flags_start + 2});
}
