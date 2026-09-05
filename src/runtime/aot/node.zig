const std = @import("std");
const builtin = @import("builtin");
const aot_state = @import("state.zig");
const shared = @import("shared.zig");

const aot_builtin = shared.aot_builtin;
const crypto = shared.crypto;
const string_mod = shared.string_mod;
const error_message = shared.error_message;
const Runtime = aot_state.Runtime;
const Value = aot_state.Value;
const Tag = aot_state.Tag;
const RootFrame = aot_state.RootFrame;
const AotProcessMode = aot_state.AotProcessMode;
const AotProcessTask = aot_state.AotProcessTask;
const AotArchiveTask = aot_state.AotArchiveTask;
const AotCommandResult = aot_state.AotCommandResult;
const numberValue = aot_state.numberValue;
const valueToNumber = aot_state.valueToNumber;
const valueToNumberRuntime = aot_state.valueToNumberRuntime;
const valueUtf8LossyAlloc = aot_state.valueUtf8LossyAlloc;
const valueUtf16Alloc = aot_state.valueUtf16Alloc;
const runtimeUtf8String = aot_state.runtimeUtf8String;
const runtimeUtf8StringLossy = aot_state.runtimeUtf8StringLossy;
const isString = aot_state.isString;
const stringUtf8Alloc = aot_state.stringUtf8Alloc;
const nodeBasename = aot_state.nodeBasename;
const nodeDirname = aot_state.nodeDirname;
const nodePathSeparator = aot_state.nodePathSeparator;
const nodePathSeparatorWide = aot_state.nodePathSeparatorWide;
const isWindowsDriveLetter = aot_state.isWindowsDriveLetter;
const isWindowsDriveLetterWide = aot_state.isWindowsDriveLetterWide;
const pathBasenameUnits = aot_state.pathBasenameUnits;
const pathDirnameUnits = aot_state.pathDirnameUnits;
const aotOsName = aot_state.aotOsName;
const aotArchitectureName = aot_state.aotArchitectureName;
const aotRuntimeIo = aot_state.aotRuntimeIo;
const writeAotStderr = aot_state.writeAotStderr;
const writeBytes = aot_state.writeBytes;
const runAotShellCommand = aot_state.runAotShellCommand;
const queueAotProcess = aot_state.queueAotProcess;
const aotArchiveExecute = aot_state.aotArchiveExecute;
const resolveAotCallback = aot_state.resolveAotCallback;
const nextRandom = aot_state.nextRandom;

const AotPosixIfAddrs = if (builtin.os.tag == .windows) opaque {} else extern struct {
    next: ?*AotPosixIfAddrs,
    name: [*:0]const u8,
    flags: c_uint,
    address: ?*std.posix.sockaddr,
    netmask: ?*std.posix.sockaddr,
    destination: ?*std.posix.sockaddr,
    data: ?*anyopaque,
};

const AotPosixInterfaces = if (builtin.os.tag == .windows) struct {} else struct {
    pub extern "c" fn getifaddrs(result: *?*AotPosixIfAddrs) c_int;
    pub extern "c" fn freeifaddrs(result: ?*AotPosixIfAddrs) void;
};

const AotWindowsSocketAddress = extern struct {
    address: ?*std.os.windows.ws2_32.sockaddr,
    length: c_int,
};

const AotWindowsUnicastAddress = extern struct {
    alignment: u64,
    next: ?*AotWindowsUnicastAddress,
    address: AotWindowsSocketAddress,
};

const AotWindowsAdapterAddresses = extern struct {
    alignment: u64,
    next: ?*AotWindowsAdapterAddresses,
    adapter_name: ?[*:0]u8,
    first_unicast_address: ?*AotWindowsUnicastAddress,
};

const AotWindowsInterfaces = if (builtin.os.tag == .windows) struct {
    pub extern "iphlpapi" fn GetAdaptersAddresses(
        family: u32,
        flags: u32,
        reserved: ?*anyopaque,
        addresses: ?*AotWindowsAdapterAddresses,
        size: *u32,
    ) callconv(.winapi) u32;
} else struct {};

