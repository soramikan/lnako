const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared.zig");
const state = @import("state.zig");

pub const lnako_aot_node_mother_path_init = state.lnako_aot_node_mother_path_init;
pub const lnako_aot_push_roots = state.lnako_aot_push_roots;
pub const lnako_aot_node_constants_init = state.lnako_aot_node_constants_init;
pub const lnako_aot_pop_roots = state.lnako_aot_pop_roots;
pub const lnako_aot_node_constants_init_wide = state.lnako_aot_node_constants_init_wide;
pub const lnako_aot_collect = state.lnako_aot_collect;
pub const lnako_aot_runtime_init = state.lnako_aot_runtime_init;
pub const lnako_aot_runtime_deinit = state.lnako_aot_runtime_deinit;
pub const lnako_aot_node_directory_constants_init = state.lnako_aot_node_directory_constants_init;

const AotClientHttpBodyKind = state.AotClientHttpBodyKind;
const AotClientHttpResult = state.AotClientHttpResult;
const AotHttpRoute = state.AotHttpRoute;
const Arithmetic = state.Arithmetic;
const BigInt = state.BigInt;
const ByteKind = state.ByteKind;
const FunctionCallback = state.FunctionCallback;
const Object = state.Object;
const RootFrame = state.RootFrame;
const Runtime = state.Runtime;
const Tag = state.Tag;
const Value = state.Value;
const aotArchitectureName = state.aotArchitectureName;
const aotBigintRangeAllocationTest = state.aotBigintRangeAllocationTest;
const aotByteBufferSlice = state.aotByteBufferSlice;
const aotClientHttpBodyKind = state.aotClientHttpBodyKind;
const aotClientHttpResponseBody = state.aotClientHttpResponseBody;
const aotClientHttpResponseStatus = state.aotClientHttpResponseStatus;
const aotClientHttpResponseValue = state.aotClientHttpResponseValue;
const aotClientPrepareAjax = state.aotClientPrepareAjax;
const aotClientPreparePost = state.aotClientPreparePost;
const aotDictionaryBigIntPropertyKeyAllocationTest = state.aotDictionaryBigIntPropertyKeyAllocationTest;
const aotDictionaryPropertyKeyAllocationTest = state.aotDictionaryPropertyKeyAllocationTest;
const aotHttpBestRoute = state.aotHttpBestRoute;
const aotHttpDispositionParameter = state.aotHttpDispositionParameter;
const aotHttpMimeType = state.aotHttpMimeType;
const aotHttpMultipartBoundary = state.aotHttpMultipartBoundary;
const aotHttpParsePost = state.aotHttpParsePost;
const aotHttpParseQuery = state.aotHttpParseQuery;
const aotHttpUploadBasename = state.aotHttpUploadBasename;
const aotOsName = state.aotOsName;
const aotWidthAllocationTest = state.aotWidthAllocationTest;
const aot_builtin = state.aot_builtin;
const appendDisplayLog = state.appendDisplayLog;
const appendSearchElements = state.appendSearchElements;
const arithmetic = state.arithmetic;
const arrayAddBuiltin = state.arrayAddBuiltin;
const arrayCallbackBuiltin = state.arrayCallbackBuiltin;
const arrayCutBuiltin = state.arrayCutBuiltin;
const arrayExtremumBuiltin = state.arrayExtremumBuiltin;
const arrayFillBuiltin = state.arrayFillBuiltin;
const arrayInsertBuiltin = state.arrayInsertBuiltin;
const arrayInsertManyBuiltin = state.arrayInsertManyBuiltin;
const arrayItems = state.arrayItems;
const arrayOrderingBuiltin = state.arrayOrderingBuiltin;
const arrayRangeCopyBuiltin = state.arrayRangeCopyBuiltin;
const arraySequenceBuiltin = state.arraySequenceBuiltin;
const arraySumBuiltin = state.arraySumBuiltin;
const arraySwapBuiltin = state.arraySwapBuiltin;
const arrayTakeBuiltin = state.arrayTakeBuiltin;
const bigIntArithmetic = state.bigIntArithmetic;
const caniuseAgentsBuiltin = state.caniuseAgentsBuiltin;
const caniuseBrowsersBuiltin = state.caniuseBrowsersBuiltin;
const codePointFindAllocationTest = state.codePointFindAllocationTest;
const codePointFindBuiltin = state.codePointFindBuiltin;
const compareValues = state.compareValues;
const concat = state.concat;
const createJsonTestString = state.createJsonTestString;
const crypto = state.crypto;
const currentDirectoryAlloc = state.currentDirectoryAlloc;
const cutEndIndex = state.cutEndIndex;
const datetimeAddDatePluginEpoch = state.datetimeAddDatePluginEpoch;
const datetimeAddDateSystemEpoch = state.datetimeAddDateSystemEpoch;
const datetimeBuiltin = state.datetimeBuiltin;
const datetimeConstructLocal = state.datetimeConstructLocal;
const datetimeFieldsFromEpoch = state.datetimeFieldsFromEpoch;
const deepCloneBuiltin = state.deepCloneBuiltin;
const default_random_seed = state.default_random_seed;
const dictionaryHasBuiltin = state.dictionaryHasBuiltin;
const dictionaryKeysBuiltin = state.dictionaryKeysBuiltin;
const dictionaryProperty = state.dictionaryProperty;
const dictionaryRemoveBuiltin = state.dictionaryRemoveBuiltin;
const dictionaryToPrimitive = state.dictionaryToPrimitive;
const dictionaryValuesBuiltin = state.dictionaryValuesBuiltin;
const drainAotEvents = state.drainAotEvents;
const eraDataBuiltin = state.eraDataBuiltin;
const expectAotNodePathArgumentFailure = state.expectAotNodePathArgumentFailure;
const expectAotReferenceStringRangeMessage = state.expectAotReferenceStringRangeMessage;
const expectJsonAotString = state.expectJsonAotString;
const expectUtf16String = state.expectUtf16String;
const incrementNumber = state.incrementNumber;
const incrementValue = state.incrementValue;
const indexOfUnitsBuiltin = state.indexOfUnitsBuiltin;
const invokeAotCallback = state.invokeAotCallback;
const isAotHttpResponse = state.isAotHttpResponse;
const isNegativeZero = state.isNegativeZero;
const jsonDecodeBuiltin = state.jsonDecodeBuiltin;
const jsonEncodeBuiltin = state.jsonEncodeBuiltin;
const kanaMapBuiltin = state.kanaMapBuiltin;
const lnako_aot_ajax_onerror_set = state.lnako_aot_ajax_onerror_set;
const lnako_aot_ajax_options_set = state.lnako_aot_ajax_options_set;
const lnako_aot_archive_call = state.lnako_aot_archive_call;
const lnako_aot_archive_tool_path_set = state.lnako_aot_archive_tool_path_set;
const lnako_aot_arithmetic = state.lnako_aot_arithmetic;
const lnako_aot_array_new = state.lnako_aot_array_new;
const lnako_aot_bigint_truthy = state.lnako_aot_bigint_truthy;
const lnako_aot_binding_cell_new = state.lnako_aot_binding_cell_new;
const lnako_aot_binding_cell_value = state.lnako_aot_binding_cell_value;
const lnako_aot_builtin_call = state.lnako_aot_builtin_call;
const lnako_aot_builtin_call_site = state.lnako_aot_builtin_call_site;
const lnako_aot_compare = state.lnako_aot_compare;
const lnako_aot_concat = state.lnako_aot_concat;
const lnako_aot_cut = state.lnako_aot_cut;
const lnako_aot_cut_site = state.lnako_aot_cut_site;
const lnako_aot_debug_display = state.lnako_aot_debug_display;
const lnako_aot_destructure_get = state.lnako_aot_destructure_get;
const lnako_aot_dispatch_display_begin = state.lnako_aot_dispatch_display_begin;
const lnako_aot_dispatch_display_begin_with_epoch = state.lnako_aot_dispatch_display_begin_with_epoch;
const lnako_aot_dispatch_result = state.lnako_aot_dispatch_result;
const lnako_aot_exception_pending = state.lnako_aot_exception_pending;
const lnako_aot_exception_set = state.lnako_aot_exception_set;
const lnako_aot_exception_set_error_message = state.lnako_aot_exception_set_error_message;
const lnako_aot_exception_take = state.lnako_aot_exception_take;
const lnako_aot_function_call = state.lnako_aot_function_call;
const lnako_aot_function_capture = state.lnako_aot_function_capture;
const lnako_aot_function_new = state.lnako_aot_function_new;
const lnako_aot_function_new_named = state.lnako_aot_function_new_named;
const lnako_aot_hatena_execute = state.lnako_aot_hatena_execute;
const lnako_aot_increment = state.lnako_aot_increment;
const lnako_aot_index_get = state.lnako_aot_index_get;
const lnako_aot_index_set = state.lnako_aot_index_set;
const lnako_aot_node_file_callback_call = state.lnako_aot_node_file_callback_call;
const lnako_aot_node_stdin_callback_call = state.lnako_aot_node_stdin_callback_call;
const lnako_aot_print_collection = state.lnako_aot_print_collection;
const lnako_aot_print_number = state.lnako_aot_print_number;
const lnako_aot_promise_call_site = state.lnako_aot_promise_call_site;
const lnako_aot_regexp_call_site = state.lnako_aot_regexp_call_site;
const lnako_aot_runtime_drain_events = state.lnako_aot_runtime_drain_events;
const lnako_aot_shift = state.lnako_aot_shift;
const lnako_aot_stdio_call = state.lnako_aot_stdio_call;
const lnako_aot_timer_call_site = state.lnako_aot_timer_call_site;
const markupBuiltin = state.markupBuiltin;
const measureCallableBuiltin = state.measureCallableBuiltin;
const nodeBasenameFor = state.nodeBasenameFor;
const nodeBasenameWideFor = state.nodeBasenameWideFor;
const nodeChangeDirectoryBuiltin = state.nodeChangeDirectoryBuiltin;
const nodeCreateTemporaryDirectoryBuiltin = state.nodeCreateTemporaryDirectoryBuiltin;
const nodeCryptoBuiltin = state.nodeCryptoBuiltin;
const nodeCurrentDirectoryBuiltin = state.nodeCurrentDirectoryBuiltin;
const nodeDirectoryBuiltin = state.nodeDirectoryBuiltin;
const nodeDirname = state.nodeDirname;
const nodeDirnameFor = state.nodeDirnameFor;
const nodeEncodingBuiltin = state.nodeEncodingBuiltin;
const nodeEncodingSupportsBuiltin = state.nodeEncodingSupportsBuiltin;
const nodeEnvironmentBuiltin = state.nodeEnvironmentBuiltin;
const nodeEnvironmentListBuiltin = state.nodeEnvironmentListBuiltin;
const nodeEnvironmentValueBuiltin = state.nodeEnvironmentValueBuiltin;
const nodeFileCopyMoveBuiltin = state.nodeFileCopyMoveBuiltin;
const nodeFileExistenceBuiltin = state.nodeFileExistenceBuiltin;
const nodeFileInfoBuiltin = state.nodeFileInfoBuiltin;
const nodeFileOperationBuiltin = state.nodeFileOperationBuiltin;
const nodeFileReadBuiltin = state.nodeFileReadBuiltin;
const nodeFileSaveBuiltin = state.nodeFileSaveBuiltin;
const nodeFileSizeBuiltin = state.nodeFileSizeBuiltin;
const nodeMotherPathBuiltin = state.nodeMotherPathBuiltin;
const nodeNetworkAddressesBuiltin = state.nodeNetworkAddressesBuiltin;
const nodePathBuiltin = state.nodePathBuiltin;
const nodePostDataBuiltin = state.nodePostDataBuiltin;
const nodeProcessExitCode = state.nodeProcessExitCode;
const nodeStdinAllBuiltin = state.nodeStdinAllBuiltin;
const nodeStdinCallbackBuiltin = state.nodeStdinCallbackBuiltin;
const nodeStdinLineBuiltin = state.nodeStdinLineBuiltin;
const nodeStdinValueBuiltin = state.nodeStdinValueBuiltin;
const numberValue = state.numberValue;
const pathBuiltin = state.pathBuiltin;
const pendingExceptionMessageUtf8Alloc = state.pendingExceptionMessageUtf8Alloc;
const referenceAotArrayStringKeyAllocationTest = state.referenceAotArrayStringKeyAllocationTest;
const referenceBuiltin = state.referenceBuiltin;
const regexpBuiltin = state.regexpBuiltin;
const runtimeUtf8String = state.runtimeUtf8String;
const safe_array_element_limit = state.safe_array_element_limit;
const search_element_limit = state.search_element_limit;
const shift = state.shift;
const staticStringValue = state.staticStringValue;
const staticUtf8 = state.staticUtf8;
const strictEqual = state.strictEqual;
const systemExecutionBuiltin = state.systemExecutionBuiltin;
const systemPathComponentBuiltin = state.systemPathComponentBuiltin;
const tableBuiltin = state.tableBuiltin;
const tableColumnCountBuiltin = state.tableColumnCountBuiltin;
const tablePropertyIndex = state.tablePropertyIndex;
const tableRowProperty = state.tableRowProperty;
const table_byte_buffer_buffer_enumerable_property_names = state.table_byte_buffer_buffer_enumerable_property_names;
const testAotCapturedIncrement = state.testAotCapturedIncrement;
const testAotConstantSeven = state.testAotConstantSeven;
const testAotCustomString = state.testAotCustomString;
const testAotDescending = state.testAotDescending;
const testAotDouble = state.testAotDouble;
const testAotEven = state.testAotEven;
const testAotFileProgressStop = state.testAotFileProgressStop;
const testAotFunction = state.testAotFunction;
const testAotKanaCharAtA = state.testAotKanaCharAtA;
const testAotKanaSplit = state.testAotKanaSplit;
const testAotKanaSubstringPlain = state.testAotKanaSubstringPlain;
const testAotKanaSubstringVoiced = state.testAotKanaSubstringVoiced;
const testAotSecondArgument = state.testAotSecondArgument;
const testAotSortOrder = state.testAotSortOrder;
const testAotToPrimitiveObject = state.testAotToPrimitiveObject;
const toml_temporal = state.toml_temporal;
const urlBuiltin = state.urlBuiltin;
const utf16FailureMessageUtf8Alloc = state.utf16FailureMessageUtf8Alloc;
const validateFillDimensions = state.validateFillDimensions;
const valueToNumber = state.valueToNumber;
const valueToPrimitive = state.valueToPrimitive;
const valueUtf16Alloc = state.valueUtf16Alloc;
const valueUtf8LossyAlloc = state.valueUtf8LossyAlloc;

test "UTF-16文字列をルートから正確にmark-and-sweepする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var values = [_]Value{try runtime.createString(&.{ 0x3042, 0xd83d, 0xde00 })};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &values, values.len);
    try std.testing.expectEqual(@as(usize, 0), runtime.collect());
    try std.testing.expectEqual(@as(usize, 1), runtime.object_count);
    try std.testing.expectEqualSlices(u16, &.{ 0x3042, 0xd83d, 0xde00 }, values[0].object().?.payload.utf16_string);
    runtime.popRoots(&frame);
    try std.testing.expectEqual(@as(usize, 1), runtime.collect());
    try std.testing.expectEqual(@as(usize, 0), runtime.object_count);
}

test "LLVM側の値ABIと同じ16バイト配置を保つ" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Value));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Value, "tag"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Value, "payload"));
}

test "公開AOT ABIは動的値をポインタで受け渡す" {
    try std.testing.expectEqual(*const fn (?*Value, ?*Value, ?*Value, i32, ?*const anyopaque) callconv(.c) void, @TypeOf(&lnako_aot_node_constants_init));
    try std.testing.expectEqual(*const fn (?*Value, ?*Value, ?*Value, i32, ?*const anyopaque) callconv(.c) void, @TypeOf(&lnako_aot_node_constants_init_wide));
    try std.testing.expectEqual(*const fn (?*Value, ?*Value, ?*Value) callconv(.c) void, @TypeOf(&lnako_aot_node_directory_constants_init));
    try std.testing.expectEqual(*const fn (?*Value, ?[*]const u8, u64) callconv(.c) void, @TypeOf(&lnako_aot_node_mother_path_init));
    try std.testing.expectEqual(*const fn (*Value, *anyopaque, ?[*]const Value, usize) callconv(.c) void, FunctionCallback);
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize) callconv(.c) void, @TypeOf(&lnako_aot_array_new));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value) callconv(.c) void, @TypeOf(&lnako_aot_index_get));
    try std.testing.expectEqual(*const fn (*const Value, *const Value, *const Value) callconv(.c) c_int, @TypeOf(&lnako_aot_index_set));
    try std.testing.expectEqual(*const fn (*Value, *const Value, usize) callconv(.c) void, @TypeOf(&lnako_aot_destructure_get));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value, u8) callconv(.c) void, @TypeOf(&lnako_aot_arithmetic));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value, u8) callconv(.c) void, @TypeOf(&lnako_aot_compare));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value, u8) callconv(.c) void, @TypeOf(&lnako_aot_shift));
    try std.testing.expectEqual(*const fn (*Value, *const Value, *const Value) callconv(.c) void, @TypeOf(&lnako_aot_concat));
    try std.testing.expectEqual(*const fn (*Value, *const Value) callconv(.c) void, @TypeOf(&lnako_aot_increment));
    try std.testing.expectEqual(*const fn (*const Value, bool) callconv(.c) void, @TypeOf(&lnako_aot_print_collection));
    try std.testing.expectEqual(*const fn (*Value, ?*const Value) callconv(.c) void, @TypeOf(&lnako_aot_binding_cell_new));
    try std.testing.expectEqual(*const fn (*Value) callconv(.c) *Value, @TypeOf(&lnako_aot_binding_cell_value));
    try std.testing.expectEqual(*const fn (*Value, FunctionCallback, usize, ?[*]const Value, usize) callconv(.c) void, @TypeOf(&lnako_aot_function_new));
    try std.testing.expectEqual(*const fn (*Value, *anyopaque, usize) callconv(.c) void, @TypeOf(&lnako_aot_function_capture));
    try std.testing.expectEqual(*const fn (*Value, *const Value, ?[*]const Value, usize) callconv(.c) void, @TypeOf(&lnako_aot_function_call));
    try std.testing.expectEqual(*const fn (*Value, *Value, ?[*]const Value, usize, u8) callconv(.c) void, @TypeOf(&lnako_aot_cut));
    try std.testing.expectEqual(*const fn (*Value, *Value, ?[*]const Value, usize, u8, u64) callconv(.c) void, @TypeOf(&lnako_aot_cut_site));
    try std.testing.expectEqual(*const fn (*Value, *Value, ?[*]const Value, usize, u16, u64) callconv(.c) void, @TypeOf(&lnako_aot_node_stdin_callback_call));
    try std.testing.expectEqual(*const fn (*Value, *Value, ?[*]const Value, usize, u16, u64) callconv(.c) void, @TypeOf(&lnako_aot_archive_call));
    try std.testing.expectEqual(*const fn () callconv(.c) void, @TypeOf(&lnako_aot_runtime_drain_events));
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize, u16) callconv(.c) void, @TypeOf(&lnako_aot_builtin_call));
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize, u16, u64) callconv(.c) void, @TypeOf(&lnako_aot_builtin_call_site));
    try std.testing.expectEqual(*const fn (*Value, *Value, ?[*]const Value, usize, u16, u64) callconv(.c) void, @TypeOf(&lnako_aot_timer_call_site));
    try std.testing.expectEqual(*const fn (*Value, *Value, *Value, ?[*]const Value, usize, u16, u64) callconv(.c) void, @TypeOf(&lnako_aot_promise_call_site));
    try std.testing.expectEqual(*const fn (*Value, ?*const Value, u64, ?[*]const u8, usize, ?*Value, u64) callconv(.c) void, @TypeOf(&lnako_aot_debug_display));
    try std.testing.expectEqual(*const fn (*Value, ?*const Value, u64, ?[*]const u8, usize, ?*Value, u64) callconv(.c) void, @TypeOf(&lnako_aot_hatena_execute));
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize, *Value, u64) callconv(.c) void, @TypeOf(&lnako_aot_archive_tool_path_set));
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize, *Value, u64) callconv(.c) void, @TypeOf(&lnako_aot_archive_tool_path_set));
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize, *Value, u64) callconv(.c) void, @TypeOf(&lnako_aot_ajax_options_set));
    try std.testing.expectEqual(*const fn (*Value, ?[*]const Value, usize, *Value, u64) callconv(.c) void, @TypeOf(&lnako_aot_ajax_onerror_set));
    try std.testing.expectEqual(*const fn (*Value, ?*Value, ?[*]const Value, usize, u16, u64) callconv(.c) void, @TypeOf(&lnako_aot_regexp_call_site));
    try std.testing.expectEqual(*const fn (u64) callconv(.c) u64, @TypeOf(&lnako_aot_dispatch_display_begin));
    try std.testing.expectEqual(*const fn (u64, *u64) callconv(.c) u64, @TypeOf(&lnako_aot_dispatch_display_begin_with_epoch));
    try std.testing.expectEqual(*const fn (u64, u64, u64) callconv(.c) void, @TypeOf(&lnako_aot_dispatch_result));
    try std.testing.expectEqual(*const fn (*const Value, bool) callconv(.c) void, @TypeOf(&lnako_aot_print_number));
    try std.testing.expectEqual(*const fn (*const Value) callconv(.c) void, @TypeOf(&lnako_aot_exception_set));
    try std.testing.expectEqual(*const fn (*const Value) callconv(.c) void, @TypeOf(&lnako_aot_exception_set_error_message));
    try std.testing.expectEqual(*const fn () callconv(.c) c_int, @TypeOf(&lnako_aot_exception_pending));
    try std.testing.expectEqual(*const fn (*Value) callconv(.c) void, @TypeOf(&lnako_aot_exception_take));
}

test "AOTコマンドライン定数は生成mainのargvから構築する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }

    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const executable = "/opt/lnako/bin/sample";
    const first_argument = "alpha";
    const second_argument = "日本語";
    var argv = [_]?[*:0]const u8{ executable.ptr, first_argument.ptr, second_argument.ptr, null };
    lnako_aot_node_constants_init(&roots[0], &roots[1], &roots[2], 3, @ptrCast(&argv));

    try std.testing.expectEqual(Tag.array, @as(Tag, @enumFromInt(roots[0].tag)));
    const arguments = roots[0].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 3), arguments.len);
    try expectUtf16String(&state.active_runtime.?, arguments[0], executable);
    try expectUtf16String(&state.active_runtime.?, arguments[1], first_argument);
    try expectUtf16String(&state.active_runtime.?, arguments[2], second_argument);
    try expectUtf16String(&state.active_runtime.?, roots[1], "sample");
    try expectUtf16String(&state.active_runtime.?, roots[2], executable);
}

test "AOT Windows wide argvはUTF-16引数とWTF-16実行ファイル名を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }

    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    var executable = [_:0]u16{ 'C', ':', '\\', 0x65e5, 0x672c, '\\', 0xd800 };
    var first_argument = [_:0]u16{ 0xd83d, 0xde00 };
    var argv = [_]?[*:0]const u16{ &executable, &first_argument, null };
    lnako_aot_node_constants_init_wide(&roots[0], &roots[1], &roots[2], 2, @ptrCast(&argv));

    try std.testing.expectEqual(Tag.array, @as(Tag, @enumFromInt(roots[0].tag)));
    const arguments = roots[0].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 2), arguments.len);
    const executable_units = try valueUtf16Alloc(&state.active_runtime.?, arguments[0]);
    defer state.active_runtime.?.allocator.free(executable_units);
    try std.testing.expectEqualSlices(u16, executable[0..], executable_units);
    const first_units = try valueUtf16Alloc(&state.active_runtime.?, arguments[1]);
    defer state.active_runtime.?.allocator.free(first_units);
    try std.testing.expectEqualSlices(u16, first_argument[0..], first_units);
    const name_units = try valueUtf16Alloc(&state.active_runtime.?, roots[1]);
    defer state.active_runtime.?.allocator.free(name_units);
    try std.testing.expectEqualSlices(u16, &.{0xd800}, name_units);
    const path_units = try valueUtf16Alloc(&state.active_runtime.?, roots[2]);
    defer state.active_runtime.?.allocator.free(path_units);
    try std.testing.expectEqualSlices(u16, executable[0..], path_units);
}

test "AOT dispatchのfailure epochは過去のpending exceptionを再利用しない" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();

    const first_dispatch_epoch = runtime.failure_epoch;
    runtime.setFailure(error.InvalidArgumentCount);
    try std.testing.expectEqual(first_dispatch_epoch +% 1, runtime.failure_epoch);
    try std.testing.expect(runtime.has_pending_exception);

    // The pending exception intentionally remains set. A successful dispatch
    // beginning here observes the new epoch and therefore is not attributed
    // the earlier failure merely because the slot is still occupied.
    const second_dispatch_epoch = runtime.failure_epoch;
    try std.testing.expectEqual(second_dispatch_epoch, runtime.failure_epoch);
    try std.testing.expect(second_dispatch_epoch != first_dispatch_epoch);

    _ = runtime.takeException();
    try std.testing.expectEqual(second_dispatch_epoch, runtime.failure_epoch);
    try std.testing.expect(!runtime.has_pending_exception);
}

test "AOT切取はUTF-16検索と元値lengthの遅延評価を再現する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try state.active_runtime.?.createString(&.{ 'a', ':', 'b', ':', 'c' });
    roots[1] = try state.active_runtime.?.createString(&.{':'});
    var cut_arguments = [_]Value{ roots[0], roots[1] };
    roots[2] = try state.active_runtime.?.createString(&.{ 'k', 'e', 'e', 'p' });
    lnako_aot_cut(&roots[3], &roots[2], &cut_arguments, cut_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{'a'}, roots[3].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 'b', ':', 'c' }, roots[2].object().?.payload.utf16_string);

    roots[4] = try state.active_runtime.?.createString(&.{ 'a', '[', 'b', ']', 'c', '[', 'd', ']', 'e' });
    roots[5] = try state.active_runtime.?.createString(&.{'['});
    roots[6] = try state.active_runtime.?.createString(&.{']'});
    var range_arguments = [_]Value{ roots[4], roots[5], roots[6] };
    lnako_aot_cut(&roots[7], &roots[2], &range_arguments, range_arguments.len, 1);
    try std.testing.expectEqualSlices(u16, &.{'b'}, roots[7].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'c', '[', 'd', ']', 'e' }, roots[2].object().?.payload.utf16_string);

    roots[8] = try state.active_runtime.?.createString(&.{ '1', '2', '3', 'X' });
    const number_arguments = [_]Value{ roots[8], numberValue(123) };
    lnako_aot_cut(&roots[9], &roots[2], &number_arguments, number_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[9].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ '1', '2', '3', 'X' }, roots[2].object().?.payload.utf16_string);

    roots[10] = try state.active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    roots[11] = try state.active_runtime.?.createString(&.{ '1', ',', '2', 'X' });
    const array_arguments = [_]Value{ roots[11], roots[10] };
    lnako_aot_cut(&roots[12], &roots[2], &array_arguments, array_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[12].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ '2', 'X' }, roots[2].object().?.payload.utf16_string);

    roots[18] = try state.active_runtime.?.createString(&.{ 't', 'r', 'u', 'e', 'X' });
    const boolean_arguments = [_]Value{ roots[18], .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 } };
    lnako_aot_cut(&roots[19], &roots[2], &boolean_arguments, boolean_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[19].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 't', 'r', 'u', 'e', 'X' }, roots[2].object().?.payload.utf16_string);

    roots[13] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("length"), numberValue(2) });
    roots[14] = try state.active_runtime.?.createString(&.{ '[', 'o', 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']', 'X' });
    const dictionary_arguments = [_]Value{ roots[14], roots[13] };
    lnako_aot_cut(&roots[15], &roots[2], &dictionary_arguments, dictionary_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[15].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']', 'X' }, roots[2].object().?.payload.utf16_string);

    lnako_aot_function_new(&roots[10], testAotFunction, 1, null, 0);
    const function_arguments = [_]Value{ staticStringValue("function () { [native code] }X"), roots[10] };
    lnako_aot_cut(&roots[11], &roots[2], &function_arguments, function_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[11].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 'u', 'n', 'c', 't', 'i', 'o', 'n', ' ', '(', ')', ' ', '{', ' ', '[', 'n', 'a', 't', 'i', 'v', 'e', ' ', 'c', 'o', 'd', 'e', ']', ' ', '}', 'X' }, roots[2].object().?.payload.utf16_string);

    roots[16] = try state.active_runtime.?.createString(&.{ 0xd83d, 0xde00, 0, 0xd800 });
    roots[17] = try state.active_runtime.?.createString(&.{ 0xd83d, 0xde00 });
    const unicode_arguments = [_]Value{ roots[16], roots[17] };
    try std.testing.expectEqual(@as(?usize, 0), indexOfUnitsBuiltin(roots[16].object().?.payload.utf16_string, roots[17].object().?.payload.utf16_string, 0));
    try std.testing.expectEqual(@as(usize, 2), try cutEndIndex(&state.active_runtime.?, 0, roots[17], 4));
    state.active_runtime.?.next_collection = state.active_runtime.?.object_count;
    lnako_aot_cut(&roots[3], &roots[2], &unicode_arguments, unicode_arguments.len, 0);
    try std.testing.expectEqualSlices(u16, &.{}, roots[3].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 0, 0xd800 }, roots[2].object().?.payload.utf16_string);

    const absent_range_arguments = [_]Value{ roots[16], staticStringValue("missing"), .{ .tag = @intFromEnum(Tag.null_value) } };
    lnako_aot_cut(&roots[3], &roots[2], &absent_range_arguments, absent_range_arguments.len, 1);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(u16, &.{}, roots[3].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00, 0, 0xd800 }, roots[2].object().?.payload.utf16_string);

    const undefined_nonmatch_arguments = [_]Value{ staticStringValue("abc"), .{} };
    lnako_aot_cut(&roots[3], &roots[2], &undefined_nonmatch_arguments, undefined_nonmatch_arguments.len, 0);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, roots[3].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{}, roots[2].object().?.payload.utf16_string);

    roots[2] = try state.active_runtime.?.createString(&.{ 'k', 'e', 'e', 'p' });
    const null_match_arguments = [_]Value{ staticStringValue("null"), .{ .tag = @intFromEnum(Tag.null_value) } };
    lnako_aot_cut(&roots[3], &roots[2], &null_match_arguments, null_match_arguments.len, 0);
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(u16, &.{ 'k', 'e', 'e', 'p' }, roots[2].object().?.payload.utf16_string);
    lnako_aot_exception_take(&roots[1]);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);

    const undefined_match_arguments = [_]Value{ staticStringValue("undefined"), .{} };
    lnako_aot_cut(&roots[3], &roots[2], &undefined_match_arguments, undefined_match_arguments.len, 0);
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(u16, &.{ 'k', 'e', 'e', 'p' }, roots[2].object().?.payload.utf16_string);
    lnako_aot_exception_take(&roots[1]);
    try std.testing.expect(!state.active_runtime.?.has_pending_exception);
}

test "AOT関数値を呼び出しGCで回収する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var function: Value = .{};
    lnako_aot_function_new(&function, testAotFunction, 1, null, 0);
    var argument = numberValue(7);
    var result: Value = .{};
    lnako_aot_function_call(&result, &function, @ptrCast(&argument), 1);
    try std.testing.expectEqual(argument.payload, result.payload);
    try std.testing.expectEqual(@as(usize, 1), state.active_runtime.?.object_count);
    try std.testing.expectEqual(@as(usize, 1), lnako_aot_collect());
}

test "AOT関数値の文字列化は生成ABIの関数名を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const name = "試験123";
    const expected = "function 試験123() { [native code] }";
    lnako_aot_function_new_named(&roots[0], testAotFunction, 0, name.ptr, name.len, null, 0);
    const text = try valueUtf16Alloc(&state.active_runtime.?, roots[0]);
    defer state.active_runtime.?.allocator.free(text);
    const expected_units = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, expected);
    defer std.testing.allocator.free(expected_units);
    try std.testing.expectEqualSlices(u16, expected_units, text);

    roots[1] = try valueToPrimitive(&state.active_runtime.?, roots[0], .number);
    try std.testing.expectEqualSlices(u16, expected_units, roots[1].object().?.payload.utf16_string);
}

test "AOT動的関数の不足引数へ共有システム文脈を追加し超過引数を無視する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, numberValue(3), numberValue(4), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_function_new(&roots[0], testAotFunction, 1, null, 0);
    lnako_aot_function_new(&roots[1], testAotSecondArgument, 2, null, 0);
    lnako_aot_function_call(&roots[4], &roots[0], null, 0);
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[4].tag)));
    const system_context = roots[4].payload;
    lnako_aot_function_call(&roots[4], &roots[1], @ptrCast(&roots[2]), 1);
    try std.testing.expectEqual(system_context, roots[4].payload);
    lnako_aot_function_call(&roots[4], &roots[0], @ptrCast(&roots[2]), 2);
    try std.testing.expectEqual(roots[2].payload, roots[4].payload);
}

test "AOT標準命令ディスパッチで値を文字列へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 }, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.to_string));
    try std.testing.expectEqualSlices(u16, &.{ 't', 'r', 'u', 'e' }, roots[1].object().?.payload.utf16_string);
}

test "AOT標準出力ABIは出力プールと表示履歴の境界を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    roots[0] = try createJsonTestString(&runtime, "old\n");
    roots[1] = try createJsonTestString(&runtime, "A");
    roots[2] = try createJsonTestString(&runtime, "B");
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    lnako_aot_stdio_call(&roots[3], &roots[0], @ptrCast(&roots[1]), 1, @intFromEnum(aot_builtin.Command.stdio_continue_display), 0);
    lnako_aot_stdio_call(&roots[3], &roots[0], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.stdio_continue_display_many), 0);
    try std.testing.expectEqualStrings("AB", active.print_pool.items);

    try appendDisplayLog(active, &roots[0], active.print_pool.items);
    try expectUtf16String(active, roots[0], "old\nAB\n");
    lnako_aot_stdio_call(&roots[3], &roots[0], null, 0, @intFromEnum(aot_builtin.Command.stdio_clear_log), 0);
    try expectUtf16String(active, roots[0], "");
    try std.testing.expectEqualStrings("AB", active.print_pool.items);
}

test "AOT型確認は動的値をJavaScript型名へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ numberValue(1), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.type_of));
    try std.testing.expectEqualStrings("number", staticUtf8(roots[1]));
}

test "AOT数学命令dispatchは数値・配列・別名を処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = numberValue(0);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.math_sin));
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(roots[1].payload)));

    roots[2] = numberValue(2);
    roots[3] = numberValue(8);
    var logarithm_arguments = [_]Value{ roots[2], roots[3] };
    lnako_aot_builtin_call(&roots[4], &logarithm_arguments, logarithm_arguments.len, @intFromEnum(aot_builtin.Command.math_logn));
    try std.testing.expectApproxEqAbs(@as(f64, 3), @as(f64, @bitCast(roots[4].payload)), 1e-14);

    roots[5] = try state.active_runtime.?.createArray(&.{ numberValue(0), numberValue(1) });
    lnako_aot_builtin_call(&roots[6], @ptrCast(&roots[5]), 1, @intFromEnum(aot_builtin.Command.math_coordinate_angle));
    try std.testing.expectApproxEqAbs(@as(f64, 90), @as(f64, @bitCast(roots[6].payload)), 1e-12);

    roots[7] = numberValue(-1.2);
    lnako_aot_builtin_call(&roots[8], @ptrCast(&roots[7]), 1, @intFromEnum(aot_builtin.Command.math_floor));
    try std.testing.expectEqual(@as(f64, -2), @as(f64, @bitCast(roots[8].payload)));

    roots[9] = numberValue(-1.5);
    lnako_aot_builtin_call(&roots[10], @ptrCast(&roots[9]), 1, @intFromEnum(aot_builtin.Command.math_round));
    try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(roots[10].payload)));
}

test "AOT乱数命令は固定シードの数値・配列・辞書・範囲を処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .random_state = default_random_seed };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = numberValue(10);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.math_random));
    try std.testing.expectEqual(@as(f64, 8), @as(f64, @bitCast(roots[1].payload)));

    roots[2] = try state.active_runtime.?.createArray(&.{ numberValue(2), numberValue(4) });
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.math_random));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[3].payload)));

    roots[4] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(7), staticStringValue("末尾"), numberValue(9) });
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[4]), 1, @intFromEnum(aot_builtin.Command.math_random));
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(roots[5].payload)));

    roots[6] = numberValue(10);
    roots[7] = numberValue(12);
    var range_arguments = [_]Value{ roots[6], roots[7] };
    lnako_aot_builtin_call(&roots[8], &range_arguments, range_arguments.len, @intFromEnum(aot_builtin.Command.math_random_range));
    try std.testing.expectEqual(@as(f64, 10), @as(f64, @bitCast(roots[8].payload)));
}

