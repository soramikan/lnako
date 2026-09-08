const std = @import("std");

const max_entries = 100_000;
const max_total_size = 1024 * 1024 * 1024;
const max_compression_ratio = 100;

const Entry = struct {
    name: []u8,
    data: []u8,
    is_directory: bool,
    local_offset: u32 = 0,

    fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.data);
    }
};

pub fn create(allocator: std.mem.Allocator, io: std.Io, source: []const u8, destination: []const u8) !void {
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }
    try gatherEntries(allocator, io, source, &entries);
    std.mem.sort(Entry, entries.items, {}, lessThanEntry);
    if (entries.items.len > max_entries) return error.ZipEntryCountExceeded;

    var total_input_size: u64 = 0;
    for (entries.items) |entry| total_input_size += entry.data.len;
    if (total_input_size > max_total_size) return error.ZipTotalSizeExceeded;

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    for (entries.items) |*entry| {
        entry.local_offset = std.math.cast(u32, output.items.len) orelse return error.Zip64Required;
        const crc = if (entry.is_directory) 0 else std.hash.Crc32.hash(entry.data);
        const size = std.math.cast(u32, entry.data.len) orelse return error.Zip64Required;
        try appendInt(&output, allocator, u32, 0x04034b50);
        try appendInt(&output, allocator, u16, 20);
        try appendInt(&output, allocator, u16, 0x0800);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u32, crc);
        try appendInt(&output, allocator, u32, size);
        try appendInt(&output, allocator, u32, size);
        try appendInt(&output, allocator, u16, std.math.cast(u16, entry.name.len) orelse return error.ZipEntryNameTooLong);
        try appendInt(&output, allocator, u16, 0);
        try output.appendSlice(allocator, entry.name);
        try output.appendSlice(allocator, entry.data);
    }

    const central_offset = std.math.cast(u32, output.items.len) orelse return error.Zip64Required;
    for (entries.items) |entry| {
        const crc = if (entry.is_directory) 0 else std.hash.Crc32.hash(entry.data);
        const size = std.math.cast(u32, entry.data.len) orelse return error.Zip64Required;
        try appendInt(&output, allocator, u32, 0x02014b50);
        try appendInt(&output, allocator, u16, 0x0314);
        try appendInt(&output, allocator, u16, 20);
        try appendInt(&output, allocator, u16, 0x0800);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u32, crc);
        try appendInt(&output, allocator, u32, size);
        try appendInt(&output, allocator, u32, size);
        try appendInt(&output, allocator, u16, std.math.cast(u16, entry.name.len) orelse return error.ZipEntryNameTooLong);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u32, if (entry.is_directory) 0x41ed0010 else 0x81a40000);
        try appendInt(&output, allocator, u32, entry.local_offset);
        try output.appendSlice(allocator, entry.name);
    }
    const central_size = std.math.cast(u32, output.items.len - central_offset) orelse return error.Zip64Required;
    const count = std.math.cast(u16, entries.items.len) orelse return error.Zip64Required;
    try appendInt(&output, allocator, u32, 0x06054b50);
    try appendInt(&output, allocator, u16, 0);
    try appendInt(&output, allocator, u16, 0);
    try appendInt(&output, allocator, u16, count);
    try appendInt(&output, allocator, u16, count);
    try appendInt(&output, allocator, u32, central_size);
    try appendInt(&output, allocator, u32, central_offset);
    try appendInt(&output, allocator, u16, 0);
    if (output.items.len > max_total_size) return error.ZipTotalSizeExceeded;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = destination, .data = output.items });
}

