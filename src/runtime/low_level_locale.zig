const std = @import("std");
const builtin = @import("builtin");
const unicode_properties = @import("unicode_properties");
const unicode_width = @import("unicode_width");

/// Issue #38: ロケール文字列比較・端末表示幅の共有実装。
/// Interpreter（`plugins/lowlevel/locale.zig`）とAOT
/// （`runtime/aot/low_level/locale.zig`）の双方がこのモジュールへ
/// 揃え、経路間の同値性を保つ。
/// Cロケールbytewise比較。UTF-8バイト列をそのまま比較するためmacOS/Linux/
/// Windowsで常に一致するportable baseline（`strcmp`と同じ順序付けを
/// 内蔵NULにも拡張したもの）。返り値は -1 / 0 / 1。
pub fn compareBytewise(a: []const u8, b: []const u8) i8 {
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// Cロケール系のlocale名判定。空・"C"・"POSIX"・"C.UTF-8"など
/// エンコーディング指定だけが付いた名前は、どのOSでも同じ結果になる
/// bytewise比較へフォールバックする。
pub fn isCLocaleName(name: []const u8) bool {
    if (name.len == 0) return true;
    var base = name;
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| base = name[0..dot];
    return std.ascii.eqlIgnoreCase(base, "C") or std.ascii.eqlIgnoreCase(base, "POSIX");
}

pub const CollateError = error{
    /// OPTIONS.localeが受理できる形ではない（`EINVAL`）。
    InvalidLocale,
    /// OSがロケール照合を提供しない、またはlocaleが存在しない（`ENOTSUP`）。
    LocaleCollateUnsupported,
    OutOfMemory,
};

/// locale名 `name` で `a` と `b` を照合する。Cロケール系名はbytewise比較
/// （全OS一致）、それ以外はOSの照合機能（POSIX: newlocale/strcoll_l、
/// Windows: CompareStringEx）へ委譲する。非C localeの結果はOSと
/// インストール済みロケールデータに依存し、未提供localeは
/// `LocaleCollateUnsupported`（ENOTSUP）になる。内蔵NULは照合をそこで
/// 打ち切る（C APIの文字列契約に一致）。
pub fn collate(allocator: std.mem.Allocator, name: []const u8, a: []const u8, b: []const u8) CollateError!i8 {
    if (isCLocaleName(name)) return compareBytewise(a, b);
    if (!hasUtf8Codeset(name)) return error.InvalidLocale;
    if (comptime builtin.os.tag == .windows) return collateWindows(allocator, name, a, b);
    if (comptime hasPosixCollation()) return collatePosix(allocator, name, a, b);
    return error.LocaleCollateUnsupported;
}

/// locale名の `.` 指定codesetがUTF-8系か。比較対象は常にUTF-8バイト列
/// なので、`ja_JP.EUC-JP` 等の非UTF-8ロケールへ委譲するとOSがバイト列を
/// 別encodingとして解釈し不正な照合結果になる。受理側が変換しない本API
/// では非UTF-8 codeset指定をlocale名不正（EINVAL）として拒否する。
/// `.` が無ければ実装側が `.UTF-8` を補うためUTF-8とみなす。
fn hasUtf8Codeset(name: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return true;
    var codeset = name[dot + 1 ..];
    if (std.mem.indexOfScalar(u8, codeset, '@')) |at| codeset = codeset[0..at];
    var normalized: [8]u8 = undefined;
    var n: usize = 0;
    for (codeset) |byte| {
        if (byte == '-' or byte == '_') continue;
        if (n >= normalized.len) return false;
        normalized[n] = std.ascii.toLower(byte);
        n += 1;
    }
    return std.mem.eql(u8, normalized[0..n], "utf8");
}

/// OSのロケール照合がコンパイル時点で提供可能か。WASIはロケールAPIを
/// 持たないためfalse。`低レイヤー機能対応判定` の `locale_collate` は
/// これとカタログmatrix、host callback有無の積で決まる。
pub fn collateSupported() bool {
    return switch (builtin.os.tag) {
        .wasi, .freestanding => false,
        else => true,
    };
}

fn hasPosixCollation() bool {
    return switch (builtin.os.tag) {
        .windows, .wasi, .freestanding => false,
        else => true,
    };
}

const libc = struct {
    pub const locale_t = ?*anyopaque;
    pub extern "c" fn newlocale(mask: c_int, locale: [*:0]const u8, base: locale_t) locale_t;
    pub extern "c" fn freelocale(locale: locale_t) void;
    pub extern "c" fn strcoll_l(a: [*:0]const u8, b: [*:0]const u8, locale: locale_t) c_int;
};

// POSIXの LC_COLLATE_MASK。glibc/muslは LC_COLLATE=3 のため (1<<3)、
// Darwin/BSD系は LC_COLLATE=1 のため (1<<0)。
const lc_collate_mask: c_int = switch (builtin.os.tag) {
    .linux => 1 << 3,
    else => 1 << 0,
};

/// POSIXロケール名を `newlocale` へ渡す形へ正規化する。BCP47風の `-` は
/// `_` へ写し、エンコーディング省略は `.UTF-8` を補う（比較対象が
/// UTF-8バイト列のため、非UTF-8ロケールへ落ちると照合結果がOS間で
/// ずれる）。受理する文字は `[A-Za-z0-9._@-]` のみ。
fn posixLocaleName(buffer: []u8, name: []const u8) ?[:0]const u8 {
    if (name.len == 0 or name.len > buffer.len - 8) return null;
    var len: usize = 0;
    var has_encoding = false;
    var in_tag = true;
    var at_pos: ?usize = null;
    for (name) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '@' or byte == '-';
        if (!ok) return null;
        if (byte == '.' or byte == '@') in_tag = false;
        if (byte == '.') has_encoding = true;
        if (byte == '@' and at_pos == null) at_pos = len;
        // BCP47の`-`→`_`変換は言語タグ部（エンコーディング・修飾より前）
        // だけに適用する。`.UTF-8` のハイフンまで潰すと不正名になる。
        buffer[len] = if (byte == '-' and in_tag) '_' else byte;
        len += 1;
    }
    if (!has_encoding) {
        // POSIX名は `language[_territory][.codeset][@modifier]` の順。
        // @modifier があればその直前へcodesetを挿入する。
        const insert_at = at_pos orelse len;
        std.mem.copyBackwards(u8, buffer[insert_at + 6 .. len + 6], buffer[insert_at..len]);
        @memcpy(buffer[insert_at..][0..6], ".UTF-8");
        len += 6;
    }
    buffer[len] = 0;
    return buffer[0..len :0];
}

