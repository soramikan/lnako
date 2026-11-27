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
const package_v1_cli = @import("package_v1_cli.zig");
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
    // 旧 package publish の内部テスト fixture は旧 lock を必要とする。
    // 公開入口の guard とは別の内部処理テスト入口を使う。
    try project_cmd.runInLegacyInternalForTest(a, io, "lock", &.{}, root, &environ, &out.writer, &err.writer);
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
        // publish は version record の公開後に index.json へ package を登録する。
        .{ .method = "PUT", .path = "/index.json", .status = 204 },
    };
    try server.serve(&routes);

    var diagnostics = diag.List.init(a);
    defer diagnostics.deinit();
    var options = validOptions(root, server.base_url.?);
    options.dry_run = false;
    var first = try publish.run(a, io, options, &diagnostics);
    defer first.deinit();
    try testing.expectEqual(publish.Status.uploaded, first.status);
    // GET（未公開）+ artifact PUT + record PUT + index GET + index PUT。
    try testing.expectEqual(@as(usize, 5), server.requestCount());
    try testing.expectEqual(@as(usize, 3), server.countCaptures("PUT"));

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
    // 再実行でも index 登録は通す（索引登録だけ失敗して中断した公開を
    // 再試行できるようにするため）。登録は冪等なので内容は変わらない。
    try testing.expectEqual(@as(usize, 4), server.countCaptures("PUT"));
    try testing.expectEqual(@as(usize, 8), server.requestCount());
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
        .{ .method = "PUT", .path = "/index.json", .status = 204 },
    };
    try healthy.serve(&healthy_routes);
    var diagnostics2 = diag.List.init(a);
    defer diagnostics2.deinit();
    var retry_options = validOptions(root, healthy.base_url.?);
    retry_options.dry_run = false;
    var retried = try publish.run(a, io, retry_options, &diagnostics2);
    defer retried.deinit();
    try testing.expectEqual(publish.Status.uploaded, retried.status);
    // artifact・record・index の 3 PUT。
    try testing.expectEqual(@as(usize, 3), healthy.countCaptures("PUT"));
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

test "package publish CLI は v1 で旧 static PUT を対象外にする" {
    // CLI は旧経路へ接続せず、P07 の公開 API と代替手順を示して終了する。
    // std.process.exit を伴うため、文言の契約だけをここで固定する。
    try testing.expect(std.mem.indexOf(u8, package_v1_cli.publish_out_of_scope_message, "対象外") != null);
    try testing.expect(std.mem.indexOf(u8, package_v1_cli.publish_out_of_scope_message, "POST /v1/packages/{scope}/{name}/releases") != null);
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
        .{ .method = "PUT", .path = "/index.json", .status = 204 },
    };
    try healthy.serve(&healthy_routes);
    var retry_diagnostics = diag.List.init(a);
    defer retry_diagnostics.deinit();
    var retry_options = validOptions(root, healthy.base_url.?);
    retry_options.dry_run = false;
    var retried = try publish.run(a, io, retry_options, &retry_diagnostics);
    defer retried.deinit();
    try testing.expectEqual(publish.Status.uploaded, retried.status);
    // 再実行時は GET 404 + artifact PUT + record PUT + index GET + index PUT。
    try testing.expectEqual(@as(usize, 3), healthy.countCaptures("PUT"));
    try testing.expectEqual(@as(usize, 5), healthy.captureCount());
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

