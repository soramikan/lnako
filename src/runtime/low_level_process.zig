const std = @import("std");
const builtin = @import("builtin");
const foundation = @import("low_level_foundation.zig");
const low_level_io = @import("low_level_io.zig");

/// `プロセス起動` OPTIONSで受け取る環境変数1件。値はWTF-8。
pub const EnvEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// `プロセス起動` OPTIONS。cwd/env/stdio/detachedを表す。
/// envがnullなら親環境を継承し、非nullならその集合で置き換える（Nodeと同じ）。
pub const SpawnOptions = struct {
    cwd: ?[]const u8 = null,
    env: ?[]const EnvEntry = null,
    stdin: foundation.ProcessStdioMode = .inherit,
    stdout: foundation.ProcessStdioMode = .inherit,
    stderr: foundation.ProcessStdioMode = .inherit,
    detached: bool = false,
};

/// `プロセス待機` の結果。`signal` は正常終了時null、
/// シグナル終了時は `exit_code` が `128 + signal` になる（shellと同じ慣例）。
pub const WaitResult = struct {
    exit_code: i32,
    signal: ?u32,
};

pub const TtySize = struct {
    rows: u16,
    columns: u16,
};

/// Spawn済みプロセスのentry。`std.process.Child` がOS側のハンドルと
/// pipe（stdio=pipe時）を所有する。waitで再利用しないようtableから取り除く。
pub const ProcessEntry = struct {
    id: foundation.HandleId,
    child: std.process.Child,
    /// detached起動。deinit時に強制終了せず、reaper threadで非同期にreapする。
    detached: bool = false,
};

/// deinit時に引き取ったdetached子を待ってreapするthread。長寿命の子でも
/// Runtimeを停止させず、子の終了後にゾンビを残さない。RuntimeのIo/allocatorは
/// 先に破棄され得るため借用せず、生成物に依存しないglobal Ioと
/// page_allocatorだけを使う（detachedはstdio=pipeを禁止しており、drainも不要）。
const DetachedReaper = struct {
    child: *std.process.Child,

    fn run(self: *DetachedReaper) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        _ = self.child.wait(io) catch {};
        std.heap.page_allocator.destroy(self.child);
        std.heap.page_allocator.destroy(self);
    }
};

/// detached子をreaper threadへ引き渡す。threadを起動できない場合は
/// ゾンビを残さないよう同期回収へフォールバックする。Runtimeより長生きし得る
/// reaperはRuntimeのallocator/Ioを借用せず、page_allocatorとglobal Ioを使う。
fn handOffDetached(io: std.Io, child: *std.process.Child) void {
    if (comptime builtin.os.tag == .windows) {
        // detachedはWindowsではENOTSUPのため到達しない。
        killChild(io, child);
        return;
    }
    const owned_child = std.heap.page_allocator.create(std.process.Child) catch {
        killChild(io, child);
        return;
    };
    owned_child.* = child.*;
    const reaper = std.heap.page_allocator.create(DetachedReaper) catch {
        killChild(io, owned_child);
        std.heap.page_allocator.destroy(owned_child);
        return;
    };
    reaper.* = .{ .child = owned_child };
    const thread = std.Thread.spawn(.{}, DetachedReaper.run, .{reaper}) catch {
        killChild(io, owned_child);
        std.heap.page_allocator.destroy(owned_child);
        std.heap.page_allocator.destroy(reaper);
        return;
    };
    thread.detach();
}