pub fn extract(io: std.Io, source: []const u8, destination: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, destination);
    var destination_directory = try std.Io.Dir.cwd().openDir(io, destination, .{});
    defer destination_directory.close(io);
    // 展開はまず出力先の内側に作った隔離dirへ行い、検証済みの結果だけを
    // no-followのdirectory handle経由で公開する。新規dirの内部には既存linkが
    // 存在しないため、std側の展開がlinkを追跡して境界の外へ書き出す余地がない。
    var staging_name_buffer: [staging_name_len]u8 = undefined;
    const staging_name = try createStagingDirectory(io, destination_directory, &staging_name_buffer);
    var staging_directory = try destination_directory.openDir(io, staging_name, .{});
    defer {
        staging_directory.close(io);
        destination_directory.deleteTree(io, staging_name) catch {};
    }
    const archive_stat = try std.Io.Dir.cwd().statFile(io, source, .{});
    const archive_size = archive_stat.size;
    const file = try std.Io.Dir.cwd().openFile(io, source, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    var iterator = try std.zip.Iterator.init(&reader);
    var filename_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var total_uncompressed: u64 = 0;
    var total_compressed: u64 = 0;
    var entry_count: u64 = 0;
    while (try iterator.next()) |entry| {
        entry_count += 1;
        if (entry_count > max_entries) return error.ZipEntryCountExceeded;
        total_uncompressed = std.math.add(u64, total_uncompressed, entry.uncompressed_size) catch return error.ZipTotalSizeExceeded;
        if (total_uncompressed > max_total_size) return error.ZipTotalSizeExceeded;
        total_compressed = std.math.add(u64, total_compressed, entry.compressed_size) catch return error.ZipTotalSizeExceeded;
        if (entry.compressed_size != 0 and entry.uncompressed_size / max_compression_ratio > entry.compressed_size) return error.ZipCompressionRatioExceeded;
        if (archive_size > 0 and total_uncompressed / max_compression_ratio > archive_size) return error.ZipCompressionRatioExceeded;
        // 名前はcentral directory header（固定46byte）直後にある。検査を
        // 展開より先に行い、不正な名前がfile systemへ触れないようにする。
        if (filename_buffer.len < entry.filename_len) return error.ZipInsufficientBuffer;
        try reader.seekTo(entry.header_zip_offset + 46);
        try reader.interface.readSliceAll(filename_buffer[0..entry.filename_len]);
        const filename = filename_buffer[0..entry.filename_len];
        try validateExtractName(filename);
        try entry.extract(&reader, .{}, &filename_buffer, staging_directory);
        if (filename[filename.len - 1] == '/') {
            try publishExtractedDirectory(io, destination_directory, filename);
            continue;
        }
        if (!try verifyExtractedFile(io, staging_directory, filename, entry.uncompressed_size, entry.crc32)) {
            return error.ZipChecksumMismatch;
        }
        try publishExtractedFile(io, staging_directory, destination_directory, filename);
    }
}

const staging_prefix = ".lnako-zip-stage-";
const staging_name_len = staging_prefix.len + 16;

