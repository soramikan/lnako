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

    _ = @import("cli.zig");
    _ = @import("cli/app.zig");
    _ = @import("cli/arguments.zig");
    _ = @import("cli/commands/test.zig");

    _ = @import("backend/llvm/module.zig");
    _ = @import("backend/llvm/module/manifest.zig");
    _ = @import("backend/llvm/module/unsupported.zig");
    _ = @import("backend/llvm/module/emitter.zig");
    _ = @import("backend/llvm/module/emitter/context.zig");
    _ = @import("backend/llvm/module/emitter/preamble.zig");
    _ = @import("backend/llvm/module/emitter/declarations.zig");
    _ = @import("backend/llvm/module/emitter/functions.zig");
    _ = @import("backend/llvm/module/emitter/terminators.zig");
    _ = @import("backend/llvm/module/emitter/instruction_router.zig");
    _ = @import("backend/llvm/module/emitter/operations/constants.zig");
    _ = @import("backend/llvm/module/emitter/operations/collections.zig");
    _ = @import("backend/llvm/module/emitter/operations/variables.zig");
    _ = @import("backend/llvm/module/emitter/operations/control.zig");
    _ = @import("backend/llvm/module/emitter/operations/arithmetic.zig");
    _ = @import("backend/llvm/module/emitter/operations/calls.zig");
    _ = @import("backend/llvm/module/emitter/operations/plugins.zig");

    _ = @import("regexp");
}