/// プロセスhandleの表。`HandleId` のindex空間
/// `[process_handle_index_base, hash_handle_index_base)` を使い、
/// 同じraw値をファイル/ハッシュhandleと共有しない。
pub const ProcessTable = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(ProcessEntry) = .empty,
    generations: std.AutoHashMap(u32, u32),
    free_indices: std.ArrayList(u32) = .empty,
    next_index: u32 = foundation.process_handle_index_base,

    pub fn init(allocator: std.mem.Allocator) ProcessTable {
        return .{ .allocator = allocator, .generations = std.AutoHashMap(u32, u32).init(allocator) };
    }

    /// waitされていない子プロセスを後始末する。detachedの子は親の終了後も
    /// 走り続けられるよう強制終了しないが、ゾンビを残さないよう、専用の
    /// reaper threadへ移して非同期にreapする。
    pub fn deinit(self: *ProcessTable, io: std.Io) void {
        for (self.entries.items) |*entry| {
            if (entry.detached) {
                handOffDetached(io, &entry.child);
                continue;
            }
            if (entry.child.id != null) killChild(io, &entry.child);
        }
        self.entries.deinit(self.allocator);
        self.generations.deinit();
        self.free_indices.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn len(self: *const ProcessTable) usize {
        return self.entries.items.len;
    }

    pub fn find(self: *ProcessTable, id: foundation.HandleId) ?*ProcessEntry {
        for (self.entries.items) |*entry| {
            if (entry.id.index == id.index and entry.id.generation == id.generation) return entry;
        }
        return null;
    }

    pub fn remove(self: *ProcessTable, id: foundation.HandleId) ?ProcessEntry {
        for (self.entries.items, 0..) |*entry, index| {
            if (entry.id.index == id.index and entry.id.generation == id.generation) {
                const removed = self.entries.swapRemove(index);
                if (self.generations.getPtr(id.index)) |generation| {
                    generation.* = generation.* +% 1;
                    if (generation.* == 0) generation.* = 1;
                }
                // OOMでfree listへ戻せない場合は世代表から外し、sequential scanで
                // 再利用できるようにする（indexが永久にスキップされない）。
                self.free_indices.append(self.allocator, id.index) catch {
                    _ = self.generations.remove(id.index);
                };
                return removed;
            }
        }
        return null;
    }

    fn allocateId(self: *ProcessTable) !foundation.HandleId {
        if (self.free_indices.pop()) |index| {
            const generation = self.generations.get(index) orelse 1;
            return .{ .index = index, .generation = if (generation == 0) 1 else generation };
        }
        var index: u32 = self.next_index;
        if (index < foundation.process_handle_index_base or index >= foundation.hash_handle_index_base) {
            index = foundation.process_handle_index_base;
        }
        while (self.generations.contains(index)) {
            index +%= 1;
            if (index >= foundation.hash_handle_index_base) index = foundation.process_handle_index_base;
        }
        try self.generations.put(index, 1);
        self.next_index = index +% 1;
        if (self.next_index >= foundation.hash_handle_index_base) self.next_index = foundation.process_handle_index_base;
        return .{ .index = index, .generation = 1 };
    }

    /// shellを介さず `argv` をそのまま子プロセスへ渡す。stdio=pipeの親側は
    /// entryが保持し、wait時にdrainしてから回収する。
    pub fn spawn(self: *ProcessTable, io: std.Io, argv: []const []const u8, options: SpawnOptions) !foundation.HandleId {
        if (argv.len == 0) return error.InvalidArgument;
        // detachedは親が再びwaitしないため、drainする主体のいないpipe stdioは
        // 子のブロックを招く。pipeとの併用はEINVALで拒否する。
        if (options.detached and (options.stdin == .pipe or options.stdout == .pipe or options.stderr == .pipe)) {
            return error.InvalidArgument;
        }
        // WindowsはCREATE_NEW_PROCESS_GROUP/DETACHED_PROCESSをZigの
        // SpawnOptionsが公開しないため、detachedはENOTSUPにする。
        if (options.detached and builtin.os.tag == .windows) return error.OperationUnsupported;

        var environ_map: std.process.Environ.Map = .init(self.allocator);
        defer environ_map.deinit();
        if (options.env) |entries| {
            for (entries) |entry| {
                if (entry.name.len == 0) return error.InvalidArgument;
                environ_map.put(entry.name, entry.value) catch |failure| switch (failure) {
                    error.OutOfMemory => return failure,
                };
            }
        }

        var spawn_options: std.process.SpawnOptions = .{
            .argv = argv,
            .cwd = if (options.cwd) |cwd| .{ .path = cwd } else .inherit,
            .environ_map = if (options.env != null) &environ_map else null,
            .stdin = stdioFor(options.stdin),
            .stdout = stdioFor(options.stdout),
            .stderr = stdioFor(options.stderr),
        };
        // pgidはPOSIX専用（Windowsのpid_tはHANDLE型）。detachedは
        // 新しいプロセスグループを作り、親のシグナル配送から切り離す。
        if (comptime builtin.os.tag != .windows) {
            if (options.detached) spawn_options.pgid = 0;
        }
        var child = try std.process.spawn(io, spawn_options);
        errdefer killChild(io, &child);

        const id = try self.allocateId();
        errdefer self.free_indices.append(self.allocator, id.index) catch {};
        try self.entries.append(self.allocator, .{ .id = id, .child = child, .detached = options.detached });
        return id;
    }

    /// 子プロセスの終了を待つ。stdio=pipeの親側を先に閉じ/drainして
    /// 子がpipe bufferで停止しないようにする。成否に関わらずhandleは
    /// 消費し、再waitはEBADFにする（ZigのChild.waitはPOSIXでは失敗時も
    /// idをnullへ掃除するが、Windowsでは残り得るため）。
    pub fn wait(self: *ProcessTable, io: std.Io, id: foundation.HandleId) !WaitResult {
        const entry = self.find(id) orelse return error.InvalidHandle;
        drainPipes(io, self.allocator, &entry.child) catch |failure| {
            killChild(io, &entry.child);
            _ = self.remove(id);
            return failure;
        };
        const term = entry.child.wait(io) catch |failure| {
            if (entry.child.id != null) killChild(io, &entry.child);
            _ = self.remove(id);
            return failure;
        };
        _ = self.remove(id);
        return waitResultFromTerm(term);
    }

    /// handleをwaitせずに破棄する。子プロセスを強制終了してreapする。
    pub fn discard(self: *ProcessTable, io: std.Io, id: foundation.HandleId) !void {
        const entry = self.find(id) orelse return error.InvalidHandle;
        if (entry.child.id != null) killChild(io, &entry.child);
        _ = self.remove(id);
    }
};

