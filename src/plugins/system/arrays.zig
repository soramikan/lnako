const std = @import("std");
const value_mod = @import("../../runtime/value.zig");
const shared = @import("arrays/shared.zig");
pub const Value = shared.Value;
pub const Runtime = shared.Runtime;
pub const ByteKind = shared.ByteKind;
pub const Context = shared.Context;

const common = @import("common.zig");
const core = @import("arrays/core.zig");
const map_mod = @import("arrays/map.zig");
const sort = @import("arrays/sort.zig");
const table = @import("arrays/table.zig");
const TestMutatingSortContext = sort.TestMutatingSortContext;
const TestSortOrderContext = sort.TestSortOrderContext;
const ZeroRandomContext = sort.ZeroRandomContext;
const arrayAdd = core.arrayAdd;
const arraySearch = core.arraySearch;
const cut = core.cut;
pub const deepClone = core.deepClone;
const elementCount = core.elementCount;
const eql = shared.eql;
const fill = core.fill;
const indexed = shared.indexed;
const insertMany = core.insertMany;
const insertOne = core.insertOne;
const isAny = shared.isAny;
const isNegativeZero = core.isNegativeZero;
const join = core.join;
const map = map_mod.map;
const numericConvert = core.numericConvert;
const pop = core.pop;
const propertyIndexUnits = shared.propertyIndexUnits;
const push = core.push;
const rangeCopy = core.rangeCopy;
const reduceExtremum = core.reduceExtremum;
const reference = core.reference;
const reverse = core.reverse;
const sequence = core.sequence;
const shuffle = sort.shuffle;
const sortCustom = sort.sortCustom;
const sortDefault = sort.sortDefault;
const sortNumeric = sort.sortNumeric;
const sum = core.sum;
const swap = core.swap;
const tableColumn = table.tableColumn;
const tableColumnCount = table.tableColumnCount;
const tableColumnSum = table.tableColumnSum;
const tableDeleteColumn = table.tableDeleteColumn;
const tableInsertColumn = table.tableInsertColumn;
const tablePickup = table.tablePickup;
const tableRegexpPickup = table.tableRegexpPickup;
const tableRegexpSearch = table.tableRegexpSearch;
const tableRowCount = table.tableRowCount;
const tableSearch = table.tableSearch;
const tableSort = table.tableSort;
const tableUnique = table.tableUnique;
const take = core.take;
const testElementCountFunction = shared.testElementCountFunction;
const transpose = table.transpose;
const prototype_mod = @import("arrays/prototype.zig");
pub const byteBufferBufferEnumerablePropertyNames = prototype_mod.byteBufferBufferEnumerablePropertyNames;
pub const byteBufferAllowsStandardPrototype = prototype_mod.byteBufferAllowsStandardPrototype;
pub const hasStandardInheritedProperty = prototype_mod.hasStandardInheritedProperty;
pub const standardInheritedProperty = prototype_mod.standardInheritedProperty;

