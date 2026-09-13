const std = @import("std");
const diagnostics = @import("diagnostics.zig");

pub const Position = diagnostics.Position;

/// TOML値の種別。日時は `datetime` に保持し、正規化は呼出し側に委ねる。
/// テーブルは unmanaged map。Document のアリーナがバッファを所有するため、
/// 参照側は allocator を保持せず Document 移動後も安全に読める。
pub const Kind = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: std.ArrayList(Value),
    table: std.StringHashMapUnmanaged(Value),
    datetime: []const u8,
};

/// `[a]` / `[[a]]` ヘッダまたはドットキーで定義済みのテーブル。
/// 再定義を検出するために使用する。
pub const flag_defined: u8 = 1;
/// インラインテーブル `{ ... }` とその内部テーブル。拡張できない。
pub const flag_inline: u8 = 2;
/// `[[a]]` ヘッダで作られた array of tables。`a = [ ... ]` の通常配列を
/// `[[a]]` で再定義できないことを検出するために使用する。
pub const flag_array_table: u8 = 4;

pub const Value = struct {
    kind: Kind,
    position: Position,
    flags: u8 = 0,

    pub fn asString(self: *const Value) ?[]const u8 {
        return switch (self.kind) {
            .string => |text| text,
            else => null,
        };
    }

    pub fn asTable(self: *const Value) ?*std.StringHashMapUnmanaged(Value) {
        return switch (self.kind) {
            .table => |*table| @constCast(table),
            else => null,
        };
    }

    pub fn asArray(self: *const Value) ?*std.ArrayList(Value) {
        return switch (self.kind) {
            .array => |*array| @constCast(array),
            else => null,
        };
    }
};

/// 構文エラー。`message` は静的な文字列リテラル。
pub const SyntaxError = struct {
    message: []const u8,
    position: Position,
};

/// TOMLドキュメント。`arena` がすべての文字列・コンテナを所有する。
/// `deinit` を呼ぶまで `root` 以下の `Value` は有効。
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: std.StringHashMapUnmanaged(Value),
    source: []const u8,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *Document) std.mem.Allocator {
        return self.arena.allocator();
    }
};

pub const Result = union(enum) {
    ok: Document,
    err: SyntaxError,
};

pub const Error = error{OutOfMemory};

/// TOMLを解析する。不正UTF-8と構文エラーは `Result.err` で返し、
/// その場合の内部メモリはすべて解放済み。
pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!Result {
    if (!std.unicode.utf8ValidateSlice(source)) {
        return .{ .err = .{ .message = "invalid UTF-8 input", .position = positionAt(source, utf8ErrorOffset(source)) } };
    }
    var document = Document{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .root = undefined,
        .source = undefined,
    };
    errdefer document.arena.deinit();
    const arena = document.arena.allocator();
    document.root = .empty;
    document.source = try arena.dupe(u8, source);

    var parser = Parser{
        .document = &document,
    };
    if (parser.parseDocument()) |_| {
        return .{ .ok = document };
    } else |err| switch (err) {
        // OOM は errdefer が arena を解放する。
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const position = parser.position();
            const message = parser.error_message orelse "invalid TOML";
            document.arena.deinit();
            return .{ .err = .{ .message = message, .position = position } };
        },
    }
}

/// 不正な UTF-8 シーケンスが始まるバイト位置を返す。
fn utf8ErrorOffset(source: []const u8) usize {
    var index: usize = 0;
    while (index < source.len) {
        const length = std.unicode.utf8ByteSequenceLength(source[index]) catch return index;
        if (index + length > source.len) return index;
        _ = std.unicode.utf8Decode(source[index .. index + length]) catch return index;
        index += length;
    }
    return source.len;
}

/// バイト offset を `line`/`column`（いずれもバイト単位）へ変換する。
fn positionAt(source: []const u8, offset: usize) Position {
    var position = Position{ .line = 1, .column = 1, .offset = offset };
    for (source[0..@min(offset, source.len)]) |byte| {
        if (byte == '\n') {
            position.line += 1;
            position.column = 1;
        } else {
            position.column += 1;
        }
    }
    return position;
}

const Terminator = enum { equal, bracket, double_bracket };

const ParseError = error{
    InvalidTomlDocument,
    InvalidTomlKey,
    InvalidTomlValue,
    InvalidTomlTable,
    InvalidTomlArray,
    InvalidTomlInlineTable,
    InvalidTomlEscape,
    InvalidTomlNumber,
    InvalidTomlInteger,
    UnterminatedTomlString,
    DuplicateTomlKey,
    OutOfMemory,
};

