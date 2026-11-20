const std = @import("std");
const builtin = @import("builtin");
const state = @import("state.zig");
const http_server = @import("http_server.zig");

const Runtime = state.Runtime;
const AotHttpRoute = state.AotHttpRoute;
const aotHttpIo = http_server.aotHttpIo;
const aotHttpServeStatic = http_server.aotHttpServeStatic;
const aotHttpIngressStart = http_server.aotHttpIngressStart;
const aotHttpReceiveRequest = http_server.aotHttpReceiveRequest;
const aotHttpPathOnly = http_server.aotHttpPathOnly;
const aotHttpTestSendRequest = http_server.aotHttpTestSendRequest;
const expectAotHttpResponse = http_server.expectAotHttpResponse;
const aotHttpOpenStaticFile = http_server.aotHttpOpenStaticFile;
const aotHttpReadStaticFile = http_server.aotHttpReadStaticFile;
const aotHttpStaticReadErrorStatus = http_server.aotHttpStaticReadErrorStatus;
const aotHttpEnforceStaticReadLimit = http_server.aotHttpEnforceStaticReadLimit;
const aotHttpRegisterStaticRoute = http_server.aotHttpRegisterStaticRoute;
const aotHttpPosixStatAt = http_server.aotHttpPosixStatAt;
const aotHttpOpenPosixRegularFileFallback = http_server.aotHttpOpenPosixRegularFileFallback;
const aotHttpUnsignedId = http_server.aotHttpUnsignedId;
const aotHttpReadStaticFromReader = http_server.aotHttpReadStaticFromReader;
const aotHttpIsStaticPathMiss = http_server.aotHttpIsStaticPathMiss;
const runtimeUtf8String = state.runtimeUtf8String;