/// 出力先内にランダム名の空dirを作る。予測不能な名前のため、事前にlinkを
/// 仕込まれて隔離dirへ誘導される余地がない。
fn createStagingDirectory(io: std.Io, destination: std.Io.Dir, buffer: *[staging_name_len]u8) ![]const u8 {
    for (0..8) |_| {
        var random: [8]u8 = undefined;
        io.random(&random);
        const name = std.fmt.bufPrint(buffer, "{s}{x}", .{ staging_prefix, random }) catch unreachable;
        destination.createDir(io, name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        return name;
    }
    return error.PathAlreadyExists;
}

/// entry名の境界を検査する。std側が`..`と先頭`/`を拒否した上で、
/// 制御文字と`:`（Windowsのdrive/UNC/ADSとの衝突）を追加で拒否する。
fn validateExtractName(filename: []const u8) !void {
    if (filename.len == 0) return error.ZipBadFilename;
    var components = std.mem.splitScalar(u8, filename, '/');
    while (components.next()) |component| {
        if (component.len == 0) continue;
        if (std.mem.eql(u8, component, "..")) return error.ZipBadFilename;
        if (std.mem.indexOfAny(u8, component, ":\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f") != null) return error.ZipBadFilename;
    }
}

/// `rest`に実効成分（空でも`.`でもない成分）が残るか。
fn hasExtractComponent(rest: []const u8) bool {
    var components = std.mem.splitScalar(u8, rest, '/');
    while (components.next()) |component| {
        if (component.len != 0 and !std.mem.eql(u8, component, ".")) return true;
    }
    return false;
}

/// 中間成分・最終のdirectory成分を順にno-followで開き、存在しなければ作成する。
/// 既存のlinkやfileはSymLinkLoop/NotDirで失敗し、追跡しない。
fn openOrCreateDirNoFollow(io: std.Io, parent: std.Io.Dir, name: []const u8) !std.Io.Dir {
    return parent.openDir(io, name, .{ .follow_symlinks = false }) catch |first| {
        if (first != error.FileNotFound) return first;
        parent.createDir(io, name, .default_dir) catch |second| switch (second) {
            error.PathAlreadyExists => {},
            else => return second,
        };
        return parent.openDir(io, name, .{ .follow_symlinks = false });
    };
}

/// directory entryを出力先へ公開する。各成分をno-followで開いて作成する。
fn publishExtractedDirectory(io: std.Io, destination: std.Io.Dir, filename: []const u8) !void {
    var current = destination;
    var owns_current = false;
    defer if (owns_current) current.close(io);
    var components = std.mem.splitScalar(u8, filename, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        const next = try openOrCreateDirNoFollow(io, current, component);
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
    }
}

/// 検証済みのstaging fileを出力先へ公開する。中間成分はno-followで開き、
/// 最終成分は上書きしないrenameで一度だけ置く。
fn publishExtractedFile(io: std.Io, staging: std.Io.Dir, destination: std.Io.Dir, filename: []const u8) !void {
    var staging_name: [std.fs.max_path_bytes]u8 = undefined;
    var staging_len: usize = 0;
    var current = destination;
    var owns_current = false;
    defer if (owns_current) current.close(io);
    var index: usize = 0;
    while (index < filename.len) {
        const end = std.mem.indexOfScalarPos(u8, filename, index, '/') orelse filename.len;
        const component = filename[index..end];
        index = end + 1;
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (staging_len != 0) {
            staging_name[staging_len] = '/';
            staging_len += 1;
        }
        @memcpy(staging_name[staging_len..][0..component.len], component);
        staging_len += component.len;
        const rest: []const u8 = if (index > filename.len) "" else filename[index..];
        if (!hasExtractComponent(rest)) {
            const staged = staging_name[0..staging_len];
            std.Io.Dir.renamePreserve(staging, staged, current, component, io) catch |err| switch (err) {
                // renamePreserve非対応の環境ではexclusive createへ退避する。
                error.OperationUnsupported => try copyExtractedFile(io, staging, staged, current, component),
                else => return err,
            };
            return;
        }
        const next = try openOrCreateDirNoFollow(io, current, component);
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
    }
    return error.ZipBadFilename;
}

/// renamePreserve非対応環境の退避経路。exclusive createにより最終成分の
/// 既存file・linkを上書きしない。
fn copyExtractedFile(io: std.Io, staging: std.Io.Dir, staged_name: []const u8, parent: std.Io.Dir, name: []const u8) !void {
    var source_file = try staging.openFile(io, staged_name, .{ .follow_symlinks = false });
    defer source_file.close(io);
    var output = try parent.createFile(io, name, .{ .exclusive = true });
    defer output.close(io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var file_reader = source_file.reader(io, &read_buffer);
    var file_writer = output.writer(io, &write_buffer);
    while (true) {
        var chunk: [8192]u8 = undefined;
        const length = try file_reader.interface.readSliceShort(&chunk);
        if (length == 0) break;
        try file_writer.interface.writeAll(chunk[0..length]);
    }
    try file_writer.end();
    try staging.deleteFile(io, staged_name);
}

fn verifyExtractedFile(io: std.Io, directory: std.Io.Dir, path: []const u8, expected_size: u64, expected_crc32: u32) !bool {
    const file = try directory.openFile(io, path, .{});
    defer file.close(io);
    var reader_buffer: [8192]u8 = undefined;
    var data_buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    var crc = std.hash.Crc32.init();
    var size: u64 = 0;
    while (true) {
        const length = try reader.interface.readSliceShort(&data_buffer);
        if (length == 0) break;
        size = std.math.add(u64, size, length) catch return false;
        crc.update(data_buffer[0..length]);
    }
    return size == expected_size and crc.final() == expected_crc32;
}

fn gatherEntries(allocator: std.mem.Allocator, io: std.Io, source: []const u8, entries: *std.ArrayList(Entry)) !void {
    var total_size: u64 = 0;
    const stat = try std.Io.Dir.cwd().statFile(io, source, .{});
    if (stat.kind != .directory) {
        const data = try std.Io.Dir.cwd().readFileAlloc(io, source, allocator, .limited(max_total_size));
        errdefer allocator.free(data);
        try entries.append(allocator, .{ .name = try normalizedName(allocator, std.fs.path.basename(source), false), .data = data, .is_directory = false });
        return;
    }

    const root_name = std.fs.path.basename(std.mem.trimEnd(u8, source, "/\\"));
    try entries.append(allocator, .{ .name = try normalizedName(allocator, root_name, true), .data = try allocator.alloc(u8, 0), .is_directory = true });
    var directory = try std.Io.Dir.cwd().openDir(io, source, .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |walked| {
        if (entries.items.len >= max_entries) return error.ZipEntryCountExceeded;
        const joined_name = try std.fs.path.join(allocator, &.{ root_name, walked.path });
        defer allocator.free(joined_name);
        if (walked.kind == .directory) {
            try entries.append(allocator, .{ .name = try normalizedName(allocator, joined_name, true), .data = try allocator.alloc(u8, 0), .is_directory = true });
        } else if (walked.kind == .file) {
            const file_path = try std.fs.path.join(allocator, &.{ source, walked.path });
            defer allocator.free(file_path);
            const data = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(max_total_size));
            errdefer allocator.free(data);
            total_size = std.math.add(u64, total_size, data.len) catch return error.ZipTotalSizeExceeded;
            if (total_size > max_total_size) return error.ZipTotalSizeExceeded;
            try entries.append(allocator, .{ .name = try normalizedName(allocator, joined_name, false), .data = data, .is_directory = false });
        }
    }
}

fn normalizedName(allocator: std.mem.Allocator, source: []const u8, directory: bool) ![]u8 {
    const extra: usize = if (directory and (source.len == 0 or source[source.len - 1] != '/')) 1 else 0;
    const result = try allocator.alloc(u8, source.len + extra);
    for (source, 0..) |byte, index| result[index] = if (byte == '\\') '/' else byte;
    if (extra == 1) result[source.len] = '/';
    return result;
}

fn appendInt(list: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}

fn lessThanEntry(_: void, left: Entry, right: Entry) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

test "stored ZIPを作成・展開する" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "source.txt", .data = "日本語ABC" });
    const temporary_path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(temporary_path);
    const source = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "source.txt" });
    defer std.testing.allocator.free(source);
    const zip_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "result.zip" });
    defer std.testing.allocator.free(zip_path);
    const output_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "output" });
    defer std.testing.allocator.free(output_path);
    try create(std.testing.allocator, std.testing.io, source, zip_path);
    try extract(std.testing.io, zip_path, output_path);
    const extracted = try std.fs.path.join(std.testing.allocator, &.{ output_path, "source.txt" });
    defer std.testing.allocator.free(extracted);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, extracted, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("日本語ABC", bytes);

    const archive = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, zip_path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(archive);
    archive[30 + "source.txt".len] ^= 0xff;
    const corrupted_path = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "corrupted.zip" });
    defer std.testing.allocator.free(corrupted_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = corrupted_path, .data = archive });
    const corrupted_output = try std.fs.path.join(std.testing.allocator, &.{ temporary_path, "corrupted-output" });
    defer std.testing.allocator.free(corrupted_output);
    try std.testing.expectError(error.ZipChecksumMismatch, extract(std.testing.io, corrupted_path, corrupted_output));
}

