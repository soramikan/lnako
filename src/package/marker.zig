const std = @import("std");
const semver = @import("semver.zig");
const diagnostics = @import("diagnostics.zig");

pub const Position = diagnostics.Position;

/// marker式の構文エラー。`message` は静的な文字列リテラル。
pub const SyntaxError = struct {
    message: []const u8,
    position: Position,
};

/// marker式が参照できるプロファイル/コンテキストフィールド。
pub const Field = enum {
    os,
    cpu,
    abi,
    compat_js,
    optimize,
    version,
    features,

    pub fn name(self: Field) []const u8 {
        return switch (self) {
            .os => "os",
            .cpu => "cpu",
            .abi => "abi",
            .compat_js => "compat-js",
            .optimize => "optimize",
            .version => "version",
            .features => "features",
        };
    }
};

pub const CmpOp = enum {
    eq,
    ne,
    lt,
    lte,
    gt,
    gte,
    in,
    not_in,
};

pub const Operand = union(enum) {
    field: Field,
    string: []const u8,
    boolean: bool,
    list: []const Operand,
};

pub const Comparison = struct { left: Operand, op: CmpOp, right: Operand };

pub const Expr = union(enum) {
    or_: struct { left: *const Expr, right: *const Expr },
    and_: struct { left: *const Expr, right: *const Expr },
    not: *const Expr,
    comparison: Comparison,
    operand: Operand,
};

/// marker評価コンテキスト。OS/CPU/ABI/実行モード/バージョン/featuresを保持する。
pub const Context = struct {
    os: []const u8 = "",
    cpu: []const u8 = "",
    abi: []const u8 = "",
    compat_js: bool = false,
    optimize: []const u8 = "O0",
    version: ?semver.Version = null,
    features: []const []const u8 = &.{},
};

/// 解析済みmarker式。`arena` が全ノードを所有する。
pub const Marker = struct {
    arena: std.heap.ArenaAllocator,
    root: *const Expr,
    source: []const u8,

    pub fn deinit(self: *Marker) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn evaluate(self: *const Marker, context: Context) EvalError!bool {
        return evalExpr(self.root, context);
    }
};

pub const Result = union(enum) {
    ok: Marker,
    err: SyntaxError,
};

pub const Error = error{OutOfMemory};
pub const EvalError = error{ UnknownField, TypeMismatch, InvalidVersion };

/// marker式を解析する。文法:
///   or  := and ("or" and)*
///   and := unary ("and" unary)*
///   unary := "not" unary | "(" or ")" | comparison | operand
///   comparison := operand (==|!=|<|<=|>|>=|in|"not in") operand
///   operand := field | "string" | 'string' | true | false | [operand, ...]
///   field := os | cpu | abi | compat-js | optimize | version | features
pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!Result {
    var marker = Marker{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = undefined,
        .source = undefined,
    };
    errdefer marker.arena.deinit();
    const arena = marker.arena.allocator();
    marker.source = try arena.dupe(u8, text);

    var parser = Parser{ .marker = &marker };
    if (parser.parseRoot()) |_| {
        return .{ .ok = marker };
    } else |err| switch (err) {
        // OOM は errdefer が arena を解放する。
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const position = parser.position();
            const message = parser.error_message orelse "invalid marker";
            marker.arena.deinit();
            return .{ .err = .{ .message = message, .position = position } };
        },
    }
}

const Token = union(enum) {
    ident: []const u8,
    string: []const u8,
    lparen,
    rparen,
    lbracket,
    rbracket,
    comma,
    op_eq,
    op_ne,
    op_lt,
    op_lte,
    op_gt,
    op_gte,
    kw_and,
    kw_or,
    kw_not,
    kw_in,
    kw_true,
    kw_false,
};

const ParseError = error{ InvalidMarker, OutOfMemory };

