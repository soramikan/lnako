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

pub const runtime = struct {
    pub const string = @import("runtime/string.zig");
    pub const bigint = @import("runtime/bigint.zig");
    pub const value = @import("runtime/value.zig");
    pub const operators = @import("runtime/operators.zig");
    pub const interpreter = @import("runtime/interpreter.zig");
};

pub const compat = struct {
    pub const quickjs = @import("compat/quickjs.zig");
    pub const embedded = @import("compat/embedded.zig");
};

pub const plugins = struct {
    pub const system = @import("plugins/system.zig");
    pub const math = @import("plugins/math.zig");
    pub const csv = @import("plugins/csv.zig");
    pub const toml = @import("plugins/toml.zig");
    pub const node = @import("plugins/node.zig");
    pub const encoding = @import("plugins/encoding.zig");
    pub const crypto = @import("plugins/crypto.zig");
    pub const http_server = @import("plugins/http_server.zig");
    pub const markup = @import("plugins/markup.zig");
    pub const caniuse = @import("plugins/caniuse.zig");
    pub const kansuji = @import("plugins/kansuji.zig");
};

pub const backend = struct {
    pub const llvm = struct {
        pub const api = @import("backend/llvm/api.zig");
        pub const module = @import("backend/llvm/module.zig");
        pub const compiler = @import("backend/llvm/compiler.zig");
    };
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

test {
    std.testing.refAllDecls(frontend.source);
    std.testing.refAllDecls(frontend.josi);
    std.testing.refAllDecls(frontend.token);
    std.testing.refAllDecls(frontend.lexer);
    std.testing.refAllDecls(frontend.syntax_transform);
    std.testing.refAllDecls(frontend.ast);
    std.testing.refAllDecls(frontend.diagnostic);
    std.testing.refAllDecls(frontend.parser);
    std.testing.refAllDecls(semantic.analyzer);
    std.testing.refAllDecls(semantic.module_graph);
    std.testing.refAllDecls(ir.hir);
    std.testing.refAllDecls(ir.nako_ir);
    std.testing.refAllDecls(ir.lower_ssa);
    std.testing.refAllDecls(ir.verifier);
    std.testing.refAllDecls(ir.printer);
    std.testing.refAllDecls(runtime.string);
    std.testing.refAllDecls(runtime.bigint);
    std.testing.refAllDecls(runtime.value);
    std.testing.refAllDecls(runtime.operators);
    std.testing.refAllDecls(runtime.interpreter);
    std.testing.refAllDecls(compat.quickjs);
    std.testing.refAllDecls(compat.embedded);
    std.testing.refAllDecls(plugins.system);
    std.testing.refAllDecls(plugins.math);
    std.testing.refAllDecls(plugins.csv);
    std.testing.refAllDecls(plugins.toml);
    std.testing.refAllDecls(plugins.node);
    std.testing.refAllDecls(plugins.encoding);
    std.testing.refAllDecls(plugins.crypto);
    std.testing.refAllDecls(plugins.http_server);
    std.testing.refAllDecls(plugins.markup);
    std.testing.refAllDecls(plugins.caniuse);
    std.testing.refAllDecls(plugins.kansuji);
    std.testing.refAllDecls(backend.llvm.api);
    std.testing.refAllDecls(backend.llvm.module);
    std.testing.refAllDecls(backend.llvm.compiler);
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