pub fn call(runtime: *Runtime, name: []const u8, arguments: []const Value, context: ?Context) !?Value {
    const a = common.argument(arguments, 0);
    const b = common.argument(arguments, 1);
    const c = common.argument(arguments, 2);
    if (isAny(name, &.{ "配列結合", "配列只結合" })) return try join(runtime, a, if (eql(name, "配列只結合")) try runtime.stringUtf8("") else b);
    if (eql(name, "配列検索")) return .{ .number = @floatFromInt(arraySearch(a, b)) };
    if (isAny(name, &.{ "配列要素数", "要素数", "LEN" })) return .{ .number = @floatFromInt(elementCount(a)) };
    if (eql(name, "配列挿入")) return try insertOne(runtime, a, b, c);
    if (eql(name, "配列一括挿入")) return try insertMany(runtime, a, b, c);
    if (eql(name, "配列ソート")) return try sortDefault(runtime, a);
    if (eql(name, "配列数値変換")) return try numericConvert(runtime, a);
    if (eql(name, "配列数値ソート")) return try sortNumeric(runtime, a);
    if (eql(name, "配列カスタムソート")) return try sortCustom(runtime, a, b, context);
    if (eql(name, "配列逆順")) return try reverse(a);
    if (eql(name, "配列シャッフル")) return try shuffle(a, context);
    if (isAny(name, &.{ "配列削除", "配列切取" })) return try cut(runtime, a, b);
    if (eql(name, "配列取出")) return try take(runtime, a, b, c);
    if (eql(name, "配列ポップ")) return try pop(a);
    if (isAny(name, &.{ "配列プッシュ", "配列追加" })) return try push(a, b);
    if (eql(name, "配列複製")) return try deepClone(runtime, a);
    if (eql(name, "配列範囲コピー")) return try rangeCopy(runtime, a, b);
    if (isAny(name, &.{ "参照", "配列参照" })) return try reference(runtime, a, b);
    if (eql(name, "配列足")) return try arrayAdd(runtime, a, b);
    if (eql(name, "配列最大値")) return try reduceExtremum(runtime, a, true);
    if (eql(name, "配列最小値")) return try reduceExtremum(runtime, a, false);
    if (eql(name, "配列合計")) return try sum(runtime, a);
    if (eql(name, "配列入替")) return try swap(runtime, a, b, c);
    if (eql(name, "配列連番作成")) return try sequence(runtime, a, b);
    if (eql(name, "配列要素作成")) return try fill(runtime, a, b);
    if (isAny(name, &.{ "配列関数適用", "配列マップ" })) return try map(runtime, a, b, context, false);
    if (eql(name, "配列フィルタ")) return try map(runtime, a, b, context, true);

    if (eql(name, "表ソート")) return try tableSort(runtime, a, b, false);
    if (eql(name, "表数値ソート")) return try tableSort(runtime, a, b, true);
    if (eql(name, "表ピックアップ")) return try tablePickup(runtime, a, b, c, false);
    if (eql(name, "表完全一致ピックアップ")) return try tablePickup(runtime, a, b, c, true);
    if (eql(name, "表検索")) return try tableSearch(runtime, a, b, c, common.argument(arguments, 3));
    if (eql(name, "表列数")) return try tableColumnCount(runtime, a);
    if (eql(name, "表行数")) return try tableRowCount(a);
    if (eql(name, "表行列交換")) return try transpose(runtime, a, false);
    if (eql(name, "表右回転")) return try transpose(runtime, a, true);
    if (eql(name, "表重複削除")) return try tableUnique(runtime, a, b);
    if (eql(name, "表列取得")) return try tableColumn(runtime, a, b);
    if (eql(name, "表列挿入")) return try tableInsertColumn(runtime, a, b, c);
    if (eql(name, "表列削除")) return try tableDeleteColumn(runtime, a, b);
    if (eql(name, "表列合計")) return try tableColumnSum(runtime, a, b);
    if (eql(name, "表曖昧検索")) return try tableRegexpSearch(runtime, a, b, c, common.argument(arguments, 3));
    if (eql(name, "表正規表現ピックアップ")) return try tableRegexpPickup(runtime, a, b, c);
    return null;
}