const Parser = struct {
    document: *Document,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,
    error_message: ?[]const u8 = null,

    fn position(self: *const Parser) Position {
        return .{ .line = self.line, .column = self.column, .offset = self.index };
    }

    fn peek(self: *const Parser) ?u8 {
        if (self.index >= self.document.source.len) return null;
        return self.document.source[self.index];
    }

    fn peekAt(self: *const Parser, offset: usize) ?u8 {
        const i = self.index + offset;
        if (i >= self.document.source.len) return null;
        return self.document.source[i];
    }

    fn advance(self: *Parser) void {
        if (self.index >= self.document.source.len) return;
        const byte = self.document.source[self.index];
        self.index += 1;
        if (byte == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
    }

    fn consume(self: *Parser, byte: u8) bool {
        if (self.peek() != byte) return false;
        self.advance();
        return true;
    }

    fn fail(self: *Parser, err: ParseError, message: []const u8) ParseError {
        if (self.error_message == null) self.error_message = message;
        return err;
    }

    fn parseDocument(self: *Parser) ParseError!void {
        var current: *std.StringHashMapUnmanaged(Value) = &self.document.root;
        while (true) {
            try self.skipDocumentSpace();
            if (self.peek() == null) break;
            if (self.peek() == '[') {
                const array_table = self.peekAt(1) == '[';
                self.advance();
                if (array_table) self.advance();
                const path = try self.keyPath(if (array_table) .double_bracket else .bracket);
                current = try self.resolveTable(path.items, array_table);
            } else {
                const path = try self.keyPath(.equal);
                const parsed_value = try self.parseValue();
                try self.assign(current, path.items, parsed_value, flag_defined);
            }
            self.skipHorizontal();
            if (self.peek() == '#') try self.skipComment();
            if (self.peek()) |byte| {
                if (byte == '\n') {
                    self.advance();
                } else if (byte == '\r') {
                    if (self.peekAt(1) != '\n') return self.fail(error.InvalidTomlDocument, "bare carriage return");
                    self.advance();
                    self.advance();
                } else {
                    return self.fail(error.InvalidTomlDocument, "unexpected content after statement");
                }
            }
        }
    }

    const KeyPath = std.ArrayList([]const u8);

    fn keyPath(self: *Parser, terminator: Terminator) ParseError!KeyPath {
        var result: KeyPath = .empty;
        while (true) {
            self.skipHorizontal();
            if (self.peek() == null) return self.fail(error.InvalidTomlKey, "empty key");
            const key = try self.keyPart();
            try result.append(self.document.arena.allocator(), key);
            self.skipHorizontal();
            if (self.peek() == '.') {
                self.advance();
                continue;
            }
            switch (terminator) {
                .equal => {
                    if (!self.consume('=')) return self.fail(error.InvalidTomlKey, "expected '=' after key");
                },
                .bracket => {
                    if (!self.consume(']')) return self.fail(error.InvalidTomlTable, "expected ']' after table name");
                },
                .double_bracket => {
                    if (!self.consume(']') or !self.consume(']')) return self.fail(error.InvalidTomlTable, "expected ']]' after array table name");
                },
            }
            if (result.items.len == 0) return self.fail(error.InvalidTomlKey, "empty key");
            return result;
        }
    }

    fn keyPart(self: *Parser) ParseError![]const u8 {
        const byte = self.peek().?;
        if (byte == '"' or byte == '\'') {
            return self.stringBytes(byte, false);
        }
        const start = self.index;
        while (self.peek()) |b| {
            if (!isBareKey(b)) break;
            self.advance();
        }
        if (start == self.index) return self.fail(error.InvalidTomlKey, "invalid key");
        return self.document.arena.allocator().dupe(u8, self.document.source[start..self.index]);
    }

    fn parseValue(self: *Parser) ParseError!Value {
        self.skipHorizontal();
        const pos = self.position();
        const byte = self.peek() orelse return self.fail(error.InvalidTomlValue, "missing value");
        const kind: Kind = switch (byte) {
            '"' => .{ .string = try self.stringValue('"') },
            '\'' => .{ .string = try self.stringValue('\'') },
            '[' => .{ .array = try self.parseArray() },
            '{' => .{ .table = try self.parseInlineTable() },
            else => try self.bareValue(),
        };
        return .{ .kind = kind, .position = pos, .flags = if (byte == '{') flag_inline else 0 };
    }

    fn stringValue(self: *Parser, quote: u8) ParseError![]const u8 {
        const multiline = self.peekAt(1) == quote and self.peekAt(2) == quote;
        return self.stringBytes(quote, multiline);
    }

    fn stringBytes(self: *Parser, quote: u8, multiline: bool) ParseError![]const u8 {
        self.index += if (multiline) 3 else 1;
        self.column += if (multiline) 3 else 1;
        if (multiline) {
            // 開始直後の改行は無視する。改行は LF または CRLF。
            if (self.peek() == '\r') {
                if (self.peekAt(1) != '\n') return self.fail(error.UnterminatedTomlString, "bare carriage return");
                self.advance();
                self.advance();
            } else {
                _ = self.consume('\n');
            }
        }
        var output: std.ArrayList(u8) = .empty;
        while (self.peek()) |byte| {
            if (byte == quote) {
                if (!multiline) {
                    self.advance();
                    return output.toOwnedSlice(self.document.arena.allocator());
                }
                // 連続するクォート数を数え、末尾1〜2個を内容として残せるようにする。
                var run: usize = 0;
                while (self.peekAt(run) == quote) run += 1;
                if (run >= 3) {
                    // 4〜5個なら超過分が内容のクォート。6個以上は内容中の `"""` で不正。
                    if (run > 5) return self.fail(error.UnterminatedTomlString, "too many consecutive quotes");
                    for (0..run - 3) |_| try output.append(self.document.arena.allocator(), quote);
                    self.index += run;
                    self.column += run;
                    return output.toOwnedSlice(self.document.arena.allocator());
                }
                self.advance();
                try output.append(self.document.arena.allocator(), byte);
                continue;
            }
            if (!multiline and (byte == '\n' or byte == '\r')) return self.fail(error.UnterminatedTomlString, "unterminated string");
            if (multiline and byte == '\r' and self.peekAt(1) != '\n') {
                return self.fail(error.UnterminatedTomlString, "bare carriage return");
            }
            // 制御文字（tab・複数行の改行を除く）はエスケープが必要。
            if ((byte < 0x20 and byte != '\t' and byte != '\n' and byte != '\r') or byte == 0x7f) {
                return self.fail(error.InvalidTomlValue, "control character in string");
            }
            self.advance();
            if (quote == '\'' or byte != '\\') {
                try output.append(self.document.arena.allocator(), byte);
                continue;
            }
            const escaped = self.peek() orelse return self.fail(error.UnterminatedTomlString, "unterminated escape");
            self.advance();
            switch (escaped) {
                'b' => try output.append(self.document.arena.allocator(), 0x08),
                't' => try output.append(self.document.arena.allocator(), '\t'),
                'n' => try output.append(self.document.arena.allocator(), '\n'),
                'f' => try output.append(self.document.arena.allocator(), 0x0c),
                'r' => try output.append(self.document.arena.allocator(), '\r'),
                '"' => try output.append(self.document.arena.allocator(), '"'),
                '\\' => try output.append(self.document.arena.allocator(), '\\'),
                'u' => try self.appendUnicode(&output, 4),
                'U' => try self.appendUnicode(&output, 8),
                '\n', '\r' => {
                    if (!multiline) return self.fail(error.InvalidTomlEscape, "line escape in single-line string");
                    if (escaped == '\r' and !self.consume('\n')) {
                        return self.fail(error.InvalidTomlEscape, "bare carriage return");
                    }
                    while (self.peek()) |b| {
                        if (b == ' ' or b == '\t' or b == '\n') {
                            self.advance();
                        } else if (b == '\r') {
                            if (self.peekAt(1) != '\n') return self.fail(error.InvalidTomlEscape, "bare carriage return");
                            self.advance();
                        } else break;
                    }
                },
                else => return self.fail(error.InvalidTomlEscape, "invalid escape sequence"),
            }
        }
        return self.fail(error.UnterminatedTomlString, "unterminated string");
    }

    fn appendUnicode(self: *Parser, output: *std.ArrayList(u8), digits: usize) ParseError!void {
        if (self.index + digits > self.document.source.len) return self.fail(error.InvalidTomlEscape, "truncated unicode escape");
        const codepoint = std.fmt.parseInt(u21, self.document.source[self.index .. self.index + digits], 16) catch
            return self.fail(error.InvalidTomlEscape, "invalid unicode escape");
        for (0..digits) |_| self.advance();
        if (!std.unicode.utf8ValidCodepoint(codepoint)) return self.fail(error.InvalidTomlEscape, "invalid unicode codepoint");
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &buffer) catch
            return self.fail(error.InvalidTomlEscape, "invalid unicode codepoint");
        try output.appendSlice(self.document.arena.allocator(), buffer[0..length]);
    }

    fn parseArray(self: *Parser) ParseError!std.ArrayList(Value) {
        self.advance(); // '['
        var result: std.ArrayList(Value) = .empty;
        try self.skipValueSpace();
        if (self.consume(']')) return result;
        while (true) {
            const item = try self.parseValue();
            try result.append(self.document.arena.allocator(), item);
            try self.skipValueSpace();
            if (self.consume(']')) return result;
            if (!self.consume(',')) return self.fail(error.InvalidTomlArray, "expected ',' or ']' in array");
            try self.skipValueSpace();
            if (self.consume(']')) return result;
        }
    }

    fn parseInlineTable(self: *Parser) ParseError!std.StringHashMapUnmanaged(Value) {
        self.advance(); // '{'
        var result: std.StringHashMapUnmanaged(Value) = .empty;
        self.skipHorizontal();
        if (self.consume('}')) return result;
        while (true) {
            const path = try self.keyPath(.equal);
            const item = try self.parseValue();
            try self.assign(&result, path.items, item, flag_defined);
            self.skipHorizontal();
            if (self.consume('}')) return result;
            if (!self.consume(',')) return self.fail(error.InvalidTomlInlineTable, "expected ',' or '}' in inline table");
            self.skipHorizontal();
        }
    }

    fn bareValue(self: *Parser) ParseError!Kind {
        const start = self.index;
        while (self.peek()) |byte| {
            // `1979-05-27 07:32` のようなローカル日時の空白を読み飛ばす。
            if (byte == ' ' and self.index == start + 10 and hasDatePrefix(self.document.source[start..]) and
                self.peekAt(1) != null and std.ascii.isDigit(self.peekAt(1).?))
            {
                self.advance();
                continue;
            }
            if (byte == ',' or byte == ']' or byte == '}' or byte == '#' or byte == '\n' or byte == '\r' or byte == ' ' or byte == '\t') break;
            self.advance();
        }
        if (start == self.index) return self.fail(error.InvalidTomlValue, "empty value");
        const token = self.document.source[start..self.index];
        if (std.mem.eql(u8, token, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, token, "false")) return .{ .boolean = false };
        if (std.mem.eql(u8, token, "inf") or std.mem.eql(u8, token, "+inf")) return .{ .float = std.math.inf(f64) };
        if (std.mem.eql(u8, token, "-inf")) return .{ .float = -std.math.inf(f64) };
        if (std.mem.eql(u8, token, "nan") or std.mem.eql(u8, token, "+nan") or std.mem.eql(u8, token, "-nan")) return .{ .float = std.math.nan(f64) };
        if (looksLikeTemporal(token)) {
            if (!validTemporal(token)) return self.fail(error.InvalidTomlValue, "invalid datetime");
            return .{ .datetime = try self.document.arena.allocator().dupe(u8, token) };
        }
        // 整数と浮動小数を先に分類し、整数として不正な表記が float に救済されないようにする。
        switch (classifyNumber(token)) {
            .integer => {
                const integer = parseInteger(self.document.arena.allocator(), token) catch
                    return self.fail(error.InvalidTomlInteger, "invalid integer");
                return .{ .integer = integer };
            },
            .float => {
                const number = parseFloat(self.document.arena.allocator(), token) catch
                    return self.fail(error.InvalidTomlNumber, "invalid number");
                return .{ .float = number };
            },
            .invalid => return self.fail(error.InvalidTomlNumber, "invalid number"),
        }
    }

    fn resolveTable(self: *Parser, path: []const []const u8, array_table: bool) ParseError!*std.StringHashMapUnmanaged(Value) {
        const arena = self.document.arena.allocator();
        var current = &self.document.root;
        for (path, 0..) |segment, i| {
            const last = i + 1 == path.len;
            const gop = try current.getOrPut(arena, segment);
            if (last and array_table) {
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .kind = .{ .array = .empty }, .position = self.position(), .flags = flag_array_table };
                } else if (gop.value_ptr.kind != .array or gop.value_ptr.flags & flag_array_table == 0) {
                    // `a = [1]` 等の通常配列は `[[a]]` で再定義できない。
                    return self.fail(error.InvalidTomlTable, "array table conflicts with existing non-array-table value");
                }
                try gop.value_ptr.kind.array.append(arena, .{
                    .kind = .{ .table = .empty },
                    .position = self.position(),
                });
                return &gop.value_ptr.kind.array.items[gop.value_ptr.kind.array.items.len - 1].kind.table;
            }
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .kind = .{ .table = .empty },
                    .position = self.position(),
                    .flags = if (last) flag_defined else 0,
                };
                current = &gop.value_ptr.kind.table;
                continue;
            }
            if (gop.value_ptr.flags & flag_inline != 0) {
                return self.fail(error.InvalidTomlTable, "cannot extend inline table");
            }
            switch (gop.value_ptr.kind) {
                .table => |*table| {
                    if (last) {
                        if (gop.value_ptr.flags & flag_defined != 0) {
                            return self.fail(error.InvalidTomlTable, "table already defined");
                        }
                        gop.value_ptr.flags |= flag_defined;
                    }
                    current = table;
                },
                .array => |*array| {
                    if (last) return self.fail(error.InvalidTomlTable, "table conflicts with existing array");
                    if (array.items.len == 0) return self.fail(error.InvalidTomlTable, "cannot extend empty array as table");
                    const last_item = &array.items[array.items.len - 1];
                    if (last_item.flags & flag_inline != 0) return self.fail(error.InvalidTomlTable, "cannot extend inline table");
                    if (last_item.kind != .table) return self.fail(error.InvalidTomlTable, "cannot extend non-table array item");
                    current = &last_item.kind.table;
                },
                else => return self.fail(error.InvalidTomlTable, "table conflicts with existing value"),
            }
        }
        return current;
    }

    fn assign(self: *Parser, base: *std.StringHashMapUnmanaged(Value), path: []const []const u8, assigned: Value, mark: u8) ParseError!void {
        if (path.len == 0) return self.fail(error.InvalidTomlKey, "empty key path");
        const arena = self.document.arena.allocator();
        var current = base;
        for (path[0 .. path.len - 1]) |segment| {
            const gop = try current.getOrPut(arena, segment);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .kind = .{ .table = .empty },
                    .position = self.position(),
                    .flags = mark,
                };
            } else if (gop.value_ptr.kind != .table) {
                return self.fail(error.InvalidTomlKey, "key conflicts with existing value");
            } else if (gop.value_ptr.flags & flag_inline != 0) {
                return self.fail(error.InvalidTomlKey, "cannot extend inline table");
            }
            current = &gop.value_ptr.kind.table;
        }
        const last = path[path.len - 1];
        const gop = try current.getOrPut(arena, last);
        if (gop.found_existing) return self.fail(error.DuplicateTomlKey, "duplicate key");
        gop.value_ptr.* = assigned;
    }

    fn skipDocumentSpace(self: *Parser) ParseError!void {
        while (self.peek()) |byte| {
            switch (byte) {
                ' ', '\t', '\n' => self.advance(),
                '\r' => {
                    if (self.peekAt(1) != '\n') return self.fail(error.InvalidTomlDocument, "bare carriage return");
                    self.advance();
                    self.advance();
                },
                '#' => try self.skipComment(),
                else => return,
            }
        }
    }

    fn skipValueSpace(self: *Parser) ParseError!void {
        while (self.peek()) |byte| {
            switch (byte) {
                ' ', '\t', '\n' => self.advance(),
                '\r' => {
                    if (self.peekAt(1) != '\n') return self.fail(error.InvalidTomlArray, "bare carriage return");
                    self.advance();
                    self.advance();
                },
                '#' => try self.skipComment(),
                else => return,
            }
        }
    }

    fn skipHorizontal(self: *Parser) void {
        while (self.peek()) |byte| {
            if (byte == ' ' or byte == '\t') {
                self.advance();
            } else return;
        }
    }

    fn skipComment(self: *Parser) ParseError!void {
        while (self.peek()) |byte| {
            // `\r` は呼出し側が `\r\n` 対として検証するためここで止める。
            if (byte == '\n' or byte == '\r') return;
            if ((byte < 0x20 and byte != '\t') or byte == 0x7f) {
                return self.fail(error.InvalidTomlDocument, "control character in comment");
            }
            self.advance();
        }
    }
};

