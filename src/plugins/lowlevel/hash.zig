const std = @import("std");
const builtin = @import("builtin");
const value_mod = @import("../../runtime/value.zig");
const foundation = @import("../../runtime/low_level_foundation.zig");
const low_level_io = @import("../../runtime/low_level_io.zig");
const low_level_hash = @import("../../runtime/low_level_hash.zig");
const low_level_fs = @import("../../runtime/low_level_fs.zig");
const low_level_context = @import("../../runtime/low_level/context.zig");
const common = @import("../system/common.zig");
const node_shared = @import("../node/shared.zig");
const shared = @import("shared.zig");
// ドメインテストはディスパッチャ経由で契約を検査する。本番ビルドでは
// call.zigを解析しないよう、テスト時にだけ読み込んで閉路を避ける。
const call = if (builtin.is_test) @import("call.zig").call else void;

const Value = shared.Value;
const Runtime = shared.Runtime;
const State = shared.State;
const Effects = shared.Effects;
const Context = low_level_context.Context;
const emptyContext = low_level_context.emptyContext;

const throwStructured = shared.throwStructured;
const lookupHandle = shared.lookupHandle;
const rememberHandle = shared.rememberHandle;
const forgetHandle = shared.forgetHandle;
const bytesArgument = shared.bytesArgument;
const thrownErrorCode = shared.thrownErrorCode;

const captureThrow = shared.captureThrow;

pub fn hashCreate(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const algorithm_value = common.argument(arguments, 0);
    if (algorithm_value != .string) {
        return throwStructured(runtime, effects, .EINVAL, foundation.hash_operation, null, null, "アルゴリズム名は文字列である必要があります");
    }
    const algorithm = try node_shared.valueUtf8(runtime, algorithm_value);
    defer runtime.allocator().free(algorithm);
    const raw = context.createHash(algorithm) catch |failure| {
        return throwHash(runtime, effects, failure);
    };
    errdefer context.discardHash(raw) catch {};
    const id = foundation.HandleId.fromRaw(raw);
    var handle = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&handle);
    try rememberHandle(state, runtime.allocator(), handle, id);
    return handle;
}

pub fn hashUpdate(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    const bytes = bytesArgument(runtime, common.argument(arguments, 1)) catch {
        return throwStructured(runtime, effects, .EINVAL, foundation.hash_operation, null, null, "追加する値はBytesである必要があります");
    };
    context.updateHash(id.raw(), bytes) catch |failure| {
        return throwHash(runtime, effects, failure);
    };
    return .undefined;
}

pub fn hashDigest(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    var encoding: low_level_hash.Encoding = .raw;
    const encoding_value = common.argument(arguments, 1);
    if (encoding_value != .undefined and encoding_value != .null_value) {
        if (encoding_value != .string) {
            return throwStructured(runtime, effects, .EINVAL, foundation.hash_operation, null, null, "encodingは文字列である必要があります");
        }
        const name = try node_shared.valueUtf8(runtime, encoding_value);
        defer runtime.allocator().free(name);
        encoding = low_level_hash.Encoding.fromName(name) orelse {
            return throwStructured(runtime, effects, .EINVAL, foundation.hash_operation, null, null, "未知のencodingです");
        };
    }
    const digest = context.digestHash(id.raw(), runtime.allocator()) catch |failure| {
        // digestHashはentryを見つけて消費してからfinalizeする。BadFileDescriptorは
        // 「hash表に無い」（ファイルhandleの取り違え等）で消費していないため、
        // 元handleのidentity mappingを消してはならない。
        if (failure != error.BadFileDescriptor and failure != error.IncrementalHashUnavailable) {
            forgetHandle(state, handle);
        }
        return throwHash(runtime, effects, failure);
    };
    defer runtime.allocator().free(digest);
    forgetHandle(state, handle);
    return encodeDigest(runtime, digest, encoding);
}

