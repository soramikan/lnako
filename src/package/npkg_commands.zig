//! `NAKO-PKG/commands.json` のモデル・シリアライズ・解析。
//!
//! commands.json は `.npkg` が提供する公開命令の静的索引であり、AST のみから
//! 生成される（初期化コードは実行しない）。公開トップレベル関数は
//! `{ name, args, josi }`、公開変数は `{ name, variable: true }` を持つ。
//! `fn`/`async`/`return` は静的に決定できないため生成側では省略する。
//! これらは将来拡張用の予約フィールドとして受理側では許容するが、v1 では
//! 値を解釈せずモデルへも保持しない（SPECIFICATION §6.4）。
//!
//! 形式は `docs/package-system/SPECIFICATION.md` §6.4、
//! `tools/package-system/schema/commands.schema.json` に対応する。

const std = @import("std");
const diag = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;

/// commands.json の schema version。`SCHEMA_VERSIONS.md` §7 と対応する。
pub const schema_version: u32 = 1;

/// commands.json の1項目。文字列スライスは構築側または `arena` が所有する。
pub const Command = struct {
    name: []const u8,
    /// 関数の引数名。変数 (`variable`) では空。
    args: []const []const u8 = &.{},
    /// 引数と対応する助詞。`args` と同数または空。
    josi: []const []const u8 = &.{},
    variable: bool = false,
};

fn commandLessThan(_: void, a: Command, b: Command) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try std.json.Stringify.value(text, .{}, writer);
}

fn writeJsonStringArray(writer: *std.Io.Writer, items: []const []const u8) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        try writeJsonString(writer, item);
    }
    try writer.writeByte(']');
}

/// commands.json を決定的に書き出す。`commands` は名前順にソート写を取る。
/// 同一入力からは常に同一バイト列になる。
pub fn emit(allocator: Allocator, commands: []const Command, writer: *std.Io.Writer) !void {
    const sorted = try allocator.dupe(Command, commands);
    defer allocator.free(sorted);
    std.mem.sort(Command, sorted, {}, commandLessThan);

    try writer.writeAll("{\"schemaVersion\":1,\"commands\":[");
    for (sorted, 0..) |command, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, command.name);
        if (command.variable) {
            try writer.writeAll(",\"variable\":true}");
            continue;
        }
        try writer.writeAll(",\"args\":");
        try writeJsonStringArray(writer, command.args);
        try writer.writeAll(",\"josi\":");
        try writeJsonStringArray(writer, command.josi);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}\n");
}

/// `commands` 配列（commands.json と environment.json の snapshot が同じ形式）の
/// 写し。`complete` は全要素が v1 の形に適合したか。不正要素は飛ばすが、
/// 呼出し側が「完全な索引」と誤認しないよう false を返す。
pub const ParsedList = struct {
    commands: []const Command = &.{},
    complete: bool = true,
};

/// `commands` 配列をモデルへ写す。文字列と配列は `arena` が所有する。
/// 名前を持たない要素・型違いの要素は飛ばして `complete=false` にする
/// （環境 snapshot は改竄・破損し得る入力だが、その存在を未検査として扱う）。
pub fn parseList(arena: Allocator, value: ?std.json.Value) error{OutOfMemory}!ParsedList {
    // `commands` フィールド自体が無い環境は索引未記録（未検査）として扱う。
    const commands_value = value orelse return .{ .complete = false };
    if (commands_value != .array) return .{ .complete = false };
    var list: std.ArrayList(Command) = .empty;
    var complete = true;
    for (commands_value.array.items) |item| {
        if (item != .object) {
            complete = false;
            continue;
        }
        const name_value = item.object.get("name") orelse {
            complete = false;
            continue;
        };
        if (name_value != .string) {
            complete = false;
            continue;
        }
        var command = Command{ .name = try arena.dupe(u8, name_value.string) };
        if (item.object.get("variable")) |variable| {
            if (variable == .bool) {
                command.variable = variable.bool;
            } else complete = false;
        }
        if (item.object.get("args")) |args| {
            if (args == .array) {
                const slice = try arena.alloc([]const u8, args.array.items.len);
                for (args.array.items, 0..) |arg, index| {
                    if (arg == .string) {
                        slice[index] = try arena.dupe(u8, arg.string);
                    } else {
                        slice[index] = "";
                        complete = false;
                    }
                }
                command.args = slice;
            } else complete = false;
        }
        if (item.object.get("josi")) |josi| {
            if (josi == .array) {
                const slice = try arena.alloc([]const u8, josi.array.items.len);
                for (josi.array.items, 0..) |arg, index| {
                    if (arg == .string) {
                        slice[index] = try arena.dupe(u8, arg.string);
                    } else {
                        slice[index] = "";
                        complete = false;
                    }
                }
                command.josi = slice;
            } else complete = false;
        }
        if (command.variable and (command.args.len != 0 or command.josi.len != 0)) complete = false;
        // 関数は args と同数の josi を持つ（助詞なし引数は空文字列で表す）。
        // args のみで josi を欠く索引はスロットを構成できないため、検査済み
        // として扱わない（semantic 側の助詞検査を誤動作させない）。
        if (!command.variable and command.josi.len != command.args.len) complete = false;
        try list.append(arena, command);
    }
    if (list.items.len == 0) return .{ .complete = complete };
    return .{ .commands = try list.toOwnedSlice(arena), .complete = complete };
}

