const std = @import("std");
const builtin = @import("builtin");

pub const max_safe_integer: i64 = 9007199254740991;
pub const min_safe_integer: i64 = -9007199254740991;
pub const ns_per_us: i128 = 1_000;
pub const ns_per_ms: i128 = 1_000_000;
pub const ns_per_s: i128 = 1_000_000_000;
pub const unix_epoch_filetime_100ns: i128 = 116444736000000000;

pub const plugin_namespace = "plugin_lowlevel";
pub const bytes_plugin_kind: u32 = 6;
pub const bytes_typeof_name = "object";
pub const handle_typeof_name = "object";
pub const empty_bytes_means_eof = true;
pub const cnako_bytes_type = "Buffer";
pub const unsupported_error_code = PortableErrorCode.ENOTSUP;
pub const invalid_handle_error_code = PortableErrorCode.EBADF;
pub const capability_query_unknown_returns_false = true;
pub const structured_errors_apply_to_new_commands_only = true;
pub const aot_compiles_unsupported_calls = true;

pub const capability_supported_command = "低レイヤー機能対応判定";
pub const capability_list_command = "低レイヤー機能一覧取得";
pub const capability_query_particles = "NAMEの/NAMEを";

pub const Error = error{
    InvalidOffset,
    InvalidSize,
    InvalidTimestamp,
};

pub const PublicInteger = enum {
    number,
    bigint,
};

pub const HandleKind = enum {
    file,
    directory,
    hash,
    process,
};

pub const HandleId = packed struct(u64) {
    index: u32,
    generation: u32,

    pub const invalid: HandleId = .{ .index = 0, .generation = 0 };

    pub fn raw(self: HandleId) u64 {
        return @bitCast(self);
    }

    pub fn fromRaw(value: u64) HandleId {
        return @bitCast(value);
    }

    pub fn isValid(self: HandleId) bool {
        return self.index != 0 and self.generation != 0;
    }

    pub fn nextGeneration(self: HandleId) HandleId {
        const next = self.generation +% 1;
        return .{
            .index = self.index,
            .generation = if (next == 0) 1 else next,
        };
    }
};

pub const BytesContract = struct {
    pub const value_kind_name = "bytes";
    pub const buffer_kind_name = "buffer";
    pub const rejects_string = true;
    pub const rejects_uint8_array_kind = true;
    pub const rejects_array_buffer_kind = true;
    pub const copies_on_create = true;
    pub const preserves_nul = true;
    pub const preserves_invalid_utf8 = true;
};

pub const HandleContract = struct {
    pub const public_is_opaque_object = true;
    pub const public_is_number = false;
    pub const public_is_os_fd = false;
    pub const assignment_is_reference = true;
    pub const clone_is_invalid = true;
    pub const json_is_invalid = true;
    pub const forged_dictionary_is_invalid = true;
    pub const double_close_is_ebadf = true;
};

/// ハッシュhandleのindex空間の開始値。ファイル・プロセスhandleは1から連番で
/// 払い出し、それぞれの上限で止める。raw HandleIdが種別を跨いで衝突しないことを
/// 双方向で保証する（Issue #32・#35）。
pub const hash_handle_index_base: u32 = 0x8000_0000;

/// プロセスhandleのindex空間の開始値。ファイルhandleは
/// `[1, process_handle_index_base)`、プロセスは
/// `[process_handle_index_base, hash_handle_index_base)`、
/// ハッシュは `[hash_handle_index_base, dir_handle_index_base)`、
/// ディレクトリは `[dir_handle_index_base, u32max]` を使う。
/// 4種は同じ `HandleId` を共有するため、index空間を重ねない。
pub const process_handle_index_base: u32 = 0x4000_0000;

/// HandleIdがプロセスhandleのindex空間に属するか。プロセス命令へ
/// ファイル/ハッシュ/ディレクトリhandleが渡された場合、表を変更せずEBADFで
/// 弾くために使う。
pub fn isProcessHandleId(id: HandleId) bool {
    return id.index >= process_handle_index_base and id.index < hash_handle_index_base;
}

/// ディレクトリhandleのindex空間の開始値。ファイル・プロセス・ハッシュの
/// どの空間とも重ならないよう、最上位1/4を専有する（Issue #33）。
/// 各tableの払い出しは自分の区間内へ留まり、raw HandleIdが種別を跨いで
/// 衝突しない。
pub const dir_handle_index_base: u32 = 0xC000_0000;

pub fn isSafeInteger(number: f64) bool {
    if (!std.math.isFinite(number)) return false;
    if (number != @trunc(number)) return false;
    return number >= @as(f64, @floatFromInt(min_safe_integer)) and
        number <= @as(f64, @floatFromInt(max_safe_integer));
}

pub fn offsetFromNumber(number: f64) Error!i64 {
    if (!isSafeInteger(number)) return error.InvalidOffset;
    return @intFromFloat(number);
}

pub fn sizeFromNumber(number: f64) Error!u64 {
    if (!isSafeInteger(number) or number < 0) return error.InvalidSize;
    return @intFromFloat(number);
}

pub fn offsetFromSigned(value: i128) Error!i64 {
    if (value < std.math.minInt(i64) or value > std.math.maxInt(i64)) return error.InvalidOffset;
    return @intCast(value);
}

pub fn sizeFromUnsigned(value: u128) Error!u64 {
    if (value > std.math.maxInt(u64)) return error.InvalidSize;
    return @intCast(value);
}

pub fn publicOffset(value: i64) PublicInteger {
    if (value >= min_safe_integer and value <= max_safe_integer) return .number;
    return .bigint;
}

pub fn publicSize(value: u64) PublicInteger {
    if (value <= @as(u64, @intCast(max_safe_integer))) return .number;
    return .bigint;
}

pub const TimeNs = i128;
pub const OptionalTimeNs = ?TimeNs;

pub fn timeNsFromUnixMsNumber(number: f64) Error!TimeNs {
    if (!isSafeInteger(number)) return error.InvalidTimestamp;
    const ms: i128 = @intFromFloat(number);
    return ms * ns_per_ms;
}

/// ナノ秒のNumber入力を `TimeNs` へ変換する。安全整数のみを受け付け、
/// 小数や安全整数外は `InvalidTimestamp`（EINVAL）になる。
pub fn timeNsFromNumber(number: f64) Error!TimeNs {
    if (!isSafeInteger(number)) return error.InvalidTimestamp;
    return @intFromFloat(number);
}

/// `ファイル時刻設定` / `ファイル時刻設定済` のATIME/MTIME引数契約。
/// `null` は既存値維持（UTIME_OMIT）、`"now"` は現在時刻（UTIME_NOW）、
/// ナノ秒BigInt/Numberはその時刻（UTIME系の明示値）を表す。
pub const SetTime = union(enum) {
    unchanged,
    now,
    at: TimeNs,

    pub fn isNow(self: SetTime) bool {
        return switch (self) {
            .now => true,
            else => false,
        };
    }

    pub fn isUnchanged(self: SetTime) bool {
        return switch (self) {
            .unchanged => true,
            else => false,
        };
    }
};

pub fn timeNsFromUnixNs(value: i128) TimeNs {
    return value;
}

pub fn timeNsFromUnixMicroseconds(value: i64) TimeNs {
    return @as(i128, value) * ns_per_us;
}

pub fn timeNsFromUnixSeconds(value: i64) TimeNs {
    return @as(i128, value) * ns_per_s;
}

pub fn timeNsFromWindowsFileTime(filetime_100ns: u64) TimeNs {
    return @as(i128, filetime_100ns) * 100 - unix_epoch_filetime_100ns * 100;
}

pub fn publicTimeNs(_: TimeNs) PublicInteger {
    return .bigint;
}

pub fn timeMsNumber(ns: TimeNs) Error!f64 {
    const ms = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(ns_per_ms));
    if (!std.math.isFinite(ms)) return error.InvalidTimestamp;
    return ms;
}

pub const missing_timestamp_is_null = true;
pub const zero_timestamp_is_unix_epoch = true;
pub const file_time_epoch_is_utc = true;
pub const zero_byte_read_is_eof = true;
pub const partial_read_is_not_eof = true;
pub const error_string_equals_message = true;

pub const PortableErrorCode = enum {
    ENOENT,
    EACCES,
    EPERM,
    EEXIST,
    ENOTDIR,
    EISDIR,
    ENOTEMPTY,
    EXDEV,
    ELOOP,
    EROFS,
    ENOSPC,
    EMFILE,
    ENFILE,
    EINVAL,
    EPIPE,
    EBADF,
    ENOTSUP,

    pub fn name(self: PortableErrorCode) []const u8 {
        return @tagName(self);
    }

    pub fn fromName(text: []const u8) ?PortableErrorCode {
        inline for (std.meta.tags(PortableErrorCode)) |tag| {
            if (std.mem.eql(u8, text, @tagName(tag))) return tag;
        }
        return null;
    }
};

pub fn portableCodeFor(failure: Error) PortableErrorCode {
    return switch (failure) {
        error.InvalidOffset, error.InvalidSize, error.InvalidTimestamp => .EINVAL,
    };
}

/// なでしこ文字列（UTF-16コード単位）をOSパスへ可逆に変換する。孤立サロゲートは
/// WTF-8として保持し、U+FFFDへ置換しない。lossy変換では孤立サロゲートが実在する
/// U+FFFD名へ化け、rename/unlinkが別ファイルを操作し得るため、ファイルパスの
/// 入力にはこの可逆変換を使う。Windowsのファイルパス表現（WTF-8）と一致し、
/// POSIXでは任意バイト列として扱われる。
pub fn pathBytesFromUtf16(allocator: std.mem.Allocator, units: []const u16) ![]u8 {
    return std.unicode.wtf16LeToWtf8Alloc(allocator, units);
}

/// OSパス（WTF-8）をなでしこ文字列のUTF-16コード単位へ戻す。孤立サロゲートを
/// 保持するため、readlink/realpathの戻り値を可逆に扱える。POSIXの任意バイト列の
/// ようにWTF-8として不正な場合は `error.InvalidWtf8` を返し、呼び出し側が
/// 既存のlossy変換へフォールバックする。
pub fn pathUnitsFromBytes(allocator: std.mem.Allocator, bytes: []const u8) error{ InvalidWtf8, OutOfMemory }![]u16 {
    return std.unicode.wtf8ToWtf16LeAlloc(allocator, bytes);
}

