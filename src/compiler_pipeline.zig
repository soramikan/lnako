pub const compile = @import("compiler_pipeline/compile.zig");
pub const embedded = @import("compiler_pipeline/embedded.zig");

pub const compileInput = compile.compileInput;
pub const compileInputWithProvider = compile.compileInputWithProvider;
pub const writeCompatExecutable = embedded.writeCompatExecutable;
