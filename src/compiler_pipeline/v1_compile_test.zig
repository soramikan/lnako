//! `compileInput` が `.nako/v1` 環境を自動で読み、package import を
//! 旧 `.nako/environment.json` へフォールバックせず解決することを確認する。

const std = @import("std");
const testing = std.testing;
const lnako = @import("lnako");
const compile = @import("compile.zig");

const io = std.testing.io;
const generation = "gen-0123456789abcdef";
const package_dir = "packages/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const package_root = ".nako/v1/generations/" ++ generation ++ "/" ++ package_dir;
const package_hash = "sha256:2222222222222222222222222222222222222222222222222222222222222222";

fn writeFile(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len > 0) try dir.createDirPath(io, parent);
    }
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

fn writeEnv(allocator: std.mem.Allocator, dir: std.Io.Dir, lock_bytes: []const u8) !void {
    return writeEnvForProfile(allocator, dir, lock_bytes, "default");
}

fn writeEnvForProfile(allocator: std.mem.Allocator, dir: std.Io.Dir, lock_bytes: []const u8, profile: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_bytes, &digest, .{});
    const hex_text = std.fmt.bytesToHex(digest, .lower);
    const env = try std.fmt.allocPrint(allocator, "{{\"schema_version\":1,\"generation\":\"{s}\",\"profile\":\"{s}\",\"runtime\":\"lnako\",\"target_triple\":\"aarch64-macos-none\",\"lock_sha256\":\"sha256:{s}\",\"packages\":[", .{ generation, profile, hex_text[0..] });
    defer allocator.free(env);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll(env);
    try output.writer.print("{{\"id\":\"@acme/demo\",\"version\":\"1.0.0\",\"kind\":\"universal\",\"sha256\":\"{s}\",\"root\":\"{s}\",\"exports\":[{{\"subpath\":\".\",\"entry\":\"src/index.nako3\",\"binding\":\"scoped\"}}],\"exports_global_commands\":false,\"global_commands\":[]}}", .{ package_hash, package_dir });
    try output.writer.writeAll("]}");
    const env_path = try std.fmt.allocPrint(allocator, ".nako/v1/generations/{s}/environment.json", .{generation});
    defer allocator.free(env_path);
    try writeFile(dir, env_path, output.written());
    try writeFile(dir, ".nako/v1/environment.json", "{\"schema_version\":1,\"generation\":\"" ++ generation ++ "\"}");
}

const global_lock_json =
    \\{"schema_version":1,"profiles":[{"name":"default","runtime":"lnako","target_triple":"aarch64-macos-none","nodes":[{"key":"@acme/demo@1.0.0","id":"@acme/demo","version":"1.0.0","sha256":"sha256:2222222222222222222222222222222222222222222222222222222222222222","kind":"universal","global":true}],"root":[{"to":"@acme/demo@1.0.0","id":"@acme/demo","req":"^1.0.0","alias":"demo","features":[],"default_features":true,"optional":false,"allow_global_commands":true,"runtimes":[]}],"edges":[]}]}
;

const global_manifest =
    \\schema_version = 1
    \\[package]
    \\[dependencies]
    \\"@acme/demo" = { version = "^1.0.0", alias = "demo", allow_global_commands = true }
    \\
;

