//! v1 `.npkg` のクロスアーティファクト検証（§3.3・§3.5・§5.3）。
//!
//! 入力は個別検証済みのアーカイブが公開する `METADATA.toml` の TOML 文書と
//! `COMMANDS.json` の JSON 値だけにする。ZIP やファイルシステムへは触れない
//! ため、P03 の `v1_archive` と独立してコンパイル・試験できる。
//!
//! 統合時は `v1_archive.Verified` が `metadata.root`（`toml.Document`）と
//! `commands.value`（`std.json.Value`）を持つ前提で、そのスライスをそのまま
//! `validate` / `check` へ渡せる。個別検証の後、永続化の前に呼ぶこと。
//!
//! P03 のモデルは個別検証の結果なので、ここでは比較の基準を入力文書のまま
//! 正規化する。既定値の補完規則を個別検証の判定と混在させない。
//!
//! 正規化の規則:
//! - `exports[].binding` の省略は `scoped`、依存の `allow_global_commands`
//!   の省略は `false`、依存の `runtimes` の省略は全ランタイム共通。
//!   依存の `default_features` は `true`、`optional` は `false` を省略時の
//!   意味として補う（依存条件の評価に必要な既定値）。
//! - `capabilities`、feature の追加先、依存、COMMANDS の global 命令名は
//!   集合として比較し、順序と重複を無視する。
//! - `engines`、`exports`、`features`、`dependencies` の表のキー順は無視する。
//! - 比較対象の共通項目に順序そのものが意味を持つ配列はない。命令の引数や
//!   定数の並びはアーティファクト固有で、ここでは比較しない。
//! - `artifact.entries`、`artifact.kind`、`artifact.runtimes`、
//!   `artifact.native` はアーティファクト固有。`kind`/`runtimes`/
//!   `target_triple`/`abi_version` の組だけを重複検査に使う。
//! - COMMANDS の `global_commands` は `binding = "global"` の入口の
//!   `commands[].name` から作り、定数は含めない（§3.5）。

