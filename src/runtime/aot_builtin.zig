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
    dictionary_keys,
    dictionary_remove,
    dictionary_has,
    hash_keys,
    hash_values,
    hash_remove,
    hash_has,
    truth_label,
    repeat_multiply,
    unicode_length,
    codepoint_find,
    string_starts,
    string_ends,
    element_count,
    array_join,
    array_join_only,
    array_search,
    array_sort,
    array_numeric_convert,
    array_numeric_sort,
    array_reverse,
    array_insert,
    array_insert_many,
    array_cut,
    array_take,
    array_pop,
    array_push,
    array_clone,
    array_range_copy,
    reference,
    array_add,
    array_maximum,
    array_minimum,
    array_sum,
    array_swap,
    array_sequence,
    array_fill,
    table_pickup,
    table_exact_pickup,
    table_search,
    table_column_count,
    table_row_count,
    table_column,
    table_transpose,
    table_rotate,
    table_unique,
    table_insert_column,
    table_delete_column,
    table_column_sum,
    table_regexp_search,
    table_regexp_pickup,
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
    occurrence,
    cut,
    cut_range,
    substring_mid,
    substring_left,
    substring_right,
    split_all,
    split_first,
    string_remove,
    trim_both,
    trim_right,
    trim_left,
    replace_all,
    replace_first,
    uppercase,
    lowercase,
    hiragana,
    katakana,
    ascii_full_width,
    ascii_half_width,
    ascii_symbol_full_width,
    ascii_symbol_half_width,
    katakana_full_width,
    katakana_half_width,
    full_width,
    half_width,
    currency_format,
    zero_pad,
    space_pad,
    hiragana_predicate,
    katakana_predicate,
    digit_predicate,
    number_sequence_predicate,
    regexp_match,
    regexp_extract,
    regexp_replace,
    regexp_split,
    json_encode,
    json_encode_pretty,
    json_decode,
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
    if (std.mem.eql(u8, name, "辞書キー列挙")) return .dictionary_keys;
    if (std.mem.eql(u8, name, "辞書キー削除")) return .dictionary_remove;
    if (std.mem.eql(u8, name, "辞書キー存在")) return .dictionary_has;
    if (std.mem.eql(u8, name, "ハッシュキー列挙")) return .hash_keys;
    if (std.mem.eql(u8, name, "ハッシュ内容列挙")) return .hash_values;
    if (std.mem.eql(u8, name, "ハッシュキー削除")) return .hash_remove;
    if (std.mem.eql(u8, name, "ハッシュキー存在")) return .hash_has;
    if (std.mem.eql(u8, name, "真偽判定")) return .truth_label;
    if (std.mem.eql(u8, name, "掛")) return .repeat_multiply;
    if (std.mem.eql(u8, name, "文字数")) return .unicode_length;
    if (std.mem.eql(u8, name, "何文字目")) return .codepoint_find;
    if (std.mem.eql(u8, name, "文字始")) return .string_starts;
    if (std.mem.eql(u8, name, "文字終")) return .string_ends;
    if (std.mem.eql(u8, name, "配列要素数") or std.mem.eql(u8, name, "要素数") or std.mem.eql(u8, name, "LEN")) return .element_count;
    if (std.mem.eql(u8, name, "配列結合")) return .array_join;
    if (std.mem.eql(u8, name, "配列只結合")) return .array_join_only;
    if (std.mem.eql(u8, name, "配列検索")) return .array_search;
    if (std.mem.eql(u8, name, "配列ソート")) return .array_sort;
    if (std.mem.eql(u8, name, "配列数値変換")) return .array_numeric_convert;
    if (std.mem.eql(u8, name, "配列数値ソート")) return .array_numeric_sort;
    if (std.mem.eql(u8, name, "配列逆順")) return .array_reverse;
    if (std.mem.eql(u8, name, "配列挿入")) return .array_insert;
    if (std.mem.eql(u8, name, "配列一括挿入")) return .array_insert_many;
    if (std.mem.eql(u8, name, "配列削除") or std.mem.eql(u8, name, "配列切取")) return .array_cut;
    if (std.mem.eql(u8, name, "配列取出")) return .array_take;
    if (std.mem.eql(u8, name, "配列ポップ")) return .array_pop;
    if (std.mem.eql(u8, name, "配列プッシュ") or std.mem.eql(u8, name, "配列追加")) return .array_push;
    if (std.mem.eql(u8, name, "配列複製")) return .array_clone;
    if (std.mem.eql(u8, name, "配列範囲コピー")) return .array_range_copy;
    if (std.mem.eql(u8, name, "参照") or std.mem.eql(u8, name, "配列参照")) return .reference;
    if (std.mem.eql(u8, name, "配列足")) return .array_add;
    if (std.mem.eql(u8, name, "配列最大値")) return .array_maximum;
    if (std.mem.eql(u8, name, "配列最小値")) return .array_minimum;
    if (std.mem.eql(u8, name, "配列合計")) return .array_sum;
    if (std.mem.eql(u8, name, "配列入替")) return .array_swap;
    if (std.mem.eql(u8, name, "配列連番作成")) return .array_sequence;
    if (std.mem.eql(u8, name, "配列要素作成")) return .array_fill;
    if (std.mem.eql(u8, name, "表ピックアップ")) return .table_pickup;
    if (std.mem.eql(u8, name, "表完全一致ピックアップ")) return .table_exact_pickup;
    if (std.mem.eql(u8, name, "表検索")) return .table_search;
    if (std.mem.eql(u8, name, "表列数")) return .table_column_count;
    if (std.mem.eql(u8, name, "表行数")) return .table_row_count;
    if (std.mem.eql(u8, name, "表列取得")) return .table_column;
    if (std.mem.eql(u8, name, "表行列交換")) return .table_transpose;
    if (std.mem.eql(u8, name, "表右回転")) return .table_rotate;
    if (std.mem.eql(u8, name, "表重複削除")) return .table_unique;
    if (std.mem.eql(u8, name, "表列挿入")) return .table_insert_column;
    if (std.mem.eql(u8, name, "表列削除")) return .table_delete_column;
    if (std.mem.eql(u8, name, "表列合計")) return .table_column_sum;
    if (std.mem.eql(u8, name, "表曖昧検索")) return .table_regexp_search;
    if (std.mem.eql(u8, name, "表正規表現ピックアップ")) return .table_regexp_pickup;
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
    if (std.mem.eql(u8, name, "出現")) return .occurrence;
    if (std.mem.eql(u8, name, "切取")) return .cut;
    if (std.mem.eql(u8, name, "範囲切取")) return .cut_range;
    if (std.mem.eql(u8, name, "MID") or std.mem.eql(u8, name, "文字抜出")) return .substring_mid;
    if (std.mem.eql(u8, name, "LEFT") or std.mem.eql(u8, name, "文字左部分")) return .substring_left;
    if (std.mem.eql(u8, name, "RIGHT") or std.mem.eql(u8, name, "文字右部分")) return .substring_right;
    if (std.mem.eql(u8, name, "区切")) return .split_all;
    if (std.mem.eql(u8, name, "文字列分割")) return .split_first;
    if (std.mem.eql(u8, name, "文字削除")) return .string_remove;
    if (std.mem.eql(u8, name, "トリム") or std.mem.eql(u8, name, "空白除去")) return .trim_both;
    if (std.mem.eql(u8, name, "右トリム") or std.mem.eql(u8, name, "末尾空白除去")) return .trim_right;
    if (std.mem.eql(u8, name, "左トリム")) return .trim_left;
    if (std.mem.eql(u8, name, "置換")) return .replace_all;
    if (std.mem.eql(u8, name, "単置換")) return .replace_first;
    if (std.mem.eql(u8, name, "大文字変換")) return .uppercase;
    if (std.mem.eql(u8, name, "小文字変換")) return .lowercase;
    if (std.mem.eql(u8, name, "平仮名変換")) return .hiragana;
    if (std.mem.eql(u8, name, "カタカナ変換")) return .katakana;
    if (std.mem.eql(u8, name, "英数全角変換")) return .ascii_full_width;
    if (std.mem.eql(u8, name, "英数半角変換")) return .ascii_half_width;
    if (std.mem.eql(u8, name, "英数記号全角変換")) return .ascii_symbol_full_width;
    if (std.mem.eql(u8, name, "英数記号半角変換")) return .ascii_symbol_half_width;
    if (std.mem.eql(u8, name, "カタカナ全角変換")) return .katakana_full_width;
    if (std.mem.eql(u8, name, "カタカナ半角変換")) return .katakana_half_width;
    if (std.mem.eql(u8, name, "全角変換")) return .full_width;
    if (std.mem.eql(u8, name, "半角変換")) return .half_width;
    if (std.mem.eql(u8, name, "通貨形式")) return .currency_format;
    if (std.mem.eql(u8, name, "ゼロ埋")) return .zero_pad;
    if (std.mem.eql(u8, name, "空白埋")) return .space_pad;
    if (std.mem.eql(u8, name, "かなか判定")) return .hiragana_predicate;
    if (std.mem.eql(u8, name, "カタカナ判定")) return .katakana_predicate;
    if (std.mem.eql(u8, name, "数字判定")) return .digit_predicate;
    if (std.mem.eql(u8, name, "数列判定")) return .number_sequence_predicate;
    if (std.mem.eql(u8, name, "正規表現マッチ")) return .regexp_match;
    if (std.mem.eql(u8, name, "正規表現抽出")) return .regexp_extract;
    if (std.mem.eql(u8, name, "正規表現置換")) return .regexp_replace;
    if (std.mem.eql(u8, name, "正規表現区切")) return .regexp_split;
    if (std.mem.eql(u8, name, "JSON変換") or std.mem.eql(u8, name, "JSONエンコード") or std.mem.eql(u8, name, "JSON_E")) return .json_encode;
    if (std.mem.eql(u8, name, "JSONエンコード整形") or std.mem.eql(u8, name, "JSON_ES")) return .json_encode_pretty;
    if (std.mem.eql(u8, name, "JSON取得") or std.mem.eql(u8, name, "JSONデコード") or std.mem.eql(u8, name, "JSON_D")) return .json_decode;
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
    try std.testing.expectEqual(Command.cut, lookup("切取").?);
    try std.testing.expectEqual(Command.cut_range, lookup("範囲切取").?);
    try std.testing.expectEqual(Command.is_nan, lookup("NAN判定").?);
    try std.testing.expectEqual(Command.is_number_nan, lookup("非数判定").?);
    try std.testing.expectEqual(Command.array_maximum, lookup("配列最大値").?);
    try std.testing.expectEqual(Command.array_minimum, lookup("配列最小値").?);
    try std.testing.expectEqual(Command.array_sum, lookup("配列合計").?);
    try std.testing.expectEqual(Command.array_swap, lookup("配列入替").?);
    try std.testing.expectEqual(Command.array_sequence, lookup("配列連番作成").?);
    try std.testing.expectEqual(Command.array_fill, lookup("配列要素作成").?);
    try std.testing.expectEqual(Command.radix16, lookup("HEX").?);
    try std.testing.expectEqual(Command.radix, lookup("進数変換").?);
    try std.testing.expectEqual(Command.radix2, lookup("二進").?);
    try std.testing.expectEqual(Command.radix2_display, lookup("二進表示").?);
    try std.testing.expectEqual(Command.json_decode, lookup("JSON取得").?);
    try std.testing.expectEqual(Command.json_decode, lookup("JSONデコード").?);
    try std.testing.expectEqual(Command.json_decode, lookup("JSON_D").?);
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
    try std.testing.expectEqual(Command.dictionary_keys, lookup("辞書キー列挙").?);
    try std.testing.expectEqual(Command.dictionary_remove, lookup("辞書キー削除").?);
    try std.testing.expectEqual(Command.dictionary_has, lookup("辞書キー存在").?);
    try std.testing.expectEqual(Command.hash_keys, lookup("ハッシュキー列挙").?);
    try std.testing.expectEqual(Command.hash_values, lookup("ハッシュ内容列挙").?);
    try std.testing.expectEqual(Command.hash_remove, lookup("ハッシュキー削除").?);
    try std.testing.expectEqual(Command.hash_has, lookup("ハッシュキー存在").?);
    try std.testing.expectEqual(Command.truth_label, lookup("真偽判定").?);
    try std.testing.expectEqual(Command.repeat_multiply, lookup("掛").?);
    try std.testing.expectEqual(Command.unicode_length, lookup("文字数").?);
    try std.testing.expectEqual(Command.codepoint_find, lookup("何文字目").?);
    try std.testing.expectEqual(Command.string_starts, lookup("文字始").?);
    try std.testing.expectEqual(Command.string_ends, lookup("文字終").?);
    try std.testing.expectEqual(Command.element_count, lookup("配列要素数").?);
    try std.testing.expectEqual(Command.element_count, lookup("要素数").?);
    try std.testing.expectEqual(Command.element_count, lookup("LEN").?);
    try std.testing.expectEqual(Command.array_join, lookup("配列結合").?);
    try std.testing.expectEqual(Command.array_join_only, lookup("配列只結合").?);
    try std.testing.expectEqual(Command.array_search, lookup("配列検索").?);
    try std.testing.expectEqual(Command.array_sort, lookup("配列ソート").?);
    try std.testing.expectEqual(Command.array_numeric_convert, lookup("配列数値変換").?);
    try std.testing.expectEqual(Command.array_numeric_sort, lookup("配列数値ソート").?);
    try std.testing.expectEqual(Command.array_reverse, lookup("配列逆順").?);
    try std.testing.expectEqual(Command.array_insert, lookup("配列挿入").?);
    try std.testing.expectEqual(Command.array_insert_many, lookup("配列一括挿入").?);
    try std.testing.expectEqual(Command.array_cut, lookup("配列削除").?);
    try std.testing.expectEqual(Command.array_cut, lookup("配列切取").?);
    try std.testing.expectEqual(Command.array_take, lookup("配列取出").?);
    try std.testing.expectEqual(Command.array_pop, lookup("配列ポップ").?);
    try std.testing.expectEqual(Command.array_push, lookup("配列プッシュ").?);
    try std.testing.expectEqual(Command.array_push, lookup("配列追加").?);
    try std.testing.expectEqual(Command.array_clone, lookup("配列複製").?);
    try std.testing.expectEqual(Command.array_range_copy, lookup("配列範囲コピー").?);
    try std.testing.expectEqual(Command.reference, lookup("参照").?);
    try std.testing.expectEqual(Command.reference, lookup("配列参照").?);
    try std.testing.expectEqual(Command.array_add, lookup("配列足").?);
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
    try std.testing.expectEqual(Command.occurrence, lookup("出現").?);
    try std.testing.expectEqual(Command.substring_mid, lookup("MID").?);
    try std.testing.expectEqual(Command.substring_mid, lookup("文字抜出").?);
    try std.testing.expectEqual(Command.substring_left, lookup("LEFT").?);
    try std.testing.expectEqual(Command.substring_left, lookup("文字左部分").?);
    try std.testing.expectEqual(Command.substring_right, lookup("RIGHT").?);
    try std.testing.expectEqual(Command.substring_right, lookup("文字右部分").?);
    try std.testing.expectEqual(Command.split_all, lookup("区切").?);
    try std.testing.expectEqual(Command.split_first, lookup("文字列分割").?);
    try std.testing.expectEqual(Command.string_remove, lookup("文字削除").?);
    try std.testing.expectEqual(Command.trim_both, lookup("トリム").?);
    try std.testing.expectEqual(Command.trim_both, lookup("空白除去").?);
    try std.testing.expectEqual(Command.trim_right, lookup("右トリム").?);
    try std.testing.expectEqual(Command.trim_right, lookup("末尾空白除去").?);
    try std.testing.expectEqual(Command.trim_left, lookup("左トリム").?);
    try std.testing.expectEqual(Command.replace_all, lookup("置換").?);
    try std.testing.expectEqual(Command.replace_first, lookup("単置換").?);
    try std.testing.expectEqual(Command.regexp_match, lookup("正規表現マッチ").?);
    try std.testing.expectEqual(Command.regexp_extract, lookup("正規表現抽出").?);
    try std.testing.expectEqual(Command.regexp_replace, lookup("正規表現置換").?);
    try std.testing.expectEqual(Command.regexp_split, lookup("正規表現区切").?);
    try std.testing.expectEqual(Command.json_encode, lookup("JSON変換").?);
    try std.testing.expectEqual(Command.json_encode, lookup("JSONエンコード").?);
    try std.testing.expectEqual(Command.json_encode, lookup("JSON_E").?);
    try std.testing.expectEqual(Command.json_encode_pretty, lookup("JSONエンコード整形").?);
    try std.testing.expectEqual(Command.json_encode_pretty, lookup("JSON_ES").?);
    try std.testing.expectEqual(Command.uppercase, lookup("大文字変換").?);
    try std.testing.expectEqual(Command.lowercase, lookup("小文字変換").?);
    try std.testing.expectEqual(Command.hiragana, lookup("平仮名変換").?);
    try std.testing.expectEqual(Command.katakana, lookup("カタカナ変換").?);
    try std.testing.expectEqual(Command.ascii_full_width, lookup("英数全角変換").?);
    try std.testing.expectEqual(Command.ascii_half_width, lookup("英数半角変換").?);
    try std.testing.expectEqual(Command.ascii_symbol_full_width, lookup("英数記号全角変換").?);
    try std.testing.expectEqual(Command.ascii_symbol_half_width, lookup("英数記号半角変換").?);
    try std.testing.expectEqual(Command.katakana_full_width, lookup("カタカナ全角変換").?);
    try std.testing.expectEqual(Command.katakana_half_width, lookup("カタカナ半角変換").?);
    try std.testing.expectEqual(Command.full_width, lookup("全角変換").?);
    try std.testing.expectEqual(Command.half_width, lookup("半角変換").?);
    try std.testing.expectEqual(Command.currency_format, lookup("通貨形式").?);
    try std.testing.expectEqual(Command.zero_pad, lookup("ゼロ埋").?);
    try std.testing.expectEqual(Command.space_pad, lookup("空白埋").?);
    try std.testing.expectEqual(Command.hiragana_predicate, lookup("かなか判定").?);
    try std.testing.expectEqual(Command.katakana_predicate, lookup("カタカナ判定").?);
    try std.testing.expectEqual(Command.digit_predicate, lookup("数字判定").?);
    try std.testing.expectEqual(Command.number_sequence_predicate, lookup("数列判定").?);
    try std.testing.expect(lookup("未対応命令") == null);
}