fn collatePosix(allocator: std.mem.Allocator, name: []const u8, a: []const u8, b: []const u8) CollateError!i8 {
    var name_buffer: [128]u8 = undefined;
    const locale_name = posixLocaleName(&name_buffer, name) orelse return error.InvalidLocale;
    const locale = libc.newlocale(lc_collate_mask, locale_name.ptr, null);
    if (locale == null) return error.LocaleCollateUnsupported;
    defer libc.freelocale(locale);
    const a_z = try allocator.dupeZ(u8, a);
    defer allocator.free(a_z);
    const b_z = try allocator.dupeZ(u8, b);
    defer allocator.free(b_z);
    const order = libc.strcoll_l(a_z.ptr, b_z.ptr, locale);
    return if (order < 0) -1 else if (order > 0) 1 else 0;
}

const kernel32 = struct {
    pub extern "kernel32" fn CompareStringEx(
        locale_name: ?[*:0]const u16,
        flags: u32,
        s1: ?[*]const u16,
        len1: c_int,
        s2: ?[*]const u16,
        len2: c_int,
        version_info: ?*anyopaque,
        reserved: ?*anyopaque,
        param: isize,
    ) c_int;
};

/// Windowsロケール名を `CompareStringEx` へ渡すBCP47形へ正規化する。
/// `_` は `-` へ写し、`.UTF-8` 等のエンコーディングや `@` 修飾は落とす。
fn windowsLocaleName(buffer: []u16, name: []const u8) ?[:0]const u16 {
    if (name.len == 0 or name.len >= buffer.len) return null;
    var len: usize = 0;
    for (name) |byte| {
        if (byte == '.' or byte == '@') break;
        const ok = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
        if (!ok) return null;
        buffer[len] = if (byte == '_') '-' else byte;
        len += 1;
    }
    if (len == 0) return null;
    buffer[len] = 0;
    return buffer[0..len :0];
}