pub fn runAotExternal(runtime: *Runtime, target: []const u8, reveal: bool) !void {
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .macos => if (reveal) &.{ "/usr/bin/open", "-R", target } else &.{ "/usr/bin/open", target },
        .windows => if (reveal)
            &.{ "explorer.exe", "/select,", target }
        else
            &.{ "cmd.exe", "/d", "/s", "/c", "start", "", target },
        else => if (reveal)
            &.{ "xdg-open", std.fs.path.dirname(target) orelse "." }
        else
            &.{ "xdg-open", target },
    };
    // Keep platform-specific argv construction on the production path, then
    // stop only the final process launch in the hermetic fixture environment.
    // This mirrors the CLI host and avoids starting a desktop application in
    // CI while preserving the official non-Windows Explorer result.
    if (std.c.getenv("LNAKO_TEST_OPEN_EXTERNAL") != null) {
        if (reveal and builtin.os.tag != .windows) return error.OpenExternalFailed;
        return;
    }
    const result = try std.process.run(runtime.allocator, runtime.process_io.io(), .{
        .argv = argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    runtime.allocator.free(result.stdout);
    runtime.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return error.OpenExternalFailed;
}

pub fn nodeProcessBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    switch (command) {
        .node_open_external_browser, .node_open_external_explorer => {
            if (arguments.len < 1) return error.InvalidArgumentCount;
            const target = try valueUtf8LossyAlloc(runtime, arguments[0]);
            defer runtime.allocator.free(target);
            try runAotExternal(runtime, target, command == .node_open_external_explorer);
            return .{};
        },
        .node_process_run_wait, .node_process_run, .node_process_start, .node_process_run_wait_output => {
            if (arguments.len < 1) return error.InvalidArgumentCount;
            const command_text = try valueUtf8LossyAlloc(runtime, arguments[0]);
            defer runtime.allocator.free(command_text);
            if (command == .node_process_run_wait) {
                const cwd = try currentDirectoryAlloc(runtime);
                defer runtime.allocator.free(cwd);
                var result = try runAotShellCommand(runtime, command_text, cwd);
                defer result.deinit(runtime.allocator);
                if (result.exit_code != 0) return error.CommandFailed;
                return runtimeUtf8StringLossy(runtime, result.stdout);
            }
            if (command == .node_process_run_wait_output) {
                const cwd = try currentDirectoryAlloc(runtime);
                defer runtime.allocator.free(cwd);
                var result = try runAotShellCommand(runtime, command_text, cwd);
                defer result.deinit(runtime.allocator);
                writeBytes(result.stdout, false);
                writeAotStderr(result.stderr);
                return numberValue(@floatFromInt(result.exit_code));
            }
            const mode = AotProcessMode.command_output;
            try queueAotProcess(runtime, command_text, mode, .{});
            return .{};
        },
        .node_process_start_callback => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            var roots = [_]Value{arguments[0]};
            var frame = RootFrame{};
            runtime.pushRoots(&frame, &roots, roots.len);
            defer runtime.popRoots(&frame);
            roots[0] = try resolveAotCallback(runtime, roots[0]);
            const command_text = try valueUtf8LossyAlloc(runtime, arguments[1]);
            defer runtime.allocator.free(command_text);
            try queueAotProcess(runtime, command_text, .output_callback, roots[0]);
            return .{};
        },
        else => return error.UnknownCommand,
    }
}

pub fn nodeBasenameWideFor(path: []const u16, windows: bool) []const u16 {
    var end = path.len;
    while (end > 0 and nodePathSeparatorWide(path[end - 1], windows)) end -= 1;
    if (end == 0) return &.{};
    const drive_path = windows and path.len >= 2 and isWindowsDriveLetterWide(path[0]) and path[1] == ':';
    if (drive_path and end == 2 and path.len > end and nodePathSeparatorWide(path[2], true)) return &.{};
    var start = end;
    while (start > 0 and !nodePathSeparatorWide(path[start - 1], windows)) start -= 1;
    if (drive_path and start < 2) start = 2;
    return path[start..end];
}
pub fn nodeNetworkAddressesBuiltin(runtime: *Runtime, ipv6: bool) !Value {
    const synthetic = if (std.c.getenv("LNAKO_TEST_NETWORK_TOPOLOGY")) |topology|
        std.mem.eql(u8, std.mem.span(topology), "synthetic-v1")
    else
        false;
    var addresses = if (synthetic)
        try syntheticAotNetworkAddresses(runtime.allocator, ipv6)
    else if (builtin.os.tag == .windows)
        try aotWindowsNetworkAddresses(runtime.allocator, ipv6)
    else
        try aotPosixNetworkAddresses(runtime.allocator, ipv6);
    defer deinitAotNetworkAddressList(runtime.allocator, &addresses);

    var result = try runtime.createArray(&.{});
    var frame = RootFrame{};
    runtime.pushRoots(&frame, @ptrCast(&result), 1);
    defer runtime.popRoots(&frame);
    for (addresses.items) |address| {
        const value = try runtimeUtf8StringLossy(runtime, address);
        try result.object().?.payload.array.append(runtime.allocator, value);
    }
    return result;
}

