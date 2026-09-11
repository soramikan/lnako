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