fn collateWindows(allocator: std.mem.Allocator, name: []const u8, a: []const u8, b: []const u8) CollateError!i8 {
    var name_buffer: [128]u16 = undefined;
    const locale_name = windowsLocaleName(&name_buffer, name) orelse return error.InvalidLocale;
    const a_w = std.unicode.wtf8ToWtf16LeAllocZ(allocator, a) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidLocale,
    };
    defer allocator.free(a_w);
    const b_w = std.unicode.wtf8ToWtf16LeAllocZ(allocator, b) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWtf8 => return error.InvalidLocale,
    };
    defer allocator.free(b_w);
    const order = kernel32.CompareStringEx(locale_name.ptr, 0, a_w.ptr, -1, b_w.ptr, -1, null, null, 0);
    // CSTR_LESS_THAN=1 / CSTR_EQUAL=2 / CSTR_GREATER_THAN=3。0はエラーで、
    // 未知ロケール名（ERROR_INVALID_PARAMETER等）をENOTSUPへ写す。
    return switch (order) {
        1 => -1,
        2 => 0,
        3 => 1,
        else => error.LocaleCollateUnsupported,
    };
}

/// `文字表示幅取得` の共有実装。UTF-8バイト列の端末表示セル幅を返す
/// （コードポイント数ではない）。規則:
/// - East Asian Width が Fullwidth/Wide、Emoji_Presentation、地域指標は2セル
/// - 結合文字（Mn/Me/Mc）、異体字セレクタ、絵文字修飾子、ZWJ/ZWNJ、
///   制御・書式・区切り文字、Default_Ignorableは0セル
/// - VS16( U+FE0F )は直前基底が絵文字適格なら幅を2へ、VS15( U+FE0E )は
///   全角でない基底の幅を1へ戻す（キーキャップ・テキスト絵文字対応）
/// - 連続する地域指標は2個で1旗グリフ（計2セル、奇数個目は単体2セル）。
///   結合文字・修飾子・ZWJ等が間に挟まるとペアにならず各2セル
/// - 絵文字適格基底と絵文字メンバーだけがZWJで連結されたクラスタは
///   全体で2セル。絵文字でないZWJ列はZWJを0幅で終端し基底幅の合計
/// - 絵文字修飾子は直前基底がEmoji_Modifier_Baseのときだけ0セルへ
///   吸収し、それ以外は単独2セル
/// - それ以外は1セル。不正UTF-8（打ち切り・overlong・孤立サロゲート・
///   単独継続byte）は欠損単位1セル（単独継続byteは各1セル）
pub fn displayWidth(text: []const u8) u32 {
    var total: u32 = 0;
    var cluster: Cluster = .{};
    var ri_odd = false;
    var index: usize = 0;
    while (index < text.len) {
        const decoded = decode(text, index);
        index += decoded.len;
        const cp = decoded.cp orelse {
            total += cluster.finish() + 1;
            cluster = .{};
            ri_odd = false;
            continue;
        };
        if (cp == zwj) {
            ri_odd = false;
            if (cluster.has_base) cluster.zwj_pending = true;
            continue;
        }
        if (contains(.join_control, cp)) {
            ri_odd = false;
            // ZWNJ等は0幅だが、ZWJの連結保留は切る。
            cluster.zwj_pending = false;
            continue;
        }
        // 結合文字・VS等は基底へ吸収。絵文字修飾子（肌色）は
        // Grapheme_ExtendではなくGCB=Extend側のため別途扱い、直前基底が
        // Emoji_Modifier_Baseのときだけ吸収し、それ以外や先頭では
        // 単独絵文字（2セル）として残す。これらの0幅文字が間に挟まった
        // 地域指標は旗ペアにならないためri_oddを切る。
        if (isExtend(cp) or (isEmojiModifier(cp) and cluster.has_base and cluster.modifier_base)) {
            ri_odd = false;
            cluster.extend(cp);
            continue;
        }
        if (isRegionalIndicator(cp)) {
            if (ri_odd) {
                // 旗グリフの後半。ペア先頭で2セルを計上済みなので+0。
                ri_odd = false;
                continue;
            }
            ri_odd = true;
            total += cluster.finish();
            // 地域指標は絵文字ZWJシーケンスの構成員にはならないため、
            // ZWJ連結可能を示す wide_or_emoji は立てない。
            cluster = .{ .has_base = true, .width = 2, .first = cp };
            continue;
        }
        ri_odd = false;
        // ZWJ連結は絵文字シーケンスのみ縮退する。基底が絵文字適格
        // （wide_or_emoji）で後続も絵文字メンバーのときだけ1グリフへ
        // 連結し、それ以外はZWJを0幅で終端して前後を別々に加算する
        // （`中‍A` は3セル、`中‍文` は4セル）。
        if (cluster.zwj_pending and cluster.wide_or_emoji and isEmojiMember(cp)) {
            cluster.addJoined(cp);
        } else {
            total += cluster.finish();
            cluster = .{ .has_base = true };
            cluster.addBase(cp);
        }
    }
    return total + cluster.finish();
}