test "参照は辞書と配列の標準prototype propertyを解決する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var dictionary = try runtime.createDictionary();
    try roots.protect(&dictionary);
    var array = try common.arrayFromValues(&runtime, &.{.{ .number = 1 }});
    try roots.protect(&array);
    var to_string_key = try runtime.stringUtf8("toString");
    try roots.protect(&to_string_key);
    var constructor_key = try runtime.stringUtf8("constructor");
    try roots.protect(&constructor_key);
    var proto_key = try runtime.stringUtf8("__proto__");
    try roots.protect(&proto_key);
    var map_key = try runtime.stringUtf8("map");
    try roots.protect(&map_key);
    var name_key = try runtime.stringUtf8("name");
    try roots.protect(&name_key);

    var dictionary_method = try reference(&runtime, dictionary, to_string_key);
    try roots.protect(&dictionary_method);
    try std.testing.expect(dictionary_method == .function);
    var dictionary_constructor = try reference(&runtime, dictionary, constructor_key);
    try roots.protect(&dictionary_constructor);
    try std.testing.expect(dictionary_constructor == .function);
    var dictionary_constructor_name = try indexed(&runtime, dictionary_constructor, name_key);
    try roots.protect(&dictionary_constructor_name);
    try std.testing.expectEqualSlices(u16, &.{ 'O', 'b', 'j', 'e', 'c', 't' }, dictionary_constructor_name.string.units);
    var dictionary_proto = try reference(&runtime, dictionary, proto_key);
    try roots.protect(&dictionary_proto);
    try std.testing.expect(dictionary_proto == .dictionary);

    var array_method = try reference(&runtime, array, map_key);
    try roots.protect(&array_method);
    try std.testing.expect(array_method == .function);
    var alias_method = (try call(&runtime, "配列参照", &.{ array, to_string_key }, null)).?;
    try roots.protect(&alias_method);
    try std.testing.expect(alias_method == .function);

    const dictionary_method_again = try reference(&runtime, dictionary, to_string_key);
    try std.testing.expect(dictionary_method_again == .function);
    try std.testing.expect(dictionary_method_again.function == dictionary_method.function);
    const array_method_again = try reference(&runtime, array, map_key);
    try std.testing.expect(array_method_again == .function);
    try std.testing.expect(array_method_again.function == array_method.function);
    const array_to_string = try reference(&runtime, array, to_string_key);
    try std.testing.expect(array_to_string == .function);
    try std.testing.expect(array_to_string.function != dictionary_method.function);

    var has_own_key = try runtime.stringUtf8("hasOwnProperty");
    try roots.protect(&has_own_key);
    const dictionary_has_own = try reference(&runtime, dictionary, has_own_key);
    const array_has_own = try reference(&runtime, array, has_own_key);
    try std.testing.expect(dictionary_has_own == .function);
    try std.testing.expect(array_has_own == .function);
    try std.testing.expect(dictionary_has_own.function == array_has_own.function);

    const dictionary_constructor_again = try reference(&runtime, dictionary, constructor_key);
    const array_constructor = try reference(&runtime, array, constructor_key);
    try std.testing.expect(dictionary_constructor_again.function == dictionary_constructor.function);
    try std.testing.expect(array_constructor.function != dictionary_constructor.function);

    const dictionary_proto_again = try reference(&runtime, dictionary, proto_key);
    const array_proto = try reference(&runtime, array, proto_key);
    try std.testing.expect(dictionary_proto_again.dictionary == dictionary_proto.dictionary);
    try std.testing.expect(!Value.strictEqual(array_proto, dictionary_proto));
    const array_proto_again = try reference(&runtime, array, proto_key);
    try std.testing.expect(array_proto_again.array == array_proto.array);

    try dictionary.dictionary.set(to_string_key.string, .{ .number = 7 });
    var own_value = try reference(&runtime, dictionary, to_string_key);
    try roots.protect(&own_value);
    try std.testing.expectEqual(@as(f64, 7), own_value.number);
}

test "関数とPromiseの要素数はObject.keysと同じ0にする" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var name = try runtime.stringUtf8("F");
    try roots.protect(&name);
    var function = try runtime.createNativeFunction(name.string, 0, testElementCountFunction, &.{});
    try roots.protect(&function);
    var promise = try runtime.createPromise();
    try roots.protect(&promise);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "配列要素数", &.{function}, null)).?.number);
    try std.testing.expectEqual(@as(f64, 0), (try call(&runtime, "LEN", &.{promise}, null)).?.number);
}

