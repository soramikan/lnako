const std = @import("std");
const builtin = @import("builtin");
const diag = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;

/// 取得対象の種別。offline や失敗時に「何が不足しているか」を特定する。
pub const ResourceKind = enum {
    /// registry `index.json`。
    index,
    /// registry `<owner>/<name>.json`。
    package,
    /// registry `<owner>/<name>/<version>.json`。
    version,
    /// 取得した package の manifest（`nako.toml` / `METADATA.toml`）。
    manifest,
    /// 配布 artifact（`.npkg` / tar.gz / raw など）本体。
    artifact,
    /// Git repository。
    repository,
};

/// 失敗理由の分類。全 provider で統一する。
pub const FailureKind = enum {
    /// `--offline` で通信が禁止され、かつ必要なデータが手元に無い。
    offline,
    /// 404・ファイル不在・index 未収録など対象が存在しない。
    not_found,
    /// 応答が timeout までに完了しなかった。
    timeout,
    /// redirect が拒否された（`max_redirects` 超過または 0 指定）。
    redirect_denied,
    /// 取得上限（`max_bytes`）を超えた。
    too_large,
    /// 取得内容の hash が宣言と不一致（破損・改竄）。
    hash_mismatch,
    /// metadata（manifest/registry record）の構造が schema v1 に適合しない。
    invalid_metadata,
    /// 接続・TLS・HTTP status などその他の通信失敗。
    network,
    /// 要求された provider が利用不能（Git 実行ファイル不在など）。
    unavailable,
    /// 同一 identity に別内容・別 source が割り当てられた衝突。
    source_collision,
    /// source 指定自体が不正（URI・hash 形式の不備など）。
    invalid_source,
};

/// 1 回の取得失敗の記録。`target`/`message` は `Session` の arena が所有する。
pub const Failure = struct {
    kind: FailureKind,
    resource: ResourceKind,
    /// URL・path・package 名など失敗対象の識別子。
    target: []const u8 = "",
    message: []const u8 = "",
    /// kind 既定の診断コードを上書きする場合に設定する
    /// （例: registry record 不一致は分類上 invalid_metadata だが
    /// 診断コードは E010_REGISTRY_RECORD_MISMATCH）。
    code: ?[]const u8 = null,

    /// 失敗分類に対応する診断コード。
    pub fn diagnosticCode(self: Failure) []const u8 {
        if (self.code) |code| return code;
        return switch (self.kind) {
            .offline => diag.E043_FETCH_OFFLINE,
            .not_found => diag.E013_MISSING_PACKAGE,
            .timeout => diag.E042_FETCH_TIMEOUT,
            .redirect_denied => diag.E045_FETCH_REDIRECT,
            .too_large => diag.E044_FETCH_TOO_LARGE,
            .hash_mismatch => diag.E009_HASH_MISMATCH,
            .invalid_metadata => diag.E029_INVALID_VALUE,
            .network => diag.E041_FETCH_NETWORK,
            .unavailable => diag.E047_PROVIDER_UNAVAILABLE,
            .source_collision => diag.E046_SOURCE_COLLISION,
            .invalid_source => diag.E029_INVALID_VALUE,
        };
    }
};

/// 全 provider 共通の取得 policy。`--offline`・取得上限・timeout・redirect を揃える。
pub const Policy = struct {
    /// true のとき一切のネットワーク通信・外部 process 起動（git clone/fetch）
    /// を行わない。手元に無いデータは `offline` 失敗として不足を報告する。
    /// path provider はローカルのみで完結するため offline でも動作する。
    offline: bool = false,
    /// 1 応答あたりの取得上限。0 は上限なし。
    max_bytes: usize = 64 * 1024 * 1024,
    /// HTTP 要求全体（接続・応答・本文読取り）の制限時間。0 は制限なし。
    timeout_ns: u64 = 60 * std.time.ns_per_s,
    /// 許可する redirect 回数。0 は redirect を一切拒否する。
    max_redirects: u16 = 3,
    /// true のとき平文 `http://` を全 host で許可する。false（既定）では
    /// loopback host（localhost・127.0.0.0/8・::1）への平文 http だけを
    /// 許可し、それ以外は `invalid_source` として拒否する。registry の
    /// index/metadata や manifest の hash を通信路上で改変される攻撃を
    /// 既定で防ぐための制限。
    allow_plaintext_http: bool = false,
};

