const std = @import("std");
const builtin = @import("builtin");
const lnako = @import("lnako");

pub var interrupt_requested = std.atomic.Value(bool).init(false);

pub const WindowsInterrupt = if (builtin.os.tag == .windows) struct {
    pub extern "kernel32" fn SetConsoleCtrlHandler(handler_fn: ?*const fn (u32) callconv(.winapi) i32, add: i32) callconv(.winapi) i32;

    pub fn handler(control_type: u32) callconv(.winapi) i32 {
        if (control_type != 0 and control_type != 1) return 0;
        interrupt_requested.store(true, .release);
        return 1;
    }
} else struct {};

pub const WindowsShell = if (builtin.os.tag == .windows) struct {
    pub extern "shell32" fn ShellExecuteW(hwnd: ?*anyopaque, lpOperation: ?[*:0]const u16, lpFile: [*:0]const u16, lpParameters: ?[*:0]const u16, lpDirectory: ?[*:0]const u16, nShowCmd: c_int) callconv(.winapi) isize;

    fn wtf16LeFromWtf8(allocator: std.mem.Allocator, source: []const u8) ![:0]u16 {
        const units = try std.unicode.wtf8ToWtf16LeAlloc(allocator, source);
        defer allocator.free(units);
        return try allocator.dupeZ(u16, units);
    }

    pub fn openExternal(allocator: std.mem.Allocator, target: []const u8, reveal: bool) !void {
        if (reveal) {
            if (std.mem.indexOfAny(u8, target, "\"\x00")) |_| return error.OpenExternalFailed;
            const file: [*:0]const u16 = std.unicode.wtf8ToWtf16LeStringLiteral("explorer.exe").ptr;
            const parameters_utf8 = try std.fmt.allocPrint(allocator, "/select,\"{s}\"", .{target});
            defer allocator.free(parameters_utf8);
            const parameters = try wtf16LeFromWtf8(allocator, parameters_utf8);
            defer allocator.free(parameters);
            if (ShellExecuteW(null, null, file, parameters.ptr, null, 1) <= 32) return error.OpenExternalFailed;
        } else {
            const file = try wtf16LeFromWtf8(allocator, target);
            defer allocator.free(file);
            if (ShellExecuteW(null, null, file.ptr, null, null, 1) <= 32) return error.OpenExternalFailed;
        }
    }
} else struct {};

const PosixIfAddrs = if (builtin.os.tag == .windows) opaque {} else extern struct {
    next: ?*PosixIfAddrs,
    name: [*:0]const u8,
    flags: c_uint,
    address: ?*std.posix.sockaddr,
    netmask: ?*std.posix.sockaddr,
    destination: ?*std.posix.sockaddr,
    data: ?*anyopaque,
};

const PosixInterfaces = if (builtin.os.tag == .windows) struct {} else struct {
    extern "c" fn getifaddrs(result: *?*PosixIfAddrs) c_int;
    extern "c" fn freeifaddrs(result: ?*PosixIfAddrs) void;
};

const WindowsSocketAddress = extern struct {
    address: ?*std.os.windows.ws2_32.sockaddr,
    length: c_int,
};

const WindowsUnicastAddress = extern struct {
    alignment: u64,
    next: ?*WindowsUnicastAddress,
    address: WindowsSocketAddress,
};

const WindowsAdapterAddresses = extern struct {
    alignment: u64,
    next: ?*WindowsAdapterAddresses,
    adapter_name: ?[*:0]u8,
    first_unicast_address: ?*WindowsUnicastAddress,
};

const WindowsInterfaces = if (builtin.os.tag == .windows) struct {
    extern "iphlpapi" fn GetAdaptersAddresses(
        family: u32,
        flags: u32,
        reserved: ?*anyopaque,
        addresses: ?*WindowsAdapterAddresses,
        size: *u32,
    ) callconv(.winapi) u32;
} else struct {};

pub fn posixNetworkAddresses(allocator: std.mem.Allocator, ipv6: bool) !lnako.plugins.node.NetworkAddresses {
    if (builtin.os.tag == .windows) return error.NetworkInterfacesUnavailable;
    var first: ?*PosixIfAddrs = null;
    if (PosixInterfaces.getifaddrs(&first) != 0) return error.NetworkInterfacesUnavailable;
    defer PosixInterfaces.freeifaddrs(first);
    var items: std.ArrayList([]u8) = .empty;
    errdefer deinitNetworkAddressList(allocator, &items);
    var current = first;
    while (current) |entry| : (current = entry.next) {
        // Nodeのos.networkInterfaces()が内部で使うlibuvと同じく、
        // UPかつRUNNINGのインターフェイスだけを公開する。
        if ((entry.flags & 0x1) == 0 or (entry.flags & 0x40) == 0) continue;
        const address = entry.address orelse continue;
        const family: usize = @intCast(address.family);
        if ((!ipv6 and family != std.posix.AF.INET) or (ipv6 and family != std.posix.AF.INET6)) continue;
        try items.append(allocator, try formatSockAddress(allocator, address, if (ipv6) std.mem.span(entry.name) else null));
    }
    return .{ .items = try items.toOwnedSlice(allocator) };
}