test "配列と表の破壊的操作・コピー・検索を処理する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var array = try common.arrayFromValues(&runtime, &.{ .{ .number = 3 }, .{ .number = 1 }, .{ .number = 2 } });
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&array);
    _ = (try call(&runtime, "配列数値ソート", &.{array}, null)).?;
    try std.testing.expectEqual(@as(f64, 1), array.array.get(0).number);
    _ = (try call(&runtime, "配列挿入", &.{ array, .{ .number = 1 }, .{ .number = 9 } }, null)).?;
    try std.testing.expectEqual(@as(f64, 9), array.array.get(1).number);
    const copy = (try call(&runtime, "配列範囲コピー", &.{ array, .{ .number = 1 } }, null)).?;
    try std.testing.expectEqual(@as(f64, 9), copy.number);
}

test "カスタムソート中に元配列が短縮されても収集済み要素を安全に書き戻す" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var array = try common.arrayFromValues(&runtime, &.{ .{ .number = 3 }, .{ .number = 1 }, .{ .number = 2 } });
    try roots.protect(&array);
    var name = try runtime.stringUtf8("配列短縮比較");
    try roots.protect(&name);
    var function = try runtime.createNativeFunction(name.string, 2, testElementCountFunction, &.{});
    try roots.protect(&function);
    var test_context = TestMutatingSortContext{ .target = array.array };

    const result = (try call(&runtime, "配列カスタムソート", &.{ function, array }, .{
        .context = &test_context,
        .callFn = TestMutatingSortContext.invoke,
    })).?;

    try std.testing.expect(result.array == array.array);
    try std.testing.expect(test_context.mutated);
    try std.testing.expectEqual(@as(usize, 3), array.array.len());
    try std.testing.expectEqual(@as(f64, 1), array.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 2), array.array.get(1).number);
    try std.testing.expectEqual(@as(f64, 3), array.array.get(2).number);
}

test "カスタムソートの小配列比較順はV8のrun検出規則を保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    var array = try common.arrayFromValues(&runtime, &.{ .{ .number = 3 }, .{ .number = 1 }, .{ .number = 2 } });
    try roots.protect(&array);
    var name = try runtime.stringUtf8("配列比較順");
    try roots.protect(&name);
    var function = try runtime.createNativeFunction(name.string, 2, testElementCountFunction, &.{});
    try roots.protect(&function);
    var context = TestSortOrderContext{};

    _ = try call(&runtime, "配列カスタムソート", &.{ function, array }, .{
        .context = &context,
        .callFn = TestSortOrderContext.invoke,
    });

    try std.testing.expectEqual(@as(usize, 4), context.count);
    try std.testing.expectEqualSlices([2]f64, &.{ .{ 1, 3 }, .{ 2, 1 }, .{ 2, 3 }, .{ 2, 1 } }, context.pairs[0..context.count]);
    try std.testing.expectEqual(@as(f64, 1), array.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 2), array.array.get(1).number);
    try std.testing.expectEqual(@as(f64, 3), array.array.get(2).number);
}

