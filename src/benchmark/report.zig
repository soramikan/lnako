const std = @import("std");
const model = @import("model.zig");

pub fn writeBenchmarkMarkdown(writer: *std.Io.Writer, report: model.BenchmarkReport) !void {
    if (report.schema_version == 1) return writeLegacyBenchmarkMarkdown(writer, report);
    try writer.print(
        "# lnako benchmark\n\n- schema: `{d}`\n- generated_at_unix_ms: `{d}`\n- git_commit: `{s}`\n- git_dirty: `{}`\n- target: `{s}/{s}`\n- toolchain: Zig `{s}`, LLVM/LLD `{s}`\n- profile: `{s}`\n- iterations: `{d}`\n- warmup: `{d}`\n- optimization: `{s}`\n- suite_name: `{s}`\n- suite: `{s}`\n- suite_sha256: `{s}`\n- source: `{s}`\n\n",
        .{
            report.schema_version,
            report.generated_at_unix_ms,
            report.git_commit,
            report.git_dirty,
            report.target.os,
            report.target.arch,
            report.toolchain.zig,
            report.toolchain.llvm,
            report.profile,
            report.iterations,
            report.warmup,
            report.optimization,
            report.suite_name,
            report.suite,
            report.suite_sha256,
            report.source,
        },
    );
    try writer.writeAll(
        "| category | case | measurement | mode | samples | min (ns) | p25 (ns) | median (ns) | p75 (ns) | max (ns) | IQR (ns) | MAD (ns) | mean (ns) | stddev (ns) | CV | binary size (bytes) |\n" ++
            "|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n",
    );
    var previous_category: ?[]const u8 = null;
    for (report.cases) |item| {
        if (previous_category == null or !std.mem.eql(u8, previous_category.?, item.category)) {
            try writer.print("\n### {s}\n\n", .{item.category});
            previous_category = item.category;
        }
        for (item.measurements) |measurement| {
            if (measurement.binary_size_bytes) |size| {
                try writer.print(
                    "| `{s}` | `{s}` | `{s}` | `{s}` | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} |\n",
                    .{
                        item.category,
                        item.id,
                        item.measurement,
                        measurement.mode,
                        measurement.samples_ns.len,
                        measurement.min_ns,
                        measurement.p25_ns,
                        measurement.median_ns,
                        measurement.p75_ns,
                        measurement.max_ns,
                        measurement.iqr_ns,
                        measurement.mad_ns,
                        measurement.mean_ns,
                        measurement.stddev_ns,
                        measurement.cv,
                        size,
                    },
                );
            } else {
                try writer.print(
                    "| `{s}` | `{s}` | `{s}` | `{s}` | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | {d} | - |\n",
                    .{
                        item.category,
                        item.id,
                        item.measurement,
                        measurement.mode,
                        measurement.samples_ns.len,
                        measurement.min_ns,
                        measurement.p25_ns,
                        measurement.median_ns,
                        measurement.p75_ns,
                        measurement.max_ns,
                        measurement.iqr_ns,
                        measurement.mad_ns,
                        measurement.mean_ns,
                        measurement.stddev_ns,
                        measurement.cv,
                    },
                );
            }
        }
    }
    try writer.writeAll(
        "\n測定値は各sampleの子プロセス完了までのwall-clock nanosecondsです。`startup`と`steady_state`はプロセス単位で測定し、steady-stateの反復回数をカーネル時間へ換算しません。`compile`はAOT生成時間を実行時間から分離し、生成ファイルのサイズをbytesで記録します。\n" ++
            "統計: raw sampleは収集順を保持し、p25/p50/p75はtype 7線形補間を最近接ns（.5は切り上げ）へ丸めます。MADは整数medianからの絶対偏差のmedian、stddevは母標準偏差、CVはstddev/meanです。\n" ++
            "実行タイムアウトはCLI側では設定せず、子プロセス完了までを記録します。CIではジョブのタイムアウトで上限を設けます。\n",
    );
    for (report.cases) |item| for (item.measurements) |measurement| for (measurement.warnings) |warning| {
        try writer.print("\nwarning: `{s}/{s}` {s}\n", .{ item.id, measurement.mode, warning });
    };
}

fn writeLegacyBenchmarkMarkdown(writer: *std.Io.Writer, report: model.BenchmarkReport) !void {
    try writer.print(
        "# lnako benchmark\n\n- schema: `{d}`\n- generated_at_unix_ms: `{d}`\n- git_commit: `{s}`\n- target: `{s}/{s}`\n- toolchain: Zig `{s}`, LLVM/LLD `{s}`\n- suite_name: `{s}`\n- suite: `{s}`\n- optimization: `{s}`\n- iterations: `{d}`\n- warmup: `{d}`\n\n",
        .{
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
        },
    );
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
