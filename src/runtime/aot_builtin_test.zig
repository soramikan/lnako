const std = @import("std");
const aot_builtin = @import("aot_builtin.zig");
const low_level_foundation = @import("low_level_foundation.zig");

const Command = aot_builtin.Command;
const low_level_bindings = aot_builtin.low_level_bindings;
const lookup = aot_builtin.lookup;
const dispatchRouteFor = aot_builtin.dispatchRouteFor;
const routeSpecificCommand = aot_builtin.routeSpecificCommand;
const canonicalOpcodeName = aot_builtin.canonicalOpcodeName;
const isLowLevelCommand = aot_builtin.isLowLevelCommand;
const lowLevelCatalogCommand = aot_builtin.lowLevelCatalogCommand;

test "plugin_datetime routeは旧形式pluginの27命令だけを識別する" {
    const datetime_commands = [_]Command{
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
    };
    for (datetime_commands) |command| try std.testing.expectEqualStrings("plugin_datetime", dispatchRouteFor(command, true));
    try std.testing.expectEqualStrings("builtin", dispatchRouteFor(.datetime_now, false));
    try std.testing.expectEqualStrings("builtin", dispatchRouteFor(.datetime_system_time_milliseconds, true));
    try std.testing.expectEqualStrings("builtin", dispatchRouteFor(.datetime_format, true));
    try std.testing.expectEqualStrings("builtin", dispatchRouteFor(.datetime_monotonic_milliseconds, true));
}

test "低レイヤー命令はplugin_lowlevelへdispatchする" {
    for (std.meta.tags(Command)) |command| {
        if (isLowLevelCommand(command)) {
            try std.testing.expectEqualStrings("plugin_lowlevel", dispatchRouteFor(command, false));
        }
    }
}

test "カタログの低レイヤー命令はdispatch名と利用者向け表記の両方でlookupできる" {
    try std.testing.expectEqual(@as(usize, 61), low_level_bindings.len);
    for (low_level_bindings) |binding| {
        try std.testing.expectEqual(binding.command, lookup(binding.name).?);
        const spec = low_level_foundation.catalogCommandFor(binding.name).?;
        if (spec.user_name) |user_name| {
            try std.testing.expectEqual(binding.command, lookup(user_name).?);
        }
        const resolved = lowLevelCatalogCommand(binding.command).?;
        try std.testing.expectEqualStrings(spec.id, resolved.id);
        try std.testing.expectEqualStrings(spec.name, resolved.name);
    }
}

test "同名pathと終命令はrouteごとのAOT opcodeへ分離する" {
    try std.testing.expectEqual(Command.node_path_basename, routeSpecificCommand("ファイル名抽出", false).?);
    try std.testing.expectEqual(Command.node_path_dirname, routeSpecificCommand("パス抽出", false).?);
    try std.testing.expectEqual(Command.node_exit, routeSpecificCommand("終", false).?);
    try std.testing.expectEqual(Command.system_path_basename, routeSpecificCommand("ファイル名抽出", true).?);
    try std.testing.expectEqual(Command.system_path_dirname, routeSpecificCommand("パス抽出", true).?);
    try std.testing.expectEqual(Command.system_end, routeSpecificCommand("終", true).?);
    try std.testing.expectEqual(Command.node_exit, routeSpecificCommand("終了", true).?);
}