test "AOT日時の現在時刻・日付・年月命令を固定時計で処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .clock_milliseconds = 1_735_689_845_678 };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 12;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try datetimeBuiltin(&runtime, .datetime_now, &.{});
    try expectUtf16String(&runtime, roots[0], "09:04:05");
    roots[1] = try datetimeBuiltin(&runtime, .datetime_system_time, &.{});
    try std.testing.expectEqual(@as(f64, 1_735_689_845), @as(f64, @bitCast(roots[1].payload)));
    roots[2] = try datetimeBuiltin(&runtime, .datetime_system_time_milliseconds, &.{});
    try std.testing.expectEqual(@as(f64, 1_735_689_845_678), @as(f64, @bitCast(roots[2].payload)));
    roots[3] = try datetimeBuiltin(&runtime, .datetime_today, &.{});
    try expectUtf16String(&runtime, roots[3], "2025/01/01");
    roots[4] = try datetimeBuiltin(&runtime, .datetime_tomorrow, &.{});
    try expectUtf16String(&runtime, roots[4], "2025/01/02");
    roots[5] = try datetimeBuiltin(&runtime, .datetime_yesterday, &.{});
    try expectUtf16String(&runtime, roots[5], "2024/12/31");
    roots[6] = try datetimeBuiltin(&runtime, .datetime_current_year, &.{});
    try std.testing.expectEqual(@as(f64, 2025), @as(f64, @bitCast(roots[6].payload)));
    roots[7] = try datetimeBuiltin(&runtime, .datetime_next_year, &.{});
    try std.testing.expectEqual(@as(f64, 2026), @as(f64, @bitCast(roots[7].payload)));
    roots[8] = try datetimeBuiltin(&runtime, .datetime_last_year, &.{});
    try std.testing.expectEqual(@as(f64, 2024), @as(f64, @bitCast(roots[8].payload)));
    roots[9] = try datetimeBuiltin(&runtime, .datetime_current_month, &.{});
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[9].payload)));
    roots[10] = try datetimeBuiltin(&runtime, .datetime_next_month, &.{});
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[10].payload)));
    roots[11] = try datetimeBuiltin(&runtime, .datetime_previous_month, &.{});
    try std.testing.expectEqual(@as(f64, 12), @as(f64, @bitCast(roots[11].payload)));
}

test "AOT曜日命令はAsia/Tokyoの日曜始まり番号を処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .clock_milliseconds = 1_735_689_845_678 };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "2024/02/29");
    var arguments = [_]Value{roots[0]};
    roots[1] = try datetimeBuiltin(&runtime, .datetime_weekday, &arguments);
    roots[2] = try datetimeBuiltin(&runtime, .datetime_weekday_number, &arguments);
    try expectUtf16String(&runtime, roots[1], "木");
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast(roots[2].payload)));

    roots[3] = try runtimeUtf8String(&runtime, "2024/02/30");
    arguments[0] = roots[3];
    roots[4] = try datetimeBuiltin(&runtime, .datetime_weekday, &arguments);
    try expectUtf16String(&runtime, roots[4], "金");
}

test "AOT Unix日時変換は秒と日時文字列を相互変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .clock_milliseconds = 1_735_689_845_678 };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "1970/01/01 09:00:01");
    var arguments = [_]Value{roots[0]};
    roots[1] = try datetimeBuiltin(&runtime, .datetime_unix_time, &arguments);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[1].payload)));

    arguments[0] = numberValue(3);
    roots[2] = try datetimeBuiltin(&runtime, .datetime_date_time, &arguments);
    try expectUtf16String(&runtime, roots[2], "1970/01/01 09:00:03");

    arguments[0] = try runtimeUtf8String(&runtime, "3");
    roots[3] = try datetimeBuiltin(&runtime, .datetime_date_time, &arguments);
    try expectUtf16String(&runtime, roots[3], "1970/01/01 09:00:03");
}

test "AOT日時書式差分加算と単調時計を処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .clock_milliseconds = 1_735_689_845_678, .monotonic_milliseconds = 123.5 };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 16;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "2024/02/29 03:04:05");
    roots[1] = try runtimeUtf8String(&runtime, "YYYY-MM-DD WWW HH:mm:ss ccc MMM W YY MM DD HH mm ss M D H m s");
    var arguments = [_]Value{ roots[0], roots[1] };
    roots[2] = try datetimeBuiltin(&runtime, .datetime_format, &arguments);
    try expectUtf16String(&runtime, roots[2], "2024-02-29 Thu 03:04:05 000 Feb 木 24 02 29 03 04 05 2 29 3 4 5");

    roots[3] = try runtimeUtf8String(&runtime, "2019/05/01");
    arguments[0] = roots[3];
    roots[4] = try datetimeBuiltin(&runtime, .datetime_era, arguments[0..1]);
    try expectUtf16String(&runtime, roots[4], "令和元年05月01日");

    roots[5] = try runtimeUtf8String(&runtime, "2020/01/01");
    roots[6] = try runtimeUtf8String(&runtime, "2024/01/01");
    arguments = .{ roots[5], roots[6] };
    roots[7] = try datetimeBuiltin(&runtime, .datetime_year_difference, &arguments);
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast(roots[7].payload)));

    roots[8] = try runtimeUtf8String(&runtime, "日");
    var unit_arguments = [_]Value{ roots[5], roots[6], roots[8] };
    roots[9] = try datetimeBuiltin(&runtime, .datetime_difference, &unit_arguments);
    try std.testing.expectEqual(@as(f64, 1461), @as(f64, @bitCast(roots[9].payload)));

    roots[10] = try runtimeUtf8String(&runtime, "2024/01/01 23:30:00");
    roots[11] = try runtimeUtf8String(&runtime, "+01:00:00");
    arguments = .{ roots[10], roots[11] };
    roots[12] = try datetimeBuiltin(&runtime, .datetime_add_time, &arguments);
    try expectUtf16String(&runtime, roots[12], "2024/01/02 00:30:00");

    roots[13] = try runtimeUtf8String(&runtime, "2024/01/31");
    roots[14] = try runtimeUtf8String(&runtime, "0/1/0");
    arguments = .{ roots[13], roots[14] };
    roots[15] = try datetimeBuiltin(&runtime, .datetime_add_date, &arguments);
    try expectUtf16String(&runtime, roots[15], "2024/03/02");

    try std.testing.expectEqual(@as(f64, 123.5), @as(f64, @bitCast((try datetimeBuiltin(&runtime, .datetime_monotonic_milliseconds, &.{})).payload)));
}

test "AOT旧形式plugin_datetimeの日付加算は月末をdayjs互換で丸める" {
    const original = datetimeConstructLocal(2024, 0, 31, 0, 0, 0, 0, false);
    const parts = [_]i64{ 0, 1, 0 };
    const plugin_fields = datetimeFieldsFromEpoch(datetimeAddDatePluginEpoch(original, parts, 1));
    try std.testing.expectEqual(@as(i64, 2024), plugin_fields.year);
    try std.testing.expectEqual(@as(i64, 2), plugin_fields.month);
    try std.testing.expectEqual(@as(i64, 29), plugin_fields.day);

    const system_fields = datetimeFieldsFromEpoch(datetimeAddDateSystemEpoch(original, parts, 1));
    try std.testing.expectEqual(@as(i64, 2024), system_fields.year);
    try std.testing.expectEqual(@as(i64, 3), system_fields.month);
    try std.testing.expectEqual(@as(i64, 2), system_fields.day);
}

test "AOT URLとBase64命令はUTF-16文字列と配列を処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "A あ/😀");
    var arguments = [_]Value{roots[0]};
    roots[1] = try urlBuiltin(&runtime, .url_encode, &arguments);
    try expectUtf16String(&runtime, roots[1], "A%20%E3%81%82%2F%F0%9F%98%80");
    arguments[0] = roots[1];
    roots[2] = try urlBuiltin(&runtime, .url_decode, &arguments);
    try expectUtf16String(&runtime, roots[2], "A あ/😀");

    arguments[0] = try runtimeUtf8String(&runtime, "https://example.test/?a=1&a=2&flag");
    roots[3] = try urlBuiltin(&runtime, .url_parameters, &arguments);
    try expectUtf16String(&runtime, dictionaryProperty(roots[3], &.{'a'}), "2");
    try expectUtf16String(&runtime, dictionaryProperty(roots[3], &.{ 'f', 'l', 'a', 'g' }), "");

    arguments[0] = try runtimeUtf8String(&runtime, "こんにちは");
    roots[4] = try urlBuiltin(&runtime, .base64_encode, &arguments);
    try expectUtf16String(&runtime, roots[4], "44GT44KT44Gr44Gh44Gv");
    arguments[0] = roots[4];
    roots[5] = try urlBuiltin(&runtime, .base64_decode, &arguments);
    try expectUtf16String(&runtime, roots[5], "こんにちは");

    roots[6] = try runtime.createArray(&.{ numberValue(65), numberValue(300), numberValue(-1) });
    arguments[0] = roots[6];
    roots[7] = try urlBuiltin(&runtime, .base64_encode, &arguments);
    try expectUtf16String(&runtime, roots[7], "QSz/");
}

test "AOT Base64エンコードは3種のbyte bufferを入力にする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    var arguments = [_]Value{.{}};
    roots[0] = try runtime.createBytes(&.{ 0x41, 0x42, 0xff });
    arguments[0] = roots[0];
    roots[1] = try urlBuiltin(&runtime, .base64_encode, &arguments);
    try expectUtf16String(&runtime, roots[1], "QUL/");

    roots[2] = try runtime.createUint8Array(&.{ 0x41, 0x42, 0xff });
    arguments[0] = roots[2];
    roots[3] = try urlBuiltin(&runtime, .base64_encode, &arguments);
    try expectUtf16String(&runtime, roots[3], "QUL/");

    roots[4] = try runtime.createArrayBuffer(&.{ 0x41, 0x42, 0xff });
    arguments[0] = roots[4];
    roots[5] = try urlBuiltin(&runtime, .base64_encode, &arguments);
    try expectUtf16String(&runtime, roots[5], "QUL/");
}

test "AOTパス命令は拡張子と終端区切り文字を処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "/a/.b/c.c++");
    var arguments = [_]Value{ roots[0], .{} };
    roots[1] = try pathBuiltin(&runtime, .path_extract_extension, &arguments);
    try expectUtf16String(&runtime, roots[1], ".c++");

    roots[2] = try runtimeUtf8String(&runtime, ".bashrc");
    arguments[0] = roots[2];
    roots[3] = try pathBuiltin(&runtime, .path_extract_extension, &arguments);
    try expectUtf16String(&runtime, roots[3], ".bashrc");

    const changed_source_text: []const u8 = if (comptime builtin.os.tag == .windows) "C:\\a\\b.txt" else "/a/.b/c.txt";
    const changed_expected: []const u8 = if (comptime builtin.os.tag == .windows) "C:\\a\\b.docx" else "/a/.b/c.docx";
    roots[4] = try runtimeUtf8String(&runtime, changed_source_text);
    roots[5] = try runtimeUtf8String(&runtime, " docx ");
    arguments = .{ roots[4], roots[5] };
    roots[6] = try pathBuiltin(&runtime, .path_change_extension, &arguments);
    try expectUtf16String(&runtime, roots[6], changed_expected);

    const trailing_source: []const u8 = if (comptime builtin.os.tag == .windows) "a\\b" else "a/b";
    const trailing_added: []const u8 = if (comptime builtin.os.tag == .windows) "a\\b\\" else "a/b/";
    roots[7] = try runtimeUtf8String(&runtime, trailing_source);
    arguments = .{ roots[7], .{} };
    roots[8] = try pathBuiltin(&runtime, .path_add_trailing_separator, &arguments);
    try expectUtf16String(&runtime, roots[8], trailing_added);

    const repeated_separator_path: []const u8 = if (comptime builtin.os.tag == .windows) "a\\b\\\\" else "a/b//";
    const removed_separator_path: []const u8 = if (comptime builtin.os.tag == .windows) "a\\b\\" else "a/b/";
    roots[9] = try runtimeUtf8String(&runtime, repeated_separator_path);
    arguments = .{ roots[9], .{} };
    const removed = try pathBuiltin(&runtime, .path_remove_trailing_separator, &arguments);
    try expectUtf16String(&runtime, removed, removed_separator_path);
    const deleted = try pathBuiltin(&runtime, .path_delete_trailing_separator, &arguments);
    try expectUtf16String(&runtime, deleted, removed_separator_path);
}

test "AOT system path aliasはslash splitの末尾要素とpop後のpathを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "/a/b");
    var arguments = [_]Value{roots[0]};
    roots[1] = try systemPathComponentBuiltin(&runtime, .system_path_basename, &arguments);
    try expectUtf16String(&runtime, roots[1], "b");
    roots[2] = try systemPathComponentBuiltin(&runtime, .system_path_dirname, &arguments);
    try expectUtf16String(&runtime, roots[2], "/a");

    roots[3] = try runtimeUtf8String(&runtime, "a/");
    arguments[0] = roots[3];
    roots[4] = try systemPathComponentBuiltin(&runtime, .system_path_dirname, &arguments);
    try expectUtf16String(&runtime, roots[4], "a");
}

test "AOT漢数字命令は指数・全角数字・小数・BigIntを処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = numberValue(10001);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.kansuji_to_kanji));
    try expectUtf16String(&runtime, roots[1], "一万一");

    roots[2] = try runtimeUtf8String(&state.active_runtime.?, "0.01");
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.kansuji_to_kanji));
    try expectUtf16String(&runtime, roots[3], "零・〇一");

    roots[4] = try runtimeUtf8String(&state.active_runtime.?, "1e-3");
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[4]), 1, @intFromEnum(aot_builtin.Command.kansuji_to_kanji));
    try expectUtf16String(&runtime, roots[5], "零・〇〇一");

    roots[6] = try runtimeUtf8String(&state.active_runtime.?, "１２３");
    lnako_aot_builtin_call(&roots[7], @ptrCast(&roots[6]), 1, @intFromEnum(aot_builtin.Command.kansuji_to_kanji));
    try expectUtf16String(&runtime, roots[7], "百二十三");

    roots[8] = try runtimeUtf8String(&state.active_runtime.?, "一万一");
    lnako_aot_builtin_call(&roots[9], @ptrCast(&roots[8]), 1, @intFromEnum(aot_builtin.Command.kansuji_to_arabic));
    try std.testing.expectEqual(@as(f64, 10001), @as(f64, @bitCast(roots[9].payload)));

    roots[0] = try runtimeUtf8String(&state.active_runtime.?, "一・二");
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.kansuji_to_arabic));
    try std.testing.expectEqual(@as(f64, 1.2), @as(f64, @bitCast(roots[1].payload)));

    roots[2] = try runtimeUtf8String(&state.active_runtime.?, "一無量大数");
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.kansuji_to_arabic));
    try std.testing.expectEqual(Tag.bigint, @as(Tag, @enumFromInt(roots[3].tag)));
    const huge = roots[3].object().?.payload.bigint.toString(runtime.allocator, 10) catch unreachable;
    defer runtime.allocator.free(huge);
    try std.testing.expectEqual(@as(usize, 69), huge.len);
    try std.testing.expectEqual(@as(u8, '1'), huge[0]);
    for (huge[1..]) |digit| try std.testing.expectEqual(@as(u8, '0'), digit);
}

test "AOT CSV命令は引用・数値変換・TSV・オプションを処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try runtimeUtf8String(&state.active_runtime.?, "1,\"a,b\",3\n4,5,6");
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.csv_parse));
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[1].object().?.payload.array.items[0].object().?.payload.array.items[0].payload)));
    try expectUtf16String(&runtime, roots[1].object().?.payload.array.items[0].object().?.payload.array.items[1], "a,b");
    try std.testing.expectEqual(@as(usize, 2), roots[1].object().?.payload.array.items.len);

    roots[2] = try runtimeUtf8String(&state.active_runtime.?, "1\t2\n3\t4");
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.tsv_parse));
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast(roots[3].object().?.payload.array.items[1].object().?.payload.array.items[1].payload)));

    roots[4] = try state.active_runtime.?.createArray(&.{});
    roots[5] = try state.active_runtime.?.createArray(&.{numberValue(1)});
    try roots[5].object().?.payload.array.append(state.active_runtime.?.allocator, try runtimeUtf8String(&state.active_runtime.?, "a,b"));
    try roots[4].object().?.payload.array.append(state.active_runtime.?.allocator, roots[5]);
    lnako_aot_builtin_call(&roots[6], @ptrCast(&roots[4]), 1, @intFromEnum(aot_builtin.Command.table_csv_stringify));
    try expectUtf16String(&runtime, roots[6], "1,\"a,b\"\r\n");
    try expectUtf16String(&runtime, roots[5].object().?.payload.array.items[0], "1");
    try expectUtf16String(&runtime, roots[5].object().?.payload.array.items[1], "\"a,b\"");

    roots[7] = try runtimeUtf8String(&state.active_runtime.?, "|");
    roots[8] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("eol"), roots[7], staticStringValue("auto_convert_number"), .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 } });
    lnako_aot_builtin_call(&roots[9], @ptrCast(&roots[8]), 1, @intFromEnum(aot_builtin.Command.csv_options));
    roots[10] = try runtimeUtf8String(&state.active_runtime.?, "1,2");
    lnako_aot_builtin_call(&roots[11], @ptrCast(&roots[10]), 1, @intFromEnum(aot_builtin.Command.csv_parse));
    try std.testing.expectEqual(Tag.utf16_string, @as(Tag, @enumFromInt(roots[11].object().?.payload.array.items[0].object().?.payload.array.items[0].tag)));

    roots[12] = try state.active_runtime.?.createArray(&.{try state.active_runtime.?.createArray(&.{ numberValue(3), numberValue(4) })});
    lnako_aot_builtin_call(&roots[13], @ptrCast(&roots[12]), 1, @intFromEnum(aot_builtin.Command.csv_stringify));
    try expectUtf16String(&runtime, roots[13], "3,4|");
    roots[12] = try state.active_runtime.?.createArray(&.{try state.active_runtime.?.createArray(&.{ numberValue(5), numberValue(6) })});
    lnako_aot_builtin_call(&roots[13], @ptrCast(&roots[12]), 1, @intFromEnum(aot_builtin.Command.tsv_stringify));
    try expectUtf16String(&runtime, roots[13], "5\t6|");
}

test "AOT TOML命令は表・配列・インライン表を処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try runtimeUtf8String(&state.active_runtime.?, "title=\"x\"\nn=1_000\na=[1,2]\no={x=1}\n[server]\nport=8080\n[[products]]\nname=\"a\"\n[[products]]\nname=\"b\"\n");
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.toml_parse));
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[1].tag)));
    try std.testing.expectEqual(@as(f64, 1000), @as(f64, @bitCast(dictionaryProperty(roots[1], &.{'n'}).payload)));
    const server = dictionaryProperty(roots[1], &.{ 's', 'e', 'r', 'v', 'e', 'r' });
    try std.testing.expectEqual(@as(f64, 8080), @as(f64, @bitCast(dictionaryProperty(server, &.{ 'p', 'o', 'r', 't' }).payload)));
    const products = dictionaryProperty(roots[1], &.{ 'p', 'r', 'o', 'd', 'u', 'c', 't', 's' });
    try std.testing.expectEqual(@as(usize, 2), products.object().?.payload.array.items.len);
    try expectUtf16String(&state.active_runtime.?, dictionaryProperty(products.object().?.payload.array.items[0], &.{ 'n', 'a', 'm', 'e' }), "a");
    try expectUtf16String(&state.active_runtime.?, dictionaryProperty(products.object().?.payload.array.items[1], &.{ 'n', 'a', 'm', 'e' }), "b");

    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[1]), 1, @intFromEnum(aot_builtin.Command.toml_stringify));
    const encoded_units = try valueUtf16Alloc(&state.active_runtime.?, roots[2]);
    defer state.active_runtime.?.allocator.free(encoded_units);
    const products_header = try std.unicode.utf8ToUtf16LeAlloc(state.active_runtime.?.allocator, "[[products]]");
    defer state.active_runtime.?.allocator.free(products_header);
    try std.testing.expect(std.mem.indexOf(u16, encoded_units, products_header) != null);

    roots[3] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("a"), numberValue(1) });
    lnako_aot_builtin_call(&roots[4], @ptrCast(&roots[3]), 1, @intFromEnum(aot_builtin.Command.toml_stringify));
    try expectUtf16String(&state.active_runtime.?, roots[4], "a = 1\n");
}

test "AOT TOML日時は専用値としてJSONとTOMLへ正規化する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try runtimeUtf8String(&state.active_runtime.?, "d=1979-05-27\nt=07:32\no=1979-05-27T07:32:00Z\nl=1979-05-27 07:32\n");
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.toml_parse));
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[1].tag)));
    const date = dictionaryProperty(roots[1], &.{'d'});
    try std.testing.expect(date.object().?.toml_temporal != null);
    try std.testing.expectEqual(toml_temporal.Kind.date, date.object().?.toml_temporal.?.kind);

    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[1]), 1, @intFromEnum(aot_builtin.Command.json_encode));
    try expectUtf16String(&state.active_runtime.?, roots[2], "{\"d\":\"1979-05-27\",\"t\":\"07:32:00.000\",\"o\":\"1979-05-27T07:32:00.000Z\",\"l\":\"1979-05-27T07:32:00.000\"}");

    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[1]), 1, @intFromEnum(aot_builtin.Command.toml_stringify));
    try expectUtf16String(&state.active_runtime.?, roots[3], "d = 1979-05-27\nt = 07:32:00.000\no = 1979-05-27T07:32:00.000Z\nl = 1979-05-27T07:32:00.000\n");
}

test "AOTマークアップ命令はMarkdownとHTMLを純Zigで変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "# Heading\n\nplain *em* **strong**\n");
    roots[1] = try markupBuiltin(&runtime, .markdown_to_html, roots[0]);
    try expectUtf16String(&runtime, roots[1], "<h1>Heading</h1>\n<p>plain <em>em</em> <strong>strong</strong></p>\n");

    roots[2] = try runtimeUtf8String(&runtime, "<div><p>A <strong>B</strong></p><p>C</p></div>");
    roots[3] = try markupBuiltin(&runtime, .html_pretty, roots[2]);
    try expectUtf16String(&runtime, roots[3], "<div>\n  <p>A <strong>B</strong>\n  </p>\n  <p>C</p>\n</div>");
}

test "AOT Node環境命令はコンパイル対象のOSとCPU名を返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try nodeEnvironmentBuiltin(&runtime, .node_os);
    try expectUtf16String(&runtime, roots[0], aotOsName());
    roots[1] = try nodeEnvironmentBuiltin(&runtime, .node_architecture);
    try expectUtf16String(&runtime, roots[1], aotArchitectureName());
}

test "AOT Node終了コードは有限値を符号なし8bitへ正規化する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try std.testing.expectEqual(@as(u8, 7), try nodeProcessExitCode(&runtime, numberValue(7)));
    try std.testing.expectEqual(@as(u8, 255), try nodeProcessExitCode(&runtime, numberValue(-1)));
    try std.testing.expectEqual(@as(u8, 0), try nodeProcessExitCode(&runtime, numberValue(std.math.nan(f64))));
}

test "AOT Node存在判定はファイルとフォルダの存在を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try nodeFileExistenceBuiltin(&runtime, .node_file_exists, &.{staticStringValue(".")});
    roots[1] = try nodeFileExistenceBuiltin(&runtime, .node_folder_exists, &.{staticStringValue(".")});
    roots[2] = try nodeFileExistenceBuiltin(&runtime, .node_file_exists, &.{staticStringValue("LNAKO_MISSING_PATH_7F4B")});
    try std.testing.expectEqual(Tag.boolean, @as(Tag, @enumFromInt(roots[0].tag)));
    try std.testing.expectEqual(Tag.boolean, @as(Tag, @enumFromInt(roots[1].tag)));
    try std.testing.expectEqual(Tag.boolean, @as(Tag, @enumFromInt(roots[2].tag)));
    try std.testing.expect(roots[0].payload != 0);
    try std.testing.expect(roots[1].payload != 0);
    try std.testing.expect(roots[2].payload == 0);
}

test "AOT Node基本ファイルI/OはテキストとBufferを読み書きする" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "日本語\nABC" });
    const temporary_path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(temporary_path);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "source.txt" });
    defer std.testing.allocator.free(source_path);
    const text_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "text-copy.txt" });
    defer std.testing.allocator.free(text_path);
    const binary_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "binary-copy.bin" });
    defer std.testing.allocator.free(binary_path);

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, source_path);
    roots[1] = try nodeFileReadBuiltin(&runtime, .node_file_open, &.{roots[0]});
    roots[2] = try nodeFileReadBuiltin(&runtime, .node_file_read, &.{roots[0]});
    roots[3] = try nodeFileReadBuiltin(&runtime, .node_file_binary_read, &.{roots[0]});
    try expectUtf16String(&runtime, roots[1], "日本語\nABC");
    try expectUtf16String(&runtime, roots[2], "日本語\nABC");
    try std.testing.expectEqual(Tag.byte_buffer, @as(Tag, @enumFromInt(roots[3].tag)));
    try std.testing.expectEqualStrings("日本語\nABC", roots[3].object().?.payload.byte_buffer.bytes);

    roots[4] = try runtimeUtf8String(&runtime, text_path);
    _ = try nodeFileSaveBuiltin(&runtime, &.{ roots[1], roots[4] });
    roots[5] = try nodeFileReadBuiltin(&runtime, .node_file_read, &.{roots[4]});
    try expectUtf16String(&runtime, roots[5], "日本語\nABC");

    roots[6] = try runtimeUtf8String(&runtime, binary_path);
    _ = try nodeFileSaveBuiltin(&runtime, &.{ roots[3], roots[6] });
    roots[7] = try nodeFileReadBuiltin(&runtime, .node_file_binary_read, &.{roots[6]});
    try std.testing.expectEqual(Tag.byte_buffer, @as(Tag, @enumFromInt(roots[7].tag)));
    try std.testing.expectEqualSlices(u8, "日本語\nABC", roots[7].object().?.payload.byte_buffer.bytes);
}

test "AOT Node文字コード命令は共有codecへ接続する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "日本語ABC");
    roots[1] = try nodeEncodingBuiltin(&runtime, .node_encoding_sjis_encode, &.{roots[0]});
    roots[2] = try nodeEncodingBuiltin(&runtime, .node_encoding_sjis_decode, &.{roots[1]});
    roots[3] = try nodeEncodingBuiltin(&runtime, .node_encoding_encode, &.{ roots[0], staticStringValue("euc-jp") });
    roots[4] = try nodeEncodingBuiltin(&runtime, .node_encoding_decode, &.{ roots[3], staticStringValue("euc-jp") });

    try std.testing.expectEqual(Tag.byte_buffer, @as(Tag, @enumFromInt(roots[1].tag)));
    try std.testing.expectEqualSlices(u8, &.{ 0x93, 0xfa, 0x96, 0x7b, 0x8c, 0xea, 'A', 'B', 'C' }, roots[1].object().?.payload.byte_buffer.bytes);
    try expectUtf16String(&runtime, roots[2], "日本語ABC");
    try std.testing.expectEqual(Tag.byte_buffer, @as(Tag, @enumFromInt(roots[3].tag)));
    try expectUtf16String(&runtime, roots[4], "日本語ABC");
    try std.testing.expectError(error.InvalidArgumentCount, nodeEncodingBuiltin(&runtime, .node_encoding_encode, &.{roots[0]}));
}

test "AOT Node同期ファイル操作は列挙・再帰コピー・移動・削除を処理する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "data/sub");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "data/a.txt", .data = "abc" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "data/sub/nested.txt", .data = "nested" });

    const root_path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const data_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "data" });
    defer std.testing.allocator.free(data_path);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ data_path, "a.txt" });
    defer std.testing.allocator.free(source_path);
    const copy_path = try std.fs.path.join(std.testing.allocator, &.{ data_path, "copy.txt" });
    defer std.testing.allocator.free(copy_path);
    const moved_path = try std.fs.path.join(std.testing.allocator, &.{ data_path, "moved.txt" });
    defer std.testing.allocator.free(moved_path);
    const tree_copy_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "tree-copy" });
    defer std.testing.allocator.free(tree_copy_path);
    const tree_move_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "tree-move" });
    defer std.testing.allocator.free(tree_move_path);
    const nested_copy_path = try std.fs.path.join(std.testing.allocator, &.{ tree_move_path, "sub", "nested.txt" });
    defer std.testing.allocator.free(nested_copy_path);
    const created_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "created", "deep" });
    defer std.testing.allocator.free(created_path);
    const pattern_path = try std.fs.path.join(std.testing.allocator, &.{ data_path, "*.txt" });
    defer std.testing.allocator.free(pattern_path);

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "上書禁止");
    roots[1] = try runtimeUtf8String(&runtime, pattern_path);
    roots[2] = try nodeFileOperationBuiltin(&runtime, .node_file_list, &.{roots[1]}, &roots[0]);
    roots[3] = try nodeFileOperationBuiltin(&runtime, .node_file_list_all, &.{roots[1]}, &roots[0]);
    try std.testing.expectEqual(@as(usize, 1), roots[2].object().?.payload.array.items.len);
    try expectUtf16String(&runtime, roots[2].object().?.payload.array.items[0], "a.txt");
    try std.testing.expectEqual(@as(usize, 2), roots[3].object().?.payload.array.items.len);
    for (roots[3].object().?.payload.array.items) |item| {
        const item_path = try valueUtf8LossyAlloc(&runtime, item);
        defer runtime.allocator.free(item_path);
        try std.testing.expect(std.mem.startsWith(u8, item_path, data_path));
    }

    roots[4] = try runtimeUtf8String(&runtime, source_path);
    roots[5] = try runtimeUtf8String(&runtime, copy_path);
    _ = try nodeFileOperationBuiltin(&runtime, .node_file_copy, &.{ roots[4], roots[5] }, &roots[0]);
    try std.testing.expectError(error.CopyDestinationExists, nodeFileOperationBuiltin(&runtime, .node_file_copy, &.{ roots[4], roots[5] }, &roots[0]));
    _ = try nodeFileOperationBuiltin(&runtime, .node_file_copy_overwrite, &.{ roots[4], roots[5] }, &roots[0]);

    roots[0] = try runtimeUtf8String(&runtime, "上書");
    roots[6] = try runtimeUtf8String(&runtime, moved_path);
    _ = try nodeFileOperationBuiltin(&runtime, .node_file_move, &.{ roots[5], roots[6] }, &roots[0]);
    try std.testing.expect((try nodeFileExistenceBuiltin(&runtime, .node_file_exists, &.{roots[6]})).payload != 0);
    _ = try nodeFileOperationBuiltin(&runtime, .node_file_copy, &.{ roots[4], roots[6] }, &roots[0]);
    roots[13] = try nodeFileReadBuiltin(&runtime, .node_file_read, &.{roots[6]});
    try expectUtf16String(&runtime, roots[13], "abc");

    roots[7] = try runtimeUtf8String(&runtime, data_path);
    roots[8] = try runtimeUtf8String(&runtime, tree_copy_path);
    roots[9] = try runtimeUtf8String(&runtime, tree_move_path);
    _ = try nodeFileOperationBuiltin(&runtime, .node_file_copy, &.{ roots[7], roots[8] }, &roots[0]);
    _ = try nodeFileOperationBuiltin(&runtime, .node_file_move_overwrite, &.{ roots[8], roots[9] }, &roots[0]);
    roots[10] = try runtimeUtf8String(&runtime, nested_copy_path);
    try std.testing.expect((try nodeFileExistenceBuiltin(&runtime, .node_file_exists, &.{roots[10]})).payload != 0);
    _ = try nodeFileOperationBuiltin(&runtime, .node_file_delete, &.{roots[9]}, &roots[0]);
    try std.testing.expect((try nodeFileExistenceBuiltin(&runtime, .node_file_exists, &.{roots[9]})).payload == 0);

    roots[11] = try runtimeUtf8String(&runtime, created_path);
    _ = try nodeFileOperationBuiltin(&runtime, .node_folder_create, &.{roots[11]}, &roots[0]);
    try std.testing.expect((try nodeFileExistenceBuiltin(&runtime, .node_folder_exists, &.{roots[11]})).payload != 0);
    _ = try nodeFileOperationBuiltin(&runtime, .node_file_delete, &.{roots[6]}, &roots[0]);
    try std.testing.expect((try nodeFileExistenceBuiltin(&runtime, .node_file_exists, &.{roots[6]})).payload == 0);
}

test "AOT Nodeファイルcallbackは完了・進捗・停止を処理する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "copy-source.txt", .data = "copy" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "move-source.txt", .data = "move" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "delete-target.txt", .data = "delete" });
    try temporary.dir.createDirPath(std.testing.io, "tree/sub");
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "tree/one.txt", .data = "1" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "tree/sub/two.txt", .data = "2" });

    const root_path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root_path);
    const copy_source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "copy-source.txt" });
    defer std.testing.allocator.free(copy_source_path);
    const copy_target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "copy-target.txt" });
    defer std.testing.allocator.free(copy_target_path);
    const move_source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "move-source.txt" });
    defer std.testing.allocator.free(move_source_path);
    const move_target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "move-target.txt" });
    defer std.testing.allocator.free(move_target_path);
    const delete_target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "delete-target.txt" });
    defer std.testing.allocator.free(delete_target_path);
    const tree_source_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "tree" });
    defer std.testing.allocator.free(tree_source_path);
    const tree_target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "tree-target" });
    defer std.testing.allocator.free(tree_target_path);
    const tree_target_one_path = try std.fs.path.join(std.testing.allocator, &.{ tree_target_path, "one.txt" });
    defer std.testing.allocator.free(tree_target_one_path);
    const tree_target_two_path = try std.fs.path.join(std.testing.allocator, &.{ tree_target_path, "sub", "two.txt" });
    defer std.testing.allocator.free(tree_target_two_path);
    const tree_source_two_path = try std.fs.path.join(std.testing.allocator, &.{ tree_source_path, "sub", "two.txt" });
    defer std.testing.allocator.free(tree_source_two_path);

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }

    var roots = [_]Value{.{}} ** 16;
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    const active = &state.active_runtime.?;

    roots[0] = try active.createBindingCell(numberValue(0));
    roots[1] = try active.createFunction(testAotCapturedIncrement, 0, &.{roots[0]});
    roots[2] = try runtimeUtf8String(active, copy_source_path);
    roots[3] = try runtimeUtf8String(active, copy_target_path);
    roots[4] = try runtimeUtf8String(active, move_source_path);
    roots[5] = try runtimeUtf8String(active, move_target_path);
    roots[6] = try runtimeUtf8String(active, delete_target_path);

    var callback_arguments = [_]Value{ roots[1], roots[2], roots[3] };
    lnako_aot_node_file_callback_call(
        &roots[15],
        &roots[14],
        &callback_arguments,
        callback_arguments.len,
        @intFromEnum(aot_builtin.Command.node_file_copy_callback),
        1,
    );
    try drainAotEvents(active);
    try std.testing.expect((try nodeFileExistenceBuiltin(active, .node_file_exists, &.{roots[3]})).payload != 0);

    callback_arguments = .{ roots[1], roots[4], roots[5] };
    lnako_aot_node_file_callback_call(
        &roots[15],
        &roots[14],
        &callback_arguments,
        callback_arguments.len,
        @intFromEnum(aot_builtin.Command.node_file_move_callback),
        2,
    );
    try drainAotEvents(active);
    try std.testing.expect((try nodeFileExistenceBuiltin(active, .node_file_exists, &.{roots[4]})).payload == 0);
    try std.testing.expect((try nodeFileExistenceBuiltin(active, .node_file_exists, &.{roots[5]})).payload != 0);

    var delete_callback_arguments = [_]Value{ roots[1], roots[6] };
    lnako_aot_node_file_callback_call(
        &roots[15],
        &roots[14],
        &delete_callback_arguments,
        delete_callback_arguments.len,
        @intFromEnum(aot_builtin.Command.node_file_delete_callback),
        3,
    );
    try drainAotEvents(active);
    try std.testing.expect((try nodeFileExistenceBuiltin(active, .node_file_exists, &.{roots[6]})).payload == 0);
    try std.testing.expectEqual(@as(f64, 3), valueToNumber(roots[0].object().?.payload.binding_cell));

    roots[7] = try active.createBindingCell(numberValue(0));
    roots[8] = try active.createFunction(testAotFileProgressStop, 1, &.{roots[7]});
    roots[9] = try runtimeUtf8String(active, tree_source_path);
    roots[10] = try runtimeUtf8String(active, tree_target_path);
    roots[11] = try runtimeUtf8String(active, tree_target_one_path);
    roots[12] = try runtimeUtf8String(active, tree_target_two_path);
    roots[13] = try runtimeUtf8String(active, tree_source_two_path);
    var progress_registration = [_]Value{roots[8]};
    lnako_aot_node_file_callback_call(
        &roots[15],
        &roots[14],
        &progress_registration,
        progress_registration.len,
        @intFromEnum(aot_builtin.Command.node_file_process_callback),
        4,
    );
    roots[15] = staticStringValue("上書禁止");
    _ = try nodeFileCopyMoveBuiltin(active, .node_file_copy, &.{ roots[9], roots[10] }, &roots[15]);

    try std.testing.expectEqual(@as(f64, 1), valueToNumber(roots[7].object().?.payload.binding_cell));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(dictionaryProperty(roots[14], &.{ '件', '数' })));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(dictionaryProperty(roots[14], &.{ '現', '在' })));
    try std.testing.expect((try nodeFileExistenceBuiltin(active, .node_file_exists, &.{roots[9]})).payload != 0);
    try std.testing.expect((try nodeFileExistenceBuiltin(active, .node_file_exists, &.{roots[13]})).payload != 0);
    try std.testing.expect((try nodeFileExistenceBuiltin(active, .node_file_exists, &.{roots[11]})).payload != 0);
    try std.testing.expect((try nodeFileExistenceBuiltin(active, .node_file_exists, &.{roots[12]})).payload == 0);
}