pub fn syntheticAotNetworkAddresses(allocator: std.mem.Allocator, ipv6: bool) !std.ArrayList([]u8) {
    // Keep the AOT test route byte-for-byte aligned with the CLI host's
    // synthetic topology. The marker is injected only by oracle fixtures.
    const addresses: []const []const u8 = if (ipv6)
        &.{ "::1", "fe80::1234", "2001:db8::10" }
    else
        &.{ "127.0.0.1", "192.0.2.10" };
    var items: std.ArrayList([]u8) = .empty;
    errdefer deinitAotNetworkAddressList(allocator, &items);
    for (addresses) |address| try items.append(allocator, try allocator.dupe(u8, address));
    return items;
}

pub fn aotPosixNetworkAddresses(allocator: std.mem.Allocator, ipv6: bool) !std.ArrayList([]u8) {
    if (builtin.os.tag == .windows) return error.NetworkInterfacesUnavailable;
    var first: ?*AotPosixIfAddrs = null;
    if (AotPosixInterfaces.getifaddrs(&first) != 0) return error.NetworkInterfacesUnavailable;
    defer AotPosixInterfaces.freeifaddrs(first);

    var items: std.ArrayList([]u8) = .empty;
    errdefer deinitAotNetworkAddressList(allocator, &items);
    var current = first;
    while (current) |entry| : (current = entry.next) {
        // Nodeのos.networkInterfaces()が内部で使うlibuvと同じく、
        // UPかつRUNNINGのインターフェイスだけを公開する。
        if ((entry.flags & 0x1) == 0 or (entry.flags & 0x40) == 0) continue;
        const address = entry.address orelse continue;
        const family: usize = @intCast(address.family);
        if ((!ipv6 and family != std.posix.AF.INET) or (ipv6 and family != std.posix.AF.INET6)) continue;
        try items.append(allocator, try aotFormatSockAddress(allocator, address));
    }
    return items;
}

pub fn aotWindowsNetworkAddresses(allocator: std.mem.Allocator, ipv6: bool) !std.ArrayList([]u8) {
    if (builtin.os.tag != .windows) return error.NetworkInterfacesUnavailable;
    const overflow_code = 111;
    var size: u32 = 15 * 1024;
    var storage = try allocator.alignedAlloc(u8, .of(AotWindowsAdapterAddresses), size);
    defer allocator.free(storage);
    var result = AotWindowsInterfaces.GetAdaptersAddresses(std.os.windows.ws2_32.AF.UNSPEC, 0, null, @ptrCast(storage.ptr), &size);
    if (result == overflow_code) {
        storage = try allocator.realloc(storage, size);
        result = AotWindowsInterfaces.GetAdaptersAddresses(std.os.windows.ws2_32.AF.UNSPEC, 0, null, @ptrCast(storage.ptr), &size);
    }
    if (result != 0) return error.NetworkInterfacesUnavailable;

    var items: std.ArrayList([]u8) = .empty;
    errdefer deinitAotNetworkAddressList(allocator, &items);
    var adapter: ?*AotWindowsAdapterAddresses = @ptrCast(storage.ptr);
    while (adapter) |current| : (adapter = current.next) {
        var unicast = current.first_unicast_address;
        while (unicast) |entry| : (unicast = entry.next) {
            const address = entry.address.address orelse continue;
            const family: usize = @intCast(address.family);
            if ((!ipv6 and family != std.os.windows.ws2_32.AF.INET) or (ipv6 and family != std.os.windows.ws2_32.AF.INET6)) continue;
            try items.append(allocator, try aotFormatWindowsSockAddress(allocator, address));
        }
    }
    return items;
}

pub fn deinitAotNetworkAddressList(allocator: std.mem.Allocator, items: *std.ArrayList([]u8)) void {
    for (items.items) |item| allocator.free(item);
    items.deinit(allocator);
}

pub fn aotFormatSockAddress(allocator: std.mem.Allocator, address: *const std.posix.sockaddr) ![]u8 {
    if (address.family == std.posix.AF.INET) {
        const source: *const std.posix.sockaddr.in = @ptrCast(@alignCast(address));
        const bytes: *const [4]u8 = @ptrCast(&source.addr);
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    }
    const source: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(address));
    return aotFormatIpv6Address(allocator, source.addr);
}

pub fn aotFormatWindowsSockAddress(allocator: std.mem.Allocator, address: *const std.os.windows.ws2_32.sockaddr) ![]u8 {
    if (address.family == std.os.windows.ws2_32.AF.INET) {
        const source: *const std.os.windows.ws2_32.sockaddr.in = @ptrCast(@alignCast(address));
        const bytes: *const [4]u8 = @ptrCast(&source.addr);
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    }
    const source: *const std.os.windows.ws2_32.sockaddr.in6 = @ptrCast(@alignCast(address));
    return aotFormatIpv6Address(allocator, source.addr);
}

