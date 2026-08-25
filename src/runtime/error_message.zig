const std = @import("std");

pub fn forFailure(failure: anyerror) []const u8 {
    return switch (failure) {
        error.CannotMixBigIntAndNumber => "Cannot mix BigInt and other types, use explicit conversions",
        error.CannotConvertBigIntToNumber => "Cannot convert a BigInt value to a number",
        error.UnsignedShiftOfBigInt => "BigInts have no unsigned right shift, use >> instead",
        error.NegativeBigIntExponent => "Exponent must be positive",
        error.InvalidRadix => "toString() radix argument must be between 2 and 36",
        error.StartsWithReceiverExpected => "s.startsWith is not a function",
        error.EndsWithReceiverExpected => "s.endsWith is not a function",
        error.StartsWithNullReceiver => "Cannot read properties of null (reading 'startsWith')",
        error.StartsWithUndefinedReceiver => "Cannot read properties of undefined (reading 'startsWith')",
        error.EndsWithNullReceiver => "Cannot read properties of null (reading 'endsWith')",
        error.EndsWithUndefinedReceiver => "Cannot read properties of undefined (reading 'endsWith')",
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
}