test "AOT Nodeファイルサイズ取得はstatのサイズを返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const expected = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), ".", .{});
    const result = try nodeFileSizeBuiltin(&runtime, &.{staticStringValue(".")});
    try std.testing.expectEqual(@as(f64, @floatFromInt(expected.size)), valueToNumber(result));
}

test "AOT Nodeファイル情報取得はstatフィールドとメソッドを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const expected = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), ".", .{});
    roots[0] = try nodeFileInfoBuiltin(&state.active_runtime.?, &.{staticStringValue(".")});
    roots[1] = dictionaryProperty(roots[0], &.{ 's', 'i', 'z', 'e' });
    try std.testing.expectEqual(@as(f64, @floatFromInt(expected.size)), valueToNumber(roots[1]));
    const method_names = [_][]const u8{ "isFile", "isDirectory", "isSymbolicLink" };
    for ([_][]const u16{
        &.{ 'i', 's', 'F', 'i', 'l', 'e' },
        &.{ 'i', 's', 'D', 'i', 'r', 'e', 'c', 't', 'o', 'r', 'y' },
        &.{ 'i', 's', 'S', 'y', 'm', 'b', 'o', 'l', 'i', 'c', 'L', 'i', 'n', 'k' },
    }, 2..) |key, index| {
        roots[index] = dictionaryProperty(roots[0], key);
        try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[index].tag)));
        try std.testing.expectEqual(@as(usize, 0), roots[index].object().?.payload.function.captures.len);
        try std.testing.expectEqualStrings(method_names[index - 2], roots[index].object().?.payload.function.name);
    }
    roots[5] = try invokeAotCallback(&state.active_runtime.?, roots[2], null, 0);
    try std.testing.expectEqual(Tag.boolean, @as(Tag, @enumFromInt(roots[5].tag)));
    try std.testing.expect(roots[5].payload == 0);
    roots[5] = try invokeAotCallback(&state.active_runtime.?, roots[3], null, 0);
    try std.testing.expect(roots[5].payload != 0);
    roots[5] = try invokeAotCallback(&state.active_runtime.?, roots[4], null, 0);
    try std.testing.expect(roots[5].payload == 0);
    try std.testing.expectEqual(@as(usize, 0), state.active_runtime.?.named_functions.items.len);
}

test "AOT Nodeネットワーク命令はOSアドレスを文字列配列へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try nodeNetworkAddressesBuiltin(&runtime, false);
    roots[1] = try nodeNetworkAddressesBuiltin(&runtime, true);
    for (roots) |value| {
        try std.testing.expectEqual(Tag.array, @as(Tag, @enumFromInt(value.tag)));
        for (value.object().?.payload.array.items) |address| {
            try std.testing.expectEqual(Tag.utf16_string, @as(Tag, @enumFromInt(address.tag)));
            const units = address.object().?.payload.utf16_string;
            try std.testing.expect(units.len > 0);
            try std.testing.expect(std.mem.indexOfScalar(u16, units, '%') == null);
        }
    }
}

test "AOT Node文字コード変換サポート判定はInterpreterと同じ別名を受理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const supported = [_]Value{
        staticStringValue("Shift_JIS"),
        staticStringValue("utf16"),
        staticStringValue("windows-1252:2000"),
        staticStringValue("gb18030"),
        staticStringValue("euc-kr"),
        staticStringValue("big5"),
        staticStringValue("cesu8"),
        staticStringValue("utf7-imap"),
    };
    for (supported) |value| {
        const result = try nodeEncodingSupportsBuiltin(&runtime, &.{value});
        try std.testing.expectEqual(Tag.boolean, @as(Tag, @enumFromInt(result.tag)));
        try std.testing.expect(result.payload != 0);
    }
    for ([_]Value{ staticStringValue("utf"), staticStringValue("ucs2le"), staticStringValue("x-lnako-unknown") }) |value| {
        const result = try nodeEncodingSupportsBuiltin(&runtime, &.{value});
        try std.testing.expectEqual(Tag.boolean, @as(Tag, @enumFromInt(result.tag)));
        try std.testing.expect(result.payload == 0);
    }
}

test "AOT Node標準入力全取得はUTF-8入力を文字列にする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const result = try nodeStdinValueBuiltin(&runtime, "A\n日本語\n");
    try expectUtf16String(&runtime, result, "A\n日本語\n");
}

test "AOT Node標準入力行命令は行分割と尋の数値変換を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.stdin_bytes = try runtime.allocator.dupe(u8, "abc\rX\r\n41\nrest\n");
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const empty_prompt = [_]Value{staticStringValue("")};
    roots[0] = try nodeStdinLineBuiltin(&runtime, .node_stdin_character, &empty_prompt);
    roots[1] = try nodeStdinLineBuiltin(&runtime, .node_stdin_line, &empty_prompt);
    roots[2] = try nodeStdinAllBuiltin(&runtime);
    try expectUtf16String(&runtime, roots[0], "abc\rX");
    try std.testing.expectEqual(@as(f64, 41), valueToNumber(roots[1]));
    try expectUtf16String(&runtime, roots[2], "abc\rX\r\n41\nrest\n");
    try std.testing.expectEqual(@as(usize, 10), runtime.stdin_offset);
}

test "AOT Node標準入力取得時は全行を対象へ設定してコールバックへ渡す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    state.active_runtime.?.stdin_bytes = try state.active_runtime.?.allocator.dupe(u8, "A\r\nB\n");
    var rooted = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &rooted, rooted.len);
    defer lnako_aot_pop_roots(&frame);
    rooted[0] = try state.active_runtime.?.createFunction(testAotFunction, 1, &.{});
    const callback_arguments = [_]Value{rooted[0]};
    const result = try nodeStdinCallbackBuiltin(&state.active_runtime.?, &rooted[1], &callback_arguments);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(result.tag)));
    try expectUtf16String(&state.active_runtime.?, rooted[1], "B");
    try std.testing.expectEqual(@as(usize, 5), state.active_runtime.?.stdin_offset);
}

test "AOT Node POSTデータ生成は辞書をURI component形式へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "{\"a\":\"x y\",\"日本\":\"語!\"}");
    roots[1] = try jsonDecodeBuiltin(&runtime, roots[0]);
    roots[2] = try nodePostDataBuiltin(&runtime, &.{roots[1]});
    try expectUtf16String(&runtime, roots[2], "a=x%20y&%E6%97%A5%E6%9C%AC=%E8%AA%9E!");

    roots[3] = try nodePostDataBuiltin(&runtime, &.{staticStringValue("not-a-dictionary")});
    try expectUtf16String(&runtime, roots[3], "");
}

test "AOT Nodeの環境依存ディレクトリ命令はOSの環境値を使う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const home_name = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = std.c.getenv(home_name) orelse return error.HomeDirectoryUnavailable;
    const home_path = std.mem.span(home);
    roots[0] = try nodeDirectoryBuiltin(&runtime, .node_home_directory);
    roots[1] = try nodeDirectoryBuiltin(&runtime, .node_desktop);
    roots[2] = try nodeDirectoryBuiltin(&runtime, .node_documents);
    roots[3] = try nodeDirectoryBuiltin(&runtime, .node_temporary_directory);
    try expectUtf16String(&runtime, roots[0], home_path);

    const desktop = try std.fs.path.join(runtime.allocator, &.{ home_path, "Desktop" });
    defer runtime.allocator.free(desktop);
    try expectUtf16String(&runtime, roots[1], desktop);
    const documents = try std.fs.path.join(runtime.allocator, &.{ home_path, "Documents" });
    defer runtime.allocator.free(documents);
    try expectUtf16String(&runtime, roots[2], documents);

    const fallback = if (builtin.os.tag == .windows) "." else "/tmp";
    const raw = if (builtin.os.tag == .windows)
        std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse fallback
    else
        std.c.getenv("TMPDIR") orelse fallback;
    const temporary = std.mem.span(raw);
    const trimmed = std.mem.trimEnd(u8, temporary, "/\\");
    try expectUtf16String(&runtime, roots[3], if (trimmed.len == 0) temporary else trimmed);
}

test "AOT Node母艦パスはソースパスのディレクトリを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const source_path = "fixtures/main.nako3";
    lnako_aot_node_mother_path_init(&roots[0], @ptrCast(source_path.ptr), source_path.len);
    const cwd = try currentDirectoryAlloc(&state.active_runtime.?);
    defer state.active_runtime.?.allocator.free(cwd);
    const absolute_source = try std.fs.path.resolve(state.active_runtime.?.allocator, &.{ cwd, source_path });
    defer state.active_runtime.?.allocator.free(absolute_source);
    const expected = nodeDirname(absolute_source);
    try expectUtf16String(&state.active_runtime.?, roots[0], expected);

    roots[1] = try nodeMotherPathBuiltin(&state.active_runtime.?);
    try expectUtf16String(&state.active_runtime.?, roots[1], expected);
}

test "AOT一時フォルダ作成は6文字suffixと衝突回避を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .random_state = default_random_seed };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 2;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const prefix = ".lnako-aot-temporary-";
    var arguments = [_]Value{staticStringValue(prefix)};
    roots[0] = try nodeCreateTemporaryDirectoryBuiltin(&runtime, &arguments);
    const first = try valueUtf8LossyAlloc(&runtime, roots[0]);
    defer runtime.allocator.free(first);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), first) catch {};
    try std.testing.expect(std.mem.startsWith(u8, first, prefix));
    try std.testing.expectEqual(prefix.len + 6, first.len);
    const first_stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), first, .{});
    try std.testing.expectEqual(.directory, first_stat.kind);

    roots[1] = try nodeCreateTemporaryDirectoryBuiltin(&runtime, &arguments);
    const second = try valueUtf8LossyAlloc(&runtime, roots[1]);
    defer runtime.allocator.free(second);
    defer std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.io(), second) catch {};
    try std.testing.expect(std.mem.startsWith(u8, second, prefix));
    try std.testing.expectEqual(prefix.len + 6, second.len);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    const second_stat = try std.Io.Dir.cwd().statFile(std.Io.Threaded.global_single_threaded.io(), second, .{});
    try std.testing.expectEqual(.directory, second_stat.kind);
}

test "AOT環境変数取得はC環境から値を読み未設定をundefinedにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const path = std.c.getenv("PATH") orelse return error.EnvironmentUnavailable;
    var arguments = [_]Value{try runtimeUtf8String(&runtime, "PATH")};
    roots[0] = try nodeEnvironmentValueBuiltin(&runtime, &arguments);
    try expectUtf16String(&runtime, roots[0], std.mem.span(path));

    arguments[0] = try runtimeUtf8String(&runtime, "LNAKO_ENVIRONMENT_VARIABLE_THAT_DOES_NOT_EXIST_7F4B");
    roots[1] = try nodeEnvironmentValueBuiltin(&runtime, &arguments);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[1].tag)));
}

test "AOT環境変数一覧取得はPATHを含む辞書を生成する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const path = std.c.getenv("PATH") orelse return error.EnvironmentUnavailable;
    roots[0] = try nodeEnvironmentListBuiltin(&runtime);
    var path_key: []const u8 = "PATH";
    var path_key_copy: ?[]u8 = null;
    defer if (path_key_copy) |copy| runtime.allocator.free(copy);
    if (comptime builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        var map = try std.process.Environ.createMap(environ, runtime.allocator);
        defer map.deinit();
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, "PATH")) {
                path_key_copy = try runtime.allocator.dupe(u8, entry.key_ptr.*);
                path_key = path_key_copy.?;
                break;
            }
        }
    }
    const path_key_units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, path_key);
    defer runtime.allocator.free(path_key_units);
    try expectUtf16String(&runtime, dictionaryProperty(roots[0], path_key_units), std.mem.span(path));
}

test "AOTカレントディレクトリ取得は現在の作業フォルダを返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const io = std.Io.Threaded.global_single_threaded.io();
    const expected = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", runtime.allocator);
    defer runtime.allocator.free(expected.ptr[0 .. expected.len + 1]);
    roots[0] = try nodeCurrentDirectoryBuiltin(&runtime);
    try expectUtf16String(&runtime, roots[0], expected);
    roots[1] = try nodeCurrentDirectoryBuiltin(&runtime);
    try expectUtf16String(&runtime, roots[1], expected);
}

test "AOT Nodeパス解決はpath.resolveとpath.joinの規則を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const cwd = try currentDirectoryAlloc(&runtime);
    defer runtime.allocator.free(cwd);

    roots[0] = try nodePathBuiltin(&runtime, .node_path_absolute, &.{staticStringValue("a/../b.txt")});
    const absolute_expected = try std.fs.path.resolve(runtime.allocator, &.{ cwd, "a/../b.txt" });
    defer runtime.allocator.free(absolute_expected);
    try expectUtf16String(&runtime, roots[0], absolute_expected);

    roots[1] = try nodePathBuiltin(&runtime, .node_path_resolve, &.{ staticStringValue("a"), staticStringValue("b/../c.txt") });
    const relative_expected = try std.fs.path.resolve(runtime.allocator, &.{ cwd, "a/b/../c.txt" });
    defer runtime.allocator.free(relative_expected);
    try expectUtf16String(&runtime, roots[1], relative_expected);
}

test "AOT Node互換のWindowsパスはdrive-relativeとUNC rootを保持する" {
    try std.testing.expectEqualStrings("foo", nodeBasenameFor("C:foo", true));
    try std.testing.expectEqualStrings("C:", nodeDirnameFor("C:foo", true));
    try std.testing.expectEqualStrings("bar", nodeBasenameFor("C:foo\\bar", true));
    try std.testing.expectEqualStrings("C:foo", nodeDirnameFor("C:foo\\bar", true));
    try std.testing.expectEqualStrings("", nodeBasenameFor("C:\\", true));
    try std.testing.expectEqualStrings("C:\\", nodeDirnameFor("C:\\", true));
    try std.testing.expectEqualStrings("file", nodeBasenameFor("\\\\server\\share\\file", true));
    try std.testing.expectEqualStrings("\\\\server\\share\\", nodeDirnameFor("\\\\server\\share\\file", true));
    try std.testing.expectEqualStrings("share", nodeBasenameFor("\\\\server\\share\\", true));
    try std.testing.expectEqualStrings("\\\\server\\share\\", nodeDirnameFor("\\\\server\\share\\", true));
    try std.testing.expectEqualStrings("bar", nodeBasenameFor("\\\\?\\C:\\foo\\bar", true));
    try std.testing.expectEqualStrings("\\\\?\\C:\\foo", nodeDirnameFor("\\\\?\\C:\\foo\\bar", true));
    try std.testing.expectEqualStrings("foo", nodeBasenameFor("\\\\?\\C:\\foo\\", true));
    try std.testing.expectEqualStrings("\\\\?\\C:\\", nodeDirnameFor("\\\\?\\C:\\foo\\", true));
    try std.testing.expectEqualStrings("share", nodeBasenameFor("\\\\?\\UNC\\server\\share\\", true));
    try std.testing.expectEqualStrings("\\\\?\\UNC\\server", nodeDirnameFor("\\\\?\\UNC\\server\\share\\", true));
    try std.testing.expectEqualStrings("name", nodeBasenameFor("\\\\.\\pipe\\name\\", true));
    try std.testing.expectEqualStrings("\\\\.\\pipe\\", nodeDirnameFor("\\\\.\\pipe\\name\\", true));
    try std.testing.expectEqualStrings("foo", nodeBasenameFor("\\\\.\\C:\\foo\\", true));
    try std.testing.expectEqualStrings("\\\\.\\C:\\", nodeDirnameFor("\\\\.\\C:\\foo\\", true));

    // Node's win32 implementation recognizes both separator bytes without
    // normalizing the prefix.  The root scan must not misclassify a mixed
    // separator run as a complete UNC root.
    try std.testing.expectEqualStrings("b", nodeBasenameFor("a/\\\\b", true));
    try std.testing.expectEqualStrings("a/\\", nodeDirnameFor("a/\\\\b", true));
    try std.testing.expectEqualStrings("b", nodeBasenameFor("a\\\\/b", true));
    try std.testing.expectEqualStrings("a\\\\", nodeDirnameFor("a\\\\/b", true));
    const mixed_unc = [_]u8{ '/', '\\', '\\', 'c', '?', '\\', 'Z', ':', '_', 'a', 'b', '?', '0', 'Y', '/', '\\' };
    const mixed_unc_dir = [_]u8{ '/', '\\', '\\', 'c', '?' };
    try std.testing.expectEqualStrings("Z:_ab?0Y", nodeBasenameFor(&mixed_unc, true));
    try std.testing.expectEqualSlices(u8, &mixed_unc_dir, nodeDirnameFor(&mixed_unc, true));
}

test "AOT Windows wide argv basenameはUTF-16 code unitを保持する" {
    const path = &.{ 'C', ':', '\\', 0xd83d, 0xde00, '\\', 0xd800 };
    try std.testing.expectEqualSlices(u16, &.{0xd800}, nodeBasenameWideFor(path, true));
    try std.testing.expectEqualSlices(u16, &.{}, nodeBasenameWideFor(&.{ 'C', ':', '\\' }, true));
    try std.testing.expectEqualSlices(u16, &.{ 'f', 'o', 'o' }, nodeBasenameWideFor(&.{ 'C', ':', 'f', 'o', 'o' }, true));
}

test "AOT Nodeパス命令は非文字列入力をNodeの型診断へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try expectAotNodePathArgumentFailure(&runtime, "path", .{ .tag = @intFromEnum(Tag.null_value) }, "The \"path\" argument must be of type string. Received null");
    try expectAotNodePathArgumentFailure(&runtime, "path", numberValue(123), "The \"path\" argument must be of type string. Received type number (123)");

    const dictionary = try runtime.createDictionary(&.{});
    const array = try runtime.createArray(&.{});
    var roots = [_]Value{ dictionary, array };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try expectAotNodePathArgumentFailure(&runtime, "path", roots[0], "The \"path\" argument must be of type string. Received an instance of Object");
    try expectAotNodePathArgumentFailure(&runtime, "path", roots[1], "The \"path\" argument must be of type string. Received an instance of Array");
}

test "AOTカレントディレクトリ変更は相対パスを受けてundefinedを返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}};
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    var arguments = [_]Value{try runtimeUtf8String(&runtime, ".")};
    roots[0] = try nodeChangeDirectoryBuiltin(&runtime, &arguments);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[0].tag)));
}

test "AOTカレントディレクトリ変更は失敗時にNodeのchdir診断を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const missing_path = "lnako-current-directory-missing-7f4b";
    roots[0] = try runtimeUtf8String(&runtime, missing_path);
    const cwd = try currentDirectoryAlloc(&runtime);
    defer runtime.allocator.free(cwd);
    const expected = try std.fmt.allocPrint(
        runtime.allocator,
        "ENOENT: no such file or directory, chdir '{s}' -> '{s}'",
        .{ cwd, missing_path },
    );
    defer runtime.allocator.free(expected);

    _ = nodeChangeDirectoryBuiltin(&runtime, roots[0..1]) catch |failure| {
        try std.testing.expectEqual(error.FileNotFound, failure);
        try std.testing.expect(runtime.has_pending_exception);
        try expectUtf16String(&runtime, runtime.pending_exception, expected);
        _ = runtime.takeException();
        return;
    };
    return error.ExpectedFailure;
}

test "AOT対応ブラウザ一覧取得はv3.7.24の辞書をキャッシュする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try caniuseBrowsersBuiltin(&runtime);
    roots[1] = try caniuseBrowsersBuiltin(&runtime);
    try std.testing.expectEqual(roots[0].payload, roots[1].payload);
    try std.testing.expectEqual(@as(usize, 16), roots[0].object().?.payload.dictionary.items.len);
    roots[2] = dictionaryProperty(roots[0], &.{ 'c', 'h', 'r', 'o', 'm', 'e' });
    try std.testing.expectEqual(Tag.array, @as(Tag, @enumFromInt(roots[2].tag)));
    try std.testing.expectEqual(@as(usize, 10), roots[2].object().?.payload.array.items.len);
    try expectUtf16String(&runtime, roots[2].object().?.payload.array.items[0], "145");
}

test "AOTブラウザ名変換表はv3.7.24の辞書をキャッシュする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try caniuseAgentsBuiltin(&runtime);
    roots[1] = try caniuseAgentsBuiltin(&runtime);
    try std.testing.expectEqual(roots[0].payload, roots[1].payload);
    try std.testing.expectEqual(@as(usize, 19), roots[0].object().?.payload.dictionary.items.len);
    roots[2] = dictionaryProperty(roots[0], &.{ 'c', 'h', 'r', 'o', 'm', 'e' });
    try expectUtf16String(&runtime, roots[2], "Chrome");
}

test "AOT元号データはv3.7.24の配列・辞書をキャッシュする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try eraDataBuiltin(&runtime);
    roots[1] = try eraDataBuiltin(&runtime);
    try std.testing.expectEqual(roots[0].payload, roots[1].payload);
    try std.testing.expectEqual(Tag.array, @as(Tag, @enumFromInt(roots[0].tag)));
    try std.testing.expectEqual(@as(usize, 5), roots[0].object().?.payload.array.items.len);
    roots[2] = roots[0].object().?.payload.array.items[0];
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[2].tag)));
    roots[3] = dictionaryProperty(roots[2], &.{ '元', '号' });
    roots[4] = dictionaryProperty(roots[2], &.{ '改', '元', '日' });
    try expectUtf16String(&runtime, roots[3], "令和");
    try expectUtf16String(&runtime, roots[4], "2019/05/01");
}

test "AOT整数実数変換はJavaScript接頭辞規則を共有する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ staticStringValue(" -0x10rest"), .{}, staticStringValue("12.5xyz"), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.to_int));
    try std.testing.expectEqual(@as(f64, -16), @as(f64, @bitCast(roots[1].payload)));
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.to_float));
    try std.testing.expectEqual(@as(f64, 12.5), @as(f64, @bitCast(roots[3].payload)));
}

test "AOTのNAN判定と非数判定はNumber変換の有無を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ staticStringValue("12x"), .{}, numberValue(std.math.nan(f64)), .{}, staticStringValue("NaN"), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.is_nan));
    try std.testing.expectEqual(@as(u64, 1), roots[1].payload);
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.is_number_nan));
    try std.testing.expectEqual(@as(u64, 1), roots[3].payload);
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[4]), 1, @intFromEnum(aot_builtin.Command.is_number_nan));
    try std.testing.expectEqual(@as(u64, 0), roots[5].payload);
}

test "AOT進数変換は小数基数を切り捨てて不正基数を例外にする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ staticStringValue("31px"), numberValue(16.9), .{}, numberValue(-10.9), .{}, numberValue(31), .{}, .{}, numberValue(31), numberValue(1), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, @intFromEnum(aot_builtin.Command.radix));
    try std.testing.expectEqualSlices(u16, &.{ '1', 'f' }, roots[2].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[4], @ptrCast(&roots[3]), 1, @intFromEnum(aot_builtin.Command.radix2));
    try std.testing.expectEqualSlices(u16, &.{ '-', '1', '0', '1', '0' }, roots[4].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[7], @ptrCast(&roots[5]), 2, @intFromEnum(aot_builtin.Command.radix));
    try std.testing.expectEqualSlices(u16, &.{ '3', '1' }, roots[7].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[10], @ptrCast(&roots[8]), 2, @intFromEnum(aot_builtin.Command.radix));
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    const message = try valueUtf16Alloc(&state.active_runtime.?, state.active_runtime.?.takeException());
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualSlices(u16, &.{ 't', 'o', 'S', 't', 'r', 'i', 'n', 'g', '(', ')', ' ', 'r', 'a', 'd', 'i', 'x', ' ', 'a', 'r', 'g', 'u', 'm', 'e', 'n', 't', ' ', 'm', 'u', 's', 't', ' ', 'b', 'e', ' ', 'b', 'e', 't', 'w', 'e', 'e', 'n', ' ', '2', ' ', 'a', 'n', 'd', ' ', '3', '6' }, message);
}

test "AOTのRGBは各16進表現の末尾2文字を連結する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ numberValue(-1), numberValue(std.math.nan(f64)), staticStringValue("Infinity"), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[0]), 3, @intFromEnum(aot_builtin.Command.rgb));
    try std.testing.expectEqualSlices(u16, &.{ '#', '-', '1', 'a', 'N', 'a', 'N' }, roots[3].object().?.payload.utf16_string);
}

test "AOTビット命令はNumberの32bit化とBigInt演算を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ staticStringValue("5"), numberValue(3), .{}, staticStringValue("3"), numberValue(2), .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, @intFromEnum(aot_builtin.Command.bit_and));
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[2].payload)));
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[3]), 2, @intFromEnum(aot_builtin.Command.shift_left));
    try std.testing.expectEqual(@as(f64, 12), @as(f64, @bitCast(roots[5].payload)));
    roots[6] = try state.active_runtime.?.createBigInt("0n");
    lnako_aot_builtin_call(&roots[7], @ptrCast(&roots[6]), 1, @intFromEnum(aot_builtin.Command.bit_not));
    const bigint_text = try roots[7].object().?.payload.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(bigint_text);
    try std.testing.expectEqualStrings("-1", bigint_text);
}

test "AOT算術比較命令は奇数の符号とNumber限定べき乗を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ numberValue(-3), .{}, numberValue(2), numberValue(8), .{}, numberValue(2), numberValue(1), numberValue(3), .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.is_odd));
    try std.testing.expectEqual(@as(u64, 0), roots[1].payload);
    lnako_aot_builtin_call(&roots[4], @ptrCast(&roots[2]), 2, @intFromEnum(aot_builtin.Command.power_number));
    try std.testing.expectEqual(@as(f64, 256), @as(f64, @bitCast(roots[4].payload)));
    lnako_aot_builtin_call(&roots[8], @ptrCast(&roots[5]), 3, @intFromEnum(aot_builtin.Command.in_range));
    try std.testing.expectEqual(@as(u64, 1), roots[8].payload);
    roots[9] = try state.active_runtime.?.createBigInt("2n");
    roots[10] = try state.active_runtime.?.createBigInt("3n");
    lnako_aot_builtin_call(&roots[8], @ptrCast(&roots[9]), 2, @intFromEnum(aot_builtin.Command.power_number));
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
}

test "AOT集約論理範囲命令は動的値と辞書を返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ numberValue(1), numberValue(9), numberValue(3), .{}, numberValue(0), staticStringValue("右"), .{}, numberValue(1), numberValue(3), .{}, .{}, .{}, numberValue(std.math.nan(f64)), numberValue(1), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[0]), 3, @intFromEnum(aot_builtin.Command.maximum));
    try std.testing.expectEqual(@as(f64, 9), @as(f64, @bitCast(roots[3].payload)));
    lnako_aot_builtin_call(&roots[6], @ptrCast(&roots[4]), 2, @intFromEnum(aot_builtin.Command.logical_or));
    try std.testing.expectEqualStrings("右", staticUtf8(roots[6]));
    lnako_aot_builtin_call(&roots[9], @ptrCast(&roots[7]), 2, @intFromEnum(aot_builtin.Command.range));
    roots[10] = try state.active_runtime.?.createString(&.{ 0x5148, 0x982d });
    roots[11] = try state.active_runtime.?.createString(&.{ 0x672b, 0x5c3e });
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(state.active_runtime.?.indexGet(roots[9], roots[10]).payload)));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(state.active_runtime.?.indexGet(roots[9], roots[11]).payload)));
    lnako_aot_builtin_call(&roots[14], @ptrCast(&roots[12]), 2, @intFromEnum(aot_builtin.Command.maximum));
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast(roots[14].payload))));
}

test "AOT空コレクション命令は独立値を返し真偽判定は日本語ラベルにする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, numberValue(0), .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[0], null, 0, @intFromEnum(aot_builtin.Command.empty_array));
    lnako_aot_builtin_call(&roots[1], null, 0, @intFromEnum(aot_builtin.Command.empty_array));
    try std.testing.expect(roots[0].payload != roots[1].payload);
    lnako_aot_builtin_call(&roots[2], null, 0, @intFromEnum(aot_builtin.Command.empty_dictionary));
    lnako_aot_builtin_call(&roots[3], null, 0, @intFromEnum(aot_builtin.Command.empty_dictionary));
    try std.testing.expect(roots[2].payload != roots[3].payload);
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[4]), 1, @intFromEnum(aot_builtin.Command.truth_label));
    try std.testing.expectEqualSlices(u16, &.{0x507d}, roots[5].object().?.payload.utf16_string);
    roots[6] = try state.active_runtime.?.createArray(&.{});
    lnako_aot_builtin_call(&roots[7], @ptrCast(&roots[6]), 1, @intFromEnum(aot_builtin.Command.truth_label));
    try std.testing.expectEqualSlices(u16, &.{0x771f}, roots[7].object().?.payload.utf16_string);
}

test "AOT掛命令は文字列配列反復と数値乗算を切り替える" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ staticStringValue("ab"), staticStringValue("2x"), .{}, .{}, numberValue(2), .{}, numberValue(3), numberValue(4), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, @intFromEnum(aot_builtin.Command.repeat_multiply));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'a', 'b' }, roots[2].object().?.payload.utf16_string);
    roots[3] = try state.active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[3]), 2, @intFromEnum(aot_builtin.Command.repeat_multiply));
    try std.testing.expectEqual(@as(usize, 4), roots[5].object().?.payload.array.items.len);
    lnako_aot_builtin_call(&roots[8], @ptrCast(&roots[6]), 2, @intFromEnum(aot_builtin.Command.repeat_multiply));
    try std.testing.expectEqual(@as(f64, 12), @as(f64, @bitCast(roots[8].payload)));
}

test "AOT文字長検索と要素数はUnicode scalarとUTF-16を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    roots[0] = try state.active_runtime.?.createString(&.{ 'A', 0xd83d, 0xde00, 'B' });
    roots[1] = try state.active_runtime.?.createString(&.{ 0xd83d, 0xde00, 'B' });
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.unicode_length));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(roots[2].payload)));
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[0]), 2, @intFromEnum(aot_builtin.Command.codepoint_find));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[3].payload)));
    lnako_aot_builtin_call(&roots[4], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.element_count));
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast(roots[4].payload)));
    roots[5] = staticStringValue("A");
    const starts_arguments = [_]Value{ roots[0], roots[5] };
    lnako_aot_builtin_call(&roots[6], &starts_arguments, starts_arguments.len, @intFromEnum(aot_builtin.Command.string_starts));
    try std.testing.expect(roots[6].payload != 0);
    roots[7] = staticStringValue("B");
    const ends_arguments = [_]Value{ roots[0], roots[7] };
    lnako_aot_builtin_call(&roots[8], &ends_arguments, ends_arguments.len, @intFromEnum(aot_builtin.Command.string_ends));
    try std.testing.expect(roots[8].payload != 0);
    roots[9] = try state.active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    lnako_aot_builtin_call(&roots[10], @ptrCast(&roots[9]), 1, @intFromEnum(aot_builtin.Command.element_count));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(roots[10].payload)));
}

test "AOT何文字目はArray.from要素境界と辞書ToLengthを再現する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    var roots = [_]Value{.{}} ** 24;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{staticStringValue("a")});
    roots[1] = try runtime.createArray(&.{ staticStringValue("a"), .{ .tag = @intFromEnum(Tag.null_value) } });
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[0], roots[1]));
    roots[2] = try runtime.createArray(&.{
        staticStringValue("a"),
        .{},
    });
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[0], roots[2]));

    roots[3] = try runtime.createArray(&.{ staticStringValue("a"), numberValue(12), numberValue(3) });
    try std.testing.expectEqual(@as(usize, 2), try codePointFindBuiltin(&runtime, roots[3], staticStringValue("123")));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[3], staticStringValue("12")));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, numberValue(123), numberValue(123)));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, staticStringValue("abc"), numberValue(123)));
    roots[17] = try runtime.createBigInt("1n");
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[17], roots[17]));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, staticStringValue("abc"), roots[17]));

    roots[4] = try runtime.createArray(&.{ staticStringValue("a"), staticStringValue("b") });
    roots[5] = try runtime.createArray(&.{ roots[4], staticStringValue("c") });
    roots[6] = try runtime.createArray(&.{roots[4]});
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[5], staticStringValue("a,b")));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[5], roots[6]));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[5], staticStringValue("b,c")));

    roots[7] = try runtime.createDictionary(&.{ staticStringValue("length"), staticStringValue("2"), staticStringValue("0"), staticStringValue("x"), staticStringValue("1"), staticStringValue("y") });
    try std.testing.expectEqual(@as(usize, 2), try codePointFindBuiltin(&runtime, roots[7], staticStringValue("y")));
    roots[8] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(1.9), staticStringValue("0"), staticStringValue("x"), staticStringValue("1"), staticStringValue("y") });
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[8], staticStringValue("x")));
    roots[9] = try runtime.createDictionary(&.{ staticStringValue("length"), .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 }, staticStringValue("0"), staticStringValue("x") });
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[9], staticStringValue("x")));
    roots[10] = try runtime.createArray(&.{numberValue(2)});
    roots[11] = try runtime.createDictionary(&.{ staticStringValue("length"), roots[10], staticStringValue("0"), staticStringValue("x"), staticStringValue("1"), staticStringValue("y") });
    try std.testing.expectEqual(@as(usize, 2), try codePointFindBuiltin(&runtime, roots[11], staticStringValue("y")));
    roots[12] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(-1), staticStringValue("0"), staticStringValue("x") });
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[12], staticStringValue("x")));
    roots[13] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(std.math.nan(f64)), staticStringValue("0"), staticStringValue("x") });
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[13], staticStringValue("x")));
    roots[14] = try runtime.createDictionary(&.{ staticStringValue("length"), .{ .tag = @intFromEnum(Tag.null_value) }, staticStringValue("0"), staticStringValue("x") });
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[14], staticStringValue("x")));

    roots[19] = try runtime.createDictionary(&.{
        staticStringValue("length"), numberValue(2),
        staticStringValue("0"),      staticStringValue("a"),
        staticStringValue("1"),      staticStringValue("b"),
    });
    roots[20] = try runtime.createDictionary(&.{});
    roots[20].object().?.prototype = roots[19];
    _ = runtime.collect();
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[20], staticStringValue("ab")));
    try expectUtf16String(&runtime, runtime.indexGet(roots[20], staticStringValue("0")), "a");
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(runtime.indexGet(roots[20], staticStringValue("length"))));

    roots[15] = try runtime.createFunction(testAotFunction, 1, &.{});
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, staticStringValue("abc"), roots[15]));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[15], staticStringValue("a")));

    const null_value: Value = .{ .tag = @intFromEnum(Tag.null_value) };
    try std.testing.expectError(error.NakoException, codePointFindBuiltin(&runtime, null_value, staticStringValue("a")));
    const null_message = try valueUtf16Alloc(&runtime, runtime.takeException());
    defer runtime.allocator.free(null_message);
    const expected_null = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "object null is not iterable (cannot read property Symbol(Symbol.iterator))");
    defer runtime.allocator.free(expected_null);
    try std.testing.expectEqualSlices(u16, expected_null, null_message);
    const undefined_value: Value = .{};
    try std.testing.expectError(error.NakoException, codePointFindBuiltin(&runtime, undefined_value, staticStringValue("a")));
    const undefined_message = try valueUtf16Alloc(&runtime, runtime.takeException());
    defer runtime.allocator.free(undefined_message);
    const expected_undefined = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "undefined is not iterable (cannot read property Symbol(Symbol.iterator))");
    defer runtime.allocator.free(expected_undefined);
    try std.testing.expectEqualSlices(u16, expected_undefined, undefined_message);
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, staticStringValue("abc"), staticStringValue("a")));

    roots[21] = try runtime.createArrayBuffer(&.{ 1, 2 });
    try runtime.indexSet(roots[21], staticStringValue("length"), numberValue(2));
    try runtime.indexSet(roots[21], staticStringValue("0"), staticStringValue("x"));
    try runtime.indexSet(roots[21], staticStringValue("1"), staticStringValue("y"));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(runtime.indexGet(roots[21], staticStringValue("length"))));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[21], staticStringValue("xy")));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[21], staticStringValue("x")));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[21], staticStringValue("xz")));

    roots[18] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(@floatFromInt(search_element_limit)), staticStringValue("0"), staticStringValue("hit") });
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[18], staticStringValue("hit")));
    roots[16] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(@floatFromInt(search_element_limit + 1)), staticStringValue("0"), staticStringValue("hit") });
    try std.testing.expectError(error.ArraySizeLimitExceeded, codePointFindBuiltin(&runtime, roots[16], staticStringValue("hit")));
}

