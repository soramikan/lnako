//! `--compat-js` AOT runtime の JS→Nako 値変換境界。
//!
//! `JS実行` の戻り値は interpreter（`src/compat/quickjs.zig` の `fromRaw`）と同じ
//! full 変換で、プリミティブに加えて BigInt・関数値・配列・辞書・Promise を
//! 再帰的に Nako 値へ写す。JS 関数値は AOT の関数オブジェクトとして保持し、
//! `external` binding の QuickJS 参照を GC sweep で解放する。
//!
//! `JS関数実行` の浅い戻り値、`JSオブジェクト取得` / `JSメソッド実行` の再帰
//! 変換、呼出し後の再同期も、同じ JS→Nako 変換規則としてこの module に集約する。
//! ABI（`pub export fn lnako_aot_compat_*`）は `compat_js.zig` に残し、通常 AOT へ
//! QuickJS を混入させない分離を維持する。
const std = @import("std");
const state = @import("state.zig");
const compat = @import("compat_js.zig");

const Value = state.Value;
const Tag = state.Tag;
const Engine = compat.Engine;
const RawValue = compat.RawValue;

/// JS→Nako / Nako→JS 変換のネスト上限。深い非循環オブジェクトでもスタック
/// 枯渇せず、上限超過は`QuickJsNestingTooDeep`の明示エラーにする
/// （interpreterの同名上限と同値）。
pub const max_interop_conversion_depth: usize = 64;

/// `SyncState.full_values` のcallback経路だけで使うNako→JS変換。
/// interpreterの`toRaw`と同じく、BigIntは10進文字列、bytesは0..255の数値配列に
/// する。通常の`JS関数実行` / `JSオブジェクト取得` / `JSメソッド実行` は
/// このhelperを呼ばず、従来どおりBigIntとbytesを明示エラーにする。
pub fn fullSyncValueRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value) anyerror!*RawValue {
    const object = value.object() orelse return error.QuickJsUnsupportedArgument;
    return switch (@as(Tag, @fromBackingInt(value.tag))) {
        .bigint => blk: {
            const text = try object.payload.bigint.toString(runtime.allocator, 10);
            defer runtime.allocator.free(text);
            break :blk compat.lnako_qjs_bigint(engine_value, text.ptr, text.len) orelse {
                compat.fail(runtime, engine_value);
                return compat.reported_engine_failure;
            };
        },
        .byte_buffer => blk: {
            const bytes = object.payload.byte_buffer.bytes;
            if (bytes.len > std.math.maxInt(u32) or bytes.len > 1_000_000) return error.QuickJsCollectionTooLarge;
            const result = compat.lnako_qjs_array(engine_value) orelse return error.OutOfMemory;
            errdefer compat.lnako_qjs_value_free(result);
            for (bytes, 0..) |byte, index| {
                const item = compat.lnako_qjs_number(engine_value, @floatFromInt(byte)) orelse return error.OutOfMemory;
                defer compat.lnako_qjs_value_free(item);
                if (compat.lnako_qjs_set_index(result, @intCast(index), item) < 0) {
                    compat.fail(runtime, engine_value);
                    return compat.reported_engine_failure;
                }
            }
            break :blk result;
        },
        else => error.QuickJsUnsupportedArgument,
    };
}

/// external値のNako側の内容をJSオブジェクトへ書き戻す（interpreterの
/// `syncExternal`と同じ意味）。外部参照の子要素は同じJS参照をdupし、externalを
/// 持たない入れ子の配列・辞書は再帰的にJSコピーを作る。Nako側の循環参照は
/// `in_progress`（Nako Object pointer → 生成中のJS参照）で止める。
///
/// `SyncState` は同期中の変換キャッシュ。in_progressは循環検出、completedは
/// 同期中に変換した子を共有・再同期するために保持する。completedのRawValueは
/// この同期の終了時にまとめて解放する。
pub const SyncState = struct {
    in_progress: std.AutoHashMapUnmanaged(usize, *RawValue) = .empty,
    completed: std.AutoHashMapUnmanaged(usize, *RawValue) = .empty,
    /// JS関数値のcallbackだけが真にする。トップレベルでも入れ子でもBigIntと
    /// bytesを変換し、それ以外の経路（JS関数実行・JSオブジェクト取得・
    /// JSメソッド実行）は従来どおり明示的な未対応エラーにする。
    full_values: bool = false,

    pub fn deinit(self: *SyncState, allocator: std.mem.Allocator) void {
        var iterator = self.completed.valueIterator();
        while (iterator.next()) |raw| compat.lnako_qjs_value_free(raw.*);
        self.completed.deinit(allocator);
        self.in_progress.deinit(allocator);
    }
};

pub fn syncExternalRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value, raw: *RawValue, sync: *SyncState) anyerror!void {
    const object = value.object() orelse return;
    const identity = @intFromPtr(object);
    // 同一同期内で変換中のexternal値は循環参照として止める。
    if (sync.in_progress.get(identity)) |_| return;
    if (sync.completed.get(identity)) |cached| {
        // 同期中に再出現したexternal値は前回のJS参照を最新のNako内容で
        // 再同期してから共有する（interpreterのsyncExternalと同じ）。
        try sync.in_progress.put(runtime.allocator, identity, cached);
        defer _ = sync.in_progress.remove(identity);
        try syncContents(runtime, engine_value, value, cached, sync, 0);
        return;
    }
    try sync.in_progress.put(runtime.allocator, identity, raw);
    defer _ = sync.in_progress.remove(identity);
    try syncContents(runtime, engine_value, value, raw, sync, 0);
    // 呼出し元のraw所有権は壊さず、同期中の再出現用にdupを記録する。
    const cached = compat.lnako_qjs_dup(raw) orelse return error.OutOfMemory;
    errdefer compat.lnako_qjs_value_free(cached);
    try sync.completed.put(runtime.allocator, identity, cached);
}