fn daysOfMonth(year: u32, month: u32) u32 {
    const days = [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) return 29;
    return days[month - 1];
}

/// `HH:MM:SS[.frac]` を検証する。`allow_offset` が真なら末尾の
/// `Z`/`z`/`±HH:MM` オフセットも受理する（日付なしの local time には付けられない）。
fn validTimeWithOffset(text: []const u8, allow_offset: bool) bool {
    if (text.len < 8) return false;
    if (!std.ascii.isDigit(text[0]) or !std.ascii.isDigit(text[1]) or text[2] != ':' or
        !std.ascii.isDigit(text[3]) or !std.ascii.isDigit(text[4]) or text[5] != ':' or
        !std.ascii.isDigit(text[6]) or !std.ascii.isDigit(text[7])) return false;
    const hour = std.fmt.parseInt(u32, text[0..2], 10) catch return false;
    const minute = std.fmt.parseInt(u32, text[3..5], 10) catch return false;
    const second = std.fmt.parseInt(u32, text[6..8], 10) catch return false;
    if (hour > 23 or minute > 59 or second > 59) return false;
    var i: usize = 8;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == start) return false;
    }
    if (i == text.len) return true;
    if (!allow_offset) return false;
    const byte = text[i];
    if (byte == 'Z' or byte == 'z') return i + 1 == text.len;
    if (byte != '+' and byte != '-') return false;
    const offset = text[i + 1 ..];
    if (offset.len != 5) return false;
    if (!std.ascii.isDigit(offset[0]) or !std.ascii.isDigit(offset[1]) or offset[2] != ':' or
        !std.ascii.isDigit(offset[3]) or !std.ascii.isDigit(offset[4])) return false;
    const oh = std.fmt.parseInt(u32, offset[0..2], 10) catch return false;
    const om = std.fmt.parseInt(u32, offset[3..5], 10) catch return false;
    return oh <= 23 and om <= 59;
}

