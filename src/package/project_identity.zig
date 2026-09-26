//! Project package sources: declaration-to-lock identity helpers.
const std = @import("std");
const builtin = @import("builtin");
const fetch = @import("fetch.zig");
const lock_model = @import("lock_model.zig");
const manifest_mod = @import("manifest.zig");
const provider = @import("provider.zig");

const Allocator = std.mem.Allocator;
pub const Error = error{ FileSystem, OutOfMemory, ResolveFailed };

/// A source dependency declaration as represented by the project manifest.
pub const SourceDecl = union(enum) {
    path: manifest_mod.PathDependency,
    git: manifest_mod.GitDependency,
    http: manifest_mod.HttpDependency,
};

/// Convert only the host-native separator in a project-relative spelling to
/// `/`. On POSIX, backslashes are valid filename characters and stay intact.
fn normalizeProjectRelativePath(gpa: Allocator, path: []const u8, native_sep: u8) Error![]const u8 {
    if (native_sep == '/') return gpa.dupe(u8, path);
    const normalized = try gpa.dupe(u8, path);
    for (@constCast(normalized)) |*char| {
        if (char.* == native_sep) char.* = '/';
    }
    return normalized;
}

/// Fold a path into its identity form: native separators become `/` and, on
/// Windows (case-insensitive filesystems), ASCII letters are lowercased so
/// that `deps/lib` and `DEPS/lib` refer to the same identity. POSIX paths
/// are returned verbatim because case and backslashes are significant.
fn identityFoldedPath(gpa: Allocator, path: []const u8, windows_fs: bool) Error![]const u8 {
    const sep: u8 = if (windows_fs) '\\' else '/';
    const normalized = try normalizeProjectRelativePath(gpa, path, sep);
    if (!windows_fs) return normalized;
    for (@constCast(normalized)) |*char| char.* = std.ascii.toLower(char.*);
    return normalized;
}

fn canonicalPathForId(gpa: Allocator, declared: []const u8, base_dir: ?[]const u8, project_root: []const u8) Error![]const u8 {
    return canonicalPathForIdOs(gpa, declared, base_dir, project_root, builtin.os.tag == .windows);
}

/// Resolve a declared path against its manifest directory and return a
/// project-relative spelling when it remains inside the project.
fn canonicalPathForIdOs(gpa: Allocator, declared: []const u8, base_dir: ?[]const u8, project_root: []const u8, windows_fs: bool) Error![]const u8 {
    const abs = if (provider.isAbsoluteDepPath(declared))
        std.fs.path.resolve(gpa, &.{declared}) catch return error.FileSystem
    else
        std.fs.path.resolve(gpa, &.{ base_dir orelse project_root, declared }) catch return error.FileSystem;
    defer gpa.free(abs);
    const root = std.fs.path.resolve(gpa, &.{project_root}) catch return error.FileSystem;
    defer gpa.free(root);
    // On Windows the same directory can be spelled `DEPS\lib` or `deps\lib`;
    // fold case and separators before the containment check and in the
    // returned identity so spelling alone cannot fork a public package ID.
    const abs_norm = try identityFoldedPath(gpa, abs, windows_fs);
    defer gpa.free(abs_norm);
    const root_norm = try identityFoldedPath(gpa, root, windows_fs);
    defer gpa.free(root_norm);
    if (std.mem.startsWith(u8, abs_norm, root_norm) and abs_norm.len > root_norm.len and
        abs_norm[root_norm.len] == '/')
    {
        return gpa.dupe(u8, abs_norm[root_norm.len + 1 ..]);
    }
    return gpa.dupe(u8, abs_norm);
}

