//! アーカイブ型 artifact（`tar.gz` / `npm-tarball`）の検証付き展開。
//!
//! gzip 解除 → tar 走査 → `dest_abs` への安全な書き出しを行う。
//! symlink・特殊 entry・非規範 path（`..`・`\`・制御文字・絶対 path）は
//! 拒否し、`materialize.Limits` の量上限を展開途中にも適用する。
//! 展開結果を消費側へ渡す前に `materialize.copyTree` で複製検証を通す
//! ことを想定している（この層は archive 形式の拒否と量の先止めを担う）。

const std = @import("std");
const materialize = @import("materialize.zig");
const npkg_files = @import("npkg_files.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    /// gzip/tar の形式が壊れている、または宣言された type と一致しない。
    InvalidArchive,
    /// `file`・`directory` 以外の特殊 entry（fifo・デバイス・長名以外の
    /// 未対応 header 等）。
    UnsupportedEntry,
    /// symlink entry を検出した。package tree に symlink は許可しない。
    SymlinkEncountered,
    /// entry 名が規範 path 成分でない（`..`・`.`・`\`・制御文字・絶対）。
    NonCanonicalPath,
    DuplicatePath,
    CaseCollision,
    TooManyEntries,
    FileTooLarge,
    TreeTooLarge,
    TreeTooDeep,
    OutOfMemory,
};

pub const Options = struct {
    /// 先頭から除外する path 成分数。`npm-tarball` は `package/` 前置を
    /// 持つため 1、`tar.gz` は 0。
    strip_components: u32 = 0,
    limits: materialize.Limits = .{},
};

/// tar entry 名を規範化する。`..`・`.`・空成分（`a//b`・`./a`・先頭 `/`）・
/// `\`・制御文字は `error.NonCanonicalPath`。directory entry が持つ末尾の
/// `/` は dir marker として1つだけ除去してから成分を検査する。
/// `strip_components` 未満しか成分を持たない entry は null（例:
/// npm-tarball の `package/` dir 自身）。
fn normalizeEntryName(raw: []const u8, strip_components: u32, gpa: Allocator) (Error || Allocator.Error)!?[]u8 {
    if (raw.len == 0 or raw[0] == '/') return error.NonCanonicalPath;
    const name = if (raw[raw.len - 1] == '/') raw[0 .. raw.len - 1] else raw;
    if (name.len == 0) return error.NonCanonicalPath;
    var rel = std.ArrayListUnmanaged(u8).empty;
    errdefer rel.deinit(gpa);
    var depth: u32 = 0;
    var components = std.mem.splitScalar(u8, name, '/');
    while (components.next()) |component| {
        // 空成分・`.`・`..` は正規化せず拒否する。黙って落とすと
        // `a//b` や `./a` が別名の正規 path として受理されてしまう。
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, "..")) return error.NonCanonicalPath;
        for (component) |byte| {
            // `:` は Windows で drive 前置（`C:/x`）や ADS 区切り
            // （`a:b`）と解釈される。POSIX の正当なファイル名文字だが、
            // archive entry 名は全プラットフォームで展開先 dir の内側に
            // 限定される規範形へ揃えるため拒否する（`\` と同じ扱い）。
            if (byte < 0x20 or byte == 0x7f or byte == '\\' or byte == ':') return error.NonCanonicalPath;
        }
        depth += 1;
        if (depth <= strip_components) continue;
        if (rel.items.len > 0) try rel.append(gpa, '/');
        try rel.appendSlice(gpa, component);
    }
    if (rel.items.len == 0) return null;
    return try rel.toOwnedSlice(gpa);
}

/// `archive`（gzip 圧縮された tar）を `dest_abs` へ展開する。
/// `dest_abs` は存在しないか空 dir であること（無ければ作る）。
pub fn extractTarGz(gpa: Allocator, io: std.Io, archive: []const u8, dest_abs: []const u8, options: Options) !void {
    try std.Io.Dir.cwd().createDirPath(io, dest_abs);
    var dest = try std.Io.Dir.cwd().openDir(io, dest_abs, .{});
    defer dest.close(io);
    try extractTarGzInto(gpa, io, archive, dest, options);
}

