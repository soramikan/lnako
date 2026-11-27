const std = @import("std");
const testing = std.testing;

const types = @import("v1_types.zig");
const imports = @import("v1_imports.zig");

const default_exports = [_]imports.ExportEntry{
    .{ .subpath = "." },
};

test "R-01 衝突しない直接依存は name 部分の省略名で既定入口へ解決する" {
    const declarations = [_]imports.Declaration{
        .{ .id = "@acme/json", .exports = &default_exports },
        .{ .id = "@acme/http", .exports = &default_exports },
    };
    const table = imports.Table.init(null, &declarations);
    const resolved = try table.resolve("json");
    try testing.expectEqualStrings("@acme/json", resolved.id);
    try testing.expectEqualStrings(".", resolved.subpath);
    try testing.expectEqualStrings("json", resolved.local_name);
    try testing.expect(resolved.owner == null);
    try testing.expect(resolved.binding == .scoped);
    try testing.expect(!resolved.allow_global_commands);
}

test "R-02 明示 alias はその依存だけを指し、別名同士は曖昧にならない" {
    const declarations = [_]imports.Declaration{
        .{ .id = "@acme/json", .exports = &default_exports },
        .{ .id = "@other/json", .alias = "fast_json", .exports = &default_exports },
    };
    const table = imports.Table.init(null, &declarations);

    const normal = try table.resolve("json");
    try testing.expectEqualStrings("@acme/json", normal.id);
    try testing.expectEqualStrings("json", normal.local_name);

    const aliased = try table.resolve("fast_json");
    try testing.expectEqualStrings("@other/json", aliased.id);
    try testing.expectEqualStrings("fast_json", aliased.local_name);
}

test "R-03 alias のない同名直接依存は import 時に Ambiguous Import になる" {
    const declarations = [_]imports.Declaration{
        .{ .id = "@acme/json", .exports = &default_exports },
        .{ .id = "@other/json", .exports = &default_exports },
    };
    const table = imports.Table.init(null, &declarations);

    try testing.expectError(error.AmbiguousImport, table.resolve("json"));

    const qualified = try table.resolve("@other/json");
    try testing.expectEqualStrings("@other/json", qualified.id);
    const other_qualified = try table.resolve("@acme/json");
    try testing.expectEqualStrings("@acme/json", other_qualified.id);
}

test "R-07 間接依存はルートの省略名でも完全修飾 ID でも解決しない" {
    const root_declarations = [_]imports.Declaration{
        .{ .id = "@acme/left", .exports = &default_exports },
    };
    const root = imports.Table.init(null, &root_declarations);
    try testing.expectError(error.UnknownImport, root.resolve("inner"));
    try testing.expectError(error.UnknownImport, root.resolve("@acme/inner"));

    // 依存元 @acme/left 自身の表には直接依存として存在する。スコープは
    // 依存元ごとに閉じており、ルートへ継承されない。
    const left_declarations = [_]imports.Declaration{
        .{ .id = "@acme/inner", .exports = &default_exports },
    };
    const left = imports.Table.init("@acme/left", &left_declarations);
    const resolved = try left.resolve("inner");
    try testing.expectEqualStrings("@acme/inner", resolved.id);
    try testing.expectEqualStrings("@acme/left", resolved.owner.?);
    try testing.expectError(error.UnknownImport, left.resolve("@acme/left"));
}

test "公開サブパスは宣言済みの exports だけを解決する" {
    const exports = [_]imports.ExportEntry{
        .{ .subpath = "." },
        .{ .subpath = "./client", .binding = .global },
    };
    const declarations = [_]imports.Declaration{
        .{ .id = "@acme/json", .exports = &exports },
    };
    const table = imports.Table.init(null, &declarations);

    const client = try table.resolve("json/client");
    try testing.expectEqualStrings("./client", client.subpath);
    try testing.expect(client.binding == .global);

    const qualified_client = try table.resolve("@acme/json/client");
    try testing.expectEqualStrings("./client", qualified_client.subpath);

    try testing.expectError(error.UndeclaredSubpath, table.resolve("json/missing"));
    try testing.expectError(error.UndeclaredSubpath, table.resolve("@acme/json/missing"));
    try testing.expectError(error.InvalidImportSpec, table.resolve("json/../client"));
    try testing.expectError(error.InvalidImportSpec, table.resolve("json/./client"));
    try testing.expectError(error.InvalidImportSpec, table.resolve("json/"));
    try testing.expectError(error.InvalidImportSpec, table.resolve("json\\client"));
}

test "exports 省略時は既定入口 . だけを持ち、サブパスは補完しない" {
    const declarations = [_]imports.Declaration{
        .{ .id = "@acme/json" },
    };
    const table = imports.Table.init(null, &declarations);
    const resolved = try table.resolve("json");
    try testing.expectEqualStrings(".", resolved.subpath);
    try testing.expect(resolved.binding == .scoped);
    try testing.expectError(error.UndeclaredSubpath, table.resolve("json/client"));
}

test "R-12（P09範囲）依存元の alias と global 許可を保持し、別スコープへ継承しない" {
    const global_exports = [_]imports.ExportEntry{
        .{ .subpath = ".", .binding = .global },
    };
    const dependency = types.Dependency{
        .id = "@acme/dsl",
        .req = "^1.0.0",
        .alias = "local_dsl",
        .allow_global_commands = true,
    };
    const declarations = [_]imports.Declaration{
        imports.Declaration.fromDependency(dependency, &global_exports),
    };
    const table = imports.Table.init("@acme/left", &declarations);

    const resolved = try table.resolve("local_dsl");
    try testing.expectEqualStrings("@acme/dsl", resolved.id);
    try testing.expectEqualStrings("local_dsl", resolved.alias.?);
    try testing.expect(resolved.binding == .global);
    try testing.expect(resolved.allow_global_commands);
    try testing.expect(table.allowsGlobalCommands("@acme/dsl"));

    // ルートの表には left の alias も許可も継承されない。
    const root_declarations = [_]imports.Declaration{
        .{ .id = "@acme/left", .exports = &default_exports },
    };
    const root = imports.Table.init(null, &root_declarations);
    try testing.expectError(error.UnknownImport, root.resolve("local_dsl"));
    try testing.expect(!root.allowsGlobalCommands("@acme/dsl"));
}

test "完全修飾 ID の重複宣言も import 時に曖昧として拒否する" {
    const declarations = [_]imports.Declaration{
        .{ .id = "@acme/json", .exports = &default_exports },
        .{ .id = "@acme/json", .alias = "second", .exports = &default_exports },
    };
    const table = imports.Table.init(null, &declarations);
    try testing.expectError(error.AmbiguousImport, table.resolve("@acme/json"));
    try testing.expectError(error.AmbiguousImport, table.direct("@acme/json"));
    try testing.expect(table.allowsGlobalCommands("@acme/json") == false);
}

test "重複した exports サブパスは先勝ちにせず曖昧として拒否する" {
    const duplicate_exports = [_]imports.ExportEntry{
        .{ .subpath = "./client", .binding = .scoped },
        .{ .subpath = "./client", .binding = .global },
    };
    const declarations = [_]imports.Declaration{
        .{ .id = "@acme/json", .exports = &duplicate_exports },
    };
    const table = imports.Table.init(null, &declarations);
    try testing.expectError(error.AmbiguousImport, table.resolve("json/client"));
}
