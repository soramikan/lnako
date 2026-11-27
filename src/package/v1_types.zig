//! パッケージ形式 v1 の共通型と構文検証（仕様 §1・§2）。
//!
//! このファイルは識別子・公開バージョン・ハッシュ・target triple・
//! SPDX 式・相対パスの純粋な検証と、manifest / index / lock が共有する
//! 小さな型を提供する。ファイル I/O・TOML 解析・依存解決は持たない。

const std = @import("std");
const semver = @import("semver.zig");
const spdx = @import("v1_spdx.zig");

pub const Runtime = enum { lnako, cnako, wnako };

pub const Kind = enum { universal, esm, @"native-source", @"native-prebuilt" };

pub const Binding = enum { scoped, global };

/// アーティファクトの配信元。`registry` はレジストリの基底 URL 配下、
/// `external` は許可済み外部ホストを指す。
pub const Hosting = enum { registry, external };

pub const Capability = enum {
    @"pure-nako",
    native,
    ffi,
    fs,
    net,
    env,
    process,
    unsafe,
};

/// 依存の宣言。`runtimes` が空なら全ランタイム共通（METADATA.toml の既定）。
pub const Dependency = struct {
    id: []const u8,
    req: []const u8,
    alias: ?[]const u8 = null,
    features: []const []const u8 = &.{},
    default_features: bool = true,
    optional: bool = false,
    runtimes: []const Runtime = &.{},
    allow_global_commands: bool = false,
};

/// 配布アーティファクト。`target_triple` は `native-prebuilt`、
/// `abi_version` は native 系、`glibc_min` は GNU Linux の
/// `native-prebuilt` でだけ使う。
pub const Artifact = struct {
    kind: Kind,
    runtimes: []const Runtime,
    target_triple: ?[]const u8 = null,
    abi_version: ?u32 = null,
    glibc_min: ?[]const u8 = null,
    sha256: []const u8 = "",
    url: []const u8 = "",
    size: u64 = 0,
    hosting: Hosting = .registry,
};

/// 一般利用者の登録を拒否する予約 scope（仕様 §1.1）。
/// 構文検証では受理し、登録権限の検査でのみ拒否する。
pub const reserved_scopes = [_][]const u8{
    "std",
    "nako",
    "nadesiko",
    "nadesiko3",
    "lnako",
    "cnako",
    "wnako",
    "core",
    "official",
    "registry",
    "system",
    "internal",
};

pub const known_capabilities = [_]Capability{
    .@"pure-nako",
    .native,
    .ffi,
    .fs,
    .net,
    .env,
    .process,
    .unsafe,
};

/// `@{scope}/{name}` 全体を検証する。予約 scope も構文上は受理する。
pub fn validId(id: []const u8) bool {
    if (id.len < 3 or id[0] != '@') return false;
    const slash = std.mem.indexOfScalar(u8, id, '/') orelse return false;
    const scope = id[1..slash];
    const name = id[slash + 1 ..];
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    return validScope(scope) and validName(name);
}

/// `^[a-z][a-z0-9-]{1,38}$`、末尾 `-` と `--` を拒否。
pub fn validScope(scope: []const u8) bool {
    return validSegment(scope, 2, 39);
}

/// `^[a-z][a-z0-9-]{0,63}$`、末尾 `-` と `--` を拒否。
pub fn validName(name: []const u8) bool {
    return validSegment(name, 1, 64);
}

fn validSegment(text: []const u8, min_len: usize, max_len: usize) bool {
    if (text.len < min_len or text.len > max_len) return false;
    if (!std.ascii.isLower(text[0])) return false;
    var previous_hyphen = false;
    for (text) |byte| {
        const ok = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-';
        if (!ok) return false;
        if (previous_hyphen and byte == '-') return false;
        previous_hyphen = byte == '-';
    }
    return text[text.len - 1] != '-';
}

pub fn isReservedScope(scope: []const u8) bool {
    for (reserved_scopes) |reserved| {
        if (std.mem.eql(u8, scope, reserved)) return true;
    }
    return false;
}

/// 予約判定の純粋関数。構文検証とは独立して呼ぶ（ID-04）。
pub fn isReservedId(id: []const u8) bool {
    if (!validId(id)) return false;
    const slash = std.mem.indexOfScalar(u8, id, '/').?;
    return isReservedScope(id[1..slash]);
}

/// 公開バージョン。SemVer 2.0.0 に厳格に従い、build metadata を拒否する。
/// 3 要素と prerelease 識別子の構文だけを検証し、数値要素の長さ・値には
/// 上限を設けない（仕様 §1.2）。node-semver の Number.MAX_SAFE_INTEGER
/// 制限は range 適合判定（`semver.Version.parse`）側にだけ残す。
pub fn validPublicVersion(text: []const u8) bool {
    // 公開バージョンは build metadata を持たない。
    if (std.mem.indexOfScalar(u8, text, '+') != null) return false;

    var core = text;
    if (std.mem.indexOfScalar(u8, core, '-')) |dash| {
        if (!validPrerelease(core[dash + 1 ..])) return false;
        core = core[0..dash];
    }

    var parts = std.mem.splitScalar(u8, core, '.');
    const major = parts.next() orelse return false;
    const minor = parts.next() orelse return false;
    const patch = parts.next() orelse return false;
    if (parts.next() != null) return false;
    return validVersionNumber(major) and validVersionNumber(minor) and validVersionNumber(patch);
}

