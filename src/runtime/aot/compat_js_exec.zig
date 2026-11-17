//! `--compat-js` AOT runtime の `sys.__exec` ビルトイン命令ディスパッチャ。
//!
//! この module は `compat_js.zig` からのみ import する。通常 AOT の
//! `liblnako_runtime.a` にはリンクされず、QuickJS を含む compat 成果物だけが
//! このディスパッチ経路を持つ。`builtins.zig` / `runtime_core.zig` から
//! 逆 import してはならない（Issue #282 Unit 1）。
const std = @import("std");
const state = @import("state.zig");
const builtins = @import("builtins.zig");
const control_flow = @import("control_flow.zig");
const debug = @import("debug.zig");
const values = @import("values.zig");
const compat_js = @import("compat_js.zig");

const Runtime = state.Runtime;
const Value = state.Value;
const aot_builtin = state.aot_builtin;

const undefined_value: Value = .{};

/// ビルトイン命令が暗黙に読み書きするシステム変数の安全なスロット。
///
/// `dynamic_globals` の `entry.value` へのポインタは、命令実行中の再入で
/// `ArrayList` が再確保されるとダングリングポインタになる。そのため
/// `entry.slot`（LLVM の固定 `@lnako.global.N`）がある場合はそれだけを使い、
/// 無い場合は GC ルート保護したスタック上の `temp_value` を渡して
/// `finish()` で名前ベースに書き戻す。`&entry.value` は決して公開しない。
pub const ManagedGlobalSlot = struct {
    runtime: *Runtime,
    name: []const u8,
    static_slot: ?*Value,
    temp_value: Value = .{},
    root_frame: state.RootFrame = .{},
    rooted: bool = false,

    pub fn init(runtime: *Runtime, name: []const u8, default_val: Value) !ManagedGlobalSlot {
        if (state.dynamicGlobal(runtime, name)) |entry| {
            if (entry.slot) |slot_ptr| {
                return .{
                    .runtime = runtime,
                    .name = name,
                    .static_slot = slot_ptr,
                };
            }
            return .{
                .runtime = runtime,
                .name = name,
                .static_slot = null,
                .temp_value = entry.value,
            };
        }
        return .{
            .runtime = runtime,
            .name = name,
            .static_slot = null,
            .temp_value = default_val,
        };
    }

    pub fn bindAndPtr(self: *ManagedGlobalSlot) *Value {
        if (self.static_slot) |slot_ptr| return slot_ptr;
        self.runtime.pushRoots(&self.root_frame, @ptrCast(&self.temp_value), 1);
        self.rooted = true;
        return &self.temp_value;
    }

    pub fn finish(self: *ManagedGlobalSlot) void {
        if (self.static_slot != null) return;
        if (!self.rooted) return;
        defer self.runtime.popRoots(&self.root_frame);
        state.upsertDynamicGlobal(self.runtime, self.name, self.temp_value) catch |err| {
            self.runtime.setFailure(err);
        };
    }
};

fn argumentsPointer(arguments: []const Value) ?[*]const Value {
    return if (arguments.len == 0) null else arguments.ptr;
}

fn lastArgument(arguments: []const Value) ?*const Value {
    return if (arguments.len == 0) null else &arguments[arguments.len - 1];
}

fn initSlot(runtime: *Runtime, name: []const u8, default_val: Value) ?ManagedGlobalSlot {
    return ManagedGlobalSlot.init(runtime, name, default_val) catch |err| {
        runtime.setFailure(err);
        return null;
    };
}

/// `表示ログ` の初期値。コンパイル済みバイナリでは preamble がシステム定数
/// `""` で初期化した静的スロットを使う。単体テスト等で未登録の場合だけ、
/// インタプリタの `appendDisplayLog` と同じ空文字列を既定値にする。
fn initDisplayLogSlot(runtime: *Runtime) ?ManagedGlobalSlot {
    if (state.dynamicGlobal(runtime, "表示ログ") != null) {
        return initSlot(runtime, "表示ログ", .{});
    }
    const empty = state.runtimeUtf8String(runtime, "") catch |err| {
        runtime.setFailure(err);
        return null;
    };
    return initSlot(runtime, "表示ログ", empty);
}

