const std = @import("std");
const target_builtin = @import("builtin");
const ir = @import("../../ir/nako_ir.zig");
const ast = @import("../../frontend/ast.zig");
const aot_abi = @import("../../runtime/aot_abi.zig");
const aot_builtin = @import("../../runtime/aot_builtin.zig");
const system_constant = @import("../../runtime/system_constant.zig");

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

/// A single builtin dispatch recorded by the optional AOT compile manifest.
///
/// This is deliberately limited to names, a stable site identity, and source
/// locations. It is a pre-optimization witness of the dispatches that the
/// LLVM emitter will see; it must not expose IR values, arguments, or pointers.
pub const ManifestCall = struct {
    source_name: []const u8,
    canonical_opcode: []const u8,
    route: []const u8,
    opcode: u16,
};

const manifest_schema = "lnako.aot.builtin-manifest.v1";
const global_manifest_schema = "lnako.aot.global-manifest.v1";
const literal_manifest_schema = "lnako.aot.literal-manifest.v1";

const ManifestHeader = struct {
    schema: []const u8,
    phase: []const u8,
    sourcePath: []const u8,
    siteIdEncoding: []const u8,
};

const ManifestSource = struct {
    line: usize,
    column: usize,
    sourceStart: usize,
    sourceEnd: usize,
};

const ManifestEntry = struct {
    schema: []const u8,
    phase: []const u8,
    kind: []const u8,
    sourceName: []const u8,
    canonicalOpcode: []const u8,
    route: []const u8,
    opcode: u16,
    siteId: []const u8,
    function: []const u8,
    source: ManifestSource,
};

const ManifestComplete = struct {
    schema: []const u8,
    phase: []const u8,
    kind: []const u8,
    complete: bool,
    entryCount: usize,
};

const GlobalManifestHeader = struct {
    schema: []const u8,
    phase: []const u8,
    sourcePath: []const u8,
    siteIdEncoding: []const u8,
};

const GlobalManifestEntry = struct {
    schema: []const u8,
    phase: []const u8,
    kind: []const u8,
    name: []const u8,
    siteId: []const u8,
    function: []const u8,
    source: ManifestSource,
};

const GlobalManifestComplete = struct {
    schema: []const u8,
    phase: []const u8,
    kind: []const u8,
    complete: bool,
    entryCount: usize,
};

const LiteralManifestHeader = struct {
    schema: []const u8,
    phase: []const u8,
    sourcePath: []const u8,
    siteIdEncoding: []const u8,
};

const LiteralManifestEntry = struct {
    schema: []const u8,
    phase: []const u8,
    kind: []const u8,
    name: []const u8,
    siteId: []const u8,
    function: []const u8,
    source: ManifestSource,
};

const LiteralManifestComplete = struct {
    schema: []const u8,
    phase: []const u8,
    kind: []const u8,
    complete: bool,
    entryCount: usize,
};

/// Resolves the same builtin routes used by the LLVM emitter.  A `null`
/// result means that the call is a user/dynamic call and is intentionally not
/// part of the builtin manifest.
pub fn manifestCall(name: []const u8, direct_callee: ?ir.FunctionId, is_builtin_call: bool) ?ManifestCall {
    if (direct_callee != null or !is_builtin_call) return null;
    if (isDisplayCall(name)) return .{
        .source_name = name,
        .canonical_opcode = "display",
        .route = "direct-display",
        .opcode = 0,
    };
    const command = aot_builtin.lookup(name) orelse return null;
    const route = aot_builtin.dispatchRoute(command);
    return .{
        .source_name = name,
        .canonical_opcode = aot_builtin.canonicalOpcodeName(command),
        .route = route,
        .opcode = @intFromEnum(command),
    };
}

/// Writes a JSONL manifest without replacing an existing file.  The first
/// record describes the schema; subsequent records are pre-optimization
/// builtin dispatch evidence in source/IR order.
pub fn writeBuiltinManifest(allocator: std.mem.Allocator, io: std.Io, program: ir.Program, source_path: []const u8, manifest_path: []const u8) !usize {
    if (!std.fs.path.isAbsolute(manifest_path)) return error.ManifestPathMustBeAbsolute;

    var file = try std.Io.Dir.createFileAbsolute(io, manifest_path, .{ .exclusive = true });
    var keep_file = true;
    defer {
        file.close(io);
        if (keep_file) std.Io.Dir.deleteFileAbsolute(io, manifest_path) catch {};
    }

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    var seen_site_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen_site_ids.deinit(allocator);
    writeManifestLine(writer, ManifestHeader{
        .schema = manifest_schema,
        .phase = "pre-opt",
        .sourcePath = source_path,
        .siteIdEncoding = "u64-hex16",
    }) catch |err| return err;
    var entry_count: usize = 0;
    for (program.functions) |function| {
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.opcode != .call) continue;
                const call = manifestCall(instruction.name, instruction.direct_callee, instruction.is_builtin_call) orelse continue;
                const site_id = instruction.site_id orelse return error.MissingDispatchSiteId;
                if (seen_site_ids.contains(site_id)) return error.ManifestSiteIdCollision;
                try seen_site_ids.put(allocator, site_id, {});
                var site_id_text: [18]u8 = undefined;
                entry_count += 1;
                try writeManifestLine(writer, ManifestEntry{
                    .schema = manifest_schema,
                    .phase = "pre-opt",
                    .kind = "builtin-dispatch",
                    .sourceName = call.source_name,
                    .canonicalOpcode = call.canonical_opcode,
                    .route = call.route,
                    .opcode = call.opcode,
                    .siteId = formatSiteId(&site_id_text, site_id),
                    .function = function.name,
                    .source = .{
                        .line = instruction.span.line + 1,
                        .column = @max(@as(usize, 1), instruction.span.column),
                        .sourceStart = instruction.span.source_start,
                        .sourceEnd = instruction.span.source_end,
                    },
                });
            }
            switch (block.terminator) {
                .throw_value => |throw_value| {
                    const site_id = throw_value.site_id orelse return error.MissingDispatchSiteId;
                    if (seen_site_ids.contains(site_id)) return error.ManifestSiteIdCollision;
                    try seen_site_ids.put(allocator, site_id, {});
                    var site_id_text: [18]u8 = undefined;
                    entry_count += 1;
                    try writeManifestLine(writer, ManifestEntry{
                        .schema = manifest_schema,
                        .phase = "pre-opt",
                        .kind = "throw-dispatch",
                        .sourceName = "エラー発生",
                        .canonicalOpcode = aot_builtin.throw_statement_canonical_opcode,
                        .route = aot_builtin.throw_statement_route,
                        .opcode = aot_builtin.throw_statement_opcode,
                        .siteId = formatSiteId(&site_id_text, site_id),
                        .function = function.name,
                        .source = .{
                            .line = throw_value.span.line + 1,
                            .column = @max(@as(usize, 1), throw_value.span.column),
                            .sourceStart = throw_value.span.source_start,
                            .sourceEnd = throw_value.span.source_end,
                        },
                    });
                },
                else => {},
            }
        }
    }
    try writer.flush();
    keep_file = false;
    return entry_count;
}

fn formatSiteId(buffer: *[18]u8, site_id: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "0x{x:0>16}", .{site_id}) catch unreachable;
}

/// Completes a manifest after LLVM emission and linking have succeeded.  A
/// missing completion record deliberately means that the preceding file is
/// only a partial validation artifact.
pub fn completeBuiltinManifest(io: std.Io, manifest_path: []const u8, entry_count: usize) !void {
    if (!std.fs.path.isAbsolute(manifest_path)) return error.ManifestPathMustBeAbsolute;
    var file = try std.Io.Dir.openFileAbsolute(io, manifest_path, .{ .mode = .read_write });
    defer file.close(io);
    const stat = try file.stat(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try file_writer.seekTo(stat.size);
    try writeManifestLine(&file_writer.interface, ManifestComplete{
        .schema = manifest_schema,
        .phase = "pre-opt",
        .kind = "complete",
        .complete = true,
        .entryCount = entry_count,
    });
    try file_writer.interface.flush();
}

/// Writes a separate JSONL manifest for statically lowered global reads. It is
/// intentionally not part of the builtin manifest because a constant lookup
/// is a load, not a builtin dispatch call.
pub fn writeGlobalManifest(allocator: std.mem.Allocator, io: std.Io, program: ir.Program, source_path: []const u8, manifest_path: []const u8) !usize {
    if (!std.fs.path.isAbsolute(manifest_path)) return error.ManifestPathMustBeAbsolute;

    var file = try std.Io.Dir.createFileAbsolute(io, manifest_path, .{ .exclusive = true });
    var keep_file = true;
    defer {
        file.close(io);
        if (keep_file) std.Io.Dir.deleteFileAbsolute(io, manifest_path) catch {};
    }

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    var seen_site_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen_site_ids.deinit(allocator);
    try writeManifestLine(writer, GlobalManifestHeader{
        .schema = global_manifest_schema,
        .phase = "pre-opt",
        .sourcePath = source_path,
        .siteIdEncoding = "u64-hex16",
    });
    var entry_count: usize = 0;
    for (program.functions) |function| {
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.opcode != .load_global) continue;
                const site_id = instruction.global_site_id orelse return error.MissingGlobalSiteId;
                if (seen_site_ids.contains(site_id)) return error.ManifestSiteIdCollision;
                try seen_site_ids.put(allocator, site_id, {});
                var site_id_text: [18]u8 = undefined;
                entry_count += 1;
                try writeManifestLine(writer, GlobalManifestEntry{
                    .schema = global_manifest_schema,
                    .phase = "pre-opt",
                    .kind = "global-load",
                    .name = instruction.name,
                    .siteId = formatSiteId(&site_id_text, site_id),
                    .function = function.name,
                    .source = .{
                        .line = instruction.span.line + 1,
                        .column = @max(@as(usize, 1), instruction.span.column),
                        .sourceStart = instruction.span.source_start,
                        .sourceEnd = instruction.span.source_end,
                    },
                });
            }
        }
    }
    try writer.flush();
    keep_file = false;
    return entry_count;
}

pub fn completeGlobalManifest(io: std.Io, manifest_path: []const u8, entry_count: usize) !void {
    if (!std.fs.path.isAbsolute(manifest_path)) return error.ManifestPathMustBeAbsolute;
    var file = try std.Io.Dir.openFileAbsolute(io, manifest_path, .{ .mode = .read_write });
    defer file.close(io);
    const stat = try file.stat(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try file_writer.seekTo(stat.size);
    try writeManifestLine(&file_writer.interface, GlobalManifestComplete{
        .schema = global_manifest_schema,
        .phase = "pre-opt",
        .kind = "complete",
        .complete = true,
        .entryCount = entry_count,
    });
    try file_writer.interface.flush();
}

/// Writes a separate JSONL manifest for catalog constants lowered directly to
/// typed literals. This must stay separate from both builtin dispatch and
/// global-read manifests because no runtime global lookup occurs.
pub fn writeLiteralManifest(allocator: std.mem.Allocator, io: std.Io, program: ir.Program, source_path: []const u8, manifest_path: []const u8) !usize {
    if (!std.fs.path.isAbsolute(manifest_path)) return error.ManifestPathMustBeAbsolute;

    var file = try std.Io.Dir.createFileAbsolute(io, manifest_path, .{ .exclusive = true });
    var keep_file = true;
    defer {
        file.close(io);
        if (keep_file) std.Io.Dir.deleteFileAbsolute(io, manifest_path) catch {};
    }

    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    var seen_site_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen_site_ids.deinit(allocator);
    try writeManifestLine(writer, LiteralManifestHeader{
        .schema = literal_manifest_schema,
        .phase = "pre-opt",
        .sourcePath = source_path,
        .siteIdEncoding = "u64-hex16",
    });
    var entry_count: usize = 0;
    for (program.functions) |function| {
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                const site_id = instruction.literal_site_id orelse continue;
                if (instruction.opcode != .const_boolean and instruction.opcode != .const_null) return error.InvalidLiteralSite;
                if (seen_site_ids.contains(site_id)) return error.ManifestSiteIdCollision;
                try seen_site_ids.put(allocator, site_id, {});
                var site_id_text: [18]u8 = undefined;
                entry_count += 1;
                try writeManifestLine(writer, LiteralManifestEntry{
                    .schema = literal_manifest_schema,
                    .phase = "pre-opt",
                    .kind = "literal-constant",
                    .name = instruction.text,
                    .siteId = formatSiteId(&site_id_text, site_id),
                    .function = function.name,
                    .source = .{
                        .line = instruction.span.line + 1,
                        .column = @max(@as(usize, 1), instruction.span.column),
                        .sourceStart = instruction.span.source_start,
                        .sourceEnd = instruction.span.source_end,
                    },
                });
            }
        }
    }
    try writer.flush();
    keep_file = false;
    return entry_count;
}