pub fn aotFormatIpv6Address(allocator: std.mem.Allocator, bytes: [16]u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const unresolved: std.Io.net.Ip6Address.Unresolved = .{ .bytes = bytes, .interface_name = null };
    try output.writer.print("{f}", .{unresolved});
    return output.toOwnedSlice();
}
pub fn nodeEnvironmentBuiltin(runtime: *Runtime, command: aot_builtin.Command) !Value {
    return runtimeUtf8String(runtime, if (command == .node_os) aotOsName() else aotArchitectureName());
}

pub fn nodeProcessExitCode(runtime: *Runtime, value: Value) !u8 {
    const number = try valueToNumberRuntime(runtime, value);
    if (!std.math.isFinite(number)) return 0;
    return @intFromFloat(@mod(@trunc(number), 256.0));
}

pub fn nodeCryptoBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    switch (command) {
        .node_hash_value => {
            if (arguments.len < 2) return error.InvalidArgumentCount;
            const input = if (arguments[0].tag == @intFromEnum(Tag.byte_buffer))
                try runtime.allocator.dupe(u8, arguments[0].object().?.payload.byte_buffer.bytes)
            else
                try valueUtf8LossyAlloc(runtime, arguments[0]);
            defer runtime.allocator.free(input);
            const algorithm = try valueUtf8LossyAlloc(runtime, arguments[1]);
            defer runtime.allocator.free(algorithm);
            const digest = try crypto.calculateDigest(runtime.allocator, input, algorithm);
            defer runtime.allocator.free(digest);

            const encoding_value: Value = if (arguments.len > 2) arguments[2] else .{};
            if (encoding_value.tag == @intFromEnum(Tag.undefined) or encoding_value.tag == @intFromEnum(Tag.null_value)) return runtime.createBytes(digest);
            const encoding_name = try valueUtf8LossyAlloc(runtime, encoding_value);
            defer runtime.allocator.free(encoding_name);
            if (std.ascii.eqlIgnoreCase(encoding_name, "hex")) {
                const result = try runtime.allocator.alloc(u8, digest.len * 2);
                defer runtime.allocator.free(result);
                _ = std.fmt.bufPrint(result, "{x}", .{digest}) catch unreachable;
                return runtimeUtf8String(runtime, result);
            }
            if (std.ascii.eqlIgnoreCase(encoding_name, "base64") or std.ascii.eqlIgnoreCase(encoding_name, "base64url")) {
                const result = try runtime.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(digest.len));
                defer runtime.allocator.free(result);
                _ = std.base64.standard.Encoder.encode(result, digest);
                if (std.ascii.eqlIgnoreCase(encoding_name, "base64")) return runtimeUtf8String(runtime, result);
                for (result) |*byte| byte.* = switch (byte.*) {
                    '+' => '-',
                    '/' => '_',
                    else => byte.*,
                };
                var length = result.len;
                while (length > 0 and result[length - 1] == '=') length -= 1;
                return runtimeUtf8String(runtime, result[0..length]);
            }
            if (std.ascii.eqlIgnoreCase(encoding_name, "latin1") or std.ascii.eqlIgnoreCase(encoding_name, "binary")) {
                const units = try runtime.allocator.alloc(u16, digest.len);
                defer runtime.allocator.free(units);
                for (digest, 0..) |byte, index| units[index] = byte;
                return runtime.createString(units);
            }
            if (std.ascii.eqlIgnoreCase(encoding_name, "utf8") or std.ascii.eqlIgnoreCase(encoding_name, "utf-8")) return runtimeUtf8StringLossy(runtime, digest);
            return error.UnsupportedDigestEncoding;
        },
        .node_random_uuid => {
            if (arguments.len != 0) return error.InvalidArgumentCount;
            var bytes: [16]u8 = undefined;
            try std.Io.Threaded.global_single_threaded.io().randomSecure(&bytes);
            const uuid = crypto.formatUuid(bytes);
            return runtimeUtf8String(runtime, &uuid);
        },
        .node_random_array => {
            const source: Value = if (arguments.len > 0) arguments[0] else .{};
            const count_number = try valueToNumberRuntime(runtime, source);
            if (std.math.isInf(count_number) or count_number < 0 or count_number > 65_536) return error.InvalidRandomByteCount;
            const count: usize = if (std.math.isNan(count_number)) 0 else @intFromFloat(@trunc(count_number));
            const bytes = try runtime.allocator.alloc(u8, count);
            defer runtime.allocator.free(bytes);
            try std.Io.Threaded.global_single_threaded.io().randomSecure(bytes);
            return runtime.createUint8Array(bytes);
        },
        else => return error.UnknownCommand,
    }
}

const node_file_module = @import("node_file.zig");

