const state = @import("state.zig");
const shared = @import("shared.zig");

pub const lnako_aot_runtime_init = state.lnako_aot_runtime_init;
pub const lnako_aot_runtime_deinit = state.lnako_aot_runtime_deinit;
pub const lnako_aot_node_constants_init = state.lnako_aot_node_constants_init;
pub const lnako_aot_node_constants_init_wide = state.lnako_aot_node_constants_init_wide;
pub const lnako_aot_node_directory_constants_init = state.lnako_aot_node_directory_constants_init;
pub const lnako_aot_node_mother_path_init = state.lnako_aot_node_mother_path_init;
pub const lnako_aot_push_roots = state.lnako_aot_push_roots;
pub const lnako_aot_pop_roots = state.lnako_aot_pop_roots;
pub const lnako_aot_collect = state.lnako_aot_collect;