pub fn completeLiteralManifest(io: std.Io, manifest_path: []const u8, entry_count: usize) !void {
    if (!std.fs.path.isAbsolute(manifest_path)) return error.ManifestPathMustBeAbsolute;
    var file = try std.Io.Dir.openFileAbsolute(io, manifest_path, .{ .mode = .read_write });
    defer file.close(io);
    const stat = try file.stat(io);
    var buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    try file_writer.seekTo(stat.size);
    try writeManifestLine(&file_writer.interface, LiteralManifestComplete{
        .schema = literal_manifest_schema,
        .phase = "pre-opt",
        .kind = "complete",
        .complete = true,
        .entryCount = entry_count,
    });
    try file_writer.interface.flush();
}

fn writeManifestLine(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{}, writer);
    try writer.writeByte('\n');
}

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
                .increment,
                .phi,
                .speed_mode_begin,
                .speed_mode_end,
                .performance_monitor_begin,
                .performance_monitor_end,
                .try_begin,
                .try_end,
                .exception_pending,
                .exception_take,
                => true,
                .const_bigint => true,
                .destructure_store => destructureSourceSupported(function, instruction),
                .const_string => true,
                .binary => arithmeticOpcode(instruction.operator) != null or comparisonPredicate(instruction.operator) != null or
                    shiftOpcode(instruction.operator) != null or
                    std.mem.eql(u8, instruction.operator, "&") or
                    std.mem.eql(u8, instruction.operator, "&&") or std.mem.eql(u8, instruction.operator, "and") or
                    std.mem.eql(u8, instruction.operator, "||") or std.mem.eql(u8, instruction.operator, "or"),
                .unary => std.mem.eql(u8, instruction.operator, "!") or std.mem.eql(u8, instruction.operator, "not") or
                    std.mem.eql(u8, instruction.operator, "+") or std.mem.eql(u8, instruction.operator, "-"),
                .call => isDisplayCall(instruction.name) or aot_builtin.lookup(instruction.name) != null or validDirectCallee(program, instruction) or lookupFunction(program, instruction.name) != null or
                    isDynamicNamedCall(function, instruction.name) or isNativePluginCall(program, function, instruction),
                .call_value => instruction.operands.len > 0,
                .make_closure => closureSupported(program, function, instruction.name),
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
            .branch, .conditional_branch, .return_value, .throw_value, .propagate_exception, .unreachable_terminator => {},
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

