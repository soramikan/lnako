const std = @import("std");

/// The v2 suite is the default benchmark input. The legacy path is kept so
/// release artifacts produced from an older checkout remain reproducible.
pub const default_suite_path = "benchmarks/suites/v2.json";
pub const legacy_suite_path = "benchmarks/suite.json";

pub const Profile = enum { smoke, normal, full };

pub fn profileName(profile: Profile) []const u8 {
    return @tagName(profile);
}

pub fn profileDefaults(profile: Profile) struct { warmup: usize, samples: usize } {
    return switch (profile) {
        .smoke => .{ .warmup = 1, .samples = 3 },
        .normal => .{ .warmup = 3, .samples = 10 },
        .full => .{ .warmup = 5, .samples = 25 },
    };
}

pub const BenchmarkOptions = struct {
    suite_path: []const u8 = default_suite_path,
    output_path: []const u8 = "benchmarks/results/latest.json",
    markdown_path: []const u8 = "benchmarks/results/latest.md",
    profile: Profile = .normal,
    iterations: usize = profileDefaults(.normal).samples,
    warmup: usize = profileDefaults(.normal).warmup,
    iterations_explicit: bool = false,
    warmup_explicit: bool = false,
    optimization: []const u8 = "O2",
    /// A repeated --case filter. The parser owns this small list with the
    /// process allocator; options live for one CLI invocation.
    case_ids: []const []const u8 = &.{},
    suite_explicit: bool = false,
    help: bool = false,
};

/// A normalized case shared by v1 and v2 execution. All string slices point
/// into the suite parse arena or the options argument vector and remain valid
/// until the benchmark run has written its report.
pub const BenchmarkSuiteCase = struct {
    id: []const u8,
    category: []const u8 = "legacy",
    kind: []const u8 = "kernel",
    description: []const u8 = "",
    measurement: []const u8 = "startup",
    profiles: []const []const u8 = &.{},
    tags: []const []const u8 = &.{},
    source: []const u8,
    source_sha256: []const u8 = "",
    input_args: []const []const u8 = &.{},
    expected_stdout: []const u8,
};

pub const BenchmarkSuite = struct {
    schema_version: u32,
    name: []const u8,
    cases: []BenchmarkSuiteCase,
};

pub const BenchmarkTarget = struct {
    os: []const u8,
    arch: []const u8,
};

pub const BenchmarkToolchain = struct {
    zig: []const u8,
    llvm: []const u8,
};

pub const BenchmarkMeasurement = struct {
    mode: []const u8,
    /// Raw samples remain in collection order. Summary calculations use an
    /// internal sorted copy (see statistics.zig).
    samples_ns: []u64,
    min_ns: u64,
    p25_ns: u64 = 0,
    median_ns: u64,
    p75_ns: u64 = 0,
    max_ns: u64,
    iqr_ns: u64 = 0,
    mad_ns: u64 = 0,
    mean_ns: f64 = 0,
    stddev_ns: f64 = 0,
    cv: f64 = 0,
    warnings: []const []const u8 = &.{},
    /// Compile measurements carry the size observed after each compile. A
    /// single final value is also emitted for consumers that only need the
    /// headline size.
    binary_size_samples_bytes: ?[]u64 = null,
    binary_size_bytes: ?u64 = null,
};

pub const BenchmarkCaseReport = struct {
    id: []const u8,
    category: []const u8 = "legacy",
    kind: []const u8 = "kernel",
    description: []const u8 = "",
    measurement: []const u8 = "startup",
    profiles: []const []const u8 = &.{},
    tags: []const []const u8 = &.{},
    source: []const u8,
    source_sha256: []const u8 = "",
    input_args: []const []const u8 = &.{},
    expected_stdout: []const u8,
    measurements: []BenchmarkMeasurement,
};

pub const BenchmarkReport = struct {
    schema_version: u32,
    project: []const u8,
    version: []const u8,
    git_commit: []const u8,
    git_dirty: bool = false,
    generated_at_unix_ms: i64,
    target: BenchmarkTarget,
    toolchain: BenchmarkToolchain,
    profile: []const u8 = "legacy",
    iterations: usize,
    warmup: usize,
    optimization: []const u8,
    suite_name: []const u8,
    suite: []const u8,
    suite_sha256: []const u8 = "",
    /// `source` is the suite path recorded as provenance. `suite` remains for
    /// v1 compatibility and existing artifact consumers.
    source: []const u8 = "",
    cases: []BenchmarkCaseReport,
};

pub const BenchmarkMode = enum { interpreter, aot_compile, aot_run };

pub const Error = error{
    MissingBenchmarkSuite,
    MissingBenchmarkOutput,
    MissingBenchmarkMarkdown,
    MissingBenchmarkIterations,
    InvalidBenchmarkIterations,
    MissingBenchmarkWarmup,
    InvalidBenchmarkWarmup,
    MissingBenchmarkProfile,
    InvalidBenchmarkProfile,
    MissingBenchmarkCase,
    InvalidBenchmarkCase,
    MissingBenchmarkOptimization,
    InvalidBenchmarkOptimization,
    UnknownBenchmarkOption,
    InvalidBenchmarkSuite,
    DuplicateBenchmarkCase,
    BenchmarkProcessFailed,
    BenchmarkOutputMismatch,
};

pub fn isValidProfileName(value: []const u8) bool {
    return std.mem.eql(u8, value, "smoke") or std.mem.eql(u8, value, "normal") or std.mem.eql(u8, value, "full");
}

pub fn isValidOptimization(value: []const u8) bool {
    return std.mem.eql(u8, value, "O0") or std.mem.eql(u8, value, "O1") or
        std.mem.eql(u8, value, "O2") or std.mem.eql(u8, value, "O3");
}

pub fn optimizationFlag(value: []const u8) []const u8 {
    return if (value.len > 0 and value[0] == '-') value else value;
}

test "profileの既定値は計測計画と一致する" {
    try std.testing.expectEqual(@as(usize, 1), profileDefaults(.smoke).warmup);
    try std.testing.expectEqual(@as(usize, 3), profileDefaults(.smoke).samples);
    try std.testing.expectEqual(@as(usize, 3), profileDefaults(.normal).warmup);
    try std.testing.expectEqual(@as(usize, 10), profileDefaults(.normal).samples);
    try std.testing.expectEqual(@as(usize, 5), profileDefaults(.full).warmup);
    try std.testing.expectEqual(@as(usize, 25), profileDefaults(.full).samples);
}

test "最適化レベルの入力を検証する" {
    try std.testing.expect(isValidOptimization("O2"));
    try std.testing.expect(!isValidOptimization("O4"));
    try std.testing.expectEqualStrings("-O2", optimizationFlag("-O2"));
}