const TestZipEntry = struct { name: []const u8, data: []const u8 = "" };

fn buildTestZip(allocator: std.mem.Allocator, entries: []const TestZipEntry) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const offsets = try allocator.alloc(u32, entries.len);
    defer allocator.free(offsets);
    for (entries, 0..) |entry, index| {
        const is_directory = entry.name.len > 0 and entry.name[entry.name.len - 1] == '/';
        const data = if (is_directory) "" else entry.data;
        const crc = if (is_directory) 0 else std.hash.Crc32.hash(data);
        offsets[index] = std.math.cast(u32, output.items.len) orelse return error.Zip64Required;
        try appendInt(&output, allocator, u32, 0x04034b50);
        try appendInt(&output, allocator, u16, 20);
        try appendInt(&output, allocator, u16, 0x0800);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u32, crc);
        try appendInt(&output, allocator, u32, @intCast(data.len));
        try appendInt(&output, allocator, u32, @intCast(data.len));
        try appendInt(&output, allocator, u16, @intCast(entry.name.len));
        try appendInt(&output, allocator, u16, 0);
        try output.appendSlice(allocator, entry.name);
        try output.appendSlice(allocator, data);
    }
    const central_offset = output.items.len;
    for (entries, 0..) |entry, index| {
        const is_directory = entry.name.len > 0 and entry.name[entry.name.len - 1] == '/';
        const data = if (is_directory) "" else entry.data;
        const crc = if (is_directory) 0 else std.hash.Crc32.hash(data);
        try appendInt(&output, allocator, u32, 0x02014b50);
        try appendInt(&output, allocator, u16, 0x0314);
        try appendInt(&output, allocator, u16, 20);
        try appendInt(&output, allocator, u16, 0x0800);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u32, crc);
        try appendInt(&output, allocator, u32, @intCast(data.len));
        try appendInt(&output, allocator, u32, @intCast(data.len));
        try appendInt(&output, allocator, u16, @intCast(entry.name.len));
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u16, 0);
        try appendInt(&output, allocator, u32, if (is_directory) 0x41ed0010 else 0x81a40000);
        try appendInt(&output, allocator, u32, offsets[index]);
        try output.appendSlice(allocator, entry.name);
    }
    const central_size = output.items.len - central_offset;
    try appendInt(&output, allocator, u32, 0x06054b50);
    try appendInt(&output, allocator, u16, 0);
    try appendInt(&output, allocator, u16, 0);
    try appendInt(&output, allocator, u16, @intCast(entries.len));
    try appendInt(&output, allocator, u16, @intCast(entries.len));
    try appendInt(&output, allocator, u32, @intCast(central_size));
    try appendInt(&output, allocator, u32, @intCast(central_offset));
    try appendInt(&output, allocator, u16, 0);
    return output.toOwnedSlice(allocator);
}