/// tar の block 長。
const block_size = 512;

/// 展開ストリームから消費してよい byte 数。`Limits` は yield された entry の
/// 量しか見ないため、`std.tar.Iterator` が内部で drain する header 宣言
/// サイズ（g/x header の payload・未読 entry body）は上限を素通りしていた。
/// header・padding の構造分だけ `Limits` に上乗せし、gzip 解除後の全消費を
/// この予算で閉じる。
fn streamBudget(limits: materialize.Limits) u64 {
    // entry あたり header 1 block + padding 1 block 未満。g/x/L/K の前置
    // header が付いても 2 倍で収まる。終端 block と端数分の余裕を足す。
    const structural = (@as(u64, limits.max_entries) * 2 + 4) * block_size * 2;
    return std.math.add(u64, limits.max_total_bytes, structural) catch std.math.maxInt(u64);
}

/// 宣言 size を alignment 計算へ渡す前の上限。`size + 511` が桁溢れしない
/// 最大値で、これを超える宣言は archive 形式の破損として扱う
/// （std.tar は `alignForward` の overflow で panic する）。
fn maxDeclaredSize() u64 {
    return std.math.maxInt(u64) - (block_size - 1);
}

/// 512 byte 固定長 header の文字列 field。NUL までを返す。
fn headerField(header: *const [block_size]u8, start: usize, len: usize) []const u8 {
    const raw = header[start..][0..len];
    const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
    return raw[0..end];
}

/// 8 進 field。std.tar の `Header.octal` と同じ正規化（先頭 `0`/空白、
/// 末尾 空白/NUL を落とす）。
fn headerOctal(header: *const [block_size]u8, start: usize, len: usize) !u64 {
    const raw = header[start..][0..len];
    const ltrimmed = std.mem.trimStart(u8, raw, "0 ");
    const rtrimmed = std.mem.trimEnd(u8, ltrimmed, " \x00");
    if (rtrimmed.len == 0) return 0;
    return std.fmt.parseInt(u64, rtrimmed, 8) catch error.InvalidArchive;
}

/// header の宣言 size。base-256（binary）表現も std.tar と同じく受理するが、
/// alignment 計算の前に範囲を検査する。
fn headerSize(header: *const [block_size]u8) !u64 {
    const raw = header[124..][0..12];
    const size: u64 = if (raw[0] == 0xff)
        return error.InvalidArchive // 2 の補数表現の負値
    else if (raw[0] == 0x80) blk: {
        if (raw[1] != 0 or raw[2] != 0 or raw[3] != 0) return error.InvalidArchive;
        break :blk std.mem.readInt(u64, raw[4..12], .big);
    } else try headerOctal(header, 124, 12);
    if (size > maxDeclaredSize()) return error.InvalidArchive;
    return size;
}

/// size を block 境界へ切り上げたときの padding 長。size は `headerSize` /
/// pax 検査済み（`maxDeclaredSize` 以下）であること。
fn blockPadding(size: u64) u64 {
    return std.mem.alignForward(u64, size, block_size) - size;
}

/// header の checksum 検証。0 は終端 block（全 zero）を表す。
fn checkHeaderChksum(header: *const [block_size]u8) !u64 {
    const declared = try headerOctal(header, 148, 8);
    var unsigned: u64 = 0;
    var signed: i64 = 0;
    for (header, 0..) |byte, index| {
        // checksum field 自身は空白として計算する。
        const value: u8 = if (index >= 148 and index < 156) ' ' else byte;
        unsigned += value;
        signed += @as(i8, @bitCast(value));
    }
    if (declared == 0 and unsigned == 256) return 0;
    if (declared != unsigned and declared != @as(u64, @bitCast(signed))) return error.InvalidArchive;
    return declared;
}