fn writeGlobalEnv(allocator: std.mem.Allocator, dir: std.Io.Dir, lock_bytes: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lock_bytes, &digest, .{});
    const hex_text = std.fmt.bytesToHex(digest, .lower);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.print("{{\"schema_version\":1,\"generation\":\"{s}\",\"profile\":\"default\",\"runtime\":\"lnako\",\"target_triple\":\"aarch64-macos-none\",\"lock_sha256\":\"sha256:{s}\",\"packages\":[", .{ generation, hex_text[0..] });
    try output.writer.print("{{\"id\":\"@acme/demo\",\"version\":\"1.0.0\",\"kind\":\"universal\",\"sha256\":\"{s}\",\"root\":\"{s}\",\"exports\":[{{\"subpath\":\".\",\"entry\":\"src/index.nako3\",\"binding\":\"global\"}}],\"exports_global_commands\":true,\"global_commands\":[\"加算確認\"]}}", .{ package_hash, package_dir });
    try output.writer.writeAll("]}");
    const env_path = try std.fmt.allocPrint(allocator, ".nako/v1/generations/{s}/environment.json", .{generation});
    defer allocator.free(env_path);
    try writeFile(dir, env_path, output.written());
    try writeFile(dir, ".nako/v1/environment.json", "{\"schema_version\":1,\"generation\":\"" ++ generation ++ "\"}");
}

const scoped_manifest =
    \\schema_version = 1
    \\[package]
    \\[dependencies]
    \\"@acme/demo" = { version = "^1.0.0", alias = "demo" }
    \\
;

const lock_json =
    \\{"schema_version":1,"profiles":[{"name":"default","runtime":"lnako","target_triple":"aarch64-macos-none","nodes":[{"key":"@acme/demo@1.0.0","id":"@acme/demo","version":"1.0.0","sha256":"sha256:2222222222222222222222222222222222222222222222222222222222222222","kind":"universal","global":false}],"root":[{"to":"@acme/demo@1.0.0","id":"@acme/demo","req":"^1.0.0","alias":"demo","features":[],"default_features":true,"optional":false,"allow_global_commands":false,"runtimes":[]}],"edges":[]}]}
;

test "v1 compile: .nako/v1 環境から package import を解決する" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "nako.toml", scoped_manifest);
    try writeFile(tmp.dir, "main.nako3", "!「pkg:demo」を取り込む\n「ok」と表示\n");
    try writeFile(tmp.dir, package_root ++ "/src/index.nako3", "「from package」と表示\n");
    try writeFile(tmp.dir, package_root ++ "/NAKO-PKG/COMMANDS.json", "{\"schema_version\":1,\"exports_global_commands\":false,\"exports\":{\".\":{\"binding\":\"scoped\",\"commands\":[],\"constants\":[]}}}");
    try writeEnv(a, tmp.dir, lock_json);
    try writeFile(tmp.dir, "nako.lock", lock_json);

    const main_path = try tmp.dir.realPathFileAlloc(io, "main.nako3", a);
    defer a.free(main_path);
    var stderr: std.Io.Writer.Allocating = .init(a);
    defer stderr.deinit();
    var program = (try compile.compileInput(a, io, main_path, .{}, &stderr.writer)) orelse {
        std.debug.print("compile diagnostics:\n{s}", .{stderr.written()});
        return error.TestExpectedCompileSuccess;
    };
    defer program.deinit();
    var found_demo = false;
    for (program.module_names) |name| {
        if (std.mem.eql(u8, name, "demo")) found_demo = true;
    }
    try testing.expect(found_demo);
}

test "v1 compile: 壊れた v1 環境は旧経路へフォールバックしない" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "nako.toml", scoped_manifest);
    try writeFile(tmp.dir, "main.nako3", "!「pkg:demo」を取り込む\n「ok」と表示\n");
    try writeFile(tmp.dir, package_root ++ "/src/index.nako3", "「from package」と表示\n");
    try writeFile(tmp.dir, package_root ++ "/NAKO-PKG/COMMANDS.json", "{\"schema_version\":1,\"exports_global_commands\":false,\"exports\":{\".\":{\"binding\":\"scoped\",\"commands\":[],\"constants\":[]}}}");
    try writeEnv(a, tmp.dir, lock_json);
    // environment が固定した hash と実 lock を食い違わせる。
    try writeFile(tmp.dir, "nako.lock", "{\"schema_version\":1,\"profiles\":[{\"name\":\"default\",\"runtime\":\"lnako\",\"nodes\":[],\"root\":[],\"edges\":[]}]}");
    const main_path = try tmp.dir.realPathFileAlloc(io, "main.nako3", a);
    defer a.free(main_path);
    var stderr: std.Io.Writer.Allocating = .init(a);
    defer stderr.deinit();
    if (try compile.compileInput(a, io, main_path, .{}, &stderr.writer)) |program| {
        var owned = program;
        owned.deinit();
        return error.TestExpectedCompileFailure;
    }
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "v1 パッケージ環境を検証できません") != null);
}

