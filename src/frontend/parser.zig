const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const lexer = @import("lexer.zig");
const syntax_transform = @import("syntax_transform.zig");
const token_mod = @import("token.zig");

const Token = token_mod.Token;
const Kind = token_mod.Kind;

pub const Error = lexer.Error || syntax_transform.Error || std.mem.Allocator.Error;

pub const ParseResult = struct {
    stream: lexer.TokenStream,
    filename: []const u8,
    root: ?*ast.Node,
    diagnostics: []diagnostic.Diagnostic,

    pub fn deinit(self: *ParseResult) void {
        self.stream.deinit();
        self.* = undefined;
    }

    pub fn succeeded(self: ParseResult) bool {
        return self.root != null and self.diagnostics.len == 0;
    }
};

/// 字句解析・構文変換を含めてソース全体を構文解析する。
/// 構文エラーは Zig の error ではなく diagnostics と root=null で返す。
pub fn parse(backing_allocator: std.mem.Allocator, source: []const u8, filename: []const u8) Error!ParseResult {
    var stream = try lexer.tokenize(backing_allocator, source);
    errdefer stream.deinit();
    try syntax_transform.apply(&stream);

    const allocator = stream.arena.allocator();
    const owned_filename = try allocator.dupe(u8, filename);
    var parser = Parser{
        .allocator = allocator,
        .tokens = stream.tokens,
        .filename = owned_filename,
        .mode = stream.mode,
    };
    const root = parser.parseProgram() catch |err| switch (err) {
        error.ParseFailed => null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const diagnostics = try parser.diagnostics.toOwnedSlice(allocator);
    return .{
        .stream = stream,
        .filename = owned_filename,
        .root = root,
        .diagnostics = diagnostics,
    };
}

const ParseFailure = error{ ParseFailed, OutOfMemory };

const Stop = packed struct {
    end: bool = false,
    else_branch: bool = false,
    error_branch: bool = false,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    filename: []const u8,
    mode: token_mod.Mode,
    index: usize = 0,
    diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty,

    fn parseProgram(self: *Parser) ParseFailure!*ast.Node {
        const root = try self.parseBlock(.{});
        if (!self.at(.eof)) return self.fail(.unexpected_token, "プログラム末尾に解釈できないトークンがあります", self.peek());
        return root;
    }

    fn parseBlock(self: *Parser, stop: Stop) ParseFailure!*ast.Node {
        const first = self.peek();
        var children: std.ArrayList(*ast.Node) = .empty;
        while (!self.at(.eof) and !self.isStop(stop)) {
            const before = self.index;
            const node = try self.parseStatement();
            try children.append(self.allocator, node);
            if (self.index == before) return self.fail(.unexpected_token, "構文解析を進められません", self.peek());
        }
        return self.makeNodeWithChildren(.block, first, try children.toOwnedSlice(self.allocator));
    }

    fn parseStatement(self: *Parser) ParseFailure!*ast.Node {
        const token = self.peek();
        if (self.isImportDirective()) return self.parseImportDirective();
        if (token.kind == .identifier and std.mem.eql(u8, token.value, "それ") and std.mem.eql(u8, token.josi, "は")) return self.parseImplicitResultAssignment();
        return switch (token.kind) {
            .eol => self.parseEol(),
            .keyword_if => self.parseIf(),
            .keyword_after_test => self.parsePostTestLoop(),
            .keyword_error_guard => self.parseTryExcept(),
            .keyword_break => self.simpleStatement(.break_statement),
            .keyword_continue => self.simpleStatement(.continue_statement),
            .def_func => self.parseFunctionDefinition(false),
            .def_test => self.parseFunctionDefinition(true),
            .keyword_let => self.parseDeclaration(false),
            .keyword_const => self.parseDeclaration(true),
            .keyword_import => self.parseImport(),
            .question_display => self.parseDebugDisplay(),
            .keyword_here_end, .keyword_else, .keyword_error => self.fail(.unexpected_token, "対応する構文の開始がありません", token),
            else => blk: {
                if (self.isModeDirective()) break :blk self.parseModeDirective();
                if (self.canStartAssignment()) break :blk self.parseAssignment();
                break :blk self.parseCallOrControl();
            },
        };
    }

    fn parseImplicitResultAssignment(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        const value = try self.parseCallExpression();
        const node = try self.makeNodeWithChildren(.assignment, start, try self.copyChildren(&.{value}));
        node.name = "それ";
        node.josi = "";
        return node;
    }

    fn parseEol(self: *Parser) ParseFailure!*ast.Node {
        const token = self.advance();
        return self.makeNode(.eol, token);
    }

    fn simpleStatement(self: *Parser, kind: ast.Kind) ParseFailure!*ast.Node {
        const token = self.advance();
        return self.makeNode(kind, token);
    }

    fn parseModeDirective(self: *Parser) ParseFailure!*ast.Node {
        const first = self.advance();
        if (first.kind == .not) {
            const directive = try self.require(.identifier, "『!』の後ろにモード名が必要です");
            if (std.mem.eql(u8, directive.value, "モジュール公開既定値")) {
                _ = try self.require(.equal, "モジュール公開既定値に『=』が必要です");
                _ = try self.parseExpression(0);
                return self.makeNode(.eol, first);
            }
            const node = try self.makeNode(.run_mode, first);
            node.value = if (std.mem.eql(u8, directive.value, "厳チェック")) "厳しくチェック" else directive.value;
            return node;
        }
        const node = try self.makeNode(.run_mode, first);
        node.value = first.value;
        return node;
    }

    fn isModeDirective(self: *Parser) bool {
        const token = self.peek();
        if (token.kind == .not) {
            const next = self.peekAhead(1);
            return next.kind == .identifier and (std.mem.eql(u8, next.value, "厳チェック") or
                std.mem.eql(u8, next.value, "モジュール公開既定値") or
                std.mem.eql(u8, next.value, "非同期モード"));
        }
        return token.kind == .keyword_mode or token.kind == .keyword_async or
            (token.kind == .identifier and (std.mem.eql(u8, token.value, "厳チェック") or
                std.mem.eql(u8, token.value, "モジュール公開既定値") or
                std.mem.eql(u8, token.value, "実行速度優先") or
                std.mem.eql(u8, token.value, "パフォーマンスモニタ適用")));
    }

    fn parseIf(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        self.skipCommas();
        const condition = try self.parseExpression(0);
        if (!isConditionalJosi(condition.josi) and !self.identifierValue("ならば")) {
            return self.fail(.invalid_control_statement, "『もし』文の条件末尾に『ならば』が必要です", self.peek());
        }
        if (self.identifierValue("ならば")) _ = self.advance();
        clearConditionalJosi(condition);

        var multiline = false;
        var true_block: *ast.Node = undefined;
        if (self.at(.eol)) {
            multiline = true;
            self.skipEols();
            true_block = try self.parseBlock(.{ .end = true, .else_branch = true });
        } else {
            true_block = try self.wrapSingle(try self.parseStatement());
        }

        var false_block = try self.emptyBlock(self.peek());
        if (self.at(.keyword_else)) {
            _ = self.advance();
            self.skipCommas();
            if (self.at(.eol)) {
                self.skipEols();
                false_block = try self.parseBlock(.{ .end = true });
            } else {
                false_block = try self.wrapSingle(try self.parseStatement());
            }
        }
        if (multiline) try self.requireEnd("『もし』文");
        return self.makeNodeWithChildren(.if_statement, start, try self.copyChildren(&.{ condition, true_block, false_block }));
    }

    fn parsePostTestLoop(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        if (self.at(.keyword_repeat)) _ = self.advance();
        if (self.at(.keyword_here_from)) _ = self.advance();
        self.skipEols();
        const body = try self.parseBlock(.{ .end = true });
        if (self.at(.keyword_here_end)) _ = self.advance();
        self.skipCommas();
        var condition: *ast.Node = if (self.at(.eol) or self.at(.eof)) try self.numberOne(start) else try self.parseExpression(0);
        if (self.identifierValue("なる") and (std.mem.eql(u8, self.peek().josi, "まで") or std.mem.eql(u8, self.peek().josi, "までの"))) {
            const until = self.advance();
            condition = try self.unary("not", condition, until);
            condition.josi = "";
            condition.raw_josi = "";
        }
        if (self.at(.keyword_repeat_while)) _ = self.advance();
        return self.makeNodeWithChildren(.post_test_loop, start, try self.copyChildren(&.{ condition, body }));
    }

    fn parseTryExcept(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        self.skipEols();
        const body = try self.parseBlock(.{ .error_branch = true });
        if (!self.at(.keyword_error)) return self.fail(.invalid_control_statement, "『エラー監視』に『エラーならば』がありません", self.peek());
        const error_token = self.advance();
        if (!isConditionalJosi(error_token.josi) and self.identifierValue("ならば")) _ = self.advance();
        self.skipEols();
        const handler = try self.parseBlock(.{ .end = true });
        try self.requireEnd("『エラー監視』文");
        return self.makeNodeWithChildren(.try_except, start, try self.copyChildren(&.{ body, handler }));
    }

    fn parseFunctionDefinition(self: *Parser, is_test: bool) ParseFailure!*ast.Node {
        const start = self.advance();
        var is_export = true;
        if (self.at(.left_brace)) {
            _ = self.advance();
            const attribute = try self.require(.identifier, "関数属性が必要です");
            if (std.mem.eql(u8, attribute.value, "非公開")) is_export = false;
            if (std.mem.eql(u8, attribute.value, "公開") or std.mem.eql(u8, attribute.value, "エクスポート")) is_export = true;
            _ = try self.require(.right_brace, "関数属性を閉じる『}』が必要です");
        }

        var arguments: []ast.Argument = &.{};
        if (self.at(.left_paren)) arguments = try self.parseArguments();
        const name_token = try self.require(.identifier, "関数名が必要です");
        if (arguments.len == 0 and self.at(.left_paren)) arguments = try self.parseArguments();
        if (name_token.josi.len != 0 and !std.mem.eql(u8, name_token.josi, "とは")) {
            return self.fail(.invalid_function_definition, "関数名の後ろには『とは』が必要です", name_token);
        }

        const body = if (self.at(.eol) or self.at(.keyword_here_from)) blk: {
            if (self.at(.keyword_here_from)) _ = self.advance();
            self.skipEols();
            const block = try self.parseBlock(.{ .end = true });
            try self.requireEnd("関数定義");
            break :blk block;
        } else try self.wrapSingle(try self.parseStatement());

        const node = try self.makeNodeWithChildren(if (is_test) .test_definition else .function_definition, start, try self.copyChildren(&.{body}));
        node.name = if (is_test) tokenStem(name_token) else name_token.value;
        node.arguments = arguments;
        node.is_export = is_export;
        return node;
    }

    fn parseArguments(self: *Parser) ParseFailure![]ast.Argument {
        _ = try self.require(.left_paren, "引数を始める『(』が必要です");
        var arguments: std.ArrayList(ast.Argument) = .empty;
        while (!self.at(.right_paren) and !self.at(.eof)) {
            if (self.at(.comma)) {
                _ = self.advance();
                continue;
            }
            const token = try self.require(.identifier, "引数名が必要です");
            try arguments.append(self.allocator, .{ .name = token.value, .josi = token.josi, .span = token.span });
        }
        _ = try self.require(.right_paren, "引数定義を閉じる『)』が必要です");
        return arguments.toOwnedSlice(self.allocator);
    }

    fn parseDeclaration(self: *Parser, is_const: bool) ParseFailure!*ast.Node {
        const start = self.advance();
        if (self.at(.left_bracket)) {
            const names = try self.parseArrayLiteral();
            _ = try self.require(.equal, "変数一覧の後ろに『=』が必要です");
            const value = try self.parseCallExpression();
            const node = try self.makeNodeWithChildren(.variable_list_definition, start, try self.copyChildren(&.{value}));
            node.arguments = try self.namesToArguments(names.children);
            node.is_const = is_const;
            return node;
        }
        const name = try self.require(.identifier, "変数名が必要です");
        _ = try self.require(.equal, "変数宣言に『=』が必要です");
        const value = try self.parseCallExpression();
        const node = try self.makeNodeWithChildren(.variable_definition, start, try self.copyChildren(&.{value}));
        node.name = name.value;
        node.is_const = is_const;
        return node;
    }

    fn parseImport(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        const path = try self.parseExpression(0);
        const node = try self.makeNodeWithChildren(.import, start, try self.copyChildren(&.{path}));
        node.value = path.value;
        return node;
    }

    fn isImportDirective(self: *Parser) bool {
        if (!self.at(.not) or (self.peekAhead(1).kind != .string and self.peekAhead(1).kind != .string_template)) return false;
        var offset: usize = 2;
        while (self.peekAhead(offset).kind != .eol and self.peekAhead(offset).kind != .eof) : (offset += 1) {
            if (self.peekAhead(offset).kind == .keyword_import) return true;
        }
        return false;
    }

    fn parseImportDirective(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        const path_token = self.advance();
        const path = try self.valueNode(.string, path_token);
        _ = try self.require(.keyword_import, "取り込み文に『取り込む』が必要です");
        const node = try self.makeNodeWithChildren(.import, start, try self.copyChildren(&.{path}));
        node.value = path.value;
        node.josi = "";
        return node;
    }

    fn parseDebugDisplay(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        const value = try self.parseExpression(0);
        const node = try self.makeNodeWithChildren(.function_call, start, try self.copyChildren(&.{value}));
        node.name = "ハテナ関数実行";
        return node;
    }

    fn canStartAssignment(self: *Parser) bool {
        var i = self.index;
        var nesting: usize = 0;
        while (i < self.tokens.len) : (i += 1) {
            const token = self.tokens[i];
            switch (token.kind) {
                .eol, .eof => return false,
                .left_paren, .left_bracket, .left_brace => nesting += 1,
                .right_paren, .right_bracket, .right_brace => if (nesting > 0) {
                    nesting -= 1;
                },
                .equal => if (nesting == 0 and !std.mem.eql(u8, token.lexeme, "==")) return true,
                else => {},
            }
        }
        return false;
    }

    fn parseAssignment(self: *Parser) ParseFailure!*ast.Node {
        const start = self.peek();
        var targets: std.ArrayList(*ast.Node) = .empty;
        try targets.append(self.allocator, try self.parseLValue());
        while (self.at(.comma)) {
            _ = self.advance();
            try targets.append(self.allocator, try self.parseLValue());
        }
        const declaration_from_towa = self.at(.keyword_let) and std.mem.eql(u8, targets.items[0].josi, "とは");
        if (declaration_from_towa) _ = self.advance();
        _ = try self.require(.equal, "代入文に『=』が必要です");
        const value = try self.parseCallExpression();
        if (targets.items.len > 1) {
            const result = try self.makeNodeWithChildren(.variable_list_definition, start, try self.copyChildren(&.{value}));
            result.arguments = try self.namesToArguments(targets.items);
            return result;
        }
        const target = targets.items[0];
        const kind: ast.Kind = switch (target.kind) {
            .array_reference => .array_assignment,
            .property_reference => .property_assignment,
            else => if (declaration_from_towa) .variable_definition else .assignment,
        };
        const target_children = if (target.kind == .array_reference or target.kind == .property_reference)
            try self.assignmentPath(target)
        else
            target.children;
        const children = if (target_children.len == 0)
            try self.copyChildren(&.{value})
        else
            try self.prepend(value, target_children);
        const node = try self.makeNodeWithChildren(kind, start, children);
        node.name = if (target.name.len > 0) target.name else target.value;
        node.josi = "";
        node.check_array_init = self.mode == .dncl or self.mode == .dncl2;
        return node;
    }

    fn parseLValue(self: *Parser) ParseFailure!*ast.Node {
        const token = try self.require(.identifier, "代入先の変数名が必要です");
        var base = try self.valueNode(.word, token);
        while (true) {
            if (self.at(.at)) {
                const at_token = self.advance();
                const index = try self.parsePrimary();
                base = try self.reference(.array_reference, base, &.{index}, at_token);
                continue;
            }
            if (self.at(.left_bracket)) {
                const open = self.advance();
                var indexes: std.ArrayList(*ast.Node) = .empty;
                while (!self.at(.right_bracket) and !self.at(.eof)) {
                    try indexes.append(self.allocator, try self.parseExpression(0));
                    if (!self.at(.comma)) break;
                    _ = self.advance();
                }
                const close = try self.require(.right_bracket, "配列添字を閉じる『]』が必要です");
                base = try self.reference(.array_reference, base, try indexes.toOwnedSlice(self.allocator), open);
                base.josi = close.josi;
                continue;
            }
            if (self.at(.property)) {
                const property_token = self.advance();
                const name = self.advance();
                if (name.kind != .identifier and name.kind != .string) return self.fail(.expected_name, "『$』の後ろにプロパティ名が必要です", name);
                const property = try self.valueNode(.string, name);
                base = try self.reference(.property_reference, base, &.{property}, property_token);
                base.josi = name.josi;
                continue;
            }
            break;
        }
        return base;
    }

    fn parseCallOrControl(self: *Parser) ParseFailure!*ast.Node {
        const start = self.peek();
        var arguments: std.ArrayList(*ast.Node) = .empty;
        var chained_calls: std.ArrayList(*ast.Node) = .empty;
        while (!self.at(.eol) and !self.at(.eof) and !self.at(.keyword_here_end) and !self.at(.keyword_else)) {
            if (self.at(.identifier) and isImplicitCallbackJosi(self.peek().josi)) {
                const command = self.advance();
                const call = try self.parseImplicitCallbackCall(command, arguments.items);
                if (chained_calls.items.len == 0) return call;
                try chained_calls.append(self.allocator, call);
                return self.makeNodeWithChildren(.block, start, try chained_calls.toOwnedSlice(self.allocator));
            }
            if (self.at(.keyword_return)) {
                const keyword = self.advance();
                const value = if (arguments.items.len > 0) arguments.items[arguments.items.len - 1] else try self.nop(keyword);
                const result = try self.makeNodeWithChildren(.return_statement, start, try self.copyChildren(&.{value}));
                result.josi = "";
                return result;
            }
            if (self.at(.keyword_repeat_count)) {
                const keyword = self.advance();
                const count = if (arguments.items.len > 0) arguments.items[arguments.items.len - 1] else try self.numberOne(keyword);
                return self.parseRepeatTimes(start, count);
            }
            if (self.at(.keyword_repeat_while)) {
                _ = self.advance();
                if (arguments.items.len == 0) return self.fail(.invalid_control_statement, "『間』の前に条件式が必要です", start);
                return self.parseWhile(start, arguments.items[arguments.items.len - 1]);
            }
            if (self.at(.keyword_repeat)) return self.parseFor(start, arguments.items);
            if (self.at(.keyword_foreach)) {
                _ = self.advance();
                const collection = if (arguments.items.len > 0) arguments.items[arguments.items.len - 1] else try self.nop(start);
                return self.parseForeach(start, collection);
            }
            if (self.at(.keyword_import)) {
                const command = self.advance();
                if (arguments.items.len == 0) return self.fail(.expected_expression, "取り込み先が必要です", command);
                const path = arguments.items[arguments.items.len - 1];
                const node = try self.makeNodeWithChildren(.import, start, try self.copyChildren(&.{path}));
                node.value = path.value;
                node.josi = "";
                return node;
            }
            if ((self.identifierValue("増") or self.identifierValue("減")) and self.peekAhead(1).kind == .keyword_repeat) {
                return self.parseFor(start, arguments.items);
            }

            if (chained_calls.items.len > 0 and self.at(.identifier)) {
                const command = self.advance();
                const call = try self.makeCommandCall(command, try arguments.toOwnedSlice(self.allocator));
                try chained_calls.append(self.allocator, call);
                if (isSequenceJosi(command.josi)) {
                    arguments = .empty;
                    try arguments.append(self.allocator, try self.implicitIt(command));
                    continue;
                }
                return self.makeNodeWithChildren(.block, start, try chained_calls.toOwnedSlice(self.allocator));
            }

            const expression = try self.parseExpression(0);
            if (expression.kind == .function_call and self.isTerminator()) {
                return expression;
            }
            try arguments.append(self.allocator, expression);

            if (self.at(.identifier)) {
                // 助詞付きの識別子の直後に別の命令名が続く場合、手前は命令ではなく
                // 引数として扱う。例: `201でHを簡易HTTPサーバヘッダ出力`。
                // 「して」などの連文助詞と「には」のコールバック構文は従来どおり
                // その位置の識別子を命令として確定する。
                if (self.peek().josi.len > 0 and
                    !isSequenceJosi(self.peek().josi) and
                    !isImplicitCallbackJosi(self.peek().josi) and
                    self.peekAhead(1).kind == .identifier)
                {
                    continue;
                }
                if ((self.identifierValue("増") or self.identifierValue("減")) and self.peekAhead(1).kind == .keyword_repeat) {
                    return self.parseFor(start, arguments.items);
                }
                const command = self.advance();
                if (std.mem.eql(u8, command.value, "実行速度優先") or std.mem.eql(u8, command.value, "パフォーマンスモニタ適用")) {
                    const option = if (arguments.items.len > 0) arguments.items[arguments.items.len - 1] else try self.nop(start);
                    return self.parseScopedMode(start, command, option);
                }
                if (std.mem.eql(u8, command.value, "条件分岐")) {
                    const condition = if (arguments.items.len > 0) arguments.items[arguments.items.len - 1] else return self.fail(.invalid_control_statement, "『条件分岐』の値が必要です", command);
                    return self.parseSwitch(start, condition);
                }
                if (try self.parseJapaneseCommand(start, command, arguments.items)) |statement| return statement;
                if (isImplicitCallbackJosi(command.josi)) return self.parseImplicitCallbackCall(command, arguments.items);
                const call = try self.makeCommandCall(command, try arguments.toOwnedSlice(self.allocator));
                if (isSequenceJosi(command.josi)) {
                    try chained_calls.append(self.allocator, call);
                    arguments = .empty;
                    try arguments.append(self.allocator, try self.implicitIt(command));
                    continue;
                }
                return call;
            }
            if (self.isTerminator()) break;
        }

        if (chained_calls.items.len > 0) return self.makeNodeWithChildren(.block, start, try chained_calls.toOwnedSlice(self.allocator));
        if (arguments.items.len == 1) {
            const value = arguments.items[0];
            if (value.kind == .word) {
                const call = try self.makeNode(.function_call, start);
                call.name = value.value;
                call.josi = value.josi;
                return call;
            }
            const node = try self.makeNodeWithChildren(.dynamic_execute, start, try self.copyChildren(&.{value}));
            return node;
        }
        return self.fail(.unexpected_token, "命令呼び出しを構成できません", self.peek());
    }

    fn makeCommandCall(self: *Parser, command: Token, arguments: []*ast.Node) ParseFailure!*ast.Node {
        const call = try self.makeNodeWithChildren(.function_call, command, arguments);
        call.name = command.value;
        call.josi = if (isSequenceJosi(command.josi)) "して" else command.josi;
        call.raw_josi = command.raw_josi;
        return call;
    }

    fn parseImplicitCallbackCall(self: *Parser, command: Token, arguments: []const *ast.Node) ParseFailure!*ast.Node {
        const callback_arguments: []ast.Argument = if (self.at(.left_paren)) try self.parseArguments() else &.{};
        if (self.at(.eol)) self.skipEols();
        const body = try self.parseBlock(.{ .end = true });
        try self.requireEnd("『には』コールバック");
        const callback = try self.makeNodeWithChildren(.anonymous_function, command, try self.copyChildren(&.{body}));
        callback.arguments = callback_arguments;
        callback.josi = "";
        callback.raw_josi = "";
        const call = try self.makeCommandCall(command, try self.prepend(callback, arguments));
        call.josi = "して";
        return call;
    }

    fn implicitIt(self: *Parser, token: Token) ParseFailure!*ast.Node {
        const result = try self.makeNode(.word, token);
        result.value = "それ";
        result.josi = "";
        result.raw_josi = "";
        return result;
    }

    fn parseJapaneseCommand(self: *Parser, start: Token, command: Token, arguments: []const *ast.Node) ParseFailure!?*ast.Node {
        const is_assign = std.mem.eql(u8, command.value, "代入");
        const is_define = std.mem.eql(u8, command.value, "定");
        const is_increment = std.mem.eql(u8, command.value, "増") or std.mem.eql(u8, command.value, "減");
        if (!is_assign and !is_define and !is_increment) return null;
        if (arguments.len < 2 or arguments[0].kind != .word) return self.fail(.invalid_assignment, "代入先と値の指定が必要です", command);
        const target = arguments[0];
        const value = arguments[1];
        if (is_assign or is_define) {
            const result = try self.makeNodeWithChildren(if (is_define) .variable_definition else .assignment, start, try self.copyChildren(&.{value}));
            result.name = target.value;
            result.josi = "";
            return result;
        }
        var amount = value;
        if (std.mem.eql(u8, command.value, "減")) {
            const minus_one = try self.makeNode(.number, command);
            minus_one.value = "-1";
            minus_one.number_value = -1;
            amount = try self.makeNodeWithChildren(.binary_operator, command, try self.copyChildren(&.{ value, minus_one }));
            amount.operator = "*";
            amount.josi = "";
        }
        const result = try self.makeNodeWithChildren(.increment, start, try self.copyChildren(&.{amount}));
        result.name = target.value;
        result.josi = "";
        return result;
    }

    fn parseScopedMode(self: *Parser, start: Token, command: Token, option: *ast.Node) ParseFailure!*ast.Node {
        const kind: ast.Kind = if (std.mem.eql(u8, command.value, "実行速度優先")) .speed_mode else .performance_monitor;
        var body: *ast.Node = undefined;
        if (self.at(.keyword_here_from)) _ = self.advance();
        if (self.at(.eol)) {
            self.skipEols();
            body = try self.parseBlock(.{ .end = true });
            try self.requireEnd("実行モード指定");
        } else {
            body = try self.wrapSingle(try self.parseStatement());
        }
        const result = try self.makeNodeWithChildren(kind, start, try self.copyChildren(&.{body}));
        _ = option;
        result.value = "";
        result.josi = "";
        return result;
    }

    fn parseSwitch(self: *Parser, start: Token, condition: *ast.Node) ParseFailure!*ast.Node {
        self.skipEols();
        var default_block = try self.emptyBlock(start);
        var cases: std.ArrayList(*ast.Node) = .empty;
        while (!self.at(.keyword_here_end) and !self.at(.eof)) {
            if (self.at(.keyword_else)) {
                _ = self.advance();
                self.skipEols();
                default_block = try self.parseBlock(.{ .end = true });
                try self.requireEnd("『条件分岐』の違えば節");
                self.skipEols();
                continue;
            }
            const case_value = try self.parseExpression(0);
            if (!isConditionalJosi(case_value.josi)) return self.fail(.invalid_control_statement, "条件分岐の値に『ならば』が必要です", self.peekPrevious());
            clearConditionalJosi(case_value);
            self.skipEols();
            const case_body = try self.parseBlock(.{ .end = true });
            try self.requireEnd("『条件分岐』の節");
            try cases.append(self.allocator, case_value);
            try cases.append(self.allocator, case_body);
            self.skipEols();
        }
        try self.requireEnd("『条件分岐』文");
        var children: std.ArrayList(*ast.Node) = .empty;
        try children.append(self.allocator, condition);
        try children.append(self.allocator, default_block);
        try children.appendSlice(self.allocator, cases.items);
        const result = try self.makeNodeWithChildren(.switch_statement, start, try children.toOwnedSlice(self.allocator));
        result.josi = "";
        return result;
    }

    fn parseCallExpression(self: *Parser) ParseFailure!*ast.Node {
        if (self.at(.def_func)) return self.parseAnonymousFunction();
        const value = try self.parseExpression(0);
        if (!self.at(.identifier)) return value;
        var arguments: std.ArrayList(*ast.Node) = .empty;
        try arguments.append(self.allocator, value);
        while (self.at(.identifier)) {
            const command = self.advance();
            const call = try self.makeNodeWithChildren(.function_call, command, try arguments.toOwnedSlice(self.allocator));
            call.name = command.value;
            call.josi = command.josi;
            if (!isSequenceJosi(command.josi)) return call;
            arguments = .empty;
            try arguments.append(self.allocator, call);
            if (!self.isTerminator()) try arguments.append(self.allocator, try self.parseExpression(0));
        }
        return arguments.items[0];
    }

    fn parseRepeatTimes(self: *Parser, start: Token, count: *ast.Node) ParseFailure!*ast.Node {
        if (self.at(.comma)) _ = self.advance();
        if (self.at(.keyword_repeat)) _ = self.advance();
        const body = try self.parseLoopBody("『回』繰り返し");
        return self.makeNodeWithChildren(.repeat_times, start, try self.copyChildren(&.{ count, body }));
    }

    fn parseWhile(self: *Parser, start: Token, condition: *ast.Node) ParseFailure!*ast.Node {
        self.skipCommas();
        if (self.at(.keyword_repeat)) _ = self.advance();
        const body = try self.parseLoopBody("『間』繰り返し");
        return self.makeNodeWithChildren(.while_statement, start, try self.copyChildren(&.{ condition, body }));
    }

    fn parseFor(self: *Parser, start: Token, arguments: []const *ast.Node) ParseFailure!*ast.Node {
        var direction: ast.LoopDirection = .automatic;
        if (self.identifierValue("増") or self.identifierValue("減")) {
            direction = if (self.identifierValue("増")) .up else .down;
            _ = self.advance();
        }
        const keyword = self.advance();
        if (arguments.len < 2) return self.fail(.invalid_control_statement, "『繰り返す』に開始値と終了値が必要です", keyword);
        var variable: []const u8 = "";
        var offset: usize = 0;
        if (arguments[0].kind == .word and std.mem.eql(u8, arguments[0].josi, "を")) {
            variable = arguments[0].value;
            offset = 1;
        }
        if (arguments.len < offset + 2) return self.fail(.invalid_control_statement, "『繰り返す』に開始値と終了値が必要です", keyword);
        const increment = if (arguments.len > offset + 2) arguments[offset + 2] else try self.nop(keyword);
        const body = try self.parseLoopBody("『繰り返す』文");
        const node = try self.makeNodeWithChildren(.for_statement, start, try self.copyChildren(&.{ arguments[offset], arguments[offset + 1], increment, body }));
        node.name = variable;
        node.josi = "";
        node.loop_direction = direction;
        if (std.mem.eql(u8, keyword.value, "増繰返")) node.loop_direction = .up;
        if (std.mem.eql(u8, keyword.value, "減繰返")) node.loop_direction = .down;
        return node;
    }

    fn parseForeach(self: *Parser, start: Token, collection: *ast.Node) ParseFailure!*ast.Node {
        const body = try self.parseLoopBody("『反復』文");
        return self.makeNodeWithChildren(.foreach_statement, start, try self.copyChildren(&.{ collection, body }));
    }

    fn parseLoopBody(self: *Parser, description: []const u8) ParseFailure!*ast.Node {
        self.skipCommas();
        if (self.at(.keyword_here_from)) _ = self.advance();
        if (self.at(.eol)) {
            self.skipEols();
            const body = try self.parseBlock(.{ .end = true });
            try self.requireEnd(description);
            return body;
        }
        return self.wrapSingle(try self.parseStatement());
    }

    fn parseAnonymousFunction(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        const arguments: []ast.Argument = if (self.at(.left_paren)) try self.parseArguments() else &.{};
        if (self.at(.eol)) self.skipEols();
        const body = try self.parseBlock(.{ .end = true });
        try self.requireEnd("無名関数");
        const node = try self.makeNodeWithChildren(.anonymous_function, start, try self.copyChildren(&.{body}));
        node.arguments = arguments;
        return node;
    }

    fn parseExpression(self: *Parser, minimum_precedence: u8) ParseFailure!*ast.Node {
        var left = try self.parseUnary();
        while (operatorInfo(self.peek().kind)) |info| {
            if (info.precedence < minimum_precedence) break;
            const operator_token = self.advance();
            const next_precedence = info.precedence + @intFromBool(!info.right_associative);
            const right = try self.parseExpression(next_precedence);
            if (operator_token.kind == .range) {
                const range = try self.makeNodeWithChildren(.function_call, operator_token, try self.copyChildren(&.{ left, right }));
                range.name = "範囲";
                range.josi = right.josi;
                left = range;
            } else {
                const binary = try self.makeNodeWithChildren(.binary_operator, operator_token, try self.copyChildren(&.{ left, right }));
                binary.operator = info.name;
                binary.josi = right.josi;
                binary.raw_josi = right.raw_josi;
                left = binary;
            }
        }
        if (minimum_precedence == 0 and left.kind == .binary_operator) propagateOperatorJosi(left, left.josi);
        return left;
    }

    fn parseUnary(self: *Parser) ParseFailure!*ast.Node {
        if (self.at(.plus)) return self.fail(.unexpected_token, "単項『+』は使用できません", self.peek());
        if (self.at(.not) or self.at(.minus)) {
            const operator_token = self.advance();
            const operand = try self.parseUnary();
            if (operator_token.kind == .minus) {
                if (operand.kind == .bigint) {
                    operand.value = if (std.mem.startsWith(u8, operand.value, "-"))
                        try self.allocator.dupe(u8, operand.value[1..])
                    else
                        try std.fmt.allocPrint(self.allocator, "-{s}", .{operand.value});
                    operand.span = operator_token.span;
                    return operand;
                }
                const minus_one = try self.makeNode(.number, operator_token);
                minus_one.value = "-1";
                minus_one.number_value = -1;
                const binary = try self.makeNodeWithChildren(.binary_operator, operator_token, try self.copyChildren(&.{ minus_one, operand }));
                binary.operator = "*";
                binary.josi = operand.josi;
                return binary;
            }
            return self.unary(operatorName(operator_token.kind), operand, operator_token);
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseFailure!*ast.Node {
        var value = try self.parsePrimary();
        while (true) {
            if (self.at(.left_paren) and value.kind == .word and value.josi.len == 0) {
                const open = self.advance();
                var arguments: std.ArrayList(*ast.Node) = .empty;
                while (!self.at(.right_paren) and !self.at(.eof)) {
                    try arguments.append(self.allocator, try self.parseExpression(0));
                    if (!self.at(.comma)) break;
                    _ = self.advance();
                }
                const close = try self.require(.right_paren, "C風関数呼び出しを閉じる『)』が必要です");
                const call = try self.makeNodeWithChildren(.function_call, open, try arguments.toOwnedSlice(self.allocator));
                call.name = value.value;
                call.josi = close.josi;
                call.raw_josi = close.raw_josi;
                value = call;
                continue;
            }
            if (self.at(.left_paren) and value.kind == .function_call) {
                const open = self.advance();
                var arguments: std.ArrayList(*ast.Node) = .empty;
                try arguments.append(self.allocator, value);
                while (!self.at(.right_paren) and !self.at(.eof)) {
                    try arguments.append(self.allocator, try self.parseExpression(0));
                    if (!self.at(.comma)) break;
                    _ = self.advance();
                }
                const close = try self.require(.right_paren, "関数値呼び出しを閉じる『)』が必要です");
                value = try self.makeNodeWithChildren(.call_value, open, try arguments.toOwnedSlice(self.allocator));
                value.josi = close.josi;
                continue;
            }
            if (self.at(.at)) {
                const token = self.advance();
                const index = try self.parsePrimary();
                const reference_kind: ast.Kind = if (isVariableReference(value.kind)) .array_reference else .array_value_reference;
                value = try self.reference(reference_kind, value, &.{index}, token);
                continue;
            }
            if (self.at(.left_bracket) and value.josi.len == 0) {
                const open = self.advance();
                var indexes: std.ArrayList(*ast.Node) = .empty;
                while (!self.at(.right_bracket) and !self.at(.eof)) {
                    try indexes.append(self.allocator, try self.parseExpression(0));
                    if (!self.at(.comma)) break;
                    _ = self.advance();
                }
                const close = try self.require(.right_bracket, "配列参照を閉じる『]』が必要です");
                const reference_kind: ast.Kind = if (isVariableReference(value.kind)) .array_reference else .array_value_reference;
                value = try self.reference(reference_kind, value, try indexes.toOwnedSlice(self.allocator), open);
                value.josi = close.josi;
                value.raw_josi = close.raw_josi;
                continue;
            }
            if (self.at(.property)) {
                const token = self.advance();
                const property_token = self.advance();
                if (property_token.kind != .identifier and property_token.kind != .string) return self.fail(.expected_name, "『$』の後ろにプロパティ名が必要です", property_token);
                const property = try self.valueNode(.string, property_token);
                const reference_kind: ast.Kind = if (isVariableReference(value.kind)) .property_reference else .array_value_reference;
                value = try self.reference(reference_kind, value, &.{property}, token);
                value.josi = property_token.josi;
                continue;
            }
            break;
        }
        return value;
    }

    fn parsePrimary(self: *Parser) ParseFailure!*ast.Node {
        const token = self.advance();
        return switch (token.kind) {
            .number => self.valueNode(.number, token),
            .bigint => self.valueNode(.bigint, token),
            .string => self.valueNode(.string, token),
            .string_template => self.valueNode(.string_template, token),
            .identifier => self.parseIdentifierValue(token),
            .function_ref => blk: {
                const node = try self.makeNode(.function_pointer, token);
                node.name = token.value;
                break :blk node;
            },
            .left_paren => blk: {
                const value = try self.parseExpression(0);
                if (!self.at(.right_paren)) return self.fail(.expected_token, "式を閉じる『)』が必要です", token);
                const close = self.advance();
                value.josi = close.josi;
                value.raw_josi = close.raw_josi;
                value.grouped = true;
                break :blk value;
            },
            .left_bracket => self.parseArrayAfterOpen(token),
            .left_brace => self.parseObjectAfterOpen(token),
            .def_func => blk: {
                self.index -= 1;
                break :blk self.parseAnonymousFunction();
            },
            else => self.fail(.expected_expression, "値または式が必要です", token),
        };
    }

    fn parseIdentifierValue(self: *Parser, token: Token) ParseFailure!*ast.Node {
        if (std.mem.eql(u8, token.value, "真") or std.mem.eql(u8, token.value, "はい") or std.mem.eql(u8, token.value, "オン")) {
            const node = try self.valueNode(.boolean, token);
            node.number_value = 1;
            return node;
        }
        if (std.mem.eql(u8, token.value, "偽") or std.mem.eql(u8, token.value, "いいえ") or std.mem.eql(u8, token.value, "オフ")) {
            const node = try self.valueNode(.boolean, token);
            node.number_value = 0;
            return node;
        }
        if (std.ascii.eqlIgnoreCase(token.value, "null")) return self.valueNode(.null_value, token);
        return self.valueNode(.word, token);
    }

    fn parseArrayLiteral(self: *Parser) ParseFailure!*ast.Node {
        return self.parseArrayAfterOpen(self.advance());
    }

    fn parseArrayAfterOpen(self: *Parser, open: Token) ParseFailure!*ast.Node {
        var values: std.ArrayList(*ast.Node) = .empty;
        while (!self.at(.right_bracket) and !self.at(.eof)) {
            if (self.at(.eol) or self.at(.comma)) {
                _ = self.advance();
                continue;
            }
            try values.append(self.allocator, try self.parseExpression(0));
            if (self.at(.comma)) _ = self.advance();
        }
        if (!self.at(.right_bracket)) return self.fail(.expected_token, "配列リテラルを閉じる『]』が必要です", open);
        const close = self.advance();
        const node = try self.makeNodeWithChildren(.array_literal, open, try values.toOwnedSlice(self.allocator));
        node.josi = close.josi;
        node.raw_josi = close.raw_josi;
        return node;
    }

    fn parseObjectAfterOpen(self: *Parser, open: Token) ParseFailure!*ast.Node {
        var values: std.ArrayList(*ast.Node) = .empty;
        while (!self.at(.right_brace) and !self.at(.eof)) {
            if (self.at(.eol) or self.at(.comma)) {
                _ = self.advance();
                continue;
            }
            const key_token = self.advance();
            if (key_token.kind != .identifier and key_token.kind != .string) {
                return self.fail(.expected_name, "辞書のキーが必要です", key_token);
            }
            const key = try self.valueNode(.string, key_token);
            try values.append(self.allocator, key);
            if (self.at(.colon)) {
                _ = self.advance();
                try values.append(self.allocator, try self.parseExpression(0));
            } else {
                try values.append(self.allocator, try self.valueNode(.word, key_token));
            }
            if (self.at(.comma)) _ = self.advance();
        }
        if (!self.at(.right_brace)) return self.fail(.expected_token, "辞書リテラルを閉じる『}』が必要です", open);
        const close = self.advance();
        const node = try self.makeNodeWithChildren(.object_literal, open, try values.toOwnedSlice(self.allocator));
        node.josi = close.josi;
        node.raw_josi = close.raw_josi;
        return node;
    }

    fn reference(self: *Parser, kind: ast.Kind, base: *ast.Node, indexes: []const *ast.Node, token: Token) ParseFailure!*ast.Node {
        var children: std.ArrayList(*ast.Node) = .empty;
        if (base.kind == kind) {
            try children.appendSlice(self.allocator, base.children);
        } else {
            try children.append(self.allocator, base);
        }
        try children.appendSlice(self.allocator, indexes);
        const node = try self.makeNodeWithChildren(kind, token, try children.toOwnedSlice(self.allocator));
        node.name = switch (kind) {
            .array_value_reference => if (token.kind == .property) "$" else "@",
            else => if (base.name.len > 0) base.name else base.value,
        };
        node.josi = if (indexes.len > 0) indexes[indexes.len - 1].josi else base.josi;
        return node;
    }

    fn assignmentPath(self: *Parser, target: *ast.Node) ParseFailure![]*ast.Node {
        var path: std.ArrayList(*ast.Node) = .empty;
        try appendAssignmentPath(&path, self.allocator, target);
        return path.toOwnedSlice(self.allocator);
    }

    fn sequence(self: *Parser, left: *ast.Node, right: *ast.Node, token: Token) ParseFailure!*ast.Node {
        const node = try self.makeNodeWithChildren(.sequence, token, try self.copyChildren(&.{ left, right }));
        node.operator = "renbun";
        node.josi = right.josi;
        return node;
    }

    fn unary(self: *Parser, operator: []const u8, operand: *ast.Node, token: Token) ParseFailure!*ast.Node {
        const node = try self.makeNodeWithChildren(.unary_operator, token, try self.copyChildren(&.{operand}));
        node.operator = operator;
        node.josi = operand.josi;
        return node;
    }

    fn numberOne(self: *Parser, token: Token) ParseFailure!*ast.Node {
        const node = try self.makeNode(.number, token);
        node.value = "1";
        node.number_value = 1;
        return node;
    }

    fn nop(self: *Parser, token: Token) ParseFailure!*ast.Node {
        return self.makeNode(.nop, token);
    }

    fn emptyBlock(self: *Parser, token: Token) ParseFailure!*ast.Node {
        return self.makeNodeWithChildren(.block, token, &.{});
    }

    fn wrapSingle(self: *Parser, child: *ast.Node) ParseFailure!*ast.Node {
        return self.makeNodeWithChildren(.block, self.peekPrevious(), try self.copyChildren(&.{child}));
    }

    fn valueNode(self: *Parser, kind: ast.Kind, token: Token) ParseFailure!*ast.Node {
        const node = try self.makeNode(kind, token);
        node.value = token.value;
        node.number_value = token.number_value;
        node.josi = token.josi;
        node.raw_josi = token.raw_josi;
        return node;
    }

    fn makeNode(self: *Parser, kind: ast.Kind, token: Token) ParseFailure!*ast.Node {
        const result = try self.allocator.create(ast.Node);
        result.* = .{
            .kind = kind,
            .span = token.span,
            .end_span = self.peekPrevious().span,
            .josi = token.josi,
            .raw_josi = token.raw_josi,
        };
        return result;
    }

    fn makeNodeWithChildren(self: *Parser, kind: ast.Kind, token: Token, children: []*ast.Node) ParseFailure!*ast.Node {
        const result = try self.makeNode(kind, token);
        result.children = children;
        if (children.len > 0) result.end_span = children[children.len - 1].end_span;
        return result;
    }

    fn copyChildren(self: *Parser, children: []const *ast.Node) ParseFailure![]*ast.Node {
        return self.allocator.dupe(*ast.Node, children);
    }

    fn namesToArguments(self: *Parser, names: []const *ast.Node) ParseFailure![]ast.Argument {
        const result = try self.allocator.alloc(ast.Argument, names.len);
        for (names, 0..) |name, index| result[index] = .{
            .name = if (name.value.len > 0) name.value else name.name,
            .josi = name.josi,
            .span = name.span,
        };
        return result;
    }

    fn prepend(self: *Parser, first: *ast.Node, rest: []const *ast.Node) ParseFailure![]*ast.Node {
        const result = try self.allocator.alloc(*ast.Node, rest.len + 1);
        result[0] = first;
        @memcpy(result[1..], rest);
        return result;
    }

    fn requireEnd(self: *Parser, description: []const u8) ParseFailure!void {
        if (!self.at(.keyword_here_end)) {
            const message = try std.fmt.allocPrint(self.allocator, "{s}の末尾に『ここまで』が必要です", .{description});
            return self.fail(.missing_block_end, message, self.peek());
        }
        _ = self.advance();
    }

    fn require(self: *Parser, kind: Kind, message: []const u8) ParseFailure!Token {
        if (!self.at(kind)) return self.fail(.expected_token, message, self.peek());
        return self.advance();
    }

    fn fail(self: *Parser, code: diagnostic.Code, message: []const u8, token: Token) ParseFailure {
        self.diagnostics.append(self.allocator, .{
            .code = code,
            .message = message,
            .file = self.filename,
            .span = token.span,
        }) catch return error.OutOfMemory;
        return error.ParseFailed;
    }

    fn isStop(self: *Parser, stop: Stop) bool {
        return (stop.end and self.at(.keyword_here_end)) or
            (stop.else_branch and self.at(.keyword_else)) or
            (stop.error_branch and self.at(.keyword_error));
    }

    fn isTerminator(self: *Parser) bool {
        return self.at(.eol) or self.at(.eof) or self.at(.right_paren) or self.at(.right_bracket) or
            self.at(.right_brace) or self.at(.keyword_here_end) or self.at(.keyword_else) or self.at(.keyword_error);
    }

    fn skipEols(self: *Parser) void {
        while (self.at(.eol)) _ = self.advance();
    }

    fn skipCommas(self: *Parser) void {
        while (self.at(.comma)) _ = self.advance();
    }

    fn identifierValue(self: *Parser, value: []const u8) bool {
        return self.at(.identifier) and std.mem.eql(u8, self.peek().value, value);
    }

    fn at(self: *Parser, kind: Kind) bool {
        return self.peek().kind == kind;
    }

    fn advance(self: *Parser) Token {
        const token = self.peek();
        if (self.index < self.tokens.len) self.index += 1;
        return token;
    }

    fn peek(self: *Parser) Token {
        if (self.tokens.len == 0) return emptyToken();
        return self.tokens[@min(self.index, self.tokens.len - 1)];
    }

    fn peekPrevious(self: *Parser) Token {
        if (self.index == 0 or self.tokens.len == 0) return self.peek();
        return self.tokens[@min(self.index - 1, self.tokens.len - 1)];
    }

    fn peekAhead(self: *Parser, distance: usize) Token {
        if (self.tokens.len == 0) return emptyToken();
        return self.tokens[@min(self.index + distance, self.tokens.len - 1)];
    }
};

const OperatorInfo = struct { precedence: u8, right_associative: bool = false, name: []const u8 };

fn operatorInfo(kind: Kind) ?OperatorInfo {
    return switch (kind) {
        .logical_or => .{ .precedence = 10, .name = "or" },
        .logical_and => .{ .precedence = 10, .name = "and" },
        .equal => .{ .precedence = 20, .name = "eq" },
        .strict_equal => .{ .precedence = 20, .name = "===" },
        .not_equal => .{ .precedence = 20, .name = "noteq" },
        .strict_not_equal => .{ .precedence = 20, .name = "!==" },
        .greater => .{ .precedence = 20, .name = "gt" },
        .greater_equal => .{ .precedence = 20, .name = "gteq" },
        .less => .{ .precedence = 20, .name = "lt" },
        .less_equal => .{ .precedence = 20, .name = "lteq" },
        .range => .{ .precedence = 25, .name = "…" },
        .bit_and => .{ .precedence = 30, .name = "&" },
        .bit_xor => .{ .precedence = 60, .name = "**" },
        .plus => .{ .precedence = 40, .name = "+" },
        .minus => .{ .precedence = 40, .name = "-" },
        .shift_left => .{ .precedence = 40, .name = "shift_l" },
        .shift_right => .{ .precedence = 40, .name = "shift_r" },
        .shift_right_unsigned => .{ .precedence = 40, .name = "shift_r0" },
        .multiply => .{ .precedence = 50, .name = "*" },
        .divide => .{ .precedence = 50, .name = "÷" },
        .integer_divide => .{ .precedence = 50, .name = "÷÷" },
        .modulo => .{ .precedence = 50, .name = "%" },
        .power => .{ .precedence = 60, .name = "**" },
        else => null,
    };
}

fn operatorName(kind: Kind) []const u8 {
    return switch (kind) {
        .not => "not",
        .minus => "-",
        .plus => "+",
        else => "",
    };
}

fn isConditionalJosi(josi: []const u8) bool {
    return std.mem.eql(u8, josi, "ならば") or std.mem.eql(u8, josi, "なら") or
        std.mem.eql(u8, josi, "たら") or std.mem.eql(u8, josi, "れば") or
        std.mem.eql(u8, josi, "でなければ") or std.mem.eql(u8, josi, "なければ");
}

fn isSequenceJosi(josi: []const u8) bool {
    const values = [_][]const u8{ "いて", "えて", "きて", "けて", "して", "って", "にて", "みて", "めて", "ねて", "には", "んで" };
    for (values) |value| if (std.mem.eql(u8, josi, value)) return true;
    return false;
}

fn isImplicitCallbackJosi(josi: []const u8) bool {
    return std.mem.eql(u8, josi, "には");
}

fn isVariableReference(kind: ast.Kind) bool {
    return kind == .word or kind == .array_reference or kind == .property_reference;
}

fn clearConditionalJosi(node: *ast.Node) void {
    node.josi = "";
    node.raw_josi = "";
    if (node.kind == .binary_operator or node.kind == .unary_operator) {
        for (node.children) |child| clearConditionalJosi(child);
    }
}

fn propagateOperatorJosi(node: *ast.Node, josi: []const u8) void {
    if (node.kind != .binary_operator) return;
    node.josi = josi;
    for (node.children) |child| if (!child.grouped) propagateOperatorJosi(child, josi);
}

fn tokenStem(token: Token) []const u8 {
    if (token.raw_josi.len > 0 and token.lexeme.len >= token.raw_josi.len) {
        return token.lexeme[0 .. token.lexeme.len - token.raw_josi.len];
    }
    return token.value;
}

fn appendAssignmentPath(path: *std.ArrayList(*ast.Node), allocator: std.mem.Allocator, node: *ast.Node) ParseFailure!void {
    if (node.kind != .array_reference and node.kind != .property_reference) {
        if (node.kind != .word) try path.append(allocator, node);
        return;
    }
    for (node.children, 0..) |child, index| {
        if (index == 0 and (child.kind == .word or child.kind == .array_reference or child.kind == .property_reference)) {
            try appendAssignmentPath(path, allocator, child);
        } else {
            try path.append(allocator, child);
        }
    }
}

fn emptyToken() Token {
    return .{
        .kind = .eof,
        .lexeme = "",
        .value = "",
        .span = ast.emptySpan(),
    };
}

test "代入・演算子優先順位・命令呼び出しを構文解析する" {
    var result = try parse(std.testing.allocator, "A=1\nB=2\nA+Bを表示\n", "main.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(ast.Kind.block, result.root.?.kind);
    try std.testing.expectEqual(ast.Kind.assignment, result.root.?.children[0].kind);
    const call = result.root.?.children[4];
    try std.testing.expectEqual(ast.Kind.function_call, call.kind);
    try std.testing.expectEqualStrings("表示", call.name);
    try std.testing.expectEqual(ast.Kind.binary_operator, call.children[0].kind);
    try std.testing.expectEqualStrings("+", call.children[0].operator);
}

test "識別子変数を途中の命令と誤認せず複数引数を構文解析する" {
    var result = try parse(std.testing.allocator, "201でHを簡易HTTPサーバヘッダ出力\n", "http-server.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const call = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, call.kind);
    try std.testing.expectEqualStrings("簡易HTTPサーバヘッダ出力", call.name);
    try std.testing.expectEqual(@as(usize, 2), call.children.len);
    try std.testing.expectEqual(ast.Kind.number, call.children[0].kind);
    try std.testing.expectEqualStrings("で", call.children[0].josi);
    try std.testing.expectEqual(ast.Kind.word, call.children[1].kind);
    try std.testing.expectEqualStrings("H", call.children[1].value);
    try std.testing.expectEqualStrings("を", call.children[1].josi);
}

test "助詞はを代入演算子として構文解析する" {
    var result = try parse(std.testing.allocator, "Fはそれ\n", "assignment.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const assignment = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.assignment, assignment.kind);
    try std.testing.expectEqualStrings("F", assignment.name);
    try std.testing.expectEqual(ast.Kind.word, assignment.children[0].kind);
    try std.testing.expectEqualStrings("それ", assignment.children[0].value);
}

test "行頭の等価比較を代入文と誤認しない" {
    var result = try parse(std.testing.allocator, "1n==1を表示\n", "equality.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const call = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, call.kind);
    try std.testing.expectEqual(ast.Kind.binary_operator, call.children[0].kind);
    try std.testing.expectEqualStrings("eq", call.children[0].operator);
}

test "冪乗演算子を公式同様に左結合として構文解析する" {
    var result = try parse(std.testing.allocator, "2^3^2を表示\n2**3**2を表示\n", "power.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const outer = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, outer.kind);
    try std.testing.expectEqualStrings("**", outer.operator);
    try std.testing.expectEqual(ast.Kind.binary_operator, outer.children[0].kind);
    try std.testing.expectEqualStrings("**", outer.children[0].operator);
    const stars = result.root.?.children[2].children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, stars.children[0].kind);
    try std.testing.expectEqualStrings("**", stars.children[0].operator);
}

test "もし文とソース位置を構文解析する" {
    var result = try parse(std.testing.allocator, "もしA=1ならば\nB=1\n違えば\nB=2\nここまで\n", "条件.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const statement = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.if_statement, statement.kind);
    try std.testing.expectEqual(@as(usize, 3), statement.children.len);
    try std.testing.expectEqual(@as(usize, 0), statement.span.line);
    try std.testing.expectEqual(@as(usize, 1), statement.span.column);
}

test "もし直後の読点を許可する" {
    var result = try parse(std.testing.allocator, "もし、A=1ならば\nB=1\nここまで\n", "条件.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(ast.Kind.if_statement, result.root.?.children[0].kind);
}

test "間と繰り返すの間の読点を許可する" {
    var result = try parse(std.testing.allocator, "(N>0)の間、繰り返す\nN=N-1\nここまで\n", "反復.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(ast.Kind.while_statement, result.root.?.children[0].kind);
}

test "それは構文を暗黙戻り値への代入として扱う" {
    var result = try parse(std.testing.allocator, "F=関数(A)それはA+1\nここまで\n", "関数.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const function = result.root.?.children[0].children[0];
    const assignment = function.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.assignment, assignment.kind);
    try std.testing.expectEqualStrings("それ", assignment.name);
}

test "には構文をコールバック先頭の命令呼び出しとして扱う" {
    var timer = try parse(std.testing.allocator, "0.01秒後には\n対象を表示\nここまで\n", "timer.nako3");
    defer timer.deinit();
    try std.testing.expect(timer.succeeded());
    const timer_call = timer.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.function_call, timer_call.kind);
    try std.testing.expectEqualStrings("秒後", timer_call.name);
    try std.testing.expectEqualStrings("して", timer_call.josi);
    try std.testing.expectEqual(@as(usize, 2), timer_call.children.len);
    try std.testing.expectEqual(ast.Kind.anonymous_function, timer_call.children[0].kind);
    try std.testing.expectEqual(ast.Kind.number, timer_call.children[1].kind);

    var promise = try parse(std.testing.allocator, "動いた時には(成功,失敗)\n成功(9)\nここまで\n", "promise.nako3");
    defer promise.deinit();
    try std.testing.expect(promise.succeeded());
    const promise_call = promise.root.?.children[0];
    try std.testing.expectEqualStrings("動時", promise_call.name);
    try std.testing.expectEqual(ast.Kind.anonymous_function, promise_call.children[0].kind);
    try std.testing.expectEqual(@as(usize, 2), promise_call.children[0].arguments.len);
    try std.testing.expectEqualStrings("成功", promise_call.children[0].arguments[0].name);
    try std.testing.expectEqualStrings("失敗", promise_call.children[0].arguments[1].name);
}

test "配列・辞書・添字代入を構文解析する" {
    var result = try parse(std.testing.allocator, "A={a:1,b:2}\nB=[[0]]\nB[0,1]=A$a\n", "collection.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqual(ast.Kind.object_literal, result.root.?.children[0].children[0].kind);
    try std.testing.expectEqual(ast.Kind.array_assignment, result.root.?.children[4].kind);
}

test "公式同様に辞書リテラルの数値キーを拒否する" {
    var result = try parse(std.testing.allocator, "A={1:2}\n", "numeric-key.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(diagnostic.Code.expected_name, result.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics[0].span.line);
}

test "公式同様に単項プラスを拒否する" {
    const cases = [_][]const u8{ "(+1)を表示\n", "A=1\n(+A)を表示\n", "(+\"1\")を表示\n" };
    for (cases) |source| {
        var result = try parse(std.testing.allocator, source, "unary-plus.nako3");
        defer result.deinit();
        try std.testing.expect(!result.succeeded());
        try std.testing.expectEqual(diagnostic.Code.unexpected_token, result.diagnostics[0].code);
        try std.testing.expectEqualStrings("単項『+』は使用できません", result.diagnostics[0].message);
    }
}

test "変数と定数の角括弧分割宣言を構文解析する" {
    var result = try parse(std.testing.allocator, "変数[A,B]=[1,2]\n定数[C,D]=[3,4]\n", "分割.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const variable_declaration = result.root.?.children[0];
    const constant_declaration = result.root.?.children[2];
    try std.testing.expectEqual(ast.Kind.variable_list_definition, variable_declaration.kind);
    try std.testing.expectEqual(@as(usize, 2), variable_declaration.arguments.len);
    try std.testing.expect(!variable_declaration.is_const);
    try std.testing.expectEqual(ast.Kind.variable_list_definition, constant_declaration.kind);
    try std.testing.expectEqual(@as(usize, 2), constant_declaration.arguments.len);
    try std.testing.expect(constant_declaration.is_const);
}

test "公式同様に宣言なしの角括弧分割代入を拒否する" {
    var result = try parse(std.testing.allocator, "[A,B]=[1,2]\n", "分割.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(diagnostic.Code.expected_token, result.diagnostics[0].code);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics[0].span.line);
}

test "負のBigIntリテラルと変数への単項マイナスを区別する" {
    var result = try parse(std.testing.allocator, "A=-5n\nB=-A\n", "bigint-minus.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const literal = result.root.?.children[0].children[0];
    try std.testing.expectEqual(ast.Kind.bigint, literal.kind);
    try std.testing.expectEqualStrings("-5n", literal.value);
    const variable_negation = result.root.?.children[2].children[0];
    try std.testing.expectEqual(ast.Kind.binary_operator, variable_negation.kind);
    try std.testing.expectEqualStrings("*", variable_negation.operator);
    try std.testing.expectEqualStrings("-1", variable_negation.children[0].value);
    try std.testing.expectEqualStrings("A", variable_negation.children[1].value);
}

test "閉じていないブロックを位置付き診断にする" {
    var result = try parse(std.testing.allocator, "もし1=1ならば\nA=1\n", "broken.nako3");
    defer result.deinit();
    try std.testing.expect(!result.succeeded());
    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(diagnostic.Code.missing_block_end, result.diagnostics[0].code);
    try std.testing.expectEqualStrings("broken.nako3", result.diagnostics[0].file);
}

test "相対nako3取り込みをASTに保持する" {
    var result = try parse(std.testing.allocator, "!「./lib.nako3」を取り込む\n", "main.nako3");
    defer result.deinit();
    try std.testing.expect(result.succeeded());
    const import_node = result.root.?.children[0];
    try std.testing.expectEqual(ast.Kind.import, import_node.kind);
    try std.testing.expectEqualStrings("./lib.nako3", import_node.value);
}
