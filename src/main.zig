const std = @import("std");
const lnako = @import("lnako");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const process_args = try init.minimal.args.toSlice(allocator);
    const args = if (process_args.len > 1) process_args[1..] else process_args[0..0];

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;
    defer stderr.flush() catch {};

    const command = lnako.parseCommand(args) catch |err| {
        try stdout.print("コマンドラインエラー: {s}\n\n", .{@errorName(err)});
        try lnako.usage(stdout);
        return;
    };

    switch (command) {
        .help => try lnako.usage(stdout),
        .version => try stdout.print("lnako {s}\n", .{lnako.version}),
        .build => {
            const options = parseBuildOptions(args[1..]) catch |err| {
                try stderr.print("build: コマンドラインエラー: {s}\n", .{@errorName(err)});
                try stderr.flush();
                std.process.exit(2);
            };
            if (options.compat_js) {
                try stderr.writeAll("build: --compat-js はQuickJS互換モード実装後に利用できます\n");
                try stderr.flush();
                std.process.exit(2);
            }
            var ir_program = (try compileInput(allocator, init.io, options.input, false, stderr)) orelse {
                try stderr.flush();
                std.process.exit(1);
            };
            defer ir_program.deinit();
            lnako.backend.llvm.compiler.compile(allocator, init.io, ir_program, .{
                .source_path = options.input,
                .output_path = options.output,
                .optimization = options.optimization,
                .emit = options.emit,
                .llvm_root = init.environ_map.get("LNAKO_LLVM_DIR"),
                .llvm_library = init.environ_map.get("LNAKO_LLVM_LIBRARY"),
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
            var ir_program = (try compileInput(allocator, init.io, args[1], false, stderr)) orelse {
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
            const compat_js = hasArgument(args[2..], "--compat-js");
            var ir_program = (try compileInput(allocator, init.io, args[1], compat_js, stderr)) orelse {
                try stderr.flush();
                std.process.exit(1);
            };
            defer ir_program.deinit();
            var runtime = lnako.runtime.value.Runtime.init(allocator);
            defer runtime.deinit();
            var cli_host = CliHost{
                .writer = stdout,
                .io = init.io,
                .fixed_now_milliseconds = parseOptionalI64(init.environ_map.get("LNAKO_TEST_NOW_MS")),
                .fixed_monotonic_milliseconds = parseOptionalF64(init.environ_map.get("LNAKO_TEST_MONOTONIC_MS")),
                .random_state = parseOptionalU64(init.environ_map.get("LNAKO_TEST_RANDOM_SEED")) orelse 0,
            };
            var interpreter = lnako.runtime.interpreter.Interpreter.init(allocator, &runtime, ir_program, cli_host.host());
            defer interpreter.deinit();
            _ = interpreter.run() catch |err| {
                try stderr.print("実行時エラー: {s}\n", .{@errorName(err)});
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
            const succeeded = try runTestTarget(allocator, init.io, args[1], stdout, stderr);
            if (!succeeded) {
                try stdout.flush();
                try stderr.flush();
                std.process.exit(1);
            }
        },
        else => try stdout.print("{s}: 実装準備中です\n", .{@tagName(command)}),
    }
}

const BuildOptions = struct {
    input: []const u8,
    output: []const u8,
    optimization: lnako.backend.llvm.compiler.Optimization = .o0,
    emit: lnako.backend.llvm.compiler.Emit = .executable,
    compat_js: bool = false,
};

fn parseBuildOptions(arguments: []const []const u8) !BuildOptions {
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

const CliHost = struct {
    writer: *std.Io.Writer,
    io: std.Io,
    random_state: u64 = 0,
    fixed_now_milliseconds: ?i64 = null,
    fixed_monotonic_milliseconds: ?f64 = null,

    fn host(self: *CliHost) lnako.runtime.interpreter.Host {
        return .{
            .context = self,
            .writeFn = write,
            .sleepMillisecondsFn = sleepMilliseconds,
            .nowMillisecondsFn = nowMilliseconds,
            .monotonicMillisecondsFn = monotonicMilliseconds,
            .randomFn = random,
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try self.writer.writeAll(bytes);
    }

    fn sleepMilliseconds(context: *anyopaque, milliseconds: u64) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const duration = std.Io.Duration.fromMilliseconds(std.math.cast(i64, milliseconds) orelse return error.TimerOverflow);
        try std.Io.sleep(self.io, duration, .awake);
    }

    fn nowMilliseconds(context: *anyopaque) !i64 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.fixed_now_milliseconds) |fixed| return fixed;
        const nanoseconds = std.Io.Timestamp.now(self.io, .real).nanoseconds;
        return @intCast(@divTrunc(nanoseconds, 1_000_000));
    }

    fn monotonicMilliseconds(context: *anyopaque) !f64 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.fixed_monotonic_milliseconds) |fixed| return fixed;
        const nanoseconds = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        return @as(f64, @floatFromInt(nanoseconds)) / 1_000_000;
    }

    fn random(context: *anyopaque) !f64 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (self.random_state == 0) {
            const nanoseconds = std.Io.Timestamp.now(self.io, .real).nanoseconds;
            self.random_state = @truncate(@as(u96, @bitCast(nanoseconds)));
            if (self.random_state == 0) self.random_state = 0x4d595df4d0f33173;
        }
        var value = self.random_state;
        value ^= value >> 12;
        value ^= value << 25;
        value ^= value >> 27;
        self.random_state = value;
        const bits = (value *% 0x2545f4914f6cdd1d) >> 11;
        return @as(f64, @floatFromInt(bits)) / 9007199254740992.0;
    }
};