pub const isNodeFileOperationCommand = node_file_module.isNodeFileOperationCommand;
pub const isNodeFileCallbackCommand = node_file_module.isNodeFileCallbackCommand;
pub const nodeFileExistenceBuiltin = node_file_module.nodeFileExistenceBuiltin;
pub const nodeFileReadBuiltin = node_file_module.nodeFileReadBuiltin;
pub const nodeEncodedFileReadBuiltin = node_file_module.nodeEncodedFileReadBuiltin;
pub const nodeFileSaveBuiltin = node_file_module.nodeFileSaveBuiltin;
pub const nodeEncodedFileSaveBuiltin = node_file_module.nodeEncodedFileSaveBuiltin;
pub const nodeEncodingName = node_file_module.nodeEncodingName;
pub const nodeEncodingValueBytesAlloc = node_file_module.nodeEncodingValueBytesAlloc;
pub const nodeEncodingBuiltin = node_file_module.nodeEncodingBuiltin;
pub const nodeFileCallbackBuiltin = node_file_module.nodeFileCallbackBuiltin;
pub const nodeFileOperationBuiltin = node_file_module.nodeFileOperationBuiltin;
pub const nodeFileListBuiltin = node_file_module.nodeFileListBuiltin;
pub const nodeFileDeleteBuiltin = node_file_module.nodeFileDeleteBuiltin;
pub const nodeFileCopyDefaultOverwrite = node_file_module.nodeFileCopyDefaultOverwrite;
pub const nodeFileCopyMoveBuiltin = node_file_module.nodeFileCopyMoveBuiltin;
pub const nodeFileSizeBuiltin = node_file_module.nodeFileSizeBuiltin;
pub const nodeFileInfoBuiltin = node_file_module.nodeFileInfoBuiltin;
pub const nodeFileInfoTrue = node_file_module.nodeFileInfoTrue;
pub const nodeFileInfoFalse = node_file_module.nodeFileInfoFalse;
pub const nodeEncodingSupportsBuiltin = node_file_module.nodeEncodingSupportsBuiltin;
pub const nodeStdinCallbackBuiltin = node_file_module.nodeStdinCallbackBuiltin;
pub const nodeStdinLineBuiltin = node_file_module.nodeStdinLineBuiltin;
pub const nodeStdinAllBuiltin = node_file_module.nodeStdinAllBuiltin;
pub const nodeStdinValueBuiltin = node_file_module.nodeStdinValueBuiltin;
pub const ensureAotStdin = node_file_module.ensureAotStdin;
pub const aotFileCopyMoveWithIo = node_file_module.aotFileCopyMoveWithIo;

const node_http_module = @import("node_http.zig");

pub const nodePostDataBuiltin = node_http_module.nodePostDataBuiltin;
pub const appendNodeUriComponent = node_http_module.appendNodeUriComponent;
pub const aotClientDictionaryGetAscii = node_http_module.aotClientDictionaryGetAscii;
pub const aotClientValueBytes = node_http_module.aotClientValueBytes;
pub const aotClientPrepareAjax = node_http_module.aotClientPrepareAjax;
pub const aotClientAppendUriComponent = node_http_module.aotClientAppendUriComponent;
pub const aotClientFormEncodedBody = node_http_module.aotClientFormEncodedBody;
pub const aotClientMultipartFields = node_http_module.aotClientMultipartFields;
pub const aotClientPreparePost = node_http_module.aotClientPreparePost;
pub const aotClientPrepareDiscord = node_http_module.aotClientPrepareDiscord;
pub const aotClientPrepareDiscordFile = node_http_module.aotClientPrepareDiscordFile;
pub const aotClientHttpMethod = node_http_module.aotClientHttpMethod;
pub const aotClientHttpRequest = node_http_module.aotClientHttpRequest;
pub const aotClientHttpBodyValue = node_http_module.aotClientHttpBodyValue;
pub const aotClientHttpResponseValue = node_http_module.aotClientHttpResponseValue;
pub const isAotHttpResponse = node_http_module.isAotHttpResponse;
pub const aotClientHttpResponseBody = node_http_module.aotClientHttpResponseBody;
pub const aotClientHttpResponseStatus = node_http_module.aotClientHttpResponseStatus;
pub const aotClientHttpBodyKind = node_http_module.aotClientHttpBodyKind;
pub const aotClientPrepareHttpCommand = node_http_module.aotClientPrepareHttpCommand;
pub const aotClientIsCallbackCommand = node_http_module.aotClientIsCallbackCommand;
pub const aotClientIsResponsePromiseCommand = node_http_module.aotClientIsResponsePromiseCommand;
pub const nodeHttpBuiltin = node_http_module.nodeHttpBuiltin;