const zwj: u21 = 0x200d;
const vs15: u21 = 0xfe0e;
const vs16: u21 = 0xfe0f;

/// 書記素クラスタの未確定幅。ZWJ連結では全メンバーが1グリフへ縮退する
/// ため、クラスタ終端（finish）まで幅を確定しない。
const Cluster = struct {
    width: u32 = 0,
    joined: bool = false,
    has_base: bool = false,
    zwj_pending: bool = false,
    wide_or_emoji: bool = false,
    modifier_base: bool = false,
    first: u21 = 0,

    fn finish(self: Cluster) u32 {
        if (!self.joined) return self.width;
        if (self.wide_or_emoji) return 2;
        return self.width;
    }

    fn addBase(self: *Cluster, cp: u21) void {
        self.width = cellWidth(cp);
        self.first = cp;
        self.has_base = true;
        self.zwj_pending = false;
        self.modifier_base = isEmojiModifierBase(cp);
        if (isEmojiMember(cp)) self.wide_or_emoji = true;
    }

    fn addJoined(self: *Cluster, cp: u21) void {
        self.joined = true;
        self.zwj_pending = false;
        self.width += cellWidth(cp);
        self.modifier_base = isEmojiModifierBase(cp);
        if (isEmojiMember(cp)) self.wide_or_emoji = true;
    }

    fn extend(self: *Cluster, cp: u21) void {
        if (cp == vs16 and self.width == 1 and isEmojiEligible(self.first)) {
            self.width = 2;
            self.wide_or_emoji = true;
        } else if (cp == vs15 and !eastAsianWide(self.first)) {
            self.width = @min(self.width, 1);
        }
    }
};

fn contains(property: unicode_properties.Property, cp: u21) bool {
    return unicode_properties.contains(property, cp);
}

fn eastAsianWide(cp: u21) bool {
    return unicode_width.eastAsianWide(cp);
}

fn isRegionalIndicator(cp: u21) bool {
    return contains(.regional_indicator, cp);
}

fn isEmojiModifier(cp: u21) bool {
    return contains(.emoji_modifier, cp);
}

/// ZWJ連結クラスタを1絵文字グリフ（2セル）へ縮退させるメンバー判定。
/// East Asian Wideは含めない。全角文字は絵文字ZWJシーケンスの構成員
/// ではないため、`中‍文` のような列を2セルへ縮退させない。
fn isEmojiMember(cp: u21) bool {
    return contains(.emoji_presentation, cp) or
        contains(.extended_pictographic, cp);
}

/// 肌色修飾子（U+1F3FB..U+1F3FF）を受け付ける基底判定。
/// Emoji_Modifier_Baseでない基底に続く修飾子は0セルへ吸収せず、
/// 単独の修飾子（2セル）として数える。
fn isEmojiModifierBase(cp: u21) bool {
    return contains(.emoji_modifier_base, cp);
}