const std = @import("std");
const toml = @import("toml.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{ OutOfMemory, CrossValidationFailed };

/// 不正な入力（個別検証を経ていない文書）を表す内部エラー。
/// 公開 API では診断へ変換し、`CrossValidationFailed` として返す。
const ParseError = error{ OutOfMemory, InvalidInput };
const Oom = error{OutOfMemory};

pub const Code = enum {
    /// アーティファクトが一つもない。
    empty_artifact_set,
    /// METADATA.toml の必須構造を読めない。
    invalid_metadata,
    /// COMMANDS.json の必須構造を読めない。
    invalid_commands,
    /// リリース共通項目が先頭アーティファクトと一致しない。
    common_field_mismatch,
    /// exports_global_commands または global 命令名の集合が一致しない。
    global_commands_mismatch,
    /// kind/runtimes/target_triple/abi_version の組が重複する。
    duplicate_artifact,
};

pub const Diagnostic = struct {
    code: Code,
    artifact: ?usize = null,
    other: ?usize = null,
    /// 静的文字列。比較に使った METADATA/COMMANDS の項目名。
    field: []const u8 = "",
};

/// `v1_archive.Verified` から取り出した比較入力を直接渡すための型。
pub const Documents = struct {
    metadata: *const toml.Document,
    commands: *const std.json.Value,
};

/// 検証結果。`deinit` まで `global_commands` と診断の文字列は有効。
pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic = &.{},
    /// 先頭アーティファクトから導出した global 命令名（定数を除く）。
    /// 不一致があっても診断に残るため、比較の基準として使える。
    global_commands: []const []const u8 = &.{},

    pub fn ok(self: *const Report) bool {
        return self.diagnostics.len == 0;
    }

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// 個別検証済みのアーカイブ入力をクロス検証する。
///
/// `artifacts` の要素は次のフィールドを持つこと。
/// - `metadata.root`: `toml.Document`
/// - `commands.value`: `std.json.Value`
///
/// 例: `v1_archive.Verified` のスライスをそのまま渡す。
pub fn validate(allocator: Allocator, artifacts: anytype) Error!void {
    var report = try check(allocator, artifacts);
    defer report.deinit();
    if (!report.ok()) return error.CrossValidationFailed;
}

/// 診断付きでクロス検証する。入力不正も例外にせず診断へ入れる。
pub fn check(allocator: Allocator, artifacts: anytype) Error!Report {
    const documents = try allocator.alloc(Documents, artifacts.len);
    defer allocator.free(documents);
    for (0..artifacts.len) |index| {
        const element = artifacts[index];
        const artifact = switch (@typeInfo(@TypeOf(element))) {
            .pointer => element,
            else => &artifacts[index],
        };
        documents[index] = .{
            .metadata = metadataDocument(artifact),
            .commands = commandsValue(artifact),
        };
    }
    return checkDocuments(allocator, documents);
}

/// `v1_archive.Verified` の公開形から TOML 文書を取り出す。
/// 仕様上の約束は `metadata.root` が `toml.Document`。P03 の `Parsed` が
/// 持つ `metadata.document` と、Document を直接持つ形も受理する。
fn metadataDocument(artifact: anytype) *const toml.Document {
    const ArtifactType = @TypeOf(artifact);
    if (comptime hasStructField(ArtifactType, "metadata")) {
        const MetadataType = structFieldType(ArtifactType, "metadata");
        if (comptime isTomlDocument(MetadataType)) return &artifact.metadata;
        if (comptime hasStructField(MetadataType, "root")) {
            const RootType = structFieldType(MetadataType, "root");
            if (comptime isTomlDocument(RootType)) return &artifact.metadata.root;
        }
        if (comptime hasStructField(MetadataType, "document")) {
            const DocumentType = structFieldType(MetadataType, "document");
            if (comptime isTomlDocument(DocumentType)) return &artifact.metadata.document;
        }
    }
    if (comptime hasStructField(ArtifactType, "metadata_root")) {
        const DocumentType = structFieldType(ArtifactType, "metadata_root");
        if (comptime isTomlDocument(DocumentType)) return &artifact.metadata_root;
    }
    @compileError("v1_cross: metadata.root に toml.Document を持つ入力を渡してください");
}

/// `v1_archive.Verified` の公開形から COMMANDS の JSON 値を取り出す。
/// 仕様上の約束は `commands.value`。P03 の `Parsed.document.value` も受理する。
fn commandsValue(artifact: anytype) *const std.json.Value {
    const ArtifactType = @TypeOf(artifact);
    if (comptime hasStructField(ArtifactType, "commands")) {
        const CommandsType = structFieldType(ArtifactType, "commands");
        if (comptime CommandsType == std.json.Value) return &artifact.commands;
        if (comptime hasStructField(CommandsType, "value")) {
            const ValueType = structFieldType(CommandsType, "value");
            if (comptime ValueType == std.json.Value) return &artifact.commands.value;
        }
        if (comptime hasStructField(CommandsType, "document")) {
            const DocumentType = structFieldType(CommandsType, "document");
            if (comptime DocumentType == std.json.Value) return &artifact.commands.document;
            if (comptime hasStructField(DocumentType, "value")) {
                const ValueType = structFieldType(DocumentType, "value");
                if (comptime ValueType == std.json.Value) return &artifact.commands.document.value;
            }
        }
    }
    if (comptime hasStructField(ArtifactType, "commands_value")) {
        if (comptime structFieldType(ArtifactType, "commands_value") == std.json.Value) {
            return &artifact.commands_value;
        }
    }
    @compileError("v1_cross: commands.value に std.json.Value を持つ入力を渡してください");
}

fn baseType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
}

fn hasStructField(comptime T: type, comptime name: []const u8) bool {
    const Base = baseType(T);
    return switch (@typeInfo(Base)) {
        .@"struct" => @hasField(Base, name),
        else => false,
    };
}