test "AOT何文字目の要素列構築は割当失敗で入力を壊さない" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, codePointFindAllocationTest, .{});
}

test "AOT何文字目の文字列fast pathはスカラーwindowを比較する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 5;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try std.testing.expectEqual(@as(usize, 2), try codePointFindBuiltin(&runtime, staticStringValue("A😀B"), staticStringValue("😀B")));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, staticStringValue(""), staticStringValue("x")));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, staticStringValue("x"), staticStringValue("")));

    roots[0] = try runtime.createString(&.{ 0xd83d, 0xde00 });
    roots[1] = try runtime.createString(&.{0xd83d});
    roots[2] = try runtime.createString(&.{0xde00});
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[0], roots[0]));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[0], roots[1]));
    try std.testing.expectEqual(@as(usize, 0), try codePointFindBuiltin(&runtime, roots[0], roots[2]));
    try std.testing.expectEqual(@as(usize, 1), try codePointFindBuiltin(&runtime, roots[1], roots[1]));

    var long_units: [2048]u16 = undefined;
    @memset(long_units[0..2046], 'a');
    long_units[2046] = 0xd83d;
    long_units[2047] = 0xde00;
    roots[3] = try runtime.createString(&long_units);
    try std.testing.expectEqual(@as(usize, 2047), try codePointFindBuiltin(&runtime, roots[3], roots[0]));
}

test "AOT何文字目のdispatch例外は文言を保持し次の呼出しへ回復する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }

    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const command = @intFromEnum(aot_builtin.Command.codepoint_find);
    roots[0] = .{ .tag = @intFromEnum(Tag.null_value) };
    roots[1] = staticStringValue("a");
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, command);
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    lnako_aot_exception_take(&roots[3]);
    const null_message = try valueUtf16Alloc(&runtime, roots[3]);
    defer runtime.allocator.free(null_message);
    const expected_null = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "object null is not iterable (cannot read property Symbol(Symbol.iterator))");
    defer runtime.allocator.free(expected_null);
    try std.testing.expectEqualSlices(u16, expected_null, null_message);

    roots[0] = staticStringValue("abc");
    roots[1] = staticStringValue("a");
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, command);
    try std.testing.expectEqual(@as(c_int, 0), lnako_aot_exception_pending());
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[2].payload)));

    roots[0] = .{};
    roots[1] = staticStringValue("a");
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, command);
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    lnako_aot_exception_take(&roots[3]);
    const undefined_message = try valueUtf16Alloc(&runtime, roots[3]);
    defer runtime.allocator.free(undefined_message);
    const expected_undefined = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "undefined is not iterable (cannot read property Symbol(Symbol.iterator))");
    defer runtime.allocator.free(expected_undefined);
    try std.testing.expectEqualSlices(u16, expected_undefined, undefined_message);

    roots[0] = staticStringValue("abc");
    roots[1] = staticStringValue("a");
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, command);
    try std.testing.expectEqual(@as(c_int, 0), lnako_aot_exception_pending());
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(roots[2].payload)));
}

test "AOT加算系命令はparseFloatとBigIntとJavaScript加算を分離する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    roots[0] = staticStringValue("1.5rest");
    roots[1] = numberValue(2);
    lnako_aot_builtin_call(&roots[2], @ptrCast(&roots[0]), 2, @intFromEnum(aot_builtin.Command.add_parsed));
    try std.testing.expectEqual(@as(f64, 3.5), @as(f64, @bitCast(roots[2].payload)));
    roots[3] = staticStringValue("2");
    roots[4] = try state.active_runtime.?.createBigInt("3n");
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[3]), 2, @intFromEnum(aot_builtin.Command.add_parsed));
    const bigint_text = try roots[5].object().?.payload.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(bigint_text);
    try std.testing.expectEqualStrings("5", bigint_text);
    const sum_arguments = [_]Value{ numberValue(1), staticStringValue("2.5x"), numberValue(3) };
    lnako_aot_builtin_call(&roots[6], &sum_arguments, sum_arguments.len, @intFromEnum(aot_builtin.Command.sum_parsed));
    try std.testing.expectEqual(@as(f64, 6.5), @as(f64, @bitCast(roots[6].payload)));
    roots[7] = try state.active_runtime.?.createArray(&.{ numberValue(1), staticStringValue("x"), numberValue(2) });
    const array_sum_arguments = [_]Value{ roots[7], numberValue(100) };
    lnako_aot_builtin_call(&roots[8], &array_sum_arguments, array_sum_arguments.len, @intFromEnum(aot_builtin.Command.sum_parsed));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(roots[8].payload)));
    const sequential_arguments = [_]Value{ staticStringValue("a"), staticStringValue("b"), staticStringValue("c") };
    lnako_aot_builtin_call(&roots[9], &sequential_arguments, sequential_arguments.len, @intFromEnum(aot_builtin.Command.sequential_add));
    try std.testing.expectEqualSlices(u16, &.{ 'b', 'c', 'a' }, roots[9].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[10], null, 0, @intFromEnum(aot_builtin.Command.sequential_add));
    lnako_aot_builtin_call(&roots[11], null, 0, @intFromEnum(aot_builtin.Command.sequential_add));
    try std.testing.expectEqual(roots[10].payload, roots[11].payload);
}

test "AOT文字コード命令は補助平面と配列と動的例外文言を扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = numberValue(0x1f600);
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.chr));
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, roots[1].object().?.payload.utf16_string);

    roots[2] = try state.active_runtime.?.createArray(&.{ numberValue(65), numberValue(0x1f600), numberValue(66) });
    lnako_aot_builtin_call(&roots[3], @ptrCast(&roots[2]), 1, @intFromEnum(aot_builtin.Command.chr));
    const characters = roots[3].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 3), characters.len);
    try std.testing.expectEqualSlices(u16, &.{'A'}, characters[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, characters[1].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'B'}, characters[2].object().?.payload.utf16_string);

    roots[4] = staticStringValue("😀");
    lnako_aot_builtin_call(&roots[5], @ptrCast(&roots[4]), 1, @intFromEnum(aot_builtin.Command.asc));
    try std.testing.expectEqual(@as(f64, 0x1f600), @as(f64, @bitCast(roots[5].payload)));
    roots[6] = try state.active_runtime.?.createArray(&.{ staticStringValue("A"), staticStringValue("😀"), staticStringValue(""), .{ .tag = @intFromEnum(Tag.null_value) }, numberValue(12) });
    lnako_aot_builtin_call(&roots[7], @ptrCast(&roots[6]), 1, @intFromEnum(aot_builtin.Command.asc));
    const codes = roots[7].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 5), codes.len);
    try std.testing.expectEqualSlices(f64, &.{ 65, 0x1f600, 0, 110, 49 }, &.{ valueToNumber(codes[0]), valueToNumber(codes[1]), valueToNumber(codes[2]), valueToNumber(codes[3]), valueToNumber(codes[4]) });

    roots[8] = numberValue(-1);
    lnako_aot_builtin_call(&roots[9], @ptrCast(&roots[8]), 1, @intFromEnum(aot_builtin.Command.chr));
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    var taken: Value = .{};
    lnako_aot_exception_take(&taken);
    const message = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, taken.object().?.payload.utf16_string);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings("Invalid code point -1", message);
}

test "AOT文字列挿入検索はUnicode scalar位置と小数開始値を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const insert_arguments = [_]Value{ staticStringValue("A😀B"), numberValue(2), staticStringValue("X") };
    lnako_aot_builtin_call(&roots[0], &insert_arguments, insert_arguments.len, @intFromEnum(aot_builtin.Command.string_insert));
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'X', 0xd83d, 0xde00, 'B' }, roots[0].object().?.payload.utf16_string);
    const nan_position_arguments = [_]Value{ staticStringValue("ABC"), staticStringValue("2rest"), staticStringValue("X") };
    lnako_aot_builtin_call(&roots[1], &nan_position_arguments, nan_position_arguments.len, @intFromEnum(aot_builtin.Command.string_insert));
    try std.testing.expectEqualSlices(u16, &.{ 'X', 'A', 'B', 'C' }, roots[1].object().?.payload.utf16_string);

    const fractional_search = [_]Value{ staticStringValue("A😀B😀"), numberValue(2.9), staticStringValue("😀") };
    lnako_aot_builtin_call(&roots[2], &fractional_search, fractional_search.len, @intFromEnum(aot_builtin.Command.string_search));
    try std.testing.expectEqual(@as(f64, 2.9), valueToNumber(roots[2]));
    const nan_search = [_]Value{ staticStringValue("A😀B😀"), staticStringValue("2rest"), staticStringValue("😀") };
    lnako_aot_builtin_call(&roots[3], &nan_search, nan_search.len, @intFromEnum(aot_builtin.Command.string_search));
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(roots[3]));
}

test "AOT出現命令は文字列検索と配列のSameValueZeroを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    state.active_runtime = runtime;
    state.active_runtime.?.next_collection = 1;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
        runtime.deinit();
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const nan = numberValue(std.math.nan(f64));
    const minus_zero = numberValue(-0.0);
    const undefined_value: Value = .{};
    const null_value: Value = .{ .tag = @intFromEnum(Tag.null_value) };
    roots[0] = try state.active_runtime.?.createArray(&.{ nan, numberValue(0), undefined_value, null_value, staticStringValue("1") });
    const array_cases = [_]struct { needle: Value, expected: bool }{
        .{ .needle = numberValue(std.math.nan(f64)), .expected = true },
        .{ .needle = minus_zero, .expected = true },
        .{ .needle = undefined_value, .expected = true },
        .{ .needle = null_value, .expected = true },
        .{ .needle = numberValue(1), .expected = false },
        .{ .needle = staticStringValue("1"), .expected = true },
    };
    for (array_cases, 1..) |case, index| {
        const arguments = [_]Value{ roots[0], case.needle };
        lnako_aot_builtin_call(&roots[index], &arguments, arguments.len, @intFromEnum(aot_builtin.Command.occurrence));
        try std.testing.expectEqual(case.expected, roots[index].payload != 0);
    }

    roots[8] = try state.active_runtime.?.createArray(&.{numberValue(1)});
    roots[9] = try state.active_runtime.?.createArray(&.{roots[8]});
    const same_array_arguments = [_]Value{ roots[9], roots[8] };
    lnako_aot_builtin_call(&roots[7], &same_array_arguments, same_array_arguments.len, @intFromEnum(aot_builtin.Command.occurrence));
    try std.testing.expect(roots[7].payload != 0);

    const string_cases = [_]struct { source: Value, needle: Value, expected: bool }{
        .{ .source = staticStringValue("A😀B"), .needle = staticStringValue("😀"), .expected = true },
        .{ .source = staticStringValue("A😀B"), .needle = staticStringValue(""), .expected = true },
        .{ .source = staticStringValue("A\x00B"), .needle = staticStringValue("\x00"), .expected = true },
        .{ .source = .{ .tag = @intFromEnum(Tag.null_value) }, .needle = staticStringValue("null"), .expected = true },
        .{ .source = .{}, .needle = staticStringValue("undefined"), .expected = true },
    };
    for (string_cases) |case| {
        const arguments = [_]Value{ case.source, case.needle };
        lnako_aot_builtin_call(&roots[6], &arguments, arguments.len, @intFromEnum(aot_builtin.Command.occurrence));
        try std.testing.expectEqual(case.expected, roots[6].payload != 0);
    }
}

test "AOT配列結合と配列検索は公式のArray境界とGCを保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    state.active_runtime = runtime;
    state.active_runtime.?.next_collection = 1;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
        runtime.deinit();
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[1] = try state.active_runtime.?.createArray(&.{ numberValue(4), numberValue(5) });
    roots[2] = try state.active_runtime.?.createArray(&.{});
    try state.active_runtime.?.indexSet(roots[2], numberValue(0), roots[2]);
    roots[0] = try state.active_runtime.?.createArray(&.{
        numberValue(1),
        .{ .tag = @intFromEnum(Tag.null_value) },
        .{},
        numberValue(3),
        roots[1],
        roots[2],
    });
    const join_arguments = [_]Value{ roots[0], staticStringValue("|") };
    lnako_aot_builtin_call(&roots[3], &join_arguments, join_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ '1', '|', '|', '|', '3', '|', '4', ',', '5', '|' }, roots[3].object().?.payload.utf16_string);
    const only_join_arguments = [_]Value{roots[0]};
    lnako_aot_builtin_call(&roots[4], &only_join_arguments, only_join_arguments.len, @intFromEnum(aot_builtin.Command.array_join_only));
    try std.testing.expectEqualSlices(u16, &.{ '1', '3', '4', ',', '5' }, roots[4].object().?.payload.utf16_string);

    const non_array_arguments = [_]Value{ staticStringValue("A\n😀\n"), staticStringValue("-") };
    lnako_aot_builtin_call(&roots[5], &non_array_arguments, non_array_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ 'A', '-', 0xd83d, 0xde00, '-' }, roots[5].object().?.payload.utf16_string);
    roots[6] = try state.active_runtime.?.createString(&.{ 'A', 0xd800, 0, 'B' });
    const lone_surrogate_arguments = [_]Value{ roots[6], staticStringValue("-") };
    lnako_aot_builtin_call(&roots[7], &lone_surrogate_arguments, lone_surrogate_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, roots[6].object().?.payload.utf16_string, roots[7].object().?.payload.utf16_string);

    roots[8] = try state.active_runtime.?.createBigInt("12n");
    roots[9] = try state.active_runtime.?.createDictionary(&.{});
    roots[10] = try state.active_runtime.?.createArray(&.{ roots[8], roots[9], .{ .tag = @intFromEnum(Tag.null_value) }, .{} });
    const object_values_arguments = [_]Value{ roots[10], staticStringValue("|") };
    lnako_aot_builtin_call(&roots[11], &object_values_arguments, object_values_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ '1', '2', '|', '[', 'o', 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']', '|', '|' }, roots[11].object().?.payload.utf16_string);
    const bigint_separator_arguments = [_]Value{ roots[1], roots[8] };
    lnako_aot_builtin_call(&roots[12], &bigint_separator_arguments, bigint_separator_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ '4', '1', '2', '5' }, roots[12].object().?.payload.utf16_string);
    lnako_aot_function_new(&roots[18], testAotFunction, 1, null, 0);
    roots[19] = try state.active_runtime.?.createArray(&.{roots[18]});
    const function_value_arguments = [_]Value{ roots[19], staticStringValue("|") };
    lnako_aot_builtin_call(&roots[12], &function_value_arguments, function_value_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ 'f', 'u', 'n', 'c', 't', 'i', 'o', 'n', ' ', '(', ')', ' ', '{', ' ', '[', 'n', 'a', 't', 'i', 'v', 'e', ' ', 'c', 'o', 'd', 'e', ']', ' ', '}' }, roots[12].object().?.payload.utf16_string);

    const sparse = try state.active_runtime.?.createArray(&.{});
    roots[13] = sparse;
    try state.active_runtime.?.indexSet(sparse, numberValue(2), numberValue(3));
    const sparse_join_arguments = [_]Value{ roots[13], staticStringValue("|") };
    lnako_aot_builtin_call(&roots[14], &sparse_join_arguments, sparse_join_arguments.len, @intFromEnum(aot_builtin.Command.array_join));
    try std.testing.expectEqualSlices(u16, &.{ '|', '|', '3' }, roots[14].object().?.payload.utf16_string);

    const nan = numberValue(std.math.nan(f64));
    roots[15] = try state.active_runtime.?.createArray(&.{ nan, numberValue(0), staticStringValue("1"), numberValue(1), .{ .tag = @intFromEnum(Tag.null_value) }, .{}, roots[1] });
    roots[17] = try state.active_runtime.?.createArray(&.{ numberValue(4), numberValue(5) });
    const search_cases = [_]struct { needle: Value, expected: f64 }{
        .{ .needle = nan, .expected = -1 },
        .{ .needle = numberValue(-0.0), .expected = 1 },
        .{ .needle = staticStringValue("1"), .expected = 2 },
        .{ .needle = numberValue(1), .expected = 3 },
        .{ .needle = .{ .tag = @intFromEnum(Tag.null_value) }, .expected = 4 },
        .{ .needle = .{}, .expected = 5 },
        .{ .needle = roots[1], .expected = 6 },
        .{ .needle = roots[17], .expected = -1 },
    };
    var search_result: Value = .{};
    for (search_cases) |case| {
        const arguments = [_]Value{ roots[15], case.needle };
        lnako_aot_builtin_call(&search_result, &arguments, arguments.len, @intFromEnum(aot_builtin.Command.array_search));
        try std.testing.expectEqual(case.expected, valueToNumber(search_result));
    }
    const non_array_search = [_]Value{ staticStringValue("abc"), staticStringValue("a") };
    lnako_aot_builtin_call(&roots[16], &non_array_search, non_array_search.len, @intFromEnum(aot_builtin.Command.array_search));
    try std.testing.expectEqual(@as(f64, -1), valueToNumber(roots[16]));
}

test "AOT配列変更命令はspliceの数値化と辞書のtruthy規則を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    state.active_runtime = runtime;
    state.active_runtime.?.next_collection = 1;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
        runtime.deinit();
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try state.active_runtime.?.createArray(&.{ numberValue(1), numberValue(2), numberValue(3) });
    const insert_arguments = [_]Value{ roots[0], numberValue(-1.5), numberValue(9) };
    lnako_aot_builtin_call(&roots[1], &insert_arguments, insert_arguments.len, @intFromEnum(aot_builtin.Command.array_insert));
    try std.testing.expectEqual(@as(usize, 0), roots[1].object().?.payload.array.items.len);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2), numberValue(9), numberValue(3) }, roots[0].object().?.payload.array.items);

    roots[2] = try state.active_runtime.?.createArray(&.{ numberValue(1), numberValue(4) });
    roots[3] = try state.active_runtime.?.createArray(&.{ numberValue(2), numberValue(3) });
    const many_arguments = [_]Value{ roots[2], numberValue(1), roots[3] };
    lnako_aot_builtin_call(&roots[4], &many_arguments, many_arguments.len, @intFromEnum(aot_builtin.Command.array_insert_many));
    try std.testing.expectEqual(roots[2].payload, roots[4].payload);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2), numberValue(3), numberValue(4) }, roots[2].object().?.payload.array.items);

    // The upstream loop would never terminate when a and b are the same
    // array.  The native runtime copies b before mutating a.
    roots[5] = try state.active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    const self_arguments = [_]Value{ roots[5], numberValue(1), roots[5] };
    lnako_aot_builtin_call(&roots[6], &self_arguments, self_arguments.len, @intFromEnum(aot_builtin.Command.array_insert_many));
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(1), numberValue(2), numberValue(2) }, roots[5].object().?.payload.array.items);

    roots[7] = try state.active_runtime.?.createArray(&.{ numberValue(0), numberValue(1), numberValue(2), numberValue(3) });
    const take_arguments = [_]Value{ roots[7], staticStringValue("1.9"), staticStringValue("2.9") };
    lnako_aot_builtin_call(&roots[8], &take_arguments, take_arguments.len, @intFromEnum(aot_builtin.Command.array_take));
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2) }, roots[8].object().?.payload.array.items);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(0), numberValue(3) }, roots[7].object().?.payload.array.items);

    roots[9] = try state.active_runtime.?.createArray(&.{ numberValue(0), numberValue(1), numberValue(2), numberValue(3) });
    roots[10] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(1), staticStringValue("末尾"), numberValue(2) });
    const range_arguments = [_]Value{ roots[9], roots[10] };
    lnako_aot_builtin_call(&roots[11], &range_arguments, range_arguments.len, @intFromEnum(aot_builtin.Command.array_cut));
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2) }, roots[11].object().?.payload.array.items);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(0), numberValue(3) }, roots[9].object().?.payload.array.items);

    roots[12] = try state.active_runtime.?.createDictionary(&.{
        staticStringValue("zero"),  numberValue(0),
        staticStringValue("yes"),   numberValue(7),
        staticStringValue("false"), .{ .tag = @intFromEnum(Tag.boolean), .payload = 0 },
    });
    const zero_key = [_]Value{ roots[12], staticStringValue("zero") };
    lnako_aot_builtin_call(&roots[13], &zero_key, zero_key.len, @intFromEnum(aot_builtin.Command.array_cut));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[13].tag)));
    try std.testing.expectEqual(@as(usize, 3), roots[12].object().?.payload.dictionary.items.len);
    const yes_key = [_]Value{ roots[12], staticStringValue("yes") };
    lnako_aot_builtin_call(&roots[14], &yes_key, yes_key.len, @intFromEnum(aot_builtin.Command.array_cut));
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[14]));
    try std.testing.expectEqual(@as(usize, 2), roots[12].object().?.payload.dictionary.items.len);

    roots[15] = try state.active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    const pop_arguments = [_]Value{roots[15]};
    lnako_aot_builtin_call(&roots[16], &pop_arguments, pop_arguments.len, @intFromEnum(aot_builtin.Command.array_pop));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(roots[16]));
    const push_arguments = [_]Value{ roots[15], numberValue(3) };
    lnako_aot_builtin_call(&roots[17], &push_arguments, push_arguments.len, @intFromEnum(aot_builtin.Command.array_push));
    try std.testing.expectEqual(roots[15].payload, roots[17].payload);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(3) }, roots[15].object().?.payload.array.items);
    lnako_aot_builtin_call(&roots[18], &push_arguments, push_arguments.len, @intFromEnum(aot_builtin.Command.array_push));
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(3), numberValue(3) }, roots[15].object().?.payload.array.items);

    roots[19] = try state.active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    roots[20] = try state.active_runtime.?.createBigInt("1n");
    const bigint_insert = [_]Value{ roots[19], roots[20], numberValue(9) };
    lnako_aot_builtin_call(&roots[21], &bigint_insert, bigint_insert.len, @intFromEnum(aot_builtin.Command.array_insert));
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2) }, roots[19].object().?.payload.array.items);
    lnako_aot_exception_take(&roots[22]);
    const bigint_take = [_]Value{ roots[19], numberValue(0), roots[20] };
    lnako_aot_builtin_call(&roots[21], &bigint_take, bigint_take.len, @intFromEnum(aot_builtin.Command.array_take));
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2) }, roots[19].object().?.payload.array.items);
    lnako_aot_exception_take(&roots[22]);

    const null_index: Value = .{ .tag = @intFromEnum(Tag.null_value) };
    const null_cut = [_]Value{ roots[19], null_index };
    lnako_aot_builtin_call(&roots[21], &null_cut, null_cut.len, @intFromEnum(aot_builtin.Command.array_cut));
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2) }, roots[19].object().?.payload.array.items);
    lnako_aot_exception_take(&roots[22]);

    roots[23] = try state.active_runtime.?.createArray(&.{});
    const empty_pop = [_]Value{roots[23]};
    lnako_aot_builtin_call(&roots[24], &empty_pop, empty_pop.len, @intFromEnum(aot_builtin.Command.array_pop));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[24].tag)));
}

test "AOT配列複製範囲参照と配列足は深さと参照を公式どおり分ける" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{.{}} ** 36;
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try state.active_runtime.?.createArray(&.{ numberValue(1), try state.active_runtime.?.createArray(&.{numberValue(2)}) });
    roots[1] = try deepCloneBuiltin(&state.active_runtime.?, roots[0]);
    try state.active_runtime.?.indexSet(roots[1], numberValue(1), try state.active_runtime.?.createArray(&.{numberValue(9)}));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(roots[0].object().?.payload.array.items[1].object().?.payload.array.items[0]));
    try std.testing.expectEqual(@as(f64, 9), valueToNumber(roots[1].object().?.payload.array.items[1].object().?.payload.array.items[0]));
    try std.testing.expectError(error.CannotSerializeBigInt, deepCloneBuiltin(&state.active_runtime.?, try state.active_runtime.?.createBigInt("1n")));

    roots[2] = try state.active_runtime.?.createArray(&.{ numberValue(0), roots[0], numberValue(3) });
    roots[3] = try arrayRangeCopyBuiltin(&state.active_runtime.?, roots[2], try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(1), staticStringValue("末尾"), numberValue(1) }));
    try std.testing.expect(roots[3].object().?.payload.array.items[0].payload != roots[2].object().?.payload.array.items[1].payload);
    roots[4] = try referenceBuiltin(&state.active_runtime.?, roots[2], numberValue(1));
    try std.testing.expectEqual(roots[2].object().?.payload.array.items[1].payload, roots[4].payload);
    roots[5] = try referenceBuiltin(&state.active_runtime.?, staticStringValue("A😀B"), numberValue(1));
    try std.testing.expectEqualSlices(u16, &.{0xd83d}, roots[5].object().?.payload.utf16_string);
    roots[6] = try referenceBuiltin(&state.active_runtime.?, roots[2], try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(1), staticStringValue("末尾"), numberValue(2) }));
    try std.testing.expectEqual(@as(usize, 2), roots[6].object().?.payload.array.items.len);
    try std.testing.expectEqual(roots[2].object().?.payload.array.items[1].payload, roots[6].object().?.payload.array.items[0].payload);
    roots[7] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("x"), numberValue(7) });
    roots[8] = try referenceBuiltin(&state.active_runtime.?, roots[7], staticStringValue("x"));
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[8]));
    roots[9] = try arrayAddBuiltin(&state.active_runtime.?, roots[0], try state.active_runtime.?.createArray(&.{ numberValue(3), numberValue(4) }));
    try std.testing.expectEqual(@as(usize, 4), roots[9].object().?.payload.array.items.len);
    try std.testing.expect(roots[9].payload != roots[0].payload);

    try std.testing.expectError(error.InvalidJsonCloneValue, deepCloneBuiltin(&state.active_runtime.?, .{}));
    roots[10] = try state.active_runtime.?.createArray(&.{.{}});
    roots[11] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), numberValue(0) });
    roots[12] = try arrayRangeCopyBuiltin(&state.active_runtime.?, roots[10], roots[11]);
    try std.testing.expectEqual(Tag.null_value, @as(Tag, @enumFromInt(roots[12].object().?.payload.array.items[0].tag)));
    roots[13] = try referenceBuiltin(&state.active_runtime.?, staticStringValue("ABC"), numberValue(1.9));
    try std.testing.expectEqualSlices(u16, &.{'B'}, roots[13].object().?.payload.utf16_string);
    roots[14] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(1e100), staticStringValue("末尾"), numberValue(1e100) });
    roots[15] = try referenceBuiltin(&state.active_runtime.?, staticStringValue("ABC"), roots[14]);
    try std.testing.expectEqual(@as(usize, 0), roots[15].object().?.payload.utf16_string.len);

    roots[16] = try state.active_runtime.?.createArray(&.{ numberValue(0), numberValue(1), numberValue(2), numberValue(3) });
    roots[17] = try state.active_runtime.?.createBigInt("0n");
    roots[18] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[17] });
    roots[19] = try arrayRangeCopyBuiltin(&state.active_runtime.?, roots[16], roots[18]);
    try std.testing.expectEqual(@as(usize, 1), roots[19].object().?.payload.array.items.len);
    roots[20] = try state.active_runtime.?.createBigInt("1n");
    roots[21] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[20] });
    roots[22] = try arrayRangeCopyBuiltin(&state.active_runtime.?, roots[16], roots[21]);
    try std.testing.expectEqual(@as(usize, 2), roots[22].object().?.payload.array.items.len);
    roots[23] = try state.active_runtime.?.createBigInt("-2n");
    roots[24] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[23] });
    roots[25] = try arrayRangeCopyBuiltin(&state.active_runtime.?, roots[16], roots[24]);
    try std.testing.expectEqual(@as(usize, 3), roots[25].object().?.payload.array.items.len);
    roots[26] = try state.active_runtime.?.createBigInt("9007199254740993n");
    roots[27] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[26] });
    roots[28] = try arrayRangeCopyBuiltin(&state.active_runtime.?, roots[16], roots[27]);
    try std.testing.expectEqual(@as(usize, 4), roots[28].object().?.payload.array.items.len);
    roots[29] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), roots[20], staticStringValue("末尾"), numberValue(2) });
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try arrayRangeCopyBuiltin(&state.active_runtime.?, roots[16], roots[29])).tag)));
    roots[30] = try state.active_runtime.?.createBigInt("-9007199254740993n");
    roots[31] = try state.active_runtime.?.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), roots[30] });
    roots[32] = try arrayRangeCopyBuiltin(&state.active_runtime.?, roots[16], roots[31]);
    try std.testing.expectEqual(@as(usize, 0), roots[32].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(try referenceBuiltin(&state.active_runtime.?, roots[16], roots[17])));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(try referenceBuiltin(&state.active_runtime.?, roots[16], roots[20])));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try referenceBuiltin(&state.active_runtime.?, roots[16], roots[23])).tag)));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try referenceBuiltin(&state.active_runtime.?, roots[16], roots[26])).tag)));
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(try referenceBuiltin(&state.active_runtime.?, roots[16], staticStringValue("0"))));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(try referenceBuiltin(&state.active_runtime.?, roots[16], staticStringValue("1"))));
    try std.testing.expectEqual(@as(f64, 4), valueToNumber(try referenceBuiltin(&state.active_runtime.?, roots[16], staticStringValue("length"))));
    const invalid_keys = [_]Value{
        staticStringValue("01"),
        staticStringValue("-0"),
        staticStringValue("-1"),
        staticStringValue("1.0"),
        staticStringValue(""),
        staticStringValue("4294967295"),
        staticStringValue("900719925474099999999999999"),
    };
    for (invalid_keys) |key| {
        try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try referenceBuiltin(&state.active_runtime.?, roots[16], key)).tag)));
    }
    try std.testing.expectEqual(@as(?usize, 0), tablePropertyIndex(&.{'0'}));
    try std.testing.expectEqual(@as(?usize, 4294967294), tablePropertyIndex(&.{ '4', '2', '9', '4', '9', '6', '7', '2', '9', '4' }));
    try std.testing.expectEqual(@as(?usize, null), tablePropertyIndex(&.{ '4', '2', '9', '4', '9', '6', '7', '2', '9', '5' }));
}

test "AOT参照の配列文字列添字はGC後も配列とキーを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 3;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    runtime.next_collection = 1;
    roots[0] = try runtime.createArray(&.{ numberValue(10), numberValue(20) });
    roots[1] = try runtime.createString(&.{ 'l', 'e', 'n', 'g', 't', 'h' });
    roots[2] = try runtime.createString(&.{'1'});
    var i: usize = 0;
    while (i < 8) : (i += 1) _ = runtime.collect();
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(try referenceBuiltin(&runtime, roots[0], roots[1])));
    try std.testing.expectEqual(@as(f64, 20), valueToNumber(try referenceBuiltin(&runtime, roots[0], roots[2])));
}

test "AOT参照は辞書と配列の標準prototype propertyを解決する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 20;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    runtime.next_collection = 1;

    roots[0] = try runtime.createDictionary(&.{});
    roots[1] = try runtime.createArray(&.{numberValue(1)});
    roots[2] = try referenceBuiltin(&runtime, roots[0], staticStringValue("toString"));
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[2].tag)));
    roots[3] = try referenceBuiltin(&runtime, roots[0], staticStringValue("constructor"));
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[3].tag)));
    roots[4] = try tableRowProperty(&runtime, roots[3], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[4], "Object");
    roots[5] = try referenceBuiltin(&runtime, roots[0], staticStringValue("__proto__"));
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[5].tag)));
    roots[6] = try referenceBuiltin(&runtime, roots[1], staticStringValue("map"));
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[6].tag)));
    roots[7] = try referenceBuiltin(&runtime, roots[1], staticStringValue("toString"));
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[7].tag)));
    roots[8] = try runtime.createDictionary(&.{ staticStringValue("toString"), numberValue(7) });
    roots[9] = try referenceBuiltin(&runtime, roots[8], staticStringValue("toString"));
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[9]));

    roots[10] = try referenceBuiltin(&runtime, roots[0], staticStringValue("toString"));
    try std.testing.expectEqual(roots[2].payload, roots[10].payload);
    roots[11] = try referenceBuiltin(&runtime, roots[0], staticStringValue("hasOwnProperty"));
    roots[12] = try referenceBuiltin(&runtime, roots[1], staticStringValue("hasOwnProperty"));
    try std.testing.expectEqual(roots[11].payload, roots[12].payload);
    roots[13] = try referenceBuiltin(&runtime, roots[1], staticStringValue("toString"));
    try std.testing.expect(roots[2].payload != roots[13].payload);
    roots[14] = try referenceBuiltin(&runtime, roots[0], staticStringValue("constructor"));
    roots[15] = try referenceBuiltin(&runtime, roots[1], staticStringValue("constructor"));
    try std.testing.expectEqual(roots[3].payload, roots[14].payload);
    try std.testing.expect(roots[3].payload != roots[15].payload);
    roots[16] = try referenceBuiltin(&runtime, roots[0], staticStringValue("__proto__"));
    roots[17] = try referenceBuiltin(&runtime, roots[1], staticStringValue("__proto__"));
    try std.testing.expectEqual(roots[5].payload, roots[16].payload);
    try std.testing.expect(roots[5].payload != roots[17].payload);
    roots[18] = try referenceBuiltin(&runtime, roots[1], staticStringValue("map"));
    try std.testing.expectEqual(roots[6].payload, roots[18].payload);
    roots[19] = try referenceBuiltin(&runtime, roots[1], staticStringValue("map"));
    try std.testing.expectEqual(roots[18].payload, roots[19].payload);
}

test "AOT配列切取は辞書のownと継承propertyを分ける" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 10;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    runtime.next_collection = 1;

    roots[0] = try runtime.createDictionary(&.{
        staticStringValue("x"),    numberValue(1),
        staticStringValue("zero"), numberValue(0),
    });
    roots[1] = try runtime.createDictionary(&.{});
    roots[1].object().?.prototype = roots[0];
    try runtime.setDictionary(&roots[1].object().?.payload.dictionary, staticStringValue("own"), numberValue(2));

    roots[2] = try arrayCutBuiltin(&runtime, roots[1], staticStringValue("x"));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(roots[2]));
    roots[3] = try referenceBuiltin(&runtime, roots[1], staticStringValue("x"));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(roots[3]));

    roots[4] = try arrayCutBuiltin(&runtime, roots[1], staticStringValue("zero"));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[4].tag)));
    roots[5] = try referenceBuiltin(&runtime, roots[1], staticStringValue("zero"));
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(roots[5]));

    roots[6] = try arrayCutBuiltin(&runtime, roots[1], staticStringValue("__proto__"));
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[6].tag)));
    try std.testing.expectEqual(roots[0].payload, roots[6].payload);
    roots[7] = try arrayCutBuiltin(&runtime, roots[1], staticStringValue("toString"));
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[7].tag)));
    roots[8] = try referenceBuiltin(&runtime, roots[1], staticStringValue("toString"));
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[8].tag)));

    roots[9] = try arrayCutBuiltin(&runtime, roots[1], staticStringValue("own"));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(roots[9]));
    const own_after = try referenceBuiltin(&runtime, roots[1], staticStringValue("own"));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(own_after.tag)));
}

test "AOT参照はbyte bufferの添字とpropertyを解決する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 10;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    runtime.next_collection = 1;

    roots[0] = try runtime.createBytes(&.{ 85, 154 });
    roots[1] = try referenceBuiltin(&runtime, roots[0], numberValue(0));
    try std.testing.expectEqual(@as(f64, 85), valueToNumber(roots[1]));
    roots[2] = try referenceBuiltin(&runtime, roots[0], staticStringValue("1"));
    try std.testing.expectEqual(@as(f64, 154), valueToNumber(roots[2]));
    roots[3] = try referenceBuiltin(&runtime, roots[0], staticStringValue("length"));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(roots[3]));
    roots[4] = try referenceBuiltin(&runtime, roots[0], staticStringValue("buffer"));
    try std.testing.expectEqual(ByteKind.array_buffer, roots[4].object().?.payload.byte_buffer.kind);
    roots[5] = try referenceBuiltin(&runtime, roots[4], staticStringValue("byteLength"));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(roots[5]));
    roots[6] = try referenceBuiltin(&runtime, roots[4], numberValue(0));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[6].tag)));
    roots[7] = try referenceBuiltin(&runtime, roots[4], staticStringValue("buffer"));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[7].tag)));
    roots[8] = try runtime.createUint8Array(&.{ 7, 8 });
    roots[9] = try referenceBuiltin(&runtime, roots[8], numberValue(0));
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[9]));
}

test "AOT参照の配列文字列添字は割当失敗でも入力を保持する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, referenceAotArrayStringKeyAllocationTest, .{});
}

test "AOT BigInt範囲終端は割当失敗とGCストレスでも入力を保持する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, aotBigintRangeAllocationTest, .{});
}