/// `plugin.mjs` を公開する ESM-only package root を作る。`compat_js_profile`
/// が真なら `compat-js = true` の profile を宣言する。
fn writeEsmPackage(a: std.mem.Allocator, temporary: *std.testing.TmpDir, dir_name: []const u8, pkg_name: []const u8, compat_js_profile: bool) ![]const u8 {
    const profile_section =
        \\
        \\[profiles.compat]
        \\runtime = "lnako"
        \\os = "linux"
        \\cpu = "x86_64"
        \\abi = "gnu"
        \\compat-js = true
        \\
    ;
    const manifest = if (compat_js_profile)
        try std.fmt.allocPrint(a,
            \\[package]
            \\name = "{s}"
            \\version = "1.0.0"
            \\license = "MIT"
            \\
        ++
            profile_section ++
            \\
            \\[[exports]]
            \\name = "main"
            \\esm = "plugin.mjs"
            \\
        , .{pkg_name})
    else
        try std.fmt.allocPrint(a,
            \\[package]
            \\name = "{s}"
            \\version = "1.0.0"
            \\license = "MIT"
            \\
            \\[[exports]]
            \\name = "main"
            \\esm = "plugin.mjs"
            \\
        , .{pkg_name});
    try temporary.dir.createDirPath(io, dir_name);
    const manifest_path = try std.fmt.allocPrint(a, "{s}/nako.toml", .{dir_name});
    try temporary.dir.writeFile(io, .{ .sub_path = manifest_path, .data = manifest });
    const plugin_path = try std.fmt.allocPrint(a, "{s}/plugin.mjs", .{dir_name});
    try temporary.dir.writeFile(io, .{ .sub_path = plugin_path, .data = "export default {};\n" });
    return temporary.dir.realPathFileAlloc(io, dir_name, a);
}

test "package publish は compat-js profile の ESM package を受理し、無宣言は E006 で拒否する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var server = RegistryServer{ .io = io, .allocator = a };
    try server.listen();
    defer server.stop();
    try server.serve(&.{});

    // compat-js = true の profile を持つ ESM-only package は公開検証を通す。
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const root = try writeEsmPackage(a, &temporary, "esm-pkg", "esm-pkg", true);
        try writeLock(a, root);
        var diagnostics = diag.List.init(a);
        defer diagnostics.deinit();
        var report = try publish.run(a, io, validOptions(root, server.base_url.?), &diagnostics);
        defer report.deinit();
        try testing.expectEqual(publish.Status.unpublished, report.status);
        try testing.expectEqual(@as(usize, 0), server.countCaptures("PUT"));
    }

    // profile 無し（compat-js 無宣言）の ESM-only package は E006 で拒否する。
    {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const root = try writeEsmPackage(a, &temporary, "esm-pkg-plain", "esm-pkg-plain", false);
        try writeLock(a, root);
        var diagnostics = diag.List.init(a);
        defer diagnostics.deinit();
        try testing.expectError(error.InvalidPackage, publish.run(a, io, validOptions(root, server.base_url.?), &diagnostics));
        try testing.expect(diagnostics.find(diag.E006_JS_IN_NORMAL_MODE) != null);
        try testing.expectEqual(@as(usize, 0), server.countCaptures("PUT"));
    }
}

// ---- v1 CLI（package build/pack.zig と verify）の統合テスト ----
//
// v1 の manifest は schema_version = 1、[package] の id/version/license、
// マップ形式の [exports]、[artifacts.*] を持つ。旧形式は読み替えない。

const v1_archive = lnako.package.v1_archive;
const v1_cross = lnako.package.v1_cross;
const v1_manifest = lnako.package.v1_manifest;
const v1_selection = lnako.package.v1_selection;
const v1_types = lnako.package.v1_types;
const v1_zip = lnako.package.v1_zip;

const V1_UNIVERSAL =
    \\schema_version = 1
    \\
    \\[package]
    \\id = "@example/demo"
    \\version = "1.0.0"
    \\license = "MIT"
    \\capabilities = ["pure-nako"]
    \\
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "scoped" }
    \\
    \\[artifacts.universal]
    \\include = ["src/**/*.nako3"]
    \\
;

const V1_ESM =
    \\schema_version = 1
    \\
    \\[package]
    \\id = "@example/demo"
    \\version = "1.0.0"
    \\license = "MIT"
    \\capabilities = ["pure-nako"]
    \\
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "scoped" }
    \\
    \\[artifacts.esm]
    \\runtimes = ["cnako", "wnako"]
    \\entry = "dist/esm/index.js"
    \\include = ["dist/esm/**/*"]
    \\
;

const V1_NATIVE =
    \\schema_version = 1
    \\
    \\[package]
    \\id = "@example/native"
    \\version = "2.0.0"
    \\license = "MIT"
    \\capabilities = ["native"]
    \\
    \\[exports]
    \\"." = { entry = "src/main.nako3", binding = "scoped" }
    \\
    \\[artifacts.universal]
    \\include = ["src/**/*.nako3"]
    \\
    \\[artifacts.native]
    \\abi_version = 1
    \\source_include = ["native/**/*"]
    \\