pub fn hashDiscard(runtime: *Runtime, state: *State, context: Context, effects: Effects, arguments: []const Value) !Value {
    const handle = common.argument(arguments, 0);
    const id = lookupHandle(state, handle) orelse {
        return throwStructured(runtime, effects, .EBADF, foundation.hash_operation, null, null, "無効なハンドルです");
    };
    context.discardHash(id.raw()) catch |failure| {
        return throwHash(runtime, effects, failure);
    };
    forgetHandle(state, handle);
    return .undefined;
}

fn encodeDigest(runtime: *Runtime, digest: []const u8, encoding: low_level_hash.Encoding) !Value {
    switch (encoding) {
        .raw => return runtime.createBytes(digest),
        .hex => {
            const result = try runtime.allocator().alloc(u8, digest.len * 2);
            defer runtime.allocator().free(result);
            const text = std.fmt.bufPrint(result, "{x}", .{digest}) catch unreachable;
            return runtime.stringUtf8(text);
        },
        .base64, .base64url => {
            const result = try runtime.allocator().alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
            defer runtime.allocator().free(result);
            _ = std.base64.standard.Encoder.encode(result, digest);
            if (encoding == .base64) return runtime.stringUtf8(result);
            for (result) |*byte| byte.* = switch (byte.*) {
                '+' => '-',
                '/' => '_',
                else => byte.*,
            };
            var length = result.len;
            while (length > 0 and result[length - 1] == '=') length -= 1;
            return runtime.stringUtf8(result[0..length]);
        },
        .latin1 => {
            const units = try runtime.allocator().alloc(u16, digest.len);
            defer runtime.allocator().free(units);
            for (digest, 0..) |byte, index| units[index] = byte;
            return runtime.stringCodeUnits(units);
        },
        .utf8 => return runtime.stringUtf8Lossy(digest),
    }
}

fn hashFailureCode(failure: anyerror) foundation.PortableErrorCode {
    return switch (failure) {
        error.UnsupportedHashAlgorithm => .EINVAL,
        error.IncrementalHashUnsupported, error.IncrementalHashUnavailable => .ENOTSUP,
        else => foundation.portableCodeForFailure(failure) orelse .EINVAL,
    };
}

fn throwHash(runtime: *Runtime, effects: Effects, failure: anyerror) anyerror {
    const code = hashFailureCode(failure);
    const capability = if (code == .ENOTSUP) foundation.Capability.incremental_hash.id() else null;
    return throwStructured(runtime, effects, code, foundation.hash_operation, null, capability, hashFailureMessage(failure));
}

fn hashFailureMessage(failure: anyerror) []const u8 {
    return switch (failure) {
        error.UnsupportedHashAlgorithm => "未対応のハッシュアルゴリズムです",
        error.IncrementalHashUnsupported => "このアルゴリズムは逐次計算に対応していません",
        error.IncrementalHashUnavailable => "逐次ハッシュは利用できません",
        error.BadFileDescriptor => "無効なハンドルです",
        else => @errorName(failure),
    };
}

