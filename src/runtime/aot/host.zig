const std = @import("std");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const builtin = shared.builtin;
const aot_builtin = shared.aot_builtin;
const error_message = shared.error_message;
const number_mod = shared.number_mod;
const string_mod = shared.string_mod;
const system_constant = shared.system_constant;
const builtin_catalog = shared.builtin_catalog;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const numberValue = aot_state.numberValue;
const staticStringValue = aot_state.staticStringValue;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const valueUtf8LossyAlloc = aot_state.valueUtf8LossyAlloc;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueToNumber = aot_state.valueToNumber;
const isString = aot_state.isString;
const valueTruthy = aot_state.valueTruthy;
const invokeAotCallback = aot_state.invokeAotCallback;
const resolveAotCallback = aot_state.resolveAotCallback;
const parseFloatBuiltin = aot_state.parseFloatBuiltin;
const repeatCount = aot_state.repeatCount;
const writeUtf16 = aot_state.writeUtf16;
const appendDisplayLog = aot_state.appendDisplayLog;
const emitDisplayLine = aot_state.emitDisplayLine;
const displayValue = aot_state.displayValue;
const fflush = aot_state.fflush;
const putchar = aot_state.putchar;
const drainAotEvents = aot_state.drainAotEvents;
const waitAotMilliseconds = aot_state.waitAotMilliseconds;
const monotonicTimeMilliseconds = aot_state.monotonicTimeMilliseconds;
const currentTimeMilliseconds = aot_state.currentTimeMilliseconds;
const dynamicInterpreterState = aot_state.dynamicInterpreterState;
const syncDynamicGlobals = aot_state.syncDynamicGlobals;
const upsertDynamicGlobal = aot_state.upsertDynamicGlobal;
const jsonEncodeBuiltin = aot_state.jsonEncodeBuiltin;
const strictEqual = aot_state.strictEqual;
const arithmetic = aot_state.arithmetic;
const createAotPromise = aot_state.createAotPromise;
const numberString = aot_state.numberString;

pub fn stringArrayBuiltin(runtime: *Runtime, names: []const []const u8) !Value {
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    for (names) |name| {
        roots[1] = try runtimeUtf8String(runtime, name);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
    }
    return roots[0];
}

pub fn systemFunctionExistsBuiltin(runtime: *Runtime, values: []const Value) !Value {
    const source = if (values.len > 0) values[values.len - 1] else Value{};
    const text = try valueUtf8LossyAlloc(runtime, source);
    defer runtime.allocator.free(text);
    for (builtin_catalog.default_names) |candidate| {
        if (std.mem.eql(u8, text, candidate)) return .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 };
    }
    return .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 };
}

/// Convert a UTF-16 exception message to UTF-8 without rejecting lone
/// surrogates.  JavaScript strings can contain unpaired surrogates, while the
/// process stderr stream is UTF-8; use U+FFFD for an unpaired code unit just
/// as the normal AOT output path does.
pub fn utf16FailureMessageUtf8Alloc(allocator: std.mem.Allocator, units: []const u16) anyerror![]u8 {
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

pub fn pendingExceptionMessageUtf8Alloc(runtime: *Runtime) anyerror![]u8 {
    if (!runtime.has_pending_exception) return error.NoPendingException;
    const units = try valueUtf16Alloc(runtime, runtime.pending_exception);
    defer runtime.allocator.free(units);
    return utf16FailureMessageUtf8Alloc(runtime.allocator, units);
}

pub fn writeBytes(bytes: []const u8, newline: bool) void {
    for (bytes) |byte| _ = putchar(byte);
    if (newline) _ = putchar('\n');
}

pub const AotHttpPathStat = enum { file, directory, missing };

pub fn runtimeFailure(failure: anyerror) noreturn {
    std.debug.print("[実行時エラー] {s}\n", .{@errorName(failure)});
    std.process.exit(1);
}

const AotPosixInterrupt = if (builtin.os.tag == .windows) struct {} else struct {
    pub fn handler(_: std.posix.SIG) callconv(.c) void {
        aot_state.aot_interrupt_requested.store(true, .release);
    }
};

const AotWindowsInterrupt = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn SetConsoleCtrlHandler(handler_fn: ?*const fn (u32) callconv(.winapi) i32, add: i32) callconv(.winapi) i32;

    pub fn handler(control_type: u32) callconv(.winapi) i32 {
        if (control_type != 0 and control_type != 1) return 0;
        aot_state.aot_interrupt_requested.store(true, .release);
        return 1;
    }
} else struct {};