pub const error_object_keys = struct {
    pub const code = "code";
    pub const native_code = "nativeCode";
    pub const operation = "operation";
    pub const path = "path";
    pub const path2 = "path2";
    pub const message = "message";
    pub const capability = "capability";
};

pub const cnako_error_keys = struct {
    pub const code = "code";
    pub const errno = "errno";
    pub const syscall = "syscall";
    pub const path = "path";
    pub const dest = "dest";
    pub const message = "message";
};

pub const CapabilityClass = enum {
    portable_core,
    posix_extension,
    lnako_native,
};

pub const Capability = enum {
    stream_file_io,
    raw_stdio,
    stat,
    lstat,
    symlink,
    readlink,
    realpath,
    rename,
    unlink,
    rmdir,
    truncate,
    utime,
    incremental_hash,
    dir_iterator,
    argv_spawn,
    signal,
    tty_isatty,
    hardlink,
    chmod,
    chown,
    access,
    uid_gid,
    priority,
    statfs,
    reflink,
    seek_data,
    seek_hole,
    fallocate,
    termios,
    nss,
    acl,
    xattr,
    selinux,
    locale_collate,
    display_width,

    pub fn id(self: Capability) []const u8 {
        return @tagName(self);
    }

    pub fn fromId(text: []const u8) ?Capability {
        inline for (std.meta.tags(Capability)) |tag| {
            if (std.mem.eql(u8, text, @tagName(tag))) return tag;
        }
        return null;
    }

    pub fn class(self: Capability) CapabilityClass {
        return switch (self) {
            .stream_file_io,
            .raw_stdio,
            .stat,
            .lstat,
            .symlink,
            .readlink,
            .realpath,
            .rename,
            .unlink,
            .rmdir,
            .truncate,
            .utime,
            .incremental_hash,
            .dir_iterator,
            .argv_spawn,
            .signal,
            .tty_isatty,
            .hardlink,
            .locale_collate,
            .display_width,
            => .portable_core,
            .chmod,
            .chown,
            .access,
            .uid_gid,
            .priority,
            .statfs,
            .reflink,
            => .posix_extension,
            .seek_data,
            .seek_hole,
            .fallocate,
            .termios,
            .nss,
            .acl,
            .xattr,
            .selinux,
            => .lnako_native,
        };
    }
};

/// このlnakoランタイムが実際に提供するcapability。既知でも未実装のものは
/// `低レイヤー機能対応判定` でfalse、実行時は `ENOTSUP` になる。G0の
/// `低レイヤー機能一覧取得` は真偽ではなく既知IDの全集を返すため、ここには
/// 含めない。
pub fn capabilityImplemented(capability: Capability) bool {
    return switch (capability) {
        .stream_file_io,
        .truncate,
        .incremental_hash,
        .raw_stdio,
        .stat,
        .lstat,
        .symlink,
        .readlink,
        .hardlink,
        .realpath,
        .rename,
        .unlink,
        .rmdir,
        .utime,
        .dir_iterator,
        .chmod,
        .chown,
        .access,
        .uid_gid,
        .argv_spawn,
        .signal,
        .tty_isatty,
        .priority,
        .locale_collate,
        .display_width,
        => true,
        else => false,
    };
}

/// 既知capabilityが指定OSで成立するか。catalog.json の `os` matrix（実装状況）と
/// `matrixRule`（`supported = os[OS] && runtimes[実行経路]`）に一致させ、未実装・
/// 非対応OSでは `低レイヤー機能対応判定` がfalseになるようにする。Linuxのstatx
/// 非対応のように実行環境依存の `conditional` はここでは判定できないためtrueを
/// 返し、実行時に `ENOTSUP` で通知する。
pub fn capabilitySupportedOnOs(capability: Capability, os: OsKind) bool {
    if (!capabilityImplemented(capability)) return false;
    return switch (capability) {
        // posix_extensionと、Zig 0.16 stdがWindowsで未対応のhardlinkは
        // Windowsでは提供しない（catalogの `os.windows` はfalse）。
        .chmod, .chown, .access, .uid_gid, .hardlink, .priority => os != .windows,
        else => true,
    };
}

/// 実行中OSでの `capabilitySupportedOnOs`。WASIはPOSIX権限・所有者APIを
/// 持たないため、これらのcapabilityはWindowsと同じくfalseになる。加えて
/// WASIは `utimensat`/`futimens` を持たず、utime（ファイル時刻設定/設定済）は
/// 実行時に常に `ENOTSUP` になるためfalseを返す。
pub fn capabilitySupportedOnCurrentOs(capability: Capability) bool {
    if (!capabilityImplemented(capability)) return false;
    if (builtin.os.tag == .wasi) {
        return switch (capability) {
            .utime => false,
            // WASIはロケールAPIを持たないため、非Cロケールの照合は提供
            // しない。Cロケールのbytewise比較とdisplay_widthは純粋計算で
            // 動作するため対象外。
            .locale_collate => false,
            else => capabilitySupportedOnOs(capability, .windows),
        };
    }
    const os: OsKind = switch (builtin.os.tag) {
        .linux => .linux,
        .windows => .windows,
        else => .macos,
    };
    return capabilitySupportedOnOs(capability, os);
}
pub const RuntimeKind = enum {
    lnako_interpreter,
    lnako_aot,
    cnako_node,
};
pub const OsKind = enum {
    linux,
    macos,
    windows,
};

pub const naming = struct {
    pub const primary_language_is_japanese = true;
    pub const ascii_primary_names_forbidden = true;
    pub const must_not_collide_with_standard_cnako = true;
    pub const particles_are_part_of_contract = true;
    pub const no_arity_overloading_by_name = true;
    pub const omitted_argument_is_undefined = true;
    pub const portable_names_have_no_lnako_prefix = true;
    pub const meta_prefix = "低レイヤー";
    pub const file_prefix = "ファイル";
    pub const stdin_prefix = "標準入力";
    pub const stdout_prefix = "標準出力";
    pub const stderr_prefix = "標準エラー出力";
};

pub const reserved_standard_command_names_are_examples = true;
pub const reserved_standard_command_names = [_][]const u8{
    "開",
    "読",
    "バイナリ読",
    "保存",
    "ファイル情報取得",
    "ファイルサイズ取得",
    "システム関数存在",
};

pub fn isExampleReservedStandardCommandName(name: []const u8) bool {
    for (reserved_standard_command_names) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return true;
    }
    return false;
}

pub const CommonContract = struct {
    pub const interpreter_equals_aot_on_same_os = true;
    pub const aot_o0_to_o3_observably_equal = true;
    pub const portable_code_matches_across_lnako_runtimes = true;
    pub const native_code_may_differ = true;
    pub const message_may_differ = true;
    pub const cnako_may_omit_lnako_native = true;
    pub const no_javascript_in_default_lnako_runtime = true;
};

/// Issue #27のストリームI/O命令名。Interpreter / AOT / 拡張builtin登録が
/// 共通で参照する正本である。既存527命令と衝突しない名前を固定する。
/// なでしこの字句解析は動詞の送り仮名を落とすため、dispatch名は語幹
/// （`ファイル開` 等）になる。利用者が書く `ファイル開く` 等は同じ命令へ
/// 正規化される。`user_forms` は動的文字列実行の互換用である。
pub const stream_commands = struct {
    pub const open = "ファイル開";
    pub const close = "ファイル閉";
    pub const read_bytes = "ファイルバイト読";
    pub const write_bytes = "ファイルバイト書";
    pub const sync = "ファイル同期";
    pub const truncate = "ファイル切詰";

    pub const open_user = "ファイル開く";
    pub const close_user = "ファイル閉じる";
    pub const read_bytes_user = "ファイルバイト読む";
    pub const write_bytes_user = "ファイルバイト書く";
};

/// Issue #32のincremental hash命令名。カタログ定義とInterpreterのdispatch、
/// AOTのbindingが共通で参照する正本である。送り仮名を持たない語幹名を固定する。
pub const hash_commands = struct {
    pub const create = "ハッシュ開始";
    pub const update = "ハッシュ追加";
    pub const digest = "ハッシュ完了";
    pub const discard = "ハッシュ破棄";
};

/// Issue #29のパス操作命令名。カタログ・Interpreter dispatch・AOTが同じ
/// 正本を参照し、名前のドリフトで静かにENOTSUP化しないようにする。
pub const filesystem_commands = struct {
    pub const stat = "ファイル詳細情報取得";
    pub const lstat = "シンボリックリンク情報取得";
    pub const symlink = "シンボリックリンク作成";
    pub const readlink = "シンボリックリンク先取得";
    pub const hardlink = "ハードリンク作成";
    pub const realpath = "実体パス取得";
    pub const rename = "パス名変更";
    pub const unlink = "ファイルリンク削除";
    pub const rmdir = "空フォルダ削除";
    /// Issue #31: パス指定のtruncateとナノ秒精度の時刻設定。
    pub const truncate_path = "ファイルサイズ変更";
    pub const utime_path = "ファイル時刻設定";
    pub const utime_handle = "ファイル時刻設定済";
};

/// Issue #33の逐次ディレクトリ列挙命令名。カタログ・Interpreter dispatch・
/// AOT bindingが同じ正本を参照する。dispatch名は送り仮名を落とした語幹で、
/// 利用者の `ディレクトリ開く` / `ディレクトリ閉じる` は同じ命令へ正規化される。
pub const dir_commands = struct {
    pub const open = "ディレクトリ開";
    pub const next = "ディレクトリ次取得";
    pub const close = "ディレクトリ閉";
    pub const foreach = "ディレクトリ列挙時";

    pub const open_user = "ディレクトリ開く";
    pub const close_user = "ディレクトリ閉じる";
};

/// Issue #34のPOSIX権限・所有者・UID/GID・access命令名。カタログ・Interpreter
/// dispatch・AOTが同じ正本を参照し、名前のドリフトで静かにENOTSUP化しない
/// ようにする。送り仮名を持たない語幹名を固定する。
pub const posix_commands = struct {
    pub const chmod = "ファイル権限設定";
    pub const chown = "ファイル所有者設定";
    pub const lchown = "シンボリックリンク所有者設定";
    pub const access = "ファイルアクセス可能";
    pub const uid = "UID取得";
    pub const euid = "EUID取得";
    pub const gid = "GID取得";
    pub const egid = "EGID取得";
    pub const groups = "所属グループID一覧取得";
    pub const umask = "UMASK変更";
};