/// RFC 3339 ベースの日時構造を簡易検証する。local date / local time /
/// local date-time / offset date-time を受理する。
fn validTemporal(token: []const u8) bool {
    if (token.len >= 10 and token[4] == '-' and token[7] == '-') {
        const year = std.fmt.parseInt(u32, token[0..4], 10) catch return false;
        const month = std.fmt.parseInt(u32, token[5..7], 10) catch return false;
        const day = std.fmt.parseInt(u32, token[8..10], 10) catch return false;
        if (month < 1 or month > 12 or day < 1 or day > daysOfMonth(year, month)) return false;
        if (token.len == 10) return true; // local date
        const sep = token[10];
        if (sep != 'T' and sep != 't' and sep != ' ') return false;
        return validTimeWithOffset(token[11..], true);
    }
    return validTimeWithOffset(token, false);
}

fn isBareKey(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

fn hasDatePrefix(token: []const u8) bool {
    return token.len >= 10 and std.ascii.isDigit(token[0]) and std.ascii.isDigit(token[1]) and
        std.ascii.isDigit(token[2]) and std.ascii.isDigit(token[3]) and token[4] == '-' and
        std.ascii.isDigit(token[5]) and std.ascii.isDigit(token[6]) and token[7] == '-' and
        std.ascii.isDigit(token[8]) and std.ascii.isDigit(token[9]);
}

fn looksLikeTemporal(token: []const u8) bool {
    if (token.len < 5 or !std.ascii.isDigit(token[0])) return false;
    return std.mem.indexOfScalar(u8, token, ':') != null or hasDatePrefix(token);
}

const NumberKind = enum { integer, float, invalid };

/// トークンを整数・浮動小数・不正に分類する。`0x`/`0o`/`0b` 前置は常に整数で、
/// `.`/`e`/`E` を含むものは浮動小数、それ以外の数字列は整数とみなす。
fn classifyNumber(token: []const u8) NumberKind {
    var rest = token;
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) rest = rest[1..];
    if (rest.len == 0) return .invalid;
    if (rest.len > 2 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'o' or rest[1] == 'b')) {
        // 16/8/2進に符号は付けられない。
        if (rest.len != token.len) return .invalid;
        return .integer;
    }
    for (rest) |byte| {
        if (byte == '.' or byte == 'e' or byte == 'E') return .float;
    }
    for (rest) |byte| {
        if (!(std.ascii.isDigit(byte) or byte == '_')) return .invalid;
    }
    return .integer;
}