fn stdioFor(mode: foundation.ProcessStdioMode) std.process.SpawnOptions.StdIo {
    return switch (mode) {
        .inherit => .inherit,
        .pipe => .pipe,
        .null_ => .ignore,
    };
}

/// 子プロセスを強制終了してreapする。Zigの `Child.kill` はSIGTERMを送って
/// 無期限に待つだけなので、SIGTERMを無視する子でハングしないようPOSIXでは
/// SIGKILLを送ってからwaitで回収する。SIGKILLは無視できないため、
/// `Child.kill` のSIGTERM再送は不要（ESRCHでのpanicも避ける）。Windowsは
/// `Child.kill` がNtTerminateProcessで終了する。
fn killChild(io: std.Io, child: *std.process.Child) void {
    if (comptime builtin.os.tag != .windows) {
        if (child.id) |id| std.posix.kill(@intCast(id), .KILL) catch {};
        if (child.id != null) _ = child.wait(io) catch {};
        return;
    }
    child.kill(io);
}

/// 子プロセスのstdin pipe（親の書込み端）を閉じてEOFを伝え、
/// stdout/stderr pipeをEOFまで読んで捨てる。読まずにwaitすると、
/// pipe bufferが埋まった子が停止してデッドロックする。
fn drainPipes(io: std.Io, allocator: std.mem.Allocator, child: *std.process.Child) !void {
    if (child.stdin) |file| {
        file.close(io);
        child.stdin = null;
    }
    const has_stdout = child.stdout != null;
    const has_stderr = child.stderr != null;
    if (!has_stdout and !has_stderr) return;
    if (has_stdout and has_stderr) {
        var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
        var multi_reader: std.Io.File.MultiReader = undefined;
        multi_reader.init(allocator, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
        defer multi_reader.deinit();
        // 読み捨てるだけなので各fill後にbuffered分をtossし、MultiReaderの
        // バッファが子の出力量に比例して増えないようにする。
        while (true) {
            multi_reader.fill(64, .none) catch |failure| switch (failure) {
                error.EndOfStream => break,
                else => return failure,
            };
            multi_reader.reader(0).tossBuffered();
            multi_reader.reader(1).tossBuffered();
        }
        try multi_reader.checkAnyError();
        return;
    }
    const file = child.stdout orelse child.stderr.?;
    var discard: [4096]u8 = undefined;
    while (true) {
        const read = low_level_io.readAtCurrent(io, file, &discard) catch |failure| switch (failure) {
            error.EndOfStream => return,
            else => return failure,
        };
        if (read == 0) return;
    }
}

fn waitResultFromTerm(term: std.process.Child.Term) WaitResult {
    return switch (term) {
        .exited => |code| .{ .exit_code = code, .signal = null },
        .signal => |signal| signalResult(@intFromEnum(signal)),
        .stopped => |signal| signalResult(@intFromEnum(signal)),
        .unknown => .{ .exit_code = -1, .signal = null },
    };
}

fn signalResult(signal: u32) WaitResult {
    return .{
        .exit_code = @intCast(foundation.signal_exit_code_offset + signal),
        .signal = signal,
    };
}

/// 現在のプロセスID。実行時に0は返らない。
pub fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .windows => @intCast(std.os.windows.GetCurrentProcessId()),
        else => @intCast(std.c.getpid()),
    };
}