;

/// `dir/path` を必要なら親ディレクトリごと書く。
fn writeV1File(
    a: std.mem.Allocator,
    temporary: *std.testing.TmpDir,
    dir_name: []const u8,
    path: []const u8,
    data: []const u8,
) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try temporary.dir.createDirPath(io, try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_name, parent }));
    }
    try temporary.dir.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir_name, path }),
        .data = data,
    });
}

fn writeV1Project(
    a: std.mem.Allocator,
    temporary: *std.testing.TmpDir,
    dir_name: []const u8,
    manifest: []const u8,
) ![]const u8 {
    try temporary.dir.createDirPath(io, dir_name);
    try temporary.dir.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/nako.toml", .{dir_name}),
        .data = manifest,
    });
    return temporary.dir.realPathFileAlloc(io, dir_name, a);
}

fn readV1File(a: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(32 * 1024 * 1024));
}

test "package build v1: universal を生成し、verify が §3 の構造検証を通す" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writeV1Project(a, &temporary, "demo", V1_UNIVERSAL);
    try writeV1File(a, &temporary, "demo", "src/main.nako3", "●公開挨拶とは\nここまで\n");
    const archive_path = try std.fmt.allocPrint(a, "{s}/demo.npkg", .{root});

    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "build", root, "-o", archive_path }, null, &out.writer, &err.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "@example/demo 1.0.0 の universal アーティファクト") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "sha256:") != null);

    const bytes = try readV1File(a, archive_path);
    var verified = try v1_archive.verify(a, bytes);
    defer verified.deinit();
    try testing.expectEqualStrings("@example/demo", verified.packageId());
    try testing.expectEqualStrings("1.0.0", verified.packageVersion());
    try testing.expectEqual(v1_types.Kind.universal, verified.artifactKind());
    try testing.expectEqual(@as(usize, 3), verified.runtimes().len);
    try testing.expect(verified.entryBytes("src/main.nako3") != null);
    const selected = try verified.selectedEntry(".");
    try testing.expect(std.mem.indexOf(u8, selected, "公開挨拶") != null);

    var out2 = std.Io.Writer.Allocating.init(a);
    var err2 = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "verify", archive_path }, null, &out2.writer, &err2.writer);
    try testing.expect(std.mem.indexOf(u8, out2.written(), "@example/demo 1.0.0（universal") != null);
    try testing.expect(std.mem.indexOf(u8, out2.written(), "検証 OK") != null);
}

test "package build v1: 同一入力の再ビルドで ZIP がバイト一致する（Z-12）" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writeV1Project(a, &temporary, "demo", V1_UNIVERSAL);
    try writeV1File(a, &temporary, "demo", "src/main.nako3", "●公開挨拶とは\nここまで\n");
    const first = try std.fmt.allocPrint(a, "{s}/a.npkg", .{root});
    const second = try std.fmt.allocPrint(a, "{s}/b.npkg", .{root});

    for ([_][]const u8{ first, second }) |path| {
        var out = std.Io.Writer.Allocating.init(a);
        var err = std.Io.Writer.Allocating.init(a);
        try package_cmd.run(a, io, &.{ "pack", root, "-o", path }, null, &out.writer, &err.writer);
    }
    const first_bytes = try readV1File(a, first);
    const second_bytes = try readV1File(a, second);
    try testing.expectEqualSlices(u8, first_bytes, second_bytes);
}

test "package build v1: ESM は --runtime と manifest の entry を反映する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writeV1Project(a, &temporary, "esm", V1_ESM);
    try writeV1File(a, &temporary, "esm", "dist/esm/index.js", "export default {};\n");
    const archive_path = try std.fmt.allocPrint(a, "{s}/esm.npkg", .{root});

    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(
        a,
        io,
        &.{ "build", root, "--kind", "esm", "--runtime", "cnako,wnako", "-o", archive_path },
        null,
        &out.writer,
        &err.writer,
    );
    try testing.expect(std.mem.indexOf(u8, out.written(), "の esm アーティファクト") != null);

    const bytes = try readV1File(a, archive_path);
    var verified = try v1_archive.verify(a, bytes);
    defer verified.deinit();
    try testing.expectEqual(v1_types.Kind.esm, verified.artifactKind());
    try testing.expectEqual(@as(usize, 2), verified.runtimes().len);
    try testing.expectEqualStrings("cnako", v1_types.runtimeName(verified.runtimes()[0]));
    try testing.expectEqualStrings("wnako", v1_types.runtimeName(verified.runtimes()[1]));
    try testing.expect(verified.entryBytes("dist/esm/index.js") != null);
}

