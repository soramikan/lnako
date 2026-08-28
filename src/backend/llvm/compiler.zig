const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../../ir/nako_ir.zig");
const optimizer = @import("../../ir/optimizer.zig");
const verifier = @import("../../ir/verifier.zig");
const api_mod = @import("api.zig");
const module_mod = @import("module.zig");

pub const Optimization = enum { o0, o1, o2, o3 };
pub const Emit = enum { llvm_ir, object, executable };

pub const Options = struct {
    optimization: Optimization = .o0,
    emit: Emit = .executable,
    source_path: []const u8,
    output_path: []const u8,
    llvm_root: ?[]const u8 = null,
    llvm_library: ?[]const u8 = null,
    runtime_library: ?[]const u8 = null,
    compile_manifest_path: ?[]const u8 = null,
    trace: bool = false,
};

pub fn compile(allocator: std.mem.Allocator, io: std.Io, program: ir.Program, options: Options, diagnostics: *std.Io.Writer) !void {
    var manifest_entry_count: ?usize = null;
    var manifest_created = false;
    var manifest_complete = false;
    defer if (manifest_created and !manifest_complete) if (options.compile_manifest_path) |manifest_path| {
        std.Io.Dir.deleteFileAbsolute(io, manifest_path) catch {};
    };
    if (options.compile_manifest_path) |manifest_path| {
        manifest_entry_count = module_mod.writeBuiltinManifest(allocator, io, program, options.source_path, manifest_path) catch |failure| {
            try diagnostics.print("AOT builtin manifest生成エラー: {s}\n", .{@errorName(failure)});
            return error.CompileManifestFailed;
        };
        manifest_created = true;
    }
    var optimized_program: ?ir.Program = null;
    defer if (optimized_program) |*owned| owned.deinit();
    if (options.optimization != .o0) {
        optimized_program = try program.clone(allocator);
        const max_iterations: usize = switch (options.optimization) {
            .o0 => unreachable,
            .o1 => 4,
            .o2 => 8,
            .o3 => 12,
        };
        const stats = try optimizer.optimize(allocator, &optimized_program.?, .{ .max_iterations = max_iterations });
        var report = try verifier.verify(allocator, optimized_program.?);
        defer report.deinit();
        if (!report.succeeded()) {
            for (report.issues) |issue| try diagnostics.print("最適化後IR検証エラー[{s}] {s}: {s}\n", .{ @tagName(issue.code), issue.function_name, issue.message });
            return error.InvalidOptimizedIr;
        }
        if (options.trace) try diagnostics.print(
            "[LLVM] Nako SSA最適化: type={d} parameter={d} return={d} direct={d} fold={d} branch={d} dce={d}\n",
            .{ stats.inferred_values, stats.inferred_parameters, stats.inferred_returns, stats.direct_calls, stats.folded_constants, stats.simplified_branches, stats.removed_instructions },
        );
    }
    const selected_program = optimized_program orelse program;
    if (module_mod.findUnsupported(selected_program)) |feature| {
        try diagnostics.print("{s}:{d}:{d}: AOT未対応機能: opcode={s} detail={s} function={s}\n", .{
            options.source_path,
            feature.span.line + 1,
            @max(@as(usize, 1), feature.span.column),
            feature.opcode,
            feature.detail,
            feature.function_name,
        });
        return error.UnsupportedInstruction;
    }
    var generated = try module_mod.generate(allocator, selected_program, options.source_path, options.optimization != .o0);
    defer generated.deinit(allocator);
    try trace(options.trace, diagnostics, "LLVM共有ライブラリを読み込みます");
    var api = api_mod.Api.openAt(allocator, options.llvm_root, options.llvm_library) catch |failure| {
        try diagnostics.print("LLVM 22.1.8を読み込めません: {s}\n", .{@errorName(failure)});
        return failure;
    };
    defer api.close();
    try trace(options.trace, diagnostics, "LLVMコンテキストを作成します");
    const context = api.contextCreate() orelse return error.LlvmContextCreationFailed;
    defer api.contextDispose(context);
    const buffer_name = try allocator.dupeZ(u8, options.source_path);
    defer allocator.free(buffer_name);
    const buffer = api.createMemoryBuffer(generated.text.ptr, generated.text.len, buffer_name.ptr) orelse return error.LlvmMemoryBufferCreationFailed;
    var llvm_module: api_mod.ModuleRef = null;
    var message: api_mod.Message = null;
    if (api.parseIr(context, buffer, &llvm_module, &message) != 0) {
        try reportMessage(&api, diagnostics, "LLVM IR解析エラー", message);
        return error.InvalidGeneratedLlvmIr;
    }
    defer api.disposeModule(llvm_module);

    try trace(options.trace, diagnostics, "LLVMホストターゲットを初期化します");
    api.initializeTargetInfo();
    api.initializeTarget();
    api.initializeTargetMc();
    api.initializeAsmPrinter();
    const triple = api.getDefaultTargetTriple();
    defer api.disposeMessage(triple);
    var target: api_mod.TargetRef = null;
    message = null;
    if (api.getTargetFromTriple(triple, &target, &message) != 0) {
        try reportMessage(&api, diagnostics, "LLVMターゲット取得エラー", message);
        return error.LlvmTargetUnavailable;
    }
    const machine = api.createTargetMachine(target, triple, "generic", "", codeGenLevel(options.optimization), 2, 0) orelse return error.LlvmTargetMachineCreationFailed;
    defer api.disposeTargetMachine(machine);
    const target_data = api.createTargetDataLayout(machine) orelse return error.LlvmDataLayoutCreationFailed;
    defer api.disposeTargetData(target_data);
    const data_layout = api.copyDataLayout(target_data);
    defer api.disposeMessage(data_layout);
    api.setTarget(llvm_module, triple);
    api.setDataLayout(llvm_module, data_layout);

    try trace(options.trace, diagnostics, "LLVMモジュールを検証・最適化します");
    try verify(&api, llvm_module, diagnostics);
    const pass_options = api.createPassBuilderOptions() orelse return error.LlvmPassBuilderCreationFailed;
    defer api.disposePassBuilderOptions(pass_options);
    api.passBuilderSetVerifyEach(pass_options, 1);
    const pipeline: [:0]const u8 = switch (options.optimization) {
        .o0 => "default<O0>",
        .o1 => "default<O1>",
        .o2 => "default<O2>",
        .o3 => "default<O3>",
    };
    if (api.runPasses(llvm_module, pipeline.ptr, machine, pass_options)) |pass_error| {
        const error_message = api.getErrorMessage(pass_error);
        defer api.disposeErrorMessage(error_message);
        try diagnostics.print("LLVM最適化エラー: {s}\n", .{std.mem.span(error_message)});
        return error.LlvmOptimizationFailed;
    }
    try verify(&api, llvm_module, diagnostics);

    try trace(options.trace, diagnostics, "LLVM生成物を出力します");
    switch (options.emit) {
        .llvm_ir => {
            const module_text = api.printModule(llvm_module);
            defer api.disposeMessage(module_text);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = options.output_path, .data = std.mem.span(module_text) });
        },
        .object => try emitObject(allocator, &api, machine, llvm_module, options.output_path, diagnostics),
        .executable => {
            const temporary_nonce = nonce(io);
            const object_path = try std.fmt.allocPrint(allocator, "{s}.lnako-{x}.o", .{ options.output_path, temporary_nonce });
            defer allocator.free(object_path);
            defer std.Io.Dir.cwd().deleteFile(io, object_path) catch {};
            try emitObject(allocator, &api, machine, llvm_module, object_path, diagnostics);
            try linkExecutable(allocator, io, object_path, options.output_path, options.llvm_root, options.runtime_library, diagnostics);
        },
    }
    if (manifest_entry_count) |entry_count| {
        module_mod.completeBuiltinManifest(io, options.compile_manifest_path.?, entry_count) catch |failure| {
            try diagnostics.print("AOT builtin manifest完了記録エラー: {s}\n", .{@errorName(failure)});
            return error.CompileManifestFailed;
        };
        manifest_complete = true;
    }
}

