//! Project package sources: declaration-to-lock identity helpers.
const std = @import("std");
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

/// Resolve a declared path against its manifest directory and return a
/// project-relative spelling when it remains inside the project.
fn canonicalPathForId(gpa: Allocator, declared: []const u8, base_dir: ?[]const u8, project_root: []const u8) Error![]const u8 {
    const abs = if (provider.isAbsoluteDepPath(declared))
        std.fs.path.resolve(gpa, &.{declared}) catch return error.FileSystem
    else
        std.fs.path.resolve(gpa, &.{ base_dir orelse project_root, declared }) catch return error.FileSystem;
    errdefer gpa.free(abs);
    const root = std.fs.path.resolve(gpa, &.{project_root}) catch return error.FileSystem;
    defer gpa.free(root);
    if (std.mem.startsWith(u8, abs, root) and abs.len > root.len and
        (abs[root.len] == '/' or abs[root.len] == std.fs.path.sep))
    {
        const rel = try gpa.dupe(u8, abs[root.len + 1 ..]);
        gpa.free(abs);
        return rel;
    }
    return abs;
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