/// provider 呼出しに共通の環境。`failures` には直近の失敗が新しい順に
/// 記録される（`lastFailure` で直近を取得）。失敗時は必ず 1 件記録する。
pub const Session = struct {
    gpa: Allocator,
    io: std.Io,
    policy: Policy = .{},
    /// 設定されていれば、manifest/registry 解析の位置付き診断もここへ転記する。
    diagnostics: ?*diag.List = null,
    arena: std.heap.ArenaAllocator,
    failures: std.ArrayList(Failure) = .empty,

    pub fn init(gpa: Allocator, io: std.Io, policy: Policy) Session {
        return .{
            .gpa = gpa,
            .io = io,
            .policy = policy,
            .arena = std.heap.ArenaAllocator.init(gpa),
        };
    }

    pub fn deinit(self: *Session) void {
        self.failures.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// session が所有する arena の allocator。取得結果・失敗メッセージは
    /// ここから割り当てられ、`deinit` で一括解放される。
    pub fn allocator(self: *Session) Allocator {
        return self.arena.allocator();
    }

    /// 失敗を分類つきで記録する。戻り値は `Error` の対応するタグ。
    pub fn fail(
        self: *Session,
        kind: FailureKind,
        resource: ResourceKind,
        target: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Error {
        return self.failCode(kind, resource, target, null, fmt, args);
    }

    /// `fail` と同じだが診断コードを `code` で上書きする。
    pub fn failCode(
        self: *Session,
        kind: FailureKind,
        resource: ResourceKind,
        target: []const u8,
        code: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Error {
        const arena = self.arena.allocator();
        const message = std.fmt.allocPrint(arena, fmt, args) catch return failureError(kind);
        const owned_target = arena.dupe(u8, target) catch return failureError(kind);
        self.failures.append(self.gpa, .{
            .kind = kind,
            .resource = resource,
            .target = owned_target,
            .message = message,
            .code = code,
        }) catch return failureError(kind);
        return failureError(kind);
    }

    pub fn lastFailure(self: *const Session) ?Failure {
        if (self.failures.items.len == 0) return null;
        return self.failures.items[self.failures.items.len - 1];
    }

    /// manifest/TOML 解析など位置付き診断を出力する API へ渡す sink。
    /// `diagnostics` が未設定なら `scratch`（呼出側が破棄する一時 List）。
    pub fn diagSink(self: *Session, scratch: *diag.List) *diag.List {
        return self.diagnostics orelse scratch;
    }

    /// 記録済み失敗を `diagnostics` へ転写する。
    pub fn reportDiagnostics(self: *const Session, diagnostics: *diag.List) !void {
        for (self.failures.items) |failure| {
            try diagnostics.addFmt(failure.diagnosticCode(), .err, failure.target, .{}, "{s}", .{failure.message});
        }
    }
};

/// 取得系 API が返す error 集合。`FailureKind` と 1 対 1 で対応する。
pub const Error = error{
    Offline,
    NotFound,
    Timeout,
    RedirectDenied,
    TooLarge,
    HashMismatch,
    InvalidMetadata,
    Network,
    ProviderUnavailable,
    SourceCollision,
    InvalidSource,
    OutOfMemory,
    Canceled,
};

pub fn failureError(kind: FailureKind) Error {
    return switch (kind) {
        .offline => error.Offline,
        .not_found => error.NotFound,
        .timeout => error.Timeout,
        .redirect_denied => error.RedirectDenied,
        .too_large => error.TooLarge,
        .hash_mismatch => error.HashMismatch,
        .invalid_metadata => error.InvalidMetadata,
        .network => error.Network,
        .unavailable => error.ProviderUnavailable,
        .source_collision => error.SourceCollision,
        .invalid_source => error.InvalidSource,
    };
}

/// HTTP(S) GET で本文全体を取得する。policy の offline・max_bytes・
/// timeout・max_redirects を適用し、失敗は `session.failures` に分類付きで
/// 記録する。成功時の戻り値は `session` の arena が所有する。
///
/// timeout は `std.Io.Select` で要求全体を deadline と競合させて実現する。
/// timeout 発生時は実行中の要求へ cancelation を送り、`Session` は
/// `error.Timeout` を返す。
pub fn fetchBytes(session: *Session, url: []const u8, resource: ResourceKind) Error![]u8 {
    if (session.policy.offline) {
        return session.fail(.offline, resource, url, "offline mode: {s} requires a network request", .{@tagName(resource)});
    }
    const uri = std.Uri.parse(url) catch {
        return session.fail(.invalid_source, resource, url, "invalid url \"{s}\"", .{url});
    };
    if (session.policy.timeout_ns == 0) {
        return fetchBytesInner(session, uri, url, resource);
    }
    // 要求全体を sleep と競合させる。timeout 側が先に完了したら要求へ
    // cancelation を送り、blocked syscall を中断させてから結果を捨てる。
    const Outcome = union(enum) {
        fetched: Error![]u8,
        timed_out: std.Io.Cancelable!void,
    };
    var buffer: [2]Outcome = undefined;
    var select = std.Io.Select(Outcome).init(session.io, &buffer);
    select.async(.fetched, FetchTask.run, .{.{ .session = session, .uri = uri, .url = url, .resource = resource }});
    select.async(.timed_out, std.Io.Timeout.sleep, .{ .{ .duration = policyDuration(session.policy.timeout_ns) }, session.io });
    const outcome = select.await() catch |err| switch (err) {
        error.Canceled => |e| return e,
    };
    switch (outcome) {
        .fetched => |result| {
            // 残った sleep を止めてから結果を返す。
            _ = select.cancel();
            return result;
        },
        .timed_out => {
            // 要求側を中断する。結果が間に合った場合は arena が後始末する。
            while (select.cancel()) |_| {}
            return session.fail(.timeout, resource, url, "fetch of \"{s}\" exceeded the timeout", .{url});
        },
    }
}

/// `policy.timeout_ns` を `std.Io.Clock.Duration`（単調時計）へ変換する。
fn policyDuration(timeout_ns: u64) std.Io.Clock.Duration {
    return .{ .raw = .fromNanoseconds(@intCast(timeout_ns)), .clock = .awake };
}

/// `Io.Select` へ渡す取得 task。timeout との競合で使う。
const FetchTask = struct {
    session: *Session,
    uri: std.Uri,
    url: []const u8,
    resource: ResourceKind,

    fn run(task: FetchTask) Error![]u8 {
        return fetchBytesInner(task.session, task.uri, task.url, task.resource);
    }
};

/// `std.http.Client` 用の TLS 文脈を接続前に用意する。
/// `src/http_tls.zig` の `initializeClientTls` と同じ処理をここへ複写する
/// （`http_tls.zig` は `root` module 側の host 層が所有しており、package 層の
/// このファイルから import すると module 境界で重複するため共有できない）。
/// 初回 URI が HTTP でも HTTPS リダイレクトに備えて `client.now` を設定する。
fn initializeClientTls(client: *std.http.Client, require_bundle: bool) !void {
    if (std.http.Client.disable_tls) return;
    if (client.now != null) return;
    const io = client.io;
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(client.allocator);
    const now = std.Io.Clock.real.now(io);
    var rescan_failed = false;
    bundle.rescan(client.allocator, io, now) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => |e| return e,
        else => rescan_failed = true,
    };
    if (rescan_failed and require_bundle) return error.CertificateBundleLoadFailure;
    try client.ca_bundle_lock.lock(io);
    defer client.ca_bundle_lock.unlock(io);
    client.now = now;
    std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
}

/// 初回・redirect 先の各ホップへ適用する URL 検査。平文 http は loopback
/// 配布または明示 opt-in のみ許可し、HTTPS→HTTP への redirect 降格もここで
/// 拒否する。
fn checkFetchUriPolicy(session: *Session, uri: std.Uri, url: []const u8, resource: ResourceKind) Error!std.http.Client.Protocol {
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse
        return session.fail(.invalid_source, resource, url, "unsupported uri scheme in \"{s}\"", .{url});
    if (protocol == .plain and !session.policy.allow_plaintext_http and !isLoopbackHost(uri)) {
        return session.fail(.invalid_source, resource, url, "plaintext http url \"{s}\" is only allowed for loopback hosts (set allow_plaintext_http to opt in)", .{url});
    }
    // TLS無効ビルドでHTTPSを渡すと`request`がabortするため通常エラーへ落とす
    // （`src/http_tls.zig` の `tlsDisabledInitialError` と同じ契約）。
    if (std.http.Client.disable_tls and protocol == .tls) {
        return session.fail(.network, resource, url, "TLS is not available in this build", .{});
    }
    return protocol;
}

fn fetchBytesInner(session: *Session, uri: std.Uri, url: []const u8, resource: ResourceKind) Error![]u8 {
    const gpa = session.arena.allocator();
    const io = session.io;

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var current_uri = uri;
    var redirects_left = session.policy.max_redirects;
    var tls_initialized = false;

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var request: std.http.Client.Request = undefined;
    var have_request = false;
    defer if (have_request) request.deinit();

    var response: std.http.Client.Response = undefined;
    while (true) {
        const protocol = try checkFetchUriPolicy(session, current_uri, url, resource);
        if (!tls_initialized) {
            // 初回HTTPからのHTTPSリダイレクトでもTLS文脈未初期化でpanicしない
            // よう事前に TLS 文脈を用意する。
            initializeClientTls(&client, protocol == .tls) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Canceled => return error.Canceled,
                else => return session.fail(.network, resource, url, "TLS initialization failed for \"{s}\"", .{url}),
            };
            tls_initialized = true;
        }

        // redirect は自動追跡せず、各ホップの URL をポリシー検査してから
        // 新しい request を張り直す（HTTPS→平文 HTTP への降格を防ぐ）。
        request = client.request(.GET, current_uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
        }) catch |err| return classifyRequestError(session, err, url, resource);
        have_request = true;

        request.sendBodiless() catch |err| return classifyRequestError(session, err, url, resource);
        response = request.receiveHead(&redirect_buffer) catch |err| return classifyRequestError(session, err, url, resource);

        if (response.head.status.class() != .redirect) break;
        if (redirects_left == 0) {
            return session.fail(.redirect_denied, resource, url, "redirect limit exceeded for \"{s}\"", .{url});
        }
        redirects_left -= 1;
        const location = response.head.location orelse
            return session.fail(.network, resource, url, "redirect from \"{s}\" has no Location header", .{url});
        // 現在の URI を基準に Location を解決する。解決結果の各成分は
        // scratch 領域を指すため、session arena に確保して次イテレーション
        // 以降も有効にする。`location` は redirect_buffer 上のため複製する。
        const resolve_buf = try gpa.alloc(u8, location.len + 8 * 1024);
        @memcpy(resolve_buf[0..location.len], location);
        var aux: []u8 = resolve_buf;
        current_uri = current_uri.resolveInPlace(location.len, &aux) catch
            return session.fail(.invalid_source, resource, url, "redirect location from \"{s}\" is invalid", .{url});
        request.deinit();
        have_request = false;
    }

    switch (response.head.status) {
        .ok => {},
        .not_found => return session.fail(.not_found, resource, url, "{s} not found (HTTP 404)", .{@tagName(resource)}),
        else => return session.fail(.network, resource, url, "fetch of \"{s}\" failed with HTTP status {d}", .{ url, @intFromEnum(response.head.status) }),
    }

    // サーバが申告した Content-Length が既に上限超過なら本文を読まずに拒否する。
    if (session.policy.max_bytes > 0) {
        if (response.head.content_length) |declared| {
            if (declared > session.policy.max_bytes) {
                return session.fail(.too_large, resource, url, "{s} exceeds the {d} byte limit", .{ @tagName(resource), session.policy.max_bytes });
            }
        }
    }

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try gpa.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try gpa.alloc(u8, std.compress.flate.max_window_len),
        .compress => return session.fail(.network, resource, url, "unsupported content encoding \"compress\"", .{}),
    };

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    var output: std.ArrayList(u8) = .empty;
    while (true) {
        var chunk: [16 * 1024]u8 = undefined;
        const n = reader.readSliceShort(&chunk) catch |err| return classifyRequestError(session, err, url, resource);
        if (n == 0) break;
        if (session.policy.max_bytes > 0 and output.items.len + n > session.policy.max_bytes) {
            return session.fail(.too_large, resource, url, "{s} exceeds the {d} byte limit", .{ @tagName(resource), session.policy.max_bytes });
        }
        try output.appendSlice(gpa, chunk[0..n]);
    }
    return output.items;
}