/// `commands` の深い写し。文字列と配列は `arena` が所有する。
pub fn cloneList(arena: Allocator, commands: []const Command) error{OutOfMemory}![]Command {
    if (commands.len == 0) return &.{};
    const out = try arena.alloc(Command, commands.len);
    for (commands, 0..) |command, index| {
        out[index] = .{
            .name = try arena.dupe(u8, command.name),
            .variable = command.variable,
            .args = try cloneStringList(arena, command.args),
            .josi = try cloneStringList(arena, command.josi),
        };
    }
    return out;
}

fn cloneStringList(arena: Allocator, items: []const []const u8) error{OutOfMemory}![]const []const u8 {
    if (items.len == 0) return &.{};
    const out = try arena.alloc([]const u8, items.len);
    for (items, 0..) |item, index| out[index] = try arena.dupe(u8, item);
    return out;
}

/// 解析済み commands.json。全メモリは内蔵 arena が所有する。
pub const Commands = struct {
    arena: std.heap.ArenaAllocator,
    commands: []Command,

    pub fn deinit(self: *Commands) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParseError = error{ OutOfMemory, InvalidJson, InvalidCommands };

const Parser = struct {
    arena: Allocator,
    diagnostics: *diag.List,

    fn report(self: *Parser, code: []const u8, path: []const u8, comptime format: []const u8, args: anytype) !void {
        try self.diagnostics.addFmt(code, .err, path, .{}, format, args);
    }

    fn asObject(self: *Parser, value: std.json.Value, path: []const u8) !?std.json.ObjectMap {
        return switch (value) {
            .object => |object| object,
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected object", .{});
                break :blk null;
            },
        };
    }

    fn asArray(self: *Parser, value: std.json.Value, path: []const u8) !?std.json.Array {
        return switch (value) {
            .array => |array| array,
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected array", .{});
                break :blk null;
            },
        };
    }

    /// 文字列は `parsed` の arena が所有するため `self.arena` へ複製する。
    fn asString(self: *Parser, value: std.json.Value, path: []const u8) !?[]const u8 {
        return switch (value) {
            .string => |text| try self.arena.dupe(u8, text),
            else => blk: {
                try self.report(diag.E023_INVALID_TYPE, path, "expected string", .{});
                break :blk null;
            },
        };
    }

    fn stringList(self: *Parser, value: std.json.Value, path: []const u8) !?[]const []const u8 {
        const array = (try self.asArray(value, path)) orelse return null;
        var items: std.ArrayList([]const u8) = .empty;
        for (array.items) |item| {
            const text = (try self.asString(item, path)) orelse continue;
            try items.append(self.arena, text);
        }
        return items.items;
    }

    fn rejectUnknown(self: *Parser, object: std.json.ObjectMap, allowed: []const []const u8, path: []const u8) !void {
        var iterator = object.iterator();
        while (iterator.next()) |entry| {
            var found = false;
            for (allowed) |name| {
                if (std.mem.eql(u8, entry.key_ptr.*, name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const field_path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, entry.key_ptr.* });
                try self.report(diag.E022_UNKNOWN_FIELD, field_path, "unknown field \"{s}\"", .{entry.key_ptr.*});
            }
        }
    }

    fn validateCommand(self: *Parser, value: std.json.Value, index: usize) !?Command {
        const path = try std.fmt.allocPrint(self.arena, "commands[{d}]", .{index});
        const object = (try self.asObject(value, path)) orelse return null;
        try self.rejectUnknown(object, &.{ "name", "args", "josi", "variable", "fn", "async", "return" }, path);

        const name_value = object.get("name") orelse {
            try self.report(diag.E019_REQUIRED_FIELD_MISSING, path, "missing required field \"name\"", .{});
            return null;
        };
        const name = (try self.asString(name_value, path)) orelse return null;

        var command = Command{ .name = name };
        if (object.get("variable")) |variable_value| {
            switch (variable_value) {
                .bool => |flag| command.variable = flag,
                else => {
                    try self.report(diag.E023_INVALID_TYPE, path, "expected boolean \"variable\"", .{});
                    return null;
                },
            }
        }
        if (object.get("args")) |args_value| {
            command.args = (try self.stringList(args_value, path)) orelse &.{};
        }
        if (object.get("josi")) |josi_value| {
            command.josi = (try self.stringList(josi_value, path)) orelse &.{};
        }
        if (command.variable) {
            if (command.args.len != 0 or command.josi.len != 0) {
                try self.report(diag.E029_INVALID_VALUE, path, "variable command \"{s}\" must not declare args/josi", .{name});
                return null;
            }
        } else if (command.josi.len != 0 and command.josi.len != command.args.len) {
            try self.report(diag.E029_INVALID_VALUE, path, "josi count {d} does not match args count {d} in \"{s}\"", .{ command.josi.len, command.args.len, name });
            return null;
        }
        return command;
    }
};

