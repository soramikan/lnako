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
    a: Allocator,
    io: std.Io,
    project_var: *const lnako.package.project.Project,
    options: lnako.package.plugin_registration.Options,
) !lnako.package.plugin_registration.Report {
    // environment.json を読み、package 記録ごとに照合入力を組み立てる。
    // `path` を解決できない package は照合対象外（load_failed にしない）。
    const env_rel = ".nako/" ++ lnako.package.environment.environment_file;
    const bytes = project_var.root_dir.readFileAlloc(io, env_rel, a, .limited(32 * 1024 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.Failed,
    };
    defer a.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.Failed,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.Failed;
    const packages_value = parsed.value.object.get("packages") orelse return error.Failed;
    if (packages_value != .object) return error.Failed;

    var inputs: std.ArrayList(lnako.package.plugin_registration.PackageInput) = .empty;
    defer inputs.deinit(a);
    var it = packages_value.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const record = entry.value_ptr.*.object;
        const path_value = record.get("path") orelse continue;
        if (path_value != .string) continue;

        // package dir は project root 相対。artifact は必ずこの dir 配下へ
        // 解決する（cwd 相対の dlopen/評価を避ける path confusion 対策）。
        const package_dir = try std.fs.path.join(a, &.{ project_var.root, path_value.string });
        defer a.free(package_dir);

        // plugin artifact の解決。exports 配下から native/JS artifact を探す。
        var artifact_rel: ?[]const u8 = null;
        var esm = false;
        if (record.get("exports")) |exports_value| {
            if (exports_value == .array) {
                for (exports_value.array.items) |item| {
                    if (item != .object) continue;
                    if (item.object.get("native")) |native_value| {
                        if (artifactPathFromDecl(native_value)) |path| {
                            artifact_rel = path;
                            esm = false;
                        }
                    }
                    if (item.object.get("esm")) |esm_value| {
                        if (artifactPathFromDecl(esm_value)) |path| {
                            artifact_rel = path;
                            esm = true;
                        }
                    }
                    if (item.object.get("path")) |path_value_inner| {
                        if (path_value_inner != .string) continue;
                        const path = path_value_inner.string;
                        if (lnako.package.npkg_commands_gen.isNativePluginArtifact(path)) {
                            artifact_rel = path;
                            esm = false;
                        } else if (isJsArtifactPath(path)) {
                            artifact_rel = path;
                            esm = true;
                        }
                    }
                }
            }
        }

        // 宣言命令 metadata。環境の索引に無い package は未検査として渡す。
        const parsed_list = try lnako.package.npkg_commands.parseList(a, record.get("commands"));
        const declared: ?[]const lnako.package.npkg_commands.Command =
            if (parsed_list.complete and parsed_list.commands.len > 0) parsed_list.commands else null;

        // artifact を絶対 path へ解決し、ESM は module source も読む。
        // 解決できない（root 外・存在しない）場合は plugin 無しとして渡し、
        // inspect 側で not_plugin / load_failed に分類させる。
        var artifact_abs: ?[]const u8 = null;
        var esm_source: ?[]const u8 = null;
        if (artifact_rel) |relative| {
            const joined = std.fs.path.join(a, &.{ package_dir, relative }) catch null;
            if (joined) |abs| {
                defer a.free(abs);
                // package dir 配下に留まることを字句で確認する。
                if (pathIsWithin(package_dir, abs)) {
                    artifact_abs = try a.dupe(u8, abs);
                    if (esm) {
                        esm_source = a.dupe(u8, project_var.root_dir.readFileAlloc(io, abs, a, .limited(8 * 1024 * 1024)) catch "") catch null;
                        if (esm_source) |source| {
                            if (source.len == 0) {
                                a.free(source);
                                esm_source = null;
                            }
                        }
                    }
                } else {
                    a.free(abs);
                }
            }
        }
        defer if (artifact_abs) |abs| a.free(abs);
        defer if (esm_source) |source| a.free(source);

        // plugin を持たない・宣言命令の無い package は `status` で区分する
        // ため、そのまま渡す（inspect 側で分類する）。
        const namespace = try lnako.package.import_resolver.namespaceFor(
            a,
            try packageNamespaceAlias(a, entry.key_ptr.*),
            null,
        );
        defer a.free(namespace);
        try inputs.append(a, .{
            .package_key = entry.key_ptr.*,
            .path = path_value.string,
            .declared = declared,
            .plugin_artifact = artifact_abs,
            .esm_source = esm_source,
            .package_root = package_dir,
            .esm = esm,
            .namespace = namespace,
        });
    }

    return lnako.package.plugin_registration.inspect(a, inputs.items, options);
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