/// VS16で絵文字表示へ昇格する基底判定。数字・#・*（キーキャップ）や
/// ©® 等のデフォルトテキスト絵文字を含む。
fn isEmojiEligible(cp: u21) bool {
    return contains(.emoji_presentation, cp) or contains(.extended_pictographic, cp) or
        contains(.emoji_component, cp);
}

/// 基底へ幅を足さずクラスタへ吸収されるコードポイント。結合文字
/// （Mn/Me+その他Grapheme_Extend）、Mc、異体字セレクタ、Default_Ignorable、
/// ハングル中声/終声ジャモ（先声との合成で2セルへ含む）。
fn isExtend(cp: u21) bool {
    if (contains(.grapheme_extend, cp)) return true;
    if (contains(.spacing_mark, cp)) return true;
    if (contains(.default_ignorable_code_point, cp)) return true;
    if (cp >= 0x1160 and cp <= 0x11ff) return true;
    if (cp >= 0xd7b0 and cp <= 0xd7fb) return true;
    return false;
}

/// 独立した基底のセル幅。制御・書式・区切り文字は0、全角・Emoji
/// Presentation・地域指標は2、それ以外は1。
fn cellWidth(cp: u21) u32 {
    if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0)) return 0;
    if (contains(.control, cp) or contains(.format, cp)) return 0;
    if (contains(.line_separator, cp) or contains(.paragraph_separator, cp)) return 0;
    if (eastAsianWide(cp) or contains(.emoji_presentation, cp)) return 2;
    if (isRegionalIndicator(cp)) return 2;
    return 1;
}

const Decoded = struct { cp: ?u21, len: usize };

/// UTF-8デコード。AOTのWTF-16由来WTF-8も受理するが、サロゲートは
/// 欠損として扱う（Interpreterのlossy変換で U+FFFD → 1セルになるのと
/// 同じ幅）。不正なバイト列は欠損単位ごとに1セルとして消費する。
fn decode(text: []const u8, start: usize) Decoded {
    const b0 = text[start];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 < 0xc0) return .{ .cp = null, .len = 1 };
    const seq_len: usize = if (b0 < 0xe0) 2 else if (b0 < 0xf0) 3 else if (b0 < 0xf8) 4 else return .{ .cp = null, .len = 1 };
    var len: usize = 1;
    while (len < seq_len and start + len < text.len) : (len += 1) {
        const c = text[start + len];
        if (c < 0x80 or c >= 0xc0) return .{ .cp = null, .len = len };
    }
    if (len < seq_len) return .{ .cp = null, .len = len };
    const cp: u21 = switch (seq_len) {
        2 => @as(u21, b0 & 0x1f) << 6 | @as(u21, text[start + 1] & 0x3f),
        3 => @as(u21, b0 & 0x0f) << 12 | @as(u21, text[start + 1] & 0x3f) << 6 | @as(u21, text[start + 2] & 0x3f),
        else => @as(u21, b0 & 0x07) << 18 | @as(u21, text[start + 1] & 0x3f) << 12 | @as(u21, text[start + 2] & 0x3f) << 6 | @as(u21, text[start + 3] & 0x3f),
    };
    const min: u21 = switch (seq_len) {
        2 => 0x80,
        3 => 0x800,
        else => 0x10000,
    };
    if (cp < min or cp > 0x10ffff) return .{ .cp = null, .len = seq_len };
    if (cp >= 0xd800 and cp <= 0xdfff) return .{ .cp = null, .len = seq_len };
    return .{ .cp = cp, .len = seq_len };
}

test "bytewise比較はCロケール順で3OS一致" {
    try std.testing.expectEqual(@as(i8, 0), compareBytewise("abc", "abc"));
    try std.testing.expectEqual(@as(i8, -1), compareBytewise("abc", "abd"));
    try std.testing.expectEqual(@as(i8, 1), compareBytewise("abd", "abc"));
    try std.testing.expectEqual(@as(i8, -1), compareBytewise("abc", "abcd"));
    try std.testing.expectEqual(@as(i8, -1), compareBytewise("", "a"));
    // UTF-8のバイト順はコードポイント順と一致する。
    try std.testing.expectEqual(@as(i8, -1), compareBytewise("あ", "い"));
    try std.testing.expectEqual(@as(i8, 1), compareBytewise("🍎", "あ"));
    // 不正UTF-8もバイト列として決定的に比較する。
    try std.testing.expectEqual(@as(i8, 1), compareBytewise("\xff", "\xfe"));
}