const StringConstant = struct { function_id: ir.FunctionId, value_id: ir.ValueId, units: []u16, index: usize };
const DebugPathConstant = struct { path: []const u8 };
const SystemStringConstant = struct { global_index: usize, units: []u16 };
const BigIntConstant = struct { function_id: ir.FunctionId, value_id: ir.ValueId, text: []const u8, index: usize };
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
    debug_paths: std.ArrayList(DebugPathConstant) = .empty,
    system_strings: std.ArrayList(SystemStringConstant) = .empty,
    native_plugin_names: std.ArrayList([]const u8) = .empty,
    system_arrays: std.ArrayList(usize) = .empty,
    system_dictionaries: std.ArrayList(usize) = .empty,
    system_era_data: std.ArrayList(usize) = .empty,
    bigints: std.ArrayList(BigIntConstant) = .empty,
    locations: std.ArrayList(DebugLocation) = .empty,
    next_metadata: usize = 4,

    fn deinit(self: *Emitter) void {
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
        for (self.globals.items, 0..) |name, index| {
            try writer.print("@lnako.global.{d} = internal global %lnako.Value ", .{index});
            try writeScalarInitializer(writer, system_constant.lookupScalar(name));
            try writer.writeByte('\n');
        }
        if (self.globals.items.len > 0) try writer.writeByte('\n');
        if (self.hasDynamicBuiltin()) for (self.globals.items, 0..) |name, index| {
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
        if (self.hasDynamicBuiltin() and self.globals.items.len > 0) try writer.writeByte('\n');
        for (self.native_plugin_names.items, 0..) |name, index| {
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
        for (self.program.native_plugin_paths, 0..) |path, index| {
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
        if (self.native_plugin_names.items.len > 0 or self.program.native_plugin_paths.len > 0) try writer.writeByte('\n');
        for (self.strings.items) |constant| {
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
        if (self.strings.items.len > 0) try writer.writeByte('\n');
        for (self.debug_paths.items, 0..) |constant, index| {
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
        if (self.debug_paths.items.len > 0) try writer.writeByte('\n');
        for (self.program.functions) |function| {
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
        if (self.program.functions.len > 0) try writer.writeByte('\n');
        for (self.system_strings.items, 0..) |constant, index| {
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
        if (self.system_strings.items.len > 0) try writer.writeByte('\n');
        if (self.needsNodeMotherPath()) {
            try writer.print("@lnako.node.source.path = private unnamed_addr constant [{d} x i8] ", .{self.source_path.len});
            if (self.source_path.len == 0) {
                try writer.writeAll("zeroinitializer\n");
            } else {
                try writer.writeByte('[');
                for (self.source_path, 0..) |byte, index| {
                    if (index > 0) try writer.writeAll(", ");
                    try writer.print("i8 {d}", .{byte});
                }
                try writer.writeAll("]\n");
            }
            try writer.writeByte('\n');
        }
        for (self.bigints.items) |constant| {
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
        if (self.bigints.items.len > 0) try writer.writeByte('\n');
        try self.writeRuntimeHelpers();
        for (self.program.functions) |function| try self.writeFunction(function);
        for (self.program.functions) |function| try self.writeFunctionWrapper(function);
        try self.writeMain();
        try self.writeDebugMetadata();
    }

    fn collectModuleData(self: *Emitter) !void {
        var string_index: usize = 0;
        var bigint_index: usize = 0;
        try self.globals.append(self.allocator, "それ");
        for (self.program.functions) |function| {
            if (!isNamedGlobalFunction(function.name) or self.globalIndex(function.name) != null) continue;
            try self.globals.append(self.allocator, function.name);
        }
        for (self.program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
            if ((instruction.opcode == .load_global or instruction.opcode == .store_global) and self.globalIndex(instruction.name) == null) {
                try self.globals.append(self.allocator, instruction.name);
            }
            if (instruction.opcode == .destructure_store) for (instruction.names) |name| {
                if (isQualifiedGlobal(name) and self.globalIndex(name) == null) try self.globals.append(self.allocator, name);
            };
            if (instruction.opcode == .increment and isQualifiedGlobal(instruction.name) and self.globalIndex(instruction.name) == null) {
                try self.globals.append(self.allocator, instruction.name);
            }
            if (instruction.opcode == .exception_take and self.globalIndex("エラーメッセージ") == null) {
                try self.globals.append(self.allocator, "エラーメッセージ");
            }
            if (instruction.opcode == .call and instruction.direct_callee == null) {
                if (isNativePluginCall(self.program, function, instruction) and self.nativePluginNameIndex(instruction.name) == null) {
                    try self.native_plugin_names.append(self.allocator, instruction.name);
                }
                if (instruction.is_builtin_call and requiresDisplayLog(instruction.name) and self.globalIndex("表示ログ") == null) {
                    try self.globals.append(self.allocator, "表示ログ");
                }
                if (instruction.is_builtin_call) if (aot_builtin.lookup(instruction.name)) |command| if (command == .system_debug_display or command == .system_hatena_execute) {
                    const path = self.sourcePathForFunction(function.name);
                    if (self.debugPathIndex(path) == null) try self.debug_paths.append(self.allocator, .{ .path = path });
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (command == .system_debug_breakpoint_wait) {
                    for ([_][]const u8{ "__DEBUGブレイクポイント一覧", "__DEBUG強制待機", "__DEBUG待機フラグ", "プラグイン名" }) |name| {
                        if (self.globalIndex(name) == null) try self.globals.append(self.allocator, name);
                    }
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (command == .cut or command == .cut_range) {
                    if (self.globalIndex("対象") == null) try self.globals.append(self.allocator, "対象");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (isTimerCommand(command)) {
                    if (self.globalIndex("対象") == null) try self.globals.append(self.allocator, "対象");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (command == .node_stdin_callback) {
                    if (self.globalIndex("対象") == null) try self.globals.append(self.allocator, "対象");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (isNodeFileCallbackCommand(command)) {
                    if (self.globalIndex("対象") == null) try self.globals.append(self.allocator, "対象");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (isPromiseCommand(command)) {
                    if (self.globalIndex("そ") == null) try self.globals.append(self.allocator, "そ");
                    if (self.globalIndex("対象") == null) try self.globals.append(self.allocator, "対象");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (command == .regexp_match or command == .regexp_extract) {
                    if (self.globalIndex("抽出文字列") == null) try self.globals.append(self.allocator, "抽出文字列");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (isPluginManagementCommand(command)) {
                    if (self.globalIndex("プラグイン名") == null) try self.globals.append(self.allocator, "プラグイン名");
                    if (self.globalIndex("名前空間") == null) try self.globals.append(self.allocator, "名前空間");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (command == .node_archive_tool_path_set) {
                    if (self.globalIndex("圧縮解凍ツールパス") == null) try self.globals.append(self.allocator, "圧縮解凍ツールパス");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (isArchiveCommand(command)) {
                    if (self.globalIndex("圧縮解凍ツールパス") == null) try self.globals.append(self.allocator, "圧縮解凍ツールパス");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (command == .node_ajax_options_set) {
                    if (self.globalIndex("AJAXオプション") == null) try self.globals.append(self.allocator, "AJAXオプション");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (command == .node_ajax_onerror_set) {
                    if (self.globalIndex("AJAX:ONERROR") == null) try self.globals.append(self.allocator, "AJAX:ONERROR");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (isNodeHttpCommand(command)) {
                    for ([_][]const u8{ "AJAXオプション", "AJAX:ONERROR", "対象" }) |name| {
                        if (self.globalIndex(name) == null) try self.globals.append(self.allocator, name);
                    }
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (isNodeFileOperationCommand(command)) {
                    if (self.globalIndex("ファイルコピーデフォルト動作") == null) try self.globals.append(self.allocator, "ファイルコピーデフォルト動作");
                };
                if (aot_builtin.lookup(instruction.name)) |command| if (isHttpServerCommand(command)) {
                    for ([_][]const u8{ "HTTPメソッド", "GETデータ", "POSTデータ", "FILESデータ" }) |name| {
                        if (self.globalIndex(name) == null) try self.globals.append(self.allocator, name);
                    }
                };
            }
            if (instruction.opcode == .const_string) {
                const value_id = instruction.result orelse return error.InvalidStringConstant;
                const units = try std.unicode.utf8ToUtf16LeAlloc(self.allocator, instruction.text);
                self.strings.append(self.allocator, .{
                    .function_id = function.id,
                    .value_id = value_id,
                    .units = units,
                    .index = string_index,
                }) catch |failure| {
                    self.allocator.free(units);
                    return failure;
                };
                string_index += 1;
            }
            if (instruction.opcode == .const_bigint) {
                try self.bigints.append(self.allocator, .{
                    .function_id = function.id,
                    .value_id = instruction.result orelse return error.InvalidBigIntConstant,
                    .text = instruction.text,
                    .index = bigint_index,
                });
                bigint_index += 1;
            }
        };
        for (self.globals.items, 0..) |name, global_index| if (self.systemStringValue(name)) |value| {
            const units = try std.unicode.utf8ToUtf16LeAlloc(self.allocator, value);
            self.system_strings.append(self.allocator, .{ .global_index = global_index, .units = units }) catch |failure| {
                self.allocator.free(units);
                return failure;
            };
        };
        for (self.globals.items, 0..) |name, global_index| {
            if (system_constant.isArray(name)) try self.system_arrays.append(self.allocator, global_index);
            if (system_constant.isDictionary(name)) try self.system_dictionaries.append(self.allocator, global_index);
            if (system_constant.isEraData(name)) try self.system_era_data.append(self.allocator, global_index);
        }
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

    fn writeFunction(self: *Emitter, function: ir.Function) !void {
        const scope = 4 + function.id;
        try self.output.writer.print("define internal %lnako.Value @lnako.fn.{d}(ptr %context", .{function.id});
        for (function.parameters, 0..) |_, index| {
            try self.output.writer.print(", %lnako.Value %arg.{d}", .{index});
        }
        try self.output.writer.print(") !dbg !{d} {{\n", .{scope});
        const locals = try self.localNames(function);
        defer self.allocator.free(locals);
        const value_root_count = functionValueCount(function);
        const root_count = value_root_count + locals.len;
        const root_storage_count = @max(@as(usize, 1), root_count);
        const aggregate_count = @max(maxAggregateOperandCount(function), maxClosureCaptureCount(self.program, function));
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
                for (function.parameters, 0..) |parameter, index| {
                    try self.output.writer.print("  store %lnako.Value %arg.{d}, ptr %root.slot.{d}\n", .{ index, parameter.value });
                }
                for (locals, 0..) |name, index| {
                    const cell_root = value_root_count + index;
                    if (nameIndex(function.captures, name)) |capture_index| {
                        try self.output.writer.print("  call void @lnako_aot_function_capture(ptr %root.slot.{d}, ptr %context, i64 {d})\n", .{ cell_root, capture_index });
                    } else {
                        try self.output.writer.print("  call void @lnako_aot_binding_cell_new(ptr %root.slot.{d}, ptr ", .{cell_root});
                        if (parameterIndex(function, name)) |parameter_index| {
                            try self.output.writer.print("%root.slot.{d}", .{function.parameters[parameter_index].value});
                        } else try self.output.writer.writeAll("null");
                        try self.output.writer.writeAll(")\n");
                    }
                    try self.output.writer.print("  %local.{d} = call ptr @lnako_aot_binding_cell_value(ptr %root.slot.{d})\n", .{ index, cell_root });
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
            .const_boolean => {
                if (instruction.literal_site_id) |site_id| try self.output.writer.print("  call void @lnako_aot_literal_site(i64 {d})\n", .{site_id});
                try self.writeBoxConstant(result orelse return error.MissingInstructionResult, 2, @intFromBool(instruction.boolean_value), instruction.span, scope);
            },
            .const_null => {
                if (instruction.literal_site_id) |site_id| try self.output.writer.print("  call void @lnako_aot_literal_site(i64 {d})\n", .{site_id});
                try self.writeBoxConstant(result orelse return error.MissingInstructionResult, 1, 0, instruction.span, scope);
            },
            .const_undefined => try self.writeBoxConstant(result orelse return error.MissingInstructionResult, 0, 0, instruction.span, scope),
            .const_bigint => {
                const id = result orelse return error.MissingInstructionResult;
                const constant = self.bigintConstant(function.id, id) orelse return error.InvalidBigIntConstant;
                try self.output.writer.print("  call void @lnako_aot_bigint_new(ptr %root.slot.{d}, ptr @lnako.bigint.{d}, i64 {d})", .{ id, constant.index, constant.text.len });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ id, id });
                try self.debugSuffix(instruction.span, scope);
            },
            .const_string => {
                const id = result orelse return error.MissingInstructionResult;
                const constant = self.stringConstant(function.id, id) orelse return error.InvalidStringConstant;
                try self.output.writer.print("  call void @lnako_aot_string_new(ptr %root.slot.{d}, ptr @lnako.string.{d}, i64 {d})", .{ id, constant.index, constant.units.len });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ id, id });
                try self.debugSuffix(instruction.span, scope);
            },
            .load_global => {
                const index = self.globalIndex(instruction.name) orelse return error.UnknownGlobal;
                if (instruction.global_site_id) |site_id| {
                    try self.output.writer.print("  call void @lnako_aot_global_read_site(i64 {d})", .{site_id});
                    try self.debugSuffix(instruction.span, scope);
                }
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
            .call => try self.writeCall(function, locals, instruction, scope, aggregate_count),
            .call_value => try self.writeCallValue(function, instruction, scope, aggregate_count),
            .make_closure => try self.writeMakeClosure(function, locals, instruction, scope, aggregate_count),
            .make_array => try self.writeAggregate(function, instruction, scope, aggregate_count, "lnako_aot_array_new"),
            .make_object => try self.writeAggregate(function, instruction, scope, aggregate_count, "lnako_aot_dictionary_new"),
            .array_get, .property_get => try self.writeIndexGet(instruction, scope),
            .array_set, .property_set => try self.writeIndexSet(locals, instruction, scope),
            .increment => try self.writeIncrement(locals, instruction, scope),
            .iterator_begin => try self.writeIteratorBegin(function, instruction, scope, aggregate_count),
            .iterator_has_next => try self.writeIteratorHasNext(instruction, scope),
            .iterator_next => try self.writeIteratorNext(function, locals, instruction, scope),
            .try_begin, .try_end => {},
            .exception_pending => {
                const id = result orelse return error.MissingInstructionResult;
                try self.output.writer.print("  %exception.pending.i32.{d} = call i32 @lnako_aot_exception_pending()", .{id});
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.print("  %exception.pending.i1.{d} = icmp ne i32 %exception.pending.i32.{d}, 0", .{ id, id });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.print("  %exception.pending.bits.{d} = zext i1 %exception.pending.i1.{d} to i64", .{ id, id });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 2, i64 0 }}, i64 %exception.pending.bits.{d}, 1", .{ id, id });
                try self.debugSuffix(instruction.span, scope);
            },
            .exception_take => {
                const error_index = self.globalIndex("エラーメッセージ") orelse return error.MissingErrorMessageGlobal;
                try self.output.writer.print("  call void @lnako_aot_exception_take(ptr @lnako.global.{d})", .{error_index});
                try self.debugSuffix(instruction.span, scope);
            },
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
            try self.output.writer.writeAll("  call void @lnako_aot_destructure_get(ptr ");
            try self.writeRequiredNamedPointer(locals, name);
            try self.output.writer.print(", ptr %root.slot.{d}, i64 {d})", .{ instruction.operands[0], index });
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
        const literal_tag: ?u8 = if (std.mem.eql(u8, instruction.name, "NULL")) 1 else if (std.mem.eql(u8, instruction.name, "undefined")) 0 else null;
        if (literal_tag) |tag| {
            try self.output.writer.print("  store %lnako.Value {{ i8 {d}, i64 0 }}, ptr %runtime.scratch", .{tag});
            try self.debugSuffix(instruction.span, scope);
        }
        try self.output.writer.print("  %set.container.{d} = load %lnako.Value, ptr ", .{temporary});
        try self.writeAssignmentContainerPointer(locals, instruction.name, literal_tag != null);
        try self.debugSuffix(instruction.span, scope);
        for (instruction.operands[1 .. instruction.operands.len - 1], 0..) |key, index| {
            try self.output.writer.writeAll("  call void @lnako_aot_index_get(ptr %runtime.scratch, ptr ");
            if (index == 0) {
                try self.writeAssignmentContainerPointer(locals, instruction.name, literal_tag != null);
            } else try self.output.writer.writeAll("%runtime.scratch");
            try self.output.writer.print(", ptr %root.slot.{d})", .{key});
            try self.debugSuffix(instruction.span, scope);
        }
        try self.output.writer.print("  %set.status.{d} = call i32 @lnako_aot_index_set(ptr ", .{temporary});
        if (instruction.operands.len == 2) {
            try self.writeAssignmentContainerPointer(locals, instruction.name, literal_tag != null);
        } else try self.output.writer.writeAll("%runtime.scratch");
        try self.output.writer.print(", ptr %root.slot.{d}, ptr %root.slot.{d})", .{ instruction.operands[instruction.operands.len - 1], instruction.operands[0] });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeAssignmentContainerPointer(self: *Emitter, locals: []const []const u8, name: []const u8, literal: bool) !void {
        if (literal) return self.output.writer.writeAll("%runtime.scratch");
        if (nameIndex(locals, name)) |index| return self.output.writer.print("%local.{d}", .{index});
        if (self.globalIndex(name)) |index| return self.output.writer.print("@lnako.global.{d}", .{index});
        return error.UnknownAssignmentContainer;
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
        if (std.mem.eql(u8, instruction.operator, "&")) return self.writeConcat(instruction, scope);
        if (runtimeArithmeticOpcode(instruction.operator)) |opcode| {
            return self.writeArithmetic(function, instruction, scope, opcode);
        }
        if (shiftOpcode(instruction.operator)) |opcode| {
            return self.writeShift(instruction, scope, opcode);
        }
        if (comparisonOpcode(instruction.operator)) |opcode| {
            return self.writeComparison(instruction, scope, opcode);
        }
        return error.UnsupportedBinaryOperator;
    }

    fn writeArithmetic(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, opcode_value: u8) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (instruction.operands.len < 2) return error.InvalidBinaryInstruction;
        const proven_number = self.optimized and valueType(function, instruction.operands[0]) == .number and valueType(function, instruction.operands[1]) == .number;
        if (!proven_number) {
            try self.output.writer.print("  call void @lnako_aot_arithmetic(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr %root.slot.{d}, i8 {d})", .{ result, instruction.operands[0], instruction.operands[1], opcode_value });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        const left_label = try std.fmt.allocPrint(self.allocator, "left.number.{d}", .{result});
        defer self.allocator.free(left_label);
        const right_label = try std.fmt.allocPrint(self.allocator, "right.number.{d}", .{result});
        defer self.allocator.free(right_label);
        try self.writeNumberOperand(function, instruction.operands[0], left_label, instruction.span, scope);
        try self.writeNumberOperand(function, instruction.operands[1], right_label, instruction.span, scope);

        const opcode = arithmeticOpcode(instruction.operator) orelse return error.UnsupportedBinaryOperator;
        if (std.mem.eql(u8, opcode, "pow")) {
            try self.output.writer.print("  %binary.number.{d} = call double @llvm.pow.f64(double %left.number.{d}, double %right.number.{d})", .{ result, result, result });
        } else if (std.mem.eql(u8, opcode, "divfloor")) {
            try self.output.writer.print("  %binary.quotient.{d} = fdiv double %left.number.{d}, %right.number.{d}", .{ result, result, result });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %binary.number.{d} = call double @llvm.floor.f64(double %binary.quotient.{d})", .{ result, result });
        } else {
            try self.output.writer.print("  %binary.number.{d} = {s} double %left.number.{d}, %right.number.{d}", .{ result, opcode, result, result });
        }
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %binary.bits.{d} = bitcast double %binary.number.{d} to i64", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = insertvalue %lnako.Value {{ i8 3, i64 0 }}, i64 %binary.bits.{d}, 1", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeComparison(self: *Emitter, instruction: ir.Instruction, scope: usize, opcode: u8) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (instruction.operands.len < 2) return error.InvalidBinaryInstruction;
        try self.output.writer.print("  call void @lnako_aot_compare(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr %root.slot.{d}, i8 {d})", .{ result, instruction.operands[0], instruction.operands[1], opcode });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeShift(self: *Emitter, instruction: ir.Instruction, scope: usize, opcode: u8) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (instruction.operands.len < 2) return error.InvalidBinaryInstruction;
        try self.output.writer.print("  call void @lnako_aot_shift(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr %root.slot.{d}, i8 {d})", .{ result, instruction.operands[0], instruction.operands[1], opcode });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeConcat(self: *Emitter, instruction: ir.Instruction, scope: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (instruction.operands.len < 2) return error.InvalidBinaryInstruction;
        try self.output.writer.print("  call void @lnako_aot_concat(ptr %root.slot.{d}, ptr %root.slot.{d}, ptr %root.slot.{d})", .{ result, instruction.operands[0], instruction.operands[1] });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeIncrement(self: *Emitter, locals: []const []const u8, instruction: ir.Instruction, scope: usize) !void {
        if (instruction.operands.len != 1) return error.InvalidIncrement;
        try self.output.writer.writeAll("  call void @lnako_aot_increment(ptr ");
        try self.writeRequiredNamedPointer(locals, instruction.name);
        try self.output.writer.print(", ptr %root.slot.{d})", .{instruction.operands[0]});
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

    fn writeCall(self: *Emitter, function: ir.Function, locals: []const []const u8, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (instruction.direct_callee == null and instruction.is_builtin_call and isDisplayCall(instruction.name)) {
            return self.writeDisplayCall(function, instruction, scope, aggregate_count);
        }
        if (instruction.direct_callee == null and instruction.is_builtin_call) if (aot_builtin.lookup(instruction.name)) |command| {
            if (command == .regexp_match or command == .regexp_extract or command == .regexp_replace or command == .regexp_split) {
                try self.writeRegexpCall(function, instruction, scope, aggregate_count, command);
                try self.writeCallResult(result, instruction.span, scope);
                return;
            }
            try self.writeBuiltinCall(function, instruction, scope, aggregate_count, command);
            try self.writeCallResult(result, instruction.span, scope);
            return;
        };
        const callee = if (instruction.direct_callee) |callee_id|
            if (callee_id < self.program.functions.len) self.program.functions[callee_id] else return error.InvalidDirectCallee
        else
            self.findFunction(instruction.name);
        if (callee == null) {
            if (isNativePluginCall(self.program, function, instruction)) {
                try self.writeNativePluginCall(function, instruction, scope, aggregate_count);
            } else {
                try self.writeDynamicCall(function, locals, instruction, .{ .name = instruction.name }, instruction.operands, scope, aggregate_count);
            }
            try self.writeCallResult(result, instruction.span, scope);
            return;
        }
        try self.output.writer.print("  %v{d} = call %lnako.Value @lnako.fn.{d}(ptr null", .{ result, callee.?.id });
        for (instruction.operands) |operand| {
            try self.output.writer.writeAll(", %lnako.Value ");
            try self.writeValueRef(function, operand);
        }
        try self.output.writer.writeByte(')');
        try self.debugSuffix(instruction.span, scope);
        try self.writeCallResult(result, instruction.span, scope);
    }

    fn writeDisplayCall(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        const site_id = instruction.site_id orelse return error.MissingDispatchSiteId;
        const display_log_index = self.globalIndex("表示ログ") orelse return error.MissingDisplayLogGlobal;
        if (std.mem.eql(u8, instruction.name, "連続表示")) {
            if (instruction.operands.len > aggregate_count) return error.InvalidCallScratch;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %display.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %display.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  %v{d} = call %lnako.Value @lnako.display_many(ptr ", .{result});
            if (instruction.operands.len > 0) try self.output.writer.print("%display.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i64 {d}, ptr @lnako.global.{d})", .{ instruction.operands.len, site_id, display_log_index });
        } else {
            if (instruction.operands.len == 0) return error.InvalidCall;
            try self.output.writer.print("  %v{d} = call %lnako.Value @lnako.display(%lnako.Value ", .{result});
            try self.writeValueRef(function, instruction.operands[instruction.operands.len - 1]);
            try self.output.writer.print(", i1 true, i64 {d}, ptr @lnako.global.{d})", .{ site_id, display_log_index });
        }
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeCallValue(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
        if (instruction.operands.len == 0) return error.InvalidCall;
        try self.writeDynamicCall(function, &.{}, instruction, .{ .value = instruction.operands[0] }, instruction.operands[1..], scope, aggregate_count);
    }

    fn writeBuiltinCall(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize, command: aot_builtin.Command) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        const site_id = instruction.site_id orelse return error.MissingDispatchSiteId;
        if (instruction.operands.len > aggregate_count) return error.InvalidCallScratch;
        if (command == .system_nadesiko or command == .system_nadesiko_continue) {
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %dynamic.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %dynamic.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_dynamic_call(ptr %root.slot.{d}, ptr ", .{result});
            if (instruction.operands.len > 0) {
                try self.output.writer.print("%dynamic.{d}.slot.0", .{result});
            } else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (command == .system_debug_display or command == .system_hatena_execute) {
            const display_log_index = self.globalIndex("表示ログ") orelse return error.MissingDisplayLogGlobal;
            const source_path = self.sourcePathForFunction(function.name);
            const path_index = self.debugPathIndex(source_path) orelse return error.MissingDebugSourcePath;
            const runtime_name = if (command == .system_hatena_execute) "lnako_aot_hatena_execute" else "lnako_aot_debug_display";
            if (instruction.operands.len > 0) {
                try self.output.writer.print("  %debug-display.{d}.slot.0 = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 0", .{ result, aggregate_count });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, instruction.operands[instruction.operands.len - 1]);
                try self.output.writer.print(", ptr %debug-display.{d}.slot.0", .{result});
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @{s}(ptr %root.slot.{d}, ptr ", .{ runtime_name, result });
            if (instruction.operands.len > 0) {
                try self.output.writer.print("%debug-display.{d}.slot.0", .{result});
            } else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, ptr @lnako.debug.path.{d}, i64 {d}, ptr @lnako.global.{d}, i64 {d})", .{
                instruction.span.line + 1,
                path_index,
                source_path.len,
                display_log_index,
                site_id,
            });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (command == .system_debug_breakpoint_wait) {
            const breakpoints_index = self.globalIndex("__DEBUGブレイクポイント一覧") orelse return error.MissingDebugBreakpointsGlobal;
            const force_wait_index = self.globalIndex("__DEBUG強制待機") orelse return error.MissingDebugForceWaitGlobal;
            const wait_flag_index = self.globalIndex("__DEBUG待機フラグ") orelse return error.MissingDebugWaitFlagGlobal;
            const plugin_name_index = self.globalIndex("プラグイン名") orelse return error.MissingPluginNameGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %debug-breakpoint-wait.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %debug-breakpoint-wait.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_debug_breakpoint_wait_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr ", .{ result, breakpoints_index, force_wait_index, wait_flag_index, plugin_name_index });
            if (instruction.operands.len > 0) try self.output.writer.print("%debug-breakpoint-wait.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (isTimerCommand(command)) {
            const target_index = self.globalIndex("対象") orelse return error.MissingTargetGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %timer.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %timer.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_timer_call_site(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, target_index });
            if (instruction.operands.len > 0) {
                try self.output.writer.print("%timer.{d}.slot.0", .{result});
            } else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (command == .node_stdin_callback) {
            const target_index = self.globalIndex("対象") orelse return error.MissingTargetGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %node-stdin-callback.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %node-stdin-callback.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_node_stdin_callback_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, target_index });
            if (instruction.operands.len > 0) {
                try self.output.writer.print("%node-stdin-callback.{d}.slot.0", .{result});
            } else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (isHttpServerCommand(command)) {
            const method_index = self.globalIndex("HTTPメソッド") orelse return error.MissingHttpMethodGlobal;
            const get_index = self.globalIndex("GETデータ") orelse return error.MissingGetDataGlobal;
            const post_index = self.globalIndex("POSTデータ") orelse return error.MissingPostDataGlobal;
            const files_index = self.globalIndex("FILESデータ") orelse return error.MissingFilesDataGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %http-server.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %http-server.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_http_server_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr ", .{ result, method_index, get_index, post_index, files_index });
            if (instruction.operands.len > 0) try self.output.writer.print("%http-server.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (isPromiseCommand(command)) {
            const last_promise_index = self.globalIndex("そ") orelse return error.MissingLastPromiseGlobal;
            const target_index = self.globalIndex("対象") orelse return error.MissingTargetGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %promise.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %promise.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_promise_call_site(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr ", .{ result, last_promise_index, target_index });
            if (instruction.operands.len > 0) {
                try self.output.writer.print("%promise.{d}.slot.0", .{result});
            } else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (isPluginManagementCommand(command)) {
            const plugin_name_index = self.globalIndex("プラグイン名") orelse return error.MissingPluginNameGlobal;
            const namespace_index = self.globalIndex("名前空間") orelse return error.MissingNamespaceGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %plugin-management.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %plugin-management.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_plugin_management_call(ptr %root.slot.{d}, ptr ", .{result});
            if (instruction.operands.len > 0) try self.output.writer.print("%plugin-management.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, i64 {d})", .{
                instruction.operands.len,
                @intFromEnum(command),
                plugin_name_index,
                namespace_index,
                site_id,
            });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (command == .node_archive_tool_path_set) {
            const archive_tool_path_index = self.globalIndex("圧縮解凍ツールパス") orelse return error.MissingArchiveToolPathGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %archive-tool-path.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %archive-tool-path.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_archive_tool_path_set(ptr %root.slot.{d}, ptr ", .{result});
            if (instruction.operands.len > 0) try self.output.writer.print("%archive-tool-path.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, ptr @lnako.global.{d}, i64 {d})", .{ instruction.operands.len, archive_tool_path_index, site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (isArchiveCommand(command)) {
            const archive_tool_path_index = self.globalIndex("圧縮解凍ツールパス") orelse return error.MissingArchiveToolPathGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %node-archive.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %node-archive.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_archive_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, archive_tool_path_index });
            if (instruction.operands.len > 0) try self.output.writer.print("%node-archive.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (isNodeProcessCommand(command)) {
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %node-process.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %node-process.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_node_process_call(ptr %root.slot.{d}, ptr ", .{result});
            if (instruction.operands.len > 0) try self.output.writer.print("%node-process.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (command == .node_ajax_options_set) {
            const ajax_options_index = self.globalIndex("AJAXオプション") orelse return error.MissingAjaxOptionsGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %ajax-options.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %ajax-options.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_ajax_options_set(ptr %root.slot.{d}, ptr ", .{result});
            if (instruction.operands.len > 0) try self.output.writer.print("%ajax-options.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, ptr @lnako.global.{d}, i64 {d})", .{ instruction.operands.len, ajax_options_index, site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (command == .node_ajax_onerror_set) {
            const ajax_onerror_index = self.globalIndex("AJAX:ONERROR") orelse return error.MissingAjaxOnerrorGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %ajax-onerror.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %ajax-onerror.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_ajax_onerror_set(ptr %root.slot.{d}, ptr ", .{result});
            if (instruction.operands.len > 0) try self.output.writer.print("%ajax-onerror.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, ptr @lnako.global.{d}, i64 {d})", .{ instruction.operands.len, ajax_onerror_index, site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (isNodeHttpCommand(command)) {
            const ajax_options_index = self.globalIndex("AJAXオプション") orelse return error.MissingAjaxOptionsGlobal;
            const ajax_onerror_index = self.globalIndex("AJAX:ONERROR") orelse return error.MissingAjaxOnerrorGlobal;
            const target_index = self.globalIndex("対象") orelse return error.MissingTargetGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %node-http.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %node-http.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_node_http_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr @lnako.global.{d}, ptr ", .{ result, ajax_options_index, ajax_onerror_index, target_index });
            if (instruction.operands.len > 0) {
                try self.output.writer.print("%node-http.{d}.slot.0", .{result});
            } else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (isNodeFileOperationCommand(command)) {
            const copy_default_index = self.globalIndex("ファイルコピーデフォルト動作") orelse return error.MissingFileCopyDefaultGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %file-operation.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %file-operation.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_file_operation_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, copy_default_index });
            if (instruction.operands.len > 0) try self.output.writer.print("%file-operation.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (isNodeFileCallbackCommand(command)) {
            const target_index = self.globalIndex("対象") orelse return error.MissingTargetGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %file-callback.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %file-callback.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_node_file_callback_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, target_index });
            if (instruction.operands.len > 0) try self.output.writer.print("%file-callback.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        if (isStdioCommand(command)) {
            const display_log_index = self.globalIndex("表示ログ") orelse return error.MissingDisplayLogGlobal;
            for (instruction.operands, 0..) |argument, index| {
                try self.output.writer.print("  %stdio.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
                try self.debugSuffix(instruction.span, scope);
                try self.output.writer.writeAll("  store %lnako.Value ");
                try self.writeValueRef(function, argument);
                try self.output.writer.print(", ptr %stdio.{d}.slot.{d}", .{ result, index });
                try self.debugSuffix(instruction.span, scope);
            }
            try self.output.writer.print("  call void @lnako_aot_stdio_call(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, display_log_index });
            if (instruction.operands.len > 0) try self.output.writer.print("%stdio.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
            try self.debugSuffix(instruction.span, scope);
            return;
        }
        for (instruction.operands, 0..) |argument, index| {
            try self.output.writer.print("  %builtin.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.writeAll("  store %lnako.Value ");
            try self.writeValueRef(function, argument);
            try self.output.writer.print(", ptr %builtin.{d}.slot.{d}", .{ result, index });
            try self.debugSuffix(instruction.span, scope);
        }
        if (command == .cut or command == .cut_range) {
            const target_index = self.globalIndex("対象") orelse return error.MissingTargetGlobal;
            const mode: u8 = if (command == .cut) 0 else 1;
            try self.output.writer.print("  call void @lnako_aot_cut_site(ptr %root.slot.{d}, ptr @lnako.global.{d}, ptr ", .{ result, target_index });
            if (instruction.operands.len > 0) {
                try self.output.writer.print("%builtin.{d}.slot.0", .{result});
            } else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i8 {d}, i64 {d})", .{ instruction.operands.len, mode, site_id });
        } else {
            try self.output.writer.print("  call void @lnako_aot_builtin_call_site(ptr %root.slot.{d}, ptr ", .{result});
            if (instruction.operands.len > 0) {
                try self.output.writer.print("%builtin.{d}.slot.0", .{result});
            } else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        }
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeRegexpCall(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize, command: aot_builtin.Command) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        const site_id = instruction.site_id orelse return error.MissingDispatchSiteId;
        if (instruction.operands.len > aggregate_count) return error.InvalidCallScratch;
        for (instruction.operands, 0..) |argument, index| {
            try self.output.writer.print("  %regexp.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.writeAll("  store %lnako.Value ");
            try self.writeValueRef(function, argument);
            try self.output.writer.print(", ptr %regexp.{d}.slot.{d}", .{ result, index });
            try self.debugSuffix(instruction.span, scope);
        }
        try self.output.writer.print("  call void @lnako_aot_regexp_call_site(ptr %root.slot.{d}, ptr ", .{result});
        if (command == .regexp_match or command == .regexp_extract) {
            const captures_index = self.globalIndex("抽出文字列") orelse return error.MissingCaptureGlobal;
            try self.output.writer.print("@lnako.global.{d}", .{captures_index});
        } else try self.output.writer.writeAll("null");
        try self.output.writer.writeAll(", ptr ");
        if (instruction.operands.len > 0) try self.output.writer.print("%regexp.{d}.slot.0", .{result}) else try self.output.writer.writeAll("null");
        try self.output.writer.print(", i64 {d}, i16 {d}, i64 {d})", .{ instruction.operands.len, @intFromEnum(command), site_id });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    const DynamicCallTarget = union(enum) { name: []const u8, value: ir.ValueId };

    fn writeDynamicCall(
        self: *Emitter,
        function: ir.Function,
        locals: []const []const u8,
        instruction: ir.Instruction,
        target: DynamicCallTarget,
        arguments: []const ir.ValueId,
        scope: usize,
        aggregate_count: usize,
    ) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        if (arguments.len > aggregate_count) return error.InvalidCallScratch;
        for (arguments, 0..) |argument, index| {
            try self.output.writer.print("  %call.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.writeAll("  store %lnako.Value ");
            try self.writeValueRef(function, argument);
            try self.output.writer.print(", ptr %call.{d}.slot.{d}", .{ result, index });
            try self.debugSuffix(instruction.span, scope);
        }
        try self.output.writer.print("  call void @lnako_aot_function_call(ptr %root.slot.{d}, ptr ", .{result});
        switch (target) {
            .name => |name| try self.writeRequiredNamedPointer(locals, name),
            .value => |value| try self.output.writer.print("%root.slot.{d}", .{value}),
        }
        try self.output.writer.writeAll(", ptr ");
        if (arguments.len > 0) {
            try self.output.writer.print("%call.{d}.slot.0", .{result});
        } else try self.output.writer.writeAll("null");
        try self.output.writer.print(", i64 {d})", .{arguments.len});
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeNativePluginCall(self: *Emitter, function: ir.Function, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        const name_index = self.nativePluginNameIndex(instruction.name) orelse return error.MissingNativePluginName;
        const site_id = instruction.site_id orelse 0;
        if (instruction.operands.len > aggregate_count) return error.InvalidCallScratch;
        for (instruction.operands, 0..) |argument, index| {
            try self.output.writer.print("  %native-plugin.{d}.slot.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.writeAll("  store %lnako.Value ");
            try self.writeValueRef(function, argument);
            try self.output.writer.print(", ptr %native-plugin.{d}.slot.{d}", .{ result, index });
            try self.debugSuffix(instruction.span, scope);
        }
        try self.output.writer.print("  call void @lnako_aot_native_plugin_call(ptr %root.slot.{d}, ptr ", .{result});
        if (instruction.operands.len > 0) {
            try self.output.writer.print("%native-plugin.{d}.slot.0", .{result});
        } else try self.output.writer.writeAll("null");
        try self.output.writer.print(", i64 {d}, ptr @lnako.native.plugin.name.{d}, i64 {d}, i64 {d})", .{ instruction.operands.len, name_index, instruction.name.len, site_id });
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeMakeClosure(self: *Emitter, caller: ir.Function, locals: []const []const u8, instruction: ir.Instruction, scope: usize, aggregate_count: usize) !void {
        const result = instruction.result orelse return error.MissingInstructionResult;
        const function = lookupFunction(self.program, instruction.name) orelse return error.UnknownClosureFunction;
        if (function.captures.len > aggregate_count) return error.InvalidAggregateScratch;
        const value_root_count = functionValueCount(caller);
        for (function.captures, 0..) |capture, index| {
            const local_index = nameIndex(locals, capture) orelse return error.MissingClosureCapture;
            const cell_root = value_root_count + local_index;
            try self.output.writer.print("  %closure.capture.{d}.{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, index, cell_root });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  %closure.capture.slot.{d}.{d} = getelementptr [{d} x %lnako.Value], ptr %aggregate.values, i64 0, i64 {d}", .{ result, index, aggregate_count, index });
            try self.debugSuffix(instruction.span, scope);
            try self.output.writer.print("  store %lnako.Value %closure.capture.{d}.{d}, ptr %closure.capture.slot.{d}.{d}", .{ result, index, result, index });
            try self.debugSuffix(instruction.span, scope);
        }
        try self.output.writer.print("  call void @lnako_aot_function_new_named(ptr %root.slot.{d}, ptr @lnako.wrapper.{d}, i64 {d}, ptr @lnako.function.name.{d}, i64 {d}, ptr ", .{ result, function.id, function.parameters.len, function.id, function.name.len });
        if (function.captures.len > 0) {
            try self.output.writer.print("%closure.capture.slot.{d}.0", .{result});
        } else try self.output.writer.writeAll("null");
        try self.output.writer.print(", i64 {d})", .{function.captures.len});
        try self.debugSuffix(instruction.span, scope);
        try self.output.writer.print("  %v{d} = load %lnako.Value, ptr %root.slot.{d}", .{ result, result });
        try self.debugSuffix(instruction.span, scope);
    }

    fn writeCallResult(self: *Emitter, result: ir.ValueId, span: ast.Span, scope: usize) !void {
        const global_index = self.globalIndex("それ") orelse return error.MissingResultGlobal;
        try self.output.writer.print("  %call.result.pending.{d} = call i32 @lnako_aot_exception_pending()", .{result});
        try self.debugSuffix(span, scope);
        try self.output.writer.print("  %call.result.is-pending.{d} = icmp ne i32 %call.result.pending.{d}, 0", .{ result, result });
        try self.debugSuffix(span, scope);
        try self.output.writer.print("  %call.result.previous.{d} = load %lnako.Value, ptr @lnako.global.{d}", .{ result, global_index });
        try self.debugSuffix(span, scope);
        try self.output.writer.print("  %call.result.selected.{d} = select i1 %call.result.is-pending.{d}, %lnako.Value %call.result.previous.{d}, %lnako.Value %v{d}", .{ result, result, result, result });
        try self.debugSuffix(span, scope);
        try self.output.writer.print("  store %lnako.Value %call.result.selected.{d}, ptr @lnako.global.{d}", .{ result, global_index });
        try self.debugSuffix(span, scope);
    }

    fn writeTerminator(self: *Emitter, function: ir.Function, terminator: ir.Terminator, span: ast.Span, scope: usize) !void {
        switch (terminator) {
            .branch => |target| {
                try self.output.writer.print("  br label %bb{d}", .{target});
                try self.debugSuffix(span, scope);
            },
            .conditional_branch => |branch| {
                const condition_label = try std.fmt.allocPrint(self.allocator, "branch.condition.v{d}", .{branch.condition});
                defer self.allocator.free(condition_label);
                try self.writeTruthyOperand(function, branch.condition, condition_label, span, scope);
                try self.output.writer.print("  br i1 %branch.condition.v{d}, label %bb{d}, label %bb{d}", .{ branch.condition, branch.then_block, branch.else_block });
                try self.debugSuffix(span, scope);
            },
            .return_value => |value| {
                try self.output.writer.writeAll("  call void @lnako_aot_pop_roots(ptr %root.frame)\n");
                try self.output.writer.writeAll("  ret %lnako.Value ");
                if (value) |operand| try self.writeValueRef(function, operand) else try self.output.writer.writeAll("{ i8 0, i64 0 }");
                try self.debugSuffix(span, scope);
            },
            .throw_value => |throw_value| {
                if (throw_value.site_id) |site_id| {
                    try self.output.writer.print("  call void @lnako_aot_throw_site(i64 {d})", .{site_id});
                    try self.debugSuffix(throw_value.span, scope);
                }
                const exception_set = if (throw_value.coerce_to_error_message) "lnako_aot_exception_set_error_message" else "lnako_aot_exception_set";
                try self.output.writer.print("  call void @{s}(ptr %root.slot.{d})", .{ exception_set, throw_value.value });
                try self.debugSuffix(span, scope);
                if (throw_value.target) |target| {
                    try self.output.writer.print("  br label %bb{d}", .{target});
                    try self.debugSuffix(span, scope);
                } else {
                    try self.output.writer.writeAll("  call void @lnako_aot_pop_roots(ptr %root.frame)\n");
                    try self.output.writer.writeAll("  ret %lnako.Value { i8 0, i64 0 }");
                    try self.debugSuffix(span, scope);
                }
            },
            .propagate_exception => {
                try self.output.writer.writeAll("  call void @lnako_aot_pop_roots(ptr %root.frame)\n");
                try self.output.writer.writeAll("  ret %lnako.Value { i8 0, i64 0 }");
                try self.debugSuffix(span, scope);
            },
            .unreachable_terminator => {
                try self.output.writer.writeAll("  unreachable");
                try self.debugSuffix(span, scope);
            },
            else => return error.UnsupportedTerminator,
        }
    }

    fn writeFunctionWrapper(self: *Emitter, function: ir.Function) !void {
        try self.output.writer.print("define internal void @lnako.wrapper.{d}(ptr %result.out, ptr %context, ptr %arguments, i64 %argument.count) {{\nentry:\n", .{function.id});
        for (function.parameters, 0..) |_, index| {
            try self.output.writer.print("  %wrapper.argument.pointer.{d} = getelementptr %lnako.Value, ptr %arguments, i64 {d}\n", .{ index, index });
            try self.output.writer.print("  %wrapper.argument.{d} = load %lnako.Value, ptr %wrapper.argument.pointer.{d}\n", .{ index, index });
        }
        try self.output.writer.print("  %wrapper.result = call %lnako.Value @lnako.fn.{d}(ptr %context", .{function.id});
        for (function.parameters, 0..) |_, index| {
            try self.output.writer.print(", %lnako.Value %wrapper.argument.{d}", .{index});
        }
        try self.output.writer.writeAll(")\n  store %lnako.Value %wrapper.result, ptr %result.out\n  ret void\n}\n\n");
    }

    fn writeMain(self: *Emitter) !void {
        const scope = 4 + self.program.functions.len;
        const entry_name = if (target_builtin.os.tag == .windows) "wmain" else "main";
        try self.output.writer.print("define i32 @{s}(i32 %argc, ptr %argv) !dbg !{d} {{\nentry:\n", .{ entry_name, scope });
        try self.output.writer.writeAll("  %runtime.status = call i32 @lnako_aot_runtime_init()\n");
        for (self.program.native_plugin_paths, 0..) |path, index| {
            try self.output.writer.print("  call void @lnako_aot_native_plugin_register(ptr @lnako.native.plugin.path.{d}, i64 {d})\n", .{ index, path.len });
        }
        for (self.globals.items, 0..) |_, global_index| {
            try self.output.writer.print("  %global.root.frame.{d} = alloca %lnako.RootFrame\n", .{global_index});
            try self.output.writer.print("  call void @lnako_aot_push_roots(ptr %global.root.frame.{d}, ptr @lnako.global.{d}, i64 1)\n", .{ global_index, global_index });
        }
        if (self.hasDynamicBuiltin()) for (self.globals.items, 0..) |name, global_index| {
            try self.output.writer.print("  call void @lnako_aot_dynamic_global_register(ptr @lnako.global.name.{d}, i64 {d}, ptr @lnako.global.{d})\n", .{ global_index, name.len, global_index });
        };
        for (self.system_strings.items, 0..) |constant, index| {
            try self.output.writer.print("  call void @lnako_aot_string_new(ptr @lnako.global.{d}, ptr ", .{constant.global_index});
            if (constant.units.len == 0) {
                try self.output.writer.writeAll("null");
            } else try self.output.writer.print("@lnako.system.string.{d}", .{index});
            try self.output.writer.print(", i64 {d})\n", .{constant.units.len});
        }
        for (self.system_arrays.items) |global_index| {
            try self.output.writer.print("  call void @lnako_aot_array_new(ptr @lnako.global.{d}, ptr null, i64 0)\n", .{global_index});
        }
        for (self.system_dictionaries.items) |global_index| {
            try self.output.writer.print("  call void @lnako_aot_caniuse_agents_new(ptr @lnako.global.{d})\n", .{global_index});
        }
        for (self.system_era_data.items) |global_index| {
            try self.output.writer.print("  call void @lnako_aot_era_data_new(ptr @lnako.global.{d})\n", .{global_index});
        }
        if (self.globalIndex("コマンドライン") != null or self.globalIndex("ナデシコランタイム") != null or self.globalIndex("ナデシコランタイムパス") != null) {
            const constants_initializer = if (target_builtin.os.tag == .windows)
                "lnako_aot_node_constants_init_wide"
            else
                "lnako_aot_node_constants_init";
            try self.output.writer.print("  call void @{s}(ptr ", .{constants_initializer});
            if (self.globalIndex("コマンドライン")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(", ptr ");
            if (self.globalIndex("ナデシコランタイム")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(", ptr ");
            if (self.globalIndex("ナデシコランタイムパス")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(", i32 %argc, ptr %argv)\n");
        }
        if (self.globalIndex("デスクトップ") != null or self.globalIndex("マイドキュメント") != null or self.globalIndex("テンポラリフォルダ") != null) {
            try self.output.writer.writeAll("  call void @lnako_aot_node_directory_constants_init(ptr ");
            if (self.globalIndex("デスクトップ")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(", ptr ");
            if (self.globalIndex("マイドキュメント")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(", ptr ");
            if (self.globalIndex("テンポラリフォルダ")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(")\n");
        }
        if (self.needsNodeMotherPath()) {
            try self.output.writer.writeAll("  call void @lnako_aot_node_mother_path_init(ptr ");
            if (self.globalIndex("母艦パス")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(", ptr ");
            if (self.source_path.len > 0) try self.output.writer.writeAll("@lnako.node.source.path") else try self.output.writer.writeAll("null");
            try self.output.writer.print(", i64 {d})\n", .{self.source_path.len});
        }
        for (self.program.functions) |function| if (self.globalIndex(function.name)) |global_index| {
            try self.output.writer.print("  call void @lnako_aot_function_new_named(ptr @lnako.global.{d}, ptr @lnako.wrapper.{d}, i64 {d}, ptr @lnako.function.name.{d}, i64 {d}, ptr null, i64 0)\n", .{ global_index, function.id, function.parameters.len, function.id, function.name.len });
        };
        if (self.program.http_server_plugin_imported) {
            try self.output.writer.writeAll("  call void @lnako_aot_http_server_init(ptr ");
            if (self.globalIndex("HTTPメソッド")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(", ptr ");
            if (self.globalIndex("GETデータ")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(", ptr ");
            if (self.globalIndex("POSTデータ")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(", ptr ");
            if (self.globalIndex("FILESデータ")) |global_index| try self.output.writer.print("@lnako.global.{d}", .{global_index}) else try self.output.writer.writeAll("null");
            try self.output.writer.writeAll(")\n");
        }
        var index = self.program.module_entries.len;
        var call_index: usize = 0;
        while (index > 0) {
            index -= 1;
            try self.output.writer.print("  %entry.result.{d} = call %lnako.Value @lnako.fn.{d}(ptr null)", .{ call_index, self.program.module_entries[index] });
            try self.debugSuffix(ast.emptySpan(), scope);
            try self.output.writer.print("  %entry.exception.pending.{d} = call i32 @lnako_aot_exception_pending()\n", .{call_index});
            try self.output.writer.print("  %entry.exception.is-pending.{d} = icmp ne i32 %entry.exception.pending.{d}, 0\n", .{ call_index, call_index });
            try self.output.writer.print("  br i1 %entry.exception.is-pending.{d}, label %entry.exception.abort.{d}, label %entry.continue.{d}\n", .{ call_index, call_index, call_index });
            try self.output.writer.print("entry.exception.abort.{d}:\n  call void @lnako_aot_exception_abort()\n  unreachable\nentry.continue.{d}:\n", .{ call_index, call_index });
            call_index += 1;
        }
        try self.output.writer.writeAll("  call void @lnako_aot_runtime_drain_events()\n");
        try self.output.writer.writeAll("  %entry.timer.exception.pending = call i32 @lnako_aot_exception_pending()\n");
        try self.output.writer.writeAll("  %entry.timer.exception.is-pending = icmp ne i32 %entry.timer.exception.pending, 0\n");
        try self.output.writer.writeAll("  br i1 %entry.timer.exception.is-pending, label %entry.timer.exception.abort, label %entry.timer.continue\n");
        try self.output.writer.writeAll("entry.timer.exception.abort:\n  call void @lnako_aot_exception_abort()\n  unreachable\nentry.timer.continue:\n");
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

    fn globalIndex(self: Emitter, name: []const u8) ?usize {
        return nameIndex(self.globals.items, name);
    }

    fn nativePluginNameIndex(self: Emitter, name: []const u8) ?usize {
        for (self.native_plugin_names.items, 0..) |candidate, index| if (std.mem.eql(u8, candidate, name)) return index;
        return null;
    }

    fn hasBuiltinCall(self: Emitter, command: aot_builtin.Command) bool {
        for (self.program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
            if (instruction.opcode != .call or instruction.direct_callee != null or !instruction.is_builtin_call) continue;
            if (aot_builtin.lookup(instruction.name) == command) return true;
        };
        return false;
    }

    fn hasDynamicBuiltin(self: Emitter) bool {
        return self.hasBuiltinCall(.system_nadesiko) or self.hasBuiltinCall(.system_nadesiko_continue);
    }

    fn needsNodeMotherPath(self: Emitter) bool {
        return self.globalIndex("母艦パス") != null or self.hasBuiltinCall(.node_mother_path);
    }

    fn systemStringValue(self: Emitter, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "名前空間")) return primaryModuleName(self.program);
        if (self.program.http_server_plugin_imported and
            (std.mem.eql(u8, name, "HTTPメソッド") or std.mem.eql(u8, name, "GETデータ") or
                std.mem.eql(u8, name, "POSTデータ") or std.mem.eql(u8, name, "FILESデータ"))) return "";
        return system_constant.lookupString(name);
    }

    fn sourcePathForFunction(self: Emitter, function_name: []const u8) []const u8 {
        var best: ?usize = null;
        for (self.program.module_names, 0..) |module_name, index| {
            if (index >= self.program.module_paths.len or !std.mem.startsWith(u8, function_name, module_name)) continue;
            if (function_name.len <= module_name.len + 1 or !std.mem.eql(u8, function_name[module_name.len .. module_name.len + 2], "__")) continue;
            if (best == null or module_name.len > self.program.module_names[best.?].len) best = index;
        }
        return if (best) |index| self.program.module_paths[index] else self.source_path;
    }

    fn debugPathIndex(self: Emitter, path: []const u8) ?usize {
        for (self.debug_paths.items, 0..) |constant, index| if (std.mem.eql(u8, constant.path, path)) return index;
        return null;
    }

    fn stringConstant(self: Emitter, function_id: ir.FunctionId, value_id: ir.ValueId) ?StringConstant {
        for (self.strings.items) |constant| if (constant.function_id == function_id and constant.value_id == value_id) return constant;
        return null;
    }

    fn bigintConstant(self: Emitter, function_id: ir.FunctionId, value_id: ir.ValueId) ?BigIntConstant {
        for (self.bigints.items) |constant| if (constant.function_id == function_id and constant.value_id == value_id) return constant;
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

fn primaryModuleName(program: ir.Program) []const u8 {
    if (program.module_entries.len == 0) return "";
    const function_id = program.module_entries[0];
    if (function_id >= program.functions.len) return "";
    const name = program.functions[function_id].name;
    const suffix = "__$entry";
    if (!std.mem.endsWith(u8, name, suffix)) return "";
    return name[0 .. name.len - suffix.len];
}

fn validDirectCallee(program: ir.Program, instruction: ir.Instruction) bool {
    return if (instruction.direct_callee) |callee| callee < program.functions.len else false;
}

fn isDynamicNamedCall(function: ir.Function, name: []const u8) bool {
    return isQualifiedGlobal(name) or hasLocalName(function, name);
}

fn isNativePluginCall(program: ir.Program, function: ir.Function, instruction: ir.Instruction) bool {
    return program.native_plugin_paths.len > 0 and
        instruction.opcode == .call and
        instruction.direct_callee == null and
        !instruction.is_builtin_call and
        instruction.name.len > 0 and
        lookupFunction(program, instruction.name) == null and
        !isDynamicNamedCall(function, instruction.name);
}

fn hasLocalName(function: ir.Function, name: []const u8) bool {
    for (function.captures) |capture| if (std.mem.eql(u8, capture, name)) return true;
    for (function.parameters) |parameter| if (std.mem.eql(u8, parameter.name, name)) return true;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if ((instruction.opcode == .load_local or instruction.opcode == .store_local or instruction.opcode == .increment) and
            std.mem.eql(u8, instruction.name, name)) return true;
        if (instruction.opcode == .destructure_store) for (instruction.names) |local_name| {
            if (std.mem.eql(u8, local_name, name)) return true;
        };
    };
    return false;
}

fn closureSupported(program: ir.Program, caller: ir.Function, name: []const u8) bool {
    const function = lookupFunction(program, name) orelse return false;
    for (function.captures) |capture| if (!hasLocalName(caller, capture)) return false;
    return true;
}

fn parameterIndex(function: ir.Function, name: []const u8) ?usize {
    for (function.parameters, 0..) |parameter, index| if (std.mem.eql(u8, parameter.name, name)) return index;
    return null;
}

fn maxClosureCaptureCount(program: ir.Program, function: ir.Function) usize {
    var count: usize = 0;
    for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .make_closure) continue;
        const closure = lookupFunction(program, instruction.name) orelse continue;
        count = @max(count, closure.captures.len);
    };
    return count;
}

fn isDisplayCall(name: []const u8) bool {
    return std.mem.eql(u8, name, "表示") or std.mem.eql(u8, name, "表示する") or std.mem.eql(u8, name, "連続表示");
}

fn isStdioCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .stdio_continue_display, .stdio_continue_display_many, .stdio_clear_log, .stdio_write_all => true,
        else => false,
    };
}

fn isTimerCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .timer_after, .timer_every, .timer_stop, .timer_stop_all => true,
        else => false,
    };
}

fn isPromiseCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .promise_create, .promise_success, .promise_settled, .promise_failure, .promise_finally, .promise_all => true,
        else => false,
    };
}

fn isHttpServerCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .http_server_start, .http_server_static, .http_server_receive, .http_server_output, .http_server_headers, .http_server_redirect => true,
        else => false,
    };
}

fn isArchiveCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_archive_extract, .node_archive_extract_callback, .node_archive_create, .node_archive_create_callback => true,
        else => false,
    };
}

fn isNodeProcessCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_process_run_wait, .node_process_run, .node_process_start, .node_process_run_wait_output, .node_process_start_callback, .node_open_external_browser, .node_open_external_explorer => true,
        else => false,
    };
}

fn isNodeFileCallbackCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_file_process_callback, .node_file_process_stop, .node_file_copy_callback, .node_file_move_callback, .node_file_delete_callback => true,
        else => false,
    };
}

fn isNodeHttpCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_ajax_send_callback, .node_ajax_receive_callback, .node_get_send_callback, .node_post_send_callback, .node_post_form_send_callback, .node_ajax_response_promise, .node_http_response_promise, .node_get_response_promise, .node_post_response_promise, .node_post_form_response_promise, .node_ajax_content_get, .node_ajax_receive, .node_post_send, .node_post_form_send, .node_ajax_text_get, .node_ajax_json_get, .node_ajax_binary_get, .node_discord_send, .node_discord_file_send => true,
        else => false,
    };
}

fn isPluginManagementCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .plugin_name_set, .namespace_set, .namespace_pop => true,
        else => false,
    };
}

fn isNodeFileOperationCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_file_list, .node_file_list_all, .node_folder_create, .node_file_copy, .node_file_copy_overwrite, .node_file_move, .node_file_move_overwrite, .node_file_delete => true,
        else => false,
    };
}

fn requiresDisplayLog(name: []const u8) bool {
    if (isDisplayCall(name)) return true;
    return if (aot_builtin.lookup(name)) |command| isStdioCommand(command) or command == .system_debug_display or command == .system_hatena_execute else false;
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
        .make_array, .make_object, .iterator_begin, .call => count = @max(count, instruction.operands.len),
        .call_value => if (instruction.operands.len > 0) {
            count = @max(count, instruction.operands.len - 1);
        },
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
        .void => false,
        else => true,
    };
}

fn destructureSourceSupported(_: ir.Function, instruction: ir.Instruction) bool {
    return instruction.operands.len == 1;
}

fn isQualifiedGlobal(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "__") != null;
}

fn isNamedGlobalFunction(name: []const u8) bool {
    return !std.mem.endsWith(u8, name, "__$entry") and std.mem.indexOf(u8, name, "__lambda$") == null;
}

fn arithmeticOpcode(operator: []const u8) ?[]const u8 {
    const entries = [_]struct { operator: []const u8, opcode: []const u8 }{
        .{ .operator = "+", .opcode = "fadd" },
        .{ .operator = "-", .opcode = "fsub" },
        .{ .operator = "*", .opcode = "fmul" },
        .{ .operator = "/", .opcode = "fdiv" },
        .{ .operator = "÷", .opcode = "fdiv" },
        .{ .operator = "÷÷", .opcode = "divfloor" },
        .{ .operator = "%", .opcode = "frem" },
        .{ .operator = "**", .opcode = "pow" },
    };
    for (entries) |entry| if (std.mem.eql(u8, operator, entry.operator)) return entry.opcode;
    return null;
}

fn runtimeArithmeticOpcode(operator: []const u8) ?u8 {
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

fn comparisonOpcode(operator: []const u8) ?u8 {
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

fn shiftOpcode(operator: []const u8) ?u8 {
    const entries = [_]struct { operator: []const u8, opcode: u8 }{
        .{ .operator = "shift_l", .opcode = 0 },
        .{ .operator = "shift_r", .opcode = 1 },
        .{ .operator = "shift_r0", .opcode = 2 },
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

fn writeMetadataString(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '"', '\\' => try writer.print("\\{c}", .{byte}),
        '\n', '\r' => try writer.writeByte(' '),
        else => try writer.writeByte(byte),
    };
}

fn writeScalarInitializer(writer: *std.Io.Writer, scalar: ?system_constant.Scalar) !void {
    const value = scalar orelse return writer.writeAll("{ i8 0, i64 0 }");
    switch (value) {
        .undefined => try writer.print("{{ i8 {d}, i64 0 }}", .{@intFromEnum(aot_abi.Tag.undefined)}),
        .null_value => try writer.print("{{ i8 {d}, i64 0 }}", .{@intFromEnum(aot_abi.Tag.null_value)}),
        .boolean => |boolean| try writer.print("{{ i8 {d}, i64 {d} }}", .{ @intFromEnum(aot_abi.Tag.boolean), @intFromBool(boolean) }),
        .number => |number| try writer.print("{{ i8 {d}, i64 {d} }}", .{ @intFromEnum(aot_abi.Tag.number), @as(u64, @bitCast(number)) }),
    }
}

test "Nako SSA IRをデバッグ情報付きLLVM IRへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=1\nB=A+2\nBを表示\nコマンドラインを表示\n母艦パスを表示\n母艦パス取得()を表示\nデバッグ表示({\"a\":1})\nフォルダ作成(\"data\")\n圧縮(\"source.txt\",\"archive.zip\")を表示\n起動待機(\"printf process\")を表示\nF=関数(P)それはP;ここまで\nFでファイル処理時\nファイル処理強制停止\nAJAXテキスト取得(\"http://127.0.0.1/\")を表示\n__DEBUG_BP_WAIT(12)を表示\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "main.nako3", false);
    defer module.deinit(std.testing.allocator);
    const expected_entry = if (target_builtin.os.tag == .windows)
        "define i32 @wmain(i32 %argc, ptr %argv)"
    else
        "define i32 @main(i32 %argc, ptr %argv)";
    try std.testing.expect(std.mem.indexOf(u8, module.text, expected_entry) != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call i32 @lnako_aot_runtime_init()") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_runtime_drain_events()\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_runtime_drain_events()\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_timer_call_site(ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_promise_call_site(ptr, ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_file_operation_call(ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_file_operation_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_archive_call(ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_archive_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_process_call(ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_process_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_file_callback_call(ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_file_callback_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_http_call(ptr, ptr, ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_http_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_constants_init(ptr, ptr, ptr, i32, ptr)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_constants_init_wide(ptr, ptr, ptr, i32, ptr)\n") != null);
    const expected_constants_initializer = if (target_builtin.os.tag == .windows)
        "call void @lnako_aot_node_constants_init_wide(ptr "
    else
        "call void @lnako_aot_node_constants_init(ptr ";
    try std.testing.expect(std.mem.indexOf(u8, module.text, expected_constants_initializer) != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_directory_constants_init(ptr, ptr, ptr)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_node_mother_path_init(ptr, ptr, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.node.source.path") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_node_mother_path_init(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_runtime_deinit()") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.global.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "!llvm.dbg.cu") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "!DILocation(line: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_builtin_call_site") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_dispatch_display_begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare i64 @lnako_aot_dispatch_display_begin_with_epoch(i64, ptr)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_dispatch_result(i64, i64, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_dispatch_result(i64 %display.call_id, i64 %site_id, i64 %display.start_epoch)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_debug_display(ptr, ptr, i64, ptr, i64, ptr, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_debug_breakpoint_wait_call(ptr, ptr, ptr, ptr, ptr, ptr, i64, i16, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_debug_breakpoint_wait_call(ptr ") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.debug.path.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_debug_display") != null);
}

test "ネイティブプラグイン命令をAOT ABIへ出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "外部追加(1)を表示\n", "native-plugin.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyzeModules(std.testing.allocator, &.{.{
        .name = "native-plugin",
        .path = "native-plugin.nako3",
        .root = parsed.root.?,
        .allows_dynamic_commands = true,
    }});
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lower(std.testing.allocator, &.{parsed.root.?}, &.{"native-plugin"}, &.{"native-plugin.nako3"}, analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    const path_allocator = program.arena.allocator();
    const paths = try path_allocator.alloc([]const u8, 1);
    paths[0] = try path_allocator.dupe(u8, "/tmp/liblnako_test_plugin.dylib");
    program.native_plugin_paths = paths;

    var native_call_found = false;
    for (program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .call or !std.mem.eql(u8, instruction.name, "外部追加")) continue;
        native_call_found = true;
        try std.testing.expect(!instruction.is_builtin_call);
        try std.testing.expect(instruction.direct_callee == null);
        try std.testing.expect(instruction.site_id == null);
    };
    try std.testing.expect(native_call_found);
    try std.testing.expect(findUnsupported(program) == null);

    var module = try generate(std.testing.allocator, program, "native-plugin.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_native_plugin_register(ptr, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_native_plugin_call(ptr, ptr, i64, ptr, i64, i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.native.plugin.name.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.native.plugin.path.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_native_plugin_register(ptr @lnako.native.plugin.path.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_native_plugin_call(ptr %root.slot.") != null);
}

test "AOT builtin manifestはdispatch routeとcanonical opcodeを保持する" {
    const display = manifestCall("表示", null, true).?;
    try std.testing.expectEqualStrings("表示", display.source_name);
    try std.testing.expectEqualStrings("display", display.canonical_opcode);
    try std.testing.expectEqualStrings("direct-display", display.route);
    try std.testing.expectEqual(@as(u16, 0), display.opcode);

    const cut = manifestCall("切取", null, true).?;
    try std.testing.expectEqualStrings("cut", cut.canonical_opcode);
    try std.testing.expectEqualStrings("cut", cut.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.cut), cut.opcode);

    const regexp = manifestCall("正規表現マッチ", null, true).?;
    try std.testing.expectEqualStrings("regexp_match", regexp.canonical_opcode);
    try std.testing.expectEqualStrings("regexp", regexp.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.regexp_match), regexp.opcode);

    const builtin = manifestCall("文字列変換", null, true).?;
    try std.testing.expectEqualStrings("to_string", builtin.canonical_opcode);
    try std.testing.expectEqualStrings("builtin", builtin.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.to_string), builtin.opcode);

    const debug = manifestCall("デバッグ表示", null, true).?;
    try std.testing.expectEqualStrings("system_debug_display", debug.canonical_opcode);
    try std.testing.expectEqualStrings("debug-display", debug.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_debug_display), debug.opcode);

    const hatena = manifestCall("ハテナ関数実行", null, true).?;
    try std.testing.expectEqualStrings("system_hatena_execute", hatena.canonical_opcode);
    try std.testing.expectEqualStrings("hatena-default", hatena.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_hatena_execute), hatena.opcode);

    const hatena_configure = manifestCall("ハテナ関数設定", null, true).?;
    try std.testing.expectEqualStrings("system_hatena_configure", hatena_configure.canonical_opcode);
    try std.testing.expectEqualStrings("hatena-configure", hatena_configure.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_hatena_configure), hatena_configure.opcode);

    const node_interrupt = manifestCall("強制終了時", null, true).?;
    try std.testing.expectEqualStrings("node_interrupt_callback", node_interrupt.canonical_opcode);
    try std.testing.expectEqualStrings("node-interrupt", node_interrupt.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_interrupt_callback), node_interrupt.opcode);

    const breakpoint_wait = manifestCall("__DEBUG_BP_WAIT", null, true).?;
    try std.testing.expectEqualStrings("system_debug_breakpoint_wait", breakpoint_wait.canonical_opcode);
    try std.testing.expectEqualStrings("debug-breakpoint-wait", breakpoint_wait.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_debug_breakpoint_wait), breakpoint_wait.opcode);

    const stdin_line = manifestCall("尋", null, true).?;
    try std.testing.expectEqualStrings("node_stdin_line", stdin_line.canonical_opcode);
    try std.testing.expectEqualStrings("node-stdin-lines", stdin_line.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_stdin_line), stdin_line.opcode);

    const archive_tool_path = manifestCall("圧縮解凍ツールパス変更", null, true).?;
    try std.testing.expectEqualStrings("node_archive_tool_path_set", archive_tool_path.canonical_opcode);
    try std.testing.expectEqualStrings("archive-tool-path", archive_tool_path.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_archive_tool_path_set), archive_tool_path.opcode);

    const archive_create = manifestCall("圧縮", null, true).?;
    try std.testing.expectEqualStrings("node_archive_create", archive_create.canonical_opcode);
    try std.testing.expectEqualStrings("node-archive", archive_create.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_archive_create), archive_create.opcode);

    const archive_extract_callback = manifestCall("解凍時", null, true).?;
    try std.testing.expectEqualStrings("node_archive_extract_callback", archive_extract_callback.canonical_opcode);
    try std.testing.expectEqualStrings("node-archive", archive_extract_callback.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_archive_extract_callback), archive_extract_callback.opcode);

    const process_wait = manifestCall("起動待機", null, true).?;
    try std.testing.expectEqualStrings("node_process_run_wait", process_wait.canonical_opcode);
    try std.testing.expectEqualStrings("node-process", process_wait.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_process_run_wait), process_wait.opcode);

    const process_start = manifestCall("起動", null, true).?;
    try std.testing.expectEqualStrings("node_process_start", process_start.canonical_opcode);
    try std.testing.expectEqualStrings("node-process", process_start.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_process_start), process_start.opcode);

    const file_callback = manifestCall("ファイルコピー時", null, true).?;
    try std.testing.expectEqualStrings("node_file_copy_callback", file_callback.canonical_opcode);
    try std.testing.expectEqualStrings("node-file-callback", file_callback.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_file_copy_callback), file_callback.opcode);

    const ajax_options = manifestCall("AJAXオプション設定", null, true).?;
    try std.testing.expectEqualStrings("node_ajax_options_set", ajax_options.canonical_opcode);
    try std.testing.expectEqualStrings("ajax-options", ajax_options.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_ajax_options_set), ajax_options.opcode);

    const ajax_onerror = manifestCall("AJAX失敗時", null, true).?;
    try std.testing.expectEqualStrings("node_ajax_onerror_set", ajax_onerror.canonical_opcode);
    try std.testing.expectEqualStrings("ajax-onerror", ajax_onerror.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_ajax_onerror_set), ajax_onerror.opcode);

    const ajax_http = manifestCall("AJAXテキスト取得", null, true).?;
    try std.testing.expectEqualStrings("node_ajax_text_get", ajax_http.canonical_opcode);
    try std.testing.expectEqualStrings("node-http", ajax_http.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_ajax_text_get), ajax_http.opcode);

    const file_open = manifestCall("開", null, true).?;
    try std.testing.expectEqualStrings("node_file_open", file_open.canonical_opcode);
    try std.testing.expectEqualStrings("node-file-io", file_open.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_file_open), file_open.opcode);

    const sjis_file = manifestCall("SJISファイル読", null, true).?;
    try std.testing.expectEqualStrings("node_file_sjis_read", sjis_file.canonical_opcode);
    try std.testing.expectEqualStrings("node-file-encoding", sjis_file.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_file_sjis_read), sjis_file.opcode);

    const sjis = manifestCall("SJIS変換", null, true).?;
    try std.testing.expectEqualStrings("node_encoding_sjis_encode", sjis.canonical_opcode);
    try std.testing.expectEqualStrings("node-encoding", sjis.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_encoding_sjis_encode), sjis.opcode);

    const file_list = manifestCall("ファイル列挙", null, true).?;
    try std.testing.expectEqualStrings("node_file_list", file_list.canonical_opcode);
    try std.testing.expectEqualStrings("node-file-operation", file_list.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_file_list), file_list.opcode);

    const file_copy = manifestCall("ファイル上書コピー", null, true).?;
    try std.testing.expectEqualStrings("node_file_copy_overwrite", file_copy.canonical_opcode);
    try std.testing.expectEqualStrings("node-file-operation", file_copy.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.node_file_copy_overwrite), file_copy.opcode);

    const timer_wait = manifestCall("秒待", null, true).?;
    try std.testing.expectEqualStrings("timer_wait", timer_wait.canonical_opcode);
    try std.testing.expectEqualStrings("builtin", timer_wait.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.timer_wait), timer_wait.opcode);

    const timer = manifestCall("秒後", null, true).?;
    try std.testing.expectEqualStrings("timer_after", timer.canonical_opcode);
    try std.testing.expectEqualStrings("timer", timer.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.timer_after), timer.opcode);

    const promise = manifestCall("成功時", null, true).?;
    try std.testing.expectEqualStrings("promise_success", promise.canonical_opcode);
    try std.testing.expectEqualStrings("promise", promise.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.promise_success), promise.opcode);

    const dynamic = manifestCall("ナデシコ", null, true).?;
    try std.testing.expectEqualStrings("system_nadesiko", dynamic.canonical_opcode);
    try std.testing.expectEqualStrings("dynamic-execute", dynamic.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_nadesiko), dynamic.opcode);

    const dynamic_continue = manifestCall("ナデシコ続", null, true).?;
    try std.testing.expectEqualStrings("system_nadesiko_continue", dynamic_continue.canonical_opcode);
    try std.testing.expectEqualStrings("dynamic-execute", dynamic_continue.route);
    try std.testing.expectEqual(@intFromEnum(aot_builtin.Command.system_nadesiko_continue), dynamic_continue.opcode);

    try std.testing.expect(manifestCall("利用者関数", 0, false) == null);
    try std.testing.expect(manifestCall("未知命令", null, false) == null);
}

test "AOT throw terminatorは専用dispatch trace ABIを出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "エラー監視\n1のエラー発生\nエラーならば\n\"handled\"を表示\nここまで\n", "throw-dispatch.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "throw-dispatch.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "throw-dispatch.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "throw-dispatch.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_throw_site(i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_throw_site(i64 ") != null);
}

test "site-aware builtin emissionはsite ID欠落を拒否する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "1を表示\n", "missing-site.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "missing-site.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "missing-site", "missing-site.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var found_builtin = false;
    for (program.functions) |*function| for (function.blocks) |*block| for (block.instructions) |*instruction| {
        if (instruction.opcode == .call and instruction.is_builtin_call) {
            instruction.site_id = null;
            found_builtin = true;
            break;
        }
    };
    try std.testing.expect(found_builtin);
    try std.testing.expectError(error.MissingDispatchSiteId, generate(std.testing.allocator, program, "missing-site.nako3", false));
}

test "global loadを専用AOT trace ABIへ出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "PIを表示\n", "global-trace.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "global-trace.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "global-trace.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "global-trace.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_global_read_site(i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_global_read_site(i64 1)") != null);
}

test "catalog literalを専用AOT trace ABIへ出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "真を表示\nNULLを表示\n", "literal-trace.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "literal-trace.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "literal-trace.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "literal-trace.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_literal_site(i64)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_literal_site(i64 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_literal_site(i64 2)") != null);
}

test "参照されたスカラーシステム定数をAOTグローバルへ初期化する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "trueを表示\nfalseを表示\nPIを表示\n非数を表示\n無限大を表示\n未定義を表示\n", "constants.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "constants.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "constants.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "constants.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "internal global %lnako.Value { i8 2, i64 1 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "internal global %lnako.Value { i8 2, i64 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "internal global %lnako.Value { i8 3, i64 4614256656552045848 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "internal global %lnako.Value { i8 0, i64 0 }") != null);
}

test "参照された文字列システム定数をGCルート登録後に初期化する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "ナデシコバージョンを表示\n改行を表示\n空を表示\n名前空間を表示\n", "string-constants.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "string-constants.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "string-constants.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "string-constants.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.system.string.") != null);
    const push = std.mem.indexOf(u8, module.text, "call void @lnako_aot_push_roots").?;
    const initialize = std.mem.indexOf(u8, module.text, "call void @lnako_aot_string_new(ptr @lnako.global.").?;
    const entry = std.mem.indexOf(u8, module.text, "%entry.result.0 = call").?;
    try std.testing.expect(push < initialize);
    try std.testing.expect(initialize < entry);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "[4 x i16] [i16 109, i16 97, i16 105, i16 110]") != null);
}