test "package build v1: --commands で ESM の実JS entry に命令を明示できる" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writeV1Project(a, &temporary, "esm", V1_ESM);
    try writeV1File(a, &temporary, "esm", "dist/esm/index.js", "export default {};\n");
    const commands_text =
        \\{"schema_version":1,"exports_global_commands":false,"exports":{".":{"binding":"scoped","commands":[{"name":"JS挨拶","kind":"function","args":[]}],"constants":[]}}}
    ;
    try writeV1File(a, &temporary, "esm", "commands.json", commands_text);
    const commands_path = try std.fs.path.join(a, &.{ root, "commands.json" });
    const archive_path = try std.fmt.allocPrint(a, "{s}/esm-commands.npkg", .{root});

    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{
        "build",     root,          "--kind",     "esm",
        "--runtime", "cnako,wnako", "--commands", commands_path,
        "-o",        archive_path,
    }, null, &out.writer, &err.writer);
    try testing.expect(std.mem.indexOf(u8, out.written(), "の esm アーティファクト") != null);

    const bytes = try readV1File(a, archive_path);
    var verified = try v1_archive.verify(a, bytes);
    defer verified.deinit();
    const export_object = verified.commands.value.object.get("exports").?.object.get(".").?.object;
    const commands = export_object.get("commands").?.array.items;
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqualStrings("JS挨拶", commands[0].object.get("name").?.string);
}

test "package build v1: native-source は abi_version を記録する（Z-14）" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try writeV1Project(a, &temporary, "native", V1_NATIVE);
    try writeV1File(a, &temporary, "native", "src/main.nako3", "●公開挨拶とは\nここまで\n");
    try writeV1File(a, &temporary, "native", "native/build.zig", "// native\n");
    const archive_path = try std.fmt.allocPrint(a, "{s}/native.npkg", .{root});

    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(
        a,
        io,
        &.{ "build", root, "--kind", "native-source", "-o", archive_path },
        null,
        &out.writer,
        &err.writer,
    );
    const bytes = try readV1File(a, archive_path);
    var verified = try v1_archive.verify(a, bytes);
    defer verified.deinit();
    try testing.expectEqual(v1_types.Kind.@"native-source", verified.artifactKind());
    try testing.expectEqual(@as(u32, 1), verified.native().?.abi_version.?);
    try testing.expectEqual(@as(usize, 1), verified.runtimes().len);
    try testing.expectEqualStrings("lnako", v1_types.runtimeName(verified.runtimes()[0]));
}

test "package build v1: native-prebuilt は triple/ABI/glibc とライブラリを収録する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest =
        \\schema_version = 1
        \\
        \\[package]
        \\id = "@example/prebuilt"
        \\version = "3.0.0"
        \\license = "MIT"
        \\capabilities = ["native"]
        \\
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "scoped" }
        \\
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\
        \\[artifacts.native]
        \\abi_version = 1
        \\prebuilt_lib_name = "demo"
        \\
    ;
    const root = try writeV1Project(a, &temporary, "prebuilt", manifest);
    try writeV1File(a, &temporary, "prebuilt", "src/main.nako3", "●公開挨拶とは\nここまで\n");
    try writeV1File(a, &temporary, "prebuilt", "native/libdemo.so", "DUMMYLIB");
    const archive_path = try std.fmt.allocPrint(a, "{s}/prebuilt.npkg", .{root});

    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{
        "build",           root,
        "--kind",          "native-prebuilt",
        "--target-triple", "x86_64-linux-gnu",
        "--glibc-min",     "2.31",
        "--library-path",  "native/libdemo.so",
        "-o",              archive_path,
    }, null, &out.writer, &err.writer);

    const bytes = try readV1File(a, archive_path);
    var verified = try v1_archive.verify(a, bytes);
    defer verified.deinit();
    try testing.expectEqual(v1_types.Kind.@"native-prebuilt", verified.artifactKind());
    const native = verified.native().?;
    try testing.expectEqualStrings("x86_64-linux-gnu", native.target_triple.?);
    try testing.expectEqual(@as(u32, 1), native.abi_version.?);
    try testing.expectEqualStrings("2.31", native.glibc_min.?);
    try testing.expectEqualStrings("native/libdemo.so", native.library_path.?);
    try testing.expectEqualStrings("DUMMYLIB", verified.entryBytes("native/libdemo.so").?);
}

