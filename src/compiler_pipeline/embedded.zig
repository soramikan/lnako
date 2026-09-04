const std = @import("std");
const lnako = @import("lnako");

pub fn writeCompatExecutable(allocator: std.mem.Allocator, io: std.Io, executable_path: []const u8, input_path: []const u8, output_path: []const u8) !void {
    const resolved_output = try std.fs.path.resolve(allocator, &.{output_path});
    defer allocator.free(resolved_output);
    const resolved_executable = try std.fs.path.resolve(allocator, &.{executable_path});
    defer allocator.free(resolved_executable);
    if (std.mem.eql(u8, resolved_output, resolved_executable)) return error.OutputOverwritesCompiler;

    var file_provider = lnako.semantic.module_graph.FileProvider{ .io = io };
    var graph = try lnako.semantic.module_graph.load(allocator, input_path, file_provider.sourceProvider(), .{ .compat_js = true });
    defer graph.deinit();
    if (!graph.succeeded()) return error.InvalidCompatSourceGraph;
    const files = try allocator.alloc(lnako.compat.embedded.SourceFile, graph.modules.len);
    defer allocator.free(files);
    for (graph.modules, files) |module, *file| file.* = .{ .path = module.path, .source = module.source };

    const compiler = try std.Io.Dir.cwd().readFileAlloc(io, executable_path, allocator, .limited(1024 * 1024 * 1024));
    defer allocator.free(compiler);
    const generated = try lnako.compat.embedded.createExecutable(allocator, compiler, graph.modules[graph.entry].path, files);
    defer allocator.free(generated);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = generated,
        .flags = .{ .permissions = .executable_file },
    });
}
