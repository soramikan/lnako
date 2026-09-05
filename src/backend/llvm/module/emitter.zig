const ir = @import("../../../ir/nako_ir.zig");
const context = @import("emitter/context.zig");
const preamble = @import("emitter/preamble.zig");
const declarations = @import("emitter/declarations.zig");
const functions_mod = @import("emitter/functions.zig");

pub const Emitter = context.Emitter;

pub fn run(emitter: *Emitter) !void {
    try preamble.collectModuleData(emitter);
    emitter.next_metadata = 4 + emitter.program.functions.len + 1;
    try preamble.emitPreamble(emitter);
    try preamble.emitDeclarations(emitter);
    try declarations.writeRuntimeHelpers(emitter);
    for (emitter.program.functions) |function| try functions_mod.writeFunction(emitter, function);
    for (emitter.program.functions) |function| try functions_mod.writeFunctionWrapper(emitter, function);
    try functions_mod.writeMain(emitter);
    try declarations.writeDebugMetadata(emitter);
}