fn isDigitForRadix(byte: u8, radix: u8) bool {
    return switch (radix) {
        16 => std.ascii.isHex(byte),
        8 => byte >= '0' and byte <= '7',
        2 => byte == '0' or byte == '1',
        else => std.ascii.isDigit(byte),
    };
}

/// `_` は両側が対象基数の数字でなければならない。
fn validUnderscores(text: []const u8, radix: u8) bool {
    for (text, 0..) |byte, index| {
        if (byte != '_') continue;
        if (index == 0 or index + 1 == text.len) return false;
        if (!isDigitForRadix(text[index - 1], radix) or !isDigitForRadix(text[index + 1], radix)) return false;
    }
    return true;
}

fn stripUnderscores(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '_') == null) return text;
    var output = try std.ArrayList(u8).initCapacity(allocator, text.len);
    errdefer output.deinit(allocator);
    for (text) |byte| {
        if (byte != '_') output.appendAssumeCapacity(byte);
    }
    return output.toOwnedSlice(allocator);
}

fn parseInteger(allocator: std.mem.Allocator, token: []const u8) ParseError!i64 {
    var sign: i128 = 1;
    var digits = token;
    if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) {
        if (digits[0] == '-') sign = -1;
        digits = digits[1..];
    }
    var radix: u8 = 10;
    if (digits.len > 2 and digits[0] == '0') switch (digits[1]) {
        'x' => radix = 16,
        'o' => radix = 8,
        'b' => radix = 2,
        else => {},
    };
    if (radix != 10 and sign != 1) return error.InvalidTomlInteger;
    if (radix != 10) digits = digits[2..];
    if (digits.len == 0) return error.InvalidTomlInteger;
    if (!validUnderscores(digits, radix)) return error.InvalidTomlInteger;
    const clean = try stripUnderscores(allocator, digits);
    if (clean.len == 0 or (radix == 10 and clean.len > 1 and clean[0] == '0')) return error.InvalidTomlInteger;
    const magnitude = std.fmt.parseInt(u64, clean, radix) catch return error.InvalidTomlInteger;
    const signed = @as(i128, @intCast(magnitude)) * sign;
    if (signed < std.math.minInt(i64) or signed > std.math.maxInt(i64)) return error.InvalidTomlInteger;
    return @intCast(signed);
}