test "package build v1: native-prebuilt は prebuilt_lib_name からライブラリと入口を導出する" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest =
        \\schema_version = 1
        \\
        \\[package]
        \\id = "@example/prebuilt-derived"
        \\version = "3.0.0"
        \\license = "MIT"
        \\capabilities = ["native"]
        \\
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "scoped" }
        \\
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\
        \\[artifacts.native]
        \\abi_version = 1
        \\prebuilt_lib_name = "demo"
        \\
    ;
    const root = try writeV1Project(a, &temporary, "prebuilt-derived", manifest);
    try writeV1File(a, &temporary, "prebuilt-derived", "src/main.nako3", "●公開挨拶とは\nここまで\n");
    try writeV1File(a, &temporary, "prebuilt-derived", "native/libdemo.so", "DUMMY-ELF");
    const archive_path = try std.fmt.allocPrint(a, "{s}/prebuilt-derived.npkg", .{root});

    var out = std.Io.Writer.Allocating.init(a);
    var err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{
        "build",           root,
        "--kind",          "native-prebuilt",
        "--target-triple", "x86_64-linux-gnu",
        "--glibc-min",     "2.31",
        "-o",              archive_path,
    }, null, &out.writer, &err.writer);

    const bytes = try readV1File(a, archive_path);
    var verified = try v1_archive.verify(a, bytes);
    defer verified.deinit();
    const native = verified.native().?;
    try testing.expectEqualStrings("native/libdemo.so", native.library_path.?);
    try testing.expectEqualStrings("DUMMY-ELF", try verified.selectedEntry("."));
    try testing.expectEqualStrings("src/main.nako3", verified.metadata_model.exports[0].entry);
    try testing.expectEqual(@as(usize, 1), verified.metadata_model.artifact.entries.len);
    try testing.expectEqualStrings(".", verified.metadata_model.artifact.entries[0].subpath);
    try testing.expectEqualStrings("native/libdemo.so", verified.metadata_model.artifact.entries[0].path);
}

