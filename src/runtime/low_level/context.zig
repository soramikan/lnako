const std = @import("std");
const foundation = @import("../low_level_foundation.zig");
const low_level_io = @import("../low_level_io.zig");
const low_level_fs = @import("../low_level_fs.zig");
const low_level_posix = @import("../low_level_posix.zig");

/// Hostが関数ポインタの `context` に載せるダミー領域。callbackを持たない
/// 空サブContext専用で、実際に呼ばれることはない（呼べば未定義）。`emptyContext`
/// と各空サブContext定数だけが参照し、ファイル外へは公開しない。
var unused_context_host: u8 = 0;

const default_host: *anyopaque = @ptrCast(&unused_context_host);

/// Stream File I/OドメインのHostコールバック。`context` は必須。callbackを
/// 1つでも設定する場合はHostへのポインタを明示すること（ダミーを既定値に
/// するとcallback側の `@alignCast` が不正なポインタを受け取る）。
pub const StreamContext = struct {
    context: *anyopaque,
    openFileFn: ?*const fn (context: *anyopaque, path: []const u8, mode: foundation.OpenMode, exclusive: bool, sync: bool) anyerror!u64 = null,
    closeFileFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,
    readFileBytesFn: ?*const fn (context: *anyopaque, raw: u64, buffer: []u8) anyerror!usize = null,
    writeFileBytesFn: ?*const fn (context: *anyopaque, raw: u64, bytes: []const u8) anyerror!usize = null,
    syncFileFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,
    truncateFileFn: ?*const fn (context: *anyopaque, raw: u64, size: u64) anyerror!void = null,

    pub fn openFile(self: StreamContext, path: []const u8, mode: foundation.OpenMode, exclusive: bool, sync: bool) !u64 {
        const function = self.openFileFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path, mode, exclusive, sync);
    }

    pub fn closeFile(self: StreamContext, raw: u64) !void {
        const function = self.closeFileFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, raw);
    }

    pub fn readFileBytes(self: StreamContext, raw: u64, buffer: []u8) !usize {
        const function = self.readFileBytesFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, raw, buffer);
    }

    pub fn writeFileBytes(self: StreamContext, raw: u64, bytes: []const u8) !usize {
        const function = self.writeFileBytesFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, raw, bytes);
    }

    pub fn syncFile(self: StreamContext, raw: u64) !void {
        const function = self.syncFileFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, raw);
    }

    pub fn truncateFile(self: StreamContext, raw: u64, size: u64) !void {
        const function = self.truncateFileFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, raw, size);
    }

    pub fn hasStreamFileIo(self: StreamContext) bool {
        return self.openFileFn != null and self.closeFileFn != null and self.readFileBytesFn != null and self.writeFileBytesFn != null and self.syncFileFn != null;
    }

    pub fn hasTruncate(self: StreamContext) bool {
        return self.truncateFileFn != null;
    }
};

/// 逐次ハッシュドメインのHostコールバック。
pub const HashContext = struct {
    context: *anyopaque,
    createHashFn: ?*const fn (context: *anyopaque, algorithm: []const u8) anyerror!u64 = null,
    updateHashFn: ?*const fn (context: *anyopaque, raw: u64, bytes: []const u8) anyerror!void = null,
    digestHashFn: ?*const fn (context: *anyopaque, raw: u64, allocator: std.mem.Allocator) anyerror![]u8 = null,
    discardHashFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,

    pub fn createHash(self: HashContext, algorithm: []const u8) !u64 {
        const function = self.createHashFn orelse return error.IncrementalHashUnavailable;
        return function(self.context, algorithm);
    }

    pub fn updateHash(self: HashContext, raw: u64, bytes: []const u8) !void {
        const function = self.updateHashFn orelse return error.IncrementalHashUnavailable;
        return function(self.context, raw, bytes);
    }

    pub fn digestHash(self: HashContext, raw: u64, allocator: std.mem.Allocator) ![]u8 {
        const function = self.digestHashFn orelse return error.IncrementalHashUnavailable;
        return function(self.context, raw, allocator);
    }

    pub fn discardHash(self: HashContext, raw: u64) !void {
        const function = self.discardHashFn orelse return error.IncrementalHashUnavailable;
        return function(self.context, raw);
    }

    pub fn hasIncrementalHash(self: HashContext) bool {
        return self.createHashFn != null and self.updateHashFn != null and self.digestHashFn != null and self.discardHashFn != null;
    }
};

