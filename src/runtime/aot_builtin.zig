const std = @import("std");

pub const Command = enum(u16) {
    to_string,
    type_of,
    to_int,
    to_float,
    is_nan,
    is_number_nan,
    radix16,
    radix,
    radix2,
    radix2_display,
    rgb,
    bit_or,
    bit_and,
    bit_xor,
    bit_not,
    shift_left,
    shift_right,
    shift_right_unsigned,
    subtract,
    multiply,
    divide,
    remainder,
    is_even,
    is_odd,
    square,
    power_number,
    greater_equal,
    less_equal,
    less,
    greater,
    strict_equal,
    strict_not_equal,
    in_range,
    maximum,
    minimum,
    clamp,
    logical_or,
    logical_and,
    logical_not,
    range,
    empty_array,
    empty_dictionary,
    truth_label,
    repeat_multiply,
    unicode_length,
    codepoint_find,
    string_starts,
    string_ends,
    element_count,
    add_parsed,
    sum_parsed,
    sequential_add,
    chr,
    asc,
    string_insert,
    string_search,
    append,
    append_line,
    concat_join,
    explode,
    refrain,
    occurrence_count,
    substring_mid,
    substring_left,
    substring_right,
    split_all,
    split_first,
    string_remove,
};

pub fn lookup(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, "文字列変換") or std.mem.eql(u8, name, "TOSTR")) return .to_string;
    if (std.mem.eql(u8, name, "変数型確認") or std.mem.eql(u8, name, "TYPEOF")) return .type_of;
    if (std.mem.eql(u8, name, "整数変換") or std.mem.eql(u8, name, "TOINT") or std.mem.eql(u8, name, "INT")) return .to_int;
    if (std.mem.eql(u8, name, "実数変換") or std.mem.eql(u8, name, "TOFLOAT") or std.mem.eql(u8, name, "FLOAT")) return .to_float;
    if (std.mem.eql(u8, name, "NAN判定")) return .is_nan;
    if (std.mem.eql(u8, name, "非数判定")) return .is_number_nan;
    if (std.mem.eql(u8, name, "HEX")) return .radix16;
    if (std.mem.eql(u8, name, "進数変換")) return .radix;
    if (std.mem.eql(u8, name, "二進")) return .radix2;
    if (std.mem.eql(u8, name, "二進表示")) return .radix2_display;
    if (std.mem.eql(u8, name, "RGB")) return .rgb;
    if (std.mem.eql(u8, name, "OR")) return .bit_or;
    if (std.mem.eql(u8, name, "AND")) return .bit_and;
    if (std.mem.eql(u8, name, "XOR")) return .bit_xor;
    if (std.mem.eql(u8, name, "NOT")) return .bit_not;
    if (std.mem.eql(u8, name, "SHIFT_L")) return .shift_left;
    if (std.mem.eql(u8, name, "SHIFT_R")) return .shift_right;
    if (std.mem.eql(u8, name, "SHIFT_UR")) return .shift_right_unsigned;
    if (std.mem.eql(u8, name, "引")) return .subtract;
    if (std.mem.eql(u8, name, "倍")) return .multiply;
    if (std.mem.eql(u8, name, "割")) return .divide;
    if (std.mem.eql(u8, name, "割余")) return .remainder;
    if (std.mem.eql(u8, name, "偶数")) return .is_even;
    if (std.mem.eql(u8, name, "奇数")) return .is_odd;
    if (std.mem.eql(u8, name, "二乗")) return .square;
    if (std.mem.eql(u8, name, "べき乗")) return .power_number;
    if (std.mem.eql(u8, name, "以上")) return .greater_equal;
    if (std.mem.eql(u8, name, "以下")) return .less_equal;
    if (std.mem.eql(u8, name, "未満")) return .less;
    if (std.mem.eql(u8, name, "超")) return .greater;
    if (std.mem.eql(u8, name, "等")) return .strict_equal;
    if (std.mem.eql(u8, name, "等無")) return .strict_not_equal;
    if (std.mem.eql(u8, name, "範囲内")) return .in_range;
    if (std.mem.eql(u8, name, "MAX") or std.mem.eql(u8, name, "最大値")) return .maximum;
    if (std.mem.eql(u8, name, "MIN") or std.mem.eql(u8, name, "最小値")) return .minimum;
    if (std.mem.eql(u8, name, "CLAMP")) return .clamp;
    if (std.mem.eql(u8, name, "論理OR")) return .logical_or;
    if (std.mem.eql(u8, name, "論理AND")) return .logical_and;
    if (std.mem.eql(u8, name, "論理NOT")) return .logical_not;
    if (std.mem.eql(u8, name, "範囲")) return .range;
    if (std.mem.eql(u8, name, "空配列")) return .empty_array;
    if (std.mem.eql(u8, name, "空辞書") or std.mem.eql(u8, name, "空ハッシュ") or std.mem.eql(u8, name, "空オブジェクト")) return .empty_dictionary;
    if (std.mem.eql(u8, name, "真偽判定")) return .truth_label;
    if (std.mem.eql(u8, name, "掛")) return .repeat_multiply;
    if (std.mem.eql(u8, name, "文字数")) return .unicode_length;
    if (std.mem.eql(u8, name, "何文字目")) return .codepoint_find;
    if (std.mem.eql(u8, name, "文字始")) return .string_starts;
    if (std.mem.eql(u8, name, "文字終")) return .string_ends;
    if (std.mem.eql(u8, name, "配列要素数") or std.mem.eql(u8, name, "要素数") or std.mem.eql(u8, name, "LEN")) return .element_count;
    if (std.mem.eql(u8, name, "足")) return .add_parsed;
    if (std.mem.eql(u8, name, "合計")) return .sum_parsed;
    if (std.mem.eql(u8, name, "連続加算")) return .sequential_add;
    if (std.mem.eql(u8, name, "CHR")) return .chr;
    if (std.mem.eql(u8, name, "ASC")) return .asc;
    if (std.mem.eql(u8, name, "文字挿入")) return .string_insert;
    if (std.mem.eql(u8, name, "文字検索")) return .string_search;
    if (std.mem.eql(u8, name, "追加")) return .append;
    if (std.mem.eql(u8, name, "一行追加")) return .append_line;
    if (std.mem.eql(u8, name, "連結") or std.mem.eql(u8, name, "文字列連結")) return .concat_join;
    if (std.mem.eql(u8, name, "文字列分解")) return .explode;
    if (std.mem.eql(u8, name, "リフレイン")) return .refrain;
    if (std.mem.eql(u8, name, "出現回数")) return .occurrence_count;
    if (std.mem.eql(u8, name, "MID") or std.mem.eql(u8, name, "文字抜出")) return .substring_mid;
    if (std.mem.eql(u8, name, "LEFT") or std.mem.eql(u8, name, "文字左部分")) return .substring_left;
    if (std.mem.eql(u8, name, "RIGHT") or std.mem.eql(u8, name, "文字右部分")) return .substring_right;
    if (std.mem.eql(u8, name, "区切")) return .split_all;
    if (std.mem.eql(u8, name, "文字列分割")) return .split_first;
    if (std.mem.eql(u8, name, "文字削除")) return .string_remove;
    return null;
}

