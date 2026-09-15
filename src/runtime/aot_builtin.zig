const std = @import("std");
const environment = @import("environment.zig");
const low_level_foundation = @import("low_level_foundation.zig");
const builtin_catalog = @import("../semantic/builtin_catalog.zig");

pub const Command = enum(u16) {
    to_string,
    type_of,
    to_int,
    to_float,
    is_nan,
    is_number_nan,
    radix16,
    radix,
    radix2,
    radix2_display,
    rgb,
    bit_or,
    bit_and,
    bit_xor,
    bit_not,
    shift_left,
    shift_right,
    shift_right_unsigned,
    subtract,
    multiply,
    divide,
    remainder,
    is_even,
    is_odd,
    square,
    power_number,
    greater_equal,
    less_equal,
    less,
    greater,
    strict_equal,
    strict_not_equal,
    in_range,
    maximum,
    minimum,
    clamp,
    logical_or,
    logical_and,
    logical_not,
    range,
    empty_array,
    empty_dictionary,
    dictionary_keys,
    dictionary_remove,
    dictionary_has,
    hash_keys,
    hash_values,
    hash_remove,
    hash_has,
    truth_label,
    repeat_multiply,
    unicode_length,
    codepoint_find,
    string_starts,
    string_ends,
    element_count,
    array_join,
    array_join_only,
    array_search,
    array_sort,
    array_numeric_convert,
    array_numeric_sort,
    array_reverse,
    array_insert,
    array_insert_many,
    array_cut,
    array_take,
    array_pop,
    array_push,
    array_clone,
    array_range_copy,
    reference,
    array_add,
    array_maximum,
    array_minimum,
    array_sum,
    array_swap,
    array_sequence,
    array_fill,
    table_pickup,
    table_exact_pickup,
    table_search,
    table_column_count,
    table_row_count,
    table_column,
    table_transpose,
    table_rotate,
    table_unique,
    table_insert_column,
    table_delete_column,
    table_column_sum,
    table_regexp_search,
    table_regexp_pickup,
    add_parsed,
    sum_parsed,
    sequential_add,
    chr,
    asc,
    string_insert,
    string_search,
    append,
    append_line,
    concat_join,
    explode,
    refrain,
    occurrence_count,
    occurrence,
    cut,
    cut_range,
    substring_mid,
    substring_left,
    substring_right,
    split_all,
    split_first,
    string_remove,
    trim_both,
    trim_right,
    trim_left,
    replace_all,
    replace_first,
    uppercase,
    lowercase,
    hiragana,
    katakana,
    ascii_full_width,
    ascii_half_width,
    ascii_symbol_full_width,
    ascii_symbol_half_width,
    katakana_full_width,
    katakana_half_width,
    full_width,
    half_width,
    currency_format,
    zero_pad,
    space_pad,
    hiragana_predicate,
    katakana_predicate,
    digit_predicate,
    number_sequence_predicate,
    regexp_match,
    regexp_extract,
    regexp_replace,
    regexp_split,
    json_encode,
    json_encode_pretty,
    json_decode,
    math_sin,
    math_cos,
    math_tan,
    math_arcsin,
    math_arccos,
    math_arctan,
    math_atan2,
    math_coordinate_angle,
    math_rad2deg,
    math_deg2rad,
    math_sign,
    math_abs,
    math_exp,
    math_hypot,
    math_log,
    math_logn,
    math_frac,
    math_integer,
    math_sqrt,
    math_round,
    math_decimal_ceil,
    math_decimal_floor,
    math_decimal_round,
    math_ceil,
    math_floor,
    math_random,
    math_random_range,
    datetime_now,
    datetime_system_time,
    datetime_system_time_milliseconds,
    datetime_today,
    datetime_tomorrow,
    datetime_yesterday,
    datetime_current_year,
    datetime_next_year,
    datetime_last_year,
    datetime_current_month,
    datetime_next_month,
    datetime_previous_month,
    caniuse_browsers,
    datetime_weekday,
    datetime_weekday_number,
    datetime_unix_time,
    datetime_date_time,
    url_encode,
    url_decode,
    url_parameters,
    base64_encode,
    base64_decode,
    node_os,
    node_architecture,
    node_environment_get,
    node_environment_list,
    node_current_directory,
    node_change_directory,
    node_path_basename,
    node_path_dirname,
    node_path_absolute,
    node_path_resolve,
    datetime_format,
    datetime_era,
    datetime_year_difference,
    datetime_month_difference,
    datetime_day_difference,
    datetime_hour_difference,
    datetime_minute_difference,
    datetime_second_difference,
    datetime_difference,
    datetime_add_time,
    datetime_add_date,
    datetime_add_datetime,
    datetime_monotonic_milliseconds,
    path_extract_extension,
    path_change_extension,
    path_add_trailing_separator,
    path_remove_trailing_separator,
    path_delete_trailing_separator,
    kansuji_to_kanji,
    kansuji_to_arabic,
    csv_parse,
    tsv_parse,
    table_csv_stringify,
    csv_stringify,
    table_tsv_stringify,
    tsv_stringify,
    csv_options,
    toml_parse,
    toml_stringify,
    markdown_to_html,
    html_pretty,
    deep_equal,
    deep_not_equal,
    table_sort,
    table_numeric_sort,
    courtesy_increment,
    courtesy_begin,
    courtesy_end,
    courtesy_level,
    stdio_continue_display,
    stdio_continue_display_many,
    stdio_clear_log,
    stdio_write_all,
    plugin_name_set,
    namespace_set,
    namespace_pop,
    timer_wait,
    async_noop,
    system_await_execute,
    system_execute,
    system_debug_display,
    system_debug_enable,
    system_global_function_names,
    system_function_names,
    system_function_exists,
    plugin_names,
    josi_names,
    reserved_words,
    assert_strict_equal,
    array_shuffle,
    array_custom_sort,
    array_function_apply,
    array_map,
    array_filter,
    line_notify_discontinued,
    node_exit,
    node_process_exit,
    node_file_exists,
    node_folder_exists,
    node_home_directory,
    node_desktop,
    node_documents,
    node_temporary_directory,
    node_mother_path,
    node_temporary_directory_create,
    system_measure_time,
    node_hash_names,
    system_hatena_execute,
    node_archive_tool_path_set,
    node_file_size,
    node_encoding_supports,
    node_stdin_all,
    node_post_data,
    node_ajax_options_set,
    node_ajax_onerror_set,
    node_network_ipv4,
    node_network_ipv6,
    node_file_info,
    node_hash_value,
    node_random_uuid,
    node_random_array,
    timer_after,
    timer_every,
    timer_stop,
    timer_stop_all,
    promise_create,
    promise_success,
    promise_settled,
    promise_failure,
    promise_finally,
    promise_all,
    node_file_open,
    node_file_read,
    node_file_binary_read,
    node_file_save,
    node_file_sjis_read,
    node_file_sjis_save,
    node_file_euc_read,
    node_file_euc_save,
    node_encoding_sjis_encode,
    node_encoding_sjis_decode,
    node_encoding_encode,
    node_encoding_decode,
    node_file_list,
    node_file_list_all,
    node_folder_create,
    node_file_copy,
    node_file_copy_overwrite,
    node_file_move,
    node_file_move_overwrite,
    node_file_delete,
    node_console_clear,
    system_debug_breakpoint_wait,
    node_stdin_line,
    node_stdin_character,
    node_stdin_callback,
    system_hatena_configure,
    node_interrupt_callback,
    http_server_start,
    http_server_static,
    http_server_receive,
    http_server_output,
    http_server_headers,
    http_server_redirect,
    node_archive_extract,
    node_archive_extract_callback,
    node_archive_create,
    node_archive_create_callback,
    node_process_run_wait,
    node_process_run,
    node_process_run_wait_output,
    node_process_start,
    node_process_start_callback,
    node_open_external_browser,
    node_open_external_explorer,
    node_file_process_callback,
    node_file_process_stop,
    node_file_copy_callback,
    node_file_move_callback,
    node_file_delete_callback,
    node_ajax_send_callback,
    node_ajax_receive_callback,
    node_get_send_callback,
    node_post_send_callback,
    node_post_form_send_callback,
    node_ajax_response_promise,
    node_http_response_promise,
    node_get_response_promise,
    node_post_response_promise,
    node_post_form_response_promise,
    node_ajax_content_get,
    node_ajax_receive,
    node_post_send,
    node_post_form_send,
    node_ajax_text_get,
    node_ajax_json_get,
    node_ajax_binary_get,
    node_discord_send,
    node_discord_file_send,
    system_nadesiko,
    system_nadesiko_continue,
    // Keep this after the existing commands so the opcode values already
    // emitted into manifests remain stable.  The official implementation
    // uses a command-specific error message for this alias.
    line_image_notify_discontinued,
    // These route-specific commands are appended to preserve every opcode
    // already emitted into a compile manifest.  They are selected only by
    // the evidence-only plugin_system route; normal cnako execution keeps
    // the Node-shadowing opcodes above.
    system_end,
    system_path_basename,
    system_path_dirname,
    // Issue #27の低レイヤーストリームI/O。G0でplugin_lowlevelへ登録した命令。
    // 既存opcodeの安定性を保つため常に末尾へ追加する。
    low_level_file_open,
    low_level_file_close,
    low_level_file_read_bytes,
    low_level_file_write_bytes,
    low_level_file_sync,
    low_level_file_truncate,
    low_level_capability_supported,
    low_level_capability_list,
    // カタログ掲載済みだが未実装の低レイヤー命令。コンパイルは成功し、
    // 実行時に `capability` と `operation` を持つ構造化 ENOTSUP を投げる
    // （`low_level_foundation.aot_compiles_unsupported_calls`）。
    // `isLowLevelCommand` は末尾連続配置に依存するため、低レイヤー以外の
    // opcodeをこの区間の後ろへ置かないこと。
    low_level_file_seek,
    low_level_file_tell,
    low_level_file_pread,
    low_level_file_pwrite,
    low_level_stdin_read,
    low_level_stdout_write,
    low_level_stderr_write,
    low_level_stdout_sync,
    low_level_stderr_sync,
    low_level_file_stat,
    low_level_file_lstat,
    low_level_symlink_create,
    low_level_symlink_read,
    low_level_hardlink_create,
    low_level_path_realpath,
    low_level_path_rename,
    low_level_path_unlink,
    low_level_path_rmdir,
    low_level_file_truncate_path,
    low_level_file_utime_path,
    low_level_file_utime_handle,
    low_level_hash_create,
    low_level_hash_update,
    low_level_hash_digest,
    low_level_hash_discard,
    low_level_dir_open,
    low_level_dir_next,
    low_level_dir_close,
    low_level_dir_foreach,
    low_level_file_chmod,
    low_level_file_chown,
    low_level_symlink_chown,
    low_level_file_access,
    low_level_uid_get,
    low_level_euid_get,
    low_level_gid_get,
    low_level_egid_get,
    low_level_groups_get,
    low_level_umask_set,
    low_level_process_spawn,
    low_level_process_wait,
    low_level_pid_get,
    low_level_ppid_get,
    low_level_signal_send,
    low_level_process_priority_get,
    low_level_process_priority_set,
    low_level_tty_isatty,
    low_level_tty_size,
    low_level_statfs,
    low_level_reflink,
    low_level_seek_data,
    low_level_seek_hole,
    low_level_fallocate,
};