fn syncContents(runtime: *state.Runtime, engine_value: *Engine, value: Value, raw: *RawValue, sync: *SyncState, depth: usize) anyerror!void {
    if (depth >= max_interop_conversion_depth) return error.QuickJsNestingTooDeep;
    switch (@as(Tag, @fromBackingInt(value.tag))) {
        .array => {
            const object = value.object() orelse return;
            const source_items = object.payload.array.items;
            if (source_items.len > std.math.maxInt(u32)) return error.QuickJsCollectionTooLarge;
            if (source_items.len > 1_000_000) return error.QuickJsCollectionTooLarge;
            // getter/host callbackによる再入でNako配列が再割当てされても安全なよう、
            // 走査対象をローカルへ複製してrootする。
            const items = try runtime.allocator.alloc(Value, source_items.len);
            defer runtime.allocator.free(items);
            @memcpy(items, source_items);
            const presence = try runtime.allocator.alloc(bool, items.len);
            defer runtime.allocator.free(presence);
            @memset(presence, true);
            const presence_len = @min(object.array_presence.items.len, items.len);
            @memcpy(presence[0..presence_len], object.array_presence.items[0..presence_len]);
            var items_frame: state.RootFrame = .{};
            runtime.pushRoots(&items_frame, if (items.len == 0) null else items.ptr, items.len);
            defer runtime.popRoots(&items_frame);
            if (compat.lnako_qjs_set_array_length(raw, @intCast(items.len)) < 0) {
                compat.fail(runtime, engine_value);
                return compat.reported_engine_failure;
            }
            for (items, 0..) |item, index| {
                // Nako側で穴になっているインデックスはJSでも穴のままにする。
                if (!presence[index]) {
                    if (compat.lnako_qjs_delete_index(raw, @intCast(index)) < 0) {
                        compat.fail(runtime, engine_value);
                        return compat.reported_engine_failure;
                    }
                    continue;
                }
                const item_raw = try syncValueRaw(runtime, engine_value, item, sync, depth + 1);
                defer compat.lnako_qjs_value_free(item_raw);
                if (compat.lnako_qjs_set_index(raw, @intCast(index), item_raw) < 0) {
                    compat.fail(runtime, engine_value);
                    return compat.reported_engine_failure;
                }
            }
        },
        .dictionary => {
            const object = value.object() orelse return;
            // 走査中の再入で辞書が再割当てされても安全なよう、entriesを複製する。
            const source_entries = object.payload.dictionary.entries.items;
            const entries = try runtime.allocator.alloc(state.DictionaryEntry, source_entries.len);
            defer runtime.allocator.free(entries);
            @memcpy(entries, source_entries);
            var entries_frame: state.RootFrame = .{};
            runtime.pushRoots(&entries_frame, if (entries.len == 0) null else @ptrCast(entries.ptr), entries.len * 2);
            defer runtime.popRoots(&entries_frame);
            var names: std.ArrayListUnmanaged([]u8) = .empty;
            defer {
                for (names.items) |name| runtime.allocator.free(name);
                names.deinit(runtime.allocator);
            }
            for (entries) |entry| {
                const name = try dictionaryKeyNameZ(runtime, entry.key);
                defer runtime.allocator.free(name);
                // 比較・削除はJSのkeys()と同じlossy UTF-8、定義/取得はWTF-8で行う。
                const name_lossy = try dictionaryKeyNameLossyZ(runtime, entry.key);
                defer runtime.allocator.free(name_lossy);
                const owned_name = try runtime.allocator.dupe(u8, name_lossy);
                names.append(runtime.allocator, owned_name) catch |failure| {
                    runtime.allocator.free(owned_name);
                    return failure;
                };
                const item_raw = try syncValueRaw(runtime, engine_value, entry.value, sync, depth + 1);
                defer compat.lnako_qjs_value_free(item_raw);
                // 未変更のプロパティは再代入しない（Object.freeze等で不要な失敗を
                // 起こさない）。変更されたキーだけをown data propertyとして定義する。
                const has_own = compat.lnako_qjs_has_own_property(raw, name.ptr);
                if (has_own < 0) {
                    compat.fail(runtime, engine_value);
                    return compat.reported_engine_failure;
                }
                if (has_own != 0) {
                    const current = compat.lnako_qjs_get_own_property(raw, name.ptr) orelse {
                        compat.fail(runtime, engine_value);
                        return compat.reported_engine_failure;
                    };
                    defer compat.lnako_qjs_value_free(current);
                    const equal = compat.lnako_qjs_strict_equal(current, item_raw);
                    if (equal < 0) {
                        compat.fail(runtime, engine_value);
                        return compat.reported_engine_failure;
                    }
                    if (equal != 0) continue;
                }
                if (compat.lnako_qjs_define_property(raw, name.ptr, item_raw) < 0) {
                    compat.fail(runtime, engine_value);
                    return compat.reported_engine_failure;
                }
            }
            // Nako側から消えたキーはJS側でも削除する（own enumerableのみ）。
            const keys = compat.lnako_qjs_keys(raw) orelse return error.QuickJsConversionFailed;
            defer compat.lnako_qjs_keys_free(keys);
            var index: usize = 0;
            while (index < compat.lnako_qjs_keys_length(keys)) : (index += 1) {
                var name_length: usize = 0;
                const name_pointer = compat.lnako_qjs_key(keys, index, &name_length) orelse continue;
                const name = name_pointer[0..name_length];
                var listed = false;
                for (names.items) |candidate| {
                    if (std.mem.eql(u8, candidate, name)) {
                        listed = true;
                        break;
                    }
                }
                if (listed) continue;
                const name_z = try runtime.allocator.dupeSentinel(u8, name, 0);
                defer runtime.allocator.free(name_z);
                if (compat.lnako_qjs_delete_property(raw, name_z.ptr) < 0) {
                    compat.fail(runtime, engine_value);
                    return compat.reported_engine_failure;
                }
            }
        },
        else => {},
    }
}