pub fn nodeDirectoryBuiltin(runtime: *Runtime, command: aot_builtin.Command) !Value {
    if (command == .node_temporary_directory) {
        const fallback = if (builtin.os.tag == .windows) "." else "/tmp";
        const raw = if (builtin.os.tag == .windows)
            std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse fallback
        else
            std.c.getenv("TMPDIR") orelse fallback;
        const value = std.mem.span(raw);
        const trimmed = std.mem.trimEnd(u8, value, "/\\");
        return runtimeUtf8StringLossy(runtime, if (trimmed.len == 0) value else trimmed);
    }

    const home_name = if (builtin.os.tag == .windows) "USERPROFILE" else "HOME";
    const home = std.c.getenv(home_name) orelse return .{};
    const home_path = std.mem.span(home);
    if (command == .node_home_directory) return runtimeUtf8StringLossy(runtime, home_path);
    const child = switch (command) {
        .node_desktop => "Desktop",
        .node_documents => "Documents",
        else => return error.UnknownCommand,
    };
    const path = try std.fs.path.join(runtime.allocator, &.{ home_path, child });
    defer runtime.allocator.free(path);
    return runtimeUtf8StringLossy(runtime, path);
}

pub fn nodeTemporaryDirectoryPrefixAlloc(runtime: *Runtime) ![]u8 {
    const fallback = if (builtin.os.tag == .windows) "." else "/tmp";
    const raw = if (builtin.os.tag == .windows)
        std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse fallback
    else
        std.c.getenv("TMPDIR") orelse fallback;
    const value = std.mem.span(raw);
    const trimmed = std.mem.trimEnd(u8, value, "/\\");
    return runtime.allocator.dupe(u8, if (trimmed.len == 0) value else trimmed);
}

pub fn nodeCreateTemporaryDirectoryBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const prefix = try valueUtf8LossyAlloc(runtime, arguments[0]);
    defer runtime.allocator.free(prefix);

    var fallback_prefix: ?[]u8 = null;
    const effective_prefix = if (prefix.len == 0) blk: {
        fallback_prefix = try nodeTemporaryDirectoryPrefixAlloc(runtime);
        break :blk fallback_prefix.?;
    } else prefix;
    defer if (fallback_prefix) |value| runtime.allocator.free(value);

    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    const io = std.Io.Threaded.global_single_threaded.io();
    for (0..128) |_| {
        const candidate = try runtime.allocator.alloc(u8, effective_prefix.len + 6);
        errdefer runtime.allocator.free(candidate);
        @memcpy(candidate[0..effective_prefix.len], effective_prefix);
        for (candidate[effective_prefix.len..]) |*byte| {
            const index = @as(usize, @intFromFloat(@floor(nextRandom(runtime) * @as(f64, @floatFromInt(alphabet.len)))));
            byte.* = alphabet[index];
        }

        if (std.fs.path.isAbsolute(candidate)) {
            std.Io.Dir.createDirAbsolute(io, candidate, .default_dir) catch |failure| switch (failure) {
                error.PathAlreadyExists => {
                    runtime.allocator.free(candidate);
                    continue;
                },
                else => return failure,
            };
        } else {
            std.Io.Dir.cwd().createDir(io, candidate, .default_dir) catch |failure| switch (failure) {
                error.PathAlreadyExists => {
                    runtime.allocator.free(candidate);
                    continue;
                },
                else => return failure,
            };
        }

        defer runtime.allocator.free(candidate);
        return runtimeUtf8StringLossy(runtime, candidate);
    }
    return error.TemporaryDirectoryCollision;
}

pub fn nodeMotherPathBuiltin(runtime: *Runtime) !Value {
    const path = runtime.aot_source_directory orelse return error.SourcePathUnavailable;
    return runtimeUtf8StringLossy(runtime, path);
}

pub fn nodeEnvironmentValueBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const key_units = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(key_units);
    const key = try (string_mod.String{ .allocator = runtime.allocator, .units = key_units }).toUtf8Lossy(runtime.allocator);
    defer runtime.allocator.free(key);
    const key_z = try runtime.allocator.dupeZ(u8, key);
    defer runtime.allocator.free(key_z);
    const environment = std.c.getenv(key_z.ptr) orelse return .{};
    return runtimeUtf8String(runtime, std.mem.span(environment));
}

