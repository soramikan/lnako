const shared = @import("shared.zig");

const std = shared.std;
const no_dispatch_call_id = shared.no_dispatch_call_id;
const fflush = struct {
    pub extern "c" fn fflush(stream: ?*std.c.FILE) c_int;
}.fflush;

pub const DispatchTrace = struct {
    file: ?*std.c.FILE = null,
    initialized: bool = false,
    disabled: bool = false,
    sequence: u64 = 0,
    next_call_id: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *DispatchTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *DispatchTrace) void {
        self.locked.store(false, .release);
    }

    pub fn deinit(self: *DispatchTrace) void {
        self.finish();
        self.lock();
        defer self.unlock();
        if (self.file) |file| _ = std.c.fclose(file);
        self.file = null;
    }

    pub fn ensureFile(self: *DispatchTrace) ?*std.c.FILE {
        if (self.disabled) return null;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse return null;
            if (path[0] == 0) return null;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return null;
            };
        }
        return self.file;
    }

    pub fn writeLine(self: *DispatchTrace, file: *std.c.FILE, rendered: []const u8) bool {
        if (std.c.fwrite(rendered.ptr, 1, rendered.len, file) != rendered.len or fflush(file) != 0) {
            _ = std.c.fclose(file);
            self.file = null;
            self.disabled = true;
            return false;
        }
        self.sequence += 1;
        return true;
    }

    pub fn begin(self: *DispatchTrace, command: []const u8, opcode: u16, route: []const u8, site_id: u64) u64 {
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return no_dispatch_call_id;
        if (self.next_call_id == no_dispatch_call_id) {
            self.disabled = true;
            return no_dispatch_call_id;
        }
        const call_id = self.next_call_id;
        self.next_call_id += 1;
        var line: [768]u8 = undefined;
        const rendered = if (site_id == 0)
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-attempt\",\"seq\":{d},\"callId\":{d},\"siteId\":null,\"opcode\":{d},\"command\":\"{s}\",\"name_source\":\"canonical-opcode\",\"route\":\"{s}\"}}\n", .{ self.sequence, call_id, opcode, command, route }) catch {
                self.disabled = true;
                return no_dispatch_call_id;
            }
        else
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-attempt\",\"seq\":{d},\"callId\":{d},\"siteId\":\"0x{x:0>16}\",\"opcode\":{d},\"command\":\"{s}\",\"name_source\":\"canonical-opcode\",\"route\":\"{s}\"}}\n", .{ self.sequence, call_id, site_id, opcode, command, route }) catch {
                self.disabled = true;
                return no_dispatch_call_id;
            };
        if (!self.writeLine(file, rendered)) return no_dispatch_call_id;
        return call_id;
    }

    pub fn result(self: *DispatchTrace, call_id: u64, command: []const u8, opcode: u16, route: []const u8, site_id: u64, success: bool) void {
        if (call_id == no_dispatch_call_id) return;
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return;
        var line: [768]u8 = undefined;
        const rendered = if (site_id == 0)
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-result\",\"seq\":{d},\"callId\":{d},\"siteId\":null,\"opcode\":{d},\"command\":\"{s}\",\"route\":\"{s}\",\"success\":{}}}\n", .{ self.sequence, call_id, opcode, command, route, success }) catch {
                self.disabled = true;
                return;
            }
        else
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-result\",\"seq\":{d},\"callId\":{d},\"siteId\":\"0x{x:0>16}\",\"opcode\":{d},\"command\":\"{s}\",\"route\":\"{s}\",\"success\":{}}}\n", .{ self.sequence, call_id, site_id, opcode, command, route, success }) catch {
                self.disabled = true;
                return;
            };
        _ = self.writeLine(file, rendered);
    }

    pub fn finish(self: *DispatchTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse return;
            if (path[0] == 0) return;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return;
            };
        }
        const file = self.ensureFile() orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        if (self.writeLine(file, rendered)) self.disabled = true;
    }

    pub fn finishTerminal(self: *DispatchTrace, reason: []const u8, exit_code: u8) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse return;
            if (path[0] == 0) return;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return;
            };
        }
        const file = self.ensureFile() orelse return;
        var line: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0,\"terminalReason\":\"{s}\",\"exitCode\":{d},\"signal\":null}}\n",
            .{ self.sequence, reason, exit_code },
        ) catch return;
        if (self.writeLine(file, rendered)) self.disabled = true;
    }
};

