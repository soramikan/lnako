const shared = @import("interpreter/shared.zig");
const state = @import("interpreter/state.zig");

pub const Value = shared.Value;
pub const Runtime = shared.Runtime;
pub const Host = state.Host;
pub const BufferHost = state.BufferHost;
pub const TestResult = state.TestResult;
pub const DynamicPreparationFn = state.DynamicPreparationFn;
pub const PreparedProgram = state.PreparedProgram;
pub const PreparedFunction = state.PreparedFunction;
pub const PreparedInstruction = state.PreparedInstruction;
pub const PreparedBlock = state.PreparedBlock;
pub const Interpreter = state.Interpreter;

pub const tests = @import("interpreter/tests.zig");
pub const exception_boundary_tests = @import("interpreter/exception_boundaries_test.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