const Parser = struct {
    marker: *Marker,
    index: usize = 0,
    error_message: ?[]const u8 = null,

    fn position(self: *const Parser) Position {
        var line: usize = 1;
        var column: usize = 1;
        for (self.marker.source[0..@min(self.index, self.marker.source.len)]) |byte| {
            if (byte == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }
        return .{ .line = line, .column = column, .offset = self.index };
    }

    fn fail(self: *Parser, err: ParseError, message: []const u8) ParseError {
        if (self.error_message == null) self.error_message = message;
        return err;
    }

    fn parseRoot(self: *Parser) ParseError!void {
        self.skipSpace();
        const expr = try self.parseOr();
        self.skipSpace();
        if (self.index != self.marker.source.len) {
            return self.fail(error.InvalidMarker, "unexpected trailing characters");
        }
        self.marker.root = expr;
    }

    fn skipSpace(self: *Parser) void {
        while (self.index < self.marker.source.len) {
            const byte = self.marker.source[self.index];
            if (byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r') {
                self.index += 1;
            } else return;
        }
    }

    fn peekByte(self: *const Parser) ?u8 {
        if (self.index >= self.marker.source.len) return null;
        return self.marker.source[self.index];
    }

    fn peekIdent(self: *Parser) ?[]const u8 {
        const start = self.index;
        while (self.index < self.marker.source.len) {
            const byte = self.marker.source[self.index];
            if (!isIdentChar(byte)) break;
            self.index += 1;
        }
        if (start == self.index) return null;
        return self.marker.source[start..self.index];
    }

    fn token(self: *Parser) ParseError!Token {
        self.skipSpace();
        const byte = self.peekByte() orelse return self.fail(error.InvalidMarker, "unexpected end of marker");
        switch (byte) {
            '(' => {
                self.index += 1;
                return .lparen;
            },
            ')' => {
                self.index += 1;
                return .rparen;
            },
            '[' => {
                self.index += 1;
                return .lbracket;
            },
            ']' => {
                self.index += 1;
                return .rbracket;
            },
            ',' => {
                self.index += 1;
                return .comma;
            },
            '=', '!' => {
                if (self.index + 1 < self.marker.source.len and self.marker.source[self.index + 1] == '=') {
                    self.index += 2;
                    return if (byte == '=') .op_eq else .op_ne;
                }
                return self.fail(error.InvalidMarker, "expected '=' after operator");
            },
            '<' => {
                self.index += 1;
                if (self.peekByte() == '=') {
                    self.index += 1;
                    return .op_lte;
                }
                return .op_lt;
            },
            '>' => {
                self.index += 1;
                if (self.peekByte() == '=') {
                    self.index += 1;
                    return .op_gte;
                }
                return .op_gt;
            },
            '"', '\'' => return .{ .string = try self.stringToken(byte) },
            else => {
                const ident = self.peekIdent() orelse return self.fail(error.InvalidMarker, "unexpected character");
                if (std.mem.eql(u8, ident, "and")) return .kw_and;
                if (std.mem.eql(u8, ident, "or")) return .kw_or;
                if (std.mem.eql(u8, ident, "not")) return .kw_not;
                if (std.mem.eql(u8, ident, "in")) return .kw_in;
                if (std.mem.eql(u8, ident, "true")) return .kw_true;
                if (std.mem.eql(u8, ident, "false")) return .kw_false;
                return .{ .ident = ident };
            },
        }
    }

    fn stringToken(self: *Parser, quote: u8) ParseError![]const u8 {
        self.index += 1;
        var output: std.ArrayList(u8) = .empty;
        const arena = self.marker.arena.allocator();
        while (self.peekByte()) |byte| {
            if (byte == quote) {
                self.index += 1;
                return output.toOwnedSlice(arena);
            }
            self.index += 1;
            if (quote == '\'' or byte != '\\') {
                try output.append(arena, byte);
                continue;
            }
            const escaped = self.peekByte() orelse return self.fail(error.InvalidMarker, "unterminated string");
            self.index += 1;
            switch (escaped) {
                'n' => try output.append(arena, '\n'),
                't' => try output.append(arena, '\t'),
                'r' => try output.append(arena, '\r'),
                '\\' => try output.append(arena, '\\'),
                '"' => try output.append(arena, '"'),
                '\'' => try output.append(arena, '\''),
                else => return self.fail(error.InvalidMarker, "invalid escape sequence"),
            }
        }
        return self.fail(error.InvalidMarker, "unterminated string");
    }

    fn lookaheadIs(self: *Parser, expected: std.meta.Tag(Token)) bool {
        const saved_index = self.index;
        const saved_message = self.error_message;
        defer {
            self.index = saved_index;
            self.error_message = saved_message;
        }
        const t = self.token() catch return false;
        return std.meta.activeTag(t) == expected;
    }

    fn parseOr(self: *Parser) ParseError!*const Expr {
        var left = try self.parseAnd();
        while (self.lookaheadIs(.kw_or)) {
            _ = try self.token();
            const right = try self.parseAnd();
            const node = try self.marker.arena.allocator().create(Expr);
            node.* = .{ .or_ = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!*const Expr {
        var left = try self.parseUnary();
        while (self.lookaheadIs(.kw_and)) {
            _ = try self.token();
            const right = try self.parseUnary();
            const node = try self.marker.arena.allocator().create(Expr);
            node.* = .{ .and_ = .{ .left = left, .right = right } };
            left = node;
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*const Expr {
        const saved = self.index;
        const t = try self.token();
        switch (t) {
            .kw_not => {
                const operand = try self.parseUnary();
                const node = try self.marker.arena.allocator().create(Expr);
                node.* = .{ .not = operand };
                return node;
            },
            .lparen => {
                const inner = try self.parseOr();
                const closing = try self.token();
                if (closing != .rparen) return self.fail(error.InvalidMarker, "expected ')'");
                return inner;
            },
            else => {
                self.index = saved;
                return self.parseComparisonOrOperand();
            },
        }
    }

    fn parseComparisonOrOperand(self: *Parser) ParseError!*const Expr {
        const left = try self.parseOperand();
        const before_op = self.index;
        const op = self.parseCmpOp() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidMarker => {
                self.index = before_op;
                const node = try self.marker.arena.allocator().create(Expr);
                node.* = .{ .operand = left };
                return node;
            },
        };
        const right = self.parseOperand() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.index = before_op;
                return self.fail(error.InvalidMarker, "expected operand after comparison operator");
            },
        };
        const node = try self.marker.arena.allocator().create(Expr);
        node.* = .{ .comparison = .{ .left = left, .op = op, .right = right } };
        return node;
    }

    fn parseCmpOp(self: *Parser) ParseError!CmpOp {
        const t = try self.token();
        return switch (t) {
            .op_eq => .eq,
            .op_ne => .ne,
            .op_lt => .lt,
            .op_lte => .lte,
            .op_gt => .gt,
            .op_gte => .gte,
            .kw_in => .in,
            .kw_not => blk: {
                const next = try self.token();
                if (next != .kw_in) return self.fail(error.InvalidMarker, "expected 'in' after 'not'");
                break :blk .not_in;
            },
            else => self.fail(error.InvalidMarker, "expected comparison operator"),
        };
    }

    fn parseOperand(self: *Parser) ParseError!Operand {
        const t = try self.token();
        switch (t) {
            .ident => |name| {
                if (fieldFromName(name)) |field| return .{ .field = field };
                return self.fail(error.InvalidMarker, "unknown field name");
            },
            .string => |text| return .{ .string = text },
            .kw_true => return .{ .boolean = true },
            .kw_false => return .{ .boolean = false },
            .lbracket => {
                var items: std.ArrayList(Operand) = .empty;
                const arena = self.marker.arena.allocator();
                self.skipSpace();
                if (self.peekByte() == ']') {
                    self.index += 1;
                    return .{ .list = &.{} };
                }
                while (true) {
                    const item = try self.parseOperand();
                    try items.append(arena, item);
                    const next = try self.token();
                    if (next == .rbracket) break;
                    if (next != .comma) return self.fail(error.InvalidMarker, "expected ',' or ']' in list");
                }
                return .{ .list = try items.toOwnedSlice(arena) };
            },
            else => return self.fail(error.InvalidMarker, "expected operand"),
        }
    }
};

fn isIdentChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn fieldFromName(name: []const u8) ?Field {
    if (std.mem.eql(u8, name, "os")) return .os;
    if (std.mem.eql(u8, name, "cpu")) return .cpu;
    if (std.mem.eql(u8, name, "abi")) return .abi;
    if (std.mem.eql(u8, name, "compat-js")) return .compat_js;
    if (std.mem.eql(u8, name, "optimize")) return .optimize;
    if (std.mem.eql(u8, name, "version")) return .version;
    if (std.mem.eql(u8, name, "features")) return .features;
    return null;
}

const Resolved = union(enum) {
    string: []const u8,
    boolean: bool,
    version: semver.Version,
    list: ListView,
};

/// リテラルリスト（`[...]`）または `features` フィールドの統一ビュー。
const ListView = union(enum) {
    operands: []const Operand,
    strings: []const []const u8,

    fn len(self: ListView) usize {
        return switch (self) {
            .operands => |items| items.len,
            .strings => |items| items.len,
        };
    }

    fn at(self: ListView, index: usize, context: Context) EvalError!Resolved {
        return switch (self) {
            .operands => |items| resolveOperand(items[index], context),
            .strings => |items| .{ .string = items[index] },
        };
    }
};

fn resolveOperand(operand: Operand, context: Context) EvalError!Resolved {
    return switch (operand) {
        .field => |field| switch (field) {
            .os => .{ .string = context.os },
            .cpu => .{ .string = context.cpu },
            .abi => .{ .string = context.abi },
            .compat_js => .{ .boolean = context.compat_js },
            .optimize => .{ .string = context.optimize },
            .version => if (context.version) |version| .{ .version = version } else error.TypeMismatch,
            .features => .{ .list = .{ .strings = context.features } },
        },
        .string => |text| .{ .string = text },
        .boolean => |boolean| .{ .boolean = boolean },
        .list => |items| .{ .list = .{ .operands = items } },
    };
}

fn evalExpr(expr: *const Expr, context: Context) EvalError!bool {
    return switch (expr.*) {
        .or_ => |pair| (try evalExpr(pair.left, context)) or (try evalExpr(pair.right, context)),
        .and_ => |pair| (try evalExpr(pair.left, context)) and (try evalExpr(pair.right, context)),
        .not => |operand| !(try evalExpr(operand, context)),
        .operand => |operand| blk: {
            const resolved = try resolveOperand(operand, context);
            break :blk switch (resolved) {
                .boolean => |boolean| boolean,
                else => error.TypeMismatch,
            };
        },
        .comparison => |comparison| try evalComparison(comparison, context),
    };
}

fn evalComparison(comparison: Comparison, context: Context) EvalError!bool {
    const left = try resolveOperand(comparison.left, context);
    const right = try resolveOperand(comparison.right, context);
    switch (comparison.op) {
        .in, .not_in => {
            const list = switch (right) {
                .list => |view| view,
                else => return error.TypeMismatch,
            };
            var found = false;
            for (0..list.len()) |i| {
                const item = try list.at(i, context);
                // `in` の要素比較は `==` と同じ意味論（SemVer 強制を含む）。
                // 比較不能な型同士は一致しないものとして扱う。
                const ord = compareResolved(left, item) catch continue;
                if (ord == .eq) {
                    found = true;
                    break;
                }
            }
            return if (comparison.op == .in) found else !found;
        },
        else => {},
    }
    const ord = try compareResolved(left, right);
    return switch (comparison.op) {
        .eq => ord == .eq,
        .ne => ord != .eq,
        .lt => ord == .lt,
        .lte => ord != .gt,
        .gt => ord == .gt,
        .gte => ord != .lt,
        else => unreachable,
    };
}

fn compareResolved(a: Resolved, b: Resolved) EvalError!std.math.Order {
    if (a == .version or b == .version) {
        const va = try coerceVersion(a);
        const vb = try coerceVersion(b);
        return va.order(vb);
    }
    if (a == .string and b == .string) {
        // SemVer として解釈できる場合はSemVer比較、それ以外は文字列比較。
        const va = semver.Version.parse(a.string) catch null;
        const vb = semver.Version.parse(b.string) catch null;
        if (va != null and vb != null) return va.?.order(vb.?);
        return std.mem.order(u8, a.string, b.string);
    }
    if (a == .boolean and b == .boolean) return std.math.order(@intFromBool(a.boolean), @intFromBool(b.boolean));
    return error.TypeMismatch;
}

fn coerceVersion(resolved: Resolved) EvalError!semver.Version {
    return switch (resolved) {
        .version => |version| version,
        .string => |text| semver.Version.parse(text) catch error.InvalidVersion,
        else => error.TypeMismatch,
    };
}

test "marker式を評価する" {
    const context = Context{
        .os = "linux",
        .cpu = "x86_64",
        .abi = "gnu",
        .compat_js = false,
        .optimize = "O2",
        .version = try semver.Version.parse("1.2.3"),
        .features = &.{ "native", "http" },
    };

    const cases = [_]struct { text: []const u8, expected: bool }{
        .{ .text = "os == \"linux\"", .expected = true },
        .{ .text = "os == \"windows\"", .expected = false },
        .{ .text = "os != \"windows\"", .expected = true },
        .{ .text = "cpu == \"x86_64\" and abi == \"gnu\"", .expected = true },
        .{ .text = "os == \"macos\" or cpu == \"x86_64\"", .expected = true },
        .{ .text = "not compat-js", .expected = true },
        .{ .text = "compat-js", .expected = false },
        .{ .text = "compat-js == false", .expected = true },
        .{ .text = "optimize >= \"O1\"", .expected = true },
        .{ .text = "version >= \"1.0.0\"", .expected = true },
        .{ .text = "version < \"1.0.0\"", .expected = false },
        .{ .text = "os in [\"linux\", \"windows\"]", .expected = true },
        .{ .text = "os not in [\"macos\"]", .expected = true },
        .{ .text = "\"native\" in features", .expected = true },
        .{ .text = "\"server\" in features", .expected = false },
        // `in` の要素比較は `==` と同じ意味論（SemVer 強制で build を無視）。
        .{ .text = "\"1.0.0+build\" == \"1.0.0\"", .expected = true },
        .{ .text = "\"1.0.0+build\" in [\"1.0.0\"]", .expected = true },
        .{ .text = "(os == \"linux\" and cpu == \"x86_64\") or compat-js", .expected = true },
        .{ .text = "not (os == \"linux\" or compat-js)", .expected = false },
    };
    for (cases) |case| {
        const result = try parse(std.testing.allocator, case.text);
        var marker = result.ok;
        defer marker.deinit();
        try std.testing.expectEqual(case.expected, try marker.evaluate(context));
    }
}

test "無効なmarker式を拒否する" {
    const bad = [_][]const u8{
        "os ==",
        "== \"linux\"",
        "os == \"linux\" and",
        "unknown-field == \"x\"",
        "os == ",
        "(os == \"linux\"",
        "os == \"linux\" extra",
    };
    for (bad) |text| {
        const result = try parse(std.testing.allocator, text);
        switch (result) {
            .ok => |*m| {
                var marker = m.*;
                defer marker.deinit();
                return error.TestUnexpectedResult;
            },
            .err => {},
        }
    }
}
