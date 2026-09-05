const std = @import("std");
const builtin = @import("builtin");
const lnako = @import("lnako");
const model = @import("model.zig");
const statistics = @import("statistics.zig");
const report = @import("report.zig");

const short_duration_threshold_ns: u64 = 200 * std.time.ns_per_ms;

pub fn parseBenchmarkOptions(arguments: []const []const u8) model.Error!model.BenchmarkOptions {
    var options = model.BenchmarkOptions{};
    var case_ids = std.ArrayList([]const u8).empty;
    errdefer case_ids.deinit(std.heap.page_allocator);

    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, argument, "--suite")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkSuite;
            options.suite_path = arguments[index];
            options.suite_explicit = true;
        } else if (std.mem.eql(u8, argument, "--output")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkOutput;
            options.output_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--markdown")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkMarkdown;
            options.markdown_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--profile")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkProfile;
            options.profile = parseProfile(arguments[index]) orelse return error.InvalidBenchmarkProfile;
            if (!options.iterations_explicit) options.iterations = model.profileDefaults(options.profile).samples;
            if (!options.warmup_explicit) options.warmup = model.profileDefaults(options.profile).warmup;
        } else if (std.mem.eql(u8, argument, "--case")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkCase;
            if (arguments[index].len == 0) return error.InvalidBenchmarkCase;
            case_ids.append(std.heap.page_allocator, arguments[index]) catch return error.InvalidBenchmarkCase;
        } else if (std.mem.eql(u8, argument, "--optimization")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkOptimization;
            options.optimization = normalizeOptimization(arguments[index]) orelse return error.InvalidBenchmarkOptimization;
        } else if (std.mem.eql(u8, argument, "--iterations")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkIterations;
            options.iterations = std.fmt.parseUnsigned(usize, arguments[index], 10) catch return error.InvalidBenchmarkIterations;
            if (options.iterations == 0) return error.InvalidBenchmarkIterations;
            options.iterations_explicit = true;
        } else if (std.mem.eql(u8, argument, "--warmup")) {
            index += 1;
            if (index >= arguments.len) return error.MissingBenchmarkWarmup;
            options.warmup = std.fmt.parseUnsigned(usize, arguments[index], 10) catch return error.InvalidBenchmarkWarmup;
            options.warmup_explicit = true;
        } else if (std.mem.eql(u8, argument, "-O0") or std.mem.eql(u8, argument, "-O1") or std.mem.eql(u8, argument, "-O2") or std.mem.eql(u8, argument, "-O3")) {
            options.optimization = argument[1..];
        } else return error.UnknownBenchmarkOption;
    }
    options.case_ids = case_ids.toOwnedSlice(std.heap.page_allocator) catch return error.InvalidBenchmarkCase;
    return options;
}

fn parseProfile(value: []const u8) ?model.Profile {
    if (std.mem.eql(u8, value, "smoke")) return .smoke;
    if (std.mem.eql(u8, value, "normal")) return .normal;
    if (std.mem.eql(u8, value, "full")) return .full;
    return null;
}

fn normalizeOptimization(value: []const u8) ?[]const u8 {
    const normalized = if (value.len > 0 and value[0] == '-') value[1..] else value;
    return if (model.isValidOptimization(normalized)) normalized else null;
}

