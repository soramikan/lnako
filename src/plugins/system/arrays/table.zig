const std = @import("std");
const value_mod = @import("../../../runtime/value.zig");
const shared = @import("shared.zig");
const Value = shared.Value;
const Runtime = shared.Runtime;
const Context = shared.Context;
const ByteKind = shared.ByteKind;

const common = @import("../common.zig");
const regexp = @import("../regexp.zig");
const operators = @import("../../../runtime/operators.zig");
const prototype_mod = @import("prototype.zig");
const sort = @import("sort.zig");
const SortCallback = sort.SortCallback;
const V8SortContext = sort.V8SortContext;
const appendArraySlot = shared.appendArraySlot;
const byteBufferAllowsStandardPrototype = prototype_mod.byteBufferAllowsStandardPrototype;
const byteBufferSlice = prototype_mod.byteBufferSlice;
const indexed = shared.indexed;
const isObjectPrototypeKey = prototype_mod.isObjectPrototypeKey;
const safe_array_element_limit = shared.safe_array_element_limit;
const spliceIndex = shared.spliceIndex;
const tableInheritedProperty = prototype_mod.tableInheritedProperty;
const testElementCountFunction = shared.testElementCountFunction;
const v8TimSortCallback = sort.v8TimSortCallback;
const v8_small_callback_sort_limit = sort.v8_small_callback_sort_limit;

const table_sort_mod = @import("table_sort.zig");
const table_filtering_mod = @import("table_filtering.zig");
const table_structure_mod = @import("table_structure.zig");
const table_projection_mod = @import("table_projection.zig");

pub const TableSortPrimitiveContext = table_sort_mod.TableSortPrimitiveContext;
pub const tableSort = table_sort_mod.tableSort;
pub const v8SmallTableSort = table_sort_mod.v8SmallTableSort;
pub const compareTableRows = table_sort_mod.compareTableRows;
pub const tablePickup = table_filtering_mod.tablePickup;
pub const tableSearch = table_filtering_mod.tableSearch;
pub const incrementTableSearchRow = table_filtering_mod.incrementTableSearchRow;
pub const tableUnique = table_filtering_mod.tableUnique;
pub const tableRegexpSearch = table_filtering_mod.tableRegexpSearch;
pub const tableRegexpPickup = table_filtering_mod.tableRegexpPickup;
pub const tableColumnCount = table_structure_mod.tableColumnCount;
pub const rowLengthValue = table_structure_mod.rowLengthValue;
pub const tableRowCount = table_structure_mod.tableRowCount;
pub const transpose = table_structure_mod.transpose;
pub const tableIterationCount = table_structure_mod.tableIterationCount;
pub const tableColumn = table_projection_mod.tableColumn;
pub const tableInsertColumn = table_projection_mod.tableInsertColumn;
pub const tableDeleteColumn = table_projection_mod.tableDeleteColumn;
pub const tableColumnSum = table_projection_mod.tableColumnSum;

test "表ソートの小配列比較順はV8のrun検出規則を保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var a = try runtime.createDictionary();
    try roots.protect(&a);
    var b = try runtime.createDictionary();
    try roots.protect(&b);
    var c = try runtime.createDictionary();
    try roots.protect(&c);
    var context = TableSortPrimitiveContext{ .values = .{ a, b, c } };
    runtime.setPrimitiveHook(.{ .context = &context, .callFn = TableSortPrimitiveContext.invoke });
    defer runtime.clearPrimitiveHook(&context);

    var row_a = try common.arrayFromValues(&runtime, &.{a});
    try roots.protect(&row_a);
    var row_b = try common.arrayFromValues(&runtime, &.{b});
    try roots.protect(&row_b);
    var row_c = try common.arrayFromValues(&runtime, &.{c});
    try roots.protect(&row_c);
    var table = try common.arrayFromValues(&runtime, &.{ row_c, row_a, row_b });
    try roots.protect(&table);

    _ = try tableSort(&runtime, table, .{ .number = 0 }, false);
    try std.testing.expectEqualStrings("ACBABCBA", context.log[0..context.count]);
    try std.testing.expectEqual(row_a.array, table.array.get(0).array);
    try std.testing.expectEqual(row_b.array, table.array.get(1).array);
    try std.testing.expectEqual(row_c.array, table.array.get(2).array);

    context.count = 0;
    var numeric_table = try common.arrayFromValues(&runtime, &.{ row_c, row_a, row_b });
    try roots.protect(&numeric_table);
    _ = try tableSort(&runtime, numeric_table, .{ .number = 0 }, true);
    try std.testing.expectEqualStrings("ACBABCBA", context.log[0..context.count]);
    try std.testing.expectEqual(row_a.array, numeric_table.array.get(0).array);
    try std.testing.expectEqual(row_b.array, numeric_table.array.get(1).array);
    try std.testing.expectEqual(row_c.array, numeric_table.array.get(2).array);
}