test "Cロケール系名はエンコーディング付きもbytewiseへ" {
    try std.testing.expect(isCLocaleName(""));
    try std.testing.expect(isCLocaleName("C"));
    try std.testing.expect(isCLocaleName("c"));
    try std.testing.expect(isCLocaleName("POSIX"));
    try std.testing.expect(isCLocaleName("C.UTF-8"));
    try std.testing.expect(isCLocaleName("POSIX.utf8"));
    try std.testing.expect(!isCLocaleName("ja_JP.UTF-8"));
    try std.testing.expect(!isCLocaleName("en-US"));
    try std.testing.expect(!isCLocaleName("xC"));
}

test "POSIXロケール名はUTF-8補完と-→_正規化を行う" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("ja_JP.UTF-8", posixLocaleName(&buffer, "ja_JP").?);
    try std.testing.expectEqualStrings("en_US.UTF-8", posixLocaleName(&buffer, "en-US").?);
    // エンコーディング部のハイフンは潰さない（UTF-8→UTF_8の化けを防ぐ）。
    try std.testing.expectEqualStrings("ja_JP.UTF-8", posixLocaleName(&buffer, "ja_JP.UTF-8").?);
    try std.testing.expectEqualStrings("zh_Hans_CN.UTF-8", posixLocaleName(&buffer, "zh-Hans-CN.UTF-8").?);
    // @modifier はcodesetの後ろに来るPOSIX順（language.codeset@modifier）。
    try std.testing.expectEqualStrings("de_DE.UTF-8@euro", posixLocaleName(&buffer, "de_DE@euro").?);
    try std.testing.expectEqualStrings("de_DE.UTF-8@euro", posixLocaleName(&buffer, "de_DE.UTF-8@euro").?);
    try std.testing.expect(posixLocaleName(&buffer, "ja;rm") == null);
    try std.testing.expect(posixLocaleName(&buffer, "") == null);
}

test "非CロケールはOS照合またはENOTSUPになる" {
    const result = collate(std.testing.allocator, "ja_JP.UTF-8", "あ", "い") catch |failure| {
        try std.testing.expect(failure == error.LocaleCollateUnsupported);
        return;
    };
    try std.testing.expect(result == -1 or result == 0 or result == 1);
    // Cロケール名はcallback非依存でbytewise比較。
    try std.testing.expectEqual(@as(i8, -1), try collate(std.testing.allocator, "C", "a", "b"));
    try std.testing.expectEqual(@as(i8, -1), try collate(std.testing.allocator, "C.UTF-8", "a", "b"));
    // 非UTF-8 codesetはOS照合へ委譲できないためEINVAL（OS共通の拒否）。
    try std.testing.expectError(error.InvalidLocale, collate(std.testing.allocator, "ja_JP.EUC-JP", "あ", "い"));
    try std.testing.expectError(error.InvalidLocale, collate(std.testing.allocator, "de_DE.ISO-8859-1", "a", "b"));
    try std.testing.expect(hasUtf8Codeset("ja_JP.UTF-8"));
    try std.testing.expect(hasUtf8Codeset("ja_JP.utf8"));
    try std.testing.expect(hasUtf8Codeset("ja_JP"));
    try std.testing.expect(hasUtf8Codeset("de_DE@euro"));
}