/// TOML float 構文（`int [.int] [(e|E)[+-]int]`、int 部の先頭ゼロ不可）を検査して解析する。
fn parseFloat(allocator: std.mem.Allocator, token: []const u8) ParseError!f64 {
    var rest = token;
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) rest = rest[1..];
    if (!validUnderscores(rest, 10)) return error.InvalidTomlNumber;
    const clean = try stripUnderscores(allocator, rest);
    if (!validFloatText(clean)) return error.InvalidTomlNumber;
    // 符号を戻して parseFloat する。
    if (rest.len == token.len) return std.fmt.parseFloat(f64, clean) catch error.InvalidTomlNumber;
    const signed = try std.fmt.allocPrint(allocator, "{c}{s}", .{ token[0], clean });
    return std.fmt.parseFloat(f64, signed) catch error.InvalidTomlNumber;
}

/// アンダースコア除去済み・符号なしの float 表記を検査する。
fn validFloatText(text: []const u8) bool {
    var i: usize = 0;
    const int_start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    if (i == int_start) return false;
    if (i - int_start > 1 and text[int_start] == '0') return false;
    if (i < text.len and text[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == frac_start) return false;
    }
    if (i < text.len and (text[i] == 'e' or text[i] == 'E')) {
        i += 1;
        if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
        const exp_start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == exp_start) return false;
    }
    return i == text.len;
}

