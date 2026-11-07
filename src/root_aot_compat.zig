const root_aot = @import("root_aot.zig");
const compat_js = @import("runtime/aot/compat_js.zig");

// 通常AOT runtimeのkeepaliveをそのまま含め、compat専用ABIだけを追加で
// 参照する。QuickJS bridgeの実体はbuild.zigがこのmoduleへリンクする。
comptime {
    _ = root_aot;
    _ = compat_js;
}

export fn lnako_aot_compat_runtime_keepalive() void {
    _ = compat_js.lnako_aot_compat_js_eval;
    _ = compat_js.lnako_aot_compat_esm_register;
    _ = compat_js.lnako_aot_compat_deinit;
}

test {
    _ = root_aot;
    _ = compat_js;
}