/// URI の host が loopback（localhost・*.localhost・127.0.0.0/8・::1）
/// なら true。平文 http を同一マシン配布に限って許可する判定に使う。
fn isLoopbackHost(uri: std.Uri) bool {
    const component = uri.host orelse return false;
    const host = switch (component) {
        .raw, .percent_encoded => |text| text,
    };
    if (std.ascii.eqlIgnoreCase(host, "localhost") or std.ascii.endsWithIgnoreCase(host, ".localhost")) return true;
    if (std.Io.net.Ip4Address.parse(host, 0)) |ip4| {
        return ip4.bytes[0] == 127;
    } else |_| {}
    // IPv6 literal は URI 上 `[…]` で囲まれる。
    const inner = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    if (std.Io.net.Ip6Address.parse(inner, 0)) |ip6| {
        return std.mem.eql(u8, &ip6.bytes, &std.Io.net.Ip6Address.loopback(0).bytes);
    } else |_| {}
    return false;
}

/// `std.http.Client` 由来の error を統一の失敗分類へ写像する。
fn classifyRequestError(session: *Session, err: anyerror, url: []const u8, resource: ResourceKind) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        // 下位レイヤーの timeout も失敗履歴へ記録して Session 契約を守る。
        error.Timeout => session.fail(.timeout, resource, url, "fetch of \"{s}\" timed out", .{url}),
        error.TooManyHttpRedirects => session.fail(.redirect_denied, resource, url, "redirect limit exceeded for \"{s}\"", .{url}),
        else => session.fail(.network, resource, url, "fetch of \"{s}\" failed: {s}", .{ url, @errorName(err) }),
    };
}

