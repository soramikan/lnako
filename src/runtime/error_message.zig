const std = @import("std");

pub fn forFailure(failure: anyerror) []const u8 {
    return switch (failure) {
        error.CannotMixBigIntAndNumber => "Cannot mix BigInt and other types, use explicit conversions",
        error.CannotConvertBigIntToNumber => "Cannot convert a BigInt value to a number",
        error.CannotConvertObjectToPrimitive => "Cannot convert object to primitive value",
        error.UnsignedShiftOfBigInt => "BigInts have no unsigned right shift, use >> instead",
        error.NegativeBigIntExponent => "Exponent must be positive",
        error.InvalidRadix => "toString() radix argument must be between 2 and 36",
        error.StartsWithReceiverExpected => "s.startsWith is not a function",
        error.EndsWithReceiverExpected => "s.endsWith is not a function",
        error.StartsWithNullReceiver => "Cannot read properties of null (reading 'startsWith')",
        error.StartsWithUndefinedReceiver => "Cannot read properties of undefined (reading 'startsWith')",
        error.EndsWithNullReceiver => "Cannot read properties of null (reading 'endsWith')",
        error.EndsWithUndefinedReceiver => "Cannot read properties of undefined (reading 'endsWith')",
        error.KatakanaFullWidthLengthNull => "Cannot read properties of null (reading 'length')",
        error.KatakanaFullWidthLengthUndefined => "Cannot read properties of undefined (reading 'length')",
        error.KatakanaFullWidthSubstringReceiver => "s.substring is not a function",
        error.KatakanaHalfWidthSplitNull => "Cannot read properties of null (reading 'split')",
        error.KatakanaHalfWidthSplitUndefined => "Cannot read properties of undefined (reading 'split')",
        error.KatakanaHalfWidthSplitReceiver => "s.split is not a function",
        error.CutNullDelimiterLength => "Cannot read properties of null (reading 'length')",
        error.CutUndefinedDelimiterLength => "Cannot read properties of undefined (reading 'length')",
        error.ArrayInsertReceiver => "『配列挿入』で配列以外の要素への挿入。",
        error.ArrayInsertManyReceiver => "『配列一括挿入』で配列以外の要素への挿入。",
        error.ArrayCutReceiver => "『配列切取』で配列以外を指定。",
        error.ArrayTakeReceiver => "『配列取出』で配列以外を指定。",
        error.ArrayPopReceiver => "『配列ポップ』で配列以外の処理。",
        error.ArrayPushReceiver => "『配列追加』で配列以外の処理。",
        error.ArrayRangeCopyReceiver => "『配列範囲コピー』で配列以外の値が指定されました。",
        error.NonEmptyArrayExpected => "Reduce of empty array with no initial value",
        error.CircularCloneValue => "Converting circular structure to JSON",
        error.CannotSerializeBigInt => "Do not know how to serialize a BigInt",
        error.InvalidJsonCloneValue => "Unexpected token 'u', \"undefined\" is not valid JSON",
        error.InvalidStringRange => "『参照』で文字列型の範囲指定が不正です。",
        error.ArrayCutNullIndex => "Cannot read properties of null (reading '先頭')",
        error.ArrayLengthDelete => "Cannot delete property 'length' of [object Array]",
        error.DictionaryKeysReceiver => "『辞書キー列挙』でハッシュ以外が与えられました。",
        error.DictionaryValuesReceiver => "『ハッシュ内容列挙』でハッシュ以外が与えられました。",
        error.DictionaryRemoveReceiver => "『辞書キー削除』でハッシュ以外が与えられました。",
        error.DictionaryHasReceiver => "Cannot use 'in' operator to search for a property",
        error.CannotConvertNullToBigInt => "Cannot convert null to a BigInt",
        error.CannotConvertUndefinedToBigInt => "Cannot convert undefined to a BigInt",
        error.RawArrayNullNotIterable => "object null is not iterable (cannot read property Symbol(Symbol.iterator))",
        error.RawArrayUndefinedNotIterable => "undefined is not iterable (cannot read property Symbol(Symbol.iterator))",
        error.InvalidKansujiInput => "『漢数字』命令の中に無効な文字が含まれています。",
        error.KansujiTooLarge => "『漢数字』命令に含められる数の大きさを超えています。",
        error.InvalidArabicNumeral => "『算用数字』命令の中に無効な文字が含まれています。",
        else => @errorName(failure),
    };
}

