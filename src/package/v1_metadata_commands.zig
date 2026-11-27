//! `NAKO-PKG/COMMANDS.json` のモデル・決定的シリアライズ・厳格な解析。
//!
//! 仕様 §3.5。`exports` のキー集合と各 `binding` は METADATA.toml の
//! `exports` と一致しなければならない（交叉検査は `v1_archive` が行う）。
//! `global` の入口が一つでもある場合に限り `exports_global_commands` を
//! `true` とする。`global_commands` は global 入口の commands[].name から
//! 作り、定数は含めない。

const std = @import("std");
const json = @import("v1_metadata_json.zig");
const types = @import("v1_types.zig");

const Allocator = std.mem.Allocator;

pub const schema_version: u32 = 1;

pub const Error = error{
    OutOfMemory,
    InvalidJson,
    InvalidCommands,
    InvalidSchemaVersion,
    MissingField,
    InvalidFieldType,
    InvalidSubpath,
    InvalidBinding,
    DuplicateCommand,
    DuplicateConstant,
    GlobalCommandsMismatch,
};

pub const Arg = struct {
    name: []const u8,
    josi: []const []const u8 = &.{},
    type_name: ?[]const u8 = null,
};

pub const Command = struct {
    name: []const u8,
    kind: []const u8,
    args: []const Arg = &.{},
    return_type: ?[]const u8 = null,
    is_async: ?bool = null,
    doc: ?[]const u8 = null,
};

pub const Export = struct {
    subpath: []const u8,
    binding: types.Binding,
    commands: []const Command = &.{},
    constants: []const []const u8 = &.{},
};

pub const Model = struct {
    exports: []const Export = &.{},
    exports_global_commands: bool = false,

    pub fn findExport(self: *const Model, subpath: []const u8) ?*const Export {
        for (self.exports) |*export_entry| {
            if (std.mem.eql(u8, export_entry.subpath, subpath)) return export_entry;
        }
        return null;
    }
};

pub const Parsed = struct {
    document: std.json.Parsed(std.json.Value),
    model: Model,
};

fn validSubpath(text: []const u8) bool {
    if (std.mem.eql(u8, text, ".")) return true;
    if (!std.mem.startsWith(u8, text, "./")) return false;
    return types.validPath(text[2..]);
}

fn parseBinding(text: []const u8) !types.Binding {
    if (std.mem.eql(u8, text, "scoped")) return .scoped;
    if (std.mem.eql(u8, text, "global")) return .global;
    return error.InvalidBinding;
}

pub fn bindingName(binding: types.Binding) []const u8 {
    return switch (binding) {
        .scoped => "scoped",
        .global => "global",
    };
}

fn exportLessThan(_: void, left: Export, right: Export) bool {
    return std.mem.order(u8, left.subpath, right.subpath) == .lt;
}

fn commandLessThan(_: void, left: Command, right: Command) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn duplicateNames(commands: []const Command) bool {
    for (commands, 0..) |command, index| {
        for (commands[index + 1 ..]) |other| {
            if (std.mem.eql(u8, command.name, other.name)) return true;
        }
    }
    return false;
}

fn duplicateStrings(items: []const []const u8) bool {
    for (items, 0..) |item, index| {
        for (items[index + 1 ..]) |other| {
            if (std.mem.eql(u8, item, other)) return true;
        }
    }
    return false;
}

/// JSON を解析し、モデルを `model_allocator` に構築する。文字列は返却する
/// `document` の arena を借用する。
pub fn parse(
    backing_allocator: Allocator,
    bytes: []const u8,
    model_allocator: Allocator,
) !Parsed {
    var document = json.parse(backing_allocator, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidJson => return error.InvalidJson,
    };
    errdefer document.deinit();
    const model = try buildModel(model_allocator, document.value);
    return .{ .document = document, .model = model };
}

