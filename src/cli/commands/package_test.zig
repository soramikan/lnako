//! `lnako package publish` の公開前検証（dry-run）・再実行の冪等性・
//! static registry への publish 経路の統合テスト。
//!
//! HTTP はテスト内の `registry_fixture.Server` のみを使い、外部
//! ネットワークへは接続しない。`publish.run` は CLI と同じ core で、
//! fixture が受理した PUT の method/path/body/認証ヘッダを直接観測する。

const std = @import("std");
const testing = std.testing;
const io = std.testing.io;

const lnako = @import("lnako");
const diag = lnako.package.diagnostics;
const fetch = lnako.package.fetch;
const npkg_build = lnako.package.npkg_build;
const publish = lnako.package.publish;
const registry = lnako.package.registry;

const package_cmd = @import("package.zig");
const project_cmd = @import("project.zig");
const registry_fixture = @import("registry_fixture.zig");
const RegistryServer = registry_fixture.Server;
const RegistryRoute = registry_fixture.Route;
const RegistryHeader = registry_fixture.Header;

/// `pkg_name/src/index.nako3` と `[exports]` を持つ package root を作る。
fn writePackage(a: std.mem.Allocator, temporary: *std.testing.TmpDir, dir_name: []const u8, pkg_name: []const u8) ![]const u8 {
    try temporary.dir.createDirPath(io, try std.fmt.allocPrint(a, "{s}/src", .{dir_name}));
    const manifest = try std.fmt.allocPrint(a,
        \\[package]
        \\name = "{s}"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "main"
        \\path = "src/index.nako3"
        \\
    , .{pkg_name});
    const manifest_path = try std.fmt.allocPrint(a, "{s}/nako.toml", .{dir_name});
    try temporary.dir.writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
    const index_path = try std.fmt.allocPrint(a, "{s}/src/index.nako3", .{dir_name});
    try temporary.dir.writeFile(io, .{ .sub_path = index_path, .data = "●公開挨拶とは\nここまで\n" });
    return temporary.dir.realPathFileAlloc(io, dir_name, a);
}

/// 既存 fixture の `nako.toml` を書き換える（lock 不整合・検証失敗の作成用）。
fn rewriteManifest(a: std.mem.Allocator, root: []const u8, body: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ root, "nako.toml" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });
}

/// `lnako lock` と同じ経路で nako.lock を生成する。
fn writeLock(a: std.mem.Allocator, root: []const u8) !void {
    var environ = std.process.Environ.Map.init(a);
    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    try project_cmd.runIn(a, io, "lock", &.{}, root, &environ, &out.writer, &err.writer);
}

fn validOptions(root: []const u8, registry_url: []const u8) publish.Options {
    return .{
        .root = root,
        .registry_url = registry_url,
        .owner = "soramikan",
        .token = "test-token",
    };
}

test "package publish dry-run は未公開を報告し、registry へ送信しない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    try server.serve(&.{});

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try publish.run(a, io, validOptions(root, server.base_url.?), &diagnostics);
    defer report.deinit();

    try testing.expectEqual(publish.Status.unpublished, report.status);
    try testing.expectEqualStrings("demo", report.name);
    try testing.expectEqualStrings("1.0.0", report.version_text);
    try testing.expectEqualStrings("soramikan", report.owner);
    try testing.expectEqual(@as(usize, 64), report.artifact_sha256.len);
    try testing.expect(report.artifact_size > 0);
    try testing.expect(report.files >= 2);
    // version record の GET 1 回だけ。PUT は無い。
    try testing.expectEqual(@as(usize, 1), server.requestCount());
    try testing.expectEqual(@as(usize, 0), server.countCaptures("PUT"));

    var out = std.Io.Writer.Allocating.init(a);
    try publish.renderSummary(&report, &out.writer);
    const summary = out.written();
    try testing.expect(std.mem.indexOf(u8, summary, "状態: 未公開") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "dry-run のため送信しません") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "auth: Bearer") != null);
}