/// 親プロセスID。WindowsはNtdllのBasicInformationから取得する。
pub fn parentPid() !u32 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            var info: std.os.windows.PROCESS.BASIC_INFORMATION = undefined;
            var length: std.os.windows.ULONG = 0;
            const status = std.os.windows.ntdll.NtQueryInformationProcess(
                std.os.windows.GetCurrentProcess(),
                .BasicInformation,
                &info,
                @sizeOf(std.os.windows.PROCESS.BASIC_INFORMATION),
                &length,
            );
            if (status != .SUCCESS) return error.OperationUnsupported;
            if (info.InheritedFromUniqueProcessId == 0) return error.OperationUnsupported;
            break :blk @intCast(info.InheritedFromUniqueProcessId);
        },
        else => @intCast(std.c.getppid()),
    };
}

/// POSIX信号番号 `signal` を `pid` へ送る。Windowsは
/// existence check(0) と terminate(9/15) だけをサポートし、
/// それ以外はENOTSUPにする（catalog notesの部分対応）。
pub fn sendSignal(pid: u32, signal: u32) !void {
    if (pid == 0) return error.InvalidSignal;
    if (builtin.os.tag == .windows) return sendSignalWindows(pid, signal);
    // 公開契約はu32だがPOSIXのpid_tは符号付き。pid_tの上限を超える値は
    // 検査付きキャストでpanicするため、先にEINVALへ写す。
    if (pid > @as(u32, @intCast(std.math.maxInt(std.posix.pid_t)))) return error.InvalidSignal;
    if (signal == 0) {
        std.posix.kill(@intCast(pid), @enumFromInt(0)) catch |failure| return switch (failure) {
            error.ProcessNotFound => error.ProcessNotFound,
            error.PermissionDenied => error.PermissionDenied,
            error.Unexpected => error.Unexpected,
        };
        return;
    }
    if (signal > 31) return error.InvalidSignal;
    std.posix.kill(@intCast(pid), @enumFromInt(signal)) catch |failure| return switch (failure) {
        error.ProcessNotFound => error.ProcessNotFound,
        error.PermissionDenied => error.PermissionDenied,
        error.Unexpected => error.Unexpected,
    };
}