// ---------------------------------------------------------------------------
// hash 照合
// ---------------------------------------------------------------------------

/// SHA-256 表記（`sha256-<base64>=`・`sha256:<hex>`・生 `<hex>`）を
/// 32 バイトへ正規化する。解釈できない場合は null。
pub fn normalizeSha256(text: []const u8) ?[32]u8 {
    var out: [32]u8 = undefined;
    if (text.len == 64) {
        _ = std.fmt.hexToBytes(&out, text) catch return null;
        return out;
    }
    if (text.len == "sha256:".len + 64 and std.mem.startsWith(u8, text, "sha256:")) {
        _ = std.fmt.hexToBytes(&out, text["sha256:".len..]) catch return null;
        return out;
    }
    if (text.len == "sha256-".len + 44 and std.mem.startsWith(u8, text, "sha256-")) {
        const encoded = text["sha256-".len..];
        if (encoded[encoded.len - 1] != '=') return null;
        const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;
        if (size != 32) return null;
        std.base64.standard.Decoder.decode(&out, encoded) catch return null;
        return out;
    }
    return null;
}

/// SHA-512 表記（`sha512-<base64>=`・`sha512:<hex>`）を 64 バイトへ
/// 正規化する。解釈できない場合は null。
fn normalizeSha512(text: []const u8) ?[64]u8 {
    var out: [64]u8 = undefined;
    if (text.len == "sha512:".len + 128 and std.mem.startsWith(u8, text, "sha512:")) {
        _ = std.fmt.hexToBytes(&out, text["sha512:".len..]) catch return null;
        return out;
    }
    if (text.len == "sha512-".len + 88 and std.mem.startsWith(u8, text, "sha512-")) {
        const encoded = text["sha512-".len..];
        if (encoded[encoded.len - 1] != '=') return null;
        const size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return null;
        if (size != 64) return null;
        std.base64.standard.Decoder.decode(&out, encoded) catch return null;
        return out;
    }
    return null;
}

