test {
    _ = @import("benchmark.zig");
    _ = @import("benchmark/model.zig");
    _ = @import("benchmark/runner.zig");
    _ = @import("benchmark/statistics.zig");
    _ = @import("benchmark/report.zig");

    _ = @import("compiler_pipeline.zig");
    _ = @import("compiler_pipeline/compile.zig");
    _ = @import("compiler_pipeline/embedded.zig");

    _ = @import("host.zig");
    _ = @import("host/environment.zig");
    _ = @import("host/process.zig");
    _ = @import("host/archive.zig");
    _ = @import("host/network.zig");
    _ = @import("host/http_client.zig");
    _ = @import("host/state.zig");
}