test "package publish は registry 未設定・認証不足・不正 URL を明示エラーにする" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();

    try testing.expectError(error.RegistryRequired, publish.run(a, io, .{ .token = "t" }, &diagnostics));
    try testing.expectError(error.AuthRequired, publish.run(a, io, .{ .registry_url = "http://127.0.0.1:1", .owner = "soramikan" }, &diagnostics));
    try testing.expectError(error.InvalidRegistry, publish.run(a, io, .{ .registry_url = "ftp://example.com/registry", .owner = "soramikan", .token = "t" }, &diagnostics));
    // loopback 以外の平文 http は既定で拒否する。
    try testing.expectError(error.InvalidRegistry, publish.run(a, io, .{ .registry_url = "http://registry.example.com", .owner = "soramikan", .token = "t" }, &diagnostics));
    // ヘッダへ載せられない token は送信前に拒否する。
    try testing.expectError(error.InvalidAuth, publish.run(a, io, .{ .registry_url = "http://127.0.0.1:1", .owner = "soramikan", .token = "bad\ntoken" }, &diagnostics));
}

test "package publish は lock 不在・lock 不整合を拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");

    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    try testing.expectError(error.LockMissing, publish.run(a, io, validOptions(root, server.base_url.?), &diagnostics));

    try writeLock(a, root);
    // manifest を書き換えると lock の manifestSha256 と一致しなくなる。
    try rewriteManifest(a, root,
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\description = "changed after lock"
        \\
        \\[[exports]]
        \\name = "main"
        \\path = "src/index.nako3"
        \\
    );
    try testing.expectError(error.LockMismatch, publish.run(a, io, validOptions(root, server.base_url.?), &diagnostics));
    try testing.expectEqual(@as(usize, 0), server.requestCount());
}

test "package publish は .npkg 検証失敗を診断付きで拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    // lock 生成後に export 先のファイルを欠落させ、publish の `.npkg`
    // 生成段階で失敗させる（manifest 自体は有効なまま）。
    try writeLock(a, root);
    const index_path = try std.fs.path.join(a, &.{ root, "src/index.nako3" });
    try std.Io.Dir.cwd().deleteFile(io, index_path);

    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    try testing.expectError(error.InvalidPackage, publish.run(a, io, validOptions(root, server.base_url.?), &diagnostics));
    try testing.expect(diagnostics.errorCount() > 0);
    try testing.expectEqual(@as(usize, 0), server.requestCount());
}