test "表検索系はlengthとraw開始値の型を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var length_key = try runtime.stringUtf8("length");
    try roots.protect(&length_key);
    var text_length = try runtime.stringUtf8("7");
    try roots.protect(&text_length);
    var dictionary = try runtime.createDictionary();
    try roots.protect(&dictionary);
    try dictionary.dictionary.set(length_key.string, text_length);
    var dictionary_table = try common.arrayFromValues(&runtime, &.{dictionary});
    try roots.protect(&dictionary_table);
    try std.testing.expectEqual(text_length.string, (try tableColumnCount(&runtime, dictionary_table)).string);
    var inherited_length = try runtime.createDictionary();
    try roots.protect(&inherited_length);
    try inherited_length.dictionary.set(length_key.string, .{ .number = 7 });
    var inherited_dictionary = try runtime.createDictionary();
    try roots.protect(&inherited_dictionary);
    inherited_dictionary.dictionary.prototype = inherited_length;
    var inherited_table = try common.arrayFromValues(&runtime, &.{inherited_dictionary});
    try roots.protect(&inherited_table);
    try std.testing.expectEqual(@as(f64, 7), (try tableColumnCount(&runtime, inherited_table)).number);

    var byte_buffer = try runtime.createBytes(&.{ 65, 66 });
    try roots.protect(&byte_buffer);
    var byte_prototype = try runtime.createDictionary();
    try roots.protect(&byte_prototype);
    try byte_prototype.dictionary.set(length_key.string, .{ .number = 7 });
    byte_buffer.bytes.prototype = byte_prototype;
    var byte_table = try common.arrayFromValues(&runtime, &.{byte_buffer});
    try roots.protect(&byte_table);
    try std.testing.expectEqual(@as(f64, 7), (try indexed(&runtime, byte_buffer, length_key)).number);
    try std.testing.expectEqual(@as(f64, 7), (try tableColumnCount(&runtime, byte_table)).number);

    var function_name = try runtime.stringUtf8("二引数");
    try roots.protect(&function_name);
    var function = try runtime.createNativeFunction(function_name.string, 2, testElementCountFunction, &.{});
    try roots.protect(&function);
    try std.testing.expectEqual(@as(f64, 0), (try indexed(&runtime, function, length_key)).number);
    var name_key = try runtime.stringUtf8("name");
    try roots.protect(&name_key);
    try std.testing.expectEqualSlices(u16, &.{ '二', '引', '数' }, (try indexed(&runtime, function, name_key)).string.units);

    var zero_text = try runtime.stringUtf8("zero");
    try roots.protect(&zero_text);
    var one_value_text = try runtime.stringUtf8("one");
    try roots.protect(&one_value_text);
    var two_value_text = try runtime.stringUtf8("two");
    try roots.protect(&two_value_text);
    var zero = try common.arrayFromValues(&runtime, &.{zero_text});
    try roots.protect(&zero);
    var one = try common.arrayFromValues(&runtime, &.{one_value_text});
    try roots.protect(&one);
    var two = try common.arrayFromValues(&runtime, &.{two_value_text});
    try roots.protect(&two);
    var table = try common.arrayFromValues(&runtime, &.{ zero, one, two });
    try roots.protect(&table);
    var one_text = try runtime.stringUtf8("1");
    try roots.protect(&one_text);
    var one_needle = try runtime.stringUtf8("one");
    try roots.protect(&one_needle);
    var two_needle = try runtime.stringUtf8("two");
    try roots.protect(&two_needle);
    try std.testing.expectEqual(one_text.string, (try tableSearch(&runtime, table, .{ .number = 0 }, one_text, one_needle)).string);
    try std.testing.expectEqual(@as(f64, 2), (try tableSearch(&runtime, table, .{ .number = 0 }, one_text, two_needle)).number);
    var one_bigint = try runtime.bigIntLiteral("1n");
    try roots.protect(&one_bigint);
    try std.testing.expectEqual(@as(i64, 1), (try tableSearch(&runtime, table, .{ .number = 0 }, one_bigint, one_needle)).bigint.toI64());
    try std.testing.expectEqual(@as(i64, 2), (try tableSearch(&runtime, table, .{ .number = 0 }, one_bigint, two_needle)).bigint.toI64());
    var object_start = try runtime.createDictionary();
    try roots.protect(&object_start);
    try std.testing.expectEqual(@as(f64, -1), (try tableSearch(&runtime, table, .{ .number = 0 }, object_start, one_needle)).number);

    var buffer = try runtime.createBytes(&.{ 85, 9 });
    try roots.protect(&buffer);
    var buffer_table = try common.arrayFromValues(&runtime, &.{buffer});
    try roots.protect(&buffer_table);
    try std.testing.expectEqual(@as(f64, 2), (try tableColumnCount(&runtime, buffer_table)).number);
    try std.testing.expectEqual(@as(f64, 85), (try indexed(&runtime, buffer, .{ .number = 0 })).number);
    try std.testing.expectEqual(@as(f64, 0), (try tableSearch(&runtime, buffer_table, .{ .number = 0 }, .{ .number = 0 }, .{ .number = 85 })).number);

    var array_buffer = try runtime.createArrayBuffer(&.{ 85, 9 });
    try roots.protect(&array_buffer);
    try std.testing.expect((try indexed(&runtime, array_buffer, length_key)) == .undefined);

    var sparse_table = try runtime.createArray();
    try roots.protect(&sparse_table);
    var sparse_row = try runtime.createArray();
    try roots.protect(&sparse_row);
    try sparse_table.array.set(2, sparse_row);
    try std.testing.expectError(error.TableRowMissing, tableColumnCount(&runtime, sparse_table));
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading 'length')", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    var null_table = try common.arrayFromValues(&runtime, &.{Value.null_value});
    try roots.protect(&null_table);
    try std.testing.expectError(error.TableRowMissing, tableColumnCount(&runtime, null_table));
    try std.testing.expectEqualStrings("Cannot read properties of null (reading 'length')", runtime.failureMessage().?);
    runtime.clearFailureMessage();
}

