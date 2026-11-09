//! `lnako check --load-plugins` の実登録照合入力の組み立て（Issue #52）。
//!
//! `.nako/environment.json` の package 記録から、宣言命令 metadata と
//! plugin artifact（native/ESM）を解決し、`plugin_registration.inspect` へ渡す。
//! artifact は package dir 配下へ字句解決し、ESM は module source も読む
//! （cwd 相対の dlopen/評価による path confusion を避ける）。

const std = @import("std");
const lnako = @import("lnako");

const Allocator = std.mem.Allocator;

/// `--load-plugins` 照合で「一致」と判定された package 数。
pub fn matchedPackageCount(report: *const lnako.package.plugin_registration.Report) usize {
    var count: usize = 0;
    for (report.packages) |*package| {
        if (package.inspected) count += 1;
    }
    return count;
}

/// plugin 実登録照合の入力を environment.json から組み立て、`--load-plugins`
/// 照合を実行する。plugin artifact は環境記録の `exports` から解決する:
/// native artifact（`.so`/`.dylib`/`.dll`/`.node`）は native plugin、
/// JS artifact（`.js`/`.mjs`/`.cjs`）または `esm` 宣言は ESM plugin。
/// 宣言命令の無い package・plugin を持たない package は照合対象外として
/// `status` に記録し、不一致とは扱わない。
pub fn runPluginRegistrationCheck(
    gpa: Allocator,
    io: std.Io,
    project_var: *const lnako.package.project.Project,
    options: lnako.package.plugin_registration.Options,
) !lnako.package.plugin_registration.Report {
    // 入力の文字列は inspect が自前 arena へ写すまで生きている必要がある。
    // ループ内で free すると inspect が解放済みメモリを読む（use-after-free）。
    // 一時 arena に確保し、inspect 完了後にまとめて解放する。
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    const env_rel = ".nako/" ++ lnako.package.environment.environment_file;
    const bytes = project_var.root_dir.readFileAlloc(io, env_rel, a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.Failed,
    };
    var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.Failed,
    };
    if (parsed.value != .object) return error.Failed;
    const packages_value = parsed.value.object.get("packages") orelse return error.Failed;
    if (packages_value != .object) return error.Failed;

    var inputs: std.ArrayList(lnako.package.plugin_registration.PackageInput) = .empty;
    var it = packages_value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const record = entry.value_ptr.*.object;
        const path_value = record.get("path") orelse continue;
        if (path_value != .string) continue;

        // package dir は project root 相対。artifact は必ずこの dir 配下へ
        // 解決する（cwd 相対の dlopen/評価を避ける path confusion 対策）。
        const package_dir = try std.fs.path.join(a, &.{ project_var.root, path_value.string });

        // 宣言命令 metadata。環境の索引に無い package は未検査として渡す。
        const parsed_list = try lnako.package.npkg_commands.parseList(a, record.get("commands"));
        const declared: ?[]const lnako.package.npkg_commands.Command =
            if (parsed_list.complete and parsed_list.commands.len > 0) parsed_list.commands else null;

        // plugin artifact は exports の全件を対象にする（複数 export が別々の
        // 命令を登録する構成で、最後の 1 件だけを見ると他を未登録と誤診断する）。
        var artifacts: std.ArrayList(lnako.package.plugin_registration.ArtifactInput) = .empty;
        if (record.get("exports")) |exports_value| {
            if (exports_value == .array) {
                for (exports_value.array.items) |item| {
                    if (item != .object) continue;
                    const is_native = if (item.object.get("native")) |v| artifactPathFromDecl(v) else null;
                    const is_esm = if (item.object.get("esm")) |v| artifactPathFromDecl(v) else null;
                    const plain = if (item.object.get("path")) |v| (if (v == .string) v.string else null) else null;

                    const relative: ?[]const u8 = is_native orelse is_esm orelse blk: {
                        const path = plain orelse break :blk null;
                        if (lnako.package.npkg_commands_gen.isNativePluginArtifact(path)) break :blk path;
                        if (isJsArtifactPath(path)) break :blk path;
                        break :blk null;
                    };
                    const relative_path = relative orelse continue;
                    // native 宣言があれば native、無ければ JS/ESM として扱う。
                    const use_esm = is_native == null and (is_esm != null or isJsArtifactPath(relative_path));

                    try artifacts.append(a, .{
                        .path = try resolveArtifact(a, io, project_var, package_dir, relative_path, use_esm),
                        .esm = use_esm,
                    });
                }
            }
        }

        // namespace は package import の alias から導出し、宣言名と実登録名を
        // 同じ公開名空間（`{ns}__{name}`）で比較できるようにする。
        const namespace = try lnako.package.import_resolver.namespaceFor(
            a,
            try packageNamespaceAlias(a, entry.key_ptr.*),
            null,
        );
        try inputs.append(a, .{
            .package_key = entry.key_ptr.*,
            .path = path_value.string,
            .declared = declared,
            .artifacts = try artifacts.toOwnedSlice(a),
            .package_root = package_dir,
            .namespace = namespace,
        });
    }

    // inspect は自前 arena へ写すため、ここで scratch を落としてよい。
    return lnako.package.plugin_registration.inspect(gpa, inputs.items, options);
}

