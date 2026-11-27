//! `lnako sync` の v1 経路（薄い CLI アダプタ）。
//!
//! 実体は `lnako.package.v1_client`。ここは診断の描画、`--json`、警告の
//! 表示だけを行う。旧 lock/sync の実装には触れない。

const std = @import("std");
const lnako = @import("lnako");

const client = lnako.package.v1_client;
const diag = lnako.package.diagnostics;

pub const Options = struct {
    project_root: []const u8,
    /// 所有権は `client.run` へ移る（成功時 Report、失敗時 client が close）。
    project_dir: std.Io.Dir,
    fixture_root: []const u8,
    registry_url: []const u8,
    profile: ?[]const u8 = null,
    runtime: ?client.Runtime = null,
    features: []const []const u8 = &.{},
    no_default_features: bool = false,
    locked: bool = false,
    source_permissions: []const client.SourcePermission = &.{},
    environ_map: ?*const std.process.Environ.Map = null,
    json: bool = false,
};

/// v1 pipeline を実行する。失敗時は診断を stderr に描画してから error を返す。
pub fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var diagnostics = diag.List.init(allocator);
    defer diagnostics.deinit();

    var report = client.run(allocator, io, .{
        .project_root = options.project_root,
        .project_dir = options.project_dir,
        .fixture_root = options.fixture_root,
        .registry_url = options.registry_url,
        .profile = options.profile,
        .runtime = options.runtime,
        .features = options.features,
        .no_default_features = options.no_default_features,
        .locked = options.locked,
        .source_permissions = options.source_permissions,
        .environ_map = options.environ_map,
    }, &diagnostics) catch |err| {
        if (diagnostics.errorCount() > 0) {
            diagnostics.render(stderr, options.project_root) catch {};
            stderr.flush() catch {};
        }
        return err;
    };
    defer report.deinit();

    for (report.warnings) |warning| {
        try stderr.print("sync: 警告: {s}\n", .{warning});
    }

    if (options.json) {
        try stdout.writeAll(report.environment_json);
        try stdout.flush();
        return;
    }

    try stderr.print("sync: v1 で {d} 個の package を世代 {s} として構築しました（profile {s}, lock {s}）\n", .{
        report.package_count,
        report.generation,
        report.profile,
        if (report.lock_wrote) "更新" else "維持",
    });
    if (report.reused_environment) {
        try stderr.writeAll("sync: 既存の .nako/v1 世代を再利用しました\n");
    }
    try stderr.flush();
}
