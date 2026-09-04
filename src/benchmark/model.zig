const std = @import("std");

pub const BenchmarkOptions = struct {
    suite_path: []const u8 = "benchmarks/suite.json",
    output_path: []const u8 = "benchmarks/results/latest.json",
    markdown_path: []const u8 = "benchmarks/results/latest.md",
    iterations: usize = 5,
    warmup: usize = 1,
    help: bool = false,
};

pub const BenchmarkSuite = struct {
    schema_version: u32,
    name: []const u8,
    cases: []BenchmarkSuiteCase,
};

pub const BenchmarkSuiteCase = struct {
    id: []const u8,
    source: []const u8,
    expected_stdout: []const u8,
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
    samples_ns: []u64,
    min_ns: u64,
    median_ns: u64,
    max_ns: u64,
};

pub const BenchmarkCaseReport = struct {
    id: []const u8,
    source: []const u8,
    expected_stdout: []const u8,
    measurements: []BenchmarkMeasurement,
};

pub const BenchmarkReport = struct {
    schema_version: u32,
    project: []const u8,
    version: []const u8,
    git_commit: []const u8,
    generated_at_unix_ms: i64,
    target: BenchmarkTarget,
    toolchain: BenchmarkToolchain,
    suite_name: []const u8,
    suite: []const u8,
    optimization: []const u8,
    iterations: usize,
    warmup: usize,
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
    UnknownBenchmarkOption,
    InvalidBenchmarkSuite,
    DuplicateBenchmarkCase,
    BenchmarkProcessFailed,
    BenchmarkOutputMismatch,
};