/// `0` または先頭が非ゼロの 10 進数字列。長さ・値の上限はない。
fn validVersionNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text.len > 1 and text[0] == '0') return false;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) return false;
    }
    return true;
}

/// `-` 以降の prerelease。`.` 区切りの非空識別子で、各文字は
/// `[0-9A-Za-z-]`。数字だけの識別子は `0` 以外で先頭ゼロを禁止する。
fn validPrerelease(text: []const u8) bool {
    if (text.len == 0) return false;
    var parts = std.mem.splitScalar(u8, text, '.');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        var numeric = true;
        for (part) |byte| {
            if (!(std.ascii.isAlphanumeric(byte) or byte == '-')) return false;
            if (!std.ascii.isDigit(byte)) numeric = false;
        }
        if (numeric and part.len > 1 and part[0] == '0') return false;
    }
    return true;
}

/// `sha256:` + 小文字 16 進 64 桁。
pub fn validHash(text: []const u8) bool {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, text, prefix)) return false;
    const digest = text[prefix.len..];
    if (digest.len != 64) return false;
    for (digest) |byte| {
        const is_hex_lower = std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f');
        if (!is_hex_lower) return false;
    }
    return true;
}

/// LLVM/Zig 形式の `{arch}-{os}-{abi}`。3 成分固定。
pub fn validTargetTriple(text: []const u8) bool {
    var parts = std.mem.splitScalar(u8, text, '-');
    const arch = parts.next() orelse return false;
    const os = parts.next() orelse return false;
    const abi = parts.next() orelse return false;
    if (parts.next() != null) return false;
    if (!containsString(&target_arches, arch)) return false;
    if (!containsString(&target_oses, os)) return false;
    if (!containsString(&target_abis, abi)) return false;
    return targetAbiConsistent(os, abi);
}

fn targetAbiConsistent(os: []const u8, abi: []const u8) bool {
    if (std.mem.eql(u8, abi, "msvc")) return std.mem.eql(u8, os, "windows");
    if (std.mem.eql(u8, os, "windows")) {
        return std.mem.eql(u8, abi, "msvc") or std.mem.eql(u8, abi, "gnu") or std.mem.eql(u8, abi, "none");
    }
    if (std.mem.eql(u8, os, "macos") or std.mem.eql(u8, os, "ios") or
        std.mem.eql(u8, os, "tvos") or std.mem.eql(u8, os, "watchos") or
        std.mem.eql(u8, os, "visionos"))
    {
        return std.mem.eql(u8, abi, "none") or std.mem.eql(u8, abi, "macho");
    }
    if (std.mem.eql(u8, os, "linux")) {
        return isLinuxAbi(abi);
    }
    return true;
}

fn isLinuxAbi(abi: []const u8) bool {
    const allowed = [_][]const u8{
        "none",       "gnu",       "gnueabi",    "gnueabihf",
        "gnuabi64",   "gnuabin32", "gnuilp32",   "gnuf32",
        "gnuf64",     "gnusf",     "gnusf64",    "gnux32",
        "musl",       "musleabi",  "musleabihf", "muslabi64",
        "muslabin32", "muslilp32", "android",    "androideabi",
    };
    return containsString(&allowed, abi);
}

/// SPDX 2.3.1 のライセンス式。固定した SPDX License List 3.27.0 で照合する。
pub fn validLicense(text: []const u8) bool {
    return spdx.isValid(text);
}

/// パッケージ内の相対パス。`/` 区切り、`.`/`..` 成分、先頭 `/`、
/// バックスラッシュ、制御文字、ドライブ文字を拒否する。
/// `*`/`?` は仕様の relativePath と同じくリテラル文字として許可する。
pub fn validPath(path: []const u8) bool {
    return validRelativePath(path);
}

/// `include` 用の相対 glob。禁止規則は `validPath` と同じ。
pub fn validGlobPattern(pattern: []const u8) bool {
    return validRelativePath(pattern);
}

fn validRelativePath(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    if (text[0] == '/' or text[0] == '\\') return false;

    var count: usize = 0;
    var segments = std.mem.splitScalar(u8, text, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        if (segment.len >= 2 and std.ascii.isAlphabetic(segment[0]) and segment[1] == ':') return false;
        for (segment) |byte| {
            if (byte == '\\') return false;
            if (byte < 0x20 or byte == 0x7f) return false;
        }
        if (!validControlCodepoints(segment)) return false;
        count += 1;
    }
    return count > 0;
}

/// UTF-8 の C1 制御文字（U+0080..U+009F）を拒否する。
fn validControlCodepoints(text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch return false;
        const codepoint = std.unicode.utf8Decode(text[index .. index + length]) catch return false;
        if (codepoint >= 0x80 and codepoint <= 0x9f) return false;
        index += length;
    }
    return true;
}