/// header の name を ustar prefix 込みで `buffer` へ展開する。
fn headerFullName(header: *const [block_size]u8, buffer: []u8) ![]const u8 {
    const name = headerField(header, 0, 100);
    const magic = header[257..][0..6];
    const is_ustar = std.mem.eql(u8, magic[0..5], "ustar") and (magic[5] == 0 or magic[5] == ' ');
    const prefix = headerField(header, 345, 155);
    if (!is_ustar or prefix.len == 0) {
        if (name.len > buffer.len) return error.InvalidArchive;
        @memcpy(buffer[0..name.len], name);
        return buffer[0..name.len];
    }
    if (buffer.len < prefix.len + 1 + name.len) return error.InvalidArchive;
    @memcpy(buffer[0..prefix.len], prefix);
    buffer[prefix.len] = '/';
    @memcpy(buffer[prefix.len + 1 ..][0..name.len], name);
    return buffer[0 .. prefix.len + 1 + name.len];
}

const TarKind = enum { directory, file, sym_link };

const TarEntry = struct {
    name: []const u8,
    size: u64,
    kind: TarKind,
};

/// 展開境界用の tar reader。`std.tar.Iterator` の代わりに使う理由は 2 つ:
/// (1) 宣言 size を alignment 計算の前に範囲検査する（std は桁溢れ panic）、
/// (2) g/x header の payload や未読 body を含む全消費を予算内に閉じる。
/// header の読み方（ustar prefix・GNU 長名 L/K・pax x/g）は std.tar と
/// 同じ意味論に合わせる。
const TarReader = struct {
    reader: *std.Io.Reader,
    /// 残り消費予算（gzip 解除後の byte 数）。
    remaining: u64,
    /// まだ読み出していない直近 entry の body 長（次の next が捨てる）。
    unread_body: u64 = 0,
    /// 直近 body の padding 長（次の next が捨てる）。
    padding: u64 = 0,
    header: [block_size]u8 = undefined,
    name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined,
    pax_size_buffer: [64]u8 = undefined,

    fn init(reader: *std.Io.Reader, budget: u64) TarReader {
        return .{ .reader = reader, .remaining = budget };
    }

    /// 予算を先に消費する。宣言だけ大きくて流れない header に対しても、
    /// 読み進める前にここで落ちる。
    fn charge(self: *TarReader, bytes: u64) !void {
        if (bytes > self.remaining) return error.InvalidArchive;
        self.remaining -= bytes;
    }

    fn readExact(self: *TarReader, buffer: []u8) !void {
        try self.charge(buffer.len);
        self.reader.readSliceAll(buffer) catch return error.InvalidArchive;
    }

    fn discard(self: *TarReader, bytes: u64) !void {
        if (bytes == 0) return;
        try self.charge(bytes);
        self.reader.discardAll64(bytes) catch return error.InvalidArchive;
    }

    fn readHeaderBlock(self: *TarReader) !?*const [block_size]u8 {
        try self.charge(block_size);
        const read = self.reader.readSliceShort(&self.header) catch return error.InvalidArchive;
        // EOF で読めなかった分は消費していない。
        self.remaining += block_size - read;
        if (read == 0) return null;
        if (read < block_size) return error.InvalidArchive;
        return &self.header;
    }

    /// GNU 長名 (L/K) の body。`std.tar` と同じく buffer に収まらない長名は
    /// 展開しない。
    fn readLongName(self: *TarReader, size: u64, buffer: []u8) ![]const u8 {
        if (size > buffer.len) return error.InvalidArchive;
        const target = buffer[0..@intCast(size)];
        try self.readExact(target);
        const end = std.mem.indexOfScalar(u8, target, 0) orelse target.len;
        return target[0..end];
    }

    /// POSIX pax header (x)。path・linkpath・size だけを解釈する。
    fn readPax(self: *TarReader, size: u64, pending: *PaxPending) !void {
        // pax 本体の消費は attribute 単位で reader から直接読まれるため、
        // 解析前にまとめて予算を消費する。
        try self.charge(size);
        var attributes: std.tar.PaxIterator = .{ .reader = self.reader, .size = @intCast(size) };
        while (attributes.next() catch return error.InvalidArchive) |attribute| {
            switch (attribute.kind) {
                .path => pending.name = attribute.value(&self.name_buffer) catch return error.InvalidArchive,
                .linkpath => {
                    // symlink entry は展開しないため長名 link だけ捨てる。
                    var discard_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                    _ = attribute.value(&discard_buffer) catch return error.InvalidArchive;
                },
                .size => {
                    const text = attribute.value(&self.pax_size_buffer) catch return error.InvalidArchive;
                    const declared = std.fmt.parseInt(u64, text, 10) catch return error.InvalidArchive;
                    // pax の size も alignment 計算へ入るため同じ上限を課す。
                    if (declared > maxDeclaredSize()) return error.InvalidArchive;
                    pending.size = declared;
                },
            }
        }
    }

    fn next(self: *TarReader) !?TarEntry {
        try self.discard(self.unread_body);
        self.unread_body = 0;
        try self.discard(self.padding);
        self.padding = 0;

        var pending = PaxPending{};

        while (true) {
            const header = (try self.readHeaderBlock()) orelse return null;
            if (try checkHeaderChksum(header) == 0) return null;
            const size = try headerSize(header);
            switch (header[156]) {
                // 通常 file・directory・symlink のみを yield する。
                0, '0', '5', '2' => {
                    const kind: TarKind = switch (header[156]) {
                        '5' => .directory,
                        '2' => .sym_link,
                        else => .file,
                    };
                    const entry_size = pending.size orelse size;
                    if (entry_size > maxDeclaredSize()) return error.InvalidArchive;
                    const name = if (pending.name.len != 0)
                        pending.name
                    else
                        try headerFullName(header, &self.name_buffer);
                    self.unread_body = entry_size;
                    self.padding = blockPadding(entry_size);
                    return .{ .name = name, .size = entry_size, .kind = kind };
                },
                'L' => {
                    pending.name = try self.readLongName(size, &self.name_buffer);
                    const pad = blockPadding(size);
                    try self.discard(pad);
                },
                // GNU 長名 link (K)。symlink entry は展開しないため body だけ捨てる。
                'K' => {
                    try self.discard(size);
                    const pad = blockPadding(size);
                    try self.discard(pad);
                },
                'x' => {
                    try self.readPax(size, &pending);
                    const pad = blockPadding(size);
                    try self.discard(pad);
                },
                // global pax header は無視するが、宣言 payload は必ず予算内で
                // 捨てる（ここが無制限 drain の入口だった）。
                'g' => {
                    try self.discard(size);
                    const pad = blockPadding(size);
                    try self.discard(pad);
                },
                else => return error.UnsupportedEntry,
            }
        }
    }

    /// yield した entry の body を `writer` へ流す。予算は流す前に消費する。
    fn streamBody(self: *TarReader, writer: *std.Io.Writer) !void {
        const bytes = self.unread_body;
        self.unread_body = 0;
        try self.charge(bytes);
        self.reader.streamExact64(writer, bytes) catch |err| switch (err) {
            // 書き出し側の失敗は archive ではなく FS の問題。
            error.WriteFailed => return err,
            else => return error.InvalidArchive,
        };
    }
};