pub fn nodeEnvironmentListBuiltin(runtime: *Runtime) !Value {
    var roots = [_]Value{ .{}, .{}, .{} };
    var frame = RootFrame{};
    runtime.pushRoots(&frame, &roots, roots.len);
    defer runtime.popRoots(&frame);

    roots[0] = try runtime.createDictionary(&.{});
    if (comptime builtin.os.tag == .windows) {
        const environ: std.process.Environ = .{ .block = .global };
        var map = try std.process.Environ.createMap(environ, runtime.allocator);
        defer map.deinit();
        var iterator = map.iterator();
        while (iterator.next()) |entry| {
            roots[1] = try runtimeUtf8StringLossy(runtime, entry.key_ptr.*);
            roots[2] = try runtimeUtf8StringLossy(runtime, entry.value_ptr.*);
            try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
        }
    } else {
        var index: usize = 0;
        while (std.c.environ[index]) |entry| : (index += 1) {
            const bytes = std.mem.span(entry);
            const separator = std.mem.indexOfScalar(u8, bytes, '=') orelse continue;
            if (separator == 0) continue;
            roots[1] = try runtimeUtf8StringLossy(runtime, bytes[0..separator]);
            roots[2] = try runtimeUtf8StringLossy(runtime, bytes[separator + 1 ..]);
            try runtime.setDictionary(&roots[0].object().?.payload.dictionary, roots[1], roots[2]);
        }
    }
    return roots[0];
}

pub fn nodeCurrentDirectoryBuiltin(runtime: *Runtime) !Value {
    const path = try currentDirectoryAlloc(runtime);
    defer runtime.allocator.free(path);
    return runtimeUtf8StringLossy(runtime, path);
}

pub fn currentDirectoryAlloc(runtime: *Runtime) ![]u8 {
    // Keep AOT's cwd semantics aligned with the CLI host.  In particular,
    // Node reports the canonical path after entering a directory through a
    // symlink; a raw getcwd buffer is a separate platform-specific path.
    const io = std.Io.Threaded.global_single_threaded.io();
    const canonical = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", runtime.allocator);
    defer runtime.allocator.free(canonical.ptr[0 .. canonical.len + 1]);
    return runtime.allocator.dupe(u8, canonical);
}

pub fn aotProcessEnvironment() std.process.Environ {
    if (comptime builtin.os.tag == .windows) return .{ .block = .global };
    var count: usize = 0;
    while (std.c.environ[count] != null) : (count += 1) {}
    return .{ .block = .{ .slice = std.c.environ[0..count :null] } };
}

pub fn nodeChangeDirectoryBuiltin(runtime: *Runtime, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const units = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(units);
    const display_path = try (string_mod.String{ .allocator = runtime.allocator, .units = units }).toUtf8Lossy(runtime.allocator);
    defer runtime.allocator.free(display_path);
    const path = if (comptime builtin.os.tag == .windows)
        try std.unicode.wtf16LeToWtf8Alloc(runtime.allocator, units)
    else
        try runtime.allocator.dupe(u8, display_path);
    defer runtime.allocator.free(path);
    const cwd_raw = try currentDirectoryAlloc(runtime);
    defer runtime.allocator.free(cwd_raw);
    const cwd = try aotNodeErrorPathAlloc(runtime, cwd_raw);
    defer runtime.allocator.free(cwd);
    const io = std.Io.Threaded.global_single_threaded.io();
    var directory = std.Io.Dir.cwd().openDir(io, path, .{}) catch |failure| {
        try setAotNodeChangeDirectoryFailure(runtime, cwd, display_path, failure);
        return failure;
    };
    defer directory.close(io);
    std.process.setCurrentDir(io, directory) catch |failure| {
        try setAotNodeChangeDirectoryFailure(runtime, cwd, display_path, failure);
        return failure;
    };
    return .{};
}

const AotNodeChangeDirectoryErrorInfo = struct {
    code: []const u8,
    description: []const u8,
};

pub fn aotNodeChangeDirectoryErrorInfo(failure: anyerror) ?AotNodeChangeDirectoryErrorInfo {
    return switch (failure) {
        error.FileNotFound => .{ .code = "ENOENT", .description = "no such file or directory" },
        error.NotDir => .{ .code = "ENOTDIR", .description = "not a directory" },
        error.AccessDenied, error.PermissionDenied => .{ .code = "EACCES", .description = "permission denied" },
        error.NameTooLong => .{ .code = "ENAMETOOLONG", .description = "name too long" },
        error.BadPathName, error.InvalidWtf8 => .{ .code = "EINVAL", .description = "invalid argument" },
        error.SymLinkLoop => .{ .code = "ELOOP", .description = "too many levels of symbolic links" },
        else => null,
    };
}

pub fn aotNodeErrorPathAlloc(runtime: *Runtime, path: []const u8) ![]u8 {
    if (comptime builtin.os.tag == .windows) {
        return std.unicode.wtf8ToUtf8LossyAlloc(runtime.allocator, path);
    }
    return runtime.allocator.dupe(u8, path);
}

pub fn setAotNodeChangeDirectoryFailure(runtime: *Runtime, cwd: []const u8, path: []const u8, failure: anyerror) !void {
    const info = aotNodeChangeDirectoryErrorInfo(failure) orelse return;
    const message = try std.fmt.allocPrint(
        runtime.allocator,
        "{s}: {s}, chdir '{s}' -> '{s}'",
        .{ info.code, info.description, cwd, path },
    );
    defer runtime.allocator.free(message);
    runtime.setFailureText(message);
}

