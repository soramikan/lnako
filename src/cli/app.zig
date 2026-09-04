const std = @import("std");
const lnako = @import("lnako");
const host = @import("../host.zig");
const benchmark = @import("../benchmark.zig");
const compiler_pipeline = @import("../compiler_pipeline.zig");
const arguments = @import("arguments.zig");
const test_command = @import("commands/test.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    executable_path: []const u8,
    process_args: []const []const u8,
    init: std.process.Init,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    if (try lnako.compat.embedded.readExecutable(allocator, io, executable_path)) |package_value| {
        var package = package_value;
        defer package.deinit();
        if (!lnako.compat.quickjs.available()) {
            try stderr.writeAll("この埋め込みプログラムにはQuickJS対応ランタイムが必要です\n");
            try stderr.flush();
            std.process.exit(1);
        }
        var ir_program = (try compiler_pipeline.compileInputWithProvider(allocator, package.entry_path, true, stderr, package.sourceProvider())) orelse {
            try stderr.flush();
            std.process.exit(1);
        };
        defer ir_program.deinit();
        var runtime = lnako.runtime.value.Runtime.init(allocator);
        defer runtime.deinit();
        var cli_host = host.CliHost{
            .writer = stdout,
            .error_writer = stderr,
            .io = io,
            .program_arguments = process_args,
            .runtime_path = executable_path,
            .source_path = package.entry_path,
            .environment_names = init.environ_map.keys(),
            .environment_values = init.environ_map.values(),
            .home_directory = host.homeDirectory(init.environ_map),
            .temporary_directory = host.temporaryDirectory(init.environ_map),
            .fixed_now_milliseconds = host.parseOptionalI64(init.environ_map.get("LNAKO_TEST_NOW_MS")),
            .fixed_monotonic_milliseconds = host.parseOptionalF64(init.environ_map.get("LNAKO_TEST_MONOTONIC_MS")),
            .random_state = host.parseOptionalU64(init.environ_map.get("LNAKO_TEST_RANDOM_SEED")) orelse 0,
            .http_server_enabled = ir_program.http_server_plugin_imported,
            .async_task_map = std.AutoHashMap(u64, *host.AsyncOperationTask).init(std.heap.page_allocator),
        };
        defer cli_host.deinit();
        var interpreter = lnako.runtime.interpreter.Interpreter.init(allocator, &runtime, ir_program, cli_host.interpreterHost());
        defer interpreter.deinit();
        _ = interpreter.run() catch |err| {
            if (err == error.ProcessExitRequested) {
                interpreter.finishProcessExitTrace();
                try stdout.flush();
                try stderr.flush();
                std.process.exit(interpreter.requestedExitCode() orelse 0);
            }
            try stderr.print("実行時エラー: {s}\n", .{runtime.failureMessage() orelse lnako.runtime.error_message.forFailure(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        return;
    }

    const command = lnako.parseCommand(args) catch |err| {
        try stderr.print("コマンドラインエラー: {s}\n\n", .{@errorName(err)});
        try lnako.usage(stderr);
        try stderr.flush();
        std.process.exit(2);
    };

    switch (command) {
        .help => try lnako.usage(stdout),
        .version => try stdout.print("lnako {s}\n", .{lnako.version}),
        .build => {
            const options = arguments.parseBuildOptions(args[1..]) catch |err| {
                try stderr.print("build: コマンドラインエラー: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(2);
            };
            if (options.compat_js and !lnako.compat.quickjs.available()) {
                try stderr.writeAll("build: このlnakoはQuickJSなしでビルドされています。zig build -Dcompat-js=trueを使用してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            if (options.compat_js and options.emit != .executable) {
                try stderr.writeAll("build: --compat-jsは--emit exeだけをサポートします\n");
                try stderr.flush();
                std.process.exit(2);
            }
            var ir_program = (try compiler_pipeline.compileInput(allocator, io, options.input, options.compat_js, stderr)) orelse {
                try stderr.flush();
                std.process.exit(1);
            };
            defer ir_program.deinit();
            if (options.compat_js) {
                compiler_pipeline.writeCompatExecutable(allocator, io, executable_path, options.input, options.output) catch |err| {
                    try stderr.print("build: QuickJS互換実行ファイルの生成に失敗しました: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
                try stdout.print("{s} を生成しました\n", .{options.output});
                return;
            }
            lnako.backend.llvm.compiler.compile(allocator, io, ir_program, .{
                .source_path = options.input,
                .output_path = options.output,
                .optimization = options.optimization,
                .emit = options.emit,
                .llvm_root = init.environ_map.get("LNAKO_LLVM_DIR"),
                .llvm_library = init.environ_map.get("LNAKO_LLVM_LIBRARY"),
                .runtime_library = init.environ_map.get("LNAKO_AOT_RUNTIME_LIBRARY"),
                .compile_manifest_path = init.environ_map.get("LNAKO_COMPILE_MANIFEST"),
                .global_manifest_path = init.environ_map.get("LNAKO_GLOBAL_MANIFEST"),
                .literal_manifest_path = init.environ_map.get("LNAKO_LITERAL_MANIFEST"),
                .trace = init.environ_map.get("LNAKO_LLVM_TRACE") != null,
            }, stderr) catch |err| {
                try stderr.print("build: ネイティブコード生成に失敗しました: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
            try stdout.print("{s} を生成しました\n", .{options.output});
        },
        .check => {
            if (args.len < 2) {
                try stderr.writeAll("check: 入力ファイルを指定してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            var ir_program = (try compiler_pipeline.compileInput(allocator, io, args[1], false, stderr)) orelse {
                try stderr.flush();
                std.process.exit(1);
            };
            defer ir_program.deinit();
            try stdout.print("{s}: 構文・意味・中間表現に問題はありません\n", .{args[1]});
        },
        .run => {
            if (args.len < 2) {
                try stderr.writeAll("run: 入力ファイルを指定してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            const run_options = arguments.splitRunArguments(args[2..]);
            const compat_js = arguments.hasArgument(run_options.lnako, "--compat-js");
            if (compat_js and !lnako.compat.quickjs.available()) {
                try stderr.writeAll("run: このlnakoはQuickJSなしでビルドされています。zig build -Dcompat-js=trueを使用してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            var ir_program = (try compiler_pipeline.compileInput(allocator, io, args[1], compat_js, stderr)) orelse {
                try stderr.flush();
                std.process.exit(1);
            };
            defer ir_program.deinit();
            var runtime = lnako.runtime.value.Runtime.init(allocator);
            defer runtime.deinit();
            var cli_host = host.CliHost{
                .writer = stdout,
                .error_writer = stderr,
                .io = io,
                .program_arguments = process_args,
                .runtime_path = process_args[0],
                .source_path = args[1],
                .environment_names = init.environ_map.keys(),
                .environment_values = init.environ_map.values(),
                .home_directory = host.homeDirectory(init.environ_map),
                .temporary_directory = host.temporaryDirectory(init.environ_map),
                .fixed_now_milliseconds = host.parseOptionalI64(init.environ_map.get("LNAKO_TEST_NOW_MS")),
                .fixed_monotonic_milliseconds = host.parseOptionalF64(init.environ_map.get("LNAKO_TEST_MONOTONIC_MS")),
                .random_state = host.parseOptionalU64(init.environ_map.get("LNAKO_TEST_RANDOM_SEED")) orelse 0,
                .http_server_enabled = ir_program.http_server_plugin_imported,
                .async_task_map = std.AutoHashMap(u64, *host.AsyncOperationTask).init(std.heap.page_allocator),
            };
            defer cli_host.deinit();
            var interpreter = lnako.runtime.interpreter.Interpreter.init(allocator, &runtime, ir_program, cli_host.interpreterHost());
            defer interpreter.deinit();
            _ = interpreter.run() catch |err| {
                if (err == error.ProcessExitRequested) {
                    interpreter.finishProcessExitTrace();
                    try stdout.flush();
                    try stderr.flush();
                    std.process.exit(interpreter.requestedExitCode() orelse 0);
                }
                try stderr.print("実行時エラー: {s}\n", .{runtime.failureMessage() orelse lnako.runtime.error_message.forFailure(err)});
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .test_command => {
            if (args.len < 2) {
                try stderr.writeAll("test: 入力ファイルまたはディレクトリを指定してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            const succeeded = try test_command.runTestTarget(allocator, io, args[1], stdout, stderr);
            if (!succeeded) {
                try stdout.flush();
                try stderr.flush();
                std.process.exit(1);
            }
        },
        .compat => try lnako.compat.report.write(stdout),
        .benchmark => {
            const options = benchmark.parseOptions(args[1..]) catch |err| {
                try stderr.print("benchmark: コマンドラインエラー: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(2);
            };
            if (options.help) {
                try benchmark.writeUsage(stdout);
                return;
            }
            const temp_dir = host.temporaryDirectory(init.environ_map);
            benchmark.run(allocator, io, executable_path, init.environ_map, temp_dir, options, stdout, stderr) catch |err| {
                try stderr.print("benchmark: 性能計測に失敗しました: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
        },
    }
}