fn trace(enabled: bool, diagnostics: *std.Io.Writer, message: []const u8) !void {
    if (!enabled) return;
    try diagnostics.print("[LLVM] {s}\n", .{message});
    try diagnostics.flush();
}

fn verify(api: *api_mod.Api, module: api_mod.ModuleRef, diagnostics: *std.Io.Writer) !void {
    var message: api_mod.Message = null;
    if (api.verifyModule(module, 2, &message) != 0) {
        try reportMessage(api, diagnostics, "LLVMモジュール検証エラー", message);
        return error.LlvmModuleVerificationFailed;
    }
    if (message) |unused| api.disposeMessage(unused);
}

fn emitObject(allocator: std.mem.Allocator, api: *api_mod.Api, machine: api_mod.TargetMachineRef, module: api_mod.ModuleRef, path: []const u8, diagnostics: *std.Io.Writer) !void {
    const output = try allocator.dupeZ(u8, path);
    defer allocator.free(output);
    var message: api_mod.Message = null;
    if (api.emitToFile(machine, module, output.ptr, 1, &message) != 0) {
        try reportMessage(api, diagnostics, "LLVMオブジェクト出力エラー", message);
        return error.LlvmObjectEmissionFailed;
    }
    if (message) |unused| api.disposeMessage(unused);
}

