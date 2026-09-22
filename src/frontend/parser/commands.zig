const std = @import("std");
const ast = @import("../ast.zig");
const token_mod = @import("../token.zig");
const parser_mod = @import("../parser.zig");
const builder = @import("builder.zig");
const helpers = @import("helpers.zig");

const Parser = parser_mod.Parser;
const ParseFailure = parser_mod.ParseFailure;
const Token = token_mod.Token;
const isSequenceJosi = helpers.isSequenceJosi;
const isImplicitCallbackJosi = helpers.isImplicitCallbackJosi;
const isConditionalJosi = helpers.isConditionalJosi;
const isTargetJosi = helpers.isTargetJosi;
const isValueJosi = helpers.isValueJosi;
const isDefineTargetJosi = helpers.isDefineTargetJosi;
const isDefineValueJosi = helpers.isDefineValueJosi;
const isIncrementTargetPath = helpers.isIncrementTargetPath;

/// 現在位置の識別子を命令名として解決する。命令・制御構文へ確定した場合は
/// そのノードを返し、識別子が引数として扱われる場合は`null`を返す
/// （呼出し元は文の解析を継続する）。
pub fn resolveCommandName(
    self: *Parser,
    start: Token,
    arguments: *std.ArrayList(*ast.Node),
    chained_calls: *std.ArrayList(*ast.Node),
) ParseFailure!?*ast.Node {
    // 助詞付きの既知命令名は、公式`yCallFunc`と同じく命令として呼び出し、
    // 結果を次の命令の引数にする（`「abc」の要素数を表示`）。長い連鎖でも
    // プロセススタックを消費しないよう、再帰せず反復して解決する。
    while (self.isChainedBuiltinCommand(self.peek())) _ = try self.callChainedBuiltinCommand(arguments);
    // 助詞付きの識別子の直後に別の命令名が続く場合、手前は命令ではなく
    // 引数として扱う。例: `201でHを簡易HTTPサーバヘッダ出力`。
    // 「して」などの連文助詞と「には」のコールバック構文は従来どおり
    // その位置の識別子を命令として確定する。条件助詞（`ならば`等）は
    // 命令呼出しを条件文へ昇格させるため、引数として扱わない。
    if (self.peek().josi.len > 0 and
        !isSequenceJosi(self.peek().josi) and
        !isImplicitCallbackJosi(self.peek().josi) and
        !isConditionalJosi(self.peek().josi) and
        self.peekAhead(1).kind == .identifier)
    {
        return null;
    }
    // ループの語の直前にある未知の識別子も命令ではなく引数とする。
    // 公式はfunclist外の名をwordとしてスタックへ積むため、`AをBで反復`の
    // Bは命令呼出しではなく反復の変数になる。
    if (!self.isKnownCommandName(self.peek().value) and self.atLoopKeywordAhead(1)) return null;
    // 配列添字・プロパティ・@参照の直後に助詞が続く場合、識別子は命令名ではなく値として続行する。
    // 例: `1をA[0]に代入`, `1をA$fooに代入`。
    const next_kind = self.peekAhead(1).kind;
    if (next_kind == .left_bracket or next_kind == .at or next_kind == .property) return null;
    if ((self.identifierValue("増") or self.identifierValue("減")) and self.peekAhead(1).kind == .keyword_repeat) {
        return try self.parseFor(start, self.rangeArguments(arguments, chained_calls));
    }
    const command = self.advance();
    if (std.mem.eql(u8, command.value, "実行速度優先") or std.mem.eql(u8, command.value, "パフォーマンスモニタ適用")) {
        const option = if (arguments.items.len > 0) arguments.items[arguments.items.len - 1] else try builder.nop(self, start);
        if (chained_calls.items.len > 0) {
            const statement = try self.parseScopedMode(start, command, option);
            try chained_calls.append(self.allocator, statement);
            return try builder.makeNodeWithChildren(self, .block, start, try chained_calls.toOwnedSlice(self.allocator));
        }
        return try self.parseScopedMode(start, command, option);
    }
    if (std.mem.eql(u8, command.value, "条件分岐")) {
        const condition = if (arguments.items.len > 0) arguments.items[arguments.items.len - 1] else return self.fail(.invalid_control_statement, "『条件分岐』の値が必要です", command);
        if (chained_calls.items.len > 0) {
            const statement = try self.parseSwitch(start, condition);
            try chained_calls.append(self.allocator, statement);
            return try builder.makeNodeWithChildren(self, .block, start, try chained_calls.toOwnedSlice(self.allocator));
        }
        return try self.parseSwitch(start, condition);
    }
    if (try self.parseJapaneseCommand(start, command, arguments.items)) |statement| {
        if (chained_calls.items.len > 0) {
            try chained_calls.append(self.allocator, statement);
            return try builder.makeNodeWithChildren(self, .block, start, try chained_calls.toOwnedSlice(self.allocator));
        }
        return statement;
    }
    if (isImplicitCallbackJosi(command.josi)) {
        const statement = try self.parseImplicitCallbackCall(command, arguments.items);
        if (chained_calls.items.len > 0) {
            try chained_calls.append(self.allocator, statement);
            return try builder.makeNodeWithChildren(self, .block, start, try chained_calls.toOwnedSlice(self.allocator));
        }
        return statement;
    }
    const call = try self.makeCommandCall(command, try arguments.toOwnedSlice(self.allocator));
    // 『戻る』の直前の助詞付き呼出しは、公式`yReturn`の`popStack(['で','を'])`
    // と同じく呼出し結果を戻り値にする（`「abc」の要素数で戻る`は3を返す）。
    // 連文の途中でも、先行呼出しは連文ノード群として保持したまま最後の
    // 呼出しを戻り値へ渡す（`keyword_return`側の分岐がブロックを組み立てる）。
    // ただし条件助詞（`ならば`等）は条件文へ昇格するため、呼出しを返して
    // `parseStatement`の`parseIfThen`へ委ねる（`等しいならば戻る`は条件文）。
    if (command.josi.len > 0 and !isConditionalJosi(command.josi) and self.at(.keyword_return)) {
        arguments.* = .empty;
        try arguments.*.append(self.allocator, call);
        return null;
    }
    // 助詞付きの関数呼出しの直後にループの語が続く場合、公式`yCall`は
    // 呼出しをスタックに積んだまま制御構文へ渡す（`Aが5以下の間`は
    // `以下(A,5)`を条件とする`間`になる）。呼出しを引数として保持し、
    // 文の解析を続けて制御構文の分岐へ委ねる。
    if (command.josi.len > 0 and chained_calls.items.len == 0 and self.atLoopKeyword()) {
        arguments.* = .empty;
        try arguments.*.append(self.allocator, call);
        return null;
    }
    if (isSequenceJosi(command.josi)) {
        try chained_calls.append(self.allocator, call);
        arguments.* = .empty;
        try arguments.*.append(self.allocator, try self.implicitIt(command));
        return null;
    }
    if (chained_calls.items.len > 0) {
        try chained_calls.append(self.allocator, call);
        return try builder.makeNodeWithChildren(self, .block, start, try chained_calls.toOwnedSlice(self.allocator));
    }
    return call;
}

