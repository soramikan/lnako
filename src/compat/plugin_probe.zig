//! ESM plugin の実登録収集（Issue #52）。`lnako check --load-plugins
//! --compat-js` 専用で、QuickJS で plugin module を評価し
//! `__lnako_commands` の key 一覧を収集する。
//!
//! 評価は QuickJS engine 内に閉じる。Effects（builtin 呼出し・global
//! 書き込み）は拒否する — plugin の top-level／`初期化` がなでしこ側へ
//! 依存する構成は収集不能（load_failed）として扱う。key は shim 側が
//! namespace 付き登録を `{ns}__{名}` へ展開済みのため、そのまま公開名と
//! して比較できる。

const std = @import("std");
const quickjs = @import("../compat/quickjs.zig");
const value_mod = @import("../runtime/value.zig");

const Allocator = std.mem.Allocator;

/// plugin module を評価して登録された command key 一覧を返す。
/// `path` は module 登録名（moduleFilename 規約で `/` 正規化される）。
pub fn collectEsmCommandNames(
    arena: Allocator,
    module_source: []const u8,
    namespace: []const u8,
) (error{ LoadFailed, OutOfMemory })![]const []const u8 {
    var runtime = value_mod.Runtime.init(arena);
    defer runtime.deinit();
    var state = quickjs.State.init(true);
    defer state.deinit();

    const module_path = try std.fmt.allocPrint(arena, "plugin-probe/{s}.mjs", .{namespace});
    const modules = [_]@import("../ir/nako_ir.zig").JavaScriptModule{
        .{
            .path = module_path,
            .source = module_source,
            .is_plugin = true,
            .namespaces = if (namespace.len > 0)
                try arena.dupe([]const u8, &[_][]const u8{namespace})
            else
                &.{},
        },
    };
    quickjs.installModules(&runtime, &state, &modules, effects()) catch
        return error.LoadFailed;
    return registeredKeys(arena, &state);
}

/// `__lnako_commands` の key 一覧を arena へ写す。
fn registeredKeys(arena: Allocator, state: *quickjs.State) (error{ LoadFailed, OutOfMemory })![]const []const u8 {
    const names = (quickjs.registeredCommandKeys(state, arena) catch return error.LoadFailed) orelse
        return error.LoadFailed;
    return names;
}

fn effects() quickjs.Effects {
    return .{
        .context = undefined,
        .invokeFn = rejectInvoke,
        .resolveFn = rejectResolve,
        .getGlobalFn = rejectGetGlobal,
        .setGlobalFn = rejectSetGlobal,
        .execFn = rejectExec,
    };
}

fn rejectInvoke(_: *anyopaque, _: value_mod.Value, _: []const value_mod.Value) anyerror!value_mod.Value {
    return error.PluginProbeInvocationRejected;
}

fn rejectResolve(_: *anyopaque, _: []const u8) anyerror!value_mod.Value {
    return error.PluginProbeInvocationRejected;
}

fn rejectGetGlobal(_: *anyopaque, _: []const u8) ?value_mod.Value {
    return null;
}

fn rejectSetGlobal(_: *anyopaque, _: []const u8, _: value_mod.Value) anyerror!void {
    return error.PluginProbeInvocationRejected;
}

fn rejectExec(_: *anyopaque, _: []const u8, _: []const value_mod.Value) anyerror!value_mod.Value {
    return error.PluginProbeInvocationRejected;
}