fn minCommandArgs(command: aot_builtin.Command) usize {
    return switch (command) {
        // 0引数でそのまま動作する、またはインタプリタでも引数不足エラーになる命令は補わない。
        .assert_strict_equal,
        .system_measure_time,
        .system_path_basename,
        .system_path_dirname,
        .node_random_uuid,
        .maximum,
        .minimum,
        .empty_array,
        .empty_dictionary,
        .sum_parsed,
        .sequential_add,
        .concat_join,
        .json_decode,
        .math_random,
        .datetime_now,
        .datetime_system_time,
        .datetime_system_time_milliseconds,
        .datetime_today,
        .datetime_tomorrow,
        .datetime_yesterday,
        .datetime_current_year,
        .datetime_next_year,
        .datetime_last_year,
        .datetime_current_month,
        .datetime_next_month,
        .datetime_previous_month,
        .datetime_monotonic_milliseconds,
        .caniuse_browsers,
        .node_os,
        .node_architecture,
        .node_environment_list,
        .node_current_directory,
        .node_home_directory,
        .node_desktop,
        .node_documents,
        .node_temporary_directory,
        .node_mother_path,
        .courtesy_increment,
        .courtesy_begin,
        .courtesy_end,
        .courtesy_level,
        .stdio_continue_display,
        .stdio_continue_display_many,
        .stdio_clear_log,
        .stdio_write_all,
        .namespace_pop,
        .timer_wait,
        .timer_after,
        .timer_every,
        .timer_stop_all,
        .promise_all,
        .async_noop,
        .node_console_clear,
        .node_file_process_stop,
        .system_debug_breakpoint_wait,
        .system_debug_display,
        .system_debug_enable,
        .system_global_function_names,
        .system_function_names,
        .system_function_exists,
        .plugin_names,
        .josi_names,
        .reserved_words,
        .line_notify_discontinued,
        .line_image_notify_discontinued,
        .node_exit,
        .system_end,
        .node_hash_names,
        .node_stdin_all,
        .node_stdin_line,
        .node_stdin_character,
        .node_network_ipv4,
        .node_network_ipv6,
        .system_hatena_configure,
        .system_nadesiko,
        .system_nadesiko_continue,
        => 0,

        .table_search,
        .table_regexp_search,
        => 4,

        .regexp_replace,
        .cut_range,
        .node_archive_extract_callback,
        .node_archive_create_callback,
        .node_file_copy_callback,
        .node_file_move_callback,
        .node_post_send_callback,
        .node_post_form_send_callback,
        .node_discord_file_send,
        .datetime_difference,
        .table_pickup,
        .table_exact_pickup,
        .table_regexp_pickup,
        .table_insert_column,
        .rgb,
        .in_range,
        .clamp,
        .string_insert,
        .string_search,
        .string_remove,
        .substring_mid,
        .replace_all,
        .replace_first,
        => 3,

        .regexp_match,
        .regexp_extract,
        .regexp_split,
        .cut,
        .http_server_start,
        .http_server_static,
        .http_server_receive,
        .http_server_headers,
        .node_archive_extract,
        .node_archive_create,
        .node_process_start_callback,
        .node_file_delete_callback,
        .node_path_resolve,
        .node_file_save,
        .node_file_sjis_save,
        .node_file_euc_save,
        .node_file_copy,
        .node_file_copy_overwrite,
        .node_file_move,
        .node_file_move_overwrite,
        .node_encoding_encode,
        .node_encoding_decode,
        .node_hash_value,
        .node_ajax_content_get,
        .node_ajax_send_callback,
        .node_ajax_receive_callback,
        .node_get_send_callback,
        .node_post_response_promise,
        .node_post_form_response_promise,
        .node_post_send,
        .node_post_form_send,
        .node_discord_send,
        .path_change_extension,
        .datetime_format,
        .datetime_year_difference,
        .datetime_month_difference,
        .datetime_day_difference,
        .datetime_hour_difference,
        .datetime_minute_difference,
        .datetime_second_difference,
        .datetime_add_time,
        .datetime_add_date,
        .datetime_add_datetime,
        .table_sort,
        .table_numeric_sort,
        .table_column,
        .table_unique,
        .table_delete_column,
        .table_column_sum,
        .array_custom_sort,
        .array_function_apply,
        .array_map,
        .array_filter,
        .radix,
        .bit_or,
        .bit_and,
        .bit_xor,
        .shift_left,
        .shift_right,
        .shift_right_unsigned,
        .subtract,
        .multiply,
        .divide,
        .remainder,
        .power_number,
        .greater_equal,
        .less_equal,
        .less,
        .greater,
        .strict_equal,
        .strict_not_equal,
        .deep_equal,
        .deep_not_equal,
        .logical_or,
        .logical_and,
        .range,
        .dictionary_remove,
        .hash_remove,
        .dictionary_has,
        .hash_has,
        .repeat_multiply,
        .codepoint_find,
        .string_starts,
        .string_ends,
        .add_parsed,
        .append,
        .append_line,
        .refrain,
        .occurrence_count,
        .occurrence,
        .substring_left,
        .substring_right,
        .split_all,
        .split_first,
        .zero_pad,
        .space_pad,
        => 2,

        else => if (aot_builtin.isLowLevelCommand(command)) 0 else 1,
    };
}