test "AOT HTTP静的配信はdocroot外を指すsymlinkを404にする" {
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try docroot.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello" });
    try outside.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "OUTSIDE-SECRET" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    const outside_path = try outside.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outside_path);
    const secret_path = try std.fs.path.join(std.testing.allocator, &.{ outside_path, "secret.txt" });
    defer std.testing.allocator.free(secret_path);
    const link_path = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "leak" });
    defer std.testing.allocator.free(link_path);
    try std.Io.Dir.symLinkAbsolute(io, secret_path, link_path, .{});
    // ディレクトリ指定のindex.htmlがsymlinkの場合も404（固定状態）。
    try docroot.dir.createDirPath(io, "linkdir");
    const index_link_path = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "linkdir/index.html" });
    defer std.testing.allocator.free(index_link_path);
    try std.Io.Dir.symLinkAbsolute(io, secret_path, index_link_path, .{});

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();
    var route = AotHttpRoute{
        .kind = .static,
        .prefix = try runtime.allocator.dupe(u8, "/static"),
        .path = try runtime.allocator.dupe(u8, docroot_path),
    };
    defer route.deinit(runtime.allocator);

    var inside = try aotHttpTestSendRequest(io, port, "GET /static/hello.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer inside.close(io);
    var inside_request = try aotHttpReceiveRequest(&runtime);
    defer inside_request.deinit();
    try aotHttpServeStatic(&runtime, route, aotHttpPathOnly(inside_request.target));
    try expectAotHttpResponse(inside, io, "HTTP/1.1 200", "hello", null);

    var escaped = try aotHttpTestSendRequest(io, port, "GET /static/leak HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer escaped.close(io);
    var escaped_request = try aotHttpReceiveRequest(&runtime);
    defer escaped_request.deinit();
    try aotHttpServeStatic(&runtime, route, aotHttpPathOnly(escaped_request.target));
    try expectAotHttpResponse(escaped, io, "HTTP/1.1 404", null, "OUTSIDE-SECRET");

    var escaped_index = try aotHttpTestSendRequest(io, port, "GET /static/linkdir/ HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer escaped_index.close(io);
    var escaped_index_request = try aotHttpReceiveRequest(&runtime);
    defer escaped_index_request.deinit();
    try aotHttpServeStatic(&runtime, route, aotHttpPathOnly(escaped_index_request.target));
    try expectAotHttpResponse(escaped_index, io, "HTTP/1.1 404", null, "OUTSIDE-SECRET");
}

test "AOT HTTP静的配信はファイル、index、404の経路で一時パスを解放する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = aotHttpIo();
    try temporary.dir.writeFile(io, .{ .sub_path = "index.html", .data = "root" });
    try temporary.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello" });
    try temporary.dir.createDirPath(io, "nested");
    try temporary.dir.writeFile(io, .{ .sub_path = "nested/index.html", .data = "nested" });
    try temporary.dir.createDirPath(io, "empty");

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const root = try temporary.dir.realPathFileAlloc(io, ".", runtime.allocator);
    defer runtime.allocator.free(root);
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();

    var route = AotHttpRoute{
        .kind = .static,
        .prefix = try runtime.allocator.dupe(u8, "/static"),
        .path = try runtime.allocator.dupe(u8, root),
    };
    defer route.deinit(runtime.allocator);

    const targets = [_][]const u8{
        "/static/hello.txt",
        "/static/",
        "/static/nested/",
        "/static/empty/",
        "/static/missing.txt",
    };
    for (targets) |target| {
        const request_bytes = try std.fmt.allocPrint(runtime.allocator, "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{target});
        defer runtime.allocator.free(request_bytes);
        var client = try aotHttpTestSendRequest(io, port, request_bytes);
        defer client.close(io);
        var request = try aotHttpReceiveRequest(&runtime);
        defer request.deinit();
        try aotHttpServeStatic(&runtime, route, aotHttpPathOnly(request.target));
        try std.testing.expect(runtime.http_connection == null);
    }
}

/// `parent/name`の実ディレクトリを、`target`へのsymlinkへ置き換える
/// （攻撃者が照合後・open前に中間ディレクトリを差し替える状況の再現）。
fn replaceDirectoryWithSymlink(io: std.Io, parent: std.Io.Dir, name: []const u8, target: []const u8) !void {
    try parent.deleteTree(io, name);
    const link_path = try parent.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(link_path);
    const path = try std.fs.path.join(std.testing.allocator, &.{ link_path, name });
    defer std.testing.allocator.free(path);
    // Windowsではディレクトリ用symlink（reparse point）として作る。
    try std.Io.Dir.symLinkAbsolute(io, target, path, .{ .is_directory = true });
}

/// 1要求を送って`aotHttpServeStatic`を呼び、status行と本文断片を検査する。
fn expectAotStaticResponse(io: std.Io, runtime: *Runtime, route: AotHttpRoute, port: u16, target: []const u8, expected_status: []const u8, expected_body: ?[]const u8) !void {
    const request_bytes = try std.fmt.allocPrint(std.testing.allocator, "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{target});
    defer std.testing.allocator.free(request_bytes);
    var client = try aotHttpTestSendRequest(io, port, request_bytes);
    defer client.close(io);
    var request = try aotHttpReceiveRequest(runtime);
    defer request.deinit();
    try aotHttpServeStatic(runtime, route, aotHttpPathOnly(request.target));
    var buffer: [4096]u8 = undefined;
    var reader = client.reader(io, &buffer);
    const response = try reader.interface.allocRemaining(std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.startsWith(u8, response, expected_status));
    if (expected_body) |body| try std.testing.expect(std.mem.indexOf(u8, response, body) != null);
}

/// LinuxでFIFOを作る（書き手なしのopenが停止しないことの検証用）。
fn createFifo(io: std.Io, directory: std.Io.Dir, name: []const u8) !void {
    const root = try directory.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ root, name });
    defer std.testing.allocator.free(path);
    const rc = std.os.linux.mknodat(std.os.linux.AT.FDCWD, path.ptr, std.os.linux.S.IFIFO | 0o600, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.CreateFifoFailed;
}

/// POSIXでUnixドメインソケットのファイルを作る（種別拒否の検証用）。
fn createUnixSocket(io: std.Io, directory: std.Io.Dir, name: []const u8) !void {
    const root = try directory.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    // Unixドメインソケットのパス上限（108バイト程度）に収めるため、cwdからの
    // 相対パスでbindする。ファイル自体はdocroot内に作られる。
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const relative_root = try std.fs.path.relativeAlloc(std.testing.allocator, cwd, null, cwd, root);
    defer std.testing.allocator.free(relative_root);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ relative_root, name });
    defer std.testing.allocator.free(path);
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    defer (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }).close(io);
    var address: std.c.sockaddr.un = std.mem.zeroes(std.c.sockaddr.un);
    address.family = std.c.AF.UNIX;
    if (@hasField(std.c.sockaddr.un, "len")) address.len = @sizeOf(std.c.sockaddr.un);
    if (path.len >= address.path.len) return error.NameTooLong;
    @memcpy(address.path[0..path.len], path);
    if (std.c.bind(fd, @ptrCast(&address), @intCast(@sizeOf(std.c.sockaddr.un))) != 0) return error.BindFailed;
}

