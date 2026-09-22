const token_mod = @import("token.zig");

pub const Span = token_mod.Span;

/// なでしこ構文を意味解析へ渡すための、所有権を持たないASTノード。
/// 文字列・子ノード配列・ノード本体は ParseResult の arena に属する。
pub const Kind = enum {
    nop,
    eol,
    number,
    bigint,
    boolean,
    null_value,
    word,
    string,
    string_template,
    block,
    if_statement,
    while_statement,
    post_test_loop,
    for_statement,
    foreach_statement,
    repeat_times,
    switch_statement,
    try_except,
    function_definition,
    anonymous_function,
    return_statement,
    continue_statement,
    break_statement,
    test_definition,
    assignment,
    property_assignment,
    array_assignment,
    variable_definition,
    variable_list_definition,
    increment,
    /// A[i]をN増やす 相当。name=対象変数、children=[増減量, 添字...]。
    /// 公式の AstInc(name=ref_array) に相当し、kindNameは "inc" を共有する。
    increment_indexed,
    array_literal,
    object_literal,
    binary_operator,
    unary_operator,
    function_call,
    call_value,
    function_pointer,
    sequence,
    array_reference,
    array_value_reference,
    property_reference,
    import,
    performance_monitor,
    speed_mode,
    run_mode,
};

pub const Argument = struct {
    name: []const u8,
    josi: []const u8,
    span: Span,
};

pub const LoopDirection = enum { automatic, up, down };

/// 後段が型別構造体へ変換せず巡回できる、安定した共通ノード表現。
/// kind に不要なフィールドは既定値のままにする。
pub const Node = struct {
    kind: Kind,
    span: Span,
    end_span: Span,
    name: []const u8 = "",
    value: []const u8 = "",
    number_value: ?f64 = null,
    josi: []const u8 = "",
    raw_josi: []const u8 = "",
    operator: []const u8 = "",
    children: []*Node = &.{},
    arguments: []Argument = &.{},
    is_const: bool = false,
    is_export: bool = false,
    is_async: bool = false,
    check_array_init: bool = false,
    /// 読み取り側の配列添字で、カンマの直前に現れた裸の単語。
    /// 公式はfunc tokenをカンマ直前では値として受理しないため、
    /// 意味解析で関数へ解決された場合は『配列アクセスで指定ミス』にする。
    bare_index_word: bool = false,
    grouped: bool = false,
    /// C風の `命令(...)` 呼び出しだけを、助詞構文と区別する。
    is_c_style_call: bool = false,
    /// 連文継続用に`implicitIt`が挿入した暗黙の『それ』マーカー。
    /// ユーザーが記述する`それ`・`(それ)`は値として残るため、
    /// 見た目の助詞情報では区別できず生成元フラグでのみ判定する。
    is_implicit_it: bool = false,
    /// 助詞付きの命令名を解決して作った呼出し（公式の`func token`の呼出し）。
    /// 範囲演算子（`1…5`）のように演算子から作られる`function_call`と区別し、
    /// 公式`ySentence`の「もし」省略形の昇格判定にだけ使う。
    command_call: bool = false,
    loop_direction: LoopDirection = .automatic,
    /// 関数本体内の実効取り込み文だけが持つ、取り込み先トップレベル文の
    /// 複製。公式は取り込み先トークンを取り込み文の位置へそのまま展開する
    /// ため、関数内では取り込み先の変数・文が呼び出し元関数のローカルに
    /// なる。module_graph が複製を接続し、意味解析は呼び出し元スコープの
    /// まま取り込み先モジュール名で名前解決する。
    expansion: []const *Node = &.{},
};

pub fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .if_statement => "if",
        .while_statement => "while",
        .post_test_loop => "atohantei",
        .for_statement => "for",
        .foreach_statement => "foreach",
        .switch_statement => "switch",
        .function_definition => "def_func",
        .anonymous_function => "func_obj",
        .return_statement => "return",
        .continue_statement => "continue",
        .break_statement => "break",
        .test_definition => "def_test",
        .assignment => "let",
        .property_assignment => "let_prop",
        .array_assignment => "let_array",
        .variable_definition => "def_local_var",
        .variable_list_definition => "def_local_varlist",
        .increment => "inc",
        .increment_indexed => "inc",
        .array_literal => "json_array",
        .object_literal => "json_obj",
        .binary_operator => "op",
        .unary_operator => "not",
        .function_call => "func",
        .function_pointer => "func_pointer",
        .sequence => "renbun",
        .array_reference => "ref_array",
        .array_value_reference => "ref_array_value",
        .property_reference => "ref_prop",
        .import => "require",
        else => @tagName(kind),
    };
}

pub fn emptySpan() Span {
    return .{
        .start = 0,
        .end = 0,
        .source_start = 0,
        .source_end = 0,
        .line = 0,
        .column = 1,
    };
}