test "package publish は artifact と version record を PUT し、再実行を同一 hash でスキップする" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    var server = RegistryServer{ .io = io, .allocator = a, .echo_puts = true };
    try server.listen();
    defer server.stop();
    const artifact_path = "/soramikan/demo/1.0.0/demo-1.0.0.npkg";
    const record_path = "/soramikan/demo/1.0.0.json";
    const routes = [_]RegistryRoute{
        .{ .method = "PUT", .path = artifact_path, .status = 201 },
        .{ .method = "PUT", .path = record_path, .status = 201 },
    };
    try server.serve(&routes);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = validOptions(root, server.base_url.?);
    options.dry_run = false;
    var first = try publish.run(a, io, options, &diagnostics);
    defer first.deinit();
    try testing.expectEqual(publish.Status.uploaded, first.status);
    // GET（未公開）+ artifact PUT + record PUT。
    try testing.expectEqual(@as(usize, 3), server.requestCount());
    try testing.expectEqual(@as(usize, 2), server.countCaptures("PUT"));

    const artifact_request = server.findCapture("PUT", artifact_path).?;
    try testing.expectEqualStrings("Bearer test-token", artifact_request.authorization.?);
    try testing.expectEqualStrings("application/octet-stream", artifact_request.content_type.?);
    // 送信した bytes は公開前検証した `.npkg` と同一。
    var built = try npkg_build.build(a, io, root, &diagnostics, .{});
    defer built.deinit();
    try testing.expectEqualSlices(u8, built.archive, artifact_request.body);

    const record_request = server.findCapture("PUT", record_path).?;
    try testing.expectEqualStrings("application/json", record_request.content_type.?);
    var parse_session = fetch.Session.init(a, io, .{});
    defer parse_session.deinit();
    const record = try registry.parseVersionRecordBytes(&parse_session, record_request.body, "http://fixture/record");
    try testing.expectEqualStrings("1.0.0", record.version);
    try testing.expectEqual(@as(usize, 1), record.artifacts.len);
    try testing.expectEqualStrings(record.artifacts[0].sha256.?, try std.fmt.allocPrint(a, "sha256:{s}", .{first.artifact_sha256}));

    // 再実行: version record が echo され、PUT は増えない。
    var diagnostics2 = diag.List.init(a);
    defer diagnostics2.deinit();
    var second = try publish.run(a, io, options, &diagnostics2);
    defer second.deinit();
    try testing.expectEqual(publish.Status.published, second.status);
    try testing.expectEqual(@as(usize, 2), server.countCaptures("PUT"));
    try testing.expectEqual(@as(usize, 4), server.requestCount());
    try testing.expectEqualStrings(first.artifact_sha256, second.artifact_sha256);

    var out = std.Io.Writer.Allocating.init(a);
    try publish.renderSummary(&second, &out.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "状態: 公開済み") != null);
}

test "package publish は同一版・異なる hash を競合として拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    const record_body =
        \\{"schemaVersion":1,"version":"1.0.0","manifestHash":"sha256:0000000000000000000000000000000000000000000000000000000000000000","yanked":false,"dependencies":[],"features":[],"artifacts":{"source":{"kind":"source","type":".npkg","sha256":"sha256:1111111111111111111111111111111111111111111111111111111111111111","url":"http://fixture/demo.npkg"}}}
    ;
    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    const routes = [_]RegistryRoute{.{ .path = "/soramikan/demo/1.0.0.json", .body = record_body }};
    try server.serve(&routes);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = validOptions(root, server.base_url.?);
    options.dry_run = false;
    try testing.expectError(error.VersionConflict, publish.run(a, io, options, &diagnostics));
    try testing.expectEqual(@as(usize, 0), server.countCaptures("PUT"));
}

test "package publish は送信失敗を保持し、再実行で復旧する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    var failing = RegistryServer{ .io = io, .allocator = a };
    try failing.listen();
    defer failing.stop();
    const failing_url = try a.dupe(u8, failing.base_url.?);
    const artifact_path = "/soramikan/demo/1.0.0/demo-1.0.0.npkg";
    const record_path = "/soramikan/demo/1.0.0.json";
    const failing_routes = [_]RegistryRoute{
        .{ .method = "PUT", .path = artifact_path, .status = 500 },
        .{ .method = "PUT", .path = record_path, .status = 201 },
    };
    try failing.serve(&failing_routes);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = validOptions(root, failing_url);
    options.dry_run = false;
    var failed_report = try publish.run(a, io, options, &diagnostics);
    defer failed_report.deinit();
    try testing.expectEqual(publish.Status.failed, failed_report.status);
    try testing.expect(failed_report.failure != null);
    try testing.expect(std.mem.indexOf(u8, failed_report.failure.?, "HTTP 500") != null);
    // artifact PUT の失敗で停止し、record は送らない（部分登録を残さない）。
    try testing.expectEqual(@as(usize, 1), failing.countCaptures("PUT"));
    try testing.expectEqual(@as(usize, 0), serverCapturesFor(&failing, "PUT", record_path));
    var failed_out = std.Io.Writer.Allocating.init(a);
    try publish.renderSummary(&failed_report, &failed_out.writer);
    try testing.expect(std.mem.indexOf(u8, failed_out.written(), "状態: 失敗") != null);

    // 同じ版・同じ artifact で再実行すると、未公開のまま成功へ収束する。
    var healthy = RegistryServer{ .io = io, .allocator = a, .echo_puts = true };
    try healthy.listen();
    defer healthy.stop();
    const healthy_routes = [_]RegistryRoute{
        .{ .method = "PUT", .path = artifact_path, .status = 201 },
        .{ .method = "PUT", .path = record_path, .status = 201 },
    };
    try healthy.serve(&healthy_routes);
    var diagnostics2 = diag.List.init(a);
    defer diagnostics2.deinit();
    var retry_options = validOptions(root, healthy.base_url.?);
    retry_options.dry_run = false;
    var retried = try publish.run(a, io, retry_options, &diagnostics2);
    defer retried.deinit();
    try testing.expectEqual(publish.Status.uploaded, retried.status);
    try testing.expectEqual(@as(usize, 2), healthy.countCaptures("PUT"));
}