test "package pack/verify v1: native --commands と cross artifacts を保ち universal と prebuilt を選ぶ" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest =
        \\schema_version = 1
        \\
        \\[package]
        \\id = "@example/dual"
        \\version = "1.0.0"
        \\license = "MIT"
        \\capabilities = ["pure-nako", "native"]
        \\
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "global" }
        \\
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\
        \\[artifacts.native]
        \\abi_version = 1
        \\prebuilt_lib_name = "demo"
        \\
    ;
    const commands_text =
        \\{"schema_version":1,"exports_global_commands":true,"exports":{".":{"binding":"global","commands":[{"name":"公開挨拶","kind":"function","args":[]}],"constants":[]}}}
    ;
    const root = try writeV1Project(a, &temporary, "dual", manifest);
    try writeV1File(a, &temporary, "dual", "src/main.nako3", "●公開挨拶とは\nここまで\n");
    try writeV1File(a, &temporary, "dual", "native/libdemo.so", "DUMMY-ELF");
    try writeV1File(a, &temporary, "dual", "commands.json", commands_text);
    const commands_path = try std.fs.path.join(a, &.{ root, "commands.json" });
    const universal_path = try std.fmt.allocPrint(a, "{s}/dual-universal.npkg", .{root});
    const prebuilt_path = try std.fmt.allocPrint(a, "{s}/dual-prebuilt.npkg", .{root});

    var universal_out = std.Io.Writer.Allocating.init(a);
    var universal_err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "build", root, "-o", universal_path }, null, &universal_out.writer, &universal_err.writer);

    var prebuilt_out = std.Io.Writer.Allocating.init(a);
    var prebuilt_err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{
        "build",           root,
        "--kind",          "native-prebuilt",
        "--target-triple", "x86_64-linux-gnu",
        "--glibc-min",     "2.31",
        "--commands",      commands_path,
        "-o",              prebuilt_path,
    }, null, &prebuilt_out.writer, &prebuilt_err.writer);

    var cross_out = std.Io.Writer.Allocating.init(a);
    var cross_err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "verify", universal_path, prebuilt_path }, null, &cross_out.writer, &cross_err.writer);
    try testing.expect(std.mem.indexOf(u8, cross_out.written(), "クロス検証 OK（2 アーティファクト") != null);

    const universal_bytes = try readV1File(a, universal_path);
    var universal = try v1_archive.verify(a, universal_bytes);
    defer universal.deinit();
    try testing.expect(universal.native() == null);
    try testing.expectEqualStrings("●公開挨拶とは\nここまで\n", try universal.selectedEntry("."));
    try testing.expectEqual(@as(usize, 0), universal.metadata_model.artifact.entries.len);

    const prebuilt_bytes = try readV1File(a, prebuilt_path);
    var prebuilt = try v1_archive.verify(a, prebuilt_bytes);
    defer prebuilt.deinit();
    try testing.expectEqualStrings("native/libdemo.so", prebuilt.native().?.library_path.?);
    try testing.expectEqualStrings("DUMMY-ELF", try prebuilt.selectedEntry("."));
    try testing.expect(prebuilt.commands_model.exports_global_commands);
    const export_object = prebuilt.commands.value.object.get("exports").?.object.get(".").?.object;
    const commands = export_object.get("commands").?.array.items;
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqualStrings("公開挨拶", commands[0].object.get("name").?.string);

    const artifacts = [_]v1_types.Artifact{
        .{ .kind = .universal, .runtimes = &.{ .lnako, .cnako, .wnako } },
        .{
            .kind = .@"native-prebuilt",
            .runtimes = &.{.lnako},
            .target_triple = "x86_64-linux-gnu",
            .abi_version = 1,
            .glibc_min = "2.31",
        },
    };
    try testing.expectEqual(@as(usize, 1), try v1_selection.select(
        "@example/dual",
        &artifacts,
        v1_selection.Target.forLnako("x86_64-linux-gnu", .{ .min = 1, .max = 1 }, "2.31"),
        &.{},
    ));
    try testing.expectEqual(@as(usize, 0), try v1_selection.select(
        "@example/dual",
        &artifacts,
        v1_selection.Target.forLnako("aarch64-linux-gnu", .{ .min = 1, .max = 1 }, "2.31"),
        &.{},
    ));
    try testing.expectEqual(@as(usize, 0), try v1_selection.select(
        "@example/dual",
        &artifacts,
        v1_selection.Target.forLnako("x86_64-linux-gnu", .{ .min = 2, .max = 2 }, "2.31"),
        &.{},
    ));
    try testing.expectEqual(@as(usize, 0), try v1_selection.select(
        "@example/dual",
        &artifacts,
        v1_selection.Target.forLnako("x86_64-linux-gnu", .{ .min = 1, .max = 1 }, "2.17"),
        &.{},
    ));
    try testing.expectEqual(@as(usize, 0), try v1_selection.select(
        "@example/dual",
        &artifacts,
        v1_selection.Target.forRuntime(.cnako),
        &.{},
    ));
}

