const std = @import("std");

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

/// ハッシュhandleのindex空間の開始値。ファイルhandleは1から連番で払い出す。
/// ファイル側の払い出しもこの値へ到達しないよう制限し、raw HandleIdが
/// 種別を跨いで衝突しないことを双方向で保証する（Issue #32）。
pub const hash_handle_index_base: u32 = 0x8000_0000;

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
        .stat,
        .lstat,
        .symlink,
        .readlink,
        .hardlink,
        .realpath,
        .rename,
        .unlink,
        .rmdir,
        => true,
        else => false,
    };
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
};

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

/// カタログ掲載61命令の実行時正本。`catalog.json` の `commands` と同じ順序で、
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
    .{ .id = "ll-stdin-read", .name = "標準入力バイト読", .user_name = "標準入力バイト読む", .min = 1, .max = 1, .operation = "read", .capability = .raw_stdio },
    .{ .id = "ll-stdout-write", .name = "標準出力バイト書", .user_name = "標準出力バイト書く", .min = 1, .max = 1, .operation = "write", .capability = .raw_stdio },
    .{ .id = "ll-stderr-write", .name = "標準エラー出力バイト書", .user_name = "標準エラー出力バイト書く", .min = 1, .max = 1, .operation = "write", .capability = .raw_stdio },
    .{ .id = "ll-stdout-sync", .name = "標準出力同期", .min = 0, .max = 0, .operation = "fsync", .capability = .raw_stdio },
    .{ .id = "ll-stderr-sync", .name = "標準エラー出力同期", .min = 0, .max = 0, .operation = "fsync", .capability = .raw_stdio },
    .{ .id = "ll-file-stat", .name = filesystem_commands.stat, .min = 1, .max = 1, .operation = filesystem_operations.stat, .capability = .stat, .implemented = true },
    .{ .id = "ll-file-lstat", .name = filesystem_commands.lstat, .min = 1, .max = 1, .operation = filesystem_operations.lstat, .capability = .lstat, .implemented = true },
    .{ .id = "ll-symlink-create", .name = filesystem_commands.symlink, .min = 2, .max = 2, .operation = filesystem_operations.symlink, .capability = .symlink, .implemented = true },
    .{ .id = "ll-symlink-read", .name = filesystem_commands.readlink, .min = 1, .max = 1, .operation = filesystem_operations.readlink, .capability = .readlink, .implemented = true },
    .{ .id = "ll-hardlink-create", .name = filesystem_commands.hardlink, .min = 2, .max = 2, .operation = filesystem_operations.hardlink, .capability = .hardlink, .implemented = true },
    .{ .id = "ll-path-realpath", .name = filesystem_commands.realpath, .min = 1, .max = 1, .operation = filesystem_operations.realpath, .capability = .realpath, .implemented = true },
    .{ .id = "ll-path-rename", .name = filesystem_commands.rename, .min = 2, .max = 2, .operation = filesystem_operations.rename, .capability = .rename, .implemented = true },
    .{ .id = "ll-path-unlink", .name = filesystem_commands.unlink, .min = 1, .max = 1, .operation = filesystem_operations.unlink, .capability = .unlink, .implemented = true },
    .{ .id = "ll-path-rmdir", .name = filesystem_commands.rmdir, .min = 1, .max = 1, .operation = filesystem_operations.rmdir, .capability = .rmdir, .implemented = true },
    .{ .id = "ll-file-truncate-path", .name = "ファイルサイズ変更", .min = 2, .max = 2, .operation = "truncate", .capability = .truncate },
    .{ .id = "ll-file-utime-path", .name = "ファイル時刻設定", .min = 3, .max = 3, .operation = "utime", .capability = .utime },
    .{ .id = "ll-file-utime-handle", .name = "ファイル時刻設定済", .min = 3, .max = 3, .operation = "futime", .capability = .utime },
    .{ .id = "ll-hash-create", .name = hash_commands.create, .min = 1, .max = 1, .operation = "hash", .capability = .incremental_hash, .implemented = true },
    .{ .id = "ll-hash-update", .name = hash_commands.update, .min = 2, .max = 2, .operation = "hash", .capability = .incremental_hash, .implemented = true },
    .{ .id = "ll-hash-digest", .name = hash_commands.digest, .min = 1, .max = 2, .operation = "hash", .capability = .incremental_hash, .implemented = true },
    .{ .id = "ll-hash-discard", .name = hash_commands.discard, .min = 1, .max = 1, .operation = "hash", .capability = .incremental_hash, .implemented = true },
    .{ .id = "ll-dir-open", .name = "ディレクトリ開", .user_name = "ディレクトリ開く", .min = 1, .max = 1, .operation = "opendir", .capability = .dir_iterator },
    .{ .id = "ll-dir-next", .name = "ディレクトリ次取得", .min = 1, .max = 1, .operation = "readdir", .capability = .dir_iterator },
    .{ .id = "ll-dir-close", .name = "ディレクトリ閉", .user_name = "ディレクトリ閉じる", .min = 1, .max = 1, .operation = "closedir", .capability = .dir_iterator },
    .{ .id = "ll-dir-foreach", .name = "ディレクトリ列挙時", .min = 2, .max = 2, .operation = "readdir", .capability = .dir_iterator },
    .{ .id = "ll-file-chmod", .name = "ファイル権限設定", .min = 2, .max = 2, .operation = "chmod", .capability = .chmod },
    .{ .id = "ll-file-chown", .name = "ファイル所有者設定", .min = 3, .max = 3, .operation = "chown", .capability = .chown },
    .{ .id = "ll-symlink-chown", .name = "シンボリックリンク所有者設定", .min = 3, .max = 3, .operation = "lchown", .capability = .chown },
    .{ .id = "ll-file-access", .name = "ファイルアクセス可能", .min = 2, .max = 2, .operation = "access", .capability = .access },
    .{ .id = "ll-uid-get", .name = "UID取得", .min = 0, .max = 0, .operation = "getuid", .capability = .uid_gid },
    .{ .id = "ll-euid-get", .name = "EUID取得", .min = 0, .max = 0, .operation = "geteuid", .capability = .uid_gid },
    .{ .id = "ll-gid-get", .name = "GID取得", .min = 0, .max = 0, .operation = "getgid", .capability = .uid_gid },
    .{ .id = "ll-egid-get", .name = "EGID取得", .min = 0, .max = 0, .operation = "getegid", .capability = .uid_gid },
    .{ .id = "ll-groups-get", .name = "所属グループID一覧取得", .min = 0, .max = 0, .operation = "getgroups", .capability = .uid_gid },
    .{ .id = "ll-umask-set", .name = "UMASK変更", .min = 1, .max = 1, .operation = "umask", .capability = .uid_gid },
    .{ .id = "ll-process-spawn", .name = "プロセス起動", .min = 1, .max = 2, .operation = "spawn", .capability = .argv_spawn },
    .{ .id = "ll-process-wait", .name = "プロセス待機", .min = 1, .max = 1, .operation = "wait", .capability = .argv_spawn },
    .{ .id = "ll-pid-get", .name = "プロセスID取得", .min = 0, .max = 0, .operation = "getpid", .capability = .argv_spawn },
    .{ .id = "ll-ppid-get", .name = "親プロセスID取得", .min = 0, .max = 0, .operation = "getppid", .capability = .argv_spawn },
    .{ .id = "ll-signal-send", .name = "シグナル送信", .min = 2, .max = 2, .operation = "kill", .capability = .signal },
    .{ .id = "ll-process-priority-get", .name = "プロセス優先度取得", .min = 1, .max = 1, .operation = "getpriority", .capability = .priority },
    .{ .id = "ll-process-priority-set", .name = "プロセス優先度設定", .min = 2, .max = 2, .operation = "setpriority", .capability = .priority },
    .{ .id = "ll-tty-isatty", .name = "端末判定", .min = 1, .max = 1, .operation = "isatty", .capability = .tty_isatty },
    .{ .id = "ll-tty-size", .name = "端末サイズ取得", .min = 1, .max = 1, .operation = "winsize", .capability = .tty_isatty },
    .{ .id = "ll-statfs", .name = "ファイルシステム情報取得", .min = 1, .max = 1, .operation = "statfs", .capability = .statfs },
    .{ .id = "ll-reflink", .name = "ファイルクローン", .min = 2, .max = 3, .operation = "reflink", .capability = .reflink },
    .{ .id = "ll-seek-data", .name = "ファイルデータ領域検索", .min = 2, .max = 2, .operation = "lseek", .capability = .seek_data },
    .{ .id = "ll-seek-hole", .name = "ファイル空洞領域検索", .min = 2, .max = 2, .operation = "lseek", .capability = .seek_hole },
    .{ .id = "ll-fallocate", .name = "ファイル領域確保", .min = 3, .max = 3, .operation = "fallocate", .capability = .fallocate },
    .{ .id = "ll-capability-supported", .name = capability_supported_command, .min = 1, .max = 1, .operation = "capability", .capability = null, .implemented = true },
    .{ .id = "ll-capability-list", .name = capability_list_command, .min = 0, .max = 0, .operation = "capability", .capability = null, .implemented = true },
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
/// カタログ61命令のdispatch名と利用者向け表記を全て含む。
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
};

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
        error.ReadOnlyFileSystem => .EROFS,
        error.NoSpaceLeft, error.DiskQuota, error.FileTooBig => .ENOSPC,
        error.ProcessFdQuotaExceeded => .EMFILE,
        error.SystemFdQuotaExceeded => .ENFILE,
        error.NotOpenForReading, error.NotOpenForWriting, error.BadFileDescriptor => .EBADF,
        error.BrokenPipe => .EPIPE,
        // hardlink/renameの非対応FSとWindowsの未対応reparse pointはENOTSUP。
        // 本関数はG0正本 `structured_error.portableCodeFromFailure` の上位集合で、
        // 低レイヤー固有のエラー名（LowLevelIoUnavailable等）もここで畳む。
        error.LowLevelIoUnavailable, error.OperationUnsupported, error.UnsupportedReparsePointType, error.Unsupported, error.NotSupported => .ENOTSUP,
        // リンク数上限（EMLINK相当）はportable 17種に無いためEPERMへ丸める。
        error.LinkQuotaExceeded => .EPERM,
        else => null,
    };
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
    try std.testing.expect(capabilityImplemented(.incremental_hash));
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

test "未知capabilityの照会はfalseで、未対応実行はENOTSUP" {
    try std.testing.expect(capability_query_unknown_returns_false);
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
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeForFailure(error.OperationUnsupported).?);
    try std.testing.expectEqual(PortableErrorCode.ENOTSUP, portableCodeForFailure(error.UnsupportedReparsePointType).?);
    try std.testing.expectEqual(PortableErrorCode.EPERM, portableCodeForFailure(error.LinkQuotaExceeded).?);
    try std.testing.expect(portableCodeForFailure(error.OutOfMemory) == null);
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