/// 同期用のJS値変換（interpreterのtoRaw相当）。JS関数値は元のJS参照を渡し、
/// 配列・辞書はexternal bindingの有無にかかわらず同じ変換経路で中身を同期する
/// （ネストしたexternalコンテナのNako側変更もJSへ書き戻す）。変換できない値
/// （Nako関数・BigInt・bytes・Promise）は明示エラーにする。ただし
/// `sync.full_values` のcallback経路だけはBigIntとbytesを変換する。
pub fn syncValueRaw(runtime: *state.Runtime, engine_value: *Engine, value: Value, sync: *SyncState, depth: usize) anyerror!*RawValue {
    if (depth >= max_interop_conversion_depth) return error.QuickJsNestingTooDeep;
    const tag = @as(Tag, @fromBackingInt(value.tag));
    if (tag == .function) {
        if (try compat.externalRaw(value)) |raw| {
            errdefer compat.lnako_qjs_value_free(raw);
            return raw;
        }
        return error.QuickJsUnsupportedArgument;
    }
    if (tag != .array and tag != .dictionary) {
        if (tag == .bigint or (sync.full_values and tag == .byte_buffer))
            return fullSyncValueRaw(runtime, engine_value, value);
        return compat.primitiveRaw(runtime, engine_value, value);
    }
    const object = value.object() orelse return error.QuickJsUnsupportedArgument;
    const identity = @intFromPtr(object);
    if (sync.in_progress.get(identity)) |existing| return compat.lnako_qjs_dup(existing) orelse error.OutOfMemory;
    if (sync.completed.get(identity)) |existing| {
        // 同期中に同じNakoオブジェクトが再度現れた場合は、前回の変換結果を
        // そのまま使わず最新の内容で再同期してから共有する。
        try sync.in_progress.put(runtime.allocator, identity, existing);
        defer _ = sync.in_progress.remove(identity);
        try syncContents(runtime, engine_value, value, existing, sync, depth);
        return compat.lnako_qjs_dup(existing) orelse error.OutOfMemory;
    }
    const raw = if (try compat.externalRaw(value)) |external|
        external
    else switch (tag) {
        .array => compat.lnako_qjs_array(engine_value) orelse return error.OutOfMemory,
        .dictionary => compat.lnako_qjs_object(engine_value) orelse return error.OutOfMemory,
        else => unreachable,
    };
    errdefer compat.lnako_qjs_value_free(raw);
    try sync.in_progress.put(runtime.allocator, identity, raw);
    errdefer _ = sync.in_progress.remove(identity);
    try syncContents(runtime, engine_value, value, raw, sync, depth);
    _ = sync.in_progress.remove(identity);
    // dupを先に確保し、completed登録後のOOMでrawがerrdefer解放されても
    // マップに解放済みポインタを残さない。
    const shared = compat.lnako_qjs_dup(raw) orelse return error.OutOfMemory;
    errdefer compat.lnako_qjs_value_free(shared);
    try sync.completed.put(runtime.allocator, identity, raw);
    return shared;
}

/// `lnako_qjs_set_property` はNUL終端の名前を取る。interpreterのtoRawと同じく
/// 辞書キーをlossy UTF-8へ変換する（辞書キーは通常は文字列）。
pub fn dictionaryKeyNameZ(runtime: *state.Runtime, key: Value) ![:0]u8 {
    // 孤立サロゲートを置換せずWTF-8で渡す（JS→Nakoのキー保持と往復させる）。
    const units = try state.valueUtf16Alloc(runtime, key);
    defer runtime.allocator.free(units);
    const text = try std.unicode.wtf16LeToWtf8Alloc(runtime.allocator, units);
    defer runtime.allocator.free(text);
    return runtime.allocator.dupeSentinel(u8, text, 0);
}

fn dictionaryKeyNameLossyZ(runtime: *state.Runtime, key: Value) ![:0]u8 {
    const text = try state.stringUtf8Alloc(runtime, key);
    defer runtime.allocator.free(text);
    return runtime.allocator.dupeSentinel(u8, text, 0);
}

/// `JS実行` の戻り値変換。interpreter の `fromRaw`（full モード）と同じ意味で、
/// プリミティブ・BigInt・関数・配列・辞書・Promise を Nako 値へ写す。
/// `raw` は成功・失敗にかかわらず必ず消費して解放する。
pub fn jsEvalResult(runtime: *state.Runtime, raw: *RawValue) anyerror!Value {
    var seen: std.AutoHashMapUnmanaged(usize, Value) = .empty;
    defer seen.deinit(runtime.allocator);
    return convertFull(runtime, raw, &seen, 0);
}

