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
            .imports = &.{.{ .name = "lnako", .module = lnako }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "lnakoを実行する");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const module_tests = b.addTest(.{ .root_module = lnako });
    const run_module_tests = b.addRunArtifact(module_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "全ての単体テストを実行する");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const fmt_step = b.step("fmt-check", "Zigソースのフォーマットを検査する");
    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "src" },
        .check = true,
    });
    fmt_step.dependOn(&fmt.step);
}