/// 連文（『して』等）で積み上げた呼出しがある文をblockへまとめて返す。
/// 公式は`して`で文を終わらせて後続を別の文として並べるため、戻る・
/// 繰り返し・取り込みなどの確定文も連鎖の一部として残す必要がある。
pub fn finishChained(self: *Parser, start: Token, chained_calls: *std.ArrayList(*ast.Node), statement: *ast.Node) ParseFailure!*ast.Node {
    if (chained_calls.items.len == 0) return statement;
    try chained_calls.append(self.allocator, statement);
    return builder.makeNodeWithChildren(self, .block, start, try chained_calls.toOwnedSlice(self.allocator));
}

/// 連文継続用にarguments先頭へ挿入した暗黙の『それ』を、範囲引数を
/// 先頭から読む『繰り返す』のために除外する。回数・条件・反復は末尾の
/// 引数だけを使うため影響しないが、範囲繰り返しは先頭から順に
/// ループ変数・開始値・終了値を読むため、マーカーを残すと一つずれて
/// 消費される。暗黙マーカーはjosi・raw_josiが共に空のword『それ』で、
/// ユーザーが書いた`それを`（josi=を）とは区別できる。
pub fn rangeArguments(self: *Parser, arguments: *std.ArrayList(*ast.Node), chained_calls: *std.ArrayList(*ast.Node)) []const *ast.Node {
    _ = self;
    if (chained_calls.items.len > 0 and arguments.items.len > 0 and
        arguments.items[0].kind == .word and std.mem.eql(u8, arguments.items[0].value, "それ") and
        arguments.items[0].josi.len == 0 and arguments.items[0].raw_josi.len == 0)
    {
        return arguments.items[1..];
    }
    return arguments.items;
}

/// 公式の`func token`相当（既知の命令名）かどうか。
pub fn isBuiltinCommandName(self: *Parser, value: []const u8) bool {
    for (self.builtin_commands) |name| if (std.mem.eql(u8, name, value)) return true;
    return false;
}