test "プラグイン管理命令を専用AOT ABIへ出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "プラグイン名設定(123)\n名前空間設定(456)\n名前空間ポップ()\n", "plugin-management.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "plugin-management.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "plugin-management.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "plugin-management.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_plugin_management_call(ptr, ptr, i64, i16, ptr, ptr, i64)\n") != null);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, module.text, "call void @lnako_aot_plugin_management_call("));
    try std.testing.expect(std.mem.indexOf(u8, module.text, "ptr @lnako.global.1, ptr @lnako.global.2") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "[4 x i16] [i16 109, i16 97, i16 105, i16 110]") != null);
}

test "参照された配列システム定数を独立したGCオブジェクトへ初期化する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "抽出文字列[0]=\"A\"\n__DEBUGブレイクポイント一覧[0]=\"B\"\n抽出文字列を表示\n__DEBUGブレイクポイント一覧を表示\n", "array-constants.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "array-constants.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "array-constants.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "array-constants.nako3", false);
    defer module.deinit(std.testing.allocator);
    const first = std.mem.indexOf(u8, module.text, "call void @lnako_aot_array_new(ptr @lnako.global.").?;
    const second = std.mem.indexOfPos(u8, module.text, first + 1, "call void @lnako_aot_array_new(ptr @lnako.global.").?;
    const entry = std.mem.indexOf(u8, module.text, "%entry.result.0 = call").?;
    try std.testing.expect(first < second);
    try std.testing.expect(second < entry);
}