fn writeTestZip(temporary: *std.testing.TmpDir, archive: []const u8) ![]u8 {
    const io = std.testing.io;
    try temporary.dir.writeFile(io, .{ .sub_path = "input.zip", .data = archive });
    const root = try temporary.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    return std.fs.path.join(std.testing.allocator, &.{ root, "input.zip" });
}

fn testOutputPath(temporary: *std.testing.TmpDir) ![]u8 {
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    return std.fs.path.join(std.testing.allocator, &.{ root, "output" });
}

fn destEntryNames(temporary: *std.testing.TmpDir) ![][]const u8 {
    var directory = try temporary.dir.openDir(std.testing.io, "output", .{ .iterate = true });
    defer directory.close(std.testing.io);
    var iterator = directory.iterate();
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(std.testing.allocator);
    while (try iterator.next(std.testing.io)) |entry| {
        try names.append(std.testing.allocator, try std.testing.allocator.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(std.testing.allocator);
}

test "deflate ZIPのnested・空directoryを展開する" {
    // python3 zipfile(ZIP_DEFLATED)で生成したfixture:
    // nested/dir/hello.txt = "deflate-body"、empty/ = 空directory
    const deflate_zip =
        "\x50\x4b\x03\x04\x14\x00\x00\x00\x08\x00\x64\x6c\x28\x5d\x0a\x58\x4e\x88\x0e\x00\x00\x00\x0c\x00\x00\x00\x14\x00\x00\x00\x6e\x65\x73\x74\x65\x64\x2f\x64\x69\x72\x2f\x68\x65\x6c\x6c\x6f\x2e\x74\x78\x74\x4b\x49\x4d\xcb\x49\x2c\x49\xd5\x4d\xca\x4f\xa9\x04\x00\x50\x4b\x03\x04\x14\x00\x00\x00\x08\x00\x64\x6c\x28\x5d\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x06\x00\x00\x00\x65\x6d\x70\x74\x79\x2f\x03\x00\x50\x4b\x01\x02\x14\x03\x14\x00\x00\x00\x08\x00\x64\x6c\x28\x5d\x0a\x58\x4e\x88\x0e\x00\x00\x00\x0c\x00\x00\x00\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x00\x00\x00\x00\x6e\x65\x73\x74\x65\x64\x2f\x64\x69\x72\x2f\x68\x65\x6c\x6c\x6f\x2e\x74\x78\x74\x50\x4b\x01\x02\x14\x03\x14\x00\x00\x00\x08\x00\x64\x6c\x28\x5d\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x06\x00\x00\x00\x00\x00\x00\x00\x00\x00\x10\x00\xfd\x41\x40\x00\x00\x00\x65\x6d\x70\x74\x79\x2f\x50\x4b\x05\x06\x00\x00\x00\x00\x02\x00\x02\x00\x76\x00\x00\x00\x66\x00\x00\x00\x00\x00";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const zip_path = try writeTestZip(&temporary, deflate_zip);
    defer std.testing.allocator.free(zip_path);
    const output_path = try testOutputPath(&temporary);
    defer std.testing.allocator.free(output_path);
    try extract(io, zip_path, output_path);

    const extracted = try std.fs.path.join(std.testing.allocator, &.{ output_path, "nested/dir/hello.txt" });
    defer std.testing.allocator.free(extracted);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, extracted, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("deflate-body", bytes);
    const empty_stat = try temporary.dir.statFile(io, "output/empty", .{ .follow_symlinks = false });
    try std.testing.expect(empty_stat.kind == .directory);
}

test "ZIP展開は中間成分の既存linkを追跡しない" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.createDir(io, "outside", .default_dir);
    try temporary.dir.createDir(io, "output", .default_dir);
    temporary.dir.symLink(io, "../outside", "output/link", .{ .is_directory = true }) catch |err| switch (err) {
        // Windows等でlink作成権限がない環境では検証を省略する。
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
    const archive = try buildTestZip(std.testing.allocator, &.{
        .{ .name = "link/evil.txt", .data = "escaped" },
    });
    defer std.testing.allocator.free(archive);
    const zip_path = try writeTestZip(&temporary, archive);
    defer std.testing.allocator.free(zip_path);
    const output_path = try testOutputPath(&temporary);
    defer std.testing.allocator.free(output_path);
    // no-followのopenはlinkをdirとして開けず失敗する（ENOTDIRまたはELOOP）。
    const link_result = extract(io, zip_path, output_path);
    try std.testing.expect(link_result == error.NotDir or link_result == error.SymLinkLoop);
    // 出力先の外へfileが作成されない。
    try std.testing.expectError(error.FileNotFound, temporary.dir.statFile(io, "outside/evil.txt", .{}));
    // link自体は変更されない。
    const stat = try temporary.dir.statFile(io, "output/link", .{ .follow_symlinks = false });
    try std.testing.expect(stat.kind == .sym_link);
    // 隔離dirが残らない。
    const names = try destEntryNames(&temporary);
    defer {
        for (names) |name| std.testing.allocator.free(name);
        std.testing.allocator.free(names);
    }
    try std.testing.expectEqual(@as(usize, 1), names.len);
    try std.testing.expectEqualStrings("link", names[0]);
}

test "ZIP展開は最終成分の既存linkとfileを上書きしない" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    try temporary.dir.createDir(io, "outside", .default_dir);
    try temporary.dir.writeFile(io, .{ .sub_path = "outside/target.txt", .data = "keep" });
    try temporary.dir.createDir(io, "output", .default_dir);
    try temporary.dir.writeFile(io, .{ .sub_path = "output/exists.txt", .data = "original" });
    temporary.dir.symLink(io, "../outside/target.txt", "output/link.txt", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileSystem => return error.SkipZigTest,
        else => return err,
    };
    const archive = try buildTestZip(std.testing.allocator, &.{
        .{ .name = "link.txt", .data = "overwrite" },
        .{ .name = "exists.txt", .data = "overwrite" },
    });
    defer std.testing.allocator.free(archive);
    const zip_path = try writeTestZip(&temporary, archive);
    defer std.testing.allocator.free(zip_path);
    const output_path = try testOutputPath(&temporary);
    defer std.testing.allocator.free(output_path);
    try std.testing.expectError(error.PathAlreadyExists, extract(io, zip_path, output_path));
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ output_path, "..", "outside", "target.txt" });
    defer std.testing.allocator.free(target_path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, target_path, std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("keep", bytes);
    const stat = try temporary.dir.statFile(io, "output/link.txt", .{ .follow_symlinks = false });
    try std.testing.expect(stat.kind == .sym_link);
}

