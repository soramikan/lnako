const std = @import("std");
const ast = @import("ast.zig");
const builtin_commands = @import("builtin_commands.zig");
const diagnostic = @import("diagnostic.zig");
const lexer = @import("lexer.zig");
const syntax_transform = @import("syntax_transform.zig");
const token_mod = @import("token.zig");

const Token = token_mod.Token;
const Kind = token_mod.Kind;

pub const helpers = @import("parser/helpers.zig");
pub const builder = @import("parser/builder.zig");
pub const expressions = @import("parser/expressions.zig");

const isConditionalJosi = helpers.isConditionalJosi;
const isSequenceJosi = helpers.isSequenceJosi;
const isTargetJosi = helpers.isTargetJosi;
const isValueJosi = helpers.isValueJosi;
const isImplicitCallbackJosi = helpers.isImplicitCallbackJosi;
const canStartExpression = helpers.canStartExpression;
const tokenStem = helpers.tokenStem;
const isIncrementTargetPath = helpers.isIncrementTargetPath;
const emptyToken = helpers.emptyToken;
const clearConditionalJosi = helpers.clearConditionalJosi;

pub const Error = lexer.Error || syntax_transform.Error || std.mem.Allocator.Error;

/// 取り込み先モジュールが残したモードを指定位置以降の文へ適用する。
/// 公式は取り込み先トークン列を取り込み文の位置へ結合して単一パースするため、
/// 取り込み先内のDNCLモード文が後続の取り込み元の文にも効く。
pub const TailMode = struct { position: usize, mode: token_mod.Mode };

/// 取り込み文の位置と、その文をパースした時点のモード。
/// mode はその時点の全モード（初期・文由来・tail適用を含む）、
/// own_mode は tail_modes 適用を除いたモード（初期モード＋文由来の有効化のみ）。
/// 循環取り込みコピーの再解析モードは own_mode 相当でしか再現できないため、
/// 取り込み後に効くtailモードとの区別が必要になる。
pub const ImportMode = struct { position: usize, mode: token_mod.Mode, own_mode: token_mod.Mode };

pub const ParseOptions = struct {
    /// 拡張子やコマンドラインで強制される構文モード（字句変換とパーサ双方に効く）
    forced: token_mod.Mode = .{},
    /// 取り込み文位置のモードを継承するパーサ初期モード。
    /// 字句変換（syntax_transform）には適用しない。公式はconvertDNCLを
    /// ファイル単位で実行するため、取り込み元のモードが効くのはパーサフラグ
    /// （1始まり添字・逆順・自動初期化）だけである。
    initial: ?token_mod.Mode = null,
    /// 各取り込み文の直後に適用する、取り込み先モジュールの終端モード。
    tail_modes: []const TailMode = &.{},
    /// 公式の`func token`に相当する既知の命令名。助詞付きの命令名を、公式
    /// `yCallFunc`と同じく連鎖呼出しとして解決するために使う
    /// （`大文字変換を表示` = `表示(大文字変換(それ))`）。既定は生成済みの
    /// 一覧（`builtin_commands.function_names`）で、空を渡すと連鎖解決しない。
    builtin_commands: []const []const u8 = &builtin_commands.function_names,
};

/// 式・命令の再帰下降の入れ子の上限。公式も極端に深い入れ子を文法エラー
/// 『Maximum call stack size exceeded』で拒否する（v3.7.24・固定オラクルで
/// `((((1))))`は1,000段成功・2,000段失敗）。上限が無いとパーサ自身の再帰が
/// 深い括弧・ブロックでプロセススタックを使い切るため、位置付き診断へ収束させる。
pub const max_parse_nesting_depth: usize = 1024;

/// ASTの入れ子の上限。連鎖呼出しと左入れ子の演算子（`1+1+...`）はパーサの再帰を
/// 深くしないまま深いASTを作るため、別に測る。公式の実測境界は連鎖・`+`連鎖とも
/// 2,000段成功・3,000段失敗なので、その受理範囲を含む2048を上限にする。
/// 後段の意味解析と中間表現loweringはASTを再帰走査するため、上限を超える入力は
/// プロセスクラッシュではなく位置付き診断へ収束させる。
pub const max_ast_depth: usize = 2048;

pub const ParseResult = struct {
    stream: lexer.TokenStream,
    filename: []const u8,
    root: ?*ast.Node,
    diagnostics: []diagnostic.Diagnostic,
    /// パース終了時点のモード。取り込み元へ継続するモードの計算に使う。
    final_mode: token_mod.Mode = .{},
    /// 各取り込み文の位置とその時点のモード（出現順）。
    import_modes: []const ImportMode = &.{},

    pub fn deinit(self: *ParseResult) void {
        self.stream.deinit();
        self.* = undefined;
    }

    pub fn succeeded(self: ParseResult) bool {
        if (self.root == null) return false;
        for (self.diagnostics) |item| if (item.blocksCompilation()) return false;
        return true;
    }
};

/// 字句解析・構文変換を含めてソース全体を構文解析する。
/// 構文エラーは Zig の error ではなく diagnostics と root=null で返す。
/// 公式処理系が継続する廃止構文は、diagnosticを残したままrootを返す。
/// `ParseOptions`を既定値で解析する便宜API。既定の`builtin_commands`は生成済みの
/// 既知命令名の一覧（`builtin_commands.function_names`）なので、本番経路と同じく
/// 助詞付きの命令名を連鎖呼出しとして解決する（`大文字変換を表示`は
/// `表示(大文字変換(それ))`になる）。連鎖解決を止めたいテストは
/// `parseWithMode`へ空の`builtin_commands`を渡す。
pub fn parse(backing_allocator: std.mem.Allocator, source: []const u8, filename: []const u8) Error!ParseResult {
    return parseWithMode(backing_allocator, source, filename, .{});
}

