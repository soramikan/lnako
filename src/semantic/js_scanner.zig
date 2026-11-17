const std = @import("std");

/// `.operand` は値として評価されるliteral系token（regex literal・閉じた
/// template literal）で、文字列ではないためspecifierにはならないが、
/// 直後の `/` が除算となる判定ではoperand扱いされる必要がある。
pub const JavaScriptTokenKind = enum { identifier, string, punctuation, operand };
pub const JavaScriptToken = struct { kind: JavaScriptTokenKind, text: []const u8 };

/// template literal内で `${` / `{` の対応を追跡する文脈。
/// `.interpolation` は `${` で開く式領域、`.brace` は式中の `{`。
const JavaScriptTemplateContext = enum { brace, interpolation };

/// JavaScriptScanner.mark/restoreで往復する走査状態。`next` の内部遷移
/// （`${` push・`}` pop・template text消費）を含めて巻き戻せるよう、
/// indexだけでなく文脈stack深さ・truncated・直前tokenも保持する。
pub const ScannerMark = struct {
    index: usize,
    contexts_len: usize,
    truncated: bool,
    last_token: ?JavaScriptToken,
};

/// 識別子直後の `/` をregex literalとみなすキーワード。これ以外の識別子・
/// 数値・`]`/`)`/`}`・文字列の直後の `/` は除算として扱う（誤検出では
/// regex中身がtoken化されてimport検出漏れになり得る — その場合も
/// runtime側のmodule_normalize境界が最終防衛になるdocumented制約）。
const regex_position_keywords = [_][]const u8{
    "return", "typeof", "instanceof", "in",       "of",      "new",
    "delete", "void",   "yield",      "await",    "throw",   "case",
    "do",     "else",   "default",    "debugger", "extends",
};

