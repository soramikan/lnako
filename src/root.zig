const std = @import("std");

pub const version = "0.2.1";

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
    pub const builtin_catalog = @import("semantic/builtin_catalog.zig");
    pub const builtin_josi = @import("semantic/builtin_josi.zig");
};

pub const ir = struct {
    pub const hir = @import("ir/hir.zig");
    pub const nako_ir = @import("ir/nako_ir.zig");
    pub const lower_ssa = @import("ir/lower_ssa.zig");
    pub const verifier = @import("ir/verifier.zig");
    pub const optimizer = @import("ir/optimizer.zig");
    pub const root_liveness = @import("ir/root_liveness.zig");
    pub const result_effect = @import("ir/result_effect.zig");
    pub const printer = @import("ir/printer.zig");
};

pub const runtime = struct {
    pub const aot_abi = @import("runtime/aot_abi.zig");
    pub const aot_builtin = @import("runtime/aot_builtin.zig");
    pub const system_constant = @import("runtime/system_constant.zig");
    pub const error_message = @import("runtime/error_message.zig");
    pub const low_level_context = @import("runtime/low_level/context.zig");
    pub const low_level_state = @import("runtime/low_level/state.zig");
    pub const low_level_foundation = @import("runtime/low_level_foundation.zig");
    pub const low_level_io = @import("runtime/low_level_io.zig");
    pub const low_level_hash = @import("runtime/low_level_hash.zig");
    pub const low_level_fs = @import("runtime/low_level_fs.zig");
    pub const low_level_process = @import("runtime/low_level_process.zig");
    pub const low_level_dir = @import("runtime/low_level_dir.zig");
    pub const low_level_posix = @import("runtime/low_level_posix.zig");
    pub const low_level_catalog = @import("runtime/low_level_catalog.zig");
    pub const structured_error = @import("runtime/structured_error.zig");
    pub const structured_error_value = @import("runtime/structured_error_value.zig");
    pub const string = @import("runtime/string.zig");
    pub const bigint = @import("runtime/bigint.zig");
    pub const number = @import("runtime/number.zig");
    pub const value = @import("runtime/value.zig");
    pub const operators = @import("runtime/operators.zig");
    pub const interpreter = @import("runtime/interpreter.zig");
};

pub const compat = struct {
    pub const quickjs = @import("compat/quickjs.zig");
    pub const embedded = @import("compat/embedded.zig");
    pub const report = @import("compat/report.zig");
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
    pub const native = @import("plugins/native.zig");
    pub const lowlevel = @import("plugins/lowlevel.zig");
};

pub const backend = struct {
    pub const llvm = struct {
        pub const api = @import("backend/llvm/api.zig");
        pub const module = @import("backend/llvm/module.zig");
        pub const compiler = @import("backend/llvm/compiler.zig");
    };
};

pub const toolchain = struct {
    pub const manager = @import("toolchain/manager.zig");
};

pub const archive = struct {
    pub const zip = @import("archive/zip.zig");
};

/// nadesiko3 パッケージシステムのデータ解析層（Issue #44）。
/// ランタイムの `plugins.toml` とは独立した manifest 向け TOML/SemVer/
/// marker/feature 解析を提供する。
pub const package = struct {
    pub const diagnostics = @import("package/diagnostics.zig");
    pub const toml = @import("package/toml.zig");
    pub const semver = @import("package/semver.zig");
    pub const marker = @import("package/marker.zig");
    pub const features = @import("package/features.zig");
    pub const manifest = @import("package/manifest.zig");
    pub const resolver = @import("package/resolver.zig");
    pub const lock = @import("package/lock.zig");
    pub const toml_write = @import("package/toml_write.zig");
    pub const glob = @import("package/glob.zig");
    pub const npkg_metadata = @import("package/npkg_metadata.zig");
    pub const npkg_files = @import("package/npkg_files.zig");
    pub const npkg_commands = @import("package/npkg_commands.zig");
    pub const npkg_commands_gen = @import("package/npkg_commands_gen.zig");
    pub const npkg_build = @import("package/npkg_build.zig");
    pub const npkg_verify = @import("package/npkg_verify.zig");
    pub const fetch = @import("package/fetch.zig");
    pub const provider = @import("package/provider.zig");
    pub const registry = @import("package/registry.zig");
    pub const cache = @import("package/cache.zig");
    pub const environment = @import("package/environment.zig");
    pub const materialize = @import("package/materialize.zig");
    pub const unpack = @import("package/unpack.zig");
    pub const sync = @import("package/sync.zig");
    pub const project = @import("package/project.zig");
};