fn structFieldType(comptime T: type, comptime name: []const u8) type {
    return @FieldType(baseType(T), name);
}

fn isTomlDocument(comptime T: type) bool {
    const Base = baseType(T);
    return switch (@typeInfo(Base)) {
        .@"struct" => @hasField(Base, "arena") and @hasField(Base, "root") and @hasField(Base, "source"),
        else => false,
    };
}

/// 文書を直接渡す低レベル版。`validate` と同じ規則で検証する。
pub fn validateDocuments(allocator: Allocator, documents: []const Documents) Error!void {
    var report = try checkDocuments(allocator, documents);
    defer report.deinit();
    if (!report.ok()) return error.CrossValidationFailed;
}

/// 文書を直接渡す低レベル版。診断と global 命令名を返す。
pub fn checkDocuments(allocator: Allocator, documents: []const Documents) Error!Report {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var context = Context{ .allocator = arena_allocator };
    try context.run(documents);

    const diagnostics = try context.diagnostics.toOwnedSlice(arena_allocator);
    const global_commands = try arena_allocator.dupe([]const u8, context.baseline_global_commands);
    return .{
        .arena = arena,
        .diagnostics = diagnostics,
        .global_commands = global_commands,
    };
}

const Metadata = struct {
    id: []const u8,
    version: []const u8,
    license: []const u8,
    capabilities: []const u8,
    engines: []const u8,
    exports: []const u8,
    features: []const u8,
    dependencies: []const u8,
    kind: []const u8,
    runtimes: []const u8,
    target_triple: ?[]const u8,
    abi_version: ?i64,
};

const Commands = struct {
    exports_global_commands: bool,
    global_commands: []const u8,
    global_names: []const []const u8,
};

const Context = struct {
    allocator: Allocator,
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,
    baseline_global_commands: []const []const u8 = &.{},

    fn run(self: *Context, documents: []const Documents) Oom!void {
        if (documents.len == 0) {
            try self.add(.{ .code = .empty_artifact_set });
            return;
        }

        const metadata = try self.allocator.alloc(?Metadata, documents.len);
        const commands = try self.allocator.alloc(?Commands, documents.len);
        for (documents, 0..) |document, index| {
            metadata[index] = parseMetadata(self.allocator, document.metadata) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidInput => blk: {
                    try self.add(.{
                        .code = .invalid_metadata,
                        .artifact = index,
                        .field = "METADATA.toml",
                    });
                    break :blk null;
                },
            };
            commands[index] = parseCommands(self.allocator, document.commands) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidInput => blk: {
                    try self.add(.{
                        .code = .invalid_commands,
                        .artifact = index,
                        .field = "COMMANDS.json",
                    });
                    break :blk null;
                },
            };
        }

        const baseline_metadata = metadata[0];
        const baseline_commands = commands[0];
        if (baseline_commands) |value| {
            self.baseline_global_commands = value.global_names;
        }

        for (1..documents.len) |index| {
            if (baseline_metadata != null and metadata[index] != null) {
                try self.compareMetadata(baseline_metadata.?, metadata[index].?, index);
            }
            if (baseline_commands != null and commands[index] != null) {
                try self.compareCommands(baseline_commands.?, commands[index].?, index);
            }
        }

        var seen = std.StringHashMapUnmanaged(usize).empty;
        defer seen.deinit(self.allocator);
        for (metadata, 0..) |entry, index| {
            const value = entry orelse continue;
            const key = try artifactKey(self.allocator, value);
            if (seen.get(key)) |previous| {
                try self.add(.{
                    .code = .duplicate_artifact,
                    .artifact = index,
                    .other = previous,
                    .field = "artifact(kind,runtimes,target_triple,abi_version)",
                });
            } else {
                try seen.put(self.allocator, key, index);
            }
        }
    }

    fn compareMetadata(self: *Context, baseline: Metadata, candidate: Metadata, index: usize) !void {
        try self.compareField("package.id", baseline.id, candidate.id, index);
        try self.compareField("package.version", baseline.version, candidate.version, index);
        try self.compareField("package.license", baseline.license, candidate.license, index);
        try self.compareField("package.capabilities", baseline.capabilities, candidate.capabilities, index);
        try self.compareField("engines", baseline.engines, candidate.engines, index);
        try self.compareField("exports", baseline.exports, candidate.exports, index);
        try self.compareField("features", baseline.features, candidate.features, index);
        try self.compareField("dependencies", baseline.dependencies, candidate.dependencies, index);
    }

    fn compareCommands(self: *Context, baseline: Commands, candidate: Commands, index: usize) !void {
        if (baseline.exports_global_commands != candidate.exports_global_commands) {
            try self.add(.{
                .code = .global_commands_mismatch,
                .artifact = index,
                .other = 0,
                .field = "COMMANDS.exports_global_commands",
            });
        }
        if (!std.mem.eql(u8, baseline.global_commands, candidate.global_commands)) {
            try self.add(.{
                .code = .global_commands_mismatch,
                .artifact = index,
                .other = 0,
                .field = "COMMANDS.global_commands",
            });
        }
    }

    fn compareField(self: *Context, field: []const u8, baseline: []const u8, candidate: []const u8, index: usize) !void {
        if (std.mem.eql(u8, baseline, candidate)) return;
        try self.add(.{
            .code = .common_field_mismatch,
            .artifact = index,
            .other = 0,
            .field = field,
        });
    }

    fn add(self: *Context, diagnostic: Diagnostic) !void {
        try self.diagnostics.append(self.allocator, diagnostic);
    }
};

