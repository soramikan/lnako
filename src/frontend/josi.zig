const std = @import("std");

pub const Match = struct {
    consumed: usize,
    raw: []const u8,
    value: []const u8,
};

pub const list = [_][]const u8{
    "でなければ",
    "について",
    "なければ",
    "くらい",
    "なのか",
    "までを",
    "までの",
    "による",
    "として",
    "ならば",
    "である",
    "します",
    "でした",
    "にゃん",
    "ものについて",
    "ものくらい",
    "ものなのか",
    "ものまでを",
    "ものまでの",
    "ものによる",
    "ものとして",
    "ものならば",
    "ものなければ",
    "ものから",
    "ものまで",
    "ものだけ",
    "ものより",
    "ものほど",
    "ものなど",
    "ものいて",
    "ものえて",
    "ものきて",
    "ものけて",
    "ものして",
    "ものって",
    "ものにて",
    "ものみて",
    "ものめて",
    "ものねて",
    "ものでは",
    "ものには",
    "ものんで",
    "ものずつ",
    "ものなら",
    "ものたら",
    "ものれば",
    "ものこと",
    "ものである",
    "ものします",
    "ものでした",
    "ものにゃん",
    "ものです",
    "ものは",
    "ものを",
    "ものに",
    "ものへ",
    "もので",
    "ものと",
    "ものが",
    "ものの",
    "から",
    "まで",
    "だけ",
    "より",
    "ほど",
    "など",
    "いて",
    "えて",
    "きて",
    "けて",
    "して",
    "って",
    "にて",
    "みて",
    "めて",
    "ねて",
    "では",
    "には",
    "んで",
    "ずつ",
    "なら",
    "たら",
    "れば",
    "こと",
    "です",
    "とは",
    "は",
    "を",
    "に",
    "へ",
    "で",
    "と",
    "が",
    "の",
};

pub fn match(source: []const u8) ?Match {
    var prefix: usize = 0;
    while (prefix < source.len) {
        if (source[prefix] == ' ' or source[prefix] == '\t') {
            prefix += 1;
            continue;
        }
        if (std.mem.startsWith(u8, source[prefix..], "　")) {
            prefix += "　".len;
            continue;
        }
        break;
    }

    var best: ?[]const u8 = null;
    for (list) |candidate| {
        if (std.mem.startsWith(u8, source[prefix..], candidate) and
            (best == null or candidate.len > best.?.len))
        {
            best = candidate;
        }
    }
    const raw = best orelse return null;
    var value = raw;
    if (std.mem.startsWith(u8, value, "もの")) value = value["もの".len..];
    if (isRemoved(value)) value = "";
    return .{ .consumed = prefix + raw.len, .raw = raw, .value = value };
}

pub fn isConditional(value: []const u8) bool {
    return std.mem.eql(u8, value, "でなければ") or std.mem.eql(u8, value, "なければ") or
        std.mem.eql(u8, value, "ならば") or std.mem.eql(u8, value, "なら") or
        std.mem.eql(u8, value, "たら") or std.mem.eql(u8, value, "れば");
}

fn isRemoved(value: []const u8) bool {
    return std.mem.eql(u8, value, "こと") or std.mem.eql(u8, value, "である") or
        std.mem.eql(u8, value, "です") or std.mem.eql(u8, value, "します") or
        std.mem.eql(u8, value, "でした") or std.mem.eql(u8, value, "にゃん");
}

test "最長の助詞ともの構文を認識する" {
    const first = match(" について表示").?;
    try std.testing.expectEqualStrings("について", first.value);
    const mono = match("ものを表示").?;
    try std.testing.expectEqualStrings("を", mono.value);
    try std.testing.expectEqualStrings("ものを", mono.raw);
}

test "意味のない助詞を除去する" {
    const result = match("である").?;
    try std.testing.expectEqualStrings("", result.value);
    try std.testing.expectEqualStrings("である", result.raw);
}