pub const Command = enum {
    build,
    run,
    check,
    test_command,
    compat,
    benchmark,
    toolchain,
    package,
    sync,
    init,
    add,
    remove,
    lock,
    update,
    tree,
    why,
    cache,
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
    if (std.mem.eql(u8, first, "toolchain")) return .toolchain;
    if (std.mem.eql(u8, first, "package")) return .package;
    if (std.mem.eql(u8, first, "sync")) return .sync;
    if (std.mem.eql(u8, first, "init")) return .init;
    if (std.mem.eql(u8, first, "add")) return .add;
    if (std.mem.eql(u8, first, "remove") or std.mem.eql(u8, first, "rm")) return .remove;
    if (std.mem.eql(u8, first, "lock")) return .lock;
    if (std.mem.eql(u8, first, "update")) return .update;
    if (std.mem.eql(u8, first, "tree")) return .tree;
    if (std.mem.eql(u8, first, "why")) return .why;
    if (std.mem.eql(u8, first, "cache")) return .cache;
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
        \\  lnako build <file.nako3|.dncl|.dncl2> -o <output> [-O0..-O3] [--emit exe|obj|llvm-ir] [--llvm-dir <path>]
        \\  lnako run <file.nako3|.dncl|.dncl2> [--compat-js] [--dncl] [--dncl2] -- [arguments]
        \\  lnako check <file.nako3|.dncl|.dncl2> [--dncl] [--dncl2]
        \\  lnako test <file.nako3|.dncl|.dncl2|directory> [--dncl] [--dncl2]
        \\  lnako compat report
        \\  lnako benchmark
        \\  lnako toolchain <status|dir|install|update|remove>
        \\  lnako package build [<dir>] [-o <output.npkg>]
        \\  lnako package verify <file.npkg> [--runtime lnako|cnako] [--os <os>] [--cpu <cpu>] [--abi <abi>] [--os-version <v>] [--libc <libc>] [--optimize <level>] [--feature <name>] [--no-default-features] [--nako-version <v>] [--cnako-version <v>] [--lnako-version <v>] [--compat-js]
        \\  lnako package cache dir|clean [--package-cache-dir <path>]
        \\  lnako sync [<dir>] [--profile <name>] [--runtime lnako|cnako] [--locked] [--offline] [--json] [--package-cache-dir <path>] [--package-cache-clean] [--allow-plaintext-http]
        \\  lnako init [<dir>] [--lib] [--name <name>]
        \\  lnako add <name[@range]> [--dev] [--path <dir>|--git <url>|--http <url>|--npm] [--commit <id>] [--dep-path <path>] [--hash <sha256>] [--mutable] [--locked] [--offline]
        \\  lnako remove <name> [--dev] [--locked] [--offline]
        \\  lnako lock [--locked] [--offline] [--profile <name>] [--features <a,b>] [--json]
        \\  lnako update [<name>...] [--offline] [--registry <url>]
        \\  lnako tree [--profile <name>] [--locked] [--offline]
        \\  lnako why <name> [--profile <name>] [--locked] [--offline]
        \\  lnako check [--json]                    プロジェクトの依存・環境状態を検査（副作用なし）
        \\  lnako cache dir|clean [--package-cache-dir <path>]
        \\
        \\依存準備オプション（run/test/build/lock/tree/why/add/remove で有効）:
        \\  --locked         nako.lock を変更せず、不足・陳腐なら失敗
        \\  --offline        ネットワーク取得を禁止
        \\  --no-sync        run/test/build での .nako 自動準備を禁止（既存環境のみ使用）
        \\  --registry <url> pkg 依存解決用 registry（既定: LNAKO_REGISTRY）
        \\
        \\共通オプション:
        \\  -h, --help       このヘルプを表示
        \\  -V, --version    バージョンを表示
        \\  --dncl           入力をDNCLモード（!DNCLモード相当）で解釈する
        \\  --dncl2          入力をDNCL2モード（!DNCL2相当）で解釈する
        \\                   .dncl はDNCLモード（v1）、.dncl2 はDNCL2を自動で有効化する
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
    std.testing.refAllDecls(ir.optimizer);
    std.testing.refAllDecls(ir.root_liveness);
    std.testing.refAllDecls(ir.result_effect);
    std.testing.refAllDecls(ir.printer);
    std.testing.refAllDecls(runtime.aot_abi);
    std.testing.refAllDecls(runtime.aot_builtin);
    std.testing.refAllDecls(runtime.system_constant);
    std.testing.refAllDecls(runtime.error_message);
    std.testing.refAllDecls(runtime.low_level_context);
    std.testing.refAllDecls(runtime.low_level_state);
    std.testing.refAllDecls(runtime.low_level_foundation);
    std.testing.refAllDecls(runtime.low_level_io);
    std.testing.refAllDecls(runtime.low_level_hash);
    std.testing.refAllDecls(runtime.low_level_fs);
    std.testing.refAllDecls(runtime.low_level_process);
    std.testing.refAllDecls(runtime.low_level_dir);
    std.testing.refAllDecls(runtime.low_level_posix);
    std.testing.refAllDecls(runtime.low_level_catalog);
    std.testing.refAllDecls(runtime.structured_error);
    std.testing.refAllDecls(runtime.structured_error_value);
    std.testing.refAllDecls(runtime.string);
    std.testing.refAllDecls(runtime.bigint);
    std.testing.refAllDecls(runtime.number);
    std.testing.refAllDecls(runtime.value);
    std.testing.refAllDecls(runtime.operators);
    std.testing.refAllDecls(runtime.interpreter);
    std.testing.refAllDecls(compat.quickjs);
    std.testing.refAllDecls(compat.embedded);
    std.testing.refAllDecls(compat.report);
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
    std.testing.refAllDecls(plugins.native);
    std.testing.refAllDecls(plugins.lowlevel);
    std.testing.refAllDecls(backend.llvm.api);
    std.testing.refAllDecls(backend.llvm.module);
    std.testing.refAllDecls(backend.llvm.compiler);
    std.testing.refAllDecls(toolchain.manager);
    std.testing.refAllDecls(package.diagnostics);
    std.testing.refAllDecls(package.toml);
    std.testing.refAllDecls(package.semver);
    std.testing.refAllDecls(package.marker);
    std.testing.refAllDecls(package.features);
    std.testing.refAllDecls(package.manifest);
    std.testing.refAllDecls(package.resolver);
    std.testing.refAllDecls(package.lock);
    std.testing.refAllDecls(package.toml_write);
    std.testing.refAllDecls(package.glob);
    std.testing.refAllDecls(package.npkg_metadata);
    std.testing.refAllDecls(package.npkg_files);
    std.testing.refAllDecls(package.npkg_commands);
    std.testing.refAllDecls(package.npkg_commands_gen);
    std.testing.refAllDecls(package.npkg_build);
    std.testing.refAllDecls(package.npkg_verify);
    std.testing.refAllDecls(package.fetch);
    std.testing.refAllDecls(package.provider);
    std.testing.refAllDecls(package.registry);
    std.testing.refAllDecls(package.cache);
    std.testing.refAllDecls(package.environment);
    std.testing.refAllDecls(package.materialize);
    std.testing.refAllDecls(package.unpack);
    std.testing.refAllDecls(package.sync);
    std.testing.refAllDecls(package.project);
}

test "コマンドを解析できる" {
    try std.testing.expectEqual(Command.build, try parseCommand(&.{"build"}));
    try std.testing.expectEqual(Command.run, try parseCommand(&.{"run"}));
    try std.testing.expectEqual(Command.benchmark, try parseCommand(&.{"benchmark"}));
    try std.testing.expectEqual(Command.compat, try parseCommand(&.{ "compat", "report" }));
    try std.testing.expectEqual(Command.help, try parseCommand(&.{}));
}

test "未知のコマンドを拒否する" {
    try std.testing.expectError(error.UnknownCommand, parseCommand(&.{"unknown"}));
    try std.testing.expectError(error.MissingCompatAction, parseCommand(&.{"compat"}));
}
