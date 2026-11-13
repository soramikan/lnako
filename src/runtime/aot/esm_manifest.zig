//! compat ESM manifest の module を AOT runtime へ保持する。
//!
//! 埋め込み interpreter は初期化時に `installModules` を実行し、plugin 命令を
//! `__lnako_commands` へ登録する。その入力となる module をここで
//! `Runtime.esm_modules` へ写す（`compat_js.zig` の ABI 面から切り離す）。
const std = @import("std");
const state = @import("state.zig");
const quickjs_compat = @import("../../compat/quickjs.zig");

/// ESM plugin の登録 shim（`__lnako_registerPlugin` 等）を含む bootstrap を
/// engine へ評価する。interpreter 側と同じ JS 環境を共有する。
/// 関数ポインタは呼出し側の生型を受けるため `anyopaque` で受ける。
pub fn installBootstrap(
    engine: anytype,
    eval_fn: anytype,
    free_fn: anytype,
) bool {
    const source = quickjs_compat.bootstrapSource;
    const result = eval_fn(engine, source.ptr, source.len, "<lnako-bootstrap>") orelse return false;
    free_fn(result);
    return true;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const item = value orelse return null;
    return switch (item) {
        .string => |text| text,
        else => null,
    };
}

/// manifest の module を AOT runtime へ保持する。埋め込み interpreter が
/// 初期化時に `installModules` で plugin 命令を登録するために必要。
pub fn collectEsmModules(runtime: *state.Runtime, modules: []const std.json.Value) void {
    const allocator = runtime.allocator;
    for (modules) |value| {
        const object = switch (value) {
            .object => |item| item,
            else => continue,
        };
        const path = jsonString(object.get("path")) orelse continue;
        const source = jsonString(object.get("source")) orelse continue;
        const is_plugin = switch (object.get("is_plugin") orelse continue) {
            .bool => |flag| flag,
            else => continue,
        };
        const namespace_list = switch (object.get("namespaces") orelse continue) {
            .array => |array| array.items,
            else => continue,
        };
        // 確保失敗は黙って切り詰めず、登録自体を失敗させる（不完全な
        // module 一覧で interpreter を初期化しない）。
        const namespaces = allocator.alloc([]const u8, namespace_list.len) catch {
            runtime.setFailure(error.OutOfMemory);
            return;
        };
        for (namespace_list, namespaces) |item, *slot| {
            slot.* = allocator.dupe(u8, jsonString(item) orelse "") catch {
                runtime.setFailure(error.OutOfMemory);
                return;
            };
        }
        const alias_list = switch (object.get("bare_aliases") orelse continue) {
            .array => |array| array.items,
            else => continue,
        };
        const aliases = allocator.alloc([]const u8, alias_list.len) catch {
            runtime.setFailure(error.OutOfMemory);
            return;
        };
        for (alias_list, aliases) |item, *slot| {
            slot.* = allocator.dupe(u8, jsonString(item) orelse "") catch {
                runtime.setFailure(error.OutOfMemory);
                return;
            };
        }
        const package_root = jsonString(object.get("package_root"));
        runtime.esm_modules.append(allocator, .{
            .path = allocator.dupe(u8, path) catch {
                runtime.setFailure(error.OutOfMemory);
                return;
            },
            .source = allocator.dupe(u8, source) catch {
                runtime.setFailure(error.OutOfMemory);
                return;
            },
            .is_plugin = is_plugin,
            .package_root = if (package_root) |root| allocator.dupe(u8, root) catch {
                runtime.setFailure(error.OutOfMemory);
                return;
            } else null,
            .namespaces = namespaces,
            .bare_aliases = aliases,
        }) catch {
            runtime.setFailure(error.OutOfMemory);
            return;
        };
    }
}

test "compat AOT runtimeは未知schemaのmanifestを解釈せず失敗する" {
    if (!@import("build_options").quickjs_enabled) return error.SkipZigTest;
    var runtime = state.Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const manifest =
        \\{"schema":999,"modules":[],"packages":[]}
    ;
    @import("compat_js.zig").lnako_aot_compat_esm_register(manifest.ptr, manifest.len);
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    @import("compat_js.zig").lnako_aot_compat_deinit();
}