test "byte bufferのnull prototypeは標準propertyを隠し添字と表の長さを保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var buffer = try runtime.createBytes(&.{ 85, 66 });
    try roots.protect(&buffer);
    var uint8 = try runtime.createUint8Array(&.{ 85, 66 });
    try roots.protect(&uint8);
    var array_buffer = try runtime.createArrayBuffer(&.{ 85, 66 });
    try roots.protect(&array_buffer);
    buffer.bytes.prototype = .null_value;
    uint8.bytes.prototype = .null_value;
    array_buffer.bytes.prototype = .null_value;

    var length_key = try runtime.stringUtf8("length");
    try roots.protect(&length_key);
    var byte_length_key = try runtime.stringUtf8("byteLength");
    try roots.protect(&byte_length_key);
    var slice_key = try runtime.stringUtf8("slice");
    try roots.protect(&slice_key);
    var map_key = try runtime.stringUtf8("map");
    try roots.protect(&map_key);

    try std.testing.expect((try indexed(&runtime, buffer, length_key)) == .undefined);
    try std.testing.expect((try indexed(&runtime, buffer, byte_length_key)) == .undefined);
    try std.testing.expect((try indexed(&runtime, buffer, slice_key)) == .undefined);
    try std.testing.expectEqual(@as(f64, 85), (try indexed(&runtime, buffer, .{ .number = 0 })).number);
    try std.testing.expect((try indexed(&runtime, uint8, length_key)) == .undefined);
    try std.testing.expect((try indexed(&runtime, uint8, map_key)) == .undefined);
    try std.testing.expectEqual(@as(f64, 85), (try indexed(&runtime, uint8, .{ .number = 0 })).number);
    try std.testing.expect((try indexed(&runtime, array_buffer, byte_length_key)) == .undefined);
    try std.testing.expect((try indexed(&runtime, array_buffer, .{ .number = 0 })) == .undefined);

    var buffer_table = try common.arrayFromValues(&runtime, &.{buffer});
    try roots.protect(&buffer_table);
    var buffer_length = try tableColumn(&runtime, buffer_table, length_key);
    try roots.protect(&buffer_length);
    try std.testing.expect(buffer_length.array.get(0) == .undefined);
    var buffer_index = try tableColumn(&runtime, buffer_table, .{ .number = 0 });
    try roots.protect(&buffer_index);
    try std.testing.expectEqual(@as(f64, 85), buffer_index.array.get(0).number);
    try std.testing.expectEqual(@as(f64, 1), (try tableColumnCount(&runtime, buffer_table)).number);

    var array_buffer_table = try common.arrayFromValues(&runtime, &.{array_buffer});
    try roots.protect(&array_buffer_table);
    var array_buffer_length = try tableColumn(&runtime, array_buffer_table, byte_length_key);
    try roots.protect(&array_buffer_length);
    try std.testing.expect(array_buffer_length.array.get(0) == .undefined);
    try std.testing.expectEqual(@as(f64, 1), (try tableColumnCount(&runtime, array_buffer_table)).number);
}