pub fn writeBenchmarkUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\使い方: lnako benchmark [options]
        \\
        \\  --suite <path>       ベンチマークsuite JSON（既定: benchmarks/suites/v2.json、無い場合はv1へフォールバック）
        \\  --output <path>      JSON結果の出力先（既定: benchmarks/results/latest.json）
        \\  --markdown <path>    Markdown結果の出力先（既定: benchmarks/results/latest.md）
        \\  --profile <name>     smoke (1/3), normal (3/10), full (5/25)
        \\  --case <id>          対象case（複数指定可）
        \\  --optimization <O0..O3>  AOT最適化レベル（既定: O2）
        \\  --iterations <n>     計測回数（profileの値を上書き）
        \\  --warmup <n>         ウォームアップ回数（profileの値を上書き）
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
    var suite_path = options.suite_path;
    const suite_bytes = blk: {
        break :blk std.Io.Dir.cwd().readFileAlloc(io, suite_path, allocator, .limited(4 * 1024 * 1024)) catch |err| {
            // The default changed to v2, but old checkouts and release bundles
            // still carry benchmarks/suite.json. Only a missing default file may
            // fall back; a present but invalid v2 file must fail validation.
            if (!options.suite_explicit and std.mem.eql(u8, suite_path, model.default_suite_path) and err == error.FileNotFound) {
                suite_path = model.legacy_suite_path;
                break :blk std.Io.Dir.cwd().readFileAlloc(io, suite_path, allocator, .limited(4 * 1024 * 1024)) catch return error.InvalidBenchmarkSuite;
            }
            return error.InvalidBenchmarkSuite;
        };
    };
    defer allocator.free(suite_bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, suite_bytes, .{}) catch return error.InvalidBenchmarkSuite;
    defer parsed.deinit();
    const suite = try normalizeSuite(allocator, parsed.value);
    const suite_sha256 = try sha256Hex(allocator, suite_bytes);
    if (suite.cases.len == 0) return error.InvalidBenchmarkSuite;

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

    var case_reports = std.ArrayList(model.BenchmarkCaseReport).empty;
    var selected_count: usize = 0;
    for (suite.cases, 0..) |item, case_index| {
        if (!caseSelected(item.id, options.case_ids)) continue;
        if (!caseSupportsProfile(item, options.profile, suite.schema_version)) continue;
        selected_count += 1;
        const source_sha256 = try hashBenchmarkSource(allocator, io, item.source);

        const binary_name = if (builtin.os.tag == .windows) "benchmark-program.exe" else "benchmark-program";
        const binary_path = try std.fmt.allocPrint(allocator, "{s}{c}{d}-{s}", .{
            temporary_directory,
            std.fs.path.sep,
            case_index,
            binary_name,
        });
        defer allocator.free(binary_path);

        var measurements = std.ArrayList(model.BenchmarkMeasurement).empty;
        const modes = modesForMeasurement(item.measurement);
        for (modes) |mode| {
            const capture = try collectBenchmarkSamples(allocator, io, executable_path, item, binary_path, options, mode, stderr);
            var summary = try statistics.summarizeBenchmarkSamplesWithAllocator(allocator, @tagName(mode), capture.samples);
            summary.binary_size_samples_bytes = capture.binary_size_samples;
            if (capture.binary_size_samples) |sizes| summary.binary_size_bytes = medianRaw(sizes);
            summary.warnings = try shortDurationWarnings(allocator, summary.median_ns, options.profile);
            try measurements.append(allocator, summary);
        }
        try case_reports.append(allocator, .{
            .id = item.id,
            .category = item.category,
            .kind = item.kind,
            .description = item.description,
            .measurement = item.measurement,
            .profiles = item.profiles,
            .tags = item.tags,
            .source = item.source,
            .source_sha256 = source_sha256,
            .input_args = item.input_args,
            .expected_stdout = item.expected_stdout,
            .measurements = try measurements.toOwnedSlice(allocator),
        });
    }
    if (selected_count == 0) return error.InvalidBenchmarkCase;

    const generated_at_unix_ms = std.math.cast(i64, @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1_000_000)) orelse 0;
    const git_commit = try benchmarkGitCommit(allocator, io, environment);
    const git_dirty = try benchmarkGitDirty(allocator, io, environment);
    const generated_report = model.BenchmarkReport{
        .schema_version = suite.schema_version,
        .project = "lnako",
        .version = lnako.version,
        .git_commit = git_commit,
        .git_dirty = git_dirty,
        .generated_at_unix_ms = generated_at_unix_ms,
        .target = .{ .os = @tagName(builtin.os.tag), .arch = @tagName(builtin.cpu.arch) },
        .toolchain = .{ .zig = "0.16.0", .llvm = "22.1.8" },
        .profile = model.profileName(options.profile),
        .iterations = options.iterations,
        .warmup = options.warmup,
        .optimization = options.optimization,
        .suite_name = suite.name,
        .suite = suite_path,
        .suite_sha256 = suite_sha256,
        .source = suite_path,
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

fn normalizeSuite(allocator: std.mem.Allocator, value: std.json.Value) model.Error!model.BenchmarkSuite {
    if (value != .object) return error.InvalidBenchmarkSuite;
    const schema = jsonUnsigned(value.object.get("schema_version")) orelse return error.InvalidBenchmarkSuite;
    const name = jsonString(value.object.get("name")) orelse return error.InvalidBenchmarkSuite;
    const case_value = value.object.get("cases") orelse return error.InvalidBenchmarkSuite;
    if (case_value != .array or case_value.array.items.len == 0) return error.InvalidBenchmarkSuite;

    var cases = std.ArrayList(model.BenchmarkSuiteCase).empty;
    for (case_value.array.items) |item| {
        if (item != .object) return error.InvalidBenchmarkSuite;
        const object = item.object;
        const id = jsonString(object.get("id")) orelse return error.InvalidBenchmarkSuite;
        const source = sourcePath(object) orelse return error.InvalidBenchmarkSuite;
        const expected_stdout = jsonString(object.get("expected_stdout")) orelse return error.InvalidBenchmarkSuite;
        for (cases.items) |previous| if (std.mem.eql(u8, id, previous.id)) return error.DuplicateBenchmarkCase;

        if (schema == 1) {
            cases.append(allocator, .{
                .id = id,
                .category = "legacy",
                .kind = "kernel",
                .description = id,
                .measurement = "startup",
                .profiles = &.{},
                .tags = &.{},
                .source = source,
                .source_sha256 = "",
                .input_args = &.{},
                .expected_stdout = expected_stdout,
            }) catch return error.InvalidBenchmarkSuite;
            continue;
        }
        if (schema != 2) return error.InvalidBenchmarkSuite;
        const category = jsonString(object.get("category")) orelse return error.InvalidBenchmarkSuite;
        const kind = jsonString(object.get("kind")) orelse return error.InvalidBenchmarkSuite;
        const description = jsonString(object.get("description")) orelse return error.InvalidBenchmarkSuite;
        const measurement = jsonString(object.get("measurement")) orelse return error.InvalidBenchmarkSuite;
        if (!isMeasurementName(measurement)) return error.InvalidBenchmarkSuite;
        const profiles = try jsonStringArray(allocator, object.get("profiles"), true);
        for (profiles) |profile| if (!model.isValidProfileName(profile)) return error.InvalidBenchmarkSuite;
        const tags = try jsonStringArray(allocator, object.get("tags"), true);
        const input_args = try jsonInputArgs(allocator, object.get("input"));
        cases.append(allocator, .{
            .id = id,
            .category = category,
            .kind = kind,
            .description = description,
            .measurement = measurement,
            .profiles = profiles,
            .tags = tags,
            .source = source,
            .source_sha256 = "",
            .input_args = input_args,
            .expected_stdout = expected_stdout,
        }) catch return error.InvalidBenchmarkSuite;
    }
    return .{ .schema_version = schema, .name = name, .cases = cases.toOwnedSlice(allocator) catch return error.InvalidBenchmarkSuite };
}

fn sourcePath(object: std.json.ObjectMap) ?[]const u8 {
    if (jsonString(object.get("source"))) |source| return if (source.len > 0) source else null;
    const sources = object.get("sources") orelse return null;
    if (sources != .object) return null;
    return jsonString(sources.object.get("lnako"));
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const inner = value orelse return null;
    return if (inner == .string) inner.string else null;
}

fn jsonUnsigned(value: ?std.json.Value) ?u32 {
    const inner = value orelse return null;
    return if (inner == .integer and inner.integer >= 0) std.math.cast(u32, inner.integer) else null;
}

fn jsonStringArray(allocator: std.mem.Allocator, value: ?std.json.Value, required: bool) model.Error![]const []const u8 {
    const inner = value orelse return if (required) error.InvalidBenchmarkSuite else &.{};
    if (inner != .array) return error.InvalidBenchmarkSuite;
    var strings = std.ArrayList([]const u8).empty;
    for (inner.array.items) |item| strings.append(allocator, jsonStringValue(item) orelse return error.InvalidBenchmarkSuite) catch return error.InvalidBenchmarkSuite;
    return strings.toOwnedSlice(allocator) catch return error.InvalidBenchmarkSuite;
}

fn jsonStringValue(value: std.json.Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}

fn jsonInputArgs(allocator: std.mem.Allocator, value: ?std.json.Value) model.Error![]const []const u8 {
    const input = value orelse return &.{};
    if (input != .object) return error.InvalidBenchmarkSuite;
    return jsonStringArray(allocator, input.object.get("args"), true);
}

fn isMeasurementName(value: []const u8) bool {
    return std.mem.eql(u8, value, "startup") or std.mem.eql(u8, value, "steady_state") or std.mem.eql(u8, value, "compile");
}

fn caseSelected(id: []const u8, filters: []const []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |filter| if (std.mem.eql(u8, id, filter)) return true;
    return false;
}

fn caseSupportsProfile(item: model.BenchmarkSuiteCase, profile: model.Profile, schema_version: u32) bool {
    if (schema_version == 1 or item.profiles.len == 0) return true;
    const wanted = model.profileName(profile);
    for (item.profiles) |available| if (std.mem.eql(u8, wanted, available)) return true;
    return false;
}

fn modesForMeasurement(measurement: []const u8) []const model.BenchmarkMode {
    return if (std.mem.eql(u8, measurement, "compile")) &compile_modes else &all_modes;
}

const all_modes = [_]model.BenchmarkMode{ .interpreter, .aot_compile, .aot_run };
const compile_modes = [_]model.BenchmarkMode{.aot_compile};

const BenchmarkCapture = struct {
    samples: []u64,
    binary_size_samples: ?[]u64 = null,
};

fn collectBenchmarkSamples(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable_path: []const u8,
    item: model.BenchmarkSuiteCase,
    binary_path: []const u8,
    options: model.BenchmarkOptions,
    mode: model.BenchmarkMode,
    stderr: *std.Io.Writer,
) !BenchmarkCapture {
    const validates_output = mode == .interpreter or mode == .aot_run;
    for (0..options.warmup) |_| _ = try benchmarkProcess(allocator, io, executable_path, item, binary_path, options, mode, validates_output, stderr);
    const samples = try allocator.alloc(u64, options.iterations);
    const binary_sizes = if (mode == .aot_compile) try allocator.alloc(u64, options.iterations) else null;
    errdefer {
        allocator.free(samples);
        if (binary_sizes) |sizes| allocator.free(sizes);
    }
    for (samples, 0..) |*sample, index| {
        sample.* = try benchmarkProcess(allocator, io, executable_path, item, binary_path, options, mode, validates_output, stderr);
        if (binary_sizes) |sizes| {
            const stat = std.Io.Dir.cwd().statFile(io, binary_path, .{}) catch {
                try stderr.print("{s}: compile後のbinary sizeを取得できませんでした\n", .{item.id});
                return error.BenchmarkProcessFailed;
            };
            sizes[index] = stat.size;
        }
    }
    return .{ .samples = samples, .binary_size_samples = binary_sizes };
}

fn benchmarkProcess(
    allocator: std.mem.Allocator,
    io: std.Io,
    executable_path: []const u8,
    item: model.BenchmarkSuiteCase,
    binary_path: []const u8,
    options: model.BenchmarkOptions,
    mode: model.BenchmarkMode,
    validates_output: bool,
    stderr: *std.Io.Writer,
) !u64 {
    var arguments = std.ArrayList([]const u8).empty;
    defer arguments.deinit(allocator);
    var optimization = [_]u8{ '-', 'O', '2' };
    optimization[2] = options.optimization[1];
    switch (mode) {
        .interpreter => {
            try arguments.append(allocator, executable_path);
            try arguments.append(allocator, "run");
            try arguments.append(allocator, item.source);
            if (item.input_args.len > 0) {
                try arguments.append(allocator, "--");
                try arguments.appendSlice(allocator, item.input_args);
            }
        },
        .aot_compile => {
            try arguments.append(allocator, executable_path);
            try arguments.append(allocator, "build");
            try arguments.append(allocator, item.source);
            try arguments.append(allocator, "-o");
            try arguments.append(allocator, binary_path);
            try arguments.append(allocator, &optimization);
        },
        .aot_run => {
            try arguments.append(allocator, binary_path);
            try arguments.appendSlice(allocator, item.input_args);
        },
    }
    const started = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const result = std.process.run(allocator, io, .{
        .argv = arguments.items,
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

fn medianRaw(values: []const u64) u64 {
    const copy = std.heap.page_allocator.dupe(u64, values) catch unreachable;
    defer std.heap.page_allocator.free(copy);
    std.mem.sort(u64, copy, {}, std.sort.asc(u64));
    return statistics.quantile(copy, 1, 2);
}

fn shortDurationWarnings(allocator: std.mem.Allocator, median_ns: u64, profile: model.Profile) ![]const []const u8 {
    if (profile != .normal or median_ns >= short_duration_threshold_ns) return &.{};
    const warnings = try allocator.alloc([]const u8, 1);
    warnings[0] = "short_duration_lt_200ms";
    return warnings;
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

fn benchmarkGitDirty(allocator: std.mem.Allocator, io: std.Io, environment: *const std.process.Environ.Map) !bool {
    if (environment.get("LNAKO_BENCHMARK_GIT_DIRTY")) |value| {
        if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) return true;
        if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false")) return false;
    }
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "status", "--porcelain", "--untracked-files=all" },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(256),
    }) catch return true;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) return true;
    return std.mem.trim(u8, result.stdout, " \t\r\n").len != 0;
}