test "v1 compile: global 入口の source 命令を実関数へ直接束縛し Interpreter で実行する" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "nako.toml", global_manifest);
    try writeFile(tmp.dir, "main.nako3", "!「pkg:demo」を取り込む\n加算確認(40)を表示\n");
    try writeFile(tmp.dir, package_root ++ "/src/index.nako3", "●(Xを)加算確認とは\nX+2で戻る\nここまで\n");
    try writeFile(tmp.dir, package_root ++ "/NAKO-PKG/COMMANDS.json", "{\"schema_version\":1,\"exports_global_commands\":true,\"exports\":{\".\":{\"binding\":\"global\",\"commands\":[{\"name\":\"加算確認\",\"kind\":\"function\",\"args\":[{\"name\":\"X\",\"josi\":[\"を\"]}]}],\"constants\":[]}}}");
    try writeGlobalEnv(a, tmp.dir, global_lock_json);
    try writeFile(tmp.dir, "nako.lock", global_lock_json);

    const main_path = try tmp.dir.realPathFileAlloc(io, "main.nako3", a);
    defer a.free(main_path);
    var stderr: std.Io.Writer.Allocating = .init(a);
    defer stderr.deinit();
    var program = (try compile.compileInput(a, io, main_path, .{}, &stderr.writer)) orelse {
        std.debug.print("compile diagnostics:\n{s}", .{stderr.written()});
        return error.TestExpectedCompileSuccess;
    };
    defer program.deinit();

    // 動的 builtin ではなく package module の実シンボルへの static call
    // （AOT はこの名前から直接関数を解決する）。
    var static_call = false;
    for (program.functions) |function| for (function.blocks) |block| for (block.instructions) |instruction| {
        if (instruction.opcode != .call) continue;
        if (!std.mem.endsWith(u8, instruction.name, "__加算確認")) continue;
        static_call = !instruction.dynamic_call;
    };
    try testing.expect(static_call);

    var runtime = lnako.runtime.value.Runtime.init(a);
    defer runtime.deinit();
    var host = lnako.runtime.interpreter.BufferHost{ .allocator = a };
    defer host.deinit();
    var interpreter = lnako.runtime.interpreter.Interpreter.init(a, &runtime, program, host.host());
    defer interpreter.deinit();
    _ = try interpreter.run();
    try testing.expectEqualStrings("42\n", host.written());
}

fn writeDemoPackage(dir: std.Io.Dir) !void {
    try writeFile(dir, package_root ++ "/src/index.nako3", "「from package」と表示\n");
    try writeFile(dir, package_root ++ "/NAKO-PKG/COMMANDS.json", "{\"schema_version\":1,\"exports_global_commands\":false,\"exports\":{\".\":{\"binding\":\"scoped\",\"commands\":[],\"constants\":[]}}}");
}