const WindowsProcess = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const PROCESS_TERMINATE: windows.DWORD = 0x0001;
    const SYNCHRONIZE: windows.DWORD = 0x00100000;

    extern "kernel32" fn OpenProcess(
        dwDesiredAccess: windows.DWORD,
        bInheritHandle: windows.BOOL,
        dwProcessId: windows.DWORD,
    ) callconv(.winapi) ?windows.HANDLE;

    extern "kernel32" fn TerminateProcess(
        hProcess: windows.HANDLE,
        uExitCode: windows.UINT,
    ) callconv(.winapi) windows.BOOL;

    extern "kernel32" fn GetProcessId(Process: windows.HANDLE) callconv(.winapi) windows.DWORD;
} else struct {};

/// Childが表すプロセスのPID。POSIXはChild.idそのもの、WindowsはHANDLEから
/// GetProcessIdで引く。`シグナル送信` はPIDを取るため、テストや将来の
/// APIが子のPIDを必要とするときに使う。
pub fn childPid(child: *const std.process.Child) ?u32 {
    if (builtin.os.tag == .windows) {
        const handle = child.id orelse return null;
        const pid = WindowsProcess.GetProcessId(handle);
        return if (pid == 0) null else pid;
    }
    const id = child.id orelse return null;
    return @intCast(id);
}

fn sendSignalWindows(pid: u32, signal: u32) !void {
    if (builtin.os.tag != .windows) return error.OperationUnsupported;
    if (signal == 0) {
        const handle = try openProcessForSignal(WindowsProcess.SYNCHRONIZE, pid);
        std.os.windows.CloseHandle(handle);
        return;
    }
    // SIGKILL(9)/SIGTERM(15) はTerminateProcessへ写す。それ以外はENOTSUP。
    if (signal != 9 and signal != 15) return error.UnsupportedSignal;
    const handle = try openProcessForSignal(WindowsProcess.PROCESS_TERMINATE, pid);
    defer std.os.windows.CloseHandle(handle);
    if (!WindowsProcess.TerminateProcess(handle, 1).toBool()) return error.PermissionDenied;
}

/// OpenProcessの失敗をGetLastErrorで分類する。ERROR_ACCESS_DENIEDは
/// 権限不足(EPERM)、それ以外（無効PIDを含む）は対象不在(EINVAL)へ写す。
fn openProcessForSignal(access: std.os.windows.DWORD, pid: u32) !std.os.windows.HANDLE {
    return WindowsProcess.OpenProcess(access, .FALSE, pid) orelse {
        const last_error = std.os.windows.GetLastError();
        return switch (last_error) {
            std.os.windows.Win32Error.ACCESS_DENIED => error.PermissionDenied,
            else => error.ProcessNotFound,
        };
    };
}

extern "c" fn getpriority(which: c_int, who: c_uint) c_int;
extern "c" fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;

const prio_process: c_int = 0;

/// プロセスのnice値（macOS/Linux）。WindowsはENOTSUP。
pub fn getPriority(pid: u32) !i32 {
    if (builtin.os.tag == .windows) return error.OperationUnsupported;
    const errno_location = std.c._errno();
    errno_location.* = 0;
    const result = getpriority(prio_process, pid);
    const err = errno_location.*;
    if (result == -1 and err != 0) return errnoToError(err);
    return result;
}

/// プロセスのnice値を設定する（macOS/Linux）。WindowsはENOTSUP。
pub fn setPriority(pid: u32, value: i32) !void {
    if (builtin.os.tag == .windows) return error.OperationUnsupported;
    const errno_location = std.c._errno();
    errno_location.* = 0;
    if (setpriority(prio_process, pid, value) != 0) return errnoToError(errno_location.*);
}

fn errnoToError(err: c_int) anyerror {
    return switch (err) {
        @intFromEnum(std.c.E.SRCH) => error.ProcessNotFound,
        @intFromEnum(std.c.E.PERM), @intFromEnum(std.c.E.ACCES) => error.PermissionDenied,
        @intFromEnum(std.c.E.INVAL) => error.InvalidArgument,
        else => error.Unexpected,
    };
}