/// `エラー発生` is lowered to an IR throw terminator, not to the generic
/// builtin-call ABI. Reserve an opcode outside the builtin enum so its
/// compile/runtime evidence cannot be mistaken for one of the 527 command
/// dispatches.
pub const throw_statement_opcode: u16 = std.math.maxInt(u16);
pub const throw_statement_canonical_opcode = "throw_statement";
pub const throw_statement_route = "throw";

/// 低レイヤー命令のopcodeと `low_level_foundation.catalog_commands` の
/// dispatch名の対応表。`lookup` / `dispatchRoute` / 実行時dispatchは全て
/// この表へ揃え、実装済み・未実装（ENOTSUP stub）のどちらも同じ経路を通す。
const LowLevelBinding = struct {
    command: Command,
    name: []const u8,
};

pub const low_level_bindings = [_]LowLevelBinding{
    .{ .command = .low_level_file_open, .name = "ファイル開" },
    .{ .command = .low_level_file_close, .name = "ファイル閉" },
    .{ .command = .low_level_file_read_bytes, .name = "ファイルバイト読" },
    .{ .command = .low_level_file_write_bytes, .name = "ファイルバイト書" },
    .{ .command = .low_level_file_sync, .name = "ファイル同期" },
    .{ .command = .low_level_file_truncate, .name = "ファイル切詰" },
    .{ .command = .low_level_capability_supported, .name = "低レイヤー機能対応判定" },
    .{ .command = .low_level_capability_list, .name = "低レイヤー機能一覧取得" },
    .{ .command = .low_level_file_seek, .name = "ファイル位置変更" },
    .{ .command = .low_level_file_tell, .name = "ファイル位置取得" },
    .{ .command = .low_level_file_pread, .name = "ファイル位置指定読込" },
    .{ .command = .low_level_file_pwrite, .name = "ファイル位置指定書込" },
    .{ .command = .low_level_stdin_read, .name = "標準入力バイト読" },
    .{ .command = .low_level_stdout_write, .name = "標準出力バイト書" },
    .{ .command = .low_level_stderr_write, .name = "標準エラー出力バイト書" },
    .{ .command = .low_level_stdout_sync, .name = "標準出力同期" },
    .{ .command = .low_level_stderr_sync, .name = "標準エラー出力同期" },
    .{ .command = .low_level_file_stat, .name = "ファイル詳細情報取得" },
    .{ .command = .low_level_file_lstat, .name = "シンボリックリンク情報取得" },
    .{ .command = .low_level_symlink_create, .name = "シンボリックリンク作成" },
    .{ .command = .low_level_symlink_read, .name = "シンボリックリンク先取得" },
    .{ .command = .low_level_hardlink_create, .name = "ハードリンク作成" },
    .{ .command = .low_level_path_realpath, .name = "実体パス取得" },
    .{ .command = .low_level_path_rename, .name = "パス名変更" },
    .{ .command = .low_level_path_unlink, .name = "ファイルリンク削除" },
    .{ .command = .low_level_path_rmdir, .name = "空フォルダ削除" },
    .{ .command = .low_level_file_truncate_path, .name = "ファイルサイズ変更" },
    .{ .command = .low_level_file_utime_path, .name = "ファイル時刻設定" },
    .{ .command = .low_level_file_utime_handle, .name = "ファイル時刻設定済" },
    .{ .command = .low_level_hash_create, .name = low_level_foundation.hash_commands.create },
    .{ .command = .low_level_hash_update, .name = low_level_foundation.hash_commands.update },
    .{ .command = .low_level_hash_digest, .name = low_level_foundation.hash_commands.digest },
    .{ .command = .low_level_hash_discard, .name = low_level_foundation.hash_commands.discard },
    .{ .command = .low_level_dir_open, .name = "ディレクトリ開" },
    .{ .command = .low_level_dir_next, .name = "ディレクトリ次取得" },
    .{ .command = .low_level_dir_close, .name = "ディレクトリ閉" },
    .{ .command = .low_level_dir_foreach, .name = "ディレクトリ列挙時" },
    .{ .command = .low_level_file_chmod, .name = "ファイル権限設定" },
    .{ .command = .low_level_file_chown, .name = "ファイル所有者設定" },
    .{ .command = .low_level_symlink_chown, .name = "シンボリックリンク所有者設定" },
    .{ .command = .low_level_file_access, .name = "ファイルアクセス可能" },
    .{ .command = .low_level_uid_get, .name = "UID取得" },
    .{ .command = .low_level_euid_get, .name = "EUID取得" },
    .{ .command = .low_level_gid_get, .name = "GID取得" },
    .{ .command = .low_level_egid_get, .name = "EGID取得" },
    .{ .command = .low_level_groups_get, .name = "所属グループID一覧取得" },
    .{ .command = .low_level_umask_set, .name = "UMASK変更" },
    .{ .command = .low_level_process_spawn, .name = "プロセス起動" },
    .{ .command = .low_level_process_wait, .name = "プロセス待機" },
    .{ .command = .low_level_pid_get, .name = "プロセスID取得" },
    .{ .command = .low_level_ppid_get, .name = "親プロセスID取得" },
    .{ .command = .low_level_signal_send, .name = "シグナル送信" },
    .{ .command = .low_level_process_priority_get, .name = "プロセス優先度取得" },
    .{ .command = .low_level_process_priority_set, .name = "プロセス優先度設定" },
    .{ .command = .low_level_tty_isatty, .name = "端末判定" },
    .{ .command = .low_level_tty_size, .name = "端末サイズ取得" },
    .{ .command = .low_level_statfs, .name = "ファイルシステム情報取得" },
    .{ .command = .low_level_reflink, .name = "ファイルクローン" },
    .{ .command = .low_level_seek_data, .name = "ファイルデータ領域検索" },
    .{ .command = .low_level_seek_hole, .name = "ファイル空洞領域検索" },
    .{ .command = .low_level_fallocate, .name = "ファイル領域確保" },
};