test "package pack/verify v1: ESM --commands と universal の cross artifacts を保ち cnako で ESM を選ぶ" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const manifest =
        \\schema_version = 1
        \\
        \\[package]
        \\id = "@example/dual-esm"
        \\version = "1.0.0"
        \\license = "MIT"
        \\capabilities = ["pure-nako"]
        \\
        \\[exports]
        \\"." = { entry = "src/main.nako3", binding = "global" }
        \\
        \\[artifacts.universal]
        \\include = ["src/**/*.nako3"]
        \\
        \\[artifacts.esm]
        \\runtimes = ["cnako", "wnako"]
        \\entry = "dist/esm/index.js"
        \\include = ["dist/esm/**/*"]
        \\
    ;
    const commands_text =
        \\{"schema_version":1,"exports_global_commands":true,"exports":{".":{"binding":"global","commands":[{"name":"公開挨拶","kind":"function","args":[]}],"constants":[]}}}
    ;
    const root = try writeV1Project(a, &temporary, "dual-esm", manifest);
    try writeV1File(a, &temporary, "dual-esm", "src/main.nako3", "●公開挨拶とは\nここまで\n");
    try writeV1File(a, &temporary, "dual-esm", "dist/esm/index.js", "export default {};\n");
    try writeV1File(a, &temporary, "dual-esm", "commands.json", commands_text);
    const commands_path = try std.fs.path.join(a, &.{ root, "commands.json" });
    const universal_path = try std.fmt.allocPrint(a, "{s}/dual-esm-universal.npkg", .{root});
    const esm_path = try std.fmt.allocPrint(a, "{s}/dual-esm-esm.npkg", .{root});

    var universal_out = std.Io.Writer.Allocating.init(a);
    var universal_err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "build", root, "-o", universal_path }, null, &universal_out.writer, &universal_err.writer);

    var esm_out = std.Io.Writer.Allocating.init(a);
    var esm_err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{
        "build",      root,
        "--kind",     "esm",
        "--commands", commands_path,
        "-o",         esm_path,
    }, null, &esm_out.writer, &esm_err.writer);

    var cross_out = std.Io.Writer.Allocating.init(a);
    var cross_err = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "verify", universal_path, esm_path }, null, &cross_out.writer, &cross_err.writer);
    try testing.expect(std.mem.indexOf(u8, cross_out.written(), "クロス検証 OK（2 アーティファクト") != null);

    const esm_bytes = try readV1File(a, esm_path);
    var esm = try v1_archive.verify(a, esm_bytes);
    defer esm.deinit();
    try testing.expectEqual(v1_types.Kind.esm, esm.artifactKind());
    try testing.expectEqualStrings("export default {};\n", try esm.selectedEntry("."));
    try testing.expect(esm.commands_model.exports_global_commands);
    const export_object = esm.commands.value.object.get("exports").?.object.get(".").?.object;
    const commands = export_object.get("commands").?.array.items;
    try testing.expectEqual(@as(usize, 1), commands.len);
    try testing.expectEqualStrings("公開挨拶", commands[0].object.get("name").?.string);

    const artifacts = [_]v1_types.Artifact{
        .{ .kind = .universal, .runtimes = &.{ .lnako, .cnako, .wnako } },
        .{ .kind = .esm, .runtimes = &.{ .cnako, .wnako } },
    };
    try testing.expectEqual(@as(usize, 1), try v1_selection.select(
        "@example/dual-esm",
        &artifacts,
        v1_selection.Target.forRuntime(.cnako),
        &.{},
    ));
    try testing.expectEqual(@as(usize, 1), try v1_selection.select(
        "@example/dual-esm",
        &artifacts,
        v1_selection.Target.forRuntime(.wnako),
        &.{},
    ));
    try testing.expectEqual(@as(usize, 0), try v1_selection.select(
        "@example/dual-esm",
        &artifacts,
        v1_selection.Target.forRuntime(.lnako),
        &.{},
    ));
}

test "package verify v1: 複数アーカイブのローカル照合が通る（X-01）" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const universal_root = try writeV1Project(a, &temporary, "universal", V1_UNIVERSAL);
    try writeV1File(a, &temporary, "universal", "src/main.nako3", "●公開挨拶とは\nここまで\n");
    const universal_path = try std.fmt.allocPrint(a, "{s}/universal.npkg", .{universal_root});
    var out1 = std.Io.Writer.Allocating.init(a);
    var err1 = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "build", universal_root, "-o", universal_path }, null, &out1.writer, &err1.writer);

    const esm_root = try writeV1Project(a, &temporary, "esm", V1_ESM);
    try writeV1File(a, &temporary, "esm", "dist/esm/index.js", "export default {};\n");
    const esm_path = try std.fmt.allocPrint(a, "{s}/esm.npkg", .{esm_root});
    var out2 = std.Io.Writer.Allocating.init(a);
    var err2 = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "build", esm_root, "--kind", "esm", "-o", esm_path }, null, &out2.writer, &err2.writer);

    var out3 = std.Io.Writer.Allocating.init(a);
    var err3 = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "verify", universal_path, esm_path }, null, &out3.writer, &err3.writer);
    try testing.expect(std.mem.indexOf(u8, out3.written(), "クロス検証 OK（2 アーティファクト") != null);
}

