const shared = @import("shared.zig");

const std = shared.std;
const no_dispatch_call_id = shared.no_dispatch_call_id;
const fflush = struct {
    pub extern "c" fn fflush(stream: ?*std.c.FILE) c_int;
}.fflush;

/// Trace output is opt-in through environment variables resolved at the first
/// record call.  Every entry point checks `gate` before taking the lock so a
/// runtime with tracing disabled never pays the atomic lock acquisition on
/// the hot path.  The gate is only written while holding `locked` and moves
/// monotonically: unresolved → active/inactive, or active → inactive once the
/// writer fails or the trace is finished.  A `finish` call on an unresolved
/// trace still resolves the environment under the lock so a program that only
/// terminates writes the same terminal record as before.
const Gate = enum(u8) { unresolved, active, inactive };

pub const DispatchTrace = struct {
    file: ?*std.c.FILE = null,
    initialized: bool = false,
    disabled: bool = false,
    sequence: u64 = 0,
    next_call_id: u64 = 0,
    locked: std.atomic.Value(bool) = .init(false),
    gate: std.atomic.Value(u8) = .init(@intFromEnum(Gate.unresolved)),
    /// Number of times the spin lock was actually entered.  Diagnostics use
    /// this to prove a disabled trace never reaches the lock.
    lock_attempts: u64 = 0,

    pub fn lock(self: *DispatchTrace) void {
        self.lock_attempts += 1;
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *DispatchTrace) void {
        self.locked.store(false, .release);
    }

    fn disable(self: *DispatchTrace) void {
        self.disabled = true;
        self.gate.store(@intFromEnum(Gate.inactive), .release);
    }

    fn resolveGate(self: *DispatchTrace) void {
        // Callers hold the lock.  `initialized && file == null` means the
        // environment lookup already ran and found nothing to open.
        if (self.disabled or (self.initialized and self.file == null)) {
            self.gate.store(@intFromEnum(Gate.inactive), .release);
        } else if (self.file != null) {
            self.gate.store(@intFromEnum(Gate.active), .release);
        }
    }

    fn resolvedInactive(self: *DispatchTrace) bool {
        return self.gate.load(.acquire) == @intFromEnum(Gate.inactive);
    }

    pub fn deinit(self: *DispatchTrace) void {
        self.finish();
        self.lock();
        defer self.unlock();
        if (self.file) |file| _ = std.c.fclose(file);
        self.file = null;
    }

    pub fn ensureFile(self: *DispatchTrace) ?*std.c.FILE {
        if (self.disabled) {
            self.resolveGate();
            return null;
        }
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse {
                self.resolveGate();
                return null;
            };
            if (path[0] == 0) {
                self.resolveGate();
                return null;
            }
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disable();
                return null;
            };
        }
        self.resolveGate();
        return self.file;
    }

    pub fn writeLine(self: *DispatchTrace, file: *std.c.FILE, rendered: []const u8) bool {
        if (std.c.fwrite(rendered.ptr, 1, rendered.len, file) != rendered.len or fflush(file) != 0) {
            _ = std.c.fclose(file);
            self.file = null;
            self.disable();
            return false;
        }
        self.sequence += 1;
        return true;
    }

    pub fn begin(self: *DispatchTrace, command: []const u8, opcode: u16, route: []const u8, site_id: u64) u64 {
        if (self.resolvedInactive()) return no_dispatch_call_id;
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return no_dispatch_call_id;
        if (self.next_call_id == no_dispatch_call_id) {
            self.disable();
            return no_dispatch_call_id;
        }
        const call_id = self.next_call_id;
        self.next_call_id += 1;
        var line: [768]u8 = undefined;
        const rendered = if (site_id == 0)
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-attempt\",\"seq\":{d},\"callId\":{d},\"siteId\":null,\"opcode\":{d},\"command\":\"{s}\",\"name_source\":\"canonical-opcode\",\"route\":\"{s}\"}}\n", .{ self.sequence, call_id, opcode, command, route }) catch {
                self.disable();
                return no_dispatch_call_id;
            }
        else
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-attempt\",\"seq\":{d},\"callId\":{d},\"siteId\":\"0x{x:0>16}\",\"opcode\":{d},\"command\":\"{s}\",\"name_source\":\"canonical-opcode\",\"route\":\"{s}\"}}\n", .{ self.sequence, call_id, site_id, opcode, command, route }) catch {
                self.disable();
                return no_dispatch_call_id;
            };
        if (!self.writeLine(file, rendered)) return no_dispatch_call_id;
        return call_id;
    }

    pub fn result(self: *DispatchTrace, call_id: u64, command: []const u8, opcode: u16, route: []const u8, site_id: u64, success: bool) void {
        if (call_id == no_dispatch_call_id) return;
        if (self.resolvedInactive()) return;
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return;
        var line: [768]u8 = undefined;
        const rendered = if (site_id == 0)
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-result\",\"seq\":{d},\"callId\":{d},\"siteId\":null,\"opcode\":{d},\"command\":\"{s}\",\"route\":\"{s}\",\"success\":{}}}\n", .{ self.sequence, call_id, opcode, command, route, success }) catch {
                self.disable();
                return;
            }
        else
            std.fmt.bufPrint(&line, "{{\"schema\":2,\"engine\":\"aot\",\"phase\":\"dispatch-result\",\"seq\":{d},\"callId\":{d},\"siteId\":\"0x{x:0>16}\",\"opcode\":{d},\"command\":\"{s}\",\"route\":\"{s}\",\"success\":{}}}\n", .{ self.sequence, call_id, site_id, opcode, command, route, success }) catch {
                self.disable();
                return;
            };
        _ = self.writeLine(file, rendered);
    }

    pub fn finish(self: *DispatchTrace) void {
        if (self.resolvedInactive()) return;
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse {
                self.resolveGate();
                return;
            };
            if (path[0] == 0) {
                self.resolveGate();
                return;
            }
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disable();
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
        if (self.writeLine(file, rendered)) self.disable();
    }

    pub fn finishTerminal(self: *DispatchTrace, reason: []const u8, exit_code: u8) void {
        if (self.resolvedInactive()) return;
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_DISPATCH_TRACE") orelse {
                self.resolveGate();
                return;
            };
            if (path[0] == 0) {
                self.resolveGate();
                return;
            }
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disable();
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
        if (self.writeLine(file, rendered)) self.disable();
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
    gate: std.atomic.Value(u8) = .init(@intFromEnum(Gate.unresolved)),
    lock_attempts: u64 = 0,

    pub fn lock(self: *GlobalTrace) void {
        self.lock_attempts += 1;
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *GlobalTrace) void {
        self.locked.store(false, .release);
    }

    fn disable(self: *GlobalTrace) void {
        self.disabled = true;
        self.gate.store(@intFromEnum(Gate.inactive), .release);
    }

    fn resolveGate(self: *GlobalTrace) void {
        if (self.disabled or (self.initialized and self.file == null)) {
            self.gate.store(@intFromEnum(Gate.inactive), .release);
        } else if (self.file != null) {
            self.gate.store(@intFromEnum(Gate.active), .release);
        }
    }

    fn resolvedInactive(self: *GlobalTrace) bool {
        return self.gate.load(.acquire) == @intFromEnum(Gate.inactive);
    }

    pub fn deinit(self: *GlobalTrace) void {
        self.finish();
        self.lock();
        defer self.unlock();
        if (self.file) |file| _ = std.c.fclose(file);
        self.file = null;
    }

    pub fn ensureFile(self: *GlobalTrace) ?*std.c.FILE {
        if (self.disabled) {
            self.resolveGate();
            return null;
        }
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_GLOBAL_TRACE") orelse {
                self.resolveGate();
                return null;
            };
            if (path[0] == 0) {
                self.resolveGate();
                return null;
            }
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disable();
                return null;
            };
        }
        self.resolveGate();
        return self.file;
    }

    pub fn writeLine(self: *GlobalTrace, file: *std.c.FILE, rendered: []const u8) bool {
        if (std.c.fwrite(rendered.ptr, 1, rendered.len, file) != rendered.len or fflush(file) != 0) {
            _ = std.c.fclose(file);
            self.file = null;
            self.disable();
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
        if (self.resolvedInactive()) return;
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return;
        var line: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"aot\",\"phase\":\"{s}\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"success\":true}}\n",
            .{ phase, self.sequence, site_id },
        ) catch {
            self.disable();
            return;
        };
        _ = self.writeLine(file, rendered);
    }

    pub fn finish(self: *GlobalTrace) void {
        if (self.resolvedInactive()) return;
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const file = if (self.initialized) self.file orelse {
            self.resolveGate();
            return;
        } else blk: {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_GLOBAL_TRACE") orelse {
                self.resolveGate();
                return;
            };
            if (path[0] == 0) {
                self.resolveGate();
                return;
            }
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disable();
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
        if (self.writeLine(file, rendered)) self.disable();
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
    gate: std.atomic.Value(u8) = .init(@intFromEnum(Gate.unresolved)),
    lock_attempts: u64 = 0,

    pub fn lock(self: *LiteralTrace) void {
        self.lock_attempts += 1;
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *LiteralTrace) void {
        self.locked.store(false, .release);
    }

    fn disable(self: *LiteralTrace) void {
        self.disabled = true;
        self.gate.store(@intFromEnum(Gate.inactive), .release);
    }

    fn resolveGate(self: *LiteralTrace) void {
        if (self.disabled or (self.initialized and self.file == null)) {
            self.gate.store(@intFromEnum(Gate.inactive), .release);
        } else if (self.file != null) {
            self.gate.store(@intFromEnum(Gate.active), .release);
        }
    }

    fn resolvedInactive(self: *LiteralTrace) bool {
        return self.gate.load(.acquire) == @intFromEnum(Gate.inactive);
    }

    pub fn deinit(self: *LiteralTrace) void {
        self.finish();
        self.lock();
        defer self.unlock();
        if (self.file) |file| _ = std.c.fclose(file);
        self.file = null;
    }

    pub fn ensureFile(self: *LiteralTrace) ?*std.c.FILE {
        if (self.disabled) {
            self.resolveGate();
            return null;
        }
        if (!self.initialized) {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_LITERAL_TRACE") orelse {
                self.resolveGate();
                return null;
            };
            if (path[0] == 0) {
                self.resolveGate();
                return null;
            }
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disable();
                return null;
            };
        }
        self.resolveGate();
        return self.file;
    }

    pub fn writeLine(self: *LiteralTrace, file: *std.c.FILE, rendered: []const u8) bool {
        if (std.c.fwrite(rendered.ptr, 1, rendered.len, file) != rendered.len or fflush(file) != 0) {
            _ = std.c.fclose(file);
            self.file = null;
            self.disable();
            return false;
        }
        self.sequence += 1;
        return true;
    }

    pub fn record(self: *LiteralTrace, site_id: u64) void {
        if (self.resolvedInactive()) return;
        self.lock();
        defer self.unlock();
        const file = self.ensureFile() orelse return;
        var line: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(
            &line,
            "{{\"schema\":1,\"engine\":\"aot\",\"phase\":\"literal\",\"seq\":{d},\"siteId\":\"0x{x:0>16}\",\"success\":true}}\n",
            .{ self.sequence, site_id },
        ) catch {
            self.disable();
            return;
        };
        _ = self.writeLine(file, rendered);
    }

    pub fn finish(self: *LiteralTrace) void {
        if (self.resolvedInactive()) return;
        self.lock();
        defer self.unlock();
        if (self.disabled) return;
        const file = if (self.initialized) self.file orelse {
            self.resolveGate();
            return;
        } else blk: {
            self.initialized = true;
            const path = std.c.getenv("LNAKO_LITERAL_TRACE") orelse {
                self.resolveGate();
                return;
            };
            if (path[0] == 0) {
                self.resolveGate();
                return;
            }
            self.file = std.c.fopen(path, "wbx") orelse {
                self.disable();
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
        if (self.writeLine(file, rendered)) self.disable();
    }
};