const PaxPending = struct {
    name: []const u8 = "",
    size: ?u64 = null,
};

/// `archive`（gzip 圧縮された tar）を open 済み `dest` dir へ handle 相対に
/// 展開する。`dest` は空 dir を想定する（呼出し側が管理 dir の下へ作成した
/// pinned handle を渡す）。path 解決を行わないため、展開先 dir を指す path
/// が rename→symlink 置換されても境界外へ書き込まない。
pub fn extractTarGzInto(gpa: Allocator, io: std.Io, archive: []const u8, dest: std.Io.Dir, options: Options) !void {
    var input = std.Io.Reader.fixed(archive);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&input, .gzip, &window_buf);
    var tar = TarReader.init(&decompress.reader, streamBudget(options.limits));

    // PathSet の key は init allocator が所有する（copyTree と同じく arena
    // 一括解放の契約）。
    var arena_impl = std.heap.ArenaAllocator.init(gpa);
    defer arena_impl.deinit();
    var seen = materialize.PathSet.init(arena_impl.allocator());
    defer {
        seen.seen_exact.deinit();
        seen.seen_lower.deinit();
    }
    var entries: u64 = 0;
    var total_bytes: u64 = 0;

    while (try tar.next()) |file| {
        const rel = (try normalizeEntryName(file.name, options.strip_components, gpa)) orelse continue;
        defer gpa.free(rel);
        if (!npkg_files.isCanonicalPath(rel)) return error.NonCanonicalPath;
        // 深さは成分数。root 直下が 1。
        const depth = std.mem.count(u8, rel, "/") + 1;
        if (depth > options.limits.max_depth) return error.TreeTooDeep;
        entries += 1;
        if (entries > options.limits.max_entries) return error.TooManyEntries;
        try seen.record(rel);

        switch (file.kind) {
            .directory => {
                dest.createDirPath(io, rel) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                };
            },
            .file => {
                if (file.size > options.limits.max_file_bytes) return error.FileTooLarge;
                total_bytes += file.size;
                if (total_bytes > options.limits.max_total_bytes) return error.TreeTooLarge;
                if (std.fs.path.dirname(rel)) |parent| {
                    dest.createDirPath(io, parent) catch |err| switch (err) {
                        error.PathAlreadyExists => {},
                        else => return err,
                    };
                }
                var out = dest.createFile(io, rel, .{ .exclusive = true }) catch |err| switch (err) {
                    error.PathAlreadyExists => return error.DuplicatePath,
                    else => return err,
                };
                defer out.close(io);
                var write_buf: [64 * 1024]u8 = undefined;
                var writer = out.writer(io, &write_buf);
                _ = tar.streamBody(&writer.interface) catch |err| switch (err) {
                    error.WriteFailed => return err,
                    else => return error.InvalidArchive,
                };
                try writer.interface.flush();
            },
            .sym_link => return error.SymlinkEncountered,
        }
    }
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// テスト用に tar を gzip 圧縮した byte 列を作る。`root` は tar 内の
/// 前置 dir（npm-tarball の `package/` 相当。空なら前置なし）。
fn buildTarGz(gpa: Allocator, root: []const u8, files: []const struct { path: []const u8, content: []const u8 }, links: []const struct { path: []const u8, target: []const u8 }) ![]u8 {
    var tar_buffer: std.Io.Writer.Allocating = .init(gpa);
    defer tar_buffer.deinit();
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &tar_buffer.writer };
    if (root.len != 0) try tar_writer.setRoot(root);
    for (files) |file| try tar_writer.writeFileBytes(file.path, file.content, .{});
    for (links) |link| try tar_writer.writeLink(link.path, link.target, .{});
    try tar_writer.finishPedantically();

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    // Compress.init は出力 buffer の最低容量を要求するため先に確保する。
    try out.ensureUnusedCapacity(64);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&out.writer, &window_buf, .gzip, .default);
    try compress.writer.writeAll(tar_buffer.written());
    try compress.finish();
    return try out.toOwnedSlice();
}

