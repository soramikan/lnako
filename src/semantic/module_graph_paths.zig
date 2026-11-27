//! 取り込みパス解決と package 境界判定。

const std = @import("std");
const module_graph = @import("module_graph.zig");

const GlobalCommand = module_graph.GlobalCommand;
const PackageResolver = module_graph.PackageResolver;
const LoadedModule = module_graph.LoadedModule;
const Loader = module_graph.Loader;

pub fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.path.resolve(allocator, &.{path});
}

pub fn isNativePluginExtension(extension: []const u8) bool {
    return std.ascii.eqlIgnoreCase(extension, ".dylib") or
        std.ascii.eqlIgnoreCase(extension, ".so") or
        std.ascii.eqlIgnoreCase(extension, ".dll");
}

pub fn isPackageSpecifier(requested: []const u8) bool {
    return std.mem.startsWith(u8, requested, "パッケージ:") or std.mem.startsWith(u8, requested, "pkg:");
}

pub const ResolvedImport = struct {
    path: []u8,
    canonical_id: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    dispatch_namespace: ?[]const u8 = null,
    package_root: ?[]const u8 = null,
    package_owner: ?[]const u8 = null,
    export_subpath: ?[]const u8 = null,
    global_commands: []const GlobalCommand = &.{},
};

pub fn resolveRequestedImport(allocator: std.mem.Allocator, importer: []const u8, importer_owner: ?[]const u8, requested: []const u8, package_resolver: ?PackageResolver) !ResolvedImport {
    if (!isPackageSpecifier(requested)) return .{ .path = try resolveImport(allocator, importer, requested) };
    const resolver = package_resolver orelse return error.PackageResolverUnavailable;
    const selected = try resolver.resolve(allocator, importer, importer_owner, requested);
    return .{ .path = try normalizePath(allocator, selected.path), .canonical_id = selected.canonical_id, .namespace = selected.namespace, .dispatch_namespace = selected.dispatch_namespace, .package_root = selected.package_root, .package_owner = selected.package_owner, .export_subpath = selected.export_subpath, .global_commands = selected.global_commands };
}

/// Lexical containment of `path` strictly inside `root`. Both sides are
/// canonicalized or lexically resolved before comparison by the callers.
pub fn pathWithinRoot(root: []const u8, path: []const u8) bool {
    // 空rootは任意pathのprefixに一致して境界を無効化するため拒否する。
    if (root.len == 0) return false;
    if (!std.mem.startsWith(u8, path, root) or path.len <= root.len) return false;
    return path[root.len] == std.fs.path.sep;
}

/// canonical export・相対子孫を含むpackage所有のmoduleか。owner key未設定でも
/// package root内のmoduleは外部から修飾名で到達させないpackage内容とする。
pub fn moduleIsPackageContent(module: *const LoadedModule) bool {
    return module.canonical_id != null or module.package_owner != null or module.package_root != null;
}

/// Ownership a package module passes to a relative descendant that stays inside
/// its canonical root. Unrooted importers and escaped paths propagate nothing.
/// owner が無いmodule（旧formatのembedded payload等）でもrootは継承する —
/// 継承を失うと孫module以降のcanonical root包含検査が丸ごと消えるため。
pub fn descendantInheritance(module: *LoadedModule, path: []const u8) ?Loader.PackageInheritance {
    const root = module.package_root orelse return null;
    if (!pathWithinRoot(root, path)) return null;
    return .{ .root = root, .owner = module.package_owner };
}

pub fn resolveImport(allocator: std.mem.Allocator, importer: []const u8, requested: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, requested, ':') != null and !std.fs.path.isAbsolute(requested)) return error.UnsupportedImport;
    if (std.fs.path.isAbsolute(requested)) return normalizePath(allocator, requested);
    return std.fs.path.resolve(allocator, &.{ std.fs.path.dirname(importer) orelse ".", requested });
}
