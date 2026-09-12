const std = @import("std");
const foundation = @import("low_level_foundation.zig");

/// Issue #37の低レイヤー命令カタログ。人間向け正本は `docs/low-level-api/catalog.json` であり、
/// 本モジュールはその同一内容のミラー `low_level_catalog.json` を埋め込んで単体テストで
/// 不変条件を検証する。両JSONの一致は `tools/check_low_level_spec.mjs` が保証する。
pub const catalog_json = @embedFile("low_level_catalog.json");

const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

fn getString(map: ObjectMap, key: []const u8) []const u8 {
    return map.get(key).?.string;
}

fn getInt(map: ObjectMap, key: []const u8) i64 {
    return map.get(key).?.integer;
}

fn tagCount() usize {
    return std.meta.tags(foundation.Capability).len;
}

fn validMatrixValue(value: Value) bool {
    return switch (value) {
        .bool => true,
        .string => |text| std.mem.eql(u8, text, "conditional"),
        else => false,
    };
}

test "カタログJSONのschemaと件数がヘッダと一致する" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, catalog_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("lnako.low-level-catalog.v1", getString(root, "schema"));
    try std.testing.expectEqual(@as(i64, 37), getInt(root, "issue"));
    const commands = root.get("commands").?.array.items;
    try std.testing.expectEqual(@as(usize, @intCast(getInt(root, "commandCount"))), commands.len);
    const capabilities = root.get("capabilities").?.array.items;
    try std.testing.expectEqual(@as(usize, @intCast(getInt(root, "capabilityCount"))), capabilities.len);
    try std.testing.expectEqual(tagCount(), capabilities.len);
    for (root.get("generatedForIssues").?.array.items) |entry| {
        const n = switch (entry) {
            .integer => |integer| integer,
            else => unreachable,
        };
        try std.testing.expect(n >= 27 and n <= 37);
    }
}

test "カタログの命令IDと名前は一意で、capability参照とclassが正本と一致する" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, catalog_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const commands = root.get("commands").?.array.items;

    var id_set = std.StringHashMap(void).init(std.testing.allocator);
    defer id_set.deinit();
    var name_set = std.StringHashMap(void).init(std.testing.allocator);
    defer name_set.deinit();

    for (commands) |command| {
        const map = command.object;
        const id = getString(map, "id");
        const name = getString(map, "name");
        const issue = getInt(map, "issue");
        const capability_field = map.get("capability").?;
        try std.testing.expect(!id_set.contains(id));
        try id_set.put(id, {});
        try std.testing.expect(!name_set.contains(name));
        try name_set.put(name, {});
        try std.testing.expect(issue >= 27 and issue <= 37);
        try std.testing.expect(name.len > 0 and id.len > 0);
        try std.testing.expect(getInt(map, "maxArgs") >= getInt(map, "minArgs"));

        if (capability_field != .null) {
            const capability_name = capability_field.string;
            const capability = foundation.Capability.fromId(capability_name) orelse
                return error.UnknownCapabilityInCatalog;
            _ = capability;
        } else {
            try std.testing.expect(std.mem.eql(u8, id, "ll-capability-supported") or
                std.mem.eql(u8, id, "ll-capability-list"));
        }

        for (map.get("errors").?.array.items) |entry| {
            try std.testing.expect(foundation.PortableErrorCode.fromName(entry.string) != null);
        }
    }
}

test "カタログのcapability matrix値と分類はfoundationのenumと一致する" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, catalog_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const capabilities = root.get("capabilities").?.array.items;

    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();

    for (capabilities) |capability| {
        const map = capability.object;
        const id = getString(map, "id");
        try std.testing.expect(!seen.contains(id));
        try seen.put(id, {});
        const enum_tag = foundation.Capability.fromId(id) orelse return error.UnknownCapabilityInCatalog;
        try std.testing.expectEqualStrings(@tagName(enum_tag.class()), getString(map, "class"));

        const os = map.get("os").?.object;
        for (std.meta.tags(foundation.OsKind)) |kind| {
            try std.testing.expect(validMatrixValue(os.get(@tagName(kind)).?));
        }
        const runtimes = map.get("runtimes").?.object;
        for (std.meta.tags(foundation.RuntimeKind)) |kind| {
            try std.testing.expect(validMatrixValue(runtimes.get(@tagName(kind)).?));
        }
    }
    try std.testing.expectEqual(tagCount(), seen.count());
}

