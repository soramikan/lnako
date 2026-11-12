//! 動的ライブラリの依存列挙（Issue #56 の推移的依存同梱）。
//!
//! `--bundle-deps` は plugin 本体だけを payload へ複製するため、plugin が
//! private 共有ライブラリへ依存していると移動後に dlopen が失敗する。
//! ここで依存を列挙し、OS 標準以外を payload へ複製する対象として返す。
//!
//! 記載名（install_name / DT_NEEDED）の書き換えは本 module の範囲外。
//! 詳しい理由は `docs/compatibility/AOT.md` を参照。
const std = @import("std");
const builtin = @import("builtin");

pub const Dependency = struct {
    /// 依存の記載名（Mach-O の install name / ELF の DT_NEEDED）。
    name: []const u8,
};

/// 同梱対象外とみなす依存か（OS 標準ライブラリ）。
/// 配布先にも存在するため payload へ複製しない。
pub fn isSystemLibrary(name: []const u8) bool {
    if (std.mem.startsWith(u8, name, "/usr/lib/")) return true;
    if (std.mem.startsWith(u8, name, "/System/")) return true;
    if (std.mem.startsWith(u8, name, "/lib/")) return true;
    if (std.mem.startsWith(u8, name, "/lib64/")) return true;
    if (std.mem.startsWith(u8, name, "@rpath/libc")) return true;
    if (std.mem.endsWith(u8, name, "libSystem.B.dylib")) return true;
    // ELF の動的ローダは PT_INTERP 側で選ばれる。payload へ複製しても
    // 使われないうえ、配置を移すと起動できなくなるため対象外とする。
    if (std.mem.startsWith(u8, name, "ld-linux")) return true;
    if (std.mem.startsWith(u8, name, "ld-musl")) return true;
    if (isWindowsSystemDll(name)) return true;
    return false;
}

fn isWindowsSystemDll(name: []const u8) bool {
    const known = [_][]const u8{
        "kernel32.dll", "user32.dll", "advapi32.dll",  "ntdll.dll",
        "ws2_32.dll",   "vcruntime",  "ucrtbase.dll",  "api-ms-win-",
        "msvcrt.dll",   "bcrypt.dll", "ole32.dll",     "shell32.dll",
        "libc.so",      "libm.so",    "libpthread.so",
    };
    var lower_buf: [260]u8 = undefined;
    if (name.len > lower_buf.len) return false;
    for (name, 0..) |ch, index| lower_buf[index] = std.ascii.toLower(ch);
    const lower = lower_buf[0..name.len];
    for (known) |prefix| {
        if (std.mem.startsWith(u8, lower, prefix)) return true;
    }
    return false;
}

/// この binary が対象 OS の共有ライブラリ形式か（列挙の前提判定）。
pub fn looksLikeSharedLibrary(bytes: []const u8) bool {
    if (bytes.len < 8) return false;
    if (std.mem.eql(u8, bytes[0..4], "\x7fELF")) return true;
    const magic_be = std.mem.readInt(u32, bytes[0..4], .big);
    const magic_le = std.mem.readInt(u32, bytes[0..4], .little);
    const macho_magics = [_]u32{ 0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe };
    for (macho_magics) |magic| {
        if (magic_be == magic or magic_le == magic) return true;
    }
    return false;
}

/// 動的ライブラリの依存記載名を列挙する（OS 標準も含む）。
/// 解析できない binary（PE・object file 等）は空を返す。
pub fn dependencies(allocator: std.mem.Allocator, bytes: []const u8) ![]Dependency {
    if (bytes.len < 32) return &.{};
    if (std.mem.eql(u8, bytes[0..4], "\x7fELF")) return elfDependencies(allocator, bytes);
    return machoDependencies(allocator, bytes);
}

