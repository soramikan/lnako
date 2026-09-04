const state = @import("state.zig");
const shared = @import("shared.zig");

pub const lnako_aot_function_new = state.lnako_aot_function_new;
pub const lnako_aot_function_new_named = state.lnako_aot_function_new_named;
pub const lnako_aot_function_capture = state.lnako_aot_function_capture;
pub const lnako_aot_function_call = state.lnako_aot_function_call;
pub const lnako_aot_dynamic_call = state.lnako_aot_dynamic_call;
pub const lnako_aot_native_plugin_call = state.lnako_aot_native_plugin_call;
pub const lnako_aot_native_plugin_register = state.lnako_aot_native_plugin_register;
pub const lnako_aot_dynamic_global_register = state.lnako_aot_dynamic_global_register;