test "AOT HTTP静的配信はopen済みfdから読むため照合後のsymlink差し替えに影響されない" {
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try docroot.dir.createDirPath(io, "sub");
    try docroot.dir.writeFile(io, .{ .sub_path = "sub/hello.txt", .data = "INSIDE" });
    try outside.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "OUTSIDE-SECRET" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    const outside_path = try outside.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outside_path);

    // `aotHttpServeStatic`と同じ順序で開く。旧実装はここでrealpath文字列を
    // 照合し、後から同じ文字列を開き直していた。
    var opened = (try aotHttpOpenStaticFile(io, docroot_path, "sub/hello.txt")).?;
    defer opened.file.close(io);
    try std.testing.expectEqualStrings("hello.txt", opened.name);

    // 開いた後（読み取り前）に中間ディレクトリをdocroot外へのsymlinkへ差し替える。
    try replaceDirectoryWithSymlink(io, docroot.dir, "sub", outside_path);

    const body = try aotHttpReadStaticFile(io, opened.file, std.testing.allocator, 1024);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("INSIDE", body);
}

test "AOT HTTP静的配信は中間・最終成分のsymlinkをdocroot内でも追従しない" {
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    try docroot.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello" });
    try docroot.dir.createDirPath(io, "nested");
    try docroot.dir.writeFile(io, .{ .sub_path = "nested/index.html", .data = "nested" });

    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    const hello_path = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "hello.txt" });
    defer std.testing.allocator.free(hello_path);
    const alias_path = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "alias.txt" });
    defer std.testing.allocator.free(alias_path);
    try std.Io.Dir.symLinkAbsolute(io, hello_path, alias_path, .{});
    const nested_path = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "nested" });
    defer std.testing.allocator.free(nested_path);
    const nested_link = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "nested_link" });
    defer std.testing.allocator.free(nested_link);
    // Windowsでディレクトリのreparse pointとして作る。
    try std.Io.Dir.symLinkAbsolute(io, nested_path, nested_link, .{ .is_directory = true });

    // 通常ファイルはこれまでどおり配信する。
    var plain = (try aotHttpOpenStaticFile(io, docroot_path, "hello.txt")).?;
    plain.file.close(io);

    // docroot内を指すsymlinkでも追従しない（fail closed）。
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "alias.txt")) == null);
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "nested_link/index.html")) == null);
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "nested_link")) == null);
    // ディレクトリ指定はindex.htmlをfdから開く。
    var index = (try aotHttpOpenStaticFile(io, docroot_path, "nested")).?;
    try std.testing.expectEqualStrings("index.html", index.name);
    index.file.close(io);

    // index.htmlがsymlinkならディレクトリ指定でも404。
    try docroot.dir.deleteFile(io, "nested/index.html");
    const index_link = try std.fs.path.join(std.testing.allocator, &.{ docroot_path, "nested/index.html" });
    defer std.testing.allocator.free(index_link);
    try std.Io.Dir.symLinkAbsolute(io, hello_path, index_link, .{});
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "nested")) == null);
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "nested/")) == null);
}

test "AOT HTTP静的配信は通常ファイルへの末尾スラッシュ・ドット指定を404にする" {
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    try docroot.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello" });
    try docroot.dir.createDirPath(io, "nested");
    try docroot.dir.writeFile(io, .{ .sub_path = "nested/index.html", .data = "nested" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);

    var plain = (try aotHttpOpenStaticFile(io, docroot_path, "hello.txt")).?;
    plain.file.close(io);
    // 旧実装は`root/hello.txt/`のstatFileがNotDirになり404だった。
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "hello.txt/")) == null);
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "hello.txt/.")) == null);
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "hello.txt/./")) == null);
    // ディレクトリ指定はindex.htmlを配信する。
    var index = (try aotHttpOpenStaticFile(io, docroot_path, "nested/")).?;
    index.file.close(io);
    var index_dot = (try aotHttpOpenStaticFile(io, docroot_path, "nested/.")).?;
    index_dot.file.close(io);
}

test "AOT HTTP静的配信はFIFOをopenで停止せず404にする" {
    // 書き手のいないFIFOをO_NONBLOCKなしで開くと停止する。通常ファイル経路と
    // index.html経路の両方がfd種別で拒否することを確認する。
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    try docroot.dir.createDirPath(io, "sub");
    try createFifo(io, docroot.dir, "pipe.txt");
    try createFifo(io, docroot.dir, "sub/index.html");
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);

    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "pipe.txt")) == null);
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "sub")) == null);
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "sub/")) == null);
}