test "AOT標準命令の正式名と別名を同じIDへ解決する" {
    try std.testing.expectEqual(Command.to_string, lookup("文字列変換").?);
    try std.testing.expectEqual(Command.to_string, lookup("TOSTR").?);
    try std.testing.expectEqual(Command.type_of, lookup("変数型確認").?);
    try std.testing.expectEqual(Command.type_of, lookup("TYPEOF").?);
    try std.testing.expectEqual(Command.to_int, lookup("整数変換").?);
    try std.testing.expectEqual(Command.to_int, lookup("TOINT").?);
    try std.testing.expectEqual(Command.to_int, lookup("INT").?);
    try std.testing.expectEqual(Command.to_float, lookup("実数変換").?);
    try std.testing.expectEqual(Command.to_float, lookup("TOFLOAT").?);
    try std.testing.expectEqual(Command.to_float, lookup("FLOAT").?);
    try std.testing.expectEqual(Command.cut, lookup("切取").?);
    try std.testing.expectEqual(Command.cut_range, lookup("範囲切取").?);
    try std.testing.expectEqual(Command.is_nan, lookup("NAN判定").?);
    try std.testing.expectEqual(Command.is_number_nan, lookup("非数判定").?);
    try std.testing.expectEqual(Command.array_maximum, lookup("配列最大値").?);
    try std.testing.expectEqual(Command.array_minimum, lookup("配列最小値").?);
    try std.testing.expectEqual(Command.array_sum, lookup("配列合計").?);
    try std.testing.expectEqual(Command.array_swap, lookup("配列入替").?);
    try std.testing.expectEqual(Command.array_sequence, lookup("配列連番作成").?);
    try std.testing.expectEqual(Command.array_fill, lookup("配列要素作成").?);
    try std.testing.expectEqual(Command.table_sort, lookup("表ソート").?);
    try std.testing.expectEqual(Command.table_numeric_sort, lookup("表数値ソート").?);
    try std.testing.expectEqual(Command.radix16, lookup("HEX").?);
    try std.testing.expectEqual(Command.radix, lookup("進数変換").?);
    try std.testing.expectEqual(Command.radix2, lookup("二進").?);
    try std.testing.expectEqual(Command.radix2_display, lookup("二進表示").?);
    try std.testing.expectEqual(Command.json_decode, lookup("JSON取得").?);
    try std.testing.expectEqual(Command.json_decode, lookup("JSONデコード").?);
    try std.testing.expectEqual(Command.json_decode, lookup("JSON_D").?);
    try std.testing.expectEqual(Command.system_measure_time, lookup("実行時間計測").?);
    try std.testing.expectEqual(Command.math_sin, lookup("SIN").?);
    try std.testing.expectEqual(Command.math_rad2deg, lookup("度変換").?);
    try std.testing.expectEqual(Command.math_rad2deg, lookup("RAD2DEG").?);
    try std.testing.expectEqual(Command.math_sign, lookup("符号").?);
    try std.testing.expectEqual(Command.math_sign, lookup("SIGN").?);
    try std.testing.expectEqual(Command.math_floor, lookup("切捨").?);
    try std.testing.expectEqual(Command.math_floor, lookup("FLOOR").?);
    try std.testing.expectEqual(Command.rgb, lookup("RGB").?);
    try std.testing.expectEqual(Command.bit_or, lookup("OR").?);
    try std.testing.expectEqual(Command.bit_and, lookup("AND").?);
    try std.testing.expectEqual(Command.bit_xor, lookup("XOR").?);
    try std.testing.expectEqual(Command.bit_not, lookup("NOT").?);
    try std.testing.expectEqual(Command.shift_left, lookup("SHIFT_L").?);
    try std.testing.expectEqual(Command.shift_right, lookup("SHIFT_R").?);
    try std.testing.expectEqual(Command.shift_right_unsigned, lookup("SHIFT_UR").?);
    try std.testing.expectEqual(Command.subtract, lookup("引").?);
    try std.testing.expectEqual(Command.multiply, lookup("倍").?);
    try std.testing.expectEqual(Command.divide, lookup("割").?);
    try std.testing.expectEqual(Command.remainder, lookup("割余").?);
    try std.testing.expectEqual(Command.is_even, lookup("偶数").?);
    try std.testing.expectEqual(Command.is_odd, lookup("奇数").?);
    try std.testing.expectEqual(Command.square, lookup("二乗").?);
    try std.testing.expectEqual(Command.power_number, lookup("べき乗").?);
    try std.testing.expectEqual(Command.greater_equal, lookup("以上").?);
    try std.testing.expectEqual(Command.less_equal, lookup("以下").?);
    try std.testing.expectEqual(Command.less, lookup("未満").?);
    try std.testing.expectEqual(Command.greater, lookup("超").?);
    try std.testing.expectEqual(Command.strict_equal, lookup("等").?);
    try std.testing.expectEqual(Command.strict_not_equal, lookup("等無").?);
    try std.testing.expectEqual(Command.in_range, lookup("範囲内").?);
    try std.testing.expectEqual(Command.maximum, lookup("MAX").?);
    try std.testing.expectEqual(Command.maximum, lookup("最大値").?);
    try std.testing.expectEqual(Command.minimum, lookup("MIN").?);
    try std.testing.expectEqual(Command.minimum, lookup("最小値").?);
    try std.testing.expectEqual(Command.clamp, lookup("CLAMP").?);
    try std.testing.expectEqual(Command.logical_or, lookup("論理OR").?);
    try std.testing.expectEqual(Command.logical_and, lookup("論理AND").?);
    try std.testing.expectEqual(Command.logical_not, lookup("論理NOT").?);
    try std.testing.expectEqual(Command.range, lookup("範囲").?);
    try std.testing.expectEqual(Command.empty_array, lookup("空配列").?);
    try std.testing.expectEqual(Command.empty_dictionary, lookup("空辞書").?);
    try std.testing.expectEqual(Command.empty_dictionary, lookup("空ハッシュ").?);
    try std.testing.expectEqual(Command.empty_dictionary, lookup("空オブジェクト").?);
    try std.testing.expectEqual(Command.dictionary_keys, lookup("辞書キー列挙").?);
    try std.testing.expectEqual(Command.dictionary_remove, lookup("辞書キー削除").?);
    try std.testing.expectEqual(Command.dictionary_has, lookup("辞書キー存在").?);
    try std.testing.expectEqual(Command.hash_keys, lookup("ハッシュキー列挙").?);
    try std.testing.expectEqual(Command.hash_values, lookup("ハッシュ内容列挙").?);
    try std.testing.expectEqual(Command.hash_remove, lookup("ハッシュキー削除").?);
    try std.testing.expectEqual(Command.hash_has, lookup("ハッシュキー存在").?);
    try std.testing.expectEqual(Command.truth_label, lookup("真偽判定").?);
    try std.testing.expectEqual(Command.repeat_multiply, lookup("掛").?);
    try std.testing.expectEqual(Command.unicode_length, lookup("文字数").?);
    try std.testing.expectEqual(Command.codepoint_find, lookup("何文字目").?);
    try std.testing.expectEqual(Command.string_starts, lookup("文字始").?);
    try std.testing.expectEqual(Command.string_ends, lookup("文字終").?);
    try std.testing.expectEqual(Command.element_count, lookup("配列要素数").?);
    try std.testing.expectEqual(Command.element_count, lookup("要素数").?);
    try std.testing.expectEqual(Command.element_count, lookup("LEN").?);
    try std.testing.expectEqual(Command.array_join, lookup("配列結合").?);
    try std.testing.expectEqual(Command.array_join_only, lookup("配列只結合").?);
    try std.testing.expectEqual(Command.array_search, lookup("配列検索").?);
    try std.testing.expectEqual(Command.array_sort, lookup("配列ソート").?);
    try std.testing.expectEqual(Command.array_numeric_convert, lookup("配列数値変換").?);
    try std.testing.expectEqual(Command.array_numeric_sort, lookup("配列数値ソート").?);
    try std.testing.expectEqual(Command.array_reverse, lookup("配列逆順").?);
    try std.testing.expectEqual(Command.array_insert, lookup("配列挿入").?);
    try std.testing.expectEqual(Command.array_insert_many, lookup("配列一括挿入").?);
    try std.testing.expectEqual(Command.array_cut, lookup("配列削除").?);
    try std.testing.expectEqual(Command.array_cut, lookup("配列切取").?);
    try std.testing.expectEqual(Command.array_take, lookup("配列取出").?);
    try std.testing.expectEqual(Command.array_pop, lookup("配列ポップ").?);
    try std.testing.expectEqual(Command.array_push, lookup("配列プッシュ").?);
    try std.testing.expectEqual(Command.array_push, lookup("配列追加").?);
    try std.testing.expectEqual(Command.array_clone, lookup("配列複製").?);
    try std.testing.expectEqual(Command.array_range_copy, lookup("配列範囲コピー").?);
    try std.testing.expectEqual(Command.reference, lookup("参照").?);
    try std.testing.expectEqual(Command.reference, lookup("配列参照").?);
    try std.testing.expectEqual(Command.array_add, lookup("配列足").?);
    try std.testing.expectEqual(Command.add_parsed, lookup("足").?);
    try std.testing.expectEqual(Command.sum_parsed, lookup("合計").?);
    try std.testing.expectEqual(Command.sequential_add, lookup("連続加算").?);
    try std.testing.expectEqual(Command.chr, lookup("CHR").?);
    try std.testing.expectEqual(Command.asc, lookup("ASC").?);
    try std.testing.expectEqual(Command.string_insert, lookup("文字挿入").?);
    try std.testing.expectEqual(Command.string_search, lookup("文字検索").?);
    try std.testing.expectEqual(Command.append, lookup("追加").?);
    try std.testing.expectEqual(Command.append_line, lookup("一行追加").?);
    try std.testing.expectEqual(Command.concat_join, lookup("連結").?);
    try std.testing.expectEqual(Command.concat_join, lookup("文字列連結").?);
    try std.testing.expectEqual(Command.explode, lookup("文字列分解").?);
    try std.testing.expectEqual(Command.refrain, lookup("リフレイン").?);
    try std.testing.expectEqual(Command.occurrence_count, lookup("出現回数").?);
    try std.testing.expectEqual(Command.occurrence, lookup("出現").?);
    try std.testing.expectEqual(Command.substring_mid, lookup("MID").?);
    try std.testing.expectEqual(Command.substring_mid, lookup("文字抜出").?);
    try std.testing.expectEqual(Command.substring_left, lookup("LEFT").?);
    try std.testing.expectEqual(Command.substring_left, lookup("文字左部分").?);
    try std.testing.expectEqual(Command.substring_right, lookup("RIGHT").?);
    try std.testing.expectEqual(Command.substring_right, lookup("文字右部分").?);
    try std.testing.expectEqual(Command.split_all, lookup("区切").?);
    try std.testing.expectEqual(Command.split_first, lookup("文字列分割").?);
    try std.testing.expectEqual(Command.string_remove, lookup("文字削除").?);
    try std.testing.expectEqual(Command.trim_both, lookup("トリム").?);
    try std.testing.expectEqual(Command.trim_both, lookup("空白除去").?);
    try std.testing.expectEqual(Command.trim_right, lookup("右トリム").?);
    try std.testing.expectEqual(Command.trim_right, lookup("末尾空白除去").?);
    try std.testing.expectEqual(Command.trim_left, lookup("左トリム").?);
    try std.testing.expectEqual(Command.replace_all, lookup("置換").?);
    try std.testing.expectEqual(Command.replace_first, lookup("単置換").?);
    try std.testing.expectEqual(Command.regexp_match, lookup("正規表現マッチ").?);
    try std.testing.expectEqual(Command.regexp_extract, lookup("正規表現抽出").?);
    try std.testing.expectEqual(Command.regexp_replace, lookup("正規表現置換").?);
    try std.testing.expectEqual(Command.regexp_split, lookup("正規表現区切").?);
    try std.testing.expectEqual(Command.json_encode, lookup("JSON変換").?);
    try std.testing.expectEqual(Command.json_encode, lookup("JSONエンコード").?);
    try std.testing.expectEqual(Command.json_encode, lookup("JSON_E").?);
    try std.testing.expectEqual(Command.json_encode_pretty, lookup("JSONエンコード整形").?);
    try std.testing.expectEqual(Command.json_encode_pretty, lookup("JSON_ES").?);
    try std.testing.expectEqual(Command.uppercase, lookup("大文字変換").?);
    try std.testing.expectEqual(Command.lowercase, lookup("小文字変換").?);
    try std.testing.expectEqual(Command.hiragana, lookup("平仮名変換").?);
    try std.testing.expectEqual(Command.katakana, lookup("カタカナ変換").?);
    try std.testing.expectEqual(Command.ascii_full_width, lookup("英数全角変換").?);
    try std.testing.expectEqual(Command.ascii_half_width, lookup("英数半角変換").?);
    try std.testing.expectEqual(Command.ascii_symbol_full_width, lookup("英数記号全角変換").?);
    try std.testing.expectEqual(Command.ascii_symbol_half_width, lookup("英数記号半角変換").?);
    try std.testing.expectEqual(Command.katakana_full_width, lookup("カタカナ全角変換").?);
    try std.testing.expectEqual(Command.katakana_half_width, lookup("カタカナ半角変換").?);
    try std.testing.expectEqual(Command.full_width, lookup("全角変換").?);
    try std.testing.expectEqual(Command.half_width, lookup("半角変換").?);
    try std.testing.expectEqual(Command.currency_format, lookup("通貨形式").?);
    try std.testing.expectEqual(Command.zero_pad, lookup("ゼロ埋").?);
    try std.testing.expectEqual(Command.space_pad, lookup("空白埋").?);
    try std.testing.expectEqual(Command.hiragana_predicate, lookup("かなか判定").?);
    try std.testing.expectEqual(Command.katakana_predicate, lookup("カタカナ判定").?);
    try std.testing.expectEqual(Command.digit_predicate, lookup("数字判定").?);
    try std.testing.expectEqual(Command.number_sequence_predicate, lookup("数列判定").?);
    try std.testing.expectEqual(Command.math_random, lookup("乱数").?);
    try std.testing.expectEqual(Command.math_random_range, lookup("乱数範囲").?);
    try std.testing.expectEqual(Command.plugin_name_set, lookup("プラグイン名設定").?);
    try std.testing.expectEqual(Command.namespace_set, lookup("名前空間設定").?);
    try std.testing.expectEqual(Command.namespace_pop, lookup("名前空間ポップ").?);
    try std.testing.expectEqual(Command.timer_wait, lookup("秒待").?);
    try std.testing.expectEqual(Command.timer_wait, lookup("秒待機").?);
    try std.testing.expectEqual(Command.timer_wait, lookup("秒逐次待機").?);
    try std.testing.expectEqual(Command.timer_after, lookup("秒後").?);
    try std.testing.expectEqual(Command.timer_every, lookup("秒毎").?);
    try std.testing.expectEqual(Command.timer_every, lookup("秒タイマー開始時").?);
    try std.testing.expectEqual(Command.timer_stop, lookup("タイマー停止").?);
    try std.testing.expectEqual(Command.timer_stop_all, lookup("全タイマー停止").?);
    try std.testing.expectEqual(Command.promise_create, lookup("動時").?);
    try std.testing.expectEqual(Command.promise_success, lookup("成功時").?);
    try std.testing.expectEqual(Command.promise_settled, lookup("処理時").?);
    try std.testing.expectEqual(Command.promise_failure, lookup("失敗時").?);
    try std.testing.expectEqual(Command.promise_finally, lookup("終了時").?);
    try std.testing.expectEqual(Command.promise_all, lookup("束").?);
    try std.testing.expectEqual(Command.node_file_open, lookup("開").?);
    try std.testing.expectEqual(Command.node_file_read, lookup("読").?);
    try std.testing.expectEqual(Command.node_file_binary_read, lookup("バイナリ読").?);
    try std.testing.expectEqual(Command.node_file_save, lookup("保存").?);
    try std.testing.expectEqual(Command.node_file_sjis_read, lookup("SJISファイル読").?);
    try std.testing.expectEqual(Command.node_file_sjis_save, lookup("SJISファイル保存").?);
    try std.testing.expectEqual(Command.node_file_euc_read, lookup("EUCファイル読").?);
    try std.testing.expectEqual(Command.node_file_euc_save, lookup("EUCファイル保存").?);
    try std.testing.expectEqual(Command.node_encoding_sjis_encode, lookup("SJIS変換").?);
    try std.testing.expectEqual(Command.node_encoding_sjis_decode, lookup("SJIS取得").?);
    try std.testing.expectEqual(Command.node_encoding_encode, lookup("エンコーディング変換").?);
    try std.testing.expectEqual(Command.node_encoding_decode, lookup("エンコーディング取得").?);
    try std.testing.expectEqual(Command.node_file_list, lookup("ファイル列挙").?);
    try std.testing.expectEqual(Command.node_file_list_all, lookup("全ファイル列挙").?);
    try std.testing.expectEqual(Command.node_folder_create, lookup("フォルダ作成").?);
    try std.testing.expectEqual(Command.node_file_copy, lookup("ファイルコピー").?);
    try std.testing.expectEqual(Command.node_file_copy_overwrite, lookup("ファイル上書コピー").?);
    try std.testing.expectEqual(Command.node_file_move, lookup("ファイル移動").?);
    try std.testing.expectEqual(Command.node_file_move_overwrite, lookup("ファイル上書移動").?);
    try std.testing.expectEqual(Command.node_file_delete, lookup("ファイル削除").?);
    try std.testing.expectEqual(Command.node_console_clear, lookup("コンソールクリア").?);
    try std.testing.expectEqual(Command.async_noop, lookup("ASYNC").?);
    try std.testing.expectEqual(Command.system_await_execute, lookup("AWAIT実行").?);
    try std.testing.expectEqual(Command.system_execute, lookup("実行").?);
    try std.testing.expectEqual(Command.system_nadesiko, lookup("ナデシコ").?);
    try std.testing.expectEqual(Command.system_nadesiko_continue, lookup("ナデシコ続").?);
    try std.testing.expectEqual(Command.system_debug_display, lookup("デバッグ表示").?);
    try std.testing.expectEqual(Command.system_hatena_execute, lookup("ハテナ関数実行").?);
    try std.testing.expectEqual(Command.system_debug_enable, lookup("__DEBUG").?);
    try std.testing.expectEqual(Command.system_debug_breakpoint_wait, lookup("__DEBUG_BP_WAIT").?);
    try std.testing.expectEqual(Command.node_stdin_line, lookup("尋").?);
    try std.testing.expectEqual(Command.node_stdin_character, lookup("文字尋").?);
    try std.testing.expectEqual(Command.node_stdin_callback, lookup("標準入力取得時").?);
    try std.testing.expectEqual(Command.system_hatena_configure, lookup("ハテナ関数設定").?);
    try std.testing.expectEqual(Command.node_interrupt_callback, lookup("強制終了時").?);
    try std.testing.expectEqual(Command.http_server_start, lookup("簡易HTTPサーバ起動時").?);
    try std.testing.expectEqual(Command.http_server_static, lookup("簡易HTTPサーバ静的パス指定").?);
    try std.testing.expectEqual(Command.http_server_receive, lookup("簡易HTTPサーバ受信時").?);
    try std.testing.expectEqual(Command.http_server_output, lookup("簡易HTTPサーバ出力").?);
    try std.testing.expectEqual(Command.http_server_headers, lookup("簡易HTTPサーバヘッダ出力").?);
    try std.testing.expectEqual(Command.http_server_redirect, lookup("簡易HTTPサーバ移動").?);
    try std.testing.expectEqual(Command.system_global_function_names, lookup("グローバル関数一覧取得").?);
    try std.testing.expectEqual(Command.system_function_names, lookup("システム関数一覧取得").?);
    try std.testing.expectEqual(Command.system_function_exists, lookup("システム関数存在").?);
    try std.testing.expectEqual(Command.plugin_names, lookup("プラグイン一覧取得").?);
    try std.testing.expectEqual(Command.plugin_names, lookup("モジュール一覧取得").?);
    try std.testing.expectEqual(Command.josi_names, lookup("助詞一覧取得").?);
    try std.testing.expectEqual(Command.reserved_words, lookup("予約語一覧取得").?);
    try std.testing.expectEqual(Command.assert_strict_equal, lookup("ASSERT等").?);
    try std.testing.expectEqual(Command.assert_strict_equal, lookup("テスト実行").?);
    try std.testing.expectEqual(Command.assert_strict_equal, lookup("テスト等").?);
    try std.testing.expectEqual(Command.array_shuffle, lookup("配列シャッフル").?);
    try std.testing.expectEqual(Command.array_custom_sort, lookup("配列カスタムソート").?);
    try std.testing.expectEqual(Command.array_function_apply, lookup("配列関数適用").?);
    try std.testing.expectEqual(Command.array_map, lookup("配列マップ").?);
    try std.testing.expectEqual(Command.array_filter, lookup("配列フィルタ").?);
    try std.testing.expectEqual(Command.line_notify_discontinued, lookup("LINE送信").?);
    try std.testing.expectEqual(Command.line_image_notify_discontinued, lookup("LINE画像送信").?);
    try std.testing.expectEqual(Command.node_exit, lookup("終").?);
    try std.testing.expectEqual(Command.node_exit, lookup("終了").?);
    try std.testing.expectEqual(Command.node_process_exit, lookup("プロセス終").?);
    try std.testing.expectEqual(Command.node_file_exists, lookup("存在").?);
    try std.testing.expectEqual(Command.node_folder_exists, lookup("フォルダ存在").?);
    try std.testing.expectEqual(Command.node_home_directory, lookup("ホームディレクトリ取得").?);
    try std.testing.expectEqual(Command.node_desktop, lookup("デスクトップ").?);
    try std.testing.expectEqual(Command.node_documents, lookup("マイドキュメント").?);
    try std.testing.expectEqual(Command.node_temporary_directory, lookup("テンポラリフォルダ").?);
    try std.testing.expectEqual(Command.node_mother_path, lookup("母艦パス取得").?);
    try std.testing.expectEqual(Command.node_temporary_directory_create, lookup("一時フォルダ作成").?);
    try std.testing.expectEqual(Command.node_hash_names, lookup("ハッシュ関数一覧取得").?);
    try std.testing.expectEqual(Command.node_archive_tool_path_set, lookup("圧縮解凍ツールパス変更").?);
    try std.testing.expectEqual(Command.node_file_size, lookup("ファイルサイズ取得").?);
    try std.testing.expectEqual(Command.node_file_info, lookup("ファイル情報取得").?);
    try std.testing.expectEqual(Command.node_encoding_supports, lookup("文字コード変換サポート判定").?);
    try std.testing.expectEqual(Command.node_stdin_all, lookup("標準入力全取得").?);
    try std.testing.expectEqual(Command.node_post_data, lookup("POSTデータ生成").?);
    try std.testing.expectEqual(Command.node_ajax_options_set, lookup("AJAXオプション設定").?);
    try std.testing.expectEqual(Command.node_ajax_onerror_set, lookup("AJAX失敗時").?);
    try std.testing.expectEqual(Command.node_ajax_send_callback, lookup("AJAX送信時").?);
    try std.testing.expectEqual(Command.node_ajax_receive_callback, lookup("AJAX受信時").?);
    try std.testing.expectEqual(Command.node_get_send_callback, lookup("GET送信時").?);
    try std.testing.expectEqual(Command.node_post_send_callback, lookup("POST送信時").?);
    try std.testing.expectEqual(Command.node_post_form_send_callback, lookup("POSTフォーム送信時").?);
    try std.testing.expectEqual(Command.node_ajax_response_promise, lookup("AJAX保障送信").?);
    try std.testing.expectEqual(Command.node_http_response_promise, lookup("HTTP保障取得").?);
    try std.testing.expectEqual(Command.node_get_response_promise, lookup("GET保障送信").?);
    try std.testing.expectEqual(Command.node_post_response_promise, lookup("POST保障送信").?);
    try std.testing.expectEqual(Command.node_post_form_response_promise, lookup("POSTフォーム保障送信").?);
    try std.testing.expectEqual(Command.node_ajax_content_get, lookup("AJAX内容取得").?);
    try std.testing.expectEqual(Command.node_ajax_receive, lookup("AJAX受信").?);
    try std.testing.expectEqual(Command.node_post_send, lookup("POST送信").?);
    try std.testing.expectEqual(Command.node_post_form_send, lookup("POSTフォーム送信").?);
    try std.testing.expectEqual(Command.node_ajax_text_get, lookup("AJAXテキスト取得").?);
    try std.testing.expectEqual(Command.node_ajax_json_get, lookup("AJAX_JSON取得").?);
    try std.testing.expectEqual(Command.node_ajax_binary_get, lookup("AJAXバイナリ取得").?);
    try std.testing.expectEqual(Command.node_discord_send, lookup("DISCORD送信").?);
    try std.testing.expectEqual(Command.node_discord_file_send, lookup("DISCORDファイル送信").?);
    try std.testing.expectEqual(Command.node_network_ipv4, lookup("自分IPアドレス取得").?);
    try std.testing.expectEqual(Command.node_network_ipv6, lookup("自分IPV6アドレス取得").?);
    try std.testing.expectEqual(Command.node_hash_value, lookup("ハッシュ値計算").?);
    try std.testing.expectEqual(Command.node_random_uuid, lookup("ランダムUUID生成").?);
    try std.testing.expectEqual(Command.node_random_array, lookup("ランダム配列生成").?);
    try std.testing.expectEqual(Command.datetime_now, lookup("今").?);
    try std.testing.expectEqual(Command.datetime_system_time_milliseconds, lookup("システム時間ミリ秒").?);
    try std.testing.expectEqual(Command.datetime_today, lookup("今日").?);
    try std.testing.expectEqual(Command.caniuse_browsers, lookup("対応ブラウザ一覧取得").?);
    try std.testing.expectEqual(Command.datetime_weekday, lookup("曜日").?);
    try std.testing.expectEqual(Command.datetime_weekday_number, lookup("曜日番号取得").?);
    try std.testing.expectEqual(Command.datetime_unix_time, lookup("UNIXTIME変換").?);
    try std.testing.expectEqual(Command.datetime_unix_time, lookup("UNIX時間変換").?);
    try std.testing.expectEqual(Command.datetime_date_time, lookup("日時変換").?);
    try std.testing.expectEqual(Command.url_encode, lookup("URLエンコード").?);
    try std.testing.expectEqual(Command.url_decode, lookup("URLデコード").?);
    try std.testing.expectEqual(Command.url_parameters, lookup("URLパラメータ解析").?);
    try std.testing.expectEqual(Command.base64_encode, lookup("BASE64エンコード").?);
    try std.testing.expectEqual(Command.base64_decode, lookup("BASE64デコード").?);
    try std.testing.expectEqual(Command.node_os, lookup("OS取得").?);
    try std.testing.expectEqual(Command.node_architecture, lookup("OSアーキテクチャ取得").?);
    try std.testing.expectEqual(Command.node_environment_get, lookup("環境変数取得").?);
    try std.testing.expectEqual(Command.node_environment_list, lookup("環境変数一覧取得").?);
    try std.testing.expectEqual(Command.node_current_directory, lookup("カレントディレクトリ取得").?);
    try std.testing.expectEqual(Command.node_current_directory, lookup("作業フォルダ取得").?);
    try std.testing.expectEqual(Command.node_change_directory, lookup("カレントディレクトリ変更").?);
    try std.testing.expectEqual(Command.node_change_directory, lookup("作業フォルダ変更").?);
    try std.testing.expectEqual(Command.node_path_basename, lookup("ファイル名抽出").?);
    try std.testing.expectEqual(Command.node_path_dirname, lookup("パス抽出").?);
    try std.testing.expectEqual(Command.node_path_absolute, lookup("絶対パス変換").?);
    try std.testing.expectEqual(Command.node_path_resolve, lookup("相対パス展開").?);
    try std.testing.expectEqual(Command.datetime_format, lookup("日時書式変換").?);
    try std.testing.expectEqual(Command.datetime_era, lookup("和暦変換").?);
    try std.testing.expectEqual(Command.datetime_year_difference, lookup("年数差").?);
    try std.testing.expectEqual(Command.datetime_month_difference, lookup("月数差").?);
    try std.testing.expectEqual(Command.datetime_day_difference, lookup("日数差").?);
    try std.testing.expectEqual(Command.datetime_hour_difference, lookup("時間差").?);
    try std.testing.expectEqual(Command.datetime_minute_difference, lookup("分差").?);
    try std.testing.expectEqual(Command.datetime_second_difference, lookup("秒差").?);
    try std.testing.expectEqual(Command.datetime_difference, lookup("日時差").?);
    try std.testing.expectEqual(Command.datetime_add_time, lookup("時間加算").?);
    try std.testing.expectEqual(Command.datetime_add_date, lookup("日付加算").?);
    try std.testing.expectEqual(Command.datetime_add_datetime, lookup("日時加算").?);
    try std.testing.expectEqual(Command.datetime_monotonic_milliseconds, lookup("時間ミリ秒取得").?);
    try std.testing.expectEqual(Command.path_extract_extension, lookup("拡張子抽出").?);
    try std.testing.expectEqual(Command.path_change_extension, lookup("拡張子変更").?);
    try std.testing.expectEqual(Command.path_add_trailing_separator, lookup("終端パス追加").?);
    try std.testing.expectEqual(Command.path_remove_trailing_separator, lookup("終端パス除去").?);
    try std.testing.expectEqual(Command.path_delete_trailing_separator, lookup("終端パス削除").?);
    try std.testing.expectEqual(Command.kansuji_to_kanji, lookup("漢数字").?);
    try std.testing.expectEqual(Command.kansuji_to_arabic, lookup("算用数字").?);
    try std.testing.expectEqual(Command.csv_parse, lookup("CSV取得").?);
    try std.testing.expectEqual(Command.tsv_parse, lookup("TSV取得").?);
    try std.testing.expectEqual(Command.table_csv_stringify, lookup("表CSV変換").?);
    try std.testing.expectEqual(Command.csv_stringify, lookup("CSV変換").?);
    try std.testing.expectEqual(Command.table_tsv_stringify, lookup("表TSV変換").?);
    try std.testing.expectEqual(Command.tsv_stringify, lookup("TSV変換").?);
    try std.testing.expectEqual(Command.csv_options, lookup("CSVオプション設定").?);
    try std.testing.expectEqual(Command.toml_parse, lookup("TOML取得").?);
    try std.testing.expectEqual(Command.toml_stringify, lookup("TOML変換").?);
    try std.testing.expectEqual(Command.markdown_to_html, lookup("マークダウンHTML変換").?);
    try std.testing.expectEqual(Command.html_pretty, lookup("HTML整形").?);
    try std.testing.expectEqual(Command.deep_equal, lookup("一致").?);
    try std.testing.expectEqual(Command.deep_not_equal, lookup("不一致").?);
    try std.testing.expectEqual(Command.courtesy_increment, lookup("ください").?);
    try std.testing.expectEqual(Command.courtesy_increment, lookup("お願").?);
    try std.testing.expectEqual(Command.courtesy_increment, lookup("です").?);
    try std.testing.expectEqual(Command.courtesy_begin, lookup("拝啓").?);
    try std.testing.expectEqual(Command.courtesy_end, lookup("敬具").?);
    try std.testing.expectEqual(Command.courtesy_level, lookup("礼節レベル取得").?);
    try std.testing.expectEqual(Command.stdio_continue_display, lookup("継続表示").?);
    try std.testing.expectEqual(Command.stdio_continue_display_many, lookup("連続無改行表示").?);
    try std.testing.expectEqual(Command.stdio_clear_log, lookup("表示ログクリア").?);
    try std.testing.expectEqual(Command.stdio_write_all, lookup("言").?);
    try std.testing.expectEqual(Command.stdio_write_all, lookup("コンソール表示").?);
    try std.testing.expectEqual(Command.node_archive_extract, lookup("解凍").?);
    try std.testing.expectEqual(Command.node_archive_extract_callback, lookup("解凍時").?);
    try std.testing.expectEqual(Command.node_archive_create, lookup("圧縮").?);
    try std.testing.expectEqual(Command.node_archive_create_callback, lookup("圧縮時").?);
    try std.testing.expectEqual(Command.node_process_run_wait, lookup("起動待機").?);
    try std.testing.expectEqual(Command.node_process_start, lookup("起動").?);
    try std.testing.expectEqual(Command.node_process_run, lookup("コマンド実行").?);
    try std.testing.expectEqual(Command.node_process_run_wait_output, lookup("コマンド実行待機").?);
    try std.testing.expectEqual(Command.node_process_start_callback, lookup("起動時").?);
    try std.testing.expectEqual(Command.node_open_external_browser, lookup("ブラウザ起動").?);
    try std.testing.expectEqual(Command.node_open_external_explorer, lookup("エクスプローラー起動").?);
    try std.testing.expectEqual(Command.node_file_process_callback, lookup("ファイル処理時").?);
    try std.testing.expectEqual(Command.node_file_process_stop, lookup("ファイル処理強制停止").?);
    try std.testing.expectEqual(Command.node_file_copy_callback, lookup("ファイルコピー時").?);
    try std.testing.expectEqual(Command.node_file_move_callback, lookup("ファイル移動時").?);
    try std.testing.expectEqual(Command.node_file_delete_callback, lookup("ファイル削除時").?);
    try std.testing.expect(lookup("未対応命令") == null);
}

test "AOTトレース名は別名ではなくcanonical opcodeを使う" {
    try std.testing.expectEqualStrings("to_string", canonicalOpcodeName(.to_string));
    try std.testing.expectEqualStrings("array_cut", canonicalOpcodeName(.array_cut));
    try std.testing.expectEqualStrings("regexp_match", canonicalOpcodeName(.regexp_match));
}