/// カテゴリ 6: ESM / native plugin 命令へのフォールバック。
///
/// ESM module が登録されている場合は `esmPluginBuiltin` を先に試し、
/// `error.UnknownCommand` のときだけ native plugin へ降りる。どちらも
/// 未知なら `error.UnknownCommand` を残す。plugin 呼出しが自分で保留例外を
/// 立てた場合は、その例外を汎用エラーで上書きしない。
fn execCompatPluginBuiltin(
    runtime: *Runtime,
    cmd_name: []const u8,
    arguments: []const Value,
    out: *Value,
) void {
    if (runtime.esm_modules.items.len > 0) {
        const result = state.esmPluginBuiltin(runtime, cmd_name, arguments) catch |failure| {
            if (failure == error.UnknownCommand and runtime.native_plugin_paths.items.len > 0) {
                execCompatNativePluginBuiltin(runtime, cmd_name, arguments, out);
                return;
            }
            if (!runtime.has_pending_exception) runtime.setFailure(failure);
            return;
        };
        out.* = result;
        return;
    }
    if (runtime.native_plugin_paths.items.len > 0) {
        execCompatNativePluginBuiltin(runtime, cmd_name, arguments, out);
        return;
    }
    runtime.setFailure(error.UnknownCommand);
}

fn execCompatNativePluginBuiltin(
    runtime: *Runtime,
    cmd_name: []const u8,
    arguments: []const Value,
    out: *Value,
) void {
    const result = state.nativePluginBuiltin(runtime, cmd_name, arguments) catch |failure| {
        if (!runtime.has_pending_exception) runtime.setFailure(failure);
        return;
    };
    out.* = result;
}

fn execCompatHatenaConfigure(runtime: *Runtime, arguments: []const Value) void {
    runtime.hatena_callbacks.clearRetainingCapacity();
    if (arguments.len == 0) return;

    var roots = [_]Value{ arguments[arguments.len - 1], .{}, .{} };
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    switch (@as(state.Tag, @fromBackingInt(@intCast(roots[0].tag)))) {
        .function, .static_utf8_string, .utf16_string => {
            runtime.hatena_callbacks.append(runtime.allocator, roots[0]) catch |err| {
                runtime.setFailure(err);
            };
        },
        .array => {
            const initial_items = state.arrayItems(roots[0]) catch |err| {
                runtime.setFailure(err);
                return;
            };
            const item_count = initial_items.items.len;
            for (0..item_count) |idx| {
                const items = state.arrayItems(roots[0]) catch |err| {
                    runtime.setFailure(err);
                    return;
                };
                if (idx >= items.items.len) break;
                const item = items.items[idx];
                if (!state.isString(item)) {
                    runtime.setFailure(error.InvalidHatenaCallback);
                    return;
                }
                const name = state.stringUtf8Alloc(runtime, item) catch |err| {
                    runtime.setFailure(err);
                    return;
                };
                defer runtime.allocator.free(name);
                if (std.mem.startsWith(u8, name, "JS:")) {
                    roots[1] = state.runtimeUtf8String(runtime, name[3..]) catch |err| {
                        runtime.setFailure(err);
                        return;
                    };
                    roots[2] = .{};
                    compat_js.lnako_aot_compat_js_eval(&roots[2], @ptrCast(&roots[1]), 1);
                    if (runtime.has_pending_exception) return;
                    if (roots[2].tag != @backingInt(state.Tag.function)) {
                        runtime.setFailure(error.InvalidHatenaCallback);
                        return;
                    }
                    runtime.hatena_callbacks.append(runtime.allocator, roots[2]) catch |err| {
                        runtime.setFailure(err);
                        return;
                    };
                } else {
                    runtime.hatena_callbacks.append(runtime.allocator, item) catch |err| {
                        runtime.setFailure(err);
                        return;
                    };
                }
            }
        },
        else => {},
    }
}

