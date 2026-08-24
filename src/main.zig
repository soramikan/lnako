const std = @import("std");
const builtin = @import("builtin");
const lnako = @import("lnako");
const zip_archive = @import("archive/zip.zig");

var interrupt_requested = std.atomic.Value(bool).init(false);

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
                .error_writer = stderr,
                .io = init.io,
                .program_arguments = process_args,
                .runtime_path = process_args[0],
                .source_path = args[1],
                .environment_names = init.environ_map.keys(),
                .environment_values = init.environ_map.values(),
                .home_directory = homeDirectory(init.environ_map),
                .temporary_directory = temporaryDirectory(init.environ_map),
                .fixed_now_milliseconds = parseOptionalI64(init.environ_map.get("LNAKO_TEST_NOW_MS")),
                .fixed_monotonic_milliseconds = parseOptionalF64(init.environ_map.get("LNAKO_TEST_MONOTONIC_MS")),
                .random_state = parseOptionalU64(init.environ_map.get("LNAKO_TEST_RANDOM_SEED")) orelse 0,
            };
            defer cli_host.deinit();
            var interpreter = lnako.runtime.interpreter.Interpreter.init(allocator, &runtime, ir_program, cli_host.host());
            defer interpreter.deinit();
            _ = interpreter.run() catch |err| {
                if (err == error.ProcessExitRequested) {
                    try stdout.flush();
                    try stderr.flush();
                    std.process.exit(interpreter.requestedExitCode() orelse 0);
                }
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
    error_writer: *std.Io.Writer,
    io: std.Io,
    random_state: u64 = 0,
    fixed_now_milliseconds: ?i64 = null,
    fixed_monotonic_milliseconds: ?f64 = null,
    program_arguments: []const []const u8 = &.{},
    runtime_path: []const u8 = "lnako",
    source_path: []const u8 = ".",
    environment_names: []const []const u8 = &.{},
    environment_values: []const []const u8 = &.{},
    home_directory: ?[]const u8 = null,
    temporary_directory: []const u8 = "/tmp",
    async_tasks: std.ArrayList(*AsyncOperationTask) = .empty,
    next_async_token: usize = 1,
    async_completion_sequence: std.atomic.Value(u64) = .init(1),

    fn deinit(self: *CliHost) void {
        while (self.async_tasks.pop()) |task| destroyAsyncTask(task, true);
        self.async_tasks.deinit(std.heap.page_allocator);
    }

    fn host(self: *CliHost) lnako.runtime.interpreter.Host {
        return .{
            .context = self,
            .writeFn = write,
            .sleepMillisecondsFn = sleepMilliseconds,
            .nowMillisecondsFn = nowMilliseconds,
            .monotonicMillisecondsFn = monotonicMilliseconds,
            .randomFn = random,
            .node_context = .{
                .context = self,
                .cwdFn = currentDirectory,
                .chdirFn = changeDirectory,
                .program_arguments = self.program_arguments,
                .runtime_path = self.runtime_path,
                .source_path = self.source_path,
                .environment_names = self.environment_names,
                .environment_values = self.environment_values,
                .home_directory = self.home_directory,
                .temporary_directory = self.temporary_directory,
                .readFileFn = readFile,
                .writeFileFn = writeFile,
                .statFileFn = statFile,
                .createDirectoryFn = createDirectory,
                .deletePathFn = deletePath,
                .copyPathFn = copyPath,
                .movePathFn = movePath,
                .listDirectoryFn = listDirectory,
                .runCommandFn = runCommand,
                .startCommandFn = startCommand,
                .startFileOperationFn = startFileOperation,
                .startArchiveFn = startArchive,
                .pollOperationFn = pollOperation,
                .readStdinFn = readStdin,
                .createTemporaryDirectoryFn = createTemporaryDirectory,
                .openExternalFn = openExternal,
                .writeStdoutFn = write,
                .writeStderrFn = writeError,
                .archiveFn = archive,
                .installInterruptFn = installInterrupt,
                .consumeInterruptFn = consumeInterrupt,
            },
        };
    }

    fn write(context: *anyopaque, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try self.writer.writeAll(bytes);
    }

    fn writeError(context: *anyopaque, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try self.error_writer.writeAll(bytes);
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

    fn currentDirectory(context: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const path = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", allocator);
        return path;
    }

    fn changeDirectory(context: *anyopaque, path: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        var directory = try std.Io.Dir.cwd().openDir(self.io, path, .{});
        defer directory.close(self.io);
        try std.process.setCurrentDir(self.io, directory);
    }

    fn readFile(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        return std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(1024 * 1024 * 1024));
    }

    fn writeFile(context: *anyopaque, path: []const u8, bytes: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes });
    }

    fn statFile(context: *anyopaque, path: []const u8) !lnako.plugins.node.FileStat {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const stat = try std.Io.Dir.cwd().statFile(self.io, path, .{});
        return .{
            .kind = switch (stat.kind) {
                .file => .file,
                .directory => .directory,
                else => .other,
            },
            .size = stat.size,
            .inode = @floatFromInt(stat.inode),
            .links = @floatFromInt(stat.nlink),
            .block_size = @floatFromInt(stat.block_size),
            .modified_nanoseconds = stat.mtime.nanoseconds,
            .changed_nanoseconds = stat.ctime.nanoseconds,
            .accessed_nanoseconds = if (stat.atime) |time| time.nanoseconds else null,
        };
    }

    fn createDirectory(context: *anyopaque, path: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try std.Io.Dir.cwd().createDirPath(self.io, path);
    }

    fn deletePath(context: *anyopaque, path: []const u8) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        try std.Io.Dir.cwd().deleteTree(self.io, path);
    }

    fn copyPath(context: *anyopaque, allocator: std.mem.Allocator, source: []const u8, destination: []const u8, overwrite: bool) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const stat = try std.Io.Dir.cwd().statFile(self.io, source, .{});
        if (stat.kind != .directory) return std.Io.Dir.cwd().copyFile(source, std.Io.Dir.cwd(), destination, self.io, .{ .replace = overwrite, .make_path = true });
        try std.Io.Dir.cwd().createDirPath(self.io, destination);
        var directory = try std.Io.Dir.cwd().openDir(self.io, source, .{ .iterate = true });
        defer directory.close(self.io);
        var walker = try directory.walk(allocator);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            const target = try std.fs.path.join(allocator, &.{ destination, entry.path });
            defer allocator.free(target);
            if (entry.kind == .directory) {
                try std.Io.Dir.cwd().createDirPath(self.io, target);
            } else if (entry.kind == .file) {
                const from = try std.fs.path.join(allocator, &.{ source, entry.path });
                defer allocator.free(from);
                try std.Io.Dir.cwd().copyFile(from, std.Io.Dir.cwd(), target, self.io, .{ .replace = overwrite, .make_path = true });
            }
        }
    }

    fn movePath(context: *anyopaque, allocator: std.mem.Allocator, source: []const u8, destination: []const u8, overwrite: bool) !void {
        try copyPath(context, allocator, source, destination, overwrite);
        try deletePath(context, source);
    }

    fn listDirectory(context: *anyopaque, allocator: std.mem.Allocator, path: []const u8, recursive: bool) ![]lnako.plugins.node.FileEntry {
        const self: *CliHost = @ptrCast(@alignCast(context));
        var directory = try std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true });
        defer directory.close(self.io);
        var entries: std.ArrayList(lnako.plugins.node.FileEntry) = .empty;
        errdefer {
            for (entries.items) |entry| allocator.free(entry.name);
            entries.deinit(allocator);
        }
        if (recursive) {
            var walker = try directory.walk(allocator);
            defer walker.deinit();
            while (try walker.next(self.io)) |entry| try entries.append(allocator, .{
                .name = try allocator.dupe(u8, entry.path),
                .kind = switch (entry.kind) {
                    .file => .file,
                    .directory => .directory,
                    else => .other,
                },
            });
        } else {
            var iterator = directory.iterate();
            while (try iterator.next(self.io)) |entry| try entries.append(allocator, .{
                .name = try allocator.dupe(u8, entry.name),
                .kind = switch (entry.kind) {
                    .file => .file,
                    .directory => .directory,
                    else => .other,
                },
            });
        }
        std.mem.sort(lnako.plugins.node.FileEntry, entries.items, {}, lessThanNodeFileEntry);
        return entries.toOwnedSlice(allocator);
    }

    fn runCommand(context: *anyopaque, allocator: std.mem.Allocator, command: []const u8) !lnako.plugins.node.CommandResult {
        const self: *CliHost = @ptrCast(@alignCast(context));
        return runShellCommand(allocator, self.io, command, null);
    }

    fn startCommand(context: *anyopaque, command: []const u8) !usize {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const allocator = std.heap.page_allocator;
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(self.io, ".", allocator);
        errdefer allocator.free(cwd);
        return self.startAsyncOperation(.{ .command = .{ .command = owned_command, .cwd = cwd } });
    }

    fn startFileOperation(context: *anyopaque, operation: lnako.plugins.node.FileOperation, source: []const u8, destination: ?[]const u8, overwrite: bool) !usize {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const allocator = std.heap.page_allocator;
        const owned_source = try allocator.dupe(u8, source);
        errdefer allocator.free(owned_source);
        const owned_destination = if (destination) |path| try allocator.dupe(u8, path) else null;
        errdefer if (owned_destination) |path| allocator.free(path);
        return self.startAsyncOperation(.{ .file = .{ .operation = operation, .source = owned_source, .destination = owned_destination, .overwrite = overwrite } });
    }

    fn startArchive(context: *anyopaque, operation: lnako.plugins.node.ArchiveOperation, source: []const u8, destination: []const u8, external_tool: ?[]const u8) !usize {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const allocator = std.heap.page_allocator;
        const owned_source = try allocator.dupe(u8, source);
        errdefer allocator.free(owned_source);
        const owned_destination = try allocator.dupe(u8, destination);
        errdefer allocator.free(owned_destination);
        const owned_tool = if (external_tool) |tool| try allocator.dupe(u8, tool) else null;
        errdefer if (owned_tool) |tool| allocator.free(tool);
        return self.startAsyncOperation(.{ .archive = .{ .operation = operation, .source = owned_source, .destination = owned_destination, .external_tool = owned_tool } });
    }

    fn startAsyncOperation(self: *CliHost, operation: AsyncOperation) !usize {
        const allocator = std.heap.page_allocator;
        const task = try allocator.create(AsyncOperationTask);
        errdefer allocator.destroy(task);
        const token = self.next_async_token;
        self.next_async_token +%= 1;
        if (self.next_async_token == 0) self.next_async_token = 1;
        task.* = .{ .token = token, .host = self, .operation = operation };
        try self.async_tasks.append(allocator, task);
        errdefer _ = self.async_tasks.pop();
        task.thread = try std.Thread.spawn(.{}, AsyncOperationTask.run, .{task});
        return token;
    }

    fn pollOperation(context: *anyopaque, allocator: std.mem.Allocator, token: usize) !?lnako.plugins.node.CommandResult {
        const self: *CliHost = @ptrCast(@alignCast(context));
        for (self.async_tasks.items, 0..) |task, index| {
            if (task.token != token) continue;
            const complete = task.complete.load(.acquire);
            if (!complete) return null;
            for (self.async_tasks.items) |other| {
                if (other == task or !other.complete.load(.acquire)) continue;
                if (other.completion_order < task.completion_order) return null;
            }
            const failure = task.failure;
            const source = task.result;
            const owned = if (source) |result| blk: {
                const stdout_bytes = try allocator.dupe(u8, result.stdout);
                errdefer allocator.free(stdout_bytes);
                const stderr_bytes = try allocator.dupe(u8, result.stderr);
                errdefer allocator.free(stderr_bytes);
                break :blk lnako.plugins.node.CommandResult{ .stdout = stdout_bytes, .stderr = stderr_bytes, .exit_code = result.exit_code };
            } else null;
            _ = self.async_tasks.orderedRemove(index);
            destroyAsyncTask(task, true);
            if (failure) |err| return err;
            return owned orelse error.AsyncCommandMissingResult;
        }
        return error.AsyncCommandNotFound;
    }

    fn readStdin(context: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(self.io, &buffer);
        return reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024));
    }

    fn createTemporaryDirectory(context: *anyopaque, allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        for (0..128) |_| {
            const candidate = try allocator.alloc(u8, prefix.len + 6);
            errdefer allocator.free(candidate);
            @memcpy(candidate[0..prefix.len], prefix);
            for (candidate[prefix.len..]) |*byte| byte.* = alphabet[@as(usize, @intFromFloat(try random(self))) % alphabet.len];
            std.Io.Dir.cwd().createDir(self.io, candidate, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {
                    allocator.free(candidate);
                    continue;
                },
                else => return err,
            };
            return candidate;
        }
        return error.TemporaryDirectoryCollision;
    }

    fn openExternal(context: *anyopaque, allocator: std.mem.Allocator, target: []const u8, reveal: bool) !void {
        const self: *CliHost = @ptrCast(@alignCast(context));
        const argv: []const []const u8 = switch (builtin.os.tag) {
            .macos => if (reveal) &.{ "/usr/bin/open", "-R", target } else &.{ "/usr/bin/open", target },
            .windows => if (reveal)
                &.{ "explorer.exe", "/select,", target }
            else
                &.{ "cmd.exe", "/d", "/s", "/c", "start", "", target },
            else => if (reveal)
                &.{ "xdg-open", std.fs.path.dirname(target) orelse "." }
            else
                &.{ "xdg-open", target },
        };
        const result = try std.process.run(allocator, self.io, .{ .argv = argv, .stdout_limit = .limited(1024 * 1024), .stderr_limit = .limited(1024 * 1024) });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) return error.OpenExternalFailed;
    }

    fn archive(context: *anyopaque, allocator: std.mem.Allocator, operation: lnako.plugins.node.ArchiveOperation, source: []const u8, destination: []const u8, external_tool: ?[]const u8) ![]u8 {
        const self: *CliHost = @ptrCast(@alignCast(context));
        if (external_tool) |tool| return runArchiveTool(allocator, self.io, tool, operation, source, destination);
        switch (operation) {
            .compress => try zip_archive.create(allocator, self.io, source, destination),
            .extract => try zip_archive.extract(self.io, source, destination),
        }
        return allocator.alloc(u8, 0);
    }

    fn installInterrupt(_: *anyopaque) !void {
        if (builtin.os.tag == .windows) {
            if (WindowsInterrupt.SetConsoleCtrlHandler(WindowsInterrupt.handler, 1) == 0) return error.InterruptHandlingUnavailable;
        } else {
            const action: std.posix.Sigaction = .{
                .handler = .{ .handler = PosixInterrupt.handler },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(.INT, &action, null);
        }
    }

    fn consumeInterrupt(_: *anyopaque) bool {
        return interrupt_requested.swap(false, .acquire);
    }
};

