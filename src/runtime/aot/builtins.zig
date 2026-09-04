const std = @import("std");
const shared = @import("shared.zig");
const state = @import("state.zig");

const aot_builtin = shared.aot_builtin;
const Tag = shared.Tag;
const Value = state.Value;
const Arithmetic = state.Arithmetic;
const Comparison = state.Comparison;
const ShiftOperator = state.ShiftOperator;

pub export fn lnako_aot_builtin_call(out: *Value, arguments: ?[*]const Value, len: usize, opcode: u16) callconv(.c) void {
    lnako_aot_builtin_call_site(out, arguments, len, opcode, 0);
}

/// Dedicated ABI for timer commands. Timer registration updates the shared
/// `対象` value, so generated LLVM passes that global explicitly instead of
/// relying on a runtime-local lookup.
/// Dedicated ABI for promise commands. The last promise and callback target
/// are explicit globals so asynchronous callbacks cannot be redirected by a
/// local variable with the same source-level name.
/// Dedicated ABI for `__DEBUG_BP_WAIT`. The debugger-facing system globals
/// are generated values rather than runtime-owned name lookups, so LLVM passes
/// their storage explicitly. This preserves the official immediate-return,
/// main-plugin wait, and non-main pending-Promise branches without adding a
/// JavaScript runtime to normal AOT execution.
pub export fn lnako_aot_debug_breakpoint_wait_call(
    out: *Value,
    breakpoints: *Value,
    force_wait: *Value,
    wait_flag: *Value,
    plugin_name: *Value,
    arguments: ?[*]const Value,
    len: usize,
    opcode: u16,
    site_id: u64,
) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const command = std.enums.fromInt(aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "debug-breakpoint-wait", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "debug-breakpoint-wait", site_id, false);
        return;
    };
    if (command != .system_debug_breakpoint_wait) {
        runtime.setFailure(error.UnknownCommand);
        return;
    }
    const command_name = aot_builtin.canonicalOpcodeName(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, "debug-breakpoint-wait", site_id);
    const start_epoch = runtime.failure_epoch;
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, "debug-breakpoint-wait", site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const actual = if (arguments) |pointer| pointer[0..len] else &.{};
    out.* = state.debugBreakpointWaitBuiltin(runtime, breakpoints, force_wait, wait_flag, plugin_name, actual) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    success = runtime.failure_epoch == start_epoch;
}