/// Issue #28のraw標準入出力命令名。`stream_commands` と同じくdispatch名は
/// 送り仮名を落とした語幹で、利用者の `…読む`/`…書く` は同じ命令へ
/// 正規化される。同期命令は送り仮名を持たない。
pub const stdio_commands = struct {
    pub const stdin_read = "標準入力バイト読";
    pub const stdout_write = "標準出力バイト書";
    pub const stderr_write = "標準エラー出力バイト書";
    pub const stdout_sync = "標準出力同期";
    pub const stderr_sync = "標準エラー出力同期";

    pub const stdin_read_user = "標準入力バイト読む";
    pub const stdout_write_user = "標準出力バイト書く";
    pub const stderr_write_user = "標準エラー出力バイト書く";
};

/// Issue #35のargv型プロセス起動・signal・priority・TTY命令名。カタログ・
/// Interpreter dispatch・AOT bindingが共通で参照する正本である。送り仮名を
/// 持たない語幹名を固定する。
pub const process_commands = struct {
    pub const spawn = "プロセス起動";
    pub const wait = "プロセス待機";
    pub const pid_get = "プロセスID取得";
    pub const ppid_get = "親プロセスID取得";
    pub const signal_send = "シグナル送信";
    pub const priority_get = "プロセス優先度取得";
    pub const priority_set = "プロセス優先度設定";
    pub const tty_isatty = "端末判定";
    pub const tty_size = "端末サイズ取得";
};

/// Issue #35のプロセス命令が失敗したときに返す構造化エラーの操作名（ASCII）。
/// カタログ `operation` と揃える。NodeのSystemError `syscall` 相当。
pub const process_operations = struct {
    pub const spawn = "spawn";
    pub const wait = "wait";
    pub const getpid = "getpid";
    pub const getppid = "getppid";
    pub const kill = "kill";
    pub const getpriority = "getpriority";
    pub const setpriority = "setpriority";
    pub const isatty = "isatty";
    pub const winsize = "winsize";
};

/// プロセスの標準入出力ストリーム。`端末判定` / `端末サイズ取得` の
/// STREAM引数を表す。助詞の `標準入力` / `標準出力` / `標準エラー出力` と
/// Nodeの `stdin` / `stdout` / `stderr` の両表記を受け付ける。
pub const ProcessStream = enum {
    stdin,
    stdout,
    stderr,

    pub fn fromText(text: []const u8) ?ProcessStream {
        if (std.mem.eql(u8, text, "stdin") or std.mem.eql(u8, text, "標準入力")) return .stdin;
        if (std.mem.eql(u8, text, "stdout") or std.mem.eql(u8, text, "標準出力")) return .stdout;
        if (std.mem.eql(u8, text, "stderr") or std.mem.eql(u8, text, "標準エラー出力")) return .stderr;
        return null;
    }

    pub fn name(self: ProcessStream) []const u8 {
        return @tagName(self);
    }
};

/// `プロセス起動` OPTIONSの stdio 値。Nodeの `child_process` と同じ
/// `inherit` / `pipe` / `null`（`ignore` もnull扱い）。
pub const ProcessStdioMode = enum {
    inherit,
    pipe,
    null_,

    pub fn fromText(text: []const u8) ?ProcessStdioMode {
        if (std.mem.eql(u8, text, "inherit")) return .inherit;
        if (std.mem.eql(u8, text, "pipe")) return .pipe;
        if (std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "ignore")) return .null_;
        return null;
    }

    pub fn name(self: ProcessStdioMode) []const u8 {
        return switch (self) {
            .inherit => "inherit",
            .pipe => "pipe",
            .null_ => "null",
        };
    }
};

/// `OPTIONS` 辞書のキー。cwd/env/stdio/detached。
pub const process_option_keys = struct {
    pub const cwd = "cwd";
    pub const env = "env";
    pub const stdio = "stdio";
    pub const detached = "detached";
};

/// `waitResult` 辞書のキー。`exitCode` と `signal`。
pub const wait_result_keys = struct {
    pub const exit_code = "exitCode";
    pub const signal = "signal";
};

/// `ttySize` 辞書のキー。`rows` と `columns`。
pub const tty_size_keys = struct {
    pub const rows = "rows";
    pub const columns = "columns";
};

/// Issue #38のロケール比較・端末表示幅命令名。カタログ・Interpreter
/// dispatch・AOT bindingが共通で参照する正本である。
pub const locale_commands = struct {
    pub const compare = "ロケール文字列比較";
    pub const display_width = "文字表示幅取得";
};

/// Issue #38のロケール命令が失敗したときに返す構造化エラーの操作名
/// （ASCII）。カタログ `operation` と揃える。
pub const locale_operations = struct {
    pub const collate = "collate";
    pub const width = "width";
};

/// `ロケール文字列比較` のOPTIONS辞書キー。`locale`のみを解釈し、
/// 未知キーは無視する（cnako側のIntl.Collatorオプション拡張と共存
/// させるための契約）。
pub const collate_option_keys = struct {
    pub const locale = "locale";
};

/// `waitResult.signal` が正常終了時に取る値。
pub const signal_on_normal_exit_is_null = true;

/// シグナル終了時の `exitCode` は `128 + signal`（shellと同じ慣例）。
pub const signal_exit_code_offset: u32 = 128;

/// 標準cnako 527件の外にある低レイヤー命令名。`builtin_catalog.names` は
/// 公式527件と同期して生成されるため変更せず、解析器のbuiltin解決だけに
/// 追加する。`低レイヤー機能対応判定` / `低レイヤー機能一覧取得` も含む。
pub const CommandArity = struct {
    min: u8,
    max: u8,
    operation: []const u8,
};

/// `docs/low-level-api/catalog.json` の命令1件に対応する実行時定義。
/// `name` はdispatch名（字句解析が送り仮名を落とした語幹）、`user_name` は
/// カタログ `name` の利用者向け表記（dispatch名と同じなら null）。
/// `implemented == false` の命令は全経路へ登録されるが、実行時には
/// `capability` と `operation` を設定した構造化 `ENOTSUP` を投げる。
pub const CatalogCommand = struct {
    id: []const u8,
    name: []const u8,
    user_name: ?[]const u8 = null,
    min: u8,
    max: u8,
    operation: []const u8,
    capability: ?Capability,
    implemented: bool = false,
};