fn reportMessage(api: *api_mod.Api, diagnostics: *std.Io.Writer, prefix: []const u8, message: api_mod.Message) !void {
    if (message) |text| {
        defer api.disposeMessage(text);
        try diagnostics.print("{s}: {s}\n", .{ prefix, std.mem.span(text) });
    } else try diagnostics.print("{s}\n", .{prefix});
}

fn codeGenLevel(optimization: Optimization) c_uint {
    return switch (optimization) {
        .o0 => 0,
        .o1 => 1,
        .o2 => 2,
        .o3 => 3,
    };
}

fn nonce(io: std.Io) u64 {
    return @truncate(@as(u96, @bitCast(std.Io.Timestamp.now(io, .awake).nanoseconds)));
}

fn linkExecutable(allocator: std.mem.Allocator, io: std.Io, object_path: []const u8, output_path: []const u8, llvm_root: ?[]const u8, runtime_override: ?[]const u8, diagnostics: *std.Io.Writer) !void {
    const tools = try findLinkTools(allocator, io, llvm_root);
    defer allocator.free(tools.clang);
    defer allocator.free(tools.lld);
    const runtime_library = findRuntimeLibrary(allocator, io, runtime_override) catch |failure| {
        try diagnostics.print("AOTランタイム静的ライブラリを読み込めません: {s}\n", .{@errorName(failure)});
        return failure;
    };
    defer allocator.free(runtime_library);
    const linker_argument = try std.fmt.allocPrint(allocator, "--ld-path={s}", .{tools.lld});
    defer allocator.free(linker_argument);
    const macos_sdk: ?[]u8 = if (builtin.os.tag == .macos) try findMacOsSdk(allocator, io) else null;
    defer if (macos_sdk) |path| allocator.free(path);
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .linux => &.{ tools.clang, linker_argument, object_path, runtime_library, "-o", output_path, "-lm" },
        .macos => &.{ tools.clang, linker_argument, "-isysroot", macos_sdk.?, object_path, runtime_library, "-o", output_path },
        .windows => &.{ tools.clang, linker_argument, object_path, runtime_library, "-liphlpapi", "-lntdll", "-o", output_path },
        else => &.{ tools.clang, linker_argument, object_path, runtime_library, "-o", output_path },
    };
    const result = try std.process.run(allocator, io, .{ .argv = argv });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    try diagnostics.print("LLDリンクエラー:\n{s}", .{result.stderr});
    return error.LldLinkFailed;
}

fn findRuntimeLibrary(allocator: std.mem.Allocator, io: std.Io, override: ?[]const u8) ![]u8 {
    if (override) |path| {
        _ = try std.Io.Dir.cwd().statFile(io, path, .{});
        return allocator.dupe(u8, path);
    }
    const executable = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(executable);
    const directory = std.fs.path.dirname(executable) orelse return error.AotRuntimeLibraryNotFound;
    const name = if (builtin.os.tag == .windows) "lnako_runtime.lib" else "liblnako_runtime.a";
    const path = try std.fs.path.join(allocator, &.{ directory, "..", "lib", name });
    errdefer allocator.free(path);
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return error.AotRuntimeLibraryNotFound;
    return path;
}

fn findMacOsSdk(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.MacOsSdkNotFound;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) return error.MacOsSdkNotFound;
    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0) return error.MacOsSdkNotFound;
    return allocator.dupe(u8, path);
}

const LinkTools = struct { clang: []u8, lld: []u8 };

