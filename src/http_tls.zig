const std = @import("std");

/// HTTPS接続に必要なTLS文脈（`client.now`とCAバンドル）を接続前に用意する。
///
/// `std.http.Client.request`/`fetch`は初回URIがHTTPSのときしかTLS文脈を
/// 初期化しない。そのためHTTPからHTTPSへ自動リダイレクトすると、初期化を
/// 経由せず`Connection.Tls.create`が`client.now.?`でpanicする。ここで先に
/// 初期化しておけば、初回HTTPSとリダイレクトの双方でpanicしない。
///
/// `require_bundle`がfalseのときはCAバンドル読込に失敗しても`client.now`だけ
/// 設定する。平文HTTP要求をCAストアの有無へ依存させないためで、その状態で
/// HTTPSへリダイレクトした場合はTLS検証エラーとして通常失敗する。
pub fn initializeClientTls(client: *std.http.Client, require_bundle: bool) !void {
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

/// 初回URIがHTTPSならtrue。TLS無効ビルドでHTTPSを渡すと
/// `std.http.Client.request`が`unreachable`へ入るため、呼出側はこれを見て
/// 通常エラーへ落とす。
pub fn requestRequiresTls(uri: std.Uri) bool {
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return false;
    return protocol == .tls;
}

/// TLS無効ビルドで初回URIがHTTPSのときだけ`TlsInitializationFailed`を返す。
/// 平文HTTPは`request`の対象外なので許可し、リダイレクト先HTTPSは
/// `connectTcpOptions`側が通常エラーにする。`disable_tls`は呼出側の
/// comptime定数をそのまま渡せるよう引数にしている（テスト可能にするため）。
pub fn tlsDisabledInitialError(initial_is_tls: bool, disable_tls: bool) ?anyerror {
    if (disable_tls and initial_is_tls) return error.TlsInitializationFailed;
    return null;
}

test "TLS無効時の初回HTTPSだけを通常エラーにし平文HTTPは許可する" {
    try std.testing.expectEqual(error.TlsInitializationFailed, tlsDisabledInitialError(true, true).?);
    try std.testing.expect(tlsDisabledInitialError(false, true) == null);
    try std.testing.expect(tlsDisabledInitialError(true, false) == null);
    try std.testing.expect(tlsDisabledInitialError(false, false) == null);
}