test "参照された辞書システム定数を専用AOT初期化子へ渡す" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "JSON変換(ブラウザ名変換表)を表示\n", "dictionary-constants.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "dictionary-constants.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "dictionary-constants.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "dictionary-constants.nako3", false);
    defer module.deinit(std.testing.allocator);
    const initialize = std.mem.indexOf(u8, module.text, "call void @lnako_aot_caniuse_agents_new(ptr @lnako.global.").?;
    const entry = std.mem.indexOf(u8, module.text, "%entry.result.0 = call").?;
    try std.testing.expect(initialize < entry);
}

test "参照された元号データを専用AOT初期化子へ渡す" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "JSON変換(元号データ)を表示\n", "era-data.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "era-data.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "era-data.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "era-data.nako3", false);
    defer module.deinit(std.testing.allocator);
    const initialize = std.mem.indexOf(u8, module.text, "call void @lnako_aot_era_data_new(ptr @lnako.global.").?;
    const entry = std.mem.indexOf(u8, module.text, "%entry.result.0 = call").?;
    try std.testing.expect(initialize < entry);
}

test "正規表現マッチは未参照の抽出文字列もAOTグローバルへ確保する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "正規表現マッチ(\"a\",『/(a)/』)\n", "regexp-global.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "regexp-global.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "regexp_global", "regexp-global.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "regexp-global.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_array_new(ptr @lnako.global.") != null);
    const call = std.mem.indexOf(u8, module.text, "call void @lnako_aot_regexp_call_site").?;
    const capture_pointer = std.mem.indexOfPos(u8, module.text, call, "ptr @lnako.global.").?;
    const call_end = std.mem.indexOfPos(u8, module.text, call, "\n").?;
    try std.testing.expect(capture_pointer < call_end);
}

test "配列と辞書をルート付きAOTランタイム呼び出しへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "A=[1,2]\nA[1]=5\nA[1]を表示\nAを表示\nB={\"x\":7}\nB@\"x\"を表示\nBを表示\nX=[8,9]\n変数[C,D]=X\nCを表示\n変数[E,F]=7\nEを表示\n";
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
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_destructure_get") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_print_collection") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_index_get(ptr, ptr, ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "ptr %runtime.scratch") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare %lnako.Value @lnako_aot_") == null);
}