test "unpack extractTarGz は tar.gz を展開してファイルを書き出す" {
    const io = testing.io;
    const archive = try buildTarGz(testing.allocator, "", &.{
        .{ .path = "nako.toml", .content = "[package]\n" },
        .{ .path = "src/index.nako3", .content = "●テストとは\n" },
    }, &.{});
    defer testing.allocator.free(archive);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dest = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dest);
    const extract_dir = try std.fs.path.join(testing.allocator, &.{ dest, "out" });
    defer testing.allocator.free(extract_dir);

    try extractTarGz(testing.allocator, io, archive, extract_dir, .{});
    const file_path = try std.fs.path.join(testing.allocator, &.{ extract_dir, "src", "index.nako3" });
    defer testing.allocator.free(file_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file_path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("●テストとは\n", bytes);
}

test "unpack extractTarGz は strip_components で前置 dir を除外する" {
    const io = testing.io;
    const archive = try buildTarGz(testing.allocator, "package", &.{
        .{ .path = "nako.toml", .content = "[package]\n" },
    }, &.{});
    defer testing.allocator.free(archive);

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dest = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dest);
    const extract_dir = try std.fs.path.join(testing.allocator, &.{ dest, "out" });
    defer testing.allocator.free(extract_dir);

    try extractTarGz(testing.allocator, io, archive, extract_dir, .{ .strip_components = 1 });
    const file_path = try std.fs.path.join(testing.allocator, &.{ extract_dir, "nako.toml" });
    defer testing.allocator.free(file_path);
    try std.Io.Dir.cwd().access(io, file_path, .{});
}

