test {
    _ = @import("benchmark.zig");
    _ = @import("benchmark/model.zig");
    _ = @import("benchmark/runner.zig");
    _ = @import("benchmark/statistics.zig");
    _ = @import("benchmark/report.zig");

    _ = @import("compiler_pipeline.zig");
    _ = @import("compiler_pipeline/compile.zig");
    _ = @import("compiler_pipeline/embedded.zig");
}