pub fn installAotInterrupt() !void {
    if (builtin.os.tag == .windows) {
        if (AotWindowsInterrupt.SetConsoleCtrlHandler(AotWindowsInterrupt.handler, 1) == 0) return error.InterruptHandlingUnavailable;
    } else {
        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = AotPosixInterrupt.handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &action, null);
    }
}

pub fn pollAotInterrupt(runtime: *Runtime) !void {
    if (!aot_state.aot_interrupt_requested.swap(false, .acquire)) return;
    if (runtime.interrupt_callback.tag != @intFromEnum(Tag.function)) return;

    var undefined_value = Value{};
    const result = try invokeAotCallback(runtime, runtime.interrupt_callback, @ptrCast(&undefined_value), 1);
    if (valueTruthy(result)) {
        runtime.dispatch_trace.finishTerminal("interrupt-callback", 0);
        _ = fflush(null);
        std.process.exit(0);
    }
}

/// Records execution of one statically identified global load. The generated
/// module supplies the ID from its pre-optimization global manifest.
/// Records execution of one statically identified global store. The generated
/// module supplies the ID from its pre-optimization global manifest.
/// Records execution of one statically identified typed literal. The
/// generated module supplies the ID from its pre-optimization literal
/// manifest.
/// Initializes Node-host constants whose values depend on the generated
/// executable's process arguments.  The generated main has already rooted
/// every referenced global before this function is called, so newly allocated
/// strings and the command-line array remain visible to the collector while
/// the values are being assembled.
/// Windows' `wmain` receives UTF-16 command-line arguments.  Keep those code
/// units intact so WTF-16 input, including unpaired surrogates, follows the
/// same value representation as the rest of the runtime.
/// Initializes Node directory values that are exposed as globals when a
/// program uses the shorthand form without parentheses.
/// Initializes the source directory used by Node's mother-path global and
/// function. Relative source paths are resolved against the executable's
/// current working directory, matching the interpreter host context.
/// Runs callbacks that were registered by the generated program before its
/// global roots are removed. This gives AOT the same top-level timer drain as
/// the Interpreter while keeping callback values inside the native runtime.
/// Installs the four mutable globals used by the built-in HTTP server. The
/// generated main roots these globals for the lifetime of the event loop.
/// Dedicated ABI for the six synchronous commands exposed by
/// `plugin_httpserver.mjs`. The implementation is native AOT code and does
/// not load or evaluate JavaScript.
/// Site-aware display hooks used by generated LLVM.  The hooks are additive;
/// the runtime ABI for existing generated modules remains unchanged.
/// Begins a direct-display trace and returns the failure epoch observed at the
/// same boundary through `epoch_out`.  The extra out parameter avoids making
/// the call ID carry two independent pieces of state across LLVM IR.
/// Records a source-level `エラー発生` throw. This is intentionally a
/// separate ABI from `lnako_aot_builtin_call_site`: the compiler lowers the
/// command to a throw terminator so exception handler control flow remains
/// explicit and no generic builtin dispatch is introduced.
pub fn debugDisplayBuiltin(runtime: *Runtime, value: Value, line: u64, source_path: []const u8, display_log: ?*Value) !void {
    var roots = [_]Value{ value, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    var printable = value;
    switch (@as(Tag, @enumFromInt(value.tag))) {
        .array, .dictionary => {
            roots[1] = try jsonEncodeBuiltin(runtime, value, false);
            printable = roots[1];
        },
        else => {},
    }
    const text = try valueUtf8LossyAlloc(runtime, printable);
    defer runtime.allocator.free(text);
    const normalized_source_path = normalizeDebugSourcePath(source_path, builtin.os.tag == .windows);
    const message = try std.fmt.allocPrint(runtime.allocator, "{s}({d}): {s}", .{ normalized_source_path, line, text });
    defer runtime.allocator.free(message);
    roots[2] = try runtimeUtf8String(runtime, message);
    try displayValue(runtime, roots[2], true, display_log);
}

pub fn normalizeDebugSourcePath(source_path: []const u8, windows: bool) []const u8 {
    if (windows) {
        if (std.mem.indexOfScalar(u8, source_path, ':')) |separator| return source_path[0..separator];
    }
    return source_path;
}

/// AOT版`ハテナ関数実行`は、カスタムコールバックが未設定なら公式既定動作
/// （`デバッグ表示`）を、設定済みなら純Zigのコールバック列を専用ABIで実行する。
/// `JS:`コールバックの評価だけは通常AOTへ持ち込まず、明示的なcompat-js境界に残す。
/// Dedicated ABI for plugin and namespace state.  These commands mutate
/// system globals, so the targets are explicit instead of being looked up by
/// name inside the AOT runtime.
/// Dedicated ABI for Node's archive tool path setter. The setter mutates a
/// system global, while archive execution itself remains a separate external
/// tool boundary.
/// Dedicated ABI for Node's ZIP archive commands. The default path keeps the
/// existing pure-Zig stored-ZIP implementation; an explicitly changed tool
/// path is invoked with argv semantics, matching the command's external-tool
/// boundary without introducing a JavaScript runtime into AOT.
/// Dedicated ABI for Node's AJAX option setter. The option object is kept in
/// the corresponding rooted system global; actual HTTP execution remains a
/// separate external boundary.
/// Dedicated ABI for Node's AJAX error callback setter. The callback value is
/// kept in the corresponding rooted system global; invoking it on a failed
/// HTTP operation remains a separate external boundary.
/// Dedicated ABI for Node's HTTP client commands. Requests use Zig's native
/// HTTP client; callback and Response-Promise results are returned through the
/// AOT event queue so their observable ordering remains compatible with the
/// interpreter without embedding a JavaScript runtime.
pub fn promiseSentinel(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = .{};
}

pub fn byteBufferUnboundSliceCallback(out: *Value, _: *anyopaque, _: ?[*]const Value, _: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (aot_state.active_runtime) |*active| active else return;
    runtime.setFailureText("Cannot read properties of undefined (reading 'subarray')");
}

/// Dedicated ABI for Node's synchronous standard-input callback command. The
/// callback and `対象` storage are passed explicitly so a local variable with
/// the same source-level name cannot redirect the command's side effect.
pub fn builtinDispatchRoute(command: aot_builtin.Command) []const u8 {
    return aot_builtin.dispatchRoute(command);
}

pub fn typeNameValue(value: Value) Value {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => staticStringValue("undefined"),
        .null_value, .byte_buffer, .array, .dictionary, .iterator, .promise => staticStringValue("object"),
        .boolean => staticStringValue("boolean"),
        .number => staticStringValue("number"),
        .static_utf8_string, .utf16_string => staticStringValue("string"),
        .bigint => staticStringValue("bigint"),
        .function => staticStringValue("function"),
        .binding_cell => typeNameValue(value.object().?.payload.binding_cell),
    };
}

