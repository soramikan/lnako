const std = @import("std");
const state = @import("state.zig");

const Runtime = state.Runtime;
const Value = state.Value;
const Tag = state.Tag;
const RootFrame = state.RootFrame;
const runtimeUtf8String = state.runtimeUtf8String;

pub fn caniuseBrowsersBuiltin(runtime: *Runtime) !Value {
    if (runtime.caniuse_browsers.tag != @intFromEnum(Tag.undefined)) return runtime.caniuse_browsers;

    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{});
    for (caniuse_browsers) |browser| {
        roots[1] = try runtime.createArray(&.{});
        for (browser.versions) |version| {
            const value = try runtimeUtf8String(runtime, version);
            try roots[1].object().?.payload.array.append(runtime.allocator, value);
        }
        roots[2] = try runtimeUtf8String(runtime, browser.key);
        try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[2], roots[1]);
    }
    runtime.caniuse_browsers = roots[0];
    return roots[0];
}

const CaniuseBrowser = struct { key: []const u8, versions: []const []const u8 };

pub fn caniuseAgentsBuiltin(runtime: *Runtime) !Value {
    if (runtime.caniuse_agents.tag != @intFromEnum(Tag.undefined)) return runtime.caniuse_agents;

    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{});
    for (caniuse_agents) |agent| {
        roots[1] = try runtimeUtf8String(runtime, agent.key);
        roots[2] = try runtimeUtf8String(runtime, agent.name);
        try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
    }
    runtime.caniuse_agents = roots[0];
    return roots[0];
}
const CaniuseAgent = struct { key: []const u8, name: []const u8 };

// This is the generated v3.7.24 browsers_agents.mjs snapshot. The AOT
// runtime owns its copy so normal execution never loads the JavaScript
// caniuse plugin.
const caniuse_agents = [_]CaniuseAgent{
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

// This is the generated v3.7.24 browsers.mjs snapshot. The AOT runtime owns
// its copy so normal execution never loads the JavaScript caniuse plugin.
const caniuse_browsers = [_]CaniuseBrowser{
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
