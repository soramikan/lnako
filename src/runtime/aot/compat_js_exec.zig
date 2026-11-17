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

/// 命令実行が新しい失敗を残さなかった場合だけ `それ` を戻り値へ同期する。
/// インタプリタの呼び出し文が結果を `それ` に書き戻す挙動に合わせる。
fn syncSore(runtime: *Runtime, out: *Value, start_epoch: u64) void {
    if (runtime.failure_epoch != start_epoch) return;
    state.upsertDynamicGlobal(runtime, "それ", out.*) catch |err| runtime.setFailure(err);
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
    start_epoch: u64,
) void {
    if (runtime.esm_modules.items.len > 0) {
        const result = state.esmPluginBuiltin(runtime, cmd_name, arguments) catch |failure| {
            if (failure == error.UnknownCommand and runtime.native_plugin_paths.items.len > 0) {
                execCompatNativePluginBuiltin(runtime, cmd_name, arguments, out, start_epoch);
                return;
            }
            if (!runtime.has_pending_exception) runtime.setFailure(failure);
            return;
        };
        out.* = result;
        syncSore(runtime, out, start_epoch);
        return;
    }
    if (runtime.native_plugin_paths.items.len > 0) {
        execCompatNativePluginBuiltin(runtime, cmd_name, arguments, out, start_epoch);
        return;
    }
    runtime.setFailure(error.UnknownCommand);
}

fn execCompatNativePluginBuiltin(
    runtime: *Runtime,
    cmd_name: []const u8,
    arguments: []const Value,
    out: *Value,
    start_epoch: u64,
) void {
    const result = state.nativePluginBuiltin(runtime, cmd_name, arguments) catch |failure| {
        if (!runtime.has_pending_exception) runtime.setFailure(failure);
        return;
    };
    out.* = result;
    syncSore(runtime, out, start_epoch);
}