pub fn parseIntBuiltin(runtime: *Runtime, value: Value) !f64 {
    const units = try valueUtf16Alloc(runtime, value);
    defer runtime.allocator.free(units);
    return number_mod.parseIntPrefix(units, null);
}

pub fn runtimeUtf8String(runtime: *Runtime, text: []const u8) !Value {
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

pub fn runtimeUtf8StringLossy(runtime: *Runtime, text: []const u8) !Value {
    const decoded = try string_mod.String.fromUtf8Lossy(runtime.allocator, text);
    return runtime.ownString(decoded.units);
}

pub fn debugBreakpointWaitBuiltin(
    runtime: *Runtime,
    breakpoints: *Value,
    force_wait: *Value,
    wait_flag: *Value,
    plugin_name: *Value,
    arguments: []const Value,
) !Value {
    const line_value = if (arguments.len > 0) arguments[arguments.len - 1] else Value{};
    const line = try valueToNumberRuntime(runtime, line_value);
    const force = valueTruthy(force_wait.*);
    force_wait.* = numberValue(0);
    var breakpoint_hit = false;
    if (breakpoints.object()) |object| if (object.payload == .array) {
        const line_number = numberValue(line);
        for (object.payload.array.items) |candidate| if (try strictEqual(runtime, candidate, line_number)) {
            breakpoint_hit = true;
            break;
        };
    };
    if (!force and !breakpoint_hit) return numberValue(line);
    if (!(try strictEqual(runtime, plugin_name.*, staticStringValue("メイン")))) return createAotPromise(runtime);

    const line_text = try numberString(runtime.allocator, line);
    defer runtime.allocator.free(line_text);
    const marker = try std.fmt.allocPrint(runtime.allocator, "@__DEBUG_BP_WAIT({s})", .{line_text});
    defer runtime.allocator.free(marker);
    writeBytes(marker, true);

    while (true) {
        const flag = wait_flag.*;
        if (flag.tag == @intFromEnum(Tag.number) and @as(f64, @bitCast(flag.payload)) == 1) {
            wait_flag.* = numberValue(0);
            return numberValue(line);
        }
        try waitAotMilliseconds(runtime, 500);
    }
}

pub fn measureCallableBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len == 0) return error.NotCallable;
    var roots = [_]Value{ arguments[arguments.len - 1], .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[1] = try resolveAotCallback(runtime, roots[0]);
    const started = monotonicTimeMilliseconds(runtime);
    roots[2] = try invokeAotCallback(runtime, roots[1], null, 0);
    const finished = monotonicTimeMilliseconds(runtime);
    return numberValue(finished - started);
}

