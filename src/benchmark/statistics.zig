const std = @import("std");
const model = @import("model.zig");

/// Summarize samples without changing their collection order. The no-allocator
/// entry point is retained for callers written against the v1 benchmark API.
pub fn summarizeBenchmarkSamples(mode: []const u8, samples: []u64) model.BenchmarkMeasurement {
    return summarizeBenchmarkSamplesWithAllocator(std.heap.page_allocator, mode, samples) catch unreachable;
}

pub fn summarizeBenchmarkSamplesWithAllocator(
    allocator: std.mem.Allocator,
    mode: []const u8,
    samples: []u64,
) !model.BenchmarkMeasurement {
    if (samples.len == 0) return error.EmptyBenchmarkSamples;

    // Keep samples_ns as the raw process observations. All ordering-dependent
    // calculations operate on this private copy.
    const sorted = try allocator.dupe(u64, samples);
    defer allocator.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));

    const median_ns = quantile(sorted, 1, 2);
    const p25_ns = quantile(sorted, 1, 4);
    const p75_ns = quantile(sorted, 3, 4);
    const mean_ns = mean(samples);
    const stddev_ns = populationStddev(samples, mean_ns);
    const mad_ns = medianAbsoluteDeviation(sorted, median_ns);
    return .{
        .mode = mode,
        .samples_ns = samples,
        .min_ns = sorted[0],
        .p25_ns = p25_ns,
        .median_ns = median_ns,
        .p75_ns = p75_ns,
        .max_ns = sorted[sorted.len - 1],
        .iqr_ns = p75_ns - p25_ns,
        .mad_ns = mad_ns,
        .mean_ns = mean_ns,
        .stddev_ns = stddev_ns,
        .cv = if (mean_ns == 0) 0 else stddev_ns / mean_ns,
        .warnings = &.{},
    };
}

/// Quantiles use the inclusive linear-interpolation (Hyndman-Fan type 7)
/// position `p * (n - 1)`. Since timings are integer nanoseconds, the
/// interpolated value is rounded to the nearest integer, with half values
/// rounded upward. This convention is also enforced by the JS result checker.
pub fn quantile(sorted: []const u64, numerator: u64, denominator: u64) u64 {
    std.debug.assert(sorted.len > 0);
    std.debug.assert(numerator <= denominator);
    if (sorted.len == 1 or numerator == 0) return sorted[0];
    if (numerator == denominator) return sorted[sorted.len - 1];
    const span = sorted.len - 1;
    const scaled = @as(u128, span) * numerator;
    const lower: usize = @intCast(scaled / denominator);
    const remainder: u64 = @intCast(scaled % denominator);
    if (remainder == 0 or lower + 1 >= sorted.len) return sorted[lower];
    const left = sorted[lower];
    const right = sorted[lower + 1];
    const distance = right - left;
    const interpolated = (@as(u128, distance) * remainder + denominator / 2) / denominator;
    return left + @as(u64, @intCast(interpolated));
}

fn mean(samples: []const u64) f64 {
    var total: f64 = 0;
    for (samples) |sample| total += @floatFromInt(sample);
    return total / @as(f64, @floatFromInt(samples.len));
}

fn populationStddev(samples: []const u64, average: f64) f64 {
    var squared: f64 = 0;
    for (samples) |sample| {
        const difference = @as(f64, @floatFromInt(sample)) - average;
        squared += difference * difference;
    }
    return @sqrt(squared / @as(f64, @floatFromInt(samples.len)));
}

fn medianAbsoluteDeviation(sorted: []const u64, median_ns: u64) u64 {
    const deviations = std.heap.page_allocator.alloc(u64, sorted.len) catch unreachable;
    defer std.heap.page_allocator.free(deviations);
    for (sorted, 0..) |sample, index| deviations[index] = if (sample >= median_ns) sample - median_ns else median_ns - sample;
    std.mem.sort(u64, deviations, {}, std.sort.asc(u64));
    return quantile(deviations, 1, 2);
}

pub fn benchmarkOutputMatches(actual: []const u8, expected: []const u8) bool {
    var actual_index: usize = 0;
    var expected_index: usize = 0;
    while (actual_index < actual.len or expected_index < expected.len) {
        const actual_byte = nextNormalizedByte(actual, &actual_index);
        const expected_byte = nextNormalizedByte(expected, &expected_index);
        if (actual_byte != expected_byte) return false;
    }
    return true;
}

fn nextNormalizedByte(bytes: []const u8, index: *usize) ?u8 {
    if (index.* >= bytes.len) return null;
    const value = bytes[index.*];
    index.* += 1;
    if (value == '\r') {
        if (index.* < bytes.len and bytes[index.*] == '\n') index.* += 1;
        return '\n';
    }
    return value;
}

test "benchmarkのCRLFとLFを同一視し空stdoutも受理する" {
    try std.testing.expect(benchmarkOutputMatches("10000\r\n", "10000\n"));
    try std.testing.expect(benchmarkOutputMatches("", ""));
    try std.testing.expect(!benchmarkOutputMatches("1000\r\n", "10000\n"));
}

test "raw sampleの順序を維持したまま統計を計算する" {
    var samples = [_]u64{ 9, 1, 7, 3 };
    const measurement = try summarizeBenchmarkSamplesWithAllocator(std.testing.allocator, "test", &samples);
    try std.testing.expectEqual(@as(u64, 9), measurement.samples_ns[0]);
    try std.testing.expectEqual(@as(u64, 1), measurement.samples_ns[1]);
    try std.testing.expectEqual(@as(u64, 5), measurement.median_ns);
    try std.testing.expectEqual(@as(u64, 3), measurement.p25_ns);
    try std.testing.expectEqual(@as(u64, 8), measurement.p75_ns);
    try std.testing.expectEqual(@as(u64, 5), measurement.iqr_ns);
    try std.testing.expectEqual(@as(u64, 3), measurement.mad_ns);
    try std.testing.expectApproxEqAbs(@as(f64, 5), measurement.mean_ns, 0.0001);
}

test "空のsampleは要約できない" {
    try std.testing.expectError(error.EmptyBenchmarkSamples, summarizeBenchmarkSamplesWithAllocator(std.testing.allocator, "test", &.{}));
}