/// カタログ掲載63命令の実行時正本。`catalog.json` の `commands` と同じ順序で、
/// `src/runtime/low_level_catalog.zig` のテストが id/name/arity/operation/
/// capability の一致を埋め込みJSONへ照合する。
pub const catalog_commands = [_]CatalogCommand{
    .{ .id = "ll-file-open", .name = stream_commands.open, .user_name = stream_commands.open_user, .min = 1, .max = 2, .operation = stream_operations.open, .capability = .stream_file_io, .implemented = true },
    .{ .id = "ll-file-close", .name = stream_commands.close, .user_name = stream_commands.close_user, .min = 1, .max = 1, .operation = stream_operations.close, .capability = .stream_file_io, .implemented = true },
    .{ .id = "ll-file-read", .name = stream_commands.read_bytes, .user_name = stream_commands.read_bytes_user, .min = 2, .max = 2, .operation = stream_operations.read, .capability = .stream_file_io, .implemented = true },
    .{ .id = "ll-file-write", .name = stream_commands.write_bytes, .user_name = stream_commands.write_bytes_user, .min = 2, .max = 2, .operation = stream_operations.write, .capability = .stream_file_io, .implemented = true },
    .{ .id = "ll-file-sync", .name = stream_commands.sync, .min = 1, .max = 1, .operation = stream_operations.fsync, .capability = .stream_file_io, .implemented = true },
    .{ .id = "ll-file-truncate-handle", .name = stream_commands.truncate, .min = 2, .max = 2, .operation = stream_operations.ftruncate, .capability = .truncate, .implemented = true },
    .{ .id = "ll-file-seek", .name = "ファイル位置変更", .min = 2, .max = 3, .operation = "lseek", .capability = .stream_file_io },
    .{ .id = "ll-file-tell", .name = "ファイル位置取得", .min = 1, .max = 1, .operation = "lseek", .capability = .stream_file_io },
    .{ .id = "ll-file-pread", .name = "ファイル位置指定読込", .min = 3, .max = 3, .operation = "pread", .capability = .stream_file_io },
    .{ .id = "ll-file-pwrite", .name = "ファイル位置指定書込", .min = 3, .max = 3, .operation = "pwrite", .capability = .stream_file_io },
    .{ .id = "ll-stdin-read", .name = stdio_commands.stdin_read, .user_name = stdio_commands.stdin_read_user, .min = 1, .max = 1, .operation = "read", .capability = .raw_stdio, .implemented = true },
    .{ .id = "ll-stdout-write", .name = stdio_commands.stdout_write, .user_name = stdio_commands.stdout_write_user, .min = 1, .max = 1, .operation = "write", .capability = .raw_stdio, .implemented = true },
    .{ .id = "ll-stderr-write", .name = stdio_commands.stderr_write, .user_name = stdio_commands.stderr_write_user, .min = 1, .max = 1, .operation = "write", .capability = .raw_stdio, .implemented = true },
    .{ .id = "ll-stdout-sync", .name = stdio_commands.stdout_sync, .min = 0, .max = 0, .operation = "fsync", .capability = .raw_stdio, .implemented = true },
    .{ .id = "ll-stderr-sync", .name = stdio_commands.stderr_sync, .min = 0, .max = 0, .operation = "fsync", .capability = .raw_stdio, .implemented = true },
    .{ .id = "ll-file-stat", .name = filesystem_commands.stat, .min = 1, .max = 1, .operation = filesystem_operations.stat, .capability = .stat, .implemented = true },
    .{ .id = "ll-file-lstat", .name = filesystem_commands.lstat, .min = 1, .max = 1, .operation = filesystem_operations.lstat, .capability = .lstat, .implemented = true },
    .{ .id = "ll-symlink-create", .name = filesystem_commands.symlink, .min = 2, .max = 2, .operation = filesystem_operations.symlink, .capability = .symlink, .implemented = true },
    .{ .id = "ll-symlink-read", .name = filesystem_commands.readlink, .min = 1, .max = 1, .operation = filesystem_operations.readlink, .capability = .readlink, .implemented = true },
    .{ .id = "ll-hardlink-create", .name = filesystem_commands.hardlink, .min = 2, .max = 2, .operation = filesystem_operations.hardlink, .capability = .hardlink, .implemented = true },
    .{ .id = "ll-path-realpath", .name = filesystem_commands.realpath, .min = 1, .max = 1, .operation = filesystem_operations.realpath, .capability = .realpath, .implemented = true },
    .{ .id = "ll-path-rename", .name = filesystem_commands.rename, .min = 2, .max = 2, .operation = filesystem_operations.rename, .capability = .rename, .implemented = true },
    .{ .id = "ll-path-unlink", .name = filesystem_commands.unlink, .min = 1, .max = 1, .operation = filesystem_operations.unlink, .capability = .unlink, .implemented = true },
    .{ .id = "ll-path-rmdir", .name = filesystem_commands.rmdir, .min = 1, .max = 1, .operation = filesystem_operations.rmdir, .capability = .rmdir, .implemented = true },
    .{ .id = "ll-file-truncate-path", .name = filesystem_commands.truncate_path, .min = 2, .max = 2, .operation = filesystem_operations.truncate, .capability = .truncate, .implemented = true },
    .{ .id = "ll-file-utime-path", .name = filesystem_commands.utime_path, .min = 3, .max = 3, .operation = filesystem_operations.utime, .capability = .utime, .implemented = true },
    .{ .id = "ll-file-utime-handle", .name = filesystem_commands.utime_handle, .min = 3, .max = 3, .operation = filesystem_operations.futime, .capability = .utime, .implemented = true },
    .{ .id = "ll-hash-create", .name = hash_commands.create, .min = 1, .max = 1, .operation = "hash", .capability = .incremental_hash, .implemented = true },
    .{ .id = "ll-hash-update", .name = hash_commands.update, .min = 2, .max = 2, .operation = "hash", .capability = .incremental_hash, .implemented = true },
    .{ .id = "ll-hash-digest", .name = hash_commands.digest, .min = 1, .max = 2, .operation = "hash", .capability = .incremental_hash, .implemented = true },
    .{ .id = "ll-hash-discard", .name = hash_commands.discard, .min = 1, .max = 1, .operation = "hash", .capability = .incremental_hash, .implemented = true },
    .{ .id = "ll-dir-open", .name = dir_commands.open, .user_name = dir_commands.open_user, .min = 1, .max = 1, .operation = directory_operations.open, .capability = .dir_iterator, .implemented = true },
    .{ .id = "ll-dir-next", .name = dir_commands.next, .min = 1, .max = 1, .operation = directory_operations.next, .capability = .dir_iterator, .implemented = true },
    .{ .id = "ll-dir-close", .name = dir_commands.close, .user_name = dir_commands.close_user, .min = 1, .max = 1, .operation = directory_operations.close, .capability = .dir_iterator, .implemented = true },
    .{ .id = "ll-dir-foreach", .name = dir_commands.foreach, .min = 2, .max = 2, .operation = directory_operations.foreach, .capability = .dir_iterator, .implemented = true },
    .{ .id = "ll-file-chmod", .name = posix_commands.chmod, .min = 2, .max = 2, .operation = posix_operations.chmod, .capability = .chmod, .implemented = true },
    .{ .id = "ll-file-chown", .name = posix_commands.chown, .min = 3, .max = 3, .operation = posix_operations.chown, .capability = .chown, .implemented = true },
    .{ .id = "ll-symlink-chown", .name = posix_commands.lchown, .min = 3, .max = 3, .operation = posix_operations.lchown, .capability = .chown, .implemented = true },
    .{ .id = "ll-file-access", .name = posix_commands.access, .min = 2, .max = 2, .operation = posix_operations.access, .capability = .access, .implemented = true },
    .{ .id = "ll-uid-get", .name = posix_commands.uid, .min = 0, .max = 0, .operation = posix_operations.uid, .capability = .uid_gid, .implemented = true },
    .{ .id = "ll-euid-get", .name = posix_commands.euid, .min = 0, .max = 0, .operation = posix_operations.euid, .capability = .uid_gid, .implemented = true },
    .{ .id = "ll-gid-get", .name = posix_commands.gid, .min = 0, .max = 0, .operation = posix_operations.gid, .capability = .uid_gid, .implemented = true },
    .{ .id = "ll-egid-get", .name = posix_commands.egid, .min = 0, .max = 0, .operation = posix_operations.egid, .capability = .uid_gid, .implemented = true },
    .{ .id = "ll-groups-get", .name = posix_commands.groups, .min = 0, .max = 0, .operation = posix_operations.groups, .capability = .uid_gid, .implemented = true },
    .{ .id = "ll-umask-set", .name = posix_commands.umask, .min = 1, .max = 1, .operation = posix_operations.umask, .capability = .uid_gid, .implemented = true },
    .{ .id = "ll-process-spawn", .name = process_commands.spawn, .min = 1, .max = 2, .operation = process_operations.spawn, .capability = .argv_spawn, .implemented = true },
    .{ .id = "ll-process-wait", .name = process_commands.wait, .min = 1, .max = 1, .operation = process_operations.wait, .capability = .argv_spawn, .implemented = true },
    .{ .id = "ll-pid-get", .name = process_commands.pid_get, .min = 0, .max = 0, .operation = process_operations.getpid, .capability = .argv_spawn, .implemented = true },
    .{ .id = "ll-ppid-get", .name = process_commands.ppid_get, .min = 0, .max = 0, .operation = process_operations.getppid, .capability = .argv_spawn, .implemented = true },
    .{ .id = "ll-signal-send", .name = process_commands.signal_send, .min = 2, .max = 2, .operation = process_operations.kill, .capability = .signal, .implemented = true },
    .{ .id = "ll-process-priority-get", .name = process_commands.priority_get, .min = 1, .max = 1, .operation = process_operations.getpriority, .capability = .priority, .implemented = true },
    .{ .id = "ll-process-priority-set", .name = process_commands.priority_set, .min = 2, .max = 2, .operation = process_operations.setpriority, .capability = .priority, .implemented = true },
    .{ .id = "ll-tty-isatty", .name = process_commands.tty_isatty, .min = 1, .max = 1, .operation = process_operations.isatty, .capability = .tty_isatty, .implemented = true },
    .{ .id = "ll-tty-size", .name = process_commands.tty_size, .min = 1, .max = 1, .operation = process_operations.winsize, .capability = .tty_isatty, .implemented = true },
    .{ .id = "ll-statfs", .name = "ファイルシステム情報取得", .min = 1, .max = 1, .operation = "statfs", .capability = .statfs },
    .{ .id = "ll-reflink", .name = "ファイルクローン", .min = 2, .max = 3, .operation = "reflink", .capability = .reflink },
    .{ .id = "ll-seek-data", .name = "ファイルデータ領域検索", .min = 2, .max = 2, .operation = "lseek", .capability = .seek_data },
    .{ .id = "ll-seek-hole", .name = "ファイル空洞領域検索", .min = 2, .max = 2, .operation = "lseek", .capability = .seek_hole },
    .{ .id = "ll-fallocate", .name = "ファイル領域確保", .min = 3, .max = 3, .operation = "fallocate", .capability = .fallocate },
    .{ .id = "ll-capability-supported", .name = capability_supported_command, .min = 1, .max = 1, .operation = "capability", .capability = null, .implemented = true },
    .{ .id = "ll-capability-list", .name = capability_list_command, .min = 0, .max = 0, .operation = "capability", .capability = null, .implemented = true },
    .{ .id = "ll-locale-compare", .name = locale_commands.compare, .min = 2, .max = 3, .operation = locale_operations.collate, .capability = .locale_collate, .implemented = true },
    .{ .id = "ll-display-width", .name = locale_commands.display_width, .min = 1, .max = 1, .operation = locale_operations.width, .capability = .display_width, .implemented = true },
};

/// dispatch名または利用者向け表記からカタログ定義を引く。`ファイル開` と
/// `ファイル開く` のどちらでも同じ項目を返す。
pub fn catalogCommandFor(name: []const u8) ?CatalogCommand {
    for (catalog_commands) |command| {
        if (std.mem.eql(u8, name, command.name)) return command;
        if (command.user_name) |user_name| {
            if (std.mem.eql(u8, name, user_name)) return command;
        }
    }
    return null;
}

pub fn commandArity(name: []const u8) ?CommandArity {
    const command = catalogCommandFor(name) orelse return null;
    return .{ .min = command.min, .max = command.max, .operation = command.operation };
}

/// 解析器のbuiltin解決と `システム関数存在` が参照する拡張命令名の一覧。
/// カタログ63命令のdispatch名と利用者向け表記を全て含む。
pub const extension_command_names = blk: {
    @setEvalBranchQuota(100_000);
    var names: []const []const u8 = &.{};
    for (catalog_commands) |command| {
        names = names ++ @as([]const []const u8, &.{command.name});
        if (command.user_name) |user_name| {
            names = names ++ @as([]const []const u8, &.{user_name});
        }
    }
    break :blk names;
};

/// 低レイヤー命令が失敗したときに返す構造化エラーの操作名（ASCII）。
/// NodeのSystemError `syscall` 相当。エラー辞書の `operation` へ入れる。
pub const stream_operations = struct {
    pub const open = "open";
    pub const close = "close";
    pub const read = "read";
    pub const write = "write";
    pub const fsync = "fsync";
    pub const ftruncate = "ftruncate";
};

/// Issue #32のincremental hash命令が失敗したときに返す構造化エラーの操作名
/// （ASCII）。カタログの `operation` は4命令とも共通で `hash` である。
pub const hash_operation = "hash";

/// Issue #29のパス操作が失敗したときに返す構造化エラーの操作名（ASCII）。
/// NodeのSystemError `syscall` / POSIX syscall名と揃える。
pub const filesystem_operations = struct {
    pub const stat = "stat";
    pub const lstat = "lstat";
    pub const symlink = "symlink";
    pub const readlink = "readlink";
    pub const hardlink = "link";
    pub const realpath = "realpath";
    pub const rename = "rename";
    pub const unlink = "unlink";
    pub const rmdir = "rmdir";
    /// Issue #31のパスtruncateと時刻設定のsyscall名。NodeのSystemError
    /// `syscall` / POSIX syscall名と揃える。
    pub const truncate = "truncate";
    pub const utime = "utime";
    pub const futime = "futime";
};

/// Issue #33の逐次ディレクトリ列挙が失敗したときに返す構造化エラーの操作名
/// （ASCII）。NodeのSystemError `syscall` / POSIX syscall名と揃える。
pub const directory_operations = struct {
    pub const open = "opendir";
    pub const next = "readdir";
    pub const close = "closedir";
    pub const foreach = "readdir";
};

