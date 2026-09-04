const std = @import("std");
const model = @import("model.zig");

pub fn writeBenchmarkMarkdown(writer: *std.Io.Writer, report: model.BenchmarkReport) !void {
    try writer.print("# lnako benchmark\n\n- schema: `{d}`\n- generated_at_unix_ms: `{d}`\n- git_commit: `{s}`\n- target: `{s}/{s}`\n- toolchain: Zig `{s}`, LLVM/LLD `{s}`\n- suite_name: `{s}`\n- suite: `{s}`\n- optimization: `{s}`\n- iterations: `{d}`\n- warmup: `{d}`\n\n", .{
        report.schema_version,
        report.generated_at_unix_ms,
        report.git_commit,
        report.target.os,
        report.target.arch,
        report.toolchain.zig,
        report.toolchain.llvm,
        report.suite_name,
        report.suite,
        report.optimization,
        report.iterations,
        report.warmup,
    });
    try writer.writeAll("| case | mode | samples | min (ns) | median (ns) | max (ns) |\n|---|---|---:|---:|---:|---:|\n");
    for (report.cases) |item| for (item.measurements) |measurement| {
        try writer.print("| `{s}` | `{s}` | {d} | {d} | {d} | {d} |\n", .{ item.id, measurement.mode, measurement.samples_ns.len, measurement.min_ns, measurement.median_ns, measurement.max_ns });
    };
    try writer.writeAll("\n測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`interpreter`は`lnako run`、`aot_compile`はLLVM O2生成、`aot_run`は生成実行ファイルを測定します。suiteの期待stdoutとの一致を各sampleで確認しています。\n");
}

pub fn writeBenchmarkFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
    if (std.fs.path.isAbsolute(path)) {
        var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
    } else try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}