const PosixInterrupt = if (builtin.os.tag == .windows) struct {} else struct {
    fn handler(_: std.posix.SIG) callconv(.c) void {
        interrupt_requested.store(true, .release);
    }
};

const WindowsInterrupt = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn SetConsoleCtrlHandler(handler_fn: ?*const fn (u32) callconv(.winapi) i32, add: i32) callconv(.winapi) i32;

    fn handler(control_type: u32) callconv(.winapi) i32 {
        if (control_type != 0 and control_type != 1) return 0;
        interrupt_requested.store(true, .release);
        return 1;
    }
} else struct {};

const AsyncOperation = union(enum) {
    command: struct { command: []u8, cwd: []u8 },
    file: struct { operation: lnako.plugins.node.FileOperation, source: []u8, destination: ?[]u8, overwrite: bool },
    archive: struct { operation: lnako.plugins.node.ArchiveOperation, source: []u8, destination: []u8, external_tool: ?[]u8 },

    fn deinit(self: *@This()) void {
        const allocator = std.heap.page_allocator;
        switch (self.*) {
            .command => |operation| {
                allocator.free(operation.command);
                allocator.free(operation.cwd);
            },
            .file => |operation| {
                allocator.free(operation.source);
                if (operation.destination) |destination| allocator.free(destination);
            },
            .archive => |operation| {
                allocator.free(operation.source);
                allocator.free(operation.destination);
                if (operation.external_tool) |tool| allocator.free(tool);
            },
        }
        self.* = undefined;
    }
};

