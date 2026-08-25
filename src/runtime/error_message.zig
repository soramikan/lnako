const std = @import("std");

pub fn forFailure(failure: anyerror) []const u8 {
    return switch (failure) {
        error.CannotMixBigIntAndNumber => "Cannot mix BigInt and other types, use explicit conversions",
        error.CannotConvertBigIntToNumber => "Cannot convert a BigInt value to a number",
        error.UnsignedShiftOfBigInt => "BigInts have no unsigned right shift, use >> instead",
        error.NegativeBigIntExponent => "Exponent must be positive",
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
    try std.testing.expectEqualStrings("UnknownFailure", forFailure(error.UnknownFailure));
}