/// `sys.__exec(name, args)` のビルトイン命令ディスパッチ。Unit 1 の範囲
/// （特殊 lowering 命令・正規表現・はてな実行・ターゲット必須の主要命令・
/// 汎用命令・補助命令）を AOT ランタイムの専用 ABI へ振り分ける。
pub fn execCompatBuiltin(runtime: *Runtime, cmd_name: []const u8, arguments: []const Value, out: *Value) void {
    out.* = .{};

    // カテゴリ 1: `aot_builtin.lookup` の前段で特別に lowering される命令。
    if (std.mem.eql(u8, cmd_name, "表示") or std.mem.eql(u8, cmd_name, "表示する")) {
        var log_slot = initDisplayLogSlot(runtime) orelse return;
        defer log_slot.finish();
        const log_ptr = log_slot.bindAndPtr();
        values.lnako_aot_display_value(lastArgument(arguments) orelse &undefined_value, true, log_ptr);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "連続表示")) {
        var log_slot = initDisplayLogSlot(runtime) orelse return;
        defer log_slot.finish();
        const log_ptr = log_slot.bindAndPtr();
        debug.lnako_aot_display_many(argumentsPointer(arguments), arguments.len, log_ptr);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "エラー発生")) {
        const default_error = state.staticStringValue("エラー");
        debug.lnako_aot_exception_set_error_message(lastArgument(arguments) orelse &default_error);
        debug.lnako_aot_throw_site(0);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "JS実行")) {
        compat_js.lnako_aot_compat_js_eval(out, argumentsPointer(arguments), arguments.len);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "JS関数実行")) {
        compat_js.lnako_aot_compat_js_call(out, argumentsPointer(arguments), arguments.len);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "JSオブジェクト取得")) {
        compat_js.lnako_aot_compat_js_object_get(out, argumentsPointer(arguments), arguments.len);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "JSメソッド実行")) {
        compat_js.lnako_aot_compat_js_method_call(out, argumentsPointer(arguments), arguments.len);
        return;
    }

    // カテゴリ 5: `aot_builtin.lookup` にないインタプリタ補助命令。
    // `ASSERT` / `確認` はインタプリタと同じく最後の引数の truthiness を見る。
    if (std.mem.eql(u8, cmd_name, "ASSERT") or std.mem.eql(u8, cmd_name, "確認")) {
        if (arguments.len == 0 or !state.valueTruthy(arguments[arguments.len - 1])) {
            runtime.setFailure(error.AssertionFailed);
            return;
        }
        out.* = arguments[arguments.len - 1];
        return;
    }

    // カテゴリ 6: ビルトインに無い命令は ESM / native plugin の命令として
    // 実行時に解決する。`dynamic.zig` 側は QuickJS を一切 import しないため、
    // この経路を compat 専用 module に閉じ込めても通常 AOT の分離は崩れない。
    const command = aot_builtin.lookup(cmd_name) orelse {
        execCompatPluginBuiltin(runtime, cmd_name, arguments, out);
        return;
    };
    if ((command == .maximum or command == .minimum) and arguments.len == 0) {
        out.* = state.numberValue(if (command == .maximum) -std.math.inf(f64) else std.math.inf(f64));
        return;
    }
    // インタプリタの plugin 群は不足実引数を `.undefined` として扱うが、AOT 汎用
    // call site 等は呼び出し元 arity 検査を前提に `InvalidArgumentCount` を返す。
    // `sys.__exec` 経由では最小必要数まで `.undefined` を補って一致させる。
    var padded_storage: [4]Value = .{ undefined_value, undefined_value, undefined_value, undefined_value };
    const min_args = minCommandArgs(command);
    const call_args: []const Value = if (arguments.len < min_args) blk: {
        @memcpy(padded_storage[0..arguments.len], arguments);
        break :blk padded_storage[0..min_args];
    } else arguments;

    switch (command) {
        // カテゴリ 2: 専用 ABI を持つ正規表現命令。
        .regexp_match, .regexp_extract, .regexp_replace, .regexp_split => {
            var capture_slot = initSlot(runtime, "抽出文字列", .{}) orelse return;
            defer capture_slot.finish();
            const capture_ptr: ?*Value = if (command == .regexp_match or command == .regexp_extract)
                capture_slot.bindAndPtr()
            else
                null;
            debug.lnako_aot_regexp_call_site(
                out,
                capture_ptr,
                argumentsPointer(call_args),
                call_args.len,
                @backingInt(command),
                0,
            );
            return;
        },
        // カテゴリ 2: ハテナ関数設定（compat 経路のみ `JS:` 形式を関数へ変換）。
        .system_hatena_configure => {
            execCompatHatenaConfigure(runtime, call_args);
            return;
        },
        // カテゴリ 2: はてな実行。
        .system_hatena_execute => {
            var log_slot = initDisplayLogSlot(runtime) orelse return;
            defer log_slot.finish();
            const log_ptr = log_slot.bindAndPtr();
            debug.lnako_aot_hatena_execute(
                out,
                lastArgument(call_args),
                0,
                null,
                0,
                log_ptr,
                0,
            );
            return;
        },
        // カテゴリ 3: `対象` を更新する切取命令。
        .cut, .cut_range => {
            var target_slot = initSlot(runtime, "対象", .{}) orelse return;
            defer target_slot.finish();
            const target_ptr = target_slot.bindAndPtr();
            const mode: u8 = if (command == .cut) 0 else 1;
            state.lnako_aot_cut_site(
                out,
                target_ptr,
                argumentsPointer(call_args),
                call_args.len,
                mode,
                0,
            );
            return;
        },
        // カテゴリ 3: プラグイン名・名前空間の管理命令。
        .plugin_name_set, .namespace_set, .namespace_pop => {
            var plugin_slot = initSlot(runtime, "プラグイン名", .{}) orelse return;
            defer plugin_slot.finish();
            var namespace_slot = initSlot(runtime, "名前空間", .{}) orelse return;
            defer namespace_slot.finish();
            const plugin_ptr = plugin_slot.bindAndPtr();
            const namespace_ptr = namespace_slot.bindAndPtr();
            debug.lnako_aot_plugin_management_call(
                out,
                argumentsPointer(call_args),
                call_args.len,
                @backingInt(command),
                plugin_ptr,
                namespace_ptr,
                0,
            );
            return;
        },
        // カテゴリ 3: `表示ログ` を更新する stdio 命令。
        .stdio_continue_display, .stdio_continue_display_many, .stdio_clear_log, .stdio_write_all => {
            var log_slot = initDisplayLogSlot(runtime) orelse return;
            defer log_slot.finish();
            const log_ptr = log_slot.bindAndPtr();
            debug.lnako_aot_stdio_call(
                out,
                log_ptr,
                argumentsPointer(call_args),
                call_args.len,
                @backingInt(command),
                0,
            );
            return;
        },
        // カテゴリ 3: `表示ログ` を更新するデバッグ表示。
        .system_debug_display => {
            var log_slot = initDisplayLogSlot(runtime) orelse return;
            defer log_slot.finish();
            const log_ptr = log_slot.bindAndPtr();
            debug.lnako_aot_debug_display(
                out,
                lastArgument(call_args),
                0,
                null,
                0,
                log_ptr,
                0,
            );
            return;
        },
        // カテゴリ 2: 圧縮解凍ツールパスの設定。
        .node_archive_tool_path_set => {
            var tool_slot = initSlot(runtime, "圧縮解凍ツールパス", state.staticStringValue("7z")) orelse return;
            defer tool_slot.finish();
            control_flow.lnako_aot_archive_tool_path_set(
                out,
                argumentsPointer(call_args),
                call_args.len,
                tool_slot.bindAndPtr(),
                0,
            );
            return;
        },
        // カテゴリ 2: AJAX の既定オプション設定。
        .node_ajax_options_set => {
            var options_slot = initSlot(runtime, "AJAXオプション", state.staticStringValue("")) orelse return;
            defer options_slot.finish();
            control_flow.lnako_aot_ajax_options_set(
                out,
                argumentsPointer(call_args),
                call_args.len,
                options_slot.bindAndPtr(),
                0,
            );
            return;
        },
        // カテゴリ 2: AJAX の失敗ハンドラ設定。
        .node_ajax_onerror_set => {
            var onerror_slot = initSlot(
                runtime,
                "AJAX:ONERROR",
                .{ .tag = @backingInt(state.Tag.null_value), .payload = 0 },
            ) orelse return;
            defer onerror_slot.finish();
            control_flow.lnako_aot_ajax_onerror_set(
                out,
                argumentsPointer(call_args),
                call_args.len,
                onerror_slot.bindAndPtr(),
                0,
            );
            return;
        },
        // カテゴリ 2: 標準入力取得時のコールバック（同一ターンで同期実行）。
        .node_stdin_callback => {
            var target_slot = initSlot(runtime, "対象", .{}) orelse return;
            defer target_slot.finish();
            control_flow.lnako_aot_node_stdin_callback_call(
                out,
                target_slot.bindAndPtr(),
                argumentsPointer(call_args),
                call_args.len,
                @backingInt(command),
                0,
            );
            return;
        },
        // カテゴリ 3: デバッグのブレイクポイント待機。
        .system_debug_breakpoint_wait => {
            var breakpoints_slot = initSlot(runtime, "__DEBUGブレイクポイント一覧", .{}) orelse return;
            defer breakpoints_slot.finish();
            var force_wait_slot = initSlot(runtime, "__DEBUG強制待機", state.numberValue(0)) orelse return;
            defer force_wait_slot.finish();
            var wait_flag_slot = initSlot(runtime, "__DEBUG待機フラグ", state.numberValue(0)) orelse return;
            defer wait_flag_slot.finish();
            var plugin_slot = initSlot(runtime, "プラグイン名", state.staticStringValue("メイン")) orelse return;
            defer plugin_slot.finish();
            builtins.lnako_aot_debug_breakpoint_wait_call(
                out,
                breakpoints_slot.bindAndPtr(),
                force_wait_slot.bindAndPtr(),
                wait_flag_slot.bindAndPtr(),
                plugin_slot.bindAndPtr(),
                argumentsPointer(call_args),
                call_args.len,
                @backingInt(command),
                0,
            );
            return;
        },
        // カテゴリ 3: タイマー。`対象` は `秒後` / `秒毎` の非同期
        // コールバックが保持し得るため、固定スロットがある場合だけ専用 ABI へ
        // 渡す。無い場合（preamble を持たない単体テスト）はスタック上の
        // 値を保持させないよう直接実行する。
        .timer_after, .timer_every, .timer_stop, .timer_stop_all => {
            var target_slot = initSlot(runtime, "対象", .{}) orelse return;
            defer target_slot.finish();
            if (target_slot.static_slot) |target_ptr| {
                control_flow.lnako_aot_timer_call_site(
                    out,
                    target_ptr,
                    argumentsPointer(call_args),
                    call_args.len,
                    @backingInt(command),
                    0,
                );
            } else {
                out.* = state.timerBuiltin(runtime, command, call_args, null) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
            }
            return;
        },
        // カテゴリ 3: Promise。`そ` は呼出し中だけ読み書きされるが、
        // `対象` は非同期の連鎖処理が保持し得るため固定スロットだけを渡す。
        .promise_create, .promise_success, .promise_settled, .promise_failure, .promise_finally, .promise_all => {
            var so_slot = initSlot(runtime, "そ", .{}) orelse return;
            defer so_slot.finish();
            var target_slot = initSlot(runtime, "対象", .{}) orelse return;
            defer target_slot.finish();
            const so_ptr = so_slot.bindAndPtr();
            if (target_slot.static_slot) |target_ptr| {
                control_flow.lnako_aot_promise_call_site(
                    out,
                    so_ptr,
                    target_ptr,
                    argumentsPointer(call_args),
                    call_args.len,
                    @backingInt(command),
                    0,
                );
            } else {
                out.* = state.promiseAotBuiltin(runtime, command, call_args, so_ptr, null) catch |failure| {
                    if (!runtime.has_pending_exception) runtime.setFailure(failure);
                    return;
                };
            }
            return;
        },
        else => {
            // カテゴリ 2: AJAX / HTTP クライアント命令。`対象` と失敗
            // ハンドラは非同期タスクが保持し得るため固定スロットだけを渡す。
            if (state.isNodeHttpCommand(command)) {
                var options_slot = initSlot(runtime, "AJAXオプション", state.staticStringValue("")) orelse return;
                defer options_slot.finish();
                var onerror_slot = initSlot(
                    runtime,
                    "AJAX:ONERROR",
                    .{ .tag = @backingInt(state.Tag.null_value), .payload = 0 },
                ) orelse return;
                defer onerror_slot.finish();
                var target_slot = initSlot(runtime, "対象", .{}) orelse return;
                defer target_slot.finish();
                control_flow.lnako_aot_node_http_call(
                    out,
                    options_slot.bindAndPtr(),
                    onerror_slot.static_slot,
                    target_slot.static_slot,
                    argumentsPointer(call_args),
                    call_args.len,
                    @backingInt(command),
                    0,
                );
                return;
            }
            // カテゴリ 2: 圧縮解凍の実行命令。
            if (state.isArchiveCommand(command)) {
                var tool_slot = initSlot(runtime, "圧縮解凍ツールパス", state.staticStringValue("7z")) orelse return;
                defer tool_slot.finish();
                control_flow.lnako_aot_archive_call(
                    out,
                    tool_slot.bindAndPtr(),
                    argumentsPointer(call_args),
                    call_args.len,
                    @backingInt(command),
                    0,
                );
                return;
            }
            // カテゴリ 3: 同期ファイル操作。コピー既定動作は可変グローバル。
            if (state.isNodeFileOperationCommand(command)) {
                var mode_slot = initSlot(runtime, "ファイルコピーデフォルト動作", state.staticStringValue("上書禁止")) orelse return;
                defer mode_slot.finish();
                control_flow.lnako_aot_file_operation_call(
                    out,
                    mode_slot.bindAndPtr(),
                    argumentsPointer(call_args),
                    call_args.len,
                    @backingInt(command),
                    0,
                );
                return;
            }
            // カテゴリ 3: ファイル操作の進捗コールバック。`対象` は非同期の
            // ファイルタスクが保持し得るため固定スロットだけを渡す。
            if (state.isNodeFileCallbackCommand(command)) {
                var target_slot = initSlot(runtime, "対象", .{}) orelse return;
                defer target_slot.finish();
                if (target_slot.static_slot) |target_ptr| {
                    control_flow.lnako_aot_node_file_callback_call(
                        out,
                        target_ptr,
                        argumentsPointer(call_args),
                        call_args.len,
                        @backingInt(command),
                        0,
                    );
                } else {
                    out.* = state.nodeFileCallbackBuiltin(runtime, null, command, call_args) catch |failure| {
                        runtime.setFailure(failure);
                        return;
                    };
                }
                return;
            }
            // カテゴリ 3: 簡易 HTTP サーバ。受信コールバックが
            // `runtime.http_globals` を参照するため、スタック上の temp を
            // 残す場合は呼出し前の値へ戻す。
            if (state.isHttpServerCommand(command)) {
                var method_slot = initSlot(runtime, "HTTPメソッド", .{}) orelse return;
                defer method_slot.finish();
                var get_slot = initSlot(runtime, "GETデータ", .{}) orelse return;
                defer get_slot.finish();
                var post_slot = initSlot(runtime, "POSTデータ", .{}) orelse return;
                defer post_slot.finish();
                var files_slot = initSlot(runtime, "FILESデータ", .{}) orelse return;
                defer files_slot.finish();
                const prev_http_globals = runtime.http_globals;
                control_flow.lnako_aot_http_server_call(
                    out,
                    method_slot.bindAndPtr(),
                    get_slot.bindAndPtr(),
                    post_slot.bindAndPtr(),
                    files_slot.bindAndPtr(),
                    argumentsPointer(call_args),
                    call_args.len,
                    @backingInt(command),
                    0,
                );
                if (method_slot.static_slot == null or get_slot.static_slot == null or
                    post_slot.static_slot == null or files_slot.static_slot == null)
                {
                    runtime.http_globals = prev_http_globals;
                }
                return;
            }
            // カテゴリ 4: 汎用 call site が処理できる命令。
            if (!aot_builtin.hasGenericCallSiteDispatch(command)) {
                runtime.setFailure(error.UnknownCommand);
                return;
            }
            builtins.lnako_aot_builtin_call_site(
                out,
                argumentsPointer(call_args),
                call_args.len,
                @backingInt(command),
                0,
            );
            return;
        },
    }
}
