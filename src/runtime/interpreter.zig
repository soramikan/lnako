const shared = @import("interpreter/shared.zig");
const state = @import("interpreter/state.zig");

pub const Value = shared.Value;
pub const Runtime = shared.Runtime;
pub const Host = state.Host;
pub const BufferHost = state.BufferHost;
pub const TestResult = state.TestResult;
pub const DynamicPreparationFn = state.DynamicPreparationFn;
pub const Interpreter = state.Interpreter;

pub const tests = @import("interpreter/tests.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