test "表ソートは最上位配列のholeと明示的undefinedをpresence順に保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var high = try common.arrayFromValues(&runtime, &.{.{ .number = 2 }});
    try roots.protect(&high);
    var low = try common.arrayFromValues(&runtime, &.{.{ .number = 1 }});
    try roots.protect(&low);
    var table = try runtime.createArray();
    try roots.protect(&table);
    try table.array.set(0, high);
    try table.array.set(2, low);
    try table.array.set(3, .undefined);

    const sorted = try tableSort(&runtime, table, .{ .number = 0 }, false);
    try std.testing.expectEqual(table.array, sorted.array);
    try std.testing.expectEqual(low.array, table.array.get(0).array);
    try std.testing.expectEqual(high.array, table.array.get(1).array);
    try std.testing.expectEqual(Value.undefined, table.array.get(2));
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, table.array.presence.items);

    var high_text = try runtime.stringUtf8("10");
    try roots.protect(&high_text);
    var low_text = try runtime.stringUtf8("2");
    try roots.protect(&low_text);
    var numeric_high = try common.arrayFromValues(&runtime, &.{high_text});
    try roots.protect(&numeric_high);
    var numeric_low = try common.arrayFromValues(&runtime, &.{low_text});
    try roots.protect(&numeric_low);
    var numeric_table = try runtime.createArray();
    try roots.protect(&numeric_table);
    try numeric_table.array.set(0, numeric_high);
    try numeric_table.array.set(2, numeric_low);
    try numeric_table.array.set(3, .undefined);
    _ = try tableSort(&runtime, numeric_table, .{ .number = 0 }, true);
    try std.testing.expectEqual(numeric_low.array, numeric_table.array.get(0).array);
    try std.testing.expectEqual(numeric_high.array, numeric_table.array.get(1).array);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, numeric_table.array.presence.items);
}

test "表数値ソートはns-msのBigInt型境界を公式どおり拒否する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var first_bigint = try runtime.bigIntLiteral("1n");
    try roots.protect(&first_bigint);
    var second_bigint = try runtime.bigIntLiteral("2n");
    try roots.protect(&second_bigint);
    var first_row = try common.arrayFromValues(&runtime, &.{first_bigint});
    try roots.protect(&first_row);
    var second_row = try common.arrayFromValues(&runtime, &.{second_bigint});
    try roots.protect(&second_row);
    var bigint_table = try common.arrayFromValues(&runtime, &.{ first_row, second_row });
    try roots.protect(&bigint_table);
    try std.testing.expectError(error.CannotConvertBigIntToNumber, tableSort(&runtime, bigint_table, .{ .number = 0 }, true));

    var number_row = try common.arrayFromValues(&runtime, &.{.{ .number = 2 }});
    try roots.protect(&number_row);
    var mixed_table = try common.arrayFromValues(&runtime, &.{ first_row, number_row });
    try roots.protect(&mixed_table);
    try std.testing.expectError(error.CannotMixBigIntAndNumber, tableSort(&runtime, mixed_table, .{ .number = 0 }, true));
}