test "AOT HTTP静的配信は読み込み上限の境界を旧readFileAllocと揃える" {
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    try docroot.dir.writeFile(io, .{ .sub_path = "three.txt", .data = "abc" });
    try docroot.dir.writeFile(io, .{ .sub_path = "four.txt", .data = "abcd" });
    try docroot.dir.writeFile(io, .{ .sub_path = "five.txt", .data = "abcde" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);

    // 上限直前は読み込める。
    var three = (try aotHttpOpenStaticFile(io, docroot_path, "three.txt")).?;
    defer three.file.close(io);
    const body = try aotHttpReadStaticFile(io, three.file, std.testing.allocator, 4);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("abc", body);

    // 旧`readFileAlloc(.limited(N))`は「N以上」でStreamTooLongだった。
    var four = (try aotHttpOpenStaticFile(io, docroot_path, "four.txt")).?;
    defer four.file.close(io);
    try std.testing.expectError(error.StreamTooLong, aotHttpReadStaticFile(io, four.file, std.testing.allocator, 4));

    var five = (try aotHttpOpenStaticFile(io, docroot_path, "five.txt")).?;
    defer five.file.close(io);
    try std.testing.expectError(error.StreamTooLong, aotHttpReadStaticFile(io, five.file, std.testing.allocator, 4));

    // 413分類は課題A（fix/sec-219-interp-static-io）と同じ。
    try std.testing.expectEqual(@as(?u16, 413), aotHttpStaticReadErrorStatus(error.StreamTooLong));
    try std.testing.expectEqual(@as(?u16, 404), aotHttpStaticReadErrorStatus(error.FileNotFound));
    try std.testing.expectEqual(@as(?u16, 500), aotHttpStaticReadErrorStatus(error.AccessDenied));
    try std.testing.expectEqual(@as(?u16, null), aotHttpStaticReadErrorStatus(error.OutOfMemory));
}

test "AOT HTTP静的配信は実行権限だけのディレクトリをO_PATHで読める" {
    // LinuxのO_PATHは読み取り権限を要求しない。macOS実機は未検証のため対象外。
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    try docroot.dir.createDirPath(io, "search_only");
    try docroot.dir.writeFile(io, .{ .sub_path = "search_only/hello.txt", .data = "hello" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    const dir_path = try std.fs.path.joinZ(std.testing.allocator, &.{ docroot_path, "search_only" });
    defer std.testing.allocator.free(dir_path);
    const rc = std.os.linux.chmod(dir_path.ptr, 0o111);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.ChmodFailed;
    // cleanupがディレクトリを走査できるよう、先に権限を戻す（deferはLIFO）。
    defer _ = std.os.linux.chmod(dir_path.ptr, 0o755);

    var opened = (try aotHttpOpenStaticFile(io, docroot_path, "search_only/hello.txt")).?;
    defer opened.file.close(io);
    const body = try aotHttpReadStaticFile(io, opened.file, std.testing.allocator, 1024);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

test "AOT HTTP静的配信は中間ディレクトリのsymlink差し替えと競合してもdocroot外を読まない" {
    // RENAME_EXCHANGEで実ディレクトリとdocroot外へのsymlinkを原子的に入れ替え、
    // 照合とopenの間の実時間ウィンドウを攻撃者が継続的に狙う状況を作る。
    // 修正前はこのテストでdocroot外の`OUTSIDE-SECRET`が返る（PoC）。
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    var outside = std.testing.tmpDir(.{});
    defer outside.cleanup();
    try docroot.dir.createDirPath(io, "sub");
    try docroot.dir.writeFile(io, .{ .sub_path = "sub/hello.txt", .data = "INSIDE" });
    try outside.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "OUTSIDE-SECRET" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    const outside_path = try outside.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(outside_path);
    const swap_dir = try std.fs.path.joinZ(std.testing.allocator, &.{ docroot_path, "sub" });
    defer std.testing.allocator.free(swap_dir);
    const swap_link = try std.fs.path.joinZ(std.testing.allocator, &.{ docroot_path, "sub_link" });
    defer std.testing.allocator.free(swap_link);
    try std.Io.Dir.symLinkAbsolute(io, outside_path, swap_link, .{ .is_directory = true });

    const swapper = struct {
        fn run(dir: [:0]const u8, link: [:0]const u8, stop: *std.atomic.Value(bool), successful: *std.atomic.Value(u64)) void {
            const linux = std.os.linux;
            while (!stop.load(.acquire)) {
                // 戻り値0（成功）だけを数える。失敗を成功として数えない。
                if (linux.renameat2(linux.AT.FDCWD, dir.ptr, linux.AT.FDCWD, link.ptr, .{ .EXCHANGE = true }) == 0) {
                    _ = successful.fetchAdd(1, .monotonic);
                }
            }
        }
    };

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();
    var route = AotHttpRoute{
        .kind = .static,
        .prefix = try runtime.allocator.dupe(u8, "/static"),
        .path = try runtime.allocator.dupe(u8, docroot_path),
    };
    defer route.deinit(runtime.allocator);

    // 固定状態（競合なし）では200でINSIDEが返る。
    try expectAotStaticResponse(io, &runtime, route, port, "/static/sub/hello.txt", "HTTP/1.1 200", "INSIDE");

    var stop = std.atomic.Value(bool).init(false);
    var successful = std.atomic.Value(u64).init(0);
    const thread = try std.Thread.spawn(.{}, swapper.run, .{ swap_dir, swap_link, &stop, &successful });
    var joined = false;
    defer if (!joined) {
        stop.store(true, .release);
        thread.join();
    };

    var leaks: usize = 0;
    var ok_responses: usize = 0;
    var not_found_responses: usize = 0;
    for (0..400) |_| {
        var client = try aotHttpTestSendRequest(io, port, "GET /static/sub/hello.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
        defer client.close(io);
        var request = try aotHttpReceiveRequest(&runtime);
        defer request.deinit();
        try aotHttpServeStatic(&runtime, route, aotHttpPathOnly(request.target));
        var buffer: [4096]u8 = undefined;
        var reader = client.reader(io, &buffer);
        const response = try reader.interface.allocRemaining(std.testing.allocator, .limited(64 * 1024));
        defer std.testing.allocator.free(response);
        if (std.mem.indexOf(u8, response, "OUTSIDE-SECRET") != null) leaks += 1;
        // 許容するのは「200 + INSIDE」と「404」だけ。空応答・500・その他は失敗。
        if (std.mem.startsWith(u8, response, "HTTP/1.1 200")) {
            if (std.mem.indexOf(u8, response, "INSIDE") == null) {
                std.debug.print("\n[AOT静的配信TOCTOU回帰] 200だが本文がINSIDEでない: {s}\n", .{response});
                return error.UnexpectedStaticBody;
            }
            ok_responses += 1;
        } else if (std.mem.startsWith(u8, response, "HTTP/1.1 404")) {
            not_found_responses += 1;
        } else {
            std.debug.print("\n[AOT静的配信TOCTOU回帰] 想定外の応答: {s}\n", .{response});
            return error.UnexpectedStaticStatus;
        }
    }
    stop.store(true, .release);
    thread.join();
    joined = true;
    const successful_swaps = successful.load(.monotonic);
    std.debug.print(
        "\n[AOT静的配信TOCTOU回帰] successful_swaps={d} requests=400 200={d} 404={d} docroot外読み出し={d}\n",
        .{ successful_swaps, ok_responses, not_found_responses, leaks },
    );
    // 差し替えが一度も成功していないテストは競合を検証できていない。
    try std.testing.expect(successful_swaps > 0);
    try std.testing.expectEqual(@as(usize, 0), leaks);
}

test "AOT HTTP静的配信はLinuxでFIFOとソケットを事前statで検出し404にする" {
    // Linuxで確認できる範囲: statxが.named_pipe/.unix_domain_socketを返し、
    // aotHttpOpenStaticFileが読み取りopen前にnullを返すこと。
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    try createFifo(io, docroot.dir, "pipe");
    try createUnixSocket(io, docroot.dir, "sock");
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);

    const pipe_stat = (try aotHttpPosixStatAt(docroot.dir, "pipe")).?;
    try std.testing.expectEqual(std.Io.File.Kind.named_pipe, pipe_stat.kind);
    const sock_stat = (try aotHttpPosixStatAt(docroot.dir, "sock")).?;
    try std.testing.expectEqual(std.Io.File.Kind.unix_domain_socket, sock_stat.kind);

    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "pipe")) == null);
    try std.testing.expect((try aotHttpOpenStaticFile(io, docroot_path, "sock")) == null);
}

test "AOT HTTP静的配信はDarwinのソケットopen拒否を404に分類する" {
    // Darwinはソケットの読み取りopenにEOPNOTSUPPを返し、Zigは
    // error.FileLocksUnsupportedへ変換する。種別違いとして404にする。
    try std.testing.expect(aotHttpIsStaticPathMiss(error.FileLocksUnsupported));
}

test "AOT HTTP静的配信はNULを含むdocrootで停止しない" {
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    try docroot.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);
    const nul_path = try std.fmt.allocPrint(std.testing.allocator, "{s}\x00evil", .{docroot_path});
    defer std.testing.allocator.free(nul_path);
    // toPosixPathのassertで停止せず、404相当のnullになる。
    try std.testing.expect((try aotHttpOpenStaticFile(io, nul_path, "hello.txt")) == null);
}

