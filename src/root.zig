const std = @import("std");

pub const version = "0.0.0-dev";

pub const frontend = struct {
    pub const source = @import("frontend/source.zig");
    pub const josi = @import("frontend/josi.zig");
    pub const token = @import("frontend/token.zig");
    pub const lexer = @import("frontend/lexer.zig");
    pub const syntax_transform = @import("frontend/syntax_transform.zig");
    pub const ast = @import("frontend/ast.zig");
    pub const diagnostic = @import("frontend/diagnostic.zig");
    pub const parser = @import("frontend/parser.zig");
};

pub const semantic = struct {
    pub const analyzer = @import("semantic/analyzer.zig");
    pub const module_graph = @import("semantic/module_graph.zig");
};

pub const ir = struct {
    pub const hir = @import("ir/hir.zig");
    pub const nako_ir = @import("ir/nako_ir.zig");
    pub const lower_ssa = @import("ir/lower_ssa.zig");
    pub const verifier = @import("ir/verifier.zig");
    pub const printer = @import("ir/printer.zig");
};

pub const Command = enum {
    build,
    run,
    check,
    test_command,
    compat,
    benchmark,
    help,
    version,
};

pub const ParseError = error{
    UnknownCommand,
    MissingCompatAction,
    UnexpectedArgument,
};

pub fn parseCommand(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return .help;
    const first = args[0];
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h") or std.mem.eql(u8, first, "help")) return .help;
    if (std.mem.eql(u8, first, "--version") or std.mem.eql(u8, first, "-V") or std.mem.eql(u8, first, "version")) return .version;
    if (std.mem.eql(u8, first, "build")) return .build;
    if (std.mem.eql(u8, first, "run")) return .run;
    if (std.mem.eql(u8, first, "check")) return .check;
    if (std.mem.eql(u8, first, "test")) return .test_command;
    if (std.mem.eql(u8, first, "benchmark")) return .benchmark;
    if (std.mem.eql(u8, first, "compat")) {
        if (args.len < 2 or !std.mem.eql(u8, args[1], "report")) return error.MissingCompatAction;
        return .compat;
    }
    return error.UnknownCommand;
}

pub fn usage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\lnako - なでしこ3ネイティブコンパイラ
        \\
        \\使い方:
        \\  lnako build <file.nako3> -o <output> [options]
        \\  lnako run <file.nako3> [--compat-js] -- [arguments]
        \\  lnako check <file.nako3>
        \\  lnako test <file-or-directory>
        \\  lnako compat report
        \\  lnako benchmark
        \\
        \\共通オプション:
        \\  -h, --help       このヘルプを表示
        \\  -V, --version    バージョンを表示
        \\
    );
}

test "コマンドを解析できる" {
    try std.testing.expectEqual(Command.build, try parseCommand(&.{"build"}));
    try std.testing.expectEqual(Command.run, try parseCommand(&.{"run"}));
    try std.testing.expectEqual(Command.compat, try parseCommand(&.{ "compat", "report" }));
    try std.testing.expectEqual(Command.help, try parseCommand(&.{}));
}

test "未知のコマンドを拒否する" {
    try std.testing.expectError(error.UnknownCommand, parseCommand(&.{"unknown"}));
    try std.testing.expectError(error.MissingCompatAction, parseCommand(&.{"compat"}));
}