test "表列取得と表ピックアップは最上位のholeをArrayメソッドどおり扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var first = try common.arrayFromValues(&runtime, &.{ .{ .number = 2 }, .{ .number = 20 } });
    try roots.protect(&first);
    var second = try common.arrayFromValues(&runtime, &.{.{ .number = 1 }});
    try roots.protect(&second);
    var table = try runtime.createArray();
    try roots.protect(&table);
    try table.array.set(0, first);
    try table.array.set(2, second);

    var column = try tableColumn(&runtime, table, .{ .number = 1 });
    try roots.protect(&column);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, column.array.presence.items);
    try std.testing.expectEqual(@as(f64, 20), column.array.get(0).number);
    try std.testing.expectEqual(Value.undefined, column.array.get(1));
    try std.testing.expectEqual(Value.undefined, column.array.get(2));

    var partial = try tablePickup(&runtime, table, .{ .number = 0 }, .{ .number = 1 }, false);
    try roots.protect(&partial);
    try std.testing.expectEqual(@as(usize, 1), partial.array.len());
    try std.testing.expectEqual(second.array, partial.array.get(0).array);
    var exact = try tablePickup(&runtime, table, .{ .number = 0 }, .{ .number = 2 }, true);
    try roots.protect(&exact);
    try std.testing.expectEqual(@as(usize, 1), exact.array.len());
    try std.testing.expectEqual(first.array, exact.array.get(0).array);
}

test "表列挿入削除合計は外側と行内部のholeをforEachとsliceどおり扱う" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var sparse_row = try runtime.createArray();
    try roots.protect(&sparse_row);
    try sparse_row.array.set(0, .{ .number = 1 });
    try sparse_row.array.set(2, .{ .number = 3 });
    var dense_row = try common.arrayFromValues(&runtime, &.{ .{ .number = 4 }, .{ .number = 5 } });
    try roots.protect(&dense_row);
    var table = try runtime.createArray();
    try roots.protect(&table);
    try table.array.set(0, sparse_row);
    try table.array.set(2, dense_row);
    var values = try common.arrayFromValues(&runtime, &.{ .{ .number = 9 }, .{ .number = 8 }, .{ .number = 7 } });
    try roots.protect(&values);

    var inserted = try tableInsertColumn(&runtime, table, .{ .number = 1 }, values);
    try roots.protect(&inserted);
    try std.testing.expectEqual(@as(usize, 2), inserted.array.len());
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true }, inserted.array.get(0).array.presence.items);
    try std.testing.expectEqual(@as(f64, 1), inserted.array.get(0).array.get(0).number);
    try std.testing.expectEqual(@as(f64, 9), inserted.array.get(0).array.get(1).number);
    try std.testing.expectEqual(Value.undefined, inserted.array.get(0).array.get(2));
    try std.testing.expectEqual(@as(f64, 3), inserted.array.get(0).array.get(3).number);
    try std.testing.expectEqual(@as(f64, 7), inserted.array.get(1).array.get(1).number);

    var deleted = try tableDeleteColumn(&runtime, table, .{ .number = 1 });
    try roots.protect(&deleted);
    try std.testing.expectEqual(@as(usize, 2), deleted.array.len());
    try std.testing.expectEqualSlices(bool, &.{ true, true }, deleted.array.get(0).array.presence.items);
    try std.testing.expectEqual(@as(f64, 1), deleted.array.get(0).array.get(0).number);
    try std.testing.expectEqual(@as(f64, 3), deleted.array.get(0).array.get(1).number);
    try std.testing.expectEqual(@as(f64, 4), deleted.array.get(1).array.get(0).number);

    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, table.array.presence.items);
    try std.testing.expectEqual(@as(f64, 1), table.array.get(0).array.get(0).number);
    try std.testing.expectEqual(@as(f64, 4), table.array.get(2).array.get(0).number);
    const sum_value = try tableColumnSum(&runtime, table, .{ .number = 0 });
    try std.testing.expectEqual(@as(f64, 5), sum_value.number);
}