fn hashBenchmarkSource(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch return error.InvalidBenchmarkSuite;
    defer allocator.free(bytes);
    return sha256Hex(allocator, bytes);
}

fn sha256Hex(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex: [64]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        hex[index * 2] = alphabet[byte >> 4];
        hex[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return allocator.dupe(u8, &hex);
}

test "benchmarkのprofile・case・optimizationオプションを解析する" {
    const options = try parseBenchmarkOptions(&.{ "--profile", "smoke", "--case", "one", "--case", "two", "--optimization", "O3", "--iterations", "9", "--warmup", "2", "--suite", "suite.json", "--output", "result.json", "--markdown", "result.md" });
    try std.testing.expectEqual(model.Profile.smoke, options.profile);
    try std.testing.expectEqual(@as(usize, 9), options.iterations);
    try std.testing.expectEqual(@as(usize, 2), options.warmup);
    try std.testing.expectEqualStrings("O3", options.optimization);
    try std.testing.expectEqual(@as(usize, 2), options.case_ids.len);
    try std.testing.expectEqualStrings("one", options.case_ids[0]);
    try std.testing.expectEqualStrings("suite.json", options.suite_path);
    try std.testing.expect(options.suite_explicit);
}

test "profile指定は明示したiterationsとwarmupを上書きしない" {
    const options = try parseBenchmarkOptions(&.{ "--iterations", "7", "--warmup", "4", "--profile", "full" });
    try std.testing.expectEqual(@as(usize, 7), options.iterations);
    try std.testing.expectEqual(@as(usize, 4), options.warmup);
}

test "未知のprofileと最適化レベルを拒否する" {
    try std.testing.expectError(error.InvalidBenchmarkProfile, parseBenchmarkOptions(&.{ "--profile", "fast" }));
    try std.testing.expectError(error.InvalidBenchmarkOptimization, parseBenchmarkOptions(&.{ "--optimization", "O4" }));
    try std.testing.expectError(error.MissingBenchmarkCase, parseBenchmarkOptions(&.{"--case"}));
}