pub fn sha256Hex(gpa: Allocator, bytes: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = try gpa.alloc(u8, 64);
    _ = std.fmt.bufPrint(hex, "{x}", .{digest}) catch unreachable;
    return hex;
}

fn sha512Hex(gpa: Allocator, bytes: []const u8) ![]u8 {
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &digest, .{});
    const hex = try gpa.alloc(u8, 128);
    _ = std.fmt.bufPrint(hex, "{x}", .{digest}) catch unreachable;
    return hex;
}

/// 取得 bytes を宣言 hash と照合する。`expected` は sha256
/// （`sha256:<hex>`・`sha256-<base64>=`・生 `<hex>`）または sha512
/// （`sha512:<hex>`・`sha512-<base64>=`）表記を受理する。解釈不能な
/// 形式なら `invalid_source`、不一致なら `hash_mismatch` を記録して
/// 失敗する。
pub fn verifyHash(session: *Session, bytes: []const u8, expected: []const u8, target: []const u8, resource: ResourceKind) Error!void {
    if (normalizeSha256(expected)) |expected_bytes| {
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
        if (std.mem.eql(u8, &actual, &expected_bytes)) return;
        const actual_hex = try sha256Hex(session.arena.allocator(), bytes);
        return session.fail(.hash_mismatch, resource, target, "sha256 mismatch for \"{s}\": expected {s}, got sha256:{s}", .{ target, expected, actual_hex });
    }
    if (normalizeSha512(expected)) |expected_bytes| {
        var actual: [64]u8 = undefined;
        std.crypto.hash.sha2.Sha512.hash(bytes, &actual, .{});
        if (std.mem.eql(u8, &actual, &expected_bytes)) return;
        const actual_hex = try sha512Hex(session.arena.allocator(), bytes);
        return session.fail(.hash_mismatch, resource, target, "sha512 mismatch for \"{s}\": expected {s}, got sha512:{s}", .{ target, expected, actual_hex });
    }
    return session.fail(.invalid_source, resource, target, "unsupported hash notation \"{s}\"", .{expected});
}