const HashHost = struct {
    table: low_level_hash.HashHandleTable,

    fn init(allocator: std.mem.Allocator) HashHost {
        return .{ .table = low_level_hash.HashHandleTable.init(allocator) };
    }

    fn deinit(self: *HashHost) void {
        self.table.deinit();
    }

    fn create(pointer: *anyopaque, algorithm: []const u8) anyerror!u64 {
        const self: *HashHost = @ptrCast(@alignCast(pointer));
        return (try self.table.insert(try low_level_hash.startNamed(algorithm))).raw();
    }

    fn update(pointer: *anyopaque, raw: u64, bytes: []const u8) anyerror!void {
        const self: *HashHost = @ptrCast(@alignCast(pointer));
        const entry = self.table.find(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
        entry.hasher.update(bytes);
    }

    fn digest(pointer: *anyopaque, raw: u64, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *HashHost = @ptrCast(@alignCast(pointer));
        var removed = self.table.remove(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
        return removed.hasher.finalize(allocator);
    }

    fn discard(pointer: *anyopaque, raw: u64) anyerror!void {
        const self: *HashHost = @ptrCast(@alignCast(pointer));
        _ = self.table.remove(foundation.HandleId.fromRaw(raw)) orelse return error.BadFileDescriptor;
    }

    fn context(self: *HashHost) Context {
        return .{ .hash = .{
            .context = self,
            .createHashFn = create,
            .updateHashFn = update,
            .digestHashFn = digest,
            .discardHashFn = discard,
        } };
    }
};

test "Interpreter低レイヤーのincremental hashはchunk供給と完了後にEBADFになる" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var algorithm = try runtime.stringUtf8("sha256");
    try roots.protect(&algorithm);
    var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
    try roots.protect(&handle);

    var chunk = try runtime.createBytes("a");
    try roots.protect(&chunk);
    _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk });
    chunk = try runtime.createBytes("b");
    try roots.protect(&chunk);
    _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk });
    chunk = try runtime.createBytes("c");
    try roots.protect(&chunk);
    _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk });

    var encoding = try runtime.stringUtf8("hex");
    try roots.protect(&encoding);
    var result = (try call(&runtime, &state, context, effects, "ハッシュ完了", &.{ handle, encoding })).?;
    try roots.protect(&result);
    const text = try result.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", text);

    // 完了後のhandleは破棄済みで、追加も再完了もEBADF。
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk }));
    const update_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(update_code);
    try std.testing.expectEqualStrings("EBADF", update_code);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ完了", &.{handle}));
    const digest_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(digest_code);
    try std.testing.expectEqualStrings("EBADF", digest_code);
}

test "Interpreter低レイヤーのハッシュ破棄は二重破棄と偽造handleをEBADFにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var algorithm = try runtime.stringUtf8("md5");
    try roots.protect(&algorithm);
    var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
    try roots.protect(&handle);
    _ = try call(&runtime, &state, context, effects, "ハッシュ破棄", &.{handle});
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ破棄", &.{handle}));
    const discard_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(discard_code);
    try std.testing.expectEqualStrings("EBADF", discard_code);

    // 同じ形の辞書を手作りしてもhandle tableに載らずEBADF。
    var forged = try runtime.createDictionary();
    try roots.protect(&forged);
    var forged_bytes = try runtime.createBytes("x");
    try roots.protect(&forged_bytes);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ追加", &.{ forged, forged_bytes }));
    const forged_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(forged_code);
    try std.testing.expectEqualStrings("EBADF", forged_code);
}

test "Interpreter低レイヤーのハッシュ開始は未知をEINVAL、RIPEMDをENOTSUPにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var unknown = try runtime.stringUtf8("crc32");
    try roots.protect(&unknown);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ開始", &.{unknown}));
    const unknown_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(unknown_code);
    try std.testing.expectEqualStrings("EINVAL", unknown_code);

    thrown = .undefined;
    var ripemd = try runtime.stringUtf8("ripemd160");
    try roots.protect(&ripemd);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ開始", &.{ripemd}));
    const ripemd_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(ripemd_code);
    try std.testing.expectEqualStrings("ENOTSUP", ripemd_code);

    // substring bytesはBuffer kindだけを受け付ける。
    thrown = .undefined;
    var algorithm = try runtime.stringUtf8("sha256");
    try roots.protect(&algorithm);
    var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
    try roots.protect(&handle);
    var uint8_array = try runtime.createUint8Array("abc");
    try roots.protect(&uint8_array);
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, uint8_array }));
    const bytes_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(bytes_code);
    try std.testing.expectEqualStrings("EINVAL", bytes_code);
}

test "Interpreter低レイヤーのincremental_hash対応判定は全callbackでtrue" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var name = try runtime.stringUtf8("incremental_hash");
    try roots.protect(&name);
    const supported = (try call(&runtime, &state, host.context(), effects, foundation.capability_supported_command, &.{name})).?;
    try std.testing.expect(supported == .boolean and supported.boolean);
    const unsupported = (try call(&runtime, &state, emptyContext(), effects, foundation.capability_supported_command, &.{name})).?;
    try std.testing.expect(unsupported == .boolean and !unsupported.boolean);
}