/// `dirEntry`辞書のフィールド名。カタログ `typeSchemas.dirEntry` と一致させる。
pub const dir_entry_keys = struct {
    pub const name = "name";
    pub const kind = "type";
};

/// `dir_entry_keys` の全2フィールド。辞書構築の網羅テストが参照する。
pub const dir_entry_key_list = [_][]const u8{
    dir_entry_keys.name,
    dir_entry_keys.kind,
};

/// Issue #34のPOSIX権限・所有者・UID/GID・access命令が失敗したときに返す
/// 構造化エラーの操作名（ASCII）。NodeのSystemError `syscall` / POSIX
/// syscall名と揃える。
pub const posix_operations = struct {
    pub const chmod = "chmod";
    pub const chown = "chown";
    pub const lchown = "lchown";
    pub const access = "access";
    pub const uid = "getuid";
    pub const euid = "geteuid";
    pub const gid = "getgid";
    pub const egid = "getegid";
    pub const groups = "getgroups";
    pub const umask = "umask";
};

/// `ファイルアクセス可能` のMODEビット。OSのaccess(2)と同じ値で、
/// F_OK(0) / R_OK(4) / W_OK(2) / X_OK(1) のビット和を取る。
pub const access_mode = struct {
    pub const f_ok: u32 = 0;
    pub const x_ok: u32 = 1;
    pub const w_ok: u32 = 2;
    pub const r_ok: u32 = 4;
    pub const all: u32 = r_ok | w_ok | x_ok;
};

/// `ファイル権限設定`/`UMASK変更` が受け付ける数値modeの上限（0〜0o7777）。
pub const max_permission_mode: u32 = 0o7777;

/// chown/lchownで「そのIDを変更しない」を表す値（POSIXの `(uid_t)-1`）。
pub const unchanged_id: i64 = -1;

/// `stat`辞書のフィールド名。カタログ `typeSchemas.stat` と一致させる。
pub const stat_field_keys = struct {
    pub const kind = "kind";
    pub const size = "size";
    pub const mode = "mode";
    pub const uid = "uid";
    pub const gid = "gid";
    pub const dev = "dev";
    pub const rdev = "rdev";
    pub const inode = "inode";
    pub const nlink = "nlink";
    pub const block_size = "blockSize";
    pub const blocks = "blocks";
    pub const atime_ns = "atimeNs";
    pub const mtime_ns = "mtimeNs";
    pub const ctime_ns = "ctimeNs";
    pub const birthtime_ns = "birthtimeNs";
};

/// `stat_field_keys` の全15フィールドを列挙したもの。辞書構築の網羅テストが
/// 参照する。カタログ `typeSchemas.stat` と同じ順序。
pub const stat_field_key_list = [_][]const u8{
    stat_field_keys.kind,
    stat_field_keys.size,
    stat_field_keys.mode,
    stat_field_keys.uid,
    stat_field_keys.gid,
    stat_field_keys.dev,
    stat_field_keys.rdev,
    stat_field_keys.inode,
    stat_field_keys.nlink,
    stat_field_keys.block_size,
    stat_field_keys.blocks,
    stat_field_keys.atime_ns,
    stat_field_keys.mtime_ns,
    stat_field_keys.ctime_ns,
    stat_field_keys.birthtime_ns,
};

/// 開くときのアクセス様式。`ファイル開く` のmode引数から決まる。
/// 位置（read/write/append）と生成・切詰の有無だけを固定し、
/// OS固有のO_APPEND等の表現は実装側へ委ねる。
pub const OpenMode = enum {
    read,
    read_write,
    write_create_truncate,
    write_read_create_truncate,
    append_create,
    append_read_create,

    pub fn isRead(self: OpenMode) bool {
        return switch (self) {
            .read, .read_write, .write_read_create_truncate, .append_read_create => true,
            else => false,
        };
    }

    pub fn isWrite(self: OpenMode) bool {
        return switch (self) {
            .read_write, .write_create_truncate, .write_read_create_truncate, .append_create, .append_read_create => true,
            else => false,
        };
    }

    pub fn isAppend(self: OpenMode) bool {
        return switch (self) {
            .append_create, .append_read_create => true,
            else => false,
        };
    }

    pub fn isTruncate(self: OpenMode) bool {
        return switch (self) {
            .write_create_truncate, .write_read_create_truncate => true,
            else => false,
        };
    }

    pub fn creates(self: OpenMode) bool {
        return switch (self) {
            .write_create_truncate, .write_read_create_truncate, .append_create, .append_read_create => true,
            else => false,
        };
    }
};

pub const InvalidModeError = error{InvalidMode};

pub const ParsedOpenMode = struct {
    mode: OpenMode,
    exclusive: bool = false,
    sync: bool = false,
};

/// Node.js `fs.open` の文字列flagsを `OpenMode` へ写す。`r`/`r+`/`w`/`w+`/
/// `a`/`a+` に修飾子 `b`/`x`/`s` を組み合わせられる。`x` は生成系のmodeでのみ
/// 有効であり、未知の文字や `x` の不正使用は `error.InvalidMode` にする。
/// 数値flags（`O_RDONLY`等）はG0で未凍結のため受け付けない。
pub fn parseOpenMode(text: []const u8) InvalidModeError!ParsedOpenMode {
    if (text.len == 0) return error.InvalidMode;
    var seen_r = false;
    var seen_w = false;
    var seen_a = false;
    var plus = false;
    var exclusive = false;
    var binary = false;
    var sync = false;
    for (text) |character| switch (character) {
        'r' => {
            if (seen_r or seen_w or seen_a) return error.InvalidMode;
            seen_r = true;
        },
        'w' => {
            if (seen_r or seen_w or seen_a) return error.InvalidMode;
            seen_w = true;
        },
        'a' => {
            if (seen_r or seen_w or seen_a) return error.InvalidMode;
            seen_a = true;
        },
        '+' => {
            if (plus) return error.InvalidMode;
            plus = true;
        },
        'x' => {
            if (exclusive) return error.InvalidMode;
            exclusive = true;
        },
        'b' => {
            if (binary) return error.InvalidMode;
            binary = true;
        },
        's' => {
            if (sync) return error.InvalidMode;
            sync = true;
        },
        else => {
            return error.InvalidMode;
        },
    };
    const mode: OpenMode = if (seen_r)
        (if (plus) .read_write else .read)
    else if (seen_w)
        (if (plus) .write_read_create_truncate else .write_create_truncate)
    else if (seen_a)
        (if (plus) .append_read_create else .append_create)
    else
        return error.InvalidMode;
    if (exclusive and !mode.creates()) return error.InvalidMode;
    return .{ .mode = mode, .exclusive = exclusive, .sync = sync };
}

pub fn openModeFromNodeFlags(text: []const u8) InvalidModeError!OpenMode {
    return (try parseOpenMode(text)).mode;
}

/// 低レイヤー命令の失敗をportable codeへ写す。写せない失敗は `null` を返し、
/// 呼び出し側が既定値（`EINVAL` または `ENOTSUP`）へ丸める。native codeは
/// この関数では追跡せず、公開エラー辞書では `null` を許容する。
pub fn portableCodeForFailure(failure: anyerror) ?PortableErrorCode {
    return switch (failure) {
        error.FileNotFound, error.NotFound => .ENOENT,
        // G0の `structured_error.portableCodeFromFailure` と揃える:
        // EACCES（アクセス拒否）とEPERM（操作不許可）を区別する。
        error.AccessDenied => .EACCES,
        error.PermissionDenied => .EPERM,
        error.SymLinkLoop => .ELOOP,
        error.IsDir => .EISDIR,
        error.NotDir => .ENOTDIR,
        error.PathAlreadyExists, error.AlreadyExists => .EEXIST,
        error.DirNotEmpty => .ENOTEMPTY,
        error.CrossDevice => .EXDEV,
        // readlinkの対象がsymlinkでない場合はEINVAL（Node fs.readlinkと同じ）。
        // 不正なパス表現（WTF-8として不正等）もEINVALへ揃える。
        error.NotLink, error.BadPathName, error.InvalidWtf8, error.InvalidArgument => .EINVAL,
        // 時刻がOS表現（time_t / Windowsの100ns）に収まらない場合はEINVAL。
        error.InvalidTimestamp => .EINVAL,
        error.ReadOnlyFileSystem => .EROFS,
        error.NoSpaceLeft, error.DiskQuota, error.FileTooBig => .ENOSPC,
        error.ProcessFdQuotaExceeded => .EMFILE,
        error.SystemFdQuotaExceeded => .ENFILE,
        error.NotOpenForReading, error.NotOpenForWriting, error.BadFileDescriptor => .EBADF,
        // 低レイヤーhandle表の内部整合が崩れた場合（wait/close対象が表に無い）
        // も無効handleとしてEBADFへ写す。
        error.InvalidHandle => .EBADF,
        error.BrokenPipe => .EPIPE,
        // stdin履歴上限超過。ポータブル集合にENOMEM等が無いため、リソース
        // 枯渇として最も近いENOSPCへ写像する。
        error.StreamTooLong => .ENOSPC,
        // Issue #35: kill/setpriorityの対象プロセス不在は引数不正としてEINVAL、
        // 非対応シグナル・非対応プラットフォームはENOTSUPへ写す。EACCES/EPERMは
        // 上の AccessDenied/PermissionDenied で既に写像済み。
        error.ProcessNotFound => .EINVAL,
        error.InvalidSignal, error.InvalidSignalNumber => .EINVAL,
        error.UnsupportedSignal => .ENOTSUP,
        // hardlink/renameの非対応FSとWindowsの未対応reparse pointはENOTSUP。
        // 本関数はG0正本 `structured_error.portableCodeFromFailure` の上位集合で、
        // 低レイヤー固有のエラー名（LowLevelIoUnavailable等）もここで畳む。
        error.LowLevelIoUnavailable, error.OperationUnsupported, error.UnsupportedReparsePointType, error.Unsupported, error.NotSupported => .ENOTSUP,
        // リンク数上限（EMLINK相当）はportable 17種に無いためEPERMへ丸める。
        error.LinkQuotaExceeded => .EPERM,
        else => null,
    };
}