/// Filesystemメタデータ操作ドメインのHostコールバック。
pub const FsContext = struct {
    context: *anyopaque,
    statFn: ?*const fn (context: *anyopaque, path: []const u8, follow: bool) anyerror!low_level_fs.Metadata = null,
    symlinkFn: ?*const fn (context: *anyopaque, target: []const u8, link: []const u8) anyerror!void = null,
    readlinkFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 = null,
    hardlinkFn: ?*const fn (context: *anyopaque, target: []const u8, link: []const u8) anyerror!void = null,
    realpathFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![:0]u8 = null,
    renameFn: ?*const fn (context: *anyopaque, source: []const u8, destination: []const u8) anyerror!void = null,
    unlinkFn: ?*const fn (context: *anyopaque, path: []const u8) anyerror!void = null,
    rmdirFn: ?*const fn (context: *anyopaque, path: []const u8) anyerror!void = null,

    pub fn stat(self: FsContext, path: []const u8, follow: bool) !low_level_fs.Metadata {
        const function = self.statFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path, follow);
    }

    pub fn createSymlink(self: FsContext, target: []const u8, link: []const u8) !void {
        const function = self.symlinkFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, target, link);
    }

    pub fn readlink(self: FsContext, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const function = self.readlinkFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, allocator, path);
    }

    pub fn createHardLink(self: FsContext, target: []const u8, link: []const u8) !void {
        const function = self.hardlinkFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, target, link);
    }

    pub fn realpath(self: FsContext, allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
        const function = self.realpathFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, allocator, path);
    }

    pub fn rename(self: FsContext, source: []const u8, destination: []const u8) !void {
        const function = self.renameFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, source, destination);
    }

    pub fn unlink(self: FsContext, path: []const u8) !void {
        const function = self.unlinkFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path);
    }

    pub fn rmdir(self: FsContext, path: []const u8) !void {
        const function = self.rmdirFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path);
    }

    pub fn hasStat(self: FsContext) bool {
        return self.statFn != null;
    }

    pub fn hasSymlink(self: FsContext) bool {
        return self.symlinkFn != null;
    }

    pub fn hasReadlink(self: FsContext) bool {
        return self.readlinkFn != null;
    }

    pub fn hasHardLink(self: FsContext) bool {
        return self.hardlinkFn != null;
    }

    pub fn hasRealpath(self: FsContext) bool {
        return self.realpathFn != null;
    }

    pub fn hasRename(self: FsContext) bool {
        return self.renameFn != null;
    }

    pub fn hasUnlink(self: FsContext) bool {
        return self.unlinkFn != null;
    }

    pub fn hasRmdir(self: FsContext) bool {
        return self.rmdirFn != null;
    }
};

/// POSIX権限・所有者・UID/GID・accessドメインのHostコールバック。
pub const PosixContext = struct {
    context: *anyopaque,
    chmodFn: ?*const fn (context: *anyopaque, path: []const u8, mode: u32) anyerror!void = null,
    chownFn: ?*const fn (context: *anyopaque, path: []const u8, uid: ?u32, gid: ?u32, follow: bool) anyerror!void = null,
    accessFn: ?*const fn (context: *anyopaque, path: []const u8, mode: u32) anyerror!bool = null,
    idFn: ?*const fn (context: *anyopaque, kind: low_level_posix.IdKind) anyerror!u32 = null,
    groupsFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]u32 = null,
    umaskFn: ?*const fn (context: *anyopaque, mode: u32) anyerror!u32 = null,

    pub fn chmod(self: PosixContext, path: []const u8, mode: u32) !void {
        const function = self.chmodFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path, mode);
    }

    pub fn chown(self: PosixContext, path: []const u8, uid: ?u32, gid: ?u32, follow: bool) !void {
        const function = self.chownFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path, uid, gid, follow);
    }

    pub fn access(self: PosixContext, path: []const u8, mode: u32) !bool {
        const function = self.accessFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, path, mode);
    }

    pub fn id(self: PosixContext, kind: low_level_posix.IdKind) !u32 {
        const function = self.idFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, kind);
    }

    pub fn groups(self: PosixContext, allocator: std.mem.Allocator) ![]u32 {
        const function = self.groupsFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, allocator);
    }

    pub fn umask(self: PosixContext, mode: u32) !u32 {
        const function = self.umaskFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, mode);
    }

    pub fn hasChmod(self: PosixContext) bool {
        return self.chmodFn != null;
    }

    pub fn hasChown(self: PosixContext) bool {
        return self.chownFn != null;
    }

    pub fn hasAccess(self: PosixContext) bool {
        return self.accessFn != null;
    }

    pub fn hasUidGid(self: PosixContext) bool {
        return self.idFn != null and self.groupsFn != null and self.umaskFn != null;
    }
};