fn findLinkTools(allocator: std.mem.Allocator, io: std.Io, llvm_root: ?[]const u8) !LinkTools {
    if (llvm_root) |root| {
        const clang_name = if (builtin.os.tag == .windows) "clang.exe" else "clang";
        const lld_name = switch (builtin.os.tag) {
            .macos => "ld64.lld",
            .windows => "lld-link.exe",
            else => "ld.lld",
        };
        const clang = try std.fs.path.join(allocator, &.{ root, "bin", clang_name });
        errdefer allocator.free(clang);
        const lld = try std.fs.path.join(allocator, &.{ root, "bin", lld_name });
        errdefer allocator.free(lld);
        try requireVersionedTool(allocator, io, clang);
        try requireVersionedTool(allocator, io, lld);
        return .{ .clang = clang, .lld = lld };
    }
    const clang_candidates: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "/opt/homebrew/opt/llvm/bin/clang", "/usr/local/opt/llvm/bin/clang", "clang-22", "clang" },
        .windows => &.{ "clang.exe", "clang-cl.exe" },
        else => &.{ "/usr/lib/llvm-22/bin/clang", "/usr/local/bin/clang-22", "clang-22", "clang" },
    };
    const lld_candidates: []const []const u8 = switch (builtin.os.tag) {
        .macos => &.{ "/opt/homebrew/opt/lld/bin/ld64.lld", "/usr/local/opt/lld/bin/ld64.lld", "ld64.lld" },
        .windows => &.{ "lld-link.exe", "lld-link" },
        else => &.{ "/usr/lib/llvm-22/bin/ld.lld", "/usr/local/bin/ld.lld", "ld.lld" },
    };
    const clang = try findVersionedTool(allocator, io, clang_candidates);
    errdefer allocator.free(clang);
    const lld = try findVersionedTool(allocator, io, lld_candidates);
    return .{ .clang = clang, .lld = lld };
}

fn findVersionedTool(allocator: std.mem.Allocator, io: std.Io, candidates: []const []const u8) ![]u8 {
    for (candidates) |candidate| {
        requireVersionedTool(allocator, io, candidate) catch continue;
        return allocator.dupe(u8, candidate);
    }
    return error.Llvm22LinkerToolsNotFound;
}

fn requireVersionedTool(allocator: std.mem.Allocator, io: std.Io, candidate: []const u8) !void {
    const result = std.process.run(allocator, io, .{ .argv = &.{ candidate, "--version" }, .stdout_limit = .limited(64 * 1024), .stderr_limit = .limited(64 * 1024) }) catch return error.Llvm22LinkerToolsNotFound;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) return error.Llvm22LinkerToolsNotFound;
    if (std.mem.indexOf(u8, result.stdout, "22.1.8") == null and std.mem.indexOf(u8, result.stderr, "22.1.8") == null) return error.Llvm22LinkerToolsNotFound;
}

test "LLVM C APIで全最適化レベルのモジュールを検証してIRを出力する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "1+2を表示\n", "main.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "main.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "main.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const optimizations = [_]Optimization{ .o0, .o1, .o2, .o3 };
    for (optimizations) |optimization| {
        const output_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/lnako-llvm-{s}.ll", .{ temporary.sub_path, @tagName(optimization) });
        defer std.testing.allocator.free(output_path);
        var diagnostics: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer diagnostics.deinit();
        compile(std.testing.allocator, std.testing.io, program, .{ .source_path = "main.nako3", .output_path = output_path, .emit = .llvm_ir, .optimization = optimization, .trace = true }, &diagnostics.writer) catch |failure| switch (failure) {
            error.LlvmLibraryNotFound => return error.SkipZigTest,
            else => return failure,
        };
        if (optimization == .o0) {
            try std.testing.expect(std.mem.indexOf(u8, diagnostics.written(), "Nako SSA最適化") == null);
        } else try std.testing.expect(std.mem.indexOf(u8, diagnostics.written(), "Nako SSA最適化:") != null);
        const file = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, output_path, std.testing.allocator, .limited(4 * 1024 * 1024));
        defer std.testing.allocator.free(file);
        try std.testing.expect(std.mem.indexOf(u8, file, "target triple") != null);
        try std.testing.expect(std.mem.indexOf(u8, file, "!llvm.dbg.cu") != null);
    }
}

test "捕捉ありクロージャをLLVM生成対象として受理する" {
    const parser = @import("../../frontend/parser.zig");
    const semantic = @import("../../semantic/analyzer.zig");
    const hir = @import("../../ir/hir.zig");
    const lower = @import("../../ir/lower_ssa.zig");
    var parsed = try parser.parse(std.testing.allocator, "●(Aを)作るとは\nF=関数(B)それはA+B;ここまで\nFで戻る\nここまで\n作る(1)\n", "unsupported.nako3");
    defer parsed.deinit();
    var analyzed = try semantic.analyze(std.testing.allocator, parsed.root.?, "unsupported.nako3");
    defer analyzed.deinit();
    var hir_program = try hir.lowerSingle(std.testing.allocator, parsed.root.?, "main", "unsupported.nako3", analyzed);
    defer hir_program.deinit();
    var program = try lower.lower(std.testing.allocator, hir_program);
    defer program.deinit();
    try std.testing.expect(module_mod.findUnsupported(program) == null);
    var generated = try module_mod.generate(std.testing.allocator, program, "closure.nako3", false);
    defer generated.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, generated.text, "@lnako_aot_function_capture") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated.text, "closure.capture") != null);
}