comptime {
    @setEvalBranchQuota(500_000);
    // `isLowLevelCommand` の範囲判定は `low_level_bindings` がカタログの
    // 全命令を網羅し、enumの末尾へ連続配置されていることを前提にする。
    std.debug.assert(low_level_bindings.len == low_level_foundation.catalog_commands.len);
    for (low_level_bindings, 0..) |binding, index| {
        const spec = low_level_foundation.catalogCommandFor(binding.name) orelse
            @compileError("low_level_bindings にカタログ外の命令があります: " ++ binding.name);
        if (!std.mem.eql(u8, spec.name, binding.name)) {
            @compileError("low_level_bindings の名前はdispatch名（語幹）でなければなりません: " ++ binding.name);
        }
        if (@intFromEnum(binding.command) != @intFromEnum(Command.low_level_file_open) + index) {
            @compileError("low_level_bindings の順序はenum末尾の宣言順と一致させてください: " ++ binding.name);
        }
    }
    // 件数一致とあわせて逆方向も検証し、binding名の重複・カタログ命令の
    // 欠落を検出する。あわせて `catalogCommandFor` が先勝ち線形探索のため
    // dispatch名と利用者向け表記の解決名が全カタログで一意であることを検証する。
    for (low_level_foundation.catalog_commands) |spec| {
        var found = false;
        for (low_level_bindings) |binding| {
            if (std.mem.eql(u8, binding.name, spec.name)) found = true;
        }
        if (!found) {
            @compileError("low_level_bindings にカタログ命令がありません: " ++ spec.name);
        }
    }
    for (low_level_foundation.catalog_commands, 0..) |spec, index| {
        if (spec.user_name) |user_name| {
            if (std.mem.eql(u8, spec.name, user_name)) {
                @compileError("user_nameはdispatch名と同じならnullにしてください: " ++ spec.name);
            }
        }
        for (low_level_foundation.catalog_commands[index + 1 ..]) |other| {
            if (std.mem.eql(u8, spec.name, other.name) or
                (other.user_name != null and std.mem.eql(u8, spec.name, other.user_name.?)) or
                (spec.user_name != null and std.mem.eql(u8, spec.user_name.?, other.name)) or
                (spec.user_name != null and other.user_name != null and std.mem.eql(u8, spec.user_name.?, other.user_name.?)))
            {
                @compileError("カタログの解決名が重複しています: " ++ spec.name);
            }
        }
    }
    // dispatch名が標準cnako命令名や `lookup`/Interpreter早期dispatchより
    // 先に解決される名前と衝突すると、当該低レイヤー命令が到達不能になる。
    // `テスト実行`/`テスト等` は `default_names` にも含まれるが、早期
    // dispatch名としても検査対象へ残す（defense in depth）。
    // `builtin_catalog` に載らない早期dispatch名（`interpreter/plugins.zig`
    // の `callBuiltinImpl` 冒頭の文字列比較）を追加した場合はこのリストも
    // 更新しないと衝突を見逃す。
    const earlier_names = [_][]const u8{ "表示する", "ASSERT", "確認", "テスト実行", "テスト等" };
    for (low_level_bindings) |binding| {
        const spec = low_level_foundation.catalogCommandFor(binding.name).?;
        for ([2][]const u8{ binding.name, spec.user_name orelse binding.name }) |resolved| {
            for (builtin_catalog.names) |standard_name| {
                if (std.mem.eql(u8, resolved, standard_name)) {
                    @compileError("低レイヤー命令の解決名が標準cnako命令と衝突しています: " ++ resolved);
                }
            }
            for (builtin_catalog.default_names) |standard_name| {
                if (std.mem.eql(u8, resolved, standard_name)) {
                    @compileError("低レイヤー命令の解決名が既定plugin名と衝突しています: " ++ resolved);
                }
            }
            for (earlier_names) |earlier| {
                if (std.mem.eql(u8, resolved, earlier)) {
                    @compileError("低レイヤー命令の解決名が早期dispatch名と衝突しています: " ++ resolved);
                }
            }
        }
    }
    const fields = std.meta.fields(Command);
    var low_level_count: usize = 0;
    for (fields) |field| {
        const low_level = std.mem.startsWith(u8, field.name, "low_level_");
        const in_tail = field.value >= @intFromEnum(Command.low_level_file_open);
        if (low_level != in_tail) {
            @compileError("低レイヤーopcodeはenum末尾へ連続配置してください: " ++ field.name);
        }
        if (low_level) low_level_count += 1;
    }
    if (low_level_count != low_level_bindings.len) {
        @compileError("enum末尾の低レイヤーopcode数と low_level_bindings の件数が一致しません");
    }
}

/// opcodeが低レイヤー命令かどうか。enum末尾への連続配置で判定する。
pub fn isLowLevelCommand(command: Command) bool {
    return @intFromEnum(command) >= @intFromEnum(Command.low_level_file_open);
}

/// opcodeに対応するカタログ定義。ENOTSUP stubが `capability` /
/// `operation` / arity をここから引く。
pub fn lowLevelCatalogCommand(command: Command) ?low_level_foundation.CatalogCommand {
    if (!isLowLevelCommand(command)) return null;
    const index = @intFromEnum(command) - @intFromEnum(Command.low_level_file_open);
    if (index >= low_level_bindings.len) return null;
    return low_level_foundation.catalogCommandFor(low_level_bindings[index].name);
}

/// The LLVM ABI receives an opcode after aliases have already been lowered.
/// Trace consumers must therefore treat this as the canonical enum spelling,
/// not as the source spelling used by a Nadesiko program.
pub fn canonicalOpcodeName(command: Command) []const u8 {
    return @tagName(command);
}

/// The old-format official `plugin_datetime` module contains only this
/// subset of the datetime names.  The other datetime opcodes are provided by
/// the system plugin and must not be attributed to the duplicate catalog
/// entries in `plugin_datetime`.
fn isDatetimePluginCommand(command: Command) bool {
    return switch (command) {
        .datetime_now,
        .datetime_system_time,
        .datetime_today,
        .datetime_tomorrow,
        .datetime_yesterday,
        .datetime_current_year,
        .datetime_next_year,
        .datetime_last_year,
        .datetime_current_month,
        .datetime_next_month,
        .datetime_previous_month,
        .datetime_weekday,
        .datetime_weekday_number,
        .datetime_unix_time,
        .datetime_date_time,
        .datetime_era,
        .datetime_year_difference,
        .datetime_month_difference,
        .datetime_day_difference,
        .datetime_hour_difference,
        .datetime_minute_difference,
        .datetime_second_difference,
        .datetime_difference,
        .datetime_add_time,
        .datetime_add_date,
        .datetime_add_datetime,
        => true,
        else => false,
    };
}