/// Raw Stdio（stdin/stderr/stdoutのバイト入出力）ドメインのHostコールバック。
pub const StdioContext = struct {
    context: *anyopaque,
    /// Issue #28: stdinの単一source of truth。`標準入力バイト読む` と
    /// テキスト系stdin命令（`plugin_node` 経由）が同じ `StdinSource` の
    /// `consumed` カーソルを消費する。sourceはhost側（CliHost等）が所有し、
    /// peekは生成せず既存を返し、stdinSourceFnは無ければ生成する。
    /// `allocator` 引数は助言的で、実装はhost寿命のallocatorで確保すること
    /// （呼び出し側の短命runtime allocatorでsourceを確保するとUAFになる）。
    /// peekとstdinSourceFnはセットで提供すること（peek欠落だとTTY `尋` が
    /// 共有sourceを見落とし直接行readへ切り替わってバイトを置き去りにする）。
    peekStdinSourceFn: ?*const fn (context: *anyopaque) ?*low_level_io.StdinSource = null,
    stdinSourceFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!*low_level_io.StdinSource = null,
    writeStdoutBytesFn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!usize = null,
    writeStderrBytesFn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!usize = null,
    syncStdoutFn: ?*const fn (context: *anyopaque) anyerror!void = null,
    syncStderrFn: ?*const fn (context: *anyopaque) anyerror!void = null,

    pub fn stdinSource(self: StdioContext, allocator: std.mem.Allocator) !*low_level_io.StdinSource {
        const function = self.stdinSourceFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, allocator);
    }

    pub fn writeStdoutBytes(self: StdioContext, bytes: []const u8) !usize {
        const function = self.writeStdoutBytesFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, bytes);
    }

    pub fn writeStderrBytes(self: StdioContext, bytes: []const u8) !usize {
        const function = self.writeStderrBytesFn orelse return error.LowLevelIoUnavailable;
        return function(self.context, bytes);
    }

    pub fn syncStdout(self: StdioContext) !void {
        const function = self.syncStdoutFn orelse return error.LowLevelIoUnavailable;
        return function(self.context);
    }

    pub fn syncStderr(self: StdioContext) !void {
        const function = self.syncStderrFn orelse return error.LowLevelIoUnavailable;
        return function(self.context);
    }

    pub fn hasRawStdio(self: StdioContext) bool {
        return self.stdinSourceFn != null and self.peekStdinSourceFn != null and self.writeStdoutBytesFn != null and self.writeStderrBytesFn != null and self.syncStdoutFn != null and self.syncStderrFn != null;
    }
};

const empty_stream: StreamContext = .{ .context = default_host };
const empty_hash: HashContext = .{ .context = default_host };
const empty_fs: FsContext = .{ .context = default_host };
const empty_posix: PosixContext = .{ .context = default_host };
const empty_stdio: StdioContext = .{ .context = default_host };