pub fn shouldRegisterNamedFunction(name: []const u8) bool {
    // HIR gives anonymous functions an internal name for calls and debug
    // metadata, but the official global-function list exposes named language
    // functions only.  Closures must therefore not enter named_functions.
    return name.len > 0 and std.mem.indexOf(u8, name, "__lambda$") == null;
}

pub fn systemGlobalFunctionNamesBuiltin(runtime: *Runtime) !Value {
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    for (runtime.named_functions.items) |registered| {
        roots[1] = try runtimeUtf8String(runtime, registered.name);
        try roots[0].object().?.payload.array.append(runtime.allocator, roots[1]);
    }
    return roots[0];
}

pub fn aotOsName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        .windows => "win32",
        .linux => "linux",
        else => @tagName(builtin.os.tag),
    };
}

pub fn aotArchitectureName() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        .x86 => "ia32",
        else => @tagName(builtin.cpu.arch),
    };
}

pub fn radixBuiltin(runtime: *Runtime, value: Value, radix_value: Value) !Value {
    const number = try parseIntBuiltin(runtime, value);
    const radix_number: f64 = if (radix_value.tag == @intFromEnum(Tag.undefined)) 10 else try valueToNumberRuntime(runtime, radix_value);
    const truncated = @trunc(radix_number);
    if (!std.math.isFinite(radix_number) or truncated < 2 or truncated > 36) return error.InvalidRadix;
    const text = try number_mod.integerToRadixAlloc(runtime.allocator, number, @intFromFloat(truncated));
    defer runtime.allocator.free(text);
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    return runtime.ownString(units);
}

pub fn rgbBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    var components: [3]f64 = undefined;
    for (0..3) |index| components[index] = try parseIntBuiltin(runtime, arguments[index]);
    const text = try number_mod.rgbAlloc(runtime.allocator, components);
    defer runtime.allocator.free(text);
    const units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, text);
    return runtime.ownString(units);
}

pub fn rangeBuiltin(runtime: *Runtime, first: Value, last: Value) !Value {
    var roots = [_]Value{ first, last, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[2] = try runtime.createString(&.{ 0x5148, 0x982d });
    roots[3] = try runtime.createString(&.{ 0x672b, 0x5c3e });
    roots[4] = try runtime.createDictionary(&.{ roots[2], roots[0], roots[3], roots[1] });
    return roots[4];
}

pub fn repeatMultiplyBuiltin(runtime: *Runtime, left: Value, right: Value) !Value {
    var roots = [_]Value{ left, right, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    if (!isString(roots[0]) and roots[0].tag != @intFromEnum(Tag.array)) return arithmetic(runtime, .multiply, roots[0], roots[1]);
    const count_number = try parseIntBuiltin(runtime, roots[1]);
    const count: usize = if (std.math.isNan(count_number) or count_number <= 0)
        0
    else if (!std.math.isFinite(count_number) or count_number > @as(f64, @floatFromInt(std.math.maxInt(usize))))
        return error.RepetitionTooLarge
    else
        @intFromFloat(@trunc(count_number));
    if (isString(roots[0])) {
        const source = try valueUtf16Alloc(runtime, roots[0]);
        defer runtime.allocator.free(source);
        const length = std.math.mul(usize, source.len, count) catch return error.RepetitionTooLarge;
        const units = try runtime.allocator.alloc(u16, length);
        for (0..count) |index| @memcpy(units[index * source.len ..][0..source.len], source);
        return runtime.ownString(units);
    }
    const source = roots[0].object().?.payload.array.items;
    const length = std.math.mul(usize, source.len, count) catch return error.RepetitionTooLarge;
    const values = try runtime.allocator.alloc(Value, length);
    defer runtime.allocator.free(values);
    for (0..count) |index| @memcpy(values[index * source.len ..][0..source.len], source);
    roots[2] = try runtime.createArray(values);
    return roots[2];
}