pub fn nodePathBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    const required: usize = if (command == .node_path_resolve) 2 else 1;
    if (arguments.len < required) return error.InvalidArgumentCount;

    const first_label = if (command == .node_path_absolute) "paths[0]" else "path";
    const first = try nodePathArgument(runtime, first_label, arguments[0]);
    defer runtime.allocator.free(first);
    const cwd = try currentDirectoryAlloc(runtime);
    defer runtime.allocator.free(cwd);

    const resolved = switch (command) {
        .node_path_absolute => try std.fs.path.resolve(runtime.allocator, &.{ cwd, first }),
        .node_path_resolve => blk: {
            const second = try nodePathArgument(runtime, "path", arguments[1]);
            defer runtime.allocator.free(second);
            const joined = try std.fs.path.join(runtime.allocator, &.{ first, second });
            defer runtime.allocator.free(joined);
            break :blk try std.fs.path.resolve(runtime.allocator, &.{ cwd, joined });
        },
        else => return error.UnknownCommand,
    };
    defer runtime.allocator.free(resolved);
    return runtimeUtf8StringLossy(runtime, resolved);
}

pub fn nodePathComponentBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    const path = try nodePathArgument(runtime, "path", arguments[0]);
    defer runtime.allocator.free(path);
    const component = switch (command) {
        .node_path_basename => nodeBasename(path),
        .node_path_dirname => nodeDirname(path),
        else => return error.UnknownCommand,
    };
    return runtimeUtf8StringLossy(runtime, component);
}

pub fn systemPathComponentBuiltin(runtime: *Runtime, command: aot_builtin.Command, arguments: []const Value) !Value {
    if (arguments.len < 1) return error.InvalidArgumentCount;
    if (!isString(arguments[0])) return error.InvalidPathSource;
    const path = try valueUtf16Alloc(runtime, arguments[0]);
    defer runtime.allocator.free(path);
    const component = switch (command) {
        .system_path_basename => pathBasenameUnits(path, '/'),
        .system_path_dirname => blk: {
            const separator = std.mem.lastIndexOfScalar(u16, path, '/');
            break :blk if (separator) |index| path[0..index] else &.{};
        },
        else => return error.UnknownCommand,
    };
    return runtime.createString(component);
}

pub fn nodePathArgument(runtime: *Runtime, label: []const u8, value: Value) ![]u8 {
    if (!isString(value)) {
        const received = try nodePathReceivedType(runtime, value);
        defer runtime.allocator.free(received);
        const message = try std.fmt.allocPrint(
            runtime.allocator,
            "The \"{s}\" argument must be of type string. Received {s}",
            .{ label, received },
        );
        defer runtime.allocator.free(message);
        runtime.setFailureText(message);
        return error.InvalidPathSource;
    }
    return stringUtf8Alloc(runtime, value);
}

pub fn nodePathReceivedType(runtime: *Runtime, value: Value) ![]u8 {
    return switch (@as(Tag, @enumFromInt(value.tag))) {
        .undefined => runtime.allocator.dupe(u8, "undefined"),
        .null_value => runtime.allocator.dupe(u8, "null"),
        .boolean => runtime.allocator.dupe(u8, if (value.payload == 0) "type boolean (false)" else "type boolean (true)"),
        .number => nodePathPrimitiveReceivedType(runtime, value, "number", false),
        .bigint => nodePathPrimitiveReceivedType(runtime, value, "bigint", true),
        .byte_buffer => switch (value.object().?.payload.byte_buffer.kind) {
            .buffer => runtime.allocator.dupe(u8, "an instance of Buffer"),
            .uint8_array => runtime.allocator.dupe(u8, "an instance of Uint8Array"),
            .array_buffer => runtime.allocator.dupe(u8, "an instance of ArrayBuffer"),
        },
        .array => runtime.allocator.dupe(u8, "an instance of Array"),
        .dictionary, .iterator, .binding_cell => runtime.allocator.dupe(u8, "an instance of Object"),
        .function => runtime.allocator.dupe(u8, "function "),
        .promise => runtime.allocator.dupe(u8, "an instance of Promise"),
        .static_utf8_string, .utf16_string => unreachable,
    };
}

pub fn nodePathPrimitiveReceivedType(runtime: *Runtime, value: Value, type_name: []const u8, bigint_suffix: bool) ![]u8 {
    const text = try valueUtf8LossyAlloc(runtime, value);
    defer runtime.allocator.free(text);
    return std.fmt.allocPrint(
        runtime.allocator,
        "type {s} ({s}{s})",
        .{ type_name, text, if (bigint_suffix) "n" else "" },
    );
}