test "不正なZIP entry名を拒否し隔離dirを残さない" {
    const bad_names = [_][]const u8{ "../escape.txt", "a:b.txt", "a\x01b.txt", "sub/../../escape.txt" };
    for (bad_names) |name| {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        const io = std.testing.io;
        const archive = try buildTestZip(std.testing.allocator, &.{.{ .name = name, .data = "x" }});
        defer std.testing.allocator.free(archive);
        const zip_path = try writeTestZip(&temporary, archive);
        defer std.testing.allocator.free(zip_path);
        const output_path = try testOutputPath(&temporary);
        defer std.testing.allocator.free(output_path);
        try std.testing.expectError(error.ZipBadFilename, extract(io, zip_path, output_path));
        // 隔離dirを含めて出力先へ何も残さない。
        var directory = try temporary.dir.openDir(io, "output", .{ .iterate = true });
        defer directory.close(io);
        var iterator = directory.iterate();
        try std.testing.expect((try iterator.next(io)) == null);
    }
}

test "CRC不一致では検証済みfile以外を出力先へ残さない" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = std.testing.io;
    const archive = try buildTestZip(std.testing.allocator, &.{
        .{ .name = "corrupt.txt", .data = "corrupt-data" },
    });
    defer std.testing.allocator.free(archive);
    const index = std.mem.indexOf(u8, archive, "corrupt-data").?;
    archive[index] ^= 0xff;
    const zip_path = try writeTestZip(&temporary, archive);
    defer std.testing.allocator.free(zip_path);
    const output_path = try testOutputPath(&temporary);
    defer std.testing.allocator.free(output_path);
    try std.testing.expectError(error.ZipChecksumMismatch, extract(io, zip_path, output_path));
    var directory = try temporary.dir.openDir(io, "output", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    try std.testing.expect((try iterator.next(io)) == null);
}