test "AOT参照の文字列範囲エラーはJSON値・UTF-16・保留例外を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{.{}} ** 12;
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    try expectAotReferenceStringRangeMessage(&state.active_runtime.?, .{}, "『参照』で文字列型の範囲指定(undefined)が不正です。");
    roots[0] = try state.active_runtime.?.createString(&.{ 'A', 'B', 'C' });
    try expectAotReferenceStringRangeMessage(&state.active_runtime.?, roots[0], "『参照』で文字列型の範囲指定(\"ABC\")が不正です。");
    roots[1] = try state.active_runtime.?.createArray(&.{ numberValue(1), numberValue(2) });
    try expectAotReferenceStringRangeMessage(&state.active_runtime.?, roots[1], "『参照』で文字列型の範囲指定([1,2])が不正です。");
    roots[2] = try state.active_runtime.?.createDictionary(&.{});
    try expectAotReferenceStringRangeMessage(&state.active_runtime.?, roots[2], "『参照』で文字列型の範囲指定({})が不正です。");
    roots[3] = try state.active_runtime.?.createString(&.{0xd800});
    try expectAotReferenceStringRangeMessage(&state.active_runtime.?, roots[3], "『参照』で文字列型の範囲指定(\"\\ud800\")が不正です。");
    roots[4] = try state.active_runtime.?.createFunction(testAotFunction, 1, &.{});
    try expectAotReferenceStringRangeMessage(&state.active_runtime.?, roots[4], "『参照』で文字列型の範囲指定(undefined)が不正です。");

    roots[5] = try state.active_runtime.?.createBigInt("1n");
    try std.testing.expectError(error.CannotSerializeBigInt, referenceBuiltin(&state.active_runtime.?, staticStringValue("ABC"), roots[5]));
    roots[6] = try state.active_runtime.?.createDictionary(&.{});
    try state.active_runtime.?.indexSet(roots[6], staticStringValue("self"), roots[6]);
    const circular_args = [_]Value{ staticStringValue("ABC"), roots[6] };
    var result: Value = .{};
    lnako_aot_builtin_call(&result, &circular_args, circular_args.len, @intFromEnum(aot_builtin.Command.reference));
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    const circular_message = state.active_runtime.?.takeException();
    const circular_units = try valueUtf16Alloc(&state.active_runtime.?, circular_message);
    defer state.active_runtime.?.allocator.free(circular_units);
    try std.testing.expect(std.mem.startsWith(u16, circular_units, &.{ 'C', 'o', 'n', 'v' }));

    const null_args = [_]Value{ staticStringValue("ABC"), .{ .tag = @intFromEnum(Tag.null_value) } };
    lnako_aot_builtin_call(&result, &null_args, null_args.len, @intFromEnum(aot_builtin.Command.reference));
    try std.testing.expect(state.active_runtime.?.has_pending_exception);
    const null_message = state.active_runtime.?.takeException();
    const null_units = try valueUtf16Alloc(&state.active_runtime.?, null_message);
    defer state.active_runtime.?.allocator.free(null_units);
    const expected_null = try std.unicode.utf8ToUtf16LeAlloc(state.active_runtime.?.allocator, "Cannot read properties of null (reading '先頭')");
    defer state.active_runtime.?.allocator.free(expected_null);
    try std.testing.expectEqualSlices(u16, expected_null, null_units);
}

test "AOT文字列連結分解反復出現命令は公式の型変換を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try state.active_runtime.?.createArray(&.{numberValue(1)});
    const append_arguments = [_]Value{ roots[0], numberValue(2) };
    lnako_aot_builtin_call(&roots[1], &append_arguments, append_arguments.len, @intFromEnum(aot_builtin.Command.append));
    try std.testing.expectEqual(roots[0].payload, roots[1].payload);
    try std.testing.expectEqual(@as(usize, 2), roots[0].object().?.payload.array.items.len);

    const line_arguments = [_]Value{ staticStringValue("a"), staticStringValue("b") };
    lnako_aot_builtin_call(&roots[2], &line_arguments, line_arguments.len, @intFromEnum(aot_builtin.Command.append_line));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', '\n' }, roots[2].object().?.payload.utf16_string);
    const join_arguments = [_]Value{ staticStringValue("a"), numberValue(1), .{ .tag = @intFromEnum(Tag.null_value) }, .{} };
    lnako_aot_builtin_call(&roots[3], &join_arguments, join_arguments.len, @intFromEnum(aot_builtin.Command.concat_join));
    try std.testing.expectEqualSlices(u16, &.{ 'a', '1' }, roots[3].object().?.payload.utf16_string);

    const explode_arguments = [_]Value{staticStringValue("A😀B")};
    lnako_aot_builtin_call(&roots[4], &explode_arguments, explode_arguments.len, @intFromEnum(aot_builtin.Command.explode));
    const characters = roots[4].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 3), characters.len);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, characters[1].object().?.payload.utf16_string);

    const refrain_arguments = [_]Value{ staticStringValue("x"), numberValue(2.1) };
    lnako_aot_builtin_call(&roots[5], &refrain_arguments, refrain_arguments.len, @intFromEnum(aot_builtin.Command.refrain));
    try std.testing.expectEqualSlices(u16, &.{ 'x', 'x', 'x' }, roots[5].object().?.payload.utf16_string);
    const empty_count_arguments = [_]Value{ staticStringValue(""), staticStringValue("") };
    lnako_aot_builtin_call(&roots[6], &empty_count_arguments, empty_count_arguments.len, @intFromEnum(aot_builtin.Command.occurrence_count));
    try std.testing.expectEqual(@as(f64, -1), valueToNumber(roots[6]));
    const emoji_count_arguments = [_]Value{ staticStringValue("😀"), staticStringValue("") };
    lnako_aot_builtin_call(&roots[7], &emoji_count_arguments, emoji_count_arguments.len, @intFromEnum(aot_builtin.Command.occurrence_count));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(roots[7]));
}

test "AOT部分文字列命令は数値小数と文字列小数を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const numeric_mid = [_]Value{ staticStringValue("A😀BCD"), numberValue(2.9), numberValue(2.9) };
    lnako_aot_builtin_call(&roots[0], &numeric_mid, numeric_mid.len, @intFromEnum(aot_builtin.Command.substring_mid));
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00, 'B', 'C' }, roots[0].object().?.payload.utf16_string);
    const string_mid = [_]Value{ staticStringValue("A😀BCD"), staticStringValue("2.9"), staticStringValue("2.9") };
    lnako_aot_builtin_call(&roots[1], &string_mid, string_mid.len, @intFromEnum(aot_builtin.Command.substring_mid));
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00, 'B' }, roots[1].object().?.payload.utf16_string);
    const zero_mid = [_]Value{ staticStringValue("ABCDE"), numberValue(0), numberValue(2) };
    lnako_aot_builtin_call(&roots[2], &zero_mid, zero_mid.len, @intFromEnum(aot_builtin.Command.substring_mid));
    try std.testing.expectEqual(@as(usize, 0), roots[2].object().?.payload.utf16_string.len);
    const left_arguments = [_]Value{ staticStringValue("A😀BCD"), numberValue(2.9) };
    lnako_aot_builtin_call(&roots[3], &left_arguments, left_arguments.len, @intFromEnum(aot_builtin.Command.substring_left));
    try std.testing.expectEqualSlices(u16, &.{ 'A', 0xd83d, 0xde00 }, roots[3].object().?.payload.utf16_string);
    const right_arguments = [_]Value{ staticStringValue("A😀BCD"), numberValue(2.9) };
    lnako_aot_builtin_call(&roots[4], &right_arguments, right_arguments.len, @intFromEnum(aot_builtin.Command.substring_right));
    try std.testing.expectEqualSlices(u16, &.{ 'B', 'C', 'D' }, roots[4].object().?.payload.utf16_string);
}

test "AOT文字列分割削除はUTF-16空区切りとsplice位置を扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const split_arguments = [_]Value{ staticStringValue("A😀B😀C"), staticStringValue("😀") };
    lnako_aot_builtin_call(&roots[0], &split_arguments, split_arguments.len, @intFromEnum(aot_builtin.Command.split_all));
    const parts = roots[0].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 3), parts.len);
    try std.testing.expectEqualSlices(u16, &.{'A'}, parts[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'B'}, parts[1].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'C'}, parts[2].object().?.payload.utf16_string);
    const empty_split = [_]Value{ staticStringValue("😀"), staticStringValue("") };
    lnako_aot_builtin_call(&roots[1], &empty_split, empty_split.len, @intFromEnum(aot_builtin.Command.split_all));
    const units = roots[1].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 2), units.len);
    try std.testing.expectEqualSlices(u16, &.{0xd83d}, units[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{0xde00}, units[1].object().?.payload.utf16_string);

    lnako_aot_builtin_call(&roots[2], &empty_split, empty_split.len, @intFromEnum(aot_builtin.Command.split_first));
    const first_parts = roots[2].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 2), first_parts.len);
    try std.testing.expectEqual(@as(usize, 0), first_parts[0].object().?.payload.utf16_string.len);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, first_parts[1].object().?.payload.utf16_string);

    const remove_arguments = [_]Value{ staticStringValue("ABCDE"), numberValue(-1), numberValue(2) };
    lnako_aot_builtin_call(&roots[3], &remove_arguments, remove_arguments.len, @intFromEnum(aot_builtin.Command.string_remove));
    try std.testing.expectEqualSlices(u16, &.{ 'A', 'B', 'C' }, roots[3].object().?.payload.utf16_string);
}

test "AOTトリム命令はECMAScript空白だけを左右別に除去する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    const source = [_]Value{staticStringValue("﻿　\t A  \u{2029}")};
    lnako_aot_builtin_call(&roots[0], &source, source.len, @intFromEnum(aot_builtin.Command.trim_both));
    try std.testing.expectEqualSlices(u16, &.{'A'}, roots[0].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[1], &source, source.len, @intFromEnum(aot_builtin.Command.trim_right));
    try std.testing.expectEqualSlices(u16, &.{ 0xfeff, 0x3000, '\t', ' ', 'A' }, roots[1].object().?.payload.utf16_string);
    lnako_aot_builtin_call(&roots[2], &source, source.len, @intFromEnum(aot_builtin.Command.trim_left));
    try std.testing.expectEqualSlices(u16, &.{ 'A', ' ', 0x00a0, 0x2029 }, roots[2].object().?.payload.utf16_string);
}

test "AOT置換命令は全置換の空検索と単置換の置換パターンを分ける" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    const empty_all = [_]Value{ staticStringValue("abc"), staticStringValue(""), staticStringValue("-") };
    lnako_aot_builtin_call(&roots[0], &empty_all, empty_all.len, @intFromEnum(aot_builtin.Command.replace_all));
    try std.testing.expectEqualSlices(u16, &.{ 'a', '-', 'b', '-', 'c' }, roots[0].object().?.payload.utf16_string);
    const special_first = [_]Value{ staticStringValue("abc"), staticStringValue("b"), staticStringValue("[$$][$&][$`][$']") };
    lnako_aot_builtin_call(&roots[1], &special_first, special_first.len, @intFromEnum(aot_builtin.Command.replace_first));
    const expected = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, "a[$][b][a][c]c");
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualSlices(u16, expected, roots[1].object().?.payload.utf16_string);
    const literal_all = [_]Value{ staticStringValue("abc"), staticStringValue("b"), staticStringValue("[$&]") };
    lnako_aot_builtin_call(&roots[2], &literal_all, literal_all.len, @intFromEnum(aot_builtin.Command.replace_all));
    try std.testing.expectEqualSlices(u16, &.{ 'a', '[', '$', '&', ']', 'c' }, roots[2].object().?.payload.utf16_string);
    const undefined_separator = [_]Value{ staticStringValue("xundefinedy"), .{}, staticStringValue("z") };
    lnako_aot_builtin_call(&roots[3], &undefined_separator, undefined_separator.len, @intFromEnum(aot_builtin.Command.replace_all));
    try std.testing.expectEqualSlices(u16, &.{ 'x', 'u', 'n', 'd', 'e', 'f', 'i', 'n', 'e', 'd', 'y' }, roots[3].object().?.payload.utf16_string);
    const undefined_join = [_]Value{ staticStringValue("a-a"), staticStringValue("a"), .{} };
    lnako_aot_builtin_call(&roots[4], &undefined_join, undefined_join.len, @intFromEnum(aot_builtin.Command.replace_all));
    try std.testing.expectEqualSlices(u16, &.{ ',', '-', ',' }, roots[4].object().?.payload.utf16_string);
    const undefined_first_replacement = [_]Value{ staticStringValue("x-x"), staticStringValue("x"), .{} };
    lnako_aot_builtin_call(&roots[5], &undefined_first_replacement, undefined_first_replacement.len, @intFromEnum(aot_builtin.Command.replace_first));
    try std.testing.expectEqualSlices(u16, &.{ 'u', 'n', 'd', 'e', 'f', 'i', 'n', 'e', 'd', '-', 'x' }, roots[5].object().?.payload.utf16_string);
}

test "AOT幅埋めは正のInfinity幅を非終了ではなく安全制限へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const arguments = [_]Value{ staticStringValue("x"), numberValue(std.math.inf(f64)) };
    lnako_aot_builtin_call(&roots[0], &arguments, arguments.len, @intFromEnum(aot_builtin.Command.zero_pad));
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    const message = try pendingExceptionMessageUtf8Alloc(&state.active_runtime.?);
    defer state.active_runtime.?.allocator.free(message);
    try std.testing.expectEqualStrings("String padding width is unbounded", message);
    _ = state.active_runtime.?.takeException();

    const negative_arguments = [_]Value{ staticStringValue("x"), numberValue(-std.math.inf(f64)) };
    lnako_aot_builtin_call(&roots[1], &negative_arguments, negative_arguments.len, @intFromEnum(aot_builtin.Command.space_pad));
    try std.testing.expectEqualSlices(u16, &.{ ' ', 'x' }, roots[1].object().?.payload.utf16_string);
}

test "AOT幅変換は英数記号とカナの合成順序および公式の濁点端挙動を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const ascii_full = [_]Value{staticStringValue("Az09!")};
    lnako_aot_builtin_call(&roots[0], &ascii_full, ascii_full.len, @intFromEnum(aot_builtin.Command.ascii_full_width));
    try std.testing.expectEqualSlices(u16, &.{ 0xff21, 0xff5a, 0xff10, 0xff19, '!' }, roots[0].object().?.payload.utf16_string);
    const symbols_full = [_]Value{staticStringValue("A 1!")};
    lnako_aot_builtin_call(&roots[1], &symbols_full, symbols_full.len, @intFromEnum(aot_builtin.Command.ascii_symbol_full_width));
    try std.testing.expectEqualSlices(u16, &.{ 0xff21, 0x3000, 0xff11, 0xff01 }, roots[1].object().?.payload.utf16_string);
    const symbols_half = [_]Value{staticStringValue("Ａ　１！")};
    lnako_aot_builtin_call(&roots[2], &symbols_half, symbols_half.len, @intFromEnum(aot_builtin.Command.ascii_symbol_half_width));
    try std.testing.expectEqualSlices(u16, &.{ 'A', ' ', '1', '!' }, roots[2].object().?.payload.utf16_string);

    const kana_full = [_]Value{staticStringValue("ｶﾞｯﾂ")};
    lnako_aot_builtin_call(&roots[3], &kana_full, kana_full.len, @intFromEnum(aot_builtin.Command.katakana_full_width));
    try std.testing.expectEqualSlices(u16, &.{ 0x30ac, 0x30c3, 0x30c5 }, roots[3].object().?.payload.utf16_string);
    const kana_half = [_]Value{staticStringValue("ガッツ")};
    lnako_aot_builtin_call(&roots[4], &kana_half, kana_half.len, @intFromEnum(aot_builtin.Command.katakana_half_width));
    try std.testing.expectEqualSlices(u16, &.{ 0xff76, 0xff9e, 0xff6f, 0xff82 }, roots[4].object().?.payload.utf16_string);
    const odd_voiced = [_]Value{staticStringValue("ｶﾞﾊﾟﾞﾟ")};
    lnako_aot_builtin_call(&roots[5], &odd_voiced, odd_voiced.len, @intFromEnum(aot_builtin.Command.katakana_full_width));
    try std.testing.expectEqualSlices(u16, &.{ 0x30ac, 0x30d1, 0x30d1 }, roots[5].object().?.payload.utf16_string);

    const full = [_]Value{staticStringValue("A ｶﾞ!")};
    lnako_aot_builtin_call(&roots[6], &full, full.len, @intFromEnum(aot_builtin.Command.full_width));
    try std.testing.expectEqualSlices(u16, &.{ 0xff21, 0x3000, 0x30ac, 0xff01 }, roots[6].object().?.payload.utf16_string);
    const half = [_]Value{staticStringValue("Ａ　ガ！")};
    lnako_aot_builtin_call(&roots[7], &half, half.len, @intFromEnum(aot_builtin.Command.half_width));
    try std.testing.expectEqualSlices(u16, &.{ 'A', ' ', 0xff76, 0xff9e, '!' }, roots[7].object().?.payload.utf16_string);
}

test "AOT幅変換のカナ系は生レシーバ分岐と保留例外を公式どおり処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const rt = &state.active_runtime.?;
    var roots = [_]Value{.{}} ** 8;
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);
    rt.next_collection = 1;

    roots[0] = try rt.createArray(&.{});
    roots[1] = try rt.createArray(&.{numberValue(1)});
    roots[2] = try rt.createDictionary(&.{ staticStringValue("length"), numberValue(1) });
    roots[3] = try rt.createDictionary(&.{});
    try std.testing.expectEqualSlices(u16, &.{}, (try kanaMapBuiltin(rt, roots[0], true)).object().?.payload.utf16_string);
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, kanaMapBuiltin(rt, roots[1], true));
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, kanaMapBuiltin(rt, roots[2], true));
    try std.testing.expectEqualSlices(u16, &.{}, (try kanaMapBuiltin(rt, roots[3], true)).object().?.payload.utf16_string);
    try std.testing.expectError(error.KatakanaFullWidthLengthNull, kanaMapBuiltin(rt, .{ .tag = @intFromEnum(Tag.null_value) }, true));
    try std.testing.expectError(error.KatakanaHalfWidthSplitUndefined, kanaMapBuiltin(rt, .{}, false));
    try std.testing.expectError(error.KatakanaHalfWidthSplitReceiver, kanaMapBuiltin(rt, numberValue(1), false));

    const failing = [_]Value{numberValue(1)};
    lnako_aot_builtin_call(&roots[4], &failing, failing.len, @intFromEnum(aot_builtin.Command.half_width));
    const failure_units = try valueUtf16Alloc(rt, rt.takeException());
    defer rt.allocator.free(failure_units);
    try std.testing.expectEqualSlices(u16, &.{ 's', '.', 's', 'p', 'l', 'i', 't', ' ', 'i', 's', ' ', 'n', 'o', 't', ' ', 'a', ' ', 'f', 'u', 'n', 'c', 't', 'i', 'o', 'n' }, failure_units);
    const succeeding = [_]Value{staticStringValue("ガ")};
    lnako_aot_builtin_call(&roots[5], &succeeding, succeeding.len, @intFromEnum(aot_builtin.Command.half_width));
    try std.testing.expect(!rt.has_pending_exception);
    try std.testing.expectEqualSlices(u16, &.{ 0xff76, 0xff9e }, roots[5].object().?.payload.utf16_string);

    roots[6] = try rt.createBytes(&.{0x41});
    try std.testing.expectError(error.KatakanaFullWidthSubstringReceiver, kanaMapBuiltin(rt, roots[6], true));
    try std.testing.expectError(error.KatakanaHalfWidthSplitReceiver, kanaMapBuiltin(rt, roots[6], false));
}

test "AOT幅変換は辞書のカスタムsubstring・charAt・splitとprototypeを呼び出す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{.{}} ** 12;
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);

    roots[0] = try active.createFunction(testAotKanaSubstringVoiced, 2, &.{});
    roots[1] = try active.createFunction(testAotKanaSubstringPlain, 2, &.{});
    roots[2] = try active.createFunction(testAotKanaCharAtA, 1, &.{});
    roots[3] = try active.createFunction(testAotKanaSplit, 1, &.{});

    roots[4] = try active.createDictionary(&.{ staticStringValue("length"), numberValue(2), staticStringValue("substring"), roots[0], staticStringValue("charAt"), roots[2] });
    roots[5] = try kanaMapBuiltin(active, roots[4], true);
    try expectUtf16String(active, roots[5], "ガ");

    roots[6] = try active.createDictionary(&.{ staticStringValue("length"), numberValue(2), staticStringValue("substring"), roots[1], staticStringValue("charAt"), roots[2] });
    roots[7] = try kanaMapBuiltin(active, roots[6], true);
    try expectUtf16String(active, roots[7], "アア");

    roots[8] = try active.createDictionary(&.{ staticStringValue("split"), roots[3] });
    roots[9] = try active.createDictionary(&.{});
    roots[9].object().?.prototype = roots[8];
    roots[10] = try kanaMapBuiltin(active, roots[9], false);
    try expectUtf16String(active, roots[10], "ｶﾞｯﾂ");

    roots[11] = try active.createDictionary(&.{ staticStringValue("length"), numberValue(1), staticStringValue("substring"), roots[1] });
    try std.testing.expectError(error.KatakanaFullWidthCharAtReceiver, kanaMapBuiltin(active, roots[11], true));
}

test "AOT幅変換は入力をGCルート化し全割当失敗を処理する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, aotWidthAllocationTest, .{});
}

test "AOTクロージャがGC管理の可変セルを共有する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{} };
    var frame: RootFrame = .{};
    state.active_runtime.?.pushRoots(&frame, &roots, roots.len);
    var initial = numberValue(4);
    lnako_aot_binding_cell_new(&roots[0], &initial);
    lnako_aot_function_new(&roots[1], testAotCapturedIncrement, 0, @ptrCast(&roots[0]), 1);
    try std.testing.expectEqual(@as(usize, 0), state.active_runtime.?.collect());
    var result: Value = .{};
    lnako_aot_function_call(&result, &roots[1], null, 0);
    try std.testing.expectEqual(@as(f64, 5), valueToNumber(result));
    lnako_aot_function_call(&result, &roots[1], null, 0);
    try std.testing.expectEqual(@as(f64, 6), valueToNumber(result));
    lnako_aot_binding_cell_value(&roots[0]).* = roots[1];
    state.active_runtime.?.popRoots(&frame);
    try std.testing.expectEqual(@as(usize, 2), state.active_runtime.?.collect());
}

test "保留例外をGCルートとして保持し一度だけ取り出す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const message = try state.active_runtime.?.createString(&.{ '失', '敗' });
    lnako_aot_exception_set(&message);
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    try std.testing.expectEqual(@as(usize, 0), state.active_runtime.?.collect());
    var taken: Value = .{};
    lnako_aot_exception_take(&taken);
    try std.testing.expectEqual(message.payload, taken.payload);
    try std.testing.expectEqual(@as(c_int, 0), lnako_aot_exception_pending());
    try std.testing.expectEqual(@as(usize, 1), state.active_runtime.?.collect());
}

test "AOTエラー発生のError message変換を値型ごとに行う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var values = [_]Value{
        .{},
        numberValue(123),
        .{ .tag = @intFromEnum(Tag.boolean), .payload = 1 },
        .{ .tag = @intFromEnum(Tag.null_value) },
        staticStringValue("文字列"),
    };
    var roots: RootFrame = .{};
    lnako_aot_push_roots(&roots, &values, values.len);
    defer lnako_aot_pop_roots(&roots);

    const expected = [_][]const u8{ "", "123", "true", "null", "文字列" };
    for (&values, expected) |*value, expected_text| {
        lnako_aot_exception_set_error_message(value);
        try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
        var taken: Value = .{};
        lnako_aot_exception_take(&taken);
        const actual = try valueUtf16Alloc(&runtime, taken);
        defer runtime.allocator.free(actual);
        const expected_units = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, expected_text);
        defer runtime.allocator.free(expected_units);
        try std.testing.expectEqualSlices(u16, expected_units, actual);
    }
}

test "AOT未捕捉例外の本文をUTF-16から安全にUTF-8へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();

    try std.testing.expectError(error.NoPendingException, pendingExceptionMessageUtf8Alloc(&runtime));

    runtime.setFailureText("object null is not iterable (cannot read property Symbol(Symbol.iterator))");
    const null_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(null_message);
    try std.testing.expectEqualStrings("object null is not iterable (cannot read property Symbol(Symbol.iterator))", null_message);
    _ = runtime.takeException();

    runtime.setFailureText("undefined is not iterable (cannot read property Symbol(Symbol.iterator))");
    const undefined_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(undefined_message);
    try std.testing.expectEqualStrings("undefined is not iterable (cannot read property Symbol(Symbol.iterator))", undefined_message);
    _ = runtime.takeException();

    const units = [_]u16{ 'a', 0xd83d, 0xde00, 0xd800, 'b', 0xdc00 };
    const surrogate_message = try utf16FailureMessageUtf8Alloc(runtime.allocator, &units);
    defer runtime.allocator.free(surrogate_message);
    try std.testing.expectEqualStrings("a😀�b�", surrogate_message);
}

test "AOT算術失敗を公式文言の保留例外へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var values = [_]Value{ try state.active_runtime.?.createBigInt("1n"), numberValue(1), .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &values, values.len);
    defer lnako_aot_pop_roots(&frame);
    lnako_aot_arithmetic(&values[2], &values[0], &values[1], @intFromEnum(Arithmetic.add));
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    var taken: Value = .{};
    lnako_aot_exception_take(&taken);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, taken.object().?.payload.utf16_string);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("Cannot mix BigInt and other types, use explicit conversions", utf8);
}

test "AOTのnull添字代入をキー付きの保留例外へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var values = [_]Value{ .{ .tag = @intFromEnum(Tag.null_value) }, numberValue(0), numberValue(2) };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &values, values.len);
    defer lnako_aot_pop_roots(&frame);
    try std.testing.expectEqual(@as(c_int, -1), lnako_aot_index_set(&values[0], &values[1], &values[2]));
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    var taken: Value = .{};
    lnako_aot_exception_take(&taken);
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, taken.object().?.payload.utf16_string);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("Cannot set properties of null (setting '0')", utf8);
}

test "ルートフレームをLIFOで連結する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var outer: RootFrame = .{};
    var inner: RootFrame = .{};
    runtime.pushRoots(&outer, null, 0);
    runtime.pushRoots(&inner, null, 0);
    try std.testing.expect(runtime.roots == &inner);
    runtime.popRoots(&inner);
    try std.testing.expect(runtime.roots == &outer);
    runtime.popRoots(&outer);
    try std.testing.expect(runtime.roots == null);
}

test "配列と辞書の子を反復走査し循環参照を回収する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var array = try runtime.createArray(&.{});
    const dictionary = try runtime.createDictionary(&.{});
    try runtime.indexSet(array, numberValue(0), dictionary);
    try runtime.indexSet(dictionary, staticStringValue("array"), array);
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, @ptrCast(&array), 1);
    try std.testing.expectEqual(@as(usize, 0), runtime.collect());
    try std.testing.expectEqual(@as(usize, 2), runtime.object_count);
    runtime.popRoots(&frame);
    try std.testing.expectEqual(@as(usize, 2), runtime.collect());
    try std.testing.expectEqual(@as(usize, 0), runtime.object_count);
}

test "配列の伸長と辞書の挿入位置を保った更新を行う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const array = try runtime.createArray(&.{numberValue(1)});
    try runtime.indexSet(array, numberValue(2), numberValue(3));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 3))), runtime.indexGet(array, numberValue(2)).payload);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(runtime.indexGet(array, numberValue(1)).tag)));
    const dictionary = try runtime.createDictionary(&.{ staticStringValue("x"), numberValue(1), staticStringValue("y"), numberValue(2) });
    try runtime.indexSet(dictionary, staticStringValue("x"), numberValue(7));
    const entries = dictionary.object().?.payload.dictionary.items;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 7))), entries[0].value.payload);
}

test "プリミティブへの添字代入を無視し非反復値を空として扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try runtime.indexSet(numberValue(1), numberValue(0), numberValue(2));
    try runtime.indexSet(.{ .tag = @intFromEnum(Tag.boolean), .payload = 1 }, numberValue(0), numberValue(2));
    const text = try runtime.createString(&.{ 'a', 'b', 'c' });
    try runtime.indexSet(text, numberValue(0), numberValue(2));
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, text.object().?.payload.utf16_string);
    const iterator = try runtime.createIterator(&.{.{ .tag = @intFromEnum(Tag.null_value) }}, false, 0);
    try std.testing.expect(!runtime.iteratorHasNext(iterator));
}

test "AOT分割宣言は非配列を1要素の値として扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const scalar = numberValue(7);
    try std.testing.expectEqual(scalar.payload, runtime.destructureGet(scalar, 0).payload);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(runtime.destructureGet(scalar, 1).tag)));
    const array = try runtime.createArray(&.{ numberValue(2), numberValue(3) });
    try std.testing.expectEqual(numberValue(3).payload, runtime.destructureGet(array, 1).payload);
}

test "UTF-16文字列の添字と反復をコード単位で処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var values = [_]Value{try runtime.createString(&.{ 'A', 0xd83d, 0xde00, 'B' })};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &values, values.len);
    const high = runtime.indexGet(values[0], numberValue(1));
    try std.testing.expectEqualSlices(u16, &.{0xd83d}, high.object().?.payload.utf16_string);
    values[0] = try runtime.createIterator(&.{values[0]}, false, 0);
    var target: Value = .{};
    var key: Value = .{};
    _ = runtime.iteratorNext(values[0], null, &target, &key, null);
    try std.testing.expectEqualSlices(u16, &.{'A'}, target.object().?.payload.utf16_string);
    _ = runtime.iteratorNext(values[0], null, &target, &key, null);
    try std.testing.expectEqualSlices(u16, &.{0xd83d}, target.object().?.payload.utf16_string);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 1))), key.payload);
    runtime.popRoots(&frame);
}

test "AOT BigIntを任意精度で生成して真偽判定する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const large = try runtime.createBigInt("123456789012345678901234567890n");
    const zero = try runtime.createBigInt("0n");
    try std.testing.expect(!large.object().?.payload.bigint.isZero());
    try std.testing.expect(zero.object().?.payload.bigint.isZero());
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_bigint_truthy(&large));
    try std.testing.expectEqual(@as(c_int, 0), lnako_aot_bigint_truthy(&zero));
}

test "AOT BigInt算術とNumber混在エラーを処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const left = try runtime.createBigInt("123456789012345678901234567890n");
    const right = try runtime.createBigInt("10n");
    var roots = [_]Value{ left, right, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    roots[2] = try bigIntArithmetic(&runtime, .add, roots[0], roots[1]);
    const text = try roots[2].object().?.payload.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("123456789012345678901234567900", text);
    try std.testing.expectError(error.CannotMixBigIntAndNumber, bigIntArithmetic(&runtime, .add, roots[0], numberValue(1)));
    try std.testing.expectError(error.CannotConvertBigIntToNumber, bigIntArithmetic(&runtime, .integer_divide, roots[0], roots[1]));
    runtime.popRoots(&frame);
}

test "AOT動的数値演算は文字列・配列・辞書を公式規則で変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createString(&.{'5'});
    roots[1] = try runtime.createArray(&.{numberValue(5)});
    roots[2] = try runtime.createArray(&.{});
    roots[3] = try runtime.createDictionary(&.{});

    const string_result = try arithmetic(&runtime, .subtract, roots[0], numberValue(2));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(string_result.payload)));
    const singleton_result = try arithmetic(&runtime, .multiply, roots[1], numberValue(2));
    try std.testing.expectEqual(@as(f64, 10), @as(f64, @bitCast(singleton_result.payload)));
    const empty_result = try arithmetic(&runtime, .add, roots[2], numberValue(1));
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast(empty_result.payload))));
    const dictionary_result = try arithmetic(&runtime, .add, roots[3], numberValue(1));
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast(dictionary_result.payload))));
    const whitespace_result = try arithmetic(&runtime, .power, try runtime.createString(&.{ 0x3000, '2', 0x3000 }), numberValue(3));
    try std.testing.expectEqual(@as(f64, 8), @as(f64, @bitCast(whitespace_result.payload)));
    const prefix_result = try arithmetic(&runtime, .add, try runtime.createString(&.{ '5', 'x' }), numberValue(2));
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(prefix_result.payload)));
    const floor_result = try arithmetic(&runtime, .integer_divide, numberValue(-5), numberValue(2));
    try std.testing.expectEqual(@as(f64, -3), @as(f64, @bitCast(floor_result.payload)));
}

test "AOT辞書のカスタムToPrimitiveはヒント順序と失敗を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{.{}} ** 8;
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);

    roots[0] = try active.createDictionary(&.{});
    roots[1] = try active.createFunction(testAotCustomString, 0, &.{});
    roots[2] = try active.createFunction(testAotConstantSeven, 0, &.{});
    roots[3] = try active.createFunction(testAotToPrimitiveObject, 0, &.{});
    try active.setDictionary(&roots[0].object().?.payload.dictionary, staticStringValue("toString"), roots[1]);
    try active.setDictionary(&roots[0].object().?.payload.dictionary, staticStringValue("valueOf"), roots[2]);
    try expectUtf16String(active, try dictionaryToPrimitive(active, roots[0], .string), "CUSTOM");
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast((try dictionaryToPrimitive(active, roots[0], .number)).payload)));

    roots[4] = try active.createDictionary(&.{});
    try active.setDictionary(&roots[4].object().?.payload.dictionary, staticStringValue("valueOf"), roots[2]);
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast((try dictionaryToPrimitive(active, roots[4], .number)).payload)));
    const object_add = try arithmetic(active, .add, roots[4], numberValue(1));
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast(object_add.payload))));

    roots[6] = try active.createDictionary(&.{});
    roots[7] = try active.createDictionary(&.{ staticStringValue("toString"), roots[1] });
    roots[6].object().?.prototype = roots[7];
    try expectUtf16String(active, try dictionaryToPrimitive(active, roots[6], .string), "CUSTOM");

    roots[5] = try active.createDictionary(&.{});
    try active.setDictionary(&roots[5].object().?.payload.dictionary, staticStringValue("toString"), roots[3]);
    try active.setDictionary(&roots[5].object().?.payload.dictionary, staticStringValue("valueOf"), roots[3]);
    try std.testing.expectError(error.CannotConvertObjectToPrimitive, dictionaryToPrimitive(active, roots[5], .string));
}

test "AOT配列のカスタムToPrimitiveは文字列と数値hintへ接続する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{.{}} ** 7;
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);

    roots[0] = try active.createArray(&.{ numberValue(1), numberValue(2) });
    roots[1] = try active.createFunction(testAotCustomString, 0, &.{});
    roots[2] = try active.createFunction(testAotConstantSeven, 0, &.{});
    try active.setDictionary(&roots[0].object().?.array_properties, staticStringValue("toString"), roots[1]);
    try active.setDictionary(&roots[0].object().?.array_properties, staticStringValue("valueOf"), roots[2]);
    try expectUtf16String(active, try valueToPrimitive(active, roots[0], .string), "CUSTOM");
    try expectUtf16String(active, roots[0], "CUSTOM");
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast((try valueToPrimitive(active, roots[0], .number)).payload)));
    const subtraction = try arithmetic(active, .subtract, roots[0], numberValue(1));
    try std.testing.expectEqual(@as(f64, 6), @as(f64, @bitCast(subtraction.payload)));

    roots[3] = try active.createArray(&.{ numberValue(1), numberValue(2) });
    try active.setDictionary(&roots[3].object().?.array_properties, staticStringValue("valueOf"), roots[2]);
    try expectUtf16String(active, roots[3], "1,2");
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast((try valueToPrimitive(active, roots[3], .number)).payload)));

    roots[4] = try active.createArray(&.{ numberValue(1), numberValue(2) });
    roots[5] = try active.createFunction(testAotToPrimitiveObject, 0, &.{});
    try active.setDictionary(&roots[4].object().?.array_properties, staticStringValue("toString"), roots[5]);
    try std.testing.expectError(error.CannotConvertObjectToPrimitive, valueToPrimitive(active, roots[4], .string));
}

test "AOT byte bufferのcustom prototypeをToPrimitiveへ接続する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{.{}} ** 8;
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);

    roots[0] = try active.createBytes(&.{ 85, 66 });
    roots[1] = try active.createUint8Array(&.{ 85, 66 });
    roots[2] = try active.createArrayBuffer(&.{ 85, 66 });
    roots[3] = try active.createFunction(testAotCustomString, 0, &.{});
    roots[4] = try active.createFunction(testAotConstantSeven, 0, &.{});
    roots[5] = try active.createDictionary(&.{ staticStringValue("toString"), roots[3] });
    roots[6] = try active.createDictionary(&.{ staticStringValue("valueOf"), roots[4] });
    roots[0].object().?.prototype = roots[5];
    roots[1].object().?.prototype = roots[5];
    roots[2].object().?.prototype = roots[6];

    try expectUtf16String(active, try valueToPrimitive(active, roots[0], .string), "CUSTOM");
    try expectUtf16String(active, try valueToPrimitive(active, roots[1], .string), "CUSTOM");
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast((try valueToPrimitive(active, roots[2], .number)).payload)));
}

test "AOT BigInt比較をNumberとの間でも精度を落とさず処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const bigint = try runtime.createBigInt("9007199254740993n");
    try std.testing.expect(try compareValues(&runtime, .greater, bigint, numberValue(9007199254740992.0)));
    try std.testing.expect(try compareValues(&runtime, .abstract_equal, try runtime.createBigInt("1n"), numberValue(1)));
    try std.testing.expect(!(try compareValues(&runtime, .strict_equal, try runtime.createBigInt("1n"), numberValue(1))));
}