test "表正規表現系はraw RegExpと浅いコピーとGCを保つ" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var first_text = try runtime.stringUtf8("alice");
    try roots.protect(&first_text);
    var marker = try runtime.createDictionary();
    try roots.protect(&marker);
    var first = try common.arrayFromValues(&runtime, &.{ first_text, marker });
    try roots.protect(&first);
    var second_text = try runtime.stringUtf8("bob");
    try roots.protect(&second_text);
    var second = try common.arrayFromValues(&runtime, &.{second_text});
    try roots.protect(&second);
    var table = try common.arrayFromValues(&runtime, &.{ first, second });
    try roots.protect(&table);
    var raw_pattern = try runtime.stringUtf8("^ali");
    try roots.protect(&raw_pattern);
    const found = try tableRegexpSearch(&runtime, table, .{ .number = 0 }, .{ .number = 0 }, raw_pattern);
    try std.testing.expectEqual(@as(f64, 0), found.number);

    var slash_pattern = try runtime.stringUtf8("/^ali/i");
    try roots.protect(&slash_pattern);
    try std.testing.expectEqual(@as(f64, -1), (try tableRegexpSearch(&runtime, table, .{ .number = 0 }, .{ .number = 0 }, slash_pattern)).number);

    var start_text = try runtime.stringUtf8("1");
    try roots.protect(&start_text);
    var bob_pattern = try runtime.stringUtf8("bob");
    try roots.protect(&bob_pattern);
    const string_start = try tableRegexpSearch(&runtime, table, start_text, .{ .number = 0 }, bob_pattern);
    try std.testing.expectEqual(start_text.string, string_start.string);
    var start_bigint = try runtime.bigIntLiteral("1n");
    try roots.protect(&start_bigint);
    const bigint_start = try tableRegexpSearch(&runtime, table, start_bigint, .{ .number = 0 }, bob_pattern);
    try std.testing.expectEqual(@as(i64, 1), bigint_start.bigint.toI64());

    var picked = try tableRegexpPickup(&runtime, table, .{ .number = 0 }, raw_pattern);
    try roots.protect(&picked);
    try std.testing.expect(picked.array != table.array);
    try std.testing.expect(picked.array.get(0).array != first.array);
    try std.testing.expectEqual(marker.dictionary, picked.array.get(0).array.get(1).dictionary);

    var sparse_row = try runtime.createArray();
    try roots.protect(&sparse_row);
    try sparse_row.array.set(0, first_text);
    try sparse_row.array.set(2, second_text);
    var sparse_inner_table = try common.arrayFromValues(&runtime, &.{sparse_row});
    try roots.protect(&sparse_inner_table);
    var sparse_inner_picked = try tableRegexpPickup(&runtime, sparse_inner_table, .{ .number = 0 }, raw_pattern);
    try roots.protect(&sparse_inner_picked);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, sparse_inner_picked.array.get(0).array.presence.items);

    var empty_pattern_pickup = try tableRegexpPickup(&runtime, table, .{ .number = 0 }, .undefined);
    try roots.protect(&empty_pattern_pickup);
    try std.testing.expectEqual(@as(usize, 2), empty_pattern_pickup.array.len());
    var string_table = try common.arrayFromValues(&runtime, &.{first_text});
    try roots.protect(&string_table);
    var first_unit_pattern = try runtime.stringUtf8("^a");
    try roots.protect(&first_unit_pattern);
    var string_pickup = try tableRegexpPickup(&runtime, string_table, .{ .number = 0 }, first_unit_pattern);
    try roots.protect(&string_pickup);
    try std.testing.expectEqual(first_text.string, string_pickup.array.get(0).string);

    var invalid = try runtime.stringUtf8("[");
    try roots.protect(&invalid);
    var empty = try runtime.createArray();
    try roots.protect(&empty);
    try std.testing.expectError(error.UnclosedCharacterClass, tableRegexpSearch(&runtime, empty, .{ .number = 0 }, .{ .number = 0 }, invalid));
    try std.testing.expectEqualStrings("Invalid regular expression: /[/: Unterminated character class", runtime.failureMessage().?);
    runtime.clearFailureMessage();
    try std.testing.expectError(error.UnclosedCharacterClass, tableRegexpPickup(&runtime, empty, .{ .number = 0 }, invalid));
    try std.testing.expectEqualStrings("Invalid regular expression: /[/: Unterminated character class", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    var null_row = try common.arrayFromValues(&runtime, &.{Value.null_value});
    try roots.protect(&null_row);
    try std.testing.expectError(error.TableRowMissing, tableRegexpSearch(&runtime, null_row, .{ .number = 0 }, .{ .number = 0 }, raw_pattern));
    try std.testing.expectEqualStrings("Cannot read properties of null (reading '0')", runtime.failureMessage().?);
    runtime.clearFailureMessage();
    try std.testing.expectError(error.TableRowMissing, tableRegexpPickup(&runtime, null_row, .{ .number = 0 }, raw_pattern));
    try std.testing.expectEqualStrings("Cannot read properties of null (reading '0')", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    var sparse_table = try runtime.createArray();
    try roots.protect(&sparse_table);
    try sparse_table.array.set(0, first);
    try sparse_table.array.set(2, second);
    try std.testing.expectError(error.TableRowMissing, tableRegexpSearch(&runtime, sparse_table, .{ .number = 0 }, .{ .number = 0 }, bob_pattern));
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading '0')", runtime.failureMessage().?);
    runtime.clearFailureMessage();
    try std.testing.expectError(error.TableRowMissing, tableRegexpPickup(&runtime, sparse_table, .{ .number = 0 }, raw_pattern));
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading '0')", runtime.failureMessage().?);
    runtime.clearFailureMessage();
}