test "package verify v1: 共通項目が異なる複数アーカイブを P04 が拒否する（X-02）" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const left_root = try writeV1Project(a, &temporary, "left", V1_UNIVERSAL);
    try writeV1File(a, &temporary, "left", "src/main.nako3", "●公開挨拶とは\nここまで\n");
    const left_path = try std.fmt.allocPrint(a, "{s}/left.npkg", .{left_root});
    var out1 = std.Io.Writer.Allocating.init(a);
    var err1 = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "build", left_root, "-o", left_path }, null, &out1.writer, &err1.writer);

    const right_manifest = try std.mem.replaceOwned(u8, a, V1_UNIVERSAL, "license = \"MIT\"", "license = \"Apache-2.0\"");
    const right_root = try writeV1Project(a, &temporary, "right", right_manifest);
    try writeV1File(a, &temporary, "right", "src/main.nako3", "●公開挨拶とは\nここまで\n");
    const right_path = try std.fmt.allocPrint(a, "{s}/right.npkg", .{right_root});
    var out2 = std.Io.Writer.Allocating.init(a);
    var err2 = std.Io.Writer.Allocating.init(a);
    try package_cmd.run(a, io, &.{ "build", right_root, "-o", right_path }, null, &out2.writer, &err2.writer);

    var verified: std.ArrayList(v1_archive.Verified) = .empty;
    defer {
        for (verified.items) |*item| item.deinit();
        verified.deinit(a);
    }
    for ([_][]const u8{ left_path, right_path }) |path| {
        const bytes = try readV1File(a, path);
        try verified.append(a, try v1_archive.verify(a, bytes));
    }
    var report = try v1_cross.check(a, verified.items);
    defer report.deinit();
    try testing.expect(!report.ok());
    var saw_mismatch = false;
    for (report.diagnostics) |diagnostic| {
        if (diagnostic.code == .common_field_mismatch) saw_mismatch = true;
    }
    try testing.expect(saw_mismatch);
}

test "package verify v1: 旧制御ファイルを LegacyArchive として拒否する（Z-16）" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();

    const entries = [_]v1_zip.SourceEntry{
        .{ .path = "NAKO-PKG/FILES.toml", .data = "schema_version = 1\n" },
        .{ .path = "NAKO-PKG/commands.json", .data = "{}" },
        .{ .path = "NAKO-PKG/METADATA.toml", .data = "schema_version = 1\n" },
    };
    const bytes = try v1_zip.build(a, &entries, .{});
    try testing.expectError(error.LegacyArchive, v1_archive.verify(a, bytes));
    try testing.expect(std.mem.indexOf(u8, package_v1_cli.legacy_archive_message, "再作成") != null);
}

test "package build v1: 旧 manifest を読み替えず LegacyManifest にする（M-06）" {
    var arena_impl = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_impl.deinit();
    const a = arena_impl.allocator();
    const legacy =
        \\[package]
        \\name = "demo"
        \\version = "1.0.0"
        \\license = "MIT"
        \\
        \\[[exports]]
        \\name = "main"
        \\path = "src/index.nako3"
        \\
    ;
    try testing.expectError(error.LegacyManifest, v1_manifest.parse(a, legacy, .pack));
    try testing.expect(std.mem.indexOf(u8, package_v1_cli.legacy_manifest_message, "再作成") != null);
}

test "package verify v1: 旧制御名のバイト列を移行ヒントとして検出する" {
    try testing.expect(package_cmd.containsLegacyControlHint("PK\x03\x04NAKO-PKG/FILES.toml"));
    try testing.expect(package_cmd.containsLegacyControlHint("NAKO-PKG/commands.json"));
    try testing.expect(!package_cmd.containsLegacyControlHint("NAKO-PKG/FILES.json"));
    try testing.expect(!package_cmd.containsLegacyControlHint("src/main.nako3"));
}
