const std = @import("std");
const lnako = @import("lnako");
const host = @import("../host.zig");
const benchmark = @import("../benchmark.zig");
const compiler_pipeline = @import("../compiler_pipeline.zig");
const arguments = @import("arguments.zig");
const test_command = @import("commands/test.zig");
const package_command = @import("commands/package.zig");
const sync_command = @import("commands/sync.zig");
const project_command = @import("commands/project.zig");

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
        var ir_program = (compiler_pipeline.compileInputWithProvider(allocator, package.entry_path, .{ .compat_js = true, .forced_mode = package.forced_mode }, stderr, package.sourceProvider()) catch |err| {
            if (err == error.ConflictingDnclModes) {
                try stderr.writeAll("拡張子と埋め込みDNCLモードが異なるDNCL方言を要求しています\n");
                try stderr.flush();
                std.process.exit(1);
            }
            return err;
        }) orelse {
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
            var prep = project_command.PrepFlags{};
            defer prep.deinit(allocator);
            const build_args = project_command.extractPrepFlags(allocator, args[1..], &prep, "build", stderr) catch args[1..];
            const options = arguments.parseBuildOptions(build_args) catch |err| {
                if (err == error.ConflictingDnclModes)
                    try stderr.writeAll("build: --dnclと--dncl2は同時に指定できません\n")
                else
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
            const extension_mode = lnako.semantic.module_graph.extensionForcedMode(options.input);
            if ((extension_mode.dncl and options.forced_mode.dncl2) or (extension_mode.dncl2 and options.forced_mode.dncl)) {
                try stderr.writeAll("build: 拡張子と--dncl/--dncl2が異なるDNCL方言を要求しています\n");
                try stderr.flush();
                std.process.exit(2);
            }
            // プロジェクト内の入力なら依存環境を自動準備する。
            // --compat-js は ESM 実装の許容へ効くため解決へ伝える。
            prep.compat_js = options.compat_js;
            try project_command.prepareForExecution(allocator, io, options.input, &prep, init.environ_map, "build", stderr);
            var ir_program = (try compiler_pipeline.compileInputTraced(allocator, io, options.input, .{ .compat_js = options.compat_js, .forced_mode = options.forced_mode }, stderr, init.environ_map.get("LNAKO_LLVM_TRACE") != null)) orelse {
                try stderr.flush();
                std.process.exit(1);
            };
            defer ir_program.deinit();
            if (options.compat_js) {
                compiler_pipeline.writeCompatExecutable(allocator, io, executable_path, options.input, options.output, options.forced_mode) catch |err| {
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
                .llvm_root = options.llvm_dir orelse init.environ_map.get("LNAKO_LLVM_DIR"),
                .llvm_library = init.environ_map.get("LNAKO_LLVM_LIBRARY"),
                .environment = init.environ_map,
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
            // 位置引数（入力ファイル）が無ければプロジェクト環境の静的検査。
            // prep 系フラグ（--locked/--profile 等）を除いた残りを検査する。
            var check_prep = project_command.PrepFlags{};
            defer check_prep.deinit(allocator);
            const check_args = project_command.extractPrepFlags(allocator, args[1..], &check_prep, "check", stderr) catch args[1..];
            var check_file: ?[]const u8 = null;
            var file_index: usize = 0;
            for (check_args, 0..) |argument, i| {
                if (!std.mem.startsWith(u8, argument, "-")) {
                    check_file = argument;
                    file_index = i;
                    break;
                }
            }
            if (check_file == null) {
                project_command.checkProject(allocator, io, args[1..], ".", init.environ_map, stdout, stderr) catch |err| {
                    try stderr.print("check: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
                return;
            }
            // ファイル検査ではプロジェクト準備フラグ（--locked/--profile 等）
            // は適用先が無いため用法エラーとする（黙って捨てない）。
            if (check_prep.locked or check_prep.offline or check_prep.no_sync or
                check_prep.profile != null or check_prep.features.items.len > 0 or
                check_prep.no_default_features or check_prep.registry != null or
                check_prep.cache_dir != null or check_prep.allow_plaintext_http or
                check_prep.json)
            {
                try stderr.writeAll("check: ファイル指定時はプロジェクト準備フラグ（--locked/--profile 等）は使えません\n");
                try stderr.flush();
                std.process.exit(2);
            }
            // ファイル以外の引数を従来どおり dncl 系オプションだけに限定する。
            var option_args: std.ArrayList([]const u8) = .empty;
            defer option_args.deinit(allocator);
            for (check_args, 0..) |argument, i| {
                if (i != file_index) try option_args.append(allocator, argument);
            }
            if (arguments.findUnknownOption(option_args.items, &.{ "--dncl", "--dncl2" })) |unknown| {
                try stderr.print("check: 不明なオプションです: {s}\n", .{unknown});
                try stderr.flush();
                std.process.exit(2);
            }
            const check_mode = arguments.dnclModeFromArguments(option_args.items) catch {
                try stderr.writeAll("check: --dnclと--dncl2は同時に指定できません\n");
                try stderr.flush();
                std.process.exit(2);
            };
            var ir_program = (compiler_pipeline.compileInput(allocator, io, check_file.?, .{ .forced_mode = check_mode }, stderr) catch |err| {
                if (err == error.ConflictingDnclModes) {
                    try stderr.writeAll("check: 拡張子と--dncl/--dncl2が異なるDNCL方言を要求しています\n");
                    try stderr.flush();
                    std.process.exit(2);
                }
                return err;
            }) orelse {
                try stderr.flush();
                std.process.exit(1);
            };
            defer ir_program.deinit();
            try stdout.print("{s}: 構文・意味・中間表現に問題はありません\n", .{check_file.?});
        },
        .run => {
            if (args.len < 2) {
                try stderr.writeAll("run: 入力ファイルを指定してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            const run_options = arguments.splitRunArguments(args[1..]);
            var run_prep = project_command.PrepFlags{};
            defer run_prep.deinit(allocator);
            const run_lnako_args = project_command.extractPrepFlags(allocator, run_options.lnako, &run_prep, "run", stderr) catch run_options.lnako;
            // 位置引数（入力ファイル）は prep 系フラグと前後してもよい。
            var run_file: ?[]const u8 = null;
            var run_file_index: usize = 0;
            for (run_lnako_args, 0..) |argument, i| {
                if (!std.mem.startsWith(u8, argument, "-")) {
                    run_file = argument;
                    run_file_index = i;
                    break;
                }
            }
            var lnako_flags: std.ArrayList([]const u8) = .empty;
            defer lnako_flags.deinit(allocator);
            for (run_lnako_args, 0..) |argument, i| {
                if (i != run_file_index or run_file == null) try lnako_flags.append(allocator, argument);
            }
            if (arguments.findUnknownFlag(lnako_flags.items, &.{ "--compat-js", "--dncl", "--dncl2" })) |unknown| {
                try stderr.print("run: 不明なオプションです: {s}\n", .{unknown});
                try stderr.flush();
                std.process.exit(2);
            }
            const input = run_file orelse {
                try stderr.writeAll("run: 入力ファイルを指定してください\n");
                try stderr.flush();
                std.process.exit(2);
            };
            const compat_js = arguments.hasArgument(lnako_flags.items, "--compat-js");
            if (compat_js and !lnako.compat.quickjs.available()) {
                try stderr.writeAll("run: このlnakoはQuickJSなしでビルドされています。zig build -Dcompat-js=trueを使用してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            const run_mode = arguments.dnclModeFromArguments(lnako_flags.items) catch {
                try stderr.writeAll("run: --dnclと--dncl2は同時に指定できません\n");
                try stderr.flush();
                std.process.exit(2);
            };
            // プロジェクト内の入力なら依存環境を自動準備する。
            // --compat-js は ESM 実装の許容へ効くため解決へ伝える。
            run_prep.compat_js = compat_js;
            try project_command.prepareForExecution(allocator, io, input, &run_prep, init.environ_map, "run", stderr);
            var ir_program = (compiler_pipeline.compileInput(allocator, io, input, .{ .compat_js = compat_js, .forced_mode = run_mode }, stderr) catch |err| {
                if (err == error.ConflictingDnclModes) {
                    try stderr.writeAll("run: 拡張子と--dncl/--dncl2が異なるDNCL方言を要求しています\n");
                    try stderr.flush();
                    std.process.exit(2);
                }
                return err;
            }) orelse {
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
                .source_path = input,
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
            var test_prep = project_command.PrepFlags{};
            defer test_prep.deinit(allocator);
            const test_args = project_command.extractPrepFlags(allocator, args[1..], &test_prep, "test", stderr) catch args[1..];
            // 位置引数（入力ファイル/ディレクトリ）は prep 系フラグと前後してもよい。
            var test_input: ?[]const u8 = null;
            var test_input_index: usize = 0;
            for (test_args, 0..) |argument, i| {
                if (!std.mem.startsWith(u8, argument, "-")) {
                    test_input = argument;
                    test_input_index = i;
                    break;
                }
            }
            var test_option_args: std.ArrayList([]const u8) = .empty;
            defer test_option_args.deinit(allocator);
            for (test_args, 0..) |argument, i| {
                if (i != test_input_index or test_input == null) try test_option_args.append(allocator, argument);
            }
            if (arguments.findUnknownOption(test_option_args.items, &.{ "--dncl", "--dncl2" })) |unknown| {
                try stderr.print("test: 不明なオプションです: {s}\n", .{unknown});
                try stderr.flush();
                std.process.exit(2);
            }
            const input = test_input orelse {
                try stderr.writeAll("test: 入力ファイルまたはディレクトリを指定してください\n");
                try stderr.flush();
                std.process.exit(2);
            };
            const test_mode = arguments.dnclModeFromArguments(test_option_args.items) catch {
                try stderr.writeAll("test: --dnclと--dncl2は同時に指定できません\n");
                try stderr.flush();
                std.process.exit(2);
            };
            // プロジェクト内の入力なら依存環境を自動準備する。
            try project_command.prepareForExecution(allocator, io, input, &test_prep, init.environ_map, "test", stderr);
            const succeeded = test_command.runTestTarget(allocator, io, input, test_mode, stdout, stderr) catch |err| {
                if (err == error.ConflictingDnclModes) {
                    try stderr.writeAll("test: 拡張子と--dncl/--dncl2が異なるDNCL方言を要求しています\n");
                    try stderr.flush();
                    std.process.exit(2);
                }
                return err;
            };
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
        .toolchain => {
            runToolchainCommand(allocator, io, args[1..], executable_path, init.environ_map, stdout, stderr) catch |err| {
                try stderr.print("toolchain: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .package => {
            package_command.run(allocator, io, args[1..], stdout, stderr) catch |err| {
                try stderr.print("package: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .sync => {
            sync_command.run(allocator, io, args[1..], init.environ_map, stdout, stderr) catch |err| {
                try stderr.print("sync: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(1);
            };
        },
        .init, .add, .remove, .lock, .update, .tree, .why, .cache => {
            const verb = switch (command) {
                .init => "init",
                .add => "add",
                .remove => "remove",
                .lock => "lock",
                .update => "update",
                .tree => "tree",
                .why => "why",
                else => "cache",
            };
            project_command.run(allocator, io, verb, args[1..], init.environ_map, stdout, stderr) catch |err| {
                try stderr.print("{s}: {s}\n", .{ verb, @errorName(err) });
                try stderr.flush();
                std.process.exit(1);
            };
        },
    }
}

fn runToolchainCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,
    executable_path: []const u8,
    environ_map: *std.process.Environ.Map,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    const manager = lnako.toolchain.manager;
    if (args.len == 0) {
        try manager.writeStatus(allocator, io, environ_map, executable_path, stdout);
        return;
    }
    const verb = args[0];
    if (std.mem.eql(u8, verb, "status")) {
        try manager.writeStatus(allocator, io, environ_map, executable_path, stdout);
        return;
    }
    if (std.mem.eql(u8, verb, "dir")) {
        const root = try manager.toolchainsRoot(allocator, environ_map);
        defer allocator.free(root);
        try stdout.print("{s}\n", .{root});
        return;
    }
    if (std.mem.eql(u8, verb, "install")) {
        var options: manager.InstallOptions = .{};
        var index: usize = 1;
        while (index < args.len) : (index += 1) {
            const argument = args[index];
            if (std.mem.eql(u8, argument, "--force")) {
                options.force = true;
            } else if (std.mem.eql(u8, argument, "--from-dir") and index + 1 < args.len) {
                index += 1;
                options.from_dir = args[index];
            } else if (std.mem.eql(u8, argument, "--archive") and index + 1 < args.len) {
                index += 1;
                options.archive_path = args[index];
            } else if (std.mem.eql(u8, argument, "--url") and index + 1 < args.len) {
                index += 1;
                options.url_override = args[index];
            } else if (std.mem.eql(u8, argument, "--sha256") and index + 1 < args.len) {
                index += 1;
                options.sha256_override = args[index];
            } else {
                try stderr.print("toolchain install: 不明な引数です: {s}\n", .{argument});
                std.process.exit(2);
            }
        }
        const result = try manager.installLlvm(allocator, io, environ_map, options, stdout, stderr);
        allocator.free(result.root);
        return;
    }
    if (std.mem.eql(u8, verb, "update")) {
        // pin済みバージョンへ強制再導入（install --forceと同等）。
        const result = try manager.installLlvm(allocator, io, environ_map, .{ .force = true }, stdout, stderr);
        allocator.free(result.root);
        return;
    }
    if (std.mem.eql(u8, verb, "remove")) {
        try manager.removeLlvm(allocator, io, environ_map, stdout);
        return;
    }
    try stderr.print("toolchain: 不明な操作です: {s}（status|dir|install|update|remove）\n", .{verb});
    std.process.exit(2);
}