/// JavaScript sourceの軽量tokenizer。`import` 文やplugin exportの収集が
/// 目的のため、文字列は内容をtokenとして返し、template literalのtext部分は
/// スキップする。ただし `${...}` interpolation内の式は実行時に評価され
/// `import()` を含み得るためtoken化対象とする — 全体をskipすると補間内の
/// 動的importがgraphへ記録されず、QuickJS側loaderのFS fallbackが
/// package root外を読み得る。文字列・template・interpolation・文脈stackが
/// source終端までに閉じない（または上限を超える）場合は `truncated` を
/// 立て、呼出し側が収集不能な構造の残存をfail-closedで扱えるようにする。
pub const JavaScriptScanner = struct {
    source: []const u8,
    index: usize = 0,
    truncated: bool = false,
    contexts: [max_context_nesting]JavaScriptTemplateContext = undefined,
    contexts_len: usize = 0,
    /// 直前に返したtoken。regex literalと除算 `/` の区別に使う —
    /// `/}` のようなregex中の `}` が文脈stackを崩さないよう、式を開始
    /// できる位置の `/` のみregexとして読む。
    last_token: ?JavaScriptToken = null,

    const max_context_nesting = 1024;

    /// 返却tokenの発行と last_token 更新を一体化する。
    fn emit(self: *JavaScriptScanner, token: JavaScriptToken) JavaScriptToken {
        self.last_token = token;
        return token;
    }

    /// rewind用に現在のscanner状態を保存する。`next` は `${` pushや
    /// `}` pop、template text消費を内部で行うため、indexだけ巻き戻すと
    /// 文脈stackが見かけの位置と不整合になる。
    pub fn mark(self: *JavaScriptScanner) ScannerMark {
        return .{
            .index = self.index,
            .contexts_len = self.contexts_len,
            .truncated = self.truncated,
            .last_token = self.last_token,
        };
    }

    pub fn restore(self: *JavaScriptScanner, saved: ScannerMark) void {
        // contexts_lenを戻せば十分 — pushは末尾indexへ書き、popは
        // 減算のみなので巻き戻し後に再利用される領域だけを管理すればよい。
        self.index = saved.index;
        self.contexts_len = saved.contexts_len;
        self.truncated = saved.truncated;
        self.last_token = saved.last_token;
    }

    /// 現在位置の `/` がregex literalを開始するか。除算と誤認すると
    /// `/}` 等の中身がtoken化されて文脈対応が崩れるため、operandが続け
    /// られないtoken（文の区切り・式を開く記号・キーワード）の直後のみ
    /// regexとみなす。operand判定を外す保守的な誤判定ではregex中身が
    /// token化されてimport検出が漏れ得る — その場合も opaque 報告はなく
    /// runtime側のmodule_normalize境界が最終防衛になる（documented制約）。
    fn regexPosition(self: *JavaScriptScanner) bool {
        const token = self.last_token orelse return true;
        return switch (token.kind) {
            .string, .operand => false,
            .identifier => for (regex_position_keywords) |keyword| {
                if (std.mem.eql(u8, token.text, keyword)) break true;
            } else false,
            .punctuation => blk: {
                if (token.text.len == 1 and std.ascii.isDigit(token.text[0])) break :blk false;
                break :blk !(std.mem.eql(u8, token.text, ")") or
                    std.mem.eql(u8, token.text, "]") or
                    std.mem.eql(u8, token.text, "}"));
            },
        };
    }

    fn pushContext(self: *JavaScriptScanner, context: JavaScriptTemplateContext) void {
        if (self.contexts_len == max_context_nesting) {
            // 追跡不能な深さはtruncate扱いにしてfail-closedする。
            self.truncated = true;
            return;
        }
        self.contexts[self.contexts_len] = context;
        self.contexts_len += 1;
    }

    /// `` ` `` 直後、またはinterpolationを閉じた `}` 直後のtemplate textを
    /// 走査する。`` ` `` で閉じれば通常token化へ戻り、`${` があれば
    /// interpolation文脈をpushして式のtoken化へ移る。終端まで閉じなければ
    /// truncatedを立てる。
    fn scanTemplateText(self: *JavaScriptScanner) void {
        while (self.index < self.source.len) {
            const character = self.source[self.index];
            if (character == '\\') {
                self.index = @min(self.source.len, self.index + 2);
                continue;
            }
            if (character == '`') {
                self.index += 1;
                return;
            }
            if (character == '$' and self.index + 1 < self.source.len and self.source[self.index + 1] == '{') {
                self.index += 2;
                self.pushContext(.interpolation);
                return;
            }
            self.index += 1;
        }
        self.truncated = true;
    }

    pub fn next(self: *JavaScriptScanner) ?JavaScriptToken {
        while (self.index < self.source.len) {
            const character = self.source[self.index];
            if (std.ascii.isWhitespace(character)) {
                self.index += 1;
                continue;
            }
            if (character == '/' and self.index + 1 < self.source.len and self.source[self.index + 1] == '/') {
                self.index += 2;
                while (self.index < self.source.len and self.source[self.index] != '\n') self.index += 1;
                continue;
            }
            if (character == '/' and self.index + 1 < self.source.len and self.source[self.index + 1] == '*') {
                self.index += 2;
                while (self.index + 1 < self.source.len and !(self.source[self.index] == '*' and self.source[self.index + 1] == '/')) self.index += 1;
                self.index = @min(self.source.len, self.index + 2);
                continue;
            }
            if (character == '/' and self.regexPosition()) {
                // regex literal — `/}` のような中身が `}`/`"`/`` ` `` を含むと
                // 文脈stackや文字列走査を崩すため、閉じ `/` まで一括skipする。
                // 改行はregexに含められないため、改行・EOFまでに閉じなければ
                // 除算と判断して `/` を通常tokenとして返す。
                const regex_start = self.index;
                self.index += 1;
                var in_class = false;
                var closed = false;
                while (self.index < self.source.len) : (self.index += 1) {
                    const rc = self.source[self.index];
                    if (rc == '\\') {
                        self.index = @min(self.source.len, self.index + 1);
                        continue;
                    }
                    if (rc == '\n') break;
                    if (rc == '[') in_class = true;
                    if (rc == ']') in_class = false;
                    if (rc == '/' and !in_class) {
                        closed = true;
                        break;
                    }
                }
                if (closed) {
                    self.index += 1;
                    while (self.index < self.source.len and std.ascii.isAlphabetic(self.source[self.index])) self.index += 1;
                    // regex literalはoperand — 直後の `/` が除算になるよう
                    // .operandで発行する（punctuationだとregex開始位置と
                    // 誤判定され、後続の式が呑まれる）。
                    return self.emit(.{ .kind = .operand, .text = self.source[regex_start..self.index] });
                }
                self.index = regex_start;
            }
            if (character == '`') {
                const template_start = self.index;
                self.index += 1;
                const depth = self.contexts_len;
                self.scanTemplateText();
                if (!self.truncated) {
                    if (self.contexts_len == depth) {
                        // `` ` `` で閉じたtemplate literalはoperand — 直後の
                        // `/` が除算と判定されるよう last_token だけ更新する。
                        self.last_token = .{ .kind = .operand, .text = self.source[template_start..self.index] };
                    } else {
                        // `${` で補間へ移行 — 式の先頭はregex literalが
                        // 来得るため `(` と同じ式開始扱いにする。
                        self.last_token = .{ .kind = .punctuation, .text = "(" };
                    }
                }
                continue;
            }
            if (character == '{') {
                self.pushContext(.brace);
                self.index += 1;
                return self.emit(.{ .kind = .punctuation, .text = self.source[self.index - 1 .. self.index] });
            }
            if (character == '}') {
                self.index += 1;
                if (self.contexts_len > 0) {
                    const context = self.contexts[self.contexts_len - 1];
                    self.contexts_len -= 1;
                    // `${` を閉じる `}` はtemplate text側へ文脈を戻すだけで
                    // tokenとして返さない。式中の `{` を閉じる `}` のみ返す。
                    if (context == .interpolation) {
                        const depth = self.contexts_len;
                        self.scanTemplateText();
                        if (!self.truncated) {
                            if (self.contexts_len == depth) {
                                // templateが `` ` `` で閉じた — 補間込みでも
                                // template literal全体はoperand。直後の `/` を
                                // 除算と判定させるため last_token を更新する。
                                self.last_token = .{ .kind = .operand, .text = self.source[self.index - 1 .. self.index] };
                            } else {
                                // 続く `${` で次の補間へ — 式先頭はregexが来得る。
                                self.last_token = .{ .kind = .punctuation, .text = "(" };
                            }
                        }
                        continue;
                    }
                }
                return self.emit(.{ .kind = .punctuation, .text = self.source[self.index - 1 .. self.index] });
            }
            if (character == '\'' or character == '"') {
                const quote = character;
                const start = self.index + 1;
                self.index = start;
                while (self.index < self.source.len) : (self.index += 1) {
                    if (self.source[self.index] == '\\') {
                        self.index = @min(self.source.len, self.index + 1);
                        continue;
                    }
                    if (self.source[self.index] == quote) {
                        const text = self.source[start..self.index];
                        self.index += 1;
                        return self.emit(.{ .kind = .string, .text = text });
                    }
                }
                self.truncated = true;
                return null;
            }
            // 非ASCII（日本語識別子など）も identifier として扱う。punctuation
            // に落とすと直後の `/` を regex 開始と誤認し、import 走査が壊れる。
            if (std.ascii.isAlphabetic(character) or character == '_' or character == '$' or character >= 0x80) {
                const start = self.index;
                self.index += 1;
                while (self.index < self.source.len and (std.ascii.isAlphanumeric(self.source[self.index]) or self.source[self.index] == '_' or self.source[self.index] == '$' or self.source[self.index] >= 0x80)) self.index += 1;
                return self.emit(.{ .kind = .identifier, .text = self.source[start..self.index] });
            }
            self.index += 1;
            return self.emit(.{ .kind = .punctuation, .text = self.source[self.index - 1 .. self.index] });
        }
        // 開いたままのinterpolation文脈が残っていればsourceは構造を閉じずに
        // 終端へ達している — 残りのtokenが未走査のまま見逃されるため
        // truncatedとして報告する。
        if (self.contexts_len > 0) self.truncated = true;
        return null;
    }
};
