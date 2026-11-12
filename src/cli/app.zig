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
        var ir_program = (compiler_pipeline.compileInputWithProvider(allocator, package.entry_path, .{
            .compat_js = true,
            .forced_mode = package.forced_mode,
            .package_resolver = package.packageResolver(),
            .npm_module_resolver = package.npmModuleResolver(),
        }, stderr, package.sourceProvider()) catch |err| {
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
                else if (err == error.MissingBackend)
                    try stderr.writeAll("build: --backendの値がありません\n")
                else if (err == error.InvalidBackend)
                    try stderr.writeAll("build: --backendはaotまたはembeddedを指定してください\n")
                else if (err == error.MissingSbomPath)
                    try stderr.writeAll("build: --sbomの値がありません\n")
                else
                    try stderr.print("build: コマンドラインエラー: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(2);
            };
            // `--compat-js` の既定は従来の同梱実行ファイル方式（embedded）。
            // LLVM AOT＋QuickJS runtime は `--backend aot` の明示opt-in。
            const compat_backend: arguments.BuildBackend = options.backend orelse .embedded;
            if (options.compat_js and !lnako.compat.quickjs.available()) {
                try stderr.writeAll("build: このlnakoはQuickJSなしでビルドされています。zig build -Dcompat-js=trueを使用してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            if (options.backend != null and !options.compat_js) {
                try stderr.writeAll("build: --backendは--compat-jsとだけ併用できます\n");
                try stderr.flush();
                std.process.exit(2);
            }
            if (options.compat_js and compat_backend == .embedded and options.emit != .executable) {
                try stderr.writeAll("build: --compat-js --backend embeddedは--emit exeだけをサポートします\n");
                try stderr.flush();
                std.process.exit(2);
            }
            // SBOM は「生成物へ同梱した npm/ESM package」の一覧なので、
            // その同梱を行う compat AOT だけで意味を持つ。`--bundle-deps` は
            // 通常 AOT でも `.nako3` 依存を同梱するため、`--sbom` 併用を許す。
            const wants_sbom = options.sbom != null;
            if (wants_sbom and !(options.compat_js and compat_backend == .aot) and !options.bundle_deps) {
                try stderr.writeAll("build: --sbomは--compat-js --backend aotまたは--bundle-depsと併用してください\n");
                try stderr.flush();
                std.process.exit(2);
            }
            if (options.sbom) |sbom_path| {
                // 生成物や入力 source を SBOM で上書きしない（取り違えを拒否）。
                // 相対/絶対の表記差や symlink 経由の同一 file も実体 path で
                // 判定する。
                if (try arguments.sameDestination(allocator, io, options.output, sbom_path)) {
                    try stderr.writeAll("build: --sbomには出力ファイルと異なるパスを指定してください\n");
                    try stderr.flush();
                    std.process.exit(2);
                }
                if (try arguments.sameDestination(allocator, io, options.input, sbom_path)) {
                    try stderr.writeAll("build: --sbomには入力ファイルと異なるパスを指定してください\n");
                    try stderr.flush();
                    std.process.exit(2);
                }
                // payload の内側を SBOM の出力先にすると、payload の自己記述
                // （bundle.json）や同梱物を SBOM が上書き・混入させる。
                if (options.bundle_deps) {
                    const payload_root = try compiler_pipeline.bundleDeps.payloadPath(allocator, options.output);
                    defer allocator.free(payload_root);
                    if (pathIsInside(allocator, payload_root, sbom_path)) {
                        try stderr.writeAll("build: --sbomは--bundle-depsのpayload内に出力できません\n");
                        try stderr.flush();
                        std.process.exit(2);
                    }
                }
            }
            // `--bundle-deps` は embedded backend（単一 file 同梱実行ファイル）
            // では payload directory を持てないため対象外。
            if (options.bundle_deps and options.compat_js and compat_backend == .embedded) {
                try stderr.writeAll("build: --bundle-depsは--compat-js --backend embeddedでは使えません（通常AOTまたは--compat-js --backend aotで使用してください）\n");
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
            // --compat-js は ESM 実装の許容へ、-O は optimize-gated
            // artifact の選択へ効くため解決へ伝える。
            prep.compat_js = options.compat_js;
            prep.optimize = switch (options.optimization) {
                .o0 => "O0",
                .o1 => "O1",
                .o2 => "O2",
                .o3 => "O3",
            };
            try project_command.prepareForExecution(allocator, io, options.input, &prep, init.environ_map, "build", stderr);
            var ir_program = (try compiler_pipeline.compileInputTraced(allocator, io, options.input, .{
                .compat_js = options.compat_js,
                .forced_mode = options.forced_mode,
                .package_cache_root = prep.cache_dir,
                .writable_mode = prep.writableMode(init.environ_map),
            }, stderr, init.environ_map.get("LNAKO_LLVM_TRACE") != null)) orelse {
                try stderr.flush();
                std.process.exit(1);
            };
            defer ir_program.deinit();
            // 生成物へ source を同梱した package の metadata を IR に記録する
            // （ESM manifest の packages と --sbom の単一の源）。読み取りは
            // build 時 FS に対して行い、生成物の実行時には不要。
            // `--bundle-deps` は `.nako3` 依存（source-only / native plugin）も
            // 同梱対象にする（collectBundledPackages 内の拡張モード）。
            compiler_pipeline.bundled.bundle_deps_enabled = options.bundle_deps;
            if (options.bundle_deps or (options.compat_js and compat_backend == .aot)) {
                // `--bundle-deps` は project 自身を同梱対象から除外する。
                // entry とローカル module も module_paths に載るため、境界を
                // 渡さないと project 全体が payload へ複製される。
                var project_boundary: ?[]u8 = null;
                defer if (project_boundary) |root| allocator.free(root);
                if (options.bundle_deps) {
                    var rejected = false;
                    var writable_warning = false;
                    project_boundary = lnako.package.import_resolver.findProjectRootDetailed(
                        allocator,
                        io,
                        options.input,
                        &rejected,
                        prep.writableMode(init.environ_map),
                        &writable_warning,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        else => null,
                    };
                    // 境界が特定できないと project 自身が同梱対象になり、
                    // `.nako/`・秘密 file を含む project 全体が payload へ
                    // 複製され得る。同梱は「依存だけを入れる」契約なので、
                    // 境界不明は fail-closed にする。
                    if (project_boundary == null) {
                        try stderr.writeAll("build: --bundle-depsはproject rootを特定できないため中止します（nako.tomlを持つproject内で実行してください）\n");
                        try stderr.flush();
                        std.process.exit(2);
                    }
                }
                compiler_pipeline.collectBundledPackagesForProject(allocator, io, &ir_program, project_boundary) catch |err| {
                    try stderr.print("build: 同梱packageのmetadataを読めませんでした: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
            }
            // `--bundle-deps`: compile 前に payload を計画し、native plugin
            // path を実行ファイル相対 marker へ書き換える（emitter が marker
            // を生成物へ埋め込む）。payload の書き出しは codegen 成功後。
            // plan 結果は compile 経路が共有する CLI arena を跨いで生存する
            // 必要があるため page_allocator で確保する（process 終了までの
            // 短命データで、compile 内の arena rollback/reuse と重ならない）。
            var bundle_packages: ?[]compiler_pipeline.bundleDeps.BundlePackage = null;
            var bundle_payload_root: ?[]u8 = null;
            defer if (bundle_payload_root) |root| std.heap.page_allocator.free(root);
            if (options.bundle_deps) {
                const bundle_allocator = std.heap.page_allocator;
                bundle_payload_root = compiler_pipeline.bundleDeps.payloadPath(bundle_allocator, options.output) catch |err| {
                    try stderr.print("build: 依存packageの同梱に失敗しました: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
                compiler_pipeline.bundleDeps.deletePayload(io, bundle_payload_root.?);
                bundle_packages = compiler_pipeline.bundleDeps.plan(bundle_allocator, io, &ir_program) catch |err| {
                    try stderr.print("build: 依存packageの同梱に失敗しました: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
                rewritePluginMarkers(&ir_program, bundle_packages.?) catch |err| {
                    try stderr.print("build: 依存packageの同梱に失敗しました: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
            }
            if (options.compat_js and compat_backend == .embedded) {
                compiler_pipeline.writeCompatExecutable(allocator, io, executable_path, options.input, options.output, options.forced_mode, prep.cache_dir) catch |err| {
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
                .runtime_library = if (options.compat_js and compat_backend == .aot)
                    init.environ_map.get("LNAKO_AOT_RUNTIME_LIBRARY_COMPAT")
                else
                    init.environ_map.get("LNAKO_AOT_RUNTIME_LIBRARY"),
                .compat_js = options.compat_js and compat_backend == .aot,
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
            // `--bundle-deps`: 依存 package の file を `<out>.deps/` へ複製する
            // （plan は compile 前に済ませてある。SBOM（併用時）は同梱物と
            // 同じ `bundled_packages` を読む）。
            if (options.bundle_deps) {
                compiler_pipeline.bundleDeps.write(allocator, io, bundle_payload_root.?, bundle_packages.?) catch |err| {
                    compiler_pipeline.bundleDeps.deletePayload(io, bundle_payload_root.?);
                    if (bundle_packages) |packages| freeBundlePackages(std.heap.page_allocator, packages);
                    bundle_packages = null;
                    try stderr.print("build: 依存packageの同梱に失敗しました: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
                if (bundle_packages) |packages| freeBundlePackages(std.heap.page_allocator, packages);
                bundle_packages = null;
                try stdout.print("{s} を生成しました（同梱payload）\n", .{bundle_payload_root.?});
            }
            if (options.sbom) |sbom_path| {
                compiler_pipeline.writeCompatSbom(allocator, io, sbom_path, &ir_program, options.output) catch |err| {
                    try stderr.print("build: SBOMの生成に失敗しました: {s}\n", .{@errorName(err)});
                    try stderr.flush();
                    std.process.exit(1);
                };
                try stdout.print("{s} を生成しました（同梱package {d} 件）\n", .{ sbom_path, ir_program.bundled_packages.len });
            }
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
            // ただし `--package-cache-dir` は compile 経路へ伝播するため許可
            // する（`run`/`build`/`test` と同じ #54 の配線）。
            if (check_prep.locked or check_prep.offline or check_prep.no_sync or
                check_prep.profile != null or check_prep.features.items.len > 0 or
                check_prep.no_default_features or check_prep.registry != null or
                check_prep.allow_plaintext_http or check_prep.json)
            {
                try stderr.writeAll("check: ファイル指定時はプロジェクト準備フラグ（--locked/--profile 等）は使えません\n");
                try stderr.flush();
                std.process.exit(2);
            }
            // ファイル以外の引数を従来どおり dncl 系オプションだけに限定する。
            // trust フラグは extractPrepFlags が消費済みなので option_args に残らない。
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
            var ir_program = (compiler_pipeline.compileInput(allocator, io, check_file.?, .{
                .forced_mode = check_mode,
                .writable_mode = check_prep.writableMode(init.environ_map),
                // ファイル検査では未検査の package 命令呼出しを可視化する。
                .report_uninspected_packages = true,
                // `--package-cache-dir` は run/build/test と同じ経路へ伝播する。
                .package_cache_root = check_prep.cache_dir,
            }, stderr) catch |err| {
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
            var ir_program = (compiler_pipeline.compileInput(allocator, io, input, .{
                .compat_js = compat_js,
                .forced_mode = run_mode,
                .package_cache_root = run_prep.cache_dir,
                .writable_mode = run_prep.writableMode(init.environ_map),
            }, stderr) catch |err| {
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
            const succeeded = test_command.runTestTarget(allocator, io, input, test_mode, test_prep.writableMode(init.environ_map), test_prep.cache_dir, stdout, stderr) catch |err| {
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
            package_command.run(allocator, io, args[1..], init.environ_map, stdout, stderr) catch |err| {
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

/// `candidate` が `directory` 配下（または同一）か。両方を絶対 path へ
/// 正規化してから比較する。
fn pathIsInside(allocator: std.mem.Allocator, directory: []const u8, candidate: []const u8) bool {
    const base = std.fs.path.resolve(allocator, &.{directory}) catch return false;
    defer allocator.free(base);
    const target = std.fs.path.resolve(allocator, &.{candidate}) catch return false;
    defer allocator.free(target);
    if (!std.mem.startsWith(u8, target, base)) return false;
    if (target.len == base.len) return true;
    return target[base.len] == std.fs.path.sep;
}

/// `plan` の結果を解放する。file の relative/source_path と files slice は
/// `plan` 呼び出し側の allocator（CLI arena）で確保されている。
fn freeBundlePackages(allocator: std.mem.Allocator, packages: []const compiler_pipeline.bundleDeps.BundlePackage) void {
    for (packages) |item| {
        for (item.files) |file| {
            allocator.free(file.relative);
            allocator.free(file.source_path);
        }
        allocator.free(item.files);
    }
    allocator.free(packages);
}

/// native plugin path を payload marker へ書き換える。package 配下に無い
/// plugin は従来どおり build 機の絶対 path のまま残す（`--bundle-deps` の
/// 対象外。同梱しない path を marker 化すると実行時に解決できない）。
/// 書換後の slice は program arena に置く（IR と同じ lifetime）。
fn rewritePluginMarkers(
    ir_program: *lnako.ir.nako_ir.Program,
    packages: []const compiler_pipeline.bundleDeps.BundlePackage,
) !void {
    const arena = ir_program.arena.allocator();
    var rewritten: std.ArrayListUnmanaged([]const u8) = .empty;
    for (ir_program.native_plugin_paths) |plugin_path| {
        if (try compiler_pipeline.bundleDeps.markerFor(arena, packages, plugin_path)) |marker| {
            try rewritten.append(arena, marker);
        } else {
            try rewritten.append(arena, plugin_path);
        }
    }
    ir_program.native_plugin_paths = try rewritten.toOwnedSlice(arena);
    // `native_plugin_packages` も同じ marker へ揃える。install と AOT emitter
    // は path 一致で namespace を対応付けるため、ここを絶対 path のまま
    // 残すと namespaces が空になり、修飾名の命令が登録されない（移動後の
    // 生成物で `{ns}__{name}` 呼出しが全滅する）。
    var rewritten_packages: std.ArrayListUnmanaged(lnako.ir.nako_ir.NativePluginPackage) = .empty;
    for (ir_program.native_plugin_packages) |package| {
        const path = if (try compiler_pipeline.bundleDeps.markerFor(arena, packages, package.path)) |marker| marker else package.path;
        try rewritten_packages.append(arena, .{ .path = path, .namespace = package.namespace });
    }
    ir_program.native_plugin_packages = try rewritten_packages.toOwnedSlice(arena);
}
