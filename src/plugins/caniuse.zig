const std = @import("std");
const value_mod = @import("../runtime/value.zig");
const common = @import("system/common.zig");
const constants = @import("system/constants.zig");

pub const Value = value_mod.Value;
pub const Runtime = value_mod.Runtime;

pub const State = struct {
    browsers: Value = .undefined,
    agents: Value = .undefined,

    pub fn trace(self: State, runtime: *Runtime) !void {
        try runtime.traceExternal(self.browsers);
        try runtime.traceExternal(self.agents);
    }
};

const Agent = struct { key: []const u8, name: []const u8 };
const Browser = struct { key: []const u8, versions: []const []const u8 };

const agents = [_]Agent{
    .{ .key = "ie", .name = "IE" },
    .{ .key = "edge", .name = "Edge" },
    .{ .key = "firefox", .name = "Firefox" },
    .{ .key = "chrome", .name = "Chrome" },
    .{ .key = "safari", .name = "Safari" },
    .{ .key = "opera", .name = "Opera" },
    .{ .key = "ios_saf", .name = "Safari on iOS" },
    .{ .key = "op_mini", .name = "Opera Mini" },
    .{ .key = "android", .name = "Android Browser" },
    .{ .key = "bb", .name = "Blackberry Browser" },
    .{ .key = "op_mob", .name = "Opera Mobile" },
    .{ .key = "and_chr", .name = "Chrome for Android" },
    .{ .key = "and_ff", .name = "Firefox for Android" },
    .{ .key = "ie_mob", .name = "IE Mobile" },
    .{ .key = "and_uc", .name = "UC Browser for Android" },
    .{ .key = "samsung", .name = "Samsung Internet" },
    .{ .key = "and_qq", .name = "QQ Browser" },
    .{ .key = "baidu", .name = "Baidu Browser" },
    .{ .key = "kaios", .name = "KaiOS Browser" },
};

const browsers = [_]Browser{
    .{ .key = "and_chr", .versions = &.{"145"} },
    .{ .key = "and_ff", .versions = &.{"147"} },
    .{ .key = "and_qq", .versions = &.{"14.9"} },
    .{ .key = "and_uc", .versions = &.{"15.5"} },
    .{ .key = "android", .versions = &.{"145"} },
    .{ .key = "chrome", .versions = &.{ "145", "144", "143", "142", "139", "133", "131", "125", "112", "109" } },
    .{ .key = "edge", .versions = &.{ "145", "144", "143", "142" } },
    .{ .key = "firefox", .versions = &.{ "147", "146", "145", "140" } },
    .{ .key = "ios_saf", .versions = &.{ "26.3", "26.2", "26.1", "18.5-18.7", "16.6-16.7" } },
    .{ .key = "kaios", .versions = &.{ "3.0-3.1", "2.5" } },
    .{ .key = "node", .versions = &.{ "25.1.0", "24.11.0", "22.21.0" } },
    .{ .key = "op_mini", .versions = &.{"all"} },
    .{ .key = "op_mob", .versions = &.{"80"} },
    .{ .key = "opera", .versions = &.{ "125", "124" } },
    .{ .key = "safari", .versions = &.{ "26.3", "26.2" } },
    .{ .key = "samsung", .versions = &.{ "29", "28" } },
};

pub fn install(runtime: *Runtime, state: *State, installer: constants.Installer) !void {
    var roots = runtime.rootFrame();
    defer roots.deinit();
    if (state.agents == .undefined) state.agents = try makeAgents(runtime);
    try roots.protect(&state.agents);
    if (state.browsers == .undefined) state.browsers = try makeBrowsers(runtime);
    try roots.protect(&state.browsers);
    try installer.set("ブラウザ名変換表", state.agents);
}

pub fn call(_: *Runtime, state: *State, name: []const u8, _: []const Value) !?Value {
    if (std.mem.eql(u8, name, "対応ブラウザ一覧取得")) return @as(?Value, state.browsers);
    return null;
}

fn makeAgents(runtime: *Runtime) !Value {
    var result = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (agents) |agent| try common.dictionarySetUtf8(runtime, result.dictionary, agent.key, try runtime.stringUtf8(agent.name));
    return result;
}

fn makeBrowsers(runtime: *Runtime) !Value {
    var result = try runtime.createDictionary();
    var roots = runtime.rootFrame();
    defer roots.deinit();
    try roots.protect(&result);
    for (browsers) |browser| {
        var versions = try runtime.createArray();
        try roots.protect(&versions);
        for (browser.versions) |version| _ = try versions.array.push(try runtime.stringUtf8(version));
        try common.dictionarySetUtf8(runtime, result.dictionary, browser.key, versions);
    }
    return result;
}

test "v3.7.24固定のブラウザデータを構築する" {
    var runtime = Runtime.init(std.testing.allocator);
    defer runtime.deinit();
    var state: State = .{};
    var roots = runtime.rootFrame();
    defer roots.deinit();
    state.agents = try makeAgents(&runtime);
    try roots.protect(&state.agents);
    state.browsers = try makeBrowsers(&runtime);
    try roots.protect(&state.browsers);
    try std.testing.expectEqual(@as(usize, 19), state.agents.dictionary.len());
    try std.testing.expectEqual(@as(usize, 16), state.browsers.dictionary.len());
    try std.testing.expectEqual(@as(usize, 10), commonDictionaryValue(state.browsers.dictionary, "chrome").?.array.len());
}

fn commonDictionaryValue(dictionary: *value_mod.Dictionary, expected: []const u8) ?Value {
    for (dictionary.keys(), dictionary.values()) |key, value| {
        if (key.units.len != expected.len) continue;
        var equal = true;
        for (key.units, expected) |unit, byte| if (unit != byte) {
            equal = false;
            break;
        };
        if (equal) return value;
    }
    return null;
}
