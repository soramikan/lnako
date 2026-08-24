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
    dynamic_execute,
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
    grouped: bool = false,
    loop_direction: LoopDirection = .automatic,
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
        .array_literal => "json_array",
        .object_literal => "json_obj",
        .binary_operator => "op",
        .unary_operator => "not",
        .function_call => "func",
        .sequence => "renbun",
        .array_reference => "ref_array",
        .array_value_reference => "ref_array_value",
        .property_reference => "ref_prop",
        .import => "require",
        .dynamic_execute => "calc_func",
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