fn readU32Le(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn readU32Be(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

/// Mach-O（thin）の `LC_LOAD_DYLIB` 系から依存名を列挙する。
fn machoDependencies(allocator: std.mem.Allocator, bytes: []const u8) ![]Dependency {
    var list: std.ArrayListUnmanaged(Dependency) = .empty;
    errdefer list.deinit(allocator);
    // Mach-O のマジックはファイル先頭 4 byte に格納順で書かれる。thin の
    // little-endian ファイルは LE 読みで 0xfeedfacf(64bit)/0xfeedface(32bit)
    // になり、ファイル先頭は cffaedfe / cefaedfe と見える。
    const magic = readU32Le(bytes, 0) orelse return list.toOwnedSlice(allocator);
    const is64 = magic == 0xfeedfacf;
    if (!is64 and magic != 0xfeedface) return list.toOwnedSlice(allocator);
    const header_size: usize = if (is64) 32 else 28;
    const ncmds = readU32Le(bytes, 16) orelse return list.toOwnedSlice(allocator);
    var offset = header_size;
    var index: u32 = 0;
    while (index < ncmds) : (index += 1) {
        const cmd = readU32Le(bytes, offset) orelse break;
        const cmdsize = readU32Le(bytes, offset + 4) orelse break;
        if (cmdsize < 8) break;
        const end_of_cmd = offset + cmdsize;
        if (end_of_cmd > bytes.len) break;
        switch (cmd) {
            0xc, 0x80000018, 0x8000001f, 0x80000023 => {
                // dylib_command の name はコマンド先頭からの相対 offset。
                const name_off = readU32Le(bytes, offset + 8) orelse {
                    offset = end_of_cmd;
                    continue;
                };
                if (name_off < cmdsize) {
                    const start = offset + name_off;
                    const end = std.mem.indexOfScalarPos(u8, bytes[0..end_of_cmd], start, 0) orelse end_of_cmd;
                    if (end > start) {
                        try list.append(allocator, .{ .name = try allocator.dupe(u8, bytes[start..end]) });
                    }
                }
            },
            else => {},
        }
        offset = end_of_cmd;
    }
    return list.toOwnedSlice(allocator);
}

/// ELF の `DT_NEEDED` から依存名を列挙する。
fn elfDependencies(allocator: std.mem.Allocator, bytes: []const u8) ![]Dependency {
    var list: std.ArrayListUnmanaged(Dependency) = .empty;
    errdefer list.deinit(allocator);
    if (bytes.len < 64) return list.toOwnedSlice(allocator);
    const is64 = bytes[4] == 2;
    const little = bytes[5] == 1;
    const phoff: u64 = if (is64)
        readU64(bytes, 32, little) orelse return list.toOwnedSlice(allocator)
    else
        readU32(bytes, 28, little) orelse return list.toOwnedSlice(allocator);
    const phentsize: u16 = if (is64)
        readU16(bytes, 54, little) orelse return list.toOwnedSlice(allocator)
    else
        readU16(bytes, 42, little) orelse return list.toOwnedSlice(allocator);
    const phnum: u16 = if (is64)
        readU16(bytes, 56, little) orelse return list.toOwnedSlice(allocator)
    else
        readU16(bytes, 44, little) orelse return list.toOwnedSlice(allocator);
    // PT_LOAD の vaddr→file offset 対応（DT_STRTAB の vaddr を file offset へ）。
    var strtab_vaddr: ?u64 = null;
    var needed_offsets: [128]u64 = undefined;
    var needed_count: usize = 0;
    var index: u16 = 0;
    const ph_start: usize = @intCast(phoff);
    while (index < phnum) : (index += 1) {
        const base = ph_start + @as(usize, index) * phentsize;
        const p_type = readU32(bytes, base, little) orelse break;
        if (p_type != 2) continue; // PT_DYNAMIC
        const dyn_off: u64 = if (is64)
            readU64(bytes, base + 8, little) orelse break
        else
            readU32(bytes, base + 4, little) orelse break;
        const dyn_size: u64 = if (is64)
            readU64(bytes, base + 32, little) orelse break
        else
            readU32(bytes, base + 16, little) orelse break;
        const entry_size: u64 = if (is64) 16 else 8;
        var cursor: u64 = dyn_off;
        const dyn_end = dyn_off + dyn_size;
        while (cursor + entry_size <= dyn_end and cursor + entry_size <= bytes.len) : (cursor += entry_size) {
            const tag: i64 = if (is64)
                @bitCast(readU64(bytes, @intCast(cursor), little) orelse break)
            else
                @as(i64, @intCast(readU32(bytes, @intCast(cursor), little) orelse break));
            const value: u64 = if (is64)
                readU64(bytes, @intCast(cursor + 8), little) orelse break
            else
                readU32(bytes, @intCast(cursor + 4), little) orelse break;
            if (tag == 0) break; // DT_NULL
            if (tag == 1 and needed_count < needed_offsets.len) {
                needed_offsets[needed_count] = value;
                needed_count += 1;
            } else if (tag == 5) {
                strtab_vaddr = value;
            }
        }
    }
    const strtab_v = strtab_vaddr orelse return list.toOwnedSlice(allocator);
    const strtab = vaddrToOffset(bytes, is64, little, strtab_v) orelse return list.toOwnedSlice(allocator);
    for (needed_offsets[0..needed_count]) |offset_in_strtab| {
        const start_u64 = strtab + offset_in_strtab;
        if (start_u64 >= bytes.len) continue;
        const start: usize = @intCast(start_u64);
        const end = std.mem.indexOfScalarPos(u8, bytes, start, 0) orelse bytes.len;
        if (end > start) {
            try list.append(allocator, .{ .name = try allocator.dupe(u8, bytes[start..end]) });
        }
    }
    return list.toOwnedSlice(allocator);
}

/// ELF の仮想アドレスを program header の PT_LOAD からファイル offset へ写す。
fn vaddrToOffset(bytes: []const u8, is64: bool, little: bool, vaddr: u64) ?usize {
    const phoff: u64 = if (is64)
        readU64(bytes, 32, little) orelse return null
    else
        readU32(bytes, 28, little) orelse return null;
    const phentsize: u16 = if (is64)
        readU16(bytes, 54, little) orelse return null
    else
        readU16(bytes, 42, little) orelse return null;
    const phnum: u16 = if (is64)
        readU16(bytes, 56, little) orelse return null
    else
        readU16(bytes, 44, little) orelse return null;
    var index: u16 = 0;
    const ph_start: usize = @intCast(phoff);
    while (index < phnum) : (index += 1) {
        const base = ph_start + @as(usize, index) * phentsize;
        const p_type = readU32(bytes, base, little) orelse return null;
        if (p_type != 1) continue; // PT_LOAD
        const p_offset: u64 = if (is64)
            readU64(bytes, base + 8, little) orelse continue
        else
            readU32(bytes, base + 4, little) orelse continue;
        const p_vaddr: u64 = if (is64)
            readU64(bytes, base + 16, little) orelse continue
        else
            readU32(bytes, base + 8, little) orelse continue;
        const p_filesz: u64 = if (is64)
            readU64(bytes, base + 32, little) orelse continue
        else
            readU32(bytes, base + 16, little) orelse continue;
        if (vaddr >= p_vaddr and vaddr < p_vaddr + p_filesz) {
            const delta = vaddr - p_vaddr;
            return @intCast(p_offset + delta);
        }
    }
    return null;
}

fn readU16(bytes: []const u8, offset: usize, little: bool) ?u16 {
    if (offset + 2 > bytes.len) return null;
    return std.mem.readInt(u16, bytes[offset..][0..2], if (little) .little else .big);
}

fn readU32(bytes: []const u8, offset: usize, little: bool) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], if (little) .little else .big);
}