/// `プロセス起動` 専用のportable code写像。spawnの契約エラー集合は
/// ENOENT/EACCES/EPERM/EINVAL/ENOTSUPだけなので、fd枯渇（EMFILE/ENFILE）や
/// その他のリソース失敗を含む未写像の失敗はEINVALへ丸める。nullは返さない。
pub fn portableCodeForSpawnFailure(failure: anyerror) PortableErrorCode {
    return switch (failure) {
        error.FileNotFound, error.NotFound => .ENOENT,
        error.AccessDenied => .EACCES,
        error.PermissionDenied => .EPERM,
        error.OperationUnsupported, error.UnsupportedReparsePointType, error.Unsupported, error.NotSupported, error.LowLevelIoUnavailable => .ENOTSUP,
        else => .EINVAL,
    };
}

/// `ディレクトリ開く` が投げ得るcode。カタログの集合は
/// ENOENT/ENOTDIR/EACCES/EPERM/EMFILE/ENFILE/ENOTSUP で、それ以外
/// （ELOOP等のOS固有失敗や未写像エラー）は全命令共通のEINVALへ丸める。
pub fn dirOpenErrorCode(failure: anyerror) PortableErrorCode {
    return switch (portableCodeForFailure(failure) orelse .EINVAL) {
        .ENOENT, .ENOTDIR, .EACCES, .EPERM, .EMFILE, .ENFILE, .ENOTSUP => |code| code,
        else => .EINVAL,
    };
}

/// `ディレクトリ次取得` が投げ得るcode。 EBADF/EINVAL/ENOTSUP のみを残す。
pub fn dirNextErrorCode(failure: anyerror) PortableErrorCode {
    return switch (portableCodeForFailure(failure) orelse .EINVAL) {
        .EBADF, .ENOTSUP => |code| code,
        else => .EINVAL,
    };
}

/// `ディレクトリ列挙時` が投げ得るcode。列挙中のEACCES/EPERMを保持し、
/// EBADF等の次取得専用codeはEINVALへ丸める。
pub fn dirForeachErrorCode(failure: anyerror) PortableErrorCode {
    return switch (portableCodeForFailure(failure) orelse .EINVAL) {
        .ENOENT, .ENOTDIR, .EACCES, .EPERM, .ENOTSUP => |code| code,
        else => .EINVAL,
    };
}

/// `ディレクトリ閉じる` はEBADFのみを返す契約。無効ハンドル以外の失敗も
/// 契約に合わせてEBADFへ丸める。
pub fn dirCloseErrorCode(_: anyerror) PortableErrorCode {
    return .EBADF;
}

test "ディレクトリ命令の失敗は契約のportable code集合へ丸められる" {
    try std.testing.expectEqual(PortableErrorCode.ENOENT, dirOpenErrorCode(error.FileNotFound));
    try std.testing.expectEqual(PortableErrorCode.ENOTDIR, dirOpenErrorCode(error.NotDir));
    try std.testing.expectEqual(PortableErrorCode.EACCES, dirOpenErrorCode(error.AccessDenied));
    try std.testing.expectEqual(PortableErrorCode.EPERM, dirOpenErrorCode(error.PermissionDenied));
    try std.testing.expectEqual(PortableErrorCode.EMFILE, dirOpenErrorCode(error.ProcessFdQuotaExceeded));
    try std.testing.expectEqual(PortableErrorCode.ENFILE, dirOpenErrorCode(error.SystemFdQuotaExceeded));
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, dirOpenErrorCode(error.LowLevelIoUnavailable));
    // openの契約に無いELOOPや未写像エラーはEINVAL。
    try std.testing.expectEqual(PortableErrorCode.EINVAL, dirOpenErrorCode(error.SymLinkLoop));
    try std.testing.expectEqual(PortableErrorCode.EINVAL, dirOpenErrorCode(error.Unexpected));

    try std.testing.expectEqual(PortableErrorCode.EBADF, dirNextErrorCode(error.BadFileDescriptor));
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, dirNextErrorCode(error.LowLevelIoUnavailable));
    // 次取得の契約に無いEACCESはEINVAL。
    try std.testing.expectEqual(PortableErrorCode.EINVAL, dirNextErrorCode(error.AccessDenied));

    try std.testing.expectEqual(PortableErrorCode.EACCES, dirForeachErrorCode(error.AccessDenied));
    try std.testing.expectEqual(PortableErrorCode.EPERM, dirForeachErrorCode(error.PermissionDenied));
    try std.testing.expectEqual(PortableErrorCode.ENOENT, dirForeachErrorCode(error.FileNotFound));
    try std.testing.expectEqual(PortableErrorCode.EINVAL, dirForeachErrorCode(error.BadFileDescriptor));

    try std.testing.expectEqual(PortableErrorCode.EBADF, dirCloseErrorCode(error.Unexpected));
}

test "HandleIdはindexを下位32bit、generationを上位32bitに置く" {
    const id = HandleId{ .index = 1, .generation = 2 };
    try std.testing.expectEqual(@as(u64, (@as(u64, 2) << 32) | 1), id.raw());
    try std.testing.expectEqual(id, HandleId.fromRaw(id.raw()));
}

test "HandleIdの0は無効で、発行値はindexもgenerationも1以上" {
    try std.testing.expect(!HandleId.invalid.isValid());
    try std.testing.expect(!(HandleId{ .index = 0, .generation = 1 }).isValid());
    try std.testing.expect(!(HandleId{ .index = 1, .generation = 0 }).isValid());
    try std.testing.expect((HandleId{ .index = 1, .generation = 1 }).isValid());
}

test "HandleIdのgenerationは0を飛ばして進む" {
    const wrapped = HandleId{ .index = 7, .generation = std.math.maxInt(u32) };
    const next = wrapped.nextGeneration();
    try std.testing.expectEqual(@as(u32, 7), next.index);
    try std.testing.expectEqual(@as(u32, 1), next.generation);
    try std.testing.expectEqual(@as(u32, 2), (HandleId{ .index = 7, .generation = 1 }).nextGeneration().generation);
}

test "安全整数だけをoffsetとsizeのNumber入力として受け付ける" {
    try std.testing.expectEqual(@as(i64, 0), try offsetFromNumber(0));
    try std.testing.expectEqual(@as(i64, 0), try offsetFromNumber(-0.0));
    try std.testing.expectEqual(@as(i64, -1), try offsetFromNumber(-1));
    try std.testing.expectEqual(max_safe_integer, try offsetFromNumber(@floatFromInt(max_safe_integer)));
    try std.testing.expectEqual(min_safe_integer, try offsetFromNumber(@floatFromInt(min_safe_integer)));
    try std.testing.expectError(error.InvalidOffset, offsetFromNumber(1.5));
    try std.testing.expectError(error.InvalidOffset, offsetFromNumber(std.math.inf(f64)));
    try std.testing.expectError(error.InvalidOffset, offsetFromNumber(std.math.nan(f64)));
    try std.testing.expectError(error.InvalidOffset, offsetFromNumber(@floatFromInt(max_safe_integer + 1)));
    try std.testing.expectEqual(@as(u64, 0), try sizeFromNumber(0));
    try std.testing.expectError(error.InvalidSize, sizeFromNumber(-1));
    try std.testing.expectError(error.InvalidSize, sizeFromNumber(1.25));
}

test "安全整数を超えるoffsetとsizeは公開時にBigIntへ上げる" {
    try std.testing.expectEqual(PublicInteger.number, publicOffset(max_safe_integer));
    try std.testing.expectEqual(PublicInteger.bigint, publicOffset(max_safe_integer + 1));
    try std.testing.expectEqual(PublicInteger.number, publicOffset(min_safe_integer));
    try std.testing.expectEqual(PublicInteger.bigint, publicOffset(min_safe_integer - 1));
    try std.testing.expectEqual(PublicInteger.number, publicSize(@as(u64, @intCast(max_safe_integer))));
    try std.testing.expectEqual(PublicInteger.bigint, publicSize(@as(u64, @intCast(max_safe_integer)) + 1));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), try offsetFromSigned(std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), try sizeFromUnsigned(std.math.maxInt(u64)));
    try std.testing.expectError(error.InvalidOffset, offsetFromSigned(@as(i128, std.math.maxInt(i64)) + 1));
    try std.testing.expectError(error.InvalidOffset, offsetFromSigned(@as(i128, std.math.minInt(i64)) - 1));
    try std.testing.expectError(error.InvalidSize, sizeFromUnsigned(@as(u128, std.math.maxInt(u64)) + 1));
}

test "timestampのナノ秒公開は常にBigIntで、欠損はnull、0はepoch" {
    const missing: OptionalTimeNs = null;
    try std.testing.expectEqual(PublicInteger.bigint, publicTimeNs(0));
    try std.testing.expectEqual(PublicInteger.bigint, publicTimeNs(1));
    try std.testing.expectEqual(@as(TimeNs, 1_000_000_000), try timeNsFromUnixMsNumber(1000));
    try std.testing.expectEqual(@as(TimeNs, @as(i128, max_safe_integer) * ns_per_ms), try timeNsFromUnixMsNumber(@floatFromInt(max_safe_integer)));
    try std.testing.expectEqual(@as(f64, 1000), try timeMsNumber(1_000_000_000));
    try std.testing.expectEqual(@as(f64, 1.5), try timeMsNumber(1_500_000));
    try std.testing.expectError(error.InvalidTimestamp, timeNsFromUnixMsNumber(1.5));
    try std.testing.expectEqual(@as(TimeNs, 2_000_000_000), timeNsFromUnixSeconds(2));
    try std.testing.expectEqual(@as(TimeNs, 2_000_000), timeNsFromUnixMicroseconds(2_000));
    try std.testing.expectEqual(@as(TimeNs, 9007199254740991), try timeNsFromNumber(9007199254740991));
    try std.testing.expectEqual(@as(TimeNs, 0), try timeNsFromNumber(0));
    try std.testing.expectEqual(@as(TimeNs, -1), try timeNsFromNumber(-1));
    try std.testing.expectError(error.InvalidTimestamp, timeNsFromNumber(1.5));
    try std.testing.expectError(error.InvalidTimestamp, timeNsFromNumber(@floatFromInt(max_safe_integer + 1)));
    try std.testing.expectEqual(@as(TimeNs, 2_000_000_000), (SetTime{ .at = 2_000_000_000 }).at);
    try std.testing.expectEqual(@as(TimeNs, -11644473600000000000), timeNsFromWindowsFileTime(0));
    try std.testing.expect(missing == null);
    try std.testing.expect(missing_timestamp_is_null);
    try std.testing.expect(zero_timestamp_is_unix_epoch);
    try std.testing.expect(file_time_epoch_is_utc);
    try std.testing.expect(zero_byte_read_is_eof);
    try std.testing.expect(partial_read_is_not_eof);
}