fn serverCapturesFor(server: *RegistryServer, method: []const u8, path: []const u8) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < server.captureCount()) : (index += 1) {
        const request = server.captureAt(index).?;
        if (std.mem.eql(u8, request.method, method) and std.mem.eql(u8, request.path, path)) count += 1;
    }
    return count;
}

test "package publish CLI は環境変数の registry 設定を使う" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    try server.serve(&.{});

    var environ = std.process.Environ.Map.init(a);
    try environ.put("LNAKO_REGISTRY", server.base_url.?);
    try environ.put("LNAKO_REGISTRY_OWNER", "soramikan");
    try environ.put("LNAKO_REGISTRY_TOKEN", "test-token");
    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "publish", root }, &environ, &out.writer, &err.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "状態: 未公開") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "registry: ") != null);
    try testing.expectEqual(@as(usize, 0), server.countCaptures("PUT"));
}

test "package publish は owner の形式を検証する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    try server.serve(&.{});

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = validOptions(root, server.base_url.?);
    options.owner = "bad/owner";
    try testing.expectError(error.InvalidRegistry, publish.run(a, io, options, &diagnostics));
    try testing.expectEqual(@as(usize, 0), server.requestCount());
}

test "package publish は index.json から owner を解決し、曖昧・未収録なら明示を要求する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    const index_body =
        \\{"schemaVersion":1,"packages":[{"schemaVersion":1,"id":"pkg:00000000000000000000000000000000","name":"demo","owner":"octo","versions":[]}]}
    ;
    var resolved_server = RegistryServer{ .io = io, .allocator = a };
    try resolved_server.listen();
    defer resolved_server.stop();
    const resolved_routes = [_]RegistryRoute{.{ .path = "/index.json", .body = index_body }};
    try resolved_server.serve(&resolved_routes);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = validOptions(root, resolved_server.base_url.?);
    options.owner = null;
    var report = try publish.run(a, io, options, &diagnostics);
    defer report.deinit();
    try testing.expectEqualStrings("octo", report.owner);
    // index の GET と version record の GET。
    try testing.expectEqual(@as(usize, 2), resolved_server.requestCount());

    // 同名が複数 owner に存在する index は、誤送信を避けるため明示指定を要求する。
    const ambiguous_body =
        \\{"schemaVersion":1,"packages":[{"schemaVersion":1,"id":"pkg:00000000000000000000000000000000","name":"demo","owner":"octo","versions":[]},{"schemaVersion":1,"id":"pkg:11111111111111111111111111111111","name":"demo","owner":"other","versions":[]}]}
    ;
    var ambiguous_server = RegistryServer{ .io = io, .allocator = a };
    try ambiguous_server.listen();
    defer ambiguous_server.stop();
    const ambiguous_routes = [_]RegistryRoute{.{ .path = "/index.json", .body = ambiguous_body }};
    try ambiguous_server.serve(&ambiguous_routes);
    var ambiguous_diagnostics = diag.List.init(a);
    defer ambiguous_diagnostics.deinit();
    var ambiguous_options = validOptions(root, ambiguous_server.base_url.?);
    ambiguous_options.owner = null;
    try testing.expectError(error.OwnerRequired, publish.run(a, io, ambiguous_options, &ambiguous_diagnostics));

    // index 未収録（404）も明示指定を要求する。
    var missing_server = RegistryServer{ .io = io, .allocator = a };
    try missing_server.listen();
    defer missing_server.stop();
    try missing_server.serve(&.{});
    var missing_diagnostics = diag.List.init(a);
    defer missing_diagnostics.deinit();
    var missing_options = validOptions(root, missing_server.base_url.?);
    missing_options.owner = null;
    try testing.expectError(error.OwnerRequired, publish.run(a, io, missing_options, &missing_diagnostics));
}