test "AOT HTTP静的配信はNULを含むdocrootの登録を拒否する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const prefix = try runtimeUtf8String(&runtime, "/static");
    const path = try runtimeUtf8String(&runtime, "docroot\x00evil");
    try std.testing.expectError(error.BadPathName, aotHttpRegisterStaticRoute(&runtime, prefix, path));
    try std.testing.expectEqual(@as(usize, 0), runtime.http_server_state.routes.items.len);
}

test "AOT HTTP静的配信は読み取り中に上限ちょうどへ達すると413相当にする" {
    // 事前statは上限未満（2 < 4）だが、実読取が上限ちょうど（4バイト）に
    // 達する経路をReader.fixedで通す。testing.allocatorがリークも検出する。
    var reader = std.Io.Reader.fixed("1234");
    try std.testing.expectError(error.StreamTooLong, aotHttpReadStaticFromReader(&reader, 2, std.testing.allocator, 4));

    // 上限直前（3バイト）は成功する。
    var short_reader = std.Io.Reader.fixed("123");
    const kept = try aotHttpReadStaticFromReader(&short_reader, 2, std.testing.allocator, 4);
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("123", kept);
}

test "AOT HTTP静的配信は符号付きdev_tの負値を安全にu64へ変換する" {
    try std.testing.expectEqual(@as(u64, 0xffffffff), aotHttpUnsignedId(@as(i32, -1)));
    try std.testing.expectEqual(@as(u64, 0x7fffffff), aotHttpUnsignedId(@as(i32, 0x7fffffff)));
    try std.testing.expectEqual(@as(u64, 0xffffffffffffffff), aotHttpUnsignedId(@as(i64, -1)));
}