fn parseOptionalI64(value: ?[]const u8) ?i64 {
    return std.fmt.parseInt(i64, value orelse return null, 10) catch null;
}

fn parseOptionalU64(value: ?[]const u8) ?u64 {
    return std.fmt.parseInt(u64, value orelse return null, 10) catch null;
}

fn parseOptionalF64(value: ?[]const u8) ?f64 {
    return std.fmt.parseFloat(f64, value orelse return null) catch null;
}

fn compileInput(allocator: std.mem.Allocator, io: std.Io, path: []const u8, compat_js: bool, stderr: *std.Io.Writer) !?lnako.ir.nako_ir.Program {
    var file_provider = lnako.semantic.module_graph.FileProvider{ .io = io };
    var graph = lnako.semantic.module_graph.load(allocator, path, file_provider.sourceProvider(), .{ .compat_js = compat_js }) catch |err| {
        try stderr.print("{s}: 読み込みまたは字句解析に失敗しました: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    defer graph.deinit();
    if (!graph.succeeded()) {
        for (graph.diagnostics) |item| try item.render(sourceForDiagnostic(graph, item.file), stderr);
        for (graph.modules) |module| if (module.parsed) |parsed| {
            for (parsed.diagnostics) |item| try item.render(module.source, stderr);
        };
        return null;
    }
    var program = try graph.analyze(allocator);
    defer program.deinit();
    if (!program.succeeded()) {
        for (program.diagnostics) |item| try item.render(sourceForDiagnostic(graph, item.file), stderr);
        return null;
    }
    var roots: std.ArrayList(*lnako.frontend.ast.Node) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;
    for (graph.modules) |module| {
        if (module.kind != .nako3) continue;
        try roots.append(allocator, module.parsed.?.root.?);
        try names.append(allocator, module.name);
        try paths.append(allocator, module.path);
    }
    var hir_program = try lnako.ir.hir.lower(allocator, roots.items, names.items, paths.items, program);
    defer hir_program.deinit();
    var ir_program = try lnako.ir.lower_ssa.lower(allocator, hir_program);
    errdefer ir_program.deinit();
    var verification = try lnako.ir.verifier.verify(allocator, ir_program);
    defer verification.deinit();
    if (!verification.succeeded()) {
        for (verification.issues) |issue| try stderr.print("IR検証エラー[{s}] {s}: {s}\n", .{ @tagName(issue.code), issue.function_name, issue.message });
        ir_program.deinit();
        return null;
    }
    return ir_program;
}

fn runTestTarget(allocator: std.mem.Allocator, io: std.Io, path: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| {
        try stderr.print("{s}: テスト対象を確認できません: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    if (stat.kind != .directory) return runTestFile(allocator, io, path, stdout, stderr);

    var directory = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.eqlIgnoreCase(std.fs.path.extension(entry.path), ".nako3")) continue;
        try files.append(allocator, try std.fs.path.join(allocator, &.{ path, entry.path }));
    }
    std.mem.sort([]const u8, files.items, {}, lessThanString);
    var succeeded = true;
    for (files.items) |file| if (!try runTestFile(allocator, io, file, stdout, stderr)) {
        succeeded = false;
    };
    return succeeded;
}

fn runTestFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var ir_program = (try compileInput(allocator, io, path, false, stderr)) orelse return false;
    defer ir_program.deinit();
    var runtime = lnako.runtime.value.Runtime.init(allocator);
    defer runtime.deinit();
    var cli_host = CliHost{ .writer = stdout, .io = io };
    var interpreter = lnako.runtime.interpreter.Interpreter.init(allocator, &runtime, ir_program, cli_host.host());
    defer interpreter.deinit();
    _ = interpreter.run() catch |err| {
        try stderr.print("{s}: テスト初期化エラー: {s}\n", .{ path, @errorName(err) });
        return false;
    };
    const results = try interpreter.runTests();
    var succeeded = true;
    for (results) |result| {
        if (result.passed) {
            try stdout.print("ok - {s}: {s}\n", .{ path, result.name });
        } else {
            succeeded = false;
            try stdout.print("not ok - {s}: {s} ({s})\n", .{ path, result.name, result.message });
        }
    }
    if (results.len == 0) try stdout.print("{s}: テスト定義はありません\n", .{path});
    return succeeded;
}

fn hasArgument(arguments: []const []const u8, expected: []const u8) bool {
    for (arguments) |argument| if (std.mem.eql(u8, argument, expected)) return true;
    return false;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn sourceForDiagnostic(graph: lnako.semantic.module_graph.ModuleGraph, file: []const u8) []const u8 {
    for (graph.modules) |module| if (std.mem.eql(u8, module.path, file)) return module.source;
    return "";
}

test "CLIモジュールを読み込める" {
    try std.testing.expect(lnako.version.len > 0);
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