test "package publish は record 送信失敗後も再実行で復旧する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    const artifact_path = "/soramikan/demo/1.0.0/demo-1.0.0.npkg";
    const record_path = "/soramikan/demo/1.0.0.json";
    // artifact は成功し record だけ失敗する。artifact は送信済みだが
    // record が無いため、再実行時は未公開として同じ artifact を再送する。
    var failing = RegistryServer{ .io = io, .allocator = a };
    try failing.listen();
    defer failing.stop();
    const failing_routes = [_]RegistryRoute{
        .{ .method = "PUT", .path = artifact_path, .status = 201 },
        .{ .method = "PUT", .path = record_path, .status = 500 },
    };
    try failing.serve(&failing_routes);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = validOptions(root, failing.base_url.?);
    options.dry_run = false;
    var failed_report = try publish.run(a, io, options, &diagnostics);
    defer failed_report.deinit();
    try testing.expectEqual(publish.Status.failed, failed_report.status);
    try testing.expect(std.mem.indexOf(u8, failed_report.failure.?, "version record") != null);
    try testing.expect(std.mem.indexOf(u8, failed_report.failure.?, "HTTP 500") != null);
    try testing.expectEqual(@as(usize, 1), serverCapturesFor(&failing, "PUT", artifact_path));
    try testing.expectEqual(@as(usize, 1), serverCapturesFor(&failing, "PUT", record_path));

    var healthy = RegistryServer{ .io = io, .allocator = a, .echo_puts = true };
    try healthy.listen();
    defer healthy.stop();
    const healthy_routes = [_]RegistryRoute{
        .{ .method = "PUT", .path = artifact_path, .status = 201 },
        .{ .method = "PUT", .path = record_path, .status = 201 },
    };
    try healthy.serve(&healthy_routes);
    var retry_diagnostics = diag.List.init(a);
    defer retry_diagnostics.deinit();
    var retry_options = validOptions(root, healthy.base_url.?);
    retry_options.dry_run = false;
    var retried = try publish.run(a, io, retry_options, &retry_diagnostics);
    defer retried.deinit();
    try testing.expectEqual(publish.Status.uploaded, retried.status);
    // 再実行時は GET 404 のあと artifact と record の 2 PUT。
    try testing.expectEqual(@as(usize, 2), healthy.countCaptures("PUT"));
    try testing.expectEqual(@as(usize, 3), healthy.captureCount());
}

test "package publish は registry 照会の HTTP 失敗を送信前に拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    const routes = [_]RegistryRoute{
        .{ .path = "/soramikan/demo/1.0.0.json", .status = 500 },
    };
    try server.serve(&routes);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = validOptions(root, server.base_url.?);
    options.dry_run = false;
    try testing.expectError(error.RegistryUnavailable, publish.run(a, io, options, &diagnostics));
    try testing.expect(diagnostics.errorCount() > 0);
    try testing.expectEqual(@as(usize, 0), server.countCaptures("PUT"));
}