test "配列ソート系は安定な破壊的操作とundefined末尾を保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var astral = try runtime.stringUtf8("😀");
    try roots.protect(&astral);
    var private_use = try runtime.stringCodeUnits(&.{0xe000});
    try roots.protect(&private_use);
    var ascii = try runtime.stringUtf8("A");
    try roots.protect(&ascii);
    var values = try common.arrayFromValues(&runtime, &.{ private_use, .undefined, astral, ascii });
    try roots.protect(&values);
    const sorted = (try call(&runtime, "配列ソート", &.{values}, null)).?;
    try std.testing.expectEqual(values.array, sorted.array);
    try std.testing.expectEqualSlices(u16, &.{'A'}, values.array.get(0).string.units);
    try std.testing.expectEqual(astral.string, values.array.get(1).string);
    try std.testing.expectEqual(private_use.string, values.array.get(2).string);
    try std.testing.expectEqual(Value.undefined, values.array.get(3));

    var numeric_text = try runtime.stringUtf8("2x");
    try roots.protect(&numeric_text);
    var numeric = try common.arrayFromValues(&runtime, &.{ numeric_text, .undefined, .{ .number = 10 }, .{ .number = std.math.nan(f64) }, .{ .number = -0.0 }, .{ .number = 0.0 } });
    try roots.protect(&numeric);
    const numeric_sorted = (try call(&runtime, "配列数値ソート", &.{numeric}, null)).?;
    try std.testing.expectEqual(numeric.array, numeric_sorted.array);
    try std.testing.expect(isNegativeZero(numeric.array.get(0).number));
    try std.testing.expect(!isNegativeZero(numeric.array.get(1).number));
    try std.testing.expectEqual(numeric_text.string, numeric.array.get(2).string);
    try std.testing.expectEqual(@as(f64, 10), numeric.array.get(3).number);
    try std.testing.expect(std.math.isNan(numeric.array.get(4).number));
    try std.testing.expectEqual(Value.undefined, numeric.array.get(5));

    const converted = (try call(&runtime, "配列数値変換", &.{numeric}, null)).?;
    try std.testing.expectEqual(numeric.array, converted.array);
    try std.testing.expectEqual(std.meta.Tag(Value).number, std.meta.activeTag(numeric.array.get(2)));
    const reversed = (try call(&runtime, "配列逆順", &.{numeric}, null)).?;
    try std.testing.expectEqual(numeric.array, reversed.array);
    try std.testing.expect(std.math.isNan(numeric.array.get(0).number));
}

test "疎配列の順序操作は値とpresenceの公式境界を保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var sorted = try runtime.createArray();
    try roots.protect(&sorted);
    try sorted.array.set(0, .{ .number = 3 });
    try sorted.array.set(2, .{ .number = 1 });
    try sorted.array.set(3, .undefined);
    _ = try call(&runtime, "配列ソート", &.{sorted}, null);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, sorted.array.presence.items);
    try std.testing.expectEqual(@as(f64, 1), sorted.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 3), sorted.array.get(1).number);
    try std.testing.expectEqual(Value.undefined, sorted.array.get(2));
    try std.testing.expectEqual(Value.undefined, sorted.array.get(3));

    var numeric = try runtime.createArray();
    try roots.protect(&numeric);
    try numeric.array.set(0, .{ .number = 10 });
    try numeric.array.set(2, .{ .number = 2 });
    try numeric.array.set(3, .undefined);
    _ = try call(&runtime, "配列数値ソート", &.{numeric}, null);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, numeric.array.presence.items);
    try std.testing.expectEqual(@as(f64, 2), numeric.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 10), numeric.array.get(1).number);
    try std.testing.expectEqual(Value.undefined, numeric.array.get(2));

    var converted = try runtime.createArray();
    try roots.protect(&converted);
    try converted.array.set(0, .undefined);
    try converted.array.set(2, .{ .number = 4 });
    _ = try call(&runtime, "配列数値変換", &.{converted}, null);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, converted.array.presence.items);
    try std.testing.expect(std.math.isNan(converted.array.get(0).number));
    try std.testing.expect(std.math.isNan(converted.array.get(1).number));
    try std.testing.expectEqual(@as(f64, 4), converted.array.get(2).number);

    var reversed = try runtime.createArray();
    try roots.protect(&reversed);
    try reversed.array.set(0, .{ .number = 1 });
    try reversed.array.set(2, .{ .number = 3 });
    _ = try call(&runtime, "配列逆順", &.{reversed}, null);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, reversed.array.presence.items);
    try std.testing.expectEqual(@as(f64, 3), reversed.array.get(0).number);
    try std.testing.expectEqual(Value.undefined, reversed.array.get(1));
    try std.testing.expectEqual(@as(f64, 1), reversed.array.get(2).number);

    var shuffled = try runtime.createArray();
    try roots.protect(&shuffled);
    try shuffled.array.set(0, .{ .number = 1 });
    try shuffled.array.set(2, .{ .number = 3 });
    var random_state: u8 = 0;
    _ = try call(&runtime, "配列シャッフル", &.{shuffled}, .{
        .context = &random_state,
        .randomFn = ZeroRandomContext.next,
    });
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, shuffled.array.presence.items);
    try std.testing.expectEqual(Value.undefined, shuffled.array.get(0));
    try std.testing.expectEqual(@as(f64, 3), shuffled.array.get(1).number);
    try std.testing.expectEqual(@as(f64, 1), shuffled.array.get(2).number);
}