test "AOT動的比較は文字列変換と参照同一性を区別する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{
        try runtime.createArray(&.{numberValue(1)}),
        try runtime.createArray(&.{numberValue(1)}),
        try runtime.createString(&.{'1'}),
        try runtime.createDictionary(&.{}),
        try runtime.createArray(&.{staticStringValue("[object Object]")}),
    };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    try std.testing.expect(try compareValues(&runtime, .abstract_equal, roots[0], numberValue(1)));
    try std.testing.expect(!(try compareValues(&runtime, .strict_equal, roots[0], numberValue(1))));
    try std.testing.expect(try compareValues(&runtime, .strict_equal, roots[0], roots[0]));
    try std.testing.expect(!(try compareValues(&runtime, .strict_equal, roots[0], roots[1])));
    try std.testing.expect(try compareValues(&runtime, .abstract_equal, staticStringValue("1"), roots[2]));
    try std.testing.expect(!(try compareValues(&runtime, .abstract_equal, roots[3], roots[4])));
    try std.testing.expect(try compareValues(&runtime, .abstract_equal, .{ .tag = @intFromEnum(Tag.null_value) }, .{}));
    try std.testing.expect(!(try compareValues(&runtime, .strict_equal, .{ .tag = @intFromEnum(Tag.null_value) }, .{})));
    try std.testing.expect(try compareValues(&runtime, .greater, staticStringValue("2"), numberValue(1)));
    try std.testing.expect(!(try compareValues(&runtime, .greater, staticStringValue("A"), numberValue(1))));
}

test "AOT一致系命令は配列と辞書を内容比較する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ numberValue(1), numberValue(2) });
    roots[1] = try runtime.createArray(&.{ numberValue(1), numberValue(2) });
    roots[2] = try runtime.createArray(&.{ numberValue(1), numberValue(3) });
    roots[3] = try runtime.createDictionary(&.{ staticStringValue("x"), roots[0] });
    roots[4] = try runtime.createDictionary(&.{ staticStringValue("x"), roots[1] });
    roots[5] = try runtime.createDictionary(&.{ staticStringValue("x"), roots[2] });

    try std.testing.expect(try compareValues(&runtime, .deep_equal, roots[0], roots[1]));
    try std.testing.expect(!(try compareValues(&runtime, .deep_equal, roots[0], roots[2])));
    try std.testing.expect(try compareValues(&runtime, .deep_equal, roots[3], roots[4]));
    try std.testing.expect(!(try compareValues(&runtime, .deep_equal, roots[3], roots[5])));
    try std.testing.expect(try compareValues(&runtime, .deep_not_equal, roots[3], roots[5]));
    try std.testing.expect(try compareValues(&runtime, .deep_equal, numberValue(1), numberValue(1)));
    try std.testing.expect(try compareValues(&runtime, .deep_not_equal, numberValue(1), staticStringValue("1")));
}

test "AOTのNumberとBigIntシフトを公式規則で処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 240))), (try shift(&runtime, .left, numberValue(15), numberValue(4))).payload);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 2147483647))), (try shift(&runtime, .right_unsigned, numberValue(-1), numberValue(1))).payload);
    const value = try runtime.createBigInt("8n");
    const negative = try runtime.createBigInt("-2n");
    const shifted = try shift(&runtime, .left, value, negative);
    const text = try shifted.object().?.payload.bigint.toString(std.testing.allocator, 10);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("2", text);
    try std.testing.expectError(error.UnsignedShiftOfBigInt, shift(&runtime, .right_unsigned, value, try runtime.createBigInt("1n")));
}

test "AOTの値をUTF-16文字列として連結する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{
        try runtime.createBigInt("12345678901234567890n"),
        try runtime.createArray(&.{ numberValue(1), numberValue(2) }),
        try runtime.createDictionary(&.{}),
        try runtime.createArray(&.{}),
    };
    try runtime.indexSet(roots[3], numberValue(0), roots[3]);
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    const joined = try concat(&runtime, roots[0], staticStringValue("個"));
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, joined.object().?.payload.utf16_string);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("12345678901234567890個", utf8);
    const number_joined = try concat(&runtime, numberValue(3), staticStringValue("個"));
    const number_utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, number_joined.object().?.payload.utf16_string);
    defer std.testing.allocator.free(number_utf8);
    try std.testing.expectEqualStrings("3個", number_utf8);
    const array_joined = try concat(&runtime, roots[1], staticStringValue("個"));
    try std.testing.expectEqualSlices(u16, &.{ '1', ',', '2', 0x500b }, array_joined.object().?.payload.utf16_string);
    const dictionary_joined = try concat(&runtime, roots[2], staticStringValue("個"));
    try std.testing.expectEqualSlices(u16, &.{ '[', 'o', 'b', 'j', 'e', 'c', 't', ' ', 'O', 'b', 'j', 'e', 'c', 't', ']', 0x500b }, dictionary_joined.object().?.payload.utf16_string);
    const cycle_joined = try concat(&runtime, roots[3], staticStringValue("個"));
    try std.testing.expectEqualSlices(u16, &.{0x500b}, cycle_joined.object().?.payload.utf16_string);
}

test "AOT増減は未定義・文字列・BigIntをNumberへ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const value = incrementValue(&runtime, .{}, numberValue(1));
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 1))), value.payload);
    const bigint = try runtime.createBigInt("5n");
    try std.testing.expectEqual(@as(f64, 7), incrementNumber(&runtime, bigint) + incrementNumber(&runtime, numberValue(2)));
    const string = try runtime.createString(&.{'5'});
    try std.testing.expectEqual(@as(f64, 7), incrementNumber(&runtime, string) + incrementNumber(&runtime, numberValue(2)));
}

test "回数・範囲・配列・辞書の反復状態と元コレクションを追跡する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var values = [_]Value{try runtime.createArray(&.{ numberValue(3), numberValue(4) })};
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &values, values.len);
    values[0] = try runtime.createIterator(&.{values[0]}, false, 0);
    try std.testing.expectEqual(@as(usize, 0), runtime.collect());
    try std.testing.expectEqual(@as(usize, 2), runtime.object_count);
    var target: Value = .{};
    var key: Value = .{};
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 3))), runtime.iteratorNext(values[0], null, &target, &key, null).payload);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 0))), key.payload);
    try std.testing.expect(runtime.iteratorHasNext(values[0]));
    _ = runtime.iteratorNext(values[0], null, &target, &key, null);
    try std.testing.expect(!runtime.iteratorHasNext(values[0]));
    runtime.popRoots(&frame);
    try std.testing.expectEqual(@as(usize, 2), runtime.collect());

    var repeat = try runtime.createIterator(&.{numberValue(2)}, false, 0);
    runtime.pushRoots(&frame, @ptrCast(&repeat), 1);
    var repeat_target: Value = .{};
    _ = runtime.iteratorNext(repeat, &repeat_target, null, null, null);
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 1))), repeat_target.payload);
    runtime.popRoots(&frame);
    const non_iterable = try runtime.createIterator(&.{try runtime.createBigInt("1n")}, false, 0);
    try std.testing.expect(!runtime.iteratorHasNext(non_iterable));
}

test "AOT配列の集約・入替・連番・要素生成を公式境界で処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 20;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{staticStringValue("9")});
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt((try arrayExtremumBuiltin(&runtime, roots[0], true)).tag)));
    roots[3] = try runtime.createBigInt("1n");
    roots[1] = try runtime.createArray(&.{roots[3]});
    try std.testing.expectEqual(roots[3].payload, (try arrayExtremumBuiltin(&runtime, roots[1], false)).payload);
    try std.testing.expectError(error.ArrayExpected, arrayExtremumBuiltin(&runtime, numberValue(1), true));

    roots[0] = try runtime.createArray(&.{ numberValue(-0.0), numberValue(0.0) });
    const maximum = try arrayExtremumBuiltin(&runtime, roots[0], true);
    try std.testing.expect(!isNegativeZero(@bitCast(maximum.payload)));
    roots[1] = try runtime.createArray(&.{ numberValue(0.0), numberValue(-0.0) });
    const minimum = try arrayExtremumBuiltin(&runtime, roots[1], false);
    try std.testing.expect(isNegativeZero(@bitCast(minimum.payload)));
    roots[2] = try runtime.createArray(&.{ numberValue(2), numberValue(std.math.nan(f64)), numberValue(3) });
    try std.testing.expect(std.math.isNan(@as(f64, @bitCast((try arrayExtremumBuiltin(&runtime, roots[2], true)).payload))));
    roots[4] = try runtime.createArray(&.{ numberValue(0), roots[3] });
    try std.testing.expectError(error.CannotConvertBigIntToNumber, arrayExtremumBuiltin(&runtime, roots[4], true));

    roots[5] = try runtime.createArray(&.{ roots[3], staticStringValue("2.5x"), staticStringValue("x") });
    try std.testing.expectEqual(@as(f64, 3.5), @as(f64, @bitCast((try arraySumBuiltin(&runtime, roots[5])).payload)));
    roots[6] = try runtime.createArray(&.{ numberValue(0), numberValue(1), numberValue(2) });
    _ = try arraySwapBuiltin(&runtime, roots[6], numberValue(0), numberValue(4));
    const swapped = try arrayItems(roots[6]);
    try std.testing.expectEqual(@as(usize, 5), swapped.items.len);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(swapped.items[0].tag)));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(swapped.items[3].tag)));
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(swapped.items[4].payload)));
    try std.testing.expectError(error.ArraySparseLengthLimit, arraySwapBuiltin(&runtime, roots[6], numberValue(0), numberValue(@floatFromInt(safe_array_element_limit))));

    roots[7] = try arraySequenceBuiltin(&runtime, staticStringValue("2"), numberValue(4));
    const sequence = try arrayItems(roots[7]);
    try std.testing.expectEqual(@as(usize, 3), sequence.items.len);
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt(sequence.items[0].tag)));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(sequence.items[1].payload)));
    roots[8] = try runtime.createBigInt("2n");
    roots[9] = try runtime.createBigInt("4n");
    roots[10] = try arraySequenceBuiltin(&runtime, roots[8], roots[9]);
    try std.testing.expectEqual(@as(usize, 3), (try arrayItems(roots[10])).items.len);
    try std.testing.expectError(error.ArraySequenceSizeLimit, arraySequenceBuiltin(&runtime, numberValue(0), numberValue(std.math.inf(f64))));
    try std.testing.expectError(error.ArraySequenceSizeLimit, arraySequenceBuiltin(&runtime, numberValue(-std.math.inf(f64)), numberValue(-1)));
    try std.testing.expectError(
        error.ArraySequenceSizeLimit,
        arraySequenceBuiltin(&runtime, numberValue(9_007_199_254_740_992), numberValue(9_007_199_254_740_992)),
    );

    roots[11] = try runtime.createArray(&.{ numberValue(@floatFromInt(safe_array_element_limit)), numberValue(2) });
    try std.testing.expectError(error.ArrayFillSizeLimit, arrayFillBuiltin(&runtime, numberValue(0), roots[11]));
    roots[11] = try runtime.createArray(&.{ numberValue(1), numberValue(@floatFromInt(safe_array_element_limit - 1)) });
    try validateFillDimensions(&runtime, roots[11]);
    roots[11] = try runtime.createArray(&.{ numberValue(1), numberValue(@floatFromInt(safe_array_element_limit)) });
    try std.testing.expectError(error.ArrayFillSizeLimit, validateFillDimensions(&runtime, roots[11]));
    roots[11] = try runtime.createArray(&.{});
    roots[12] = try arrayFillBuiltin(&runtime, numberValue(7), roots[11]);
    try std.testing.expectEqual(@as(usize, 0), (try arrayItems(roots[12])).items.len);
    roots[13] = try arrayFillBuiltin(&runtime, .{}, numberValue(2));
    const undefined_fill = try arrayItems(roots[13]);
    try std.testing.expectEqual(@as(usize, 2), undefined_fill.items.len);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(undefined_fill.items[0].tag)));
    try std.testing.expectError(error.ArrayFillSizeLimit, arrayFillBuiltin(&runtime, numberValue(0), numberValue(std.math.inf(f64))));

    roots[11] = try runtime.createArray(&.{numberValue(1)});
    roots[12] = try arrayFillBuiltin(&runtime, roots[11], numberValue(2));
    const cloned = try arrayItems(roots[12]);
    try runtime.indexSet(cloned.items[0], numberValue(0), numberValue(9));
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(runtime.indexGet(cloned.items[1], numberValue(0)).payload)));

    roots[11] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[11], numberValue(1), numberValue(2));
    try runtime.indexSet(roots[11], numberValue(2), .{});
    roots[12] = try arrayFillBuiltin(&runtime, roots[11], numberValue(1));
    const sparse_outer = try arrayItems(roots[12]);
    const sparse_clone_value = sparse_outer.items[0];
    const sparse_clone = try arrayItems(sparse_clone_value);
    try std.testing.expectEqual(@as(usize, 3), sparse_clone.items.len);
    try std.testing.expect(!runtime.aotArrayIsPresent(sparse_clone_value.object().?, 0));
    try std.testing.expect(runtime.aotArrayIsPresent(sparse_clone_value.object().?, 1));
    try std.testing.expect(runtime.aotArrayIsPresent(sparse_clone_value.object().?, 2));
    try runtime.indexSet(sparse_clone_value, numberValue(0), numberValue(9));
    const sparse_source = try arrayItems(roots[11]);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(sparse_source.items[0].tag)));
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(sparse_source.items[1].payload)));

    roots[14] = try runtime.createBytes(&.{ 85, 154 });
    roots[15] = try arrayFillBuiltin(&runtime, roots[14], numberValue(1));
    const buffer_clone = (try arrayItems(roots[15])).items[0];
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(buffer_clone.tag)));
    const buffer_data = runtime.indexGet(buffer_clone, staticStringValue("data"));
    try std.testing.expectEqual(@as(f64, 85), @as(f64, @bitCast((try arrayItems(buffer_data)).items[0].payload)));
    try runtime.indexSet(buffer_data, numberValue(0), numberValue(9));
    try std.testing.expectEqual(@as(u8, 85), roots[14].object().?.payload.byte_buffer.bytes[0]);

    roots[16] = try runtime.createUint8Array(&.{ 139, 103 });
    roots[17] = try arrayFillBuiltin(&runtime, roots[16], numberValue(1));
    const uint8_clone = (try arrayItems(roots[17])).items[0];
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(uint8_clone.tag)));
    try std.testing.expectEqual(@as(f64, 139), @as(f64, @bitCast(runtime.indexGet(uint8_clone, staticStringValue("0")).payload)));

    roots[18] = try runtime.createArrayBuffer(&.{ 1, 2 });
    roots[19] = try arrayFillBuiltin(&runtime, roots[18], numberValue(1));
    const array_buffer_clone = (try arrayItems(roots[19])).items[0];
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(array_buffer_clone.tag)));
    try std.testing.expectEqual(@as(usize, 0), array_buffer_clone.object().?.payload.dictionary.items.len);
}

test "AOT配列生成の安全上限を命令別の診断へ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame: RootFrame = .{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    const sequence_arguments = [_]Value{ numberValue(0), numberValue(std.math.inf(f64)) };
    lnako_aot_builtin_call(
        &roots[0],
        &sequence_arguments,
        sequence_arguments.len,
        @intFromEnum(aot_builtin.Command.array_sequence),
    );
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    const sequence_message = try pendingExceptionMessageUtf8Alloc(&state.active_runtime.?);
    defer state.active_runtime.?.allocator.free(sequence_message);
    try std.testing.expectEqualStrings("Array sequence exceeds safety limit", sequence_message);
    _ = state.active_runtime.?.takeException();

    const fill_arguments = [_]Value{ numberValue(0), numberValue(std.math.inf(f64)) };
    lnako_aot_builtin_call(
        &roots[1],
        &fill_arguments,
        fill_arguments.len,
        @intFromEnum(aot_builtin.Command.array_fill),
    );
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    const fill_message = try pendingExceptionMessageUtf8Alloc(&state.active_runtime.?);
    defer state.active_runtime.?.allocator.free(fill_message);
    try std.testing.expectEqualStrings("Array fill size exceeds safety limit", fill_message);
    _ = state.active_runtime.?.takeException();

    roots[2] = try state.active_runtime.?.createArray(&.{numberValue(0)});
    const swap_arguments = [_]Value{ roots[2], numberValue(0), numberValue(@floatFromInt(safe_array_element_limit)) };
    lnako_aot_builtin_call(
        &roots[1],
        &swap_arguments,
        swap_arguments.len,
        @intFromEnum(aot_builtin.Command.array_swap),
    );
    try std.testing.expectEqual(@as(c_int, 1), lnako_aot_exception_pending());
    const swap_message = try pendingExceptionMessageUtf8Alloc(&state.active_runtime.?);
    defer state.active_runtime.?.allocator.free(swap_message);
    try std.testing.expectEqualStrings("Sparse array length exceeds safety limit", swap_message);
}

test "AOT配列ソート系は安定mergeとundefined末尾と同一配列を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 8;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createString(&.{0xe000});
    roots[1] = try runtime.createArray(&.{ roots[0], .{}, staticStringValue("😀"), staticStringValue("A") });
    const identity = roots[1].payload;
    try std.testing.expectEqual(identity, (try arrayOrderingBuiltin(&runtime, .array_sort, roots[1])).payload);
    const sorted = (try arrayItems(roots[1])).items;
    const first = try valueUtf16Alloc(&runtime, sorted[0]);
    defer runtime.allocator.free(first);
    try std.testing.expectEqualSlices(u16, &.{'A'}, first);
    const second = try valueUtf16Alloc(&runtime, sorted[1]);
    defer runtime.allocator.free(second);
    try std.testing.expectEqualSlices(u16, &.{ 0xd83d, 0xde00 }, second);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(sorted[3].tag)));

    roots[2] = try runtime.createBigInt("2n");
    roots[3] = try runtime.createArray(&.{ staticStringValue("10"), .{}, roots[2], numberValue(std.math.nan(f64)), numberValue(-0.0), numberValue(0.0) });
    try std.testing.expectEqual(roots[3].payload, (try arrayOrderingBuiltin(&runtime, .array_numeric_sort, roots[3])).payload);
    const numeric = (try arrayItems(roots[3])).items;
    try std.testing.expect(isNegativeZero(valueToNumber(numeric[0])));
    try std.testing.expect(!isNegativeZero(valueToNumber(numeric[1])));
    try std.testing.expectEqual(Tag.bigint, @as(Tag, @enumFromInt(numeric[2].tag)));
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt(numeric[3].tag)));
    try std.testing.expect(std.math.isNan(valueToNumber(numeric[4])));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(numeric[5].tag)));
    _ = try arrayOrderingBuiltin(&runtime, .array_numeric_convert, roots[3]);
    try std.testing.expectEqual(Tag.number, @as(Tag, @enumFromInt((try arrayItems(roots[3])).items[2].tag)));
    try std.testing.expect(std.math.isNan(valueToNumber((try arrayItems(roots[3])).items[5])));
    try std.testing.expectEqual(roots[3].payload, (try arrayOrderingBuiltin(&runtime, .array_reverse, roots[3])).payload);
    try std.testing.expect(std.math.isNan(valueToNumber((try arrayItems(roots[3])).items[0])));
}

test "AOT疎配列の順序操作は値とpresenceの公式境界を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .random_state = default_random_seed };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 5;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[0], numberValue(0), numberValue(3));
    try runtime.indexSet(roots[0], numberValue(2), numberValue(1));
    try runtime.indexSet(roots[0], numberValue(3), .{});
    _ = try arrayOrderingBuiltin(&runtime, .array_sort, roots[0]);
    const sorted = roots[0].object().?.array_presence.items;
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, sorted);
    try std.testing.expectEqual(@as(f64, 1), valueToNumber((try arrayItems(roots[0])).items[0]));
    try std.testing.expectEqual(@as(f64, 3), valueToNumber((try arrayItems(roots[0])).items[1]));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try arrayItems(roots[0])).items[2].tag)));

    roots[1] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[1], numberValue(0), numberValue(10));
    try runtime.indexSet(roots[1], numberValue(2), numberValue(2));
    try runtime.indexSet(roots[1], numberValue(3), .{});
    _ = try arrayOrderingBuiltin(&runtime, .array_numeric_sort, roots[1]);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, roots[1].object().?.array_presence.items);
    try std.testing.expectEqual(@as(f64, 2), valueToNumber((try arrayItems(roots[1])).items[0]));
    try std.testing.expectEqual(@as(f64, 10), valueToNumber((try arrayItems(roots[1])).items[1]));

    roots[2] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[2], numberValue(0), .{});
    try runtime.indexSet(roots[2], numberValue(2), numberValue(4));
    _ = try arrayOrderingBuiltin(&runtime, .array_numeric_convert, roots[2]);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, roots[2].object().?.array_presence.items);
    try std.testing.expect(std.math.isNan(valueToNumber((try arrayItems(roots[2])).items[0])));
    try std.testing.expect(std.math.isNan(valueToNumber((try arrayItems(roots[2])).items[1])));
    try std.testing.expectEqual(@as(f64, 4), valueToNumber((try arrayItems(roots[2])).items[2]));

    roots[3] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[3], numberValue(0), numberValue(1));
    try runtime.indexSet(roots[3], numberValue(2), numberValue(3));
    _ = try arrayOrderingBuiltin(&runtime, .array_reverse, roots[3]);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, roots[3].object().?.array_presence.items);
    try std.testing.expectEqual(@as(f64, 3), valueToNumber((try arrayItems(roots[3])).items[0]));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber((try arrayItems(roots[3])).items[2]));

    roots[4] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[4], numberValue(0), numberValue(1));
    try runtime.indexSet(roots[4], numberValue(2), numberValue(3));
    _ = try arrayOrderingBuiltin(&runtime, .array_shuffle, roots[4]);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, roots[4].object().?.array_presence.items);
}

test "AOT疎配列のsplice系操作は削除側と戻り値側のpresenceを移動する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 6;
    var frame: RootFrame = .{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[0], numberValue(0), numberValue(1));
    try runtime.indexSet(roots[0], numberValue(2), numberValue(3));
    _ = try arrayCutBuiltin(&runtime, roots[0], numberValue(1));
    try std.testing.expectEqualSlices(bool, &.{ true, true }, roots[0].object().?.array_presence.items);
    try std.testing.expectEqual(@as(f64, 3), valueToNumber((try arrayItems(roots[0])).items[1]));

    roots[1] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[1], numberValue(0), numberValue(1));
    try runtime.indexSet(roots[1], numberValue(2), numberValue(3));
    roots[2] = try arrayTakeBuiltin(&runtime, roots[1], numberValue(1), numberValue(2));
    try std.testing.expectEqualSlices(bool, &.{ false, true }, roots[2].object().?.array_presence.items);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try arrayItems(roots[2])).items[0].tag)));
    try std.testing.expectEqual(@as(f64, 3), valueToNumber((try arrayItems(roots[2])).items[1]));
    try std.testing.expectEqualSlices(bool, &.{true}, roots[1].object().?.array_presence.items);

    roots[3] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[3], numberValue(0), numberValue(1));
    try runtime.indexSet(roots[3], numberValue(2), numberValue(3));
    _ = try arrayInsertBuiltin(&runtime, roots[3], numberValue(1), numberValue(9));
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true }, roots[3].object().?.array_presence.items);

    roots[4] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[4], numberValue(0), numberValue(1));
    try runtime.indexSet(roots[4], numberValue(2), numberValue(3));
    roots[5] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[5], numberValue(1), numberValue(7));
    _ = try arrayInsertManyBuiltin(&runtime, roots[4], numberValue(1), roots[5]);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false, true }, roots[4].object().?.array_presence.items);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try arrayItems(roots[4])).items[1].tag)));
    try std.testing.expectEqual(@as(f64, 7), valueToNumber((try arrayItems(roots[4])).items[2]));
}

test "AOT疎配列の参照と配列足は穴のpresenceを保ち範囲コピーだけJSON化する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 8;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[0], numberValue(0), numberValue(1));
    try runtime.indexSet(roots[0], numberValue(2), numberValue(3));
    try runtime.indexSet(roots[0], numberValue(3), .{});
    roots[1] = try runtime.createDictionary(&.{ staticStringValue("先頭"), numberValue(0), staticStringValue("末尾"), numberValue(3) });

    roots[2] = try referenceBuiltin(&runtime, roots[0], roots[1]);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, true }, roots[2].object().?.array_presence.items);

    roots[3] = try arrayRangeCopyBuiltin(&runtime, roots[0], roots[1]);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, true }, roots[3].object().?.array_presence.items);
    try std.testing.expectEqual(Tag.null_value, @as(Tag, @enumFromInt((try arrayItems(roots[3])).items[1].tag)));
    try std.testing.expectEqual(Tag.null_value, @as(Tag, @enumFromInt((try arrayItems(roots[3])).items[3].tag)));

    roots[4] = try runtime.createArray(&.{ numberValue(4), numberValue(5) });
    roots[5] = try arrayAddBuiltin(&runtime, roots[0], roots[4]);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, true, true, true }, roots[5].object().?.array_presence.items);

    roots[6] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[6], numberValue(1), numberValue(7));
    roots[7] = try arrayAddBuiltin(&runtime, roots[0], roots[6]);
    try std.testing.expectEqualSlices(bool, &.{ true, false, true, true, false, true }, roots[7].object().?.array_presence.items);
}

test "AOT配列シャッフルはFisher-Yatesの置換と同一配列を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .random_state = default_random_seed };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try state.active_runtime.?.createArray(&.{ numberValue(1), numberValue(2), numberValue(3), numberValue(4) });
    const original = roots[0].payload;
    lnako_aot_builtin_call(&roots[1], @ptrCast(&roots[0]), 1, @intFromEnum(aot_builtin.Command.array_shuffle));
    try std.testing.expectEqual(original, roots[1].payload);
    try std.testing.expect(state.active_runtime.?.random_state != default_random_seed);

    var seen = [_]bool{false} ** 4;
    for ((try arrayItems(roots[0])).items) |item| {
        const number = valueToNumber(item);
        try std.testing.expect(number >= 1 and number <= 4 and @trunc(number) == number);
        const index: usize = @intFromFloat(number - 1);
        try std.testing.expect(!seen[index]);
        seen[index] = true;
    }
    for (seen) |present| try std.testing.expect(present);
}

test "AOT配列コールバックは関数値・名前解決と新配列規則を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{.{}} ** 11;
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try active.createNamedFunction(testAotDescending, 2, "module__降順", &.{});
    roots[1] = try active.createArray(&.{ numberValue(1), numberValue(3), numberValue(2) });
    var sort_arguments = [_]Value{ roots[0], roots[1] };
    roots[2] = try arrayCallbackBuiltin(active, .array_custom_sort, &sort_arguments);
    try std.testing.expectEqual(roots[1].payload, roots[2].payload);
    try std.testing.expectEqual(@as(f64, 3), valueToNumber((try arrayItems(roots[1])).items[0]));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber((try arrayItems(roots[1])).items[1]));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber((try arrayItems(roots[1])).items[2]));

    roots[3] = try active.createNamedFunction(testAotDouble, 1, "module__二倍", &.{});
    roots[4] = try active.createArray(&.{ numberValue(1), numberValue(2), numberValue(3) });
    var apply_arguments = [_]Value{ staticStringValue("二倍"), roots[4] };
    roots[5] = try arrayCallbackBuiltin(active, .array_function_apply, &apply_arguments);
    try std.testing.expect(roots[4].payload != roots[5].payload);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(2), numberValue(4), numberValue(6) }, (try arrayItems(roots[5])).items);

    roots[6] = try active.createArray(&.{ numberValue(4), numberValue(5) });
    var map_arguments = [_]Value{ roots[3], roots[6] };
    roots[7] = try arrayCallbackBuiltin(active, .array_map, &map_arguments);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(8), numberValue(10) }, (try arrayItems(roots[7])).items);

    roots[8] = try active.createNamedFunction(testAotEven, 1, "module__偶数判定関数", &.{});
    roots[9] = try active.createArray(&.{ numberValue(1), numberValue(2), numberValue(3), numberValue(4) });
    var filter_arguments = [_]Value{ staticStringValue("偶数判定関数"), roots[9] };
    roots[10] = try arrayCallbackBuiltin(active, .array_filter, &filter_arguments);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(2), numberValue(4) }, (try arrayItems(roots[10])).items);
}

test "AOTカスタムソートの小配列比較順はV8のrun検出規則を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{.{}} ** 4;
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);

    roots[0] = try active.createArray(&.{});
    roots[1] = try active.createFunction(testAotSortOrder, 2, &.{roots[0]});
    roots[2] = try active.createArray(&.{ numberValue(3), numberValue(1), numberValue(2) });
    var arguments = [_]Value{ roots[1], roots[2] };
    roots[3] = try arrayCallbackBuiltin(active, .array_custom_sort, &arguments);

    try std.testing.expectEqualSlices(Value, &.{ numberValue(13), numberValue(21), numberValue(23), numberValue(21) }, (try arrayItems(roots[0])).items);
    try std.testing.expectEqualSlices(Value, &.{ numberValue(1), numberValue(2), numberValue(3) }, (try arrayItems(roots[2])).items);
}

test "AOT同期実行は関数値・名前解決・AWAIT引数展開を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try state.active_runtime.?.createNamedFunction(testAotConstantSeven, 0, "main__七", &.{});
    roots[1] = try systemExecutionBuiltin(&state.active_runtime.?, .system_execute, &.{roots[0]});
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[1]));
    roots[2] = try systemExecutionBuiltin(&state.active_runtime.?, .system_execute, &.{staticStringValue("七")});
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[2]));
    roots[3] = try systemExecutionBuiltin(&state.active_runtime.?, .system_execute, &.{numberValue(9)});
    try std.testing.expectEqual(@as(f64, 9), valueToNumber(roots[3]));

    roots[4] = try state.active_runtime.?.createNamedFunction(testAotFunction, 1, "main__待機値", &.{});
    roots[5] = try state.active_runtime.?.createArray(&.{numberValue(4)});
    const awaited = try systemExecutionBuiltin(&state.active_runtime.?, .system_await_execute, &.{ roots[4], roots[5] });
    try std.testing.expectEqual(@as(f64, 4), valueToNumber(awaited));
}

test "AOT実行時間計測は関数名と単調時計を使う" {
    var runtime = Runtime{ .allocator = std.testing.allocator, .monotonic_milliseconds = 123.5 };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try state.active_runtime.?.createNamedFunction(testAotConstantSeven, 0, "main__七", &.{});
    roots[1] = try measureCallableBuiltin(&state.active_runtime.?, &.{staticStringValue("七")});
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(roots[1]));
    roots[2] = try measureCallableBuiltin(&state.active_runtime.?, &.{roots[0]});
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(roots[2]));
}

test "AOT圧縮解凍は内蔵ZIPとcallbackタスクを実行する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "日本語ABC" });
    const base = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(base);
    const source = try std.fs.path.join(std.testing.allocator, &.{ base, "source.txt" });
    defer std.testing.allocator.free(source);
    const archive = try std.fs.path.join(std.testing.allocator, &.{ base, "archive.zip" });
    defer std.testing.allocator.free(archive);
    const output = try std.fs.path.join(std.testing.allocator, &.{ base, "output" });
    defer std.testing.allocator.free(output);
    const callback_archive = try std.fs.path.join(std.testing.allocator, &.{ base, "callback.zip" });
    defer std.testing.allocator.free(callback_archive);
    const callback_output = try std.fs.path.join(std.testing.allocator, &.{ base, "callback-output" });
    defer std.testing.allocator.free(callback_output);

    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = staticStringValue("7z");
    roots[1] = try runtimeUtf8String(&state.active_runtime.?, source);
    roots[2] = try runtimeUtf8String(&state.active_runtime.?, archive);
    roots[3] = try runtimeUtf8String(&state.active_runtime.?, output);
    var direct_create = [_]Value{ roots[1], roots[2] };
    lnako_aot_archive_call(&roots[8], &roots[0], &direct_create, direct_create.len, @intFromEnum(aot_builtin.Command.node_archive_create), 1);
    try std.testing.expectEqual(Tag.boolean, @as(Tag, @enumFromInt(roots[8].tag)));
    try std.testing.expectEqual(@as(usize, 0), state.active_runtime.?.archive_tasks.items.len);

    var direct_extract = [_]Value{ roots[2], roots[3] };
    lnako_aot_archive_call(&roots[8], &roots[0], &direct_extract, direct_extract.len, @intFromEnum(aot_builtin.Command.node_archive_extract), 2);
    const extracted = try std.fs.path.join(std.testing.allocator, &.{ output, "source.txt" });
    defer std.testing.allocator.free(extracted);
    const extracted_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, extracted, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(extracted_bytes);
    try std.testing.expectEqualStrings("日本語ABC", extracted_bytes);

    roots[4] = try state.active_runtime.?.createBindingCell(numberValue(0));
    roots[5] = try state.active_runtime.?.createFunction(testAotCapturedIncrement, 0, &.{roots[4]});
    roots[6] = try runtimeUtf8String(&state.active_runtime.?, callback_archive);
    roots[7] = try runtimeUtf8String(&state.active_runtime.?, callback_output);
    var callback_create = [_]Value{ roots[5], roots[1], roots[6] };
    lnako_aot_archive_call(&roots[8], &roots[0], &callback_create, callback_create.len, @intFromEnum(aot_builtin.Command.node_archive_create_callback), 3);
    try std.testing.expectEqual(@as(usize, 1), state.active_runtime.?.archive_tasks.items.len);
    try drainAotEvents(&state.active_runtime.?);
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(roots[4].object().?.payload.binding_cell));

    var callback_extract = [_]Value{ roots[5], roots[6], roots[7] };
    lnako_aot_archive_call(&roots[8], &roots[0], &callback_extract, callback_extract.len, @intFromEnum(aot_builtin.Command.node_archive_extract_callback), 4);
    try drainAotEvents(&state.active_runtime.?);
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(roots[4].object().?.payload.binding_cell));
    const callback_extracted = try std.fs.path.join(std.testing.allocator, &.{ callback_output, "source.txt" });
    defer std.testing.allocator.free(callback_extracted);
    const callback_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, callback_extracted, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(callback_bytes);
    try std.testing.expectEqualStrings("日本語ABC", callback_bytes);
}

test "AOTハッシュ関数一覧取得は固定したNode互換名を配列で返す" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var result = Value{};
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, @ptrCast(&result), 1);
    defer lnako_aot_pop_roots(&frame);

    lnako_aot_builtin_call(&result, null, 0, @intFromEnum(aot_builtin.Command.node_hash_names));
    try std.testing.expectEqual(crypto.hash_names.len, result.object().?.payload.array.items.len);
    try expectUtf16String(&state.active_runtime.?, result.object().?.payload.array.items[0], crypto.hash_names[0]);
    try expectUtf16String(&state.active_runtime.?, result.object().?.payload.array.items[crypto.hash_names.len - 1], crypto.hash_names[crypto.hash_names.len - 1]);
}

test "AOT Node暗号はバイト値の型と境界を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try runtimeUtf8String(&state.active_runtime.?, "abc");
    roots[1] = try runtimeUtf8String(&state.active_runtime.?, "sha256");
    var hash_arguments = [_]Value{ roots[0], roots[1], .{} };
    roots[2] = try nodeCryptoBuiltin(&state.active_runtime.?, .node_hash_value, &hash_arguments);
    try std.testing.expectEqual(Tag.byte_buffer, @as(Tag, @enumFromInt(roots[2].tag)));
    try std.testing.expectEqual(ByteKind.buffer, roots[2].object().?.payload.byte_buffer.kind);
    const expected_digest = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    try std.testing.expectEqualSlices(u8, &expected_digest, roots[2].object().?.payload.byte_buffer.bytes);
    try std.testing.expectEqual(@as(f64, 186), valueToNumber(state.active_runtime.?.indexGet(roots[2], numberValue(0))));
    try std.testing.expectEqual(@as(f64, 173), valueToNumber(state.active_runtime.?.indexGet(roots[2], numberValue(31))));

    roots[3] = try jsonEncodeBuiltin(&state.active_runtime.?, roots[2], false);
    try expectUtf16String(&state.active_runtime.?, roots[3], "{\"type\":\"Buffer\",\"data\":[186,120,22,191,143,1,207,234,65,65,64,222,93,174,34,35,176,3,97,163,150,23,122,156,180,16,255,97,242,0,21,173]}");

    var random_arguments = [_]Value{numberValue(4)};
    roots[4] = try nodeCryptoBuiltin(&state.active_runtime.?, .node_random_array, &random_arguments);
    try std.testing.expectEqual(ByteKind.uint8_array, roots[4].object().?.payload.byte_buffer.kind);
    try std.testing.expectEqual(@as(usize, 4), roots[4].object().?.payload.byte_buffer.bytes.len);
    for (roots[4].object().?.payload.byte_buffer.bytes) |byte| try std.testing.expect(byte <= 255);
    try state.active_runtime.?.indexSet(roots[4], numberValue(0), numberValue(258.9));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(state.active_runtime.?.indexGet(roots[4], numberValue(0))));

    roots[5] = try nodeCryptoBuiltin(&state.active_runtime.?, .node_random_uuid, &.{});
    const uuid = try valueUtf16Alloc(&state.active_runtime.?, roots[5]);
    defer state.active_runtime.?.allocator.free(uuid);
    try std.testing.expectEqual(@as(usize, 36), uuid.len);
    try std.testing.expectEqual(@as(u16, '4'), uuid[14]);
    try std.testing.expect(uuid[19] == '8' or uuid[19] == '9' or uuid[19] == 'a' or uuid[19] == 'b');

    roots[6] = try state.active_runtime.?.createIterator(&.{roots[4]}, false, 0);
    var iterator_value = Value{};
    var iterator_key = Value{};
    _ = state.active_runtime.?.iteratorNext(roots[6], null, &iterator_value, &iterator_key, null);
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(iterator_key));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(iterator_value));

    roots[7] = try state.active_runtime.?.createArrayBuffer(&.{ 1, 2 });
    try std.testing.expectEqual(ByteKind.array_buffer, roots[7].object().?.payload.byte_buffer.kind);
    try expectUtf16String(&state.active_runtime.?, roots[7], "[object ArrayBuffer]");
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(state.active_runtime.?.indexGet(roots[7], numberValue(0)).tag)));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(state.active_runtime.?.indexGet(roots[7], staticStringValue("length")).tag)));
    var array_buffer_elements = try appendSearchElements(&state.active_runtime.?, roots[7]);
    defer array_buffer_elements.deinit();
    try std.testing.expectEqual(@as(usize, 0), array_buffer_elements.items.items.len);
    roots[8] = try jsonEncodeBuiltin(&state.active_runtime.?, roots[7], false);
    try expectUtf16String(&state.active_runtime.?, roots[8], "{}");
}