test "Interpreter低レイヤーのハッシュ完了はencoding省略でraw bytesを返す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var algorithm = try runtime.stringUtf8("md5");
    try roots.protect(&algorithm);
    var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
    try roots.protect(&handle);
    var chunk = try runtime.createBytes("abc");
    try roots.protect(&chunk);
    _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk });

    // ENCODING省略はraw bytes。
    var raw = (try call(&runtime, &state, context, effects, "ハッシュ完了", &.{handle})).?;
    try roots.protect(&raw);
    try std.testing.expect(raw == .bytes);
    var hex_buffer: [32]u8 = undefined;
    const raw_hex = std.fmt.bufPrint(&hex_buffer, "{x}", .{raw.bytes.bytes}) catch unreachable;
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", raw_hex);

    // 未知encodingはEINVAL。
    var algorithm2 = try runtime.stringUtf8("md5");
    try roots.protect(&algorithm2);
    var handle2 = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm2})).?;
    try roots.protect(&handle2);
    var bad_encoding = try runtime.stringUtf8("base32");
    try roots.protect(&bad_encoding);
    thrown = .undefined;
    try std.testing.expectError(error.NakoException, call(&runtime, &state, context, effects, "ハッシュ完了", &.{ handle2, bad_encoding }));
    const encoding_code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(encoding_code);
    try std.testing.expectEqualStrings("EINVAL", encoding_code);
}

test "Interpreter低レイヤーのハッシュ開始は非文字列と数値をEINVALにする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };

    try std.testing.expectError(error.NakoException, call(&runtime, &state, host.context(), effects, "ハッシュ開始", &.{.{ .number = 1 }}));
    const code = try thrownErrorCode(&runtime, thrown);
    defer std.testing.allocator.free(code);
    try std.testing.expectEqualStrings("EINVAL", code);
}

test "Interpreter低レイヤーのハッシュはGC stress下でもhandleを保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var algorithm = try runtime.stringUtf8("sha256");
    try roots.protect(&algorithm);
    var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
    try roots.protect(&handle);
    var chunk = try runtime.createBytes("abc");
    try roots.protect(&chunk);
    _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, chunk });
    var encoding = try runtime.stringUtf8("hex");
    try roots.protect(&encoding);
    var result = (try call(&runtime, &state, context, effects, "ハッシュ完了", &.{ handle, encoding })).?;
    try roots.protect(&result);
    const text = try result.string.toUtf8Lossy(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", text);
}

test "Interpreter低レイヤーのハッシュ完了encodingはハッシュ値計算と一致する" {
    const plugin_crypto = @import("../crypto.zig");
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state = State{};
    defer state.deinit(std.testing.allocator);
    var host = HashHost.init(std.testing.allocator);
    defer host.deinit();
    const context = host.context();
    var thrown: Value = .undefined;
    const effects = Effects{ .context = @ptrCast(&thrown), .throwFn = captureThrow };
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var input = try runtime.createBytes("abc");
    try roots.protect(&input);
    var algorithm = try runtime.stringUtf8("sha256");
    try roots.protect(&algorithm);
    for ([_][]const u8{ "hex", "base64", "base64url", "latin1", "binary", "utf8", "utf-8" }) |encoding_name| {
        var encoding = try runtime.stringUtf8(encoding_name);
        try roots.protect(&encoding);
        var expected = (try plugin_crypto.call(&runtime, null, "ハッシュ値計算", &.{ input, algorithm, encoding })).?;
        try roots.protect(&expected);
        const expected_text = try node_shared.valueUtf8(&runtime, expected);
        defer std.testing.allocator.free(expected_text);

        var handle = (try call(&runtime, &state, context, effects, "ハッシュ開始", &.{algorithm})).?;
        try roots.protect(&handle);
        _ = try call(&runtime, &state, context, effects, "ハッシュ追加", &.{ handle, input });
        var actual = (try call(&runtime, &state, context, effects, "ハッシュ完了", &.{ handle, encoding })).?;
        try roots.protect(&actual);
        const actual_text = try node_shared.valueUtf8(&runtime, actual);
        defer std.testing.allocator.free(actual_text);
        try std.testing.expectEqualStrings(expected_text, actual_text);
    }
}