test "coreUtilities逆引きは既知の命令IDとcapability IDだけを参照する" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, catalog_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const commands = root.get("commands").?.array.items;
    const capabilities = root.get("capabilities").?.array.items;

    var command_ids = std.StringHashMap(void).init(std.testing.allocator);
    defer command_ids.deinit();
    var capability_ids = std.StringHashMap(void).init(std.testing.allocator);
    defer capability_ids.deinit();
    for (commands) |command| try command_ids.put(getString(command.object, "id"), {});
    for (capabilities) |capability| try capability_ids.put(getString(capability.object, "id"), {});

    for (root.get("coreUtilities").?.array.items) |entry| {
        const map = entry.object;
        const utility = getString(map, "utility");
        try std.testing.expect(utility.len > 0);
        for (map.get("commands").?.array.items) |command_ref| {
            try std.testing.expect(command_ids.contains(command_ref.string));
        }
        for (map.get("capabilities").?.array.items) |capability_ref| {
            try std.testing.expect(capability_ids.contains(capability_ref.string));
        }
    }
}

test "typesの定義はカタログのreturns型を網羅する" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, catalog_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const commands = root.get("commands").?.array.items;
    const types = root.get("types").?.object;

    for (commands) |command| {
        try std.testing.expect(types.contains(getString(command.object, "returns")));
    }
}

const PlaceholderSet = std.StringHashMap(void);

fn collectPlaceholders(allocator: std.mem.Allocator, particles: []const u8) !PlaceholderSet {
    var set = PlaceholderSet.init(allocator);
    var index: usize = 0;
    while (index < particles.len) {
        if (particles[index] >= 'A' and particles[index] <= 'Z') {
            const start = index;
            while (index < particles.len and isPlaceholderChar(particles[index])) index += 1;
            try set.put(particles[start..index], {});
        } else index += 1;
    }
    return set;
}

fn isPlaceholderChar(character: u8) bool {
    return (character >= 'A' and character <= 'Z') or (character >= '0' and character <= '9') or character == '_';
}

test "助詞プレースホルダとarity・引数型がparameterTypesで覆われる" {
    var parsed = try std.json.parseFromSlice(Value, std.testing.allocator, catalog_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const commands = root.get("commands").?.array.items;
    const types = root.get("types").?.object;
    const parameter_types = root.get("parameterTypes").?.object;

    for (commands) |command| {
        const map = command.object;
        const particles = getString(map, "particles");
        const max_args: usize = @intCast(getInt(map, "maxArgs"));
        var placeholders = try collectPlaceholders(std.testing.allocator, particles);
        defer placeholders.deinit();
        if (particles.len == 0) continue;
        try std.testing.expectEqual(max_args, placeholders.count());

        const overrides = if (map.get("paramTypes")) |override| override.object else null;
        var iterator = placeholders.keyIterator();
        while (iterator.next()) |key| {
            const placeholder = key.*;
            if (overrides) |override| {
                if (override.get(placeholder)) |type_name| {
                    try std.testing.expect(types.contains(type_name.string));
                    continue;
                }
            }
            const type_name = parameter_types.get(placeholder) orelse return error.UnmappedParameterType;
            try std.testing.expect(types.contains(type_name.string));
        }
        if (overrides) |override| {
            var override_iterator = override.iterator();
            while (override_iterator.next()) |entry| {
                try std.testing.expect(placeholders.contains(entry.key_ptr.*));
                try std.testing.expect(types.contains(entry.value_ptr.string));
            }
        }
    }
}

test "HandleKindはファイル・ディレクトリ・ハッシュ・プロセスを持つ" {
    try std.testing.expectEqual(@as(usize, 4), std.meta.tags(foundation.HandleKind).len);
    try std.testing.expect(std.meta.stringToEnum(foundation.HandleKind, "file") != null);
    try std.testing.expect(std.meta.stringToEnum(foundation.HandleKind, "directory") != null);
    try std.testing.expect(std.meta.stringToEnum(foundation.HandleKind, "hash") != null);
    try std.testing.expect(std.meta.stringToEnum(foundation.HandleKind, "process") != null);
}