/// 標準入出力ストリームが端末かどうか。`std.Io.File.isTty` は
/// POSIXのisattyとWindowsのGetConsoleMode相当を共通化する。
pub fn isTty(io: std.Io, file: std.Io.File) !bool {
    return file.isTty(io);
}

/// 端末サイズ。POSIXはTIOCGWINSZ、WindowsはGetConsoleScreenBufferInfo。
/// 非端末はENOTSUP。
pub fn ttySize(io: std.Io, file: std.Io.File) !TtySize {
    if (builtin.os.tag == .windows) return ttySizeWindows(file);
    if (!(file.isTty(io) catch false)) return error.OperationUnsupported;
    return switch (builtin.os.tag) {
        .linux => blk: {
            var size: std.posix.winsize = undefined;
            const result = std.os.linux.ioctl(file.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&size));
            if (std.os.linux.errno(result) != .SUCCESS) return error.OperationUnsupported;
            break :blk .{ .rows = size.row, .columns = size.col };
        },
        else => blk: {
            var size: std.posix.winsize = undefined;
            if (std.c.ioctl(file.handle, std.c.T.IOCGWINSZ, &size) != 0) return error.OperationUnsupported;
            break :blk .{ .rows = size.row, .columns = size.col };
        },
    };
}

const WindowsConsole = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;

    /// Win32のCONSOLE_SCREEN_BUFFER_INFO。Zigの
    /// `CONSOLE.USER_IO.INFO.SCREEN_BUFFER` はGetConsoleScreenBufferInfoEx用で
    /// ColorTableを持つためレイアウトが一致しない。GetConsoleScreenBufferInfo
    /// にはこの正しい構造体を渡す。
    const SMALL_RECT = extern struct {
        Left: i16,
        Top: i16,
        Right: i16,
        Bottom: i16,
    };
    const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
        dwSize: windows.COORD,
        dwCursorPosition: windows.COORD,
        wAttributes: u16,
        srWindow: SMALL_RECT,
        dwMaximumWindowSize: windows.COORD,
    };

    extern "kernel32" fn GetConsoleScreenBufferInfo(
        hConsoleOutput: windows.HANDLE,
        lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
    ) callconv(.winapi) windows.BOOL;
} else struct {};

fn ttySizeWindows(file: std.Io.File) !TtySize {
    if (builtin.os.tag != .windows) return error.OperationUnsupported;
    var raw: WindowsConsole.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (!WindowsConsole.GetConsoleScreenBufferInfo(file.handle, &raw).toBool()) return error.OperationUnsupported;
    const columns: i32 = @as(i32, raw.srWindow.Right) - @as(i32, raw.srWindow.Left) + 1;
    const rows: i32 = @as(i32, raw.srWindow.Bottom) - @as(i32, raw.srWindow.Top) + 1;
    if (columns <= 0 or rows <= 0) return error.OperationUnsupported;
    return .{ .rows = @intCast(rows), .columns = @intCast(columns) };
}

const testing = std.testing;

test "ProcessTableのindexはプロセス空間で巡回しファイル/ハッシュを侵さない" {
    var table = ProcessTable.init(testing.allocator);
    defer {
        for (table.entries.items) |*entry| entry.child.id = null;
        table.entries.deinit(testing.allocator);
        table.generations.deinit();
        table.free_indices.deinit(testing.allocator);
    }
    table.next_index = foundation.hash_handle_index_base;
    const id = try table.allocateId();
    try testing.expectEqual(foundation.process_handle_index_base, id.index);
    try testing.expect(table.next_index < foundation.hash_handle_index_base);

    const removed = table.remove(.{ .index = id.index, .generation = id.generation });
    try testing.expect(removed == null);
    // 直接allocateしたidはentriesに無いためremoveはnull。generationは進めない。
    var iterator = table.generations.iterator();
    while (iterator.next()) |entry| {
        try testing.expect(entry.key_ptr.* >= foundation.process_handle_index_base);
        try testing.expect(entry.key_ptr.* < foundation.hash_handle_index_base);
    }
}