/// Global-read tracing is a separate opt-in channel from builtin dispatch
/// tracing. It records only that a statically identified global load executed;
/// names and values remain in the compile manifest and never cross the ABI.
pub const GlobalTrace = struct {
    file: ?*std.c.FILE = null,
    initialized: bool = false,
    disabled: bool = false,
    sequence: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *GlobalTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *GlobalTrace) void {
        self.locked.store(false, .release);
    }

    pub fn deinit(self: *GlobalTrace) void {
        self.finish();
        self.lock();
        defer self.unlock();
        if (self.file) |file| _ = std.c.fclose(file);
        self.file = null;
    }

    pub fn ensureFile(self: *GlobalTrace) ?*std.c.FILE {
        if (self.disabled) return null;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_GLOBAL_TRACE") orelse return null;
            if (path[0] == 0) return null;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return null;
            };
        }
        return self.file;
    }

    pub fn writeLine(self: *GlobalTrace, file: *std.c.FILE, rendered: []const u8) bool {
        if (std.c.fwrite(rendered.ptr, 1, rendered.len, file) != rendered.len or fflush(file) != 0) {
            _ = std.c.fclose(file);
            self.file = null;
            self.disabled = true;
            return false;
        }
        self.sequence += 1;
        return true;
    }

    pub fn record(self: *GlobalTrace, site_id: u64) void {
        self.recordPhase(site_id, "global-read");
    }

    pub fn recordWrite(self: *GlobalTrace, site_id: u64) void {
        self.recordPhase(site_id, "global-write");
    }

    pub fn recordPhase(self: *GlobalTrace, site_id: u64, phase: []const u8) void {
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return;
        var line: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"aot\",\"phase\":\"{s}\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"success\":true}}\n",
            .{ phase, self.sequence, site_id },
        ) catch {
            self.disabled = true;
            return;
        };
        _ = self.writeLine(file, rendered);
    }

    pub fn finish(self: *GlobalTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const file = if (self.initialized) self.file orelse return else blk: {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_GLOBAL_TRACE") orelse return;
            if (path[0] == 0) return;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return;
            };
            break :blk self.file;
        } orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"aot\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        if (self.writeLine(file, rendered)) self.disabled = true;
    }
};

/// Typed literal tracing is separate from global-read tracing because the
/// catalog lists both as `定数`, while only a global reference performs a
/// runtime lookup. The trace records execution of the fixed literal site and
/// never exposes the literal value through the ABI.
pub const LiteralTrace = struct {
    file: ?*std.c.FILE = null,
    initialized: bool = false,
    disabled: bool = false,
    sequence: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *LiteralTrace) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *LiteralTrace) void {
        self.locked.store(false, .release);
    }

    pub fn deinit(self: *LiteralTrace) void {
        self.finish();
        self.lock();
        defer self.unlock();
        if (self.file) |file| _ = std.c.fclose(file);
        self.file = null;
    }

    pub fn ensureFile(self: *LiteralTrace) ?*std.c.FILE {
        if (self.disabled) return null;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_LITERAL_TRACE") orelse return null;
            if (path[0] == 0) return null;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return null;
            };
        }
        return self.file;
    }

    pub fn writeLine(self: *LiteralTrace, file: *std.c.FILE, rendered: []const u8) bool {
        if (std.c.fwrite(rendered.ptr, 1, rendered.len, file) != rendered.len or fflush(file) != 0) {
            _ = std.c.fclose(file);
            self.file = null;
            self.disabled = true;
            return false;
        }
        self.sequence += 1;
        return true;
    }

    pub fn record(self: *LiteralTrace, site_id: u64) void {
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return;
        var line: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"aot\",\"phase\":\"literal\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"success\":true}}\n",
            .{ self.sequence, site_id },
        ) catch {
            self.disabled = true;
            return;
        };
        _ = self.writeLine(file, rendered);
    }

    pub fn finish(self: *LiteralTrace) void {
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const file = if (self.initialized) self.file orelse return else blk: {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_LITERAL_TRACE") orelse return;
            if (path[0] == 0) return;
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disabled = true;
                return;
            };
            break :blk self.file;
        } orelse return;
        var line: [160]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"aot\",\"phase\":\"trace-end\",\"seq\":{d},\"dropped\":0}}\n",
            .{self.sequence},
        ) catch return;
        if (self.writeLine(file, rendered)) self.disabled = true;
    }
};