test "回数・範囲・コレクション反復をAOTイテレーターへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "C=2\nC回\n回数を表示\nここまで\nNを1から2まで繰り返す\nNを表示\nここまで\nA=[3,4]\nAを反復\n対象を表示\nここまで\nS=\"AB\"\nSを反復\n対象を表示\nここまで\n";
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

test "UTF-16文字列定数と添字と反復をAOTランタイムへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "S=「A😀B」\nS[1]を表示\n「A😀B」を反復\n対象を表示\nここまで\nN=「A\x00B」\nNを表示\n", "string-iterator.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "string-iterator.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "string-iterator.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "string-iterator.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_string_new(ptr, ptr, i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_print_utf16(ptr, i1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "[4 x i16] [i16 65, i16 55357, i16 56832, i16 66]") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "[3 x i16] [i16 65, i16 0, i16 66]") != null);
}

test "BigInt定数と真偽判定をAOTランタイムへ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "123456789012345678901234567890nを表示\nもし0nならば\n『誤』を表示\n違えば\n『正』を表示\nここまで\n", "bigint.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "bigint.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "bigint.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "bigint.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_bigint_new(ptr, ptr, i64)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_print_bigint(ptr, i1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare i32 @lnako_aot_bigint_truthy(ptr)") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.bigint.") != null);
}