test "AOT圧縮解凍ツールパス変更は可変グローバルを更新する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try state.active_runtime.?.createString(&.{ '7', 'z' });
    var arguments = [_]Value{staticStringValue("native-tool")};
    lnako_aot_archive_tool_path_set(&roots[1], &arguments, arguments.len, &roots[0], 9);
    try expectUtf16String(&state.active_runtime.?, roots[0], "native-tool");
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[1].tag)));
}

test "AOT AJAXオプション設定は設定値をグローバルへ保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try state.active_runtime.?.createString(&.{});
    roots[1] = try runtimeUtf8String(&state.active_runtime.?, "{\"method\":\"PUT\",\"body\":\"payload\"}");
    roots[2] = try jsonDecodeBuiltin(&state.active_runtime.?, roots[1]);
    var arguments = [_]Value{roots[2]};
    lnako_aot_ajax_options_set(&roots[3], &arguments, arguments.len, &roots[0], 10);
    try std.testing.expectEqual(roots[2].payload, roots[0].payload);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[3].tag)));
}

test "AOT AJAX失敗時はコールバック値をグローバルへ保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    roots[0] = try state.active_runtime.?.createNamedFunction(testAotFunction, 1, "main__ajaxError", &.{});
    var arguments = [_]Value{roots[0]};
    lnako_aot_ajax_onerror_set(&roots[1], &arguments, arguments.len, &roots[2], 11);
    try std.testing.expectEqual(roots[0].payload, roots[2].payload);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[1].tag)));
}

test "AOT HTTP clientはrequest準備とResponse境界を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 8;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtimeUtf8String(&runtime, "{\"method\":\"PUT\",\"headers\":{\"X-Test\":\"yes\"},\"body\":\"payload\"}");
    roots[1] = try jsonDecodeBuiltin(&runtime, roots[0]);
    var ajax_request = try aotClientPrepareAjax(&runtime, &roots[1], staticStringValue("http://127.0.0.1/options"));
    defer ajax_request.deinit();
    try std.testing.expectEqualStrings("PUT", ajax_request.method);
    try std.testing.expectEqualStrings("http://127.0.0.1/options", ajax_request.url);
    try std.testing.expectEqualStrings("payload", ajax_request.body);
    try std.testing.expectEqual(@as(usize, 1), ajax_request.headers.items.len);
    try std.testing.expectEqualStrings("X-Test", ajax_request.headers.items[0].name);
    try std.testing.expectEqualStrings("yes", ajax_request.headers.items[0].value);

    roots[2] = try runtimeUtf8String(&runtime, "{\"a\":\"x y\",\"日本\":\"語\"}");
    roots[3] = try jsonDecodeBuiltin(&runtime, roots[2]);
    var form_request = try aotClientPreparePost(&runtime, staticStringValue("http://127.0.0.1/post"), roots[3], true, true);
    defer form_request.deinit();
    try std.testing.expect(std.mem.indexOf(u8, form_request.body, "name=\"日本\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, form_request.body, "語") != null);
    try std.testing.expectEqualStrings("multipart/form-data", form_request.headers.items[0].value);

    var result = AotClientHttpResult{ .body = try runtime.allocator.dupe(u8, "{\"ok\":true}"), .status = 200 };
    defer result.deinit(runtime.allocator);
    roots[4] = try aotClientHttpResponseValue(&runtime, result);
    try std.testing.expect(isAotHttpResponse(roots[4]));
    const response_text = try valueUtf8LossyAlloc(&runtime, roots[4]);
    defer runtime.allocator.free(response_text);
    try std.testing.expectEqualStrings("[object Response]", response_text);
    roots[5] = try jsonEncodeBuiltin(&runtime, roots[4], false);
    try expectUtf16String(&runtime, roots[5], "{}");
    roots[6] = try aotClientHttpResponseBody(roots[4]);
    try std.testing.expectEqualStrings("{\"ok\":true}", roots[6].object().?.payload.byte_buffer.bytes);
    try std.testing.expectEqual(@as(u16, 200), aotClientHttpResponseStatus(roots[4]));
    try std.testing.expectEqual(AotClientHttpBodyKind.text, (try aotClientHttpBodyKind(&runtime, staticStringValue("テキスト"))).?);
    try std.testing.expectEqual(AotClientHttpBodyKind.json, (try aotClientHttpBodyKind(&runtime, staticStringValue("JSON"))).?);
    try std.testing.expect((try aotClientHttpBodyKind(&runtime, staticStringValue("BODY"))) == null);
}

test "AOT表ソートは指定列を比較して同じ配列を安定ソートする" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    var roots = [_]Value{.{}} ** 10;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ staticStringValue("b"), numberValue(2) });
    roots[1] = try runtime.createArray(&.{ staticStringValue("a"), numberValue(10) });
    roots[2] = try runtime.createArray(&.{ staticStringValue("a"), numberValue(1) });
    roots[3] = try runtime.createArray(&.{ roots[0], roots[1], roots[2] });
    const sorted = try tableBuiltin(&runtime, .table_sort, &.{ roots[3], numberValue(0) });
    try std.testing.expectEqual(roots[3].payload, sorted.payload);
    const sorted_rows = (try arrayItems(roots[3])).items;
    try expectUtf16String(&runtime, try tableRowProperty(&runtime, sorted_rows[0], numberValue(0)), "a");
    try expectUtf16String(&runtime, try tableRowProperty(&runtime, sorted_rows[1], numberValue(0)), "a");
    try expectUtf16String(&runtime, try tableRowProperty(&runtime, sorted_rows[2], numberValue(0)), "b");
    try std.testing.expectEqual(roots[1].payload, sorted_rows[0].payload);
    try std.testing.expectEqual(roots[2].payload, sorted_rows[1].payload);

    roots[4] = try runtime.createArray(&.{ staticStringValue("x"), staticStringValue("10") });
    roots[5] = try runtime.createArray(&.{ staticStringValue("y"), staticStringValue("2") });
    roots[6] = try runtime.createArray(&.{ staticStringValue("z"), staticStringValue("30") });
    roots[7] = try runtime.createArray(&.{ roots[4], roots[5], roots[6] });
    const numeric = try tableBuiltin(&runtime, .table_numeric_sort, &.{ roots[7], numberValue(1) });
    try std.testing.expectEqual(roots[7].payload, numeric.payload);
    const numeric_rows = (try arrayItems(roots[7])).items;
    try expectUtf16String(&runtime, try tableRowProperty(&runtime, numeric_rows[0], numberValue(0)), "y");
    try expectUtf16String(&runtime, try tableRowProperty(&runtime, numeric_rows[1], numberValue(0)), "x");
    try expectUtf16String(&runtime, try tableRowProperty(&runtime, numeric_rows[2], numberValue(0)), "z");
}

test "AOT表ソートは最上位配列のholeと明示的undefinedをpresence順に保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 8;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{numberValue(2)});
    roots[1] = try runtime.createArray(&.{numberValue(1)});
    roots[2] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[2], numberValue(0), roots[0]);
    try runtime.indexSet(roots[2], numberValue(2), roots[1]);
    try runtime.indexSet(roots[2], numberValue(3), .{});
    _ = try tableBuiltin(&runtime, .table_sort, &.{ roots[2], numberValue(0) });
    try std.testing.expectEqual(roots[1].payload, (try arrayItems(roots[2])).items[0].payload);
    try std.testing.expectEqual(roots[0].payload, (try arrayItems(roots[2])).items[1].payload);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try arrayItems(roots[2])).items[2].tag)));
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, roots[2].object().?.array_presence.items);

    roots[3] = try runtime.createArray(&.{staticStringValue("10")});
    roots[4] = try runtime.createArray(&.{staticStringValue("2")});
    roots[5] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[5], numberValue(0), roots[3]);
    try runtime.indexSet(roots[5], numberValue(2), roots[4]);
    try runtime.indexSet(roots[5], numberValue(3), .{});
    _ = try tableBuiltin(&runtime, .table_numeric_sort, &.{ roots[5], numberValue(0) });
    try std.testing.expectEqual(roots[4].payload, (try arrayItems(roots[5])).items[0].payload);
    try std.testing.expectEqual(roots[3].payload, (try arrayItems(roots[5])).items[1].payload);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true, false }, roots[5].object().?.array_presence.items);
}

test "AOT表数値ソートはns-msのBigInt型境界を公式どおり拒否する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 8;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBigInt("1n");
    roots[1] = try runtime.createBigInt("2n");
    roots[2] = try runtime.createArray(&.{roots[0]});
    roots[3] = try runtime.createArray(&.{roots[1]});
    roots[4] = try runtime.createArray(&.{ roots[2], roots[3] });
    try std.testing.expectError(error.CannotConvertBigIntToNumber, tableBuiltin(&runtime, .table_numeric_sort, &.{ roots[4], numberValue(0) }));

    roots[5] = try runtime.createArray(&.{numberValue(2)});
    roots[6] = try runtime.createArray(&.{ roots[2], roots[5] });
    try std.testing.expectError(error.CannotMixBigIntAndNumber, tableBuiltin(&runtime, .table_numeric_sort, &.{ roots[6], numberValue(0) }));
}

test "AOT表列取得と表ピックアップは最上位のholeをArrayメソッドどおり扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 8;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ numberValue(2), numberValue(20) });
    roots[1] = try runtime.createArray(&.{numberValue(1)});
    roots[2] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[2], numberValue(0), roots[0]);
    try runtime.indexSet(roots[2], numberValue(2), roots[1]);

    roots[3] = try tableBuiltin(&runtime, .table_column, &.{ roots[2], numberValue(1) });
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, roots[3].object().?.array_presence.items);
    try std.testing.expectEqual(@as(f64, 20), valueToNumber(roots[3].object().?.payload.array.items[0]));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[3].object().?.payload.array.items[1].tag)));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[3].object().?.payload.array.items[2].tag)));

    roots[4] = try tableBuiltin(&runtime, .table_pickup, &.{ roots[2], numberValue(0), numberValue(1) });
    try std.testing.expectEqual(@as(usize, 1), roots[4].object().?.payload.array.items.len);
    try std.testing.expectEqual(roots[1].payload, roots[4].object().?.payload.array.items[0].payload);
    roots[5] = try tableBuiltin(&runtime, .table_exact_pickup, &.{ roots[2], numberValue(0), numberValue(2) });
    try std.testing.expectEqual(@as(usize, 1), roots[5].object().?.payload.array.items.len);
    try std.testing.expectEqual(roots[0].payload, roots[5].object().?.payload.array.items[0].payload);
}

test "AOT敬語命令は未定義初期値と礼節レベルを公式どおり処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    var roots = [_]Value{.{}} ** 7;
    var frame = RootFrame{};
    lnako_aot_push_roots(&frame, &roots, roots.len);
    defer lnako_aot_pop_roots(&frame);

    lnako_aot_builtin_call(&roots[0], null, 0, @intFromEnum(aot_builtin.Command.courtesy_end));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[0].tag)));
    lnako_aot_builtin_call(&roots[1], null, 0, @intFromEnum(aot_builtin.Command.courtesy_level));
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(roots[1]));

    lnako_aot_builtin_call(&roots[2], null, 0, @intFromEnum(aot_builtin.Command.courtesy_end));
    lnako_aot_builtin_call(&roots[3], null, 0, @intFromEnum(aot_builtin.Command.courtesy_level));
    try std.testing.expectEqual(@as(f64, 100), valueToNumber(roots[3]));

    lnako_aot_builtin_call(&roots[4], null, 0, @intFromEnum(aot_builtin.Command.courtesy_increment));
    lnako_aot_builtin_call(&roots[5], null, 0, @intFromEnum(aot_builtin.Command.courtesy_increment));
    lnako_aot_builtin_call(&roots[6], null, 0, @intFromEnum(aot_builtin.Command.courtesy_level));
    try std.testing.expectEqual(@as(f64, 102), valueToNumber(roots[6]));
}

test "AOT表検索系は行プロパティとraw開始値を公式どおり処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 24;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ staticStringValue("alice"), numberValue(10) });
    roots[1] = try runtime.createArray(&.{ staticStringValue("bob"), numberValue(20) });
    roots[2] = try runtime.createArray(&.{ roots[0], roots[1] });
    roots[3] = try runtime.createDictionary(&.{});
    roots[4] = try runtime.createString(&.{ 'a', 0xd83d, 0xde00 });
    roots[5] = try runtime.createString(&.{ 'l', 'e', 'n', 'g', 't', 'h' });
    roots[6] = try runtime.createString(&.{'3'});
    try roots[3].object().?.payload.dictionary.append(runtime.allocator, .{ .key = roots[5], .value = roots[6] });
    roots[9] = try runtime.createArray(&.{});
    roots[7] = try runtime.createArray(&.{ roots[9], roots[4], roots[3] });
    const columns = try tableBuiltin(&runtime, .table_column_count, roots[7..8]);
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast(columns.payload)));

    const picked = try tableBuiltin(&runtime, .table_pickup, &.{ roots[2], numberValue(0), staticStringValue("ali") });
    try std.testing.expectEqual(@as(usize, 1), picked.object().?.payload.array.items.len);
    try std.testing.expectEqual(roots[0].payload, picked.object().?.payload.array.items[0].payload);
    const exact = try tableBuiltin(&runtime, .table_exact_pickup, &.{ roots[2], numberValue(0), staticStringValue("alice") });
    try std.testing.expectEqual(@as(usize, 1), exact.object().?.payload.array.items.len);
    const found = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), numberValue(1), staticStringValue("bob") });
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(found.payload)));
    const not_found = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), .{}, staticStringValue("alice") });
    try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(not_found.payload)));
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), numberValue(-1), staticStringValue("alice") }));
    roots[8] = try runtime.createBigInt("1n");
    const bigint_found = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), roots[8], staticStringValue("bob") });
    try std.testing.expectEqual(Tag.bigint, @as(Tag, @enumFromInt(bigint_found.tag)));
    try std.testing.expectEqual(@as(i64, 1), bigint_found.object().?.payload.bigint.toI64());
    const string_found = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), staticStringValue("1"), staticStringValue("bob") });
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt(string_found.tag)));
    const incremented_found = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), staticStringValue("0"), staticStringValue("bob") });
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast(incremented_found.payload)));
    const object_start = try tableBuiltin(&runtime, .table_search, &.{ roots[2], numberValue(0), roots[3], staticStringValue("alice") });
    try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(object_start.payload)));
    roots[10] = try runtime.createArray(&.{.{}});
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_column, &.{ roots[10], numberValue(0) }));
    roots[11] = try runtime.createArray(&.{.{ .tag = @intFromEnum(Tag.null_value), .payload = 0 }});
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_column, &.{ roots[11], numberValue(0) }));
    roots[12] = try runtime.createDictionary(&.{ staticStringValue("length"), staticStringValue("7") });
    roots[13] = try runtime.createArray(&.{roots[12]});
    const text_columns = try tableBuiltin(&runtime, .table_column_count, roots[13..14]);
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt(text_columns.tag)));
    roots[14] = try runtime.createBigInt("2n");
    roots[15] = try runtime.createDictionary(&.{ staticStringValue("length"), roots[14] });
    roots[16] = try runtime.createArray(&.{roots[15]});
    const bigint_columns = try tableBuiltin(&runtime, .table_column_count, roots[16..17]);
    try std.testing.expectEqual(Tag.bigint, @as(Tag, @enumFromInt(bigint_columns.tag)));
    try std.testing.expectEqual(@as(i64, 2), bigint_columns.object().?.payload.bigint.toI64());
    roots[12] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(7) });
    roots[13] = try runtime.createDictionary(&.{});
    roots[13].object().?.prototype = roots[12];
    roots[14] = try runtime.createArray(&.{roots[13]});
    roots[15] = try tableBuiltin(&runtime, .table_column_count, roots[14..16]);
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[15]));
    roots[18] = try runtime.createBytes(&.{ 65, 66 });
    roots[19] = try runtime.createDictionary(&.{ staticStringValue("length"), numberValue(7) });
    try runtime.indexSet(roots[18], staticStringValue("__proto__"), roots[19]);
    try std.testing.expectEqual(roots[19].tag, roots[18].object().?.prototype.tag);
    try std.testing.expectEqual(roots[19].payload, roots[18].object().?.prototype.payload);
    roots[20] = try runtime.createArray(&.{roots[18]});
    roots[21] = try tableBuiltin(&runtime, .table_column_count, roots[20..22]);
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(runtime.indexGet(roots[18], staticStringValue("length"))));
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[21]));
    roots[17] = try runtime.createFunction(testAotFunction, 2, &.{});
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast((try tableRowProperty(&runtime, roots[17], staticStringValue("length"))).payload)));
    const function_name = try tableRowProperty(&runtime, roots[17], staticStringValue("name"));
    try expectUtf16String(&runtime, function_name, "");
}

test "AOT表行propertyはown値を優先して標準prototypeを解決する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 20;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{ staticStringValue("toString"), staticStringValue("own") });
    roots[1] = try runtime.createArray(&.{});
    roots[2] = try runtime.createString(&.{'x'});
    roots[3] = try runtime.createFunction(testAotFunction, 1, &.{});

    try expectUtf16String(&runtime, try tableRowProperty(&runtime, roots[0], staticStringValue("toString")), "own");
    roots[4] = try tableRowProperty(&runtime, roots[0], staticStringValue("constructor"));
    roots[5] = try tableRowProperty(&runtime, roots[4], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[5], "Object");
    roots[6] = try tableRowProperty(&runtime, roots[1], staticStringValue("map"));
    roots[7] = try tableRowProperty(&runtime, roots[6], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[7], "map");
    roots[8] = try tableRowProperty(&runtime, roots[2], staticStringValue("constructor"));
    roots[9] = try tableRowProperty(&runtime, roots[8], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[9], "String");
    roots[10] = try tableRowProperty(&runtime, roots[2], staticStringValue("toUpperCase"));
    roots[11] = try tableRowProperty(&runtime, roots[10], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[11], "toUpperCase");
    roots[12] = try tableRowProperty(&runtime, roots[3], staticStringValue("prototype"));
    try expectUtf16String(&runtime, try tableRowProperty(&runtime, roots[12], staticStringValue("toString")), "function toString() { [native code] }");
    roots[15] = try tableRowProperty(&runtime, roots[3], staticStringValue("prototype"));
    try std.testing.expect(try strictEqual(&runtime, roots[12], roots[15]));
    roots[16] = try tableRowProperty(&runtime, roots[12], staticStringValue("constructor"));
    try std.testing.expect(try strictEqual(&runtime, roots[3], roots[16]));
    roots[13] = try tableRowProperty(&runtime, roots[0], staticStringValue("__proto__"));
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[13].tag)));
    roots[14] = try tableRowProperty(&runtime, roots[1], staticStringValue("__proto__"));
    try std.testing.expectEqual(Tag.array, @as(Tag, @enumFromInt(roots[14].tag)));
}

test "AOT表列挿入削除合計は外側と行内部のholeをforEachとsliceどおり扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 12;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[0], numberValue(0), numberValue(1));
    try runtime.indexSet(roots[0], numberValue(2), numberValue(3));
    roots[1] = try runtime.createArray(&.{ numberValue(4), numberValue(5) });
    roots[2] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[2], numberValue(0), roots[0]);
    try runtime.indexSet(roots[2], numberValue(2), roots[1]);
    roots[3] = try runtime.createArray(&.{ numberValue(9), numberValue(8), numberValue(7) });
    roots[4] = try tableBuiltin(&runtime, .table_insert_column, &.{ roots[2], numberValue(1), roots[3] });
    try std.testing.expectEqual(@as(usize, 2), roots[4].object().?.payload.array.items.len);
    const inserted_row = roots[4].object().?.payload.array.items[0].object().?;
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true }, inserted_row.array_presence.items);
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(inserted_row.payload.array.items[0]));
    try std.testing.expectEqual(@as(f64, 9), valueToNumber(inserted_row.payload.array.items[1]));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(inserted_row.payload.array.items[2].tag)));
    try std.testing.expectEqual(@as(f64, 3), valueToNumber(inserted_row.payload.array.items[3]));
    try std.testing.expectEqual(@as(f64, 7), valueToNumber(roots[4].object().?.payload.array.items[1].object().?.payload.array.items[1]));

    roots[5] = try tableBuiltin(&runtime, .table_delete_column, &.{ roots[2], numberValue(1) });
    const deleted_row = roots[5].object().?.payload.array.items[0].object().?;
    try std.testing.expectEqualSlices(bool, &.{ true, true }, deleted_row.array_presence.items);
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(deleted_row.payload.array.items[0]));
    try std.testing.expectEqual(@as(f64, 3), valueToNumber(deleted_row.payload.array.items[1]));
    try std.testing.expectEqual(@as(f64, 4), valueToNumber(roots[5].object().?.payload.array.items[1].object().?.payload.array.items[0]));

    roots[6] = try tableBuiltin(&runtime, .table_column_sum, &.{ roots[2], numberValue(0) });
    try std.testing.expectEqual(@as(f64, 5), valueToNumber(roots[6]));
}

test "AOT表正規表現系はraw RegExpと浅いコピーを保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    var roots = [_]Value{.{}} ** 16;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ staticStringValue("alice"), staticStringValue("payload") });
    roots[1] = try runtime.createArray(&.{staticStringValue("bob")});
    roots[2] = try runtime.createArray(&.{ roots[0], roots[1] });
    const raw = staticStringValue("^ali");
    const found = try tableBuiltin(&runtime, .table_regexp_search, &.{ roots[2], numberValue(0), numberValue(0), raw });
    try std.testing.expectEqual(@as(f64, 0), @as(f64, @bitCast(found.payload)));
    const slash = try tableBuiltin(&runtime, .table_regexp_search, &.{ roots[2], numberValue(0), numberValue(0), staticStringValue("/^ali/i") });
    try std.testing.expectEqual(@as(f64, -1), @as(f64, @bitCast(slash.payload)));

    roots[3] = try runtime.createBigInt("1n");
    const bigint_found = try tableBuiltin(&runtime, .table_regexp_search, &.{ roots[2], roots[3], numberValue(0), staticStringValue("bob") });
    try std.testing.expectEqual(Tag.bigint, @as(Tag, @enumFromInt(bigint_found.tag)));
    try std.testing.expectEqual(@as(i64, 1), bigint_found.object().?.payload.bigint.toI64());

    roots[4] = try tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[2], numberValue(0), raw });
    try std.testing.expect(roots[4].object() != roots[2].object());
    try std.testing.expect(roots[4].object().?.payload.array.items[0].object() != roots[0].object());
    try std.testing.expectEqual(roots[0].object().?.payload.array.items[1].payload, roots[4].object().?.payload.array.items[0].object().?.payload.array.items[1].payload);

    roots[11] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[11], numberValue(0), staticStringValue("alice"));
    try runtime.indexSet(roots[11], numberValue(2), staticStringValue("tail"));
    roots[12] = try runtime.createArray(&.{roots[11]});
    roots[13] = try tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[12], numberValue(0), raw });
    const sparse_inner_row = roots[13].object().?.payload.array.items[0].object().?;
    try std.testing.expectEqualSlices(bool, &.{ true, false, true }, sparse_inner_row.array_presence.items);

    roots[7] = try tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[2], numberValue(0), .{} });
    try std.testing.expectEqual(@as(usize, 2), roots[7].object().?.payload.array.items.len);
    roots[8] = try runtime.createArray(&.{staticStringValue("alice")});
    roots[9] = try tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[8], numberValue(0), staticStringValue("^a") });
    try std.testing.expectEqual(Tag.static_utf8_string, @as(Tag, @enumFromInt(roots[9].object().?.payload.array.items[0].tag)));

    roots[5] = try runtime.createArray(&.{.{ .tag = @intFromEnum(Tag.null_value), .payload = 0 }});
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_regexp_search, &.{ roots[5], numberValue(0), numberValue(0), raw }));
    const null_search_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(null_search_message);
    try std.testing.expectEqualStrings("Cannot read properties of null (reading '0')", null_search_message);
    _ = runtime.takeException();
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[5], numberValue(0), raw }));
    const null_pickup_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(null_pickup_message);
    try std.testing.expectEqualStrings("Cannot read properties of null (reading '0')", null_pickup_message);
    _ = runtime.takeException();
    roots[10] = try runtime.createArray(&.{});
    try runtime.indexSet(roots[10], numberValue(0), roots[0]);
    try runtime.indexSet(roots[10], numberValue(2), roots[1]);
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_regexp_search, &.{ roots[10], numberValue(0), numberValue(0), staticStringValue("^bob") }));
    const sparse_search_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(sparse_search_message);
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading '0')", sparse_search_message);
    _ = runtime.takeException();
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[10], numberValue(0), raw }));
    const sparse_pickup_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(sparse_pickup_message);
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading '0')", sparse_pickup_message);
    _ = runtime.takeException();
    roots[6] = try runtime.createArray(&.{});
    try std.testing.expectError(error.UnclosedCharacterClass, tableBuiltin(&runtime, .table_regexp_search, &.{ roots[6], numberValue(0), numberValue(0), staticStringValue("[") }));
    const search_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(search_message);
    try std.testing.expectEqualStrings("Invalid regular expression: /[/: Unterminated character class", search_message);
    _ = runtime.takeException();
    try std.testing.expectError(error.UnclosedCharacterClass, tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[6], numberValue(0), staticStringValue("[") }));
    const pickup_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(pickup_message);
    try std.testing.expectEqualStrings("Invalid regular expression: /[/: Unterminated character class", pickup_message);
    _ = runtime.takeException();
}

test "AOT表正規表現ピックアップはBufferのsliceを共有する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    var roots = [_]Value{.{}} ** 8;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes(&.{ 85, 66 });
    roots[1] = try runtime.createArray(&.{roots[0]});
    roots[2] = try tableBuiltin(&runtime, .table_regexp_pickup, &.{ roots[1], numberValue(0), staticStringValue("^85") });
    try runtime.indexSet(roots[0], numberValue(0), numberValue(7));
    const picked_row = roots[2].object().?.payload.array.items[0];
    try std.testing.expectEqual(@as(u8, 7), picked_row.object().?.payload.byte_buffer.bytes[0]);
}

test "AOT表列挿入はbyte bufferの種類とslice内容を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 8;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes(&.{ 0x41, 0x42, 0x43 });
    roots[1] = try runtime.createArray(&.{roots[0]});
    roots[2] = try runtime.createArray(&.{numberValue(9)});
    roots[3] = try tableBuiltin(&runtime, .table_insert_column, &.{ roots[1], numberValue(1), roots[2] });
    const row = roots[3].object().?.payload.array.items[0].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 3), row.len);
    try std.testing.expectEqual(ByteKind.buffer, row[0].object().?.payload.byte_buffer.kind);
    try std.testing.expectEqualSlices(u8, &.{0x41}, row[0].object().?.payload.byte_buffer.bytes);
    try std.testing.expectEqual(@as(f64, 9), valueToNumber(row[1]));
    try std.testing.expectEqualSlices(u8, &.{ 0x42, 0x43 }, row[2].object().?.payload.byte_buffer.bytes);
}

test "AOT表列挿入はBufferのsliceだけを共有しTypedArrayのsliceを複製する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 10;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes(&.{ 1, 2, 3 });
    roots[1] = try runtime.createArray(&.{roots[0]});
    roots[2] = try runtime.createArray(&.{numberValue(9)});
    roots[3] = try tableBuiltin(&runtime, .table_insert_column, &.{ roots[1], numberValue(1), roots[2] });
    const inserted_row = roots[3].object().?.payload.array.items[0].object().?.payload.array.items;
    try runtime.indexSet(roots[0], numberValue(0), numberValue(7));
    try runtime.indexSet(roots[0], numberValue(1), numberValue(8));
    try std.testing.expectEqual(@as(u8, 7), inserted_row[0].object().?.payload.byte_buffer.bytes[0]);
    try std.testing.expectEqual(@as(u8, 8), inserted_row[2].object().?.payload.byte_buffer.bytes[0]);

    roots[4] = try runtime.createUint8Array(&.{ 4, 5 });
    roots[5] = try aotByteBufferSlice(&runtime, roots[4].object().?.payload.byte_buffer, 0, 1);
    try runtime.indexSet(roots[4], numberValue(0), numberValue(6));
    try std.testing.expectEqual(@as(u8, 4), roots[5].object().?.payload.byte_buffer.bytes[0]);

    roots[6] = try runtime.createArrayBuffer(&.{ 10, 11 });
    roots[7] = try aotByteBufferSlice(&runtime, roots[6].object().?.payload.byte_buffer, 0, 1);
    try runtime.indexSet(roots[6], numberValue(0), numberValue(12));
    try std.testing.expectEqual(@as(u8, 10), roots[7].object().?.payload.byte_buffer.bytes[0]);
}

test "AOT表命令はbyte bufferのlengthと数値添字を読む" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 10;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes(&.{ 65, 66 });
    roots[1] = try runtime.createUint8Array(&.{67});
    roots[2] = try runtime.createArrayBuffer(&.{ 68, 69 });
    roots[3] = try runtime.createArray(&.{ roots[0], roots[1], roots[2] });
    roots[4] = try tableBuiltin(&runtime, .table_column_count, &.{roots[3]});
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(roots[4]));

    roots[5] = try tableBuiltin(&runtime, .table_column, &.{ roots[3], numberValue(0) });
    const column = roots[5].object().?.payload.array.items;
    try std.testing.expectEqual(@as(f64, 65), valueToNumber(column[0]));
    try std.testing.expectEqual(@as(f64, 67), valueToNumber(column[1]));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(column[2].tag)));

    roots[6] = try tableBuiltin(&runtime, .table_pickup, &.{ roots[3], numberValue(0), numberValue(65) });
    try std.testing.expectEqual(@as(usize, 1), roots[6].object().?.payload.array.items.len);
    roots[7] = try tableBuiltin(&runtime, .table_exact_pickup, &.{ roots[3], numberValue(0), numberValue(67) });
    try std.testing.expectEqual(@as(usize, 1), roots[7].object().?.payload.array.items.len);
    roots[8] = try tableBuiltin(&runtime, .table_search, &.{ roots[3], numberValue(0), numberValue(0), numberValue(65) });
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(roots[8]));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try tableRowProperty(&runtime, roots[2], staticStringValue("length"))).tag)));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try tableRowProperty(&runtime, roots[2], numberValue(0))).tag)));
}

test "AOT byte bufferのprototype属性とscalar propertyを解決する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    var roots = [_]Value{.{}} ** 32;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes(&.{ 85, 66 });
    roots[1] = try runtime.createUint8Array(&.{ 85, 66 });
    roots[2] = try runtime.createArrayBuffer(&.{ 85, 66 });
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(runtime.indexGet(roots[0], staticStringValue("byteLength"))));
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(runtime.indexGet(roots[0], staticStringValue("byteOffset"))));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(runtime.indexGet(roots[0], staticStringValue("BYTES_PER_ELEMENT"))));
    roots[17] = runtime.indexGet(roots[0], staticStringValue("buffer"));
    try std.testing.expectEqual(Tag.byte_buffer, @as(Tag, @enumFromInt(roots[17].tag)));
    try std.testing.expectEqual(ByteKind.array_buffer, roots[17].object().?.payload.byte_buffer.kind);
    try std.testing.expectEqual(@as(usize, 2), roots[17].object().?.payload.byte_buffer.bytes.len);
    roots[27] = try aotByteBufferSlice(&runtime, roots[0].object().?.payload.byte_buffer, 0, 2);
    roots[28] = runtime.indexGet(roots[27], staticStringValue("buffer"));
    try std.testing.expectEqual(roots[17].payload, roots[28].payload);
    try runtime.indexSet(roots[0], numberValue(0), numberValue(9));
    try std.testing.expectEqual(@as(f64, 9), valueToNumber(runtime.indexGet(roots[27], numberValue(0))));
    try runtime.indexSet(roots[27], numberValue(0), numberValue(8));
    try std.testing.expectEqual(@as(f64, 8), valueToNumber(runtime.indexGet(roots[0], numberValue(0))));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(runtime.indexGet(roots[17], staticStringValue("byteLength"))));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(runtime.indexGet(roots[2], staticStringValue("byteLength"))));
    try std.testing.expectEqual(@as(f64, 2), valueToNumber(runtime.indexGet(roots[2], staticStringValue("maxByteLength"))));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(runtime.indexGet(roots[2], staticStringValue("length")).tag)));

    roots[3] = try tableRowProperty(&runtime, roots[0], staticStringValue("constructor"));
    roots[4] = try tableRowProperty(&runtime, roots[3], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[4], "Buffer");
    roots[5] = try tableRowProperty(&runtime, roots[0], staticStringValue("subarray"));
    roots[6] = try tableRowProperty(&runtime, roots[5], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[6], "subarray");
    roots[7] = try tableRowProperty(&runtime, roots[0], staticStringValue("toLocaleString"));
    roots[8] = try tableRowProperty(&runtime, roots[7], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[8], "toString");

    roots[9] = try tableRowProperty(&runtime, roots[1], staticStringValue("constructor"));
    roots[10] = try tableRowProperty(&runtime, roots[9], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[10], "Uint8Array");
    roots[11] = try tableRowProperty(&runtime, roots[1], staticStringValue("map"));
    roots[12] = try tableRowProperty(&runtime, roots[11], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[12], "map");
    roots[18] = try tableRowProperty(&runtime, roots[0], staticStringValue("buffer"));
    try std.testing.expectEqual(Tag.byte_buffer, @as(Tag, @enumFromInt(roots[18].tag)));
    try std.testing.expectEqual(ByteKind.array_buffer, roots[18].object().?.payload.byte_buffer.kind);
    try std.testing.expectEqual(@as(usize, 2), roots[18].object().?.payload.byte_buffer.bytes.len);
    roots[19] = runtime.indexGet(roots[1], staticStringValue("buffer"));
    try std.testing.expectEqual(Tag.byte_buffer, @as(Tag, @enumFromInt(roots[19].tag)));
    try std.testing.expectEqual(ByteKind.array_buffer, roots[19].object().?.payload.byte_buffer.kind);
    try std.testing.expectEqual(@as(usize, 2), roots[19].object().?.payload.byte_buffer.bytes.len);
    roots[29] = runtime.indexGet(roots[1], staticStringValue("buffer"));
    try std.testing.expectEqual(roots[19].payload, roots[29].payload);

    roots[13] = try tableRowProperty(&runtime, roots[2], staticStringValue("constructor"));
    roots[14] = try tableRowProperty(&runtime, roots[13], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[14], "ArrayBuffer");
    roots[15] = try tableRowProperty(&runtime, roots[2], staticStringValue("slice"));
    roots[16] = try tableRowProperty(&runtime, roots[15], staticStringValue("name"));
    try expectUtf16String(&runtime, roots[16], "slice");
    try std.testing.expectEqual(Tag.boolean, @as(Tag, @enumFromInt(runtime.indexGet(roots[2], staticStringValue("resizable")).tag)));
    try std.testing.expect(runtime.indexGet(roots[2], staticStringValue("resizable")).payload == 0);
    try std.testing.expectEqual(Tag.boolean, @as(Tag, @enumFromInt(runtime.indexGet(roots[2], staticStringValue("detached")).tag)));
    try std.testing.expect(runtime.indexGet(roots[2], staticStringValue("detached")).payload == 0);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(runtime.indexGet(roots[2], staticStringValue("buffer")).tag)));

    roots[20] = runtime.indexGet(roots[0], staticStringValue("readUInt8"));
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[20].tag)));
    try std.testing.expectEqualStrings("", roots[20].object().?.payload.function.name);
    roots[21] = runtime.indexGet(roots[0], staticStringValue("parent"));
    try std.testing.expectEqual(Tag.byte_buffer, @as(Tag, @enumFromInt(roots[21].tag)));
    try std.testing.expectEqual(ByteKind.array_buffer, roots[21].object().?.payload.byte_buffer.kind);
    try std.testing.expectEqual(@as(usize, 2), roots[21].object().?.payload.byte_buffer.bytes.len);
    roots[22] = runtime.indexGet(roots[0], staticStringValue("offset"));
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(roots[22]));
    roots[23] = runtime.indexGet(roots[0], staticStringValue("toLocaleString"));
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[23].tag)));
    try std.testing.expectEqualStrings("toString", roots[23].object().?.payload.function.name);
    roots[24] = runtime.indexGet(roots[1], staticStringValue("map"));
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[24].tag)));
    try std.testing.expectEqualStrings("map", roots[24].object().?.payload.function.name);
    roots[25] = runtime.indexGet(roots[2], staticStringValue("slice"));
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(roots[25].tag)));
    try std.testing.expectEqualStrings("slice", roots[25].object().?.payload.function.name);
    roots[26] = runtime.indexGet(roots[0], staticStringValue("missing"));
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(roots[26].tag)));
}