pub fn dispatchRouteFor(command: Command, datetime_plugin_route: bool) []const u8 {
    if (datetime_plugin_route and isDatetimePluginCommand(command)) return "plugin_datetime";
    if (isLowLevelCommand(command)) return "plugin_lowlevel";
    return switch (command) {
        .cut, .cut_range => "cut",
        .regexp_match, .regexp_extract, .regexp_replace, .regexp_split => "regexp",
        .timer_after, .timer_every, .timer_stop, .timer_stop_all => "timer",
        .promise_create, .promise_success, .promise_settled, .promise_failure, .promise_finally, .promise_all => "promise",
        .node_file_open, .node_file_read, .node_file_binary_read, .node_file_save => "node-file-io",
        .node_file_sjis_read, .node_file_sjis_save, .node_file_euc_read, .node_file_euc_save => "node-file-encoding",
        .node_encoding_sjis_encode, .node_encoding_sjis_decode, .node_encoding_encode, .node_encoding_decode => "node-encoding",
        .node_file_list, .node_file_list_all, .node_folder_create, .node_file_copy, .node_file_copy_overwrite, .node_file_move, .node_file_move_overwrite, .node_file_delete => "node-file-operation",
        .system_debug_display => "debug-display",
        .system_hatena_execute => "hatena-default",
        .system_nadesiko, .system_nadesiko_continue => "dynamic-execute",
        .system_hatena_configure => "hatena-configure",
        .node_interrupt_callback => "node-interrupt",
        .system_end => "system-debug",
        .system_path_basename, .system_path_dirname => "system-path",
        .http_server_start, .http_server_static, .http_server_receive, .http_server_output, .http_server_headers, .http_server_redirect => "http-server",
        .system_debug_breakpoint_wait => "debug-breakpoint-wait",
        .node_stdin_line, .node_stdin_character, .node_stdin_callback => "node-stdin-lines",
        .node_archive_tool_path_set => "archive-tool-path",
        .node_archive_extract, .node_archive_extract_callback, .node_archive_create, .node_archive_create_callback => "node-archive",
        .node_process_run_wait, .node_process_run, .node_process_start, .node_process_run_wait_output, .node_process_start_callback, .node_open_external_browser, .node_open_external_explorer => "node-process",
        .node_file_process_callback, .node_file_process_stop, .node_file_copy_callback, .node_file_move_callback, .node_file_delete_callback => "node-file-callback",
        .node_ajax_options_set => "ajax-options",
        .node_ajax_onerror_set => "ajax-onerror",
        .node_ajax_send_callback, .node_ajax_receive_callback, .node_get_send_callback, .node_post_send_callback, .node_post_form_send_callback, .node_ajax_response_promise, .node_http_response_promise, .node_get_response_promise, .node_post_response_promise, .node_post_form_response_promise, .node_ajax_content_get, .node_ajax_receive, .node_post_send, .node_post_form_send, .node_ajax_text_get, .node_ajax_json_get, .node_ajax_binary_get, .node_discord_send, .node_discord_file_send => "node-http",
        else => "builtin",
    };
}

/// Returns the stable route name shared by the LLVM manifest and the AOT
/// runtime trace. Keeping this mapping next to the opcode enum prevents a
/// generic ABI call from being reported as `builtin` when the emitter has
/// assigned it to a specialized native route.
pub fn dispatchRoute(command: Command) []const u8 {
    return dispatchRouteFor(command, datetimePluginRouteEnabled());
}