pub fn syntheticNetworkAddresses(allocator: std.mem.Allocator, ipv6: bool) !lnako.plugins.node.NetworkAddresses {
    // This test-only topology mirrors the fields that Node's os.networkInterfaces()
    // exposes while keeping the returned command value limited to address strings.
    // Production runs never set LNAKO_TEST_NETWORK_TOPOLOGY and use the OS APIs below.
    const addresses: []const []const u8 = if (ipv6)
        &.{ "::1", "fe80::1234", "2001:db8::10" }
    else
        &.{ "127.0.0.1", "192.0.2.10" };
    var items: std.ArrayList([]u8) = .empty;
    errdefer deinitNetworkAddressList(allocator, &items);
    for (addresses) |address| try items.append(allocator, try allocator.dupe(u8, address));
    return .{ .items = try items.toOwnedSlice(allocator) };
}

pub fn windowsNetworkAddresses(allocator: std.mem.Allocator, ipv6: bool) !lnako.plugins.node.NetworkAddresses {
    if (builtin.os.tag != .windows) return error.NetworkInterfacesUnavailable;
    const overflow_code = 111;
    var size: u32 = 15 * 1024;
    var storage = try allocator.alignedAlloc(u8, .of(WindowsAdapterAddresses), size);
    defer allocator.free(storage);
    var result = WindowsInterfaces.GetAdaptersAddresses(std.os.windows.ws2_32.AF.UNSPEC, 0, null, @ptrCast(storage.ptr), &size);
    if (result == overflow_code) {
        storage = try allocator.realloc(storage, size);
        result = WindowsInterfaces.GetAdaptersAddresses(std.os.windows.ws2_32.AF.UNSPEC, 0, null, @ptrCast(storage.ptr), &size);
    }
    if (result != 0) return error.NetworkInterfacesUnavailable;
    var items: std.ArrayList([]u8) = .empty;
    errdefer deinitNetworkAddressList(allocator, &items);
    var adapter: ?*WindowsAdapterAddresses = @ptrCast(storage.ptr);
    while (adapter) |current| : (adapter = current.next) {
        var unicast = current.first_unicast_address;
        while (unicast) |entry| : (unicast = entry.next) {
            const address = entry.address.address orelse continue;
            const family: usize = @intCast(address.family);
            if ((!ipv6 and family != std.os.windows.ws2_32.AF.INET) or (ipv6 and family != std.os.windows.ws2_32.AF.INET6)) continue;
            try items.append(allocator, try formatWindowsSockAddress(allocator, address));
        }
    }
    return .{ .items = try items.toOwnedSlice(allocator) };
}

pub fn deinitNetworkAddressList(allocator: std.mem.Allocator, items: *std.ArrayList([]u8)) void {
    for (items.items) |item| allocator.free(item);
    items.deinit(allocator);
}

pub fn formatSockAddress(allocator: std.mem.Allocator, address: *const std.posix.sockaddr, interface_name: ?[]const u8) ![]u8 {
    _ = interface_name;
    if (address.family == std.posix.AF.INET) {
        const source: *const std.posix.sockaddr.in = @ptrCast(@alignCast(address));
        const bytes: *const [4]u8 = @ptrCast(&source.addr);
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    }
    const source: *const std.posix.sockaddr.in6 = @ptrCast(@alignCast(address));
    return formatIpv6Address(allocator, source.addr);
}

pub fn formatWindowsSockAddress(allocator: std.mem.Allocator, address: *const std.os.windows.ws2_32.sockaddr) ![]u8 {
    if (address.family == std.os.windows.ws2_32.AF.INET) {
        const source: *const std.os.windows.ws2_32.sockaddr.in = @ptrCast(@alignCast(address));
        const bytes: *const [4]u8 = @ptrCast(&source.addr);
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
    }
    const source: *const std.os.windows.ws2_32.sockaddr.in6 = @ptrCast(@alignCast(address));
    return formatIpv6Address(allocator, source.addr);
}

pub fn formatIpv6Address(allocator: std.mem.Allocator, bytes: [16]u8) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    const unresolved: std.Io.net.Ip6Address.Unresolved = .{ .bytes = bytes, .interface_name = null };
    try output.writer.print("{f}", .{unresolved});
    return output.toOwnedSlice();
}