test "表変換系はGCストレス下で文字列行とJSキー規則を保持する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var text_row = try runtime.stringUtf8("abc");
    try roots.protect(&text_row);
    var table = try common.arrayFromValues(&runtime, &.{text_row});
    try roots.protect(&table);
    var values = try runtime.stringUtf8("Z");
    try roots.protect(&values);
    var inserted = try tableInsertColumn(&runtime, table, .{ .number = 1 }, values);
    try roots.protect(&inserted);
    try std.testing.expectEqual(@as(usize, 3), inserted.array.get(0).array.len());
    try std.testing.expectEqualSlices(u16, &.{'a'}, inserted.array.get(0).array.get(0).string.units);
    try std.testing.expectEqualSlices(u16, &.{'Z'}, inserted.array.get(0).array.get(1).string.units);
    try std.testing.expectEqualSlices(u16, &.{ 'b', 'c' }, inserted.array.get(0).array.get(2).string.units);

    var byte_row = try runtime.createBytes(&.{ 0x41, 0x42, 0x43 });
    try roots.protect(&byte_row);
    var byte_table = try common.arrayFromValues(&runtime, &.{byte_row});
    try roots.protect(&byte_table);
    var byte_values = try common.arrayFromValues(&runtime, &.{.{ .number = 9 }});
    try roots.protect(&byte_values);
    var byte_inserted = try tableInsertColumn(&runtime, byte_table, .{ .number = 1 }, byte_values);
    try roots.protect(&byte_inserted);
    try std.testing.expectEqual(@as(usize, 3), byte_inserted.array.get(0).array.len());
    try std.testing.expectEqualSlices(u8, &.{0x41}, byte_inserted.array.get(0).array.get(0).bytes.bytes);
    try std.testing.expectEqual(@as(f64, 9), byte_inserted.array.get(0).array.get(1).number);
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x43 }, byte_inserted.array.get(0).array.get(2).bytes.bytes);

    var prototype = try runtime.stringUtf8("__proto__");
    try roots.protect(&prototype);
    var ordinary = try runtime.stringUtf8("a");
    try roots.protect(&ordinary);
    var prototype_row = try common.arrayFromValues(&runtime, &.{prototype});
    try roots.protect(&prototype_row);
    var ordinary_row = try common.arrayFromValues(&runtime, &.{ordinary});
    try roots.protect(&ordinary_row);
    var duplicate_row = try common.arrayFromValues(&runtime, &.{ordinary});
    try roots.protect(&duplicate_row);
    var duplicate_table = try common.arrayFromValues(&runtime, &.{ prototype_row, ordinary_row, duplicate_row });
    try roots.protect(&duplicate_table);
    var unique = try tableUnique(&runtime, duplicate_table, .{ .number = 0 });
    try roots.protect(&unique);
    try std.testing.expectEqual(@as(usize, 1), unique.array.len());
    try std.testing.expect(unique.array.get(0).array == ordinary_row.array);

    var x = try runtime.stringUtf8("x");
    try roots.protect(&x);
    var y = try runtime.stringUtf8("y");
    try roots.protect(&y);
    var x_row = try common.arrayFromValues(&runtime, &.{x});
    try roots.protect(&x_row);
    var y_row = try common.arrayFromValues(&runtime, &.{y});
    try roots.protect(&y_row);
    var sum_table = try common.arrayFromValues(&runtime, &.{ x_row, y_row });
    try roots.protect(&sum_table);
    var column_sum = try tableColumnSum(&runtime, sum_table, .{ .number = 0 });
    try roots.protect(&column_sum);
    try std.testing.expectEqualSlices(u16, &.{ '0', 'x', 'y' }, column_sum.string.units);

    var sparse_table = try runtime.createArray();
    try roots.protect(&sparse_table);
    _ = try sparse_table.array.push(x_row);
    _ = try sparse_table.array.push(.undefined);
    _ = try sparse_table.array.deleteIndex(1);
    _ = try sparse_table.array.push(y_row);
    try std.testing.expectError(error.TableRowMissing, tableUnique(&runtime, sparse_table, .{ .number = 0 }));
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading '0')", runtime.failureMessage().?);
    runtime.clearFailureMessage();

    var empty = try runtime.createArray();
    try roots.protect(&empty);
    var bigint_index = try runtime.bigIntLiteral("1n");
    try roots.protect(&bigint_index);
    var empty_insert = try tableInsertColumn(&runtime, empty, bigint_index, .null_value);
    try roots.protect(&empty_insert);
    try std.testing.expectEqual(@as(usize, 0), empty_insert.array.len());
}