test "BigInt実行時エラーを公式JavaScriptの文言へ変換する" {
    try std.testing.expectEqualStrings(
        "Cannot mix BigInt and other types, use explicit conversions",
        forFailure(error.CannotMixBigIntAndNumber),
    );
    try std.testing.expectEqualStrings(
        "Cannot convert a BigInt value to a number",
        forFailure(error.CannotConvertBigIntToNumber),
    );
    try std.testing.expectEqualStrings(
        "Cannot convert object to primitive value",
        forFailure(error.CannotConvertObjectToPrimitive),
    );
    try std.testing.expectEqualStrings(
        "BigInts have no unsigned right shift, use >> instead",
        forFailure(error.UnsignedShiftOfBigInt),
    );
    try std.testing.expectEqualStrings(
        "toString() radix argument must be between 2 and 36",
        forFailure(error.InvalidRadix),
    );
    try std.testing.expectEqualStrings("UnknownFailure", forFailure(error.UnknownFailure));
    try std.testing.expectEqualStrings("s.startsWith is not a function", forFailure(error.StartsWithReceiverExpected));
    try std.testing.expectEqualStrings("Cannot read properties of null (reading 'endsWith')", forFailure(error.EndsWithNullReceiver));
    try std.testing.expectEqualStrings("Cannot read properties of null (reading 'length')", forFailure(error.KatakanaFullWidthLengthNull));
    try std.testing.expectEqualStrings("Cannot delete property 'length' of [object Array]", forFailure(error.ArrayLengthDelete));
    try std.testing.expectEqualStrings("『辞書キー列挙』でハッシュ以外が与えられました。", forFailure(error.DictionaryKeysReceiver));
    try std.testing.expectEqualStrings("『ハッシュ内容列挙』でハッシュ以外が与えられました。", forFailure(error.DictionaryValuesReceiver));
    try std.testing.expectEqualStrings("『辞書キー削除』でハッシュ以外が与えられました。", forFailure(error.DictionaryRemoveReceiver));
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading 'length')", forFailure(error.KatakanaFullWidthLengthUndefined));
    try std.testing.expectEqualStrings("s.substring is not a function", forFailure(error.KatakanaFullWidthSubstringReceiver));
    try std.testing.expectEqualStrings("Cannot read properties of null (reading 'split')", forFailure(error.KatakanaHalfWidthSplitNull));
    try std.testing.expectEqualStrings("Cannot read properties of undefined (reading 'split')", forFailure(error.KatakanaHalfWidthSplitUndefined));
    try std.testing.expectEqualStrings("s.split is not a function", forFailure(error.KatakanaHalfWidthSplitReceiver));
    try std.testing.expectEqualStrings("Cannot convert null to a BigInt", forFailure(error.CannotConvertNullToBigInt));
    try std.testing.expectEqualStrings(
        "object null is not iterable (cannot read property Symbol(Symbol.iterator))",
        forFailure(error.RawArrayNullNotIterable),
    );
    try std.testing.expectEqualStrings(
        "undefined is not iterable (cannot read property Symbol(Symbol.iterator))",
        forFailure(error.RawArrayUndefinedNotIterable),
    );
    try std.testing.expectEqualStrings("『漢数字』命令の中に無効な文字が含まれています。", forFailure(error.InvalidKansujiInput));
    try std.testing.expectEqualStrings("『漢数字』命令に含められる数の大きさを超えています。", forFailure(error.KansujiTooLarge));
    try std.testing.expectEqualStrings("『算用数字』命令の中に無効な文字が含まれています。", forFailure(error.InvalidArabicNumeral));
}