const AsyncOperationTask = struct {
    token: usize,
    host: *CliHost,
    operation: AsyncOperation,
    thread: ?std.Thread = null,
    complete: std.atomic.Value(bool) = .init(false),
    completion_order: u64 = 0,
    result: ?lnako.plugins.node.CommandResult = null,
    failure: ?anyerror = null,

    fn run(self: *@This()) void {
        const result = self.execute() catch |err| {
            self.failure = err;
            self.completion_order = self.host.async_completion_sequence.fetchAdd(1, .monotonic);
            self.complete.store(true, .release);
            return;
        };
        self.result = result;
        self.completion_order = self.host.async_completion_sequence.fetchAdd(1, .monotonic);
        self.complete.store(true, .release);
    }

    fn execute(self: *@This()) !lnako.plugins.node.CommandResult {
        const allocator = std.heap.page_allocator;
        return switch (self.operation) {
            .command => |operation| runShellCommand(allocator, self.host.io, operation.command, operation.cwd),
            .file => |operation| blk: {
                switch (operation.operation) {
                    .copy => try CliHost.copyPath(self.host, allocator, operation.source, operation.destination orelse return error.MissingFileDestination, operation.overwrite),
                    .move => try CliHost.movePath(self.host, allocator, operation.source, operation.destination orelse return error.MissingFileDestination, operation.overwrite),
                    .delete => try CliHost.deletePath(self.host, operation.source),
                }
                break :blk try emptyCommandResult(allocator);
            },
            .archive => |operation| blk: {
                const stdout_bytes = try CliHost.archive(self.host, allocator, operation.operation, operation.source, operation.destination, operation.external_tool);
                errdefer allocator.free(stdout_bytes);
                break :blk .{ .stdout = stdout_bytes, .stderr = try allocator.alloc(u8, 0), .exit_code = 0 };
            },
        };
    }
};