fn parseMetadata(allocator: Allocator, document: *const toml.Document) ParseError!Metadata {
    const root = &document.root;
    const package = tableField(root, "package") orelse return error.InvalidInput;

    const id = stringField(package, "id") orelse return error.InvalidInput;
    const version = stringField(package, "version") orelse return error.InvalidInput;
    const license = stringField(package, "license") orelse return error.InvalidInput;

    const capabilities = try canonicalOptionalStringArray(allocator, package, "capabilities", null);
    const engines = try canonicalEngines(allocator, root);
    const exports = try canonicalExports(allocator, root);
    const features = try canonicalFeatures(allocator, root);
    const dependencies = try canonicalDependencies(allocator, root);

    const artifact = tableField(root, "artifact") orelse return error.InvalidInput;
    const kind = stringField(artifact, "kind") orelse return error.InvalidInput;
    const runtimes_value = artifact.getPtr("runtimes") orelse return error.InvalidInput;
    const runtimes_array = runtimes_value.asArray() orelse return error.InvalidInput;
    if (runtimes_array.items.len == 0) return error.InvalidInput;
    const runtimes = try canonicalStringValues(allocator, runtimes_array.items);

    var target_triple: ?[]const u8 = null;
    var abi_version: ?i64 = null;
    if (artifact.getPtr("native")) |native_value| {
        const native = native_value.asTable() orelse return error.InvalidInput;
        if (native.getPtr("target_triple")) |value| {
            target_triple = value.asString() orelse return error.InvalidInput;
        }
        if (native.getPtr("abi_version")) |value| {
            abi_version = switch (value.kind) {
                .integer => |integer| integer,
                else => return error.InvalidInput,
            };
        }
    }

    if (std.mem.eql(u8, kind, "universal") or std.mem.eql(u8, kind, "esm")) {
        // target は index 上 null。artifact.native は持たない。
        target_triple = null;
        abi_version = null;
    } else if (std.mem.eql(u8, kind, "native-source")) {
        if (abi_version == null) return error.InvalidInput;
        // ソース用の target_triple は不要。重複判定でも持たない。
        target_triple = null;
    } else if (std.mem.eql(u8, kind, "native-prebuilt")) {
        if (target_triple == null or abi_version == null) return error.InvalidInput;
    } else {
        return error.InvalidInput;
    }

    return .{
        .id = id,
        .version = version,
        .license = license,
        .capabilities = capabilities,
        .engines = engines,
        .exports = exports,
        .features = features,
        .dependencies = dependencies,
        .kind = kind,
        .runtimes = runtimes,
        .target_triple = target_triple,
        .abi_version = abi_version,
    };
}

