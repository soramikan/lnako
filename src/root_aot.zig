const aot = @import("runtime/aot.zig");

// AOTランタイムライブラリとしてコンパイルした際、root_aot.zigが
// 実質的なランタイム呼び出しを持たないと、ZigはAOT ABIエクスポートを
// コード生成対象から落としてしまい、ネイティブリンクで未定義シンボル
// エラーになる。aot.zigが再エクスポートするすべてのlnako_aot_* ABI関数を
// 参照するダミー関数をエクスポートして、実体がオブジェクトに残るようにする。
export fn lnako_aot_runtime_keepalive() void {
    _ = aot.lnako_aot_function_new;
    _ = aot.lnako_aot_function_new_named;
    _ = aot.lnako_aot_function_capture;
    _ = aot.lnako_aot_function_call;
    _ = aot.lnako_aot_dynamic_call;
    _ = aot.lnako_aot_native_plugin_call;
    _ = aot.lnako_aot_native_plugin_register;
    _ = aot.lnako_aot_dynamic_global_register;
    _ = aot.lnako_aot_regexp_call;
    _ = aot.lnako_aot_regexp_call_site;
    _ = aot.lnako_aot_builtin_call;
    _ = aot.lnako_aot_builtin_call_site;
    _ = aot.lnako_aot_runtime_drain_events;
    _ = aot.lnako_aot_http_server_init;
    _ = aot.lnako_aot_http_server_call;
    _ = aot.lnako_aot_stdio_call;
    _ = aot.lnako_aot_plugin_management_call;
    _ = aot.lnako_aot_archive_tool_path_set;
    _ = aot.lnako_aot_archive_call;
    _ = aot.lnako_aot_ajax_options_set;
    _ = aot.lnako_aot_ajax_onerror_set;
    _ = aot.lnako_aot_node_http_call;
    _ = aot.lnako_aot_timer_call_site;
    _ = aot.lnako_aot_promise_call_site;
    _ = aot.lnako_aot_file_operation_call;
    _ = aot.lnako_aot_node_process_call;
    _ = aot.lnako_aot_node_file_callback_call;
    _ = aot.lnako_aot_node_stdin_callback_call;
    _ = aot.lnako_aot_global_read_site;
    _ = aot.lnako_aot_global_write_site;
    _ = aot.lnako_aot_literal_site;
    _ = aot.lnako_aot_dispatch_display_begin;
    _ = aot.lnako_aot_dispatch_display_begin_with_epoch;
    _ = aot.lnako_aot_dispatch_result;
    _ = aot.lnako_aot_throw_site;
    _ = aot.lnako_aot_exception_set;
    _ = aot.lnako_aot_exception_set_error_message;
    _ = aot.lnako_aot_exception_pending;
    _ = aot.lnako_aot_exception_take;
    _ = aot.lnako_aot_exception_abort;
    _ = aot.lnako_aot_print_utf16;
    _ = aot.lnako_aot_print_number;
    _ = aot.lnako_aot_print_bigint;
    _ = aot.lnako_aot_print_collection;
    _ = aot.lnako_aot_display_value;
    _ = aot.lnako_aot_debug_display;
    _ = aot.lnako_aot_hatena_execute;
    _ = aot.lnako_aot_display_many;
    _ = aot.lnako_aot_debug_breakpoint_wait_call;
    _ = aot.lnako_aot_string_new;
    _ = aot.lnako_aot_bigint_new;
    _ = aot.lnako_aot_bigint_truthy;
    _ = aot.lnako_aot_arithmetic;
    _ = aot.lnako_aot_compare;
    _ = aot.lnako_aot_shift;
    _ = aot.lnako_aot_concat;
    _ = aot.lnako_aot_increment;
    _ = aot.lnako_aot_array_new;
    _ = aot.lnako_aot_dictionary_new;
    _ = aot.lnako_aot_caniuse_agents_new;
    _ = aot.lnako_aot_era_data_new;
    _ = aot.lnako_aot_index_get;
    _ = aot.lnako_aot_index_set;
    _ = aot.lnako_aot_destructure_get;
    _ = aot.lnako_aot_iterator_new;
    _ = aot.lnako_aot_iterator_has_next;
    _ = aot.lnako_aot_iterator_next;
    _ = aot.lnako_aot_binding_cell_new;
    _ = aot.lnako_aot_binding_cell_value;
    _ = aot.lnako_aot_cut;
    _ = aot.lnako_aot_cut_site;
    _ = aot.lnako_aot_runtime_init;
    _ = aot.lnako_aot_runtime_deinit;
    _ = aot.lnako_aot_node_constants_init;
    _ = aot.lnako_aot_node_constants_init_wide;
    _ = aot.lnako_aot_node_directory_constants_init;
    _ = aot.lnako_aot_node_mother_path_init;
    _ = aot.lnako_aot_push_roots;
    _ = aot.lnako_aot_pop_roots;
    _ = aot.lnako_aot_collect;
}

comptime {
    _ = aot;
}