test "疎配列のsplice系操作は削除側と戻り値側のpresenceを移動する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var removed_source = try runtime.createArray();
    try roots.protect(&removed_source);
    try removed_source.array.set(0, .{ .number = 1 });
    try removed_source.array.set(2, .{ .number = 3 });
    const removed = (try call(&runtime, "配列削除", &.{ removed_source, .{ .number = 1 } }, null)).?;
    try std.testing.expectEqual(Value.undefined, removed);
    try std.testing.expectEqualSlices(bool, &.{ true, true }, removed_source.array.presence.items);
    try std.testing.expectEqual(@as(f64, 3), removed_source.array.get(1).number);

    var taken_source = try runtime.createArray();
    try roots.protect(&taken_source);
    try taken_source.array.set(0, .{ .number = 1 });
    try taken_source.array.set(2, .{ .number = 3 });
    const taken = (try call(&runtime, "配列取出", &.{ taken_source, .{ .number = 1 }, .{ .number = 2 } }, null)).?;
    try std.testing.expectEqualSlices(bool, &.{ false, true }, taken.array.presence.items);
    try std.testing.expectEqual(Value.undefined, taken.array.get(0));
    try std.testing.expectEqual(@as(f64, 3), taken.array.get(1).number);
    try std.testing.expectEqualSlices(bool, &.{true}, taken_source.array.presence.items);
    try std.testing.expectEqual(@as(f64, 1), taken_source.array.get(0).number);

    var inserted = try runtime.createArray();
    try roots.protect(&inserted);
    try inserted.array.set(0, .{ .number = 1 });
    try inserted.array.set(2, .{ .number = 3 });
    _ = try call(&runtime, "配列挿入", &.{ inserted, .{ .number = 1 }, .{ .number = 9 } }, null);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true }, inserted.array.presence.items);
    try std.testing.expectEqual(@as(f64, 9), inserted.array.get(1).number);
    try std.testing.expectEqual(@as(f64, 3), inserted.array.get(3).number);

    var bulk = try runtime.createArray();
    try roots.protect(&bulk);
    try bulk.array.set(0, .{ .number = 1 });
    try bulk.array.set(2, .{ .number = 3 });
    var values = try runtime.createArray();
    try roots.protect(&values);
    try values.array.set(1, .{ .number = 7 });
    _ = try call(&runtime, "配列一括挿入", &.{ bulk, .{ .number = 1 }, values }, null);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false, true }, bulk.array.presence.items);
    try std.testing.expectEqual(Value.undefined, bulk.array.get(1));
    try std.testing.expectEqual(@as(f64, 7), bulk.array.get(2).number);
    try std.testing.expectEqual(@as(f64, 3), bulk.array.get(4).number);
}