test "WaitResultはシグナル終了を128+signalで表す" {
    const exited = waitResultFromTerm(.{ .exited = 3 });
    try testing.expectEqual(@as(i32, 3), exited.exit_code);
    try testing.expect(exited.signal == null);
    const signaled = waitResultFromTerm(.{ .signal = @enumFromInt(9) });
    try testing.expectEqual(@as(i32, 137), signaled.exit_code);
    try testing.expectEqual(@as(?u32, 9), signaled.signal);
}

test "currentPidは0を返さない" {
    try testing.expect(currentPid() != 0);
}

test "pid_t上限を超えるPIDはpanicせずEINVALへ写る" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try testing.expectError(error.InvalidSignal, sendSignal(std.math.maxInt(u32), 0));
    try testing.expectError(error.InvalidSignal, sendSignal(@as(u32, 1) << 31, 0));
}

test "spawnはargv境界を保持しpipe stdoutを読める" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);
    const id = try table.spawn(testing.io, &.{ "/bin/echo", "a b", "c'd", "e\"f" }, .{ .stdout = .pipe });
    const entry = table.find(id).?;
    var buffer: [256]u8 = undefined;
    var total: usize = 0;
    while (total < buffer.len) {
        const read = try low_level_io.readAtCurrent(testing.io, entry.child.stdout.?, buffer[total..]);
        if (read == 0) break;
        total += read;
    }
    const term = try entry.child.wait(testing.io);
    try testing.expectEqual(@as(u8, 0), term.exited);
    try testing.expectEqualStrings("a b c'd e\"f\n", buffer[0..total]);
    _ = table.remove(id);
}

test "spawnの終了コードとシグナル終了をwaitで取得する" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);

    const failed_id = try table.spawn(testing.io, &.{"/usr/bin/false"}, .{});
    const failed = try table.wait(testing.io, failed_id);
    try testing.expectEqual(@as(i32, 1), failed.exit_code);
    try testing.expect(failed.signal == null);
    try testing.expectEqual(@as(usize, 0), table.len());
    try testing.expectError(error.InvalidHandle, table.wait(testing.io, failed_id));

    const sleeping_id = try table.spawn(testing.io, &.{ "/bin/sleep", "30" }, .{});
    const entry = table.find(sleeping_id).?;
    const pid: u32 = @intCast(entry.child.id.?);
    try sendSignal(pid, 15);
    const killed = try table.wait(testing.io, sleeping_id);
    try testing.expectEqual(@as(i32, 128 + 15), killed.exit_code);
    try testing.expectEqual(@as(?u32, 15), killed.signal);
}

test "detachedや不正argvは構造化しない内部エラーになる" {
    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);
    try testing.expectError(error.InvalidArgument, table.spawn(testing.io, &.{}, .{}));
}

test "waitはpipe出力をdrainしてデッドロックしない" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);
    // 256KiBをstdout pipeへ書き、readerがdrainしないとpipe bufferで停止する。
    // stderrはddのrecords報告がtest runnerのprotocol channel(fd 2)へ漏れて
    // `zig build test`を破壊しないようnullへ捨てる。
    const id = try table.spawn(testing.io, &.{ "/bin/dd", "if=/dev/zero", "bs=1024", "count=256" }, .{ .stdout = .pipe, .stderr = .null_ });
    const result = try table.wait(testing.io, id);
    try testing.expectEqual(@as(i32, 0), result.exit_code);
    try testing.expect(result.signal == null);
}

test "waitはstdout/stderr両pipeをdrainしてデッドロックしない" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);
    // stdoutとstderrの両方へpipe buffer(通常64KiB)を超える200KiBを順に書き、
    // 2本同時にdrainできないと子が停止する。テスト子としてのみshを使う。
    const script = "dd if=/dev/zero bs=1024 count=200 2>/dev/null; dd if=/dev/zero bs=1024 count=200 1>&2 2>/dev/null";
    const id = try table.spawn(testing.io, &.{ "/bin/sh", "-c", script }, .{ .stdout = .pipe, .stderr = .pipe });
    const result = try table.wait(testing.io, id);
    try testing.expectEqual(@as(i32, 0), result.exit_code);
    try testing.expect(result.signal == null);
}

