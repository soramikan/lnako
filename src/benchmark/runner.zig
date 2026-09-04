const std = @import("std");
const builtin = @import("builtin");
const lnako = @import("lnako");
const model = @import("model.zig");
const statistics = @import("statistics.zig");
const report = @import("report.zig");

pub fn parseBenchmarkOptions(arguments: []const []const u8) model.Error!model.BenchmarkOptions {
    var options = model.BenchmarkOptions{};
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, argument, "--suite")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkSuite;
            options.suite_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--output")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkOutput;
            options.output_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--markdown")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkMarkdown;
            options.markdown_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--iterations")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkIterations;
            options.iterations = std.fmt.parseUnsigned(usize, arguments[index], 10) catch return error.InvalidBenchmarkIterations;
            if (options.iterations == 0) return error.InvalidBenchmarkIterations;
        } else if (std.mem.eql(u8, argument, "--warmup")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkWarmup;
            options.warmup = std.fmt.parseUnsigned(usize, arguments[index], 10) catch return error.InvalidBenchmarkWarmup;
        } else return error.UnknownBenchmarkOption;
    }
    return options;
}

pub fn writeBenchmarkUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\使い方: lnako benchmark [options]
        \\
        \\  --suite <path>       ベンチマークsuite JSON（既定: benchmarks/suite.json）
        \\  --output <path>      JSON結果の出力先（既定: benchmarks/results/latest.json）
        \\  --markdown <path>    Markdown結果の出力先（既定: benchmarks/results/latest.md）
        \\  --iterations <n>     計測回数（既定: 5）
        \\  --warmup <n>         ウォームアップ回数（既定: 1）
        \\
    );
}

pub fn runBenchmark(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable_path: []const u8,
    environment: *const std.process.Environ.Map,
    temporary_root: []const u8,
    options: model.BenchmarkOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const suite_bytes = try std.Io.Dir.cwd().readFileAlloc(io, options.suite_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(suite_bytes);
    const parsed = std.json.parseFromSlice(model.BenchmarkSuite, allocator, suite_bytes, .{}) catch return error.InvalidBenchmarkSuite;
    defer parsed.deinit();
    const suite = parsed.value;
    if (suite.schema_version != 1 or suite.name.len == 0 or suite.cases.len == 0) return error.InvalidBenchmarkSuite;
    for (suite.cases, 0..) |item, index| {
        if (item.id.len == 0 or item.source.len == 0) return error.InvalidBenchmarkSuite;
        for (suite.cases[0..index]) |previous| if (std.mem.eql(u8, item.id, previous.id)) return error.DuplicateBenchmarkCase;
    }

    const nonce: u96 = @truncate(@as(u96, @bitCast(std.Io.Timestamp.now(io, .awake).nanoseconds)));
    const temporary_directory = try std.fmt.allocPrint(allocator, "{s}{c}lnako-benchmark-{x}", .{
        std.mem.trimEnd(u8, temporary_root, "/\\"),
        std.fs.path.sep,
        nonce,
    });
    defer allocator.free(temporary_directory);
    if (std.fs.path.isAbsolute(temporary_directory))
        try std.Io.Dir.createDirAbsolute(io, temporary_directory, .default_dir)
    else
        try std.Io.Dir.cwd().createDirPath(io, temporary_directory);
    defer std.Io.Dir.cwd().deleteTree(io, temporary_directory) catch {};

    const binary_name = if (builtin.os.tag == .windows) "benchmark-program.exe" else "benchmark-program";
    const binary_path = try std.fs.path.join(allocator, &.{ temporary_directory, binary_name });
    defer allocator.free(binary_path);

    var case_reports: std.ArrayList(model.BenchmarkCaseReport) = .empty;
    for (suite.cases) |item| {
        var measurements: std.ArrayList(model.BenchmarkMeasurement) = .empty;
        for ([_]model.BenchmarkMode{ .interpreter, .aot_compile, .aot_run }) |mode| {
            const samples = try collectBenchmarkSamples(allocator, io, executable_path, item, binary_path, options, mode, stderr);
            try measurements.append(allocator, statistics.summarizeBenchmarkSamples(@tagName(mode), samples));
        }
        try case_reports.append(allocator, .{
            .id = item.id,
            .source = item.source,
            .expected_stdout = item.expected_stdout,
            .measurements = try measurements.toOwnedSlice(allocator),
        });
    }

    const generated_at_unix_ms = std.math.cast(i64, @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000)) orelse 0;
    const git_commit = try benchmarkGitCommit(allocator, io, environment);
    const generated_report = model.BenchmarkReport{
        .schema_version = 1,
        .project = "lnako",
        .version = lnako.version,
        .git_commit = git_commit,
        .generated_at_unix_ms = generated_at_unix_ms,
        .target = .{ .os = @tagName(builtin.os.tag), .arch = @tagName(builtin.cpu.arch) },
        .toolchain = .{ .zig = "0.16.0", .llvm = "22.1.8" },
        .suite_name = suite.name,
        .suite = options.suite_path,
        .optimization = "O2",
        .iterations = options.iterations,
        .warmup = options.warmup,
        .cases = try case_reports.toOwnedSlice(allocator),
    };

    var json_output: std.Io.Writer.Allocating = .init(allocator);
    defer json_output.deinit();
    try std.json.Stringify.value(generated_report, .{}, &json_output.writer);
    try json_output.writer.writeByte('\n');
    const json_bytes = try json_output.toOwnedSlice();
    defer allocator.free(json_bytes);
    try report.writeBenchmarkFile(io, options.output_path, json_bytes);

    var markdown_output: std.Io.Writer.Allocating = .init(allocator);
    defer markdown_output.deinit();
    try report.writeBenchmarkMarkdown(&markdown_output.writer, generated_report);
    const markdown_bytes = try markdown_output.toOwnedSlice();
    defer allocator.free(markdown_bytes);
    try report.writeBenchmarkFile(io, options.markdown_path, markdown_bytes);

    try stdout.print("ベンチマーク結果を記録しました: {s}, {s}\n", .{ options.output_path, options.markdown_path });
}