test "配列コピーと参照はJSONとJavaScript添字の境界を保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var clone_failed = false;
    _ = deepClone(&runtime, .undefined) catch {
        clone_failed = true;
    };
    try std.testing.expect(clone_failed);

    var source = try common.arrayFromValues(&runtime, &.{.undefined});
    try roots.protect(&source);
    var range = try runtime.createDictionary();
    try roots.protect(&range);
    var first_key = try runtime.stringUtf8("先頭");
    try roots.protect(&first_key);
    var last_key = try runtime.stringUtf8("末尾");
    try roots.protect(&last_key);
    try range.dictionary.set(first_key.string, .{ .number = 0 });
    try range.dictionary.set(last_key.string, .{ .number = 0 });
    var copied = try rangeCopy(&runtime, source, range);
    try roots.protect(&copied);
    try std.testing.expectEqual(Value.null_value, copied.array.get(0));

    var text = try runtime.stringUtf8("ABC");
    try roots.protect(&text);
    var character = try reference(&runtime, text, .{ .number = 1.9 });
    try roots.protect(&character);
    try std.testing.expectEqualSlices(u16, &.{'B'}, character.string.units);
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, source, .{ .number = 0.9 }));

    try range.dictionary.set(first_key.string, .{ .number = 1e100 });
    try range.dictionary.set(last_key.string, .{ .number = 1e100 });
    var empty = try reference(&runtime, text, range);
    try roots.protect(&empty);
    try std.testing.expectEqual(@as(usize, 0), empty.string.len());

    var cut_source = try common.arrayFromValues(&runtime, &.{ .{ .number = 0 }, .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } });
    try roots.protect(&cut_source);
    try range.dictionary.set(first_key.string, .{ .number = -2 });
    try range.dictionary.set(last_key.string, .{ .number = -1 });
    var removed = try cut(&runtime, cut_source, range);
    try roots.protect(&removed);
    try std.testing.expectEqual(@as(f64, 2), removed.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 3), removed.array.get(1).number);
    try std.testing.expectEqual(@as(usize, 2), cut_source.array.len());

    var range_source = try common.arrayFromValues(&runtime, &.{ .{ .number = 0 }, .{ .number = 1 }, .{ .number = 2 }, .{ .number = 3 } });
    try roots.protect(&range_source);
    var zero_bigint = try runtime.bigIntLiteral("0n");
    try roots.protect(&zero_bigint);
    var one_bigint = try runtime.bigIntLiteral("1n");
    try roots.protect(&one_bigint);
    var negative_bigint = try runtime.bigIntLiteral("-2n");
    try roots.protect(&negative_bigint);
    var huge_positive_bigint = try runtime.bigIntLiteral("9007199254740993n");
    try roots.protect(&huge_positive_bigint);
    var huge_negative_bigint = try runtime.bigIntLiteral("-9007199254740993n");
    try roots.protect(&huge_negative_bigint);
    try range.dictionary.set(first_key.string, .{ .number = 0 });
    try range.dictionary.set(last_key.string, zero_bigint);
    var bigint_zero_copy = try rangeCopy(&runtime, range_source, range);
    try roots.protect(&bigint_zero_copy);
    try std.testing.expectEqual(@as(usize, 1), bigint_zero_copy.array.len());
    try range.dictionary.set(last_key.string, one_bigint);
    var bigint_one_copy = try rangeCopy(&runtime, range_source, range);
    try roots.protect(&bigint_one_copy);
    try std.testing.expectEqual(@as(usize, 2), bigint_one_copy.array.len());
    try range.dictionary.set(last_key.string, negative_bigint);
    var bigint_negative_copy = try rangeCopy(&runtime, range_source, range);
    try roots.protect(&bigint_negative_copy);
    try std.testing.expectEqual(@as(usize, 3), bigint_negative_copy.array.len());
    try range.dictionary.set(last_key.string, huge_positive_bigint);
    var bigint_huge_copy = try rangeCopy(&runtime, range_source, range);
    try roots.protect(&bigint_huge_copy);
    try std.testing.expectEqual(@as(usize, 4), bigint_huge_copy.array.len());
    try range.dictionary.set(last_key.string, huge_negative_bigint);
    var bigint_huge_negative_copy = try rangeCopy(&runtime, range_source, range);
    try roots.protect(&bigint_huge_negative_copy);
    try std.testing.expectEqual(@as(usize, 0), bigint_huge_negative_copy.array.len());
    try range.dictionary.set(first_key.string, one_bigint);
    try range.dictionary.set(last_key.string, .{ .number = 2 });
    try std.testing.expectEqual(Value.undefined, try rangeCopy(&runtime, range_source, range));
    try std.testing.expectEqual(@as(f64, 0), (try reference(&runtime, range_source, zero_bigint)).number);
    try std.testing.expectEqual(@as(f64, 1), (try reference(&runtime, range_source, one_bigint)).number);
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, negative_bigint));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, huge_positive_bigint));

    var key_zero = try runtime.stringUtf8("0");
    try roots.protect(&key_zero);
    var key_one = try runtime.stringUtf8("1");
    try roots.protect(&key_one);
    var key_leading_zero = try runtime.stringUtf8("01");
    try roots.protect(&key_leading_zero);
    var key_negative_zero = try runtime.stringUtf8("-0");
    try roots.protect(&key_negative_zero);
    var key_negative_one = try runtime.stringUtf8("-1");
    try roots.protect(&key_negative_one);
    var key_decimal = try runtime.stringUtf8("1.0");
    try roots.protect(&key_decimal);
    var key_empty = try runtime.stringUtf8("");
    try roots.protect(&key_empty);
    var key_max = try runtime.stringUtf8("4294967295");
    try roots.protect(&key_max);
    var key_huge = try runtime.stringUtf8("900719925474099999999999999");
    try roots.protect(&key_huge);
    var key_length = try runtime.stringUtf8("length");
    try roots.protect(&key_length);
    try std.testing.expectEqual(@as(f64, 0), (try reference(&runtime, range_source, key_zero)).number);
    try std.testing.expectEqual(@as(f64, 1), (try reference(&runtime, range_source, key_one)).number);
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_leading_zero));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_negative_zero));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_negative_one));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_decimal));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_empty));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_max));
    try std.testing.expectEqual(Value.undefined, try reference(&runtime, range_source, key_huge));
    try std.testing.expectEqual(@as(f64, 4), (try reference(&runtime, range_source, key_length)).number);
    const alias_arguments = [_]Value{ range_source, key_one };
    const alias_result = (try call(&runtime, "配列参照", &alias_arguments, null)).?;
    try std.testing.expectEqual(@as(f64, 1), alias_result.number);
    try std.testing.expectEqual(@as(?usize, 0), propertyIndexUnits(&.{'0'}));
    try std.testing.expectEqual(@as(?usize, 4294967294), propertyIndexUnits(&.{ '4', '2', '9', '4', '9', '6', '7', '2', '9', '4' }));
    try std.testing.expectEqual(@as(?usize, null), propertyIndexUnits(&.{ '4', '2', '9', '4', '9', '6', '7', '2', '9', '5' }));

    try range.dictionary.set(first_key.string, .{ .number = 0 });
    try range.dictionary.set(last_key.string, one_bigint);
    var bigint_text = try reference(&runtime, text, range);
    try roots.protect(&bigint_text);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'B' }, bigint_text.string.units);
    try range.dictionary.set(last_key.string, negative_bigint);
    var bigint_empty_text = try reference(&runtime, text, range);
    try roots.protect(&bigint_empty_text);
    try std.testing.expectEqual(@as(usize, 0), bigint_empty_text.string.len());

    _ = range.dictionary.remove(last_key.string);
    try range.dictionary.set(first_key.string, .{ .number = 1 });
    var missing_last_copy = try rangeCopy(&runtime, source, range);
    try roots.protect(&missing_last_copy);
    try std.testing.expectEqual(@as(usize, 0), missing_last_copy.array.len());
    try range.dictionary.set(first_key.string, .{ .number = 2 });
    var missing_last_text = try reference(&runtime, text, range);
    try roots.protect(&missing_last_text);
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'B' }, missing_last_text.string.units);
}