pub fn buildModel(allocator: Allocator, value: std.json.Value) !Model {
    const root = json.object(value) catch return error.InvalidCommands;
    const version = json.integerField(root, "schema_version") catch return error.InvalidCommands;
    if (version != schema_version) return error.InvalidSchemaVersion;
    const flag = json.boolField(root, "exports_global_commands") catch return error.InvalidCommands;
    const exports_value = json.field(root, "exports") catch return error.InvalidCommands;
    const exports_object = json.object(exports_value) catch return error.InvalidCommands;

    const exports = try allocator.alloc(Export, exports_object.count());
    var index: usize = 0;
    var iterator = exports_object.iterator();
    while (iterator.next()) |item| : (index += 1) {
        const subpath = item.key_ptr.*;
        if (!validSubpath(subpath)) return error.InvalidSubpath;
        const object = json.object(item.value_ptr.*) catch return error.InvalidCommands;
        const binding_text = json.stringField(object, "binding") catch return error.InvalidCommands;
        const binding = parseBinding(binding_text) catch return error.InvalidBinding;
        const commands_value = json.field(object, "commands") catch return error.InvalidCommands;
        const command_items = json.array(commands_value) catch return error.InvalidCommands;
        const commands = try allocator.alloc(Command, command_items.items.len);
        for (command_items.items, 0..) |command_value, command_index| {
            const command_object = json.object(command_value) catch return error.InvalidCommands;
            const name = json.stringField(command_object, "name") catch return error.InvalidCommands;
            if (name.len == 0) return error.InvalidCommands;
            const kind = json.stringField(command_object, "kind") catch return error.InvalidCommands;
            if (kind.len == 0) return error.InvalidCommands;
            const args_value = json.field(command_object, "args") catch return error.InvalidCommands;
            const arg_items = json.array(args_value) catch return error.InvalidCommands;
            const args = try allocator.alloc(Arg, arg_items.items.len);
            for (arg_items.items, 0..) |arg_value, arg_index| {
                const arg_object = json.object(arg_value) catch return error.InvalidCommands;
                const arg_name = json.stringField(arg_object, "name") catch return error.InvalidCommands;
                if (arg_name.len == 0) return error.InvalidCommands;
                const josi_value = json.field(arg_object, "josi") catch return error.InvalidCommands;
                const josi_items = json.array(josi_value) catch return error.InvalidCommands;
                const josi = try allocator.alloc([]const u8, josi_items.items.len);
                for (josi_items.items, 0..) |josi_value_item, josi_index| {
                    josi[josi_index] = json.string(josi_value_item) catch return error.InvalidCommands;
                }
                const type_name = try optionalStringField(arg_object, "type");
                args[arg_index] = .{ .name = arg_name, .josi = josi, .type_name = type_name };
            }
            commands[command_index] = .{
                .name = name,
                .kind = kind,
                .args = args,
                .return_type = try optionalStringField(command_object, "return_type"),
                .is_async = try optionalBoolField(command_object, "async"),
                .doc = try optionalStringField(command_object, "doc"),
            };
        }
        if (duplicateNames(commands)) return error.DuplicateCommand;
        const constants_value = json.field(object, "constants") catch return error.InvalidCommands;
        const constant_items = json.array(constants_value) catch return error.InvalidCommands;
        const constants = try allocator.alloc([]const u8, constant_items.items.len);
        for (constant_items.items, 0..) |constant_value, constant_index| {
            constants[constant_index] = json.string(constant_value) catch return error.InvalidCommands;
        }
        if (duplicateStrings(constants)) return error.DuplicateConstant;
        exports[index] = .{
            .subpath = subpath,
            .binding = binding,
            .commands = commands,
            .constants = constants,
        };
    }
    std.mem.sort(Export, exports, {}, exportLessThan);
    for (exports, 0..) |export_entry, export_index| {
        if (export_index > 0 and std.mem.eql(u8, exports[export_index - 1].subpath, export_entry.subpath))
            return error.InvalidCommands;
    }
    const model = Model{ .exports = exports, .exports_global_commands = flag };
    try validateFlag(model);
    return model;
}

fn optionalStringField(map: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = json.optionalField(map, name) orelse return null;
    const text = try json.string(value);
    return text;
}

fn optionalBoolField(map: std.json.ObjectMap, name: []const u8) !?bool {
    const value = json.optionalField(map, name) orelse return null;
    const flag = try json.boolean(value);
    return flag;
}

fn hasGlobalExport(model: Model) bool {
    for (model.exports) |export_entry| {
        if (export_entry.binding == .global) return true;
    }
    return false;
}

fn validateFlag(model: Model) !void {
    if (model.exports_global_commands != hasGlobalExport(model)) return error.GlobalCommandsMismatch;
}

