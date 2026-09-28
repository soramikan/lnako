//! 依存解決の composite provider / details source。path/git/http で
//! 取得済みの local package（仮想 id）と registry の pkg 依存を
//! ひとつの resolver.Provider / lock_mod.DetailsSource へ合成する。
//! project.zig から分割した実装で、型は project 側の ResolveContext /
//! LocalPackage を参照する。

const std = @import("std");
const lock_mod = @import("lock.zig");
const lock_model = @import("lock_model.zig");
const project = @import("project.zig");
const registry = @import("registry.zig");
const resolver = @import("resolver.zig");

const Allocator = std.mem.Allocator;

fn isVirtualId(id_text: []const u8) bool {
    return std.mem.startsWith(u8, id_text, "path:") or
        std.mem.startsWith(u8, id_text, "git:") or
        std.mem.startsWith(u8, id_text, "http:");
}

pub const Composite = struct {
    ctx: *project.ResolveContext,
    registry: ?*registry.StaticRegistry,
    /// 解決対象 profile で source 実装のみ許容するか（any/common）。
    source_only: bool,
    locked_index: ?*const lock_mod.LockedIndex,
    /// `metaFromManifest` 用の profile target。
    target: resolver.Target,
    /// 解決中の profile 名。推移的 pkg 依存の `profile` 制約を
    /// `rootDeps` と同じ条件で絞るために使う。
    profile_name: []const u8 = "",

    pub fn provider(self: *Composite) resolver.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .listVersions = listVersions,
                .versionMeta = versionMeta,
                .lockedVersion = lockedVersion,
            },
        };
    }

    pub fn detailsSource(self: *Composite) lock_mod.DetailsSource {
        return .{ .context = self, .getFn = getDetails };
    }

    fn stripImpls(self: *const Composite, meta: *resolver.VersionMeta) void {
        if (!self.source_only) return;
        meta.has_native = false;
        meta.has_esm = false;
        if (!meta.has_source and meta.unavailable_reason == null) {
            meta.unavailable_reason = "package has no shared source implementation for an any/common profile";
        }
    }

    fn listVersions(ptr: *anyopaque, gpa: Allocator, id: resolver.PackageId) anyerror![]const resolver.Version {
        const self: *Composite = @ptrCast(@alignCast(ptr));
        const name = switch (id) {
            .pkg => |pkg| pkg,
            .npm => return error.PackageNotFound,
        };
        if (isVirtualId(name)) {
            const local = self.ctx.locals.get(name) orelse return error.PackageNotFound;
            const version = resolver.Version.parse(local.version_text) catch return error.PackageNotFound;
            const out = try gpa.alloc(resolver.Version, 1);
            out[0] = version;
            return out;
        }
        const reg = self.registry orelse return error.RegistryRequired;
        return reg.provider().listVersions(gpa, id);
    }

    fn versionMeta(ptr: *anyopaque, gpa: Allocator, id: resolver.PackageId, version: resolver.Version) anyerror!resolver.VersionMeta {
        const self: *Composite = @ptrCast(@alignCast(ptr));
        const name = switch (id) {
            .pkg => |pkg| pkg,
            .npm => return .{ .unavailable_reason = "npm dependencies are not resolved by the project resolver" },
        };
        if (isVirtualId(name)) {
            const local = self.ctx.locals.get(name) orelse
                return .{ .unavailable_reason = "dependency source was not acquired" };
            var meta: resolver.VersionMeta = undefined;
            if (local.manifest) |*dep_manifest| {
                meta = try resolver.metaFromManifest(gpa, dep_manifest, self.target);
                // any/common profile は cnako 環境へも materialize され得る
                // ので、lnako へ coerce した target だけでなく cnako
                // target にも照合する。`runtimes = ["lnako"]` だけの
                // package を受理して `sync --runtime cnako` で使えない
                // 環境を作らないため。
                if (self.source_only and meta.unavailable_reason == null) {
                    var cnako_target = self.target;
                    cnako_target.runtime = "cnako";
                    const cnako_meta = try resolver.metaFromManifest(gpa, dep_manifest, cnako_target);
                    if (cnako_meta.unavailable_reason) |reason| meta.unavailable_reason = reason;
                }
                // 推移的 pkg 辺を rootDeps と同じ条件で絞る。`dep.profile`
                // は現行 profile 名と一致する場合のみ有効で、feature-gated
                // で未 activated の宣言は除外する。metaFromManifest は両方
                // を評価しないため orchestration 側で落とす。
                if (meta.dependencies.len != 0) {
                    var kept: std.ArrayList(resolver.Dependency) = .empty;
                    for (meta.dependencies) |d| {
                        const decl = dep_manifest.dependencies.pkg.get(d.name) orelse {
                            try kept.append(gpa, d);
                            continue;
                        };
                        if (decl.profile) |p| {
                            if (!std.mem.eql(u8, p, self.profile_name)) continue;
                        }
                        if (project.depIsGated(&local.gated_deps, decl.name, decl.alias) and
                            !project.depIsActivated(&local.activated_deps, decl.name, decl.alias)) continue;
                        try kept.append(gpa, d);
                    }
                    meta.dependencies = kept.items;
                }
            } else {
                // manifest を持たない取得（raw http 等）は source 実装のみ。
                meta = .{ .has_source = true };
            }
            self.stripImpls(&meta);
            return meta;
        }
        const reg = self.registry orelse return error.RegistryRequired;
        var meta = try reg.provider().versionMeta(gpa, id, version);
        self.stripImpls(&meta);
        return meta;
    }

    fn lockedVersion(ptr: *anyopaque, id: resolver.PackageId) ?resolver.Version {
        const self: *Composite = @ptrCast(@alignCast(ptr));
        if (isVirtualId(switch (id) {
            .pkg => |pkg| pkg,
            .npm => return null,
        })) return null;
        const index = self.locked_index orelse return null;
        return index.get(id);
    }

    fn getDetails(context: *anyopaque, gpa: Allocator, id: []const u8, version: []const u8) anyerror!?lock_mod.PackageDetails {
        const self: *Composite = @ptrCast(@alignCast(context));
        if (isVirtualId(id)) {
            const local = self.ctx.locals.get(id) orelse return null;
            const artifacts = try gpa.alloc(lock_model.Artifact, 1);
            artifacts[0] = local.artifact;
            return .{
                .public_id = local.public_id,
                .name = local.package_name,
                .source = local.source,
                .artifacts = artifacts,
            };
        }
        const reg = self.registry orelse return null;
        return reg.detailsSource().get(gpa, id, version);
    }
};