fn parseCommands(allocator: Allocator, value: *const std.json.Value) ParseError!Commands {
    if (value.* != .object) return error.InvalidInput;
    const object = &value.object;

    const flag_value = object.getPtr("exports_global_commands") orelse return error.InvalidInput;
    const exports_global_commands = switch (flag_value.*) {
        .bool => |boolean| boolean,
        else => return error.InvalidInput,
    };

    const exports_value = object.getPtr("exports") orelse return error.InvalidInput;
    if (exports_value.* != .object) return error.InvalidInput;

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var has_global_entry = false;
    var iterator = exports_value.object.iterator();
    while (iterator.next()) |entry| {
        const export_value = entry.value_ptr;
        if (export_value.* != .object) return error.InvalidInput;

        const binding_value = export_value.object.getPtr("binding") orelse return error.InvalidInput;
        const binding = switch (binding_value.*) {
            .string => |text| text,
            else => return error.InvalidInput,
        };

        if (std.mem.eql(u8, binding, "global")) {
            has_global_entry = true;
            const commands_value = export_value.object.getPtr("commands") orelse return error.InvalidInput;
            if (commands_value.* != .array) return error.InvalidInput;
            for (commands_value.array.items) |command| {
                if (command != .object) return error.InvalidInput;
                const name_value = command.object.getPtr("name") orelse return error.InvalidInput;
                const name = switch (name_value.*) {
                    .string => |text| text,
                    else => return error.InvalidInput,
                };
                try names.append(allocator, name);
            }
        } else if (!std.mem.eql(u8, binding, "scoped")) {
            return error.InvalidInput;
        }
    }

    // §3.5: global の入口が一つでもある場合に限り true。
    if (exports_global_commands != has_global_entry) return error.InvalidInput;

    const global_names = try uniqueSortedStrings(allocator, names.items);
    const global_commands = try canonicalStringList(allocator, global_names);
    return .{
        .exports_global_commands = exports_global_commands,
        .global_commands = global_commands,
        .global_names = global_names,
    };
}

