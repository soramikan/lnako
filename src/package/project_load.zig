//! `nako.toml` プロジェクトの検出・読込。
//!
//! `load`/`loadFromDir` は読込時に project root の dir handle を pin し、
//! 以後の manifest/lock アクセスはその handle 相対に行う。これにより
//! 読込後に `root` path が rename/置換されても、保持中の project が
//! 別 dir の manifest・lock を参照・改変することはない。
//! `project.zig` から分離した読込系で、`project.zig` は再エクスポート
//! するため呼出し側は従来どおり `project.X` で参照できる。

const std = @import("std");
const diag = @import("diagnostics.zig");
const manifest_mod = @import("manifest.zig");
const project = @import("project.zig");

const Allocator = std.mem.Allocator;

const Error = project.Error;
const mapFs = project.mapFs;
const manifest_name = project.manifest_name;

// ---------------------------------------------------------------------------
// プロジェクト検出・読込
// ---------------------------------------------------------------------------

/// `nako.toml` を持つプロジェクト。全メモリは内蔵 arena が所有する。
/// arena はヒープ上に確保する。内部オブジェクト（`manifest.document` の
/// arena 等）の child_allocator が arena 自身を指すため、スタック上の
/// arena を返すと関数 return 後に dangling pointer になる。
pub const Project = struct {
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    /// プロジェクトルートの絶対 path（末尾 separator なし）。
    root: []const u8,
    /// `root` の pinned handle。`root` path が rename/置換されてもこの
    /// handle は同じ dir を指し続けるため、manifest・lock の読書きは
    /// path 再解決を挟まず handle 相対に行う。
    root_dir: std.Io.Dir,
    manifest_path: []const u8,
    manifest_bytes: []const u8,
    /// `sha256:<64hex>`。`lock.Input.manifest_sha256` と同じ表現。
    manifest_sha256: []const u8,
    manifest: manifest_mod.Manifest,

    pub fn deinit(self: *Project) void {
        self.manifest.deinit();
        self.root_dir.close(self.io);
        const arena = self.arena;
        const gpa = arena.child_allocator;
        arena.deinit();
        gpa.destroy(arena);
        self.* = undefined;
    }
};

/// `start_dir` から親 dir へ `nako.toml` を探す。見つかった dir の絶対
/// path を `gpa` で返す。見つからなければ null。`start_dir` は存在する
/// dir を想定（存在しない場合は FileSystem 相当の error を返す）。
pub fn findRoot(gpa: Allocator, io: std.Io, start_dir: []const u8) Error!?[]const u8 {
    var dir = try absPath(gpa, io, start_dir);
    defer gpa.free(dir);
    while (true) {
        const candidate = try std.fs.path.join(gpa, &.{ dir, manifest_name });
        defer gpa.free(candidate);
        const candidate_stat = std.Io.Dir.cwd().statFile(io, candidate, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return mapFs(err),
        };
        if (candidate_stat) |stat| {
            if (stat.kind != .file) return error.InvalidManifest;
            // symlink 経由で見つけた実在 root は realPath で固定する。
            // alias 側の綴りが残ると依存 identity・lock が実行入口ごとに
            // 分かれる（lexical 正規化は非実在 path 用の init でのみ使う）。
            // sentinel 付き確保なので、API の非 sentinel slice へ写し直す。
            const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, dir, gpa) catch |err| return mapFs(err);
            defer gpa.free(resolved);
            return try gpa.dupe(u8, resolved);
        }
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null;
        const next = try gpa.dupe(u8, parent);
        gpa.free(dir);
        dir = next;
    }
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// 相対 path を cwd 基準の絶対 path へ正規化する。実在しない成分を含んで
/// いてもよい（lexical 正規化のみ）。
fn absPath(gpa: Allocator, io: std.Io, path: []const u8) Error![]const u8 {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.path.resolve(gpa, &.{path}) catch return error.FileSystem;
    }
    const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa) catch |err| return mapFs(err);
    defer gpa.free(cwd);
    return std.fs.path.resolve(gpa, &.{ cwd, path }) catch return error.FileSystem;
}

/// `root`（`nako.toml` を持つ dir）のプロジェクトを読み込む。
pub fn load(gpa: Allocator, io: std.Io, root: []const u8, diagnostics: *diag.List) Error!Project {
    const root_lexical = try absPath(gpa, io, root);
    defer gpa.free(root_lexical);
    // 実在 root は realPath に正規化して symlink alias の綴り違いで
    // project identity が揺れないようにする。
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, root_lexical, gpa) catch |err| switch (err) {
        error.FileNotFound => return error.ProjectNotFound,
        else => return mapFs(err),
    };
    defer gpa.free(resolved);
    const root_abs = try gpa.dupe(u8, resolved);
    defer gpa.free(root_abs);
    // 読込時に dir handle を pin する。以後の manifest/lock アクセスは
    // この handle 相対に行い、`root` path が rename/置換されても
    // 別 dir の manifest・lock は参照・改変しない。
    const root_dir = std.Io.Dir.cwd().openDir(io, root_abs, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.ProjectNotFound,
        else => return mapFs(err),
    };
    // 所有権は `loadFromDir` が引き継ぎ、失敗時もそこで close される。
    return loadFromDir(gpa, io, root_abs, root_dir, diagnostics);
}

/// `root`（canonical 済みの絶対 path）とその pinned handle から読み込む。
/// 呼出し側は `root_dir` の所有権を手放し、成功時は返却 `Project`・
/// 失敗時はこの関数が close する。manifest の読込・解析は handle 相対に
/// 行うため、path の rename/置換では別 dir の manifest を読まない。
pub fn loadFromDir(gpa: Allocator, io: std.Io, root: []const u8, root_dir: std.Io.Dir, diagnostics: *diag.List) Error!Project {
    var owned_dir = root_dir;
    errdefer owned_dir.close(io);
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    const a = arena.allocator();

    const root_abs = try a.dupe(u8, root);
    const manifest_path = try std.fs.path.join(a, &.{ root_abs, manifest_name });
    const bytes = owned_dir.readFileAlloc(io, manifest_name, a, .limited(manifest_mod.max_manifest_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.ProjectNotFound,
        else => return mapFs(err),
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const sha_text = try std.fmt.allocPrint(a, "sha256:{s}", .{std.fmt.bytesToHex(digest, .lower)});

    const errors_before = diagnostics.errorCount();
    var manifest = manifest_mod.parse(a, bytes, diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidManifest,
    };
    errdefer manifest.deinit();
    // errorCount は累積のため、この parse が追加した分だけを見る。
    if (diagnostics.errorCount() > errors_before) return error.InvalidManifest;

    return .{
        .arena = arena,
        .io = io,
        .root = root_abs,
        .root_dir = owned_dir,
        .manifest_path = manifest_path,
        .manifest_bytes = bytes,
        .manifest_sha256 = sha_text,
        .manifest = manifest,
    };
}

/// `start_dir` から `nako.toml` を遡ってプロジェクトを読み込む。
/// 見つからなければ null。
pub fn discoverAndLoad(gpa: Allocator, io: std.Io, start_dir: []const u8, diagnostics: *diag.List) Error!?Project {
    const root = (try findRoot(gpa, io, start_dir)) orelse return null;
    defer gpa.free(root);
    return try load(gpa, io, root, diagnostics);
}