/// git 子プロセスへ渡す環境を構築する。`git push` の hook（pre-push 等）や
/// rebase から起動されたプロセスでは GIT_DIR・GIT_WORK_TREE・
/// GIT_INDEX_FILE 等の `GIT_*` 環境変数が設定されており、そのまま継承
/// すると子プロセスの git が意図した repo ではなく呼出し側の repo を
/// 操作する。POSIX は `environ`、Windows は PEB の WTF-16 環境ブロックから
/// `GIT_*` を除去した環境を返す。対応しない環境では null（既定の継承）
/// を返す。
/// 返り値の Map は呼出し側が `deinit` で解放する。
pub fn sanitizedGitEnvMap(gpa: Allocator) Allocator.Error!?std.process.Environ.Map {
    var map = std.process.Environ.Map.init(gpa);
    errdefer map.deinit();
    switch (builtin.os.tag) {
        .windows => {
            const windows = std.os.windows;
            const peb = windows.peb();
            _ = windows.ntdll.RtlEnterCriticalSection(peb.FastPebLock);
            defer _ = windows.ntdll.RtlLeaveCriticalSection(peb.FastPebLock);
            const ptr = peb.ProcessParameters.Environment;
            var i: usize = 0;
            while (ptr[i] != 0) {
                const key_start = i;
                // `=C:` 形式の特殊変数は先頭 '=' を key の一部として扱う。
                if (ptr[i] == '=') i += 1;
                while (ptr[i] != 0 and ptr[i] != '=') : (i += 1) {}
                const key_w = ptr[key_start..i];
                if (ptr[i] == '=') i += 1;
                const value_start = i;
                while (ptr[i] != 0) : (i += 1) {}
                const value_w = ptr[value_start..i];
                i += 1;
                // Windows の環境変数参照は大小文字を区別しない。
                if (key_w.len >= 4 and windows.eqlIgnoreCaseWtf16(key_w[0..4], &.{ 'G', 'I', 'T', '_' })) continue;
                const key = try std.unicode.wtf16LeToWtf8Alloc(gpa, key_w);
                defer gpa.free(key);
                const value = try std.unicode.wtf16LeToWtf8Alloc(gpa, value_w);
                defer gpa.free(value);
                try map.put(key, value);
            }
            return map;
        },
        .wasi => return null,
        else => {
            var i: usize = 0;
            while (std.c.environ[i]) |entry| : (i += 1) {
                const kv = std.mem.span(entry);
                const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                if (kv[0..eq].len >= 4 and std.ascii.eqlIgnoreCase(kv[0..eq][0..4], "GIT_")) continue;
                try map.put(kv[0..eq], kv[eq + 1 ..]);
            }
            return map;
        },
    }
}