test "最小限のTOMLを解析する" {
    const source =
        \\title = "x"
        \\n = 1_000
        \\f = 1.5
        \\b = true
        \\a = [1, 2]
        \\o = { x = 1 }
        \\[server]
        \\port = 8080
        \\
    ;
    const result = try parse(std.testing.allocator, source);
    var doc = result.ok;
    defer doc.deinit();

    const root = &doc.root;
    try std.testing.expectEqualStrings("x", root.get("title").?.kind.string);
    try std.testing.expectEqual(@as(i64, 1000), root.get("n").?.kind.integer);
    try std.testing.expectEqual(@as(f64, 1.5), root.get("f").?.kind.float);
    try std.testing.expectEqual(true, root.get("b").?.kind.boolean);
    try std.testing.expectEqual(@as(usize, 2), root.get("a").?.kind.array.items.len);
    try std.testing.expectEqual(@as(i64, 1), root.get("o").?.kind.table.get("x").?.kind.integer);
    const server = root.get("server").?.kind.table;
    try std.testing.expectEqual(@as(i64, 8080), server.get("port").?.kind.integer);
}

test "配列の表とドットキーを解析する" {
    const source =
        \\[[exports]]
        \\name = "a"
        \\[[exports]]
        \\name = "b"
        \\[dependencies.pkg]
        \\req = { version = "^1" }
        \\
    ;
    const result = try parse(std.testing.allocator, source);
    var doc = result.ok;
    defer doc.deinit();

    const exports = doc.root.get("exports").?.kind.array;
    try std.testing.expectEqual(@as(usize, 2), exports.items.len);
    try std.testing.expectEqualStrings("a", exports.items[0].kind.table.get("name").?.kind.string);
    try std.testing.expectEqualStrings("b", exports.items[1].kind.table.get("name").?.kind.string);
    const dependencies = doc.root.get("dependencies").?.kind.table;
    const pkg = dependencies.get("pkg").?.kind.table;
    const req = pkg.get("req").?.kind.table;
    try std.testing.expectEqualStrings("^1", req.get("version").?.kind.string);
}

test "位置情報を記録する" {
    const result = try parse(std.testing.allocator, "title = \"x\"\n[package]\nname = \"a\"\n");
    var doc = result.ok;
    defer doc.deinit();
    const pkg = doc.root.get("package").?.kind.table;
    const name = pkg.get("name").?;
    try std.testing.expectEqual(@as(usize, 3), name.position.line);
    try std.testing.expect(name.position.column > 1);
}

test "重複キーを検出する" {
    const result = try parse(std.testing.allocator, "a = 1\na = 2\n");
    switch (result) {
        .ok => |*doc| {
            var d = doc.*;
            defer d.deinit();
            return error.TestUnexpectedResult;
        },
        .err => |err| {
            try std.testing.expect(std.mem.indexOf(u8, err.message, "duplicate") != null);
            try std.testing.expectEqual(@as(usize, 2), err.position.line);
        },
    }
}

test "無効なUTF-8を拒否する" {
    const result = try parse(std.testing.allocator, "a = \"\xff\"\n");
    switch (result) {
        .ok => |*doc| {
            var d = doc.*;
            defer d.deinit();
            return error.TestUnexpectedResult;
        },
        .err => |err| {
            try std.testing.expect(std.mem.indexOf(u8, err.message, "UTF-8") != null);
            try std.testing.expect(err.position.offset > 0);
        },
    }
}

fn expectSyntaxError(source: []const u8) !void {
    const result = try parse(std.testing.allocator, source);
    switch (result) {
        .ok => |*doc| {
            var d = doc.*;
            defer d.deinit();
            return error.TestUnexpectedResult;
        },
        .err => {},
    }
}

