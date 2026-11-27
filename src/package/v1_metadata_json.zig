//! 制御 JSON（FILES.json・COMMANDS.json）の厳格な読み込み補助。
//!
//! 文書全体が単一の JSON 値であることを検証してから値を返す。数値は JSON
//! の整数だけを受理し、浮動小数は型違いとして拒否する（TOML の整数検査と
//! 同じ方針）。重複キーは `std.json` の仕様どおり後勝ちとなるため、ここでは
//! 検出しない。

const std = @import("std");

pub const Error = error{ OutOfMemory, InvalidJson };

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    if (!try std.json.Scanner.validate(allocator, bytes)) return error.InvalidJson;
    return std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
}

pub fn object(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |map| map,
        else => error.InvalidFieldType,
    };
}

pub fn array(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |list| list,
        else => error.InvalidFieldType,
    };
}

pub fn string(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidFieldType,
    };
}

pub fn integer(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |number| number,
        else => error.InvalidFieldType,
    };
}

pub fn boolean(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidFieldType,
    };
}

pub fn field(map: std.json.ObjectMap, name: []const u8) !std.json.Value {
    return map.get(name) orelse error.MissingField;
}

pub fn optionalField(map: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    return map.get(name);
}

pub fn stringField(map: std.json.ObjectMap, name: []const u8) ![]const u8 {
    return string(try field(map, name));
}

pub fn integerField(map: std.json.ObjectMap, name: []const u8) !i64 {
    return integer(try field(map, name));
}

pub fn boolField(map: std.json.ObjectMap, name: []const u8) !bool {
    return boolean(try field(map, name));
}

pub fn optionalStringField(map: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = optionalField(map, name) orelse return null;
    return string(value);
}
