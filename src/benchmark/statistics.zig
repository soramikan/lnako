const std = @import("std");
const model = @import("model.zig");

pub fn summarizeBenchmarkSamples(mode: []const u8, samples: []u64) model.BenchmarkMeasurement {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    var total = samples[samples.len / 2];
    if (samples.len % 2 == 0) total = samples[samples.len / 2 - 1] / 2 + samples[samples.len / 2] / 2 + (samples[samples.len / 2 - 1] % 2 + samples[samples.len / 2] % 2) / 2;
    return .{
        .mode = mode,
        .samples_ns = samples,
        .min_ns = samples[0],
        .median_ns = total,
        .max_ns = samples[samples.len - 1],
    };
}

pub fn benchmarkOutputMatches(actual: []const u8, expected: []const u8) bool {
    var actual_index: usize = 0;
    var expected_index: usize = 0;
    while (true) {
        while (actual_index + 1 < actual.len and actual[actual_index] == '\r' and actual[actual_index + 1] == '\n') actual_index += 1;
        while (expected_index + 1 < expected.len and expected[expected_index] == '\r' and expected[expected_index + 1] == '\n') expected_index += 1;
        const actual_byte = if (actual_index < actual.len) actual[actual_index] else null;
        const expected_byte = if (expected_index < expected.len) expected[expected_index] else null;
        if (actual_byte == null or expected_byte == null) return actual_byte == null and expected_byte == null;
        if (actual_byte.? != expected_byte.?) return false;
        actual_index += 1;
        expected_index += 1;
    }
}

test "benchmarkのCRLFをLFとして期待値と比較する" {
    try std.testing.expect(benchmarkOutputMatches("10000\r\n", "10000\n"));
    try std.testing.expect(!benchmarkOutputMatches("1000\r\n", "10000\n"));
}

test "benchmarkの中央値を昇順sampleから計算する" {
    const samples = try std.testing.allocator.alloc(u64, 4);
    samples[0] = 9;
    samples[1] = 1;
    samples[2] = 7;
    samples[3] = 3;
    const measurement = summarizeBenchmarkSamples("test", samples);
    defer std.testing.allocator.free(measurement.samples_ns);
    try std.testing.expectEqual(@as(u64, 5), measurement.median_ns);
    try std.testing.expectEqual(@as(u64, 1), measurement.min_ns);
    try std.testing.expectEqual(@as(u64, 9), measurement.max_ns);
}