fn convertFull(
    runtime: *state.Runtime,
    raw: *RawValue,
    seen: *std.AutoHashMapUnmanaged(usize, Value),
    depth: usize,
) anyerror!Value {
    if (depth >= max_interop_conversion_depth) {
        compat.lnako_qjs_value_free(raw);
        return error.QuickJsNestingTooDeep;
    }
    const kind = compat.lnako_qjs_kind(raw);
    // 関数値は `jsFunctionValue` が自身の参照を消費する（external binding へ
    // dup して保持する）ため、ここで二重に解放しない。
    if (kind == .function) return jsFunctionValue(runtime, raw);
    defer compat.lnako_qjs_value_free(raw);
    return switch (kind) {
        .undefined, .null_value, .boolean, .number, .string => compat.primitiveFromRaw(runtime, raw),
        .bigint => blk: {
            // interpreter の full 変換と同じく10進文字列経由で BigInt を作る。
            var length: usize = 0;
            const text = compat.lnako_qjs_to_string(raw, &length) orelse return error.QuickJsConversionFailed;
            defer compat.lnako_qjs_free_string(text);
            break :blk try runtime.createBigInt(text[0..length]);
        },
        .array => convertFullArray(runtime, raw, seen, depth),
        // `JS実行` の `.object` は bytes を拒否しない。interpreter の full 変換と
        // 同じく own properties 付きの辞書＋external binding として返す。
        .object, .promise => convertFullObject(runtime, raw, seen, depth),
        else => error.QuickJsUnsupportedValue,
    };
}