test "動的算術とBigInt比較をAOTランタイムへ接続する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "A=12345678901234567890n\nB=10n\nA+Bを表示\nA>Bを表示\nA==\"12345678901234567890\"を表示\nA&\"個\"を表示\n8n<<2nを表示\n", "bigint-operators.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "bigint-operators.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "bigint-operators.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "bigint-operators.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_arithmetic") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_compare") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_shift") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_concat") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "binary.has.bigint.") == null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_display_value") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@.lnako.fmt.number") == null);
}

test "増減文をNumber変換付きAOTランタイムへ接続する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "Aを1増\nAを表示\nB=\"5\"\nBを2増\nBを表示\n", "increment.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "increment.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "increment.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "increment.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_increment") != null);
}

test "関数戻り値をシステム変数それへ書き戻す" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "●七とは\n7で戻る\nここまで\n●空とは\nここまで\n七()\nA=それ\n空()\nB=それ\n";
    var parsed = try parser.parse(std.testing.allocator, source, "result.nako3");
    defer parsed.deinit();
    try std.testing.expect(parsed.succeeded());
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "result.nako3");
    defer analyzed.deinit();
    try std.testing.expect(analyzed.succeeded());
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "result", "result.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var module = try generate(std.testing.allocator, program, "result.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "store %lnako.Value %v") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "ret %lnako.Value { i8 0, i64 0 }") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.global.0") != null);
}

