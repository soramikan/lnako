const model = @import("benchmark/model.zig");
const runner = @import("benchmark/runner.zig");
const statistics = @import("benchmark/statistics.zig");
const report = @import("benchmark/report.zig");

pub const BenchmarkOptions = model.BenchmarkOptions;

pub const run = runner.runBenchmark;
pub const parseOptions = runner.parseBenchmarkOptions;
pub const writeUsage = runner.writeBenchmarkUsage;

test {
    _ = model;
    _ = runner;
    _ = statistics;
    _ = report;
}