fn convertFullArray(
    runtime: *state.Runtime,
    raw: *RawValue,
    seen: *std.AutoHashMapUnmanaged(usize, Value),
    depth: usize,
) anyerror!Value {
    const identity = compat.lnako_qjs_identity(raw);
    if (seen.get(identity)) |existing| return existing;
    const length = compat.lnako_qjs_array_length(raw);
    if (length > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
    // 空配列を先に作り、埋める前に seen へ登録する。自己参照配列は同じ Object を
    // 指すため、interpreter の convertArray と同じ循環表現になる。
    var result = try runtime.createArray(&.{});
    var result_frame: state.RootFrame = .{};
    runtime.pushRoots(&result_frame, @ptrCast(&result), 1);
    defer runtime.popRoots(&result_frame);
    try seen.put(runtime.allocator, identity, result);
    const object = result.object() orelse return error.QuickJsConversionFailed;
    for (0..length) |index| {
        const present = compat.lnako_qjs_has_index(raw, @intCast(index));
        if (present < 0) return conversionFailure(runtime, raw);
        if (present == 0) {
            // JS の穴は Nako 側でも presence=false の穴として保持する。
            try runtime.aotArrayAppend(object, .{});
            _ = try runtime.aotArrayDeleteIndex(object, index);
            continue;
        }
        const item = compat.lnako_qjs_get_index(raw, @intCast(index)) orelse return conversionFailure(runtime, raw);
        var roots = [_]Value{.{}};
        var entry_frame: state.RootFrame = .{};
        runtime.pushRoots(&entry_frame, &roots, roots.len);
        defer runtime.popRoots(&entry_frame);
        roots[0] = try convertFull(runtime, item, seen, depth + 1);
        try runtime.aotArrayAppend(object, roots[0]);
    }
    try compat.attachExternal(result, raw);
    return result;
}

fn convertFullObject(
    runtime: *state.Runtime,
    raw: *RawValue,
    seen: *std.AutoHashMapUnmanaged(usize, Value),
    depth: usize,
) anyerror!Value {
    const identity = compat.lnako_qjs_identity(raw);
    if (seen.get(identity)) |existing| return existing;
    const keys = compat.lnako_qjs_keys(raw) orelse return error.QuickJsConversionFailed;
    defer compat.lnako_qjs_keys_free(keys);
    const count = compat.lnako_qjs_keys_length(keys);
    if (count > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
    var result = try runtime.createDictionary(&.{});
    var result_frame: state.RootFrame = .{};
    runtime.pushRoots(&result_frame, @ptrCast(&result), 1);
    defer runtime.popRoots(&result_frame);
    try seen.put(runtime.allocator, identity, result);
    for (0..count) |index| {
        var name_length: usize = 0;
        const name_pointer = compat.lnako_qjs_key(keys, index, &name_length) orelse continue;
        const name = name_pointer[0..name_length];
        const name_z = try runtime.allocator.dupeSentinel(u8, name, 0);
        defer runtime.allocator.free(name_z);
        // キー生成に失敗した場合に item の所有権が未移転のまま漏れないよう、先に作る。
        const key = try wtf8Value(runtime, name);
        const item = compat.lnako_qjs_get_property(raw, name_z.ptr) orelse return conversionFailure(runtime, raw);
        // キー文字列を root し、値の変換で GC が走っても回収されないようにする。
        var roots = [_]Value{ key, .{} };
        var entry_frame: state.RootFrame = .{};
        runtime.pushRoots(&entry_frame, &roots, roots.len);
        defer runtime.popRoots(&entry_frame);
        roots[1] = try convertFull(runtime, item, seen, depth + 1);
        try runtime.setDictionary(&result.object().?.payload.dictionary, roots[0], roots[1]);
    }
    try compat.attachExternal(result, raw);
    return result;
}

/// JS 関数値を AOT の関数オブジェクトへ変換する。`JS実行` の full 変換と、
/// 呼出し後の再同期（`setRefreshedEntry`）の両方から呼ばれる。
///
/// `raw` は必ず消費する（`convertResult` / `callResultFromRaw` と同じ所有権
/// 規則）。external binding には dup した参照を渡すため、GC sweep の
/// `releaseExternal` が1回だけ元の参照を解放する。
pub fn jsFunctionValue(runtime: *state.Runtime, raw: *RawValue) anyerror!Value {
    defer compat.lnako_qjs_value_free(raw);
    const name_value = compat.lnako_qjs_get_property(raw, "name");
    defer if (name_value) |value| compat.lnako_qjs_value_free(value);
    var name_length: usize = 0;
    const name_text = if (name_value) |value| compat.lnako_qjs_to_string(value, &name_length) else null;
    defer if (name_text) |text| compat.lnako_qjs_free_string(text);
    // 取得できない関数（無名関数・getter 例外）は interpreter と同じ `<js>` にする。
    const name: []const u8 = if (name_text) |text| text[0..name_length] else "<js>";
    // `register_global = false` のため無名関数が `named_functions` へ溜まらない。
    const function_value = try runtime.createMethodFunction(jsFunctionCallback, 0, name, &.{});
    var roots = [_]Value{function_value};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const object = roots[0].object() orelse return error.QuickJsConversionFailed;
    // Nako 側の関数値は既定で `arity` 個の実引数へパディングされる
    // （`functions.zig` の `callback_len`）。JS 関数は渡された実引数をそのまま
    // 受け取るため、生成 wrapper 規約（実個数）へ切り替える。これを忘れると
    // `arity = 0` のため Nako 側の実引数が0個として渡ってしまう。
    object.payload.function.generated_wrapper = true;
    try compat.attachExternal(roots[0], raw);
    return roots[0];
}

/// `JS実行` が返した JS 関数値を Nako の関数値として呼び出す callback。
/// `functions.zig` は `context` に呼出し対象の `*state.Object` を渡す。
pub fn jsFunctionCallback(out: *Value, context: *anyopaque, arguments: ?[*]const Value, len: usize) callconv(.c) void {
    out.* = .{};
    const runtime = if (state.active_runtime) |*active| active else return;
    const object: *state.Object = @ptrCast(@alignCast(context));
    const handle = if (object.external) |external| external.handle else null;
    const function: *const RawValue = @ptrCast(@alignCast(handle orelse {
        runtime.setFailure(error.QuickJsValueNotCallable);
        return;
    }));
    if (arguments == null and len != 0) {
        runtime.setFailure(error.InvalidArgumentCount);
        return;
    }
    const engine_value = compat.ensureEngine() catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    // refresh が引数コンテナの payload を差し替えても安全なよう、実引数
    // スライスを複製して root する（interpreter の `externalCall` と同じ）。
    const snapshot = runtime.allocator.alloc(Value, len) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    defer runtime.allocator.free(snapshot);
    if (arguments) |source| @memcpy(snapshot, source[0..len]);
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, if (snapshot.len == 0) null else snapshot.ptr, snapshot.len);
    defer runtime.popRoots(&frame);
    var sync = SyncState{ .full_values = true };
    defer sync.deinit(runtime.allocator);
    const raw_arguments = runtime.allocator.alloc(*const RawValue, snapshot.len) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
    var initialized: usize = 0;
    defer {
        for (raw_arguments[0..initialized]) |raw| compat.lnako_qjs_value_free(@constCast(raw));
        runtime.allocator.free(raw_arguments);
    }
    for (snapshot, 0..) |value, index| {
        raw_arguments[index] = syncValueRaw(runtime, engine_value, value, &sync, 0) catch |failure| {
            compat.reportUnsupported(runtime, failure, compat.unsupported_argument_message);
            return;
        };
        initialized += 1;
    }
    // 空配列はゼロ長 alloc の ptr を C ABI へ渡さず null にする。
    const raw_pointer: [*c]const *const RawValue = if (raw_arguments.len == 0) null else raw_arguments.ptr;
    const result = compat.lnako_qjs_call(engine_value, function, raw_pointer, raw_arguments.len) orelse {
        // 失敗しても呼出し途中の JS 側変更を Nako へ反映する。refresh が
        // last_error を上書きし得るため、元の例外文言を保存してから復元する。
        const saved_error = compat.lnako_qjs_take_error(engine_value);
        for (snapshot, raw_arguments[0..initialized]) |value, argument_raw| {
            refreshFromRaw(runtime, value, @constCast(argument_raw)) catch {};
        }
        if (saved_error) |text| {
            defer compat.lnako_qjs_free_string(text);
            runtime.setFailureText(std.mem.span(text));
        } else compat.fail(runtime, engine_value);
        return;
    };
    if (compat.lnako_qjs_drain_jobs(engine_value) < 0) {
        compat.lnako_qjs_value_free(result);
        compat.fail(runtime, engine_value);
        return;
    }
    // interpreter の `externalCall` と同じく、呼出し後に JS 側の内容で実引数を
    // 再同期する（JS 側で書き換えた外側オブジェクトを Nako 側へ戻す）。
    for (snapshot, raw_arguments[0..initialized]) |value, argument_raw| {
        refreshFromRaw(runtime, value, @constCast(argument_raw)) catch |failure| {
            compat.lnako_qjs_value_free(result);
            compat.reportRefreshFailure(runtime, failure, compat.unsupported_argument_message);
            return;
        };
    }
    // Promise は interpreter の `externalCall` と同じく await せず full 変換へ
    // 通す（`JS関数実行` の呼出し経路だけが解決値を待つ）。
    out.* = jsEvalResult(runtime, result) catch |failure| {
        runtime.setFailure(failure);
        return;
    };
}

/// `JS関数実行` の戻り値変換。プリミティブに加えて、JS 配列→Nako 配列・
/// JS オブジェクト→Nako 辞書の浅いコピーだけを許可する。要素/値は
/// プリミティブに限り、ネストした配列/辞書・関数・BigInt・bytes は
/// interpreter（compat/quickjs.zig）と同じ文言の明示的な未対応エラーにする。
/// Promise は呼出し側（`lnako_aot_compat_js_call`）が await してから渡す。
/// 配列/辞書には QuickJS 参照の external binding を結び付け、`JSオブジェクト取得`
/// と`JSメソッド実行`が同じ JS オブジェクトを参照できるようにする。
/// raw は成功・失敗にかかわらず消費して解放する。
pub fn callResultFromRaw(runtime: *state.Runtime, raw: *RawValue) !Value {
    defer compat.lnako_qjs_value_free(raw);
    return switch (compat.lnako_qjs_kind(raw)) {
        .undefined, .null_value, .boolean, .number, .string => compat.primitiveFromRaw(runtime, raw),
        .array => blk: {
            const value = try shallowArrayFromRaw(runtime, raw);
            try compat.attachExternal(value, raw);
            break :blk value;
        },
        .object => blk: {
            if (compat.lnako_qjs_is_bytes(raw) != 0) return error.QuickJsUnsupportedResult;
            const value = try shallowDictionaryFromRaw(runtime, raw);
            try compat.attachExternal(value, raw);
            break :blk value;
        },
        else => error.QuickJsUnsupportedResult,
    };
}

/// 浅いコピーの要素/値。プリミティブ以外は明示的な未対応エラーにする。
fn shallowResultElement(runtime: *state.Runtime, raw: *RawValue) !Value {
    defer compat.lnako_qjs_value_free(raw);
    return compat.primitiveFromRaw(runtime, raw) catch |failure| switch (failure) {
        error.QuickJsUnsupportedValue => error.QuickJsUnsupportedResult,
        else => failure,
    };
}

fn wtf8Value(runtime: *state.Runtime, text: []const u8) !Value {
    const units = try std.unicode.wtf8ToWtf16LeAlloc(runtime.allocator, text);
    defer runtime.allocator.free(units);
    return runtime.createString(units);
}

pub fn shallowArrayFromRaw(runtime: *state.Runtime, raw: *const RawValue) !Value {
    const length = compat.lnako_qjs_array_length(raw);
    // `length = 0xFFFFFFFF` のような疎配列で数十GBを一括確保しないよう、
    // AOTの配列上限と同じ制限を浅いコピーにも適用する。
    if (length > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
    const items = try runtime.allocator.alloc(Value, length);
    defer runtime.allocator.free(items);
    @memset(items, .{});
    // 変換中の要素をGC rootへ載せる。空配列はalloc(0)のptrをrootへ渡さない。
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, if (length == 0) null else items.ptr, length);
    defer runtime.popRoots(&frame);
    for (0..length) |index| {
        const item = compat.lnako_qjs_get_index(raw, @intCast(index)) orelse return conversionFailure(runtime, raw);
        items[index] = try shallowResultElement(runtime, item);
    }
    return runtime.createArray(items);
}

pub fn shallowDictionaryFromRaw(runtime: *state.Runtime, raw: *const RawValue) !Value {
    const keys = compat.lnako_qjs_keys(raw) orelse return error.QuickJsConversionFailed;
    defer compat.lnako_qjs_keys_free(keys);
    const count = compat.lnako_qjs_keys_length(keys);
    if (count > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
    const pair_length = std.math.mul(usize, count, 2) catch return error.QuickJsCollectionTooLarge;
    const pairs = try runtime.allocator.alloc(Value, pair_length);
    defer runtime.allocator.free(pairs);
    @memset(pairs, .{});
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, if (pair_length == 0) null else pairs.ptr, pair_length);
    defer runtime.popRoots(&frame);
    var initialized: usize = 0;
    for (0..count) |index| {
        var name_length: usize = 0;
        const name_pointer = compat.lnako_qjs_key(keys, index, &name_length) orelse continue;
        const name = name_pointer[0..name_length];
        const name_z = try runtime.allocator.dupeSentinel(u8, name, 0);
        defer runtime.allocator.free(name_z);
        const item = compat.lnako_qjs_get_property(raw, name_z.ptr) orelse return conversionFailure(runtime, raw);
        // 要素値を先に作ってpairs（root frame）へ載せ、その後キー文字列を作る。
        // 逆順だとキー生成中のGCで要素値が未rootのまま回収され得る。
        pairs[initialized + 1] = try shallowResultElement(runtime, item);
        pairs[initialized] = try wtf8Value(runtime, name);
        initialized += 2;
    }
    return runtime.createDictionary(pairs[0..initialized]);
}

/// `JSオブジェクト取得` / `JSメソッド実行` の戻り値変換。`JS関数実行` の浅い
/// 規則（`callResultFromRaw`）と違い、配列/辞書は再帰的に変換し、各配列/辞書へ
/// external bindingを付与する。関数とbytesはこの経路では明示的な未対応エラーに
/// する。BigIntは呼出し後の再同期（refresh）と変換規則を共有するため保持する。
/// rawは消費する。
pub fn resultFromRaw(runtime: *state.Runtime, raw: *RawValue) !Value {
    var seen: std.AutoHashMapUnmanaged(usize, Value) = .empty;
    defer seen.deinit(runtime.allocator);
    return convertResult(runtime, raw, &seen, 0);
}

/// 変換途中のQuickJS例外を失わずに報告する。bridgeがNULLを返した場合は
/// engineのlast_errorをruntimeへ記録し、二重設定を避ける内部エラーを返す。
fn conversionFailure(runtime: *state.Runtime, raw: *const RawValue) anyerror {
    const engine_value = compat.lnako_qjs_value_engine(raw) orelse return error.QuickJsConversionFailed;
    compat.fail(runtime, engine_value);
    return compat.reported_engine_failure;
}

fn convertResult(runtime: *state.Runtime, raw: *RawValue, seen: *std.AutoHashMapUnmanaged(usize, Value), depth: usize) anyerror!Value {
    if (depth >= max_interop_conversion_depth) {
        compat.lnako_qjs_value_free(raw);
        return error.QuickJsNestingTooDeep;
    }
    defer compat.lnako_qjs_value_free(raw);
    return switch (compat.lnako_qjs_kind(raw)) {
        .undefined, .null_value, .boolean, .number, .string => compat.primitiveFromRaw(runtime, raw),
        .bigint => blk: {
            // 呼出し後の再同期（refresh）で BigInt プロパティを失わないよう、
            // interpreter の full 変換と同じ10進文字列経路で作る。
            var length: usize = 0;
            const text = compat.lnako_qjs_to_string(raw, &length) orelse return error.QuickJsConversionFailed;
            defer compat.lnako_qjs_free_string(text);
            break :blk try runtime.createBigInt(text[0..length]);
        },
        .array => convertResultArray(runtime, raw, seen, depth),
        .object => blk: {
            if (compat.lnako_qjs_is_bytes(raw) != 0) return error.QuickJsUnsupportedResult;
            break :blk convertResultDictionary(runtime, raw, seen, depth);
        },
        else => error.QuickJsUnsupportedResult,
    };
}

fn convertResultArray(runtime: *state.Runtime, raw: *RawValue, seen: *std.AutoHashMapUnmanaged(usize, Value), depth: usize) anyerror!Value {
    const identity = compat.lnako_qjs_identity(raw);
    if (seen.get(identity)) |existing| return existing;
    const length = compat.lnako_qjs_array_length(raw);
    if (length > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
    // 空配列を先に作り、埋める前にseenへ登録する。自己参照配列は同じObjectを
    // 指すため、interpreterのconvertArrayと同じ循環表現になる。
    var result = try runtime.createArray(&.{});
    var result_frame: state.RootFrame = .{};
    runtime.pushRoots(&result_frame, @ptrCast(&result), 1);
    defer runtime.popRoots(&result_frame);
    try seen.put(runtime.allocator, identity, result);
    const object = result.object() orelse return error.QuickJsConversionFailed;
    for (0..length) |index| {
        const present = compat.lnako_qjs_has_index(raw, @intCast(index));
        if (present < 0) return conversionFailure(runtime, raw);
        if (present == 0) {
            // JSの穴はNako側でもpresence=falseの穴として保持する。
            try runtime.aotArrayAppend(object, .{});
            _ = try runtime.aotArrayDeleteIndex(object, index);
            continue;
        }
        const item = compat.lnako_qjs_get_index(raw, @intCast(index)) orelse return conversionFailure(runtime, raw);
        var roots = [_]Value{.{}};
        var entry_frame: state.RootFrame = .{};
        runtime.pushRoots(&entry_frame, &roots, roots.len);
        defer runtime.popRoots(&entry_frame);
        roots[0] = try convertResult(runtime, item, seen, depth + 1);
        try runtime.aotArrayAppend(object, roots[0]);
    }
    try compat.attachExternal(result, raw);
    return result;
}

fn convertResultDictionary(runtime: *state.Runtime, raw: *RawValue, seen: *std.AutoHashMapUnmanaged(usize, Value), depth: usize) anyerror!Value {
    const identity = compat.lnako_qjs_identity(raw);
    if (seen.get(identity)) |existing| return existing;
    const keys = compat.lnako_qjs_keys(raw) orelse return error.QuickJsConversionFailed;
    defer compat.lnako_qjs_keys_free(keys);
    const count = compat.lnako_qjs_keys_length(keys);
    if (count > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
    var result = try runtime.createDictionary(&.{});
    var result_frame: state.RootFrame = .{};
    runtime.pushRoots(&result_frame, @ptrCast(&result), 1);
    defer runtime.popRoots(&result_frame);
    try seen.put(runtime.allocator, identity, result);
    for (0..count) |index| {
        var name_length: usize = 0;
        const name_pointer = compat.lnako_qjs_key(keys, index, &name_length) orelse continue;
        const name = name_pointer[0..name_length];
        const name_z = try runtime.allocator.dupeSentinel(u8, name, 0);
        defer runtime.allocator.free(name_z);
        // キー生成に失敗した場合にitemの所有権が未移転のまま漏れないよう、先に作る。
        const key = try wtf8Value(runtime, name);
        const item = compat.lnako_qjs_get_property(raw, name_z.ptr) orelse return conversionFailure(runtime, raw);
        // キー文字列をrootし、値の変換でGCが走っても回収されないようにする。
        var roots = [_]Value{ key, .{} };
        var entry_frame: state.RootFrame = .{};
        runtime.pushRoots(&entry_frame, &roots, roots.len);
        defer runtime.popRoots(&entry_frame);
        roots[1] = try convertResult(runtime, item, seen, depth + 1);
        try runtime.setDictionary(&result.object().?.payload.dictionary, roots[0], roots[1]);
    }
    try compat.attachExternal(result, raw);
    return result;
}

/// JS値でNako側コピーを再構築する（interpreterの`refreshExternal`相当）。
/// JS側でメソッドが実引数/レシーバの配列・辞書を変更した場合に、次の呼出しで
/// 古いNako内容を書き戻してしまうのを防ぐ。external bindingの有無にかかわらず、
/// 呼出し時に作ったJS値（externalなら同じJS参照のdup、plainならJSコピー）から
/// 再構築する。途中で変換に失敗しても元の内容を失わないよう、まず一時的な
/// 配列/辞書へ構築し、成功後に中身だけ差し替える（Nako Objectの同一性は保つ）。
pub fn refreshFromRaw(runtime: *state.Runtime, value: Value, raw: *RawValue) anyerror!void {
    const tag = @as(Tag, @fromBackingInt(value.tag));
    if (tag != .array and tag != .dictionary) return;
    const object = value.object() orelse return;
    if (compat.lnako_qjs_identity(raw) == 0) return;
    var seen: std.AutoHashMapUnmanaged(usize, Value) = .empty;
    defer seen.deinit(runtime.allocator);
    try seen.put(runtime.allocator, compat.lnako_qjs_identity(raw), value);
    switch (tag) {
        .array => {
            const length = compat.lnako_qjs_array_length(raw);
            if (length > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
            var fresh = try runtime.createArray(&.{});
            var fresh_frame: state.RootFrame = .{};
            runtime.pushRoots(&fresh_frame, @ptrCast(&fresh), 1);
            defer runtime.popRoots(&fresh_frame);
            const fresh_object = fresh.object() orelse return error.QuickJsConversionFailed;
            for (0..length) |index| {
                const present = compat.lnako_qjs_has_index(raw, @intCast(index));
                if (present < 0) return conversionFailure(runtime, raw);
                if (present == 0) {
                    try runtime.aotArrayAppend(fresh_object, .{});
                    _ = try runtime.aotArrayDeleteIndex(fresh_object, index);
                    continue;
                }
                const item = compat.lnako_qjs_get_index(raw, @intCast(index)) orelse return conversionFailure(runtime, raw);
                try appendRefreshedItem(runtime, fresh_object, item, &seen);
            }
            std.mem.swap(std.ArrayList(Value), &object.payload.array, &fresh_object.payload.array);
            std.mem.swap(std.ArrayList(bool), &object.array_presence, &fresh_object.array_presence);
        },
        .dictionary => {
            const keys = compat.lnako_qjs_keys(raw) orelse return error.QuickJsConversionFailed;
            defer compat.lnako_qjs_keys_free(keys);
            const count = compat.lnako_qjs_keys_length(keys);
            if (count > state.safe_array_element_limit) return error.QuickJsCollectionTooLarge;
            var fresh = try runtime.createDictionary(&.{});
            var fresh_frame: state.RootFrame = .{};
            runtime.pushRoots(&fresh_frame, @ptrCast(&fresh), 1);
            defer runtime.popRoots(&fresh_frame);
            const fresh_object = fresh.object() orelse return error.QuickJsConversionFailed;
            for (0..count) |index| {
                var name_length: usize = 0;
                const name_pointer = compat.lnako_qjs_key(keys, index, &name_length) orelse continue;
                const name = name_pointer[0..name_length];
                const name_z = try runtime.allocator.dupeSentinel(u8, name, 0);
                defer runtime.allocator.free(name_z);
                const item = compat.lnako_qjs_get_property(raw, name_z.ptr) orelse return conversionFailure(runtime, raw);
                try setRefreshedEntry(runtime, fresh_object, name, item, &seen);
            }
            std.mem.swap(state.AotDictionary, &object.payload.dictionary, &fresh_object.payload.dictionary);
        },
        else => {},
    }
}

fn appendRefreshedItem(runtime: *state.Runtime, object: *state.Object, item: *RawValue, seen: *std.AutoHashMapUnmanaged(usize, Value)) !void {
    var roots = [_]Value{try convertFull(runtime, item, seen, 1)};
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try runtime.aotArrayAppend(object, roots[0]);
}

fn setRefreshedEntry(runtime: *state.Runtime, object: *state.Object, name: []const u8, item: *RawValue, seen: *std.AutoHashMapUnmanaged(usize, Value)) !void {
    // キー生成に失敗した場合はitemの所有権がまだ移っていないため、ここで解放する。
    var roots = [_]Value{ wtf8Value(runtime, name) catch |failure| {
        compat.lnako_qjs_value_free(item);
        return failure;
    }, .{} };
    var frame: state.RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    // callback後のrefreshはfull変換にする。辞書直下の関数だけでなく、配列要素や
    // ネストした値に入った関数・BigInt・Promise・bytesも`JS実行`と同じ規則で
    // 保持する（`seen` が循環参照も維持する）。
    roots[1] = try convertFull(runtime, item, seen, 1);
    try runtime.setDictionary(&object.payload.dictionary, roots[0], roots[1]);
}