/// 公式の`func token`として解決できる名前かどうか。公式は組み込み命令に
/// 加えて、ソース内で定義された関数も`func token`にする。
pub fn isKnownCommandName(self: *Parser, value: []const u8) bool {
    if (self.isBuiltinCommandName(value)) return true;
    for (self.user_functions) |name| if (std.mem.eql(u8, name, value)) return true;
    return false;
}

/// 現在位置の識別子が「助詞付きの既知命令名」で、直後にも識別子が続くか。
/// 公式`yCallFunc`はこの位置の命令を呼び出し、結果を次の命令の引数にする。
pub fn isChainedBuiltinCommand(self: *Parser, token: Token) bool {
    if (token.kind != .identifier) return false;
    // 条件助詞（`ならば`等）は連鎖呼出しの引数にならない。
    // 公式の字句解析は『ならば』を独立トークンとして式を切断するため、
    // `XならばY`は常に『もし』省略形の条件文になる（`等しいならばAを戻る`
    // の`等しい`を引数チェーンへ入れない）。
    if (token.josi.len == 0 or isSequenceJosi(token.josi) or isImplicitCallbackJosi(token.josi) or
        isConditionalJosi(token.josi)) return false;
    if (self.peekAhead(1).kind != .identifier) return false;
    return self.isBuiltinCommandName(token.value);
}

/// 現在位置の助詞付き命令を呼び出し、結果を引数リストへ置き換える。
/// 置き換えた場合は`true`を返す。
pub fn callChainedBuiltinCommand(self: *Parser, arguments: *std.ArrayList(*ast.Node)) ParseFailure!bool {
    if (!self.isChainedBuiltinCommand(self.peek())) return false;
    const command = self.advance();
    const call = try self.makeCommandCall(command, try arguments.toOwnedSlice(self.allocator));
    arguments.* = .empty;
    try arguments.append(self.allocator, call);
    return true;
}

pub fn makeCommandCall(self: *Parser, command: Token, arguments: []*ast.Node) ParseFailure!*ast.Node {
    const call = try builder.makeNodeWithChildren(self, .function_call, command, arguments);
    call.name = command.value;
    call.josi = if (isSequenceJosi(command.josi)) "して" else command.josi;
    call.raw_josi = command.raw_josi;
    call.command_call = true;
    return call;
}

pub fn parseImplicitCallbackCall(self: *Parser, command: Token, arguments: []const *ast.Node) ParseFailure!*ast.Node {
    const callback_arguments: []ast.Argument = if (self.at(.left_paren)) try self.parseArguments() else &.{};
    if (self.at(.eol)) self.skipEols();
    const body = try self.parseBlock(.{ .end = true });
    try self.requireEnd("『には』コールバック");
    const callback = try builder.makeNodeWithChildren(self, .anonymous_function, command, try builder.copyChildren(self, &.{body}));
    callback.arguments = callback_arguments;
    callback.josi = "";
    callback.raw_josi = "";
    const call = try self.makeCommandCall(command, try builder.prepend(self, callback, arguments));
    call.josi = "して";
    return call;
}

pub fn implicitIt(self: *Parser, token: Token) ParseFailure!*ast.Node {
    const result = try builder.makeNode(self, .word, token);
    result.value = "それ";
    result.josi = "";
    result.raw_josi = "";
    return result;
}

