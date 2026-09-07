const ir = @import("../../../ir/nako_ir.zig");
const context = @import("emitter/context.zig");
const preamble = @import("emitter/preamble.zig");
const declarations = @import("emitter/declarations.zig");
const functions_mod = @import("emitter/functions.zig");

pub const Emitter = context.Emitter;

pub fn run(emitter: *Emitter) !void {
    try preamble.collectModuleData(emitter);
    // Reserve generic function scopes, the main scope, and the separate
    // scalar-variant scopes before allocating source locations.
    emitter.next_metadata = 5 + emitter.program.functions.len * 2;
    try preamble.emitPreamble(emitter);
    try preamble.emitDeclarations(emitter);
    try declarations.writeRuntimeHelpers(emitter);
    for (emitter.program.functions) |function| try functions_mod.writeFunction(emitter, function);
    for (emitter.program.functions) |function| try functions_mod.writeFunctionWrapper(emitter, function);
    try functions_mod.writeMain(emitter);
    try declarations.writeDebugMetadata(emitter);
}
