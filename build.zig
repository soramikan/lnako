const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const compat_js = b.option(bool, "compat-js", "QuickJS互換モードを静的リンクする") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "quickjs_enabled", compat_js);
    build_options.addOption([]const u8, "compat_summary_json", @embedFile("compat/v3.7.24/summary.json"));

    const lnako = b.addModule("lnako", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = compat_js or target.result.os.tag == .linux,
    });
    lnako.addOptions("build_options", build_options);
    if (compat_js) {
        configureQuickJs(b, lnako, target.result.os.tag);
    } else {
        lnako.addIncludePath(b.path("src/compat"));
        lnako.addCSourceFiles(.{ .root = b.path("src/compat"), .files = &.{"quickjs_stub.c"} });
    }

    const exe = b.addExecutable(.{
        .name = "lnako",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = compat_js or target.result.os.tag == .linux,
            .imports = &.{.{ .name = "lnako", .module = lnako }},
        }),
    });
    b.installArtifact(exe);

    const aot_runtime = b.addLibrary(.{
        .name = "lnako_runtime",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/aot.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(aot_runtime);

    const native_plugin_fixture = b.addLibrary(.{
        .name = "lnako_test_plugin",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    native_plugin_fixture.root_module.addIncludePath(b.path("include"));
    native_plugin_fixture.root_module.addCSourceFiles(.{
        .root = b.path("tests/native_plugin"),
        .files = &.{"fixture.c"},
        .flags = if (target.result.os.tag == .windows) &.{"-std=c11"} else &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L" },
    });
    if (target.result.os.tag != .windows) native_plugin_fixture.root_module.linkSystemLibrary("pthread", .{});
    const install_native_plugin_fixture = b.addInstallArtifact(native_plugin_fixture, .{});

    const invalid_native_plugin_fixture = b.addLibrary(.{
        .name = "lnako_invalid_plugin",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    invalid_native_plugin_fixture.root_module.addIncludePath(b.path("include"));
    invalid_native_plugin_fixture.root_module.addCSourceFiles(.{
        .root = b.path("tests/native_plugin"),
        .files = &.{"invalid_abi.c"},
        .flags = &.{"-std=c11"},
    });
    const install_invalid_native_plugin_fixture = b.addInstallArtifact(invalid_native_plugin_fixture, .{});

    const native_plugin_fixture_step = b.step("native-plugin-fixture", "ネイティブプラグインABIのfixtureを生成する");
    native_plugin_fixture_step.dependOn(&install_native_plugin_fixture.step);
    native_plugin_fixture_step.dependOn(&install_invalid_native_plugin_fixture.step);

    const run_step = b.step("run", "lnakoを実行する");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const lexer_probe = b.addExecutable(.{
        .name = "lexer-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/lexer_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lnako", .module = lnako }},
        }),
    });
    const lexer_probe_step = b.step("lexer-probe", "字句解析結果をJSON Linesで出力する");
    const lexer_probe_run = b.addRunArtifact(lexer_probe);
    if (b.args) |args| lexer_probe_run.addArgs(args);
    lexer_probe_step.dependOn(&lexer_probe_run.step);

    const syntax_probe = b.addExecutable(.{
        .name = "syntax-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/syntax_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lnako", .module = lnako }},
        }),
    });
    const syntax_probe_step = b.step("syntax-probe", "構文変換後のトークンをJSON Linesで出力する");
    const syntax_probe_run = b.addRunArtifact(syntax_probe);
    if (b.args) |args| syntax_probe_run.addArgs(args);
    syntax_probe_step.dependOn(&syntax_probe_run.step);

    const parser_probe = b.addExecutable(.{
        .name = "parser-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/parser_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lnako", .module = lnako }},
        }),
    });
    const parser_probe_step = b.step("parser-probe", "ASTをJSON Linesで出力する");
    const parser_probe_run = b.addRunArtifact(parser_probe);
    if (b.args) |args| parser_probe_run.addArgs(args);
    parser_probe_step.dependOn(&parser_probe_run.step);

    const semantic_probe = b.addExecutable(.{
        .name = "semantic-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/semantic_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lnako", .module = lnako }},
        }),
    });
    const semantic_probe_step = b.step("semantic-probe", "意味解析の名前解決結果をJSON Linesで出力する");
    const semantic_probe_run = b.addRunArtifact(semantic_probe);
    if (b.args) |args| semantic_probe_run.addArgs(args);
    semantic_probe_step.dependOn(&semantic_probe_run.step);

    const ir_probe = b.addExecutable(.{
        .name = "ir-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ir_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lnako", .module = lnako }},
        }),
    });
    const ir_probe_step = b.step("ir-probe", "Nako SSA IRをテキストで出力する");
    const ir_probe_run = b.addRunArtifact(ir_probe);
    if (b.args) |args| ir_probe_run.addArgs(args);
    ir_probe_step.dependOn(&ir_probe_run.step);

    const value_probe = b.addExecutable(.{
        .name = "value-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/value_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lnako", .module = lnako }},
        }),
    });
    const value_probe_step = b.step("value-probe", "動的値の変換結果をJSON Linesで出力する");
    const value_probe_run = b.addRunArtifact(value_probe);
    if (b.args) |args| value_probe_run.addArgs(args);
    value_probe_step.dependOn(&value_probe_run.step);

    const module_tests = b.addTest(.{ .root_module = lnako });
    const run_module_tests = b.addRunArtifact(module_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const aot_runtime_tests = b.addTest(.{ .root_module = aot_runtime.root_module });
    const run_aot_runtime_tests = b.addRunArtifact(aot_runtime_tests);

    const test_step = b.step("test", "全ての単体テストを実行する");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_aot_runtime_tests.step);

    const fmt_step = b.step("fmt-check", "Zigソースのフォーマットを検査する");
    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "tools" },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
}

