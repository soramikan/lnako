const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const builtin = shared.builtin;
const error_message = shared.error_message;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const numberValue = aot_state.numberValue;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const staticStringValue = aot_state.staticStringValue;
const putchar = aot_state.putchar;
const writeBytes = aot_state.writeBytes;
const arrayItems = aot_state.arrayItems;
const installAotInterrupt = aot_state.installAotInterrupt;
const debugDisplayBuiltin = aot_state.debugDisplayBuiltin;
const lnako_aot_builtin_call_site = aot_state.lnako_aot_builtin_call_site;
const stringUtf8Alloc = aot_state.stringUtf8Alloc;
const isString = aot_state.isString;
const valueTruthy = aot_state.valueTruthy;
const invokeAotCallback = aot_state.invokeAotCallback;
const resolveAotCallback = aot_state.resolveAotCallback;
const currentTimeMilliseconds = aot_state.currentTimeMilliseconds;
const runtimeUtf8String = aot_state.runtimeUtf8String;
const runtimeUtf8StringLossy = aot_state.runtimeUtf8StringLossy;
const dynamicInterpreterState = aot_state.dynamicInterpreterState;

pub fn writeUtf16(units: []const u16, newline: bool) void {
    var index: usize = 0;
    while (index < units.len) {
        const first = units[index];
        var codepoint: u21 = undefined;
        if (first >= 0xd800 and first <= 0xdbff and index + 1 < units.len and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) {
            const second = units[index + 1];
            codepoint = @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
            index += 2;
        } else {
            codepoint = if (first >= 0xd800 and first <= 0xdfff) 0xfffd else @intCast(first);
            index += 1;
        }
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch unreachable;
        for (encoded[0..length]) |byte| _ = putchar(byte);
    }
    if (newline) _ = putchar('\n');
}

pub fn valueUtf8LossyAlloc(runtime: *Runtime, value: Value) ![]u8 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return utf16UnitsToUtf8LossyAlloc(runtime.allocator, units);
}

pub fn utf16UnitsToUtf8LossyAlloc(allocator: std.mem.Allocator, units: []const u16) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < units.len) {
        const first = units[index];
        var codepoint: u21 = undefined;
        if (first >= 0xd800 and first <= 0xdbff and index + 1 < units.len and units[index + 1] >= 0xdc00 and units[index + 1] <= 0xdfff) {
            const second = units[index + 1];
            codepoint = @intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (@as(u32, second) - 0xdc00));
            index += 2;
        } else {
            codepoint = if (first >= 0xd800 and first <= 0xdfff) 0xfffd else @intCast(first);
            index += 1;
        }
        var encoded: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &encoded) catch return error.InvalidUnicodeScalar;
        try output.appendSlice(allocator, encoded[0..length]);
    }
    return output.toOwnedSlice(allocator);
}

pub fn appendDisplayLog(runtime: *Runtime, display_log: ?*Value, line: []const u8) !void {
    const pointer = display_log orelse return;
    const current = try valueUtf8LossyAlloc(runtime, pointer.*);
    defer runtime.allocator.free(current);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);
    try output.appendSlice(runtime.allocator, current);
    try output.appendSlice(runtime.allocator, line);
    try output.append(runtime.allocator, '\n');
    pointer.* = try runtimeUtf8String(runtime, output.items);
}

pub fn emitDisplayLine(runtime: *Runtime, text: []const u8, newline: bool, display_log: ?*Value) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(runtime.allocator);
    try output.appendSlice(runtime.allocator, runtime.print_pool.items);
    try output.appendSlice(runtime.allocator, text);
    runtime.print_pool.clearRetainingCapacity();
    writeBytes(output.items, newline);
    if (newline) try appendDisplayLog(runtime, display_log, output.items);
}

pub fn displayValue(runtime: *Runtime, value: Value, newline: bool, display_log: ?*Value) !void {
    const text = try valueUtf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(text);
    try emitDisplayLine(runtime, text, newline, display_log);
}

pub fn continueDisplayValue(runtime: *Runtime, value: Value) !void {
    const text = try valueUtf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(text);
    try runtime.print_pool.appendSlice(runtime.allocator, text);
}

pub fn joinValuesUtf8Alloc(runtime: *Runtime, values: []const Value) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(runtime.allocator);
    for (values) |value| {
        const text = try valueUtf8LossyAlloc(runtime, value);
        defer runtime.allocator.free(text);
        try output.appendSlice(runtime.allocator, text);
    }
    return output.toOwnedSlice(runtime.allocator);
}

pub fn displayMany(runtime: *Runtime, values: []const Value, display_log: ?*Value) !void {
    const text = try joinValuesUtf8Alloc(runtime, values);
    defer runtime.allocator.free(text);
    try emitDisplayLine(runtime, text, true, display_log);
}

pub fn configureHatenaBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    runtime.hatena_callbacks.clearRetainingCapacity();
    if (arguments.len == 0) return .{};

    var setting = arguments[arguments.len - 1];
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&setting), 1);
    defer runtime.popRoots(&frame);

    switch (@as(Tag, @enumFromInt(setting.tag))) {
        .function, .static_utf8_string, .utf16_string => try runtime.hatena_callbacks.append(runtime.allocator, setting),
        .array => {
            const items = try arrayItems(setting);
            for (items.items) |item| {
                if (!isString(item)) return error.InvalidHatenaCallback;
                const name = try stringUtf8Alloc(runtime, item);
                defer runtime.allocator.free(name);
                if (std.mem.startsWith(u8, name, "JS:")) return error.JavaScriptCompatibilityRequired;
                try runtime.hatena_callbacks.append(runtime.allocator, item);
            }
        },
        else => {},
    }
    return .{};
}