test "表正規表現ピックアップはBufferのsliceを共有する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var buffer = try runtime.createBytes(&.{ 85, 66 });
    try roots.protect(&buffer);
    var table = try common.arrayFromValues(&runtime, &.{buffer});
    try roots.protect(&table);
    var pattern = try runtime.stringUtf8("^85");
    try roots.protect(&pattern);
    var picked = try tableRegexpPickup(&runtime, table, .{ .number = 0 }, pattern);
    try roots.protect(&picked);
    buffer.bytes.set(0, 7);
    try std.testing.expectEqual(@as(f64, 7), picked.array.get(0).bytes.get(0).number);
}

test "表列挿入はBufferのsliceだけを共有しTypedArrayのsliceを複製する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    runtime.setGcStress(true);
    var roots = runtime.rootFrame();
    defer roots.deinit();

    var buffer = try runtime.createBytes(&.{ 1, 2, 3 });
    try roots.protect(&buffer);
    var table = try common.arrayFromValues(&runtime, &.{buffer});
    try roots.protect(&table);
    var values = try common.arrayFromValues(&runtime, &.{.{ .number = 9 }});
    try roots.protect(&values);
    var inserted = try tableInsertColumn(&runtime, table, .{ .number = 1 }, values);
    try roots.protect(&inserted);
    buffer.bytes.set(0, 7);
    buffer.bytes.set(1, 8);
    const inserted_row = inserted.array.get(0).array;
    try std.testing.expectEqual(@as(f64, 7), inserted_row.get(0).bytes.get(0).number);
    try std.testing.expectEqual(@as(f64, 8), inserted_row.get(2).bytes.get(0).number);

    var uint8 = try runtime.createUint8Array(&.{ 4, 5 });
    try roots.protect(&uint8);
    var uint8_slice = try byteBufferSlice(&runtime, uint8.bytes, 0, 1);
    try roots.protect(&uint8_slice);
    uint8.bytes.set(0, 6);
    try std.testing.expectEqual(@as(f64, 4), uint8_slice.bytes.get(0).number);

    var array_buffer = try runtime.createArrayBuffer(&.{ 10, 11 });
    try roots.protect(&array_buffer);
    var array_buffer_slice = try byteBufferSlice(&runtime, array_buffer.bytes, 0, 1);
    try roots.protect(&array_buffer_slice);
    array_buffer.bytes.set(0, 12);
    try std.testing.expectEqual(@as(f64, 10), array_buffer_slice.bytes.get(0).number);
}