/// artifact の相対 path を絶対 path へ解決する。package dir 外を指す宣言は
/// 空（未解決）として扱い、inspect 側で not_plugin に分類させる。
fn resolveArtifact(
    a: Allocator,
    io: std.Io,
    project_var: *const lnako.package.project.Project,
    package_dir: []const u8,
    relative: []const u8,
    esm: bool,
) !?lnako.package.plugin_registration.ArtifactInput.Path {
    const abs = std.fs.path.join(a, &.{ package_dir, relative }) catch return null;
    if (!pathIsWithin(package_dir, abs)) return null;
    const source: ?[]const u8 = if (esm)
        project_var.root_dir.readFileAlloc(io, abs, a, .limited(8 * 1024 * 1024)) catch null
    else
        null;
    return .{ .path = abs, .source = source };
}

/// `child` が `root` 配下（同一 path 境界）にあるか。字句比較のみで、
/// 実体の realpath 検証は呼出し側の package 所有権検査に委ねる。
fn pathIsWithin(root: []const u8, child: []const u8) bool {
    if (!std.mem.startsWith(u8, child, root)) return false;
    if (child.len == root.len) return true;
    return child[root.len] == std.fs.path.sep;
}

/// package key から namespace alias を導く。環境の package key は
/// `pkg:<alias>` か `<name>@<version>` 形式。`pkg:` 前置はそのまま alias、
/// それ以外は key を alias として扱う（`namespaceFor` が正規化する）。
fn packageNamespaceAlias(a: Allocator, package_key: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, package_key, "pkg:")) return a.dupe(u8, package_key[4..]);
    const at = std.mem.indexOfScalar(u8, package_key, '@') orelse return a.dupe(u8, package_key);
    return a.dupe(u8, package_key[0..at]);
}

/// export 記録の `native`/`esm` artifact 宣言から相対 path を取り出す。
/// 文字列形式（`native = { path = "..." }` の TOML は環境 JSON では
/// object）と path key の双方を受理する。解決できない宣言は null。
fn artifactPathFromDecl(value: std.json.Value) ?[]const u8 {
    if (value == .string) return value.string;
    if (value != .object) return null;
    // OS 条件付き配列の最初の path も artifact path として受理する
    // （照合時点で target 適合の絞込みは静的検査側の conditions 表示に委ね、
    // ここでは「どの artifact が plugin 実体か」の判定だけを行う）。
    if (value.object.get("path")) |path| {
        if (path == .string) return path.string;
    }
    return null;
}

/// export `path` が JS/ESM artifact か（`command_inspect.isJsArtifact` と
/// 同一規則）。
fn isJsArtifactPath(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    return std.ascii.eqlIgnoreCase(extension, ".js") or
        std.ascii.eqlIgnoreCase(extension, ".mjs") or
        std.ascii.eqlIgnoreCase(extension, ".cjs");
}