test "unpack extractTarGz は symlink・traversal・重複 entry を拒否する" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dest = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dest);

    const symlinked = try buildTarGz(testing.allocator, "", &.{
        .{ .path = "a.txt", .content = "x" },
    }, &.{
        .{ .path = "link.txt", .target = "a.txt" },
    });
    defer testing.allocator.free(symlinked);
    const out1 = try std.fs.path.join(testing.allocator, &.{ dest, "o1" });
    defer testing.allocator.free(out1);
    try testing.expectError(error.SymlinkEncountered, extractTarGz(testing.allocator, io, symlinked, out1, .{}));

    // `..` を含む entry は展開前に拒否する（tar.Writer が作れない形式を
    // 直接 byte 列で検査する代わりに normalizeEntryName で検証）。
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("../escape", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("a/../b", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("/abs", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("a\\b", 0, testing.allocator));
    // 空成分・`.` 成分も正規化せず拒否する（`a//b` や `./a` が黙って
    // 別名として受理されないこと）。
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("a//b", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("./a", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("a/./b", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("a/b//", 0, testing.allocator));

    // drive 前置・ADS 形式も拒否する（Windows で展開先 dir の外へ
    // 書き出されないよう `:` を含む成分は全て非規範とする）。
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("C:/escape/x.txt", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("C:\\escape", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("a:b", 0, testing.allocator));
    try testing.expectError(error.NonCanonicalPath, normalizeEntryName("C:relative", 0, testing.allocator));

    // directory entry の末尾 `/` は dir marker として除去される。
    const dir_name = (try normalizeEntryName("src/dir/", 0, testing.allocator)).?;
    defer testing.allocator.free(dir_name);
    try testing.expectEqualStrings("src/dir", dir_name);

    // 同一 path の重複は PathSet が検出する。
    const dup = try buildTarGz(testing.allocator, "", &.{
        .{ .path = "dup.txt", .content = "1" },
        .{ .path = "dup.txt", .content = "2" },
    }, &.{});
    defer testing.allocator.free(dup);
    const out2 = try std.fs.path.join(testing.allocator, &.{ dest, "o2" });
    defer testing.allocator.free(out2);
    try testing.expectError(error.DuplicatePath, extractTarGz(testing.allocator, io, dup, out2, .{}));
}

test "unpack extractTarGz は gzip でない入力を InvalidArchive とする" {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dest = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dest);
    const extract_dir = try std.fs.path.join(testing.allocator, &.{ dest, "out" });
    defer testing.allocator.free(extract_dir);
    try testing.expectError(error.InvalidArchive, extractTarGz(testing.allocator, io, "not a gzip stream", extract_dir, .{}));
}

/// 512 byte header の checksum field を正しく埋める。
fn sealHeader(header: []u8) void {
    @memset(header[148..156], ' ');
    var sum: u64 = 0;
    for (header) |byte| sum += byte;
    _ = std.fmt.bufPrint(header[148..156], "{o:0>6}\x00 ", .{sum}) catch unreachable;
}

/// 生の tar byte 列を gzip 圧縮する。
fn gzipBytes(gpa: Allocator, raw: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.ensureUnusedCapacity(64);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(&out.writer, &window_buf, .gzip, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();
    return try out.toOwnedSlice();
}

fn extractInto(archive: []const u8, limits: materialize.Limits) !void {
    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dest = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dest);
    const extract_dir = try std.fs.path.join(testing.allocator, &.{ dest, "out" });
    defer testing.allocator.free(extract_dir);
    try extractTarGz(testing.allocator, io, archive, extract_dir, .{ .limits = limits });
}

test "unpack extractTarGz は base-256 の巨大 size 宣言で panic せず InvalidArchive を返す" {
    // 監査時の fingerprint: std.tar の blockPadding が alignForward の
    // 桁溢れで panic していた（74 byte の gzip で SIGABRT）。
    var raw: [512]u8 = @splat(0);
    @memcpy(raw[0..4], "evil");
    raw[156] = '0';
    raw[124] = 0x80; // base-256 encoding
    std.mem.writeInt(u64, raw[128..136], std.math.maxInt(u64), .big);
    sealHeader(&raw);
    const archive = try gzipBytes(testing.allocator, &raw);
    defer testing.allocator.free(archive);

    try testing.expectError(error.InvalidArchive, extractInto(archive, .{}));
}

test "unpack extractTarGz は g header の宣言 payload を予算で打ち切る" {
    // 監査時の fingerprint: 32KB の gzip が 33.5MB を drain しても量上限が
    // 一切発火しなかった。宣言 size 分の実体を用意し、専用予算で落ちること。
    const declared: u64 = 4 * 1024 * 1024;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(testing.allocator);
    try raw.ensureTotalCapacity(testing.allocator, 512 + declared);

    var header: [512]u8 = @splat(0);
    @memcpy(header[0..12], "pax_global_g"[0..12]);
    header[156] = 'g';
    _ = std.fmt.bufPrint(header[124..136], "{o:0>11}\x00", .{declared}) catch unreachable;
    sealHeader(&header);
    try raw.appendSlice(testing.allocator, &header);
    try raw.appendNTimes(testing.allocator, 0, declared);

    const archive = try gzipBytes(testing.allocator, raw.items);
    defer testing.allocator.free(archive);

    try testing.expectError(error.InvalidArchive, extractInto(archive, .{
        .max_total_bytes = 1024,
        .max_entries = 1,
        .max_file_bytes = 1024,
    }));
}

test "unpack extractTarGz は pax の巨大 size 宣言で panic せず InvalidArchive を返す" {
    var raw: [1024]u8 = @splat(0);
    // pax record: "<len> size=<20 digit u64max>\n" は 29 byte。
    @memcpy(raw[0..8], "pax_size");
    raw[156] = 'x';
    _ = std.fmt.bufPrint(raw[124..136], "{o:0>11}\x00", .{29}) catch unreachable;
    sealHeader(raw[0..512]);
    @memcpy(raw[512..541], "29 size=18446744073709551615\n");
    const archive = try gzipBytes(testing.allocator, &raw);
    defer testing.allocator.free(archive);

    try testing.expectError(error.InvalidArchive, extractInto(archive, .{}));
}

test "unpack extractTarGz は pax の path を file 名として使う" {
    var raw: [2048]u8 = @splat(0);
    // pax record "20 path=renamed.txt\n" (20 byte)
    @memcpy(raw[0..8], "pax_path");
    raw[156] = 'x';
    _ = std.fmt.bufPrint(raw[124..136], "{o:0>11}\x00", .{20}) catch unreachable;
    sealHeader(raw[0..512]);
    @memcpy(raw[512..532], "20 path=renamed.txt\n");

    var file_header: [512]u8 = @splat(0);
    @memcpy(file_header[0..8], "orig.txt");
    file_header[156] = '0';
    _ = std.fmt.bufPrint(file_header[124..136], "{o:0>11}\x00", .{1}) catch unreachable;
    sealHeader(&file_header);
    @memcpy(raw[1024..1536], &file_header);
    raw[1536] = 'x';

    const archive = try gzipBytes(testing.allocator, &raw);
    defer testing.allocator.free(archive);

    const io = testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const dest = try temporary.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dest);
    const extract_dir = try std.fs.path.join(testing.allocator, &.{ dest, "out" });
    defer testing.allocator.free(extract_dir);
    try extractTarGz(testing.allocator, io, archive, extract_dir, .{});

    const file_path = try std.fs.path.join(testing.allocator, &.{ extract_dir, "renamed.txt" });
    defer testing.allocator.free(file_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, file_path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("x", bytes);
}