/// 各ランタイム（Interpreter/AOT）がHostから受け取る低レイヤーI/O契約。
/// ドメイン別サブContextへ分割し、Hostはドメインごとに関数を実装する。
/// `Context` 自体はなでしこ値に依存しない。
pub const Context = struct {
    stream: StreamContext = empty_stream,
    hash: HashContext = empty_hash,
    fs: FsContext = empty_fs,
    posix: PosixContext = empty_posix,
    stdio: StdioContext = empty_stdio,

    pub fn openFile(self: Context, path: []const u8, mode: foundation.OpenMode, exclusive: bool, sync: bool) !u64 {
        return self.stream.openFile(path, mode, exclusive, sync);
    }

    pub fn closeFile(self: Context, raw: u64) !void {
        return self.stream.closeFile(raw);
    }

    pub fn readFileBytes(self: Context, raw: u64, buffer: []u8) !usize {
        return self.stream.readFileBytes(raw, buffer);
    }

    pub fn writeFileBytes(self: Context, raw: u64, bytes: []const u8) !usize {
        return self.stream.writeFileBytes(raw, bytes);
    }

    pub fn syncFile(self: Context, raw: u64) !void {
        return self.stream.syncFile(raw);
    }

    pub fn truncateFile(self: Context, raw: u64, size: u64) !void {
        return self.stream.truncateFile(raw, size);
    }

    pub fn createHash(self: Context, algorithm: []const u8) !u64 {
        return self.hash.createHash(algorithm);
    }

    pub fn updateHash(self: Context, raw: u64, bytes: []const u8) !void {
        return self.hash.updateHash(raw, bytes);
    }

    pub fn digestHash(self: Context, raw: u64, allocator: std.mem.Allocator) ![]u8 {
        return self.hash.digestHash(raw, allocator);
    }

    pub fn discardHash(self: Context, raw: u64) !void {
        return self.hash.discardHash(raw);
    }

    pub fn stat(self: Context, path: []const u8, follow: bool) !low_level_fs.Metadata {
        return self.fs.stat(path, follow);
    }

    pub fn createSymlink(self: Context, target: []const u8, link: []const u8) !void {
        return self.fs.createSymlink(target, link);
    }

    pub fn readlink(self: Context, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return self.fs.readlink(allocator, path);
    }

    pub fn createHardLink(self: Context, target: []const u8, link: []const u8) !void {
        return self.fs.createHardLink(target, link);
    }

    pub fn realpath(self: Context, allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
        return self.fs.realpath(allocator, path);
    }

    pub fn rename(self: Context, source: []const u8, destination: []const u8) !void {
        return self.fs.rename(source, destination);
    }

    pub fn unlink(self: Context, path: []const u8) !void {
        return self.fs.unlink(path);
    }

    pub fn rmdir(self: Context, path: []const u8) !void {
        return self.fs.rmdir(path);
    }

    pub fn chmod(self: Context, path: []const u8, mode: u32) !void {
        return self.posix.chmod(path, mode);
    }

    pub fn chown(self: Context, path: []const u8, uid: ?u32, gid: ?u32, follow: bool) !void {
        return self.posix.chown(path, uid, gid, follow);
    }

    pub fn access(self: Context, path: []const u8, mode: u32) !bool {
        return self.posix.access(path, mode);
    }

    pub fn id(self: Context, kind: low_level_posix.IdKind) !u32 {
        return self.posix.id(kind);
    }

    pub fn groups(self: Context, allocator: std.mem.Allocator) ![]u32 {
        return self.posix.groups(allocator);
    }

    pub fn umask(self: Context, mode: u32) !u32 {
        return self.posix.umask(mode);
    }

    pub fn stdinSource(self: Context, allocator: std.mem.Allocator) !*low_level_io.StdinSource {
        return self.stdio.stdinSource(allocator);
    }

    pub fn writeStdoutBytes(self: Context, bytes: []const u8) !usize {
        return self.stdio.writeStdoutBytes(bytes);
    }

    pub fn writeStderrBytes(self: Context, bytes: []const u8) !usize {
        return self.stdio.writeStderrBytes(bytes);
    }

    pub fn syncStdout(self: Context) !void {
        return self.stdio.syncStdout();
    }

    pub fn syncStderr(self: Context) !void {
        return self.stdio.syncStderr();
    }

    pub fn hasStreamFileIo(self: Context) bool {
        return self.stream.hasStreamFileIo();
    }

    pub fn hasTruncate(self: Context) bool {
        return self.stream.hasTruncate();
    }

    pub fn hasIncrementalHash(self: Context) bool {
        return self.hash.hasIncrementalHash();
    }

    pub fn hasStat(self: Context) bool {
        return self.fs.hasStat();
    }

    pub fn hasSymlink(self: Context) bool {
        return self.fs.hasSymlink();
    }

    pub fn hasReadlink(self: Context) bool {
        return self.fs.hasReadlink();
    }

    pub fn hasHardLink(self: Context) bool {
        return self.fs.hasHardLink();
    }

    pub fn hasRealpath(self: Context) bool {
        return self.fs.hasRealpath();
    }

    pub fn hasRename(self: Context) bool {
        return self.fs.hasRename();
    }

    pub fn hasUnlink(self: Context) bool {
        return self.fs.hasUnlink();
    }

    pub fn hasRmdir(self: Context) bool {
        return self.fs.hasRmdir();
    }

    pub fn hasChmod(self: Context) bool {
        return self.posix.hasChmod();
    }

    pub fn hasChown(self: Context) bool {
        return self.posix.hasChown();
    }

    pub fn hasAccess(self: Context) bool {
        return self.posix.hasAccess();
    }

    pub fn hasUidGid(self: Context) bool {
        return self.posix.hasUidGid();
    }

    pub fn hasRawStdio(self: Context) bool {
        return self.stdio.hasRawStdio();
    }
};