pub fn parseJapaneseCommand(self: *Parser, start: Token, command: Token, arguments: []const *ast.Node) ParseFailure!?*ast.Node {
    const is_assign = std.mem.eql(u8, command.value, "代入");
    const is_define = std.mem.eql(u8, command.value, "定");
    const is_increment = std.mem.eql(u8, command.value, "増") or std.mem.eql(u8, command.value, "減");
    if (!is_assign and !is_define and !is_increment) return null;

    if (arguments.len == 0) return self.fail(.invalid_assignment, "代入先と値の指定が必要です", command);

    // 公式ySadameruは値の後ろの `{公開}`/`{非公開}` 属性を受理する。
    const attribute_is_export = if (is_define) try self.parseVariableAttribute(self.export_default) else self.export_default;

    // 「に代入」は「に」が代入先、「を」が値。「に定める」は「を」が定義対象、「に」が値。

    var target_index: ?usize = null;
    var value_index: ?usize = null;
    for (arguments, 0..) |arg, i| {
        const arg_is_target = if (is_define) isDefineTargetJosi(arg.josi) else isTargetJosi(arg.josi);
        const arg_is_value = if (is_define) isDefineValueJosi(arg.josi) else isValueJosi(arg.josi);
        if (arg_is_target) {
            if (target_index == null) target_index = i;
        } else if (arg_is_value) {
            if (value_index == null) value_index = i;
        }
    }

    if (is_assign or is_define) {
        var target: *ast.Node = undefined;
        var value: *ast.Node = undefined;
        if (target_index) |ti| {
            target = arguments[ti];
            // 公式ySadameruは値の助詞が無ければnop（=0）を初期値にする。
            value = if (value_index) |vi| arguments[vi] else if (is_define) try builder.omittedValue(self, command) else if (arguments.len > 1 and ti != 0) arguments[0] else try self.implicitIt(command);
        } else if (value_index) |vi| {
            value = arguments[vi];
            target = if (vi == 0) try self.implicitIt(command) else arguments[0];
        } else {
            target = arguments[0];
            value = if (arguments.len > 1) arguments[1] else try self.implicitIt(command);
        }
        // 公式ySadameruの定義対象は`word`に限る。配列要素・プロパティは
        // 『(定数名)を(値)に定める』の形ではないため文法エラーになる。
        if (is_define and target.kind != .word)
            return self.fail(.invalid_assignment, "『定める』文で定数が見当たりません。『(定数名)を(値)に定める』のように使います。", command);
        if (!is_define and target.kind != .word and target.kind != .array_reference and target.kind != .property_reference)
            return self.fail(.invalid_assignment, "代入先は変数・配列・プロパティである必要があります", command);

        const kind: ast.Kind = if (is_define and target.kind == .word)
            .variable_definition
        else switch (target.kind) {
            .array_reference => .array_assignment,
            .property_reference => .property_assignment,
            else => .assignment,
        };
        const target_children = if (target.kind == .array_reference or target.kind == .property_reference)
            try builder.assignmentPath(self, target)
        else
            target.children;
        const children = if (target_children.len == 0)
            try builder.copyChildren(self, &.{value})
        else
            try builder.prepend(self, value, target_children);
        const result = try builder.makeNodeWithChildren(self, kind, start, children);
        result.name = if (target.kind == .word) target.value else if (target.name.len > 0) target.name else target.value;
        result.josi = "";
        // `Aを1に定める`の宣言も公式ySadameru同様にモジュール変数として
        // 既定公開する。ASTのis_exportは既定falseなので、ここで明示する。
        if (kind == .variable_definition) {
            result.is_export = attribute_is_export;
            // 公式ySadameruは`createVar(word, true, ...)`で定数を作る。
            result.is_const = is_define;
        }
        result.check_array_init = kind == .array_assignment and (self.mode.dncl or self.mode.dncl2);
        return result;
    }

    // 公式yIncDec相当: 『を』助詞の直近引数が増減対象、『だけ』または無助詞の直近引数が増減量。
    // 『に』『から』等の助詞対象や、定数・式・prop[i]形への増減は構文エラー。
    var inc_target_index: ?usize = null;
    var inc_amount_index: ?usize = null;
    for (arguments, 0..) |arg, i| {
        if (std.mem.eql(u8, arg.josi, "を")) {
            inc_target_index = i;
        } else if (std.mem.eql(u8, arg.josi, "だけ") or arg.josi.len == 0) {
            inc_amount_index = i;
        }
    }
    const inc_usage = try std.fmt.allocPrint(self.allocator, "『{s}』文で定数が見当たりません。『(変数名)を(値)だけ{s}』のように使います。", .{ command.value, command.value });
    const inc_target = if (inc_target_index) |ti|
        arguments[ti]
    else
        return self.fail(.invalid_assignment, inc_usage, command);
    if (!isIncrementTargetPath(inc_target))
        return self.fail(.invalid_assignment, inc_usage, command);
    var amount: *ast.Node = undefined;
    if (inc_amount_index) |ai| {
        amount = arguments[ai];
    } else {
        const one = try builder.makeNode(self, .number, command);
        one.value = "1";
        one.number_value = 1;
        amount = one;
    }
    if (std.mem.eql(u8, command.value, "減")) {
        const minus_one = try builder.makeNode(self, .number, command);
        minus_one.value = "-1";
        minus_one.number_value = -1;
        amount = try builder.makeNodeWithChildren(self, .binary_operator, command, try builder.copyChildren(self, &.{ amount, minus_one }));
        amount.operator = "*";
        amount.josi = "";
    }
    if (inc_target.kind == .word) {
        const result = try builder.makeNodeWithChildren(self, .increment, start, try builder.copyChildren(self, &.{amount}));
        result.name = inc_target.value;
        result.josi = "";
        return result;
    }
    // A[i]をN増やす: 公式はコンテナと添字を一度だけ評価し、要素が未定義なら0に初期化する
    const target_path = try builder.assignmentPath(self, inc_target);
    const children = try builder.prepend(self, amount, target_path);
    const result = try builder.makeNodeWithChildren(self, .increment_indexed, start, children);
    result.name = if (inc_target.name.len > 0) inc_target.name else inc_target.value;
    result.josi = "";
    return result;
}