pub fn configureInterruptBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len == 0) return error.InvalidArgumentCount;

    var callback = arguments[0];
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&callback), 1);
    defer runtime.popRoots(&frame);
    callback = try resolveAotCallback(runtime, callback);
    runtime.interrupt_callback = callback;
    try installAotInterrupt();
    return .{};
}

pub fn invokeHatenaNamedCallback(
    runtime: *Runtime,
    name_value: Value,
    parameter: Value,
    line: u64,
    source_path: []const u8,
    display_log: ?*Value,
) !Value {
    const name = try stringUtf8Alloc(runtime, name_value);
    defer runtime.allocator.free(name);
    if (std.mem.eql(u8, name, "表示") or std.mem.eql(u8, name, "表示する")) {
        try displayValue(runtime, parameter, true, display_log);
        return .{};
    }
    if (std.mem.eql(u8, name, "連続表示")) {
        try displayMany(runtime, &.{parameter}, display_log);
        return .{};
    }
    const command = aot_builtin.lookup(name) orelse return error.UnknownFunction;
    if (command == .system_debug_display) {
        try debugDisplayBuiltin(runtime, parameter, line, source_path, display_log);
        return .{};
    }
    var argument = parameter;
    var result = Value{};
    const start_epoch = runtime.failure_epoch;
    lnako_aot_builtin_call_site(&result, @ptrCast(&argument), 1, @intFromEnum(command), 0);
    if (runtime.has_pending_exception and runtime.failure_epoch != start_epoch) return error.CallbackExecutionFailed;
    return result;
}

pub fn invokeHatenaCallbacks(
    runtime: *Runtime,
    parameter: Value,
    line: u64,
    source_path: []const u8,
    display_log: ?*Value,
) !Value {
    var roots = [_]Value{ parameter, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    for (runtime.hatena_callbacks.items) |callback| {
        roots[1] = if (callback.tag == @intFromEnum(Tag.function))
            try invokeAotCallback(runtime, callback, @ptrCast(&roots[0]), 1)
        else if (isString(callback))
            try invokeHatenaNamedCallback(runtime, callback, roots[0], line, source_path, display_log)
        else
            return error.InvalidHatenaCallback;
        roots[0] = roots[1];
    }
    return roots[0];
}

pub fn writeAllValues(runtime: *Runtime, values: []const Value) !void {
    for (values) |value| {
        const text = try valueUtf8LossyAlloc(runtime, value);
        defer runtime.allocator.free(text);
        writeBytes(text, false);
    }
    writeBytes("", true);
}

pub fn isStdioCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .stdio_continue_display, .stdio_continue_display_many, .stdio_clear_log, .stdio_write_all => true,
        else => false,
    };
}

pub fn isNodeProcessCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_process_run_wait, .node_process_run, .node_process_start, .node_process_run_wait_output, .node_process_start_callback, .node_open_external_browser, .node_open_external_explorer => true,
        else => false,
    };
}

pub fn isNodeHttpCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_ajax_send_callback, .node_ajax_receive_callback, .node_get_send_callback, .node_post_send_callback, .node_post_form_send_callback, .node_ajax_response_promise, .node_http_response_promise, .node_get_response_promise, .node_post_response_promise, .node_post_form_response_promise, .node_ajax_content_get, .node_ajax_receive, .node_post_send, .node_post_form_send, .node_ajax_text_get, .node_ajax_json_get, .node_ajax_binary_get, .node_discord_send, .node_discord_file_send => true,
        else => false,
    };
}

pub fn isArchiveCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .node_archive_extract, .node_archive_extract_callback, .node_archive_create, .node_archive_create_callback => true,
        else => false,
    };
}

pub fn isPluginManagementCommand(command: aot_builtin.Command) bool {
    return switch (command) {
        .plugin_name_set, .namespace_set, .namespace_pop => true,
        else => false,
    };
}

pub fn stdioBuiltin(runtime: *Runtime, command: aot_builtin.Command, values: []const Value, display_log: ?*Value) !void {
    switch (command) {
        .stdio_continue_display => try continueDisplayValue(runtime, if (values.len > 0) values[values.len - 1] else .{}),
        .stdio_continue_display_many => {
            const text = try joinValuesUtf8Alloc(runtime, values);
            defer runtime.allocator.free(text);
            try runtime.print_pool.appendSlice(runtime.allocator, text);
        },
        .stdio_clear_log => {
            if (display_log) |pointer| pointer.* = try runtimeUtf8String(runtime, "");
        },
        .stdio_write_all => try writeAllValues(runtime, values),
        else => return error.UnknownCommand,
    }
}

pub fn pluginManagementArgument(runtime: *Runtime, values: []const Value) !Value {
    var source = if (values.len > 0) values[values.len - 1] else Value{};
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&source), 1);
    defer runtime.popRoots(&frame);
    const units = try valueUtf16Alloc(runtime, source);
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

pub fn pluginManagementBuiltin(
    runtime: *Runtime,
    command: aot_builtin.Command,
    values: []const Value,
    plugin_name: *Value,
    namespace: *Value,
) !void {
    switch (command) {
        .plugin_name_set => plugin_name.* = try pluginManagementArgument(runtime, values),
        .namespace_set => {
            var converted = try pluginManagementArgument(runtime, values);
            var frame = RootFrame{};
            runtime.pushRoots(&frame, @ptrCast(&converted), 1);
            defer runtime.popRoots(&frame);
            try runtime.namespace_stack.append(runtime.allocator, .{
                .namespace = namespace.*,
                .plugin_name = plugin_name.*,
            });
            namespace.* = converted;
        },
        .namespace_pop => if (runtime.namespace_stack.pop()) |previous| {
            namespace.* = previous.namespace;
            plugin_name.* = previous.plugin_name;
        },
        else => return error.UnknownCommand,
    }
}