test "表示幅はASCII・全角・結合文字・VSを処理する" {
    try std.testing.expectEqual(@as(u32, 0), displayWidth(""));
    try std.testing.expectEqual(@as(u32, 5), displayWidth("hello"));
    try std.testing.expectEqual(@as(u32, 10), displayWidth("こんにちは"));
    try std.testing.expectEqual(@as(u32, 4), displayWidth("ab中"));
    // 結合文字は基底へ幅を足さない（e + U+0301 = 1セル、合成済みéと同じ）。
    try std.testing.expectEqual(@as(u32, 1), displayWidth("e\xcc\x81"));
    try std.testing.expectEqual(@as(u32, 1), displayWidth("\xc3\xa9"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("か\xe3\x82\x99"));
    // VS16でテキスト絵文字が2セルへ、VS15は全角以外を1セルへ。
    try std.testing.expectEqual(@as(u32, 1), displayWidth("\xe2\x98\x83"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("\xe2\x98\x83\xef\xb8\x8f"));
    try std.testing.expectEqual(@as(u32, 1), displayWidth("\xe2\x98\x83\xef\xb8\x8e"));
    // キーキャップ: 数字 + VS16 + U+20E3 = 2セル。
    try std.testing.expectEqual(@as(u32, 2), displayWidth("1\xef\xb8\x8f\xe2\x83\xa3"));
}

test "表示幅は絵文字・修飾子・旗・ZWJ列を1グリフへ集約する" {
    try std.testing.expectEqual(@as(u32, 2), displayWidth("🍎"));
    // 絵文字修飾子（肌色）は基底へ0。単独は2セル。
    try std.testing.expectEqual(@as(u32, 2), displayWidth("👋🏽"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("🏽"));
    // 地域指標はペアで旗1グリフ=2セル、単体は2セル。
    try std.testing.expectEqual(@as(u32, 2), displayWidth("🇯🇵"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("🇯"));
    try std.testing.expectEqual(@as(u32, 4), displayWidth("🇯🇵🇺🇸"));
    // ZWJ連結の絵文字列は1グリフ=2セル。
    try std.testing.expectEqual(@as(u32, 2), displayWidth("👨‍👩‍👧‍👦"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("❤‍🔥"));
    // ZWJ/ZWNJ自体は0セル。
    try std.testing.expectEqual(@as(u32, 2), displayWidth("ab"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("a\u{200d}b"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("a\u{200c}b"));
}

test "表示幅は絵文字でないZWJ列・修飾子・分断された旗を縮退させない" {
    // 非絵文字のZWJ列は縮退しない（基底幅の合計、ZWJ自体は0セル）。
    try std.testing.expectEqual(@as(u32, 4), displayWidth("中\u{200d}文"));
    try std.testing.expectEqual(@as(u32, 3), displayWidth("中\u{200d}A"));
    try std.testing.expectEqual(@as(u32, 3), displayWidth("a\u{200d}👨"));
    // Emoji_Modifier_Baseでない基底の後の肌色修飾子は単独2セル。
    try std.testing.expectEqual(@as(u32, 3), displayWidth("A🏽"));
    try std.testing.expectEqual(@as(u32, 4), displayWidth("中🏽"));
    // Emoji_Modifier_Baseの後では吸収される。
    try std.testing.expectEqual(@as(u32, 2), displayWidth("👋🏽"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("👨🏽"));
    // 結合文字・修飾子・ZWJ等が挟まると地域指標はペアにならない。
    try std.testing.expectEqual(@as(u32, 4), displayWidth("🇯\u{301}🇵"));
    try std.testing.expectEqual(@as(u32, 4), displayWidth("🇯\u{200d}🇵"));
    try std.testing.expectEqual(@as(u32, 5), displayWidth("🇯a🇵"));
}

test "表示幅は制御文字と不正UTF-8を規則通りに処理する" {
    try std.testing.expectEqual(@as(u32, 0), displayWidth("\x00"));
    // ESC自体は0幅だが、後続の可視ASCIIは表示セルを持つ（CSI全体は
    // 認識しない。表示幅APIは文字列のグリフ幅を数える契約）。
    try std.testing.expectEqual(@as(u32, 4), displayWidth("\x1b[31m"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("a\x00b"));
    // 不正UTF-8: 打ち切り列・孤立サロゲート(WTF-8)・単独継続byteは各1セル。
    try std.testing.expectEqual(@as(u32, 1), displayWidth("\xe3"));
    try std.testing.expectEqual(@as(u32, 1), displayWidth("\xed\xa0\x80"));
    try std.testing.expectEqual(@as(u32, 1), displayWidth("\x80"));
    try std.testing.expectEqual(@as(u32, 2), displayWidth("\xff\xfe"));
    try std.testing.expectEqual(@as(u32, 3), displayWidth("a\xffb"));
}