test "array of tablesの再定義規則" {
    // 通常配列は [[a]] で再定義できない。
    try expectSyntaxError("a = [1]\n[[a]]\n");
    try expectSyntaxError("a = []\n[[a]]\n");
    try expectSyntaxError("a = [{b = 1}]\n[[a]]\n");
    // リテラル配列内のインラインテーブルは拡張できない。
    try expectSyntaxError("a = [{b = 1}]\n[a.b]\n");
    // [[a]] で作った配列には追加できる。
    const result = try parse(std.testing.allocator, "[[a]]\nx = 1\n[[a]]\nx = 2\n[a.b]\ny = 3\n");
    var doc = result.ok;
    defer doc.deinit();
    const a = doc.root.get("a").?.kind.array;
    try std.testing.expectEqual(@as(usize, 2), a.items.len);
    try std.testing.expectEqual(@as(i64, 3), a.items[1].kind.table.get("b").?.kind.table.get("y").?.kind.integer);
}

test "整数と浮動小数の厳密な検証" {
    const ok_cases = [_]struct { source: []const u8, integer: i64 }{
        .{ .source = "a = -9223372036854775808\n", .integer = std.math.minInt(i64) },
        .{ .source = "a = 9223372036854775807\n", .integer = std.math.maxInt(i64) },
        .{ .source = "a = 0xdead_beef\n", .integer = 0xdead_beef },
        .{ .source = "a = 1_000\n", .integer = 1000 },
    };
    for (ok_cases) |case| {
        const result = try parse(std.testing.allocator, case.source);
        var doc = result.ok;
        defer doc.deinit();
        try std.testing.expectEqual(case.integer, doc.root.get("a").?.kind.integer);
    }
    const bad = [_][]const u8{
        "a = 01\n", // 先頭ゼロ
        "a = 9223372036854775808\n", // i64 範囲外は float に救済されない
        "a = -0x10\n", // 非10進に符号は付けられない
        "a = +0o7\n",
        "a = 0x_1\n", // `_` の両側は対象基数の数字のみ
        "a = 0x_DEAD\n",
        "a = 1__2\n",
        "a = 1.\n",
        "a = .5\n",
        "a = 1.e5\n",
        "a = 1e\n",
        "a = 01.5\n",
    };
    for (bad) |source| {
        try expectSyntaxError(source);
    }
}

test "複数行文字列は末尾1〜2個のクォートを内容に含められる" {
    const result = try parse(std.testing.allocator, "a = \"\"\"x\"\"\"\"\nb = \"\"\"y\"\"\"\"\"\n");
    var doc = result.ok;
    defer doc.deinit();
    try std.testing.expectEqualStrings("x\"", doc.root.get("a").?.kind.string);
    try std.testing.expectEqualStrings("y\"\"", doc.root.get("b").?.kind.string);
    // 内容中の3連続クォートは不正。
    try expectSyntaxError("a = \"\"\"x\"\"\"y\"\"\"\n");
}

test "孤立したCRは改行として受理しない" {
    try expectSyntaxError("a = 1\rb = 2\n");
    try expectSyntaxError("a = \"x\ry\"\n");
    const result = try parse(std.testing.allocator, "a = 1\r\nb = 2\r\n");
    var doc = result.ok;
    defer doc.deinit();
    try std.testing.expectEqual(@as(i64, 2), doc.root.get("b").?.kind.integer);
}

test "日時は構造を検証する" {
    const ok_cases = [_][]const u8{
        "a = 1979-05-27\n",
        "a = 07:32:00\n",
        "a = 1979-05-27T07:32:00Z\n",
        "a = 1979-05-27 07:32:00\n",
        "a = 1979-05-27T07:32:00.999+09:00\n",
        "a = 2000-02-29\n",
    };
    for (ok_cases) |source| {
        const result = try parse(std.testing.allocator, source);
        var doc = result.ok;
        defer doc.deinit();
        try std.testing.expect(doc.root.get("a").?.kind == .datetime);
    }
    const bad = [_][]const u8{
        "a = 1979-13-45\n", // 月日の範囲外
        "a = 12:34\n", // 秒が必須
        "a = 1979-05-27T\n", // 時刻がない
        "a = 07:32:00Z\n", // local time にオフセットは付けられない
        "a = 1979-05-27T24:00:00\n", // 時の範囲外
        "a = 1900-02-29\n", // うるう年でない2/29
    };
    for (bad) |source| {
        try expectSyntaxError(source);
    }
}

test "文字列とコメントの制御文字を拒否する" {
    try expectSyntaxError("a = \"x\x01y\"\n");
    try expectSyntaxError("a = \"x\x7fy\"\n");
    try expectSyntaxError("a = 'x\x01y'\n");
    try expectSyntaxError("a = 1 # comment\x01\n");
    // tab は文字列・コメントともに許容する。
    const result = try parse(std.testing.allocator, "a = \"x\ty\" # c\td\n");
    var doc = result.ok;
    defer doc.deinit();
    try std.testing.expectEqualStrings("x\ty", doc.root.get("a").?.kind.string);
    // エスケープ済み制御文字は受理する。
    const escaped = try parse(std.testing.allocator, "a = \"x\\u0001y\"\n");
    var doc2 = escaped.ok;
    defer doc2.deinit();
    try std.testing.expectEqualStrings("x\x01y", doc2.root.get("a").?.kind.string);
}
