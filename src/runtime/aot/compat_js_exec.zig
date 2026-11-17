//! `--compat-js` AOT runtime の `sys.__exec` ビルトイン命令ディスパッチャ。
//!
//! この module は `compat_js.zig` からのみ import する。通常 AOT の
//! `liblnako_runtime.a` にはリンクされず、QuickJS を含む compat 成果物だけが
//! このディスパッチ経路を持つ。`builtins.zig` / `runtime_core.zig` から
//! 逆 import してはならない（Issue #282 Unit 1）。
const std = @import("std");
const state = @import("state.zig");
const builtins = @import("builtins.zig");
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

    const command = aot_builtin.lookup(cmd_name) orelse {
        runtime.setFailure(error.UnknownCommand);
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
        else => {
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
