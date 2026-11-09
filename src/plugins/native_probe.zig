//! native plugin の実登録収集（Issue #52）。`lnako check --load-plugins`
//! 専用で、dlopen と `initialize` を実行して `registerCommand` された
//! command の公開名・助詞・arity を収集する。実行時 dispatch は行わない
//! ため、収集後に `deinitialize`→library close まで確実に回収する。
//!
//! `plugins/native.zig` の登録・検証経路（ABI・名前・重複検査）を再利用し、
//! 収集専用の小さな State を持つ。Effects（builtin 呼出し）は拒否する —
//! 登録中に builtin を呼ぶ plugin は収集不能（load_failed）として扱う。

const std = @import("std");
const plugin_native = @import("native.zig");
const nako_ir = @import("../ir/nako_ir.zig");
const Runtime = plugin_native.Runtime;

const Allocator = std.mem.Allocator;

/// 1 plugin 分の収集結果。文字列は `arena` が所有する。
pub const Collected = struct {
    /// 公開名。namespace 付き登録は `{ns}__{name}`。
    names: []const []const u8,
    /// `names` と対応する生の particles 文字列。
    particles: []const []const u8,
    minimum_arguments: []const usize,
    maximum_arguments: []const usize,
};

/// native plugin をロードして登録 command を収集する。
/// `namespace` は package import 由来の公開 namespace（空は無修飾）。
pub fn collect(
    arena: Allocator,
    artifact_path: []const u8,
    namespace: []const u8,
) (error{ LoadFailed, OutOfMemory })!Collected {
    var runtime = Runtime.init(arena);
    defer runtime.deinit();
    var state = plugin_native.State.init();
    defer state.deinit();

    const packages = [_]nako_ir.NativePluginPackage{
        .{ .path = artifact_path, .namespace = namespace },
    };
    plugin_native.install(&runtime, &state, &[_][]const u8{artifact_path}, &packages, effects()) catch
        return error.LoadFailed;

    // 収集した command を arena へ写す（State.deinit が所有メモリを解放
    // するため）。公開名は namespace 付き登録を `{ns}__{name}` へ展開する。
    const commands = plugin_native.registeredCommands(&state);
    const names = try arena.alloc([]const u8, commands.len);
    const particles = try arena.alloc([]const u8, commands.len);
    const minimums = try arena.alloc(usize, commands.len);
    const maximums = try arena.alloc(usize, commands.len);
    for (commands, 0..) |command, index| {
        if (command.namespace) |ns| {
            names[index] = try std.fmt.allocPrint(arena, "{s}__{s}", .{ ns, command.name });
        } else {
            names[index] = try arena.dupe(u8, command.name);
        }
        particles[index] = try arena.dupe(u8, command.particles);
        minimums[index] = command.minimum_arguments;
        maximums[index] = command.maximum_arguments;
    }
    return .{
        .names = names,
        .particles = particles,
        .minimum_arguments = minimums,
        .maximum_arguments = maximums,
    };
}

fn effects() plugin_native.Effects {
    return .{
        .context = undefined,
        .invokeFn = rejectInvoke,
        .execFn = rejectExec,
    };
}

fn rejectInvoke(_: *anyopaque, _: plugin_native.Value, _: []const plugin_native.Value) anyerror!plugin_native.Value {
    return error.PluginProbeInvocationRejected;
}

fn rejectExec(_: *anyopaque, _: []const u8, _: []const plugin_native.Value) anyerror!plugin_native.Value {
    return error.PluginProbeInvocationRejected;
}