/// 決定的な COMMANDS.json を書き出す。サブパス・命令名・定数名を昇順に
/// 並べ、`exports_global_commands` は `binding` から導出する。
pub fn emit(allocator: Allocator, exports_input: []const Export) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exports = try arena.dupe(Export, exports_input);
    std.mem.sort(Export, exports, {}, exportLessThan);
    for (exports, 0..) |*export_entry, index| {
        if (index > 0 and std.mem.eql(u8, exports[index - 1].subpath, export_entry.subpath))
            return error.InvalidSubpath;
        if (!validSubpath(export_entry.subpath)) return error.InvalidSubpath;
        const commands = try arena.dupe(Command, export_entry.commands);
        for (commands) |command| {
            if (command.name.len == 0 or command.kind.len == 0) return error.InvalidCommands;
        }
        std.mem.sort(Command, commands, {}, commandLessThan);
        if (duplicateNames(commands)) return error.DuplicateCommand;
        export_entry.commands = commands;
        const constants = try arena.dupe([]const u8, export_entry.constants);
        std.mem.sort([]const u8, constants, {}, stringLessThan);
        if (duplicateStrings(constants)) return error.DuplicateConstant;
        export_entry.constants = constants;
    }
    const global = hasGlobalExport(.{ .exports = exports, .exports_global_commands = false });

    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    errdefer output.deinit();
    const writer = &output.writer;
    try writer.print("{{\"schema_version\":{d},\"exports_global_commands\":{s},\"exports\":{{", .{
        schema_version,
        if (global) "true" else "false",
    });
    for (exports, 0..) |export_entry, export_index| {
        if (export_index > 0) try writer.writeByte(',');
        try std.json.Stringify.value(export_entry.subpath, .{}, writer);
        try writer.print(":{{\"binding\":\"{s}\",\"commands\":[", .{bindingName(export_entry.binding)});
        for (export_entry.commands, 0..) |command, command_index| {
            if (command_index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try std.json.Stringify.value(command.name, .{}, writer);
            try writer.writeAll(",\"kind\":");
            try std.json.Stringify.value(command.kind, .{}, writer);
            try writer.writeAll(",\"args\":[");
            for (command.args, 0..) |arg, arg_index| {
                if (arg_index > 0) try writer.writeByte(',');
                try writer.writeAll("{\"name\":");
                try std.json.Stringify.value(arg.name, .{}, writer);
                try writer.writeAll(",\"josi\":[");
                for (arg.josi, 0..) |josi, josi_index| {
                    if (josi_index > 0) try writer.writeByte(',');
                    try std.json.Stringify.value(josi, .{}, writer);
                }
                try writer.writeByte(']');
                if (arg.type_name) |type_name| {
                    try writer.writeAll(",\"type\":");
                    try std.json.Stringify.value(type_name, .{}, writer);
                }
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
            if (command.return_type) |return_type| {
                try writer.writeAll(",\"return_type\":");
                try std.json.Stringify.value(return_type, .{}, writer);
            }
            if (command.is_async) |is_async| {
                try writer.print(",\"async\":{s}", .{if (is_async) "true" else "false"});
            }
            if (command.doc) |doc| {
                try writer.writeAll(",\"doc\":");
                try std.json.Stringify.value(doc, .{}, writer);
            }
            try writer.writeByte('}');
        }
        try writer.writeAll("],\"constants\":[");
        for (export_entry.constants, 0..) |constant, constant_index| {
            if (constant_index > 0) try writer.writeByte(',');
            try std.json.Stringify.value(constant, .{}, writer);
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("}}\n");
    return output.toOwnedSlice();
}

/// `global` 入口の命令名集合（昇順・重複なし）。定数は含めない。
pub fn globalCommandNames(allocator: Allocator, model: Model) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    for (model.exports) |export_entry| {
        if (export_entry.binding != .global) continue;
        for (export_entry.commands) |command| try names.append(allocator, command.name);
    }
    std.mem.sort([]const u8, names.items, {}, stringLessThan);
    var unique: usize = 0;
    for (names.items) |name| {
        if (unique > 0 and std.mem.eql(u8, names.items[unique - 1], name)) continue;
        names.items[unique] = name;
        unique += 1;
    }
    names.shrinkRetainingCapacity(unique);
    return names.toOwnedSlice(allocator);
}