/// feature 名・依存の alias に使えるローカル名。
pub fn validLocalName(text: []const u8) bool {
    if (text.len == 0) return false;
    if (!std.unicode.utf8ValidateSlice(text)) return false;
    if (std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "..")) return false;
    if (!validControlCodepoints(text)) return false;
    for (text) |byte| {
        if (std.ascii.isWhitespace(byte)) return false;
        if (byte == '/' or byte == '\\') return false;
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return true;
}

pub fn validFeatureName(text: []const u8) bool {
    return validLocalName(text);
}

pub fn validAlias(text: []const u8) bool {
    return validLocalName(text);
}

/// v1 の依存・engine 範囲を node-semver 7.7.4 の既定 API として解析する。
/// 旧内部 API（`semver.Range.parse`）の厳格な wildcard 規則とは分離し、
/// `1.x.5`・`*.1`・`*.*.*-alpha` を実 node-semver と同じ展開で受理する。
pub fn parseRange(allocator: std.mem.Allocator, text: []const u8) semver.Error!semver.Range {
    return semver.Range.parseNodeSemver(allocator, text);
}

/// node-semver 7.7.4 の既定範囲構文として妥当なら true。
/// 空文字列は node-semver と同じく wildcard として受理する。
pub fn validRange(allocator: std.mem.Allocator, text: []const u8) bool {
    var range = parseRange(allocator, text) catch return false;
    range.deinit(allocator);
    return true;
}

/// `major.minor[.patch]` 形式の glibc 最小版。
pub fn validGlibcVersion(text: []const u8) bool {
    if (text.len == 0) return false;
    var parts = std.mem.splitScalar(u8, text, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |byte| {
            if (!std.ascii.isDigit(byte)) return false;
        }
        count += 1;
    }
    return count >= 2;
}

pub fn containsString(list: []const []const u8, text: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, text)) return true;
    }
    return false;
}

pub fn runtimeName(runtime: Runtime) []const u8 {
    return @tagName(runtime);
}

pub fn kindName(kind: Kind) []const u8 {
    return @tagName(kind);
}

pub fn bindingName(binding: Binding) []const u8 {
    return @tagName(binding);
}

pub fn parseRuntime(text: []const u8) ?Runtime {
    inline for (@typeInfo(Runtime).@"enum".field_names) |name| {
        if (std.mem.eql(u8, text, name)) return @field(Runtime, name);
    }
    return null;
}

pub fn parseKind(text: []const u8) ?Kind {
    inline for (@typeInfo(Kind).@"enum".field_names) |name| {
        if (std.mem.eql(u8, text, name)) return @field(Kind, name);
    }
    return null;
}

pub fn parseBinding(text: []const u8) ?Binding {
    inline for (@typeInfo(Binding).@"enum".field_names) |name| {
        if (std.mem.eql(u8, text, name)) return @field(Binding, name);
    }
    return null;
}

pub fn parseCapability(text: []const u8) ?Capability {
    inline for (@typeInfo(Capability).@"enum".field_names) |name| {
        if (std.mem.eql(u8, text, name)) return @field(Capability, name);
    }
    return null;
}

const target_arches = [_][]const u8{
    "aarch64", "aarch64_be",  "amdgcn",      "arm",         "armeb",
    "avr",     "bpfeb",       "bpfel",       "csky",        "hexagon",
    "lanai",   "loongarch32", "loongarch64", "m68k",        "mips",
    "mips64",  "mips64el",    "mipsel",      "msp430",      "nvptx",
    "nvptx64", "powerpc",     "powerpc64",   "powerpc64le", "r600",
    "riscv32", "riscv64",     "s390x",       "sparc",       "sparc64",
    "spirv",   "spirv32",     "spirv64",     "thumb",       "thumbeb",
    "ve",      "wasm32",      "wasm64",      "x86",         "x86_64",
    "xcore",   "xtensa",
};

const target_oses = [_][]const u8{
    "aix",          "android",  "cuda",     "dragonfly", "emscripten",
    "freestanding", "fuchsia",  "haiku",    "hermit",    "hurd",
    "illumos",      "ios",      "linux",    "lv2",       "macos",
    "netbsd",       "none",     "openbsd",  "plan9",     "ps4",
    "ps5",          "rtems",    "serenity", "solaris",   "tvos",
    "uefi",         "visionos", "wasi",     "watchos",   "windows",
    "xros",
};

const target_abis = [_][]const u8{
    "none",      "gnu",      "gnuabin32",  "gnuabi64",  "gnueabi",
    "gnueabihf", "gnuf32",   "gnuf64",     "gnuilp32",  "gnusf",
    "gnusf64",   "gnux32",   "code16",     "eabi",      "eabihf",
    "musl",      "musleabi", "musleabihf", "muslabi64", "muslabin32",
    "muslilp32", "msvc",     "itanium",    "cygnus",    "coreclr",
    "simulator", "macabi",   "android",    "haiku",     "ohos",
    "macho",     "elf",      "coff",       "wasm",      "c",
    "cpp",       "ilp32",    "llvm",
};

test {
    _ = @import("v1_types_test.zig");
}