test "Windowsのspawn/wait/存在確認が動作する" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);
    const id = try table.spawn(testing.io, &.{ "cmd.exe", "/d", "/c", "exit", "3" }, .{});
    const result = try table.wait(testing.io, id);
    try testing.expectEqual(@as(i32, 3), result.exit_code);
    try testing.expect(result.signal == null);
    try sendSignal(currentPid(), 0);
}

test "Windowsの権限不足シグナルはEPERMになる" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // PID 4 (System) は保護されており、PROCESS_TERMINATEのOpenProcessが
    // ERROR_ACCESS_DENIEDを返す。EPERM（PermissionDenied）へ写ることを確認する。
    try testing.expectError(error.PermissionDenied, sendSignal(4, 15));
}

test "WindowsのTerminateProcessはexitCode=1とsignal=nullを返す" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);
    const id = try table.spawn(testing.io, &.{ "cmd.exe", "/d", "/c", "ping", "-n", "30", "127.0.0.1" }, .{ .stdin = .null_, .stdout = .null_, .stderr = .null_ });
    const entry = table.find(id).?;
    const pid = childPid(&entry.child) orelse return error.TestExpectedEqual;
    try sendSignal(pid, 15);
    const result = try table.wait(testing.io, id);
    try testing.expectEqual(@as(i32, 1), result.exit_code);
    try testing.expect(result.signal == null);
}

test "env置換は子の環境を置き換える" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);
    const env = [_]EnvEntry{.{ .name = "LNAKO_PROC_TEST", .value = "1" }};
    const id = try table.spawn(testing.io, &.{"/usr/bin/env"}, .{ .env = &env, .stdout = .pipe });
    const entry = table.find(id).?;
    var buffer: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buffer.len) {
        const read = try low_level_io.readAtCurrent(testing.io, entry.child.stdout.?, buffer[total..]);
        if (read == 0) break;
        total += read;
    }
    const output = buffer[0..total];
    try testing.expect(std.mem.indexOf(u8, output, "LNAKO_PROC_TEST=1") != null);
    try testing.expect(std.mem.indexOf(u8, output, "PATH=") == null);
    _ = try table.wait(testing.io, id);
}

test "cwd指定は子の作業ディレクトリへ反映される" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const directory = try temporary.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(directory);

    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);
    const id = try table.spawn(testing.io, &.{"/bin/pwd"}, .{ .cwd = directory, .stdout = .pipe });
    const entry = table.find(id).?;
    var buffer: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buffer.len) {
        const read = try low_level_io.readAtCurrent(testing.io, entry.child.stdout.?, buffer[total..]);
        if (read == 0) break;
        total += read;
    }
    const output = std.mem.trimEnd(u8, buffer[0..total], "\r\n");
    try testing.expectEqualStrings(directory, output);
    _ = try table.wait(testing.io, id);
}

test "detached起動でもシグナル送信と待機ができる" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);
    const id = try table.spawn(testing.io, &.{ "/bin/sleep", "30" }, .{ .detached = true });
    const entry = table.find(id).?;
    try testing.expect(entry.detached);
    const pid: u32 = @intCast(entry.child.id.?);
    try sendSignal(pid, 15);
    const killed = try table.wait(testing.io, id);
    try testing.expectEqual(@as(?u32, 15), killed.signal);
}

test "detachedとpipe stdioの併用はEINVALで拒否する" {
    var table = ProcessTable.init(testing.allocator);
    defer table.deinit(testing.io);
    try testing.expectError(error.InvalidArgument, table.spawn(testing.io, &.{"/bin/true"}, .{ .detached = true, .stdout = .pipe }));
    try testing.expectError(error.InvalidArgument, table.spawn(testing.io, &.{"/bin/true"}, .{ .detached = true, .stdin = .pipe }));
}
