const std = @import("std");
const lnako = @import("lnako");

pub const BuildOptions = struct {
    input: []const u8,
    output: []const u8,
    optimization: lnako.backend.llvm.compiler.Optimization = .o0,
    emit: lnako.backend.llvm.compiler.Emit = .executable,
    compat_js: bool = false,
};

pub fn parseBuildOptions(arguments: []const []const u8) !BuildOptions {
    if (arguments.len == 0) return error.MissingInput;
    var output: ?[]const u8 = null;
    var optimization: lnako.backend.llvm.compiler.Optimization = .o0;
    var emit: lnako.backend.llvm.compiler.Emit = .executable;
    var compat_js = false;
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        if (std.mem.eql(u8, argument, "-o")) {
            index += 1;
            if (index >= arguments.len) return error.MissingOutput;
            output = arguments[index];
        } else if (std.mem.eql(u8, argument, "-O0")) {
            optimization = .o0;
        } else if (std.mem.eql(u8, argument, "-O1")) {
            optimization = .o1;
        } else if (std.mem.eql(u8, argument, "-O2")) {
            optimization = .o2;
        } else if (std.mem.eql(u8, argument, "-O3")) {
            optimization = .o3;
        } else if (std.mem.eql(u8, argument, "--compat-js")) {
            compat_js = true;
        } else if (std.mem.eql(u8, argument, "--emit")) {
            index += 1;
            if (index >= arguments.len) return error.MissingEmitKind;
            emit = if (std.mem.eql(u8, arguments[index], "exe"))
                .executable
            else if (std.mem.eql(u8, arguments[index], "obj"))
                .object
            else if (std.mem.eql(u8, arguments[index], "llvm-ir"))
                .llvm_ir
            else
                return error.InvalidEmitKind;
        } else return error.UnknownBuildOption;
    }
    return .{
        .input = arguments[0],
        .output = output orelse return error.MissingOutput,
        .optimization = optimization,
        .emit = emit,
        .compat_js = compat_js,
    };
}

pub fn hasArgument(arguments: []const []const u8, expected: []const u8) bool {
    for (arguments) |argument| if (std.mem.eql(u8, argument, expected)) return true;
    return false;
}

pub fn splitRunArguments(arguments: []const []const u8) struct { lnako: []const []const u8, program: []const []const u8 } {
    for (arguments, 0..) |argument, index| {
        if (std.mem.eql(u8, argument, "--")) {
            return .{ .lnako = arguments[0..index], .program = arguments[index + 1 ..] };
        }
    }
    return .{ .lnako = arguments, .program = &[_][]const u8{} };
}

pub fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

test "buildの出力形式と最適化レベルを解析する" {
    const options = try parseBuildOptions(&.{ "main.nako3", "-o", "main", "-O3", "--emit", "obj" });
    try std.testing.expectEqualStrings("main.nako3", options.input);
    try std.testing.expectEqualStrings("main", options.output);
    try std.testing.expectEqual(lnako.backend.llvm.compiler.Optimization.o3, options.optimization);
    try std.testing.expectEqual(lnako.backend.llvm.compiler.Emit.object, options.emit);
    try std.testing.expectError(error.MissingOutput, parseBuildOptions(&.{"main.nako3"}));
    try std.testing.expectError(error.InvalidEmitKind, parseBuildOptions(&.{ "main.nako3", "-o", "main", "--emit", "asm" }));
}