fn benchmarkGitCommit(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map) ![]const u8 {
    if (environment.get("LNAKO_BENCHMARK_COMMIT")) |commit| return commit;
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "--verify", "HEAD" },
        .stdout_limit = .limited(256),
        .stderr_limit = .limited(256),
    }) catch return "unknown";
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) return "unknown";
    const commit = std.mem.trim(u8, result.stdout, " \t\r\n");
    return if (commit.len > 0) try allocator.dupe(u8, commit) else "unknown";
}

fn collectBenchmarkSamples(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable_path: []const u8,
    item: model.BenchmarkSuiteCase,
    binary_path: []const u8,
    options: model.BenchmarkOptions,
    mode: model.BenchmarkMode,
    stderr: *std.Io.Writer,
) ![]u64 {
    const validates_output = mode == .interpreter or mode == .aot_run;
    for (0..options.warmup) |_| _ = try benchmarkProcess(allocator, io, executable_path, item, binary_path, mode, validates_output, stderr);
    const samples = try allocator.alloc(u64, options.iterations);
    for (samples) |*sample| sample.* = try benchmarkProcess(allocator, io, executable_path, item, binary_path, mode, validates_output, stderr);
    return samples;
}

fn benchmarkProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable_path: []const u8,
    item: model.BenchmarkSuiteCase,
    binary_path: []const u8,
    mode: model.BenchmarkMode,
    validates_output: bool,
    stderr: *std.Io.Writer,
) !u64 {
    var argv: [5][]const u8 = undefined;
    const arguments: []const []const u8 = switch (mode) {
        .interpreter => blk: {
            argv = .{ executable_path, "run", item.source, undefined, undefined };
            break :blk argv[0..3];
        },
        .aot_compile => blk: {
            argv = .{ executable_path, "build", item.source, "-o", binary_path };
            break :blk argv[0..5];
        },
        .aot_run => blk: {
            argv = .{ binary_path, undefined, undefined, undefined, undefined };
            break :blk argv[0..1];
        },
    };
    var timed_argv: [6][]const u8 = undefined;
    const actual_arguments = if (mode == .aot_compile) blk: {
        timed_argv = .{ executable_path, "build", item.source, "-o", binary_path, "-O2" };
        break :blk timed_argv[0..6];
    } else arguments;
    const started = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const result = std.process.run(allocator, io, .{
        .argv = actual_arguments,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    }) catch |err| {
        try stderr.print("{s}: {s}プロセス起動失敗: {s}\n", .{ item.id, @tagName(mode), @errorName(err) });
        return error.BenchmarkProcessFailed;
    };
    const finished = std.Io.Timestamp.now(io, .awake).nanoseconds;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        try stderr.print("{s}: {s}が終了コード0になりませんでした\nstdout: {s}\nstderr: {s}\n", .{ item.id, @tagName(mode), result.stdout, result.stderr });
        return error.BenchmarkProcessFailed;
    }
    if (validates_output and !statistics.benchmarkOutputMatches(result.stdout, item.expected_stdout)) {
        try stderr.print("{s}: {s}の出力がsuiteの期待値と一致しませんでした\n期待値: {s}\n実際: {s}\n", .{ item.id, @tagName(mode), item.expected_stdout, result.stdout });
        return error.BenchmarkOutputMismatch;
    }
    return if (finished > started) std.math.cast(u64, finished - started) orelse std.math.maxInt(u64) else 0;
}

test "benchmarkの計測条件と出力先を解析する" {
    const options = try parseBenchmarkOptions(&.{ "--iterations", "9", "--warmup", "2", "--suite", "suite.json", "--output", "result.json", "--markdown", "result.md" });
    try std.testing.expectEqual(@as(usize, 9), options.iterations);
    try std.testing.expectEqual(@as(usize, 2), options.warmup);
    try std.testing.expectEqualStrings("suite.json", options.suite_path);
    try std.testing.expectEqualStrings("result.json", options.output_path);
    try std.testing.expectEqualStrings("result.md", options.markdown_path);
    try std.testing.expectError(error.InvalidBenchmarkIterations, parseBenchmarkOptions(&.{ "--iterations", "0" }));
    try std.testing.expectError(error.UnknownBenchmarkOption, parseBenchmarkOptions(&.{"--unknown"}));
}