fn canonicalEngines(allocator: Allocator, root: *const std.StringHashMapUnmanaged(toml.Value)) ParseError![]const u8 {
    const value = root.getPtr("engines") orelse return canonicalStringList(allocator, &.{});
    const engines = value.asTable() orelse return error.InvalidInput;

    const Entry = struct { name: []const u8, range: []const u8 };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var iterator = engines.iterator();
    while (iterator.next()) |entry| {
        const range = entry.value_ptr.asString() orelse return error.InvalidInput;
        try entries.append(allocator, .{ .name = entry.key_ptr.*, .range = range });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendCount(&out, allocator, entries.items.len);
    for (entries.items) |entry| {
        try appendStringField(&out, allocator, entry.name);
        try appendStringField(&out, allocator, entry.range);
    }
    return out.toOwnedSlice(allocator);
}

fn canonicalExports(allocator: Allocator, root: *const std.StringHashMapUnmanaged(toml.Value)) ParseError![]const u8 {
    const value = root.getPtr("exports") orelse return canonicalStringList(allocator, &.{});
    const exports = value.asTable() orelse return error.InvalidInput;

    const Entry = struct { path: []const u8, entry: []const u8, binding: []const u8 };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var iterator = exports.iterator();
    while (iterator.next()) |item| {
        const export_table = item.value_ptr.asTable() orelse return error.InvalidInput;
        const entry = stringField(export_table, "entry") orelse return error.InvalidInput;
        const binding = if (export_table.getPtr("binding")) |binding_value| blk: {
            const text = binding_value.asString() orelse return error.InvalidInput;
            if (!std.mem.eql(u8, text, "scoped") and !std.mem.eql(u8, text, "global")) {
                return error.InvalidInput;
            }
            break :blk text;
        } else "scoped";

        try entries.append(allocator, .{
            .path = item.key_ptr.*,
            .entry = entry,
            .binding = binding,
        });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendCount(&out, allocator, entries.items.len);
    for (entries.items) |entry| {
        try appendStringField(&out, allocator, entry.path);
        try appendStringField(&out, allocator, entry.entry);
        try appendStringField(&out, allocator, entry.binding);
    }
    return out.toOwnedSlice(allocator);
}

fn canonicalFeatures(allocator: Allocator, root: *const std.StringHashMapUnmanaged(toml.Value)) ParseError![]const u8 {
    const value = root.getPtr("features") orelse return canonicalStringList(allocator, &.{});
    const features = value.asTable() orelse return error.InvalidInput;

    const Entry = struct { name: []const u8, members: []const u8 };
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    var iterator = features.iterator();
    while (iterator.next()) |item| {
        const members_value = item.value_ptr.asArray() orelse return error.InvalidInput;
        try entries.append(allocator, .{
            .name = item.key_ptr.*,
            .members = try canonicalStringValues(allocator, members_value.items),
        });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendCount(&out, allocator, entries.items.len);
    for (entries.items) |entry| {
        try appendStringField(&out, allocator, entry.name);
        try appendStringField(&out, allocator, entry.members);
    }
    return out.toOwnedSlice(allocator);
}

fn canonicalDependencies(allocator: Allocator, root: *const std.StringHashMapUnmanaged(toml.Value)) ParseError![]const u8 {
    const value = root.getPtr("dependencies") orelse return canonicalStringList(allocator, &.{});
    const array = value.asArray() orelse return error.InvalidInput;

    var entries: std.ArrayListUnmanaged([]const u8) = .empty;
    for (array.items) |*item| {
        const dependency = item.asTable() orelse return error.InvalidInput;
        try entries.append(allocator, try canonicalDependency(allocator, dependency));
    }
    return canonicalStringList(allocator, entries.items);
}

fn canonicalDependency(allocator: Allocator, table: *std.StringHashMapUnmanaged(toml.Value)) ParseError![]const u8 {
    const id = stringField(table, "id") orelse return error.InvalidInput;
    const req = stringField(table, "req") orelse return error.InvalidInput;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendStringField(&out, allocator, id);
    try appendStringField(&out, allocator, req);
    try appendCanonicalStringArrayField(&out, allocator, table, "features", null);
    try appendBoolField(&out, allocator, try boolField(table, "default_features", true));
    try appendBoolField(&out, allocator, try boolField(table, "optional", false));
    try appendCanonicalStringArrayField(&out, allocator, table, "runtimes", &default_runtimes);
    try appendOptionalStringField(&out, allocator, table, "alias");
    try appendBoolField(&out, allocator, try boolField(table, "allow_global_commands", false));
    return out.toOwnedSlice(allocator);
}

const default_runtimes = [_][]const u8{ "lnako", "cnako", "wnako" };

fn canonicalOptionalStringArray(
    allocator: Allocator,
    table: *std.StringHashMapUnmanaged(toml.Value),
    key: []const u8,
    default: ?[]const []const u8,
) ParseError![]const u8 {
    const value = table.getPtr(key) orelse {
        if (default) |items| return canonicalStringList(allocator, items);
        return canonicalStringList(allocator, &.{});
    };
    const array = value.asArray() orelse return error.InvalidInput;
    return canonicalStringValues(allocator, array.items);
}

fn appendCanonicalStringArrayField(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *std.StringHashMapUnmanaged(toml.Value),
    key: []const u8,
    default: ?[]const []const u8,
) ParseError!void {
    const canonical = try canonicalOptionalStringArray(allocator, table, key, default);
    try appendStringField(out, allocator, canonical);
}

fn canonicalStringValues(allocator: Allocator, values: []const toml.Value) ParseError![]const u8 {
    const texts = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |*value, index| {
        texts[index] = value.asString() orelse return error.InvalidInput;
    }
    return canonicalStringList(allocator, texts);
}

/// 文字列の集合を長さ接頭辞付きで正規化する。順序と重複は無視する。
fn canonicalStringList(allocator: Allocator, values: []const []const u8) Oom![]const u8 {
    const sorted = try allocator.dupe([]const u8, values);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var body: std.ArrayListUnmanaged(u8) = .empty;
    var count: usize = 0;
    var last: ?[]const u8 = null;
    for (sorted) |text| {
        if (last) |previous| {
            if (std.mem.eql(u8, previous, text)) continue;
        }
        last = text;
        count += 1;
        try appendStringField(&body, allocator, text);
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendCount(&out, allocator, count);
    try out.appendSlice(allocator, body.items);
    return out.toOwnedSlice(allocator);
}

fn uniqueSortedStrings(allocator: Allocator, values: []const []const u8) Oom![]const []const u8 {
    const sorted = try allocator.dupe([]const u8, values);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var count: usize = 0;
    for (sorted) |text| {
        if (count == 0 or !std.mem.eql(u8, sorted[count - 1], text)) {
            sorted[count] = text;
            count += 1;
        }
    }
    return sorted[0..count];
}

fn artifactKey(allocator: Allocator, metadata: Metadata) Oom![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendStringField(&out, allocator, metadata.kind);
    try appendStringField(&out, allocator, metadata.runtimes);
    try appendOptionalStringValue(&out, allocator, metadata.target_triple);
    try appendOptionalIntValue(&out, allocator, metadata.abi_version);
    return out.toOwnedSlice(allocator);
}

fn tableField(
    parent: *const std.StringHashMapUnmanaged(toml.Value),
    key: []const u8,
) ?*std.StringHashMapUnmanaged(toml.Value) {
    const value = parent.getPtr(key) orelse return null;
    return value.asTable();
}

fn stringField(table: *const std.StringHashMapUnmanaged(toml.Value), key: []const u8) ?[]const u8 {
    const value = table.getPtr(key) orelse return null;
    return value.asString();
}

fn boolField(table: *const std.StringHashMapUnmanaged(toml.Value), key: []const u8, default: bool) ParseError!bool {
    const value = table.getPtr(key) orelse return default;
    return switch (value.kind) {
        .boolean => |boolean| boolean,
        else => error.InvalidInput,
    };
}

fn appendOptionalStringField(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    table: *const std.StringHashMapUnmanaged(toml.Value),
    key: []const u8,
) Oom!void {
    try appendOptionalStringValue(out, allocator, stringField(table, key));
}

fn appendOptionalStringValue(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    value: ?[]const u8,
) Oom!void {
    if (value) |text| {
        try out.append(allocator, '+');
        try appendStringField(out, allocator, text);
    } else {
        try out.append(allocator, '-');
    }
}

fn appendOptionalIntValue(
    out: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    value: ?i64,
) Oom!void {
    if (value) |integer| {
        try out.append(allocator, '+');
        var buffer: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d};", .{integer}) catch unreachable;
        try out.appendSlice(allocator, text);
    } else {
        try out.append(allocator, '-');
    }
}

fn appendBoolField(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, value: bool) Oom!void {
    try out.append(allocator, if (value) 'T' else 'F');
}

fn appendCount(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, count: usize) Oom!void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}:", .{count}) catch unreachable;
    try out.appendSlice(allocator, text);
}

fn appendStringField(out: *std.ArrayListUnmanaged(u8), allocator: Allocator, text: []const u8) Oom!void {
    try appendCount(out, allocator, text.len);
    try out.appendSlice(allocator, text);
}