test "AOT HTTP静的配信のprocfsフォールバックは同一inodeだけを受け付ける" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    try docroot.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "A" });
    try docroot.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "B" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);

    const pre_a = (try aotHttpPosixStatAt(docroot.dir, "a.txt")).?;
    // 事前statがa.txtのままb.txtを開こうとすると(dev, ino)不一致で拒否する。
    try std.testing.expect((try aotHttpOpenPosixRegularFileFallback(io, docroot.dir, "b.txt", pre_a)) == null);
    // 同一inodeなら開ける。
    const fd = (try aotHttpOpenPosixRegularFileFallback(io, docroot.dir, "a.txt", pre_a)).?;
    (std.Io.File{ .handle = fd, .flags = .{ .nonblocking = true } }).close(io);
}

test "AOT HTTP静的配信は要求パス先頭のバックスラッシュを従来どおり除去する" {
    const io = aotHttpIo();
    var docroot = std.testing.tmpDir(.{});
    defer docroot.cleanup();
    try docroot.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello" });
    const docroot_path = try docroot.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(docroot_path);

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    runtime.http_server = try address.listen(io, .{ .reuse_address = true });
    try aotHttpIngressStart(&runtime);
    runtime.http_server_state.started = true;
    const port = runtime.http_server.?.socket.address.getPort();
    var route = AotHttpRoute{
        .kind = .static,
        .prefix = try runtime.allocator.dupe(u8, "/static"),
        .path = try runtime.allocator.dupe(u8, docroot_path),
    };
    defer route.deinit(runtime.allocator);

    // ベース実装は先頭の`/`と`\`をtrimStartで除去していた。
    var client = try aotHttpTestSendRequest(io, port, "GET /static/\\hello.txt HTTP/1.1\r\nHost: localhost\r\n\r\n");
    defer client.close(io);
    var request = try aotHttpReceiveRequest(&runtime);
    defer request.deinit();
    try aotHttpServeStatic(&runtime, route, aotHttpPathOnly(request.target));
    try expectAotHttpResponse(client, io, "HTTP/1.1 200", "hello", null);
}