/// lnako 0.2.0までのフラットなHost契約（`.context`, `.openFileFn`, `.statFn` …）。
/// Issue #96で `Context` をサブContext化したため、外部Host実装の移行を機械的に
/// するための互換初期化型。`toContext()` でドメイン別Contextへ詰め替える。
///
/// 注意: これは構造体リテラルの完全互換ではない。既存コードの
/// `Context{ .context = host, .openFileFn = open }` は
/// `FlatContext{ .context = host, .openFileFn = open }.toContext()` へ
/// 書き換える必要がある。lnako本体のHost（`CliHost`）とAOTは移行済み。
pub const FlatContext = struct {
    context: *anyopaque,
    openFileFn: ?*const fn (context: *anyopaque, path: []const u8, mode: foundation.OpenMode, exclusive: bool, sync: bool) anyerror!u64 = null,
    closeFileFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,
    readFileBytesFn: ?*const fn (context: *anyopaque, raw: u64, buffer: []u8) anyerror!usize = null,
    writeFileBytesFn: ?*const fn (context: *anyopaque, raw: u64, bytes: []const u8) anyerror!usize = null,
    syncFileFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,
    truncateFileFn: ?*const fn (context: *anyopaque, raw: u64, size: u64) anyerror!void = null,
    createHashFn: ?*const fn (context: *anyopaque, algorithm: []const u8) anyerror!u64 = null,
    updateHashFn: ?*const fn (context: *anyopaque, raw: u64, bytes: []const u8) anyerror!void = null,
    digestHashFn: ?*const fn (context: *anyopaque, raw: u64, allocator: std.mem.Allocator) anyerror![]u8 = null,
    discardHashFn: ?*const fn (context: *anyopaque, raw: u64) anyerror!void = null,
    statFn: ?*const fn (context: *anyopaque, path: []const u8, follow: bool) anyerror!low_level_fs.Metadata = null,
    symlinkFn: ?*const fn (context: *anyopaque, target: []const u8, link: []const u8) anyerror!void = null,
    readlinkFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 = null,
    hardlinkFn: ?*const fn (context: *anyopaque, target: []const u8, link: []const u8) anyerror!void = null,
    realpathFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror![:0]u8 = null,
    renameFn: ?*const fn (context: *anyopaque, source: []const u8, destination: []const u8) anyerror!void = null,
    unlinkFn: ?*const fn (context: *anyopaque, path: []const u8) anyerror!void = null,
    rmdirFn: ?*const fn (context: *anyopaque, path: []const u8) anyerror!void = null,
    chmodFn: ?*const fn (context: *anyopaque, path: []const u8, mode: u32) anyerror!void = null,
    chownFn: ?*const fn (context: *anyopaque, path: []const u8, uid: ?u32, gid: ?u32, follow: bool) anyerror!void = null,
    accessFn: ?*const fn (context: *anyopaque, path: []const u8, mode: u32) anyerror!bool = null,
    idFn: ?*const fn (context: *anyopaque, kind: low_level_posix.IdKind) anyerror!u32 = null,
    groupsFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror![]u32 = null,
    umaskFn: ?*const fn (context: *anyopaque, mode: u32) anyerror!u32 = null,
    peekStdinSourceFn: ?*const fn (context: *anyopaque) ?*low_level_io.StdinSource = null,
    stdinSourceFn: ?*const fn (context: *anyopaque, allocator: std.mem.Allocator) anyerror!*low_level_io.StdinSource = null,
    writeStdoutBytesFn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!usize = null,
    writeStderrBytesFn: ?*const fn (context: *anyopaque, bytes: []const u8) anyerror!usize = null,
    syncStdoutFn: ?*const fn (context: *anyopaque) anyerror!void = null,
    syncStderrFn: ?*const fn (context: *anyopaque) anyerror!void = null,

    pub fn toContext(self: FlatContext) Context {
        return .{
            .stream = .{
                .context = self.context,
                .openFileFn = self.openFileFn,
                .closeFileFn = self.closeFileFn,
                .readFileBytesFn = self.readFileBytesFn,
                .writeFileBytesFn = self.writeFileBytesFn,
                .syncFileFn = self.syncFileFn,
                .truncateFileFn = self.truncateFileFn,
            },
            .hash = .{
                .context = self.context,
                .createHashFn = self.createHashFn,
                .updateHashFn = self.updateHashFn,
                .digestHashFn = self.digestHashFn,
                .discardHashFn = self.discardHashFn,
            },
            .fs = .{
                .context = self.context,
                .statFn = self.statFn,
                .symlinkFn = self.symlinkFn,
                .readlinkFn = self.readlinkFn,
                .hardlinkFn = self.hardlinkFn,
                .realpathFn = self.realpathFn,
                .renameFn = self.renameFn,
                .unlinkFn = self.unlinkFn,
                .rmdirFn = self.rmdirFn,
            },
            .posix = .{
                .context = self.context,
                .chmodFn = self.chmodFn,
                .chownFn = self.chownFn,
                .accessFn = self.accessFn,
                .idFn = self.idFn,
                .groupsFn = self.groupsFn,
                .umaskFn = self.umaskFn,
            },
            .stdio = .{
                .context = self.context,
                .peekStdinSourceFn = self.peekStdinSourceFn,
                .stdinSourceFn = self.stdinSourceFn,
                .writeStdoutBytesFn = self.writeStdoutBytesFn,
                .writeStderrBytesFn = self.writeStderrBytesFn,
                .syncStdoutFn = self.syncStdoutFn,
                .syncStderrFn = self.syncStderrFn,
            },
        };
    }
};

pub fn emptyContext() Context {
    return .{};
}

test "FlatContextは旧フラット契約をドメイン別Contextへ詰め替える" {
    const statFn = struct {
        fn call(_: *anyopaque, _: []const u8, _: bool) anyerror!low_level_fs.Metadata {
            return error.Unexpected;
        }
    }.call;
    const writeFn = struct {
        fn call(_: *anyopaque, _: []const u8) anyerror!usize {
            return 0;
        }
    }.call;
    var host: u8 = 0;
    const flat = FlatContext{
        .context = @ptrCast(&host),
        .statFn = statFn,
        .writeStdoutBytesFn = writeFn,
    };
    const converted = flat.toContext();
    try std.testing.expect(converted.fs.statFn == statFn);
    try std.testing.expect(converted.fs.context == @as(*anyopaque, @ptrCast(&host)));
    try std.testing.expect(converted.stdio.writeStdoutBytesFn == writeFn);
    try std.testing.expect(converted.stream.openFileFn == null);
    try std.testing.expect(converted.hasStat());
    try std.testing.expect(!converted.hasStreamFileIo());
}