test "package publish は cross-origin redirect で Bearer token を再送しない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    // redirect 先（別 authority）。version record は 404 のまま。
    var other = RegistryServer{ .io = io, .allocator = a };
    try other.listen();
    defer other.stop();
    try other.serve(&.{});
    const other_url = try std.fmt.allocPrint(a, "{s}/record", .{other.base_url.?});

    var registry_server = RegistryServer{ .io = io, .allocator = a };
    try registry_server.listen();
    defer registry_server.stop();
    const redirect_headers = [_]RegistryHeader{.{ .name = "location", .value = other_url }};
    const routes = [_]RegistryRoute{
        .{ .path = "/soramikan/demo/1.0.0.json", .status = 302, .headers = &redirect_headers },
    };
    try registry_server.serve(&routes);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try publish.run(a, io, validOptions(root, registry_server.base_url.?), &diagnostics);
    defer report.deinit();
    try testing.expectEqual(publish.Status.unpublished, report.status);

    // 同一 authority の初回 GET には Bearer を送り、redirect 先には送らない。
    const initial = registry_server.findCapture("GET", "/soramikan/demo/1.0.0.json").?;
    try testing.expectEqualStrings("Bearer test-token", initial.authorization.?);
    const redirected = other.findCapture("GET", "/record").?;
    try testing.expect(redirected.authorization == null);
}

test "package publish は同一 authority redirect で Bearer token を維持する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    try writeLock(a, root);

    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    const target = try std.fmt.allocPrint(a, "{s}/record", .{server.base_url.?});
    const redirect_headers = [_]RegistryHeader{.{ .name = "location", .value = target }};
    const routes = [_]RegistryRoute{
        .{ .path = "/soramikan/demo/1.0.0.json", .status = 302, .headers = &redirect_headers },
    };
    try server.serve(&routes);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var report = try publish.run(a, io, validOptions(root, server.base_url.?), &diagnostics);
    defer report.deinit();
    try testing.expectEqual(publish.Status.unpublished, report.status);

    // 同一 authority の redirect では Bearer を維持する。
    const redirected = server.findCapture("GET", "/record").?;
    try testing.expectEqualStrings("Bearer test-token", redirected.authorization.?);
}

test "package publish は --allow-plaintext-http 指定時に非 loopback 平文 http を設定エラーにしない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(io, "empty");
    const empty_root = try temporary.dir.realPathFileAlloc(io, "empty", a);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    // registry 設定は通過し、project 不在で止まる（InvalidRegistry ではない）。
    try testing.expectError(error.ProjectNotFound, publish.run(a, io, .{
        .root = empty_root,
        .registry_url = "http://registry.example.com",
        .owner = "soramikan",
        .token = "test-token",
        .allow_plaintext_http = true,
    }, &diagnostics));
    try testing.expectEqual(@as(usize, 0), diagnostics.errorCount());
}

test "package publish は id 宣言ありで index 未収録のとき name 一致の別 owner を採用しない" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writePackage(a, &temporary, "demo", "demo");
    // 自 package の Public ID を宣言してから lock する。
    try rewriteManifest(a, root,
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\id = "pkg:22222222222222222222222222222222"
        \\
        \\[[exports]]
        \\name = "main"
        \\path = "src/index.nako3"
        \\
    );
    try writeLock(a, root);

    // index には同名・別 id の package だけが存在する（自 id は未収録）。
    const index_body =
        \\{"schemaVersion":1,"packages":[{"schemaVersion":1,"id":"pkg:11111111111111111111111111111111","name":"demo","owner":"other","versions":[]}]}
    ;
    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    const routes = [_]RegistryRoute{.{ .path = "/index.json", .body = index_body }};
    try server.serve(&routes);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = validOptions(root, server.base_url.?);
    options.owner = null;
    try testing.expectError(error.OwnerRequired, publish.run(a, io, options, &diagnostics));
    try testing.expectEqual(@as(usize, 0), server.countCaptures("PUT"));
}
