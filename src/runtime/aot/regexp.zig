const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const regexp = shared.regexp;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;

const RegexpCallResult = struct { value: Value, captures: ?Value = null };

pub fn regexpCommandName(command: aot_builtin.Command) ?[]const u8 {
    return switch (command) {
        .regexp_match => "正規表現マッチ",
        .regexp_extract => "正規表現抽出",
        .regexp_replace => "正規表現置換",
        .regexp_split => "正規表現区切",
        else => null,
    };
}

pub fn setRegexpCompileFailureMessage(runtime: *Runtime, specification: []const u16, default_global: bool, failure: anyerror) !void {
    const message = try regexp.compileFailureMessageAlloc(runtime.allocator, specification, default_global, failure) orelse return;
    defer runtime.allocator.free(message);
    runtime.setFailureText(message);
}

pub fn regexpBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !RegexpCallResult {
    _ = regexpCommandName(command) orelse return error.UnknownCommand;
    const required: usize = if (command == .regexp_replace) 3 else 2;
    if (arguments.len < required) return error.InvalidArgumentCount;

    var rooted = [_]Value{ arguments[0], arguments[1], if (arguments.len > 2) arguments[2] else .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &rooted, rooted.len);
    defer runtime.popRoots(&frame);

    const source_units = try valueUtf16Alloc(runtime, rooted[0]);
    defer runtime.allocator.free(source_units);
    const pattern_units = try valueUtf16Alloc(runtime, rooted[1]);
    defer runtime.allocator.free(pattern_units);
    var compiled = regexp.compilePattern(runtime.allocator, pattern_units, true) catch |failure| {
        try setRegexpCompileFailureMessage(runtime, pattern_units, true, failure);
        return failure;
    };
    defer compiled.deinit();

    if (command == .regexp_replace) {
        const replacement_units = try valueUtf16Alloc(runtime, rooted[2]);
        defer runtime.allocator.free(replacement_units);
        const output_units = try regexp.replaceUnits(runtime.allocator, source_units, replacement_units, &compiled);
        defer runtime.allocator.free(output_units);
        rooted[3] = try runtime.createString(output_units);
        return .{ .value = rooted[3] };
    }

    if (command == .regexp_extract or command == .regexp_split) compiled.flags.global = true;
    const matches = try regexp.findMatches(runtime.allocator, source_units, &compiled);
    defer runtime.allocator.free(matches);
    rooted[3] = try runtime.createArray(&.{});

    if (command == .regexp_match) {
        if (matches.len == 0) return .{ .value = .{ .tag = @intFromEnum(Tag.null_value) }, .captures = rooted[3] };
        if (!compiled.flags.global) {
            for (matches[0].captures[0..compiled.capture_count]) |span| {
                const item: Value = if (span.matched) try runtime.createString(source_units[span.start..span.end]) else .{};
                try rooted[3].object().?.payload.array.append(runtime.allocator, item);
            }
            rooted[4] = try runtime.createString(source_units[matches[0].span.start..matches[0].span.end]);
            return .{ .value = rooted[4], .captures = rooted[3] };
        }
        rooted[4] = try runtime.createArray(&.{});
        for (matches) |match| {
            const item = try runtime.createString(source_units[match.span.start..match.span.end]);
            try rooted[4].object().?.payload.array.append(runtime.allocator, item);
        }
        return .{ .value = rooted[4], .captures = rooted[3] };
    }

    if (command == .regexp_extract) {
        rooted[4] = try runtime.createArray(&.{});
        for (matches) |match| {
            var has_named = false;
            for (compiled.capture_names[0..compiled.capture_count]) |capture_name| if (capture_name != null) {
                has_named = true;
                break;
            };
            if (has_named) {
                rooted[5] = try runtime.createDictionary(&.{});
                for (compiled.capture_names[0..compiled.capture_count], 0..) |capture_name, index| if (capture_name) |key_units| {
                    rooted[6] = if (match.captures[index].matched) try runtime.createString(source_units[match.captures[index].start..match.captures[index].end]) else .{};
                    rooted[7] = try runtime.createString(key_units);
                    try rooted[5].object().?.payload.dictionary.append(runtime.allocator, .{ .key = rooted[7], .value = rooted[6] });
                    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[6]);
                };
                try rooted[3].object().?.payload.array.append(runtime.allocator, rooted[5]);
            } else {
                rooted[5] = try runtime.createArray(&.{});
                if (compiled.capture_count == 0) {
                    rooted[6] = try runtime.createString(source_units[match.span.start..match.span.end]);
                    try rooted[5].object().?.payload.array.append(runtime.allocator, rooted[6]);
                    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[6]);
                } else for (match.captures[0..compiled.capture_count]) |span| {
                    rooted[6] = if (span.matched) try runtime.createString(source_units[span.start..span.end]) else .{};
                    try rooted[5].object().?.payload.array.append(runtime.allocator, rooted[6]);
                    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[6]);
                }
                try rooted[3].object().?.payload.array.append(runtime.allocator, rooted[5]);
            }
        }
        return .{ .value = rooted[4], .captures = rooted[3] };
    }

    // String.split(RegExp) always uses global matching and includes captures.
    rooted[4] = rooted[3];
    var cursor: usize = 0;
    for (matches) |match| {
        if (match.span.start == match.span.end and (match.span.start == 0 or match.span.start == source_units.len or match.span.start == cursor)) continue;
        rooted[5] = try runtime.createString(source_units[cursor..match.span.start]);
        try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[5]);
        for (match.captures[0..compiled.capture_count]) |span| {
            rooted[5] = if (span.matched) try runtime.createString(source_units[span.start..span.end]) else .{};
            try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[5]);
        }
        cursor = match.span.end;
    }
    rooted[5] = try runtime.createString(source_units[cursor..]);
    try rooted[4].object().?.payload.array.append(runtime.allocator, rooted[5]);
    if (source_units.len == 0 and matches.len > 0) rooted[4].object().?.payload.array.clearRetainingCapacity();
    return .{ .value = rooted[4] };
}