/// `options.forced` は拡張子やコマンドラインで強制される構文モード（.dncl、--dncl など）。
/// `options.initial` は取り込み元から継承するパーサ初期モード、
/// `options.tail_modes` は取り込み先の終端モードを取り込み文の直後へ適用する。
pub fn parseWithMode(backing_allocator: std.mem.Allocator, source: []const u8, filename: []const u8, options: ParseOptions) Error!ParseResult {
    var stream = try lexer.tokenizeWithMode(backing_allocator, source, options.forced);
    errdefer stream.deinit();
    try syntax_transform.apply(&stream);

    const allocator = stream.arena.allocator();
    const owned_filename = try allocator.dupe(u8, filename);
    var parser = Parser{
        .allocator = allocator,
        .tokens = stream.tokens,
        .filename = owned_filename,
        // 公式は DNCLモード/DNCL2モード トークンが現れた位置からモードを有効化する
        // （yDNCLMode相当）。ディレクティブ検出による構文変換はファイル全体へ
        // 適用済みだが、添字・自動初期化の意味づけは取り込み元から継承した
        // モード（initial）と強制モード（forced）の両方が効いた状態で開始する。
        .mode = orMode(options.initial orelse .{}, options.forced),
        .own_mode = orMode(options.initial orelse .{}, options.forced),
        .tail_modes = options.tail_modes,
        .builtin_commands = options.builtin_commands,
    };
    var root = parser.parseProgram() catch |err| switch (err) {
        error.ParseFailed => null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    // パーサの再帰では捕まえられない深い左入れ子（`1+1+...`）と連鎖呼出しを、
    // 再帰走査する意味解析・loweringへ渡す前に位置付き診断で止める。
    if (root) |node| {
        if (try parser.exceedAstDepth(node)) |span| {
            try parser.diagnostics.append(allocator, .{
                .code = .nesting_too_deep,
                .message = "式や命令の入れ子が深すぎます",
                .file = owned_filename,
                .span = span,
            });
            root = null;
        }
    }
    const diagnostics = try parser.diagnostics.toOwnedSlice(allocator);
    return .{
        .stream = stream,
        .filename = owned_filename,
        .root = root,
        .diagnostics = diagnostics,
        .final_mode = parser.mode,
        .import_modes = try parser.import_modes.toOwnedSlice(allocator),
    };
}

pub const ParseFailure = error{ ParseFailed, OutOfMemory };

fn orMode(a: token_mod.Mode, b: token_mod.Mode) token_mod.Mode {
    return .{
        .dncl = a.dncl or b.dncl,
        .dncl2 = a.dncl2 or b.dncl2,
        .indent = a.indent or b.indent,
    };
}

const Stop = packed struct {
    end: bool = false,
    else_branch: bool = false,
    error_branch: bool = false,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const Token,
    filename: []const u8,
    mode: token_mod.Mode,
    /// tail_modes適用を除いたモード累積（初期モード＋モード文の有効化）。
    own_mode: token_mod.Mode,
    tail_modes: []const TailMode = &.{},
    /// 公式の`func token`に相当する既知の命令名（`ParseOptions.builtin_commands`）。
    builtin_commands: []const []const u8 = &.{},
    tail_cursor: usize = 0,
    import_modes: std.ArrayList(ImportMode) = .empty,
    index: usize = 0,
    delimited_expression_depth: usize = 0,
    /// 再帰下降の現在の深さ（`max_nesting_depth`と比較する）。
    nesting_depth: usize = 0,
    diagnostics: std.ArrayList(diagnostic.Diagnostic) = .empty,

    /// 再帰下降の一段分を数え、上限を超えたら位置付き診断にする。
    /// 上限が無いとパーサ自身の再帰が深い括弧・ブロックでプロセススタックを使い切る。
    pub fn enterNesting(self: *Parser) ParseFailure!void {
        self.nesting_depth += 1;
        if (self.nesting_depth > max_parse_nesting_depth) return self.fail(.nesting_too_deep, "式や命令の入れ子が深すぎます", self.peek());
    }

    pub fn leaveNesting(self: *Parser) void {
        self.nesting_depth -= 1;
    }

    /// 解析済みのASTの深さを、明示的なスタックで測る（再帰すると検査自体が
    /// プロセススタックを使い切る）。上限を超えたときだけ最深部の位置を返す。
    /// パーサの再帰深さでは捕まえられない左入れ子（`1+1+...`）と連鎖呼出しを、
    /// 後段の意味解析・loweringへ渡す前に止める。
    pub fn exceedAstDepth(self: *Parser, root: *ast.Node) std.mem.Allocator.Error!?ast.Span {
        const Frame = struct { node: *ast.Node, index: usize };
        var stack: std.ArrayList(Frame) = .empty;
        defer stack.deinit(self.allocator);
        try stack.append(self.allocator, .{ .node = root, .index = 0 });
        while (stack.items.len > 0) {
            const top = stack.items[stack.items.len - 1];
            if (top.index >= top.node.children.len) {
                _ = stack.pop();
                continue;
            }
            stack.items[stack.items.len - 1].index += 1;
            const child = top.node.children[top.index];
            if (stack.items.len + 1 > max_ast_depth) return child.span;
            try stack.append(self.allocator, .{ .node = child, .index = 0 });
        }
        return null;
    }

    pub fn parseProgram(self: *Parser) ParseFailure!*ast.Node {
        const root = try self.parseBlock(.{});
        if (!self.at(.eof)) return self.fail(.unexpected_token, "プログラム末尾に解釈できないトークンがあります", self.peek());
        return root;
    }

    /// 取り込み先モジュールの終端モードを、取り込み文の直後から適用する。
    /// 公式は取り込み先トークンを結合して単一パースするため、取り込み先内の
    /// DNCLモード文が後続の取り込み元の文にも効く。モードは単調に有効化される
    /// だけなので OR 適用で足りる。取り込み文自身の解析には適用しない
    /// （position は取り込み文の先頭なので `>` で比較する）。
    pub fn applyTailModes(self: *Parser) void {
        while (self.tail_cursor < self.tail_modes.len and
            self.peek().span.start > self.tail_modes[self.tail_cursor].position)
        {
            const tail = self.tail_modes[self.tail_cursor];
            self.mode.dncl = self.mode.dncl or tail.mode.dncl;
            self.mode.dncl2 = self.mode.dncl2 or tail.mode.dncl2;
            self.mode.indent = self.mode.indent or tail.mode.indent;
            self.tail_cursor += 1;
        }
    }

    /// 取り込み文の位置とその時点のモードを記録する。
    /// 取り込み先はこの時点のモードを継承してパースされる（公式の結合ストリーム相当）。
    pub fn recordImportMode(self: *Parser, node: *ast.Node) ParseFailure!void {
        try self.import_modes.append(self.allocator, .{ .position = node.span.start, .mode = self.mode, .own_mode = self.own_mode });
    }

    pub fn parseBlock(self: *Parser, stop: Stop) ParseFailure!*ast.Node {
        const first = self.peek();
        var children: std.ArrayList(*ast.Node) = .empty;
        while (!self.at(.eof) and !self.isStop(stop)) {
            const before = self.index;
            const node = try self.parseStatement();
            try children.append(self.allocator, node);
            if (self.index == before) return self.fail(.unexpected_token, "構文解析を進められません", self.peek());
        }
        return builder.makeNodeWithChildren(self, .block, first, try children.toOwnedSlice(self.allocator));
    }

    pub fn parseStatement(self: *Parser) ParseFailure!*ast.Node {
        // 文の解析は全てここを通るため、入れ子の上限はここで数える。ブロック・
        // 同一行の制御構文（`もし1ならばもし1ならば…`）・ループ本体・スコープ
        // 指定・無名関数は、いずれも`parseStatement`の再帰として深くなる。
        try self.enterNesting();
        defer self.leaveNesting();
        self.applyTailModes();
        const token = self.peek();
        if (self.isImportDirective()) return self.parseImportDirective();
        if (self.isLegacySequentialDirective()) return self.parseLegacySequentialDirective();
        if (self.isLegacyAsyncDirective()) return self.parseLegacyAsyncDirective();
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
                if (self.isTowaDeclaration() or self.canStartAssignment()) break :blk self.parseAssignment();
                break :blk self.parseCallOrControl();
            },
        };
    }

    pub fn parseImplicitResultAssignment(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        const value = try self.parseCallExpression();
        const node = try builder.makeNodeWithChildren(self, .assignment, start, try builder.copyChildren(self, &.{value}));
        node.name = "それ";
        node.josi = "";
        return node;
    }

    pub fn parseEol(self: *Parser) ParseFailure!*ast.Node {
        const token = self.advance();
        return builder.makeNode(self, .eol, token);
    }

    pub fn simpleStatement(self: *Parser, kind: ast.Kind) ParseFailure!*ast.Node {
        const token = self.advance();
        return builder.makeNode(self, kind, token);
    }

    pub fn parseModeDirective(self: *Parser) ParseFailure!*ast.Node {
        const first = self.advance();
        // 公式yDNCLMode相当: この文の位置から配列モードを有効化し、空行を返す。
        if (first.kind == .keyword_dncl_mode) {
            self.mode.dncl = true;
            self.own_mode.dncl = true;
            return builder.makeNode(self, .eol, first);
        }
        if (first.kind == .keyword_dncl2_mode) {
            self.mode.dncl2 = true;
            self.own_mode.dncl2 = true;
            return builder.makeNode(self, .eol, first);
        }
        if (first.kind == .not) {
            const directive = try self.require(.identifier, "『!』の後ろにモード名が必要です");
            if (std.mem.eql(u8, directive.value, "モジュール公開既定値")) {
                _ = try self.require(.equal, "モジュール公開既定値に『=』が必要です");
                _ = try expressions.parseExpression(self, 0);
                return builder.makeNode(self, .eol, first);
            }
            const node = try builder.makeNode(self, .run_mode, first);
            node.value = if (std.mem.eql(u8, directive.value, "厳チェック")) "厳しくチェック" else directive.value;
            return node;
        }
        const node = try builder.makeNode(self, .run_mode, first);
        node.value = first.value;
        return node;
    }

    pub fn parseLegacySequentialDirective(self: *Parser) ParseFailure!*ast.Node {
        const directive = self.advance();
        try self.reportLegacyDeprecation(directive, "『逐次実行』構文は廃止されました(https://nadesi.com/v3/doc/go.php?944)。");
        // 公式は廃止語句を消費した後、次のトークンを位置に持つ空文を返す。
        // 実際の改行や後続文は次のparseStatementへ渡して継続する。
        return builder.makeNode(self, .eol, self.peek());
    }

    pub fn parseLegacyAsyncDirective(self: *Parser) ParseFailure!*ast.Node {
        _ = self.advance(); // !
        _ = self.advance(); // 非同期モード
        // 公式のlogger.errorも、!非同期モードを消費した後のpeekを位置に使う。
        try self.reportLegacyDeprecation(self.peek(), "『非同期モード』構文は廃止されました(https://nadesi.com/v3/doc/go.php?1028)。");
        return builder.makeNode(self, .eol, self.peek());
    }

    pub fn reportLegacyDeprecation(self: *Parser, token: Token, message: []const u8) ParseFailure!void {
        self.diagnostics.append(self.allocator, .{
            .severity = .error_severity,
            .code = .legacy_deprecated,
            .message = message,
            .file = self.filename,
            .span = token.span,
        }) catch return error.OutOfMemory;
    }

    pub fn isLegacySequentialDirective(self: *Parser) bool {
        return self.peek().kind == .identifier and std.mem.eql(u8, self.peek().value, "逐次実行");
    }

    pub fn isLegacyAsyncDirective(self: *Parser) bool {
        const token = self.peek();
        const next = self.peekAhead(1);
        return token.kind == .not and next.kind == .keyword_async and
            std.mem.eql(u8, next.value, "非同期モード");
    }

    pub fn isModeDirective(self: *Parser) bool {
        const token = self.peek();
        if (token.kind == .not) {
            const next = self.peekAhead(1);
            return next.kind == .identifier and (std.mem.eql(u8, next.value, "厳チェック") or
                std.mem.eql(u8, next.value, "モジュール公開既定値") or
                std.mem.eql(u8, next.value, "非同期モード"));
        }
        return token.kind == .keyword_mode or token.kind == .keyword_async or
            token.kind == .keyword_dncl_mode or token.kind == .keyword_dncl2_mode or
            (token.kind == .identifier and (std.mem.eql(u8, token.value, "厳チェック") or
                std.mem.eql(u8, token.value, "モジュール公開既定値") or
                std.mem.eql(u8, token.value, "実行速度優先") or
                std.mem.eql(u8, token.value, "パフォーマンスモニタ適用")));
    }

    pub fn parseIf(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        self.skipCommas();
        var condition = try expressions.parseExpression(self, 0);
        if (!isConditionalJosi(condition.josi) and !self.identifierValue("ならば")) {
            return self.fail(.invalid_control_statement, "『もし』文の条件末尾に『ならば』が必要です", self.peek());
        }
        if (self.identifierValue("ならば")) _ = self.advance();
        // 公式parserは「Aでなければ」を条件式Aの否定ノードとして保持する。
        // DNCLの「Aでないならば」はsyntax_transformで同じ助詞へ正規化されるため、
        // 条件式のjosiを消す前にnotへ包む必要がある。
        if (std.mem.eql(u8, condition.josi, "でなければ")) {
            condition = try builder.unary(self, "not", condition, self.peekPrevious());
        }
        clearConditionalJosi(condition);

        var multiline = false;
        var true_block: *ast.Node = undefined;
        if (self.at(.eol)) {
            multiline = true;
            self.skipEols();
            true_block = try self.parseBlock(.{ .end = true, .else_branch = true });
        } else {
            true_block = try builder.wrapSingle(self, try self.parseStatement());
        }

        var false_block = try builder.emptyBlock(self, self.peek());
        if (self.at(.keyword_else)) {
            _ = self.advance();
            self.skipCommas();
            if (self.at(.eol)) {
                self.skipEols();
                false_block = try self.parseBlock(.{ .end = true });
            } else {
                // 公式parserは、複数行の真節でも違えば節が同じ行から
                // 始まる場合を「短文」として扱い、外側のここまでを要求しない。
                // これにより「そうでなくもし」を、内側のもし文だけが
                // インライン分岐として閉じる公式のASTに合わせる。
                multiline = false;
                false_block = try builder.wrapSingle(self, try self.parseStatement());
            }
        }
        if (multiline) try self.requireEnd("『もし』文");
        return builder.makeNodeWithChildren(self, .if_statement, start, try builder.copyChildren(self, &.{ condition, true_block, false_block }));
    }

    pub fn parsePostTestLoop(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        if (self.at(.keyword_repeat)) _ = self.advance();
        if (self.at(.keyword_here_from)) _ = self.advance();
        self.skipEols();
        const body = try self.parseBlock(.{ .end = true });
        if (self.at(.keyword_here_end)) _ = self.advance();
        self.skipCommas();
        var condition: *ast.Node = if (self.at(.eol) or self.at(.eof)) try builder.numberOne(self, start) else try expressions.parseExpression(self, 0);
        if (self.identifierValue("なる") and (std.mem.eql(u8, self.peek().josi, "まで") or std.mem.eql(u8, self.peek().josi, "までの"))) {
            const until = self.advance();
            condition = try builder.unary(self, "not", condition, until);
            condition.josi = "";
            condition.raw_josi = "";
        }
        if (self.at(.keyword_repeat_while)) _ = self.advance();
        return builder.makeNodeWithChildren(self, .post_test_loop, start, try builder.copyChildren(self, &.{ condition, body }));
    }

    pub fn parseTryExcept(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        self.skipEols();
        const body = try self.parseBlock(.{ .error_branch = true });
        if (!self.at(.keyword_error)) return self.fail(.invalid_control_statement, "『エラー監視』に『エラーならば』がありません", self.peek());
        const error_token = self.advance();
        if (!isConditionalJosi(error_token.josi) and self.identifierValue("ならば")) _ = self.advance();
        self.skipEols();
        const handler = try self.parseBlock(.{ .end = true });
        try self.requireEnd("『エラー監視』文");
        return builder.makeNodeWithChildren(self, .try_except, start, try builder.copyChildren(self, &.{ body, handler }));
    }

    pub fn parseFunctionDefinition(self: *Parser, is_test: bool) ParseFailure!*ast.Node {
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
        } else try builder.wrapSingle(self, try self.parseStatement());

        const node = try builder.makeNodeWithChildren(self, if (is_test) .test_definition else .function_definition, start, try builder.copyChildren(self, &.{body}));
        node.name = if (is_test) tokenStem(name_token) else name_token.value;
        node.arguments = arguments;
        node.is_export = is_export;
        return node;
    }

    pub fn parseArguments(self: *Parser) ParseFailure![]ast.Argument {
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

    pub fn parseDeclaration(self: *Parser, is_const: bool) ParseFailure!*ast.Node {
        const start = self.advance();
        if (self.at(.left_bracket)) {
            const names = try expressions.parseArrayLiteral(
                self,
            );
            _ = try self.require(.equal, "変数一覧の後ろに『=』が必要です");
            const value = try self.parseCallExpression();
            const node = try builder.makeNodeWithChildren(self, .variable_list_definition, start, try builder.copyChildren(self, &.{value}));
            node.arguments = try builder.namesToArguments(self, names.children);
            node.is_const = is_const;
            return node;
        }
        const name = try self.require(.identifier, "変数名が必要です");
        const has_attribute = self.at(.left_brace);
        const is_export = try self.parseVariableAttribute(true);
        // 公式は`変数 A`の初期値省略を許し、その値は0になる。属性付きの
        // 宣言と`定数`は`=`を必須にする。
        var value = try builder.omittedValue(self, name);
        if (self.at(.equal)) {
            _ = self.advance();
            value = try self.parseCallExpression();
        } else if (is_const or has_attribute) {
            return self.fail(.expected_token, "変数宣言に『=』が必要です", self.peek());
        }
        const node = try builder.makeNodeWithChildren(self, .variable_definition, start, try builder.copyChildren(self, &.{value}));
        node.name = name.value;
        node.is_const = is_const;
        node.is_export = is_export;
        return node;
    }

    /// 変数・定数の`{公開}`/`{非公開}`属性を読み、公開可否を返す。
    /// 属性が無ければ`default`をそのまま返す。
    pub fn parseVariableAttribute(self: *Parser, default: bool) ParseFailure!bool {
        if (!self.at(.left_brace)) return default;
        _ = self.advance();
        const attribute = try self.require(.identifier, "変数属性が必要です");
        _ = try self.require(.right_brace, "変数属性を閉じる『}』が必要です");
        if (std.mem.eql(u8, attribute.value, "非公開")) return false;
        if (std.mem.eql(u8, attribute.value, "公開") or std.mem.eql(u8, attribute.value, "エクスポート")) return true;
        return default;
    }

    /// `取込 <expr>` の文頭形式。
    pub fn parseImport(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        const path = try expressions.parseExpression(self, 0);
        const node = try builder.makeNodeWithChildren(self, .import, start, try builder.copyChildren(self, &.{path}));
        node.value = path.value;
        try self.recordImportMode(node);
        return node;
    }

    pub fn isImportDirective(self: *Parser) bool {
        if (!self.at(.not) or (self.peekAhead(1).kind != .string and self.peekAhead(1).kind != .string_template)) return false;
        var offset: usize = 2;
        while (self.peekAhead(offset).kind != .eol and self.peekAhead(offset).kind != .eof) : (offset += 1) {
            if (self.peekAhead(offset).kind == .keyword_import) return true;
        }
        return false;
    }

    pub fn parseImportDirective(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        const path_token = self.advance();
        const path = try builder.valueNode(self, .string, path_token);
        _ = try self.require(.keyword_import, "取り込み文に『取り込む』が必要です");
        const node = try builder.makeNodeWithChildren(self, .import, start, try builder.copyChildren(self, &.{path}));
        node.value = path.value;
        node.josi = "";
        try self.recordImportMode(node);
        return node;
    }

    pub fn parseDebugDisplay(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        const value = try expressions.parseExpression(self, 0);
        const node = try builder.makeNodeWithChildren(self, .function_call, start, try builder.copyChildren(self, &.{value}));
        node.name = "ハテナ関数実行";
        return node;
    }

    pub fn canStartAssignment(self: *Parser) bool {
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

    /// `Aとは変数`/`Aとは定数`の宣言文。公式は初期値を省略できるため、
    /// `=`の有無だけを見る`canStartAssignment`では判定できない。
    pub fn isTowaDeclaration(self: *Parser) bool {
        const token = self.peek();
        if (token.kind != .identifier) return false;
        if (!std.mem.eql(u8, token.josi, "とは")) return false;
        const next = self.peekAhead(1);
        return next.kind == .keyword_let or next.kind == .keyword_const;
    }

    pub fn parseAssignment(self: *Parser) ParseFailure!*ast.Node {
        const start = self.peek();
        var targets: std.ArrayList(*ast.Node) = .empty;
        try targets.append(self.allocator, try self.parseLValue());
        while (self.at(.comma)) {
            _ = self.advance();
            try targets.append(self.allocator, try self.parseLValue());
        }
        // 公式は`Aとは変数`/`Aとは定数`を宣言として扱い、`{公開}`/`{非公開}`
        // 属性と`=`による初期値を任意にする。
        const declaration_from_towa = (self.at(.keyword_let) or self.at(.keyword_const)) and
            std.mem.eql(u8, targets.items[0].josi, "とは");
        var declaration_is_const = false;
        var declaration_is_export = true;
        if (declaration_from_towa) {
            declaration_is_const = self.peek().kind == .keyword_const;
            _ = self.advance();
            declaration_is_export = try self.parseVariableAttribute(true);
        }
        var value = if (declaration_from_towa) try builder.omittedValue(self, start) else undefined;
        if (self.at(.equal)) {
            _ = self.advance();
            value = try self.parseCallExpression();
        } else if (!declaration_from_towa) {
            return self.fail(.expected_token, "代入文に『=』が必要です", self.peek());
        }
        if (targets.items.len > 1) {
            const result = try builder.makeNodeWithChildren(self, .variable_list_definition, start, try builder.copyChildren(self, &.{value}));
            result.arguments = try builder.namesToArguments(self, targets.items);
            return result;
        }
        const target = targets.items[0];
        const kind: ast.Kind = switch (target.kind) {
            .array_reference => .array_assignment,
            .property_reference => .property_assignment,
            else => if (declaration_from_towa) .variable_definition else .assignment,
        };
        const target_children = if (target.kind == .array_reference or target.kind == .property_reference)
            try builder.assignmentPath(self, target)
        else
            target.children;
        const children = if (target_children.len == 0)
            try builder.copyChildren(self, &.{value})
        else
            try builder.prepend(self, value, target_children);
        const node = try builder.makeNodeWithChildren(self, kind, start, children);
        node.name = if (target.name.len > 0) target.name else target.value;
        node.josi = "";
        if (declaration_from_towa) {
            node.is_const = declaration_is_const;
            node.is_export = declaration_is_export;
        }
        // DNCLでは未初期化変数への配列要素代入で30要素配列を自動初期化する（公式flagCheckArrayInit相当）
        node.check_array_init = kind == .array_assignment and (self.mode.dncl or self.mode.dncl2);
        return node;
    }

    pub fn parseLValue(self: *Parser) ParseFailure!*ast.Node {
        const token = try self.require(.identifier, "代入先の変数名が必要です");
        var base = try builder.valueNode(self, .word, token);
        while (true) {
            if (self.at(.at)) {
                const at_token = self.advance();
                // 公式はprop[i]形（プロパティ参照への添字適用）を受理しない
                if (base.kind == .property_reference) return self.fail(.invalid_array_access, "配列アクセスで指定ミス", at_token);
                const index = try builder.dnclArrayIndex(self, try expressions.parsePrimary(
                    self,
                ));
                base = try builder.reference(self, .array_reference, base, &.{index}, at_token);
                continue;
            }
            if (self.at(.left_bracket)) {
                const open = self.advance();
                if (base.kind == .property_reference) return self.fail(.invalid_array_access, "配列アクセスで指定ミス", open);
                self.delimited_expression_depth += 1;
                defer self.delimited_expression_depth -= 1;
                var indexes: std.ArrayList(*ast.Node) = .empty;
                while (!self.at(.right_bracket) and !self.at(.eof)) {
                    const index = try expressions.parseExpression(self, 0);
                    // 読み出し側と同じく、公式はfunc tokenをカンマ直前では
                    // 値として受理しない（代入側のlet_arrayでも指定ミスになる）。
                    if (index.kind == .word and index.josi.len == 0 and !index.grouped and self.at(.comma)) index.bare_index_word = true;
                    try indexes.append(self.allocator, try builder.dnclArrayIndex(self, index));
                    // 代入側は公式のlet_array同様にカンマ区切りの次元数制限がない
                    if (!self.at(.comma)) break;
                    _ = self.advance();
                }
                const close = try self.require(.right_bracket, "配列添字を閉じる『]』が必要です");
                builder.dnclReverseIndexes(self, indexes.items);
                base = try builder.reference(self, .array_reference, base, try indexes.toOwnedSlice(self.allocator), open);
                base.josi = close.josi;
                continue;
            }
            if (self.at(.property)) {
                const property_token = self.advance();
                const name = self.advance();
                if (name.kind != .identifier and name.kind != .string) return self.fail(.expected_name, "『$』の後ろにプロパティ名が必要です", name);
                const property = try builder.valueNode(self, .string, name);
                base = try builder.reference(self, .property_reference, base, &.{property}, property_token);
                base.josi = name.josi;
                continue;
            }
            break;
        }
        return base;
    }

    pub fn parseCallOrControl(self: *Parser) ParseFailure!*ast.Node {
        const start = self.peek();
        var arguments: std.ArrayList(*ast.Node) = .empty;
        var chained_calls: std.ArrayList(*ast.Node) = .empty;
        while (!self.at(.eol) and !self.at(.eof) and !self.at(.keyword_here_end) and !self.at(.keyword_else)) {
            if (self.at(.identifier) and isImplicitCallbackJosi(self.peek().josi)) {
                const command = self.advance();
                const call = try self.parseImplicitCallbackCall(command, arguments.items);
                if (chained_calls.items.len == 0) return call;
                try chained_calls.append(self.allocator, call);
                return builder.makeNodeWithChildren(self, .block, start, try chained_calls.toOwnedSlice(self.allocator));
            }
            if (self.at(.keyword_return)) {
                const keyword = self.advance();
                const value = if (arguments.items.len > 0) arguments.items[arguments.items.len - 1] else try builder.nop(self, keyword);
                const result = try builder.makeNodeWithChildren(self, .return_statement, start, try builder.copyChildren(self, &.{value}));
                result.josi = "";
                return result;
            }
            if (self.at(.keyword_repeat_count)) {
                const keyword = self.advance();
                const count = if (arguments.items.len > 0) arguments.items[arguments.items.len - 1] else try self.implicitIt(keyword);
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
                const collection = if (arguments.items.len > 0) arguments.items[arguments.items.len - 1] else try builder.nop(self, start);
                return self.parseForeach(start, collection);
            }
            if (self.at(.keyword_import)) {
                const command = self.advance();
                if (arguments.items.len == 0) return self.fail(.expected_expression, "取り込み先が必要です", command);
                const path = arguments.items[arguments.items.len - 1];
                const node = try builder.makeNodeWithChildren(self, .import, start, try builder.copyChildren(self, &.{path}));
                node.value = path.value;
                node.josi = "";
                try self.recordImportMode(node);
                return node;
            }
            if ((self.identifierValue("増") or self.identifierValue("減")) and self.peekAhead(1).kind == .keyword_repeat) {
                return self.parseFor(start, arguments.items);
            }

            // 助詞付きの既知命令名は、公式`yCallFunc`と同じく命令として呼び出し、
            // 結果を次の命令の引数にする（`大文字変換を表示`）。
            if (try self.callChainedBuiltinCommand(&arguments)) {
                // 直後の識別子は連鎖の結果を引数に取る命令名なので、ここで解決する。
                if (self.at(.identifier) and !self.isChainedBuiltinCommand(self.peek())) {
                    if (try self.resolveCommandName(start, &arguments, &chained_calls)) |statement| return statement;
                }
                continue;
            }

            if (chained_calls.items.len > 0 and self.at(.identifier)) {
                // 連文の続きが引数（「に」「を」「へ」等）で始まる場合、
                // その識別子を命令と誤認せず、下のparseExpression経由で引数として処理する。
                const token = self.peek();
                if (token.josi.len > 0 and !isSequenceJosi(token.josi) and !isImplicitCallbackJosi(token.josi)) {
                    // fall through to parseExpression.
                } else {
                    const command = self.advance();
                    const call = try self.makeCommandCall(command, try arguments.toOwnedSlice(self.allocator));
                    try chained_calls.append(self.allocator, call);
                    if (isSequenceJosi(command.josi)) {
                        arguments = .empty;
                        try arguments.append(self.allocator, try self.implicitIt(command));
                        continue;
                    }
                    return builder.makeNodeWithChildren(self, .block, start, try chained_calls.toOwnedSlice(self.allocator));
                }
            }

            const expression = try expressions.parseExpression(self, 0);
            if (expression.kind == .function_call and self.isTerminator()) {
                return expression;
            }
            try arguments.append(self.allocator, expression);

            if (self.at(.identifier)) {
                if (try self.resolveCommandName(start, &arguments, &chained_calls)) |statement| return statement;
                continue;
            }
            if (self.isTerminator()) break;
        }

        if (chained_calls.items.len > 0) return builder.makeNodeWithChildren(self, .block, start, try chained_calls.toOwnedSlice(self.allocator));
        if (arguments.items.len == 1) {
            const value = arguments.items[0];
            if (value.kind == .word) {
                const call = try builder.makeNode(self, .function_call, start);
                call.name = value.value;
                call.josi = value.josi;
                return call;
            }
            const node = try builder.makeNodeWithChildren(self, .dynamic_execute, start, try builder.copyChildren(self, &.{value}));
            return node;
        }
        return self.fail(.unexpected_token, "命令呼び出しを構成できません", self.peek());
    }

    /// 現在位置の識別子を命令名として解決する。命令・制御構文へ確定した場合は
    /// そのノードを返し、識別子が引数として扱われる場合は`null`を返す
    /// （呼出し元は文の解析を継続する）。
    fn resolveCommandName(
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
        // その位置の識別子を命令として確定する。
        if (self.peek().josi.len > 0 and
            !isSequenceJosi(self.peek().josi) and
            !isImplicitCallbackJosi(self.peek().josi) and
            self.peekAhead(1).kind == .identifier)
        {
            return null;
        }
        // 配列添字・プロパティ・@参照の直後に助詞が続く場合、識別子は命令名ではなく値として続行する。
        // 例: `1をA[0]に代入`, `1をA$fooに代入`。
        const next_kind = self.peekAhead(1).kind;
        if (next_kind == .left_bracket or next_kind == .at or next_kind == .property) return null;
        if ((self.identifierValue("増") or self.identifierValue("減")) and self.peekAhead(1).kind == .keyword_repeat) {
            return try self.parseFor(start, arguments.items);
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

    /// 公式の`func token`相当（既知の命令名）かどうか。
    fn isBuiltinCommandName(self: *Parser, value: []const u8) bool {
        for (self.builtin_commands) |name| if (std.mem.eql(u8, name, value)) return true;
        return false;
    }

    /// 現在位置の識別子が「助詞付きの既知命令名」で、直後にも識別子が続くか。
    /// 公式`yCallFunc`はこの位置の命令を呼び出し、結果を次の命令の引数にする。
    fn isChainedBuiltinCommand(self: *Parser, token: Token) bool {
        if (token.kind != .identifier) return false;
        if (token.josi.len == 0 or isSequenceJosi(token.josi) or isImplicitCallbackJosi(token.josi)) return false;
        if (self.peekAhead(1).kind != .identifier) return false;
        return self.isBuiltinCommandName(token.value);
    }

    /// 現在位置の助詞付き命令を呼び出し、結果を引数リストへ置き換える。
    /// 置き換えた場合は`true`を返す。
    fn callChainedBuiltinCommand(self: *Parser, arguments: *std.ArrayList(*ast.Node)) ParseFailure!bool {
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

        // 「に代入」は「に」が代入先、「を」が値。「に定める」は「を」が定義対象、「に」が値。

        var target_index: ?usize = null;
        var value_index: ?usize = null;
        for (arguments, 0..) |arg, i| {
            const arg_is_target = if (is_define) isValueJosi(arg.josi) else isTargetJosi(arg.josi);
            const arg_is_value = if (is_define) isTargetJosi(arg.josi) else isValueJosi(arg.josi);
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
                if (target.kind != .word and target.kind != .array_reference and target.kind != .property_reference)
                    return self.fail(.invalid_assignment, "代入先は変数・配列・プロパティである必要があります", command);
                value = if (value_index) |vi| arguments[vi] else if (value_index == null and arguments.len > 1 and ti != 0) arguments[0] else try self.implicitIt(command);
            } else if (value_index) |vi| {
                value = arguments[vi];
                target = if (vi == 0) try self.implicitIt(command) else arguments[0];
                if (target.kind != .word and target.kind != .array_reference and target.kind != .property_reference)
                    return self.fail(.invalid_assignment, "代入先は変数・配列・プロパティである必要があります", command);
            } else {
                target = arguments[0];
                if (target.kind != .word and target.kind != .array_reference and target.kind != .property_reference)
                    return self.fail(.invalid_assignment, "代入先は変数・配列・プロパティである必要があります", command);
                value = if (arguments.len > 1) arguments[1] else try self.implicitIt(command);
            }

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
            // `Aを1に定める`の宣言も公式同様にモジュール変数として既定公開する。
            // ASTのis_exportは既定falseなので、ここで明示する。
            if (kind == .variable_definition) result.is_export = true;
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

    pub fn parseScopedMode(self: *Parser, start: Token, command: Token, option: *ast.Node) ParseFailure!*ast.Node {
        const kind: ast.Kind = if (std.mem.eql(u8, command.value, "実行速度優先")) .speed_mode else .performance_monitor;
        var body: *ast.Node = undefined;
        if (self.at(.keyword_here_from)) _ = self.advance();
        if (self.at(.eol)) {
            self.skipEols();
            body = try self.parseBlock(.{ .end = true });
            try self.requireEnd("実行モード指定");
        } else {
            body = try builder.wrapSingle(self, try self.parseStatement());
        }
        const result = try builder.makeNodeWithChildren(self, kind, start, try builder.copyChildren(self, &.{body}));
        _ = option;
        result.value = "";
        result.josi = "";
        return result;
    }

    pub fn parseSwitch(self: *Parser, start: Token, condition: *ast.Node) ParseFailure!*ast.Node {
        self.skipEols();
        var default_block = try builder.emptyBlock(self, start);
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
            const case_value = try expressions.parseExpression(self, 0);
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
        const result = try builder.makeNodeWithChildren(self, .switch_statement, start, try children.toOwnedSlice(self.allocator));
        result.josi = "";
        return result;
    }

    pub fn parseCallExpression(self: *Parser) ParseFailure!*ast.Node {
        if (self.at(.def_func)) return self.parseAnonymousFunction();
        const value = try expressions.parseExpression(self, 0);
        if (!self.at(.identifier) and (value.josi.len == 0 or !canStartExpression(self.peek().kind))) return value;
        var arguments: std.ArrayList(*ast.Node) = .empty;
        try arguments.append(self.allocator, value);

        // DNCLの「すべての値を0にする」は、公式の変換後に
        // `[0] 100を掛`という助詞付きの連続引数になる。最初の式の
        // 直後が識別子でない場合も、次の命令まで引数式を集める。
        // 識別子の引数は、次の識別子が命令名として続く場合だけ読む。
        const argument_start = self.index;
        while (true) {
            if (self.at(.identifier)) {
                // 助詞付きの既知命令名は、文位置と同じく連鎖呼出しとして解決する
                // （`A=「abc」の大文字変換を文字数`の右辺も同じASTにする）。
                if (try self.callChainedBuiltinCommand(&arguments)) continue;
                if (self.peek().josi.len > 0 and self.peekAhead(1).kind == .identifier) {
                    try arguments.append(self.allocator, try expressions.parseExpression(self, 0));
                    continue;
                }
                break;
            }
            if (self.isTerminator() or arguments.items[arguments.items.len - 1].josi.len == 0 or
                !canStartExpression(self.peek().kind)) break;
            try arguments.append(self.allocator, try expressions.parseExpression(self, 0));
        }
        if (!self.at(.identifier)) {
            self.index = argument_start;
            return value;
        }
        while (self.at(.identifier)) {
            const command = self.advance();
            const call = try builder.makeNodeWithChildren(self, .function_call, command, try arguments.toOwnedSlice(self.allocator));
            call.name = command.value;
            call.josi = command.josi;
            if (!isSequenceJosi(command.josi)) return call;
            arguments = .empty;
            try arguments.append(self.allocator, call);
            if (!self.isTerminator()) try arguments.append(self.allocator, try expressions.parseExpression(self, 0));
        }
        return arguments.items[0];
    }

    pub fn parseRepeatTimes(self: *Parser, start: Token, count: *ast.Node) ParseFailure!*ast.Node {
        if (self.at(.comma)) _ = self.advance();
        if (self.at(.keyword_repeat)) _ = self.advance();
        const body = try self.parseLoopBody("『回』繰り返し");
        return builder.makeNodeWithChildren(self, .repeat_times, start, try builder.copyChildren(self, &.{ count, body }));
    }

    pub fn parseWhile(self: *Parser, start: Token, condition: *ast.Node) ParseFailure!*ast.Node {
        self.skipCommas();
        if (self.at(.keyword_repeat)) _ = self.advance();
        const body = try self.parseLoopBody("『間』繰り返し");
        const result = try builder.makeNodeWithChildren(self, .while_statement, start, try builder.copyChildren(self, &.{ condition, body }));
        result.josi = "";
        result.raw_josi = "";
        return result;
    }

    pub fn parseFor(self: *Parser, start: Token, arguments: []const *ast.Node) ParseFailure!*ast.Node {
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
        const increment = if (arguments.len > offset + 2) arguments[offset + 2] else try builder.nop(self, keyword);
        const body = try self.parseLoopBody("『繰り返す』文");
        const node = try builder.makeNodeWithChildren(self, .for_statement, start, try builder.copyChildren(self, &.{ arguments[offset], arguments[offset + 1], increment, body }));
        node.name = variable;
        node.josi = "";
        node.loop_direction = direction;
        if (std.mem.eql(u8, keyword.value, "増繰返")) node.loop_direction = .up;
        if (std.mem.eql(u8, keyword.value, "減繰返")) node.loop_direction = .down;
        return node;
    }

    pub fn parseForeach(self: *Parser, start: Token, collection: *ast.Node) ParseFailure!*ast.Node {
        const body = try self.parseLoopBody("『反復』文");
        const result = try builder.makeNodeWithChildren(self, .foreach_statement, start, try builder.copyChildren(self, &.{ collection, body }));
        result.josi = "";
        result.raw_josi = "";
        return result;
    }

    pub fn parseLoopBody(self: *Parser, description: []const u8) ParseFailure!*ast.Node {
        self.skipCommas();
        if (self.at(.keyword_here_from)) _ = self.advance();
        if (self.at(.eol)) {
            self.skipEols();
            const body = try self.parseBlock(.{ .end = true });
            try self.requireEnd(description);
            return body;
        }
        return builder.wrapSingle(self, try self.parseStatement());
    }

    pub fn parseAnonymousFunction(self: *Parser) ParseFailure!*ast.Node {
        const start = self.advance();
        const arguments: []ast.Argument = if (self.at(.left_paren)) try self.parseArguments() else &.{};
        if (self.at(.eol)) self.skipEols();
        const body = try self.parseBlock(.{ .end = true });
        try self.requireEnd("無名関数");
        const node = try builder.makeNodeWithChildren(self, .anonymous_function, start, try builder.copyChildren(self, &.{body}));
        node.arguments = arguments;
        return node;
    }

    pub fn requireEnd(self: *Parser, description: []const u8) ParseFailure!void {
        if (!self.at(.keyword_here_end)) {
            const message = try std.fmt.allocPrint(self.allocator, "{s}の末尾に『ここまで』が必要です", .{description});
            return self.fail(.missing_block_end, message, self.peek());
        }
        _ = self.advance();
    }

    pub fn require(self: *Parser, kind: Kind, message: []const u8) ParseFailure!Token {
        if (!self.at(kind)) return self.fail(.expected_token, message, self.peek());
        return self.advance();
    }

    pub fn fail(self: *Parser, code: diagnostic.Code, message: []const u8, token: Token) ParseFailure {
        self.diagnostics.append(self.allocator, .{
            .code = code,
            .message = message,
            .file = self.filename,
            .span = token.span,
        }) catch return error.OutOfMemory;
        return error.ParseFailed;
    }

    pub fn isStop(self: *Parser, stop: Stop) bool {
        return (stop.end and self.at(.keyword_here_end)) or
            (stop.else_branch and self.at(.keyword_else)) or
            (stop.error_branch and self.at(.keyword_error));
    }

    pub fn isTerminator(self: *Parser) bool {
        return self.at(.eol) or self.at(.eof) or self.at(.right_paren) or self.at(.right_bracket) or
            self.at(.right_brace) or self.at(.keyword_here_end) or self.at(.keyword_else) or self.at(.keyword_error);
    }

    pub fn skipEols(self: *Parser) void {
        while (self.at(.eol)) _ = self.advance();
    }

    pub fn skipCommas(self: *Parser) void {
        while (self.at(.comma)) _ = self.advance();
    }

    pub fn identifierValue(self: *Parser, value: []const u8) bool {
        return self.at(.identifier) and std.mem.eql(u8, self.peek().value, value);
    }

    pub fn at(self: *Parser, kind: Kind) bool {
        return self.peek().kind == kind;
    }

    pub fn advance(self: *Parser) Token {
        const token = self.peek();
        if (self.index < self.tokens.len) self.index += 1;
        return token;
    }

    pub fn peek(self: *Parser) Token {
        if (self.tokens.len == 0) return emptyToken();
        return self.tokens[@min(self.index, self.tokens.len - 1)];
    }

    pub fn peekPrevious(self: *Parser) Token {
        if (self.index == 0 or self.tokens.len == 0) return self.peek();
        return self.tokens[@min(self.index - 1, self.tokens.len - 1)];
    }

    pub fn peekAhead(self: *Parser, distance: usize) Token {
        if (self.tokens.len == 0) return emptyToken();
        return self.tokens[@min(self.index + distance, self.tokens.len - 1)];
    }
};
test {
    _ = @import("parser_test.zig");
}
