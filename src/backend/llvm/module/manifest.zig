const std = @import("std");
const ir = @import("../../../ir/nako_ir.zig");
const aot_builtin = @import("../../../runtime/aot_builtin.zig");
const shared = @import("shared.zig");

pub const ManifestCall = struct {
    source_name: []const u8,
    canonical_opcode: []const u8,
    route: []const u8,
    opcode: u16,
};

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
    if (shared.isDisplayCall(name)) return .{
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
        .schema = shared.manifest_schema,
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
                    .schema = shared.manifest_schema,
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
                        .schema = shared.manifest_schema,
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
        .schema = shared.manifest_schema,
        .phase = "pre-opt",
        .kind = "complete",
        .complete = true,
        .entryCount = entry_count,
    });
    try file_writer.interface.flush();
}

/// Writes a separate JSONL manifest for statically lowered global accesses. It
/// is intentionally not part of the builtin manifest because a global load or
/// store is not a builtin dispatch call.
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
        .schema = shared.global_manifest_schema,
        .phase = "pre-opt",
        .sourcePath = source_path,
        .siteIdEncoding = "u64-hex16",
    });
    var entry_count: usize = 0;
    for (program.functions) |function| {
        for (function.blocks) |block| {
            for (block.instructions) |instruction| {
                if (instruction.opcode != .load_global and instruction.opcode != .store_global) continue;
                const site_id = instruction.global_site_id orelse return error.MissingGlobalSiteId;
                if (seen_site_ids.contains(site_id)) return error.ManifestSiteIdCollision;
                try seen_site_ids.put(allocator, site_id, {});
                var site_id_text: [18]u8 = undefined;
                entry_count += 1;
                try writeManifestLine(writer, GlobalManifestEntry{
                    .schema = shared.global_manifest_schema,
                    .phase = "pre-opt",
                    .kind = if (instruction.opcode == .load_global) "global-load" else "global-store",
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
        .schema = shared.global_manifest_schema,
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
        .schema = shared.literal_manifest_schema,
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
                    .schema = shared.literal_manifest_schema,
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
        .schema = shared.literal_manifest_schema,
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