pub fn canonicalHttpHash(gpa: Allocator, text: []const u8) ![]const u8 {
    if (fetch.normalizeSha256(text)) |digest| {
        return std.fmt.allocPrint(gpa, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    }
    if (fetch.normalizeSha512(text)) |digest| {
        return std.fmt.allocPrint(gpa, "sha512:{s}", .{std.fmt.bytesToHex(digest, .lower)});
    }
    return gpa.dupe(u8, text);
}

/// Form the solver identity from the acquired, canonical source pin.
pub fn virtualIdForResolvedSource(gpa: Allocator, source: lock_model.Source, project_root: []const u8) Error![]const u8 {
    var canonical = source;
    if (canonical.kind == .path) {
        canonical.path = try canonicalPathForId(gpa, canonical.path orelse return error.ResolveFailed, null, project_root);
    } else if (canonical.kind == .http) {
        canonical.hash = try canonicalHttpHash(gpa, canonical.hash orelse return error.ResolveFailed);
    }
    return provider.identityText(gpa, canonical);
}

fn virtualIdForDecl(gpa: Allocator, decl: SourceDecl, base_dir: ?[]const u8, project_root: []const u8) Error![]const u8 {
    const identity_source: lock_model.Source = switch (decl) {
        .path => |dep| .{ .kind = .path, .path = try canonicalPathForId(gpa, dep.path, base_dir, project_root) },
        .git => |dep| .{ .kind = .git, .url = dep.url, .commit = dep.commit, .path = dep.path },
        .http => |dep| .{ .kind = .http, .url = dep.url, .hash = dep.hash },
    };
    return provider.identityText(gpa, identity_source);
}

fn publicIdFor(gpa: Allocator, id_text: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id_text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(gpa, "pkg:{s}", .{hex[0..32]});
}

/// Provisional ID from a declaration spelling; lock lookups must use the package-matching helper below.
pub fn publicIdForSourceDecl(gpa: Allocator, decl: SourceDecl, base_dir: ?[]const u8, project_root: []const u8) Error![]const u8 {
    return publicIdFor(gpa, try virtualIdForDecl(gpa, decl, base_dir, project_root));
}

/// Match a manifest declaration to its resolved lock source and return that canonical public ID.
pub fn publicIdForSourceDeclInPackages(gpa: Allocator, decl: SourceDecl, base_dir: ?[]const u8, project_root: []const u8, packages: []const lock_model.PackageEntry) Error!?[]const u8 {
    for (packages) |entry| {
        const source = entry.source orelse continue;
        const matches = switch (decl) {
            .path => |dep| blk: {
                if (source.kind != .path) break :blk false;
                const declared = try canonicalPathForId(gpa, dep.path, base_dir, project_root);
                const locked = try canonicalPathForId(gpa, source.path orelse break :blk false, null, project_root);
                break :blk std.mem.eql(u8, declared, locked);
            },
            .git => |dep| source.kind == .git and
                std.mem.eql(u8, source.url orelse "", dep.url) and
                std.mem.eql(u8, source.path orelse "", dep.path orelse "") and
                std.mem.startsWith(u8, source.commit orelse "", dep.commit),
            .http => |dep| source.kind == .http and
                std.mem.eql(u8, source.url orelse "", dep.url) and
                provider.sourceHashEql(source.hash, dep.hash),
        };
        if (matches) return try gpa.dupe(u8, entry.id);
    }
    return null;
}

test "project-relative path IDs use slash spelling across host separators" {
    const gpa = std.testing.allocator;
    const windows_path = try normalizeProjectRelativePath(gpa, "packages\\demo", '\\');
    defer gpa.free(windows_path);
    const posix_path = try normalizeProjectRelativePath(gpa, "packages/demo", '/');
    defer gpa.free(posix_path);

    const windows_text = try provider.identityText(gpa, .{ .kind = .path, .path = windows_path });
    defer gpa.free(windows_text);
    const posix_text = try provider.identityText(gpa, .{ .kind = .path, .path = posix_path });
    defer gpa.free(posix_text);
    const windows_id = try publicIdFor(gpa, windows_text);
    defer gpa.free(windows_id);
    const posix_id = try publicIdFor(gpa, posix_text);
    defer gpa.free(posix_id);
    try std.testing.expectEqualStrings(posix_id, windows_id);

    // Backslash is an ordinary character in POSIX filenames, not a separator.
    const posix_filename = try normalizeProjectRelativePath(gpa, "packages\\demo", '/');
    defer gpa.free(posix_filename);
    try std.testing.expectEqualStrings("packages\\demo", posix_filename);
}

test "windows identity folds path case and separators" {
    const gpa = std.testing.allocator;
    // Same directory spelled `DEPS/lib` vs `deps/lib` (and absolute forms
    // differing only by case) must collapse to one identity on Windows.
    const upper = try canonicalPathForIdOs(gpa, "DEPS/lib", null, "/proj", true);
    defer gpa.free(upper);
    const lower = try canonicalPathForIdOs(gpa, "deps/lib", null, "/proj", true);
    defer gpa.free(lower);
    try std.testing.expectEqualStrings("deps/lib", upper);
    try std.testing.expectEqualStrings("deps/lib", lower);
    const upper_abs = try canonicalPathForIdOs(gpa, "/PROJ/DEPS/lib", null, "/Proj", true);
    defer gpa.free(upper_abs);
    try std.testing.expectEqualStrings("deps/lib", upper_abs);

    // Outside the project root the folded absolute path is still stable
    // across case-only respellings.
    const ext_a = try canonicalPathForIdOs(gpa, "/Elsewhere/Lib", null, "/proj", true);
    defer gpa.free(ext_a);
    const ext_b = try canonicalPathForIdOs(gpa, "/elsewhere/lib", null, "/proj", true);
    defer gpa.free(ext_b);
    try std.testing.expectEqualStrings(ext_b, ext_a);

    // POSIX keeps case and backslashes significant. The POSIX-mode branch
    // still resolves with host separators, so it is only meaningful on a
    // POSIX host.
    if (builtin.os.tag != .windows) {
        const posix = try canonicalPathForIdOs(gpa, "DEPS/lib", null, "/proj", false);
        defer gpa.free(posix);
        try std.testing.expectEqualStrings("DEPS/lib", posix);
        const posix_abs = try canonicalPathForIdOs(gpa, "/PROJ/DEPS/lib", null, "/Proj", false);
        defer gpa.free(posix_abs);
        try std.testing.expectEqualStrings("/PROJ/DEPS/lib", posix_abs);
    }
}