test "非捕捉無名関数を統一ABIの関数値へ変換する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    const source = "F=関数(A)それはA+1;ここまで\nF(3)を表示\n";
    var parsed = try parser.parse(std.testing.allocator, source, "function-value.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "function-value.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "function_value", "function-value.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "function-value.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_function_new") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "declare void @lnako_aot_function_new_named") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.function.name.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "call void @lnako_aot_function_new_named") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_function_call") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako.wrapper.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "define internal void @lnako.wrapper.0(ptr %result.out") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "store %lnako.Value %wrapper.result, ptr %result.out") != null);
}

test "監視外のthrowを保留例外としてmainまで伝播する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "『未捕捉』のエラー発生\n", "uncaught.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "uncaught.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "uncaught", "uncaught.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(findUnsupported(program) == null);
    var module = try generate(std.testing.allocator, program, "uncaught.nako3", false);
    defer module.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_exception_set_error_message") != null);
    try std.testing.expect(std.mem.indexOf(u8, module.text, "@lnako_aot_exception_abort") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, unoptimized_module.text, "call void @lnako_aot_arithmetic") != null);
    try std.testing.expect(std.mem.indexOf(u8, unoptimized_module.text, "call i1 @lnako.truthy") != null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, "call double @lnako.to_number") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, "call void @lnako_aot_arithmetic") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, "call i1 @lnako.truthy") == null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, ".bits = extractvalue %lnako.Value") != null);
    try std.testing.expect(std.mem.indexOf(u8, optimized_module.text, ".number = bitcast i64") != null);
}