fn emptyCommandResult(allocator: std.mem.Allocator) !lnako.plugins.node.CommandResult {
    const stdout_bytes = try allocator.alloc(u8, 0);
    errdefer allocator.free(stdout_bytes);
    return .{ .stdout = stdout_bytes, .stderr = try allocator.alloc(u8, 0), .exit_code = 0 };
}

fn destroyAsyncTask(task: *AsyncOperationTask, join: bool) void {
    if (join) if (task.thread) |thread| thread.join();
    if (task.result) |*result| result.deinit(std.heap.page_allocator);
    task.operation.deinit();
    std.heap.page_allocator.destroy(task);
}

fn runShellCommand(allocator: std.mem.Allocator, io: std.Io, command: []const u8, cwd: ?[]const u8) !lnako.plugins.node.CommandResult {
    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "cmd.exe", "/d", "/s", "/c", command }
    else
        &.{ "/bin/sh", "-c", command };
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(64 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024 * 1024),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = switch (result.term) {
            .exited => |code| code,
            else => 1,
        },
    };
}

fn runArchiveTool(allocator: std.mem.Allocator, io: std.Io, tool: []const u8, operation: lnako.plugins.node.ArchiveOperation, source: []const u8, destination: []const u8) ![]u8 {
    const output_option = if (operation == .extract) try std.fmt.allocPrint(allocator, "-o{s}", .{destination}) else null;
    defer if (output_option) |option| allocator.free(option);
    const argv: []const []const u8 = switch (operation) {
        .compress => &.{ tool, "a", "-r", destination, source, "-y" },
        .extract => &.{ tool, "x", source, output_option.?, "-y" },
    };
    const result = try std.process.run(allocator, io, .{ .argv = argv, .stdout_limit = .limited(64 * 1024 * 1024), .stderr_limit = .limited(64 * 1024 * 1024) });
    allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.ArchiveToolFailed;
    }
    return result.stdout;
}

test {
    std.testing.refAllDecls(zip_archive);
}

fn lessThanNodeFileEntry(_: void, left: lnako.plugins.node.FileEntry, right: lnako.plugins.node.FileEntry) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn homeDirectory(environment: *const std.process.Environ.Map) ?[]const u8 {
    return environment.get(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME");
}

fn temporaryDirectory(environment: *const std.process.Environ.Map) []const u8 {
    const value = if (builtin.os.tag == .windows)
        environment.get("TEMP") orelse environment.get("TMP") orelse "."
    else
        environment.get("TMPDIR") orelse "/tmp";
    const trimmed = std.mem.trimEnd(u8, value, "/\\");
    return if (trimmed.len == 0) value else trimmed;
}

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
    var cli_host = CliHost{ .writer = stdout, .error_writer = stderr, .io = io };
    defer cli_host.deinit();
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