test "AOT Bufferの空viewもbacking storageからのbyteOffsetを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 5;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes(&.{ 1, 2, 3, 4 });
    roots[1] = try aotByteBufferSlice(&runtime, roots[0].object().?.payload.byte_buffer, 1, 3);
    roots[2] = try aotByteBufferSlice(&runtime, roots[1].object().?.payload.byte_buffer, 2, 2);
    roots[3] = runtime.indexGet(roots[2], staticStringValue("byteOffset"));
    roots[4] = try tableRowProperty(&runtime, roots[2], staticStringValue("offset"));
    try std.testing.expectEqual(@as(f64, 0), valueToNumber(runtime.indexGet(roots[2], staticStringValue("byteLength"))));
    try std.testing.expectEqual(@as(f64, 3), valueToNumber(roots[3]));
    try std.testing.expectEqual(@as(f64, 3), valueToNumber(roots[4]));
}

test "AOT byte bufferから抽出したslice関数は未束縛エラーを再現する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    state.active_runtime = runtime;
    defer {
        runtime = state.active_runtime.?;
        state.active_runtime = null;
    }
    const active = &state.active_runtime.?;
    var roots = [_]Value{.{}} ** 3;
    var frame = RootFrame{};
    active.pushRoots(&frame, &roots, roots.len);
    defer active.popRoots(&frame);

    roots[0] = try active.createBytes(&.{ 1, 2, 3, 4 });
    roots[1] = active.indexGet(roots[0], staticStringValue("slice"));
    var slice_arguments = [_]Value{ numberValue(0), numberValue(2) };
    lnako_aot_function_call(&roots[2], &roots[1], @ptrCast(&slice_arguments), slice_arguments.len);
    try std.testing.expect(active.has_pending_exception);
    const message = try pendingExceptionMessageUtf8Alloc(active);
    _ = active.takeException();
    defer active.allocator.free(message);
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading 'subarray')", message);
}

test "AOT表変換系は欠損列・負位置・JS加算を公式どおり処理する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 18;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createArray(&.{ numberValue(1), numberValue(2), numberValue(3) });
    roots[1] = try runtime.createArray(&.{ numberValue(4), numberValue(5), numberValue(6) });
    roots[2] = try runtime.createArray(&.{ roots[0], roots[1] });
    roots[3] = try tableBuiltin(&runtime, .table_transpose, &.{roots[2]});
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast((try arrayItems(roots[3])).items[0].object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast((try arrayItems(roots[3])).items[0].object().?.payload.array.items[1].payload)));
    roots[4] = try tableBuiltin(&runtime, .table_rotate, &.{roots[2]});
    try std.testing.expectEqual(@as(f64, 4), @as(f64, @bitCast((try arrayItems(roots[4])).items[0].object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast((try arrayItems(roots[4])).items[0].object().?.payload.array.items[1].payload)));

    roots[5] = try runtime.createArray(&.{ staticStringValue("a"), numberValue(1) });
    roots[6] = try runtime.createArray(&.{ staticStringValue("a"), numberValue(2) });
    roots[7] = try runtime.createArray(&.{ staticStringValue("b"), numberValue(3) });
    roots[8] = try runtime.createArray(&.{ roots[5], roots[6], roots[7] });
    roots[9] = try tableBuiltin(&runtime, .table_unique, &.{ roots[8], numberValue(0) });
    try std.testing.expectEqual(@as(usize, 2), (try arrayItems(roots[9])).items.len);
    try std.testing.expectEqual(roots[5].payload, (try arrayItems(roots[9])).items[0].payload);

    roots[10] = try tableBuiltin(&runtime, .table_insert_column, &.{ roots[2], numberValue(-1), roots[0] });
    try std.testing.expectEqual(@as(usize, 2), (try arrayItems(roots[10])).items[0].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 1), @as(f64, @bitCast((try arrayItems(roots[10])).items[0].object().?.payload.array.items[0].payload)));
    try std.testing.expectEqual(@as(f64, 3), @as(f64, @bitCast((try arrayItems(roots[10])).items[0].object().?.payload.array.items[1].payload)));
    roots[11] = try tableBuiltin(&runtime, .table_delete_column, &.{ roots[2], numberValue(-1) });
    try std.testing.expectEqual(@as(usize, 2), (try arrayItems(roots[11])).items[0].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast((try arrayItems(roots[11])).items[0].object().?.payload.array.items[1].payload)));

    roots[12] = try tableBuiltin(&runtime, .table_column_sum, &.{ roots[2], numberValue(1) });
    try std.testing.expectEqual(@as(f64, 7), @as(f64, @bitCast(roots[12].payload)));
    roots[13] = try runtime.createArray(&.{ staticStringValue("x"), numberValue(1) });
    roots[14] = try runtime.createArray(&.{ staticStringValue("y"), numberValue(2) });
    roots[15] = try runtime.createArray(&.{ roots[13], roots[14] });
    roots[16] = try tableBuiltin(&runtime, .table_column_sum, &.{ roots[15], numberValue(0) });
    const sum_text = try valueUtf16Alloc(&runtime, roots[16]);
    defer runtime.allocator.free(sum_text);
    try std.testing.expectEqualSlices(u16, &.{ '0', 'x', 'y' }, sum_text);

    roots[2] = try runtime.createArray(&.{ roots[13], .{}, roots[14] });
    _ = try runtime.aotArrayDeleteIndex(roots[2].object().?, 1);
    try std.testing.expectError(error.TableRowMissing, tableBuiltin(&runtime, .table_unique, &.{ roots[2], numberValue(0) }));
    const sparse_unique_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(sparse_unique_message);
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading '0')", sparse_unique_message);
    _ = runtime.takeException();
}

test "AOT一般正規表現命令は共有エンジンと抽出副作用を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    runtime.next_collection = 1;
    var roots = [_]Value{.{}} ** 12;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const all = try regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("aa,bb,cc"), staticStringValue("[a-z]+") });
    roots[0] = all.value;
    roots[1] = all.captures.?;
    try std.testing.expectEqual(@as(usize, 3), roots[0].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), roots[1].object().?.payload.array.items.len);

    const one = try regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("12-34"), staticStringValue("/([0-9]+)/") });
    roots[2] = one.value;
    roots[3] = one.captures.?;
    try std.testing.expectEqualSlices(u16, &.{ '1', '2' }, roots[2].object().?.payload.utf16_string);
    try std.testing.expectEqual(@as(usize, 1), roots[3].object().?.payload.array.items.len);

    const extracted = try regexpBuiltin(&runtime, .regexp_extract, &.{ staticStringValue("a1 b2"), staticStringValue("/(?<letter>[a-z])([0-9])/g") });
    roots[4] = extracted.value;
    roots[5] = extracted.captures.?;
    try std.testing.expectEqual(@as(usize, 2), roots[4].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), roots[5].object().?.payload.array.items.len);
    try std.testing.expectEqual(Tag.dictionary, @as(Tag, @enumFromInt(roots[5].object().?.payload.array.items[0].tag)));

    const replaced = try regexpBuiltin(&runtime, .regexp_replace, &.{ staticStringValue("aa,bb"), staticStringValue("/[a-z]+/g"), staticStringValue("<$&>") });
    roots[6] = replaced.value;
    const replaced_units = try valueUtf16Alloc(&runtime, roots[6]);
    defer runtime.allocator.free(replaced_units);
    try std.testing.expectEqualSlices(u16, &.{ '<', 'a', 'a', '>', ',', '<', 'b', 'b', '>' }, replaced_units);

    const split = try regexpBuiltin(&runtime, .regexp_split, &.{ staticStringValue("a,b"), staticStringValue("/(,)/") });
    roots[7] = split.value;
    try std.testing.expectEqual(@as(usize, 3), roots[7].object().?.payload.array.items.len);

    try std.testing.expectError(error.UnclosedCharacterClass, regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("x"), staticStringValue("[") }));
    const invalid_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(invalid_message);
    try std.testing.expectEqualStrings("Invalid regular expression: /[/g: Unterminated character class", invalid_message);
    _ = runtime.takeException();

    roots[8] = try runtime.createString(&.{1});
    const control = try regexpBuiltin(&runtime, .regexp_match, &.{ roots[8], staticStringValue("/\\cA/u") });
    roots[9] = control.value;
    try std.testing.expectEqualSlices(u16, &.{1}, roots[9].object().?.payload.utf16_string);

    roots[10] = try runtime.createString(&.{0xd800});
    const lone_surrogate = try regexpBuiltin(&runtime, .regexp_match, &.{ roots[10], staticStringValue("/\\u{D800}/u") });
    roots[11] = lone_surrogate.value;
    try std.testing.expectEqualSlices(u16, &.{0xd800}, roots[11].object().?.payload.utf16_string);

    try std.testing.expectError(error.InvalidUnicodeEscape, regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("x"), staticStringValue("/\\c1/u") }));
    const invalid_control_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(invalid_control_message);
    try std.testing.expectEqualStrings("Invalid regular expression: /\\c1/u: Invalid Unicode escape", invalid_control_message);
    _ = runtime.takeException();

    try std.testing.expectError(error.InvalidBackreference, regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("x"), staticStringValue("/\\1/u") }));
    const invalid_backreference_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(invalid_backreference_message);
    try std.testing.expectEqualStrings("Invalid regular expression: /\\1/u: Invalid escape", invalid_backreference_message);
    _ = runtime.takeException();

    try std.testing.expectError(error.InvalidDecimalEscape, regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("x"), staticStringValue("/[\\1]/u") }));
    const invalid_decimal_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(invalid_decimal_message);
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\1]/u: Invalid decimal escape", invalid_decimal_message);
    _ = runtime.takeException();

    try std.testing.expectError(error.InvalidCharacterClass, regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("x"), staticStringValue("/[\\d-a]/u") }));
    const invalid_class_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(invalid_class_message);
    try std.testing.expectEqualStrings("Invalid regular expression: /[\\d-a]/u: Invalid character class", invalid_class_message);
    _ = runtime.takeException();

    roots[8] = try runtime.createString(&.{ 'f', 'o', 'o', '-', 'f', 'o', 'o' });
    const named = try regexpBuiltin(&runtime, .regexp_match, &.{ roots[8], staticStringValue("/(?<word>[a-z]+)-\\k<word>/u") });
    roots[9] = named.value;
    try std.testing.expectEqualSlices(u16, roots[8].object().?.payload.utf16_string, roots[9].object().?.payload.utf16_string);

    roots[10] = try runtime.createString(&.{'y'});
    const optional = try regexpBuiltin(&runtime, .regexp_match, &.{ roots[10], staticStringValue("/(?<optional>x)?\\k<optional>/u") });
    roots[11] = optional.value;
    try std.testing.expectEqual(@as(usize, 0), roots[11].object().?.payload.utf16_string.len);

    try std.testing.expectError(error.InvalidNamedBackreference, regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("x"), staticStringValue("/(?<a>a)\\k<b>/u") }));
    const invalid_named_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(invalid_named_message);
    try std.testing.expectEqualStrings("Invalid regular expression: /(?<a>a)\\k<b>/u: Invalid named capture referenced", invalid_named_message);
    _ = runtime.takeException();

    try std.testing.expectError(error.InvalidNamedReference, regexpBuiltin(&runtime, .regexp_match, &.{ staticStringValue("x"), staticStringValue("/\\k/u") }));
    const malformed_named_message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(malformed_named_message);
    try std.testing.expectEqualStrings("Invalid regular expression: /\\k/u: Invalid named reference", malformed_named_message);
    _ = runtime.takeException();
}

test "AOT JSONエンコードはcompact prettyとECMAScript境界を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 20;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try jsonEncodeBuiltin(&runtime, .{}, false)).tag)));
    roots[0] = try runtime.createFunction(testAotFunction, 1, &.{});
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt((try jsonEncodeBuiltin(&runtime, roots[0], false)).tag)));

    roots[1] = try runtime.createArray(&.{ .{}, roots[0], .{ .tag = @intFromEnum(Tag.null_value) }, numberValue(std.math.nan(f64)) });
    try expectJsonAotString(&runtime, roots[1], false, "[null,null,null,null]");

    roots[2] = try runtime.createDictionary(&.{
        staticStringValue("undefined"), .{},
        staticStringValue("function"),  roots[0],
        staticStringValue("present"),   numberValue(1),
    });
    try expectJsonAotString(&runtime, roots[2], false, "{\"present\":1}");
    try expectJsonAotString(&runtime, roots[2], true, "{\n  \"present\": 1\n}");

    roots[3] = try runtime.createArray(&.{numberValue(7)});
    roots[4] = try runtime.createArray(&.{ roots[3], roots[3] });
    try expectJsonAotString(&runtime, roots[4], false, "[[7],[7]]");

    roots[5] = try runtime.createDictionary(&.{
        staticStringValue("2"),          staticStringValue("b"),
        staticStringValue("1"),          staticStringValue("a"),
        staticStringValue("x"),          staticStringValue("c"),
        staticStringValue("01"),         staticStringValue("d"),
        staticStringValue("4294967294"), staticStringValue("f"),
        staticStringValue("0"),          staticStringValue("z"),
    });
    try expectJsonAotString(&runtime, roots[5], false, "{\"0\":\"z\",\"1\":\"a\",\"2\":\"b\",\"4294967294\":\"f\",\"x\":\"c\",\"01\":\"d\"}");
    try expectJsonAotString(&runtime, roots[5], true, "{\n  \"0\": \"z\",\n  \"1\": \"a\",\n  \"2\": \"b\",\n  \"4294967294\": \"f\",\n  \"x\": \"c\",\n  \"01\": \"d\"\n}");
    roots[10] = try runtime.createDictionary(&.{ numberValue(1), staticStringValue("number"), staticStringValue("1"), staticStringValue("string"), staticStringValue("2"), staticStringValue("two") });
    try expectJsonAotString(&runtime, roots[10], false, "{\"1\":\"string\",\"2\":\"two\"}");

    roots[6] = try runtime.createString(&.{0xd800});
    try expectJsonAotString(&runtime, roots[6], false, "\"\\ud800\"");
    roots[7] = try runtime.createArray(&.{ numberValue(-0.0), numberValue(1e21), numberValue(1e-6), numberValue(1e-7) });
    try expectJsonAotString(&runtime, roots[7], false, "[0,1e+21,0.000001,1e-7]");

    roots[8] = try runtime.createBigInt("1n");
    try std.testing.expectError(error.CannotSerializeBigInt, jsonEncodeBuiltin(&runtime, roots[8], false));
    roots[9] = try runtime.createArray(&.{});
    try roots[9].object().?.payload.array.append(runtime.allocator, roots[9]);
    try std.testing.expectError(error.CircularCloneValue, jsonEncodeBuiltin(&runtime, roots[9], false));
    const message = runtime.takeException();
    const message_units = try valueUtf16Alloc(&runtime, message);
    defer runtime.allocator.free(message_units);
    const expected_message = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "Converting circular structure to JSON\n    --> starting at object with constructor 'Array'\n    --- index 0 closes the circle");
    defer runtime.allocator.free(expected_message);
    try std.testing.expectEqualSlices(u16, expected_message, message_units);

    roots[11] = try runtime.createDictionary(&.{});
    roots[12] = try runtime.createDictionary(&.{});
    try runtime.indexSet(roots[11], staticStringValue("a"), roots[12]);
    try runtime.indexSet(roots[12], staticStringValue("self"), roots[12]);
    try std.testing.expectError(error.CircularCloneValue, jsonEncodeBuiltin(&runtime, roots[11], false));
    const nested_message = runtime.takeException();
    const nested_units = try valueUtf16Alloc(&runtime, nested_message);
    defer runtime.allocator.free(nested_units);
    const expected_nested = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "Converting circular structure to JSON\n    --> starting at object with constructor 'Object'\n    --- property 'self' closes the circle");
    defer runtime.allocator.free(expected_nested);
    try std.testing.expectEqualSlices(u16, expected_nested, nested_units);

    roots[13] = try runtime.createDictionary(&.{});
    roots[14] = try runtime.createString(&.{0xd800});
    try runtime.indexSet(roots[13], roots[14], roots[13]);
    try std.testing.expectError(error.CircularCloneValue, jsonEncodeBuiltin(&runtime, roots[13], false));
    const surrogate_message = runtime.takeException();
    const surrogate_units = try valueUtf16Alloc(&runtime, surrogate_message);
    defer runtime.allocator.free(surrogate_units);
    const expected_surrogate = try std.unicode.utf8ToUtf16LeAlloc(runtime.allocator, "Converting circular structure to JSON\n    --> starting at object with constructor 'Object'\n    --- property '�' closes the circle");
    defer runtime.allocator.free(expected_surrogate);
    try std.testing.expectEqualSlices(u16, expected_surrogate, surrogate_units);

    var dictionary_values: [160]Value = undefined;
    for (0..80) |index| {
        dictionary_values[index * 2] = numberValue(@floatFromInt(index));
        dictionary_values[index * 2 + 1] = numberValue(@floatFromInt(index));
    }
    roots[15] = try runtime.createDictionary(&dictionary_values);
    var expected_gc: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer expected_gc.deinit();
    try expected_gc.writer.writeByte('{');
    for (0..80) |index| {
        if (index > 0) try expected_gc.writer.writeByte(',');
        try expected_gc.writer.print("\"{d}\":{d}", .{ index, index });
    }
    try expected_gc.writer.writeByte('}');
    // Force collections while normalized property-key objects are being built.
    // The source dictionary remains in the caller root frame, and keys already
    // produced by the serializer remain in its temporary root frame.
    runtime.next_collection = runtime.object_count;
    try expectJsonAotString(&runtime, roots[15], false, expected_gc.written());
}

test "AOT辞書・配列のキー命令は順序とBigIntキーを保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{
        try runtime.createDictionary(&.{
            staticStringValue("b"), numberValue(1),
            staticStringValue("2"), numberValue(2),
            staticStringValue("1"), numberValue(3),
        }),
        try runtime.createArray(&.{ numberValue(10), numberValue(20) }),
        try runtime.createBigInt("1n"),
        .{},
        .{},
    };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[3] = try dictionaryKeysBuiltin(&runtime, roots[0]);
    try std.testing.expectEqual(@as(usize, 3), roots[3].object().?.payload.array.items.len);
    const dictionary_keys = roots[3].object().?.payload.array.items;
    try std.testing.expectEqualSlices(u16, &.{'1'}, dictionary_keys[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'2'}, dictionary_keys[1].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'b'}, dictionary_keys[2].object().?.payload.utf16_string);
    roots[4] = try dictionaryKeysBuiltin(&runtime, roots[1]);
    try std.testing.expectEqualSlices(u16, &.{'0'}, roots[4].object().?.payload.array.items[0].object().?.payload.utf16_string);
    try std.testing.expectEqualSlices(u16, &.{'1'}, roots[4].object().?.payload.array.items[1].object().?.payload.utf16_string);
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[1], roots[2]));
    try std.testing.expectError(error.ArrayLengthDelete, dictionaryRemoveBuiltin(&runtime, roots[1], staticStringValue("length")));
    try runtime.indexSet(roots[0], roots[2], numberValue(9));
    roots[3] = try dictionaryKeysBuiltin(&runtime, roots[0]);
    try std.testing.expectEqual(@as(usize, 3), roots[3].object().?.payload.array.items.len);
}

test "AOT辞書キー命令はcustom prototype chainの順序とshadowingを保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 5;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{
        staticStringValue("2"),      numberValue(20),
        staticStringValue("base"),   numberValue(21),
        staticStringValue("shadow"), numberValue(22),
    });
    roots[1] = try runtime.createDictionary(&.{
        staticStringValue("1"),      numberValue(10),
        staticStringValue("middle"), numberValue(11),
        staticStringValue("shadow"), numberValue(12),
    });
    roots[2] = try runtime.createDictionary(&.{
        staticStringValue("3"),      numberValue(30),
        staticStringValue("own"),    numberValue(31),
        staticStringValue("shadow"), numberValue(32),
    });
    roots[1].object().?.prototype = roots[0];
    roots[2].object().?.prototype = roots[1];

    roots[3] = try dictionaryKeysBuiltin(&runtime, roots[2]);
    roots[4] = try dictionaryValuesBuiltin(&runtime, roots[2]);
    const expected_keys = [_][]const u8{ "3", "own", "shadow", "1", "middle", "2", "base" };
    const expected_values = [_]f64{ 30, 31, 32, 10, 11, 20, 21 };
    try std.testing.expectEqual(expected_keys.len, roots[3].object().?.payload.array.items.len);
    try std.testing.expectEqual(expected_values.len, roots[4].object().?.payload.array.items.len);
    for (expected_keys, 0..) |expected, index| {
        try expectUtf16String(&runtime, roots[3].object().?.payload.array.items[index], expected);
        try std.testing.expectEqual(expected_values[index], valueToNumber(roots[4].object().?.payload.array.items[index]));
    }
}

test "AOT辞書リテラルは非文字列キーをproperty keyへ正規化する" {
    try aotDictionaryPropertyKeyAllocationTest(std.testing.allocator);
}

test "AOT辞書リテラルのproperty key正規化は割当失敗を安全に処理する" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, aotDictionaryBigIntPropertyKeyAllocationTest, .{});
}

test "AOT辞書キー存在の型エラーは動的な公式文言を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const invalid_key = try runtime.createString(&.{ 'x', 0xd800 });
    try std.testing.expectError(error.DictionaryHasReceiver, dictionaryHasBuiltin(&runtime, .{ .tag = @intFromEnum(Tag.null_value) }, invalid_key));
    const message = try pendingExceptionMessageUtf8Alloc(&runtime);
    defer runtime.allocator.free(message);
    try std.testing.expectEqualStrings("Cannot use 'in' operator to search for 'x�' in null", message);
}

test "AOT辞書キー存在は標準prototype propertyを含む" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 3;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{});
    roots[1] = try runtime.createArray(&.{numberValue(1)});
    roots[2] = try runtime.createFunction(testAotFunction, 1, &.{});

    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("toString")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("constructor")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("__proto__")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[1], staticStringValue("map")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[1], staticStringValue("toString")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[2], staticStringValue("toString")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[2], staticStringValue("prototype")));
    try std.testing.expect(!(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("missing"))));
}

test "AOT辞書キー存在はbyte bufferのown indexとprototype propertyを含む" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 3;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes(&.{ 85, 66 });
    roots[1] = try runtime.createUint8Array(&.{ 85, 66 });
    roots[2] = try runtime.createArrayBuffer(&.{ 85, 66 });

    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("0")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("length")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("byteLength")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("buffer")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[1], staticStringValue("0")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[1], staticStringValue("map")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[2], staticStringValue("byteLength")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[2], staticStringValue("maxByteLength")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[2], staticStringValue("toString")));
    try std.testing.expect(!(try dictionaryHasBuiltin(&runtime, roots[2], staticStringValue("0"))));
    try std.testing.expect(!(try dictionaryHasBuiltin(&runtime, roots[2], staticStringValue("length"))));
    try std.testing.expect(!(try dictionaryHasBuiltin(&runtime, roots[2], staticStringValue("buffer"))));
    try std.testing.expect(!(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("missing"))));
}

test "AOT byte bufferのnull prototypeは標準propertyを隠し添字と表の長さを保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 5;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes(&.{ 85, 66 });
    roots[1] = try runtime.createUint8Array(&.{ 85, 66 });
    roots[2] = try runtime.createArrayBuffer(&.{ 85, 66 });
    roots[0].object().?.prototype = .{ .tag = @intFromEnum(Tag.null_value) };
    roots[1].object().?.prototype = .{ .tag = @intFromEnum(Tag.null_value) };
    roots[2].object().?.prototype = .{ .tag = @intFromEnum(Tag.null_value) };

    const undefined_tag = @intFromEnum(Tag.undefined);
    try std.testing.expectEqual(undefined_tag, runtime.indexGet(roots[0], staticStringValue("length")).tag);
    try std.testing.expectEqual(undefined_tag, runtime.indexGet(roots[0], staticStringValue("byteLength")).tag);
    try std.testing.expectEqual(undefined_tag, runtime.indexGet(roots[0], staticStringValue("slice")).tag);
    try std.testing.expectEqual(@as(f64, 85), valueToNumber(runtime.indexGet(roots[0], numberValue(0))));
    try std.testing.expectEqual(undefined_tag, runtime.indexGet(roots[1], staticStringValue("map")).tag);
    try std.testing.expectEqual(@as(f64, 85), valueToNumber(runtime.indexGet(roots[1], numberValue(0))));
    try std.testing.expectEqual(undefined_tag, runtime.indexGet(roots[2], staticStringValue("byteLength")).tag);
    try std.testing.expectEqual(undefined_tag, runtime.indexGet(roots[2], numberValue(0)).tag);

    roots[3] = try runtime.createArray(&.{roots[0]});
    try std.testing.expectEqual(undefined_tag, (try tableRowProperty(&runtime, roots[0], staticStringValue("length"))).tag);
    try std.testing.expectEqual(@as(f64, 85), valueToNumber(try tableRowProperty(&runtime, roots[0], numberValue(0))));
    try std.testing.expectEqual(@as(f64, 1), valueToNumber(try tableColumnCountBuiltin(&runtime, roots[3])));
    try std.testing.expectEqual(undefined_tag, (try tableRowProperty(&runtime, roots[2], staticStringValue("byteLength"))).tag);

    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[0], numberValue(0)));
    try std.testing.expect(!(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("length"))));
    try std.testing.expect(!(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("slice"))));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[1], numberValue(0)));
    try std.testing.expect(!(try dictionaryHasBuiltin(&runtime, roots[1], staticStringValue("map"))));
    try std.testing.expect(!(try dictionaryHasBuiltin(&runtime, roots[2], staticStringValue("byteLength"))));
}

test "AOT辞書キー列挙とハッシュ内容列挙はbyte bufferのown要素を扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 7;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes(&.{ 85, 66 });
    roots[1] = try runtime.createUint8Array(&.{ 85, 66 });
    roots[2] = try runtime.createArrayBuffer(&.{ 85, 66 });
    roots[3] = try dictionaryKeysBuiltin(&runtime, roots[1]);
    try std.testing.expectEqual(@as(usize, 2), roots[3].object().?.payload.array.items.len);
    try expectUtf16String(&runtime, roots[3].object().?.payload.array.items[0], "0");
    try expectUtf16String(&runtime, roots[3].object().?.payload.array.items[1], "1");
    roots[4] = try dictionaryValuesBuiltin(&runtime, roots[1]);
    try std.testing.expectEqual(@as(usize, 2), roots[4].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(f64, 85), valueToNumber(roots[4].object().?.payload.array.items[0]));
    try std.testing.expectEqual(@as(f64, 66), valueToNumber(roots[4].object().?.payload.array.items[1]));
    roots[5] = try dictionaryKeysBuiltin(&runtime, roots[2]);
    roots[6] = try dictionaryValuesBuiltin(&runtime, roots[2]);
    try std.testing.expectEqual(@as(usize, 0), roots[5].object().?.payload.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), roots[6].object().?.payload.array.items.len);

    try std.testing.expectError(error.ByteBufferIndexDelete, dictionaryRemoveBuiltin(&runtime, roots[0], staticStringValue("0")));
    try expectUtf16String(&runtime, runtime.takeException(), "Cannot delete property '0' of [object Uint8Array]");
    try std.testing.expectError(error.ByteBufferIndexDelete, dictionaryRemoveBuiltin(&runtime, roots[1], staticStringValue("0")));
    try expectUtf16String(&runtime, runtime.takeException(), "Cannot delete property '0' of [object Uint8Array]");
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[0], staticStringValue("0")));
    try std.testing.expect(try dictionaryHasBuiltin(&runtime, roots[1], staticStringValue("0")));
}

test "AOT Bufferの列挙はenumerable prototype propertyの順序と値を保持する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 4;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createBytes(&.{ 85, 66 });
    roots[1] = try dictionaryKeysBuiltin(&runtime, roots[0]);
    roots[2] = try dictionaryValuesBuiltin(&runtime, roots[0]);

    const property_names = table_byte_buffer_buffer_enumerable_property_names[0..];
    try std.testing.expectEqual(@as(usize, 2 + property_names.len), roots[1].object().?.payload.array.items.len);
    try expectUtf16String(&runtime, roots[1].object().?.payload.array.items[0], "0");
    try expectUtf16String(&runtime, roots[1].object().?.payload.array.items[1], "1");
    for (property_names, 0..) |name, index| {
        try expectUtf16String(&runtime, roots[1].object().?.payload.array.items[index + 2], name);
    }

    const values = roots[2].object().?.payload.array.items;
    try std.testing.expectEqual(@as(usize, 2 + property_names.len), values.len);
    try std.testing.expectEqual(@as(f64, 85), valueToNumber(values[0]));
    try std.testing.expectEqual(@as(f64, 66), valueToNumber(values[1]));
    for (property_names, 0..) |name, index| {
        const property = values[index + 2];
        if (std.mem.eql(u8, name, "parent")) {
            try std.testing.expectEqual(Tag.byte_buffer, @as(Tag, @enumFromInt(property.tag)));
            try std.testing.expectEqual(ByteKind.array_buffer, property.object().?.payload.byte_buffer.kind);
        } else if (std.mem.eql(u8, name, "offset")) {
            try std.testing.expectEqual(@as(f64, 0), valueToNumber(property));
        } else {
            try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(property.tag)));
        }
    }
    const last_property = values[values.len - 1];
    try std.testing.expectEqual(Tag.function, @as(Tag, @enumFromInt(last_property.tag)));
    try std.testing.expectEqualStrings("toString", last_property.object().?.payload.function.name);
}

test "AOT HTTPのqueryとform parserはURL decode境界を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var roots = [_]Value{.{}} ** 3;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try aotHttpParseQuery(&runtime, "/echo?a=A%20B&plus=A+B");
    {
        const query_value = try valueUtf8LossyAlloc(&runtime, runtime.indexGet(roots[0], staticStringValue("a")));
        defer runtime.allocator.free(query_value);
        try std.testing.expectEqualStrings("A B", query_value);
    }
    {
        const query_value = try valueUtf8LossyAlloc(&runtime, runtime.indexGet(roots[0], staticStringValue("plus")));
        defer runtime.allocator.free(query_value);
        try std.testing.expectEqualStrings("A+B", query_value);
    }

    roots[1] = try runtime.createArray(&.{});
    roots[2] = try aotHttpParsePost(&runtime, "application/x-www-form-urlencoded", "message=hello+world&x=A%2BB", roots[1]);
    {
        const form_value = try valueUtf8LossyAlloc(&runtime, runtime.indexGet(roots[2], staticStringValue("message")));
        defer runtime.allocator.free(form_value);
        try std.testing.expectEqualStrings("hello world", form_value);
    }
    {
        const form_value = try valueUtf8LossyAlloc(&runtime, runtime.indexGet(roots[2], staticStringValue("x")));
        defer runtime.allocator.free(form_value);
        try std.testing.expectEqualStrings("A+B", form_value);
    }
}

test "AOT HTTPのqueryは重複キーと余分な区切りを公式splitどおり扱う" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const result = try aotHttpParseQuery(&runtime, "/a?duplicate=first&duplicate=last&flag&raw=a=b&empty=");
    var roots = [_]Value{result};
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const duplicate = try valueUtf8LossyAlloc(&runtime, runtime.indexGet(result, staticStringValue("duplicate")));
    defer runtime.allocator.free(duplicate);
    const flag = try valueUtf8LossyAlloc(&runtime, runtime.indexGet(result, staticStringValue("flag")));
    defer runtime.allocator.free(flag);
    const raw = try valueUtf8LossyAlloc(&runtime, runtime.indexGet(result, staticStringValue("raw")));
    defer runtime.allocator.free(raw);
    const empty = try valueUtf8LossyAlloc(&runtime, runtime.indexGet(result, staticStringValue("empty")));
    defer runtime.allocator.free(empty);
    try std.testing.expectEqualStrings("last", duplicate);
    try std.testing.expectEqualStrings("undefined", flag);
    try std.testing.expectEqualStrings("a", raw);
    try std.testing.expectEqualStrings("", empty);
}

test "AOT HTTPのqueryは2個目以降の疑問符を公式splitどおり無視する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    const result = try aotHttpParseQuery(&runtime, "/a?x=1?ignored=2");
    var roots = [_]Value{result};
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    const x = try valueUtf8LossyAlloc(&runtime, runtime.indexGet(result, staticStringValue("x")));
    defer runtime.allocator.free(x);
    try std.testing.expectEqualStrings("1", x);
    try std.testing.expectEqual(Tag.undefined, @as(Tag, @enumFromInt(runtime.indexGet(result, staticStringValue("ignored")).tag)));
}

test "AOT HTTPのqueryの不正percent encodingはURI malformedへ変換する" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    for ([_][]const u8{ "/a?x=%", "/a?x=%2", "/a?x=%GG", "/a?x=%FF", "/a?x=%C3%28" }) |target| {
        try std.testing.expectError(error.InvalidHttpQueryEncoding, aotHttpParseQuery(&runtime, target));
    }
}

test "AOT HTTP multipartは公式のboundary抽出とLFヘッダ区切りを保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    try std.testing.expectEqualStrings("X", aotHttpMultipartBoundary("multipart/form-data; boundary=X; charset=utf-8").?);
    try std.testing.expectEqualStrings("X;Y", aotHttpMultipartBoundary("multipart/form-data; boundary=\"X;Y\"; charset=utf-8").?);
    try std.testing.expect(aotHttpMultipartBoundary("multipart/form-data") == null);

    var roots = [_]Value{.{}} ** 3;
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);
    roots[0] = try runtime.createArray(&.{});
    roots[1] = try aotHttpParsePost(&runtime, "multipart/form-data; boundary=\"X\"; charset=utf-8", "--X\nContent-Disposition: form-data; name=\"title\"\n\nhello\n--X--\n", roots[0]);
    const title = try valueUtf8LossyAlloc(&runtime, runtime.indexGet(roots[1], staticStringValue("title")));
    defer runtime.allocator.free(title);
    try std.testing.expectEqualStrings("hello", title);

    roots[2] = try aotHttpParsePost(&runtime, "Multipart/form-data; boundary=X", "raw", roots[0]);
    const raw = try valueUtf8LossyAlloc(&runtime, roots[2]);
    defer runtime.allocator.free(raw);
    try std.testing.expectEqualStrings("raw", raw);
}

test "AOT HTTP multipartのContent-Dispositionは公式の引用正規表現境界を保つ" {
    try std.testing.expectEqualStrings("hello;v1.txt", aotHttpDispositionParameter("form-data; filename=\"hello;v1.txt\"", "name").?);
    try std.testing.expectEqualStrings("hello;v1.txt", aotHttpDispositionParameter("form-data; filename=\"hello;v1.txt\"", "filename").?);
    try std.testing.expect(aotHttpDispositionParameter("form-data; Name=\"title\"", "name") == null);
    try std.testing.expect(aotHttpDispositionParameter("form-data; name=title", "name") == null);
    try std.testing.expect(aotHttpDispositionParameter("form-data; name=\"\"", "name") == null);
}

test "AOT HTTP routeと静的配信の補助判定は公式境界を保つ" {
    var runtime = Runtime{ .allocator = std.testing.allocator };
    defer runtime.deinit();
    var routes = [_]AotHttpRoute{
        .{ .kind = .callback, .prefix = try runtime.allocator.dupe(u8, "/route") },
        .{ .kind = .callback, .prefix = try runtime.allocator.dupe(u8, "/route/long") },
    };
    defer for (&routes) |*route| route.deinit(runtime.allocator);
    try std.testing.expectEqualStrings("/route/long", aotHttpBestRoute(&routes, "/route/long/test").?.prefix);
    try std.testing.expectEqualStrings("text/plain", aotHttpMimeType("hello.txt"));
    try std.testing.expectEqualStrings("text/javascript", aotHttpMimeType("module.mjs"));
    try std.testing.expectEqualStrings("hello.txt", aotHttpUploadBasename("/tmp/hello.txt"));
}