test "v1 compile: 非既定 profile と選択 feature を v1 環境の再読込へ引き継ぐ" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const manifest =
        \\schema_version = 1
        \\[package]
        \\[features]
        \\default = []
        \\extra = ["dep:demo"]
        \\[dependencies]
        \\"@acme/demo" = { version = "^1.0.0", alias = "demo", optional = true }
        \\[profiles.default]
        \\runtime = "lnako"
        \\[profiles.dev]
        \\runtime = "lnako"
        \\
    ;
    try writeFile(tmp.dir, "nako.toml", manifest);
    try writeFile(tmp.dir, "main.nako3", "!「pkg:demo」を取り込む\n「ok」と表示\n");
    try writeDemoPackage(tmp.dir);
    const dev_lock =
        \\{"schema_version":1,"profiles":[{"name":"dev","runtime":"lnako","target_triple":"aarch64-macos-none","nodes":[{"key":"@acme/demo@1.0.0","id":"@acme/demo","version":"1.0.0","sha256":"sha256:2222222222222222222222222222222222222222222222222222222222222222","kind":"universal","global":false}],"root":[{"to":"@acme/demo@1.0.0","id":"@acme/demo","req":"^1.0.0","alias":"demo","features":[],"default_features":true,"optional":true,"allow_global_commands":false,"runtimes":[]}],"edges":[]}]}
    ;
    try writeEnvForProfile(a, tmp.dir, dev_lock, "dev");
    try writeFile(tmp.dir, "nako.lock", dev_lock);

    const main_path = try tmp.dir.realPathFileAlloc(io, "main.nako3", a);
    defer a.free(main_path);
    const extra = [_][]const u8{"extra"};

    var stderr_ok: std.Io.Writer.Allocating = .init(a);
    defer stderr_ok.deinit();
    var program = (try compile.compileInput(a, io, main_path, .{
        .v1 = .{ .profile = "dev", .features = &extra },
    }, &stderr_ok.writer)) orelse {
        std.debug.print("compile diagnostics:\n{s}", .{stderr_ok.written()});
        return error.TestExpectedCompileSuccess;
    };
    defer program.deinit();
    var found_demo = false;
    for (program.module_names) |name| {
        if (std.mem.eql(u8, name, "demo")) found_demo = true;
    }
    try testing.expect(found_demo);

    // feature を落とすと lock の root と一致せず、同じ入力の再現にならない。
    var stderr_no_feature: std.Io.Writer.Allocating = .init(a);
    defer stderr_no_feature.deinit();
    if (compile.compileInput(a, io, main_path, .{
        .v1 = .{ .profile = "dev" },
    }, &stderr_no_feature.writer) catch null) |without_feature| {
        var owned = without_feature;
        owned.deinit();
        return error.TestExpectedCompileFailure;
    }

    // profile を既定へ戻すと別 profile の lock を流用できない。
    var stderr_default_profile: std.Io.Writer.Allocating = .init(a);
    defer stderr_default_profile.deinit();
    if (compile.compileInput(a, io, main_path, .{
        .v1 = .{ .features = &extra },
    }, &stderr_default_profile.writer) catch null) |default_profile| {
        var owned = default_profile;
        owned.deinit();
        return error.TestExpectedCompileFailure;
    }
}

test "v1 compile: v1 manifest では v1 環境が無いとき旧 .nako/environment.json を読まない" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "nako.toml", "schema_version = 1\n[package]\n");
    try writeFile(tmp.dir, "main.nako3", "!「pkg:demo」を取り込む\n「ok」と表示\n");
    try writeDemoPackage(tmp.dir);
    // 旧 resolver が読むと「`lnako check` で確認」の診断を出す入力。
    try writeFile(tmp.dir, ".nako/environment.json", "{\"schemaVersion\":");
    try writeFile(tmp.dir, "nako.lock", "{\"schemaVersion\":1,\"packages\":{}}");

    const main_path = try tmp.dir.realPathFileAlloc(io, "main.nako3", a);
    defer a.free(main_path);
    var stderr: std.Io.Writer.Allocating = .init(a);
    defer stderr.deinit();
    if (try compile.compileInput(a, io, main_path, .{}, &stderr.writer)) |program| {
        var owned = program;
        owned.deinit();
        return error.TestExpectedCompileFailure;
    }
    // 旧 `.nako/environment.json` の検証経路へ入っていればこの案内が出る。
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "lnako check") == null);
}