test "portable error codeは初期集合を改名せず、ENOTSUPとEBADFを含む" {
    try std.testing.expectEqualStrings("ENOENT", PortableErrorCode.ENOENT.name());
    try std.testing.expectEqual(PortableErrorCode.EXDEV, PortableErrorCode.fromName("EXDEV").?);
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, PortableErrorCode.fromName("ENOTSUP").?);
    try std.testing.expectEqual(PortableErrorCode.EBADF, PortableErrorCode.fromName("EBADF").?);
    try std.testing.expect(PortableErrorCode.fromName("UnknownCommand") == null);
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, unsupported_error_code);
    try std.testing.expectEqual(PortableErrorCode.EBADF, invalid_handle_error_code);
    try std.testing.expectEqual(@as(usize, 17), std.meta.tags(PortableErrorCode).len);
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeFor(error.InvalidOffset));
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeFor(error.InvalidSize));
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeFor(error.InvalidTimestamp));
    try std.testing.expect(error_string_equals_message);
}

test "構造化エラーのキーはNode SystemErrorへ写せる" {
    try std.testing.expectEqualStrings("code", error_object_keys.code);
    try std.testing.expectEqualStrings("nativeCode", error_object_keys.native_code);
    try std.testing.expectEqualStrings("operation", error_object_keys.operation);
    try std.testing.expectEqualStrings("path2", error_object_keys.path2);
    try std.testing.expectEqualStrings("capability", error_object_keys.capability);
    try std.testing.expectEqualStrings("errno", cnako_error_keys.errno);
    try std.testing.expectEqualStrings("syscall", cnako_error_keys.syscall);
    try std.testing.expectEqualStrings("dest", cnako_error_keys.dest);
    try std.testing.expect(structured_errors_apply_to_new_commands_only);
}

test "capability識別子はsnake_caseで分類が閉じている" {
    try std.testing.expectEqual(CapabilityClass.portable_core, Capability.stream_file_io.class());
    try std.testing.expect(capabilityImplemented(.stream_file_io));
    try std.testing.expect(capabilityImplemented(.truncate));
    try std.testing.expect(capabilityImplemented(.utime));
    try std.testing.expect(capabilityImplemented(.incremental_hash));
    try std.testing.expect(capabilityImplemented(.raw_stdio));
    try std.testing.expect(!capabilityImplemented(.termios));
    try std.testing.expectEqual(CapabilityClass.posix_extension, Capability.chmod.class());
    try std.testing.expectEqual(CapabilityClass.lnako_native, Capability.seek_data.class());
    try std.testing.expectEqual(Capability.statfs, Capability.fromId("statfs").?);
    try std.testing.expect(Capability.fromId("not_a_capability") == null);
    inline for (std.meta.tags(Capability)) |tag| {
        const text = tag.id();
        try std.testing.expect(text.len > 0);
        try std.testing.expect(std.ascii.isLower(text[0]));
        for (text) |character| {
            const ok = std.ascii.isLower(character) or std.ascii.isDigit(character) or character == '_';
            try std.testing.expect(ok);
        }
        try std.testing.expectEqual(tag, Capability.fromId(text).?);
    }
}

test "非対応OSのcapabilityは照会falseになる" {
    try std.testing.expect(capability_query_unknown_returns_false);
    inline for (.{ .chmod, .chown, .access, .uid_gid, .hardlink }) |capability| {
        try std.testing.expect(!capabilitySupportedOnOs(capability, .windows));
        try std.testing.expect(capabilitySupportedOnOs(capability, .linux));
        try std.testing.expect(capabilitySupportedOnOs(capability, .macos));
    }
    // Windowsでも成立するcapabilityはOSで落とさない。
    inline for (.{ .stream_file_io, .stat, .lstat, .unlink, .rename }) |capability| {
        try std.testing.expect(capabilitySupportedOnOs(capability, .windows));
    }
    // 未実装capabilityは指定OSに関わらずfalse。
    try std.testing.expect(!capabilitySupportedOnOs(.termios, .linux));
    try std.testing.expect(!capabilitySupportedOnOs(.statfs, .macos));
}

test "WASIではutime capabilityがfalseになる" {
    if (builtin.os.tag != .wasi) return error.SkipZigTest;
    // WASIはutimensat/futimensを持たず実行時にENOTSUPになるため、照会もfalse。
    try std.testing.expect(!capabilitySupportedOnCurrentOs(.utime));
    // truncateはWASIでもopen+setLengthで提供できる。
    try std.testing.expect(capabilitySupportedOnCurrentOs(.truncate));
}

test "未知capabilityの照会はfalseで、未対応実行はENOTSUP" {
    try std.testing.expect(aot_compiles_unsupported_calls);
    try std.testing.expectEqualStrings("低レイヤー機能対応判定", capability_supported_command);
    try std.testing.expectEqualStrings("低レイヤー機能一覧取得", capability_list_command);
    try std.testing.expectEqualStrings("NAMEの/NAMEを", capability_query_particles);
}

test "BytesとHandleの公開型契約を固定する" {
    try std.testing.expectEqualStrings("bytes", BytesContract.value_kind_name);
    try std.testing.expectEqualStrings("buffer", BytesContract.buffer_kind_name);
    try std.testing.expectEqual(@as(u32, 6), bytes_plugin_kind);
    try std.testing.expectEqualStrings("object", bytes_typeof_name);
    try std.testing.expectEqualStrings("Buffer", cnako_bytes_type);
    try std.testing.expect(empty_bytes_means_eof);
    try std.testing.expect(BytesContract.rejects_string);
    try std.testing.expect(HandleContract.public_is_opaque_object);
    try std.testing.expect(!HandleContract.public_is_number);
    try std.testing.expect(!HandleContract.public_is_os_fd);
    try std.testing.expect(HandleContract.clone_is_invalid);
    try std.testing.expectEqualStrings("object", handle_typeof_name);
}

test "新規命令は527件と衝突せずplugin_lowlevelへ登録する" {
    try std.testing.expectEqualStrings("plugin_lowlevel", plugin_namespace);
    try std.testing.expect(reserved_standard_command_names_are_examples);
    try std.testing.expect(naming.must_not_collide_with_standard_cnako);
    try std.testing.expect(naming.primary_language_is_japanese);
    try std.testing.expect(naming.ascii_primary_names_forbidden);
    try std.testing.expect(isExampleReservedStandardCommandName("開"));
    try std.testing.expect(isExampleReservedStandardCommandName("バイナリ読"));
    try std.testing.expect(!isExampleReservedStandardCommandName(capability_supported_command));
    try std.testing.expect(std.mem.startsWith(u8, capability_supported_command, naming.meta_prefix));
}

test "InterpreterとAOTは同一OSで一致し、cnakoはnative拡張を省略できる" {
    try std.testing.expect(CommonContract.interpreter_equals_aot_on_same_os);
    try std.testing.expect(CommonContract.aot_o0_to_o3_observably_equal);
    try std.testing.expect(CommonContract.portable_code_matches_across_lnako_runtimes);
    try std.testing.expect(CommonContract.native_code_may_differ);
    try std.testing.expect(CommonContract.message_may_differ);
    try std.testing.expect(CommonContract.cnako_may_omit_lnako_native);
    try std.testing.expect(CommonContract.no_javascript_in_default_lnako_runtime);
    try std.testing.expectEqual(RuntimeKind.lnako_interpreter, .lnako_interpreter);
    try std.testing.expectEqual(OsKind.macos, .macos);
}

test "ストリームI/O命令名はファイル接頭辞を持ち既存527件と衝突しない" {
    try std.testing.expect(std.mem.startsWith(u8, stream_commands.open, naming.file_prefix));
    try std.testing.expect(std.mem.startsWith(u8, stream_commands.read_bytes, naming.file_prefix));
    try std.testing.expect(!isExampleReservedStandardCommandName(stream_commands.open));
    try std.testing.expect(!isExampleReservedStandardCommandName(stream_commands.close));
    try std.testing.expect(!isExampleReservedStandardCommandName(stream_commands.read_bytes));
    try std.testing.expect(!isExampleReservedStandardCommandName(stream_commands.write_bytes));
    try std.testing.expect(!isExampleReservedStandardCommandName(stream_commands.sync));
    try std.testing.expect(!isExampleReservedStandardCommandName(stream_commands.truncate));
    try std.testing.expectEqualStrings("open", stream_operations.open);
    try std.testing.expectEqualStrings("ftruncate", stream_operations.ftruncate);
    try std.testing.expectEqual(@as(u8, 1), commandArity(stream_commands.close).?.max);
    try std.testing.expectEqual(@as(u8, 2), commandArity(stream_commands.open).?.max);
    try std.testing.expectEqual(@as(u8, 0), commandArity(capability_list_command).?.max);
    try std.testing.expectEqualStrings("hash", hash_operation);
    for ([_][]const u8{ hash_commands.create, hash_commands.update, hash_commands.digest, hash_commands.discard }) |name| {
        const command = catalogCommandFor(name).?;
        try std.testing.expect(command.implemented);
        try std.testing.expectEqual(Capability.incremental_hash, command.capability.?);
        try std.testing.expectEqualStrings(hash_operation, command.operation);
    }
}