/// Dedicated ABI for synchronous Node file operations. The copy default is a
/// mutable system global, so generated LLVM passes its storage explicitly.
/// Dedicated ABI for Node process and desktop-launch commands.  Process
/// callbacks are retained by the native event queue, so this path never
/// falls back to a JavaScript runtime in normal AOT mode.
/// Dedicated ABI for Node file-operation callback and progress commands. The
/// current `対象` storage is explicit so progress callbacks observe the same
/// dictionary value as the interpreter, while worker threads retain only
/// copied paths and the callback Value.
pub export fn lnako_aot_builtin_call_site(out: *Value, arguments: ?[*]const Value, len: usize, opcode: u16, site_id: u64) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const start_epoch = runtime.failure_epoch;
    const command = std.enums.fromInt(aot_builtin.Command, opcode) orelse {
        const call_id = runtime.dispatch_trace.begin("unknown", opcode, "builtin", site_id);
        runtime.setFailure(error.UnknownCommand);
        runtime.dispatch_trace.result(call_id, "unknown", opcode, "builtin", site_id, false);
        return;
    };
    const command_name = aot_builtin.canonicalOpcodeName(command);
    const route = state.builtinDispatchRoute(command);
    const call_id = runtime.dispatch_trace.begin(command_name, opcode, route, site_id);
    var success = false;
    defer runtime.dispatch_trace.result(call_id, command_name, opcode, route, site_id, success);
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    if (len == 0 and command != .empty_array and command != .empty_dictionary and command != .sum_parsed and command != .sequential_add and command != .concat_join and command != .json_decode and command != .math_random and command != .datetime_now and command != .datetime_system_time and command != .datetime_system_time_milliseconds and command != .datetime_today and command != .datetime_tomorrow and command != .datetime_yesterday and command != .datetime_current_year and command != .datetime_next_year and command != .datetime_last_year and command != .datetime_current_month and command != .datetime_next_month and command != .datetime_previous_month and command != .caniuse_browsers and command != .node_os and command != .node_architecture and command != .node_environment_list and command != .node_current_directory and command != .node_home_directory and command != .node_desktop and command != .node_documents and command != .node_temporary_directory and command != .node_mother_path and command != .datetime_monotonic_milliseconds and command != .courtesy_increment and command != .courtesy_begin and command != .courtesy_end and command != .courtesy_level and command != .stdio_continue_display and command != .stdio_continue_display_many and command != .stdio_clear_log and command != .namespace_pop and command != .timer_wait and command != .timer_stop_all and command != .promise_all and command != .async_noop and command != .node_console_clear and command != .node_file_process_stop and command != .system_debug_breakpoint_wait and command != .system_debug_display and command != .system_debug_enable and command != .system_global_function_names and command != .system_function_names and command != .system_function_exists and command != .plugin_names and command != .josi_names and command != .reserved_words and command != .line_notify_discontinued and command != .line_image_notify_discontinued and command != .node_exit and command != .system_end and command != .node_hash_names and command != .node_random_uuid and command != .node_stdin_all and command != .node_stdin_line and command != .node_stdin_character and command != .node_network_ipv4 and command != .node_network_ipv6 and command != .system_hatena_configure and command != .system_nadesiko and command != .system_nadesiko_continue) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const value = if (len > 0) arguments.?[0] else Value{};
    switch (command) {
        .line_notify_discontinued, .line_image_notify_discontinued => {
            const source_name = if (command == .line_notify_discontinued) "LINE送信" else "LINE画像送信";
            const message = std.fmt.allocPrint(
                runtime.allocator,
                "『{s}』は2025年4月で使えなくなりました。[詳細URL] https://nadesi.com/v3/doc/go.php?4670",
                .{source_name},
            ) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            defer runtime.allocator.free(message);
            runtime.setFailureText(message);
            return;
        },
        .system_end => {
            runtime.setFailureText("__終わる__");
            return;
        },
        .node_exit, .node_process_exit => {
            const exit_code = if (command == .node_process_exit) state.nodeProcessExitCode(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            } else 0;
            runtime.dispatch_trace.result(call_id, command_name, opcode, "builtin", site_id, true);
            runtime.dispatch_trace.finishTerminal("process-exit", exit_code);
            _ = std.c.fflush(null);
            std.process.exit(exit_code);
        },
        .node_interrupt_callback => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.configureInterruptBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .http_server_start, .http_server_static, .http_server_receive, .http_server_output, .http_server_headers, .http_server_redirect => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.httpServerBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .regexp_match, .regexp_extract, .regexp_replace, .regexp_split => {
            runtime.setFailure(error.UnknownCommand);
            return;
        },
        .json_encode, .json_encode_pretty => {
            out.* = state.jsonEncodeBuiltin(runtime, value, command == .json_encode_pretty) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .json_decode => {
            out.* = state.jsonDecodeBuiltin(runtime, value) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .math_sin, .math_cos, .math_tan, .math_arcsin, .math_arccos, .math_arctan, .math_atan2, .math_coordinate_angle, .math_rad2deg, .math_deg2rad, .math_sign, .math_abs, .math_exp, .math_hypot, .math_log, .math_logn, .math_frac, .math_integer, .math_sqrt, .math_round, .math_decimal_ceil, .math_decimal_floor, .math_decimal_round, .math_ceil, .math_floor, .math_random, .math_random_range => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.mathBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .datetime_now, .datetime_system_time, .datetime_system_time_milliseconds, .datetime_today, .datetime_tomorrow, .datetime_yesterday, .datetime_current_year, .datetime_next_year, .datetime_last_year, .datetime_current_month, .datetime_next_month, .datetime_previous_month, .datetime_weekday, .datetime_weekday_number, .datetime_unix_time, .datetime_date_time, .datetime_format, .datetime_era, .datetime_year_difference, .datetime_month_difference, .datetime_day_difference, .datetime_hour_difference, .datetime_minute_difference, .datetime_second_difference, .datetime_difference, .datetime_add_time, .datetime_add_date, .datetime_add_datetime, .datetime_monotonic_milliseconds => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.datetimeBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .url_encode, .url_decode, .url_parameters, .base64_encode, .base64_decode => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.urlBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .path_extract_extension, .path_change_extension, .path_add_trailing_separator, .path_remove_trailing_separator, .path_delete_trailing_separator => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.pathBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .kansuji_to_kanji, .kansuji_to_arabic => {
            out.* = state.kansujiBuiltin(runtime, command, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .csv_parse, .tsv_parse, .table_csv_stringify, .csv_stringify, .table_tsv_stringify, .tsv_stringify, .csv_options => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.csvBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .toml_parse, .toml_stringify => {
            out.* = state.tomlBuiltin(runtime, command, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .markdown_to_html, .html_pretty => {
            out.* = state.markupBuiltin(runtime, command, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .courtesy_increment, .courtesy_begin, .courtesy_end, .courtesy_level => {
            out.* = state.courtesyBuiltin(runtime, command);
        },
        .stdio_continue_display, .stdio_continue_display_many, .stdio_clear_log, .stdio_write_all => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            state.stdioBuiltin(runtime, command, actual, null) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .plugin_name_set, .namespace_set, .namespace_pop => {
            runtime.setFailure(error.PluginManagementRequiresTargets);
            return;
        },
        .timer_wait => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.timerWaitBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .timer_after, .timer_every, .timer_stop, .timer_stop_all => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.timerBuiltin(runtime, command, actual, null) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .promise_create, .promise_success, .promise_settled, .promise_failure, .promise_finally, .promise_all => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.promiseAotBuiltin(runtime, command, actual, null, null) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .async_noop, .node_console_clear => out.* = .{},
        .system_debug_breakpoint_wait => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            var breakpoints = Value{};
            var force_wait = state.numberValue(0);
            var wait_flag = state.numberValue(0);
            var plugin_name = state.staticStringValue("メイン");
            out.* = state.debugBreakpointWaitBuiltin(runtime, &breakpoints, &force_wait, &wait_flag, &plugin_name, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .system_await_execute, .system_execute => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.systemExecutionBuiltin(runtime, command, actual) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .system_nadesiko, .system_nadesiko_continue => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.dynamicBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .system_measure_time => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.measureCallableBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .system_hatena_configure => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.configureHatenaBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .system_debug_display => state.debugDisplayBuiltin(runtime, value, 1, &.{}, null) catch |failure| {
            runtime.setFailure(failure);
            return;
        },
        .system_hatena_execute => {
            runtime.setFailure(error.UnknownCommand);
            return;
        },
        .node_archive_tool_path_set, .node_ajax_options_set, .node_ajax_onerror_set => {
            runtime.setFailure(error.UnknownCommand);
            return;
        },
        .node_ajax_send_callback, .node_ajax_receive_callback, .node_get_send_callback, .node_post_send_callback, .node_post_form_send_callback, .node_ajax_response_promise, .node_http_response_promise, .node_get_response_promise, .node_post_response_promise, .node_post_form_response_promise, .node_ajax_content_get, .node_ajax_receive, .node_post_send, .node_post_form_send, .node_ajax_text_get, .node_ajax_json_get, .node_ajax_binary_get, .node_discord_send, .node_discord_file_send => {
            runtime.setFailure(error.UnknownCommand);
            return;
        },
        .node_archive_extract, .node_archive_extract_callback, .node_archive_create, .node_archive_create_callback => {
            runtime.setFailure(error.UnknownCommand);
            return;
        },
        .node_process_run_wait, .node_process_run, .node_process_start, .node_process_run_wait_output, .node_process_start_callback, .node_open_external_browser, .node_open_external_explorer => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeProcessBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_file_process_callback, .node_file_process_stop, .node_file_copy_callback, .node_file_move_callback, .node_file_delete_callback => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeFileCallbackBuiltin(runtime, null, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_stdin_callback => {
            runtime.setFailure(error.UnknownCommand);
            return;
        },
        .system_debug_enable => runtime.debug_enabled = true,
        .system_global_function_names => {
            out.* = state.systemGlobalFunctionNamesBuiltin(runtime) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .system_function_names => {
            out.* = state.stringArrayBuiltin(runtime, &shared.builtin_catalog.default_names) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .system_function_exists => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.systemFunctionExistsBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .plugin_names => {
            out.* = state.stringArrayBuiltin(runtime, &state.default_plugin_names) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .josi_names => {
            out.* = state.stringArrayBuiltin(runtime, &shared.josi.exported_list) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .reserved_words => {
            out.* = state.stringArrayBuiltin(runtime, &shared.lexer.exported_reserved_words) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .assert_strict_equal => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const values = arguments.?;
            const equal = state.sameValue(runtime, values[0], values[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            if (!equal) {
                runtime.setFailure(error.AssertionFailed);
                return;
            }
        },
        .node_os, .node_architecture => {
            out.* = state.nodeEnvironmentBuiltin(runtime, command) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_environment_get => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeEnvironmentValueBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_environment_list => {
            out.* = state.nodeEnvironmentListBuiltin(runtime) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_current_directory => {
            out.* = state.nodeCurrentDirectoryBuiltin(runtime) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_change_directory => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeChangeDirectoryBuiltin(runtime, actual) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .node_file_exists, .node_folder_exists => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeFileExistenceBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_file_size => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeFileSizeBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_file_open, .node_file_read, .node_file_binary_read => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeFileReadBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_file_save => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeFileSaveBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_file_list, .node_file_list_all, .node_folder_create, .node_file_copy, .node_file_copy_overwrite, .node_file_move, .node_file_move_overwrite, .node_file_delete => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            var default_copy_mode = state.staticStringValue("上書禁止");
            out.* = state.nodeFileOperationBuiltin(runtime, command, actual, &default_copy_mode) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_file_sjis_read, .node_file_euc_read => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeEncodedFileReadBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_file_sjis_save, .node_file_euc_save => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeEncodedFileSaveBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_encoding_sjis_encode, .node_encoding_sjis_decode, .node_encoding_encode, .node_encoding_decode => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeEncodingBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_file_info => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeFileInfoBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_encoding_supports => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeEncodingSupportsBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_stdin_all => {
            out.* = state.nodeStdinAllBuiltin(runtime) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_stdin_line, .node_stdin_character => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeStdinLineBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_post_data => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodePostDataBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_network_ipv4, .node_network_ipv6 => {
            out.* = state.nodeNetworkAddressesBuiltin(runtime, command == .node_network_ipv6) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_home_directory, .node_desktop, .node_documents, .node_temporary_directory => {
            out.* = state.nodeDirectoryBuiltin(runtime, command) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_mother_path => {
            out.* = state.nodeMotherPathBuiltin(runtime) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_temporary_directory_create => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeCreateTemporaryDirectoryBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_hash_names => {
            out.* = state.stringArrayBuiltin(runtime, &shared.crypto.hash_names) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_hash_value, .node_random_uuid, .node_random_array => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodeCryptoBuiltin(runtime, command, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .node_path_basename, .node_path_dirname => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodePathComponentBuiltin(runtime, command, actual) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .system_path_basename, .system_path_dirname => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.systemPathComponentBuiltin(runtime, command, actual) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .node_path_absolute, .node_path_resolve => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.nodePathBuiltin(runtime, command, actual) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .caniuse_browsers => {
            out.* = state.caniuseBrowsersBuiltin(runtime) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .to_string => {
            const units = state.valueUtf16Alloc(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            defer runtime.allocator.free(units);
            out.* = runtime.createString(units) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .type_of => out.* = state.typeNameValue(value),
        .to_int => {
            out.* = state.numberValue(state.parseIntBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            });
        },
        .to_float => {
            out.* = state.numberValue(state.parseFloatBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            });
        },
        .is_nan => {
            const number = state.valueToNumberRuntime(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(std.math.isNan(number)) };
        },
        .is_number_nan => {
            const is_nan = value.tag == @intFromEnum(Tag.number) and std.math.isNan(@as(f64, @bitCast(value.payload)));
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(is_nan) };
        },
        .radix16, .radix, .radix2, .radix2_display => {
            if (command == .radix and len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const radix_value = if (command == .radix) arguments.?[1] else state.numberValue(if (command == .radix16) 16 else 2);
            const result = state.radixBuiltin(runtime, value, radix_value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            if (command == .radix2_display) {
                state.writeUtf16(result.object().?.payload.utf16_string, true);
            } else out.* = result;
        },
        .rgb => {
            if (len < 3) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.rgbBuiltin(runtime, arguments.?[0..3]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .bit_or, .bit_and, .bit_xor => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const operator: Arithmetic = switch (command) {
                .bit_or => .bit_or,
                .bit_and => .bit_and,
                .bit_xor => .bit_xor,
                else => unreachable,
            };
            out.* = state.arithmetic(runtime, operator, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .bit_not => {
            out.* = state.bitNot(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .shift_left, .shift_right, .shift_right_unsigned => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const operator: ShiftOperator = switch (command) {
                .shift_left => .left,
                .shift_right => .right,
                .shift_right_unsigned => .right_unsigned,
                else => unreachable,
            };
            out.* = state.shift(runtime, operator, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .subtract, .multiply, .divide, .remainder => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const operator: Arithmetic = switch (command) {
                .subtract => .subtract,
                .multiply => .multiply,
                .divide => .divide,
                .remainder => .remainder,
                else => unreachable,
            };
            out.* = state.arithmetic(runtime, operator, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .square => {
            out.* = state.arithmetic(runtime, .multiply, value, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .power_number => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const left = state.valueToNumberRuntime(runtime, arguments.?[0]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            const right = state.valueToNumberRuntime(runtime, arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = state.numberValue(std.math.pow(f64, left, right));
        },
        .is_even, .is_odd => {
            const integer = state.parseIntBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            const expected: f64 = if (command == .is_even) 0 else 1;
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(@rem(integer, 2) == expected) };
        },
        .greater_equal, .less_equal, .less, .greater, .strict_equal, .strict_not_equal, .deep_equal, .deep_not_equal => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const comparison: Comparison = switch (command) {
                .greater_equal => .greater_equal,
                .less_equal => .less_equal,
                .less => .less,
                .greater => .greater,
                .strict_equal => .strict_equal,
                .strict_not_equal => .strict_not_equal,
                .deep_equal => .deep_equal,
                .deep_not_equal => .deep_not_equal,
                else => unreachable,
            };
            const result = state.compareValues(runtime, comparison, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(result) };
        },
        .in_range => {
            if (len < 3) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const lower = state.compareValues(runtime, .greater_equal, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            const upper = state.compareValues(runtime, .less_equal, arguments.?[0], arguments.?[2]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(lower and upper) };
        },
        .maximum, .minimum => {
            var result = state.valueToNumberRuntime(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            var has_nan = std.math.isNan(result);
            for (arguments.?[1..len]) |argument| {
                const number = state.valueToNumberRuntime(runtime, argument) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
                if (std.math.isNan(number)) {
                    has_nan = true;
                } else if (!has_nan) {
                    result = if (command == .maximum) @max(result, number) else @min(result, number);
                }
            }
            out.* = state.numberValue(if (has_nan) std.math.nan(f64) else result);
        },
        .clamp => {
            if (len < 3) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const number = state.valueToNumberRuntime(runtime, arguments.?[0]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            const minimum = state.valueToNumberRuntime(runtime, arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            const maximum = state.valueToNumberRuntime(runtime, arguments.?[2]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = state.numberValue(@min(@max(number, minimum), maximum));
        },
        .logical_or => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = if (state.valueTruthy(arguments.?[0])) arguments.?[0] else arguments.?[1];
        },
        .logical_and => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = if (state.valueTruthy(arguments.?[0])) arguments.?[1] else arguments.?[0];
        },
        .logical_not => out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(!state.valueTruthy(value)) },
        .range => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.rangeBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .empty_array => {
            out.* = runtime.createArray(&.{}) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .empty_dictionary => {
            out.* = runtime.createDictionary(&.{}) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .dictionary_keys, .hash_keys => {
            if (len < 1) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.dictionaryKeysBuiltin(runtime, value) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .hash_values => {
            if (len < 1) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.dictionaryValuesBuiltin(runtime, value) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .dictionary_remove, .hash_remove => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.dictionaryRemoveBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .dictionary_has, .hash_has => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const found = state.dictionaryHasBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(found) };
        },
        .truth_label => {
            out.* = runtime.createString(if (state.valueTruthy(value)) &.{0x771f} else &.{0x507d}) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .repeat_multiply => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.repeatMultiplyBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .unicode_length => {
            const units = state.valueUtf16Alloc(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            defer runtime.allocator.free(units);
            out.* = state.numberValue(@floatFromInt(state.codePointCount(units)));
        },
        .codepoint_find => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.numberValue(@floatFromInt(state.codePointFindBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            }));
        },
        .string_starts, .string_ends => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.stringBoundaryBuiltin(runtime, arguments.?[0], arguments.?[1], command == .string_starts) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .element_count => {
            out.* = state.numberValue(@floatFromInt(state.elementCountBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            }));
        },
        .array_join, .array_join_only => {
            const source: Value = if (len > 0) arguments.?[0] else .{};
            const separator: Value = if (len > 1) arguments.?[1] else .{};
            out.* = state.arrayJoinBuiltin(runtime, source, separator, command == .array_join_only) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .array_search => {
            const source: Value = if (len > 0) arguments.?[0] else .{};
            const needle: Value = if (len > 1) arguments.?[1] else .{};
            out.* = state.numberValue(state.arraySearchBuiltin(runtime, source, needle) catch |failure| {
                runtime.setFailure(failure);
                return;
            });
        },
        .array_sort, .array_numeric_convert, .array_numeric_sort, .array_reverse, .array_shuffle => {
            const source: Value = if (len > 0) arguments.?[0] else .{};
            out.* = state.arrayOrderingBuiltin(runtime, command, source) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .array_custom_sort, .array_function_apply, .array_map, .array_filter => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.arrayCallbackBuiltin(runtime, command, actual) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .array_insert, .array_insert_many, .array_cut, .array_take, .array_pop, .array_push, .array_clone, .array_range_copy, .reference, .array_add, .array_maximum, .array_minimum, .array_sum, .array_swap, .array_sequence, .array_fill => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.arrayMutationBuiltin(runtime, command, actual) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .table_sort, .table_numeric_sort, .table_pickup, .table_exact_pickup, .table_search, .table_column_count, .table_row_count, .table_column, .table_transpose, .table_rotate, .table_unique, .table_insert_column, .table_delete_column, .table_column_sum, .table_regexp_search, .table_regexp_pickup => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.tableBuiltin(runtime, command, actual) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .add_parsed => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.addParsedBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .sum_parsed => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.sumParsedBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .sequential_add => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.sequentialAddBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .chr => {
            out.* = state.chrBuiltin(runtime, value) catch |failure| {
                if (!runtime.has_pending_exception) runtime.setFailure(failure);
                return;
            };
        },
        .asc => {
            out.* = state.ascBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .string_insert, .string_search => {
            if (len < 3) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            if (command == .string_insert) {
                out.* = state.stringInsertBuiltin(runtime, arguments.?[0], arguments.?[1], arguments.?[2]) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
            } else {
                out.* = state.numberValue(state.stringSearchBuiltin(runtime, arguments.?[0], arguments.?[1], arguments.?[2]) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                });
            }
        },
        .append, .append_line => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.appendBuiltin(runtime, arguments.?[0], arguments.?[1], command == .append_line) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .concat_join => {
            const actual = if (arguments) |pointer| pointer[0..len] else &.{};
            out.* = state.joinBuiltin(runtime, actual) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .explode => {
            out.* = state.explodeBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .refrain, .occurrence_count => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            if (command == .refrain) {
                out.* = state.refrainBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
            } else {
                out.* = state.numberValue(@floatFromInt(state.occurrenceCountBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                }));
            }
        },
        .occurrence => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            const found = state.occurrenceBuiltin(runtime, arguments.?[0], arguments.?[1]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
            out.* = .{ .tag = @intFromEnum(Tag.boolean), .payload = @intFromBool(found) };
        },
        // LLVM lowers these side-effecting commands through lnako_aot_cut,
        // which receives the mandatory global 対象 pointer.  Keep the generic
        // dispatcher explicit so an accidental ABI mismatch fails safely.
        .cut, .cut_range => runtime.setFailure(error.CutRequiresTarget),
        .substring_mid, .substring_left, .substring_right => {
            const required: usize = if (command == .substring_mid) 3 else 2;
            if (len < required) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.substringBuiltin(runtime, command, arguments.?[0..required]) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .split_all, .split_first, .string_remove => {
            const required: usize = if (command == .string_remove) 3 else 2;
            if (len < required) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = if (command == .string_remove)
                state.stringRemoveBuiltin(runtime, arguments.?[0], arguments.?[1], arguments.?[2]) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                }
            else
                state.splitBuiltin(runtime, arguments.?[0], arguments.?[1], command == .split_first) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
        },
        .trim_both, .trim_right, .trim_left => {
            out.* = state.trimBuiltin(runtime, value, command != .trim_right, command != .trim_left) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .replace_all, .replace_first => {
            if (len < 3) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.replaceBuiltin(runtime, arguments.?[0], arguments.?[1], arguments.?[2], command == .replace_all) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .uppercase, .lowercase => {
            out.* = state.unicodeCaseBuiltin(runtime, value, command == .uppercase) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .hiragana, .katakana => {
            out.* = state.kanaOffsetBuiltin(runtime, value, command == .katakana) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .ascii_full_width, .ascii_half_width, .ascii_symbol_full_width, .ascii_symbol_half_width => {
            const to_full = command == .ascii_full_width or command == .ascii_symbol_full_width;
            const symbols = command == .ascii_symbol_full_width or command == .ascii_symbol_half_width;
            out.* = state.asciiWidthBuiltin(runtime, value, to_full, symbols) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .katakana_full_width, .katakana_half_width => {
            out.* = state.kanaWidthBuiltin(runtime, value, command == .katakana_full_width) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .full_width, .half_width => {
            out.* = state.widthBuiltin(runtime, value, command == .full_width) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .currency_format => {
            out.* = state.currencyBuiltin(runtime, value) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .zero_pad, .space_pad => {
            if (len < 2) {
                runtime.setFailure(error.InvalidArgumentCount);
                return;
            }
            out.* = state.padBuiltin(runtime, arguments.?[0], arguments.?[1], if (command == .zero_pad) '0' else ' ') catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
        .hiragana_predicate, .katakana_predicate, .digit_predicate, .number_sequence_predicate => {
            out.* = state.stringPredicateBuiltin(runtime, value, command) catch |failure| {
                runtime.setFailure(failure);
                return;
            };
        },
    }
    success = runtime.failure_epoch == start_epoch;
}
