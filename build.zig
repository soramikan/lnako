const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lnako = b.addModule("lnako", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "lnako",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag == .linux,
            .imports = &.{.{ .name = "lnako", .module = lnako }},
        }),
    });
    b.installArtifact(exe);

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

    const test_step = b.step("test", "全ての単体テストを実行する");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const fmt_step = b.step("fmt-check", "Zigソースのフォーマットを検査する");
    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "tools" },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
}