fn readU64(bytes: []const u8, offset: usize, little: bool) ?u64 {
    if (offset + 8 > bytes.len) return null;
    return std.mem.readInt(u64, bytes[offset..][0..8], if (little) .little else .big);
}

const testing = std.testing;

test "isSystemLibraryはOS標準ライブラリを対象外にする" {
    try testing.expect(isSystemLibrary("/usr/lib/libSystem.B.dylib"));
    try testing.expect(isSystemLibrary("/System/Library/Frameworks/AppKit.framework/AppKit"));
    try testing.expect(isSystemLibrary("/lib/x86_64-linux-gnu/libc.so.6"));
    try testing.expect(isSystemLibrary("/lib64/libm.so.6"));
    try testing.expect(isSystemLibrary("libc.so.6"));
    try testing.expect(isSystemLibrary("ld-linux-x86-64.so.2"));
    try testing.expect(isSystemLibrary("kernel32.dll"));
    try testing.expect(isSystemLibrary("api-ms-win-crt-runtime-l1-1-0.dll"));
    // private 依存は対象外にしない。
    try testing.expect(!isSystemLibrary("libhelper.dylib"));
    try testing.expect(!isSystemLibrary("@rpath/libhelper.dylib"));
    try testing.expect(!isSystemLibrary("./libhelper.so"));
    try testing.expect(!isSystemLibrary("my_helper.dll"));
}