/// commands.json を解析して検証する。JSON 構文エラーは `error.InvalidJson`、
/// スキーマ違反は E019/E022/E023/E029/E035 を diagnostics へ記録して
/// `error.InvalidCommands` を返す。
pub fn parse(allocator: Allocator, source: []const u8, diagnostics: *diag.List) ParseError!Commands {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var parser = Parser{ .arena = arena.allocator(), .diagnostics = diagnostics };
    const prior_errors = diagnostics.errorCount();

    const root = (try parser.asObject(parsed.value, "commands.json")) orelse return error.InvalidCommands;
    try parser.rejectUnknown(root, &.{ "schemaVersion", "commands" }, "commands.json");

    const version_value = root.get("schemaVersion") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, "schemaVersion", "missing required field \"schemaVersion\"", .{});
        return error.InvalidCommands;
    };
    switch (version_value) {
        .integer => |number| {
            if (number <= 0 or number > std.math.maxInt(u32)) {
                try parser.report(diag.E023_INVALID_TYPE, "schemaVersion", "expected positive integer schemaVersion", .{});
            } else if (number != schema_version) {
                try parser.report(diag.E035_UNKNOWN_NPKG_SCHEMA, "schemaVersion", "unsupported commands.json schemaVersion {d} (expected {d})", .{ number, schema_version });
            }
        },
        else => {
            try parser.report(diag.E023_INVALID_TYPE, "schemaVersion", "expected integer schemaVersion", .{});
        },
    }

    const commands_value = root.get("commands") orelse {
        try parser.report(diag.E019_REQUIRED_FIELD_MISSING, "commands", "missing required field \"commands\"", .{});
        return error.InvalidCommands;
    };
    var items: std.ArrayList(Command) = .empty;
    if (try parser.asArray(commands_value, "commands")) |array| {
        try items.ensureTotalCapacity(parser.arena, array.items.len);
        for (array.items, 0..) |item, index| {
            if (try parser.validateCommand(item, index)) |command| items.appendAssumeCapacity(command);
        }
    }
    if (diagnostics.errorCount() > prior_errors) return error.InvalidCommands;
    // 全割当が完了した後に arena を移す（allocator が指す stack 上の arena と
    // 構造体メンバが別実体にならないよう、最後にコピーする）。
    return Commands{ .arena = arena, .commands = items.items };
}