fn configureQuickJs(b: *std.Build, module: *std.Build.Module, os: std.Target.Os.Tag) void {
    const directory = b.option([]const u8, "quickjs-dir", "QuickJSソースディレクトリ") orelse
        b.graph.environ_map.get("LNAKO_QUICKJS_DIR") orelse
        b.pathResolve(&.{ ".cache", "toolchains", "quickjs-2026-06-04" });
    // QuickJS uses implementation-defined/undefined C techniques such as
    // ABI-compatible callback casts, tagged pointers, flexible-array
    // container_of and signed shifts. ReleaseSafe's C instrumentation traps
    // those upstream techniques, so disable it only for QuickJS itself. The
    // local bridge is compiled with all normal safety instrumentation.
    const quickjs_flags: []const []const u8 = if (os == .windows)
        &.{ "-std=gnu11", "-fwrapv", "-fno-sanitize=undefined", "-fno-sanitize=function", "-D_GNU_SOURCE", "-D__USE_MINGW_ANSI_STDIO", "-DCONFIG_VERSION=\"2026-06-04\"" }
    else
        &.{ "-std=gnu11", "-fwrapv", "-fno-sanitize=undefined", "-fno-sanitize=function", "-D_GNU_SOURCE", "-DCONFIG_VERSION=\"2026-06-04\"" };
    const bridge_flags: []const []const u8 = if (os == .windows)
        &.{ "-std=gnu11", "-fwrapv", "-D_GNU_SOURCE", "-D__USE_MINGW_ANSI_STDIO", "-DCONFIG_VERSION=\"2026-06-04\"" }
    else
        &.{ "-std=gnu11", "-fwrapv", "-D_GNU_SOURCE", "-DCONFIG_VERSION=\"2026-06-04\"" };
    module.addIncludePath(.{ .cwd_relative = directory });
    module.addIncludePath(b.path("src/compat"));
    module.addCSourceFiles(.{
        .root = .{ .cwd_relative = directory },
        .files = &.{ "quickjs.c", "dtoa.c", "libregexp.c", "libunicode.c", "cutils.c" },
        .flags = quickjs_flags,
    });
    module.addCSourceFiles(.{
        .root = b.path("src/compat"),
        .files = &.{"quickjs_bridge.c"},
        .flags = bridge_flags,
    });
    if (os != .windows) {
        module.linkSystemLibrary("m", .{});
        module.linkSystemLibrary("pthread", .{});
        module.linkSystemLibrary("dl", .{});
    }
}