test "looksLikeSharedLibraryはELFとMach-Oを判定する" {
    try testing.expect(looksLikeSharedLibrary("\x7fELF\x02\x01\x01\x00"));
    try testing.expect(looksLikeSharedLibrary("\xcf\xfa\xed\xfe\x0c\x00\x00\x01"));
    try testing.expect(looksLikeSharedLibrary("\xce\xfa\xed\xfe\x07\x00\x00\x01"));
    try testing.expect(!looksLikeSharedLibrary("MZ\x90\x00\x03\x00\x00\x00"));
    try testing.expect(!looksLikeSharedLibrary("\x00\x00"));
}

test "dependenciesは解析できない入力を空にする" {
    var short = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(usize, 0), (try dependencies(testing.allocator, &short)).len);
    const pe = "MZ\x90\x00\x03\x00\x00\x00\x04\x00\x00\x00\xff\xff\x00\x00\xb8\x00\x00\x00\x00\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00";
    try testing.expectEqual(@as(usize, 0), (try dependencies(testing.allocator, pe)).len);
}

test "machoDependenciesはLC_LOAD_DYLIBのinstall nameを読む" {
    // 64bit Mach-O: header(32) + 2 command。
    // 1: LC_LOAD_DYLIB(0xc) name offset 24, name="@rpath/libhelper.dylib"
    // 2: LC_LOAD_DYLIB(0xc) name offset 24, name="/usr/lib/libSystem.B.dylib"
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = "@rpath/libhelper.dylib";
    const second = "/usr/lib/libSystem.B.dylib";
    const first_size = std.mem.alignForward(usize, 24 + first.len + 1, 8);
    const second_size = std.mem.alignForward(usize, 24 + second.len + 1, 8);
    const total = 32 + first_size + second_size;
    const bytes = try a.alloc(u8, total);
    @memset(bytes, 0);
    std.mem.writeInt(u32, bytes[0..4], 0xfeedfacf, .little);
    std.mem.writeInt(u32, bytes[16..20], 2, .little);
    std.mem.writeInt(u32, bytes[20..24], @intCast(first_size + second_size), .little);
    var offset: usize = 32;
    std.mem.writeInt(u32, bytes[offset..][0..4], 0xc, .little);
    std.mem.writeInt(u32, bytes[offset + 4 ..][0..4], @intCast(first_size), .little);
    std.mem.writeInt(u32, bytes[offset + 8 ..][0..4], 24, .little);
    @memcpy(bytes[offset + 24 ..][0..first.len], first);
    offset += first_size;
    std.mem.writeInt(u32, bytes[offset..][0..4], 0xc, .little);
    std.mem.writeInt(u32, bytes[offset + 4 ..][0..4], @intCast(second_size), .little);
    std.mem.writeInt(u32, bytes[offset + 8 ..][0..4], 24, .little);
    @memcpy(bytes[offset + 24 ..][0..second.len], second);

    const list = try dependencies(a, bytes);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("@rpath/libhelper.dylib", list[0].name);
    try testing.expectEqualStrings("/usr/lib/libSystem.B.dylib", list[1].name);
    try testing.expect(!isSystemLibrary(list[0].name));
    try testing.expect(isSystemLibrary(list[1].name));
}