/// `sys.__exec(name, args)` のビルトイン命令ディスパッチ。Unit 1 の範囲
/// （特殊 lowering 命令・正規表現・はてな実行・ターゲット必須の主要命令・
/// 汎用命令・補助命令）を AOT ランタイムの専用 ABI へ振り分ける。
pub fn execCompatBuiltin(runtime: *Runtime, cmd_name: []const u8, arguments: []const Value, out: *Value) void {
    out.* = .{};
    const start_epoch = runtime.failure_epoch;

    // カテゴリ 1: `aot_builtin.lookup` の前段で特別に lowering される命令。
    if (std.mem.eql(u8, cmd_name, "表示") or std.mem.eql(u8, cmd_name, "表示する")) {
        var log_slot = initDisplayLogSlot(runtime) orelse return;
        defer log_slot.finish();
        const log_ptr = log_slot.bindAndPtr();
        values.lnako_aot_display_value(lastArgument(arguments) orelse &undefined_value, true, log_ptr);
        syncSore(runtime, out, start_epoch);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "連続表示")) {
        var log_slot = initDisplayLogSlot(runtime) orelse return;
        defer log_slot.finish();
        const log_ptr = log_slot.bindAndPtr();
        debug.lnako_aot_display_many(argumentsPointer(arguments), arguments.len, log_ptr);
        syncSore(runtime, out, start_epoch);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "エラー発生")) {
        debug.lnako_aot_exception_set_error_message(lastArgument(arguments) orelse &undefined_value);
        debug.lnako_aot_throw_site(0);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "JS実行")) {
        compat_js.lnako_aot_compat_js_eval(out, argumentsPointer(arguments), arguments.len);
        syncSore(runtime, out, start_epoch);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "JS関数実行")) {
        compat_js.lnako_aot_compat_js_call(out, argumentsPointer(arguments), arguments.len);
        syncSore(runtime, out, start_epoch);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "JSオブジェクト取得")) {
        compat_js.lnako_aot_compat_js_object_get(out, argumentsPointer(arguments), arguments.len);
        syncSore(runtime, out, start_epoch);
        return;
    }
    if (std.mem.eql(u8, cmd_name, "JSメソッド実行")) {
        compat_js.lnako_aot_compat_js_method_call(out, argumentsPointer(arguments), arguments.len);
        syncSore(runtime, out, start_epoch);
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
        syncSore(runtime, out, start_epoch);
        return;
    }

    // カテゴリ 6: ビルトインに無い命令は ESM / native plugin の命令として
    // 実行時に解決する。`dynamic.zig` 側は QuickJS を一切 import しないため、
    // この経路を compat 専用 module に閉じ込めても通常 AOT の分離は崩れない。
    const command = aot_builtin.lookup(cmd_name) orelse {
        execCompatPluginBuiltin(runtime, cmd_name, arguments, out, start_epoch);
        return;
    };
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
                argumentsPointer(arguments),
                arguments.len,
                @backingInt(command),
                0,
            );
            syncSore(runtime, out, start_epoch);
            return;
        },
        // カテゴリ 2: はてな実行。
        .system_hatena_execute => {
            var log_slot = initDisplayLogSlot(runtime) orelse return;
            defer log_slot.finish();
            const log_ptr = log_slot.bindAndPtr();
            debug.lnako_aot_hatena_execute(
                out,
                lastArgument(arguments),
                0,
                null,
                0,
                log_ptr,
                0,
            );
            syncSore(runtime, out, start_epoch);
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
                argumentsPointer(arguments),
                arguments.len,
                mode,
                0,
            );
            syncSore(runtime, out, start_epoch);
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
                argumentsPointer(arguments),
                arguments.len,
                @backingInt(command),
                plugin_ptr,
                namespace_ptr,
                0,
            );
            syncSore(runtime, out, start_epoch);
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
                argumentsPointer(arguments),
                arguments.len,
                @backingInt(command),
                0,
            );
            syncSore(runtime, out, start_epoch);
            return;
        },
        // カテゴリ 3: `表示ログ` を更新するデバッグ表示。
        .system_debug_display => {
            var log_slot = initDisplayLogSlot(runtime) orelse return;
            defer log_slot.finish();
            const log_ptr = log_slot.bindAndPtr();
            debug.lnako_aot_debug_display(
                out,
                lastArgument(arguments),
                0,
                null,
                0,
                log_ptr,
                0,
            );
            syncSore(runtime, out, start_epoch);
            return;
        },
        // カテゴリ 2: 圧縮解凍ツールパスの設定。
        .node_archive_tool_path_set => {
            var tool_slot = initSlot(runtime, "圧縮解凍ツールパス", state.staticStringValue("7z")) orelse return;
            defer tool_slot.finish();
            control_flow.lnako_aot_archive_tool_path_set(
                out,
                argumentsPointer(arguments),
                arguments.len,
                tool_slot.bindAndPtr(),
                0,
            );
            syncSore(runtime, out, start_epoch);
            return;
        },
        // カテゴリ 2: AJAX の既定オプション設定。
        .node_ajax_options_set => {
            var options_slot = initSlot(runtime, "AJAXオプション", state.staticStringValue("")) orelse return;
            defer options_slot.finish();
            control_flow.lnako_aot_ajax_options_set(
                out,
                argumentsPointer(arguments),
                arguments.len,
                options_slot.bindAndPtr(),
                0,
            );
            syncSore(runtime, out, start_epoch);
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
                argumentsPointer(arguments),
                arguments.len,
                onerror_slot.bindAndPtr(),
                0,
            );
            syncSore(runtime, out, start_epoch);
            return;
        },
        // カテゴリ 2: 標準入力取得時のコールバック（同一ターンで同期実行）。
        .node_stdin_callback => {
            var target_slot = initSlot(runtime, "対象", .{}) orelse return;
            defer target_slot.finish();
            control_flow.lnako_aot_node_stdin_callback_call(
                out,
                target_slot.bindAndPtr(),
                argumentsPointer(arguments),
                arguments.len,
                @backingInt(command),
                0,
            );
            syncSore(runtime, out, start_epoch);
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
                argumentsPointer(arguments),
                arguments.len,
                @backingInt(command),
                0,
            );
            syncSore(runtime, out, start_epoch);
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
                    argumentsPointer(arguments),
                    arguments.len,
                    @backingInt(command),
                    0,
                );
            } else {
                out.* = state.timerBuiltin(runtime, command, arguments, null) catch |failure| {
                    runtime.setFailure(failure);
                    return;
                };
            }
            syncSore(runtime, out, start_epoch);
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
                    argumentsPointer(arguments),
                    arguments.len,
                    @backingInt(command),
                    0,
                );
            } else {
                out.* = state.promiseAotBuiltin(runtime, command, arguments, so_ptr, null) catch |failure| {
                    if (!runtime.has_pending_exception) runtime.setFailure(failure);
                    return;
                };
            }
            syncSore(runtime, out, start_epoch);
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
                    argumentsPointer(arguments),
                    arguments.len,
                    @backingInt(command),
                    0,
                );
                syncSore(runtime, out, start_epoch);
                return;
            }
            // カテゴリ 2: 圧縮解凍の実行命令。
            if (state.isArchiveCommand(command)) {
                var tool_slot = initSlot(runtime, "圧縮解凍ツールパス", state.staticStringValue("7z")) orelse return;
                defer tool_slot.finish();
                control_flow.lnako_aot_archive_call(
                    out,
                    tool_slot.bindAndPtr(),
                    argumentsPointer(arguments),
                    arguments.len,
                    @backingInt(command),
                    0,
                );
                syncSore(runtime, out, start_epoch);
                return;
            }
            // カテゴリ 3: 同期ファイル操作。コピー既定動作は可変グローバル。
            if (state.isNodeFileOperationCommand(command)) {
                var mode_slot = initSlot(runtime, "ファイルコピーデフォルト動作", state.staticStringValue("上書禁止")) orelse return;
                defer mode_slot.finish();
                control_flow.lnako_aot_file_operation_call(
                    out,
                    mode_slot.bindAndPtr(),
                    argumentsPointer(arguments),
                    arguments.len,
                    @backingInt(command),
                    0,
                );
                syncSore(runtime, out, start_epoch);
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
                        argumentsPointer(arguments),
                        arguments.len,
                        @backingInt(command),
                        0,
                    );
                } else {
                    out.* = state.nodeFileCallbackBuiltin(runtime, null, command, arguments) catch |failure| {
                        runtime.setFailure(failure);
                        return;
                    };
                }
                syncSore(runtime, out, start_epoch);
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
                    argumentsPointer(arguments),
                    arguments.len,
                    @backingInt(command),
                    0,
                );
                if (method_slot.static_slot == null or get_slot.static_slot == null or
                    post_slot.static_slot == null or files_slot.static_slot == null)
                {
                    runtime.http_globals = prev_http_globals;
                }
                syncSore(runtime, out, start_epoch);
                return;
            }
            // カテゴリ 4: 汎用 call site が処理できる命令。
            if (!aot_builtin.hasGenericCallSiteDispatch(command)) {
                runtime.setFailure(error.UnknownCommand);
                return;
            }
            builtins.lnako_aot_builtin_call_site(
                out,
                argumentsPointer(arguments),
                arguments.len,
                @backingInt(command),
                0,
            );
            syncSore(runtime, out, start_epoch);
            return;
        },
    }
}