pub fn lookup(name: []const u8) ?Command {
    if (routeSpecificCommand(name, systemRouteEnabled())) |command| return command;
    if (std.mem.eql(u8, name, "文字列変換") or std.mem.eql(u8, name, "TOSTR")) return .to_string;
    if (std.mem.eql(u8, name, "変数型確認") or std.mem.eql(u8, name, "TYPEOF")) return .type_of;
    if (std.mem.eql(u8, name, "整数変換") or std.mem.eql(u8, name, "TOINT") or std.mem.eql(u8, name, "INT")) return .to_int;
    if (std.mem.eql(u8, name, "実数変換") or std.mem.eql(u8, name, "TOFLOAT") or std.mem.eql(u8, name, "FLOAT")) return .to_float;
    if (std.mem.eql(u8, name, "NAN判定")) return .is_nan;
    if (std.mem.eql(u8, name, "非数判定")) return .is_number_nan;
    if (std.mem.eql(u8, name, "HEX")) return .radix16;
    if (std.mem.eql(u8, name, "進数変換")) return .radix;
    if (std.mem.eql(u8, name, "二進")) return .radix2;
    if (std.mem.eql(u8, name, "二進表示")) return .radix2_display;
    if (std.mem.eql(u8, name, "RGB")) return .rgb;
    if (std.mem.eql(u8, name, "OR")) return .bit_or;
    if (std.mem.eql(u8, name, "AND")) return .bit_and;
    if (std.mem.eql(u8, name, "XOR")) return .bit_xor;
    if (std.mem.eql(u8, name, "NOT")) return .bit_not;
    if (std.mem.eql(u8, name, "SHIFT_L")) return .shift_left;
    if (std.mem.eql(u8, name, "SHIFT_R")) return .shift_right;
    if (std.mem.eql(u8, name, "SHIFT_UR")) return .shift_right_unsigned;
    if (std.mem.eql(u8, name, "引")) return .subtract;
    if (std.mem.eql(u8, name, "倍")) return .multiply;
    if (std.mem.eql(u8, name, "割")) return .divide;
    if (std.mem.eql(u8, name, "割余")) return .remainder;
    if (std.mem.eql(u8, name, "偶数")) return .is_even;
    if (std.mem.eql(u8, name, "奇数")) return .is_odd;
    if (std.mem.eql(u8, name, "二乗")) return .square;
    if (std.mem.eql(u8, name, "べき乗")) return .power_number;
    if (std.mem.eql(u8, name, "以上")) return .greater_equal;
    if (std.mem.eql(u8, name, "以下")) return .less_equal;
    if (std.mem.eql(u8, name, "未満")) return .less;
    if (std.mem.eql(u8, name, "超")) return .greater;
    if (std.mem.eql(u8, name, "等")) return .strict_equal;
    if (std.mem.eql(u8, name, "等無")) return .strict_not_equal;
    if (std.mem.eql(u8, name, "範囲内")) return .in_range;
    if (std.mem.eql(u8, name, "MAX") or std.mem.eql(u8, name, "最大値")) return .maximum;
    if (std.mem.eql(u8, name, "MIN") or std.mem.eql(u8, name, "最小値")) return .minimum;
    if (std.mem.eql(u8, name, "CLAMP")) return .clamp;
    if (std.mem.eql(u8, name, "論理OR")) return .logical_or;
    if (std.mem.eql(u8, name, "論理AND")) return .logical_and;
    if (std.mem.eql(u8, name, "論理NOT")) return .logical_not;
    if (std.mem.eql(u8, name, "範囲")) return .range;
    if (std.mem.eql(u8, name, "空配列")) return .empty_array;
    if (std.mem.eql(u8, name, "空辞書") or std.mem.eql(u8, name, "空ハッシュ") or std.mem.eql(u8, name, "空オブジェクト")) return .empty_dictionary;
    if (std.mem.eql(u8, name, "辞書キー列挙")) return .dictionary_keys;
    if (std.mem.eql(u8, name, "辞書キー削除")) return .dictionary_remove;
    if (std.mem.eql(u8, name, "辞書キー存在")) return .dictionary_has;
    if (std.mem.eql(u8, name, "ハッシュキー列挙")) return .hash_keys;
    if (std.mem.eql(u8, name, "ハッシュ内容列挙")) return .hash_values;
    if (std.mem.eql(u8, name, "ハッシュキー削除")) return .hash_remove;
    if (std.mem.eql(u8, name, "ハッシュキー存在")) return .hash_has;
    if (std.mem.eql(u8, name, "真偽判定")) return .truth_label;
    if (std.mem.eql(u8, name, "掛")) return .repeat_multiply;
    if (std.mem.eql(u8, name, "文字数")) return .unicode_length;
    if (std.mem.eql(u8, name, "何文字目")) return .codepoint_find;
    if (std.mem.eql(u8, name, "文字始")) return .string_starts;
    if (std.mem.eql(u8, name, "文字終")) return .string_ends;
    if (std.mem.eql(u8, name, "配列要素数") or std.mem.eql(u8, name, "要素数") or std.mem.eql(u8, name, "LEN")) return .element_count;
    if (std.mem.eql(u8, name, "配列結合")) return .array_join;
    if (std.mem.eql(u8, name, "配列只結合")) return .array_join_only;
    if (std.mem.eql(u8, name, "配列検索")) return .array_search;
    if (std.mem.eql(u8, name, "配列ソート")) return .array_sort;
    if (std.mem.eql(u8, name, "配列数値変換")) return .array_numeric_convert;
    if (std.mem.eql(u8, name, "配列数値ソート")) return .array_numeric_sort;
    if (std.mem.eql(u8, name, "配列逆順")) return .array_reverse;
    if (std.mem.eql(u8, name, "配列挿入")) return .array_insert;
    if (std.mem.eql(u8, name, "配列一括挿入")) return .array_insert_many;
    if (std.mem.eql(u8, name, "配列削除") or std.mem.eql(u8, name, "配列切取")) return .array_cut;
    if (std.mem.eql(u8, name, "配列取出")) return .array_take;
    if (std.mem.eql(u8, name, "配列ポップ")) return .array_pop;
    if (std.mem.eql(u8, name, "配列プッシュ") or std.mem.eql(u8, name, "配列追加")) return .array_push;
    if (std.mem.eql(u8, name, "配列複製")) return .array_clone;
    if (std.mem.eql(u8, name, "配列範囲コピー")) return .array_range_copy;
    if (std.mem.eql(u8, name, "参照") or std.mem.eql(u8, name, "配列参照")) return .reference;
    if (std.mem.eql(u8, name, "配列足")) return .array_add;
    if (std.mem.eql(u8, name, "配列最大値")) return .array_maximum;
    if (std.mem.eql(u8, name, "配列最小値")) return .array_minimum;
    if (std.mem.eql(u8, name, "配列合計")) return .array_sum;
    if (std.mem.eql(u8, name, "配列入替")) return .array_swap;
    if (std.mem.eql(u8, name, "配列連番作成")) return .array_sequence;
    if (std.mem.eql(u8, name, "配列要素作成")) return .array_fill;
    if (std.mem.eql(u8, name, "表ソート")) return .table_sort;
    if (std.mem.eql(u8, name, "表数値ソート")) return .table_numeric_sort;
    if (std.mem.eql(u8, name, "表ピックアップ")) return .table_pickup;
    if (std.mem.eql(u8, name, "表完全一致ピックアップ")) return .table_exact_pickup;
    if (std.mem.eql(u8, name, "表検索")) return .table_search;
    if (std.mem.eql(u8, name, "表列数")) return .table_column_count;
    if (std.mem.eql(u8, name, "表行数")) return .table_row_count;
    if (std.mem.eql(u8, name, "表列取得")) return .table_column;
    if (std.mem.eql(u8, name, "表行列交換")) return .table_transpose;
    if (std.mem.eql(u8, name, "表右回転")) return .table_rotate;
    if (std.mem.eql(u8, name, "表重複削除")) return .table_unique;
    if (std.mem.eql(u8, name, "表列挿入")) return .table_insert_column;
    if (std.mem.eql(u8, name, "表列削除")) return .table_delete_column;
    if (std.mem.eql(u8, name, "表列合計")) return .table_column_sum;
    if (std.mem.eql(u8, name, "表曖昧検索")) return .table_regexp_search;
    if (std.mem.eql(u8, name, "表正規表現ピックアップ")) return .table_regexp_pickup;
    if (std.mem.eql(u8, name, "足")) return .add_parsed;
    if (std.mem.eql(u8, name, "合計")) return .sum_parsed;
    if (std.mem.eql(u8, name, "連続加算")) return .sequential_add;
    if (std.mem.eql(u8, name, "CHR")) return .chr;
    if (std.mem.eql(u8, name, "ASC")) return .asc;
    if (std.mem.eql(u8, name, "文字挿入")) return .string_insert;
    if (std.mem.eql(u8, name, "文字検索")) return .string_search;
    if (std.mem.eql(u8, name, "追加")) return .append;
    if (std.mem.eql(u8, name, "一行追加")) return .append_line;
    if (std.mem.eql(u8, name, "連結") or std.mem.eql(u8, name, "文字列連結")) return .concat_join;
    if (std.mem.eql(u8, name, "文字列分解")) return .explode;
    if (std.mem.eql(u8, name, "リフレイン")) return .refrain;
    if (std.mem.eql(u8, name, "出現回数")) return .occurrence_count;
    if (std.mem.eql(u8, name, "出現")) return .occurrence;
    if (std.mem.eql(u8, name, "切取")) return .cut;
    if (std.mem.eql(u8, name, "範囲切取")) return .cut_range;
    if (std.mem.eql(u8, name, "MID") or std.mem.eql(u8, name, "文字抜出")) return .substring_mid;
    if (std.mem.eql(u8, name, "LEFT") or std.mem.eql(u8, name, "文字左部分")) return .substring_left;
    if (std.mem.eql(u8, name, "RIGHT") or std.mem.eql(u8, name, "文字右部分")) return .substring_right;
    if (std.mem.eql(u8, name, "区切")) return .split_all;
    if (std.mem.eql(u8, name, "文字列分割")) return .split_first;
    if (std.mem.eql(u8, name, "文字削除")) return .string_remove;
    if (std.mem.eql(u8, name, "トリム") or std.mem.eql(u8, name, "空白除去")) return .trim_both;
    if (std.mem.eql(u8, name, "右トリム") or std.mem.eql(u8, name, "末尾空白除去")) return .trim_right;
    if (std.mem.eql(u8, name, "左トリム")) return .trim_left;
    if (std.mem.eql(u8, name, "置換")) return .replace_all;
    if (std.mem.eql(u8, name, "単置換")) return .replace_first;
    if (std.mem.eql(u8, name, "大文字変換")) return .uppercase;
    if (std.mem.eql(u8, name, "小文字変換")) return .lowercase;
    if (std.mem.eql(u8, name, "平仮名変換")) return .hiragana;
    if (std.mem.eql(u8, name, "カタカナ変換")) return .katakana;
    if (std.mem.eql(u8, name, "英数全角変換")) return .ascii_full_width;
    if (std.mem.eql(u8, name, "英数半角変換")) return .ascii_half_width;
    if (std.mem.eql(u8, name, "英数記号全角変換")) return .ascii_symbol_full_width;
    if (std.mem.eql(u8, name, "英数記号半角変換")) return .ascii_symbol_half_width;
    if (std.mem.eql(u8, name, "カタカナ全角変換")) return .katakana_full_width;
    if (std.mem.eql(u8, name, "カタカナ半角変換")) return .katakana_half_width;
    if (std.mem.eql(u8, name, "全角変換")) return .full_width;
    if (std.mem.eql(u8, name, "半角変換")) return .half_width;
    if (std.mem.eql(u8, name, "通貨形式")) return .currency_format;
    if (std.mem.eql(u8, name, "ゼロ埋")) return .zero_pad;
    if (std.mem.eql(u8, name, "空白埋")) return .space_pad;
    if (std.mem.eql(u8, name, "かなか判定")) return .hiragana_predicate;
    if (std.mem.eql(u8, name, "カタカナ判定")) return .katakana_predicate;
    if (std.mem.eql(u8, name, "数字判定")) return .digit_predicate;
    if (std.mem.eql(u8, name, "数列判定")) return .number_sequence_predicate;
    if (std.mem.eql(u8, name, "正規表現マッチ")) return .regexp_match;
    if (std.mem.eql(u8, name, "正規表現抽出")) return .regexp_extract;
    if (std.mem.eql(u8, name, "正規表現置換")) return .regexp_replace;
    if (std.mem.eql(u8, name, "正規表現区切")) return .regexp_split;
    if (std.mem.eql(u8, name, "JSON変換") or std.mem.eql(u8, name, "JSONエンコード") or std.mem.eql(u8, name, "JSON_E")) return .json_encode;
    if (std.mem.eql(u8, name, "JSONエンコード整形") or std.mem.eql(u8, name, "JSON_ES")) return .json_encode_pretty;
    if (std.mem.eql(u8, name, "JSON取得") or std.mem.eql(u8, name, "JSONデコード") or std.mem.eql(u8, name, "JSON_D")) return .json_decode;
    if (std.mem.eql(u8, name, "SIN")) return .math_sin;
    if (std.mem.eql(u8, name, "COS")) return .math_cos;
    if (std.mem.eql(u8, name, "TAN")) return .math_tan;
    if (std.mem.eql(u8, name, "ARCSIN")) return .math_arcsin;
    if (std.mem.eql(u8, name, "ARCCOS")) return .math_arccos;
    if (std.mem.eql(u8, name, "ARCTAN")) return .math_arctan;
    if (std.mem.eql(u8, name, "ATAN2")) return .math_atan2;
    if (std.mem.eql(u8, name, "座標角度計算")) return .math_coordinate_angle;
    if (std.mem.eql(u8, name, "RAD2DEG") or std.mem.eql(u8, name, "度変換")) return .math_rad2deg;
    if (std.mem.eql(u8, name, "DEG2RAD") or std.mem.eql(u8, name, "ラジアン変換")) return .math_deg2rad;
    if (std.mem.eql(u8, name, "SIGN") or std.mem.eql(u8, name, "符号")) return .math_sign;
    if (std.mem.eql(u8, name, "ABS") or std.mem.eql(u8, name, "絶対値")) return .math_abs;
    if (std.mem.eql(u8, name, "EXP")) return .math_exp;
    if (std.mem.eql(u8, name, "HYPOT") or std.mem.eql(u8, name, "斜辺")) return .math_hypot;
    if (std.mem.eql(u8, name, "LN") or std.mem.eql(u8, name, "LOG")) return .math_log;
    if (std.mem.eql(u8, name, "LOGN")) return .math_logn;
    if (std.mem.eql(u8, name, "FRAC") or std.mem.eql(u8, name, "小数部分")) return .math_frac;
    if (std.mem.eql(u8, name, "整数部分")) return .math_integer;
    if (std.mem.eql(u8, name, "SQRT") or std.mem.eql(u8, name, "平方根")) return .math_sqrt;
    if (std.mem.eql(u8, name, "ROUND") or std.mem.eql(u8, name, "四捨五入")) return .math_round;
    if (std.mem.eql(u8, name, "小数点切上")) return .math_decimal_ceil;
    if (std.mem.eql(u8, name, "小数点切下")) return .math_decimal_floor;
    if (std.mem.eql(u8, name, "小数点四捨五入")) return .math_decimal_round;
    if (std.mem.eql(u8, name, "CEIL") or std.mem.eql(u8, name, "切上")) return .math_ceil;
    if (std.mem.eql(u8, name, "FLOOR") or std.mem.eql(u8, name, "切捨")) return .math_floor;
    if (std.mem.eql(u8, name, "乱数")) return .math_random;
    if (std.mem.eql(u8, name, "乱数範囲")) return .math_random_range;
    if (std.mem.eql(u8, name, "今")) return .datetime_now;
    if (std.mem.eql(u8, name, "システム時間")) return .datetime_system_time;
    if (std.mem.eql(u8, name, "システム時間ミリ秒")) return .datetime_system_time_milliseconds;
    if (std.mem.eql(u8, name, "今日")) return .datetime_today;
    if (std.mem.eql(u8, name, "明日")) return .datetime_tomorrow;
    if (std.mem.eql(u8, name, "昨日")) return .datetime_yesterday;
    if (std.mem.eql(u8, name, "今年")) return .datetime_current_year;
    if (std.mem.eql(u8, name, "来年")) return .datetime_next_year;
    if (std.mem.eql(u8, name, "去年")) return .datetime_last_year;
    if (std.mem.eql(u8, name, "今月")) return .datetime_current_month;
    if (std.mem.eql(u8, name, "来月")) return .datetime_next_month;
    if (std.mem.eql(u8, name, "先月")) return .datetime_previous_month;
    if (std.mem.eql(u8, name, "対応ブラウザ一覧取得")) return .caniuse_browsers;
    if (std.mem.eql(u8, name, "曜日")) return .datetime_weekday;
    if (std.mem.eql(u8, name, "曜日番号取得")) return .datetime_weekday_number;
    if (std.mem.eql(u8, name, "UNIXTIME変換") or std.mem.eql(u8, name, "UNIX時間変換")) return .datetime_unix_time;
    if (std.mem.eql(u8, name, "日時変換")) return .datetime_date_time;
    if (std.mem.eql(u8, name, "URLエンコード")) return .url_encode;
    if (std.mem.eql(u8, name, "URLデコード")) return .url_decode;
    if (std.mem.eql(u8, name, "URLパラメータ解析")) return .url_parameters;
    if (std.mem.eql(u8, name, "BASE64エンコード")) return .base64_encode;
    if (std.mem.eql(u8, name, "BASE64デコード")) return .base64_decode;
    if (std.mem.eql(u8, name, "OS取得")) return .node_os;
    if (std.mem.eql(u8, name, "OSアーキテクチャ取得")) return .node_architecture;
    if (std.mem.eql(u8, name, "環境変数取得")) return .node_environment_get;
    if (std.mem.eql(u8, name, "環境変数一覧取得")) return .node_environment_list;
    if (std.mem.eql(u8, name, "カレントディレクトリ取得") or std.mem.eql(u8, name, "作業フォルダ取得")) return .node_current_directory;
    if (std.mem.eql(u8, name, "カレントディレクトリ変更") or std.mem.eql(u8, name, "作業フォルダ変更")) return .node_change_directory;
    if (std.mem.eql(u8, name, "絶対パス変換")) return .node_path_absolute;
    if (std.mem.eql(u8, name, "相対パス展開")) return .node_path_resolve;
    if (std.mem.eql(u8, name, "日時書式変換")) return .datetime_format;
    if (std.mem.eql(u8, name, "和暦変換")) return .datetime_era;
    if (std.mem.eql(u8, name, "年数差")) return .datetime_year_difference;
    if (std.mem.eql(u8, name, "月数差")) return .datetime_month_difference;
    if (std.mem.eql(u8, name, "日数差")) return .datetime_day_difference;
    if (std.mem.eql(u8, name, "時間差")) return .datetime_hour_difference;
    if (std.mem.eql(u8, name, "分差")) return .datetime_minute_difference;
    if (std.mem.eql(u8, name, "秒差")) return .datetime_second_difference;
    if (std.mem.eql(u8, name, "日時差")) return .datetime_difference;
    if (std.mem.eql(u8, name, "時間加算")) return .datetime_add_time;
    if (std.mem.eql(u8, name, "日付加算")) return .datetime_add_date;
    if (std.mem.eql(u8, name, "日時加算")) return .datetime_add_datetime;
    if (std.mem.eql(u8, name, "時間ミリ秒取得")) return .datetime_monotonic_milliseconds;
    if (std.mem.eql(u8, name, "拡張子抽出")) return .path_extract_extension;
    if (std.mem.eql(u8, name, "拡張子変更")) return .path_change_extension;
    if (std.mem.eql(u8, name, "終端パス追加")) return .path_add_trailing_separator;
    if (std.mem.eql(u8, name, "終端パス除去")) return .path_remove_trailing_separator;
    if (std.mem.eql(u8, name, "終端パス削除")) return .path_delete_trailing_separator;
    if (std.mem.eql(u8, name, "漢数字")) return .kansuji_to_kanji;
    if (std.mem.eql(u8, name, "算用数字")) return .kansuji_to_arabic;
    if (std.mem.eql(u8, name, "CSV取得")) return .csv_parse;
    if (std.mem.eql(u8, name, "TSV取得")) return .tsv_parse;
    if (std.mem.eql(u8, name, "表CSV変換")) return .table_csv_stringify;
    if (std.mem.eql(u8, name, "CSV変換")) return .csv_stringify;
    if (std.mem.eql(u8, name, "表TSV変換")) return .table_tsv_stringify;
    if (std.mem.eql(u8, name, "TSV変換")) return .tsv_stringify;
    if (std.mem.eql(u8, name, "CSVオプション設定")) return .csv_options;
    if (std.mem.eql(u8, name, "TOML取得")) return .toml_parse;
    if (std.mem.eql(u8, name, "TOML変換")) return .toml_stringify;
    if (std.mem.eql(u8, name, "マークダウンHTML変換")) return .markdown_to_html;
    if (std.mem.eql(u8, name, "HTML整形")) return .html_pretty;
    if (std.mem.eql(u8, name, "一致")) return .deep_equal;
    if (std.mem.eql(u8, name, "不一致")) return .deep_not_equal;
    if (std.mem.eql(u8, name, "ください") or std.mem.eql(u8, name, "お願") or std.mem.eql(u8, name, "です")) return .courtesy_increment;
    if (std.mem.eql(u8, name, "拝啓")) return .courtesy_begin;
    if (std.mem.eql(u8, name, "敬具")) return .courtesy_end;
    if (std.mem.eql(u8, name, "礼節レベル取得")) return .courtesy_level;
    if (std.mem.eql(u8, name, "継続表示")) return .stdio_continue_display;
    if (std.mem.eql(u8, name, "連続無改行表示")) return .stdio_continue_display_many;
    if (std.mem.eql(u8, name, "表示ログクリア")) return .stdio_clear_log;
    if (std.mem.eql(u8, name, "言") or std.mem.eql(u8, name, "コンソール表示")) return .stdio_write_all;
    if (std.mem.eql(u8, name, "プラグイン名設定")) return .plugin_name_set;
    if (std.mem.eql(u8, name, "名前空間設定")) return .namespace_set;
    if (std.mem.eql(u8, name, "名前空間ポップ")) return .namespace_pop;
    if (std.mem.eql(u8, name, "秒待") or std.mem.eql(u8, name, "秒待機") or std.mem.eql(u8, name, "秒逐次待機")) return .timer_wait;
    if (std.mem.eql(u8, name, "秒後")) return .timer_after;
    if (std.mem.eql(u8, name, "秒毎") or std.mem.eql(u8, name, "秒タイマー開始時")) return .timer_every;
    if (std.mem.eql(u8, name, "タイマー停止")) return .timer_stop;
    if (std.mem.eql(u8, name, "全タイマー停止")) return .timer_stop_all;
    if (std.mem.eql(u8, name, "動時")) return .promise_create;
    if (std.mem.eql(u8, name, "成功時")) return .promise_success;
    if (std.mem.eql(u8, name, "処理時")) return .promise_settled;
    if (std.mem.eql(u8, name, "失敗時")) return .promise_failure;
    if (std.mem.eql(u8, name, "終了時")) return .promise_finally;
    if (std.mem.eql(u8, name, "束")) return .promise_all;
    if (std.mem.eql(u8, name, "ASYNC")) return .async_noop;
    if (std.mem.eql(u8, name, "AWAIT実行")) return .system_await_execute;
    if (std.mem.eql(u8, name, "実行")) return .system_execute;
    if (std.mem.eql(u8, name, "ナデシコ")) return .system_nadesiko;
    if (std.mem.eql(u8, name, "ナデシコ続")) return .system_nadesiko_continue;
    if (std.mem.eql(u8, name, "実行時間計測")) return .system_measure_time;
    if (std.mem.eql(u8, name, "デバッグ表示")) return .system_debug_display;
    if (std.mem.eql(u8, name, "ハテナ関数実行")) return .system_hatena_execute;
    if (std.mem.eql(u8, name, "__DEBUG")) return .system_debug_enable;
    if (std.mem.eql(u8, name, "__DEBUG_BP_WAIT")) return .system_debug_breakpoint_wait;
    if (std.mem.eql(u8, name, "尋")) return .node_stdin_line;
    if (std.mem.eql(u8, name, "文字尋")) return .node_stdin_character;
    if (std.mem.eql(u8, name, "標準入力取得時")) return .node_stdin_callback;
    if (std.mem.eql(u8, name, "ハテナ関数設定")) return .system_hatena_configure;
    if (std.mem.eql(u8, name, "強制終了時")) return .node_interrupt_callback;
    if (std.mem.eql(u8, name, "簡易HTTPサーバ起動時")) return .http_server_start;
    if (std.mem.eql(u8, name, "簡易HTTPサーバ静的パス指定")) return .http_server_static;
    if (std.mem.eql(u8, name, "簡易HTTPサーバ受信時")) return .http_server_receive;
    if (std.mem.eql(u8, name, "簡易HTTPサーバ出力")) return .http_server_output;
    if (std.mem.eql(u8, name, "簡易HTTPサーバヘッダ出力")) return .http_server_headers;
    if (std.mem.eql(u8, name, "簡易HTTPサーバ移動")) return .http_server_redirect;
    if (std.mem.eql(u8, name, "解凍")) return .node_archive_extract;
    if (std.mem.eql(u8, name, "解凍時")) return .node_archive_extract_callback;
    if (std.mem.eql(u8, name, "圧縮")) return .node_archive_create;
    if (std.mem.eql(u8, name, "圧縮時")) return .node_archive_create_callback;
    if (std.mem.eql(u8, name, "起動待機")) return .node_process_run_wait;
    if (std.mem.eql(u8, name, "起動")) return .node_process_start;
    if (std.mem.eql(u8, name, "コマンド実行")) return .node_process_run;
    if (std.mem.eql(u8, name, "コマンド実行待機")) return .node_process_run_wait_output;
    if (std.mem.eql(u8, name, "起動時")) return .node_process_start_callback;
    if (std.mem.eql(u8, name, "ブラウザ起動")) return .node_open_external_browser;
    if (std.mem.eql(u8, name, "エクスプローラー起動")) return .node_open_external_explorer;
    if (std.mem.eql(u8, name, "ファイル処理時")) return .node_file_process_callback;
    if (std.mem.eql(u8, name, "ファイル処理強制停止")) return .node_file_process_stop;
    if (std.mem.eql(u8, name, "ファイルコピー時")) return .node_file_copy_callback;
    if (std.mem.eql(u8, name, "ファイル移動時")) return .node_file_move_callback;
    if (std.mem.eql(u8, name, "ファイル削除時")) return .node_file_delete_callback;
    if (std.mem.eql(u8, name, "グローバル関数一覧取得")) return .system_global_function_names;
    if (std.mem.eql(u8, name, "システム関数一覧取得")) return .system_function_names;
    if (std.mem.eql(u8, name, "システム関数存在")) return .system_function_exists;
    if (std.mem.eql(u8, name, "プラグイン一覧取得") or std.mem.eql(u8, name, "モジュール一覧取得")) return .plugin_names;
    if (std.mem.eql(u8, name, "助詞一覧取得")) return .josi_names;
    if (std.mem.eql(u8, name, "予約語一覧取得")) return .reserved_words;
    if (std.mem.eql(u8, name, "ASSERT等") or std.mem.eql(u8, name, "テスト実行") or std.mem.eql(u8, name, "テスト等")) return .assert_strict_equal;
    if (std.mem.eql(u8, name, "配列シャッフル")) return .array_shuffle;
    if (std.mem.eql(u8, name, "配列カスタムソート")) return .array_custom_sort;
    if (std.mem.eql(u8, name, "配列関数適用")) return .array_function_apply;
    if (std.mem.eql(u8, name, "配列マップ")) return .array_map;
    if (std.mem.eql(u8, name, "配列フィルタ")) return .array_filter;
    if (std.mem.eql(u8, name, "LINE送信")) return .line_notify_discontinued;
    if (std.mem.eql(u8, name, "LINE画像送信")) return .line_image_notify_discontinued;
    if (std.mem.eql(u8, name, "プロセス終")) return .node_process_exit;
    if (std.mem.eql(u8, name, "存在")) return .node_file_exists;
    if (std.mem.eql(u8, name, "フォルダ存在")) return .node_folder_exists;
    if (std.mem.eql(u8, name, "ホームディレクトリ取得")) return .node_home_directory;
    if (std.mem.eql(u8, name, "デスクトップ")) return .node_desktop;
    if (std.mem.eql(u8, name, "マイドキュメント")) return .node_documents;
    if (std.mem.eql(u8, name, "テンポラリフォルダ")) return .node_temporary_directory;
    if (std.mem.eql(u8, name, "母艦パス取得")) return .node_mother_path;
    if (std.mem.eql(u8, name, "一時フォルダ作成")) return .node_temporary_directory_create;
    if (std.mem.eql(u8, name, "ハッシュ関数一覧取得")) return .node_hash_names;
    if (std.mem.eql(u8, name, "圧縮解凍ツールパス変更")) return .node_archive_tool_path_set;
    if (std.mem.eql(u8, name, "ファイルサイズ取得")) return .node_file_size;
    if (std.mem.eql(u8, name, "ファイル情報取得")) return .node_file_info;
    if (std.mem.eql(u8, name, "文字コード変換サポート判定")) return .node_encoding_supports;
    if (std.mem.eql(u8, name, "標準入力全取得")) return .node_stdin_all;
    if (std.mem.eql(u8, name, "POSTデータ生成")) return .node_post_data;
    if (std.mem.eql(u8, name, "AJAXオプション設定")) return .node_ajax_options_set;
    if (std.mem.eql(u8, name, "AJAX失敗時")) return .node_ajax_onerror_set;
    if (std.mem.eql(u8, name, "AJAX送信時")) return .node_ajax_send_callback;
    if (std.mem.eql(u8, name, "AJAX受信時")) return .node_ajax_receive_callback;
    if (std.mem.eql(u8, name, "GET送信時")) return .node_get_send_callback;
    if (std.mem.eql(u8, name, "POST送信時")) return .node_post_send_callback;
    if (std.mem.eql(u8, name, "POSTフォーム送信時")) return .node_post_form_send_callback;
    if (std.mem.eql(u8, name, "AJAX保障送信")) return .node_ajax_response_promise;
    if (std.mem.eql(u8, name, "HTTP保障取得")) return .node_http_response_promise;
    if (std.mem.eql(u8, name, "GET保障送信")) return .node_get_response_promise;
    if (std.mem.eql(u8, name, "POST保障送信")) return .node_post_response_promise;
    if (std.mem.eql(u8, name, "POSTフォーム保障送信")) return .node_post_form_response_promise;
    if (std.mem.eql(u8, name, "AJAX内容取得")) return .node_ajax_content_get;
    if (std.mem.eql(u8, name, "AJAX受信")) return .node_ajax_receive;
    if (std.mem.eql(u8, name, "POST送信")) return .node_post_send;
    if (std.mem.eql(u8, name, "POSTフォーム送信")) return .node_post_form_send;
    if (std.mem.eql(u8, name, "AJAXテキスト取得")) return .node_ajax_text_get;
    if (std.mem.eql(u8, name, "AJAX_JSON取得")) return .node_ajax_json_get;
    if (std.mem.eql(u8, name, "AJAXバイナリ取得")) return .node_ajax_binary_get;
    if (std.mem.eql(u8, name, "DISCORD送信")) return .node_discord_send;
    if (std.mem.eql(u8, name, "DISCORDファイル送信")) return .node_discord_file_send;
    if (std.mem.eql(u8, name, "自分IPアドレス取得")) return .node_network_ipv4;
    if (std.mem.eql(u8, name, "自分IPV6アドレス取得")) return .node_network_ipv6;
    if (std.mem.eql(u8, name, "ハッシュ値計算")) return .node_hash_value;
    if (std.mem.eql(u8, name, "ランダムUUID生成")) return .node_random_uuid;
    if (std.mem.eql(u8, name, "ランダム配列生成")) return .node_random_array;
    if (std.mem.eql(u8, name, "開")) return .node_file_open;
    if (std.mem.eql(u8, name, "読")) return .node_file_read;
    if (std.mem.eql(u8, name, "バイナリ読")) return .node_file_binary_read;
    if (std.mem.eql(u8, name, "保存")) return .node_file_save;
    if (std.mem.eql(u8, name, "SJISファイル読")) return .node_file_sjis_read;
    if (std.mem.eql(u8, name, "SJISファイル保存")) return .node_file_sjis_save;
    if (std.mem.eql(u8, name, "EUCファイル読")) return .node_file_euc_read;
    if (std.mem.eql(u8, name, "EUCファイル保存")) return .node_file_euc_save;
    if (std.mem.eql(u8, name, "SJIS変換")) return .node_encoding_sjis_encode;
    if (std.mem.eql(u8, name, "SJIS取得")) return .node_encoding_sjis_decode;
    if (std.mem.eql(u8, name, "エンコーディング変換")) return .node_encoding_encode;
    if (std.mem.eql(u8, name, "エンコーディング取得")) return .node_encoding_decode;
    if (std.mem.eql(u8, name, "ファイル列挙")) return .node_file_list;
    if (std.mem.eql(u8, name, "全ファイル列挙")) return .node_file_list_all;
    if (std.mem.eql(u8, name, "フォルダ作成")) return .node_folder_create;
    if (std.mem.eql(u8, name, "ファイルコピー")) return .node_file_copy;
    if (std.mem.eql(u8, name, "ファイル上書コピー")) return .node_file_copy_overwrite;
    if (std.mem.eql(u8, name, "ファイル移動")) return .node_file_move;
    if (std.mem.eql(u8, name, "ファイル上書移動")) return .node_file_move_overwrite;
    if (std.mem.eql(u8, name, "ファイル削除")) return .node_file_delete;
    if (std.mem.eql(u8, name, "コンソールクリア")) return .node_console_clear;
    // 低レイヤー命令はカタログ命令表（dispatch名と利用者向け表記の両方）で
    // 解決し、実装済みと未実装 ENOTSUP stub の区別なくopcodeを割り当てる。
    if (low_level_foundation.catalogCommandFor(name)) |spec| {
        for (low_level_bindings) |binding| {
            if (std.mem.eql(u8, binding.name, spec.name)) return binding.command;
        }
    }
    return null;
}

pub fn routeSpecificCommand(name: []const u8, system_route: bool) ?Command {
    if (std.mem.eql(u8, name, "ファイル名抽出")) return if (system_route) .system_path_basename else .node_path_basename;
    if (std.mem.eql(u8, name, "パス抽出")) return if (system_route) .system_path_dirname else .node_path_dirname;
    if (std.mem.eql(u8, name, "終")) return if (system_route) .system_end else .node_exit;
    if (std.mem.eql(u8, name, "終了")) return .node_exit;
    return null;
}

fn systemRouteEnabled() bool {
    return environment.valueEquals("LNAKO_PLUGIN_ROUTE", "plugin_system");
}

fn datetimePluginRouteEnabled() bool {
    return environment.valueEquals("LNAKO_PLUGIN_ROUTE", "plugin_datetime");
}

test {
    _ = @import("aot_builtin_test.zig");
}