test "AOT標準命令の正式名と別名を同じIDへ解決する" {
    try std.testing.expectEqual(Command.to_string, lookup("文字列変換").?);
    try std.testing.expectEqual(Command.to_string, lookup("TOSTR").?);
    try std.testing.expectEqual(Command.type_of, lookup("変数型確認").?);
    try std.testing.expectEqual(Command.type_of, lookup("TYPEOF").?);
    try std.testing.expectEqual(Command.to_int, lookup("整数変換").?);
    try std.testing.expectEqual(Command.to_int, lookup("TOINT").?);
    try std.testing.expectEqual(Command.to_int, lookup("INT").?);
    try std.testing.expectEqual(Command.to_float, lookup("実数変換").?);
    try std.testing.expectEqual(Command.to_float, lookup("TOFLOAT").?);
    try std.testing.expectEqual(Command.to_float, lookup("FLOAT").?);
    try std.testing.expectEqual(Command.is_nan, lookup("NAN判定").?);
    try std.testing.expectEqual(Command.is_number_nan, lookup("非数判定").?);
    try std.testing.expectEqual(Command.radix16, lookup("HEX").?);
    try std.testing.expectEqual(Command.radix, lookup("進数変換").?);
    try std.testing.expectEqual(Command.radix2, lookup("二進").?);
    try std.testing.expectEqual(Command.radix2_display, lookup("二進表示").?);
    try std.testing.expectEqual(Command.rgb, lookup("RGB").?);
    try std.testing.expectEqual(Command.bit_or, lookup("OR").?);
    try std.testing.expectEqual(Command.bit_and, lookup("AND").?);
    try std.testing.expectEqual(Command.bit_xor, lookup("XOR").?);
    try std.testing.expectEqual(Command.bit_not, lookup("NOT").?);
    try std.testing.expectEqual(Command.shift_left, lookup("SHIFT_L").?);
    try std.testing.expectEqual(Command.shift_right, lookup("SHIFT_R").?);
    try std.testing.expectEqual(Command.shift_right_unsigned, lookup("SHIFT_UR").?);
    try std.testing.expectEqual(Command.subtract, lookup("引").?);
    try std.testing.expectEqual(Command.multiply, lookup("倍").?);
    try std.testing.expectEqual(Command.divide, lookup("割").?);
    try std.testing.expectEqual(Command.remainder, lookup("割余").?);
    try std.testing.expectEqual(Command.is_even, lookup("偶数").?);
    try std.testing.expectEqual(Command.is_odd, lookup("奇数").?);
    try std.testing.expectEqual(Command.square, lookup("二乗").?);
    try std.testing.expectEqual(Command.power_number, lookup("べき乗").?);
    try std.testing.expectEqual(Command.greater_equal, lookup("以上").?);
    try std.testing.expectEqual(Command.less_equal, lookup("以下").?);
    try std.testing.expectEqual(Command.less, lookup("未満").?);
    try std.testing.expectEqual(Command.greater, lookup("超").?);
    try std.testing.expectEqual(Command.strict_equal, lookup("等").?);
    try std.testing.expectEqual(Command.strict_not_equal, lookup("等無").?);
    try std.testing.expectEqual(Command.in_range, lookup("範囲内").?);
    try std.testing.expectEqual(Command.maximum, lookup("MAX").?);
    try std.testing.expectEqual(Command.maximum, lookup("最大値").?);
    try std.testing.expectEqual(Command.minimum, lookup("MIN").?);
    try std.testing.expectEqual(Command.minimum, lookup("最小値").?);
    try std.testing.expectEqual(Command.clamp, lookup("CLAMP").?);
    try std.testing.expectEqual(Command.logical_or, lookup("論理OR").?);
    try std.testing.expectEqual(Command.logical_and, lookup("論理AND").?);
    try std.testing.expectEqual(Command.logical_not, lookup("論理NOT").?);
    try std.testing.expectEqual(Command.range, lookup("範囲").?);
    try std.testing.expectEqual(Command.empty_array, lookup("空配列").?);
    try std.testing.expectEqual(Command.empty_dictionary, lookup("空辞書").?);
    try std.testing.expectEqual(Command.empty_dictionary, lookup("空ハッシュ").?);
    try std.testing.expectEqual(Command.empty_dictionary, lookup("空オブジェクト").?);
    try std.testing.expectEqual(Command.truth_label, lookup("真偽判定").?);
    try std.testing.expectEqual(Command.repeat_multiply, lookup("掛").?);
    try std.testing.expectEqual(Command.unicode_length, lookup("文字数").?);
    try std.testing.expectEqual(Command.codepoint_find, lookup("何文字目").?);
    try std.testing.expectEqual(Command.string_starts, lookup("文字始").?);
    try std.testing.expectEqual(Command.string_ends, lookup("文字終").?);
    try std.testing.expectEqual(Command.element_count, lookup("配列要素数").?);
    try std.testing.expectEqual(Command.element_count, lookup("要素数").?);
    try std.testing.expectEqual(Command.element_count, lookup("LEN").?);
    try std.testing.expectEqual(Command.add_parsed, lookup("足").?);
    try std.testing.expectEqual(Command.sum_parsed, lookup("合計").?);
    try std.testing.expectEqual(Command.sequential_add, lookup("連続加算").?);
    try std.testing.expectEqual(Command.chr, lookup("CHR").?);
    try std.testing.expectEqual(Command.asc, lookup("ASC").?);
    try std.testing.expectEqual(Command.string_insert, lookup("文字挿入").?);
    try std.testing.expectEqual(Command.string_search, lookup("文字検索").?);
    try std.testing.expectEqual(Command.append, lookup("追加").?);
    try std.testing.expectEqual(Command.append_line, lookup("一行追加").?);
    try std.testing.expectEqual(Command.concat_join, lookup("連結").?);
    try std.testing.expectEqual(Command.concat_join, lookup("文字列連結").?);
    try std.testing.expectEqual(Command.explode, lookup("文字列分解").?);
    try std.testing.expectEqual(Command.refrain, lookup("リフレイン").?);
    try std.testing.expectEqual(Command.occurrence_count, lookup("出現回数").?);
    try std.testing.expectEqual(Command.substring_mid, lookup("MID").?);
    try std.testing.expectEqual(Command.substring_mid, lookup("文字抜出").?);
    try std.testing.expectEqual(Command.substring_left, lookup("LEFT").?);
    try std.testing.expectEqual(Command.substring_left, lookup("文字左部分").?);
    try std.testing.expectEqual(Command.substring_right, lookup("RIGHT").?);
    try std.testing.expectEqual(Command.substring_right, lookup("文字右部分").?);
    try std.testing.expectEqual(Command.split_all, lookup("区切").?);
    try std.testing.expectEqual(Command.split_first, lookup("文字列分割").?);
    try std.testing.expectEqual(Command.string_remove, lookup("文字削除").?);
    try std.testing.expect(lookup("未対応命令") == null);
}