test "Nodeの文字列flagsはOpenModeへ写り、不正modeはInvalidModeになる" {
    try std.testing.expectEqual(OpenMode.read, try openModeFromNodeFlags("r"));
    try std.testing.expectEqual(OpenMode.read_write, try openModeFromNodeFlags("r+"));
    try std.testing.expectEqual(OpenMode.write_create_truncate, try openModeFromNodeFlags("w"));
    try std.testing.expectEqual(OpenMode.write_read_create_truncate, try openModeFromNodeFlags("w+"));
    try std.testing.expectEqual(OpenMode.append_create, try openModeFromNodeFlags("a"));
    try std.testing.expectEqual(OpenMode.append_read_create, try openModeFromNodeFlags("a+"));
    try std.testing.expectEqual(OpenMode.read, try openModeFromNodeFlags("rb"));
    try std.testing.expectEqual(OpenMode.write_read_create_truncate, try openModeFromNodeFlags("w+b"));
    try std.testing.expectEqual(OpenMode.write_read_create_truncate, try openModeFromNodeFlags("w+bs"));
    try std.testing.expectEqual(OpenMode.write_create_truncate, try openModeFromNodeFlags("wx"));
    try std.testing.expectEqual(OpenMode.read_write, try openModeFromNodeFlags("rb+"));
    try std.testing.expectEqual(OpenMode.write_read_create_truncate, try openModeFromNodeFlags("w+x"));
    try std.testing.expectEqual(OpenMode.write_create_truncate, try openModeFromNodeFlags("xw"));
    try std.testing.expect((try parseOpenMode("wx+")).exclusive);
    try std.testing.expect((try parseOpenMode("w+bs")).sync);
    try std.testing.expect((try parseOpenMode("rs")).sync);
    try std.testing.expectError(error.InvalidMode, openModeFromNodeFlags("rbb"));
    try std.testing.expectError(error.InvalidMode, openModeFromNodeFlags("ssw"));
    try std.testing.expectError(error.InvalidMode, openModeFromNodeFlags(""));
    try std.testing.expectError(error.InvalidMode, openModeFromNodeFlags("x"));
    try std.testing.expectError(error.InvalidMode, openModeFromNodeFlags("rx"));
    try std.testing.expectError(error.InvalidMode, openModeFromNodeFlags("r+x"));
    try std.testing.expectError(error.InvalidMode, openModeFromNodeFlags("q"));
    try std.testing.expectError(error.InvalidMode, openModeFromNodeFlags("rq"));
    try std.testing.expect(OpenMode.read.isRead());
    try std.testing.expect(OpenMode.read_write.isWrite());
    try std.testing.expect(OpenMode.append_create.isAppend());
    try std.testing.expect(OpenMode.write_create_truncate.isTruncate());
    try std.testing.expect(OpenMode.write_read_create_truncate.creates());
    try std.testing.expect(!OpenMode.read.creates());
    try std.testing.expect(!OpenMode.read_write.creates());
}

test "portableCodeForFailureはI/O失敗をportable codeへ写す" {
    try std.testing.expectEqual(PortableErrorCode.ENOENT, portableCodeForFailure(error.FileNotFound).?);
    try std.testing.expectEqual(PortableErrorCode.EACCES, portableCodeForFailure(error.AccessDenied).?);
    try std.testing.expectEqual(PortableErrorCode.EPERM, portableCodeForFailure(error.PermissionDenied).?);
    try std.testing.expectEqual(PortableErrorCode.EISDIR, portableCodeForFailure(error.IsDir).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTDIR, portableCodeForFailure(error.NotDir).?);
    try std.testing.expectEqual(PortableErrorCode.EEXIST, portableCodeForFailure(error.PathAlreadyExists).?);
    try std.testing.expectEqual(PortableErrorCode.EROFS, portableCodeForFailure(error.ReadOnlyFileSystem).?);
    try std.testing.expectEqual(PortableErrorCode.ENOSPC, portableCodeForFailure(error.NoSpaceLeft).?);
    try std.testing.expectEqual(PortableErrorCode.EMFILE, portableCodeForFailure(error.ProcessFdQuotaExceeded).?);
    try std.testing.expectEqual(PortableErrorCode.ENFILE, portableCodeForFailure(error.SystemFdQuotaExceeded).?);
    try std.testing.expectEqual(PortableErrorCode.ELOOP, portableCodeForFailure(error.SymLinkLoop).?);
    try std.testing.expectEqual(PortableErrorCode.EBADF, portableCodeForFailure(error.NotOpenForReading).?);
    try std.testing.expectEqual(PortableErrorCode.EBADF, portableCodeForFailure(error.NotOpenForWriting).?);
    try std.testing.expectEqual(PortableErrorCode.EPIPE, portableCodeForFailure(error.BrokenPipe).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTEMPTY, portableCodeForFailure(error.DirNotEmpty).?);
    try std.testing.expectEqual(PortableErrorCode.EXDEV, portableCodeForFailure(error.CrossDevice).?);
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeForFailure(error.NotLink).?);
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeForFailure(error.InvalidTimestamp).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeForFailure(error.OperationUnsupported).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeForFailure(error.UnsupportedReparsePointType).?);
    try std.testing.expectEqual(PortableErrorCode.EPERM, portableCodeForFailure(error.LinkQuotaExceeded).?);
    // stdin履歴上限超過はリソース枯渇としてENOSPCへ写す。
    try std.testing.expectEqual(PortableErrorCode.ENOSPC, portableCodeForFailure(error.StreamTooLong).?);
    try std.testing.expect(portableCodeForFailure(error.OutOfMemory) == null);
}

test "portableCodeForSpawnFailureは契約集合へ限定しEMFILE/ENFILEをEINVALへ丸める" {
    try std.testing.expectEqual(PortableErrorCode.ENOENT, portableCodeForSpawnFailure(error.FileNotFound));
    try std.testing.expectEqual(PortableErrorCode.EACCES, portableCodeForSpawnFailure(error.AccessDenied));
    try std.testing.expectEqual(PortableErrorCode.EPERM, portableCodeForSpawnFailure(error.PermissionDenied));
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeForSpawnFailure(error.OperationUnsupported));
    // spawn契約にEMFILE/ENFILEは無いためEINVALへ丸める。
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeForSpawnFailure(error.ProcessFdQuotaExceeded));
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeForSpawnFailure(error.SystemFdQuotaExceeded));
    try std.testing.expectEqual(PortableErrorCode.EINVAL, portableCodeForSpawnFailure(error.InvalidExe));
}

test "Issue 29の9命令は実装済みでcapabilityが有効になる" {
    const expected_ids = [_][]const u8{
        "ll-file-stat",
        "ll-file-lstat",
        "ll-symlink-create",
        "ll-symlink-read",
        "ll-hardlink-create",
        "ll-path-realpath",
        "ll-path-rename",
        "ll-path-unlink",
        "ll-path-rmdir",
    };
    const expected_capabilities = [_]Capability{
        .stat, .lstat, .symlink, .readlink, .hardlink, .realpath, .rename, .unlink, .rmdir,
    };
    const expected_operations = [_][]const u8{
        filesystem_operations.stat,
        filesystem_operations.lstat,
        filesystem_operations.symlink,
        filesystem_operations.readlink,
        filesystem_operations.hardlink,
        filesystem_operations.realpath,
        filesystem_operations.rename,
        filesystem_operations.unlink,
        filesystem_operations.rmdir,
    };
    for (expected_ids, 0..) |id, index| {
        var found = false;
        for (catalog_commands) |command| {
            if (!std.mem.eql(u8, command.id, id)) continue;
            found = true;
            try std.testing.expect(command.implemented);
            try std.testing.expectEqual(expected_capabilities[index], command.capability.?);
            try std.testing.expectEqualStrings(expected_operations[index], command.operation);
        }
        try std.testing.expect(found);
        try std.testing.expect(capabilityImplemented(expected_capabilities[index]));
    }
    try std.testing.expectEqualStrings("blockSize", stat_field_keys.block_size);
    try std.testing.expectEqualStrings("birthtimeNs", stat_field_keys.birthtime_ns);
    try std.testing.expectEqualStrings("kind", stat_field_keys.kind);
}

test "Issue 31の3命令は実装済みでtruncate/utime capabilityが有効になる" {
    const expected_ids = [_][]const u8{
        "ll-file-truncate-path",
        "ll-file-utime-path",
        "ll-file-utime-handle",
    };
    const expected_operations = [_][]const u8{
        filesystem_operations.truncate,
        filesystem_operations.utime,
        filesystem_operations.futime,
    };
    const expected_capabilities = [_]Capability{ .truncate, .utime, .utime };
    for (expected_ids, 0..) |id, index| {
        var found = false;
        for (catalog_commands) |command| {
            if (!std.mem.eql(u8, command.id, id)) continue;
            found = true;
            try std.testing.expect(command.implemented);
            try std.testing.expectEqual(expected_capabilities[index], command.capability.?);
            try std.testing.expectEqualStrings(expected_operations[index], command.operation);
            try std.testing.expectEqual(if (index == 0) @as(u8, 2) else @as(u8, 3), command.min);
        }
        try std.testing.expect(found);
        try std.testing.expect(capabilityImplemented(expected_capabilities[index]));
    }
    try std.testing.expectEqualStrings("ファイルサイズ変更", filesystem_commands.truncate_path);
    try std.testing.expectEqualStrings("ファイル時刻設定", filesystem_commands.utime_path);
    try std.testing.expectEqualStrings("ファイル時刻設定済", filesystem_commands.utime_handle);
    try std.testing.expectEqual(@as(u8, 2), commandArity(filesystem_commands.truncate_path).?.min);
    try std.testing.expectEqual(@as(u8, 3), commandArity(filesystem_commands.utime_path).?.max);
}

test "Issue 34の10命令は実装済みでcapabilityが有効になる" {
    const expected_ids = [_][]const u8{
        "ll-file-chmod",
        "ll-file-chown",
        "ll-symlink-chown",
        "ll-file-access",
        "ll-uid-get",
        "ll-euid-get",
        "ll-gid-get",
        "ll-egid-get",
        "ll-groups-get",
        "ll-umask-set",
    };
    const expected_capabilities = [_]Capability{
        .chmod, .chown, .chown, .access, .uid_gid, .uid_gid, .uid_gid, .uid_gid, .uid_gid, .uid_gid,
    };
    const expected_operations = [_][]const u8{
        posix_operations.chmod,
        posix_operations.chown,
        posix_operations.lchown,
        posix_operations.access,
        posix_operations.uid,
        posix_operations.euid,
        posix_operations.gid,
        posix_operations.egid,
        posix_operations.groups,
        posix_operations.umask,
    };
    for (expected_ids, 0..) |id, index| {
        var found = false;
        for (catalog_commands) |command| {
            if (!std.mem.eql(u8, command.id, id)) continue;
            found = true;
            try std.testing.expect(command.implemented);
            try std.testing.expectEqual(expected_capabilities[index], command.capability.?);
            try std.testing.expectEqualStrings(expected_operations[index], command.operation);
        }
        try std.testing.expect(found);
        try std.testing.expect(capabilityImplemented(expected_capabilities[index]));
    }
    try std.testing.expectEqual(@as(u32, 0o7777), max_permission_mode);
    try std.testing.expectEqual(@as(u32, 7), access_mode.all);
    try std.testing.expectEqual(@as(i64, -1), unchanged_id);
}
